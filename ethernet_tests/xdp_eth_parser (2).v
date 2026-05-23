// xdp_eth_parser.v — synthesizable RTL XDP parser
//
// FIELD OFFSETS (confirmed against xdp_quote_parser_fpga.py):
//   sym_idx  = msg[8:11]  = payload[4:7]  → bcnt 4-7
//   order_id = msg[16:23] = payload[12:19] → bcnt 12-19
//   price    = msg[24:27] = payload[20:23] → bcnt 20-23
//   side     = msg[32]    = payload[28]    → bcnt 28
//
// SYNTHESIS FIXES vs simulation version:
//   1. S_INIT state replaces 16384-iteration reset loop (Quartus Error 10106)
//   2. Local regs hoisted to module level (Quartus Error 12152)
//   3. Emit condition uses incoming pc directly (non-blocking read-back fix)
//   4. ETH_HDR bcnt offsets +1 for hardware bridge (SFD byte offset)
//   5. ORDER_BITS=11 (2048 slots) for faster Quartus compile

module xdp_eth_parser #(
    parameter ORDER_BITS  = 11,
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
    output reg  [15:0] quotes_emitted,
    output reg  [15:0] all_add_orders
);

    // Symbol indices from fpga_symbol_map.csv (authoritative)
    function automatic [3:0] sym_lookup;
        input [31:0] idx;
        case (idx)
            32'd9    : sym_lookup = 4'd1;   // AAPL
            32'd32918: sym_lookup = 4'd2;   // TSLA
            32'd1753 : sym_lookup = 4'd3;   // GOOGL
            32'd2763 : sym_lookup = 4'd4;   // NFLX
            32'd2886 : sym_lookup = 4'd5;   // NVDA
            32'd2623 : sym_lookup = 4'd6;   // MRVL
            32'd4755 : sym_lookup = 4'd7;   // AMD
            32'd3331 : sym_lookup = 4'd8;   // QCOM
            32'd2633 : sym_lookup = 4'd9;   // MSFT
            32'd67688: sym_lookup = 4'd10;  // PLTR
            default  : sym_lookup = 4'd0;
        endcase
    endfunction

    reg [PRICE_WIDTH-1:0] best_bid  [0:SYM_COUNT-1];
    reg [PRICE_WIDTH-1:0] best_ask  [0:SYM_COUNT-1];
    reg                   bid_valid [0:SYM_COUNT-1];
    reg                   ask_valid [0:SYM_COUNT-1];

    reg [3:0]             ord_sym   [0:(1<<ORDER_BITS)-1];
    reg                   ord_side  [0:(1<<ORDER_BITS)-1];
    reg [PRICE_WIDTH-1:0] ord_price [0:(1<<ORDER_BITS)-1];
    reg                   ord_valid [0:(1<<ORDER_BITS)-1];
	 reg [63:0] price_mul_64;
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
    reg [ORDER_BITS-1:0] init_ptr;

    // Staging registers
    reg [7:0] eth12, eth13, vlan_b16;
    reg [7:0] msg_type_lo;

    reg [3:0]  ip_ihl;
    reg [7:0]  ip_proto;
    reg [7:0]  xdp_pkt_type;
    reg [7:0]  xdp_msg_left;
    reg [15:0] msg_size;
    reg [15:0] msg_bmax;

    reg [31:0] ao_sym_idx;
    reg [63:0] ao_order_id;
    reg [31:0] ao_price_raw;
    reg        ao_side;
    reg [3:0]  ao_local_id;
    reg [63:0] do_order_id;

    // Hoisted locals (FIX 2: were inside named begin blocks)
    reg [PRICE_WIDTH-1:0] pc;
    reg [ORDER_BITS-1:0]  oslot;
    reg [3:0]             sidx, lid;
    reg                   emit;

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
            quotes_emitted   <= 0;
            all_add_orders   <= 0;
            eth12 <= 0; eth13 <= 0; vlan_b16 <= 0;
            msg_type_lo <= 0;
            ip_ihl <= 4'd5; ip_proto <= 0;
            for (i = 0; i < SYM_COUNT; i = i+1) begin
                best_bid[i] <= 0; best_ask[i] <= 0;
                bid_valid[i] <= 0; ask_valid[i] <= 0;
            end
        end else begin
            quote_valid     <= 0;
            add_order_valid <= 0;

            case (state)

                // FIX 1: sweep ord_valid to 0 one entry per cycle
                S_INIT: begin
                    ord_valid[init_ptr] <= 1'b0;
                    if (init_ptr == {ORDER_BITS{1'b1}})
                        state <= S_IDLE;
                    else
                        init_ptr <= init_ptr + 1'b1;
                end

                S_IDLE: if (byte_valid && sof) begin
                    bcnt <= 1; eth12 <= 0; eth13 <= 0;
                    state <= S_ETH_HDR;
                end

                // FIX 4: bcnt is +1 in hardware (SFD byte offset)
                // Ethernet byte N arrives at bcnt = N+1
                S_ETH_HDR: begin
                    if (byte_valid) begin
                        if (bcnt==13) eth12    <= byte_in;
                        if (bcnt==14) eth13    <= byte_in;
                        if (bcnt==17) vlan_b16 <= byte_in;
                        if (bcnt==18) begin
                            if ({eth12,eth13}==16'h8100) begin
                                if ({vlan_b16,byte_in}==16'h0800) begin
                                    bcnt<=0; ip_ihl<=4'd5; ip_proto<=0;
                                    state<=S_IP_HDR;
                                end else state<=S_FLUSH;
                            end else state<=S_FLUSH;
                        end else bcnt<=bcnt+1;
                        if (eof) state<=S_IDLE;
                    end
                end

                S_IP_HDR: begin
                    if (byte_valid) begin
                        if (bcnt==0) ip_ihl   <= byte_in[3:0];
                        if (bcnt==9) ip_proto <= byte_in;
                        if (bcnt=={8'd0,ip_hdr_end}) begin
                            if (ip_proto==8'h11) begin
                                bcnt<=0; state<=S_UDP_HDR;
                            end else state<=S_FLUSH;
                        end else bcnt<=bcnt+1;
                        if (eof) state<=S_IDLE;
                    end
                end

                S_UDP_HDR: begin
                    if (byte_valid) begin
                        if (bcnt==7) begin
                            bcnt<=0; xdp_pkt_type<=0; xdp_msg_left<=0;
                            state<=S_XDP_PKT_HDR;
                        end else bcnt<=bcnt+1;
                        if (eof) state<=S_IDLE;
                    end
                end

                S_XDP_PKT_HDR: begin
                    if (byte_valid) begin
                        if (bcnt==2) xdp_pkt_type <= byte_in;
                        if (bcnt==3) xdp_msg_left <= byte_in;
                        if (bcnt==15) begin
                            if (xdp_pkt_type!=8'd1 && xdp_msg_left!=0) begin
                                bcnt<=0; msg_type_lo<=0;
                                xdp_pkts_parsed<=xdp_pkts_parsed+1;
                                state<=S_XDP_MSG_HDR;
                            end else state<=S_IDLE;
                        end else bcnt<=bcnt+1;
                        if (eof) state<=S_IDLE;
                    end
                end

                S_XDP_MSG_HDR: begin
                    if (byte_valid) begin
                        if (bcnt==0) msg_size[7:0]  <= byte_in;
                        if (bcnt==1) msg_size[15:8] <= byte_in;
                        if (bcnt==2) msg_type_lo    <= byte_in;
                        if (bcnt==3) begin
                            msg_bmax <= msg_size - 16'd5;
                            bcnt <= 0;
                            ao_sym_idx<=0; ao_order_id<=0;
                            ao_price_raw<=0; ao_side<=0;
                            ao_local_id<=0; do_order_id<=0;
                            case ({byte_in, msg_type_lo})
                                16'd100: state <= S_ADD_ORDER;
                                16'd102: state <= S_DEL_ORDER;
                                default: state <= S_MSG_SKIP;
                            endcase
                        end else bcnt<=bcnt+1;
                        if (eof) state<=S_IDLE;
                    end
                end

                S_ADD_ORDER: begin
                    if (byte_valid) begin
                        case (bcnt)
                            // CORRECT offsets (match authoritative Python parser):
                            // sym_idx  = msg[8:11]  = payload[4:7]  → bcnt 4-7
                            16'd4:  ao_sym_idx[7:0]    <= byte_in;
                            16'd5:  ao_sym_idx[15:8]   <= byte_in;
                            16'd6:  ao_sym_idx[23:16]  <= byte_in;
                            16'd7:  ao_sym_idx[31:24]  <= byte_in;
                            // order_id = msg[16:23] = payload[12:19] → bcnt 12-19
                            16'd12: ao_order_id[7:0]   <= byte_in;
                            16'd13: ao_order_id[15:8]  <= byte_in;
                            16'd14: ao_order_id[23:16] <= byte_in;
                            16'd15: ao_order_id[31:24] <= byte_in;
                            16'd16: ao_order_id[39:32] <= byte_in;
                            16'd17: ao_order_id[47:40] <= byte_in;
                            16'd18: ao_order_id[55:48] <= byte_in;
                            16'd19: ao_order_id[63:56] <= byte_in;
                            // price    = msg[24:27] = payload[20:23] → bcnt 20-23
                            16'd20: ao_price_raw[7:0]  <= byte_in;
                            16'd21: ao_price_raw[15:8] <= byte_in;
                            16'd22: ao_price_raw[23:16]<= byte_in;
                            16'd23: ao_price_raw[31:24]<= byte_in;
                            // side     = msg[32]    = payload[28]    → bcnt 28
                            16'd28: begin
                                ao_side     <= (byte_in == 8'h53);
                                ao_local_id <= sym_lookup(ao_sym_idx);
                            end
                        endcase

                        if (bcnt == msg_bmax) begin
                            all_add_orders <= all_add_orders + 1;

                            lid   = (msg_bmax >= 28) ? ao_local_id
                                                     : sym_lookup(ao_sym_idx);
                            // NYSE Pillar price_scale=6: raw/10000 = cents
                            //pc    = ao_price_raw / 32'd10000;
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

                                // FIX 3: emit using incoming pc, not just-written registers
                                emit = 0;
                                if (!ao_side) begin
                                    if (ask_valid[sidx] &&
                                        pc[PRICE_WIDTH-1:0] < best_ask[sidx])
                                        emit = 1;
                                end else begin
                                    if (bid_valid[sidx] &&
                                        best_bid[sidx] < pc[PRICE_WIDTH-1:0])
                                        emit = 1;
                                end
                                if (emit) begin
                                    if (!ao_side)
                                        quote_out <= {lid,
                                                      pc[PRICE_WIDTH-1:0],
                                                      best_ask[sidx]};
                                    else
                                        quote_out <= {lid,
                                                      best_bid[sidx],
                                                      pc[PRICE_WIDTH-1:0]};
                                    quote_valid    <= 1;
                                    quotes_emitted <= quotes_emitted + 1;
                                end
                            end

                            bcnt         <= 0;
                            xdp_msg_left <= xdp_msg_left - 1;
                            state <= (xdp_msg_left==1||eof) ? S_IDLE : S_XDP_MSG_HDR;
                        end else bcnt <= bcnt + 1;
                        if (eof) state <= S_IDLE;
                    end
                end

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
                            state <= (xdp_msg_left==1||eof) ? S_IDLE : S_XDP_MSG_HDR;
                        end else bcnt <= bcnt + 1;
                        if (eof) state <= S_IDLE;
                    end
                end

                S_MSG_SKIP: begin
                    if (byte_valid) begin
                        if (bcnt == msg_bmax) begin
                            bcnt         <= 0;
                            xdp_msg_left <= xdp_msg_left - 1;
                            state <= (xdp_msg_left==1||eof) ? S_IDLE : S_XDP_MSG_HDR;
                        end else bcnt <= bcnt + 1;
                        if (eof) state <= S_IDLE;
                    end
                end

                S_FLUSH: if (byte_valid && eof) state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule