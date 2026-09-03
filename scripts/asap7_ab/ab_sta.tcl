# ab_sta.tcl - per-stage path delays of an ORFS synthesis netlist at the
# ASAP7 SS corner under DCG-like conditions (900 ps period, 150 ps setup
# uncertainty).  Absolute numbers are ASAP7 (pessimistic predictive PDK);
# only the differences between variants are meaningful.
#   AB_V=main ORFS=/root/ORFS sta -exit ab_sta.tcl
set V    $::env(AB_V)
set ORFS [expr {[info exists ::env(ORFS)] ? $::env(ORFS) : "/root/ORFS"}]
set LIB  $ORFS/flow/platforms/asap7/lib/NLDM
foreach f {asap7sc7p5t_AO_RVT_SS_nldm_211120.lib.gz
           asap7sc7p5t_INVBUF_RVT_SS_nldm_220122.lib.gz
           asap7sc7p5t_OA_RVT_SS_nldm_211120.lib.gz
           asap7sc7p5t_SIMPLE_RVT_SS_nldm_211120.lib.gz
           asap7sc7p5t_SEQ_RVT_SS_nldm_220123.lib} {
    read_liberty $LIB/$f
}
read_verilog $ORFS/flow/results/asap7/img_filter_ab$V/base/1_2_yosys.v
link_design IMG_FILTER

create_clock -name clk -period 900 [get_ports clk]
set_clock_uncertainty -setup 150 [get_clocks clk]
set_input_delay  -clock clk 0 [all_inputs -no_clocks]
set_output_delay -clock clk 0 [all_outputs]
set_false_path -from [get_ports rst_n]

puts "==== $V : summary ===="
report_worst_slack -max
report_tns -max
puts "==== $V : worst 3 paths, full ===="
report_checks -path_delay max -group_path_count 3 -endpoint_path_count 1 \
              -unique_paths_to_endpoint -format full
puts "==== $V : worst endpoints (unique, 10) ===="
report_checks -path_delay max -group_path_count 10 -endpoint_path_count 1 \
              -unique_paths_to_endpoint -format end

# Stage = worst path between two register groups.  OpenSTA -regexp patterns
# must match the whole instance name (yosys names: rdata_q[7834]$_DFFE_PP_).
proc stage {name from to} {
    global V
    set f [get_cells -hierarchical -regexp $from]
    set t [get_cells -hierarchical -regexp $to]
    if {[llength $t] == 0} { set t [get_ports -regexp $to] }
    if {[llength $f] == 0 || [llength $t] == 0} {
        puts "==== $V : stage $name : NO CELLS (from [llength $f], to [llength $t]) ===="
        return
    }
    puts "==== $V : stage $name ([llength $f] -> [llength $t] regs) ===="
    report_checks -path_delay max -from $f -to $t -group_path_count 1 -format full
}
stage "rdata_q->MAC1"     {rdata_q\[.*}                 {(pair_q|pplo_q|pphi_q)\[.*}
stage "MAC1->pair_q"      {(pplo_q|pphi_q)\[.*}         {pair_q\[.*}
stage "pair_q->part_q"    {pair_q\[.*}                  {part_q\[.*}
stage "part_q->output"    {part_q\[.*}                  {(out_pix_data|oskid_d)\[.*}
stage "rotatorA"          {(a_sym|rem_f|ymod_f|tlo_f|mod_x|coef_q|hv_q).*} {(cvlo[123]_q|shi[123]_q|cbp_mid_q).*}
stage "rotatorB"          {(cvlo[123]_q|shi[123]_q).*}  {(c_fut|ce_fut)\[.*}
stage "ctrl->memcmd"      {(icnt|out_v_q|oskid_v|state|c_cnt|nbm1_q|ce_cur|cbp_cur).*} {(m_ce|m_1h|m_out|m_addr).*}
puts "==== $V : DONE ===="
