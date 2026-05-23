// xdp_eth_parser.v
// Synthesizable RTL: Ethernet/VLAN/IP/UDP/XDP parser
//
// BUGS FIXED vs previous version:
//
//   Bug 1 (Quartus Error 10106 - loop > 5000 iterations):
//     REMOVED: for (i=0; i<(1<<ORDER_BITS); i=i+1) ord_valid[i] <= 0;
//     With ORDER_BITS=14, that loop has 16,384 iterations which exceeds
//     Quartus's synthesis loop limit of 5,000.
//     FIX: ord_valid is a BRAM-inferred array. On device power-up BRAMs
//     initialize to 0. On reset we use a small counter (init_ptr) to sweep
//     through all 16,384 entries over 16,384 clock cycles (~328us at 50MHz)
//     before the parser accepts any frames. This is correct and synthesizable.
//
//   Bug 2 (Quartus Error 12152 - can't elaborate, local reg in named block):
//     REMOVED: begin : ao_done / reg [...] pc; reg [...] oslot; ...
//     Local reg declarations inside named begin/end blocks inside always
//     blocks are SystemVerilog, not Verilog-2001. Quartus with "Default"
//     HDL version rejects them.
//     FIX: Hoisted pc, oslot, sidx, lid, emit to module-level regs.
//     They are written combinationally inside the always block before use
//     in the same clock cycle (same always block = OK in synthesis).

