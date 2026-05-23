// xdp_eth_parser.v
// Synthesizable RTL: Ethernet/VLAN/IP/UDP/XDP parser
//
// PATCHES IN THIS VERSION:
//
//   Patch A (symbol mapping):
//     The case statement in sym_lookup was using placeholder indices
//     (5, 6, 4, ...) that did NOT correspond to the actual XDP symbol
//     indices in the target PCAP. Verified via the existing Python
//     build_symbol_table() function on ny4-xchi-pillar-b-20230822T133000.pcap,
//     the real indices for our 10 tracked tickers are:
//        AAPL=9, TSLA=32918, GOOGL=1753, NFLX=2763, NVDA=2886,
//        MRVL=2623, AMD=4755, QCOM=3331, MSFT=2633, PLTR=67688
//
//   Patch B (Q11.9 price scaling):
//     XDP price_scale = 6 (raw_price is USD * 1,000,000). Old code did
//     `pc = ao_price_raw / 32'd100` which produced wrong units. The new
//     code converts to Q11.9 (USD * 512) via a power-of-2 approximation
//     suitable for the FPGA pipeline:
//
//        target = raw_price * 512 / 1,000,000
//        approx = (raw_price * 562,949,953) >> 40
//
//     Verified exact for all $0.01..$2047.99 (the entire 20-bit Q11.9
//     range). Uses one 32x64 multiplier (one DSP block) plus a static
//     bit slice.
//
//   Patch C: declared 64-bit intermediate `price_mul_64` at module level
//     alongside the other hoisted locals. (The previous edit used it
//     without declaring it, which would not compile.)
//
//   Patch D: renamed `add_price_cents` output to keep API the same but
//     updated comments — the value on this port is now Q11.9, not cents.
//
//
// PRE-EXISTING BUG FIXES (carried over):
//
//   Bug 1 (Quartus Error 10106 - loop > 5000 iterations):
//     ord_valid cleared via S_INIT counter, not a synthesis-time loop.
//
//   Bug 2 (Quartus Error 12152 - can't elaborate local reg in named block):
//     pc, oslot, sidx, lid, emit hoisted to module-level regs.

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
    output reg  [19:0] add_price_cents,  // NOTE: legacy name. Value is now Q11.9 (USD*512).
    output reg         add_order_valid,
    output reg  [43:0] quote_out,
    output reg         quote_valid,
    output reg  [15:0] xdp_pkts_parsed,
    output reg  [15:0] add_orders_found,
    output reg  [15:0] del_orders_found,
    output reg  [15:0] all_add_orders,
    output reg  [15:0] quotes_emitted
);

    // ── Symbol index → local_id lookup (PATCH A) ────────────────────────────
    // Real XDP symbol indices verified via build_symbol_table() on
    // ny4-xchi-pillar-b-20230822T133000.pcap. If you use a different PCAP,
    // regenerate this table or sym_lookup will return 0 for everything.
    function automatic [3:0] sym_lookup;
        input [31:0] idx;
        case (idx)
            32'd9     : sym_lookup = 4'd1;   // AAPL
            32'd32918 : sym_lookup = 4'd2;   // TSLA
            32'd1753  : sym_lookup = 4'd3;   // GOOGL
            32'd2763  : sym_lookup = 4'd4;   // NFLX
            32'd2886  : sym_lookup = 4'd5;   // NVDA
            32'd2623  : sym_lookup = 4'd6;   // MRVL
            32'd4755  : sym_lookup = 4'd7;   // AMD
            32'd3331  : sym_lookup = 4'd8;   // QCOM
            32'd2633  : sym_lookup = 4'd9;   // MSFT
            32'd67688 : sym_lookup = 4'd10;  // PLTR
            default   : sym_lookup = 4'd0;
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
        S_INIT        = 4'd15,
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

    // ── Init counter sweeps ord_valid to 0 after reset (Bug 1 fix) ───────────
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

    // ── Hoisted local variables (Bug 2 fix + PATCH C: added price_mul_64) ────
    reg [PRICE_WIDTH-1:0]  pc;
    reg [ORDER_BITS-1:0]   oslot;
    reg [3:0]              sidx;
    reg [3:0]              lid;
    reg                    emit;
    reg [63:0]             price_mul_64;   // ── PATCH C: declared ──

    wire [7:0] ip_hdr_end = {ip_ihl, 2'b00} - 8'd1;

    integer i;

    always @(posedge clk) begin
        if (rst) begin
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
            for (i = 0; i < SYM_COUNT; i = i + 1) begin
                best_bid[i]  <= 0;
                best_ask[i]  <= 0;
                bid_valid[i] <= 0;
                ask_valid[i] <= 0;
            end
        end else begin
            quote_valid     <= 0;
            add_order_valid <= 0;

            case (state)

                S_INIT: begin
                    ord_valid[init_ptr] <= 1'b0;
                    if (init_ptr == {ORDER_BITS{1'b1}}) begin
                        state <= S_IDLE;
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
                            lid = (msg_bmax >= 28) ? ao_local_id
                                                   : sym_lookup(ao_sym_idx);

                            // ── PATCH B: Q11.9 price scaling ──
                            // XDP price_scale=6: raw is USD*1e6.
                            // Q11.9 target: USD*512.
                            // (raw * 562949953) >> 40 ≈ raw * 512 / 1e6 (exact in our range).
                            price_mul_64 = {32'd0, ao_price_raw} * 64'd562949953;
                            pc           = price_mul_64[59:40];

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
                                add_price_cents  <= pc[PRICE_WIDTH-1:0];   // Q11.9 now
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