module uart_rx #(
    parameter CLK_FREQ_HZ = 50000000,
    parameter BAUD_RATE   = 115200,
    parameter CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,
    output reg [7:0]  data_out,
    output reg        data_valid,
    output reg        busy
);
    localparam IDLE      = 3'd0;
    localparam START_BIT = 3'd1;
    localparam DATA_BITS = 3'd2;
    localparam STOP_BIT  = 3'd3;
    localparam CLEANUP   = 3'd4;

    reg [2:0] state;
    reg [$clog2(CLKS_PER_BIT):0] clk_count;
    reg [2:0] bit_index;
    reg [7:0] rx_shift;

    always @(posedge clk) begin
        if (rst) begin
            state      <= IDLE;
            clk_count  <= 0;
            bit_index  <= 0;
            rx_shift   <= 8'd0;
            data_out   <= 8'd0;
            data_valid <= 1'b0;
            busy       <= 1'b0;
        end else begin
            data_valid <= 1'b0;
            case (state)
                IDLE: begin
                    busy      <= 1'b0;
                    clk_count <= 0;
                    bit_index <= 0;
                    if (rx == 1'b0) begin
                        state <= START_BIT;
                        busy  <= 1'b1;
                    end
                end

                START_BIT: begin
                    if (clk_count == (CLKS_PER_BIT-1)/2) begin
                        if (rx == 1'b0) begin
                            clk_count <= 0;
                            state <= DATA_BITS;
                        end else begin
                            state <= IDLE;
                        end
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                DATA_BITS: begin
                    if (clk_count == CLKS_PER_BIT-1) begin
                        clk_count <= 0;
                        rx_shift[bit_index] <= rx;
                        if (bit_index == 3'd7) begin
                            bit_index <= 0;
                            state <= STOP_BIT;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                        end
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                STOP_BIT: begin
                    if (clk_count == CLKS_PER_BIT-1) begin
                        data_out   <= rx_shift;
                        data_valid <= 1'b1;
                        clk_count  <= 0;
                        state      <= CLEANUP;
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                CLEANUP: begin
                    state <= IDLE;
                    busy  <= 1'b0;
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule