#!/usr/bin/env python3
"""
xdp_quote_parser_fpga.py

FPGA-oriented NYSE XDP parser + formatter for the CE392 capstone.

What changed from the previous version
--------------------------------------
Price scaling is now POWER-OF-TWO, not decimal. Specifically:

    PRICE_SCALE_BITS = 9   ->   PRICE_SCALE = 1 << 9 = 512

So a USD price P is represented as round(P * 512) -- i.e. an unsigned Q11.9
fixed-point integer (11 integer bits + 9 fractional bits, total 20 bits).

Why power-of-two?
-----------------
On the FPGA, multiplying or dividing by a non-power-of-two like 100 (cents)
or 10000 forces the synthesizer to infer real divider hardware, which is
expensive and breaks timing on the DE2-115 at 50 MHz. With a power-of-two
scale, every "scale up" is a left shift, every "scale down" is an arithmetic
right shift, and the index-engine multiplier-then-shift pipeline meets
timing easily.

Field layout (unchanged on the wire)
------------------------------------
    payload[43:40] = local_symbol_id   (4 bits)
    payload[39:20] = bid_q9            (20 bits, USD * 512)
    payload[19:0]  = ask_q9            (20 bits, USD * 512)

UART frame (unchanged on the wire): 7 bytes = 0xAA sync + 6-byte payload.

Headroom check (with PRICE_SCALE_BITS=9):
    2^20 - 1 = 1,048,575        (max representable q9 value)
    1,048,575 / 512 ≈ $2,047.99 (max USD before overflow)
    1 / 512 ≈ 0.00195 USD       (resolution, ~0.2 cents -- subcent)

This easily covers AAPL/MSFT/NVDA/GOOGL/NFLX top-of-book ranges.

Outputs
-------
1) raw_quotes_filtered.csv  Human-readable filtered quote stream.
2) fpga_quotes.csv          FPGA-ready integer stream (q9 + USD for sanity).
3) fpga_symbol_map.csv      Local symbol-ID mapping used by RTL/UART replay.
4) fpga_payloads.bin        6-byte packed payloads only.
5) uart_frames.bin          7-byte UART frames: 0xAA + 6-byte payload.

Usage
-----
python3 xdp_quote_parser_fpga.py <input.pcap> <output_dir>
"""

from __future__ import annotations

import csv
import struct
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Wire/format constants
# ---------------------------------------------------------------------------

PCAP_FILE_HDR = 24
PCAP_REC_HDR  = 16
ETHERTYPE_VLAN = 0x8100
ETHERTYPE_IPV4 = 0x0800
IP_PROTO_UDP   = 0x11
XDP_PKT_HDR    = 16

MSG_SRC_TIME_REF = 2
MSG_SYMBOL_MAP   = 3
MSG_ADD_ORDER    = 100
MSG_DELETE_ORDER = 102

# ---- Power-of-two price scaling (Q11.9) -----------------------------------
PRICE_SCALE_BITS = 9                       # was effectively log2(100) ≈ 6.6 (cents)
PRICE_SCALE      = 1 << PRICE_SCALE_BITS   # = 512
PRICE_FIELD_BITS = 20                      # bid/ask each occupy 20 bits in payload
PRICE_FIELD_MAX  = (1 << PRICE_FIELD_BITS) - 1
USD_HEADROOM     = PRICE_FIELD_MAX / PRICE_SCALE  # ~$2047.998

# ---- Symbol mapping (unchanged) -------------------------------------------
TARGET_SYMBOLS = [
    "AAPL", "TSLA", "GOOGL", "NFLX", "NVDA",
    "MRVL", "AMD", "QCOM", "MSFT", "PLTR",
]

LOCAL_ID_MAP = {
    "AAPL": 1,  "TSLA": 2, "GOOGL": 3, "NFLX": 4, "NVDA": 5,
    "MRVL": 6,  "AMD":  7, "QCOM":  8, "MSFT": 9, "PLTR": 10,
}


@dataclass
class Quote:
    ts_sec: int
    ts_ns: int
    ts_full: int
    symbol_index: int
    symbol: str
    price_scale: int        # XDP raw price scale (decimals)
    bid_raw: int            # raw XDP integer
    ask_raw: int
    mid_raw: int
    bid_q9: int             # USD * 2^9, fits in 20 bits
    ask_q9: int
    mid_q9: int
    local_symbol_id: int
    payload_44: int


# ---------------------------------------------------------------------------
# Packet/message helpers (unchanged)
# ---------------------------------------------------------------------------

