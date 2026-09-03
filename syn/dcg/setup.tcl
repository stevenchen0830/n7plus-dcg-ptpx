#============================================================================
#  setup.tcl - library / physical setup for the N7+ H240 DCG run
#
#  Assignment environment: N7+ process, H240 track cell library, corner
#  ssgnp 0.675 V / 125 C, Design Compiler Graphical (topographical mode),
#  1 GHz clock.  SVT / LVT / ULVT may all be used (no ratio limit).
#
#  Everything in this file is site specific.  The course environment owns
#  the PDK: set N7P_PDK_ROOT (or edit PDK_ROOT below) and adjust the file
#  name patterns to the local installation.  Nothing else under syn/ has to
#  change.
#============================================================================
if {[info exists ::env(N7P_PDK_ROOT)]} {
    set PDK_ROOT $::env(N7P_PDK_ROOT)
} else {
    set PDK_ROOT /pdk/n7p
}
set CORNER_TAG  ssgnp0p675v125c          ;# ssgnp, 0.675 V, 125 C
set TRACK       h240                      ;# H240 cell height
set VT_LIST     {svt lvt ulvt}            ;# all three allowed by the assignment

# ---- logical libraries (.db) ---------------------------------------------
set TARGET_LIBS {}
foreach vt $VT_LIST {
    lappend TARGET_LIBS ${PDK_ROOT}/std/${TRACK}/${vt}/db/${TRACK}_${vt}_${CORNER_TAG}.db
}
set_app_var search_path       [concat $search_path [list ../../rtl .]]
set_app_var target_library    $TARGET_LIBS
set_app_var link_library      [concat "*" $TARGET_LIBS dw_foundation.sldb]
set_app_var synthetic_library dw_foundation.sldb

# ---- physical data for topographical (DCG) mode ---------------------------
set MW_TECH_FILE ${PDK_ROOT}/tech/milkyway/n7p.tf
set MW_REF_LIBS  {}
foreach vt $VT_LIST {
    lappend MW_REF_LIBS ${PDK_ROOT}/std/${TRACK}/${vt}/milkyway/${TRACK}_${vt}
}
set TLUPLUS_MAX  ${PDK_ROOT}/tech/tluplus/cworst_T.tluplus
set TLUPLUS_MAP  ${PDK_ROOT}/tech/tluplus/star.map
set MIN_ROUTING_LAYER M2
set MAX_ROUTING_LAYER M8

# ---- misc ----------------------------------------------------------------
set_app_var sh_enable_page_mode                    false
set_app_var hdlin_infer_multibit                   default_all  ;# multibit flops for the wide registers
set_app_var compile_clock_gating_through_hierarchy true
set_app_var alib_library_analysis_path             ./work
