// xdp_loopback_test.v — with debug counter display
//
// DISPLAY (default, no keys held):
//   HEX5:HEX4 = "--"  waiting for quote
//   HEX3:HEX0 = xdp_pkts_parsed  ← KEY diagnostic default
//
// KEY debug modes (hold while running replay_pcap.py):
//   No key    : HEX3:HEX0 = xdp_pkts_parsed  (got past ETH_HDR?)
//   KEY[1]    : HEX3:HEX0 = add_orders_found  (Add Orders parsed?)
//   KEY[2]    : HEX3:HEX0 = quotes_emitted    (quotes generated?)
//   KEY[1]+[2]: HEX3:HEX0 = bid price of first quote (if received)
//               HEX5:HEX4 = symbol ID of first quote
//
// LEDS:
//   LEDR[17] = heartbeat
//   LEDR[16] = sticky rx_active (0.5s after any frame)
//   LEDR[1]  = quote received (latches on)
//   LEDR[0]  = add_order pulse (50ms stretch)
//
// WHAT TO CHECK:
//   After running replay_pcap.py with 2000 packets:
//   1. No keys: if HEX shows 0000, ETH_HDR check still failing
//               if HEX shows > 0, frames are getting through to XDP level
//   2. KEY[1]:  if HEX shows 0000, no Add Orders found
//               if HEX shows > 0, Add Orders are being parsed
//   3. KEY[2]:  if HEX shows 0000, no quotes emitted (need bid+ask same symbol)
//               if HEX shows > 0, quotes found — check KEY[1]+[2] for values

