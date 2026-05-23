// m1_eth_top.v
// -----------------------------------------------------------------------------
// Ethernet replacement for m1_top.v.
//
// Same downstream interface as m1_top.v (FIFO + debug taps) so this is a
// drop-in replacement wherever m1_top was previously instantiated. The
// difference is the data source: Ethernet RX via eth_mac_bridge +
// xdp_eth_parser instead of UART RX + quote_record_assembler.
//
// Data flow:
//   ENET0 MII pins --> eth_mac_bridge --> xdp_eth_parser --> quote_eth_adapter
//                                                                  |
//                                                              48-bit record
//                                                                  v
//                                                              burst_fifo
//                                                                  |
//                                                            (FIFO read side
//                                                             exposed to caller)
//
// Caller wires:
//   - ENET0_RX_CLK, ENET0_RX_DV, ENET0_RXD, ENET0_RX_ER (from board)
//   - ENET0_RST_N, ENET0_MDC                            (to board)
//   - fifo_rd_en_i / fifo_empty_o / fifo_dout_o         (downstream consumer)
//   - debug outputs                                      (HEX/LED display)
// -----------------------------------------------------------------------------

module m1_eth_top (
    input  wire        clk,
    input  wire        rst,

    // ───────── Ethernet 0 MII (Marvell 88E1111, 100BASE-T) ─────────
    input  wire        ENET0_RX_CLK,
    input  wire        ENET0_RX_DV,
    input  wire [3:0]  ENET0_RXD,
    input  wire        ENET0_RX_ER,
    output wire        ENET0_RST_N,
    output wire        ENET0_MDC,

    // ───────── Downstream FIFO interface ─────────
    input  wire        fifo_rd_en_i,
    output wire        fifo_empty_o,
    output wire        fifo_full_o,
    output wire [8:0]  fifo_count_o,
    output wire [47:0] fifo_dout_o,

    // ───────── Debug / observability ─────────
    output reg  [7:0]  last_byte_o,          // last Ethernet byte (HEX-friendly)
    output wire [15:0] xdp_pkts_parsed_o,    // from parser
    output wire [15:0] add_orders_found_o,   // from parser (tracked syms)
    output wire [15:0] all_add_orders_o,     // from parser (any sym)
    output wire [15:0] quotes_emitted_o,     // from parser
    output wire [15:0] records_passed_o,     // from adapter
    output wire [15:0] records_dropped_o,    // from adapter (should stay 0)
    output reg  [15:0] rec_count_o           // FIFO write count (synonym of records_passed)
);

    // Hold PHY out of reset; MDC idle.
    assign ENET0_RST_N = 1'b1;
    assign ENET0_MDC   = 1'b0;

    // ─────────────────────────────────────────────────────────────────────
    // 1. MII byte stream from the PHY
    // ─────────────────────────────────────────────────────────────────────
    wire [7:0] eth_byte;
    wire       eth_valid;
    wire       eth_sof;
    wire       eth_eof;

    eth_mac_bridge u_bridge (
        .clk       (clk),
        .rst       (rst),
        .rx_clk    (ENET0_RX_CLK),
        .rx_data   (ENET0_RXD),
        .rx_dv     (ENET0_RX_DV),
        .rx_er     (ENET0_RX_ER),
        .byte_out  (eth_byte),
        .byte_valid(eth_valid),
        .sof       (eth_sof),
        .eof       (eth_eof)
    );

    // ─────────────────────────────────────────────────────────────────────
    // 2. XDP parser (Ethernet/VLAN/IP/UDP/XDP → quote_out)
    // ─────────────────────────────────────────────────────────────────────
    wire [3:0]  add_local_id_unused;
    wire        add_side_unused;
    wire [19:0] add_price_unused;
    wire        add_order_valid_unused;
    wire [43:0] parser_quote_out;
    wire        parser_quote_valid;
    wire [15:0] del_orders_unused;

    xdp_eth_parser #(
        .ORDER_BITS (11),
        .SYM_COUNT  (10),
        .PRICE_WIDTH(20)
    ) u_parser (
        .clk             (clk),
        .rst             (rst),
        .byte_in         (eth_byte),
        .byte_valid      (eth_valid),
        .sof             (eth_sof),
        .eof             (eth_eof),
        .add_local_id    (add_local_id_unused),
        .add_side        (add_side_unused),
        .add_price_cents (add_price_unused),
        .add_order_valid (add_order_valid_unused),
        .quote_out       (parser_quote_out),
        .quote_valid     (parser_quote_valid),
        .xdp_pkts_parsed (xdp_pkts_parsed_o),
        .add_orders_found(add_orders_found_o),
        .del_orders_found(del_orders_unused),
        .all_add_orders  (all_add_orders_o),
        .quotes_emitted  (quotes_emitted_o)
    );

    // ─────────────────────────────────────────────────────────────────────
    // 3. Adapter: 44-bit parser quote → 48-bit FIFO record
    // ─────────────────────────────────────────────────────────────────────
    wire [47:0] adapter_record;
    wire        adapter_valid;

    quote_eth_adapter u_adapter (
        .clk            (clk),
        .rst            (rst),
        .quote_in       (parser_quote_out),
        .quote_valid    (parser_quote_valid),
        .fifo_full      (fifo_full_o),
        .record_out     (adapter_record),
        .record_valid   (adapter_valid),
        .records_passed (records_passed_o),
        .records_dropped(records_dropped_o)
    );

    // ─────────────────────────────────────────────────────────────────────
    // 4. Burst FIFO (records, not bytes) — same 256-deep × 48-bit as UART path
    // ─────────────────────────────────────────────────────────────────────
    burst_fifo #(
        .DATA_WIDTH(48),
        .DEPTH     (256)
    ) u_burst_fifo (
        .clk  (clk),
        .rst  (rst),
        .wr_en(adapter_valid),
        .din  (adapter_record),
        .rd_en(fifo_rd_en_i),
        .dout (fifo_dout_o),
        .full (fifo_full_o),
        .empty(fifo_empty_o),
        .count(fifo_count_o)
    );

    // ─────────────────────────────────────────────────────────────────────
    // 5. Debug bookkeeping
    // ─────────────────────────────────────────────────────────────────────
    always @(posedge clk) begin
        if (rst) begin
            last_byte_o <= 8'd0;
            rec_count_o <= 16'd0;
        end else begin
            if (eth_valid)     last_byte_o <= eth_byte;
            if (adapter_valid) rec_count_o <= rec_count_o + 16'd1;
        end
    end

endmodule