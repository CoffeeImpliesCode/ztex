#!/usr/bin/env python3
"""Numerical glyph-alignment comparison for TeX engine outputs.

Implements notes/compare-design.md. Reads two per-glyph JSON records
(--ours, --ref), normalizes them, aligns glyphs with Needleman-Wunsch on
glyph identity, and writes a delta report (JSON) plus human-readable
sentences (stdout).

Usage:
  python3 scripts/compare_engines.py --ours a.json --ref b.json --out res.json
      [--baseline mode|first-top|bbox-center] [--top 5] [--px] [--dpi 96]
  python3 scripts/compare_engines.py --selftest

Per-glyph records may carry an "ink" bbox ([xmin, ymin, xmax, ymax], same
y-up space as x/y); when both sides carry it, the report additionally
compares ink left edges, ink tops and ink width/height extents, and the
verdict flags pairs whose ink deviates by more than 15% on any axis.
"""
import argparse
import json
import math
import sys
import unicodedata
from collections import Counter

MATCH_SCORE = 4.0       # exact codepoint match
NORMEQ_SCORE = 2.0      # NFC-canonical match
MISMATCH_SCORE = -4.0
GAP_PENALTY = -1.0
PT_PER_INCH = 72.0

# Ink comparison thresholds. The ink channel is [xmin, ymin, xmax, ymax] in
# the same y-up space as x/y (see normalize); deltas and ratios are computed
# against the reference ink bbox.
INK_FLAG = 0.15      # |width_ratio-1|, |height_ratio-1|, |dxi| or |dyi| above
                     # this marks the pair ink-anomalous (verdict "ink")
INK_REPORT = 0.05    # ink clause shown in the human sentence above this
# Box-layout verdict thresholds (pt)
LAYOUT_MAX_DX = 1.0
LAYOUT_MAX_DY = 0.5
LAYOUT_MEAN_DX = 0.5
LAYOUT_MEAN_DY = 0.25


def glyph_equal(a, b):
    """Exact codepoint equality."""
    return a == b


# Math symbols engines typeset with different (but visually identical)
# codepoints: XeTeX emits the plain-text codepoint (· U+00B7, - U+002D)
# where ztex emits the Unicode math codepoint (⋅ U+22C5, − U+2212).
# Map to a canonical form BEFORE NFC so both sides align.
MATH_EQUIV = {
    "\u22c5": "\u00b7",   # DOT OPERATOR      -> MIDDLE DOT
    "\u2212": "\u002d",   # MINUS SIGN        -> HYPHEN-MINUS
    "\u2215": "\u002f",   # DIVISION SLASH    -> SOLIDUS
    "\u2216": "\u005c",   # SET MINUS         -> REVERSE SOLIDUS
    "\u2217": "\u002a",   # ASTERISK OPERATOR -> ASTERISK
    "\u2032": "\u0027",   # PRIME             -> APOSTROPHE
    # Big operators: XeTeX (lmodern/cmex) emits the binary codepoint where
    # ztex emits the Unicode N-ARY form of the same visual operator.
    "\u22c3": "\u222a",   # N-ARY UNION        -> UNION            (\bigcup)
    "\u22c2": "\u2229",   # N-ARY INTERSECTION -> INTERSECTION    (\bigcap)
    "\u2a06": "\u2294",   # N-ARY SQUARE UNION -> SQUARE CUP      (\bigsqcup)
    "\u2210": "\u2210",   # \coprod: same codepoint both engines (explicit)
    "\u222e": "\u222e",   # \oint:   same codepoint both engines (explicit)
}


def _math_norm(s):
    """Map math codepoints to plain-text equivalents, then NFC."""
    return unicodedata.normalize("NFC", "".join(MATH_EQUIV.get(c, c) for c in s))


def glyph_normeq(a, b):
    """Math-symbol + NFC canonical equivalence."""
    return _math_norm(a) == _math_norm(b)


def _match_score(a, b):
    if glyph_equal(a, b):
        return MATCH_SCORE
    if glyph_normeq(a, b):
        return NORMEQ_SCORE
    return MISMATCH_SCORE


def normalize(doc, dpi=96.0):
    """Normalize one engine's glyph records (design 1).

    Axis: negate y when up == false (SVG/HTML y-down -> y-up).
    Unit: scale x, y, size to points (px -> pt via 72/dpi).
    Order: PRESERVED (the renderers emit glyphs in render order). A global
    x-sort would reorder glyphs whose x is perturbed past a neighbor, breaking
    alignment (a +5px shift on one glyph must produce +5px dx on it, not a
    reorder). NW alignment in `align` already enforces order.
    """
    unit = doc.get("unit", "pt")
    if unit == "pt":
        scale = 1.0
    elif unit == "px":
        scale = PT_PER_INCH / dpi
    else:
        raise ValueError("unsupported unit %r (expected 'pt' or 'px')" % unit)
    up = bool(doc.get("up", True))
    glyphs = []
    for g in doc.get("glyphs", []):
        rec = {
            "glyph": g["glyph"],
            "x": float(g["x"]) * scale,
            "y": float(g["y"]) * scale,
            "size": float(g.get("size", 0.0)) * scale,
        }
        if "bbox" in g:
            rec["bbox"] = [v * scale for v in g["bbox"]]
        if "ink" in g:
            xmin, ymin, xmax, ymax = (float(v) * scale for v in g["ink"])
            if not up:
                # y-down -> y-up: flip the vertical axis (ymin/ymax swap).
                rec["ink"] = [xmin, -ymax, xmax, -ymin]
            else:
                rec["ink"] = [xmin, ymin, xmax, ymax]
        if not up:
            rec["y"] = -rec["y"]
        glyphs.append(rec)
    return glyphs


