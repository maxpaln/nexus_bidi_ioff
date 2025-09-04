//   ==================================================================
//   >>>>>>>>>>>>>>>>>>>>>>> COPYRIGHT NOTICE <<<<<<<<<<<<<<<<<<<<<<<<<
//   ------------------------------------------------------------------
//   Copyright (c) 2022 by Lattice Semiconductor Corporation
//   ALL RIGHTS RESERVED
//   ------------------------------------------------------------------
//
//   Permission:
//
//      Lattice SG Pte. Ltd. grants permission to use this code
//      pursuant to the terms of the Lattice Reference Design License Agreement.
//
//
//   Disclaimer:
//
//      This VHDL or Verilog source code is intended as a design reference
//      which illustrates how these types of functions can be implemented.
//      It is the user's responsibility to verify their design for
//      consistency and functionality through the use of formal
//      verification methods.  Lattice provides no warranty
//      regarding the use or functionality of this code.
//
//   --------------------------------------------------------------------
//
//                  Lattice SG Pte. Ltd.
//                  101 Thomson Road, United Square #07-02
//                  Singapore 307591
//
//
//                     TEL: 1-800-Lattice (USA and Canada)
//                          408-826-6000 (other locations)
//
//                  web: http://www.latticesemi.com/
//                  email: techsupport@latticesemi.com
//
//   --------------------------------------------------------------------
//  Example implementation to utilise IO based registers for Bidirectional IO
//  in Nexus family.
// 
//  Requirements:
//    1. bidi_ireg, bidi_oreg, bidi_treg must all share a common clock. If
//       implemented, the reset and clock enable most also be common to all
//       FFs. i.e. a Clock Enable is not mandatory, but if a clock enable is
//       used there cannot be different clock enables for each FF.
//    2. No combinatorial logic between final FF and Bidirectional pin
//    3. Tristate Control signal needs to be the same width as the
//       bidirectional signal.
//
//  NOTES:
//
//  - If the user is finding the tristate reg is not being pushed into
//       the IO, check that the tristate control signal is not being optimised
//       during synthesis. The syn_keep attributes used below are intended to
//       prevent this.
//  - Since GSR usage can significantly complicate meeting the reset requirements
//       it is recommended to disable GSR inference via Strategy Settings.
//
// --------------------------------------------------------------------
//
// Revision History :
// --------------------------------------------------------------------
//   Ver  :| Author            :| Mod. Date :| Changes Made:
//   v1.0 :| MHoldsworth       :| 17/08/22  :| First Release
//   v1.1 :| MHoldsworth       :| 19/08/22  :| Fixed Tristate Register Push into IO FF
//   v1.2 :| Matt Holdsworth   :| 04/09/25  :| Added some clarifications based on Radiant 
//        :|                   :|           :| 2025.1. syn_useioff seems to have no effect. 
//        :|                   :|           :| Decision on whether a FF is pushed into the
//        :|                   :|           :| IO is based on RTL coding style. User can
//        :|                   :|           :| pull the FF back into the fabric with syn_keep.
// --------------------------------------------------------------------

module nexus_bidi_ioff # (
  parameter                  DWIDTH         = 8,
  parameter                  FIFO_DEPTH     = 32,
  parameter                  ALMOST_OFFSET  = 2
) (
  input   wire               clk,
  input   wire               rstn,
  input   wire               go,
  inout   wire [DWIDTH-1:0]  data_bidi
);

  // State Declarations
  localparam                 IDLE           = 'd0,
                             INPUT          = 'd1,
                             OUTPUT         = 'd2;

  // State Variable
  reg  [1:0]                 state;

  // Tri-State Enable signal - same width as data
  reg  [DWIDTH-1:0]          ts_en /* synthesis syn_keep=1 */;

  // FIFO Signals
  reg                        fifo_re;
  reg                        fifo_we;
  reg  [DWIDTH-1:0]          bidi_ireg /* synthesis syn_useioff = 1 */;
  wire [DWIDTH-1:0]          fifo_rdata;
  wire                       fifo_afull;
  wire                       fifo_aempty;
  wire                       fifo_full;
  wire                       fifo_empty;

  // Pipelining Signals
  reg  [DWIDTH-1:0]          fifo_wdata_r;
  reg  [DWIDTH-1:0]          fifo_wdata_rr;
  reg  [DWIDTH-1:0]          fifo_rdata_r;
