// quote_eth_adapter.v
// ─────────────────────────────────────────────────────────────────────────────
// Adapts xdp_eth_parser's quote_out to the existing 48-bit burst_fifo
// interface (same layout used by the UART path's quote_record_assembler).
//
// PARSER OUTPUT (44 bits):
//   quote_out[43:40] = local_symbol_id
//   quote_out[39:20] = bid_q9 (20 bits)
//   quote_out[19: 0] = ask_q9 (20 bits)
//   quote_valid      = 1-cycle pulse when above is valid
//
// FIFO INPUT (48 bits) -- matches quote_record_assembler.v exactly:
//   record_out[47:44] = 4'b0 (zero pad)
//   record_out[43:40] = local_symbol_id
//   record_out[39:20] = bid_q9
//   record_out[19: 0] = ask_q9
//   record_valid      = wr_en pulse to FIFO
//
// So this module is literally: zero-extend by 4 bits, pass through.
// Plus diagnostic counters and a drop-on-full policy.
// ─────────────────────────────────────────────────────────────────────────────

module quote_eth_adapter (
    input  wire        clk,
    input  wire        rst,

    // From xdp_eth_parser
    input  wire [43:0] quote_in,
    input  wire        quote_valid,

    // To burst_fifo
    input  wire        fifo_full,
    output reg  [47:0] record_out,
    output reg         record_valid,

    // Diagnostics (visible on HEX/LED for debug)
    output reg  [15:0] records_passed,
    output reg  [15:0] records_dropped
);

    wire [3:0]  q_sym  = quote_in[43:40];
    wire [19:0] q_bid  = quote_in[39:20];
    wire [19:0] q_ask  = quote_in[19:0];

    wire accept = quote_valid && (q_sym != 4'd0) && !fifo_full;
    wire drop   = quote_valid && (q_sym != 4'd0) && fifo_full;

    always @(posedge clk) begin
        if (rst) begin
            record_out      <= 48'd0;
            record_valid    <= 1'b0;
            records_passed  <= 16'd0;
            records_dropped <= 16'd0;
        end else begin
            record_valid <= 1'b0;

            if (accept) begin
                record_out     <= {4'b0, q_sym, q_bid, q_ask};
                record_valid   <= 1'b1;
                records_passed <= records_passed + 1'b1;
            end else if (drop) begin
                records_dropped <= records_dropped + 1'b1;
            end
        end
    end
endmodule