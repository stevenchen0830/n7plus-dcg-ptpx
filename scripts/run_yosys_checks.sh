#!/bin/sh
# Technology-independent structural checks with Yosys (no PDK needed):
#   1. REG_IN / REG_OUT      -> scripts/logs/check_reg_io.log
#   2. no latch / no memory  -> scripts/logs/synth_check.log (+ _stat.txt)
#   3. logic depth (ltp)     -> scripts/logs/depth_ltp.txt
# Usage: sh scripts/run_yosys_checks.sh            (yosys on PATH)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 2
mkdir -p scripts/logs
echo "== $(yosys -V 2>/dev/null | head -1)   $(date '+%Y-%m-%d %H:%M:%S')" | tee scripts/logs/yosys_versions.txt
RC=0

yosys -q -l scripts/logs/reg_io.log scripts/reg_io.ys > /dev/null 2>&1 || RC=1
python3 scripts/check_reg_io.py scripts/logs/reg_io.json > scripts/logs/check_reg_io.log 2>&1 || RC=1
tail -3 scripts/logs/check_reg_io.log

# the select -assert-none lines abort yosys (non-zero exit, no stat file)
# when a latch or memory cell survives
if yosys -l scripts/logs/synth_check.log scripts/synth_check.ys > /dev/null 2>&1    && grep -q "=== IMG_FILTER ===" scripts/logs/synth_check_stat.txt 2>/dev/null; then
    echo "synth_check: no latch / no memory assertions passed"
    grep -E "^\s+[0-9]+ +cells|_DFF|_SDFF" scripts/logs/synth_check_stat.txt
else
    echo "synth_check: FAILED (see scripts/logs/synth_check.log)"; RC=1
fi

yosys -l scripts/logs/depth.log scripts/depth.ys > /dev/null 2>&1 || RC=1
grep "Longest topological path" scripts/logs/depth_ltp.txt 2>/dev/null || { echo "depth: FAILED"; RC=1; }

echo "== yosys checks exit $RC"
exit $RC