//  reg  [DWIDTH-1:0]          bidi_oreg;
//  reg  [DWIDTH-1:0]          bidi_oreg /* synthesis syn_useioff = 1 */; // This has no effect
//  reg  [DWIDTH-1:0]          bidi_oreg /* synthesis syn_useioff = 0 */; // This has no effect
//  reg  [DWIDTH-1:0]          bidi_oreg /* synthesis syn_keep = 1 */; // This will force the FF out of the IO Logic and back into the fabric
  reg  [DWIDTH-1:0]          ts_en_r /* synthesis syn_keep=1 */;
  reg  [DWIDTH-1:0]          bidi_treg /* synthesis syn_useioff = 1 */;

  // Register Bidi Input
  always @(posedge clk or negedge rstn)
    if (~rstn) begin
      bidi_ireg              <= 0;
    end else begin
      // Requirement: Read Bidi Input directly into FF (no combinatorial logic)
      bidi_ireg              <= data_bidi;
    end

  // Pipeline Bidi Input to improve timing
  always @(posedge clk or negedge rstn)
    if (~rstn) begin
      fifo_wdata_r           <= 0;
      fifo_wdata_rr          <= 0;
    end else begin
      fifo_wdata_r           <= bidi_ireg;
      fifo_wdata_rr          <= fifo_wdata_r;
    end

  // Pipeline Bidi Output to improve timing
  always @(posedge clk or negedge rstn)
    if (~rstn) begin
      fifo_rdata_r           <= 0;
      bidi_oreg              <= 0;
    end else begin
      fifo_rdata_r           <= fifo_rdata;
      bidi_oreg              <= fifo_rdata_r;
    end

  // Pipeline TriState Control to improve timing
  always @(posedge clk or negedge rstn)
    if (~rstn) begin
      ts_en_r                <= {DWIDTH{1'b0}};
      bidi_treg              <= {DWIDTH{1'b0}};
    end else begin
      ts_en_r                <= ts_en;
      bidi_treg              <= ts_en_r;
    end

  // Bidirectional output control - implement bit-by-bit to simplify reg push
  // into FF
  generate
    genvar i;

    for (i=0; i<DWIDTH; i=i+1) begin
      assign data_bidi[i]    = (bidi_treg[i]) ? 1'bz : bidi_oreg[i];
    end
  endgenerate

  always @(posedge clk or negedge rstn)
    if (~rstn) begin
      ts_en                  <= {DWIDTH{1'b1}};
      fifo_re                <= 1'b0;
      fifo_we                <= 1'b0;
      state                  <= IDLE;
    end else begin
      case (state)
        IDLE : begin
          if (go) begin
            ts_en            <= {DWIDTH{1'b1}};
            state            <= INPUT;
          end else begin
            state            <= IDLE;
          end
        end
        INPUT : begin
          if (~fifo_full) begin
            fifo_we          <= 1'b1;
            state            <= INPUT;
          end else begin
            fifo_we          <= 1'b0;
            ts_en            <= 0;
            state            <= OUTPUT;
          end
        end
        OUTPUT : begin
          if (~fifo_empty) begin
            fifo_re          <= 1'b1;
            state            <= OUTPUT;
          end else begin
            fifo_we          <= 1'b0;
            state            <= IDLE;
          end
        end
        default : begin
          state              <= IDLE;
        end
      endcase
    end

  pmi_fifo #(
    .pmi_data_width          (DWIDTH), // integer       
    .pmi_data_depth          (FIFO_DEPTH), // integer       
    .pmi_almost_full_flag    (FIFO_DEPTH-ALMOST_OFFSET), // integer (pmi_almost_full_flag MUST be LESS than pmi_data_depth)       
    .pmi_almost_empty_flag   (ALMOST_OFFSET), // integer		
    .pmi_regmode             ("noreg"), // "reg"|"noreg"    	
    .pmi_family              ("common"), // "LIFCL"|"LFD2NX"|"LFCPNX"|"LFMXO5"|"UT24C"|"UT24CP"|"common"
    .pmi_implementation      ("LUT")  // "LUT"|"EBR"|"HARD_IP"
  ) i_fifo_dc (         
    .Reset                   (rstn), // I:
    .Clock                   (clk), // I:
    .WrEn                    (fifo_we), // I:
    .Data                    (fifo_wdata_rr), // I:      
    .RdEn                    (fifo_re), // I:
    .Q                       (fifo_rdata), // O:
    .Empty                   (fifo_empty), // O:
    .Full                    (fifo_full), // O:
    .AlmostEmpty             (fifo_aempty), // O:
    .AlmostFull              (fifo_afull)  // O:
  );
  

endmodule
