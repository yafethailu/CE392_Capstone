module midprice_compute #(
    parameter PRICE_WIDTH = 32
)(
    input  wire [PRICE_WIDTH-1:0] bid,
    input  wire [PRICE_WIDTH-1:0] ask,
    output wire [PRICE_WIDTH-1:0] mid
);
    wire [PRICE_WIDTH:0] sum_ext = {1'b0, bid} + {1'b0, ask};
    assign mid = sum_ext[PRICE_WIDTH:1];
endmodule