def align(ours, ref):
    """Needleman-Wunsch alignment on glyph identity (design 2).

    Returns a list of (i, j) columns pairing ours[i] with ref[j]; -1 is a
    gap sentinel. Scores per design: match 4, normeq 2, mismatch -4,
    gap -1. Ties prefer the diagonal (match over gaps).
    """
    n, m = len(ours), len(ref)
    dp = [[0.0] * (m + 1) for _ in range(n + 1)]
    tb = [[0] * (m + 1) for _ in range(n + 1)]  # 0 diag, 1 up (ours gapped), 2 left (ref gapped)
    for i in range(1, n + 1):
        dp[i][0] = i * GAP_PENALTY
        tb[i][0] = 1
    for j in range(1, m + 1):
        dp[0][j] = j * GAP_PENALTY
        tb[0][j] = 2
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            diag = dp[i - 1][j - 1] + _match_score(ours[i - 1]["glyph"], ref[j - 1]["glyph"])
            up = dp[i - 1][j] + GAP_PENALTY
            left = dp[i][j - 1] + GAP_PENALTY
            best = max(diag, up, left)
            if diag == best:
                tb[i][j] = 0
            elif up == best:
                tb[i][j] = 1
            else:
                tb[i][j] = 2
            dp[i][j] = best
    cols = []
    i, j = n, m
    while i > 0 or j > 0:
        step = tb[i][j]
        if step == 0:
            cols.append((i - 1, j - 1))
            i -= 1
            j -= 1
        elif step == 1:
            cols.append((i - 1, -1))
            i -= 1
        else:
            cols.append((-1, j - 1))
            j -= 1
    cols.reverse()
    return cols


def style(size, base):
    """Style class from rendered size vs base_size_pt (design 3)."""
    if size < 0.5 * base:
        return "scriptscript"
    if size < 0.8 * base:
        return "script"
    return "text"


def _ink_delta(o, r, ox, oy):
    """Ink-channel deltas: left edge, top edge, width/height extent.

    io/ir are [xmin, ymin, xmax, ymax] in y-up pt. Returns {} when either
    side lacks ink.
    """
    io, ir = o.get("ink"), r.get("ink")
    if not io or not ir:
        return {}
    rw = (ir[2] - ir[0]) or 1.0
    rh = (ir[3] - ir[1]) or 1.0
    w_o, w_r = io[2] - io[0], ir[2] - ir[0]
    h_o, h_r = io[3] - io[1], ir[3] - ir[1]
    return {
        "dix": io[0] - ir[0] - ox,
        "diy": io[3] - ir[3] - oy,
        "dxi": (io[0] - ir[0] - ox) / rw,
        "dyi": (io[3] - ir[3] - oy) / rh,
        "dwi": w_o - w_r,
        "dhi": h_o - h_r,
        "width_ratio": w_o / rw,
        "height_ratio": h_o / rh,
        "ink_ours": io,
        "ink_ref": ir,
    }


def _ink_anomaly(d):
    """True when the pair's ink deviates beyond INK_FLAG on any axis.

    Extent: |width_ratio-1| / |height_ratio-1| (ink vs ref ink). Position:
    the absolute ink edge deltas dix/diy (after the global offset),
    normalized by the ref font size. The eye sees the ink; a big-op whose
    baseline convention differs between engines (ztex keeps the op baseline
    at the text row, TeX raises it) must not be flagged when the ink lands
    in the same place.
    """
    if "dix" not in d:
        return False
    rsize = d["size_ref"] or 1.0
    return max(abs(d["width_ratio"] - 1.0),
               abs(d["height_ratio"] - 1.0),
               abs(d["dix"]) / rsize,
               abs(d["diy"]) / rsize) > INK_FLAG


def delta(o, r, ox=0.0, oy=0.0, base_ours=20.0, base_ref=20.0):
    """Per-pair delta (design 3): ours o vs ref r after baseline offset (ox, oy).

    dx > 0 => ours right of ref; dy > 0 => ours above ref (y-up).
    dxi/dyi are normalized by ref size; size_ratio ~1.0 => style matches.
    Ink deltas (dix/diy/dwi/dhi + ratios) are included when both sides carry
    an ink bbox; ink size is in pt, comparable across engines directly.
    """
    dx = o["x"] - r["x"] - ox
    dy = o["y"] - r["y"] - oy
    rsize = r["size"] or 0.0
    entry = {
        "glyph": o["glyph"],
        "dx": dx,
        "dy": dy,
        "dxi": dx / rsize if rsize else 0.0,
        "dyi": dy / rsize if rsize else 0.0,
        "size_ours": o["size"],
        "size_ref": r["size"],
        "size_ratio": o["size"] / rsize if rsize else 0.0,
        "style_ours": style(o["size"], base_ours),
        "style_ref": style(r["size"], base_ref),
    }
    entry.update(_ink_delta(o, r, ox, oy))
    if o["glyph"] != r["glyph"]:
        entry["glyph_ref"] = r["glyph"]
    return entry


def _merged(glyphs, run):
    """Merge a run of records: x = first of run, y and size = mean (design 2).

    Ink bbox = union of the run's ink bboxes (covers combining marks).
    """
    gs = [glyphs[t] for t in run]
    inks = [g["ink"] for g in gs if g.get("ink")]
    rec = {
        "glyph": "".join(g["glyph"] for g in gs),
        "x": gs[0]["x"],
        "y": sum(g["y"] for g in gs) / len(gs),
        "size": sum(g["size"] for g in gs) / len(gs),
    }
    if inks:
        rec["ink"] = [min(i[0] for i in inks), min(i[1] for i in inks),
                      max(i[2] for i in inks), max(i[3] for i in inks)]
    return rec


def _consecutive_runs(idx):
    """Maximal runs of consecutive glyph indices, in order."""
    if not idx:
        return []
    runs = []
    start = prev = idx[0]
    for v in idx[1:]:
        if v == prev + 1:
            prev = v
        else:
            runs.append(list(range(start, prev + 1)))
            start = prev = v
    runs.append(list(range(start, prev + 1)))
    return runs


