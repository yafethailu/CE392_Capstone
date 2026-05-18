// burst_fifo.v
// Synchronous FIFO, BRAM-inferred.  Used to absorb upstream UART microbursts.
// DATA_WIDTH = 48, DEPTH = 256 for the capstone pipeline.

module burst_fifo #(
    parameter DATA_WIDTH = 48,
    parameter DEPTH      = 256,
    parameter ADDR_WIDTH = $clog2(DEPTH)   // 8 for depth 256
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] din,
    input  wire                  rd_en,
    output reg  [DATA_WIDTH-1:0] dout,
    output wire                  full,
    output wire                  empty,
    output reg  [ADDR_WIDTH:0]   count      // 0 .. DEPTH  (9 bits for depth 256)
);
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] wr_ptr;
    reg [ADDR_WIDTH-1:0] rd_ptr;

    assign full  = (count == DEPTH[ADDR_WIDTH:0]);
    assign empty = (count == {(ADDR_WIDTH+1){1'b0}});

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= {ADDR_WIDTH{1'b0}};
            rd_ptr <= {ADDR_WIDTH{1'b0}};
            count  <= {(ADDR_WIDTH+1){1'b0}};
            dout   <= {DATA_WIDTH{1'b0}};
        end else begin
            if (do_wr) begin
                mem[wr_ptr] <= din;
                wr_ptr      <= wr_ptr + 1'b1;
            end
            if (do_rd) begin
                dout   <= mem[rd_ptr];
                rd_ptr <= rd_ptr + 1'b1;
            end
            case ({do_wr, do_rd})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule