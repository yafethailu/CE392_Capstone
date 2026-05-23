// de2_115_eth_top.v   (Ethernet-input version)
// -----------------------------------------------------------------------------
// CHANGED from UART path:
//   - removed UART_RXD pin
//   - added   ENET0_RX_CLK / ENET0_RX_DV / ENET0_RXD / ENET0_RX_ER
//   - added   ENET0_RST_N  / ENET0_MDC
//   - swapped instantiated module name 'market' → 'market_top' (no wrapper)
//   - exposed parser diagnostics as outputs (optional — pin them to spare
//     GPIO or leave as undriven module outputs for SignalTap inspection)
// -----------------------------------------------------------------------------

module de2_115_top (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,         // KEY[0] = reset (active low)

    // Ethernet 0 MII (Marvell 88E1111, 100BASE-T) - replaces UART_RXD
    input  wire        ENET0_RX_CLK,
    input  wire        ENET0_RX_DV,
    input  wire [3:0]  ENET0_RXD,
    input  wire        ENET0_RX_ER,
    output wire        ENET0_RST_N,
    output wire        ENET0_MDC,

    output wire [17:0] LEDR,
    output wire [6:0]  HEX0,
    output wire [6:0]  HEX1,
    output wire [6:0]  HEX2,
    output wire [6:0]  HEX3,
    output wire [6:0]  HEX4,
    output wire [6:0]  HEX5
);
    wire rst = ~KEY[0];

    // Parser diagnostics — exposed as named wires so they can be
    // observed in SignalTap, even though they aren't driving pins
    // in this minimal top-level. Add pin assignments to expose on
    // GPIO/spare LEDR if needed.
    wire [15:0] xdp_pkts_parsed;
    wire [15:0] add_orders_found;
    wire [15:0] all_add_orders;
    wire [15:0] quotes_emitted;
    wire [15:0] records_passed;
    wire [15:0] records_dropped;

    market_top #(
        .CLK_FREQ_HZ(50_000_000)
    ) u_sentinel (
        .clk               (CLOCK_50),
        .rst               (rst),

        // Ethernet ingress (replaces uart_rx_i)
        .ENET0_RX_CLK      (ENET0_RX_CLK),
        .ENET0_RX_DV       (ENET0_RX_DV),
        .ENET0_RXD         (ENET0_RXD),
        .ENET0_RX_ER       (ENET0_RX_ER),
        .ENET0_RST_N       (ENET0_RST_N),
        .ENET0_MDC         (ENET0_MDC),

        // Alerts (tapped internally via LEDs in alert_visualization)
        .alert_velocity_o  (),
        .alert_deviation_o (),
        .alert_any_o       (),

        // Board display
        .ledr_o            (LEDR),
        .hex0_o            (HEX0),
        .hex1_o            (HEX1),
        .hex2_o            (HEX2),
        .hex3_o            (HEX3),
        .hex4_o            (HEX4),
        .hex5_o            (HEX5),

        // Debug taps (open here; bring to GPIO if you want them on a logic analyzer)
        .fifo_dout_o       (),
        .fifo_empty_o      (),
        .fifo_count_o      (),
        .rec_count_o       (),
        .index_value_o     (),
        .xdp_pkts_parsed_o (xdp_pkts_parsed),
        .add_orders_found_o(add_orders_found),
        .all_add_orders_o  (all_add_orders),
        .quotes_emitted_o  (quotes_emitted),
        .records_passed_o  (records_passed),
        .records_dropped_o (records_dropped)
    );

endmodule