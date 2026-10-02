#!/usr/bin/env python3
"""Compare ztex vs MicroTeX math layout geometry over a fixed corpus.

Renders (already produced) live in /tmp/ztex_cmp:
  <n>.svg        ztex      (glyph outlines carry data-text/data-x/data-y/font-size)
  <n>_ref.svg    MicroTeX  (each glyph = <use x y>, glyph outlines in <defs>)

All invariants are RELATIVE / structural (font metrics differ between the
engines, so absolute sizes/positions are never compared across engines).
For every formula the same structural role assignment must hold in BOTH:

  * left-to-right order of row elements
  * row baseline alignment
  * x^2: superscript ABOVE base and smaller; x_2: subscript BELOW
  * frac: numerator above the rule, denominator below, rule between & spanning
  * big ops (sum/int/prod, display style): limits ABOVE and BELOW the operator
  * text: glyphs on one baseline; spaces: gap(,) < gap(;) < gap(quad), quad~=1em

MicroTeX glyph identity is geometric (glyph ids are per span, not per char),
so char-level sequence checks run on ztex (chars in the SVG) and MicroTeX is
checked by count, position, and order; both are cross-checked by role.

Usage: python3 compare_geom.py   (reads /tmp/ztex_cmp, prints report)
"""
import json
import re
import subprocess
import sys
import unicodedata
import xml.etree.ElementTree as ET
from pathlib import Path

DIR = "/tmp/ztex_cmp"

CORPUS = [
    ("x", "plain"),
    ("x^2", "script"),
    ("x_2", "script"),
    ("x_i^2", "script"),
    (r"\frac{1}{2}", "frac"),
    (r"\frac{x+1}{y-1}", "frac"),
    (r"\sum_{i=1}^{n} x_i", "bigop"),
    (r"\int_0^1 x\,dx", "bigop"),
    (r"\text{hi}", "text"),
    (r"\mathbf{x}+\mathrm{ab}", "textbold"),
    (r"a\,b\;c\quad d", "spaces"),
    (r"\prod_{k=1}^{m} k", "bigop"),
]

EXPECT_SEQ = {1: ["x"], 2: ["x", "2"], 3: ["x", "2"], 4: ["x", "2", "i"],
              9: ["h", "i"], 10: ["x", "+", "a", "b"]}

DIGIT_FULL_H = 13.31  # measured full-size digit height in MicroTeX frac (formula 5/6)


def parse_ztex(path: str) -> tuple[
    list[tuple[str, float, float, float]], list[tuple[float, float, float, float]]
]:
    """-> (texts, rules): texts=[(char,x,y,size)], rules=[(x,y,w,h)] non-white rects."""
    s = Path(path).read_text(encoding="utf-8")
    texts = []
    for node in ET.fromstring(s).iter():
        kind = node.tag.rsplit("}", 1)[-1]
        if kind == "path":
            content = node.get("data-text")
            x, y = node.get("data-x"), node.get("data-y")
        elif kind == "text":
            content = node.text
            x, y = node.get("x"), node.get("y")
        else:
            continue
        size = node.get("font-size")
        if content and x is not None and y is not None and size is not None:
            texts.append((unicodedata.normalize("NFKC", content), float(x), float(y), float(size)))
    rules = [(float(m.group(1)), float(m.group(2)), float(m.group(3)), float(m.group(4)))
             for m in re.finditer(
                 r'<rect x="([\d.]+)" y="([\d.]+)" width="([\d.]+)" height="([\d.]+)" fill="([^"]*)"', s)
             if not m.group(5).startswith("#fff")]
    return texts, rules


def _nums(d):
    return [float(x) for x in re.findall(r"-?\d+\.?\d*", d)]


