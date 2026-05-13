module index_engine_core #(
    parameter PRICE_WIDTH  = 32,
    parameter WEIGHT_WIDTH = 16,
    parameter INDEX_WIDTH  = 64,
    parameter SCALE        = 10000
)(
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         valid_in,
    input  wire [PRICE_WIDTH-1:0]       bid,
    input  wire [PRICE_WIDTH-1:0]       ask,
    input  wire [PRICE_WIDTH-1:0]       prev_mid,
    input  wire [WEIGHT_WIDTH-1:0]      weight,
    output reg  [PRICE_WIDTH-1:0]       new_mid,
    output reg  signed [INDEX_WIDTH-1:0] delta_index,
    output reg  signed [INDEX_WIDTH-1:0] index_value,
    output reg                          valid_out
);
    wire [PRICE_WIDTH-1:0] mid_wire;
    wire signed [PRICE_WIDTH:0] delta_mid_wire;
    wire signed [PRICE_WIDTH+WEIGHT_WIDTH:0] weighted_delta_wire;

    midprice_compute #(.PRICE_WIDTH(PRICE_WIDTH)) u_mid (
        .bid(bid),
        .ask(ask),
        .mid(mid_wire)
    );

    assign delta_mid_wire = $signed({1'b0, mid_wire}) - $signed({1'b0, prev_mid});
    assign weighted_delta_wire = delta_mid_wire * $signed({1'b0, weight});

    always @(posedge clk) begin
        if (rst) begin
            new_mid      <= 0;
            delta_index  <= 0;
            index_value  <= 0;
            valid_out    <= 1'b0;
        end else begin
            valid_out <= 1'b0;
            if (valid_in) begin
                new_mid <= mid_wire;
                delta_index <= weighted_delta_wire / SCALE;
                index_value <= index_value + (weighted_delta_wire / SCALE);
                valid_out <= 1'b1;
            end
        end
    end
endmodule