def _resolve_gap_block(block, ours, ref, ox, oy, base_ours, base_ref,
                       deltas, unmatched):
    """Classify a run of gap columns: NFC-concat merges/splits, else missing.

    Merge: two or more consecutive ours glyphs whose NFC concatenation equals
    one ref glyph (e.g. "e"+U+0301 vs "é"); split is symmetric. Leftover gap
    glyphs are missing (unmatched), never deltas.
    """
    ours_idx = [ci for ci, cj in block if ci >= 0]
    ref_idx = [cj for ci, cj in block if cj >= 0]
    consumed_o = set()
    consumed_r = set()
    n_merge = 0
    for cj in ref_idx:
        if cj in consumed_r:
            continue
        for run in _consecutive_runs(ours_idx):
            if len(run) < 2 or any(t in consumed_o for t in run):
                continue
            ours_text = "".join(ours[t]["glyph"] for t in run)
            if unicodedata.normalize("NFC", ours_text) == unicodedata.normalize("NFC", ref[cj]["glyph"]):
                d = delta(_merged(ours, run), ref[cj], ox, oy, base_ours, base_ref)
                d["merge"] = True
                d["glyphs"] = [ours[t]["glyph"] for t in run]
                deltas.append(d)
                n_merge += 1
                consumed_o.update(run)
                consumed_r.add(cj)
                break
    for ci in ours_idx:
        if ci in consumed_o:
            continue
        for run in _consecutive_runs(ref_idx):
            if len(run) < 2 or any(t in consumed_r for t in run):
                continue
            ref_text = "".join(ref[t]["glyph"] for t in run)
            if unicodedata.normalize("NFC", ref_text) == unicodedata.normalize("NFC", ours[ci]["glyph"]):
                d = delta(ours[ci], _merged(ref, run), ox, oy, base_ours, base_ref)
                d["split"] = True
                d["glyphs"] = [ref[t]["glyph"] for t in run]
                deltas.append(d)
                n_merge += 1
                consumed_o.add(ci)
                consumed_r.update(run)
                break
    for ci in ours_idx:
        if ci not in consumed_o:
            unmatched.append({"side": "ref", "glyph": ours[ci]["glyph"]})
    for cj in ref_idx:
        if cj not in consumed_r:
            unmatched.append({"side": "ours", "glyph": ref[cj]["glyph"]})
    return n_merge


def _classify(cols, ours, ref, ox, oy, base_ours, base_ref):
    """Turn alignment columns into deltas, merges/splits, and unmatched."""
    deltas = []
    unmatched = []
    n_merge = 0
    i = 0
    n = len(cols)
    while i < n:
        ci, cj = cols[i]
        if ci >= 0 and cj >= 0:
            # Run of columns sharing one ref index: ref merges ours.
            if i + 1 < n and cols[i + 1][0] == ci + 1 and cols[i + 1][1] == cj:
                k = i
                while k + 1 < n and cols[k + 1][0] == cols[k][0] + 1 and cols[k + 1][1] == cj:
                    k += 1
                run = list(range(ci, cols[k][0] + 1))
                d = delta(_merged(ours, run), ref[cj], ox, oy, base_ours, base_ref)
                d["merge"] = True
                d["glyphs"] = [ours[t]["glyph"] for t in run]
                deltas.append(d)
                n_merge += 1
                i = k + 1
            # Run of columns sharing one ours index: ours splits ref.
            elif i + 1 < n and cols[i + 1][0] == ci and cols[i + 1][1] == cj + 1:
                k = i
                while k + 1 < n and cols[k + 1][0] == ci and cols[k + 1][1] == cols[k][1] + 1:
                    k += 1
                run = list(range(cj, cols[k][1] + 1))
                d = delta(ours[ci], _merged(ref, run), ox, oy, base_ours, base_ref)
                d["split"] = True
                d["glyphs"] = [ref[t]["glyph"] for t in run]
                deltas.append(d)
                n_merge += 1
                i = k + 1
            else:
                deltas.append(delta(ours[ci], ref[cj], ox, oy, base_ours, base_ref))
                i += 1
        else:
            j = i
            block = []
            while j < n and (cols[j][0] < 0 or cols[j][1] < 0):
                block.append(cols[j])
                j += 1
            n_merge += _resolve_gap_block(block, ours, ref, ox, oy,
                                          base_ours, base_ref, deltas, unmatched)
            i = j
    n_style = sum(1 for d in deltas if d["style_ours"] != d["style_ref"])
    return deltas, unmatched, n_merge, n_style


def _mode(seq):
    """Most common value; None on empty input."""
    if not seq:
        return None
    return Counter(seq).most_common(1)[0][0]


def _median(xs):
    xs = sorted(xs)
    n = len(xs)
    if n == 0:
        return None
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def _main_row_y(glyphs, base):
    """y of glyphs on the main text row: size within [0.8, 1.3] x base.

    Excludes scripts (0.5-0.8 x base) and scaled big ops (>= 1.3 x base,
    e.g. ztex's 14/20pt display operators), which sit on different lines.
    """
    return [g["y"] for g in glyphs
            if 0.8 * base <= g["size"] <= 1.3 * base]


def _matched_x_offset(ours, ref, cols):
    """Median x offset over aligned (non-gap) columns, or None."""
    xs = [ours[i]["x"] - ref[j]["x"] for i, j in cols if i >= 0 and j >= 0]
    return _median(xs)


def _matched_y_offset(ours, ref, cols, base_ours, base_ref):
    """Median y offset over aligned columns whose glyphs are BOTH on the
    main text row (0.8-1.3 x their engine's base size).

    Restricting to both-text-size pairs keeps a big-op pair out of the
    baseline: XeTeX's big op renders at the text font size (9.96pt cmex
    design scale) while ztex's renders at 14/20pt, so a size-only filter
    would let the xetex op row capture the offset (audit R2/R3). Falls
    back to all matched pairs, then to the y-mode of text-size glyphs.
    """
    ds = [ours[i]["y"] - ref[j]["y"] for i, j in cols if i >= 0 and j >= 0
          and 0.8 * base_ours <= ours[i]["size"] <= 1.3 * base_ours
          and 0.8 * base_ref <= ref[j]["size"] <= 1.3 * base_ref]
    if not ds:
        ds = [ours[i]["y"] - ref[j]["y"] for i, j in cols
              if i >= 0 and j >= 0]
    if ds:
        return _median(ds)
    oy_ours = _mode(_main_row_y(ours, base_ours))
    oy_ref = _mode(_main_row_y(ref, base_ref))
    if oy_ours is not None and oy_ref is not None:
        return oy_ours - oy_ref
    return None


def _ink_centers(glyphs):
    centers = []
    for g in glyphs:
        b = g.get("ink")
        if b:
            centers.append(((b[0] + b[2]) / 2.0, (b[1] + b[3]) / 2.0))
        elif "bbox" in g:
            xmin, ymin, xmax, ymax = g["bbox"]
            centers.append(((xmin + xmax) / 2.0, (ymin + ymax) / 2.0))
    return centers


