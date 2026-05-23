// eth_loopback_test.v
// Minimal Ethernet loopback test for the Terasic DE2-115.
//
// WHAT IT DOES:
//   Receives raw Ethernet frames via eth_mac_bridge, captures
//   the first payload byte (byte 14 of the Ethernet frame, 0-indexed),
//   and displays it on HEX1:HEX0. Counts frames on HEX3:HEX2.
//
// BYTE POSITION NOTES:
//   After preamble/SFD stripping, the bridge outputs bytes in order:
//     bytes 0-5  : destination MAC
//     bytes 6-11 : source MAC
//     bytes 12-13: EtherType
//     byte  14   : first payload byte  ← displayed on HEX1:HEX0
//
//   In the bridge's bcnt scheme (starts at 1 after SOF), this falls at
//   bcnt == 15 because the SFD consumes the bcnt==0 slot internally.
//
// DISPLAY (KEY buttons active-low on DE2-115):
//   HEX5:HEX4  = "--"  (dashes, confirms design is loaded correctly)
//   HEX3:HEX2  = frame count (hex)
//   HEX1:HEX0  = payload byte at position 14 (default, KEY all released)
//              = payload byte at position 13 (KEY[1] held, for debug)
//              = payload byte at position 15 (KEY[2] held, for debug)
//
// LEDS:
//   LEDR[17]   = 1Hz heartbeat — FPGA clock alive
//   LEDR[16]   = sticky rx_active: lights for 0.5s after any frame arrives
//                (one frame at 100Mbps lasts ~5us, invisible as a flash)
//   LEDR[15:0] = off
//
// TEST PROCEDURE:
//   1. Flash this design
//   2. Confirm LEDR[17] blinks at 1Hz
//   3. Run: python3 send_test_byte.py --iface <iface> --value 0xAB
//   4. HEX3:HEX2 should increment, HEX1:HEX0 should show AB
//      If HEX shows 34, the offset is still off by 1 — hold KEY[2] to
//      check position 15. If HEX shows 12, hold KEY[1] for position 13.
//      Report what each KEY shows.

module eth_loopback_test (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,            // active-low on DE2-115

    // Ethernet 0 MII receive (Marvell 88E1111, MII mode, 100BASE-T)
    input  wire        ENET0_RX_CLK,   // 25MHz from PHY
    input  wire        ENET0_RX_DV,
    input  wire [3:0]  ENET0_RXD,
    input  wire        ENET0_RX_ER,
    output wire        ENET0_RST_N,    // hold high: PHY out of reset
    output wire        ENET0_MDC,      // management clock: tie low

    output wire [17:0] LEDR,
    output wire [8:0]  LEDG,
    output wire [6:0]  HEX0, HEX1,    // payload byte
    output wire [6:0]  HEX2, HEX3,    // frame count
    output wire [6:0]  HEX4, HEX5     // dashes
);

    wire clk = CLOCK_50;
    wire rst = ~KEY[0];   // KEY[0] active-low → invert to active-high

    assign ENET0_RST_N = 1'b1;
    assign ENET0_MDC   = 1'b0;
    assign LEDG        = 9'd1;   // LEDG[0] solid on as power indicator

    // ── 1Hz heartbeat ───────────────────────────────────────────────────────
    reg [24:0] hb_cnt;
    reg        heartbeat;
    always @(posedge clk or posedge rst) begin
        if (rst) begin hb_cnt <= 0; heartbeat <= 0; end
        else if (hb_cnt == 25_000_000 - 1) begin
            hb_cnt <= 0; heartbeat <= ~heartbeat;
        end else hb_cnt <= hb_cnt + 1;
    end

    // ── MAC bridge ──────────────────────────────────────────────────────────
    wire [7:0] eth_byte;
    wire       eth_valid, eth_sof, eth_eof;

    eth_mac_bridge u_bridge (
        .clk       (clk),
        .rst       (rst),
        .rx_clk    (ENET0_RX_CLK),
        .rx_data   (ENET0_RXD),
        .rx_dv     (ENET0_RX_DV),
        .rx_er     (ENET0_RX_ER),
        .byte_out  (eth_byte),
        .byte_valid(eth_valid),
        .sof       (eth_sof),
        .eof       (eth_eof)
    );

    // ── Sticky rx_active LED ────────────────────────────────────────────────
    // A single 100BASE-T frame lasts ~5us — invisible as a raw LED flash.
    // This counter keeps LEDR[16] lit for 0.5s after any frame EOF.
    reg [24:0] rx_sticky_cnt;
    reg        rx_sticky;
    always @(posedge clk or posedge rst) begin
        if (rst) begin rx_sticky_cnt <= 0; rx_sticky <= 0; end
        else if (eth_eof && eth_valid) begin
            rx_sticky_cnt <= 25_000_000 / 2 - 1;  // 0.5s at 50MHz
            rx_sticky     <= 1;
        end else if (rx_sticky_cnt != 0) begin
            rx_sticky_cnt <= rx_sticky_cnt - 1;
        end else begin
            rx_sticky <= 0;
        end
    end

    // ── Byte counter and three-position capture ─────────────────────────────
    //
    // Frame byte layout (0-indexed from first byte after preamble/SFD):
    //   0-5  : dst MAC
    //   6-11 : src MAC
    //   12-13: EtherType
    //   14   : payload[0]  ← the byte we want
    //
    // Bridge bcnt scheme: SOF fires when SFD is output. We set bcnt=1
    // on SOF, so the first real data byte (dst_MAC[0]) arrives at bcnt=1.
    // Therefore payload[0] is at bcnt=15 (not 14).
    //
    // We also capture bcnt=14 and bcnt=16 for debug comparison via KEY.
    //
    reg [7:0] bcnt;
    reg [7:0] byte_at_13;  // EtherType[0]   — KEY[1] shows this
    reg [7:0] byte_at_14;  // EtherType[1]   — should be 0x34 for our test
    reg [7:0] byte_at_15;  // payload[0]     — should be our test value (default)
    reg [7:0] byte_at_16;  // payload[1]     — KEY[2] shows this
    reg [7:0] frame_count;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bcnt         <= 0;
            byte_at_13   <= 8'hFF;
            byte_at_14   <= 8'hFF;
            byte_at_15   <= 8'hFF;
            byte_at_16   <= 8'hFF;
            frame_count  <= 0;
        end else if (eth_valid) begin
            if (eth_sof) begin
                bcnt <= 1;
            end else begin
                // Capture bytes at positions of interest
                case (bcnt)
                    8'd13: byte_at_13 <= eth_byte;
                    8'd14: byte_at_14 <= eth_byte;
                    8'd15: byte_at_15 <= eth_byte;
                    8'd16: byte_at_16 <= eth_byte;
                endcase
                if (eth_eof) begin
                    frame_count <= frame_count + 1;
                    bcnt        <= 0;
                end else begin
                    bcnt <= bcnt + 1;
                end
            end
        end
    end

    // ── Display mux via KEY buttons ─────────────────────────────────────────
    // Default (all keys released): show byte_at_15 (payload[0])
    // KEY[1] held: show byte_at_13 (EtherType[0], expect 0x12 for our test)
    // KEY[2] held: show byte_at_16 (payload[1], expect 0x00 padding)
    // KEY[1]+KEY[2] held: show byte_at_14 (EtherType[1], expect 0x34)
    reg [7:0] disp_byte;
    always @(*) begin
        if      (!KEY[2] && !KEY[1]) disp_byte = byte_at_14;  // both held
        else if (!KEY[1])            disp_byte = byte_at_13;  // KEY[1] only
        else if (!KEY[2])            disp_byte = byte_at_16;  // KEY[2] only
        else                         disp_byte = byte_at_15;  // default
    end

    // ── Seven-segment display ───────────────────────────────────────────────
    hex_dec h0 (.val(disp_byte[3:0]),   .seg(HEX0));
    hex_dec h1 (.val(disp_byte[7:4]),   .seg(HEX1));
    hex_dec h2 (.val(frame_count[3:0]), .seg(HEX2));
    hex_dec h3 (.val(frame_count[7:4]), .seg(HEX3));
    assign HEX4 = 7'b0111111;  // dash
    assign HEX5 = 7'b0111111;  // dash

    // ── LED assignments ─────────────────────────────────────────────────────
    assign LEDR[17]   = heartbeat;
    assign LEDR[16]   = rx_sticky;
    assign LEDR[15:0] = 16'd0;

endmodule

// ── 4-bit → 7-segment decoder (active-low, DE2-115 standard) ────────────────
module hex_dec (
    input  wire [3:0] val,
    output reg  [6:0] seg
);
    always @(*) begin
        case (val)
            4'h0: seg = 7'b1000000;
            4'h1: seg = 7'b1111001;
            4'h2: seg = 7'b0100100;
            4'h3: seg = 7'b0110000;
            4'h4: seg = 7'b0011001;
            4'h5: seg = 7'b0010010;
            4'h6: seg = 7'b0000010;
            4'h7: seg = 7'b1111000;
            4'h8: seg = 7'b0000000;
            4'h9: seg = 7'b0010000;
            4'hA: seg = 7'b0001000;
            4'hB: seg = 7'b0000011;
            4'hC: seg = 7'b1000110;
            4'hD: seg = 7'b0100001;
            4'hE: seg = 7'b0000110;
            4'hF: seg = 7'b0001110;
            default: seg = 7'b1111111;
        endcase
    end
endmodule
