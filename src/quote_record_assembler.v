// quote_record_assembler.v   (path B: XDP-derived 7-byte UART frames)
// -----------------------------------------------------------------------------
// Wire frame coming from uart_replay.py / xdp_quote_parser_fpga.py:
//
//     [byte 0] 0xAA                        sync marker
//     [byte 1] {4'b0, sym[3:0]}            high nibble is zero pad
//     [byte 2] bid_q9[19:12]
//     [byte 3] bid_q9[11: 4]
//     [byte 4] {bid_q9[3:0], ask_q9[19:16]}
//     [byte 5] ask_q9[15: 8]
//     [byte 6] ask_q9[ 7: 0]
//
// After we eat the sync byte, the next 6 bytes form a 48-bit record:
//
//     record_out[47:44] = 4'b0 (pad)
//     record_out[43:40] = local_symbol_id
//     record_out[39:20] = bid_q9 (Q11.9)
//     record_out[19: 0] = ask_q9 (Q11.9)
//
// State machine:
//
//     HUNT_SYNC : drop bytes until one of them == 0xAA
//     COLLECT_6 : shift the next 6 bytes MSB-first into shift_reg.
//                 On the 6th byte, emit record_out + record_valid pulse.
//                 Then go back to HUNT_SYNC and re-confirm next sync.
//
// Why we go back to HUNT_SYNC instead of "expect AA next, else drift":
//   We want self-recovery if a byte ever gets dropped/corrupted on the wire.
//   The cost is one wasted byte per record (the 0xAA itself), but at 115200
//   baud with 7-byte records we're already comfortably below line rate, so
//   simplicity wins.
//
// Debug outputs:
//   state_o            : current FSM state (for HEX/LED inspection)
//   sync_lost_count_o  : counts 'expected sync but didn't get one' events
//                        (currently unused since HUNT_SYNC is unconditional;
//                         placeholder for future strict-mode framing)
// -----------------------------------------------------------------------------

module quote_record_assembler #(
    parameter RECORD_WIDTH    = 48,
    parameter PAYLOAD_BYTES   = 6,
    parameter SYNC_BYTE       = 8'hAA
)(
    input  wire                       clk,
    input  wire                       rst,
    input  wire [7:0]                 byte_in,
    input  wire                       byte_valid,
    output reg  [RECORD_WIDTH-1:0]    record_out,
    output reg                        record_valid,
    // ---- Debug taps ----
    output wire [1:0]                 state_o,
    output wire [3:0]                 byte_count_o,    // 0..5 within payload
    output reg  [15:0]                sync_lost_count_o
);
    localparam S_HUNT_SYNC = 2'd0;
    localparam S_COLLECT_6 = 2'd1;

    reg [1:0]                state;
    reg [RECORD_WIDTH-1:0]   shift_reg;
    reg [3:0]                byte_count;

    assign state_o      = state;
    assign byte_count_o = byte_count;

    always @(posedge clk) begin
        if (rst) begin
            state             <= S_HUNT_SYNC;
            shift_reg         <= {RECORD_WIDTH{1'b0}};
            byte_count        <= 4'd0;
            record_out        <= {RECORD_WIDTH{1'b0}};
            record_valid      <= 1'b0;
            sync_lost_count_o <= 16'd0;
        end else begin
            record_valid <= 1'b0;   // default; pulses 1 cycle when we emit

            if (byte_valid) begin
                case (state)
                    // ---------------------------------------------------------
                    S_HUNT_SYNC: begin
                        // Drop everything until we see a sync byte.
                        if (byte_in == SYNC_BYTE) begin
                            state      <= S_COLLECT_6;
                            byte_count <= 4'd0;
                            shift_reg  <= {RECORD_WIDTH{1'b0}};
                        end
                        // else: stay here, ignore the byte.
                    end

                    // ---------------------------------------------------------
                    S_COLLECT_6: begin
                        // Shift in MSB-first.
                        shift_reg <= {shift_reg[RECORD_WIDTH-9:0], byte_in};

                        if (byte_count == PAYLOAD_BYTES-1) begin
                            // 6th byte just arrived -> emit full record.
                            record_out   <= {shift_reg[RECORD_WIDTH-9:0], byte_in};
                            record_valid <= 1'b1;
                            byte_count   <= 4'd0;
                            state        <= S_HUNT_SYNC;
                        end else begin
                            byte_count <= byte_count + 4'd1;
                        end
                    end

                    default: state <= S_HUNT_SYNC;
                endcase
            end
        end
    end
endmodule