def baseline_shift(ours, ref, cols=None, strategy="mode",
                   base_ours=10.0, base_ref=10.0):
    """One global 2D offset (ox, oy); deltas = (o - r) - offset (design 4).

    mode (default): oy from the median y offset of aligned pairs whose
    glyphs are on the main text row on BOTH sides (text-size on both
    engines, so big-op rows never capture the offset), ox from the median
    over all aligned columns. Unlike first-top this is immune to a
    differing first glyph (reordered limits) and to sub/superscript rows.
    first-top: align ours[0] to ref[0] baseline (legacy).
    bbox-center: align mean ink-bbox centers (falls back to first-top when
    neither side carries ink/bbox data).
    """
    if not ours or not ref:
        return (0.0, 0.0)
    ox = ours[0]["x"] - ref[0]["x"]
    oy = ours[0]["y"] - ref[0]["y"]
    if strategy == "first-top":
        return (ox, oy)
    if strategy == "mode":
        ox_m = _matched_x_offset(ours, ref, cols)
        oy_m = _matched_y_offset(ours, ref, cols, base_ours, base_ref)
        if ox_m is not None:
            ox = ox_m
        if oy_m is not None:
            oy = oy_m
        return (ox, oy)
    if strategy == "bbox-center":
        oc = _ink_centers(ours)
        rc = _ink_centers(ref)
        if oc and rc:
            ox = sum(c[0] for c in oc) / len(oc) - sum(c[0] for c in rc) / len(rc)
            oy = sum(c[1] for c in oc) / len(oc) - sum(c[1] for c in rc) / len(rc)
        return (ox, oy)
    raise ValueError("unknown baseline strategy %r" % strategy)


def _mean(xs):
    return sum(xs) / len(xs) if xs else 0.0


def _delta_norm(d):
    """Ranking norm: box delta, ink position delta and ink extent, whichever
    is largest — an ink-only defect ranks as high as a box shift."""
    box = math.hypot(d["dx"], d["dy"])
    if "dix" in d:
        return max(box, math.hypot(d["dix"], d["diy"]),
                   abs(d["dwi"]), abs(d["dhi"]))
    return box


def summarize(deltas, unmatched, n_merge, n_style, top_k=5):
    """Aggregate delta statistics (design 5) plus top-k by delta norm."""
    dxs = [abs(d["dx"]) for d in deltas]
    dys = [abs(d["dy"]) for d in deltas]
    dxi = [abs(d["dxi"]) for d in deltas]
    dyi = [abs(d["dyi"]) for d in deltas]
    ink_ds = [d for d in deltas if "dix" in d]
    stats = {
        "pairs": len(deltas),
        "ours_unmatched": sum(1 for u in unmatched if u["side"] == "ours"),
        "ref_unmatched": sum(1 for u in unmatched if u["side"] == "ref"),
        "merges": n_merge,
        "style_mismatches": n_style,
        "mean_abs_dx": _mean(dxs),
        "max_abs_dx": max(dxs, default=0.0),
        "mean_abs_dy": _mean(dys),
        "max_abs_dy": max(dys, default=0.0),
        "max_norm_dxi": max(dxi, default=0.0),
        "max_norm_dyi": max(dyi, default=0.0),
        "ink_pairs": len(ink_ds),
        "n_ink_anomalies": sum(1 for d in ink_ds if _ink_anomaly(d)),
        "mean_abs_dix": _mean([abs(d["dix"]) for d in ink_ds]),
        "max_abs_dix": max([abs(d["dix"]) for d in ink_ds], default=0.0),
        "mean_abs_diy": _mean([abs(d["diy"]) for d in ink_ds]),
        "max_abs_diy": max([abs(d["diy"]) for d in ink_ds], default=0.0),
        "max_abs_dwi": max([abs(d["dwi"]) for d in ink_ds], default=0.0),
        "max_abs_dhi": max([abs(d["dhi"]) for d in ink_ds], default=0.0),
        "max_width_dev": max([abs(d["width_ratio"] - 1.0) for d in ink_ds],
                             default=0.0),
        "max_height_dev": max([abs(d["height_ratio"] - 1.0) for d in ink_ds],
                              default=0.0),
    }
    top = sorted(deltas, key=_delta_norm, reverse=True)
    return stats, top[:max(top_k, 0)]


def _mark_reorders(unmatched, ours, ref, ox=0.0, oy=0.0):
    """Flag glyph identities left unmatched on BOTH sides as reorders.

    NW cannot cross, so a glyph present in both engines but ordered
    differently ends up unmatched on both sides; flag it (excluded from
    deltas) rather than reporting it as missing. The reordered glyph's
    geometry is NOT dropped: dx/dy (and ink dix/diy when available) are
    computed against its counterpart in the other engine, so the report
    quantifies where the reordered glyph landed.
    """
    ours_ids = {u["glyph"] for u in unmatched if u["side"] == "ours"}
    ref_ids = {u["glyph"] for u in unmatched if u["side"] == "ref"}
    for u in unmatched:
        if u["glyph"] not in ours_ids or u["glyph"] not in ref_ids:
            continue
        u["reorder"] = True
        g = u["glyph"]
        o = next((x for x in ours if glyph_normeq(x["glyph"], g)), None)
        r = next((x for x in ref if glyph_normeq(x["glyph"], g)), None)
        if o and r:
            u["dx"] = o["x"] - r["x"] - ox
            u["dy"] = o["y"] - r["y"] - oy
            if o.get("ink") and r.get("ink"):
                u["dix"] = o["ink"][0] - r["ink"][0] - ox
                u["diy"] = o["ink"][3] - r["ink"][3] - oy


def _ink_clause(d, unit):
    """Human clause for ink deltas; '' when ink is close on all axes.

    Extent clauses report width/height ratios; position clauses report the
    absolute ink edge deltas (dix/diy, after the global offset) — where the
    ink actually lands on the page.
    """
    if "dix" not in d:
        return ""
    parts = []
    wr, hr = d["width_ratio"], d["height_ratio"]
    if abs(wr - 1.0) > INK_REPORT:
        parts.append("%.2f%s (%+.0f%%) %s" % (
            abs(d["dwi"]), unit, (wr - 1.0) * 100,
            "wider" if d["dwi"] > 0 else "narrower"))
    if abs(hr - 1.0) > INK_REPORT:
        parts.append("%.2f%s (%+.0f%%) %s" % (
            abs(d["dhi"]), unit, (hr - 1.0) * 100,
            "taller" if d["dhi"] > 0 else "shorter"))
    rsize = d["size_ref"] or 1.0
    if abs(d["dix"]) > INK_REPORT * rsize:
        parts.append("ink left edge %.2f%s %s" % (
            abs(d["dix"]), unit, "right" if d["dix"] > 0 else "left"))
    if abs(d["diy"]) > INK_REPORT * rsize:
        parts.append("ink top %.2f%s %s" % (
            abs(d["diy"]), unit, "up" if d["diy"] > 0 else "down"))
    return (" (ink: " + ", ".join(parts) + ")") if parts else ""


