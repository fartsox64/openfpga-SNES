// Game Genie stub — cheat code support removed to save LABs.
// Same interface as the original CODES module; always passes data through unchanged.
module CODES(
	input  clk,
	input  reset,
	input  enable,
	output available,
	input  [ADDR_WIDTH - 1:0] addr_in,
	input  [DATA_WIDTH - 1:0] data_in,
	input  [128:0] code,
	output genie_ovr,
	output [DATA_WIDTH - 1:0] genie_data
);
parameter ADDR_WIDTH = 16;
parameter DATA_WIDTH = 8;
parameter MAX_CODES  = 32;

assign available  = 1'b0;
assign genie_ovr  = 1'b0;
assign genie_data = data_in;

endmodule