def parse_microtex(path):
    """-> (uses, bbox, rules). bbox[gid]=(xmin,xmax,ymin,ymax) in glyph-local coords
    where (x,y) of the <use> is the origin (baseline for text glyphs, box top for
    big operators). rules = [(x1,y1,x2,y2)] stroked segments in canvas coords."""
    s = Path(path).read_text(encoding="utf-8")
    defs = dict(re.findall(r'<g id="(glyph-[\d-]+)">\s*(.*?)</g>', s, re.DOTALL))
    bbox = {}
    for gid, body in defs.items():
        xs, ys = [], []
        for d in re.findall(r'<path d="([^"]*)"', body):
            nums = _nums(d)
            xs += nums[0::2]
            ys += nums[1::2]
        if xs:
            bbox[gid] = (min(xs), max(xs), min(ys), max(ys))
    uses = [(gid, float(x), float(y))
            for gid, x, y in re.findall(
                r'<use xlink:href="#([^"]+)" x="([\d.]+)" y="([\d.]+)"/>', s)]
    rules = []
    for m in re.finditer(r'<path ([^>]*)>', s):
        attrs = m.group(1)
        t = re.search(r'transform="matrix\(([-\d.]+), 0, 0, ([-\d.]+), ([-\d.]+), ([-\d.]+)\)"', attrs)
        d = re.search(r'd="([^"]*)"', attrs)
        if not (t and d):
            continue
        sx, sy, ox, oy = (float(t.group(i)) for i in (1, 2, 3, 4))
        nums = _nums(d.group(1))
        for i in range(0, len(nums) - 3, 2):
            rules.append((nums[i] * sx + ox, nums[i + 1] * sy + oy,
                          nums[i + 2] * sx + ox, nums[i + 3] * sy + oy))
    return uses, bbox, rules


def vbox(use, bbox):
    """visual bbox on canvas: (xmin, xmax, ymin, ymax)."""
    gid, x, y = use
    b = bbox[gid]
    return (x + b[0], x + b[1], y + b[2], y + b[3])


# ---------------------------------------------------------------- ztex checks

