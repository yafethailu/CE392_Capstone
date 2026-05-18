# eth_loopback_v2_top.sdc
# Timing constraints for the alexforencich MAC-based loopback test.

# ── Clocks ───────────────────────────────────────────────────────────────
# 50 MHz system clock
create_clock -name clk_50         -period 20.000 [get_ports CLOCK_50]

# 25 MHz Ethernet RX clock from PHY (sourced by PHY in MII 100 Mbit mode)
create_clock -name enet0_rx_clk   -period 40.000 [get_ports ENET0_RX_CLK]

# 25 MHz Ethernet TX clock from PHY (PHY also sources this in MII mode)
create_clock -name enet0_tx_clk   -period 40.000 [get_ports ENET0_TX_CLK]

derive_pll_clocks
derive_clock_uncertainty

# ── Clock groups ─────────────────────────────────────────────────────────
# All three clocks are asynchronous to each other. The MAC's internal
# async FIFOs handle CDC.
set_clock_groups -asynchronous \
    -group {clk_50} \
    -group {enet0_rx_clk} \
    -group {enet0_tx_clk}

# ── PHY input/output timing ──────────────────────────────────────────────
# MII spec: PHY drives RX data on RX_CLK rising edge.
# FPGA samples on the NEXT rising edge.
# Generous 10 ns setup/hold; this is a 25 MHz interface, plenty of margin.
set_input_delay  -clock enet0_rx_clk -max 10  [get_ports {ENET0_RX_DV ENET0_RXD[*] ENET0_RX_ER}]
set_input_delay  -clock enet0_rx_clk -min 0   [get_ports {ENET0_RX_DV ENET0_RXD[*] ENET0_RX_ER}]

# TX side: FPGA drives data on TX_CLK rising edge for PHY to sample.
set_output_delay -clock enet0_tx_clk -max 10  [get_ports {ENET0_TX_EN ENET0_TXD[*]}]
set_output_delay -clock enet0_tx_clk -min 0   [get_ports {ENET0_TX_EN ENET0_TXD[*]}]

# ── Async I/O - don't time ───────────────────────────────────────────────
set_false_path -from [get_ports KEY[*]]
set_false_path -to   [get_ports {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*]}]
set_false_path -to   [get_ports {ENET0_RST_N ENET0_MDC}]
set_false_path -from [get_ports ENET0_MDIO]
set_false_path -to   [get_ports ENET0_MDIO]
