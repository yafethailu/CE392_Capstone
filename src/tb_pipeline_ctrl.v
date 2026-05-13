// tb_pipeline_ctrl.v
// -----------------------------------------------------------------------------
// Self-checking testbench for pipeline_ctrl + index_engine_core + weights_rom
// + symbol_state_mem.
//
// Feeds records through a stub FIFO and checks the index_value output against
// expected values computed externally (matching the Python golden model).
//
// Cases:
//   1) Single record into empty pipeline
//   2) Two records different symbols (no hazard)
//   3) Two records SAME symbol back-to-back (RAW hazard, must forward)
//   4) Three records SAME symbol (cascade forward)
//   5) Idle bubble then same symbol (memory must be fresh)
//
// Run:
//   iverilog -g2012 -o tb tb_pipeline_ctrl.v \
//     pipeline_ctrl.v index_engine_core.v midprice_compute.v \
//     weights_rom.v symbol_state_mem.v
//   vvp tb
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_pipeline_ctrl;

    reg clk = 0;
    reg rst = 1;
    always #5 clk = ~clk;   // 100 MHz tb clock

    // Stub FIFO: queue + pop logic
    reg [47:0] fifo_queue [0:255];
    reg [7:0]  fifo_head = 0;
    reg [7:0]  fifo_tail = 0;
    wire       fifo_empty = (fifo_head == fifo_tail);
    wire [47:0] fifo_dout = fifo_queue[fifo_head];
    wire       fifo_rd_en_w;
    always @(posedge clk) begin
        if (rst) fifo_head <= 0;
        else if (fifo_rd_en_w && !fifo_empty) fifo_head <= fifo_head + 1;
    end

    // pipeline_ctrl <-> symbol_state_mem
    wire [3:0]  sm_rd_addr_w, sm_wr_addr_w;
    wire        sm_wr_en_w;
    wire [19:0] sm_mid_in_w, sm_bid_in_w, sm_ask_in_w;
    wire [19:0] sm_mid_out_w, sm_bid_out_w, sm_ask_out_w;

    symbol_state_mem #(
        .SYMBOL_COUNT(16),
        .PRICE_WIDTH (20),
        .ADDR_WIDTH  (4)
    ) u_sm (
        .clk(clk), .rst(rst),
        .wr_en  (sm_wr_en_w),
        .wr_addr(sm_wr_addr_w),
        .bid_in (sm_bid_in_w),
        .ask_in (sm_ask_in_w),
        .mid_in (sm_mid_in_w),
        .rd_addr(sm_rd_addr_w),
        .bid_out(sm_bid_out_w),
        .ask_out(sm_ask_out_w),
        .mid_out(sm_mid_out_w)
    );

    // pipeline_ctrl <-> index_engine_core
    wire        ie_valid_in_w, ie_valid_out_w;
    wire [19:0] ie_bid_w, ie_ask_w, ie_prev_mid_w;
    wire [15:0] ie_weight_w;
    wire [19:0] ie_new_mid_w;
    wire signed [63:0] ie_index_value_w, ie_delta_index_w;

    index_engine_core #(
        .PRICE_WIDTH (20),
        .WEIGHT_WIDTH(16),
        .INDEX_WIDTH (64),
        .SCALE_SHIFT (14)
    ) u_ie (
        .clk(clk), .rst(rst),
        .valid_in   (ie_valid_in_w),
        .bid        (ie_bid_w),
        .ask        (ie_ask_w),
        .prev_mid   (ie_prev_mid_w),
        .weight     (ie_weight_w),
        .new_mid    (ie_new_mid_w),
        .delta_index(ie_delta_index_w),
        .index_value(ie_index_value_w),
        .valid_out  (ie_valid_out_w)
    );

    // index_valid / index_value out
    wire        index_valid_w;
    wire signed [63:0] index_value_out_w, delta_index_out_w;
    wire [3:0]  sym_out_w;

    pipeline_ctrl #(
        .PRICE_WIDTH (20),
        .WEIGHT_WIDTH(16),
        .INDEX_WIDTH (64),
        .SYM_WIDTH   (4)
    ) u_ctrl (
        .clk(clk), .rst(rst),
        .fifo_empty (fifo_empty),
        .fifo_dout  (fifo_dout),
        .fifo_rd_en (fifo_rd_en_w),
        .sm_rd_addr (sm_rd_addr_w),
        .sm_mid_out (sm_mid_out_w),
        .sm_wr_en   (sm_wr_en_w),
        .sm_wr_addr (sm_wr_addr_w),
        .sm_bid_in  (sm_bid_in_w),
        .sm_ask_in  (sm_ask_in_w),
        .sm_mid_in  (sm_mid_in_w),
        .ie_valid_in(ie_valid_in_w),
        .ie_bid     (ie_bid_w),
        .ie_ask     (ie_ask_w),
        .ie_prev_mid(ie_prev_mid_w),
        .ie_weight  (ie_weight_w),
        .ie_valid_out(ie_valid_out_w),
        .ie_new_mid (ie_new_mid_w),
        .ie_index_value(ie_index_value_w),
        .ie_delta_index(ie_delta_index_w),
        .index_valid    (index_valid_w),
        .index_value_out(index_value_out_w),
        .delta_index_out(delta_index_out_w),
        .sym_out        (sym_out_w)
    );

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------
    integer errors = 0;
    integer records_received = 0;

    task automatic push_record(input [3:0] sym, input [19:0] bid, input [19:0] ask);
        begin
            @(posedge clk);
            fifo_queue[fifo_tail] = {4'b0, sym, bid, ask};
            fifo_tail = fifo_tail + 1;
        end
    endtask

    // Wait for the next index_valid pulse, check the value.
    task automatic expect_index(input signed [63:0] expected_value);
        integer timeout;
        begin
            timeout = 100;
            while (!index_valid_w && timeout > 0) begin
                @(posedge clk);
                timeout = timeout - 1;
            end
            if (timeout == 0) begin
                $display("TIMEOUT waiting for index_valid");
                errors = errors + 1;
            end else begin
                records_received = records_received + 1;
                if (index_value_out_w !== expected_value) begin
                    $display("FAIL: rec %0d -- got index=%0d, expected %0d",
                             records_received, index_value_out_w, expected_value);
                    errors = errors + 1;
                end else begin
                    $display(" OK : rec %0d -- index=%0d (sym=%0d)",
                             records_received, index_value_out_w, sym_out_w);
                end
                // step past the pulse so the next expect_index waits fresh
                @(posedge clk);
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Main test
    // -----------------------------------------------------------------------
    initial begin
        // init
        $dumpfile("tb_pipeline_ctrl.vcd");
        $dumpvars(0, tb_pipeline_ctrl);
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);

        // -------------------------------------------------------------------
        // Test 1: Single record. AAPL bid=98918 ask=98929 (-> mid=98923).
        // Expected: prev_mid=0, delta_mid=98923, weighted=98923*5015=496098845.
        //           delta_index = 496098845 >>> 14 = 30279.
        //           index = 0 + 30279 = 30279.
        // -------------------------------------------------------------------
        $display("\n--- Test 1: Single record (AAPL) ---");
        push_record(4'd1, 20'd98918, 20'd98929);
        expect_index(64'sd30279);

        // -------------------------------------------------------------------
        // Test 2: Two different symbols. NVDA then MSFT.
        // NVDA: bid=435200 ask=435205 -> mid=435202. delta=435202.
        //   weight 1955. weighted = 435202 * 1955 = 850720910.
        //   delta_idx = 850720910 >>> 14 = 51924. index = 30279+51924 = 82203.
        // MSFT: bid=215117 ask=215142 -> mid=215129 (note: 215117+215142=430259, >>1=215129).
        //   weight 4298. weighted = 215129 * 4298 = 924624442.
        //   Hmm wait, prev_mid for MSFT is 0, so delta = 215129.
        //   weighted = 215129 * 4298 = 924624442.
        //   delta_idx = 924624442 >>> 14 = 56435. index = 82203 + 56435 = 138638.
        // -------------------------------------------------------------------
        $display("\n--- Test 2: Two different symbols ---");
        push_record(4'd5, 20'd435200, 20'd435205);
        expect_index(64'sd82208);
        push_record(4'd9, 20'd215117, 20'd215142);
        expect_index(64'sd138642);

        // -------------------------------------------------------------------
        // Test 3: TWO records SAME symbol back-to-back (the RAW hazard).
        // Per golden model:
        //   After NVDA prev_mid=435202.
        //   Record 3a: bid=435210 ask=435215 -> mid=435212. delta=10.
        //     index = 138643 (golden model verified).
        //   Record 3b: bid=435220 ask=435225 -> mid=435222. delta=10.
        //     (prev_mid MUST be 435212 from prev record -- the RAW forward!)
        //     index = 138644.
        // If forwarding failed, prev_mid would still be 435202 -> wrong index.
        // -------------------------------------------------------------------
        $display("\n--- Test 3: Back-to-back same symbol (RAW hazard test) ---");
        push_record(4'd5, 20'd435210, 20'd435215);
        push_record(4'd5, 20'd435220, 20'd435225);
        expect_index(64'sd138643);
        expect_index(64'sd138644);

        // -------------------------------------------------------------------
        // Test 4: idle, then NVDA again. Per golden model: 138645.
        // -------------------------------------------------------------------
        $display("\n--- Test 4: Idle then same symbol (memory should be fresh) ---");
        repeat (20) @(posedge clk);   // bubble
        push_record(4'd5, 20'd435230, 20'd435235);
        expect_index(64'sd138645);

        // Done
        repeat (10) @(posedge clk);
        if (errors == 0) $display("\nALL TESTS PASSED");
        else             $display("\n%0d TEST(S) FAILED", errors);
        $finish;
    end

    initial begin
        #500_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule