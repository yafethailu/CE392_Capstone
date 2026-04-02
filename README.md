# CE392_Capstone
Capstone FPGA project for CE 392 -- Northwestern University


# FPGA × Low-Latency Trading — Capstone Project Ideas

This document collects **course-safe** project directions: they are meant for a **senior capstone** (~10 weeks), a **small Intel/Altera FPGA board**, and tools such as **Quartus**, **ModelSim** (or Questa), plus any software you like for reference models and host I/O.

**Important:** These ideas are **generic** teaching and research prototypes. They do **not** assume employer-specific code, data, or production feed formats. If your institution requires separation from internship or employer IP, state explicitly that you use **synthetic protocols and formulas** defined for the project.

---

## Constraints (typical)

| Constraint | Implication |
|-------------|-------------|
| ~10 weeks | One focused subsystem, not a full exchange stack |
| Small FPGA | Avoid full TCP, deep L2 books, PCIe DMA unless the course provides a reference design |
| Altera/Intel | Use **Quartus** for synthesis; **Vivado** is for Xilinx boards only |

**Reasonable deliverables:** synthesizable RTL, simulation testbenches, timing/resource report, optional live demo (UART, GPIO, hex displays), and a short comparison to a **software gold model** (e.g. C or Python).

---

## Idea 1 — Synthetic market ticks → hardware microstructure signals

### Problem

In electronic markets, decisions often depend on **very fast** updates of the best bid and ask and the **sizes** at those prices. Research and execution systems need **low-latency, deterministic** computation of simple quantities derived from that top-of-book snapshot (mid, spread, imbalance, custom weighted mids, etc.). Software alone can be fast, but jitter, OS scheduling, and cache effects make **worst-case** behavior harder to bound. An FPGA can offer **predictable pipeline latency** and dedicated parallelism for streaming math.

### Method

1. **Define a synthetic tick format** (course-owned), e.g. fixed-point `bid`, `ask`, `bid_size`, `ask_size` packed into a 32- or 64-bit word, streamed in over UART, GPIO, or testbench-only stimulus.
2. **Implement a pipelined RTL block** that, each valid tick, computes quantities **you specify and document**, for example:
   - `mid = (bid + ask) / 2` (integer-friendly variants using shifts),
   - `spread = ask - bid`,
   - **imbalance** \(I = \frac{B - A}{B + A}\) in fixed-point (avoid division with a small LUT or iterative divider, or restrict sizes to powers of two for a simplified demo).
3. **Optional:** a **custom weighted mid** (your formula, e.g. size-weighted combination of bid and ask) — clearly motivated in the write-up (e.g. “proxy for short-horizon fair value under toy assumptions”).
4. **Verification:** bit- or tolerance-compare against a **C or Python reference** on the same inputs.
5. **Evaluation:** report **latency in clock cycles**, **throughput** (ticks per second at target Fmax), and **ALMs/LEs, registers, memory bits**.

### Why it fits “HFT-adjacent”

Top-of-book features are a standard building block in **market microstructure** and **execution**. The project stays clear of real exchange protocols and proprietary signals.

---

## Idea 2 — FPGA pre-trade throttle and risk gate (toy order stream)

### Problem

Live trading stacks often need **hard limits** on how aggressively a strategy can send orders: maximum rate, maximum size per symbol, maximum total notional, or an emergency **kill switch**. Doing this only in software can add **variable delay**; for coursework, the interesting question is how to implement **deterministic, low-latency accept/reject** logic in hardware given a stream of **toy order requests**.

### Method

1. **Define a minimal order message:** e.g. `{symbol_id, side, quantity}` with fixed width; quantities and symbol ids in small ranges suitable for the FPGA.
2. **Implement hardware state:**
   - **Global:** orders per second (sliding window or token bucket simplified as fixed-interval counter reset),
   - **Per-symbol:** cumulative quantity or notional caps (toy “notional” = quantity × constant),
   - **Kill:** one input bit or register that forces **reject all**.
3. **Output:** `accept` / `reject` (and optional **reason code**) in **fixed cycles** after each request.
4. **Verification:** testbench with bursts, edge cases (exactly at limit, wraparound of timers), and kill activation.
5. **Evaluation:** same as Idea 1 (resources, Fmax, latency), plus a short discussion of **jitter vs. a software implementation** measured on PC if you have time.