module xdp_loopback_test (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,

    input  wire        ENET0_RX_CLK,
    input  wire        ENET0_RX_DV,
    input  wire [3:0]  ENET0_RXD,
    input  wire        ENET0_RX_ER,
    output wire        ENET0_RST_N,
    output wire        ENET0_MDC,

    output wire [17:0] LEDR,
    output wire [8:0]  LEDG,
    output wire [6:0]  HEX0, HEX1, HEX2,
    output wire [6:0]  HEX3, HEX4, HEX5
);

    wire clk = CLOCK_50;
    wire rst = ~KEY[0];

    assign ENET0_RST_N = 1'b1;
    assign ENET0_MDC   = 1'b0;
    assign LEDG        = 9'd1;

    // ── Heartbeat ──────────────────────────────────────────────────────────
    reg [24:0] hb_cnt;
    reg        heartbeat;
    always @(posedge clk or posedge rst) begin
        if (rst) begin hb_cnt <= 0; heartbeat <= 0; end
        else if (hb_cnt == 25_000_000 - 1) begin
            hb_cnt <= 0; heartbeat <= ~heartbeat;
        end else hb_cnt <= hb_cnt + 1;
    end

    // ── MAC bridge ─────────────────────────────────────────────────────────
    wire [7:0] eth_byte;
    wire       eth_valid, eth_sof, eth_eof;

    eth_mac_bridge u_bridge (
        .clk       (clk),       .rst    (rst),
        .rx_clk    (ENET0_RX_CLK),
        .rx_data   (ENET0_RXD), .rx_dv  (ENET0_RX_DV),
        .rx_er     (ENET0_RX_ER),
        .byte_out  (eth_byte),  .byte_valid(eth_valid),
        .sof       (eth_sof),   .eof    (eth_eof)
    );

    // ── Sticky rx_active ───────────────────────────────────────────────────
    reg [24:0] rx_sticky_cnt;
    reg        rx_sticky;
    always @(posedge clk or posedge rst) begin
        if (rst) begin rx_sticky_cnt <= 0; rx_sticky <= 0; end
        else if (eth_eof && eth_valid) begin
            rx_sticky_cnt <= 25_000_000 / 2 - 1;
            rx_sticky     <= 1;
        end else if (rx_sticky_cnt != 0)
            rx_sticky_cnt <= rx_sticky_cnt - 1;
        else
            rx_sticky <= 0;
    end

    // ── XDP parser ─────────────────────────────────────────────────────────
    wire [3:0]  add_local_id;
    wire        add_side;
    wire [19:0] add_price_cents;
    wire        add_order_valid;
    wire [43:0] quote_out;
    wire        quote_valid;
    wire [15:0] xdp_pkts_parsed;
    wire [15:0] add_orders_found;
    wire [15:0] del_orders_found;
    wire [15:0] all_add_orders;
    wire [15:0] quotes_emitted;

    xdp_eth_parser #(
        .ORDER_BITS (11),
        .SYM_COUNT  (10),
        .PRICE_WIDTH(20)
    ) u_parser (
        .clk             (clk),       .rst            (rst),
        .byte_in         (eth_byte),  .byte_valid     (eth_valid),
        .sof             (eth_sof),   .eof            (eth_eof),
        .add_local_id    (add_local_id),
        .add_side        (add_side),
        .add_price_cents (add_price_cents),
        .add_order_valid (add_order_valid),
        .quote_out       (quote_out), .quote_valid    (quote_valid),
        .xdp_pkts_parsed (xdp_pkts_parsed),
        .add_orders_found(add_orders_found),
        .del_orders_found(del_orders_found),
        .all_add_orders  (all_add_orders),
        .quotes_emitted  (quotes_emitted)
    );

    // ── Latch first quote ──────────────────────────────────────────────────
    reg        quote_received;
    reg [3:0]  disp_sym;
    reg [19:0] disp_bid;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            quote_received <= 0;
            disp_sym       <= 0;
            disp_bid       <= 0;
        end else if (quote_valid && !quote_received) begin
            disp_sym       <= quote_out[43:40];
            disp_bid       <= quote_out[39:20];
            quote_received <= 1;
        end
    end

    // ── Add Order pulse stretch ────────────────────────────────────────────
    reg [21:0] ao_stretch;
    reg        ao_led;
    always @(posedge clk or posedge rst) begin
        if (rst) begin ao_stretch <= 0; ao_led <= 0; end
        else if (add_order_valid) begin
            ao_stretch <= 22'd2_500_000;
            ao_led     <= 1;
        end else if (ao_stretch != 0)
            ao_stretch <= ao_stretch - 1;
        else
            ao_led <= 0;
    end

    // ── Display mux ────────────────────────────────────────────────────────
    reg [15:0] disp_val;
    reg [7:0]  sym_val;

    always @(*) begin
        if (!KEY[2] && !KEY[1]) begin
            // Both held: show first quote (symbol + bid)
            disp_val = quote_received ? disp_bid[15:0] : 16'd0;
            sym_val  = quote_received ? {4'd0, disp_sym} : 8'hFF;
        end else if (!KEY[1]) begin
            // KEY[1] only: add_orders_found
            disp_val = add_orders_found;
            sym_val  = 8'hEE;   // shows "EE" = diagnostic mode
        end else if (!KEY[2]) begin
            // KEY[2] only: quotes_emitted
            disp_val = all_add_orders;  // KEY[2]: ALL Add Orders (any symbol)
            sym_val  = 8'hCC;
        end else begin
            // Default: xdp_pkts_parsed
            disp_val = xdp_pkts_parsed;
            sym_val  = 8'hDD;
        end
    end

    hex_dec h0 (.val(disp_val[3:0]),  .seg(HEX0));
    hex_dec h1 (.val(disp_val[7:4]),  .seg(HEX1));
    hex_dec h2 (.val(disp_val[11:8]), .seg(HEX2));
    hex_dec h3 (.val(disp_val[15:12]),.seg(HEX3));
    hex_dec h4 (.val(sym_val[3:0]),   .seg(HEX4));
    hex_dec h5 (.val(sym_val[7:4]),   .seg(HEX5));

    assign LEDR[17]   = heartbeat;
    assign LEDR[16]   = rx_sticky;
    assign LEDR[15:2] = 14'd0;
    assign LEDR[1]    = quote_received;
    assign LEDR[0]    = ao_led;

endmodule

module hex_dec (
    input  wire [3:0] val,
    output reg  [6:0] seg
);
    always @(*) begin
        case (val)
            4'h0: seg = 7'b1000000; 4'h1: seg = 7'b1111001;
            4'h2: seg = 7'b0100100; 4'h3: seg = 7'b0110000;
            4'h4: seg = 7'b0011001; 4'h5: seg = 7'b0010010;
            4'h6: seg = 7'b0000010; 4'h7: seg = 7'b1111000;
            4'h8: seg = 7'b0000000; 4'h9: seg = 7'b0010000;
            4'hA: seg = 7'b0001000; 4'hB: seg = 7'b0000011;
            4'hC: seg = 7'b1000110; 4'hD: seg = 7'b0100001;
            4'hE: seg = 7'b0000110; 4'hF: seg = 7'b0001110;
            default: seg = 7'b1111111;
        endcase
    end
endmodule
