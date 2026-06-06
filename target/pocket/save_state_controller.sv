// Save state controller bridging APF (74a clock domain) and
// the savestates module (21.47MHz PPU clock domain).
//
// The savestates module uses a DDR-style toggle handshake:
//   ss_ddr_req is toggled to start a transfer
//   ss_ddr_ack mirrors ss_ddr_req when the transfer is complete
//   ss_ddr_busy = (ss_ddr_req != ss_ddr_ack)
//
// For save (core→host): savestates writes ss_ddr_do and sets ss_ddr_we=1.
// For load (host→core): savestates reads ss_ddr_di and sets ss_ddr_we=0.
//
// Data flows through FIFOs that cross the clock domain boundary.
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

    // APF save state handshake (74a domain)
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

    // Control signals to savestates module (21.47MHz domain)
    output reg ss_save,
    output reg ss_load,

    // DDR-toggle interface to savestates module (21.47MHz domain)
    input  wire [63:0] ss_ddr_do,   // data from core being saved
    output wire [63:0] ss_ddr_di,   // data to core being loaded
    input  wire [21:3] ss_ddr_addr, // address (slot-encoded, informational)
    input  wire        ss_ddr_we,   // 1=write(save), 0=read(load)
    input  wire [ 7:0] ss_ddr_be,   // byte enables (informational)
    input  wire        ss_ddr_req,  // toggled when transfer requested
    output reg         ss_ddr_ack,  // mirrors ss_ddr_req when transfer done

    input  wire        ss_busy      // save state operation in progress
);

  // ---------------------------------------------------------------------------
  // Clock-domain crossing: APF ↔ core
  // ---------------------------------------------------------------------------
  wire savestate_load_s;
  wire savestate_start_s;

  synch_3 #(.WIDTH(2)) savestate_in (
      {savestate_load,  savestate_start},
      {savestate_load_s, savestate_start_s},
      clk_ppu_21_47
  );

  reg savestate_load_ack;
  reg savestate_load_busy;
  reg savestate_load_ok;
  reg savestate_load_err;

  reg savestate_start_ack;
  reg savestate_start_busy;
  reg savestate_start_ok;
  reg savestate_start_err;

  synch_3 #(.WIDTH(8)) savestate_out (
      {savestate_load_ack,  savestate_load_busy,  savestate_load_ok,  savestate_load_err,
       savestate_start_ack, savestate_start_busy, savestate_start_ok, savestate_start_err},
      {savestate_load_ack_s, savestate_load_busy_s, savestate_load_ok_s, savestate_load_err_s,
       savestate_start_ack_s, savestate_start_busy_s, savestate_start_ok_s, savestate_start_err_s},
      clk_74a
  );

  // ---------------------------------------------------------------------------
  // Load FIFO: host→core (32-bit wide write from 74a, 64-bit wide read in 21.47)
  // ---------------------------------------------------------------------------
  wire fifo_load_empty;
  reg  fifo_load_read_req;
  wire [63:0] fifo_load_dout;
  reg  fifo_load_clr;

  // Byte-swap 32-bit words into 64-bit little-endian order
  assign ss_ddr_di = {
    fifo_load_dout[39:32], fifo_load_dout[47:40],
    fifo_load_dout[55:48], fifo_load_dout[63:56],
    fifo_load_dout[ 7: 0], fifo_load_dout[15: 8],
    fifo_load_dout[23:16], fifo_load_dout[31:24]
  };

  dcfifo_mixed_widths fifo_load (
      .data    (bridge_wr_data),
      .rdclk   (clk_ppu_21_47),
      .rdreq   (fifo_load_read_req),
      .wrclk   (clk_74a),
      .wrreq   (bridge_wr && bridge_addr[31:28] == 4'h4),
      .q       (fifo_load_dout),
      .rdempty (fifo_load_empty),
      .aclr    (fifo_load_clr)
  );
  defparam fifo_load.intended_device_family = "Cyclone V",
           fifo_load.lpm_numwords           = 256,
           fifo_load.lpm_showahead          = "OFF",
           fifo_load.lpm_type               = "dcfifo_mixed_widths",
           fifo_load.lpm_width              = 32,
           fifo_load.lpm_widthu             = 8,
           fifo_load.lpm_widthu_r           = 7,
           fifo_load.lpm_width_r            = 64,
           fifo_load.overflow_checking      = "OFF",
           fifo_load.rdsync_delaypipe       = 5,
           fifo_load.underflow_checking     = "ON",
           fifo_load.use_eab                = "ON",
           fifo_load.wrsync_delaypipe       = 5,
           fifo_load.write_aclr_synch       = "ON";

  // ---------------------------------------------------------------------------
  // Save FIFO: core→host (64-bit wide write from 21.47, 32-bit wide read in 74a)
  // ---------------------------------------------------------------------------
  reg  fifo_save_write_req;
  reg  fifo_save_read_req;
  wire fifo_save_rd_empty;
  wire fifo_save_wr_empty;

  dcfifo_mixed_widths fifo_save (
      .data    (ss_ddr_do),
      .rdclk   (clk_74a),
      .rdreq   (fifo_save_read_req),
      .wrclk   (clk_ppu_21_47),
      .wrreq   (fifo_save_write_req),
      .q       ({save_state_bridge_read_data[7:0],
                 save_state_bridge_read_data[15:8],
                 save_state_bridge_read_data[23:16],
                 save_state_bridge_read_data[31:24]}),
      .rdempty (fifo_save_rd_empty),
      .wrempty (fifo_save_wr_empty),
      .aclr    (1'b0)
  );
  defparam fifo_save.intended_device_family = "Cyclone V",
           fifo_save.lpm_numwords           = 4,
           fifo_save.lpm_showahead          = "OFF",
           fifo_save.lpm_type               = "dcfifo_mixed_widths",
           fifo_save.lpm_width              = 64,
           fifo_save.lpm_widthu             = 2,
           fifo_save.lpm_widthu_r           = 3,
           fifo_save.lpm_width_r            = 32,
           fifo_save.overflow_checking      = "ON",
           fifo_save.rdsync_delaypipe       = 5,
           fifo_save.underflow_checking     = "ON",
           fifo_save.use_eab                = "ON",
           fifo_save.wrsync_delaypipe       = 5;

  // ---------------------------------------------------------------------------
  // Bridge read path (74a domain): APF reads saved data via 0x4xxxxxxx
  // ---------------------------------------------------------------------------
  reg  [20:0] last_unloader_addr = 21'hFFFFF;
  reg  [1:0]  save_read_state;
  reg  prev_bridge_rd;

  wire [27:0] bridge_save_addr = bridge_addr[27:0];

  localparam NONE          = 0;
  localparam SAVE_READ_REQ = 1;

  always @(posedge clk_74a) begin
    prev_bridge_rd <= bridge_rd;

    fifo_save_read_req <= 0;

    if (bridge_rd && ~prev_bridge_rd && bridge_addr[31:28] == 4'h4) begin
      if (~fifo_save_rd_empty && bridge_save_addr[22:2] != last_unloader_addr) begin
        save_read_state    <= SAVE_READ_REQ;
        fifo_save_read_req <= 1;
        last_unloader_addr <= bridge_save_addr[22:2];
      end
    end

    case (save_read_state)
      SAVE_READ_REQ: begin
        save_read_state    <= NONE;
        fifo_save_read_req <= 0;
      end
      default: ;
    endcase
  end

  // ---------------------------------------------------------------------------
  // Core-side state machine (21.47MHz domain)
  // ---------------------------------------------------------------------------
  localparam SAVE_BUSY           = 1;
  localparam SAVE_WAIT_FIFO_PUSH = 2;
  localparam SAVE_WAIT_APF_READ  = 3;
  localparam SAVE_WAIT_REQ       = 4;

  localparam LOAD_WAIT_REQ       = 10;
  localparam LOAD_READ_FIFO      = 11;
  localparam LOAD_WAIT_APF_START = 12;
  localparam LOAD_APF_COMPLETE   = 13;

  reg [7:0] state;

  reg prev_savestate_start;
  reg prev_savestate_load;
  reg prev_ss_busy;
  reg save_state_loading;
  reg save_state_saving_req;

  // Track prev ddr_req to detect toggle edges
  reg ss_ddr_req_prev;

  // Pending transfer: latched when edge detected, cleared when acked
  reg   pending_req;
  reg   pending_we;

  always @(posedge clk_ppu_21_47) begin
    prev_ss_busy        <= ss_busy;
    prev_savestate_start<= savestate_start_s;
    prev_savestate_load <= savestate_load_s;
    ss_ddr_req_prev     <= ss_ddr_req;

    ss_load            <= 0;
    ss_save            <= 0;
    fifo_save_write_req<= 0;
    fifo_load_read_req <= 0;

    // Detect toggle edge on ss_ddr_req (new transfer requested)
    if (ss_ddr_req != ss_ddr_req_prev) begin
      pending_req <= 1;
      pending_we  <= ss_ddr_we;
    end

    // Auto-start load when FIFO has data from APF
    if (~fifo_load_empty && ~save_state_loading) begin
      save_state_loading <= 1;
      state              <= LOAD_WAIT_REQ;
      ss_load            <= 1;
    end

    // APF triggers save start
    if (savestate_start_s && ~prev_savestate_start) begin
      state               <= SAVE_BUSY;
      savestate_start_ack <= 1;
      savestate_start_ok  <= 0;
      savestate_start_err <= 0;
      savestate_load_ok   <= 0;
      savestate_load_err  <= 0;
      ss_save             <= 1;
    end

    // APF triggers load start (data already in FIFO)
    if (savestate_load_s && ~prev_savestate_load) begin
      save_state_saving_req <= 1;
      savestate_load_ack    <= 1;
      savestate_load_ok     <= 0;
      savestate_load_err    <= 0;
      savestate_start_ok    <= 0;
      savestate_start_err   <= 0;
    end

    case (state)
      // ------------------------------------------------------------------
      // Saving: core → FIFO → APF
      // ------------------------------------------------------------------
      SAVE_BUSY: begin
        savestate_start_ack  <= 0;
        savestate_start_busy <= 1;

        if (pending_req && pending_we) begin
          pending_req          <= 0;
          fifo_save_write_req  <= 1;
          state                <= SAVE_WAIT_APF_READ;
          savestate_start_busy <= 0;
          savestate_start_ok   <= 1;
        end
      end

      SAVE_WAIT_APF_READ: begin
        // Wait for APF to drain one 32-bit word from FIFO, then ack core
        if (fifo_save_wr_empty) begin
          ss_ddr_ack <= ss_ddr_req;   // mirror the toggle to ack
          state      <= SAVE_WAIT_REQ;
        end
      end

      SAVE_WAIT_REQ: begin
        if (pending_req && pending_we) begin
          pending_req         <= 0;
          fifo_save_write_req <= 1;
          state               <= SAVE_WAIT_APF_READ;
        end else if (prev_ss_busy && ~ss_busy) begin
          // Save complete
          state <= NONE;
        end
      end

      // ------------------------------------------------------------------
      // Loading: APF → FIFO → core
      // ------------------------------------------------------------------
      LOAD_WAIT_REQ: begin
        if (prev_ss_busy && ~ss_busy) begin
          // Load complete, wait for APF ack
          state <= LOAD_WAIT_APF_START;
        end else if (pending_req && ~pending_we && ~fifo_load_empty) begin
          // Core wants next 8-byte block and FIFO has data
          pending_req        <= 0;
          fifo_load_read_req <= 1;
          state              <= LOAD_READ_FIFO;
        end
        // If pending_req is set but FIFO is empty, leave pending_req set.
        // The state machine will retry next cycle when the APF refills the FIFO.
      end

      LOAD_READ_FIFO: begin
        // Data available from FIFO after one cycle; ack the core
        ss_ddr_ack <= ss_ddr_req;   // mirror the toggle
        state      <= LOAD_WAIT_REQ;
      end

      LOAD_WAIT_APF_START: begin
        if (save_state_saving_req) begin
          save_state_saving_req <= 0;
          save_state_loading    <= 0;
          fifo_load_clr         <= 1;
          state                 <= LOAD_APF_COMPLETE;
          savestate_load_ack    <= 0;
          savestate_load_busy   <= 1;
        end
      end

      LOAD_APF_COMPLETE: begin
        fifo_load_clr       <= 0;
        savestate_load_busy <= 0;
        savestate_load_ok   <= 1;
        state               <= NONE;
      end

      default: ; // NONE
    endcase
  end

endmodule
