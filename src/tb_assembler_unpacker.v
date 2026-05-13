// tb_assembler_unpacker.v   (path B)
// -----------------------------------------------------------------------------
// Stream bytes into quote_record_assembler, route the assembled record to
// quote_record_unpacker, check (sym, bid, ask) match what we sent.
//
// Cases:
//   1) clean back-to-back 7-byte frames
//   2) garbage bytes before the very first 0xAA (bring-up resync)
//   3) idle gaps between bytes (mimics UART pacing)
//   4) max-value record (sym=0xF, bid=0xFFFFF, ask=0xFFFFF)
//
// Run:
//   iverilog -g2012 -o tb tb_assembler_unpacker.v \
//            quote_record_assembler.v quote_record_unpacker.v
//   vvp tb
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_assembler_unpacker;
    reg         clk = 0;
    reg         rst = 1;
    reg  [7:0]  byte_in;
    reg         byte_valid;

    wire [47:0] record_out;
    wire        record_valid;
    wire [1:0]  asm_state;
    wire [3:0]  asm_byte_count;
    wire [15:0] sync_lost;

    wire [3:0]  symbol_id;
    wire [19:0] bid_q9;
    wire [19:0] ask_q9;

    integer errors = 0;

    always #5 clk = ~clk;   // 100 MHz tb clock

    quote_record_assembler #(
        .RECORD_WIDTH (48),
        .PAYLOAD_BYTES(6),
        .SYNC_BYTE    (8'hAA)
    ) u_asm (
        .clk(clk), .rst(rst),
        .byte_in(byte_in), .byte_valid(byte_valid),
        .record_out(record_out), .record_valid(record_valid),
        .state_o(asm_state),
        .byte_count_o(asm_byte_count),
        .sync_lost_count_o(sync_lost)
    );

    quote_record_unpacker u_unp (
        .record_in(record_out),
        .symbol_id(symbol_id),
        .bid_q9   (bid_q9),
        .ask_q9   (ask_q9)
    );

    // Send one byte: drive byte_valid high for one cycle, then idle a few.
    task automatic send_byte(input [7:0] b);
        begin
            @(posedge clk);
            byte_in    <= b;
            byte_valid <= 1'b1;
            @(posedge clk);
            byte_valid <= 1'b0;
            repeat (3) @(posedge clk);   // mimic UART inter-byte gap
        end
    endtask

    // Send one 7-byte frame: 0xAA + 6 payload bytes packed from sym/bid/ask.
    task automatic send_record(input [3:0]  sym,
                               input [19:0] bid,
                               input [19:0] ask);
        reg [47:0] payload48;
        begin
            payload48 = {4'b0000, sym, bid, ask};
            send_byte(8'hAA);
            send_byte(payload48[47:40]);
            send_byte(payload48[39:32]);
            send_byte(payload48[31:24]);
            send_byte(payload48[23:16]);
            send_byte(payload48[15: 8]);
            send_byte(payload48[ 7: 0]);
        end
    endtask

    task automatic check_record(input [3:0]  exp_sym,
                                input [19:0] exp_bid,
                                input [19:0] exp_ask);
        begin
            // wait for the 1-cycle record_valid pulse
            while (!record_valid) @(posedge clk);
            if (symbol_id !== exp_sym || bid_q9 !== exp_bid || ask_q9 !== exp_ask) begin
                $display("FAIL: got sym=%0d bid=%0d ask=%0d (exp %0d/%0d/%0d)",
                         symbol_id, bid_q9, ask_q9, exp_sym, exp_bid, exp_ask);
                errors = errors + 1;
            end else begin
                $display(" OK : sym=%0d bid=%0d ask=%0d", symbol_id, bid_q9, ask_q9);
            end
            // Step past the current pulse so the next check_record waits
            // for a NEW record_valid, not the same one.
            @(posedge clk);
        end
    endtask

    initial begin
        byte_in    = 8'h00;
        byte_valid = 1'b0;
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);

        // ---- 1) Garbage before first sync (resync test) ----
        send_byte(8'h12);
        send_byte(8'h34);
        send_byte(8'h00);    // assembler should still be in HUNT_SYNC

        // ---- 2) AAPL @ q9 98918 / 98929 ----
        fork
            send_record(4'd1, 20'd98918, 20'd98929);
            check_record(4'd1, 20'd98918, 20'd98929);
        join

        // ---- 3) NVDA @ q9 435200 / 435205 ----
        fork
            send_record(4'd5, 20'd435200, 20'd435205);
            check_record(4'd5, 20'd435200, 20'd435205);
        join

        // ---- 4) Max-value field ----
        fork
            send_record(4'hF, 20'hFFFFF, 20'hFFFFF);
            check_record(4'hF, 20'hFFFFF, 20'hFFFFF);
        join

        // ---- 5) Two records back-to-back, no gap ----
        fork
            begin
                send_record(4'd2, 20'd11111, 20'd22222);
                send_record(4'd3, 20'd33333, 20'd44444);
            end
            begin
                check_record(4'd2, 20'd11111, 20'd22222);
                check_record(4'd3, 20'd33333, 20'd44444);
            end
        join

        repeat (10) @(posedge clk);

        if (errors == 0) $display("\nALL TESTS PASSED");
        else             $display("\n%0d TEST(S) FAILED", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule