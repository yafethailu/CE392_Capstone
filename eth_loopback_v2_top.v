// eth_loopback_v2_top.v
// -----------------------------------------------------------------------------
// Ethernet loopback test using alexforencich's eth_mac_mii_fifo as the MAC.
//
// This replaces our homebrew eth_mac_bridge with a battle-tested MAC that:
//   - Handles preamble/SFD detection correctly
//   - Validates FCS (CRC32) and drops corrupt frames
//   - Provides a standard AXI-Stream output interface
//   - Crosses the rx_clk -> clk domain via an async FIFO
//
// Same test as before:
//   - Send any Ethernet frame from laptop
//   - Byte 14 of frame appears on HEX1:HEX0
//   - Frame counter appears on HEX3:HEX2
//
// The AXI-Stream interface from eth_mac_mii_fifo:
//   rx_axis_tdata  : 8-bit data (one byte per cycle)
//   rx_axis_tvalid : data valid
//   rx_axis_tready : sink ready (we tie high — always ready)
//   rx_axis_tlast  : end-of-frame marker
//   rx_axis_tuser  : bad-frame marker (asserted with tlast if FCS failed)
//
// AXI-Stream gives us SOF for free: the first cycle where tvalid=1 after a
// tlast (or after reset) is the start of a new frame.
// -----------------------------------------------------------------------------

