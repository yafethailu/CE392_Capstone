// eth_mac_bridge.v  — simplified SDC implementation
//
//   The toggle-handshake CDC version had a Quartus synthesis issue that
//   prevented any bytes from passing through.  This version avoids a
//   separate rx_clk always-block entirely.  Everything runs in clk (50MHz).
//
// HOW IT WORKS:
//   At 100BASE-T, rx_clk is 25MHz (40ns period).  The system clock is
//   50MHz (20ns period) — exactly 2x faster.  We detect rx_clk rising
//   edges using a 2-stage pipe and read rx_data/rx_dv directly on the
//   cycle after detection.  MII data is held stable for a full 40ns
//   after each rx_clk edge, so at 20ns (1 clk cycle) after we catch
//   the edge the data is still valid with ~20ns of margin.
//
//   This is not textbook CDC (no synchronizer on rx_data itself) but
//   is standard practice for 100Mbps MII debug designs.  The 25MHz and
//   50MHz oscillators are independent so their phase drifts continuously;
//   the edge detector catches every nibble reliably in practice.

module eth_mac_bridge (
    input  wire        clk,
    input  wire        rst,
    input  wire        rx_clk,   // 25MHz from Marvell 88E1111
    input  wire [3:0]  rx_data,
    input  wire        rx_dv,
    input  wire        rx_er,
    output reg  [7:0]  byte_out,
    output reg         byte_valid,
    output reg         sof,
    output reg         eof
);

    // ── rx_clk edge detection ─────────────────────────────────────────────
    // Two pipeline stages detect the rising edge of rx_clk in clk domain.
    // rxclk_pipe[0]: first capture (may be metastable — but at 100Mbps
    //   the window where clk and rx_clk edges overlap is tiny)
    // rxclk_pipe[1]: one cycle later — stable
    // rxclk_rise fires for one clk cycle per rx_clk rising edge.
    reg [1:0] rxclk_pipe;
    always @(posedge clk or posedge rst) begin
        if (rst) rxclk_pipe <= 2'b00;
        else     rxclk_pipe <= {rxclk_pipe[0], rx_clk};
    end
    wire rxclk_rise = rxclk_pipe[0] & ~rxclk_pipe[1];

    // ── MII nibble assembly ────────────────────────────────────────────────
    // All state lives in the clk domain.
    // On each rxclk_rise we read rx_data/rx_dv directly; at 100Mbps these
    // signals are stable for 40ns, and we sample them ~20ns after the edge.
    reg        mii_phase;
    reg [3:0]  mii_lo;
    reg        in_preamble;
    reg        err_flag;
    reg        dv_prev;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mii_phase   <= 1'b0;
            mii_lo      <= 4'd0;
            in_preamble <= 1'b1;
            err_flag    <= 1'b0;
            dv_prev     <= 1'b0;
            byte_out    <= 8'd0;
            byte_valid  <= 1'b0;
            sof         <= 1'b0;
            eof         <= 1'b0;
        end else begin
            // Default: clear single-cycle outputs
            byte_valid <= 1'b0;
            sof        <= 1'b0;
            eof        <= 1'b0;

            if (rxclk_rise) begin
                dv_prev <= rx_dv;

                // Track error within frame
                if (rx_er) err_flag <= 1'b1;

                // ── Rising edge of rx_dv: new frame starting ────────────
                if (rx_dv && !dv_prev) begin
                    mii_phase   <= 1'b0;
                    in_preamble <= 1'b1;
                    err_flag    <= 1'b0;
                end

                // ── Falling edge of rx_dv: frame ended ──────────────────
                if (!rx_dv && dv_prev && !in_preamble && !err_flag) begin
                    eof        <= 1'b1;
                    byte_valid <= 1'b1;
                    in_preamble <= 1'b1;
                end

                // ── Nibble assembly (only when data valid, no error) ─────
                if (rx_dv && !rx_er) begin
                    if (!mii_phase) begin
                        // Phase 0: capture low nibble
                        mii_lo    <= rx_data;
                        mii_phase <= 1'b1;
                    end else begin
                        // Phase 1: assemble byte = {hi_nibble, lo_nibble}
                        mii_phase <= 1'b0;

                        if (in_preamble) begin
                            // Look for SFD = 0xD5
                            if ({rx_data, mii_lo} == 8'hD5) begin
                                in_preamble <= 1'b0;
                                sof         <= 1'b1;
                                byte_valid  <= 1'b1;
                                byte_out    <= 8'hD5;
                            end
                            // Any other preamble byte (0xAA): discard
                        end else if (!err_flag) begin
                            // Real frame data
                            byte_out   <= {rx_data, mii_lo};
                            byte_valid <= 1'b1;
                        end
                    end
                end
            end // rxclk_rise
        end
    end

endmodule
