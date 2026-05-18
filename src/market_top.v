// market.v (includes m1_top.v)
// Full integration: UART RX -> assemble -> burst FIFO -> unpack ->
//   symbol state RAM -> index engine -> rolling stats -> threshold -> alert
//
// Pipeline controller FSM drives one record at a time through the datapath,
// safely avoiding RAW hazards on symbol_state_mem between back-to-back
// updates for the same symbol.
//
// At 115 200 baud, one 7-byte frame takes ~608 us; the datapath processes a
// record in ~8 cycles (160 ns at 50 MHz), so there is zero back-pressure.

module market_top #(
    parameter CLK_FREQ_HZ  = 50_000_000,
    parameter BAUD_RATE    = 115_200,
    parameter PRICE_WIDTH  = 20,         // Q11.9 fixed-point, matches wire format
    parameter WEIGHT_WIDTH = 16,
    parameter INDEX_WIDTH  = 64,
    parameter SCALE_SHIFT  = 14,         // log2(sum of weights) = log2(16384)
    parameter WIN_SIZE     = 16,
    parameter LOG2_WIN     = 4
)(
    input  wire clk,
    input  wire rst,
    input  wire uart_rx_i,

    // Anomaly outputs
    output wire alert_velocity_o,
    output wire alert_deviation_o,
    output wire alert_any_o,

    // Display outputs
    output wire [17:0] ledr_o,
    output wire [6:0]  hex0_o, hex1_o, hex2_o, hex3_o, hex4_o, hex5_o,

    // Debug / observability taps
    output wire [47:0] fifo_dout_o,
    output wire        fifo_empty_o,
    output wire [8:0]  fifo_count_o,
    output wire [15:0] rec_count_o,
    output wire signed [INDEX_WIDTH-1:0] index_value_o
);

    // ── FIFO interface ────────────────────────────────────────────────────────
    wire       fifo_full;
    reg        fifo_rd_en;

    // ── Unpacker outputs (combinational, on fifo_dout_o) ─────────────────────
    wire [3:0]  sym_id_raw;
    wire [19:0] bid_q9_raw;
    wire [19:0] ask_q9_raw;

    // ── Pipeline stage registers ──────────────────────────────────────────────
    reg [3:0]             sym_id_reg;
    reg [PRICE_WIDTH-1:0] bid_reg, ask_reg;

    // ── Symbol state memory drive signals ────────────────────────────────────
    reg [3:0]             sm_rd_addr;
    reg [3:0]             sm_wr_addr;
    reg                   sm_wr_en;
    reg [PRICE_WIDTH-1:0] sm_bid_in, sm_ask_in, sm_mid_in;
    wire [PRICE_WIDTH-1:0] sm_bid_out, sm_ask_out, sm_mid_out;

    // ── Weights ROM drive ─────────────────────────────────────────────────────
    reg  [15:0] weight_addr_reg;
    wire [15:0] weight_out;

    // ── Index engine ──────────────────────────────────────────────────────────
    reg                          engine_valid_in;
    wire [PRICE_WIDTH-1:0]       engine_new_mid;
    wire signed [INDEX_WIDTH-1:0] engine_delta_index;
    wire signed [INDEX_WIDTH-1:0] engine_index_value;
    wire                         engine_valid_out;

    assign index_value_o = engine_index_value;

    // ── Rolling window stats ──────────────────────────────────────────────────
    reg                          stats_valid_in;
    reg  signed [INDEX_WIDTH-1:0] stats_data_in;
    wire signed [INDEX_WIDTH-1:0] stats_mean;
    wire signed [INDEX_WIDTH-1:0] stats_velocity;
    wire signed [INDEX_WIDTH-1:0] stats_deviation;
    wire                         stats_valid_out;

    // Fixed anomaly thresholds (tunable via parameter or future register map)
    localparam [INDEX_WIDTH-1:0] THRESH_V = 64'd500;
    localparam [INDEX_WIDTH-1:0] THRESH_D = 64'd1000;

    // ── Debug wires from m1_top ───────────────────────────────────────────────
    wire [15:0] m1_rec_count;
    wire [7:0]  m1_last_byte;
    wire [1:0]  m1_asm_state;
    wire [3:0]  m1_asm_byte_count;
    wire        m1_rx_byte_strobe;
    wire [15:0] m1_sync_lost_count;

    assign rec_count_o = m1_rec_count;

    // ────────────────────────────────────────────────────────────────────────
    // Submodule instantiations
    // ────────────────────────────────────────────────────────────────────────

    m1_top #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (BAUD_RATE)
    ) u_m1 (
        .clk               (clk),
        .rst               (rst),
        .uart_rx_i         (uart_rx_i),
        .fifo_rd_en_i      (fifo_rd_en),
        .fifo_empty_o      (fifo_empty_o),
        .fifo_full_o       (fifo_full),
        .fifo_count_o      (fifo_count_o),
        .fifo_dout_o       (fifo_dout_o),
        .last_byte_o       (m1_last_byte),
        .asm_state_o       (m1_asm_state),
        .asm_byte_count_o  (m1_asm_byte_count),
        .rx_byte_strobe_o  (m1_rx_byte_strobe),
        .rec_count_o       (m1_rec_count),
        .sync_lost_count_o (m1_sync_lost_count)
    );

    quote_record_unpacker u_unpack (
        .record_in (fifo_dout_o),
        .symbol_id (sym_id_raw),
        .bid_q9    (bid_q9_raw),
        .ask_q9    (ask_q9_raw)
    );

    symbol_state_mem #(
        .SYMBOL_COUNT(10),
        .PRICE_WIDTH (PRICE_WIDTH),
        .ADDR_WIDTH  (4)
    ) u_sym_state (
        .clk     (clk),
        .rst     (rst),
        .wr_en   (sm_wr_en),
        .wr_addr (sm_wr_addr),
        .bid_in  (sm_bid_in),
        .ask_in  (sm_ask_in),
        .mid_in  (sm_mid_in),
        .rd_addr (sm_rd_addr),
        .bid_out (sm_bid_out),
        .ask_out (sm_ask_out),
        .mid_out (sm_mid_out)
    );

    weights_rom u_weights (
        .symbol_id (weight_addr_reg),
        .weight    (weight_out)
    );

    index_engine_core #(
        .PRICE_WIDTH (PRICE_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .INDEX_WIDTH (INDEX_WIDTH),
        .SCALE_SHIFT (SCALE_SHIFT)
    ) u_engine (
        .clk        (clk),
        .rst        (rst),
        .valid_in   (engine_valid_in),
        .bid        (bid_reg),
        .ask        (ask_reg),
        .prev_mid   (sm_mid_out),
        .weight     (weight_out),
        .new_mid    (engine_new_mid),
        .delta_index(engine_delta_index),
        .index_value(engine_index_value),
        .valid_out  (engine_valid_out)
    );

    rolling_window_stats #(
        .DATA_WIDTH (INDEX_WIDTH),
        .WINDOW_SIZE(WIN_SIZE),
        .LOG2_WIN   (LOG2_WIN)
    ) u_stats (
        .clk          (clk),
        .rst          (rst),
        .valid_in     (stats_valid_in),
        .data_in      (stats_data_in),
        .mean_out     (stats_mean),
        .velocity_out (stats_velocity),
        .deviation_out(stats_deviation),
        .valid_out    (stats_valid_out)
    );

    threshold_comparator #(
        .DATA_WIDTH(INDEX_WIDTH)
    ) u_thresh (
        .clk           (clk),
        .rst           (rst),
        .valid_in      (stats_valid_out),
        .velocity_in   (stats_velocity),
        .deviation_in  (stats_deviation),
        .threshold_v   (THRESH_V),
        .threshold_d   (THRESH_D),
        .alert_velocity (alert_velocity_o),
        .alert_deviation(alert_deviation_o),
        .alert_any     (alert_any_o)
    );

    alert_visualization #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .INDEX_WIDTH(INDEX_WIDTH)
    ) u_viz (
        .clk           (clk),
        .rst           (rst),
        .alert_velocity (alert_velocity_o),
        .alert_deviation(alert_deviation_o),
        .alert_any     (alert_any_o),
        .index_value   (engine_index_value),
        .ledr_o        (ledr_o),
        .hex0_o        (hex0_o),
        .hex1_o        (hex1_o),
        .hex2_o        (hex2_o),
        .hex3_o        (hex3_o),
        .hex4_o        (hex4_o),
        .hex5_o        (hex5_o)
    );

    // ────────────────────────────────────────────────────────────────────────
    // Pipeline controller FSM
    //
    // Timing summary (one record = 8 cycles):
    //   S_IDLE      : wait for !fifo_empty; assert fifo_rd_en combinationally
    //   S_FIFO_RD   : FIFO dout valid this cycle; unpack; set sm_rd_addr
    //   S_MEM_WAIT  : symbol_state_mem registered output latches prev_mid
    //   S_COMPUTE   : assert engine_valid_in
    //   S_RESULT    : engine_valid_out; capture new_mid; write to sym state
    //   S_STATS     : assert stats_valid_in with delta_index
    //   S_STATS_WAIT: stats valid_out propagates to threshold_comparator
    //   back to S_IDLE
    // ────────────────────────────────────────────────────────────────────────
    localparam S_IDLE      = 3'd0;
    localparam S_FIFO_RD   = 3'd1;
    localparam S_MEM_WAIT  = 3'd2;
    localparam S_COMPUTE   = 3'd3;
    localparam S_RESULT    = 3'd4;
    localparam S_STATS     = 3'd5;
    localparam S_STATS_WAIT= 3'd6;

    reg [2:0] state;

    // Combinational FIFO read enable: assert during S_IDLE when FIFO has data.
    // The FIFO latches rd_en and presents dout on the NEXT clock edge (S_FIFO_RD).
    always @(*) begin
        fifo_rd_en = (state == S_IDLE) && !fifo_empty_o;
    end

    // Registered pipeline controller
    always @(posedge clk) begin
        if (rst) begin
            state           <= S_IDLE;
            sym_id_reg      <= 4'd0;
            bid_reg         <= {PRICE_WIDTH{1'b0}};
            ask_reg         <= {PRICE_WIDTH{1'b0}};
            sm_rd_addr      <= 4'd0;
            sm_wr_addr      <= 4'd0;
            sm_wr_en        <= 1'b0;
            sm_bid_in       <= {PRICE_WIDTH{1'b0}};
            sm_ask_in       <= {PRICE_WIDTH{1'b0}};
            sm_mid_in       <= {PRICE_WIDTH{1'b0}};
            weight_addr_reg <= 16'd0;
            engine_valid_in <= 1'b0;
            stats_valid_in  <= 1'b0;
            stats_data_in   <= {INDEX_WIDTH{1'b0}};
        end else begin
            // Default single-cycle pulses
            sm_wr_en        <= 1'b0;
            engine_valid_in <= 1'b0;
            stats_valid_in  <= 1'b0;

            case (state)
                // ── Wait for FIFO data ──────────────────────────────────────
                S_IDLE: begin
                    if (!fifo_empty_o)
                        state <= S_FIFO_RD;
                end

                // ── FIFO dout is valid; unpack it ───────────────────────────
                S_FIFO_RD: begin
                    // sym_id_raw, bid_q9_raw, ask_q9_raw are combinational from fifo_dout_o
                    sym_id_reg  <= sym_id_raw;
                    // bid_q9_raw and ask_q9_raw are already 20 bits, matching PRICE_WIDTH.
                    bid_reg     <= bid_q9_raw;
                    ask_reg     <= ask_q9_raw;

                    // Set symbol_state_mem read address (0-based: wire ID 1..10 -> addr 0..9)
                    sm_rd_addr  <= (sym_id_raw > 4'd0) ? (sym_id_raw - 4'd1) : 4'd0;

                    // Set weights ROM address (combinational ROM, so addr latched here)
                    weight_addr_reg <= {12'd0, (sym_id_raw > 4'd0) ? (sym_id_raw - 4'd1) : 4'd0};

                    state <= S_MEM_WAIT;
                end

                // ── Wait 1 cycle for symbol_state_mem registered output ─────
                S_MEM_WAIT: begin
                    // sm_mid_out, weight_out now valid
                    state <= S_COMPUTE;
                end

                // ── Kick index_engine_core ──────────────────────────────────
                S_COMPUTE: begin
                    engine_valid_in <= 1'b1;
                    state           <= S_RESULT;
                end

                // ── Capture engine outputs; write new state ─────────────────
                S_RESULT: begin
                    if (engine_valid_out) begin
                        sm_wr_addr <= (sym_id_reg > 4'd0) ? (sym_id_reg - 4'd1) : 4'd0;
                        sm_bid_in  <= bid_reg;
                        sm_ask_in  <= ask_reg;
                        sm_mid_in  <= engine_new_mid;
                        sm_wr_en   <= 1'b1;
                        state      <= S_STATS;
                    end
                    // If engine not yet valid (should not happen), wait
                end

                // ── Feed index_value (not delta_index) to rolling stats ─────
                // Per spec: velocity and deviation track the index over time.
                S_STATS: begin
                    stats_data_in  <= engine_index_value;
                    stats_valid_in <= 1'b1;
                    state          <= S_STATS_WAIT;
                end

                // ── stats_valid_out fires -> threshold_comparator samples ───
                S_STATS_WAIT: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule