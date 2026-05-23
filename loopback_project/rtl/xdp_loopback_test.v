// xdp_loopback_test.v — Test 3: bridge → parser → FIFO → display
//
// Adds burst_fifo after the parser. Quotes flow in on quote_valid,
// get stored in the FIFO, and are read out one at a time.
//
// DISPLAY (KEY debug modes):
//   No key     : HEX shows xdp_pkts_parsed          (parser alive?)
//   KEY[1]     : HEX shows add_orders_found          (Add Orders found?)
//   KEY[2]     : HEX shows fifo_count                (quotes in FIFO?)
//   KEY[1]+[2] : HEX5:HEX4=symbol, HEX3:HEX0=bid    (first quote value)
//
// LEDS:
//   LEDR[17] = heartbeat
//   LEDR[16] = sticky rx_active
//   LEDR[2]  = fifo_full  (should never light — means parser too fast)
//   LEDR[1]  = quote_received (first quote latched)
//   LEDR[0]  = add_order pulse

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
    wire [15:0] quotes_emitted;
    wire [15:0] all_add_orders;

    xdp_eth_parser #(
        .ORDER_BITS (9),
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
        .quotes_emitted  (quotes_emitted),
        .all_add_orders  (all_add_orders)
    );

    // ── FIFO ───────────────────────────────────────────────────────────────
    // Quotes from parser (44 bits) padded to 48 bits to match FIFO width
    wire [47:0] fifo_din   = {4'b0, quote_out};  // zero-pad upper 4 bits
    wire        fifo_wr_en = quote_valid;
    wire [47:0] fifo_dout;
    wire        fifo_full, fifo_empty;
    wire [8:0]  fifo_count;

    // Gated drain: read one entry every 0.5s so the count is observable.
    // You should see fifo_count CLIMB while packets arrive, then tick
    // DOWN one step every 0.5s as entries drain. This proves both the
    // write path (count goes up) and read path (count goes down) work.
    // If count stays 0000 the whole time, no quotes were written.
    // If count climbs but never drops, the read path is broken.
    reg [24:0] drain_cnt;
    reg        drain_tick;
    always @(posedge clk or posedge rst) begin
        if (rst) begin drain_cnt <= 0; drain_tick <= 0; end
        else if (drain_cnt == 25_000_000 / 2 - 1) begin
            drain_cnt  <= 0;
            drain_tick <= 1;
        end else begin
            drain_cnt  <= drain_cnt + 1;
            drain_tick <= 0;
        end
    end
    wire fifo_rd_en = drain_tick && !fifo_empty;

    // Count how many times FIFO hit full — should be 0 for healthy operation
    // If this is non-zero it means quotes arrived faster than drain rate
    reg [15:0] fifo_full_count;
    always @(posedge clk or posedge rst) begin
        if (rst) fifo_full_count <= 0;
        else if (fifo_wr_en && fifo_full)
            fifo_full_count <= fifo_full_count + 1;
    end

    burst_fifo #(
        .DATA_WIDTH(48),
        .DEPTH     (256)
    ) u_fifo (
        .clk  (clk),       .rst  (rst),
        .wr_en(fifo_wr_en),.din  (fifo_din),
        .rd_en(fifo_rd_en),.dout (fifo_dout),
        .full (fifo_full), .empty(fifo_empty),
        .count(fifo_count)
    );

    // ── Latch first quote from FIFO output ─────────────────────────────────
    // We latch from fifo_dout (post-FIFO) rather than quote_out (pre-FIFO)
    // This confirms data survives the FIFO write+read round trip
    reg        quote_received;
    reg [3:0]  disp_sym;
    reg [19:0] disp_bid;

    // One-cycle delayed rd_en — fifo_dout is registered so data
    // arrives one cycle AFTER rd_en fires. Latch on the delayed pulse.
    reg fifo_rd_en_d;
    always @(posedge clk or posedge rst) begin
        if (rst) fifo_rd_en_d <= 0;
        else     fifo_rd_en_d <= fifo_rd_en;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            quote_received <= 0;
            disp_sym       <= 0;
            disp_bid       <= 0;
        end else if (fifo_rd_en_d && !quote_received) begin
            // fifo_dout is now stable (one cycle after rd_en)
            // format: {4'b0, sym_id[3:0], bid[19:0], ask[19:0]}
            disp_sym <= fifo_dout[43:40];
            disp_bid <= fifo_dout[39:20];
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
            // Both held: first quote from FIFO
            disp_val = quote_received ? disp_bid[15:0] : 16'd0;
            sym_val  = quote_received ? {4'd0, disp_sym} : 8'hFF;
        end else if (!KEY[1]) begin
            // KEY[1]: add_orders_found
            disp_val = add_orders_found;
            sym_val  = 8'hEE;
        end else if (!KEY[2]) begin
            // KEY[2]: fifo_count  ← NEW: shows how many quotes in FIFO
            disp_val = fifo_full_count;
            sym_val  = 8'hCC;  // CC = FIFO full events
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
    assign LEDR[15:3] = 13'd0;
    assign LEDR[2]    = fifo_full;
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