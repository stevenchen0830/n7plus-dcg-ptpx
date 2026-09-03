`timescale 1ns/1ps
`ifndef IMG_FILTER_DEF_V
`include "img_filter_def.v"
`endif
//============================================================================
//  IMG_FILTER  -  vertical FIR image filter
//
//  Stream    : RGBA, 10 bit per component, 4 pixel per clock (160 bit beat),
//              raster order, rdy/need handshake on both ports.
//  Kernel    : blk_h = 1, blk_v = 1..49 odd, coefficients symmetric about the
//              centre tap, sum of the blk_v coefficients = 128.
//  Boundary  : vertical mirror with edge duplication (mirrorMap of the spec).
//  Storage   : 49 external single-port SRAMs, 160 bit wide.  Row m lives in
//              bank (m mod 49) at address = beat index inside the row, so the
//              49-row sliding window maps onto the 49 banks without ever
//              moving data.
//
//  ------------------------------------------------------------------------
//  Central idea
//  ------------------------------------------------------------------------
//  A naive implementation muxes 49 banks of read data onto 49 filter taps.
//  That is a 7840 bit rotation plus a per-tap mirror computation, and it fits
//  neither the area budget nor the cycle time.
//
//  This design inverts the problem: the DATA never moves, the COEFFICIENTS
//  move.  For output row y the module computes, once per row, an effective
//  weight vector C[0..48] with
//
//      C[j] = sum of coef_k over all taps k whose mirrored source row m
//             satisfies (m mod 49) == j
//
//  Two taps that fold onto the same source row simply add their weights, so
//  the mirror logic disappears from the datapath completely.  C is produced
//  by three rotations of the symmetric coefficient array (interior taps,
//  top folded taps, bottom folded taps): 3 x 392 bit of barrel rotation
//  evaluated once per row instead of once per beat.
//
//  The datapath is then a plain, mirror free 50 term MAC per lane:
//      out = sat10( ( sum_j C[j]*bank_j + C_bp*bypass + 64 ) >> 7 )
//  with 16 lanes (4 pixels x 4 components).  The 50th tap is the row that is
//  streaming in, forwarded from the input register instead of from the SRAM,
//  which is what frees the bank that receives the write of that same cycle.
//
//  Read enables are derived from C: a zero weight is never fetched, so the
//  external memory access count scales with blk_v, not with MEM_NUM.
//
//  Timing     : accept -> mem -> rdata -> MAC1 -> MAC2 -> MAC3 -> out (6 cyc),
//               plus (blk_v-1)/2 row times of algorithmic fill latency.
//  Throughput : one 4 pixel beat per cycle for every legal blk_v.
//  REG_IN     : in_pix_data, mem_rdata, img_width, img_height, blk_v, coef
//               all drive flip-flops directly and nothing else (checked
//               structurally by scripts/check_reg_io.py).
//  REG_OUT    : out_pix_data comes straight out of a register.
//============================================================================
module IMG_FILTER (
    input  wire                             clk,
    input  wire                             rst_n,

    // input pixel stream ----------------------------------------------------
    input  wire                             in_pix_rdy,
    output wire                             in_pix_need,
    input  wire [159:0]                     in_pix_data,

    // output pixel stream ---------------------------------------------------
    output wire                             out_pix_rdy,
    input  wire                             out_pix_need,
    output reg  [159:0]                     out_pix_data,

    // frame configuration ---------------------------------------------------
    input  wire                             frm_start,
    input  wire [10:0]                      img_width,
    input  wire [11:0]                      img_height,
    input  wire [5:0]                       blk_v,
    input  wire [199:0]                     coef,

    // external single-port SRAM ---------------------------------------------
    output wire [`MEM_NUM-1:0]              mem_ce,
    output wire [`MEM_NUM-1:0]              mem_we,
    output wire [`MEM_NUM*11-1:0]           mem_addr,
    output wire [`MEM_NUM*`MEM_DWTH-1:0]    mem_wdata,
    input  wire [`MEM_NUM*`MEM_DWTH-1:0]    mem_rdata
);

    localparam NBK   = 49;   // banks / maximum kernel length
    localparam DW    = 160;  // bank width
    localparam CW    = 392;  // NBK * 8 : packed weight vector
    localparam NTAP  = 50;   // 49 memory taps + 1 forwarded tap
    // Three-stage MAC.  Two balanced stages measured ~35 logic levels each
    // (1.18 ns at the SS corner), so the array is cut three ways instead:
    // 25 pair-products (multiply + one add), 5 partial sums of 5 pairs, and
    // a final sum + round + saturate stage, at roughly 24/23/20 levels.
    localparam NPAIR = 25;   // 50 taps as 25 multiply-add pairs
    localparam NPART = 5;    // 5 partial sums of 5 pairs each
    localparam ACCW  = 20;   // accumulator width

    localparam S_IDLE  = 3'd0;
    localparam S_PREP  = 3'd1;
    localparam S_FILL  = 3'd2;
    localparam S_MAIN  = 3'd3;
    localparam S_DRAIN = 3'd4;

    integer i;

    //========================================================================
    // 0.  Helper functions
    //========================================================================
    // Cyclic rotation of a 49 x 8 array by a variable number of elements:
    // rot49(a,s)[j] = a[(j-s) mod 49].  Six fixed rewiring stages, each one
    // a rotation by 2^k elements taken modulo 49, so the composition of the
    // set bits of s is a rotation by (s mod 49); s <= 48 is therefore exact.
    // The full mod-49 rotate is a 6-level log shifter.  v4 splits it into
    // two 3-level halves with a pipeline register between them (rot49_hi o
    // rot49_lo == the original rot49); the weight-vector cone then spans
    // two shallow cycles instead of one deep one, and no multicycle
    // constraint is needed anywhere.
    function [CW-1:0] rot49_lo;              // rotate by s[2:0] (0..7)
        input [CW-1:0] a;
        input [2:0]    s;
        reg [CW-1:0] t0, t1;
        begin
            t0       = s[0] ? {a [383:0], a [391:384]} : a;    // +1  element
            t1       = s[1] ? {t0[375:0], t0[391:376]} : t0;   // +2
            rot49_lo = s[2] ? {t1[359:0], t1[391:360]} : t1;   // +4
        end
    endfunction

    function [CW-1:0] rot49_hi;              // rotate by 8*s[0]+16*s[1]+32*s[2]
        input [CW-1:0] a;
        input [2:0]    s;
        reg [CW-1:0] t3, t4;
        begin
            t3       = s[0] ? {a [327:0], a [391:328]} : a;    // +8
            t4       = s[1] ? {t3[263:0], t3[391:264]} : t3;   // +16
            rot49_hi = s[2] ? {t4[135:0], t4[391:136]} : t4;   // +32
        end
    endfunction

    // Index negation: rev49(a)[i] = a[(49-i) mod 49].  Pure wiring.
    function [CW-1:0] rev49;
        input [CW-1:0] a;
        integer k;
        begin
            rev49[7:0] = a[7:0];
            for (k = 1; k < NBK; k = k + 1)
                rev49[k*8 +: 8] = a[(NBK-k)*8 +: 8];
        end
    endfunction

    //========================================================================
    // 1.  Frame configuration - REG_IN, captured on frm_start
    //========================================================================
    reg  [11:0]  h_m1_q;      // img_height  = H-1
    reg  [8:0]   nbm1_q;      // beats per row - 1 = floor((W-1)/4)
    reg  [4:0]   hv_q;        // (blk_v-1)/2, 0..24
    reg  [199:0] coef_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_m1_q <= 12'd0;
            nbm1_q <=  9'd0;
            hv_q   <=  5'd0;
            coef_q <= 200'd0;
        end else if (frm_start) begin
            h_m1_q <= img_height;      // direct register of the port
            nbm1_q <= img_width[10:2]; // bit select only
            hv_q   <= blk_v[5:1];      // blk_v is odd: (blk_v-1)/2
            coef_q <= coef;
        end
    end

    //========================================================================
    // 2.  Frame preparation
    //     a_sym[d] = weight of a tap d rows away from the centre
    //     mod_x    = (2H+23) mod 49, needed by the bottom fold rotation
    //========================================================================
    reg  [7:0]  a_sym [0:24];
    reg  [13:0] mod_x;
    reg  [3:0]  prep_cnt;
    wire        prep_done  = (prep_cnt == 4'd12);
    // v4: the weight pipeline is one register deeper, so the PREP capture
    // moves from count 10 to 11.  Chain: mod_x final at the edge closing
    // count 8 -> stage A during 9 -> c_fut written closing 10 -> c_cur
    // captures it at the edge closing count 11; MAIN starts at 13.
    wire        prep_cload = (prep_cnt == 4'd11);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 25; i = i + 1) a_sym[i] <= 8'd0;
        end else if (prep_cnt == 4'd0) begin
            for (i = 0; i < 25; i = i + 1)
                a_sym[i] <= (i[4:0] <= hv_q) ? coef_q[(hv_q-i[4:0])*8 +: 8]
                                             : 8'd0;
        end
    end

    // (2H+23) mod 49 by eight conditional subtractions, one per PREP cycle.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mod_x <= 14'd0;
        end else begin
            case (prep_cnt)
                4'd0: mod_x <= {h_m1_q, 1'b0} + 14'd25;          // 2H + 23
                4'd1: if (mod_x >= 14'd6272) mod_x <= mod_x - 14'd6272;
                4'd2: if (mod_x >= 14'd3136) mod_x <= mod_x - 14'd3136;
                4'd3: if (mod_x >= 14'd1568) mod_x <= mod_x - 14'd1568;
                4'd4: if (mod_x >= 14'd784 ) mod_x <= mod_x - 14'd784;
                4'd5: if (mod_x >= 14'd392 ) mod_x <= mod_x - 14'd392;
                4'd6: if (mod_x >= 14'd196 ) mod_x <= mod_x - 14'd196;
                4'd7: if (mod_x >= 14'd98  ) mod_x <= mod_x - 14'd98;
                4'd8: if (mod_x >= 14'd49  ) mod_x <= mod_x - 14'd49;
                default: ;   // settled from prep_cnt == 9 onwards
            endcase
        end
    end

    //========================================================================
    // 3.  Frame / row sequencer
    //========================================================================
    reg  [2:0]  state;
    reg  [8:0]  c_cnt;     // beat inside the row
    reg  [11:0] r_cnt;     // input row index
    reg  [5:0]  wbank;     // r_cnt mod 49
    reg  [11:0] rem_q;     // H-1-y, rows still to be produced after this one

    // Parameters of the row whose weight vector is being prepared.  They run
    // one row ahead of the row that is being filtered, so the weight vector
    // is a plain register-to-register move at the row boundary instead of a
    // long combinational path fed by the handshake.
    reg  [11:0] rem_f;     // H-1-yf
    reg  [5:0]  ymod_f;    // yf mod 49
    reg  [4:0]  tlo_f;     // max(0, 24-yf)

    reg         out_v_q;

    wire e_isout   = (state == S_MAIN) | (state == S_DRAIN);
    wire e_needin  = (state == S_FILL) | (state == S_MAIN);
    wire e_active  = e_isout | e_needin;
    wire e_iswr    = e_needin & (hv_q != 5'd0);

    //-------------------------------------------------------------------
    // Elastic stream interfaces.  Both ports end in tiny register FIFOs so
    // that pipe_en is a function of REGISTERS only (fifo counters + state).
    // The former combinational path  out_pix_need / in_pix_rdy -> pipe_en
    // -> 7840 register enables  was the timing wall of the whole design:
    // the enable now leaves a flop at the clock edge and has a full cycle
    // to cross its buffer tree.
    //-------------------------------------------------------------------
    reg  [1:0]  icnt;       // input fifo occupancy, 0..2
    reg         in_need_q;  // registered in_pix_need
    reg         oskid_v;    // output overflow slot valid
    wire [1:0]  ocnt = {1'b0, out_v_q} + {1'b0, oskid_v};
    wire        ihas = (icnt != 2'd0);

    wire pipe_en   = (ocnt != 2'd2) & (e_needin ? ihas : 1'b1);
    wire e_go      = e_active & pipe_en;
    wire row_end   = (c_cnt == nbm1_q);
    wire adv_row   = e_go & row_end & e_isout;   // output row advances

    assign in_pix_need = in_need_q;

    // next row control values ------------------------------------------------
    wire [11:0] rem_n   = rem_q - 12'd1;
    wire [4:0]  tlo_fn  = (tlo_f  == 5'd0)  ? 5'd0 : tlo_f - 5'd1;
    wire [11:0] rem_fn  = rem_f - 12'd1;
    wire [5:0]  ymod_fn = (ymod_f == 6'd48) ? 6'd0 : ymod_f + 6'd1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            prep_cnt <= 4'd0;
            c_cnt    <= 9'd0;
            r_cnt    <= 12'd0;
            wbank    <= 6'd0;
            rem_q    <= 12'd0;
        end else if (frm_start) begin
            state    <= S_PREP;
            prep_cnt <= 4'd0;
            c_cnt    <= 9'd0;
            r_cnt    <= 12'd0;
            wbank    <= 6'd0;
        end else begin
            case (state)
                S_PREP: begin
                    prep_cnt <= prep_cnt + 4'd1;
                    // H-1 : output row 0 is the newest row.  Loaded from the
                    // REG_IN copy h_m1_q one cycle after frm_start so that
                    // the img_height port fans out to that register only
                    // (strict REG_IN: no mux between the port and a D pin).
                    // rem_q is first consumed after PREP, 12 cycles later.
                    if (prep_cnt == 4'd0) rem_q <= h_m1_q;
                    if (prep_done)
                        state <= (hv_q == 5'd0) ? S_MAIN : S_FILL;
                end
                default: begin
                    if (e_go) begin
                        if (row_end) begin
                            c_cnt <= 9'd0;
                            if (e_needin) begin
                                r_cnt <= r_cnt + 12'd1;
                                wbank <= (wbank == 6'd48) ? 6'd0 : wbank + 6'd1;
                            end
                            if (e_isout) rem_q <= rem_n;
                            case (state)
                                S_FILL:  if (r_cnt == h_m1_q)
                                             state <= S_DRAIN;  // hv >= H
                                         else if (r_cnt ==
                                                  ({7'd0, hv_q} - 12'd1))
                                             state <= S_MAIN;
                                S_MAIN:  if (r_cnt == h_m1_q)
                                             state <= (hv_q == 5'd0) ? S_IDLE
                                                                     : S_DRAIN;
                                S_DRAIN: if (rem_q == 12'd0)
                                             state <= S_IDLE;
                                default: ;
                            endcase
                        end else begin
                            c_cnt <= c_cnt + 9'd1;
                        end
                    end
                end
            endcase
        end
    end

    //========================================================================
    // 4.  Effective weight vector C[0..48] for the current output row
    //========================================================================
    // A[i], i = k+24 : weight of tap k, zero outside the kernel.
    wire [CW-1:0] a_flat;
    genvar gi;
    generate
        for (gi = 0; gi < NBK; gi = gi + 1) begin : G_AFLAT
            if (gi >= 24) begin : G_HI
                assign a_flat[gi*8 +: 8] = a_sym[gi-24];
            end else begin : G_LO
                assign a_flat[gi*8 +: 8] = a_sym[24-gi];
            end
        end
    endgenerate

    // Row parameters come straight out of registers: nothing on this path
    // depends on the handshake, so it is a clean register to register path
    // with a whole row time of slack.
    wire [4:0]  tlo_c  = tlo_f;
    wire [11:0] rem_c  = rem_f;
    wire [5:0]  ymod_c = ymod_f;

    wire [5:0]  thi_c  = (rem_c >= 12'd24) ? 6'd48 : (6'd24 + {1'b0,rem_c[4:0]});
    wire        byp_c  = (rem_c >= {7'd0, hv_q});   // row y+hv still arriving

    // masks: interior taps, top folded taps, bottom folded taps
    wire [CW-1:0] msk_int, msk_top, msk_bot;
    generate
        for (gi = 0; gi < NBK; gi = gi + 1) begin : G_MASK
            wire sel_top = (gi < tlo_c);
            wire sel_bot = (gi > thi_c);
            wire sel_byp = byp_c & (gi == (6'd24 + {1'b0, hv_q}));
            assign msk_int[gi*8 +: 8] = (sel_top | sel_bot | sel_byp)
                                        ? 8'd0 : a_flat[gi*8 +: 8];
            assign msk_top[gi*8 +: 8] = sel_top ? a_flat[gi*8 +: 8] : 8'd0;
            assign msk_bot[gi*8 +: 8] = sel_bot ? a_flat[gi*8 +: 8] : 8'd0;
        end
    endgenerate

    // rotation amounts, all modulo 49
    wire [6:0] s1_raw = {1'b0, ymod_c} + 7'd25;               // (y-24) mod 49
    wire [5:0] s1_c   = (s1_raw >= 7'd49) ? (s1_raw[5:0] - 6'd49) : s1_raw[5:0];
    wire [6:0] s2_raw = (ymod_c <= 6'd23) ? (7'd23 - {1'b0, ymod_c})
                                          : (7'd72 - {1'b0, ymod_c});
    wire [5:0] s2_c   = s2_raw[5:0];                          // (23-y) mod 49
    wire [6:0] s3_raw = {1'b0, mod_x[5:0]} + 7'd49 - {1'b0, ymod_c};
    wire [5:0] s3_c   = (s3_raw >= 7'd49) ? (s3_raw[5:0] - 6'd49) : s3_raw[5:0];

    // Rotator stage A : masks + the fine (0..7) half of each rotation.
    wire [CW-1:0] cvlo1 = rot49_lo(msk_int,         s1_c[2:0]);
    wire [CW-1:0] cvlo2 = rot49_lo(rev49(msk_top),  s2_c[2:0]);
    wire [CW-1:0] cvlo3 = rot49_lo(rev49(msk_bot),  s3_c[2:0]);
    wire [7:0]    cbp_nxt = byp_c ? coef_q[7:0] : 8'd0;

    reg [CW-1:0] cvlo1_q, cvlo2_q, cvlo3_q;   // mid-rotation pipeline regs
    reg [2:0]    shi1_q,  shi2_q,  shi3_q;    // coarse rotation selects
    reg [7:0]    cbp_mid_q;
    always @(posedge clk) begin
        cvlo1_q <= cvlo1;   shi1_q <= s1_c[5:3];
        cvlo2_q <= cvlo2;   shi2_q <= s2_c[5:3];
        cvlo3_q <= cvlo3;   shi3_q <= s3_c[5:3];
        cbp_mid_q <= cbp_nxt;
    end

    // Rotator stage B : the coarse (+8/+16/+32) half, then the 3-way sum.
    wire [CW-1:0] cv1 = rot49_hi(cvlo1_q, shi1_q);
    wire [CW-1:0] cv2 = rot49_hi(cvlo2_q, shi2_q);
    wire [CW-1:0] cv3 = rot49_hi(cvlo3_q, shi3_q);

    wire [CW-1:0]  c_nxt;
    wire [NBK-1:0] ce_nxt;
    generate
        for (gi = 0; gi < NBK; gi = gi + 1) begin : G_CSUM
            assign c_nxt[gi*8 +: 8] = cv1[gi*8 +: 8] + cv2[gi*8 +: 8]
                                                     + cv3[gi*8 +: 8];
            // A bank is fetched when its weight is non zero.  The three
            // contributions are unsigned and their total never overflows
            // eight bits, so the enable is the OR of the contributions and
            // does not have to wait for the adder.
            assign ce_nxt[gi]       = |{cv1[gi*8 +: 8], cv2[gi*8 +: 8],
                                        cv3[gi*8 +: 8]};
        end
    endgenerate

    // Look-ahead pipeline, now two registers deep (stage A regs -> c_fut).
    // The value is still consumed only at the next c_load, >= 6 cycles
    // after the sources step, so the extra stage is absorbed by the row
    // gap; PREP compensates by loading one count later (prep_cload = 11).
    reg [CW-1:0]  c_fut;
    reg [NBK-1:0] ce_fut;
    reg [7:0]     cbp_fut;

    always @(posedge clk) begin
        c_fut   <= c_nxt;
        ce_fut  <= ce_nxt;
        cbp_fut <= cbp_mid_q;
    end

    // Stage 2 : at the row boundary the prepared vector becomes the live one
    //           and the look ahead parameters step to the row after it.
    reg [CW-1:0]  c_cur;
    reg [NBK-1:0] ce_cur;
    reg [7:0]     cbp_cur;
    wire          c_load = adv_row | ((state == S_PREP) & prep_cload);

    always @(posedge clk) begin
        if (c_load) begin
            c_cur   <= c_fut;
            ce_cur  <= ce_fut;
            cbp_cur <= cbp_fut;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rem_f  <= 12'd0;
            ymod_f <=  6'd0;
            tlo_f  <=  5'd24;
        end else if (frm_start) begin
            ymod_f <=  6'd0;
            tlo_f  <=  5'd24;
        end else if ((state == S_PREP) && (prep_cnt == 4'd0)) begin
            rem_f  <= h_m1_q;          // look ahead starts on output row 0;
                                       // from the REG_IN copy (see rem_q),
                                       // first used by rotator stage A at
                                       // PREP count 9
        end else if (c_load) begin
            rem_f  <= rem_fn;
            ymod_f <= ymod_fn;
            tlo_f  <= tlo_fn;
        end
    end

    //========================================================================
    // 5.  Input register (REG_IN) and memory command stage
    //========================================================================
    // Two-slot input FIFO.  REG_IN: the data port lands directly in the
    // ibuf* registers; in_data_q is now an internal pipeline register fed
    // from the FIFO head, so every downstream stage is unchanged.
    reg [DW-1:0] ibuf0, ibuf1;
    reg          iwr, ird;
    reg [DW-1:0] in_data_q;

    wire iacc = in_pix_rdy & in_need_q;   // beat enters the fifo
    wire icon = pipe_en & e_needin;       // body consumes the head
    wire [1:0] icnt_n  = icnt + {1'b0, iacc} - {1'b0, icon};
    wire       in_open = ((state == S_PREP) & prep_done) | e_needin;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            icnt <= 2'd0; iwr <= 1'b0; ird <= 1'b0; in_need_q <= 1'b0;
        end else if (frm_start) begin
            icnt <= 2'd0; iwr <= 1'b0; ird <= 1'b0; in_need_q <= 1'b0;
        end else begin
            if (iacc) iwr <= ~iwr;
            if (icon) ird <= ~ird;
            icnt      <= icnt_n;
            in_need_q <= in_open & (icnt_n != 2'd2);
        end
    end

    always @(posedge clk) begin
        if (iacc) begin
            if (iwr) ibuf1 <= in_pix_data;
            else     ibuf0 <= in_pix_data;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)   in_data_q <= {DW{1'b0}};
        else if (icon) in_data_q <= ird ? ibuf1 : ibuf0;
    end

    reg [NBK-1:0] m_ce;       // read enables
    reg [NBK-1:0] m_1h;       // write bank, one hot
    reg [8:0]     m_addr;
    reg [CW-1:0]  m_c;
    reg [7:0]     m_cbp;
    reg           m_out;

    wire [NBK-1:0] wbank_1h = {{(NBK-1){1'b0}}, 1'b1} << wbank;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_ce   <= {NBK{1'b0}};
            m_1h   <= {NBK{1'b0}};
            m_out  <= 1'b0;
            m_addr <= 9'd0;
        end else if (pipe_en) begin
            m_ce   <= (e_go & e_isout) ? ce_cur   : {NBK{1'b0}};
            m_1h   <= (e_go & e_iswr ) ? wbank_1h : {NBK{1'b0}};
            m_out  <=  e_go & e_isout;
            m_addr <=  c_cnt;
        end
    end
    always @(posedge clk) begin
        if (pipe_en & e_go & e_isout) begin
            m_c   <= c_cur;
            m_cbp <= cbp_cur;
        end
    end

    generate
        for (gi = 0; gi < NBK; gi = gi + 1) begin : G_MEM
            assign mem_addr [gi*11 +: 11] = {2'b00, m_addr};
            // only the addressed bank sees the data: 48 of 49 write buses
            // stay quiet, which removes most of the write interface power
            assign mem_wdata[gi*DW +: DW] = m_1h[gi] ? in_data_q : {DW{1'b0}};
        end
    endgenerate
    assign mem_ce = (m_ce | m_1h) & {NBK{pipe_en}};
    assign mem_we =          m_1h & {NBK{pipe_en}};

    //========================================================================
    // 6.  Read data capture (REG_IN) and metadata alignment
    //========================================================================
    reg [NBK*DW-1:0] rdata_q;
    reg [NBK-1:0]    ce_d1, ce_d2;
    reg [CW-1:0]     c_d1,  c_d2;
    reg [7:0]        cbp_d1, cbp_d2;
    reg [DW-1:0]     byp_d1, byp_d2;
    reg              out_d1, out_d2, out_d3, out_d4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ce_d1  <= {NBK{1'b0}};
            ce_d2  <= {NBK{1'b0}};
            out_d1 <= 1'b0;
            out_d2 <= 1'b0;
            out_d3 <= 1'b0;
            out_d4 <= 1'b0;
        end else if (pipe_en) begin
            ce_d1  <= m_ce;
            ce_d2  <= ce_d1;
            out_d1 <= m_out;
            out_d2 <= out_d1;
            out_d3 <= out_d2;
            out_d4 <= out_d3;
        end
    end

    always @(posedge clk) begin
        if (pipe_en) begin
            byp_d1 <= in_data_q;
            byp_d2 <= byp_d1;
            c_d1   <= m_c;    c_d2   <= c_d1;
            cbp_d1 <= m_cbp;  cbp_d2 <= cbp_d1;
            if (out_d1) rdata_q <= mem_rdata;   // direct port register
        end
    end

    //========================================================================
    // 7.  Datapath : 16 lanes x 50 taps multiply accumulate
    //========================================================================
    // Banks that were not read are forced to zero.  Their weight is zero
    // anyway, so this only stops unknowns and toggles entering the tree.
    wire [NTAP*DW-1:0] tapd;
    wire [NTAP*8-1:0]  tapc;
    generate
        for (gi = 0; gi < NBK; gi = gi + 1) begin : G_TAP
            assign tapd[gi*DW +: DW] = ce_d2[gi] ? rdata_q[gi*DW +: DW]
                                                 : {DW{1'b0}};
            assign tapc[gi*8  +: 8 ] = c_d2[gi*8 +: 8];
        end
    endgenerate
    // tap 49 : the row that is streaming in.  Cleared while it carries no
    // weight (drain phase), for the same reason as the bank taps above.
    assign tapd[NBK*DW +: DW] = (|cbp_d2) ? byp_d2 : {DW{1'b0}};
    assign tapc[NBK*8  +: 8 ] = cbp_d2;

    // Stage 1 (valid at out_d2): 25 pair products per lane.
    // Stage 2 (valid at out_d3): 5 partial sums of 5 pairs.
    // Stage 3 (valid at out_d4): total, +64, >>7, saturate.
    // With legal coefficients every intermediate value is bounded by the
    // final total (all terms non-negative, sum of weights = 128), so ACCW
    // covers each stage.
    reg  [ACCW-1:0] pair_q [0:15][0:NPAIR-1];
    reg  [ACCW-1:0] part_q [0:15][0:NPART-1];
    wire [ACCW-1:0] total  [0:15];
    wire [12:0]     rndv   [0:15];
    wire [159:0]    result;

    genvar gl, gp;
    generate
        for (gl = 0; gl < 16; gl = gl + 1) begin : G_LANE
            for (gp = 0; gp < NPAIR; gp = gp + 1) begin : G_PAIR
                wire [ACCW-1:0] pprod =
                    ({{(ACCW-10){1'b0}}, tapd[(2*gp)*DW   + gl*10 +: 10]} *
                     {{(ACCW-8){1'b0}},  tapc[(2*gp)*8         +: 8]}) +
                    ({{(ACCW-10){1'b0}}, tapd[(2*gp+1)*DW + gl*10 +: 10]} *
                     {{(ACCW-8){1'b0}},  tapc[(2*gp+1)*8       +: 8]});
                always @(posedge clk)
                    if (pipe_en & out_d2) pair_q[gl][gp] <= pprod;
            end

            for (gp = 0; gp < NPART; gp = gp + 1) begin : G_PART
                wire [ACCW-1:0] psum5 = ((pair_q[gl][5*gp]   +
                                          pair_q[gl][5*gp+1]) +
                                         (pair_q[gl][5*gp+2] +
                                          pair_q[gl][5*gp+3])) +
                                          pair_q[gl][5*gp+4];
                always @(posedge clk)
                    if (pipe_en & out_d3) part_q[gl][gp] <= psum5;
            end

            assign total[gl] = ((part_q[gl][0] + part_q[gl][1]) +
                                (part_q[gl][2] + part_q[gl][3])) +
                                 part_q[gl][4];
            wire [ACCW-1:0] rsum = total[gl] + {{(ACCW-7){1'b0}}, 7'd64};
            assign rndv [gl] = rsum[ACCW-1:7];
            assign result[gl*10 +: 10] = (|rndv[gl][12:10]) ? 10'd1023
                                                            : rndv[gl][9:0];
        end
    endgenerate

    //========================================================================
    // 8.  Output register (REG_OUT)
    //========================================================================
    // Two-slot output skid.  The head (out_pix_data / out_v_q) is the
    // REG_OUT register; one overflow slot absorbs the beat that is already
    // in flight when the consumer stalls.  pipe_en is gated on ocnt < 2, so
    // a push can never overflow.
    reg [159:0] oskid_d;
    wire opop  = out_v_q & out_pix_need;
    wire opush = pipe_en & out_d4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_v_q <= 1'b0;
            oskid_v <= 1'b0;
        end else begin
            case ({oskid_v, out_v_q})
                2'b00: out_v_q <= opush;
                2'b01: begin
                    if      ( opop & ~opush) out_v_q <= 1'b0;
                    else if (~opop &  opush) oskid_v <= 1'b1;
                end
                2'b11: if (opop) oskid_v <= 1'b0;
                default: ;   // 2'b10 unreachable
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_pix_data <= 160'd0;
            oskid_d      <= 160'd0;
        end else begin
            // head loads on: empty push, pop-with-push, pop-from-skid
            if (~out_v_q | opop)
                out_pix_data <= oskid_v ? oskid_d : result;
            if (opush & out_v_q & ~opop)
                oskid_d <= result;
        end
    end
    assign out_pix_rdy = out_v_q;

`ifdef FORMAL_PROPERTIES
`include "img_filter_properties.vh"
`endif

endmodule
