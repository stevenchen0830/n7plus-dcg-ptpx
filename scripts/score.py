#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Score sheet for IMG_FILTER against the assignment's PPA grading rules.

    Score = T0/Tx*W_T + T0/Tx*PA0/PAx*W_PA + T0/Tx*PB0/PBx*W_PB + A0/Ax*W_A
            + min(10, MP0/MPx*W_MP) + min(10, MA0/MAx*W_MA)

    Tx  : performance-case duration (ps) at the DCG-converged frequency
    PAx : PTPX power of case A (W)          PBx : PTPX power of case B (W)
    Ax  : DCG cell area (um2)
    MPx : MEM_DWTH * (SRAM accesses in case A) / 6400
    MAx : MEM_NUM * MEM_DWTH / 5
    hard thresholds: Tx <= 11e6 ps, PAx <= 0.1 W, PBx <= 0.08 W,
                     Ax <= 100000 um2, congestion both/H/V <= 0.03
                     (any single miss -> score 0)

Values can be given on the command line or parsed from the DCG / PTPX
reports and the case-A simulation log.  Anything that is not available is
reported as PENDING instead of being guessed - the terms that need the N7+
environment cannot be settled without it.

    python3 scripts/score.py --cycles 9381 --wns -0.02 --area 41000 \
                             --pa 0.031 --pb 0.020 --mp-accesses 43200
    python3 scripts/score.py --dcg-reports syn/dcg/reports \
                             --ptpx-reports syn/ptpx/reports \
                             --sim-log verification/logs/case_a.log
