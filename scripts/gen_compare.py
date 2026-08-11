#!/usr/bin/env python3
"""Generate ztex + XeTeX reference SVGs for a formula, at a comparable scale.

Usage:
    scripts/gen_compare.py '<formula>' [--size PT] [--open] [--out DIR]

Renders:
  - ours:  ztex via `zig build run -- -i F -o ours.svg -s PT -b white`
           (a tight SVG of <text> elements; ImageMagick `display` renders it).
  - ref:   XeTeX standalone (tightly cropped to the formula, not an A4 page)
           -> xelatex -> pdftocairo -svg. pdftocairo's SVG renders in `display`
           (mutool's SVG uses <use xlink:href> refs that ImageMagick drops,
           showing an empty image).

Both are set at the same font size (default 10pt) and tightly cropped, so their
SVG dimensions are comparable. Prints both sizes; with --open, opens both via
`display` back-to-back.

NOTE: pdftocairo SVG is for VISUAL comparison. The numeric alignment pipeline
(compare_engines.py) needs per-glyph geometry, which requires mutool's SVG
(per-glyph data-text + transform) — see extract_geom.py for that.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ZIG = "zig"  # from PATH (devenv)
BORDER = 2  # pt margin inside the standalone page


def run(cmd, cwd=None, timeout=600):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0:
        raise RuntimeError(
            f"cmd failed ({p.returncode}): {' '.join(cmd)}\n"
            f"stdout: {p.stdout[-2000:]}\nstderr: {p.stderr[-2000:]}")
    return p


def render_ours(formula, size, out_dir):
    out = os.path.join(out_dir, "ours.svg")
    run([ZIG, "build", "run", "--", "-i", formula, "-o", out, "-s", str(size),
         "-b", "white"], cwd=REPO)
    return out


def render_ref(formula, size, out_dir):
    """XeTeX standalone (tight page) -> PDF -> pdftocairo SVG."""
    tex = os.path.join(out_dir, "ref.tex")
    with open(tex, "w") as f:
        f.write("\\documentclass[border=%dpt]{standalone}\n"
                "\\usepackage{amsmath}\n"
                "\\usepackage{lmodern}\n"
                "\\begin{document}\n"
                "$\\displaystyle %s$\n"
                "\\end{document}\n" % (BORDER, formula))
    pdf = os.path.join(out_dir, "ref.pdf")
    # fontsize: standalone honours \fontsize via documentclass options or size10.
    run(["xelatex", "-interaction=nonstopmode", "-halt-on-error",
         "-output-directory=" + out_dir, tex], cwd=out_dir)
    run(["pdftocairo", "-svg", pdf, os.path.join(out_dir, "ref.svg")], cwd=out_dir)
    return os.path.join(out_dir, "ref.svg")


def svg_size(path):
    import re
    s = open(path).read()
    m = re.search(r'viewBox="([-\d.eE]+) ([-\d.eE]+) ([-\d.eE]+) ([-\d.eE]+)"', s)
    if m:
        return (float(m.group(3)), float(m.group(4)))
    w = re.search(r'width="([\d.eE]+)"', s)
    h = re.search(r'height="([\d.eE]+)"', s)
    return (float(w.group(1)) if w else 0.0, float(h.group(1)) if h else 0.0)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("formula", help="LaTeX math (e.g. r'\\sum_{i=1}^{n} x_i')")
    ap.add_argument("--size", type=float, default=10.0, help="font size in pt (default 10)")
    ap.add_argument("--open", action="store_true", help="open both SVGs with `display`")
    ap.add_argument("--out", default=None, help="output dir (default: temp)")
    args = ap.parse_args()

    out_dir = args.out or tempfile.mkdtemp(prefix="cmp_")
    os.makedirs(out_dir, exist_ok=True)
    ours = render_ours(args.formula, args.size, out_dir)
    ref = render_ref(args.formula, args.size, out_dir)
    w_o, h_o = svg_size(ours)
    w_r, h_r = svg_size(ref)
    print(f"ours: {ours}  {w_o:.2f} x {h_o:.2f} pt")
    print(f"ref:  {ref}  {w_r:.2f} x {h_r:.2f} pt")
    if args.open:
        for p in (ours, ref):
            subprocess.Popen(["nohup", "display", p],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
