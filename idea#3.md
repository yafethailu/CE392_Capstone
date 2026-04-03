# Low-Latency FPGA Index Engine from Replayed Market Data

This README describes a **single recommended** senior capstone (~**10 weeks**), sized for a **small Intel/Altera FPGA** and tools such as **Quartus** and **ModelSim** (or Questa). A shorter **appendix** lists alternative directions if your advisor prefers a different emphasis.

---

## Title

**Primary (recommended)**  
**Low-Latency FPGA Processing of Replayed Market Data for Real-Time Weighted Index Computation**

**Alternatives**

- *Application-first:* FPGA-Based Real-Time Weighted Index Computation from Replayed Market-Data Messages  
- *Systems-first:* Streaming Quote-State and Index Engine on FPGA Under Bursty Market-Data Replay  

---

## One-sentence summary

A **host** replays captured or synthetic traffic, extracts **framed quote updates**, and streams them to an **FPGA** that **parses**, **filters** to a fixed symbol universe, **maintains per-symbol mids**, and **emits a running weighted index** with **instrumented latency**, validated against a **software reference** and stressed under **microbursts**.

---

## Problem statement

Modern electronic trading and analytics stacks must turn **high-rate, bursty** market-data streams into a **small set of derived values** with **low and predictable delay**. Average throughput alone is misleading: during **microbursts** (e.g. market open, news, large sweeps), queues fill, backpressure appears, and **tail latency** (high percentiles and worst case) degrades unless the architecture is explicit about buffering and scheduling.

**This project** asks: given **replay** of real-world (or format-identical synthetic) messages—**not** a full on-wire TCP stack on the FPGA—can a **small FPGA** implement a **concrete streaming analytics path** that (1) **updates per-symbol quote state** for a **chosen index universe**, (2) **computes a weighted index** from those mids in real time, and (3) exposes **measurable** latency under both steady and **burst** injection, compared to a **CPU gold model**?

The scientific/engineering contribution for a capstone is **not** production certification; it is a **clear datapath**, **correctness evidence**, and **quantitative** behavior (throughput, p50/p99/max latency in cycles or time, resource use).

---

## Why this scope (vs. “full adaptive feed handler” only)

- **Avoids the networking rabbit hole:** TCP/IP, full SoupBinTCP session handling, and NIC DMA on a small board are brittle in **10 weeks**. The FPGA ingests **already-framed payloads** from the host.  
- **Clear output:** A **streaming index** is easy to explain, demo, and grade.  
- **Burst story without vague “AI”:** You still study **microbursts** by **replay rate** and **FIFO depth / backpressure**, optionally with **one simple mode** (e.g. shallow vs deep buffer) to trade average vs tail latency.  
- **Employer separation:** This document describes a **course-owned architecture**; do not submit employer code or internal specs. Your **weights** and **universe** are **your** capstone parameters.

---

## Data sources (PCAP)

**Public PCAP:** You may use **openly available Nasdaq (or exchange-style) PCAP captures from the internet** (e.g. **2023** vintage) for realistic replay, provided your course and advisor accept the source. **Cite the exact dataset** (URL, description, license if any) in your report and proposal.

**Fallback:** If policy changes, use **synthetic** messages with the **same byte layout** as the subset you implement, generated from a small script—your RTL and metrics remain valid.

---

## Method and system architecture

### End-to-end pipeline

1. **Host — replay:** Read `.pcap` (or synthetic file). Optionally filter to UDP payloads that correspond to your feed subset.  
2. **Host — extract:** Parse higher-level framing as needed for your dataset (e.g. SoupBinTCP-style **payload extraction** in software only). Emit a **simple record** to the FPGA, e.g. `{symbol_id or symbol key, bid, ask, valid}` in a **fixed binary format** you define.  
3. **FPGA — ingress:** Deserialize bytes (UART, SPI, or parallel/GPIO depending on board); optional **ingress FIFO** and **cycle-accurate timestamp** latch.  
4. **FPGA — filter & state:** If symbol ∉ **index universe**, drop. Else update stored **mid** (integer-friendly: e.g. `mid = (bid + ask) >> 1` with documented scaling).  
5. **FPGA — index:** Maintain **index = Σ weight_i × mid_i** (fixed-point weights in BRAM/registers; **incremental update** when one symbol changes: subtract old contribution, add new).  
6. **FPGA — egress:** Stream **index value** and optional **per-update latency counter** back to host or to on-board displays.  
7. **Software reference:** Same stream of records → same index logic in **C or Python** → **bit- or tolerance-match** FPGA output.

### Burst and “tail latency” evaluation (lightweight)

- Host replays at **controlled RPS** and **burst clusters** (e.g. N messages with minimal spacing, then pause).  
- FPGA records or host measures **time from message accepted to index updated** (or cycles between `valid_in` and `valid_out`).  
- Report **histograms or p50 / p99 / max**; optional **two FIFO depths** or **ready/valid backpressure** policy as a single comparison experiment.

---

## Potential hardware deliverables