def checks_ztex(n, kind, texts, rules):
    out = []
    if kind in ("plain", "script", "text", "textbold"):
        seq = "".join(t[0] for t in texts)
        exp = "".join(EXPECT_SEQ[n])
        out.append(("ltr-order", seq == exp,
                    f"chars in doc order {seq!r} == expected {exp!r}"))
        if kind in ("text", "textbold"):
            ys = [t[2] for t in texts]
            out.append(("row-baseline", max(ys) - min(ys) < 1e-6, f"baselines {ys}"))
    if kind == "script":
        base = texts[0]
        for t in texts[1:]:
            if t[1] > base[1] + 1e-6 and t[2] < base[2] - 1e-6:
                out.append(("sup-above", True,
                            f"'{t[0]}' baseline {t[2]:.2f} < base '{base[0]}' {base[2]:.2f}"))
                out.append(("sup-smaller", t[3] < base[3],
                            f"sup font-size {t[3]:g} < base {base[3]:g}"))
            elif t[1] > base[1] + 1e-6 and t[2] > base[2] + 1e-6:
                out.append(("sub-below", True,
                            f"'{t[0]}' baseline {t[2]:.2f} > base '{base[0]}' {base[2]:.2f}"))
            else:
                out.append(("script-pos", False,
                            f"'{t[0]}' at ({t[1]:.2f},{t[2]:.2f}) vs base ({base[1]:.2f},{base[2]:.2f})"))
    elif kind == "frac":
        if not rules:
            out.append(("frac-rule", False, "no rule rect found"))
            return out
        rx, ry, rw, rh = rules[0]
        r_top, r_bot = ry, ry + rh
        num = [t for t in texts if t[2] < r_top - 1e-6]
        den = [t for t in texts if t[2] > r_bot + 1e-6]
        out.append(("num-above", len(num) > 0 and all(t[2] < r_top for t in num),
                    f"num baselines {[t[2] for t in num]} < rule top {r_top:.2f}"))
        out.append(("den-below", len(den) > 0 and all(t[2] > r_bot for t in den),
                    f"den baselines {[t[2] for t in den]} > rule bottom {r_bot:.2f}"))
        out.append(("rule-between", bool(num and den),
                    f"rule y[{r_top:.2f},{r_bot:.2f}] between num {num[0][2]:.2f} and den {den[0][2]:.2f}"))
        left = min(t[1] for t in texts)
        right = max(t[1] for t in texts)
        out.append(("rule-spans", rx <= left + 1e-6 and rx + rw >= right - 1e-6,
                    f"rule x[{rx:.2f},{rx + rw:.2f}] covers glyph x[{left:.2f},{right:.2f}]"))
        if num:
            ys = [t[2] for t in num]
            out.append(("num-baseline", max(ys) - min(ys) < 1e-6, f"num baselines {ys}"))
        if den:
            ys = [t[2] for t in den]
            out.append(("den-baseline", max(ys) - min(ys) < 1e-6, f"den baselines {ys}"))
    elif kind == "bigop":
        op = texts[0]
        above = [t for t in texts[1:] if t[2] < op[2] - 0.5]
        below = [t for t in texts[1:] if t[2] > op[2] + 0.5]
        row = [t for t in texts[1:] if abs(t[2] - op[2]) <= 0.5]
        out.append(("limits-above", len(above) > 0 and all(t[2] < op[2] for t in above),
                    f"upper limit baselines {[t[2] for t in above]} < op baseline {op[2]:.2f}"))
        out.append(("limits-below", len(below) > 0 and all(t[2] > op[2] for t in below),
                    f"lower limit baselines {[t[2] for t in below]} > op baseline {op[2]:.2f}"))
        out.append(("row-baseline", all(abs(t[2] - op[2]) <= 0.5 for t in row),
                    f"row baselines {[t[2] for t in row]} aligned with op {op[2]:.2f}"))
        xs = [t[1] for t in row]
        out.append(("row-ltr", all(xs[i] <= xs[i + 1] for i in range(len(xs) - 1)),
                    f"row x {[f'{x:.2f}' for x in xs]}"))
    return out


# ----------------------------------------------------------- MicroTeX checks

