// alert_visualization.v
// Drives DE2-115 LED bank and 6x7-segment displays.
//
// LEDR[0]  = alert_velocity
// LEDR[1]  = alert_deviation
// LEDR[2]  = alert_any
// LEDR[17] = heartbeat (toggles every ~0.5 s at 50 MHz)
// HEX5..HEX0 = lower 24 bits of index_value as 6 hex digits (active low)

module alert_visualization #(
    parameter CLK_FREQ_HZ = 50_000_000,
    parameter INDEX_WIDTH = 64
)(
    input  wire                          clk,
    input  wire                          rst,
    input  wire                          alert_velocity,
    input  wire                          alert_deviation,
    input  wire                          alert_any,
    input  wire signed [INDEX_WIDTH-1:0] index_value,

    output reg  [17:0] ledr_o,
    output reg  [6:0]  hex0_o,
    output reg  [6:0]  hex1_o,
    output reg  [6:0]  hex2_o,
    output reg  [6:0]  hex3_o,
    output reg  [6:0]  hex4_o,
    output reg  [6:0]  hex5_o
);
    // ── Heartbeat counter ────────────────────────────────────────────────────
    localparam HB_TOP = CLK_FREQ_HZ / 2 - 1;   // 25 000 000 - 1
    reg [24:0] hb_cnt;
    reg        hb_bit;

    always @(posedge clk) begin
        if (rst) begin
            hb_cnt <= 25'd0;
            hb_bit <= 1'b0;
        end else if (hb_cnt == HB_TOP[24:0]) begin
            hb_cnt <= 25'd0;
            hb_bit <= ~hb_bit;
        end else begin
            hb_cnt <= hb_cnt + 25'd1;
        end
    end

    // ── 7-segment decoder (active low, common anode) ─────────────────────────
    function [6:0] seg7;
        input [3:0] nibble;
        case (nibble)
            4'h0: seg7 = 7'b100_0000;
            4'h1: seg7 = 7'b111_1001;
            4'h2: seg7 = 7'b010_0100;
            4'h3: seg7 = 7'b011_0000;
            4'h4: seg7 = 7'b001_1001;
            4'h5: seg7 = 7'b001_0010;
            4'h6: seg7 = 7'b000_0010;
            4'h7: seg7 = 7'b111_1000;
            4'h8: seg7 = 7'b000_0000;
            4'h9: seg7 = 7'b001_0000;
            4'hA: seg7 = 7'b000_1000;
            4'hB: seg7 = 7'b000_0011;
            4'hC: seg7 = 7'b100_0110;
            4'hD: seg7 = 7'b010_0001;
            4'hE: seg7 = 7'b000_0110;
            4'hF: seg7 = 7'b000_1110;
            default: seg7 = 7'b111_1111;
        endcase
    endfunction

    wire [23:0] idx_low = index_value[23:0];

    always @(posedge clk) begin
        if (rst) begin
            ledr_o <= 18'd0;
            hex0_o <= 7'b111_1111;
            hex1_o <= 7'b111_1111;
            hex2_o <= 7'b111_1111;
            hex3_o <= 7'b111_1111;
            hex4_o <= 7'b111_1111;
            hex5_o <= 7'b111_1111;
        end else begin
            ledr_o[0]    <= alert_velocity;
            ledr_o[1]    <= alert_deviation;
            ledr_o[2]    <= alert_any;
            ledr_o[16:3] <= 14'd0;
            ledr_o[17]   <= hb_bit;

            hex0_o <= seg7(idx_low[ 3: 0]);
            hex1_o <= seg7(idx_low[ 7: 4]);
            hex2_o <= seg7(idx_low[11: 8]);
            hex3_o <= seg7(idx_low[15:12]);
            hex4_o <= seg7(idx_low[19:16]);
            hex5_o <= seg7(idx_low[23:20]);
        end
    end
endmodule