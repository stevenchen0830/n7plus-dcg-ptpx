#!/bin/sh
# ab_sta.sh <variant> : per-stage OpenSTA report of the ORFS synthesis
# netlist produced by ab_synth.sh (ASAP7 SS, 900 ps / 150 ps uncertainty).
# Output: $AB_WORK/<variant>/sta.log
V=$1
ORFS=${ORFS:-/root/ORFS}
WORK=${AB_WORK:-/root/ab}
HERE=$(cd "$(dirname "$0")" && pwd)
[ -n "$V" ] || { echo "usage: ab_sta.sh <variant>"; exit 2; }
STA=$ORFS/tools/install/OpenROAD/bin/sta
[ -x "$STA" ] || STA=sta
export AB_V=$V ORFS
cd "$WORK/$V" || exit 2
"$STA" -exit "$HERE/ab_sta.tcl" > sta.log 2>&1
RC=$?
echo "== sta exit $RC" >> sta.log
grep -E "worst slack|tns max|stage .*regs|NO CELLS|data arrival time" sta.log
exit $RC