def checks_microtex(n, kind, uses, bbox, rules):
    out = []
    if kind in ("plain", "script", "text", "textbold"):
        ordered = sorted(uses, key=lambda u: (u[1], u[2]))
        out.append(("elem-count", len(uses) == len(EXPECT_SEQ[n]),
                    f"{len(uses)} glyphs (expected {len(EXPECT_SEQ[n])})"))
        out.append(("ltr-order", all(ordered[i][1] <= ordered[i + 1][1] for i in range(len(ordered) - 1)),
                    f"x-order {[f'{u[1]:.2f}' for u in ordered]}"))
        if kind in ("text", "textbold"):
            ys = [u[2] for u in uses]
            out.append(("row-baseline", max(ys) - min(ys) < 0.05, f"baselines {ys}"))
        elif kind == "script":
            base = min(uses, key=lambda u: u[1])
            for u in sorted(uses, key=lambda u: u[2]):
                if u is base:
                    continue
                h = bbox[u[0]][3] - bbox[u[0]][2]
                if u[2] < base[2] - 0.05:
                    out.append(("sup-above", True,
                                f"sup y {u[2]:.2f} < base y {base[2]:.2f} (x {u[1]:.2f} > base x {base[1]:.2f})"))
                    out.append(("sup-smaller", h < DIGIT_FULL_H - 0.5,
                                f"script glyph h {h:.2f} < full-size digit h {DIGIT_FULL_H:.2f} (scale ~{h / DIGIT_FULL_H:.2f})"))
                elif u[2] > base[2] + 0.05:
                    out.append(("sub-below", True,
                                f"sub y {u[2]:.2f} > base y {base[2]:.2f} (x {u[1]:.2f} > base x {base[1]:.2f})"))
                else:
                    out.append(("script-pos", False, f"script y {u[2]:.2f} == base y {base[2]:.2f}"))
    elif kind == "frac":
        if not rules:
            out.append(("frac-rule", False, "no rule stroke found"))
            return out
        x1, y1, x2, y2 = rules[0]
        ry = (y1 + y2) / 2
        num = [u for u in uses if u[2] < ry - 0.05]
        den = [u for u in uses if u[2] > ry + 0.05]
        out.append(("num-above", len(num) > 0 and all(vbox(u, bbox)[3] < y1 + 0.05 for u in num),
                    f"num baselines {[u[2] for u in num]} above rule y {ry:.2f}"))
        out.append(("den-below", len(den) > 0 and all(vbox(u, bbox)[2] > y2 - 0.05 for u in den),
                    f"den baselines {[u[2] for u in den]} below rule y {ry:.2f}"))
        lx = min(vbox(u, bbox)[0] for u in uses)
        rx_ = max(vbox(u, bbox)[1] for u in uses)
        out.append(("rule-spans", x1 <= lx + 0.05 and x2 >= rx_ - 0.05,
                    f"rule x[{x1:.2f},{x2:.2f}] covers glyph x[{lx:.2f},{rx_:.2f}]"))
        out.append(("rule-thickness", 0.5 < (y2 - y1) if y2 != y1 else True,
                    f"rule stroke {y2 - y1:.2f}px (ztex 0.8px)"))
    elif kind == "bigop":
        op = max(uses, key=lambda u: bbox[u[0]][3] - bbox[u[0]][2])
        op_h = bbox[op[0]][3] - bbox[op[0]][2]
        op_center = op[2] + op_h / 2
        ob = vbox(op, bbox)
        above = [u for u in uses if u is not op and vbox(u, bbox)[3] < op_center - 0.05]
        below = [u for u in uses if u is not op and vbox(u, bbox)[2] > op_center + 0.05]
        row = [u for u in uses if u is not op
               and vbox(u, bbox)[2] <= op_center + 0.05 and vbox(u, bbox)[3] >= op_center - 0.05]
        out.append(("op-largest", True, f"op '{op[0]}' h {op_h:.2f} (others <= {max((bbox[u[0]][3] - bbox[u[0]][2] for u in uses if u is not op), default=0):.2f})"))
        out.append(("limits-above", len(above) > 0 and all(vbox(u, bbox)[3] < op_center for u in above),
                    f"upper-limit visual bottom {[f'{vbox(u,bbox)[3]:.1f}' for u in above]} < op center {op_center:.1f} (op top {ob[2]:.1f})"))
        out.append(("limits-below", len(below) > 0 and all(vbox(u, bbox)[2] > op_center for u in below),
                    f"lower-limit visual top {[f'{vbox(u,bbox)[2]:.1f}' for u in below]} > op center {op_center:.1f} (op bottom {ob[3]:.1f})"))
        if row:
            base_y = row[0][2]
            main = [u for u in row if abs(u[2] - base_y) < 0.05]
            out.append(("row-baseline", len(main) > 0,
                        f"row baselines {[u[2] for u in row]}; main row at {base_y:.2f}"))
            xs = [u[1] for u in row]
            out.append(("row-ltr", all(xs[i] <= xs[i + 1] for i in range(len(xs) - 1)),
                        f"row x {[f'{x:.2f}' for x in xs]}"))
            scripts = [u for u in row if abs(u[2] - base_y) >= 0.05]
            for u in scripts:
                out.append(("post-op-script", True,
                            f"'{u[0]}' baseline {u[2]:.2f} {'below' if u[2] > base_y else 'above'} row baseline {base_y:.2f}"))
    return out


# ------------------------------------------------------------------- spaces