module eth_loopback_v2_top (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,

    // ENET0 MII RX pins
    input  wire        ENET0_RX_CLK,
    input  wire        ENET0_RX_DV,
    input  wire [3:0]  ENET0_RX_DATA,
    input  wire        ENET0_RX_ER,

    // ENET0 MII TX pins (required by eth_mac_mii_fifo even if we don't TX)
    input  wire        ENET0_TX_CLK,
    output wire        ENET0_TX_EN,
    output wire [3:0]  ENET0_TXD,

    // ENET0 management/control
    output wire        ENET0_RST_N,
    output wire        ENET0_MDC,
    inout  wire        ENET0_MDIO,

    // User I/O
    output wire [17:0] LEDR,
    output wire [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5
);

    // ── Reset synchronizer ────────────────────────────────────────────────
    // KEY[0] is active-low push button. Sync the async reset to clk.
    wire clk = CLOCK_50;
    reg [2:0] rst_sync;
    always @(posedge clk) rst_sync <= {rst_sync[1:0], ~KEY[0]};
    wire rst = rst_sync[2];

    // ── PHY out of reset, MDIO idle ───────────────────────────────────────
    // The PHY needs to be released from reset. We're not configuring it via
    // MDIO for this test (relying on power-on defaults for 100Mbit auto-neg).
    assign ENET0_RST_N = ~rst;     // released after our reset deasserts
    assign ENET0_MDC   = 1'b0;
    assign ENET0_MDIO  = 1'bz;

    // ── Heartbeat ─────────────────────────────────────────────────────────
    reg [24:0] hb_cnt;
    reg        heartbeat;
    always @(posedge clk) begin
        if (rst) begin
            hb_cnt <= 0;
            heartbeat <= 0;
        end else if (hb_cnt == 25_000_000 - 1) begin
            hb_cnt <= 0;
            heartbeat <= ~heartbeat;
        end else begin
            hb_cnt <= hb_cnt + 1;
        end
    end

    // ── MAC instantiation ─────────────────────────────────────────────────
    // alexforencich's eth_mac_mii_fifo: AXI-Stream output, async FIFO inside.
    wire        rx_clk_int;        // derived rx clock for FIFO domain
    wire        tx_clk_int;        // derived tx clock for FIFO domain

    wire [7:0]  rx_axis_tdata;
    wire        rx_axis_tvalid;
    wire        rx_axis_tready;
    wire        rx_axis_tlast;
    wire        rx_axis_tuser;     // bad-frame flag (asserted with tlast)

    // TX side - tied off, not used in this test
    wire [7:0]  tx_axis_tdata  = 8'h00;
    wire        tx_axis_tvalid = 1'b0;
    wire        tx_axis_tready;     // ignored
    wire        tx_axis_tlast  = 1'b0;
    wire        tx_axis_tuser  = 1'b0;

    // Status outputs from MAC
    wire        rx_error_bad_frame;
    wire        rx_error_bad_fcs;
    wire        rx_fifo_overflow;
    wire        rx_fifo_bad_frame;
    wire        rx_fifo_good_frame;
    wire        tx_error_underflow;
    wire        tx_fifo_overflow;
    wire        tx_fifo_bad_frame;
    wire        tx_fifo_good_frame;

    // We're always ready to accept data — wire to 1
    assign rx_axis_tready = 1'b1;

    eth_mac_mii_fifo #(
        .TARGET("ALTERA"),                  // synthesize for Altera/Intel
        .CLOCK_INPUT_STYLE("GLOBAL"),         // input clock buffer style, CHANGES FROM "BUFR" TO GLOBAL
        .AXIS_DATA_WIDTH(8),
        .ENABLE_PADDING(1),
        .MIN_FRAME_LENGTH(64),
        .TX_FIFO_DEPTH(4096),
        .RX_FIFO_DEPTH(4096),
        .TX_FRAME_FIFO(1),
        .RX_FRAME_FIFO(1),
        .TX_DROP_BAD_FRAME(1),
        .RX_DROP_BAD_FRAME(1),
        .RX_DROP_WHEN_FULL(1)
    ) u_mac (
        .rst(rst),
        .logic_clk(clk),
        .logic_rst(rst),

        // RX/TX paths
        .tx_axis_tdata(tx_axis_tdata),
        .tx_axis_tvalid(tx_axis_tvalid),
        .tx_axis_tready(tx_axis_tready),
        .tx_axis_tlast(tx_axis_tlast),
        .tx_axis_tuser(tx_axis_tuser),

        .rx_axis_tdata(rx_axis_tdata),
        .rx_axis_tvalid(rx_axis_tvalid),
        .rx_axis_tready(rx_axis_tready),
        .rx_axis_tlast(rx_axis_tlast),
        .rx_axis_tuser(rx_axis_tuser),

        // MII PHY interface
        .mii_rx_clk(ENET0_RX_CLK),
        .mii_rxd(ENET0_RX_DATA),
        .mii_rx_dv(ENET0_RX_DV),
        .mii_rx_er(ENET0_RX_ER),
        .mii_tx_clk(ENET0_TX_CLK),
        .mii_txd(ENET0_TX_DATA),
        .mii_tx_en(ENET0_TX_EN),
        .mii_tx_er(),                       // not used

        // Status outputs (we just LED them)
        .tx_error_underflow(tx_error_underflow),
        .tx_fifo_overflow(tx_fifo_overflow),
        .tx_fifo_bad_frame(tx_fifo_bad_frame),
        .tx_fifo_good_frame(tx_fifo_good_frame),
        .rx_error_bad_frame(rx_error_bad_frame),
        .rx_error_bad_fcs(rx_error_bad_fcs),
        .rx_fifo_overflow(rx_fifo_overflow),
        .rx_fifo_bad_frame(rx_fifo_bad_frame),
        .rx_fifo_good_frame(rx_fifo_good_frame),

        // Speed control: 0 = 100 Mbit MII mode (DE2-115 default)
        .cfg_ifg(8'd12),                    // inter-frame gap, default
        .cfg_tx_enable(1'b1),
        .cfg_rx_enable(1'b1)
    );

    // ── Byte-14 sniffer (same idea as previous test) ──────────────────────
    // AXI-Stream gives us a clean byte stream with tvalid/tlast.
    // We count bytes from the start of each frame. Byte 14 is the first
    // payload byte after the 14-byte Ethernet header.
    reg [7:0] bcnt;
    reg [7:0] test_byte;
    reg [7:0] frame_count;
    reg [7:0] bad_frame_count;

    always @(posedge clk) begin
        if (rst) begin
            bcnt            <= 0;
            test_byte       <= 8'hFF;
            frame_count     <= 0;
            bad_frame_count <= 0;
        end else if (rx_axis_tvalid && rx_axis_tready) begin
            // Capture byte 14 (the first payload byte)
            if (bcnt == 8'd14) test_byte <= rx_axis_tdata;

            if (rx_axis_tlast) begin
                // End of frame. tuser=1 means bad frame (FCS failed).
                if (rx_axis_tuser) bad_frame_count <= bad_frame_count + 1;
                else               frame_count     <= frame_count + 1;
                bcnt <= 0;
            end else begin
                bcnt <= bcnt + 1;
            end
        end
    end

    // ── Display ───────────────────────────────────────────────────────────
    hex_dec h0 (.val(test_byte[3:0]),       .seg(HEX0));   // low nibble
    hex_dec h1 (.val(test_byte[7:4]),       .seg(HEX1));   // high nibble
    hex_dec h2 (.val(frame_count[3:0]),     .seg(HEX2));   // good frame count
    hex_dec h3 (.val(frame_count[7:4]),     .seg(HEX3));
    hex_dec h4 (.val(bad_frame_count[3:0]), .seg(HEX4));   // bad frame count
    hex_dec h5 (.val(bad_frame_count[7:4]), .seg(HEX5));

    // ── LED indicators ────────────────────────────────────────────────────
    assign LEDR[17] = heartbeat;             // 1 Hz blink = FPGA alive
    assign LEDR[16] = ENET0_RX_DV;           // direct PHY RX-active signal
    assign LEDR[15] = rx_axis_tvalid;        // MAC has data for us
    assign LEDR[14] = rx_fifo_good_frame;    // pulses on every good frame
    assign LEDR[13] = rx_fifo_bad_frame;     // pulses on each rejected frame
    assign LEDR[12] = rx_fifo_overflow;      // RX FIFO overflow (shouldn't happen)
    assign LEDR[11] = rx_error_bad_frame;
    assign LEDR[10] = rx_error_bad_fcs;
    assign LEDR[9:0] = 10'd0;
endmodule

// ─────────────────────────────────────────────────────────────────────────
// Simple hex-to-7-segment decoder (active-low segments, DE2-115 convention)
// ─────────────────────────────────────────────────────────────────────────
module hex_dec (
    input  wire [3:0] val,
    output reg  [6:0] seg
);
    always @(*) begin
        case (val)
            4'h0: seg = 7'b1000000; 4'h1: seg = 7'b1111001;
            4'h2: seg = 7'b0100100; 4'h3: seg = 7'b0110000;
            4'h4: seg = 7'b0011001; 4'h5: seg = 7'b0010010;
            4'h6: seg = 7'b0000010; 4'h7: seg = 7'b1111000;
            4'h8: seg = 7'b0000000; 4'h9: seg = 7'b0010000;
            4'hA: seg = 7'b0001000; 4'hB: seg = 7'b0000011;
            4'hC: seg = 7'b1000110; 4'hD: seg = 7'b0100001;
            4'hE: seg = 7'b0000110; 4'hF: seg = 7'b0001110;
            default: seg = 7'b1111111;
        endcase
    end
endmodule
