// de2_115_top.v
// Board-level top for  DE2-115 (Cyclone IV E)
//
// works with UART for now

module de2_115_top (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,         // KEY[0] = reset (active low on DE2-115)
    input  wire        UART_RXD,    // Onboard RS-232 RX (JP1 header alt. below)
    // input wire      GPIO_0_0,    // Uncomment to use FTDI on GPIO header
    output wire [17:0] LEDR,
    output wire [6:0]  HEX0,
    output wire [6:0]  HEX1,
    output wire [6:0]  HEX2,
    output wire [6:0]  HEX3,
    output wire [6:0]  HEX4,
    output wire [6:0]  HEX5
);
    wire rst = ~KEY[0];   // KEY is active-low; invert for active-high reset

    market #(
        .CLK_FREQ_HZ (50_000_000),
        .BAUD_RATE   (115_200)
    ) u_sentinel (
        .clk             (CLOCK_50),
        .rst             (rst),
        .uart_rx_i       (UART_RXD),   // swap to GPIO_0_0 for FTDI path
        .alert_velocity_o (),           // tapped internally via LEDs
        .alert_deviation_o(),
        .alert_any_o      (),
        .ledr_o          (LEDR),
        .hex0_o          (HEX0),
        .hex1_o          (HEX1),
        .hex2_o          (HEX2),
        .hex3_o          (HEX3),
        .hex4_o          (HEX4),
        .hex5_o          (HEX5),
        // Debug taps: left open for synthesis; connect to LEDR/GPIO for debug
        .fifo_dout_o     (),
        .fifo_empty_o    (),
        .fifo_count_o    (),
        .rec_count_o     (),
        .index_value_o   ()
    );
endmodule