### Why it fits “HFT-adjacent”

**Pre-trade risk and throttling** are standard in institutional execution; the FPGA emphasizes **determinism** and **bounded response time**, which is aligned with low-latency systems thinking.

---

## Idea 3 — Fixed-point option pricing kernel (batch pipeline)

### Problem

Risk and desk tools often need to revalue many strikes or scenarios **quickly**. For a capstone, you narrow to **one** well-known model (e.g. **Black–Scholes** for a European call, or a **binary** cash-or-nothing option) and ask: can an FPGA **pipeline** many evaluations per second with **predictable** timing, compared to a CPU loop?

### Method

1. **Choose one closed-form** and a **fixed-point format** (integer scaled by \(2^k\)) for inputs \(S, K, T, \sigma, r\) and outputs.
2. **Implement in RTL:** optional **CORDIC** or LUT-based approximations for \(\log\), \(\sqrt\), \(\exp\), **normal CDF** (piecewise polynomial or small LUT + interpolation) — scope to what fits 10 weeks.
3. **Interface:** host sends a **batch** of parameter sets; FPGA streams back prices (and optionally **one Greek**, e.g. delta) — UART framing is enough for a demo.
4. **Verification:** compare to **double-precision** software on the same inputs; document **maximum absolute/relative error** given your bit widths.
5. **Evaluation:** **options per second** at Fmax vs. single-core C; resource usage.

### Why it fits “HFT-adjacent”

**Fast repricing** under scenario shocks is relevant to **options market making and risk**, without requiring market data feeds or order matching.

---

## Idea 4 — Timestamped event recorder and latency / jitter study

### Problem

Low-latency systems are often analyzed with **precise timestamps** and **histograms** of inter-arrival times. Understanding **buffering, backpressure, and jitter** matters when a consumer cannot keep up with a producer. A small FPGA can **timestamp, optionally delay, and log** events at **nanosecond-scale resolution** relative to the board clock.

### Method

1. **Event source:** UART bytes, GPIO edges, or a **programmable pattern generator** in RTL.
2. **FPGA:** free-running **wide counter**; on each event, latch `{timestamp, event_id}` into a **small FIFO** or ring buffer; optional **programmable delay line** (N-cycle shift register) to simulate **variable network latency**.
3. **Host:** read out records (UART/USB-serial bridge if available) and plot **inter-arrival distributions** in Python.
4. **Software consumer:** simple **downstream algorithm** (e.g. EMA on a scalar derived from the event) running on PC; compare behavior with and without hardware-inserted jitter.
5. **Evaluation:** demonstrate **monotonic timestamps**, FIFO overflow handling, and **measurement resolution** in terms of clock period.

### Why it fits “HFT-adjacent”

**Measurement infrastructure** and **deterministic handling of bursty feeds** are central to production trading technology; this idea foregrounds **instrumentation** rather than alpha.

---

## Choosing one idea

| Idea | Strong if you enjoy… | Main risk |
|------|----------------------|-----------|
| 1 — Ticks → signals | Arithmetic pipelines, microstructure narrative | Division / fixed-point error needs care |
| 2 — Risk gate | Control logic, FSMs, timing of limits | Keeping scope small (toy protocol only) |
| 3 — Options kernel | numerical methods, error analysis | Approximation and verification effort |
| 4 — Timestamp / jitter | systems, host plots, methodology | Less “trading feature,” more infrastructure |

---

## Suggested proposal boilerplate (compliance)

> This capstone uses **synthetic data and a specification written for the course**. It does not use proprietary code, datasets, or internal documentation from any employer. Any comparison to industry practice is **high-level** and cited from public sources (textbooks, papers, or exchange **public** technical documentation).

---

## References (public, for motivation only)

- Market microstructure and execution: standard texts (e.g. **Harris**, *Trading and Exchanges*; **Hasbrouck**, *Empirical Market Microstructure*) — for **problem motivation**, not for copying any proprietary workflow.
- FPGA workflow: your course lab materials and **Intel Quartus** documentation for your specific device.

If you add your **board model** and **whether hardware demo is required**, you can extend this README with a **pinout / clock plan** appendix for the idea you select.
