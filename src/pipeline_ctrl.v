// pipeline_ctrl.v
// -----------------------------------------------------------------------------
// Read-modify-write controller for the index engine pipeline.
//
// 3-stage pipeline, 1 record per clock once primed:
//   stage 0 (READ):      pop FIFO, unpack, drive sym to symbol_state_mem.rd_addr,
//                        latch (sym, bid, ask, weight) into stage-1 registers.
//   stage 1 (COMPUTE):   prev_mid arrives on sm_mid_out; drive bid/ask/prev_mid/
//                        weight into index_engine_core with ie_valid_in=1.
//   stage 2 (WRITEBACK): index_engine asserts ie_valid_out; write new_mid back
//                        to symbol_state_mem, propagate to downstream.
//
// -- RAW HAZARD FORWARDING --
//
// symbol_state_mem has read-BEFORE-write semantics (the read sees memory's
// OLD value, even when a write to the same address fires the same cycle).
// So when two consecutive records hit the same symbol, the second one's
// sm_mid_out is stale. We forward in two cases:
//
//   Case A (in-flight): stage 2 is producing new_mid for symbol X RIGHT NOW
//     (ie_valid_out=1), and stage 1 is computing on symbol X RIGHT NOW.
//     Source prev_mid from ie_new_mid combinationally. (s2_sym tracks the
//     symbol currently in stage 2.)
//
//   Case B (just-completed): the last record produced new_mid for symbol X
//     N cycles ago, the writeback to memory completed N-1 cycles ago, but
//     the read posting that produced THIS cycle's sm_mid_out happened BEFORE
//     that writeback. A 1-deep "last writeback" register (fwd_sym, fwd_mid)
//     remembers it.
//
// Priority: in-flight (Case A) beats register (Case B) beats memory.
// With this two-level forwarding, the controller handles any sequence of
// back-to-back same-symbol records correctly without stalls.
// -----------------------------------------------------------------------------

