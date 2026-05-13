/* this fifo will be a queue for incoming UART streamed data 
    after it gets decoded
    storage element used: BRAM
    Components:
            - read/write pointers
            - mem arrray
            - counter (full/empty)
    */

module burst_fifo #(
    parameter DATA_WIDTH = 80,
    parameter DEPTH = 256,
    parameter ADDR_WIDTH = $clog2(DEPTH)
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] din,
    input  wire                  rd_en,
    output reg  [DATA_WIDTH-1:0] dout,
    output wire                  full,
    output wire                  empty,
    output reg  [ADDR_WIDTH:0]   count
);

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] wr_ptr;
    reg [ADDR_WIDTH-1:0] rd_ptr;

    wire do_write = wr_en && !full;
    wire do_read  = rd_en && !empty;

    assign empty = (count == 0);
    assign full  = (count == DEPTH);

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= {ADDR_WIDTH{1'b0}};
            rd_ptr <= {ADDR_WIDTH{1'b0}};
            count  <= {(ADDR_WIDTH+1){1'b0}};
            dout   <= {DATA_WIDTH{1'b0}};
        end else begin
            if (do_write) begin
                mem[wr_ptr] <= din;
                if (wr_ptr == DEPTH-1)
                    wr_ptr <= {ADDR_WIDTH{1'b0}};
                else
                    wr_ptr <= wr_ptr + 1'b1;
            end

            if (do_read) begin
                dout <= mem[rd_ptr];
                if (rd_ptr == DEPTH-1)
                    rd_ptr <= {ADDR_WIDTH{1'b0}};
                else
                    rd_ptr <= rd_ptr + 1'b1;
            end

            case ({do_write, do_read})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule