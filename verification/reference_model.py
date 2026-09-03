#!/usr/bin/env python3
"""Executable specification and architecture cross-check for IMG_FILTER.

Three independent things are checked here:

1. ``golden_filter``  - the filter exactly as the interface specification defines it
   (mirrorMap pseudo code, symmetric coefficients, +64 >> 7, clamp to 1023).

2. ``weight_vector``  - the *architecture* the RTL implements: for output row
   y it builds the per-bank weight vector C[0..48] out of three rotations of
   the symmetric coefficient array, exactly as ``img_filter.v`` does, and then
   proves that

       sum_j C[j] * bank_j  +  C_bp * forwarded_row   ==   the golden sum

   for every output row.  This is the part that replaces all per-tap mirror
   logic in hardware, so it is worth proving separately from simulation.

3. the storage invariants the design relies on: the bank that is written in a
   cycle is never one of the banks that are read in that cycle, every bank
   that is read holds a row that has already been written, and every source
   row of the 49 tap window is inside the 49 row bank window.

Run:  python3 reference_model.py
"""

import random
import sys

NBK = 49          # `MEM_NUM
HALF_MAX = 24     # (49-1)/2


# ---------------------------------------------------------------- spec model
def mirror_map(pos, height):
    """The reference mirror-boundary mapping, transcribed literally."""
    cnt = 0
    while pos < 0 or pos >= height:
        cnt += 1
        if pos < 0:
            pos += height
        else:
            pos -= height
    if cnt % 2 == 1:
        return height - 1 - pos
    return pos


def expand_coef(coef_half, blk_v):
    """coef[i] (i = 0..hv, low byte first) -> weight of tap k, k = -hv..hv.

    coef[0] is the bottom pixel of the reference block, coef[hv] the centre,
    and the upper half is the mirror of the lower half.
    """
    hv = (blk_v - 1) // 2
    return {k: coef_half[hv - abs(k)] for k in range(-hv, hv + 1)}


def golden_filter(img, H, W, blk_v, coef_half):
    """img[y][x] = (c0,c1,c2,c3); returns the filtered image."""
    hv = (blk_v - 1) // 2
    cf = expand_coef(coef_half, blk_v)
    out = []
    for y in range(H):
        row = []
        for x in range(W):
            pix = []
            for comp in range(4):
                acc = 0
                for k in range(-hv, hv + 1):
                    m = mirror_map(y + k, H)
                    acc += img[m][x][comp] * cf[k]
                acc = (acc + 64) >> 7
                pix.append(min(acc, 1023))
            row.append(tuple(pix))
        out.append(row)
    return out


# ------------------------------------------------------- architecture model
def rot49(arr, s):
    """rot49(a,s)[j] = a[(j-s) % 49]."""
    return [arr[(j - s) % NBK] for j in range(NBK)]


def rev49(arr):
    """rev49(a)[i] = a[(49-i) % 49]."""
    return [arr[(NBK - i) % NBK] for i in range(NBK)]


def weight_vector(y, H, blk_v, coef_half):
    """Reproduce the RTL weight vector for output row y.

    Returns (C[0..48], C_bypass, bypass_active).
    """
    hv = (blk_v - 1) // 2
    cf = expand_coef(coef_half, blk_v)

    # A[i] = weight of tap k = i-24, zero outside the kernel
    A = [cf.get(i - HALF_MAX, 0) for i in range(NBK)]

    rem = H - 1 - y                       # rows still to come
    tlo = max(0, HALF_MAX - y)            # first i with y+k >= 0
    thi = 48 if rem >= HALF_MAX else 24 + rem
    byp = rem >= hv                       # row y+hv is still streaming in

    m_int = [0] * NBK
    m_top = [0] * NBK
    m_bot = [0] * NBK
    for i in range(NBK):
        if i < tlo:
            m_top[i] = A[i]
        elif i > thi:
            m_bot[i] = A[i]
        elif byp and i == HALF_MAX + hv:
            pass                          # forwarded, not fetched from memory
        else:
            m_int[i] = A[i]

    s1 = (y - HALF_MAX) % NBK
    s2 = (23 - y) % NBK
    s3 = (2 * H + 23 - y) % NBK

    c1 = rot49(m_int, s1)
    c2 = rot49(rev49(m_top), s2)
    c3 = rot49(rev49(m_bot), s3)

    C = [c1[j] + c2[j] + c3[j] for j in range(NBK)]
    c_bp = cf[hv] if byp else 0
    return C, c_bp, byp


