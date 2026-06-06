// Save state shadow registers — minimal set to reduce LAB usage.
// Shadows WMADD, NMITIMEN, and MEMSEL; the save state ROM reconstructs
// the rest from WRAM/register state directly.
module savestates_regs
(
	input reset_n,
	input clk,

	input ss_busy,
	input save_en,

	input ss_reg_sel,

	input sysclkf_ce,
	input sysclkr_ce,

	input romsel_n,

	input [23:0] ca,
	input cpurd_ce,
	input cpurd_ce_n,
	input cpuwr_ce,

	input [7:0] pa,
	input pard_ce,
	input pawr_ce,

	input [7:0] di,
	output reg [7:0] ssr_do,
	output reg ssr_oe
);

wire mmio_sel    = (ca[15:10] == 6'b010000);
wire io_sel      = ~ca[22] & mmio_sel;
wire ss_io_sel   = ss_reg_sel & mmio_sel;

wire wram_sel    = (ca[15:8] == 8'h21) & (ca[7:2] == 6'b100000);

// WRAM address register ($2181-$2183)
reg [16:0] wmadd;

// NMI/timer enable ($4200)
reg        nmitimen_j;
reg  [1:0] nmitimen_hv;
reg        nmitimen_n;

// Memory speed select ($420D)
reg        memsel;

always @(posedge clk or negedge reset_n) begin
	if (~reset_n) begin
		wmadd       <= 0;
		nmitimen_j  <= 0;
		nmitimen_hv <= 0;
		nmitimen_n  <= 0;
		memsel      <= 0;
	end else begin
		if (cpuwr_ce & ~(ss_busy & save_en)) begin
			if (io_sel & (ca[9:8] == 2'd2)) begin
				case (ca[7:0])
					8'h00: begin
						nmitimen_j  <= di[0];
						nmitimen_hv <= di[5:4];
						nmitimen_n  <= di[7];
					end
					8'h0D: memsel <= di[0];
					default: ;
				endcase
			end
		end

		if (cpuwr_ce & ss_busy & ss_io_sel & (ca[9:8] == 2'd2)) begin
			case (ca[7:0])
				8'h00: begin
					nmitimen_j  <= di[0];
					nmitimen_hv <= di[5:4];
					nmitimen_n  <= di[7];
				end
				default: ;
			endcase
		end

		if (pawr_ce & ~(ss_busy & save_en)) begin
			if (pa[7:2] == 6'b100000) begin
				case (pa[1:0])
					2'd1: wmadd[ 7: 0] <= di;
					2'd2: wmadd[15: 8] <= di;
					2'd3: wmadd[   16] <= di[0];
					default: ;
				endcase
			end
		end

		if (~ss_busy) begin
			if (pard_ce | pawr_ce) begin
				if (pa == 8'h80) wmadd <= wmadd + 1'b1;
			end
		end
	end
end

always @(posedge clk) begin
	ssr_oe <= ss_reg_sel & (mmio_sel | wram_sel);
	ssr_do <= 8'h00;

	if (mmio_sel & (ca[9:8] == 2'd2)) begin
		case (ca[7:0])
			8'h00: begin
				ssr_do[0]   <= nmitimen_j;
				ssr_do[5:4] <= nmitimen_hv;
				ssr_do[7]   <= nmitimen_n;
			end
			8'h0D: ssr_do[0] <= memsel;
			default: ;
		endcase
	end

	if (wram_sel) begin
		case (ca[1:0])
			2'd1: ssr_do <= wmadd[ 7: 0];
			2'd2: ssr_do <= wmadd[15: 8];
			2'd3: ssr_do <= wmadd[   16];
			default: ;
		endcase
	end
end

endmodule
