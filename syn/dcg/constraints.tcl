#============================================================================
#  constraints.tcl - timing constraints replicating the grading conditions
#
#  Assignment text (synthesis environment section):
#    * clock 1 GHz, must not be exceeded
#    * DCG mode reserves a 0.1 x period margin for PD: the real synthesis
#      period is 90 % of the setting                     -> 0.900 ns
#    * setup uncertainty for a 1 ns clock                 -> 0.150 ns
#    * extra setup uncertainty on ICG cells, P >= 0.66 ns -> 0.100 ns
#
#  Usable logic time per stage is therefore 0.900 - 0.150 = 0.750 ns minus
#  clk->q and setup.  See docs/ppa_status.md for the logic-depth budget.
#============================================================================
set CLK_PORT          clk
set CLK_PERIOD        1.000    ;# ns - the 1 GHz of the assignment
set DCG_MARGIN        0.10     ;# DCG: real synthesis period = 90 % of setting
set SETUP_UNC         0.150    ;# ns, table "1 ns -> 0.15 ns"
set ICG_SETUP_UNC     0.100    ;# ns, table "P >= 0.66 ns -> 0.10 ns"
# The course environment applies the DCG margin itself.  When this script
# runs standalone the margin is applied here; set to 0 if the wrapper
# already scales the period, otherwise the margin would be taken twice.
set APPLY_DCG_MARGIN  1

if {$APPLY_DCG_MARGIN} {
    set SYN_PERIOD [expr {$CLK_PERIOD * (1.0 - $DCG_MARGIN)}]
} else {
    set SYN_PERIOD $CLK_PERIOD
}
puts "INFO: synthesis clock period = $SYN_PERIOD ns (setting $CLK_PERIOD ns, DCG margin $DCG_MARGIN)"

create_clock -name clk -period $SYN_PERIOD [get_ports $CLK_PORT]
set_clock_uncertainty -setup $SETUP_UNC [get_clocks clk]
set_clock_transition  0.040 [get_clocks clk]
set_dont_touch_network [get_clocks clk]
# ICG check margin: the 0.100 ns is added ON TOP of the clock uncertainty
# (the stricter reading of the "ICG additional setup uncertainty" table).
set_clock_gating_check -setup $ICG_SETUP_UNC [get_clocks clk]

# rst_n is asynchronous and released by an external synchronizer (spec:
# released synchronously outside the module), so recovery / removal timing
# is guaranteed upstream.
set_false_path -from [get_ports rst_n]
set_ideal_network [get_ports rst_n]

# ---------------------------------------------------------------------------
# IO budgets.  The assignment defines REG_IN / REG_OUT, so every stream and
# configuration input lands on a flop D pin and out_pix_data leaves a flop
# Q pin; the budgets below only have to be generous enough not to fabricate
# violations on those direct paths.  The SRAM side models a single-port
# macro: clk->q on mem_rdata, setup on ce / we / addr / wdata.
# ---------------------------------------------------------------------------
set IN_DELAY_STREAM   [expr {0.50 * $SYN_PERIOD}]   ;# producer launches mid-cycle
set OUT_DELAY_STREAM  [expr {0.50 * $SYN_PERIOD}]   ;# consumer setup budget
set SRAM_CLK_TO_Q     0.450                          ;# ns, N7-class single-port SRAM
set SRAM_SETUP        0.200                          ;# ns, SRAM input setup

set stream_ins  [get_ports {in_pix_rdy in_pix_data* out_pix_need frm_start \
                            img_width* img_height* blk_v* coef*}]
set stream_outs [get_ports {in_pix_need out_pix_rdy out_pix_data*}]
set mem_ins     [get_ports mem_rdata*]
set mem_outs    [get_ports {mem_ce* mem_we* mem_addr* mem_wdata*}]

set_input_delay  -clock clk -max $IN_DELAY_STREAM  $stream_ins
set_input_delay  -clock clk -min 0.0               $stream_ins
set_output_delay -clock clk -max $OUT_DELAY_STREAM $stream_outs
set_output_delay -clock clk -min 0.0               $stream_outs
set_input_delay  -clock clk -max $SRAM_CLK_TO_Q    $mem_ins
set_input_delay  -clock clk -min 0.0               $mem_ins
set_output_delay -clock clk -max $SRAM_SETUP       $mem_outs
set_output_delay -clock clk -min 0.0               $mem_outs

# electrical environment (driving cell name follows the site library)
set DRIVING_CELL BUFFD4BWP240H8P51PDULVT
if {[llength [get_lib_cells -quiet */$DRIVING_CELL]] > 0} {
    set_driving_cell -lib_cell $DRIVING_CELL -no_design_rule \
        [remove_from_collection [all_inputs] [get_ports $CLK_PORT]]
} else {
    set_input_transition 0.050 [remove_from_collection [all_inputs] [get_ports $CLK_PORT]]
}
set_load 0.003 [all_outputs]                          ;# pF, next-stage flop + short wire
set_max_transition 0.150 [current_design]
set_max_fanout     32    [current_design]
set_max_area 0