def _size_clause(d):
    """Always surface the size relation (ztex font-size vs ref scale)."""
    if d["style_ours"] != "text" or d["style_ref"] != "text":
        return " (script height %.1f vs ref %.1f; ratio %.2f)" % (
            d["size_ours"], d["size_ref"], d["size_ratio"])
    return " (size ratio %.2f)" % d["size_ratio"]


def _sentence(d, engine, unit):
    """Human sentence for one delta, e.g. "xelatex's ∑ is 1.20pt right and 0.20pt up (size ratio 1.00)." """
    dx, dy = d["dx"], d["dy"]
    ink_clause = _ink_clause(d, unit)
    if abs(dx) < 1e-9 and abs(dy) < 1e-9 and not ink_clause:
        text = "%s's %s is aligned" % (engine, d["glyph"])
    else:
        text = "%s's %s is %.2f%s %s" % (engine, d["glyph"], abs(dx), unit,
                                         "right" if dx > 0 else "left")
        if abs(dy) >= 1e-9:
            text += " and %.2f%s %s" % (abs(dy), unit, "up" if dy > 0 else "down")
    text += _size_clause(d) + ink_clause
    if d.get("merge"):
        text += " [merge %s]" % "+".join(d["glyphs"])
    elif d.get("split"):
        text += " [split %s]" % "+".join(d["glyphs"])
    return text + "."


def _verdict(stats):
    """One-word verdict: ink / structure / layout / ok."""
    if stats.get("n_ink_anomalies"):
        return "ink"
    if stats["ours_unmatched"] or stats["ref_unmatched"] or stats["merges"]:
        return "structure"
    if (stats["max_abs_dx"] > LAYOUT_MAX_DX or stats["max_abs_dy"] > LAYOUT_MAX_DY or
            stats["mean_abs_dx"] > LAYOUT_MEAN_DX or stats["mean_abs_dy"] > LAYOUT_MEAN_DY):
        return "layout"
    return "ok"


def human(report):
    """Human-readable stdout text built from the report."""
    s = report["stats"]
    unit = report["unit"]
    lines = list(report["top_issues"])
    miss_ours = [u["glyph"] for u in report["unmatched"]
                 if u["side"] == "ours" and not u.get("reorder")]
    miss_ref = [u["glyph"] for u in report["unmatched"]
                if u["side"] == "ref" and not u.get("reorder")]
    for engine, glyphs in ((report["engine_ours"], miss_ours),
                           (report["engine_ref"], miss_ref)):
        if glyphs:
            lines.append("Missing in %s: %s (%d glyph%s)." % (
                engine, ", ".join(glyphs), len(glyphs),
                "" if len(glyphs) == 1 else "s"))
    reord = [u for u in report["unmatched"] if u.get("reorder")]
    if reord:
        ids = sorted({u["glyph"] for u in reord})
        geom = []
        for g in ids:
            u = next(x for x in reord if x["glyph"] == g and "dx" in x)
            geom.append("%s: dx=%.2f%s dy=%.2f%s" % (
                g, u["dx"], unit, u["dy"], unit))
        lines.append("Reorder (%s vs %s): %s (%d glyph%s) — %s." % (
            report["engine_ours"], report["engine_ref"], ", ".join(ids),
            len(ids), "" if len(ids) == 1 else "s", "; ".join(geom)))
    lines.append("pairs=%d ours_unmatched=%d ref_unmatched=%d merges=%d "
                 "style_mismatches=%d mean|dx|=%.3f max|dx|=%.3f mean|dy|=%.3f "
                 "max|dy|=%.3f max|dxi|=%.3f max|dyi|=%.3f | ink_pairs=%d "
                 "n_ink_anomalies=%d mean|dix|=%.3f max|dix|=%.3f "
                 "max_width_dev=%.3f max_height_dev=%.3f" % (
                     s["pairs"], s["ours_unmatched"], s["ref_unmatched"],
                     s["merges"], s["style_mismatches"], s["mean_abs_dx"],
                     s["max_abs_dx"], s["mean_abs_dy"], s["max_abs_dy"],
                     s["max_norm_dxi"], s["max_norm_dyi"],
                     s["ink_pairs"], s["n_ink_anomalies"],
                     s["mean_abs_dix"], s["max_abs_dix"],
                     s["max_width_dev"], s["max_height_dev"]))
    verdict = report.get("verdict", "ok")
    if verdict == "ink":
        glyphs = ", ".join(sorted({d["glyph"] for d in report["deltas"]
                                   if _ink_anomaly(d)}))
        lines.append("verdict: INK DEFECT — %d ink-anomalous glyph%s: %s" % (
            s["n_ink_anomalies"], "" if s["n_ink_anomalies"] == 1 else "s",
            glyphs))
    elif verdict == "structure":
        lines.append("verdict: structure mismatch (%d ours_unmatched, "
                     "%d ref_unmatched, %d merges)" % (
                         s["ours_unmatched"], s["ref_unmatched"], s["merges"]))
    elif verdict == "layout":
        lines.append("verdict: layout drift (max|dx|=%.2f%s, max|dy|=%.2f%s)" % (
            s["max_abs_dx"], unit, s["max_abs_dy"], unit))
    else:
        lines.append("verdict: ok")
    return "\n".join(lines)


