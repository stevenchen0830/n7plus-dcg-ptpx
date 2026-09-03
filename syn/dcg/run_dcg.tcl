#============================================================================
#  run_dcg.tcl - Design Compiler Graphical synthesis of IMG_FILTER
#
#  usage:  dc_shell -topographical -f run_dcg.tcl | tee dcg.log
#
#  environment knobs:
#    DCG_SETUP=./setup_asap7.tcl  library setup file (default ./setup.tcl,
#                                 the N7+ site setup; setup_asap7.tcl is
#                                 the open-library script shakedown)
#    DCG_RETIME_MAC=1             flow-level timing fallback: let
#                                 compile_ultra -retime move only the MAC
#                                 pipeline registers into the arithmetic
#
#  Produces in ./reports:
#     qor.rpt          - Critical Path Slack / TNS / cell area (Ax)
#     timing.rpt       - worst paths, input pins, transitions
#     area.rpt         - hierarchical cell area (Ax = Total cell area)
#     congestion.rpt   - global-route congestion (both / H / V <= 0.03)
#     power.rpt        - synthesis-level power (informational; the graded
#                        PA / PB values come from PTPX, see ../ptpx)
#     clock_gating.rpt - ICG inference summary
#     violators.rpt    - every constraint violator
#     reg_io_paths.rpt - worst path from each REG_IN port / to out_pix_data
#  and in ./outputs the netlist / ddc / sdc / sdf consumed by ../ptpx.
#============================================================================
set DESIGN   IMG_FILTER
set RTL_DIR  ../../rtl

if {[info exists ::env(DCG_SETUP)]} {
    source $::env(DCG_SETUP)
} else {
    source ./setup.tcl
}

sh mkdir -p work reports outputs
define_design_lib WORK -path ./work

# ---- read RTL -------------------------------------------------------------
# img_filter_def.v carries the `MEM_NUM / `MEM_DWTH macros and is read first
analyze -format verilog [list ${RTL_DIR}/img_filter_def.v ${RTL_DIR}/img_filter.v]
elaborate $DESIGN
current_design $DESIGN
link
uniquify
check_design > reports/check_design.rpt

# ---- physical setup (topographical mode) ----------------------------------
# A setup file without physical data (setup_asap7.tcl) sets NO_PHYSICAL_DATA
# and the flow runs in plain mode even inside a -topographical shell.
set TOPO [expr {[shell_is_in_topographical_mode] && ![info exists NO_PHYSICAL_DATA]}]
if {$TOPO} {
    if {[file exists work/${DESIGN}.mw]} { sh rm -rf work/${DESIGN}.mw }
    create_mw_lib -technology $MW_TECH_FILE \
                  -mw_reference_library $MW_REF_LIBS \
                  -bus_naming_style {[%d]} work/${DESIGN}.mw
    open_mw_lib work/${DESIGN}.mw
    check_library
    set_tlu_plus_files -max_tluplus $TLUPLUS_MAX -tech2itf_map $TLUPLUS_MAP
    check_tlu_plus_files
    set_ignored_layers -min_routing_layer $MIN_ROUTING_LAYER \
                       -max_routing_layer $MAX_ROUTING_LAYER
    # no macros inside the block (the SRAMs are external): let DCG build the
    # std-cell floorplan itself at a moderate utilization
    set_utilization 0.60
    set_aspect_ratio 1.0
} else {
    puts "WARNING: not in topographical mode - congestion / physical-aware results unavailable"
}

# ---- constraints ----------------------------------------------------------
source ./constraints.tcl

# ---- clock gating ---------------------------------------------------------
# The enable structure of the RTL (7840-bit SRAM read register, MAC pipeline
# registers, per-frame configuration registers) is meant to be turned into
# integrated clock-gating cells.  The ICG setup margin is applied in
# constraints.tcl (set_clock_gating_check).
set_clock_gating_style -sequential_cell latch \
                       -positive_edge_logic integrated \
                       -negative_edge_logic integrated \
                       -minimum_bitwidth 4 \
                       -max_fanout 64

# ---- compile --------------------------------------------------------------
set COMPILE_OPTS [list -gate_clock]
if {$TOPO} { lappend COMPILE_OPTS -spg }
# Optional MAC retiming (flow-level timing fallback, no RTL change).  Every
# register is pinned first - REG_IN / REG_OUT ports, control, the weight
# pipeline - and only the MAC pipeline registers are released, so retiming
# can move them into the multiply / add trees but nothing else.
if {[info exists ::env(DCG_RETIME_MAC)] && $::env(DCG_RETIME_MAC)} {
    set_dont_retime [all_registers] true
    set_dont_retime [get_cells -hierarchical {pair_q_reg* part_q_reg* prod_q_reg*}] false
    lappend COMPILE_OPTS -retime
    puts "INFO: MAC retiming enabled (DCG_RETIME_MAC)"
}
eval compile_ultra $COMPILE_OPTS -timing_high_effort_script
eval compile_ultra $COMPILE_OPTS -incremental

# ---- reports --------------------------------------------------------------
change_names -rules verilog -hierarchy
report_qor                                        > reports/qor.rpt
report_timing -max_paths 20 -nworst 1 -input_pins -transition_time \
              -capacitance -path full_clock_expanded > reports/timing.rpt
report_constraint -all_violators                  > reports/violators.rpt
report_area -hierarchy                            > reports/area.rpt
report_power -hierarchy -verbose                  > reports/power.rpt
report_clock_gating -gated -ungated               > reports/clock_gating.rpt
report_resources                                  > reports/resources.rpt
if {$TOPO} {
    report_congestion                             > reports/congestion.rpt
}
# REG_IN / REG_OUT sanity straight from the netlist: every input (except the
# five exempt ones) must reach only flop D pins, out_pix_data must be a Q pin
redirect reports/reg_io_paths.rpt {
    foreach p {in_pix_data mem_rdata img_width img_height blk_v coef} {
        puts "== from $p =="
        report_timing -from [get_ports ${p}*] -max_paths 1 -nosplit
    }
    puts "== to out_pix_data =="
    report_timing -to [get_ports out_pix_data*] -max_paths 1 -nosplit
}

# ---- outputs for PTPX / GLS ----------------------------------------------
write -format verilog -hierarchy -output outputs/${DESIGN}.dcg.v
write -format ddc     -hierarchy -output outputs/${DESIGN}.dcg.ddc
write_sdc outputs/${DESIGN}.dcg.sdc
write_sdf outputs/${DESIGN}.dcg.sdf
exit
