`timescale 1ns/1ps
//============================================================================
//  Self checking testbench for IMG_FILTER.
//
//  * behavioural single port SRAM model, 49 banks x 1440 x 160 bit, one cycle
//    read latency, output held while ce is low, contents start as X so that a
//    read of a location that was never written shows up immediately
//  * randomised rdy / need handshake pressure on both stream ports
//  * golden model computed straight from the spec (mirrorMap pseudo code)
//  * protocol, latency, X and dead cycle checks
//  * per frame cycle count and external memory access count, i.e. the raw
//    numbers behind throughput and external-memory-power budgets
//============================================================================
module img_filter_tb;

    localparam NBK     = `MEM_NUM;
    localparam DW      = `MEM_DWTH;
    localparam MAXPIX  = 200000;
    localparam DEADMAX = 20000;

    reg clk;
    reg rst_n;

    initial begin
        clk = 1'b0;
        forever #0.5 clk = ~clk;      // 1 GHz
    end

    //-----------------------------------------------------------------------
    // DUT connections
    //-----------------------------------------------------------------------
    reg          in_pix_rdy;
    wire         in_pix_need;
    reg  [159:0] in_pix_data;

    wire         out_pix_rdy;
    reg          out_pix_need;
    wire [159:0] out_pix_data;

    reg          frm_start;
    reg  [10:0]  img_width;
    reg  [11:0]  img_height;
    reg  [5:0]   blk_v;
    reg  [199:0] coef;

    wire [NBK-1:0]     mem_ce;
    wire [NBK-1:0]     mem_we;
    wire [NBK*11-1:0]  mem_addr;
    wire [NBK*DW-1:0]  mem_wdata;
    reg  [NBK*DW-1:0]  mem_rdata;

    IMG_FILTER u_dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_pix_rdy  (in_pix_rdy),
        .in_pix_need (in_pix_need),
        .in_pix_data (in_pix_data),
        .out_pix_rdy (out_pix_rdy),
        .out_pix_need(out_pix_need),
        .out_pix_data(out_pix_data),
        .frm_start   (frm_start),
        .img_width   (img_width),
        .img_height  (img_height),
        .blk_v       (blk_v),
        .coef        (coef),
        .mem_ce      (mem_ce),
        .mem_we      (mem_we),
        .mem_addr    (mem_addr),
        .mem_wdata   (mem_wdata),
        .mem_rdata   (mem_rdata)
    );

    //-----------------------------------------------------------------------
    // Single port SRAM model
    //-----------------------------------------------------------------------
    reg [DW-1:0] sram [0:NBK-1][0:1439];
    integer      bnk;
    integer      mem_reads;
    integer      mem_writes;

    always @(posedge clk) begin
        for (bnk = 0; bnk < NBK; bnk = bnk + 1) begin
            if (mem_ce[bnk] === 1'b1) begin
                if (mem_we[bnk] === 1'b1) begin
                    sram[bnk][mem_addr[bnk*11 +: 11]] <=
                        mem_wdata[bnk*DW +: DW];
                    mem_writes = mem_writes + 1;
                end else begin
                    mem_rdata[bnk*DW +: DW] <=
                        sram[bnk][mem_addr[bnk*11 +: 11]];
                    mem_reads = mem_reads + 1;
                end
            end
        end
    end

    //-----------------------------------------------------------------------
    // Frame state, image storage and golden model
    //-----------------------------------------------------------------------
    reg [39:0]  img [0:MAXPIX-1];
    reg [7:0]   cf  [0:48];          // expanded symmetric coefficients
    reg [7:0]   wgt [0:24];          // half coefficient set
    integer     W, H, BV, HV, NB;
    integer     errors, checks, frames;
    integer     align_checks, align_errors, bank_wrap_frames;
    reg [49:0]  cov_blk_v;
    reg [3:0]   cov_width_mod4;
    reg [48:0]  cov_s1, cov_s2, cov_s3;

    function integer mirror_row;
        input integer pos;
        input integer height;
        integer p, cnt;
        begin
            p   = pos;
            cnt = 0;
            while ((p < 0) || (p >= height)) begin
                cnt = cnt + 1;
                if (p < 0) p = p + height;
                else       p = p - height;
            end
            if (cnt % 2 == 1) mirror_row = height - 1 - p;
            else              mirror_row = p;
        end
    endfunction

    function [9:0] golden_comp;
        input integer y;
        input integer x;
        input integer comp;           // 0..3, bit offset comp*10 in the pixel
        integer k, m, acc;
        reg [39:0] pix;
        begin
            acc = 0;
            for (k = -HV; k <= HV; k = k + 1) begin
                m   = mirror_row(y + k, H);
                pix = img[m*W + x];
                acc = acc + pix[comp*10 +: 10] * cf[k + 24];
            end
            acc = (acc + 64) >> 7;
            if (acc > 1023) acc = 1023;
            golden_comp = acc[9:0];
        end
    endfunction

    //-----------------------------------------------------------------------
    // White-box v4 PREP alignment assertion.  At every c_load, independently
    // rebuild the effective bank weights from mirror_row and check that the
    // two-stage split rotator delivered the vector for the intended row.
    //-----------------------------------------------------------------------
    reg [391:0] align_expected;
    reg [7:0]   align_bypass;
    integer align_y, align_h, align_hv, align_k, align_m, align_bank;
    integer align_coef, align_s1, align_s2, align_s3, align_mismatch;

    always @(posedge clk) begin
        // The final output-row boundary also performs one harmless look-ahead
        // load that is never consumed.  Exclude it explicitly: at H=4096 the
        // 12-bit rem_f underflow wraps to 4095 and otherwise resembles y=0.
        if (rst_n && (img_filter_tb.u_dut.c_load === 1'b1) &&
            ((img_filter_tb.u_dut.state == 3'd1) || // S_PREP
             (img_filter_tb.u_dut.adv_row &&
              (img_filter_tb.u_dut.rem_q != 12'd0))) &&
            (img_filter_tb.u_dut.rem_f <= img_filter_tb.u_dut.h_m1_q)) begin
            align_y  = img_filter_tb.u_dut.h_m1_q - img_filter_tb.u_dut.rem_f;
            align_h  = img_filter_tb.u_dut.h_m1_q + 1;
            align_hv = img_filter_tb.u_dut.hv_q;
            align_expected = 392'd0;
            align_bypass = 8'd0;
            for (align_k = -align_hv; align_k <= align_hv; align_k = align_k + 1) begin
                align_coef = cf[align_k + 24];
                if ((align_k == align_hv) && ((align_y + align_hv) < align_h)) begin
                    align_bypass = align_coef[7:0];
                end else begin
                    align_m = mirror_row(align_y + align_k, align_h);
                    align_bank = align_m % 49;
                    align_expected[align_bank*8 +: 8] =
                        align_expected[align_bank*8 +: 8] + align_coef[7:0];
                end
            end

            align_s1 = (align_y + 25) % 49;
            align_s2 = (23 - align_y) % 49;
            if (align_s2 < 0) align_s2 = align_s2 + 49;
            align_s3 = (((2*align_h + 23) % 49) - align_y) % 49;
            if (align_s3 < 0) align_s3 = align_s3 + 49;
            cov_s1[align_s1] = 1'b1;
            cov_s2[align_s2] = 1'b1;
            cov_s3[align_s3] = 1'b1;

            #0.05;
            align_checks = align_checks + 50;
            align_mismatch = (img_filter_tb.u_dut.cbp_cur !== align_bypass);
            for (align_bank = 0; align_bank < 49; align_bank = align_bank + 1) begin
                if (img_filter_tb.u_dut.ce_cur[align_bank] !==
                    (align_expected[align_bank*8 +: 8] != 8'd0))
                    align_mismatch = 1;
                if ((align_expected[align_bank*8 +: 8] != 8'd0) &&
                    (img_filter_tb.u_dut.c_cur[align_bank*8 +: 8] !==
                     align_expected[align_bank*8 +: 8]))
                    align_mismatch = 1;
            end
            if (align_mismatch) begin
                align_errors = align_errors + 1;
                errors = errors + 1;
                if (align_errors < 20)
                    $display("ALIGN ERROR y=%0d H=%0d hv=%0d cbp exp/got=%0d/%0d",
                             align_y, align_h, align_hv, align_bypass,
                             img_filter_tb.u_dut.cbp_cur);
                if (align_errors < 4)
                    for (align_bank = 0; align_bank < 49; align_bank = align_bank + 1)
                        if ((img_filter_tb.u_dut.ce_cur[align_bank] !==
                             (align_expected[align_bank*8 +: 8] != 8'd0)) ||
                            ((align_expected[align_bank*8 +: 8] != 8'd0) &&
                             (img_filter_tb.u_dut.c_cur[align_bank*8 +: 8] !==
                              align_expected[align_bank*8 +: 8])))
                            $display("  ALIGN bank=%0d exp=%0d/%b got=%0d/%b",
                                     align_bank,
                                     align_expected[align_bank*8 +: 8],
                                     (align_expected[align_bank*8 +: 8] != 8'd0),
                                     img_filter_tb.u_dut.c_cur[align_bank*8 +: 8],
                                     img_filter_tb.u_dut.ce_cur[align_bank]);
            end
        end
    end

    //-----------------------------------------------------------------------
    // Cycle / handshake monitors
    //-----------------------------------------------------------------------
    integer  cyc, dead, dead_max;
    integer  first_out_cycle;

    always @(posedge clk) begin
        if (rst_n) begin
            cyc = cyc + 1;
            if ((in_pix_rdy && in_pix_need) || (out_pix_rdy && out_pix_need))
                dead = 0;
            else begin
                dead = dead + 1;
                if (dead > dead_max) dead_max = dead;
                if (dead > DEADMAX) begin
                    $display("FATAL: %0d dead cycles at %0t", dead, $time);
                    errors = errors + 1;
                    $fatal(1);
                end
            end
        end
    end

    //-----------------------------------------------------------------------
    // Output checker
    //-----------------------------------------------------------------------
    integer   o_row, o_beat, o_cnt;
    integer   lane, comp, px;
    reg [9:0] exp_c, got_c;

    always @(posedge clk) begin
        if (rst_n && out_pix_rdy && out_pix_need) begin
            if (first_out_cycle < 0) first_out_cycle = cyc;
            if (o_row >= H) begin
                $display(
"ERROR: extra output beat %0d of %0d after frame end (%0t) state=%0d rem=%0d r=%0d c=%0d",
                         o_cnt, H*NB, $time, img_filter_tb.u_dut.state,
                         img_filter_tb.u_dut.rem_q, img_filter_tb.u_dut.r_cnt,
                         img_filter_tb.u_dut.c_cnt);
                $fflush;
                errors = errors + 1;
            end else begin
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    px = o_beat*4 + lane;
                    if (px < W) begin
                        for (comp = 0; comp < 4; comp = comp + 1) begin
                            exp_c = golden_comp(o_row, px, comp);
                            got_c = out_pix_data[lane*40 + comp*10 +: 10];
                            checks = checks + 1;
                            if (exp_c !== got_c) begin
                                errors = errors + 1;
                                if (errors < 20)
                                    $display(
    "ERROR row=%0d px=%0d comp=%0d exp=%0d got=%0d (%0t)",
                                    o_row, px, comp, exp_c, got_c, $time);
                            end
                        end
                    end
                end
            end
            o_cnt = o_cnt + 1;
            if (o_beat == NB-1) begin
                o_beat = 0;
                o_row  = o_row + 1;
            end else begin
                o_beat = o_beat + 1;
            end
        end
    end

    //-----------------------------------------------------------------------
    // Stimulus
    //-----------------------------------------------------------------------
    integer seed;
    integer in_gap, out_gap;
    reg [8*128-1:0] vcd_name;      // +VCD=<file>   : dump the DUT for PTPX
    reg [8*8-1:0]   case_name;     // +CASE=A|B     : one power/performance frame
    integer         case_acc;      // external SRAM accesses of that frame
    integer i, k, sum_c;
    reg [199:0] coef_v;

    // legal coefficient set: (blk_v-1)/2+1 values, blk_v symmetric taps, 128
    task make_coef;
        input integer bv;
        integer hvv, t, left, idx, v;
        begin
            hvv  = (bv-1)/2;
            for (idx = 0; idx <= 24; idx = idx + 1) wgt[idx] = 8'd0;
            left = 128;
            for (t = 0; t < 400; t = t + 1) begin
                idx = {$random(seed)} % (hvv+1);
                if (idx == hvv) begin
                    if (left >= 1 && wgt[idx] < 250) begin
                        wgt[idx] = wgt[idx] + 8'd1;
                        left     = left - 1;
                    end
                end else begin
                    if (left >= 2 && wgt[idx] < 250) begin
                        wgt[idx] = wgt[idx] + 8'd1;
                        left     = left - 2;
                    end
                end
            end
            wgt[hvv] = wgt[hvv] + left[7:0];
            // spec: only (blk_v-1)/2+1 low bytes are valid, the rest is
            // 8'hx.  Drive real X there so that any read of an unused
            // coefficient byte would corrupt the output and be caught.
            coef_v = {200{1'bx}};
            for (idx = 0; idx <= hvv; idx = idx + 1)
                coef_v[idx*8 +: 8] = wgt[idx];
            for (idx = 0; idx < 49; idx = idx + 1) cf[idx] = 8'd0;
            for (k = -hvv; k <= hvv; k = k + 1) begin
                v = (k < 0) ? -k : k;
                cf[k+24] = wgt[hvv-v];
            end
            sum_c = 0;
            for (k = -hvv; k <= hvv; k = k + 1) sum_c = sum_c + cf[k+24];
            if (sum_c != 128) begin
                $display("TB ERROR: coefficient sum %0d != 128", sum_c);
                errors = errors + 1;
            end
        end
    endtask

    task run_frame;
        input integer width;
        input integer height;
        input integer bv;
        input integer ingap;
        input integer outgap;
        input integer xgarbage;      // X on the unused lanes of a row tail
        integer beats, sent, rr, cc, ll, pxi;
        integer c0, c1, c2, c3;
        reg [159:0] beat;
        integer cyc0, mr0, mw0;
        begin
            W  = width;  H = height;  BV = bv;  HV = (bv-1)/2;
            NB = (W + 3) / 4;
            cov_blk_v[bv] = 1'b1;
            cov_width_mod4[width % 4] = 1'b1;
            if (height > 49) bank_wrap_frames = bank_wrap_frames + 1;
            in_gap = ingap;  out_gap = outgap;
            make_coef(bv);

            for (rr = 0; rr < H; rr = rr + 1) begin
                for (cc = 0; cc < W; cc = cc + 1) begin
                    c0 = {$random(seed)} % 1024;
                    c1 = {$random(seed)} % 1024;
                    c2 = {$random(seed)} % 1024;
                    c3 = {$random(seed)} % 1024;
                    img[rr*W + cc] = {c3[9:0], c2[9:0], c1[9:0], c0[9:0]};
                end
            end

            o_row = 0; o_beat = 0; o_cnt = 0;
            first_out_cycle = -1;
            cyc0 = cyc; mr0 = mem_reads; mw0 = mem_writes;

            @(negedge clk);
            frm_start  <= 1'b1;
            img_width  <= W - 1;
            img_height <= H - 1;
            blk_v      <= bv;
            coef       <= coef_v;
            @(negedge clk);
            frm_start  <= 1'b0;

            beats = H * NB;
            sent  = 0;
            fork
                begin : SEND
                    while (sent < beats) begin
                        rr   = sent / NB;
                        cc   = sent % NB;
                        beat = 160'd0;
                        for (ll = 0; ll < 4; ll = ll + 1) begin
                            pxi = cc*4 + ll;
                            if (pxi < W)
                                beat[ll*40 +: 40] = img[rr*W + pxi];
                            else if (xgarbage)
                                beat[ll*40 +: 40] = {40{1'bx}};
                            else
                                beat[ll*40 +: 40] = {$random(seed)};
                        end
                        @(negedge clk);
                        if (({$random(seed)} % 100) < in_gap) begin
                            in_pix_rdy  <= 1'b0;
                            in_pix_data <= {160{1'bx}};
                            #0.4;
                        end else begin
                            in_pix_rdy  <= 1'b1;
                            in_pix_data <= beat;
                            #0.4;                       // settle before posedge
                            if (in_pix_need) sent = sent + 1;
                        end
                    end
                    @(negedge clk);
                    in_pix_rdy  <= 1'b0;
                    in_pix_data <= {160{1'bx}};
                end
                begin : RECV
                    while (o_cnt < beats) begin
                        @(negedge clk);
                        out_pix_need <= (({$random(seed)} % 100) >= out_gap);
                    end
                    @(negedge clk);
                    out_pix_need <= 1'b0;
                end
            join

            frames = frames + 1;
            $display(
"  %4dx%-4d blk_v=%2d gap=%2d/%-2d : %6d cyc (ideal %5d), rd=%7d wr=%6d, 1st out +%0d",
                W, H, bv, ingap, outgap, cyc-cyc0, beats,
                mem_reads-mr0, mem_writes-mw0, first_out_cycle-cyc0);
            $fflush;
            if ((ingap == 0) && (first_out_cycle - cyc0 > (HV+1)*NB + 64)) begin
                $display("ERROR: first output latency %0d exceeds the blk_v bound",
                         first_out_cycle - cyc0);
                errors = errors + 1;
            end
            repeat (3) @(negedge clk);
            #0.4;
            if (out_pix_rdy !== 1'b0) begin
                $display(
"ERROR: stale out_pix_rdy after frame %0dx%0d blk_v=%0d (state=%0d rem=%0d r=%0d c=%0d)",
                    W, H, bv, img_filter_tb.u_dut.state,
                    img_filter_tb.u_dut.rem_q, img_filter_tb.u_dut.r_cnt,
                    img_filter_tb.u_dut.c_cnt);
                $fflush;
                errors = errors + 1;
            end
            repeat (20) @(negedge clk);
        end
    endtask

    // Randomised sweep.  Shapes and kernels are drawn freely and then shrunk
    // until the golden model cost stays reasonable, so the mix keeps changing
    // while the run time does not explode.
    task run_random;
        input integer n;
        input integer with_gaps;
        integer i, ww, hh, bb, gi_, go_, xg;
        begin
            for (i = 0; i < n; i = i + 1) begin
                ww = 24 + ({$random(seed)} % 300);
                hh = 24 + ({$random(seed)} % 200);
                bb =  1 + 2*({$random(seed)} % 25);
                while ((ww*hh*bb > 400000) && (hh > 32)) hh = hh - 8;
                while ((ww*hh*bb > 400000) && (ww > 32)) ww = ww - 8;
                if (ww > 1440) ww = 1440;
                gi_ = with_gaps ? ({$random(seed)} % 50) : 0;
                go_ = with_gaps ? ({$random(seed)} % 50) : 0;
                xg  = {$random(seed)} % 2;
                run_frame(ww, hh, bb, gi_, go_, xg);
            end
        end
    endtask

    //-----------------------------------------------------------------------
    // Directed frames for the four odd kernel sizes that the historical
    // directed list never drew explicitly (27, 31, 37, 45).  Each value is
    // run once with H = 24 (both mirror folds active, H < blk_v) and once
    // with H >= 49 (row -> bank modulo wraps) under handshake pressure and
    // X on the unused tail lanes.
    //-----------------------------------------------------------------------
    task run_blkv_gap;
        begin
            run_frame(  40,  24, 27,  0,  0, 0);
            run_frame(  30,  60, 27, 10, 10, 1);
            run_frame(  36,  31, 31,  0,  0, 0);   // H == blk_v
            run_frame(  25,  64, 31, 20, 20, 1);
            run_frame(  44,  24, 37,  0,  0, 0);
            run_frame(  32,  52, 37,  0, 30, 1);
            run_frame(  28,  24, 45,  0,  0, 0);
            run_frame(  33,  50, 45, 30,  0, 1);
        end
    endtask

    //-----------------------------------------------------------------------
    // +ALL_BLKV : every legal kernel size 1,3,...,49, two frames each
    //   frame 1 : W = 24..28 (every width mod 4), H = 24  -> both edges fold
    //   frame 2 : W = 32, H = 49..58 (bank wrap), handshake gaps, X lanes
    // The blk_v coverage mask must come out as 50'h2AAAAAAAAAAAA.
    //-----------------------------------------------------------------------
    task run_all_blkv;
        integer bv, w1, h2;
        begin
            for (bv = 1; bv <= 49; bv = bv + 2) begin
                w1 = 24 + ((bv/2) % 5);
                h2 = 49 + ((bv/2) % 4) * 3;
                run_frame(w1,  24, bv, 0, 0, (bv/2) % 2);
                run_frame(32,  h2, bv, (bv*7) % 40, (bv*11) % 40, 1);
            end
        end
    endtask

    //-----------------------------------------------------------------------
    // +CASE=A / +CASE=B : one frame shaped like the grading power cases.
    // The official stimulus is not published; the shapes below are the
    // documented working assumption (see docs/ppa_status.md):
    //   A (= performance case) : 1440 x 24, blk_v = 5, no handshake gaps,
    //                            (H+hv)*ceil(W/4)+21 = 9381 cycles ~ T0
    //   B (lower activity)     : 1440 x 24, blk_v = 3
    // Combine with +VCD=<file> to produce the activity file for PTPX; the
    // external-memory power term MPx = MEM_DWTH * accesses / 6400 is printed.
    //-----------------------------------------------------------------------
    task run_power_case;
        input [8*8-1:0] nm;
        integer mr0, mw0;
        begin
            mr0 = mem_reads; mw0 = mem_writes;
            case (nm)
                "A":     run_frame(1440, 24, 5, 0, 0, 0);
                "B":     run_frame(1440, 24, 3, 0, 0, 0);
                default: begin
                    $display("TB ERROR: unknown +CASE=%0s (use A or B)", nm);
                    errors = errors + 1;
                end
            endcase
            case_acc = (mem_reads - mr0) + (mem_writes - mw0);
            $display("POWER CASE %0s: mem accesses=%0d  MPx=`MEM_DWTH*acc/6400=%0d",
                     nm, case_acc, (DW * case_acc) / 6400);
        end
    endtask

    //-----------------------------------------------------------------------
    initial begin
        seed = 32'h1234_5678;
        if ($value$plusargs("SEED=%h", seed)) begin end
        errors = 0; checks = 0; frames = 0;
        align_checks = 0; align_errors = 0; bank_wrap_frames = 0;
        cov_blk_v = 50'd0; cov_width_mod4 = 4'd0;
        cov_s1 = 49'd0; cov_s2 = 49'd0; cov_s3 = 49'd0;
        mem_reads = 0; mem_writes = 0;
        cyc = 0; dead = 0; dead_max = 0;
        o_row = 0; o_beat = 0; o_cnt = 0;
        W = 4; H = 1; NB = 1; HV = 0;
        first_out_cycle = -1;
        in_pix_rdy = 0; in_pix_data = 0; out_pix_need = 0;
        frm_start = 0; img_width = 0; img_height = 0; blk_v = 1; coef = 0;
        rst_n = 0;
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (5) @(negedge clk);

        $display("== IMG_FILTER regression seed=0x%08x ==", seed);
        $fflush;

        // optional activity dump for PTPX (+VCD_PORTS: DUT ports only)
        if ($value$plusargs("VCD=%s", vcd_name)) begin
            $dumpfile(vcd_name);
            if ($test$plusargs("VCD_PORTS")) $dumpvars(1, img_filter_tb.u_dut);
            else                             $dumpvars(0, img_filter_tb.u_dut);
        end

        if ($test$plusargs("ALIGN4096_ONLY")) begin
            W = 24; H = 4096; BV = 3; HV = 1; NB = 6;
            make_coef(3);
            @(negedge clk);
            frm_start  <= 1'b1;
            img_width  <= 11'd23;
            img_height <= 12'd4095;
            blk_v      <= 6'd3;
            coef       <= coef_v;
            @(negedge clk);
            frm_start  <= 1'b0;
            wait (align_checks != 0);
            repeat (2) @(negedge clk);
            $display("ALIGN4096 checks=%0d errors=%0d", align_checks, align_errors);
            if (align_errors == 0) begin
                $display("ALIGN4096 TEST PASSED");
                $finish;
            end
            $fatal(1, "ALIGN4096 TEST FAILED");
        end

        if ($test$plusargs("H4096_ONLY")) begin
        run_frame(  24,4096,  3,  0,  0, 0);
        end else if ($value$plusargs("CASE=%s", case_name)) begin
        run_power_case(case_name);
        end else if ($test$plusargs("BLKV_GAP")) begin
        run_blkv_gap;
        end else if ($test$plusargs("ALL_BLKV")) begin
        run_all_blkv;
        if (cov_blk_v !== 50'h2AAAAAAAAAAAA) begin
            $display("ERROR: blk_v coverage mask %013h != 2AAAAAAAAAAAA", cov_blk_v);
            errors = errors + 1;
        end
        end else begin
        run_frame(  32,  24,  1,  0,  0, 0);   // pass through
        run_frame(  32,  24,  3,  0,  0, 0);
        run_frame(  28,  25,  5,  0,  0, 0);
        run_frame(  26,  24,  7,  0,  0, 1);   // width not a multiple of 4
        run_frame(  25,  27,  9,  0,  0, 1);
        run_frame(  24,  24, 49,  0,  0, 0);   // both edges fold, minimum H
        run_frame(  24,  25, 49,  0,  0, 0);
        run_frame(  32,  48, 49,  0,  0, 0);
        run_frame(  24,  30, 47,  0,  0, 0);
        run_frame(  32,  30, 25, 40,  0, 0);   // input starvation
        run_frame(  32,  30, 25,  0, 40, 0);   // output back pressure
        run_frame(  40,  32, 49, 30, 30, 0);
        run_frame(  24,  24, 49, 60, 60, 1);
        // +SMOKE stops here: the 13 frames above cover pass-through, both
        // mirror folds, minimum H, non-multiple-of-4 widths, starvation,
        // back pressure and X injection in interpreter-friendly sizes.
        // The full set below adds bank-wrap, wide/tall extremes, the eight
        // blk_v-gap frames and the randomized sweeps (hours under Icarus -
        // run before release).  +BLKV_GAP / +ALL_BLKV / +CASE=A|B select
        // the directed subsets described at the tasks above.
        if (!$test$plusargs("SMOKE")) begin
        // taller than the bank count: the row -> bank modulo wraps around
        run_frame(  24,  49, 49,  0,  0, 0);
        run_frame(  24,  50, 49,  0,  0, 0);
        run_frame(  28,  51, 49,  0,  0, 0);
        run_frame(  32, 120, 49,  0,  0, 0);
        run_frame(  32, 100, 25, 10, 10, 0);
        run_frame(  24, 512,  3,  0,  0, 0);   // long frame, counter range
        run_frame( 320,  40, 13,  0,  0, 0);   // throughput reference
        run_frame(1440,  26, 49,  0,  0, 0);
        run_frame( 640,  32,  3,  0,  0, 0);
        run_frame(  27,  24, 11,  0,  0, 1);
        run_frame(  29,  31, 21, 10, 10, 1);
        run_frame(1439,  24,  1,  0,  0, 1);
        // the four kernel sizes the list above never drew directly
        run_blkv_gap;
        // maximum legal height: 12 bit row counters and 84 wraps of the bank
        // index inside one frame
        run_frame(  24,4096,  3,  0,  0, 0);
        // randomised sweep, first without and then with handshake pressure
        run_random(14, 0);
        run_random(14, 1);
        end
        end

        $display(
"== %0d frames, %0d component checks, %0d errors, longest dead run %0d ==",
                 frames, checks, errors, dead_max);
        $display("ALIGNMENT checks=%0d errors=%0d", align_checks, align_errors);
        $display("COVERAGE blk_v=%013h width_mod4=%h bank_wrap_frames=%0d",
                 cov_blk_v, cov_width_mod4, bank_wrap_frames);
        $display("COVERAGE shifts s1=%013h s2=%013h s3=%013h",
                 cov_s1, cov_s2, cov_s3);
        if (errors == 0) begin
            $display("TEST PASSED");
            $fflush;
            $finish;
        end else begin
            $display("TEST FAILED");
            $fflush;
            $fatal(1);   // nonzero exit code so CI cannot miss a failure
        end
    end

    initial begin
        #20_000_000;
        $display("TEST FAILED: global timeout");
        $fatal(1);
    end

endmodule
