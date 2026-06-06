// Save state SA1 stub — SA1 chip save state not yet supported.
// Ports match what savestates.sv expects; all outputs are driven low.
module savestates_map
(
	input             reset_n,
	input             clk,

	input             ss_busy,
	input             save_en,

	input             ss_reg_sel,

	input             sysclkf_ce,
	input             sysclkr_ce,

	input      [23:0] ca,
	input             cpurd_n,
	input             cpuwr_n,
	input             cpuwr_ce,

	input       [7:0] pa,
	input             pard_n,
	input             pawr_n,

	input       [7:0] di,

	input             sa1_active,

	input      [23:0] sa1_a,
	input             sa1_rd_n,
	input             sa1_wr_n,
	input       [7:0] sa1_di,
	input             sa1_sa1_romsel,
	input             sa1_sns_romsel,

	output            map_active,

	output     [15:0] rom_addr,
	output            rom_ovr,

	output      [7:0] ss_do,
	output            ss_oe
);

assign map_active = 1'b0;
assign rom_addr   = 16'h0;
assign rom_ovr    = 1'b0;
assign ss_do      = 8'h0;
assign ss_oe      = 1'b0;

endmodule