"""
import argparse
import os
import re
import sys

# ---- assignment constants ----------------------------------------------------
TMAX, PAMAX, PBMAX, AMAX = 11_000_000, 0.10, 0.08, 100_000
CONG_MAX = 0.03
T0, PA0, PB0, A0, MP0, MA0 = 9_500_000, 0.035, 0.025, 30_000, 2400, 550
W_T, W_PA, W_PB, W_A, W_MP, W_MA = 30, 18, 12, 30, 5, 5
CLK_PS = 1000.0            # 1 GHz setting
DCG_MARGIN = 0.10          # real synthesis period = 90 % of the setting


def read_mem_config(def_file):
    num = dwth = None
    try:
        with open(def_file, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"\s*`define\s+MEM_NUM\s+(\d+)", line)
                if m:
                    num = int(m.group(1))
                m = re.match(r"\s*`define\s+MEM_DWTH\s+(\d+)", line)
                if m:
                    dwth = int(m.group(1))
    except OSError:
        pass
    return num or 49, dwth or 160


def grep_num(path, patterns):
    """First numeric match of any pattern in the file, else None."""
    if not path or not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    for pat in patterns:
        m = re.search(pat, text, re.MULTILINE | re.IGNORECASE)
        if m:
            return float(m.group(1))
    return None


def parse_dcg(d):
    out = {}
    if not d:
        return out
    out["wns"] = grep_num(os.path.join(d, "qor.rpt"),
                          [r"Critical Path Slack:\s*(-?[\d.]+)"])
    out["area"] = grep_num(os.path.join(d, "qor.rpt"), [r"Cell Area:\s*([\d.]+)"]) \
        or grep_num(os.path.join(d, "area.rpt"), [r"Total cell area:\s*([\d.]+)"])
    cong = os.path.join(d, "congestion.rpt")
    if os.path.isfile(cong):
        # DCG report_congestion: per-direction lines; take the overflow ratio
        # column (fraction or percent) - verify against the real report once
        with open(cong, encoding="utf-8", errors="replace") as f:
            for line in f:
                for key, tag in (("both", r"^\s*Both"), ("h", r"^\s*H\b"), ("v", r"^\s*V\b")):
                    if re.match(tag, line, re.IGNORECASE):
                        nums = re.findall(r"(-?\d+\.\d+)\s*(%?)", line)
                        if nums:
                            val, pct = nums[-1]
                            out["cong_" + key] = float(val) / (100.0 if pct else 1.0)
    return out


def parse_ptpx(d):
    out = {}
    if not d:
        return out
    for case in ("A", "B"):
        p = os.path.join(d, "power_%s.rpt" % case)
        v = grep_num(p, [r"Total Power\s*=\s*([\d.eE+-]+)",
                         r"^Total\s+(?:[\d.eE+-]+\s+){3}([\d.eE+-]+)"])
        unit = None
        if v is not None and os.path.isfile(p):
            with open(p, encoding="utf-8", errors="replace") as f:
                txt = f.read()
            m = re.search(r"Total Power\s*=\s*[\d.eE+-]+\s*\(?\s*(\w+)", txt)
            unit = m.group(1) if m else None
            if unit and unit.lower().startswith("mw"):
                v /= 1000.0
            elif unit and unit.lower().startswith("uw"):
                v /= 1e6
        out["p" + case.lower()] = v
    return out


def parse_sim_log(path):
    out = {}
    if not path or not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8", errors="replace") as f:
        txt = f.read()
    m = re.search(r"POWER CASE A: mem accesses=(\d+)", txt)
    if m:
        out["mp_accesses"] = int(m.group(1))
    m = re.search(r"blk_v=\s*\d+ gap=\s*\d+/\s*\d+\s*:\s*(\d+) cyc", txt)
    if m:
        out["cycles"] = int(m.group(1))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cycles", type=int, help="performance-case cycles (from the testbench)")
    ap.add_argument("--wns", type=float, help="DCG critical path slack in ns at the 0.9 ns synthesis period (negative = violation)")
    ap.add_argument("--area", type=float, help="DCG cell area, um2")
    ap.add_argument("--pa", type=float, help="PTPX power of case A, W")
    ap.add_argument("--pb", type=float, help="PTPX power of case B, W")
    ap.add_argument("--mp-accesses", type=int, help="SRAM accesses (reads + writes) in case A")
    ap.add_argument("--cong", type=float, nargs=3, metavar=("BOTH", "H", "V"))
    ap.add_argument("--dcg-reports")
    ap.add_argument("--ptpx-reports")
    ap.add_argument("--sim-log")
    ap.add_argument("--def-file", default=os.path.join(os.path.dirname(__file__), "..", "rtl", "img_filter_def.v"))
    a = ap.parse_args()

    v = {}
    v.update(parse_dcg(a.dcg_reports))
    v.update(parse_ptpx(a.ptpx_reports))
    v.update(parse_sim_log(a.sim_log))
    for k in ("cycles", "wns", "area", "pa", "pb", "mp_accesses"):
        if getattr(a, k) is not None:
            v[k] = getattr(a, k)
    if a.cong:
        v["cong_both"], v["cong_h"], v["cong_v"] = a.cong

    mem_num, mem_dwth = read_mem_config(a.def_file)
    print("=" * 72)
    print("IMG_FILTER score sheet   (MEM_NUM=%d, MEM_DWTH=%d)" % (mem_num, mem_dwth))
    print("=" * 72)

    total, pending, hard_fail = 0.0, [], []

    # ---- Tx ------------------------------------------------------------------
    cycles = v.get("cycles")
    wns = v.get("wns")
    if cycles is not None:
        if wns is None:
            period = CLK_PS
            note = "assumes DCG closes 1 GHz (no WNS given)"
            pending.append("Tx: DCG slack")
        elif wns >= 0:
            period = CLK_PS
            note = "DCG met at %.3f ns period (slack %+.3f ns)" % (CLK_PS / 1000 * (1 - DCG_MARGIN), wns)
        else:
            period = max(CLK_PS, (CLK_PS / 1000 * (1 - DCG_MARGIN) - wns) * 1000)
            note = "DCG slack %.3f ns -> converged period %.0f ps" % (wns, period)
        tx = cycles * period
        ok = tx <= TMAX
        s_t = T0 / tx * W_T
        total += s_t
        print("Tx    %12.0f ps  (thr %d)  %s  score %.2f/%d   [%s]" %
              (tx, TMAX, "PASS" if ok else "FAIL", s_t, W_T, note))
        if not ok:
            hard_fail.append("Tx")
    else:
        tx = None
        pending.append("Tx: performance-case cycles")
        print("Tx    PENDING  (run: sh scripts/run_sim.sh CASE_A)")

    # ---- PA / PB -------------------------------------------------------------
    for key, ref, thr, w, label in (("pa", PA0, PAMAX, W_PA, "PAx"), ("pb", PB0, PBMAX, W_PB, "PBx")):
        p = v.get(key)
        if p is None:
            pending.append("%s: PTPX" % label)
            print("%-5s PENDING  (needs PTPX, syn/ptpx/run_ptpx.tcl)" % label)
            continue
        ok = p <= thr
        if tx is not None:
            s = T0 / tx * ref / p * w
            total += s
            print("%-5s %12.4f W   (thr %.2f)  %s  score %.2f/%d" % (label, p, thr, "PASS" if ok else "FAIL", s, w))
        else:
            print("%-5s %12.4f W   (thr %.2f)  %s  score needs Tx" % (label, p, thr, "PASS" if ok else "FAIL"))
            pending.append("%s score: needs Tx" % label)
        if not ok:
            hard_fail.append(label)

    # ---- Ax ------------------------------------------------------------------
    area = v.get("area")
    if area is None:
        pending.append("Ax: DCG area")
        print("Ax    PENDING  (needs DCG, syn/dcg/run_dcg.tcl)")
    else:
        ok = area <= AMAX
        s_a = A0 / area * W_A
        total += s_a
        print("Ax    %12.0f um2 (thr %d)  %s  score %.2f/%d" % (area, AMAX, "PASS" if ok else "FAIL", s_a, W_A))
        if not ok:
            hard_fail.append("Ax")

    # ---- MPx / MAx -----------------------------------------------------------
    acc = v.get("mp_accesses")
    if acc is None:
        pending.append("MPx: case-A SRAM accesses")
        print("MPx   PENDING  (run: sh scripts/run_sim.sh CASE_A)")
    else:
        mp = mem_dwth * acc / 6400.0
        s_mp = min(10.0, MP0 / mp * W_MP) if mp > 0 else 10.0
        total += s_mp
        print("MPx   %12.1f     (ref %d)  accesses=%d  score %.2f/10" % (mp, MP0, acc, s_mp))
    ma = mem_num * mem_dwth / 5.0
    s_ma = min(10.0, MA0 / ma * W_MA)
    total += s_ma
    print("MAx   %12.1f     (ref %d)  score %.2f/10" % (ma, MA0, s_ma))

    # ---- congestion ----------------------------------------------------------
    cong = [v.get("cong_both"), v.get("cong_h"), v.get("cong_v")]
    if any(c is None for c in cong):
        pending.append("congestion: DCG report_congestion")
        print("cong  PENDING  (both / H / V from syn/dcg/reports/congestion.rpt)")
    else:
        ok = all(c <= CONG_MAX for c in cong)
        print("cong  both=%.4f H=%.4f V=%.4f (thr %.2f)  %s" % (cong[0], cong[1], cong[2], CONG_MAX, "PASS" if ok else "FAIL"))
        if not ok:
            hard_fail.append("congestion")

    print("-" * 72)
    if hard_fail:
        print("HARD THRESHOLD MISSED: %s  -> assignment score = 0" % ", ".join(hard_fail))
    elif pending:
        print("partial score %.2f (terms available so far); PENDING: %s" % (total, "; ".join(pending)))
    else:
        print("TOTAL SCORE %.2f / 110" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