def check_architecture(H, W, blk_v, coef_half, img):
    """Prove the weight vector reproduces the golden result and that the
    storage invariants hold, for a whole frame."""
    hv = (blk_v - 1) // 2
    cf = expand_coef(coef_half, blk_v)
    problems = []

    for y in range(H):
        C, c_bp, byp = weight_vector(y, H, blk_v, coef_half)

        # total weight must always be 128 (the spec guarantees sum coef = 128)
        tot = sum(C) + c_bp
        if tot != 128:
            problems.append("row %d: weights total %d, expected 128"
                            % (y, tot))

        # the newest row that exists when output row y is produced
        newest = min(y + hv, H - 1)
        window = range(max(0, newest - (NBK - 1)), newest + 1)
        wr_bank = newest % NBK if byp else None

        for j in range(NBK):
            if C[j] == 0:
                continue
            rows = [m for m in window if m % NBK == j]
            if not rows:
                problems.append("row %d: bank %d weighted but holds no row"
                                % (y, j))
                continue
            if rows[0] > newest:
                problems.append("row %d: bank %d not written yet" % (y, j))
            if wr_bank is not None and j == wr_bank:
                problems.append("row %d: bank %d read and written together"
                                % (y, j))

        # arithmetic equivalence, checked on the real pixel data
        for x in range(W):
            for comp in range(4):
                arch = 0
                for j in range(NBK):
                    if C[j] == 0:
                        continue
                    m = [r for r in window if r % NBK == j][0]
                    arch += img[m][x][comp] * C[j]
                if byp:
                    arch += img[newest][x][comp] * c_bp
                spec = 0
                for k in range(-hv, hv + 1):
                    spec += img[mirror_map(y + k, H)][x][comp] * cf[k]
                if arch != spec:
                    problems.append(
                        "row %d x %d comp %d: arch %d != spec %d"
                        % (y, x, comp, arch, spec))
                    return problems
    return problems


# ---------------------------------------------------------------- utilities
def random_coef(rng, blk_v):
    """A legal coefficient set: hv+1 bytes whose symmetric expansion is 128."""
    hv = (blk_v - 1) // 2
    w = [0] * (hv + 1)
    left = 128
    while left > 0:
        i = rng.randrange(hv + 1)
        step = 1 if i == hv else 2
        if left >= step and w[i] < 250:
            w[i] += 1
            left -= step
        elif left == 1:
            w[hv] += 1
            left = 0
    return w


def random_image(rng, H, W):
    return [[tuple(rng.randrange(1024) for _ in range(4)) for _ in range(W)]
            for _ in range(H)]


# -------------------------------------------------------------------- tests
def main():
    rng = random.Random(20260821)
    fails = 0

    print("1. mirrorMap corner cases")
    cases = [
        (-1, 24, 0), (-2, 24, 1), (-24, 24, 23), (24, 24, 23),
        (25, 24, 22), (47, 24, 0), (-25, 24, 23), (0, 24, 0), (23, 24, 23),
        (-4, 4, 3), (-5, 4, 3), (-6, 4, 2), (4, 4, 3), (7, 4, 0),
    ]
    for pos, h, want in cases:
        got = mirror_map(pos, h)
        if got != want:
            print("   FAIL mirror_map(%d,%d) = %d, expected %d"
                  % (pos, h, got, want))
            fails += 1
    print("   %d cases" % len(cases))

    print("2. single fold holds for every legal shape (H >= 24, |k| <= 24)")
    bad = 0
    for h in range(24, 200):
        for k in range(-HALF_MAX, HALF_MAX + 1):
            for y in (0, 1, 2, h // 2, h - 3, h - 2, h - 1):
                pos = y + k
                if pos < 0 and pos < -h:
                    bad += 1
                if pos >= h and pos > 2 * h - 1:
                    bad += 1
    if bad:
        print("   FAIL: %d positions need more than one fold" % bad)
        fails += 1
    else:
        print("   ok: -H <= y+k <= 2H-1 always, one reflection is enough")

    print("3. architecture equals specification")
    shapes = [(24, 8), (25, 8), (26, 5), (30, 4), (48, 6), (49, 4), (50, 4),
              (51, 4), (60, 3), (97, 3), (98, 3), (99, 3), (128, 2)]
    kernels = [1, 3, 5, 7, 11, 23, 25, 47, 49]
    checked = 0
    for (H, W) in shapes:
        for blk_v in kernels:
            coef_half = random_coef(rng, blk_v)
            img = random_image(rng, H, W)
            problems = check_architecture(H, W, blk_v, coef_half, img)
            checked += 1
            if problems:
                fails += 1
                print("   FAIL H=%d W=%d blk_v=%d" % (H, W, blk_v))
                for p in problems[:5]:
                    print("      " + p)
    print("   %d (shape, kernel) combinations" % checked)

    print("4. golden filter self consistency (flat image is preserved)")
    for blk_v in kernels:
        coef_half = random_coef(rng, blk_v)
        H, W = 30, 4
        img = [[(512, 1023, 0, 7)] * W for _ in range(H)]
        out = golden_filter(img, H, W, blk_v, coef_half)
        for y in range(H):
            for x in range(W):
                if out[y][x] != (512, 1023, 0, 7):
                    print("   FAIL blk_v=%d at (%d,%d): %s"
                          % (blk_v, y, x, out[y][x]))
                    fails += 1
                    break
    print("   a constant image survives every kernel (sum of coef = 128)")

    print("5. saturation head room")
    worst = (128 * 1023 + 64) >> 7
    print("   max possible result %d, output width 10 bit -> %s"
          % (worst, "no overflow" if worst <= 1023 else "OVERFLOW"))
    if worst > 1023:
        fails += 1


    print()
    if fails:
        print("FAILED (%d)" % fails)
        return 1
    print("ALL REFERENCE CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
