#!/bin/sh
# One-shot reproduction of the grading conditions on a machine that has the
# N7+ libraries, Design Compiler Graphical and PrimeTime PX:
#     N7P_PDK_ROOT=/path/to/pdk sh syn/run_all.sh
# Steps: DCG synthesis -> power-case activity from the testbench -> PTPX for
# case A and B -> score sheet.  Every step is skipped with a message when its
# tool is missing, so the script doubles as the checklist of what the
# official environment has to provide.
set -e
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)

if command -v dc_shell >/dev/null 2>&1; then
    (cd dcg && dc_shell -topographical -f run_dcg.tcl | tee dcg.log)
else
    echo "dc_shell not found - DCG synthesis skipped (needs the course environment)"
fi

if command -v iverilog >/dev/null 2>&1; then
    (cd "$ROOT" && VCD=verification/case_A.vcd sh scripts/run_sim.sh CASE_A \
                && VCD=verification/case_B.vcd sh scripts/run_sim.sh CASE_B)
else
    echo "iverilog not found - power-case activity files not generated"
fi

if command -v pt_shell >/dev/null 2>&1 && [ -f dcg/outputs/IMG_FILTER.dcg.v ]; then
    (cd ptpx && pt_shell -f run_ptpx.tcl -x "set CASE A; set VCD $ROOT/verification/case_A.vcd" | tee ptpx_A.log)
    (cd ptpx && pt_shell -f run_ptpx.tcl -x "set CASE B; set VCD $ROOT/verification/case_B.vcd" | tee ptpx_B.log)
else
    echo "pt_shell or the DCG netlist not found - PTPX skipped"
fi

python3 "$ROOT/scripts/score.py" --dcg-reports dcg/reports --ptpx-reports ptpx/reports \
        --sim-log "$ROOT/verification/logs/case_a.log" || true
