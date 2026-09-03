# dc_stub.tcl - run the dc_shell / pt_shell flow scripts under plain tclsh.
#
# Every tool command (create_clock, compile_ultra, report_qor, ...) becomes a
# no-op that returns an empty string, so the scripts are executed for real
# as Tcl: syntax errors, undefined variables, broken control flow and wrong
# argument plumbing surface here, months before the single official run.
# What it cannot check: tool option names and report formats.
#
#   cd syn/dcg  && tclsh ../dc_stub.tcl run_dcg.tcl topo      (topographical)
#   cd syn/dcg  && tclsh ../dc_stub.tcl run_dcg.tcl           (plain)
#   cd syn/ptpx && tclsh ../dc_stub.tcl run_ptpx.tcl
#
set ::STUB_RUN  1
set ::STUB_TOPO [expr {[llength $argv] > 1 && [lindex $argv 1] eq "topo"}]
set ::STUB_CMDS {}
set search_path {}

rename exit ::stub_real_exit
proc exit {args} { puts "  (exit)" }
proc unknown {args} {
    lappend ::STUB_CMDS [lindex $args 0]
    return ""
}
proc shell_is_in_topographical_mode {} { return $::STUB_TOPO }
proc redirect {args} { uplevel 1 [lindex $args end] }
proc sh {args} { return "" }
proc get_lib_cells {args} { return {} }

set script [lindex $argv 0]
puts "== stub run of $script (topographical=$::STUB_TOPO, DCG_SETUP=[expr {[info exists ::env(DCG_SETUP)] ? $::env(DCG_SETUP) : {default}}])"
if {[catch {source $script} err]} {
    puts "STUB RUN FAILED: $err"
    puts $::errorInfo
    ::stub_real_exit 1
}
set uniq [lsort -unique $::STUB_CMDS]
puts "  tool commands invoked ([llength $uniq]): $uniq"
puts "== stub run OK: $script"
::stub_real_exit 0
