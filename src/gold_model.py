"""
golden_model.py

Cycle-accurate Python reference for the FPGA pipeline (M1 -> M3).

Reads uart_frames.bin, produces a per-record trace of:
    sym, bid_q9, ask_q9, new_mid_q9, prev_mid_q9, delta_mid, delta_index,
    index_value, velocity, deviation, mean_window, alert, severity

This is the oracle the Verilog testbenches diff against. If the FPGA
disagrees with this model on any record, by even 1 LSB, that's a bug.

Important: every arithmetic operation here uses Python int (arbitrary
precision), but we mask each computed value to the actual bit width the
FPGA uses. That's what makes it cycle-accurate -- we exactly mimic the
truncation, sign extension, and shift behavior of the hardware.

Key parameters (must match Verilog):
    PRICE_SCALE_BITS = 9        Q11.9 fixed-point
    INDEX_WIDTH      = 64       signed accumulator
    WINDOW_SIZE      = 16       rolling window depth
    WINDOW_SHIFT     = 4        log2(WINDOW_SIZE), divide-by-shift
    WEIGHT_SHIFT     = 14       weights sum to 2^14
    NUM_SYMBOLS      = 16       4-bit symbol IDs, slot 0 unused
"""

from __future__ import annotations

import argparse
import csv
import struct
import sys
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


# ----------------------------------------------------------------------------
# Fixed parameters -- MUST match the Verilog parameters exactly.
# ----------------------------------------------------------------------------

PRICE_SCALE_BITS = 9
PRICE_SCALE      = 1 << PRICE_SCALE_BITS         # 512
PRICE_FIELD_BITS = 20
PRICE_FIELD_MAX  = (1 << PRICE_FIELD_BITS) - 1

INDEX_WIDTH      = 64
INDEX_MASK       = (1 << INDEX_WIDTH) - 1
INDEX_SIGN_BIT   = 1 << (INDEX_WIDTH - 1)
INDEX_MIN        = -(1 << (INDEX_WIDTH - 1))
INDEX_MAX        =  (1 << (INDEX_WIDTH - 1)) - 1

WINDOW_SIZE      = 16
WINDOW_SHIFT     = 4
assert (1 << WINDOW_SHIFT) == WINDOW_SIZE

WEIGHT_SHIFT     = 14
WEIGHT_SCALE     = 1 << WEIGHT_SHIFT             # 16384

NUM_SYMBOLS      = 16    # 4-bit field
RECORD_BYTES     = 7
SYNC_BYTE        = 0xAA


# ----------------------------------------------------------------------------
# Weight table -- MUST match weights_rom.v exactly.
# Sum verified == 16384 (= 2^14 = WEIGHT_SCALE).
#
# Partner's market_sentinel_top FSM does (sym_id - 1) to convert wire IDs
# (1..10) to ROM addresses (0..9). The golden model takes wire IDs (1..10)
# as input and applies the same -1 conversion before looking up the weight.
# ----------------------------------------------------------------------------

WEIGHTS_BY_ADDR = {
    0:  5015,      # AAPL  (wire id 1)
    1:  1402,      # TSLA  (wire id 2)
    2:  1384,      # GOOGL (wire id 3)
    3:   822,      # NFLX  (wire id 4)
    4:  1955,      # NVDA  (wire id 5)
    5:   274,      # MRVL  (wire id 6)
    6:   639,      # AMD   (wire id 7)
    7:   457,      # QCOM  (wire id 8)
    8:  4298,      # MSFT  (wire id 9)
    9:   138,      # PLTR  (wire id 10)
}

# Indexed by wire ID (what the parser emits, 1..10).
WEIGHTS = {0: 0}
for addr, w in WEIGHTS_BY_ADDR.items():
    WEIGHTS[addr + 1] = w
for wire_id in range(11, 16):
    WEIGHTS[wire_id] = 0

SYMBOL_NAMES = {
    0: "----",
    1: "AAPL", 2: "TSLA", 3: "GOOGL", 4: "NFLX", 5: "NVDA",
    6: "MRVL", 7: "AMD",  8: "QCOM",  9: "MSFT", 10: "PLTR",
}

assert sum(WEIGHTS.values()) == WEIGHT_SCALE, \
    f"weights must sum to {WEIGHT_SCALE}, got {sum(WEIGHTS.values())}"


# ----------------------------------------------------------------------------
# Bit-accurate arithmetic helpers
# ----------------------------------------------------------------------------

def to_signed(val: int, width: int) -> int:
    """Interpret a Python int as a width-bit two's complement signed value."""
    mask = (1 << width) - 1
    val &= mask
    sign = 1 << (width - 1)
    return val - (1 << width) if (val & sign) else val

def to_unsigned(val: int, width: int) -> int:
    """Wrap a Python int into width-bit unsigned."""
    return val & ((1 << width) - 1)

def asr(val: int, n: int) -> int:
    """Arithmetic shift right preserving sign. Python's >> already does this."""
    return val >> n


# ----------------------------------------------------------------------------
# Per-record trace entry. One per record consumed from the FIFO.
# ----------------------------------------------------------------------------

@dataclass
class Trace:
    seq:          int
    sym:          int
    bid_q9:       int
    ask_q9:       int
    new_mid_q9:   int
    prev_mid_q9:  int
    delta_mid:    int       # signed, 21-bit (range of 20-bit unsigned diff)
    delta_index:  int       # signed, 64-bit-accumulator units
    index_value:  int       # signed, 64-bit
    velocity:     int       # signed; index[t] - index[t-1]
    deviation:    int       # signed; index[t] - mean(window)
    mean_window:  int       # signed
    window_filled:bool
    alert:        bool
    severity:     int       # 0=green, 1=yellow, 2=red (per decision 4)


# ----------------------------------------------------------------------------
# The model itself
# ----------------------------------------------------------------------------

class PipelineModel:
    """
    Stateful model. Feed records one at a time via .step(); it returns a
    Trace and updates internal state to mirror the FPGA's registers.
    """

    def __init__(self, vel_thresh: int = 0, dev_thresh: int = 0):
        # Per-symbol previous-midprice state. Mirrors symbol_state_mem.v.
        self.prev_mid: list[int] = [0] * NUM_SYMBOLS

        # The running index. Signed 64-bit accumulator.
        self.index_value: int = 0

        # Previous index value for velocity computation.
        self.prev_index_value: int = 0

        # Rolling window. We keep it as a deque + running sum (running sum
        # mirrors the FPGA, which would maintain it incrementally rather
        # than re-summing W entries every record).
        self.window: deque[int] = deque(maxlen=WINDOW_SIZE)
        self.window_sum: int = 0

        # Anomaly thresholds (runtime-tunable, from slide switches).
        self.vel_thresh = vel_thresh
        self.dev_thresh = dev_thresh

        # Sequence counter for tracing.
        self.seq = 0

    # ------------------------------------------------------------------------
    def step(self, sym: int, bid_q9: int, ask_q9: int) -> Trace:
        """
        Consume one record. Returns a Trace that captures every intermediate
        value, exactly as the FPGA pipeline would compute it.

        Mirrors what the read-modify-write controller does in hardware:
          1. read prev_mid for this symbol
          2. compute new_mid = (bid + ask) >> 1
          3. delta_mid = new_mid - prev_mid (signed)
          4. delta_index = (delta_mid * weight) >>> WEIGHT_SHIFT
          5. index_value += delta_index
          6. write new_mid back to symbol_state_mem
          7. shift index_value into rolling window, update sum
          8. compute velocity, deviation
          9. evaluate alert + severity
        """
        # Bounds-check inputs (the FPGA would just truncate; we assert here
        # so model misuse fails loudly in test).
        assert 0 <= sym < NUM_SYMBOLS, f"sym {sym} out of 4-bit range"
        assert 0 <= bid_q9 <= PRICE_FIELD_MAX
        assert 0 <= ask_q9 <= PRICE_FIELD_MAX

        # ----- 1. read prev_mid (would be a 1-cycle synchronous read) -------
        prev = self.prev_mid[sym]

        # ----- 2. midprice (combinational) ---------------------------------
        # 20-bit bid + 20-bit ask -> need 21-bit carry-aware sum, then >> 1
        # gives back 20 bits. matches midprice_compute.v.
        s = bid_q9 + ask_q9
        new_mid = (s >> 1) & PRICE_FIELD_MAX

        # ----- 3. delta_mid (signed) ---------------------------------------
        # Both new_mid and prev are 20-bit unsigned values in [0, 2^20).
        # Their difference is in (-2^20, +2^20), needing 21 bits signed.
        delta_mid = new_mid - prev   # Python int; we'll re-mask at use

        # ----- 4. weighted delta -------------------------------------------
        w = WEIGHTS.get(sym, 0)
        # 21-bit signed * 15-bit unsigned (weights fit in 13 bits actually)
        # Product is at most 21+15 = 36 bits signed -> well within 64-bit
        # accumulator.
        weighted = delta_mid * w

        # ----- 4b. arithmetic right shift by WEIGHT_SHIFT ------------------
        # This is the key FPGA-friendly trick: /16384 collapses to >>> 14.
        # Python's >> on a negative int is arithmetic shift, exactly what
        # the FPGA does with $signed(x) >>> 14.
        delta_index = weighted >> WEIGHT_SHIFT

        # ----- 5. accumulator update (signed 64-bit wrap) ------------------
        new_index = self.index_value + delta_index
        # Mirror Verilog: signed 64-bit truncation (wrap-around if overflow).
        new_index = to_signed(to_unsigned(new_index, INDEX_WIDTH), INDEX_WIDTH)

        # ----- 6. write back prev_mid --------------------------------------
        self.prev_mid[sym] = new_mid

        # ----- 7. push into rolling window ---------------------------------
        # FPGA does this incrementally: sum -= oldest, append newest, sum += newest.
        if len(self.window) == WINDOW_SIZE:
            oldest = self.window[0]
            self.window_sum -= oldest
        else:
            oldest = 0   # window not yet full
        self.window.append(new_index)
        self.window_sum += new_index

        window_filled = (len(self.window) == WINDOW_SIZE)
        # Mean = sum >>> 4. Only meaningful once window is full.
        # When not full, FPGA can either gate the comparison or use partial
        # sum; we use partial mean here for completeness, but flag with
        # window_filled.
        if window_filled:
            mean = self.window_sum >> WINDOW_SHIFT
        else:
            mean = self.window_sum // max(1, len(self.window))

        # ----- 8. velocity & deviation -------------------------------------
        velocity  = new_index - self.prev_index_value
        deviation = new_index - mean

        # ----- 9. anomaly evaluation ---------------------------------------
        # Per spec + decisions: alert iff |velocity| > vel_thresh AND
        # |deviation| > dev_thresh, AND the window has filled (no false
        # alerts during startup).
        vel_exceeded = abs(velocity)  > self.vel_thresh
        dev_exceeded = abs(deviation) > self.dev_thresh

        if not window_filled:
            severity = 0
            alert    = False
        elif vel_exceeded and dev_exceeded:
            severity = 2    # red
            alert    = True
        elif vel_exceeded or dev_exceeded:
            severity = 1    # yellow
            alert    = False
        else:
            severity = 0    # green
            alert    = False

        # ----- record state -----------------------------------------------
        self.prev_index_value = new_index
        self.index_value      = new_index

        trace = Trace(
            seq           = self.seq,
            sym           = sym,
            bid_q9        = bid_q9,
            ask_q9        = ask_q9,
            new_mid_q9    = new_mid,
            prev_mid_q9   = prev,
            delta_mid     = delta_mid,
            delta_index   = delta_index,
            index_value   = new_index,
            velocity      = velocity,
            deviation     = deviation,
            mean_window   = mean,
            window_filled = window_filled,
            alert         = alert,
            severity      = severity,
        )
        self.seq += 1
        return trace


# ----------------------------------------------------------------------------
# Wire-level decoder (reads uart_frames.bin produced by the parser)
# ----------------------------------------------------------------------------

def decode_record(rec: bytes) -> tuple[int, int, int]:
    """Mirror what the FPGA assembler+unpacker produce: (sym, bid_q9, ask_q9)."""
    if len(rec) != RECORD_BYTES or rec[0] != SYNC_BYTE:
        raise ValueError(f"bad record: {rec.hex(' ')}")
    val = 0
    for b in rec[1:]:
        val = (val << 8) | b
    sym    = (val >> 40) & 0xF
    bid_q9 = (val >> 20) & 0xFFFFF
    ask_q9 = (val >>  0) & 0xFFFFF
    return sym, bid_q9, ask_q9


