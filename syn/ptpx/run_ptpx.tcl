#============================================================================
#  run_ptpx.tcl - PrimeTime PX power analysis of the DCG netlist
#
#  usage:
#    pt_shell -f run_ptpx.tcl -x "set CASE A; set VCD ../../verification/case_A.vcd"
#    pt_shell -f run_ptpx.tcl -x "set CASE B; set VCD ../../verification/case_B.vcd"
#
#  The activity file comes from the testbench:
#    vvp tb.vvp +CASE=A +VCD=case_A.vcd      (RTL activity, register names
#                                             mapped onto the netlist)
#  or from a gate-level simulation of ../dcg/outputs/IMG_FILTER.dcg.v with
#  the same testbench (exact activity, needs the cell library models).
#  Result: reports/power_<CASE>.rpt  ->  PAx / PBx  (Total Power, W)
#============================================================================
if {![info exists CASE]} { set CASE A }
if {![info exists VCD]}  { set VCD  ../../verification/case_${CASE}.vcd }
set DESIGN  IMG_FILTER
set NETLIST ../dcg/outputs/${DESIGN}.dcg.v
set SDC     ../dcg/outputs/${DESIGN}.dcg.sdc
set STRIP   img_filter_tb/u_dut          ;# testbench instance path in the VCD

source ../dcg/setup.tcl
sh mkdir -p reports

set_app_var power_enable_analysis   true
set_app_var power_analysis_mode     averaged   ;# time_based for peak-power waveforms

read_verilog $NETLIST
current_design $DESIGN
link_design
read_sdc $SDC
# DCG delivers no parasitics: PT estimates net capacitance from pin loads.
# If the environment provides a post-synthesis SPEF, read it here:
#   read_parasitics <file.spef>

read_vcd -strip_path $STRIP $VCD
# nets the VCD does not cover (synthesis-internal nets) are propagated from
# the annotated registers instead of taking a default toggle rate
set_app_var power_default_toggle_rate 0.0
update_power

report_switching_activity -list_not_annotated   > reports/not_annotated_${CASE}.rpt
report_power -verbose                           > reports/power_${CASE}.rpt
report_power -hierarchy -levels 2               > reports/power_hier_${CASE}.rpt
report_power -cell_power -nosplit               > reports/power_cells_${CASE}.rpt
exit
