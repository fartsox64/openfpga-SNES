// Save state controller - bridges APF (74a) and savestates module (21.47MHz).
//
// SAVE (core→APF): register-based — no FIFO needed.
//   APF at 74.25MHz reads ~20x faster than the SNES produces data.
//   Each 64-bit chunk is latched into save_buf_21 (21.47 domain) and
//   mirrored to save_buf_74a (74a domain) via a 2-stage toggle synchroniser.
//   The core is acked 3 cycles after the latch (data is stable in 74a by then).
//
// LOAD (APF→core): 4-entry DCFIFO.
//   APF pre-loads data into the FIFO, then signals savestate_load.
//   Core reads chunks as the savestates ROM requests them.
module save_state_controller (
    input wire clk_74a,
    input wire clk_mem_85_9,
    input wire clk_ppu_21_47,

    // APF bridge (74a domain)
    input wire        bridge_wr,
    input wire        bridge_rd,
    input wire        bridge_endian_little,
    input wire [31:0] bridge_addr,
    input wire [31:0] bridge_wr_data,
    output wire [31:0] save_state_bridge_read_data,

    // APF save state handshake
    input  wire savestate_load,
    output wire savestate_load_ack_s,
    output wire savestate_load_busy_s,
    output wire savestate_load_ok_s,
    output wire savestate_load_err_s,

    input  wire savestate_start,
    output wire savestate_start_ack_s,
    output wire savestate_start_busy_s,
    output wire savestate_start_ok_s,
    output wire savestate_start_err_s,

    // Triggers to savestates module
    output reg ss_save,
    output reg ss_load,

    // DDR-toggle interface (21.47 domain)
    input  wire [63:0] ss_ddr_do,   // data from core (save)
    output wire [63:0] ss_ddr_di,   // data to core (load)
    input  wire [21:3] ss_ddr_addr,
    input  wire        ss_ddr_we,
    input  wire [ 7:0] ss_ddr_be,
    input  wire        ss_ddr_req,  // toggled to request transfer
    output reg         ss_ddr_ack,  // mirrors ss_ddr_req when done

    input  wire        ss_busy
);

  // -------------------------------------------------------------------------
  // APF status CDC: 21.47 <-> 74a
  // -------------------------------------------------------------------------
  wire savestate_load_s;
  wire savestate_start_s;

  synch_3 #(.WIDTH(2)) ss_apf_in (
      {savestate_load, savestate_start},
      {savestate_load_s, savestate_start_s},
      clk_ppu_21_47
  );

  reg ss_load_ack,  ss_load_busy,  ss_load_ok,  ss_load_err;
  reg ss_start_ack, ss_start_busy, ss_start_ok, ss_start_err;

  synch_3 #(.WIDTH(8)) ss_apf_out (
      {ss_load_ack,  ss_load_busy,  ss_load_ok,  ss_load_err,
       ss_start_ack, ss_start_busy, ss_start_ok, ss_start_err},
      {savestate_load_ack_s,  savestate_load_busy_s,
       savestate_load_ok_s,   savestate_load_err_s,
       savestate_start_ack_s, savestate_start_busy_s,
       savestate_start_ok_s,  savestate_start_err_s},
      clk_74a
  );

  // -------------------------------------------------------------------------
  // SAVE path: 21.47 → 74a via toggle register
  // -------------------------------------------------------------------------

  // 21.47 domain: latched save data + toggle signal
  reg [63:0] save_buf_21;
  reg        save_tog_21;

  // Synchronise toggle into 74a domain, then latch data
  reg save_tog_74_r1, save_tog_74_r2, save_tog_74_prev;
  reg [63:0] save_buf_74;

  always @(posedge clk_74a) begin
    save_tog_74_r1   <= save_tog_21;
    save_tog_74_r2   <= save_tog_74_r1;
    save_tog_74_prev <= save_tog_74_r2;
    if (save_tog_74_r2 != save_tog_74_prev)
      save_buf_74 <= save_buf_21;   // sample after toggle stable
  end

  // Bridge read: bit 2 of address selects upper or lower 32 bits
  assign save_state_bridge_read_data =
      bridge_addr[2] ? save_buf_74[63:32] : save_buf_74[31:0];

  // -------------------------------------------------------------------------
  // LOAD path: APF → 4-entry DCFIFO → core
  // -------------------------------------------------------------------------
  wire        fifo_load_empty;
  reg         fifo_load_rdreq;
  wire [63:0] fifo_load_q;
  reg         fifo_load_clr;

  // Byte-swap: APF writes big-endian 32-bit words; reassemble to 64-bit LE
  assign ss_ddr_di = {
    fifo_load_q[39:32], fifo_load_q[47:40],
    fifo_load_q[55:48], fifo_load_q[63:56],
    fifo_load_q[ 7: 0], fifo_load_q[15: 8],
    fifo_load_q[23:16], fifo_load_q[31:24]
  };

  dcfifo_mixed_widths fifo_load (
      .data    (bridge_wr_data),
      .rdclk   (clk_ppu_21_47),
      .rdreq   (fifo_load_rdreq),
      .wrclk   (clk_74a),
      .wrreq   (bridge_wr && bridge_addr[31:28] == 4'h4),
      .q       (fifo_load_q),
      .rdempty (fifo_load_empty),
      .aclr    (fifo_load_clr)
  );
  defparam fifo_load.intended_device_family = "Cyclone V",
           fifo_load.lpm_numwords           = 4,
           fifo_load.lpm_showahead          = "OFF",
           fifo_load.lpm_type               = "dcfifo_mixed_widths",
           fifo_load.lpm_width              = 32,
           fifo_load.lpm_widthu             = 2,
           fifo_load.lpm_widthu_r           = 1,
           fifo_load.lpm_width_r            = 64,
           fifo_load.overflow_checking      = "OFF",
           fifo_load.rdsync_delaypipe       = 5,
           fifo_load.underflow_checking     = "ON",
           fifo_load.use_eab                = "ON",
           fifo_load.wrsync_delaypipe       = 5,
           fifo_load.write_aclr_synch       = "ON";

  // -------------------------------------------------------------------------
  // 21.47 domain state machine
  // -------------------------------------------------------------------------
  localparam IDLE         = 3'd0;
  localparam SAVE_BUSY    = 3'd1;
  localparam SAVE_WAIT    = 3'd2;
  localparam LOAD_STREAM  = 3'd3;
  localparam LOAD_DONE    = 3'd4;

  reg [2:0]  state;
  reg [1:0]  save_ack_delay;    // 3-cycle delay before acking core (CDC settling)
  reg        save_ack_pending;

  reg  prev_start_s, prev_load_s, prev_ss_busy;
  reg  ddr_req_prev;
  reg  pending_save, pending_load;
  reg  save_state_loading, save_state_load_req;

  always @(posedge clk_ppu_21_47) begin
    prev_start_s  <= savestate_start_s;
    prev_load_s   <= savestate_load_s;
    prev_ss_busy  <= ss_busy;
    ddr_req_prev  <= ss_ddr_req;

    ss_save          <= 0;
    ss_load          <= 0;
    fifo_load_rdreq  <= 0;
    fifo_load_clr    <= 0;

    // Detect ddr_req edge
    if (ss_ddr_req != ddr_req_prev) begin
      if (ss_ddr_we) pending_save <= 1;
      else           pending_load <= 1;
    end

    // Auto-start load when FIFO has data
    if (~fifo_load_empty && ~save_state_loading) begin
      save_state_loading <= 1;
      ss_load            <= 1;
      state              <= LOAD_STREAM;
    end

    // APF requests save
    if (savestate_start_s && ~prev_start_s) begin
      state        <= SAVE_BUSY;
      ss_start_ack <= 1;
      ss_start_ok  <= 0;
      ss_start_err <= 0;
      ss_load_ok   <= 0;
      ss_load_err  <= 0;
      ss_save      <= 1;
    end

    // APF acknowledges load complete
    if (savestate_load_s && ~prev_load_s) begin
      save_state_load_req <= 1;
      ss_load_ack         <= 1;
      ss_load_ok          <= 0;
      ss_load_err         <= 0;
      ss_start_ok         <= 0;
      ss_start_err        <= 0;
    end

    // 3-cycle ack delay for save path CDC settling
    if (save_ack_pending) begin
      if (save_ack_delay == 0) begin
        ss_ddr_ack       <= ss_ddr_req;
        save_ack_pending <= 0;
      end else begin
        save_ack_delay <= save_ack_delay - 1'b1;
      end
    end

    case (state)
      SAVE_BUSY: begin
        ss_start_ack  <= 0;
        ss_start_busy <= 1;
        if (pending_save) begin
          save_buf_21      <= ss_ddr_do;
          save_tog_21      <= ~save_tog_21;
          pending_save     <= 0;
          save_ack_delay   <= 2'd2;   // 3 cycles total (2 more after this one)
          save_ack_pending <= 1;
          ss_start_busy    <= 0;
          ss_start_ok      <= 1;
          state            <= SAVE_WAIT;
        end
      end

      SAVE_WAIT: begin
        if (pending_save && ~save_ack_pending) begin
          save_buf_21      <= ss_ddr_do;
          save_tog_21      <= ~save_tog_21;
          pending_save     <= 0;
          save_ack_delay   <= 2'd2;
          save_ack_pending <= 1;
        end
        if (prev_ss_busy && ~ss_busy)
          state <= IDLE;
      end

      LOAD_STREAM: begin
        if (prev_ss_busy && ~ss_busy) begin
          state <= LOAD_DONE;
        end else if (pending_load && ~fifo_load_empty) begin
          fifo_load_rdreq <= 1;
          pending_load    <= 0;
          ss_ddr_ack      <= ss_ddr_req;
        end
      end

      LOAD_DONE: begin
        if (save_state_load_req) begin
          save_state_load_req <= 0;
          save_state_loading  <= 0;
          fifo_load_clr       <= 1;
          ss_load_busy        <= 0;
          ss_load_ok          <= 1;
          state               <= IDLE;
        end
      end

      default: begin
        ss_start_ack  <= 0;
        ss_start_busy <= 0;
        ss_load_busy  <= 0;
      end
    endcase
  end

endmodule