module xdp_eth_parser #(
    parameter ORDER_BITS  = 11,     // 2,048 order slots
    parameter SYM_COUNT   = 10,
    parameter PRICE_WIDTH = 20
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  byte_in,
    input  wire        byte_valid,
    input  wire        sof,
    input  wire        eof,
    output reg  [3:0]  add_local_id,
    output reg         add_side,
    output reg  [19:0] add_price_cents,
    output reg         add_order_valid,
    output reg  [43:0] quote_out,
    output reg         quote_valid,
    output reg  [15:0] xdp_pkts_parsed,
    output reg  [15:0] add_orders_found,
    output reg  [15:0] del_orders_found,
    output reg  [15:0] all_add_orders,    // ANY Add Order type 100, any symbol
    output reg  [15:0] quotes_emitted
);

    // ── Symbol index → local_id lookup ──────────────────────────────────────
    function automatic [3:0] sym_lookup;
        input [31:0] idx;
        // Symbol indices from ny4-xchi-pillar-b-20230822T133000.pcap
        // Top 10 most active symbols by Add Order count
        // (will be updated with actual stock names after Symbol Directory parsing)
        case (idx)
            32'd5 : sym_lookup = 4'd1;   // sym_idx 5  (most active)
            32'd6 : sym_lookup = 4'd2;   // sym_idx 6
            32'd4 : sym_lookup = 4'd3;   // sym_idx 4
            32'd8 : sym_lookup = 4'd4;   // sym_idx 8
            32'd7 : sym_lookup = 4'd5;   // sym_idx 7
            32'd9 : sym_lookup = 4'd6;   // sym_idx 9
            32'd10: sym_lookup = 4'd7;   // sym_idx 10
            32'd11: sym_lookup = 4'd8;   // sym_idx 11
            32'd12: sym_lookup = 4'd9;   // sym_idx 12
            32'd13: sym_lookup = 4'd10;  // sym_idx 13
            default: sym_lookup = 4'd0;
        endcase
    endfunction

    // ── Top-of-book state ────────────────────────────────────────────────────
    reg [PRICE_WIDTH-1:0] best_bid  [0:SYM_COUNT-1];
    reg [PRICE_WIDTH-1:0] best_ask  [0:SYM_COUNT-1];
    reg                   bid_valid [0:SYM_COUNT-1];
    reg                   ask_valid [0:SYM_COUNT-1];

    // ── Order table (BRAM-inferred) ──────────────────────────────────────────
    reg [3:0]             ord_sym   [0:(1<<ORDER_BITS)-1];
    reg                   ord_side  [0:(1<<ORDER_BITS)-1];
    reg [PRICE_WIDTH-1:0] ord_price [0:(1<<ORDER_BITS)-1];
    reg                   ord_valid [0:(1<<ORDER_BITS)-1];

    // ── FSM states ───────────────────────────────────────────────────────────
    localparam
        S_INIT        = 4'd15,  // clearing ord_valid on startup/reset
        S_IDLE        = 4'd0,
        S_ETH_HDR     = 4'd1,
        S_IP_HDR      = 4'd2,
        S_UDP_HDR     = 4'd3,
        S_XDP_PKT_HDR = 4'd4,
        S_XDP_MSG_HDR = 4'd5,
        S_ADD_ORDER   = 4'd6,
        S_DEL_ORDER   = 4'd7,
        S_MSG_SKIP    = 4'd8,
        S_FLUSH       = 4'd9;

    reg [3:0]  state;
    reg [15:0] bcnt;

    // ── BUG 1 FIX: init counter sweeps ord_valid to 0 after reset ────────────
    // Runs for 2^ORDER_BITS cycles then transitions to S_IDLE.
    // At 50MHz, 16384 cycles = 327us — negligible startup delay.
    reg [ORDER_BITS-1:0] init_ptr;

    // ── Staging registers for VLAN and msg_type ──────────────────────────────
    reg [7:0] eth12, eth13, vlan_b16;
    reg [7:0] msg_type_lo;

    // ── Protocol parse registers ─────────────────────────────────────────────
    reg [3:0]  ip_ihl;
    reg [7:0]  ip_proto;
    reg [7:0]  xdp_pkt_type;
    reg [7:0]  xdp_msg_left;
    reg [15:0] msg_size;
    reg [15:0] msg_bmax;

    // ── Add Order assembly ────────────────────────────────────────────────────
    reg [31:0] ao_sym_idx;
    reg [63:0] ao_order_id;
    reg [31:0] ao_price_raw;
    reg        ao_side;
    reg [3:0]  ao_local_id;

    // ── Delete Order assembly ─────────────────────────────────────────────────
    reg [63:0] do_order_id;

    // ── BUG 2 FIX: hoisted local variables (were inside named begin blocks) ───
    // These are written and read within the same always block — safe.
    reg [PRICE_WIDTH-1:0]  pc;
    reg [ORDER_BITS-1:0]   oslot;
    reg [3:0]              sidx;
    reg [3:0]              lid;
    reg                    emit;

    wire [7:0] ip_hdr_end = {ip_ihl, 2'b00} - 8'd1;

    integer i;

    always @(posedge clk) begin
        if (rst) begin
            // Reset all small registers immediately
            state            <= S_INIT;
            init_ptr         <= {ORDER_BITS{1'b0}};
            bcnt             <= 0;
            quote_valid      <= 0;
            add_order_valid  <= 0;
            xdp_pkts_parsed  <= 0;
            add_orders_found <= 0;
            del_orders_found <= 0;
            all_add_orders   <= 0;
            quotes_emitted   <= 0;
            eth12            <= 0; eth13 <= 0; vlan_b16 <= 0;
            msg_type_lo      <= 0;
            ip_ihl           <= 4'd5;
            ip_proto         <= 0;
            // Reset small arrays directly (SYM_COUNT=10, well within limit)
            for (i = 0; i < SYM_COUNT; i = i + 1) begin
                best_bid[i]  <= 0;
                best_ask[i]  <= 0;
                bid_valid[i] <= 0;
                ask_valid[i] <= 0;
            end
            // ord_valid cleared by S_INIT state (see below)
        end else begin
            quote_valid     <= 0;
            add_order_valid <= 0;

            case (state)

                // ── BUG 1 FIX: init state clears ord_valid one entry per cycle
                S_INIT: begin
                    ord_valid[init_ptr] <= 1'b0;
                    if (init_ptr == {ORDER_BITS{1'b1}}) begin
                        state <= S_IDLE;  // all entries cleared, ready
                    end else begin
                        init_ptr <= init_ptr + 1'b1;
                    end
                end

                S_IDLE: if (byte_valid && sof) begin
                    bcnt  <= 1;
                    eth12 <= 0;
                    eth13 <= 0;
                    state <= S_ETH_HDR;
                end

                // ── Ethernet + VLAN header ────────────────────────────────────
                S_ETH_HDR: begin
                    if (byte_valid) begin
                        if (bcnt == 13) eth12    <= byte_in;
                        if (bcnt == 14) eth13    <= byte_in;
                        if (bcnt == 17) vlan_b16 <= byte_in;
                        if (bcnt == 18) begin
                            if ({eth12, eth13} == 16'h8100) begin
                                if ({vlan_b16, byte_in} == 16'h0800) begin
                                    bcnt     <= 0;
                                    ip_ihl   <= 4'd5;
                                    ip_proto <= 0;
                                    state    <= S_IP_HDR;
                                end else state <= S_FLUSH;
                            end else state <= S_FLUSH;
                        end else bcnt <= bcnt + 1;
                        if (eof) state <= S_IDLE;
                    end
                end

                // ── IPv4 header ───────────────────────────────────────────────
                S_IP_HDR: begin
                    if (byte_valid) begin
                        if (bcnt == 0) ip_ihl   <= byte_in[3:0];
                        if (bcnt == 9) ip_proto <= byte_in;
                        if (bcnt == {8'd0, ip_hdr_end}) begin
                            if (ip_proto == 8'h11) begin
                                bcnt  <= 0;
                                state <= S_UDP_HDR;
                            end else state <= S_FLUSH;
                        end else bcnt <= bcnt + 1;
                        if (eof) state <= S_IDLE;
                    end
                end

                // ── UDP header (8 bytes, skip) ────────────────────────────────
                S_UDP_HDR: begin
                    if (byte_valid) begin
                        if (bcnt == 7) begin
                            bcnt         <= 0;
                            xdp_pkt_type <= 0;
                            xdp_msg_left <= 0;
                            state        <= S_XDP_PKT_HDR;
                        end else bcnt <= bcnt + 1;
                        if (eof) state <= S_IDLE;
                    end
                end

                // ── XDP packet header (16 bytes) ──────────────────────────────
                S_XDP_PKT_HDR: begin
                    if (byte_valid) begin
                        if (bcnt == 2) xdp_pkt_type <= byte_in;
                        if (bcnt == 3) xdp_msg_left <= byte_in;
                        if (bcnt == 15) begin
                            if (xdp_pkt_type != 8'd1 && xdp_msg_left != 0) begin
                                bcnt             <= 0;
                                msg_type_lo      <= 0;
                                xdp_pkts_parsed  <= xdp_pkts_parsed + 1;
                                state            <= S_XDP_MSG_HDR;
                            end else state <= S_IDLE;
                        end else bcnt <= bcnt + 1;
                        if (eof) state <= S_IDLE;
                    end
                end

                // ── XDP message header (4 bytes) ──────────────────────────────
                S_XDP_MSG_HDR: begin
                    if (byte_valid) begin
                        if (bcnt == 0) msg_size[7:0]  <= byte_in;
                        if (bcnt == 1) msg_size[15:8] <= byte_in;
                        if (bcnt == 2) msg_type_lo    <= byte_in;
                        if (bcnt == 3) begin
                            msg_bmax     <= msg_size - 16'd5;
                            bcnt         <= 0;
                            ao_sym_idx   <= 0; ao_order_id   <= 0;
                            ao_price_raw <= 0; ao_side       <= 0;
                            ao_local_id  <= 0; do_order_id   <= 0;
                            case ({byte_in, msg_type_lo})
                                16'd100: begin state <= S_ADD_ORDER; all_add_orders <= all_add_orders + 1; end
                                16'd102: state <= S_DEL_ORDER;
                                default: state <= S_MSG_SKIP;
                            endcase
                        end else bcnt <= bcnt + 1;
                        if (eof) state <= S_IDLE;
                    end
                end

                // ── Add Order (type 100) ──────────────────────────────────────
                S_ADD_ORDER: begin
                    if (byte_valid) begin
                        case (bcnt)
                            16'd8:  ao_sym_idx[7:0]     <= byte_in;
                            16'd9:  ao_sym_idx[15:8]    <= byte_in;
                            16'd10: ao_sym_idx[23:16]   <= byte_in;
                            16'd11: ao_sym_idx[31:24]   <= byte_in;
                            16'd12: ao_order_id[7:0]    <= byte_in;
                            16'd13: ao_order_id[15:8]   <= byte_in;
                            16'd14: ao_order_id[23:16]  <= byte_in;
                            16'd15: ao_order_id[31:24]  <= byte_in;
                            16'd16: ao_order_id[39:32]  <= byte_in;
                            16'd17: ao_order_id[47:40]  <= byte_in;
                            16'd18: ao_order_id[55:48]  <= byte_in;
                            16'd19: ao_order_id[63:56]  <= byte_in;
                            16'd24: ao_price_raw[7:0]   <= byte_in;
                            16'd25: ao_price_raw[15:8]  <= byte_in;
                            16'd26: ao_price_raw[23:16] <= byte_in;
                            16'd27: ao_price_raw[31:24] <= byte_in;
                            16'd28: begin
                                ao_side     <= (byte_in == 8'h53);
                                ao_local_id <= sym_lookup(ao_sym_idx);
                            end
                        endcase

                        if (bcnt == msg_bmax) begin
                            // BUG 2 FIX: local vars hoisted to module level
                            lid   = (msg_bmax >= 28) ? ao_local_id
                                                     : sym_lookup(ao_sym_idx);
                            //pc    = ao_price_raw / 32'd100;   // options price scale: raw/100 = cents
			    // new scaling
		            price_mul_64 = {32'd0, ao_price_raw} * 64'd562949953;
			    pc = price_mul_64[59:40];
                            oslot = ao_order_id[ORDER_BITS-1:0];
                            sidx  = (lid > 0) ? lid - 4'd1 : 4'd0;

                            if (lid != 4'd0) begin
                                ord_sym  [oslot] <= lid;
                                ord_side [oslot] <= ao_side;
                                ord_price[oslot] <= pc[PRICE_WIDTH-1:0];
                                ord_valid[oslot] <= 1;

                                if (!ao_side) begin
                                    if (!bid_valid[sidx] ||
                                        pc[PRICE_WIDTH-1:0] > best_bid[sidx]) begin
                                        best_bid[sidx]  <= pc[PRICE_WIDTH-1:0];
                                        bid_valid[sidx] <= 1;
                                    end
                                end else begin
                                    if (!ask_valid[sidx] ||
                                        pc[PRICE_WIDTH-1:0] < best_ask[sidx]) begin
                                        best_ask[sidx]  <= pc[PRICE_WIDTH-1:0];
                                        ask_valid[sidx] <= 1;
                                    end
                                end

                                add_local_id     <= lid;
                                add_side         <= ao_side;
                                add_price_cents  <= pc[PRICE_WIDTH-1:0];
                                add_order_valid  <= 1;
                                add_orders_found <= add_orders_found + 1;

                                emit = 0;
                                if (bid_valid[sidx] && ask_valid[sidx]) begin
                                    if (!ao_side && pc[PRICE_WIDTH-1:0] < best_ask[sidx])
                                        emit = 1;
                                    if (ao_side && best_bid[sidx] < pc[PRICE_WIDTH-1:0])
                                        emit = 1;
                                end
                                if (emit) begin
                                    quote_out    <= {lid, best_bid[sidx], best_ask[sidx]};
                                    quote_valid  <= 1;
                                    quotes_emitted <= quotes_emitted + 1;
                                end
                            end

                            bcnt         <= 0;
                            xdp_msg_left <= xdp_msg_left - 1;
                            state <= (xdp_msg_left == 1 || eof) ? S_IDLE : S_XDP_MSG_HDR;
                        end else bcnt <= bcnt + 1;
                        if (eof) state <= S_IDLE;
                    end
                end

                // ── Delete Order (type 102) ───────────────────────────────────
                S_DEL_ORDER: begin
                    if (byte_valid) begin
                        case (bcnt)
                            16'd12: do_order_id[7:0]   <= byte_in;
                            16'd13: do_order_id[15:8]  <= byte_in;
                            16'd14: do_order_id[23:16] <= byte_in;
                            16'd15: do_order_id[31:24] <= byte_in;
                            16'd16: do_order_id[39:32] <= byte_in;
                            16'd17: do_order_id[47:40] <= byte_in;
                            16'd18: do_order_id[55:48] <= byte_in;
                            16'd19: do_order_id[63:56] <= byte_in;
                        endcase

                        if (bcnt == msg_bmax) begin
                            // BUG 2 FIX: module-level oslot, sidx
                            oslot = do_order_id[ORDER_BITS-1:0];
                            if (ord_valid[oslot]) begin
                                sidx = ord_sym[oslot] - 4'd1;
                                if (!ord_side[oslot] && bid_valid[sidx] &&
                                    ord_price[oslot] == best_bid[sidx])
                                    bid_valid[sidx] <= 0;
                                if (ord_side[oslot] && ask_valid[sidx] &&
                                    ord_price[oslot] == best_ask[sidx])
                                    ask_valid[sidx] <= 0;
                                ord_valid[oslot] <= 0;
                            end
                            del_orders_found <= del_orders_found + 1;
                            bcnt         <= 0;
                            xdp_msg_left <= xdp_msg_left - 1;
                            state <= (xdp_msg_left == 1 || eof) ? S_IDLE : S_XDP_MSG_HDR;
                        end else bcnt <= bcnt + 1;
                        if (eof) state <= S_IDLE;
                    end
                end

                // ── Skip unknown message type ─────────────────────────────────
                S_MSG_SKIP: begin
                    if (byte_valid) begin
                        if (bcnt == msg_bmax) begin
                            bcnt         <= 0;
                            xdp_msg_left <= xdp_msg_left - 1;
                            state <= (xdp_msg_left == 1 || eof) ? S_IDLE : S_XDP_MSG_HDR;
                        end else bcnt <= bcnt + 1;
                        if (eof) state <= S_IDLE;
                    end
                end

                S_FLUSH:  if (byte_valid && eof) state <= S_IDLE;
                default:  state <= S_IDLE;

            endcase
        end
    end

endmodule
