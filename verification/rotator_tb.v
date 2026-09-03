`timescale 1ns/1ps

module rotator_tb;
    localparam CW = 392;
    reg clk = 0;
    reg rst_n = 0;
    wire in_pix_need, out_pix_rdy;
    wire [159:0] out_pix_data;
    wire [48:0] mem_ce, mem_we;
    wire [538:0] mem_addr;
    wire [7839:0] mem_wdata;

    IMG_FILTER dut (
        .clk(clk), .rst_n(rst_n), .in_pix_rdy(1'b0),
        .in_pix_need(in_pix_need), .in_pix_data(160'd0),
        .out_pix_rdy(out_pix_rdy), .out_pix_need(1'b0),
        .out_pix_data(out_pix_data), .frm_start(1'b0),
        .img_width(11'd23), .img_height(12'd23), .blk_v(6'd1),
        .coef(200'd0), .mem_ce(mem_ce), .mem_we(mem_we),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_rdata(7840'd0)
    );

    reg [CW-1:0] vec, got, expected;
    integer shift, pattern, byte_index, errors, checks, seed;

    function [CW-1:0] reference_rot49;
        input [CW-1:0] value;
        input integer amount;
        integer j, src;
        begin
            reference_rot49 = {CW{1'b0}};
            for (j = 0; j < 49; j = j + 1) begin
                src = j - amount;
                while (src < 0) src = src + 49;
                reference_rot49[j*8 +: 8] = value[src*8 +: 8];
            end
        end
    endfunction

    task check_all_shifts;
        begin
            for (shift = 0; shift < 49; shift = shift + 1) begin
                got = dut.rot49_hi(dut.rot49_lo(vec, shift[2:0]), shift[5:3]);
                expected = reference_rot49(vec, shift);
                checks = checks + 1;
                if (got !== expected) begin
                    errors = errors + 1;
                    $display("ROTATOR ERROR pattern=%0d shift=%0d", pattern, shift);
                end
            end
        end
    endtask

    initial begin
        errors = 0;
        checks = 0;
        seed = 32'h49a5_17c3;

        vec = {CW{1'b0}};
        for (byte_index = 0; byte_index < 49; byte_index = byte_index + 1)
            vec[byte_index*8 +: 8] = byte_index;
        pattern = 0;
        check_all_shifts;

        vec = {CW{1'b1}};
        pattern = 1;
        check_all_shifts;

        for (pattern = 2; pattern < 66; pattern = pattern + 1) begin
            for (byte_index = 0; byte_index < 49; byte_index = byte_index + 1)
                vec[byte_index*8 +: 8] = $random(seed);
            check_all_shifts;
        end

        $display("ROTATOR COVERAGE shifts=0..48 patterns=%0d checks=%0d errors=%0d",
                 pattern, checks, errors);
        if (errors == 0) begin
            $display("ROTATOR TEST PASSED");
            $finish;
        end
        $fatal(1, "ROTATOR TEST FAILED");
    end
endmodule