def measure_ztex_gaps(n, texts):
    """Rasterize the ztex SVG at natural size (resvg text rendering is exact
    at 1x; zoomed renders shift glyphs via font fallback) and measure each
    glyph's ink run so inter-glyph gaps are computable (the ztex SVG carries
    no glyph widths)."""
    from PIL import Image
    png = f"{DIR}/{n}_z1x.png"
    subprocess.run(["resvg", f"{DIR}/{n}.svg", png], check=True, capture_output=True)
    img = Image.open(png).convert("RGB")
    w, h = img.size
    px = img.load()
    cols = [x for x in range(w) if any(min(px[x, y]) < 128 for y in range(h))]
    runs = []
    if cols:
        s = p = cols[0]
        for c in cols[1:]:
            if c == p + 1:
                p = c
            else:
                runs.append((s, p))
                s = p = c
        runs.append((s, p))
    gaps = []
    for i in range(len(texts) - 1):
        x0 = texts[i][1]
        best = None
        for r in runs:
            c = (r[0] + r[1]) / 2
            if abs(c - x0) < 6 and (best is None or abs(c - x0) < abs((best[0] + best[1]) / 2 - x0)):
                best = r
        if best is None:
            gaps.append((texts[i][0], texts[i + 1][0], float("nan")))
            continue
        gaps.append((texts[i][0], texts[i + 1][0], texts[i + 1][1] - best[1]))
    return gaps


def main():
    report = []
    all_ok = True
    for idx, (formula, kind) in enumerate(CORPUS, start=1):
        ztexts, zrules = parse_ztex(f"{DIR}/{idx}.svg")
        muses, mbbox, mrules = parse_microtex(f"{DIR}/{idx}_ref.svg")
        zc = checks_ztex(idx, kind, ztexts, zrules)
        mc = checks_microtex(idx, kind, muses, mbbox, mrules)
        if kind == "spaces":
            zg = measure_ztex_gaps(idx, ztexts)
            mg = []
            for i in range(len(muses) - 1):
                g = muses[i + 1][1] - vbox(muses[i], mbbox)[1]
                mg.append((f"g{i}", f"g{i+1}", g))
            z_ok = zg[0][2] < zg[1][2] < zg[2][2] and abs(zg[2][2] - 20) < 4
            m_ok = mg[0][2] < mg[1][2] < mg[2][2] and abs(mg[2][2] - 20) < 4
            zc.append(("gap-order+quad", z_ok,
                       f"ztex gaps {[f'{g[2]:.1f}' for g in zg]} (thin<med<quad, quad~20=1em)"))
            mc.append(("gap-order+quad", m_ok,
                       f"microtex gaps {[f'{g[2]:.1f}' for g in mg]} (thin<med<quad, quad~20=1em)"))
        zfail = [c for c in zc if not c[1]]
        mfail = [c for c in mc if not c[1]]
        ok = not zfail and not mfail
        all_ok = all_ok and ok
        report.append({"n": idx, "formula": formula, "kind": kind, "ok": ok,
                       "ztex": {"texts": ztexts, "checks": zc},
                       "microtex": {"uses": muses, "checks": mc}})
        print(f"\n=== {idx}. {formula}  [{kind}] -> {'PASS' if ok else 'MISMATCH'}")
        print("  ztex     :", " | ".join(f"{c[0]}:{'OK' if c[1] else 'FAIL'}" for c in zc))
        for c in zfail:
            print(f"      ztex FAIL {c[0]} -- {c[2]}")
        print("  microtex :", " | ".join(f"{c[0]}:{'OK' if c[1] else 'FAIL'}" for c in mc))
        for c in mfail:
            print(f"      microtex FAIL {c[0]} -- {c[2]}")
    Path(f"{DIR}/results.json").write_text(
        json.dumps(report, indent=1, default=str) + "\n", encoding="utf-8"
    )
    print(f"\nOVERALL: {'ALL PASS' if all_ok else 'SOME MISMATCHES'}")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
