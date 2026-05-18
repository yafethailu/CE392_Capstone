// threshold_comparator.v
// Compares absolute velocity and deviation against configurable thresholds.
// Asserts alert flags one cycle after valid_in.

module threshold_comparator #(
    parameter DATA_WIDTH = 64
)(
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         valid_in,
    input  wire signed [DATA_WIDTH-1:0] velocity_in,
    input  wire signed [DATA_WIDTH-1:0] deviation_in,
    input  wire        [DATA_WIDTH-1:0] threshold_v,   // velocity threshold  Tv
    input  wire        [DATA_WIDTH-1:0] threshold_d,   // deviation threshold Td

    output reg                          alert_velocity,
    output reg                          alert_deviation,
    output reg                          alert_any
);
    // Absolute values
    wire signed [DATA_WIDTH-1:0] abs_vel = velocity_in[DATA_WIDTH-1]  ? (-velocity_in)  : velocity_in;
    wire signed [DATA_WIDTH-1:0] abs_dev = deviation_in[DATA_WIDTH-1] ? (-deviation_in) : deviation_in;

    wire vel_trip = ($signed(abs_vel) > $signed(threshold_v));
    wire dev_trip = ($signed(abs_dev) > $signed(threshold_d));

    always @(posedge clk) begin
        if (rst) begin
            alert_velocity  <= 1'b0;
            alert_deviation <= 1'b0;
            alert_any       <= 1'b0;
        end else if (valid_in) begin
            alert_velocity  <= vel_trip;
            alert_deviation <= dev_trip;
            alert_any       <= vel_trip | dev_trip;
        end
    end
endmodule