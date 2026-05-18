// rolling_window_stats.v
// Circular-buffer rolling window.  Tracks a WINDOW_SIZE (power-of-2) history
// of signed samples and emits mean, velocity (1-step delta), and deviation.
//
// WINDOW_SIZE must be a power of two so division is a free right-shift.
// Inputs: data_in carries the per-update delta_index from index_engine_core.

module rolling_window_stats #(
    parameter DATA_WIDTH  = 64,
    parameter WINDOW_SIZE = 16,
    parameter LOG2_WIN    = 4    // log2(WINDOW_SIZE)
)(
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         valid_in,
    input  wire signed [DATA_WIDTH-1:0] data_in,

    output reg  signed [DATA_WIDTH-1:0] mean_out,
    output reg  signed [DATA_WIDTH-1:0] velocity_out,
    output reg  signed [DATA_WIDTH-1:0] deviation_out,
    output reg                          valid_out
);
    // Circular buffer
    reg signed [DATA_WIDTH-1:0]          buf_mem [0:WINDOW_SIZE-1];
    reg        [LOG2_WIN-1:0]            wr_ptr;

    // Running sum: DATA_WIDTH + LOG2_WIN bits to avoid overflow.
    reg signed [DATA_WIDTH+LOG2_WIN-1:0] running_sum;

    // Previous sample for velocity
    reg signed [DATA_WIDTH-1:0]          prev_sample;

    integer k;

    // ── Combinational intermediates ──────────────────────────────────────────
    // Evicted entry (oldest) is at wr_ptr (before it is overwritten)
    wire signed [DATA_WIDTH-1:0]          evicted    = buf_mem[wr_ptr];
    wire signed [DATA_WIDTH+LOG2_WIN-1:0] new_sum    = running_sum
                                                       + {{LOG2_WIN{data_in[DATA_WIDTH-1]}}, data_in}
                                                       - {{LOG2_WIN{evicted[DATA_WIDTH-1]}}, evicted};
    // Mean = new_sum >> LOG2_WIN (arithmetic right-shift, power-of-two divide)
    wire signed [DATA_WIDTH-1:0]          new_mean   = $signed(new_sum[DATA_WIDTH+LOG2_WIN-1:LOG2_WIN]);

    // Velocity = current sample minus previous
    wire signed [DATA_WIDTH-1:0]          new_vel    = data_in - prev_sample;

    // Deviation = |current - mean|
    wire signed [DATA_WIDTH-1:0]          raw_diff   = data_in - new_mean;
    wire signed [DATA_WIDTH-1:0]          new_dev    = raw_diff[DATA_WIDTH-1] ? (-raw_diff) : raw_diff;

    // ── Registered pipeline ──────────────────────────────────────────────────
    always @(posedge clk) begin
        if (rst) begin
            wr_ptr      <= {LOG2_WIN{1'b0}};
            running_sum <= {(DATA_WIDTH+LOG2_WIN){1'b0}};
            prev_sample <= {DATA_WIDTH{1'b0}};
            mean_out    <= {DATA_WIDTH{1'b0}};
            velocity_out  <= {DATA_WIDTH{1'b0}};
            deviation_out <= {DATA_WIDTH{1'b0}};
            valid_out   <= 1'b0;
            for (k = 0; k < WINDOW_SIZE; k = k + 1)
                buf_mem[k] <= {DATA_WIDTH{1'b0}};
        end else begin
            valid_out <= 1'b0;
            if (valid_in) begin
                buf_mem[wr_ptr] <= data_in;
                wr_ptr          <= wr_ptr + 1'b1;
                running_sum     <= new_sum;
                prev_sample     <= data_in;
                mean_out        <= new_mean;
                velocity_out    <= new_vel;
                deviation_out   <= new_dev;
                valid_out       <= 1'b1;
            end
        end
    end
endmodule