def iter_xdp_payloads(pcap_path: str) -> Iterator[bytes]:
    with open(pcap_path, "rb") as f:
        f.read(PCAP_FILE_HDR)
        while True:
            rec = f.read(PCAP_REC_HDR)
            if len(rec) < PCAP_REC_HDR:
                break
            caplen = struct.unpack_from("<I", rec, 8)[0]
            frame = f.read(caplen)
            if len(frame) < caplen:
                break

            eth_type = struct.unpack_from(">H", frame, 12)[0]
            if eth_type == ETHERTYPE_VLAN:
                eth_type = struct.unpack_from(">H", frame, 16)[0]
                ip_start = 18
            else:
                ip_start = 14

            if eth_type != ETHERTYPE_IPV4:
                continue
            if len(frame) < ip_start + 20:
                continue
            if frame[ip_start + 9] != IP_PROTO_UDP:
                continue

            ip_hdr_len = (frame[ip_start] & 0x0F) * 4
            xdp = frame[ip_start + ip_hdr_len + 8 :]
            if len(xdp) < XDP_PKT_HDR:
                continue
            yield xdp


def iter_messages(xdp: bytes) -> Iterator[Tuple[int, bytes]]:
    if xdp[2] == 1 or xdp[3] == 0:
        return
    offset = XDP_PKT_HDR
    for _ in range(xdp[3]):
        if offset + 4 > len(xdp):
            break
        msg_size = struct.unpack_from("<H", xdp, offset)[0]
        msg_type = struct.unpack_from("<H", xdp, offset + 2)[0]
        if msg_size == 0 or offset + msg_size > len(xdp):
            break
        yield msg_type, xdp[offset : offset + msg_size]
        offset += msg_size


# ---------------------------------------------------------------------------
# Symbol discovery (unchanged)
# ---------------------------------------------------------------------------

def build_symbol_table(pcap_path: str) -> Dict[int, Tuple[str, int]]:
    table: Dict[int, Tuple[str, int]] = {}
    for xdp in iter_xdp_payloads(pcap_path):
        for mtype, msg in iter_messages(xdp):
            if mtype == MSG_SYMBOL_MAP and len(msg) >= 44:
                sidx = struct.unpack_from("<I", msg, 4)[0]
                sym = msg[8:19].rstrip(b"\x00 ").decode("ascii", errors="replace")
                scale = msg[24]
                table[sidx] = (sym, scale)
    return table


def select_tracked_symbol_indexes(
    symbol_table: Dict[int, Tuple[str, int]],
) -> Dict[int, Tuple[str, int, int]]:
    tracked: Dict[int, Tuple[str, int, int]] = {}
    for sidx, (sym, scale) in symbol_table.items():
        if sym in LOCAL_ID_MAP:
            tracked[sidx] = (sym, scale, LOCAL_ID_MAP[sym])
    return tracked


# ---------------------------------------------------------------------------
# Price scaling: XDP raw -> Q11.9 (USD * 2^9)
# ---------------------------------------------------------------------------