def compare(odoc, rdoc, strategy="mode", top_k=5, to_px=False, dpi=96.0):
    """Full pipeline: normalize -> align -> baseline_shift -> deltas -> report."""
    ours = normalize(odoc, dpi)
    ref = normalize(rdoc, dpi)
    cols = align(ours, ref)
    base_ours = float(odoc.get("base_size_pt", 10.0))
    base_ref = float(rdoc.get("base_size_pt", 10.0))
    ox, oy = baseline_shift(ours, ref, cols, strategy, base_ours, base_ref)
    deltas, unmatched, n_merge, n_style = _classify(
        cols, ours, ref, ox, oy, base_ours, base_ref)
    _mark_reorders(unmatched, ours, ref, ox, oy)
    stats, top = summarize(deltas, unmatched, n_merge, n_style, top_k)
    if to_px:
        # px = pt * (base_size_pt/20) * dpi/72 (design: px conversion).
        px = (base_ours / 20.0) * (dpi / PT_PER_INCH)
        for d in deltas:
            d["dx"] *= px
            d["dy"] *= px
            d["size_ours"] *= px
            d["size_ref"] *= px
            for k in ("dix", "diy", "dwi", "dhi"):
                if k in d:
                    d[k] *= px
            if "ink_ours" in d:
                d["ink_ours"] = [v * px for v in d["ink_ours"]]
                d["ink_ref"] = [v * px for v in d["ink_ref"]]
        for u in unmatched:
            for k in ("dx", "dy", "dix", "diy"):
                if k in u:
                    u[k] *= px
        ox *= px
        oy *= px
    engine_ours = odoc.get("engine", "ours")
    engine_ref = rdoc.get("engine", "ref")
    unit = "px" if to_px else "pt"
    return {
        "formula": odoc.get("formula") or rdoc.get("formula") or "",
        "engine_ours": engine_ours,
        "engine_ref": engine_ref,
        "unit": unit,
        "baseline": strategy,
        "baseline_offset": {"dx": ox, "dy": oy},
        "verdict": _verdict(stats),
        "stats": stats,
        "deltas": deltas,
        "unmatched": unmatched,
        "top_issues": [_sentence(d, engine_ours, unit) for d in top],
    }


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Compare per-glyph geometry of two TeX engine outputs "
                    "(design: notes/compare-design.md).")
    ap.add_argument("--ours", metavar="JSON",
                    help="ours per-glyph JSON (required unless --selftest)")
    ap.add_argument("--ref", metavar="JSON",
                    help="reference per-glyph JSON (required unless --selftest)")
    ap.add_argument("--out", metavar="JSON",
                    help="output report path (required unless --selftest)")
    ap.add_argument("--baseline", choices=("first-top", "bbox-center", "mode"),
                    default="mode",
                    help="baseline alignment strategy (default mode)")
    ap.add_argument("--top", type=int, default=5,
                    help="top-N issue sentences (default 5)")
    ap.add_argument("--px", action="store_true",
                    help="report deltas in px instead of pt")
    ap.add_argument("--dpi", type=float, default=96.0,
                    help="dpi for px conversions (default 96)")
    ap.add_argument("--selftest", action="store_true",
                    help="run unit tests and exit")
    args = ap.parse_args(argv)
    if args.selftest:
        try:
            return _selftest()
        except AssertionError as e:
            print("selftest FAILED: %s" % e, file=sys.stderr)
            return 1
    if not (args.ours and args.ref and args.out):
        ap.error("--ours, --ref and --out are required (unless --selftest)")
    try:
        with open(args.ours, "r", encoding="utf-8") as f:
            odoc = json.load(f)
        with open(args.ref, "r", encoding="utf-8") as f:
            rdoc = json.load(f)
        report = compare(odoc, rdoc, args.baseline, args.top, args.px, args.dpi)
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(report, f, ensure_ascii=False, indent=2)
            f.write("\n")
    except (OSError, ValueError, KeyError, TypeError) as e:
        print("error: %s" % e, file=sys.stderr)
        return 1
    print(human(report))
    return 0


