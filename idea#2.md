# Adaptive FPGA Feed Handler for Low-Tail-Latency Market Data Processing Under Microburst Conditions

## Project Overview
Modern electronic trading systems rely on feed handlers to ingest, decode, normalize, and distribute market data from exchanges in real time. While average latency is important, one of the most critical and often overlooked challenges is **tail latency during market-data microbursts**.

Microbursts occur during events such as market open, macroeconomic announcements, or sudden large order sweeps, where thousands of updates can arrive within a very short time window. Traditional software-based feed handlers and even static FPGA pipelines may experience latency spikes under these conditions.

This project aims to design and implement an **adaptive low-latency FPGA-based feed handler** that can dynamically adjust its internal buffering and scheduling strategy to maintain deterministic performance under burst traffic.

The core focus is not only achieving low average latency, but specifically reducing **worst-case and p99 latency**.

---

## Problem Statement
Most existing feed handlers are optimized for average throughput and steady-state latency. However, in practical high-frequency trading environments, **microbursts can cause queue buildup and sharp latency degradation**.

The problem this project addresses is:

**How can an FPGA feed handler dynamically adapt to burst traffic in order to minimize tail latency while preserving low steady-state latency?**

The project explores whether adaptive buffering and traffic-aware scheduling can significantly outperform a fixed FIFO architecture.

---

## Project Scope
The scope of this capstone is to design a simplified but realistic market-data processing pipeline on FPGA.

The system will include:

- **Synthetic market data message generator**
  - Generates normal traffic and configurable burst traffic patterns
  - Supports multiple symbols and quote update events

- **Message parser / decoder**
  - Parses simplified market data packets  
  - Example fields: message type, symbol, price, size, timestamp

- **Adaptive elastic buffering**
  - Uses FIFO / BRAM-based buffering
  - Dynamically changes buffering depth or path selection during bursts

- **Priority scheduler**
  - Prioritizes top-of-book updates over lower-priority depth messages
  - Minimizes latency for the most critical information

- **Top-of-book reconstruction**
  - Maintains best bid and ask state for multiple symbols

- **Latency measurement framework**
  - Measures end-to-end latency in FPGA clock cycles
  - Compares static vs adaptive buffering approaches

This project will focus on **architecture and latency optimization**, rather than full implementation of exchange protocols such as ITCH or CME MDP.

---

## Goals
The primary goals of this project are:

- Design a functional FPGA-based feed-handler pipeline
- Implement adaptive burst-aware buffering
- Measure and compare latency performance
- Reduce **p99 and worst-case latency**
- Demonstrate robustness under synthetic microburst traffic
- Provide quantitative latency results and performance plots

Target evaluation metrics include:

- p50 latency
- p99 latency
- maximum observed latency
- throughput under burst load
- BRAM / LUT utilization

---

## Expected Deliverables
By the end of the project, the following deliverables are expected:

- Complete FPGA RTL / HLS design
- Simulation testbench with configurable traffic patterns
- Latency measurement and analysis scripts
- Performance comparison report
- Final presentation and demo
- GitHub repository with source code and documentation

---

## Hardware Resources
The project requires access to an FPGA development board.

Recommended platforms include:

- Xilinx Artix / Kintex board
- Zynq development board
- UltraScale+ board (preferred if available)

Minimum hardware requirements:

- BRAM resources for elastic buffers
- stable clocking support
- enough LUT / FF resources for parser and scheduler
- optional Ethernet interface for future extension

---

## Software Resources
The following software tools will be used:

- **Vivado**
  - synthesis
  - implementation
  - timing analysis
  - bitstream generation

- **Vivado Simulator / ModelSim**
  - functional verification
  - waveform debugging

- **Python**
  - synthetic traffic generation
  - latency histogram plotting
  - data analysis with `pandas` and `matplotlib`

- **Git / GitHub**
  - version control
  - documentation
  - milestone tracking

Optional:

- **Vitis HLS**
  - for rapid prototyping of selected modules

---

## Significance
This project addresses a highly practical and industry-relevant problem in **low-latency trading systems and FPGA acceleration**.

It combines concepts from:

- FPGA system design
- digital architecture
- buffering and scheduling
- real-time systems
- high-frequency trading infrastructure

The outcome will provide hands-on experience directly applicable to FPGA and low-latency engineering roles in trading and hardware systems.

---

## Timeline (10 Weeks)
- **Weeks 1–2:** architecture design and testbench setup
- **Weeks 3–4:** parser and static buffer implementation
- **Weeks 5–6:** adaptive buffering design
- **Weeks 7–8:** scheduler and latency instrumentation
- **Week 9:** evaluation and performance analysis
- **Week 10:** final demo and report
