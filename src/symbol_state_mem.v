module symbol_state_mem #(
    parameter SYMBOL_COUNT = 10,
    parameter PRICE_WIDTH = 32,
    parameter ADDR_WIDTH = $clog2(SYMBOL_COUNT)
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  wr_en,
    input  wire [ADDR_WIDTH-1:0] wr_addr,
    input  wire [PRICE_WIDTH-1:0] bid_in,
    input  wire [PRICE_WIDTH-1:0] ask_in,
    input  wire [PRICE_WIDTH-1:0] mid_in,
    input  wire [ADDR_WIDTH-1:0] rd_addr,
    output reg  [PRICE_WIDTH-1:0] bid_out,
    output reg  [PRICE_WIDTH-1:0] ask_out,
    output reg  [PRICE_WIDTH-1:0] mid_out
);
    reg [PRICE_WIDTH-1:0] bid_mem [0:SYMBOL_COUNT-1];
    reg [PRICE_WIDTH-1:0] ask_mem [0:SYMBOL_COUNT-1];
    reg [PRICE_WIDTH-1:0] mid_mem [0:SYMBOL_COUNT-1];
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < SYMBOL_COUNT; i = i + 1) begin
                bid_mem[i] <= 0;
                ask_mem[i] <= 0;
                mid_mem[i] <= 0;
            end
            bid_out <= 0;
            ask_out <= 0;
            mid_out <= 0;
        end else begin
            if (wr_en) begin
                bid_mem[wr_addr] <= bid_in;
                ask_mem[wr_addr] <= ask_in;
                mid_mem[wr_addr] <= mid_in;
            end
            bid_out <= bid_mem[rd_addr];
            ask_out <= ask_mem[rd_addr];
            mid_out <= mid_mem[rd_addr];
        end
    end
endmodule