#============================================================================
#  setup_asap7.tcl - script shakedown with the open ASAP7 predictive 7 nm
#  libraries, for a machine that has Design Compiler but no N7+ library.
#
#     cd syn/dcg
#     DCG_SETUP=./setup_asap7.tcl \
#     ASAP7_NLDM=/path/to/OpenROAD-flow-scripts/flow/platforms/asap7/lib/NLDM \
#     dc_shell -f run_dcg.tcl | tee dcg_asap7.log
#     cd ../ptpx
#     DCG_SETUP=./setup_asap7.tcl pt_shell -f run_ptpx.tcl -x "set CASE A; set VCD ..."
#
#  Purpose: execute run_dcg.tcl / constraints.tcl / run_ptpx.tcl end to end
#  (RTL read, ICG inference, REG_IN / REG_OUT path reports, area / timing /
#  power reports, netlist + SDC + SDF, PTPX activity read) BEFORE the single
#  official N7+ run, so that the official run is not the first execution
#  of these scripts.
#
#  The NUMBERS of such a run are not comparable with N7+: ASAP7 SS
#  (0.63 V / 100 C) is a pessimistic predictive corner, the RVT/LVT/SLVT
#  cells are 7.5-track, and without Milkyway / TLU+ data the flow runs in
#  plain (non-topographical) mode - no congestion report.
#============================================================================
if {[info exists ::env(ASAP7_NLDM)]} {
    set ASAP7_NLDM $::env(ASAP7_NLDM)
} else {
    set ASAP7_NLDM /root/ORFS/flow/platforms/asap7/lib/NLDM
}
set ASAP7_CORNER SS                        ;# SS 0.63 V / 100 C, the slow corner like ssgnp
set ASAP7_VT     {RVT LVT SLVT}            ;# three flavours, like SVT / LVT / ULVT
set ASAP7_GROUPS {SIMPLE AO OA INVBUF SEQ} ;# the five NLDM cell groups

# ASAP7 Liberty units: time 1 ps, capacitance 1 fF (N7+ .db: ns / pF);
# constraints.tcl multiplies every ns / pF value by these factors.
set TIME_SCALE 1000.0
set CAP_SCALE  1000.0
set DRIVING_CELL BUFx4_ASAP7_75t_R
set NO_PHYSICAL_DATA 1                     ;# no Milkyway / TLU+ -> plain dc_shell flow

# ---- .lib(.gz) -> .db, converted once into ./work/asap7_db ----------------
set DB_DIR work/asap7_db
if {![info exists ::STUB_RUN]} { file mkdir $DB_DIR }
set TARGET_LIBS {}
foreach vt $ASAP7_VT {
    foreach grp $ASAP7_GROUPS {
        # the ORFS checkout ships most groups gzipped and the SEQ group plain
        set pattern ${ASAP7_NLDM}/asap7sc7p5t_${grp}_${vt}_${ASAP7_CORNER}_nldm_*
        foreach lib [concat [glob -nocomplain ${pattern}.lib.gz] [glob -nocomplain ${pattern}.lib]] {
            set base [file tail $lib]
            while {[file extension $base] in {.gz .lib}} { set base [file rootname $base] }
            set db   ${DB_DIR}/${base}.db
            lappend TARGET_LIBS $db
            if {[file exists $db] || [info exists ::STUB_RUN]} { continue }
            set plain ${DB_DIR}/${base}.lib
            if {[file extension $lib] eq ".gz"} {
                exec gunzip -c $lib > $plain
            } else {
                file copy -force $lib $plain
            }
            # the library name is the first "library (...)" statement
            set libname ""
            set fh [open $plain r]
            while {[gets $fh line] >= 0} {
                if {[regexp {^\s*library\s*\(\s*"?([^\s")]+)"?\s*\)} $line -> libname]} { break }
            }
            close $fh
            if {$libname eq ""} { error "no library statement in $plain" }
            read_lib $plain
            write_lib $libname -format db -output $db
            remove_lib $libname
            file delete $plain
            puts "INFO: converted $base -> $db"
        }
    }
}
if {[llength $TARGET_LIBS] == 0 && ![info exists ::STUB_RUN]} {
    error "no ASAP7 Liberty files found under $ASAP7_NLDM (set ASAP7_NLDM)"
}
set_app_var search_path       [concat $search_path [list ../../rtl . $DB_DIR]]
set_app_var target_library    $TARGET_LIBS
set_app_var link_library      [concat "*" $TARGET_LIBS dw_foundation.sldb]
set_app_var synthetic_library dw_foundation.sldb

set_app_var sh_enable_page_mode                    false
set_app_var hdlin_infer_multibit                   default_all
set_app_var compile_clock_gating_through_hierarchy true
set_app_var alib_library_analysis_path             ./work
