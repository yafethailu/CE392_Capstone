// market.v   (Ethernet-input version)
// -----------------------------------------------------------------------------
// CHANGED from UART path:
//   - removed uart_rx_i  port
//   - added   ENET0_RX_* / ENET0_RST_N / ENET0_MDC pins
//   - removed BAUD_RATE  parameter (no longer used)
//   - swapped u_m1 from m1_top → m1_eth_top
//   - rerouted debug taps: last_byte_o is now last *Ethernet* byte;
//     m1_asm_state / m1_asm_byte_count / m1_sync_lost_count are gone;
//     new parser diagnostics exposed at module output for board debug.
//
// EVERYTHING ELSE (FSM, index engine, stats, threshold, alert viz)
// IS IDENTICAL TO THE UART VERSION.
// -----------------------------------------------------------------------------

module market_top #(
    parameter CLK_FREQ_HZ  = 50_000_000,
    parameter PRICE_WIDTH  = 20,        // Q11.9
    parameter WEIGHT_WIDTH = 16,
    parameter INDEX_WIDTH  = 64,
    parameter SCALE_SHIFT  = 14,        // log2(sum_of_weights) = log2(16384)
    parameter WIN_SIZE     = 16,
    parameter LOG2_WIN     = 4
)(
    input  wire clk,
    input  wire rst,

    // ───────── Ethernet 0 MII (replaces uart_rx_i) ─────────
    input  wire        ENET0_RX_CLK,
    input  wire        ENET0_RX_DV,
    input  wire [3:0]  ENET0_RXD,
    input  wire        ENET0_RX_ER,
    output wire        ENET0_RST_N,
    output wire        ENET0_MDC,

    // Anomaly outputs
    output wire alert_velocity_o,
    output wire alert_deviation_o,
    output wire alert_any_o,

    // Display outputs
    output wire [17:0] ledr_o,
    output wire [6:0]  hex0_o, hex1_o, hex2_o, hex3_o, hex4_o, hex5_o,

    // Debug / observability
    output wire [47:0] fifo_dout_o,
    output wire        fifo_empty_o,
    output wire [8:0]  fifo_count_o,
    output wire [15:0] rec_count_o,
    output wire signed [INDEX_WIDTH-1:0] index_value_o,
    // ── New: parser-level diagnostics for board bring-up ──
    output wire [15:0] xdp_pkts_parsed_o,
    output wire [15:0] add_orders_found_o,
    output wire [15:0] all_add_orders_o,
    output wire [15:0] quotes_emitted_o,
    output wire [15:0] records_passed_o,
    output wire [15:0] records_dropped_o
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

    // Fixed anomaly thresholds
    localparam [INDEX_WIDTH-1:0] THRESH_V = 64'd500;
    localparam [INDEX_WIDTH-1:0] THRESH_D = 64'd1000;

    // ── Debug wires from m1_eth_top ───────────────────────────────────────────
    wire [15:0] m1_rec_count;
    wire [7:0]  m1_last_byte;            // tied to LEDR via alert_viz still? -- no, just exposed

    assign rec_count_o = m1_rec_count;

    // ────────────────────────────────────────────────────────────────────────
    // Submodule instantiations
    // ────────────────────────────────────────────────────────────────────────

    // CHANGED: m1_top → m1_eth_top (Ethernet ingress instead of UART)
    m1_eth_top u_m1 (
        .clk                 (clk),
        .rst                 (rst),
        // Ethernet board pins
        .ENET0_RX_CLK        (ENET0_RX_CLK),
        .ENET0_RX_DV         (ENET0_RX_DV),
        .ENET0_RXD           (ENET0_RXD),
        .ENET0_RX_ER         (ENET0_RX_ER),
        .ENET0_RST_N         (ENET0_RST_N),
        .ENET0_MDC           (ENET0_MDC),
        // FIFO read side (consumed by FSM below)
        .fifo_rd_en_i        (fifo_rd_en),
        .fifo_empty_o        (fifo_empty_o),
        .fifo_full_o         (fifo_full),
        .fifo_count_o        (fifo_count_o),
        .fifo_dout_o         (fifo_dout_o),
        // Debug
        .last_byte_o         (m1_last_byte),
        .xdp_pkts_parsed_o   (xdp_pkts_parsed_o),
        .add_orders_found_o  (add_orders_found_o),
        .all_add_orders_o    (all_add_orders_o),
        .quotes_emitted_o    (quotes_emitted_o),
        .records_passed_o    (records_passed_o),
        .records_dropped_o   (records_dropped_o),
        .rec_count_o         (m1_rec_count)
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
    // Pipeline controller FSM — UNCHANGED from UART version.
    //
    // 7-state walk per record:
    //   S_IDLE -> S_FIFO_RD -> S_MEM_WAIT -> S_COMPUTE ->
    //   S_RESULT -> S_STATS -> S_STATS_WAIT -> S_IDLE
    //
    // Each record takes 8 cycles (~160 ns at 50 MHz). At Ethernet line rate
    // the FIFO can fill briefly during bursts — monitor records_dropped_o.
    // ────────────────────────────────────────────────────────────────────────
    localparam S_IDLE      = 3'd0;
    localparam S_FIFO_RD   = 3'd1;
    localparam S_MEM_WAIT  = 3'd2;
    localparam S_COMPUTE   = 3'd3;
    localparam S_RESULT    = 3'd4;
    localparam S_STATS     = 3'd5;
    localparam S_STATS_WAIT= 3'd6;

    reg [2:0] state;

    always @(*) begin
        fifo_rd_en = (state == S_IDLE) && !fifo_empty_o;
    end

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
            sm_wr_en        <= 1'b0;
            engine_valid_in <= 1'b0;
            stats_valid_in  <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (!fifo_empty_o)
                        state <= S_FIFO_RD;
                end

                S_FIFO_RD: begin
                    sym_id_reg  <= sym_id_raw;
                    bid_reg     <= bid_q9_raw;
                    ask_reg     <= ask_q9_raw;
                    sm_rd_addr  <= (sym_id_raw > 4'd0) ? (sym_id_raw - 4'd1) : 4'd0;
                    weight_addr_reg <= {12'd0, (sym_id_raw > 4'd0) ? (sym_id_raw - 4'd1) : 4'd0};
                    state <= S_MEM_WAIT;
                end

                S_MEM_WAIT: begin
                    state <= S_COMPUTE;
                end

                S_COMPUTE: begin
                    engine_valid_in <= 1'b1;
                    state           <= S_RESULT;
                end

                S_RESULT: begin
                    if (engine_valid_out) begin
                        sm_wr_addr <= (sym_id_reg > 4'd0) ? (sym_id_reg - 4'd1) : 4'd0;
                        sm_bid_in  <= bid_reg;
                        sm_ask_in  <= ask_reg;
                        sm_mid_in  <= engine_new_mid;
                        sm_wr_en   <= 1'b1;
                        state      <= S_STATS;
                    end
                end

                S_STATS: begin
                    stats_data_in  <= engine_index_value;
                    stats_valid_in <= 1'b1;
                    state          <= S_STATS_WAIT;
                end

                S_STATS_WAIT: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule