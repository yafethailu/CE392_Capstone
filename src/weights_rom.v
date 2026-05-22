// weights_rom.v
// -----------------------------------------------------------------------------
// symbol weight lookup. Weights are normalized so that they sum to
// 2^14 = 16384, matching SCALE_SHIFT=14 in index_engine_core.
//
// SYMBOLS ARE 0 indexed
//   AAPL=0, TSLA=1, GOOGL=2, NFLX=3, NVDA=4,
//   MRVL=5, AMD=6,  QCOM=7,  MSFT=8, PLTR=9.
//
// Sanity:
//   5015 + 1402 + 1384 + 822 + 1955 + 274 + 639 + 457 + 4298 + 138 = 16384
// -----------------------------------------------------------------------------

module weights_rom (
    input  wire [15:0] symbol_id,
    output reg  [15:0] weight
);
    always @(*) begin
        case (symbol_id)
            16'd0: weight = 16'd5015; // AAPL
            16'd1: weight = 16'd1402; // TSLA
            16'd2: weight = 16'd1384; // GOOGL
            16'd3: weight = 16'd822;  // NFLX
            16'd4: weight = 16'd1955; // NVDA
            16'd5: weight = 16'd274;  // MRVL
            16'd6: weight = 16'd639;  // AMD
            16'd7: weight = 16'd457;  // QCOM
            16'd8: weight = 16'd4298; // MSFT
            16'd9: weight = 16'd138;  // PLTR
            default: weight = 16'd0;
        endcase
    end
endmodule