def iter_records(bin_path: str):
    """Yield (sym, bid_q9, ask_q9) tuples from a uart_frames.bin file."""
    data = Path(bin_path).read_bytes()
    if len(data) % RECORD_BYTES != 0:
        raise ValueError(f"{bin_path} size {len(data)} not divisible by {RECORD_BYTES}")
    n = len(data) // RECORD_BYTES
    for i in range(n):
        yield decode_record(data[i*RECORD_BYTES:(i+1)*RECORD_BYTES])


# ----------------------------------------------------------------------------
# CLI runner
# ----------------------------------------------------------------------------

def run(bin_path: str,
        vel_thresh: int,
        dev_thresh: int,
        out_csv: Optional[str],
        max_records: int) -> None:

    model = PipelineModel(vel_thresh=vel_thresh, dev_thresh=dev_thresh)
    traces: list[Trace] = []

    for i, (sym, bid, ask) in enumerate(iter_records(bin_path)):
        if max_records and i >= max_records:
            break
        if sym == 0 or sym > 10:
            # untracked / pad records -- still emit a trace, but with zero
            # weight, so they don't move the index.
            pass
        t = model.step(sym, bid, ask)
        traces.append(t)

    print(f"Processed {len(traces)} records")
    if traces:
        final = traces[-1]
        print(f"Final index value : {final.index_value:>20}")
        print(f"Final velocity    : {final.velocity:>20}")
        print(f"Final deviation   : {final.deviation:>20}")
        print(f"Mean (window)     : {final.mean_window:>20}")
        n_alerts = sum(1 for t in traces if t.alert)
        n_yellow = sum(1 for t in traces if t.severity == 1)
        print(f"Alerts (red)      : {n_alerts}")
        print(f"Warnings (yellow) : {n_yellow}")

        # Show a few in human-readable form
        print("\nFirst 5 records:")
        for t in traces[:5]:
            print(f"  seq={t.seq:>3}  sym={SYMBOL_NAMES.get(t.sym,'?'):5s}  "
                  f"new_mid={t.new_mid_q9:>7}  delta_mid={t.delta_mid:>+7}  "
                  f"index={t.index_value:>+12}  vel={t.velocity:>+8}  "
                  f"dev={t.deviation:>+8}  sev={t.severity}")

    if out_csv:
        with open(out_csv, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow([
                "seq", "sym", "sym_name", "bid_q9", "ask_q9",
                "new_mid_q9", "prev_mid_q9", "delta_mid", "delta_index",
                "index_value", "velocity", "deviation", "mean_window",
                "window_filled", "severity", "alert"
            ])
            for t in traces:
                w.writerow([
                    t.seq, t.sym, SYMBOL_NAMES.get(t.sym,'?'),
                    t.bid_q9, t.ask_q9, t.new_mid_q9, t.prev_mid_q9,
                    t.delta_mid, t.delta_index, t.index_value,
                    t.velocity, t.deviation, t.mean_window,
                    int(t.window_filled), t.severity, int(t.alert)
                ])
        print(f"\nWrote trace to {out_csv}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Golden model for FPGA index pipeline.")
    ap.add_argument("--bin", required=True, help="uart_frames.bin from parser")
    ap.add_argument("--vel-thresh", type=int, default=1000,
                    help="Velocity threshold (signed magnitude). Default 1000.")
    ap.add_argument("--dev-thresh", type=int, default=5000,
                    help="Deviation threshold (signed magnitude). Default 5000.")
    ap.add_argument("--out-csv", default=None,
                    help="Optional CSV trace output")
    ap.add_argument("--max-records", type=int, default=0,
                    help="If >0, stop after N records (for quick iteration)")
    args = ap.parse_args()
    run(args.bin, args.vel_thresh, args.dev_thresh, args.out_csv, args.max_records)
    return 0


if __name__ == "__main__":
    sys.exit(main())