module pipeline_ctrl #(
    parameter PRICE_WIDTH  = 20,
    parameter WEIGHT_WIDTH = 16,
    parameter INDEX_WIDTH  = 64,
    parameter SYM_WIDTH    = 4
)(
    input  wire                          clk,
    input  wire                          rst,

    // ---- FIFO read interface ----
    input  wire                          fifo_empty,
    input  wire [47:0]                   fifo_dout,    // {4'b0, sym, bid_q9, ask_q9}
    output reg                           fifo_rd_en,

    // ---- symbol_state_mem read port ----
    output reg  [SYM_WIDTH-1:0]          sm_rd_addr,
    input  wire [PRICE_WIDTH-1:0]        sm_mid_out,   // prev_mid (1-cycle sync read)

    // ---- symbol_state_mem write port ----
    output reg                           sm_wr_en,
    output reg  [SYM_WIDTH-1:0]          sm_wr_addr,
    output reg  [PRICE_WIDTH-1:0]        sm_bid_in,
    output reg  [PRICE_WIDTH-1:0]        sm_ask_in,
    output reg  [PRICE_WIDTH-1:0]        sm_mid_in,

    // ---- index_engine_core interface ----
    output reg                           ie_valid_in,
    output reg  [PRICE_WIDTH-1:0]        ie_bid,
    output reg  [PRICE_WIDTH-1:0]        ie_ask,
    output reg  [PRICE_WIDTH-1:0]        ie_prev_mid,
    output reg  [WEIGHT_WIDTH-1:0]       ie_weight,
    input  wire                          ie_valid_out,
    input  wire [PRICE_WIDTH-1:0]        ie_new_mid,
    input  wire signed [INDEX_WIDTH-1:0] ie_index_value,
    input  wire signed [INDEX_WIDTH-1:0] ie_delta_index,

    // ---- Outputs to downstream (rolling window / anomaly detector) ----
    output reg                           index_valid,
    output reg  signed [INDEX_WIDTH-1:0] index_value_out,
    output reg  signed [INDEX_WIDTH-1:0] delta_index_out,
    output reg  [SYM_WIDTH-1:0]          sym_out      // for debug
);
    // ---- FIFO output unpacking (combinational) -----------------------------
    wire [SYM_WIDTH-1:0]    fifo_sym = fifo_dout[43:40];
    wire [PRICE_WIDTH-1:0]  fifo_bid = fifo_dout[39:20];
    wire [PRICE_WIDTH-1:0]  fifo_ask = fifo_dout[19: 0];

    // ---- Stage-1 latches (record currently in COMPUTE) ---------------------
    reg                     s1_valid;
    reg [SYM_WIDTH-1:0]     s1_sym;
    reg [PRICE_WIDTH-1:0]   s1_bid;
    reg [PRICE_WIDTH-1:0]   s1_ask;
    reg [WEIGHT_WIDTH-1:0]  s1_weight;

    // ---- Stage-2 sym tracker (record currently in WRITEBACK) ---------------
    // Needed for Case A forwarding. Updated when we transition s1 -> s2.
    reg [SYM_WIDTH-1:0]     s2_sym;

    // ---- Combinational weight lookup driven from FIFO output ---------------
    wire [WEIGHT_WIDTH-1:0] weight_combi;
    weights_rom u_weights (
        .symbol_id ({{(16-SYM_WIDTH){1'b0}}, fifo_sym}),
        .weight    (weight_combi)
    );

    // ---- Last-writeback forwarding register (Case B) -----------------------
    reg                     fwd_valid;
    reg [SYM_WIDTH-1:0]     fwd_sym;
    reg [PRICE_WIDTH-1:0]   fwd_mid;

    // ---- prev_mid selection ------------------------------------------------
    wire case_a_hit = ie_valid_out && (s1_sym == s2_sym);
    wire case_b_hit = fwd_valid    && (s1_sym == fwd_sym);
    wire [PRICE_WIDTH-1:0] prev_mid_sel =
          case_a_hit ? ie_new_mid
        : case_b_hit ? fwd_mid
        :              sm_mid_out;

    // ---- Main pipeline -----------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            fifo_rd_en       <= 1'b0;
            sm_rd_addr       <= {SYM_WIDTH{1'b0}};
            sm_wr_en         <= 1'b0;
            sm_wr_addr       <= {SYM_WIDTH{1'b0}};
            sm_bid_in        <= {PRICE_WIDTH{1'b0}};
            sm_ask_in        <= {PRICE_WIDTH{1'b0}};
            sm_mid_in        <= {PRICE_WIDTH{1'b0}};
            ie_valid_in      <= 1'b0;
            ie_bid           <= {PRICE_WIDTH{1'b0}};
            ie_ask           <= {PRICE_WIDTH{1'b0}};
            ie_prev_mid      <= {PRICE_WIDTH{1'b0}};
            ie_weight        <= {WEIGHT_WIDTH{1'b0}};
            s1_valid         <= 1'b0;
            s1_sym           <= {SYM_WIDTH{1'b0}};
            s1_bid           <= {PRICE_WIDTH{1'b0}};
            s1_ask           <= {PRICE_WIDTH{1'b0}};
            s1_weight        <= {WEIGHT_WIDTH{1'b0}};
            s2_sym           <= {SYM_WIDTH{1'b0}};
            fwd_valid        <= 1'b0;
            fwd_sym          <= {SYM_WIDTH{1'b0}};
            fwd_mid          <= {PRICE_WIDTH{1'b0}};
            index_valid      <= 1'b0;
            index_value_out  <= {INDEX_WIDTH{1'b0}};
            delta_index_out  <= {INDEX_WIDTH{1'b0}};
            sym_out          <= {SYM_WIDTH{1'b0}};
        end else begin

            // --- defaults that pulse one cycle ----------------------------
            fifo_rd_en   <= 1'b0;
            ie_valid_in  <= 1'b0;
            sm_wr_en     <= 1'b0;
            index_valid  <= 1'b0;

            // --- STAGE 0: pop and read ------------------------------------
            if (!fifo_empty) begin
                fifo_rd_en <= 1'b1;
                sm_rd_addr <= fifo_sym;
                s1_valid   <= 1'b1;
                s1_sym     <= fifo_sym;
                s1_bid     <= fifo_bid;
                s1_ask     <= fifo_ask;
                s1_weight  <= weight_combi;
            end else begin
                s1_valid <= 1'b0;
            end

            // --- STAGE 1: drive index_engine ------------------------------
            if (s1_valid) begin
                ie_valid_in <= 1'b1;
                ie_bid      <= s1_bid;
                ie_ask      <= s1_ask;
                ie_prev_mid <= prev_mid_sel;   // forwarded if needed
                ie_weight   <= s1_weight;
                s2_sym      <= s1_sym;          // advance stage-2 tracker
            end

            // --- STAGE 2: writeback and propagate -------------------------
            if (ie_valid_out) begin
                sm_wr_en   <= 1'b1;
                sm_wr_addr <= s2_sym;
                sm_mid_in  <= ie_new_mid;
                // symbol_state_mem also stores bid/ask but we never read them
                // back (only prev_mid is used downstream). Wire to 0 to keep
                // the module honest and let synthesis prune the unused BRAM.
                sm_bid_in  <= {PRICE_WIDTH{1'b0}};
                sm_ask_in  <= {PRICE_WIDTH{1'b0}};

                // remember this writeback for the next record(s)
                fwd_valid  <= 1'b1;
                fwd_sym    <= s2_sym;
                fwd_mid    <= ie_new_mid;

                index_valid     <= 1'b1;
                index_value_out <= ie_index_value;
                delta_index_out <= ie_delta_index;
                sym_out         <= s2_sym;
            end
        end
    end

endmodule