// index_engine_core.v
// -----------------------------------------------------------------------------
// Incremental weighted-index update.
//
//   new_mid     = (bid + ask) / 2
//   delta_mid   = new_mid - prev_mid                (signed)
//   delta_index = (delta_mid * weight) >>> SCALE_SHIFT
//   index_value = index_value + delta_index
//
// SCALE_SHIFT must equal log2(sum of weights). With weights summing to
// 2^14 = 16384, SCALE_SHIFT = 14. Divide-by-scale becomes a free shift on
// the FPGA, which is critical for meeting timing at 50 MHz on Cyclone IV.
// -----------------------------------------------------------------------------

module index_engine_core #(
    parameter PRICE_WIDTH  = 20,
    parameter WEIGHT_WIDTH = 16,
    parameter INDEX_WIDTH  = 64,
    parameter SCALE_SHIFT  = 14
)(
    input  wire                          clk,
    input  wire                          rst,
    input  wire                          valid_in,
    input  wire [PRICE_WIDTH-1:0]        bid,
    input  wire [PRICE_WIDTH-1:0]        ask,
    input  wire [PRICE_WIDTH-1:0]        prev_mid,
    input  wire [WEIGHT_WIDTH-1:0]       weight,
    output reg  [PRICE_WIDTH-1:0]        new_mid,
    output reg  signed [INDEX_WIDTH-1:0] delta_index,
    output reg  signed [INDEX_WIDTH-1:0] index_value,
    output reg                           valid_out
);
    wire [PRICE_WIDTH-1:0] mid_wire;
    midprice_compute #(.PRICE_WIDTH(PRICE_WIDTH)) u_mid (
        .bid(bid),
        .ask(ask),
        .mid(mid_wire)
    );

    wire signed [PRICE_WIDTH:0] delta_mid_w;
    assign delta_mid_w = $signed({1'b0, mid_wire}) - $signed({1'b0, prev_mid});

    wire signed [WEIGHT_WIDTH:0]                weight_s = $signed({1'b0, weight});
    wire signed [PRICE_WIDTH+WEIGHT_WIDTH+1:0]  weighted_delta_w = delta_mid_w * weight_s;
    wire signed [PRICE_WIDTH+WEIGHT_WIDTH+1:0]  scaled_delta_w = weighted_delta_w >>> SCALE_SHIFT;

    // Sign-extend the 38-bit shifted product to INDEX_WIDTH (64) before
    // assignment. Without this, scaled_delta_w[63:0] reads out-of-range
    // bits as x in simulation.
    wire signed [INDEX_WIDTH-1:0] scaled_delta_ext = scaled_delta_w;

    always @(posedge clk) begin
        if (rst) begin
            new_mid     <= {PRICE_WIDTH{1'b0}};
            delta_index <= {INDEX_WIDTH{1'b0}};
            index_value <= {INDEX_WIDTH{1'b0}};
            valid_out   <= 1'b0;
        end else begin
            valid_out <= 1'b0;
            if (valid_in) begin
                new_mid     <= mid_wire;
                delta_index <= scaled_delta_ext;
                index_value <= index_value + scaled_delta_ext;
                valid_out   <= 1'b1;
            end
        end
    end
endmodule