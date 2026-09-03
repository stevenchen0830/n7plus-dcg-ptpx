#!/usr/bin/env python3
"""REG_IN / REG_OUT structural check for IMG_FILTER.

Assignment rule:
  * every input except clk / rst_n / in_pix_rdy / out_pix_need / frm_start
    must be registered directly (REG_IN);
  * out_pix_data must come straight out of a register (REG_OUT).

The check walks the Yosys JSON netlist written by scripts/reg_io.ys
(register-level, enables folded into $dffe / $adffe cells):

  REG_IN  : every reader of an input-port bit must be a flip-flop cell, and
            the bit must land on its D input.  Any other cell type (mux,
            logic, arithmetic) between the port and a register is a
            violation.  Bits that nothing reads are reported as unused.
  REG_OUT : every bit of out_pix_data must be driven by the Q output of a
            flip-flop cell.

Usage:  python3 scripts/check_reg_io.py scripts/logs/reg_io.json
Exit code 0 = compliant, 1 = violation found.
"""
import json
import sys
from collections import defaultdict

TOP = "IMG_FILTER"
REG_IN_EXEMPT = {"clk", "rst_n", "in_pix_rdy", "out_pix_need", "frm_start"}
REG_OUT_PORTS = {"out_pix_data"}
FF_TYPES = {"$dff", "$dffe", "$adff", "$adffe", "$sdff", "$sdffe", "$sdffce",
            "$dffsr", "$dffsre", "$aldff", "$aldffe"}


def main(path):
    with open(path) as f:
        top = json.load(f)["modules"][TOP]
    ports = top["ports"]
    cells = top["cells"]

    readers = defaultdict(list)   # bit -> [(cell name, type, port)]
    drivers = {}                  # bit -> (cell name, type, port)
    for cname, c in cells.items():
        for pname, bits in c["connections"].items():
            direction = c["port_directions"].get(pname, "input")
            for b in bits:
                if not isinstance(b, int):
                    continue          # constant 0/1/x
                if direction == "output":
                    drivers[b] = (cname, c["type"], pname)
                else:
                    readers[b].append((cname, c["type"], pname))

    violations = []
    print("%-14s %6s %8s %8s  %s" % ("input port", "bits", "to-FF.D", "unused", "verdict"))
    for pname, p in sorted(ports.items()):
        if p["direction"] != "input" or pname in REG_IN_EXEMPT:
            continue
        to_ff, unused, bad = 0, 0, []
        for i, b in enumerate(p["bits"]):
            rl = readers.get(b, [])
            if not rl:
                unused += 1
                continue
            ok = all(t in FF_TYPES and port == "D" for (_, t, port) in rl)
            if ok:
                to_ff += 1
            else:
                bad.append((i, [(t, port) for (_, t, port) in rl if not (t in FF_TYPES and port == "D")]))
        verdict = "REG_IN ok" if not bad else "VIOLATION"
        print("%-14s %6d %8d %8d  %s" % (pname, len(p["bits"]), to_ff, unused, verdict))
        for i, what in bad[:5]:
            violations.append("%s[%d] read by %s" % (pname, i, what))
    # exempt inputs are allowed to be combinational: report only
    for pname in sorted(REG_IN_EXEMPT):
        if pname in ports:
            kinds = set()
            for b in ports[pname]["bits"]:
                for (_, t, port) in readers.get(b, []):
                    kinds.add(t)
            print("%-14s %6d  (exempt, readers: %s)" %
                  (pname, len(ports[pname]["bits"]), ", ".join(sorted(kinds)) or "none"))

    print()
    for pname in sorted(REG_OUT_PORTS):
        p = ports[pname]
        from_ff, bad = 0, []
        for i, b in enumerate(p["bits"]):
            d = drivers.get(b)
            if d and d[1] in FF_TYPES and d[2] == "Q":
                from_ff += 1
            else:
                bad.append((i, d))
        print("%-14s %6d bits, %d driven by FF.Q  %s" %
              (pname, len(p["bits"]), from_ff, "REG_OUT ok" if not bad else "VIOLATION"))
        for i, d in bad[:5]:
            violations.append("%s[%d] driven by %s" % (pname, i, d))
    # informational: the other outputs (no requirement)
    for pname, p in sorted(ports.items()):
        if p["direction"] == "output" and pname not in REG_OUT_PORTS:
            kinds = set()
            for b in p["bits"]:
                d = drivers.get(b)
                kinds.add(d[1] if d else "const/port")
            print("%-14s %6d bits, drivers: %s (no REG_OUT requirement)" %
                  (pname, len(p["bits"]), ", ".join(sorted(kinds))))

    print()
    if violations:
        print("REG_IN/REG_OUT CHECK FAILED")
        for v in violations:
            print("  " + v)
        return 1
    print("REG_IN/REG_OUT CHECK PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "scripts/logs/reg_io.json"))