| Deliverable | Description |
|-------------|-------------|
| **RTL core** | Ingress deserializer, message parser FSM for **your** fixed format, symbol filter (CAM/LUT or small RAM of allowed IDs), per-symbol mid storage, weight table, incremental weighted sum, egress serializer. |
| **Ingress buffer** | Small FIFO + overflow/drop flags (document behavior). |
| **Timestamp / latency** | Free-running counter; latch at message start and at index update for **cycle-accurate** lab measurement (even if host converts to time). |
| **Constraints & synthesis** | Quartus project, clock domain (single clock ideal), timing closure or documented Fmax. |
| **Resource report** | ALMs/LEs, registers, M9K/M10K bits, Fmax. |
| **Simulation** | ModelSim/Questa testbench with **vectors** from host export (golden from software). |
| **Board demo (if required)** | UART at modest line rate streaming records; hex/LED for subset of bits; or ILA/signaltap if course allows. |

**Scope discipline:** One **quote message type**, **fixed-point** prices, **8–32 symbols** for the index unless your FPGA is large and time permits.

---

## Software / host deliverables

- PCAP → **extractor** (Python `scapy` / `dpkt` or C) producing **binary stream** or CSV for testbench.  
- **Reference index engine** (must match FPGA semantics).  
- **Replay harness:** steady vs burst modes; optional logging of FPGA-returned index and timestamps.  
- **Plots:** latency percentiles, throughput, optional index vs time vs reference.

---

## What you can present at the end

1. **Problem & architecture** — one diagram: host replay → framed records → FPGA → index + stats.  
2. **Message format spec** — byte layout you implemented (course-owned).  
3. **Correctness** — table or plot: FPGA vs software index (max error, if fixed-point).  
4. **Performance** — Fmax, resource usage, **updates/sec**, **p50/p99/max** latency under burst.  
5. **Demo** — live or recorded: replay snippet, index updating, overflow LED or log line if stressed.  
6. **Limitations** — single message type, no full exchange stack, public PCAP cited.  
7. **Optional slide** — “future work: deeper book, more symbols, Ethernet MAC IP.”

---

## Suggested 10-week milestone schedule

| Week | Milestone |
|------|-----------|
| 1 | Lock **message format**, symbol count, weight storage; host script exports first golden vectors. |
| 2–3 | Parser + filter + mid update in RTL; unit testbench. |
| 4–5 | Weighted index (full recompute or incremental); match software reference. |
| 6 | Ingress FIFO + timestamp/latency counters; burst tests in simulation. |
| 7–8 | Synthesis, timing, board bring-up (if required). |
| 9 | PCAP replay integration, measurement plots, edge cases (unknown symbol, bad length). |
| 10 | Report, poster, demo video, cleanup repo. |

---

## Compliance boilerplate (adapt for your school)

> This capstone uses **publicly available market-data captures** (cite source) and/or **synthetic** traffic matching a **documented** message layout. It does not use proprietary employer code, internal specifications, or non-public datasets. Index weights and universes are **academic parameters** for the project.

---

## References (motivation; cite properly in your report)

- Public PCAP source you actually use (link + date).  
- Exchange **public** technical documentation for message layout **only** as needed to parse your chosen subset.  
- Microstructure / execution context: standard texts (e.g. Harris, Hasbrouck) at high level.  
- Intel Quartus and device handbooks for your board.

---

## Appendix: Other course-safe idea directions (shorter)

These are **alternatives** if your advisor wants a smaller or non–market-data project. Each fits **10 weeks** and a **small Altera** board when scoped tightly.

### A — Synthetic ticks → microstructure signals

**Problem:** Need fast, deterministic computation of mid, spread, imbalance, etc.  
**Method:** Course-defined tick word over UART; pipelined RTL; compare to C/Python.

### B — Toy pre-trade throttle / risk gate

**Problem:** Bound order rate and size with deterministic accept/reject.  
**Method:** Stream of toy orders; counters and FSM; fixed-cycle response.

### C — Fixed-point option pricing pipeline

**Problem:** Batch repricing with predictable throughput.  
**Method:** One model (e.g. Black–Scholes), LUT/polynomial approximations, error vs double.

### D — Timestamped event recorder under jitter

**Problem:** Measure bursty inter-arrival and effects on a simple consumer.  
**Method:** Wide counter, FIFO, optional delay line; Python histograms.

| Idea | Strong if you enjoy… | Main risk |
|------|----------------------|-----------|
| A | Arithmetic pipelines | Fixed-point / division |
| B | Control, FSMs | Scope creep on “orders” |
| C | Numerics | Approximation + verification time |
| D | Instrumentation | Less “finance” in the title |

---

## Tooling note

- **Intel/Altera FPGA:** **Quartus Prime** + ModelSim/Questa (per your license).  
- **Xilinx boards only:** **Vivado** — not required for Altera.  

Fill in **board model**, **clock frequency**, and **host link** (UART vs FTDI vs GPIO) when you start so pin assignments are frozen early.