def raw_price_to_q9(raw_price: int, price_scale: int) -> int:
    """
    Convert XDP raw integer price (USD * 10^price_scale) to a 20-bit Q11.9
    integer (USD * 2^9 = USD * 512), with nearest rounding.

    USD = raw_price / 10^price_scale
    q9  = round(USD * 512) = round(raw_price * 512 / 10^price_scale)
    """
    num = raw_price * PRICE_SCALE
    den = 10 ** price_scale
    if den == 1:
        return num
    # nearest rounding: (num + den/2) // den, valid for non-negative num/den.
    return (num + den // 2) // den


def usd_to_q9(usd: float) -> int:
    """Convenience: float USD -> Q11.9 integer with nearest rounding."""
    return int(round(float(usd) * PRICE_SCALE))


def q9_to_usd(q9: int) -> float:
    """Inverse for printing/sanity-checking only."""
    return q9 / PRICE_SCALE


def pack_payload_44(local_symbol_id: int, bid_q9: int, ask_q9: int) -> int:
    if not (0 <= local_symbol_id < (1 << 4)):
        raise ValueError(f"local_symbol_id out of 4-bit range: {local_symbol_id}")
    if not (0 <= bid_q9 <= PRICE_FIELD_MAX):
        raise ValueError(
            f"bid_q9 out of {PRICE_FIELD_BITS}-bit range: {bid_q9} "
            f"(>${USD_HEADROOM:.2f})"
        )
    if not (0 <= ask_q9 <= PRICE_FIELD_MAX):
        raise ValueError(
            f"ask_q9 out of {PRICE_FIELD_BITS}-bit range: {ask_q9} "
            f"(>${USD_HEADROOM:.2f})"
        )
    return (local_symbol_id << 40) | (bid_q9 << 20) | ask_q9


def payload_to_6bytes_be(payload_44: int) -> bytes:
    """Store 44-bit payload in 6 bytes, big-endian, upper 4 bits zero padded."""
    return payload_44.to_bytes(6, byteorder="big", signed=False)


def payload_to_uart_frame(payload_44: int) -> bytes:
    return bytes([0xAA]) + payload_to_6bytes_be(payload_44)


# ---------------------------------------------------------------------------
# Quote reconstruction
# ---------------------------------------------------------------------------

def reconstruct_quotes(
    pcap_path: str,
    tracked: Dict[int, Tuple[str, int, int]],
) -> List[Quote]:
    active_orders: Dict[int, Tuple[int, str, int]] = {}
    bid_levels: Dict[int, Dict[int, int]] = defaultdict(dict)
    ask_levels: Dict[int, Dict[int, int]] = defaultdict(dict)
    last_emitted: Dict[int, Tuple[int, int]] = {}
    source_time_sec = 0
    quotes: List[Quote] = []
    overflow_skipped = 0

    for xdp in iter_xdp_payloads(pcap_path):
        for mtype, msg in iter_messages(xdp):
            if mtype == MSG_SRC_TIME_REF and len(msg) >= 16:
                source_time_sec = struct.unpack_from("<I", msg, 12)[0]
                continue

            if mtype == MSG_ADD_ORDER and len(msg) >= 33:
                sym_idx = struct.unpack_from("<I", msg, 8)[0]
                if sym_idx not in tracked:
                    continue

                src_ns = struct.unpack_from("<I", msg, 4)[0]
                order_id = struct.unpack_from("<Q", msg, 16)[0]
                price = struct.unpack_from("<I", msg, 24)[0]
                side = chr(msg[32]) if msg[32] >= 32 else "?"
                if side not in ("B", "S"):
                    continue

                active_orders[order_id] = (sym_idx, side, price)
                levels = bid_levels[sym_idx] if side == "B" else ask_levels[sym_idx]
                levels[price] = levels.get(price, 0) + 1

                q = try_emit_quote(
                    sym_idx, src_ns, source_time_sec,
                    bid_levels, ask_levels, tracked, last_emitted,
                )
                if q is not None:
                    quotes.append(q)
                elif q is None and last_emitted.get(sym_idx) == ("OVERFLOW",):  # sentinel
                    overflow_skipped += 1
                continue

            if mtype == MSG_DELETE_ORDER and len(msg) >= 24:
                order_id = struct.unpack_from("<Q", msg, 16)[0]
                prior = active_orders.pop(order_id, None)
                if prior is None:
                    continue

                sym_idx, side, price = prior
                if sym_idx not in tracked:
                    continue

                src_ns = struct.unpack_from("<I", msg, 4)[0]
                levels = bid_levels[sym_idx] if side == "B" else ask_levels[sym_idx]
                count = levels.get(price, 0) - 1
                if count <= 0:
                    levels.pop(price, None)
                else:
                    levels[price] = count

                q = try_emit_quote(
                    sym_idx, src_ns, source_time_sec,
                    bid_levels, ask_levels, tracked, last_emitted,
                )
                if q is not None:
                    quotes.append(q)

    return quotes


def try_emit_quote(
    sym_idx: int,
    ts_ns: int,
    ts_sec: int,
    bid_levels: Dict[int, Dict[int, int]],
    ask_levels: Dict[int, Dict[int, int]],
    tracked: Dict[int, Tuple[str, int, int]],
    last_emitted: Dict[int, Tuple[int, int]],
) -> Optional[Quote]:
    b_levels = bid_levels[sym_idx]
    a_levels = ask_levels[sym_idx]
    if not b_levels or not a_levels:
        return None

    best_ask = min(a_levels.keys())
    raw_best_bid = max(b_levels.keys())

    if raw_best_bid < best_ask:
        best_bid = raw_best_bid
    else:
        valid_bids = [p for p in b_levels.keys() if p < best_ask]
        if not valid_bids:
            return None
        best_bid = max(valid_bids)

    if last_emitted.get(sym_idx) == (best_bid, best_ask):
        return None

    symbol, price_scale, local_symbol_id = tracked[sym_idx]
    bid_q9 = raw_price_to_q9(best_bid, price_scale)
    ask_q9 = raw_price_to_q9(best_ask, price_scale)

    # Reject (silently skip) any quote that would not fit in the 20-bit field.
    # This protects the FPGA from receiving truncated/wrapped prices.
    if bid_q9 > PRICE_FIELD_MAX or ask_q9 > PRICE_FIELD_MAX:
        return None

    last_emitted[sym_idx] = (best_bid, best_ask)

    mid_raw = (best_bid + best_ask) >> 1
    mid_q9  = (bid_q9 + ask_q9) >> 1
    payload = pack_payload_44(local_symbol_id, bid_q9, ask_q9)

    return Quote(
        ts_sec=ts_sec,
        ts_ns=ts_ns,
        ts_full=ts_sec * 1_000_000_000 + ts_ns,
        symbol_index=sym_idx,
        symbol=symbol,
        price_scale=price_scale,
        bid_raw=best_bid,
        ask_raw=best_ask,
        mid_raw=mid_raw,
        bid_q9=bid_q9,
        ask_q9=ask_q9,
        mid_q9=mid_q9,
        local_symbol_id=local_symbol_id,
        payload_44=payload,
    )


# ---------------------------------------------------------------------------
# Writers
# ---------------------------------------------------------------------------

def write_symbol_map_csv(path: Path, tracked: Dict[int, Tuple[str, int, int]]) -> None:
    rows = []
    for sidx, (sym, scale, local_id) in tracked.items():
        rows.append((local_id, sym, sidx, scale))
    rows.sort()
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["local_symbol_id", "symbol", "xdp_symbol_index", "xdp_price_scale"])
        w.writerows(rows)


