// m1_top.v   (path B)
// -----------------------------------------------------------------------------
// Milestone-1 top: UART RX -> sync-hunting record assembler (48 bits) ->
//                  burst FIFO of records.
//
// Wire format (one quote = 7 bytes):
//   [0xAA] [{4'b0, sym}] [bid hi] [bid mid] [{bid lo, ask hi nibble}]
//          [ask mid] [ask lo]
//
// Debug taps for DE2-115 bring-up:
//   last_byte_o        : last UART byte received (good for HEX/LEDR display)
//   asm_state_o        : 0 = HUNT_SYNC, 1 = COLLECT_6
//   asm_byte_count_o   : 0..5 within current payload
//   rx_byte_strobe_o   : 1-cycle pulse per UART byte
//   rec_count_o        : count of fully assembled records (mod 2^16)
//   sync_lost_count_o  : reserved for future strict framing
// -----------------------------------------------------------------------------

module market_sentinel_m1_top #(
    parameter CLK_FREQ_HZ = 50000000,
    parameter BAUD_RATE   = 115200
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        uart_rx_i,

    // Downstream consumer (M2 will hook the index pipeline here)
    input  wire        fifo_rd_en_i,
    output wire        fifo_empty_o,
    output wire        fifo_full_o,
    output wire [8:0]  fifo_count_o,
    output wire [47:0] fifo_dout_o,

    // ---- Debug / observability ----
    output reg  [7:0]  last_byte_o,
    output wire [1:0]  asm_state_o,
    output wire [3:0]  asm_byte_count_o,
    output wire        rx_byte_strobe_o,
    output reg  [15:0] rec_count_o,
    output wire [15:0] sync_lost_count_o
);
    // ---- UART RX ----
    wire [7:0] rx_byte;
    wire       rx_valid;

    uart_rx #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (BAUD_RATE)
    ) u_uart_rx (
        .clk        (clk),
        .rst        (rst),
        .rx         (uart_rx_i),
        .data_out   (rx_byte),
        .data_valid (rx_valid),
        .busy       ()
    );

    assign rx_byte_strobe_o = rx_valid;

    // ---- 48-bit record assembler with sync hunt ----
    wire [47:0] assembled_record;
    wire        assembled_valid;

    quote_record_assembler #(
        .RECORD_WIDTH (48),
        .PAYLOAD_BYTES(6),
        .SYNC_BYTE    (8'hAA)
    ) u_record_assembler (
        .clk               (clk),
        .rst               (rst),
        .byte_in           (rx_byte),
        .byte_valid        (rx_valid),
        .record_out        (assembled_record),
        .record_valid      (assembled_valid),
        .state_o           (asm_state_o),
        .byte_count_o      (asm_byte_count_o),
        .sync_lost_count_o (sync_lost_count_o)
    );

    // ---- Burst FIFO (records, not bytes) ----
    burst_fifo #(
        .DATA_WIDTH(48),
        .DEPTH     (256)
    ) u_burst_fifo (
        .clk   (clk),
        .rst   (rst),
        .wr_en (assembled_valid),
        .din   (assembled_record),
        .rd_en (fifo_rd_en_i),
        .dout  (fifo_dout_o),
        .full  (fifo_full_o),
        .empty (fifo_empty_o),
        .count (fifo_count_o)
    );

    // ---- Debug bookkeeping ----
    always @(posedge clk) begin
        if (rst) begin
            last_byte_o <= 8'd0;
            rec_count_o <= 16'd0;
        end else begin
            if (rx_valid)        last_byte_o <= rx_byte;
            if (assembled_valid) rec_count_o <= rec_count_o + 16'd1;
        end
    end
endmodule