def _selftest():
    """Unit tests for the pure functions; run via --selftest."""
    checks = 0

    def ok(cond, name):
        nonlocal checks
        if not cond:
            raise AssertionError(name)
        checks += 1

    def G(glyph, x, y, size=10.0):
        return {"glyph": glyph, "x": x, "y": y, "size": size}

    # --- normalize ---
    doc = {"unit": "pt", "up": False, "base_size_pt": 20.0,
           "glyphs": [{"glyph": "x", "x": 1.0, "y": 5.0, "size": 10.0}]}
    g = normalize(doc)[0]
    ok(g["y"] == -5.0, "normalize negates y when up=false")
    ok(g["x"] == 1.0 and g["size"] == 10.0, "normalize keeps pt values")

    doc = {"unit": "px", "up": True, "base_size_pt": 20.0,
           "glyphs": [{"glyph": "x", "x": 96.0, "y": 0.0, "size": 48.0}]}
    g = normalize(doc, dpi=96.0)[0]
    ok(abs(g["x"] - 72.0) < 1e-9 and abs(g["size"] - 36.0) < 1e-9,
       "normalize scales px to pt")

    doc = {"unit": "pt", "up": True, "base_size_pt": 20.0, "glyphs": [
        {"glyph": "sub", "x": 5.0, "y": 1.0, "size": 8.0},
        {"glyph": "sup", "x": 5.0, "y": 9.0, "size": 8.0}]}
    gs = normalize(doc)
    ok(gs[0]["glyph"] == "sub" and gs[1]["glyph"] == "sup",
       "normalize preserves input order (no x-sort)")

    try:
        normalize({"unit": "em", "glyphs": []})
        ok(False, "normalize rejects unknown unit")
    except ValueError:
        ok(True, "normalize rejects unknown unit")

    # --- align ---
    ok(align([G("a", 0, 0), G("b", 1, 0)], [G("a", 0, 0), G("b", 1, 0)]) == [(0, 0), (1, 1)],
       "align matches identical runs")
    ok(align([G("e\u0301", 0, 0)], [G("\u00e9", 0, 0)]) == [(0, 0)],
       "align matches NFC-equivalent glyphs")
    ok(glyph_normeq("\u22c5", "\u00b7"), "math dot equates to middle dot")
    ok(glyph_normeq("\u2212", "-"), "math minus equates to hyphen-minus")
    ok(align([G("a", 0, 0)], [G("b", 0, 0)]) == [(-1, 0), (0, -1)],
       "align gaps on mismatch")
    ok(align([G("a", 0, 0), G("b", 1, 0)], [G("a", 0, 0)]) == [(0, 0), (1, -1)],
       "align gaps a trailing ours glyph")

    # --- style / delta ---
    ok(style(40.0, 20.0) == "text" and style(14.0, 20.0) == "script"
       and style(9.0, 20.0) == "scriptscript", "style thresholds")
    o, r = G("∑", 12.0, 14.0, size=40.0), G("∑", 10.0, 12.0, size=40.0)
    d = delta(o, r, 0.0, 0.0, 20.0, 20.0)
    ok(abs(d["dx"] - 2.0) < 1e-9 and abs(d["dy"] - 2.0) < 1e-9, "delta dx/dy")
    ok(abs(d["dxi"] - 0.05) < 1e-9 and abs(d["dyi"] - 0.05) < 1e-9,
       "delta normalized by ref size")
    ok(d["size_ratio"] == 1.0 and d["style_ours"] == "text"
       and d["style_ref"] == "text", "delta ratio and style")
    d2 = delta(o, r, 5.0, 5.0, 20.0, 20.0)
    ok(abs(d2["dx"] + 3.0) < 1e-9, "delta subtracts baseline offset")

    # --- baseline_shift ---
    ours = [G("a", 10, 20), G("b", 30, 20)]
    ref = [G("a", 5, 15), G("b", 25, 15)]
    ox, oy = baseline_shift(ours, ref, strategy="first-top")
    ok(ox == 5.0 and oy == 5.0, "first-top aligns first glyphs")
    ox, oy = baseline_shift(ours, ref, cols=[(0, 0), (1, 1)], strategy="mode",
                            base_ours=10.0, base_ref=10.0)
    ok(oy == 5.0 and ox == 5.0, "mode aligns y-mode and matched-x median")
    ob = [{"glyph": "a", "x": 0, "y": 0, "size": 10, "ink": [0, 0, 10, 10]}]
    rb = [{"glyph": "a", "x": 0, "y": 0, "size": 10, "ink": [2, 2, 12, 12]}]
    ox, oy = baseline_shift(ob, rb, strategy="bbox-center")
    ok(ox == -2.0 and oy == -2.0, "bbox-center aligns ink centers")
    # R3: a differing first glyph must not poison the offset. ref starts with
    # the big op, ours starts with the script '1'; the main row carries the
    # offset.
    ours_r3 = [G("1", 0, 30, size=7.0), G("∫", 5, 20, size=20.0),
               G("x", 30, 20, size=10.0)]
    ref_r3 = [G("∫", 0, 15, size=9.96), G("1", 5, 25, size=7.0),
              G("x", 30, 15, size=9.96)]
    ox, oy = baseline_shift(ours_r3, ref_r3,
                            cols=[(-1, 0), (0, -1), (1, 2)], strategy="mode",
                            base_ours=10.0, base_ref=10.0)
    ok(abs(oy - 5.0) < 1e-9, "mode offset from main row, not first glyph")

    # --- classify: missing, merge, split, reorder ---
    cols = align([G("a", 0, 0), G("b", 1, 0)], [G("a", 0, 0)])
    deltas, unmatched, nm, ns = _classify(cols, [G("a", 0, 0), G("b", 1, 0)],
                                          [G("a", 0, 0)], 0.0, 0.0, 20.0, 20.0)
    ok(len(deltas) == 1 and unmatched == [{"side": "ref", "glyph": "b"}],
       "missing glyph -> unmatched, not a delta")

    cols = align([G("e", 0, 0), G("\u0301", 0, 0)], [G("\u00e9", 0, 0)])
    deltas, unmatched, nm, ns = _classify(cols, [G("e", 0, 0), G("\u0301", 0, 0)],
                                          [G("\u00e9", 0, 0)], 0.0, 0.0, 20.0, 20.0)
    ok(nm == 1 and len(deltas) == 1 and deltas[0].get("merge"),
       "combining-mark split -> merge delta")

    cols = align([G("\u00e9", 0, 0)], [G("e", 0, 0), G("\u0301", 0, 0)])
    deltas, unmatched, nm, ns = _classify(cols, [G("\u00e9", 0, 0)],
                                          [G("e", 0, 0), G("\u0301", 0, 0)],
                                          0.0, 0.0, 20.0, 20.0)
    ok(nm == 1 and len(deltas) == 1 and deltas[0].get("split"),
       "combining-mark merge in ref -> split delta")

    # R4: reordered glyph excluded from deltas but its geometry reported
    # (including ink deltas when both sides carry ink).
    oa = {"glyph": "a", "x": 0, "y": 0, "size": 10, "ink": [0, 0, 5, 10]}
    ob = {"glyph": "b", "x": 1, "y": 0, "size": 10, "ink": [1, 0, 6, 10]}
    ra = {"glyph": "a", "x": 1, "y": 0, "size": 10, "ink": [1, 0, 6, 10]}
    rb = {"glyph": "b", "x": 0, "y": 0, "size": 10, "ink": [0, 0, 5, 10]}
    cols = align([oa, ob], [rb, ra])
    deltas, unmatched, nm, ns = _classify(cols, [oa, ob], [rb, ra],
                                          0.0, 0.0, 20.0, 20.0)
    _mark_reorders(unmatched, [oa, ob], [rb, ra], 0.0, 0.0)
    ok(len(deltas) == 1 and any(u.get("reorder") for u in unmatched),
       "reordered glyph flagged and excluded from deltas")
    reo = next(u for u in unmatched if u.get("reorder"))
    ok(reo.get("dx") == 1.0 and reo.get("dy") == 0.0,
       "reordered glyph carries its geometry (dx/dy)")
    ok(reo.get("dix") == 1.0 and reo.get("diy") == 0.0,
       "reordered glyph carries its ink geometry (dix/diy)")

    # --- ink channel ---
    gi = {"glyph": "∫", "x": 0.0, "y": -5.0, "size": 20.0,
          "ink": [0.0, -20.0, 11.06, 5.0]}  # y-down records, up=false
    g = normalize({"unit": "pt", "up": False, "base_size_pt": 10.0,
                   "glyphs": [gi]})[0]
    ok(g["ink"] == [0.0, -5.0, 11.06, 20.0], "normalize flips ink to y-up")
    d = delta(g, {"glyph": "∫", "x": 0.0, "y": 5.0, "size": 9.96,
                  "ink": [0.0, -5.0, 8.63, 20.0]}, 0.0, 0.0, 10.0, 10.0)
    ok(abs(d["width_ratio"] - 11.06 / 8.63) < 1e-9 and d["dwi"] > 2.4,
       "delta reports ink width ratio")
    ok(_ink_anomaly(d), "28% wider ink flags as ink anomaly")
    ok(not _ink_anomaly(delta(
        g, {"glyph": "∫", "x": 0.0, "y": 5.0, "size": 9.96,
            "ink": [0.0, -5.0, 11.0, 20.0]}, 0.0, 0.0, 10.0, 10.0)),
       "small ink width difference is not an anomaly")

    # --- summarize ---
    deltas = [{"glyph": "a", "dx": 1.0, "dy": 0.0, "dxi": 0.1, "dyi": 0.0,
               "dix": 1.0, "diy": 0.0, "dwi": 2.0, "dhi": 0.0,
               "width_ratio": 1.2, "height_ratio": 1.0, "size_ref": 10.0},
              {"glyph": "b", "dx": -2.0, "dy": 0.5, "dxi": 0.05, "dyi": 0.05,
               "dix": -1.0, "diy": 0.5, "dwi": 0.0, "dhi": 0.0,
               "width_ratio": 1.0, "height_ratio": 1.0, "size_ref": 10.0}]
    unmatched = [{"side": "ours", "glyph": "x"}, {"side": "ref", "glyph": "y"}]
    stats, top = summarize(deltas, unmatched, 2, 1, top_k=1)
    ok(stats["pairs"] == 2 and stats["ours_unmatched"] == 1
       and stats["ref_unmatched"] == 1 and stats["merges"] == 2
       and stats["style_mismatches"] == 1, "summarize counts")
    ok(abs(stats["mean_abs_dx"] - 1.5) < 1e-9 and stats["max_abs_dx"] == 2.0,
       "summarize dx stats")
    ok(abs(stats["mean_abs_dy"] - 0.25) < 1e-9 and stats["max_abs_dy"] == 0.5,
       "summarize dy stats")
    ok(stats["max_norm_dxi"] == 0.1 and stats["max_norm_dyi"] == 0.05,
       "summarize normalized max")
    ok(stats["ink_pairs"] == 2 and stats["n_ink_anomalies"] == 1
       and abs(stats["max_width_dev"] - 0.2) < 1e-9, "summarize ink stats")
    ok(top[0]["glyph"] == "b", "summarize top-k by combined norm")

    # --- human sentences (spec examples) ---
    d = {"glyph": "∑", "dx": 1.2, "dy": 0.2, "size_ours": 40.0, "size_ref": 40.0,
         "size_ratio": 1.0, "style_ours": "text", "style_ref": "text"}
    ok(_sentence(d, "xelatex", "pt") ==
       "xelatex's ∑ is 1.20pt right and 0.20pt up (size ratio 1.00).",
       "issue sentence includes size ratio (spec example)")
    d2 = dict(d, glyph="2", dx=-0.9, dy=0.0, size_ours=9.3, size_ref=9.3,
              style_ours="script", style_ref="script")
    ok(_sentence(d2, "ztex", "pt") ==
       "ztex's 2 is 0.90pt left (script height 9.3 vs ref 9.3; ratio 1.00).",
       "script-height sentence (spec example)")
    d3 = dict(d, glyph="∫", dx=0.0, dy=0.0, size_ours=20.0, size_ref=9.96,
              size_ratio=2.008, dix=0.0, diy=0.0, dwi=2.43, dhi=0.63,
              width_ratio=1.28, height_ratio=1.03, dxi=0.0, dyi=0.0)
    sent = _sentence(d3, "ztex", "pt")
    ok("28%" in sent and "wider" in sent and "aligned" not in sent,
       "ink defect sentence flags width, never 'aligned': %r" % sent)

    # --- compare end to end ---
    odoc = {"engine": "ztex", "formula": "x", "unit": "pt", "up": True,
            "base_size_pt": 20.0,
            "glyphs": [{"glyph": "x", "x": 1.0, "y": 2.0, "size": 20.0}]}
    rdoc = {"engine": "xelatex", "formula": "x", "unit": "pt", "up": True,
            "base_size_pt": 20.0,
            "glyphs": [{"glyph": "x", "x": 0.0, "y": 2.0, "size": 20.0}]}
    rep = compare(odoc, rdoc)
    ok(rep["stats"]["pairs"] == 1, "compare end to end")
    ok(rep["baseline_offset"] == {"dx": 1.0, "dy": 0.0}, "compare baseline offset")
    ok(abs(rep["deltas"][0]["dx"]) < 1e-9, "mode removes global offset")
    ok(rep["top_issues"][0] == "ztex's x is aligned (size ratio 1.00).",
       "compare top issue")
    rep = compare(odoc, rdoc, to_px=True)
    ok(abs(rep["baseline_offset"]["dx"] - 4.0 / 3.0) < 1e-9 and rep["unit"] == "px",
       "compare px conversion")

    # --- R1 self-check: synthetic ink defect must be flagged end to end ---
    odoc_i = {"engine": "ztex", "formula": "int", "unit": "pt", "up": False,
              "base_size_pt": 10.0,
              "glyphs": [
                  {"glyph": "∫", "x": 10.0, "y": 20.0, "size": 20.0,
                   "ink": [11.0, 0.0, 22.06, 22.22]},
                  {"glyph": "1", "x": 0.0, "y": 10.0, "size": 7.0},
                  {"glyph": "x", "x": 30.0, "y": 20.0, "size": 10.0},
              ]}
    rdoc_i = {"engine": "xetex", "formula": "int", "unit": "pt", "up": False,
              "base_size_pt": 10.0,
              "glyphs": [
                  {"glyph": "∫", "x": 10.0, "y": 20.0, "size": 9.96,
                   "ink": [10.55, 0.0, 19.18, 21.59]},
                  {"glyph": "1", "x": 0.0, "y": 10.0, "size": 7.0},
                  {"glyph": "x", "x": 30.0, "y": 20.0, "size": 10.0},
              ]}
    rep = compare(odoc_i, rdoc_i)
    ok(rep["verdict"] == "ink", "synthetic 28%-wider ink -> verdict 'ink'")
    ok(rep["stats"]["n_ink_anomalies"] == 1, "one ink-anomalous pair flagged")
    intd = next(dd for dd in rep["deltas"] if dd["glyph"] == "∫")
    ok(abs(intd["width_ratio"] - 11.06 / 8.63) < 1e-2,
       "ink defect quantified as width ratio")
    ok(any("wider" in t for t in rep["top_issues"]),
       "top issue names the ink width defect")
    # control: matching inks -> verdict ok
    rep_ok = compare(
        {"engine": "ztex", "formula": "int", "unit": "pt", "up": False,
         "base_size_pt": 10.0,
         "glyphs": [{"glyph": "∫", "x": 10.0, "y": 20.0, "size": 20.0,
                     "ink": [10.55, 0.0, 19.18, 21.59]}]},
        {"engine": "xetex", "formula": "int", "unit": "pt", "up": False,
         "base_size_pt": 10.0,
         "glyphs": [{"glyph": "∫", "x": 10.0, "y": 20.0, "size": 9.96,
                     "ink": [10.55, 0.0, 19.18, 21.59]}]})
    ok(rep_ok["verdict"] == "ok", "matching inks -> verdict 'ok'")

    print("selftest: %d checks passed" % checks)
    return 0


if __name__ == "__main__":
    sys.exit(main())