def write_raw_quotes_csv(path: Path, quotes: List[Quote]) -> None:
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow([
            "timestamp_sec", "timestamp_ns", "timestamp_ns_full",
            "symbol_index", "symbol", "xdp_price_scale",
            "bid_raw", "ask_raw", "mid_raw",
            "bid_usd", "ask_usd", "mid_usd",
        ])
        for q in quotes:
            den = 10 ** q.price_scale
            w.writerow([
                q.ts_sec, q.ts_ns, q.ts_full,
                q.symbol_index, q.symbol, q.price_scale,
                q.bid_raw, q.ask_raw, q.mid_raw,
                f"{q.bid_raw/den:.6f}", f"{q.ask_raw/den:.6f}", f"{q.mid_raw/den:.6f}",
            ])


def write_fpga_quotes_csv(path: Path, quotes: List[Quote]) -> None:
    """
    FPGA-ready stream. Columns include both the integer Q11.9 values that the
    FPGA actually consumes, AND a human-readable USD column for sanity-checking.
    """
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow([
            "timestamp_sec", "timestamp_ns", "timestamp_ns_full",
            "symbol", "local_symbol_id",
            f"bid_q{PRICE_SCALE_BITS}",
            f"ask_q{PRICE_SCALE_BITS}",
            f"mid_q{PRICE_SCALE_BITS}",
            "bid_usd", "ask_usd", "mid_usd",
            "payload_44_hex", "payload_6B_hex", "uart_frame_7B_hex",
        ])
        for q in quotes:
            payload6 = payload_to_6bytes_be(q.payload_44)
            uart7 = payload_to_uart_frame(q.payload_44)
            w.writerow([
                q.ts_sec, q.ts_ns, q.ts_full,
                q.symbol, q.local_symbol_id,
                q.bid_q9, q.ask_q9, q.mid_q9,
                f"{q9_to_usd(q.bid_q9):.4f}",
                f"{q9_to_usd(q.ask_q9):.4f}",
                f"{q9_to_usd(q.mid_q9):.4f}",
                f"0x{q.payload_44:011X}",
                payload6.hex().upper(),
                uart7.hex().upper(),
            ])


def write_payload_bins(payload_path: Path, uart_path: Path, quotes: List[Quote]) -> None:
    with payload_path.open("wb") as fpayload, uart_path.open("wb") as fuart:
        for q in quotes:
            payload6 = payload_to_6bytes_be(q.payload_44)
            fpayload.write(payload6)
            fuart.write(b"\xAA" + payload6)


