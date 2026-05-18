// quote_record_unpacker.v   (path B: 48-bit record)
// -----------------------------------------------------------------------------
// Combinational slice. No clock, no state. Bits don't move; just renamed.
//
//     record_in[47:44] = 4'b0 (zero pad from wire byte 1's high nibble)
//     record_in[43:40] = local_symbol_id   (4 bits)
//     record_in[39:20] = bid_q9            (20 bits, USD * 512)
//     record_in[19: 0] = ask_q9            (20 bits, USD * 512)
//
// Q11.9 means: USD = q9_value / 2^9 = q9_value / 512.
// All FPGA arithmetic stays in q9 units; we only convert back to USD for
// human display in simulation/host.
// -----------------------------------------------------------------------------

module quote_record_unpacker (
    input  wire [47:0] record_in,
    output wire [3:0]  symbol_id,
    output wire [19:0] bid_q9,
    output wire [19:0] ask_q9
);
    assign symbol_id = record_in[43:40];
    assign bid_q9    = record_in[39:20];
    assign ask_q9    = record_in[19: 0];
endmodule