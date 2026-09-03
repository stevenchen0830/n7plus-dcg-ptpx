#!/bin/sh
# Execute every DC / PT flow script under plain tclsh with stubbed tool
# commands (syn/dc_stub.tcl): catches Tcl syntax errors, undefined variables
# and broken control flow in all setup / mode combinations.  Needs tclsh.
set -e
cd "$(dirname "$0")"
run() { echo "--- $*"; "$@"; }
(cd dcg  && run tclsh ../dc_stub.tcl run_dcg.tcl topo)
(cd dcg  && DCG_SETUP=./setup_asap7.tcl run tclsh ../dc_stub.tcl run_dcg.tcl)
(cd dcg  && DCG_SETUP=./setup_asap7.tcl DCG_RETIME_MAC=1 run tclsh ../dc_stub.tcl run_dcg.tcl topo)
(cd ptpx && run tclsh ../dc_stub.tcl run_ptpx.tcl)
(cd ptpx && DCG_SETUP=./setup_asap7.tcl run tclsh ../dc_stub.tcl run_ptpx.tcl)
echo "== all flow scripts executed under tclsh"