def write_readme(
    path: Path,
    tracked: Dict[int, Tuple[str, int, int]],
    quotes: List[Quote],
) -> None:
    counts = Counter(q.symbol for q in quotes)
    lines: List[str] = []
    lines.append("CE392 FPGA market-data formatting package")
    lines.append("")
    lines.append("Files")
    lines.append("-----")
    lines.append("fpga_symbol_map.csv      Local 4-bit ID mapping used by the FPGA")
    lines.append("raw_quotes_filtered.csv  Filtered top-of-book quote stream in raw/USD units")
    lines.append("fpga_quotes.csv          FPGA-ready quote stream with 20-bit Q11.9 bid/ask")
    lines.append("fpga_payloads.bin        6-byte packed payload records only")
    lines.append("uart_frames.bin          7-byte UART frames: 0xAA sync + 6-byte payload")
    lines.append("xdp_quote_parser_fpga.py This parser/formatter")
    lines.append("")
    lines.append("Price scaling (CHANGED)")
    lines.append("-----------------------")
    lines.append(f"PRICE_SCALE_BITS = {PRICE_SCALE_BITS}")
    lines.append(f"PRICE_SCALE      = 1 << {PRICE_SCALE_BITS} = {PRICE_SCALE}")
    lines.append("Format           = unsigned Q11.9 (USD * 512), 20 bits")
    lines.append(f"USD headroom     = ~${USD_HEADROOM:.4f}  (max representable price)")
    lines.append(f"Resolution       = 1/{PRICE_SCALE} USD ≈ {100/PRICE_SCALE:.4f} cents")
    lines.append("Why power-of-two : multiply / divide collapse to shifts on FPGA.")
    lines.append("")
    lines.append("Wire format (unchanged)")
    lines.append("-----------------------")
    lines.append("payload[43:40] = local_symbol_id (4 bits)")
    lines.append(f"payload[39:20] = bid_q{PRICE_SCALE_BITS} (20 bits, USD*{PRICE_SCALE})")
    lines.append(f"payload[19:0 ] = ask_q{PRICE_SCALE_BITS} (20 bits, USD*{PRICE_SCALE})")
    lines.append("UART frame     = 7 bytes: 0xAA sync + 6-byte big-endian payload")
    lines.append("                 (44-bit payload + 0xAA does not fit in 6 bytes;")
    lines.append("                  upper 4 bits of byte1 are zero-padding)")
    lines.append("")
    lines.append("Symbol map")
    lines.append("----------")
    for sym in TARGET_SYMBOLS:
        if sym in LOCAL_ID_MAP:
            lines.append(f"  {sym:5s} -> {LOCAL_ID_MAP[sym]}")
    lines.append("")
    lines.append("Tracked symbol indexes found in this PCAP")
    lines.append("-----------------------------------------")
    for sidx, (sym, scale, local_id) in sorted(tracked.items(), key=lambda kv: kv[1][2]):
        lines.append(
            f"  {sym:5s} local_id={local_id:2d} "
            f"xdp_symbol_index={sidx:6d} xdp_price_scale={scale}"
        )
    lines.append("")
    lines.append("Quote counts")
    lines.append("------------")
    for sym, cnt in counts.most_common():
        lines.append(f"  {sym:5s}: {cnt}")
    path.write_text("\n".join(lines) + "\n")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: python3 xdp_quote_parser_fpga.py <input.pcap> <output_dir>")
        return 1

    pcap_path = sys.argv[1]
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Price scale: USD * 2^{PRICE_SCALE_BITS} = {PRICE_SCALE} "
          f"(headroom ~${USD_HEADROOM:.2f}, resolution ~{100/PRICE_SCALE:.4f}¢)",
          flush=True)

    print("Pass 1: building symbol table...", flush=True)
    symbol_table = build_symbol_table(pcap_path)
    print(f"  symbol table entries: {len(symbol_table)}", flush=True)

    tracked = select_tracked_symbol_indexes(symbol_table)
    tracked_symbols = sorted(
        [v[0] for v in tracked.values()], key=lambda s: LOCAL_ID_MAP[s]
    )
    print(f"  tracked symbols found in PCAP: {tracked_symbols}", flush=True)

    missing = [s for s in TARGET_SYMBOLS if s not in tracked_symbols]
    if missing:
        print(f"  warning: target symbols missing from this PCAP: {missing}", flush=True)

    print("Pass 2: reconstructing filtered quotes and formatting for FPGA...", flush=True)
    quotes = reconstruct_quotes(pcap_path, tracked)
    print(f"  emitted FPGA-ready quotes: {len(quotes)}", flush=True)

    write_symbol_map_csv(out_dir / "fpga_symbol_map.csv", tracked)
    write_raw_quotes_csv(out_dir / "raw_quotes_filtered.csv", quotes)
    write_fpga_quotes_csv(out_dir / "fpga_quotes.csv", quotes)
    write_payload_bins(out_dir / "fpga_payloads.bin", out_dir / "uart_frames.bin", quotes)
    write_readme(out_dir / "README.txt", tracked, quotes)

    print(f"  wrote outputs to {out_dir}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())