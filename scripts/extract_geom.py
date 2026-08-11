#!/usr/bin/env python3
"""Per-glyph geometry extraction for ztex, MicroTeX, and XeTeX.

For a fixed corpus, renders each formula with all three engines and writes a
per-glyph JSON record to /tmp/cmp/<engine>_<i>.json:

    {"engine": "ztex", "formula": "...", "unit": "pt", "up": false,
     "base_size_pt": 20.0,
     "glyphs": [{"glyph": "x", "x": 0.0, "y": 17.3, "size": 20.0,
                 "ink": [xmin, ymin, xmax, ymax]}, ...]}

Coordinate conventions (identical across engines):
  * x,y = glyph baseline origin, SVG y-down (page/top-left origin), in pt.
  * up = false (never flipped to y-up).
  * size = font-size in pt (ztex <text font-size>, XeTeX <use> matrix scale,
    MicroTeX glyph bbox height -- MicroTeX has no font-size in its SVG).
  * ink = [xmin, ymin, xmax, ymax] ink bounding box in the same y-down page
    coordinates as x,y (None/absent when the ink cannot be derived).

Ink derivation per engine:
  * ztex:   the SVG carries only <text> with a font-family chain headed by
            "Latin Modern Math"; the drawn ink is what the viewer's font
            renderer produces. We compute it exactly from the Latin Modern
            Math OTF metrics (fontTools) at the declared font-size, so a
            missing/fallback font or a wrong scale shows up as an ink delta.
  * XeTeX:  mutool embeds the real glyph outlines in <defs>. Both mutool
            output generations are handled: the classic one
            (<use data-text transform="matrix(a,0,0,-a,x,y)"/> with paths in
            em units) and the newer one (<use xlink:href="#glyph-N-M" x y/>
            with paths already in pt, y-down from the use origin). For the
            newer generation the <use> carries no text; glyph text, baseline
            y and font size are recovered from a parallel `mutool draw -F
            stext` XML (render_xetex writes one next to the SVG).
  * MicroTeX: glyph paths in <defs>; the ink bbox is the path-point bbox
            translated to the <use> origin (same approximation the size
            field already used).

Rendering recipes:
  * ztex:     zig build run -- -i '<f>' -o out.svg -s 10 -b white
  * MicroTeX: clatexmath -headless -input='<f>' -output=out.svg
  * XeTeX:    minimal .tex -> xelatex -> PDF -> mutool draw -F svg
              (plus mutool draw -F stext for the newer SVG generation).

Usage: python3 scripts/extract_geom.py
"""
import glob
import html
import json
import os
import re
import shlex
import subprocess
import sys

OUT = "/tmp/cmp"
WORK = os.path.join(OUT, "work")
ZIG = "~/projects/ztex"
MICRO = "~/projects/MicroTeX"

CORPUS = [
    r"x^2",
    r"x_2",
    r"\frac{a+b}{c-d}",
    r"\sum_{i=1}^{n} x_i",
    r"a\cdot b",
    r"\int_0^1 x\,dx",
    r"x^2+y^2",
]

NIX_PKGS = "gtkmm3 gtksourceview gtksourceviewmm cairomm fontconfig freetype tinyxml-2 mupdf"

BASE_SIZE = {"ztex": 10.0, "micro": 20.0, "xetex": 10.0}  # pt


def run(cmd, cwd=None, timeout=600):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0:
        raise RuntimeError(
            f"cmd failed ({p.returncode}): {' '.join(cmd)}\nstdout: {p.stdout[-2000:]}\nstderr: {p.stderr[-2000:]}")
    return p

# ------------------------------------------------------------------ utils

_PATH_NUM = re.compile(r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?")


def _bez_extent(p0, p1, p2, p3):
    """Exact min/max of a cubic bezier coordinate on t in [0,1]."""
    vals = [p0, p1, p2, p3]
    a = -p0 + 3 * p1 - 3 * p2 + p3
    b = 2 * (p0 - 2 * p1 + p2)
    c = p1 - p0
    if abs(a) > 1e-12:
        disc = b * b - 4 * a * c
        if disc >= 0:
            sq = disc ** 0.5
            for t in ((-b + sq) / (2 * a), (-b - sq) / (2 * a)):
                if 0.0 < t < 1.0:
                    tm = 1 - t
                    vals.append(tm * tm * tm * p0 + 3 * tm * tm * t * p1
                                + 3 * tm * t * t * p2 + t * t * t * p3)
    elif abs(b) > 1e-12:
        t = -c / (2 * b)
        if 0.0 < t < 1.0:
            tm = 1 - t
            vals.append(tm * tm * tm * p0 + 3 * tm * tm * t * p1
                        + 3 * tm * t * t * p2 + t * t * t * p3)
    return min(vals), max(vals)


def _path_bbox(d):
    """Exact ink bbox (xmin, ymin, xmax, ymax) of a mutool SVG path.

    Parses M/L/C/H/V/S/Z (absolute or relative) and evaluates exact cubic
    bezier extents, so control points never inflate the bbox. On any
    malformed path it falls back to the coordinate-point bbox (never
    crashes; the point bbox is a slight over-estimate).
    """
    if not d:
        return None
    try:
        return _path_bbox_exact(d)
    except (ValueError, IndexError):
        nums = [float(m.group()) for m in _PATH_NUM.finditer(d)]
        if not nums:
            return None
        xs, ys = nums[0::2], nums[1::2]
        return (min(xs), min(ys), max(xs), max(ys))


_CMD = re.compile(r"[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?")


def _path_bbox_exact(d):
    """Exact bbox of an SVG path with M/L/C/H/V/Z (absolute or relative)."""
    toks = _CMD.findall(d)
    if not toks:
        return None
    i = 0
    cur = [0.0, 0.0]
    start = [0.0, 0.0]
    xs, ys = [], []

    def num():
        nonlocal i
        t = toks[i]
        if len(t) == 1 and t.isalpha():
            raise ValueError("unexpected command %r" % t)
        i += 1
        return float(t)

    def point(x, y):
        xs.append(x)
        ys.append(y)

    def cub(p0, p1, p2, p3):
        lo, hi = _bez_extent(p0[0], p1[0], p2[0], p3[0])
        xs.extend((lo, hi))
        lo, hi = _bez_extent(p0[1], p1[1], p2[1], p3[1])
        ys.extend((lo, hi))

    def is_cmd(t):
        return len(t) == 1 and t.isalpha()

    def rel(lower, base, v):
        return base + v if lower else v

    while i < len(toks):
        t = toks[i]
        i += 1
        if not is_cmd(t):
            raise ValueError("expected command, got %r" % t)
        lower = t.islower()
        if t in "Mm":
            x, y = num(), num()
            if lower:
                x += cur[0]
                y += cur[1]
            cur = [x, y]
            start = [x, y]
            point(x, y)
            while i < len(toks) and not is_cmd(toks[i]):
                x, y = num(), num()
                if lower:
                    x += cur[0]
                    y += cur[1]
                cur = [x, y]
                point(x, y)
        elif t in "Ll":
            x, y = num(), num()
            if lower:
                x += cur[0]
                y += cur[1]
            cur = [x, y]
            point(x, y)
            while i < len(toks) and not is_cmd(toks[i]):
                x, y = num(), num()
                if lower:
                    x += cur[0]
                    y += cur[1]
                cur = [x, y]
                point(x, y)
        elif t in "Cc":
            args = [num() for _ in range(6)]
            p0 = list(cur)
            p1 = [rel(lower, p0[0], args[0]), rel(lower, p0[1], args[1])]
            p2 = [rel(lower, p0[0], args[2]), rel(lower, p0[1], args[3])]
            p3 = [rel(lower, p0[0], args[4]), rel(lower, p0[1], args[5])]
            cub(p0, p1, p2, p3)
            cur = p3
            while i < len(toks) and not is_cmd(toks[i]):
                args = [num() for _ in range(6)]
                p0 = list(cur)
                p1 = [rel(lower, p0[0], args[0]), rel(lower, p0[1], args[1])]
                p2 = [rel(lower, p0[0], args[2]), rel(lower, p0[1], args[3])]
                p3 = [rel(lower, p0[0], args[4]), rel(lower, p0[1], args[5])]
                cub(p0, p1, p2, p3)
                cur = p3
        elif t in "Hh":
            x = num()
            if lower:
                x += cur[0]
            cur = [x, cur[1]]
            point(*cur)
            while i < len(toks) and not is_cmd(toks[i]):
                x = num()
                if lower:
                    x += cur[0]
                cur = [x, cur[1]]
                point(*cur)
        elif t in "Vv":
            y = num()
            if lower:
                y += cur[1]
            cur = [cur[0], y]
            point(*cur)
            while i < len(toks) and not is_cmd(toks[i]):
                y = num()
                if lower:
                    y += cur[1]
                cur = [cur[0], y]
                point(*cur)
        elif t in "Zz":
            cur = list(start)
        else:
            raise ValueError("unsupported path command %r" % t)
    if not xs:
        return None
    return (min(xs), min(ys), max(xs), max(ys))


def _use_elements(s):
    """Yield attribute dicts for every <use .../> in the SVG."""
    for m in re.finditer(r"<use\b([^>]*)/?>", s):
        yield dict(re.findall(r'([\w:.-]+)="([^"]*)"', m.group(1)))


# ------------------------------------------------------- Latin Modern Math

_LM = {}  # lazy: path, upem, cmap, bbox{cp: (xmin,ymin,xmax,ymax) font units}


def _find_lm_math():
    """Locate the Latin Modern Math OTF via fontconfig, else store paths."""
    try:
        p = subprocess.run(["fc-match", "-f", "%{file}", "Latin Modern Math"],
                           capture_output=True, text=True, timeout=30)
        hit = p.stdout.strip()
        if hit and os.path.exists(hit):
            return hit
    except OSError:
        pass
    for pat in ("/nix/store/*/share/fonts/opentype/*/latinmodern-math.otf",
                "/nix/store/*/latinmodern-math.otf",
                "/usr/share/fonts/**/latinmodern-math.otf",
                "/usr/local/share/fonts/**/latinmodern-math.otf"):
        hits = glob.glob(pat)
        if hits:
            return hits[0]
    return None


def _load_lm_math():
    """Load Latin Modern Math ink bboxes (once). Returns True on success."""
    if "bbox" in _LM:
        return True
    path = _find_lm_math()
    if not path:
        return False
    try:
        from fontTools.pens.boundsPen import BoundsPen
        from fontTools.ttLib import TTFont
    except ImportError:
        return False
    font = TTFont(path)
    gs = font.getGlyphSet()
    cmap = font.getBestCmap()
    bbox = {}
    for cp, name in cmap.items():
        pen = BoundsPen(gs)
        gs[name].draw(pen)
        if pen.bounds:
            bbox[cp] = pen.bounds
    _LM.update(path=path, upem=font["head"].unitsPerEm, cmap=cmap, bbox=bbox)
    return True


def _ztex_ink_bbox(ch, size_pt):
    """Ink bbox (xmin, ymin, xmax, ymax) in pt, font-space y-up, or None."""
    if not _load_lm_math():
        return None
    cp = ord(ch)
    b = _LM["bbox"].get(cp)
    if b is None:
        return None
    s = size_pt / _LM["upem"]
    return (b[0] * s, b[1] * s, b[2] * s, b[3] * s)


# ---------------------------------------------------------------- rendering

def render_ztex(i, formula):
    out = os.path.join(WORK, f"ztex_{i}.svg")
    run(["zig", "build", "run", "--", "-i", formula, "-o", out, "-s", "10", "-b", "white"],
        cwd=ZIG)
    return out


def render_micro(i, formula):
    out = os.path.join(WORK, f"micro_{i}.svg")
    cmd = f"_build/src/clatexmath -headless -input={shlex.quote(formula)} -output={shlex.quote(out)}"
    run(["nix-shell", "-p", *NIX_PKGS.split(), "--run", cmd], cwd=MICRO)
    return out


def render_xetex(i, formula):
    doc = os.path.join(WORK, f"xetex_{i}.tex")
    with open(doc, "w") as f:
        f.write("\\documentclass{article}\n\\pagestyle{empty}\n\\begin{document}\n")
        f.write("\\[" + formula + "\\]\n")
        f.write("\\end{document}\n")
    run(["xelatex", "-interaction=nonstopmode", "-halt-on-error", doc], cwd=WORK)
    pdf = os.path.join(WORK, f"xetex_{i}.pdf")
    svg = os.path.join(WORK, f"xetex_{i}.svg")
    cmd = f"mutool draw -F svg {shlex.quote(pdf)}"
    p = subprocess.run(["nix-shell", "-p", "mupdf", "--run", cmd],
                       capture_output=True, text=True, timeout=600)
    if p.returncode != 0:
        raise RuntimeError(f"mutool failed: {p.stderr[-2000:]}")
    with open(svg, "w") as f:
        f.write(p.stdout)
    # Text/baseline source for the newer mutool SVG generation (no data-text).
    stext = os.path.join(WORK, f"xetex_{i}.stext")
    cmd = f"mutool draw -F stext -o {shlex.quote(stext)} {shlex.quote(pdf)}"
    q = subprocess.run(["nix-shell", "-p", "mupdf", "--run", cmd],
                       capture_output=True, text=True, timeout=600)
    if q.returncode != 0:
        stext = None
    return svg, stext


# ---------------------------------------------------------------- parsing

def parse_ztex_svg(path):
    """<text x y font-size font-family> -> per-glyph records with ink.

    The font-space ink bbox is y-up with the baseline at 0 while the SVG is
    y-down, so ink = [x + xmin*s, y - ymax*s, x + xmax*s, y - ymin*s].
    """
    s = open(path, encoding="utf-8").read()
    out = []
    for m in re.finditer(
            r'<text x="([-\d.eE]+)pt?" y="([-\d.eE]+)pt?" font-size="([-\d.eE]+)pt?"[^>]*>([^<]*)</text>', s):
        x, y, size = float(m.group(1)), float(m.group(2)), float(m.group(3))
        txt = html.unescape(m.group(4))
        rec = {"glyph": txt, "x": x, "y": y, "size": size}
        if len(txt) == 1:
            b = _ztex_ink_bbox(txt, size)
            if b is not None:
                xmin, ymin, xmax, ymax = b
                rec["ink"] = [x + xmin, y - ymax, x + xmax, y - ymin]
        out.append(rec)
    return out


def parse_micro_svg(path):
    s = open(path).read()
    defs = dict(re.findall(r'<g id="(glyph-[\d-]+)">\s*(.*?)</g>', s, re.S))
    bbox = {}
    for gid, body in defs.items():
        xs, ys = [], []
        for d in re.findall(r'<path d="([^"]*)"', body):
            nums = [float(x) for x in _PATH_NUM.findall(d)]
            xs += nums[0::2]
            ys += nums[1::2]
        if xs:
            bbox[gid] = (min(xs), max(xs), min(ys), max(ys))
    out = []
    for attrs in _use_elements(s):
        gid = attrs.get("xlink:href", "").lstrip("#")
        if not gid or "x" not in attrs or "y" not in attrs:
            continue
        x, y = float(attrs["x"]), float(attrs["y"])
        b = bbox.get(gid)
        rec = {"glyph": gid, "x": x, "y": y,
               "size": (b[3] - b[2]) if b else 0.0}
        if b:
            rec["ink"] = [x + b[0], y + b[2], x + b[1], y + b[3]]
        out.append(rec)
    return out


def _stext_chars(path):
    """mutool -F stext XML -> [(x, y, size, text)] per non-space char.

    x = glyph left edge, y = baseline, both y-down page pt (matching the
    SVG coordinate space).
    """
    s = open(path, encoding="utf-8").read()
    chars = []
    for fm in re.finditer(r'<font name="[^"]*" size="([-\d.eE]+)">(.*?)</font>', s, re.S):
        size = float(fm.group(1))
        for cm in re.finditer(r"<char\b([^>]*)>", fm.group(2)):
            attrs = dict(re.findall(r'([\w:.-]+)="([^"]*)"', cm.group(1)))
            if "x" not in attrs or "y" not in attrs or "c" not in attrs:
                continue
            c = html.unescape(attrs["c"])
            if c.strip():
                chars.append((float(attrs["x"]), float(attrs["y"]), size, c))
    return chars


def _pair_stext(uses, chars):
    """Attach text/baseline-y/font-size from stext to the newer-format uses.

    Both lists sort identically by (y, x) for well-formed math rows, so pair
    positionally after sorting; the residual offsets (use origin vs stext
    left edge / baseline) are per-font and < 1.2pt on real data.
    """
    us = sorted(enumerate(uses), key=lambda t: (t[1]["y"], t[1]["x"]))
    cs = sorted(enumerate(chars), key=lambda t: (t[1][1], t[1][0]))
    for (ui, u), (ci, c) in zip(us, cs):
        u["glyph"] = c[3]
        u["y"] = c[1]
        u["size"] = c[2]


def parse_xetex_svg(path, stext_path=None):
    """<use> glyphs -> per-glyph records with ink, from defs paths.

    Old mutool generation: <use data-text transform="matrix(a,0,0,-a,e,f)"/>,
    defs paths in em units (y-up from the baseline); the matrix maps them to
    the page. Newer generation: <use xlink:href="#glyph-N-M" x y/> with defs
    paths already in pt (y-down from the use origin); text, baseline y and
    font size come from the stext XML.
    """
    s = open(path, encoding="utf-8").read()
    defs = dict(re.findall(r'<g id="([^"]+)">\s*<path d="([^"]*)"', s))
    defs.update(re.findall(r'<path id="([^"]+)" d="([^"]*)"', s))
    uses = list(_use_elements(s))
    if not uses:
        return []
    if "transform" in uses[0]:
        return _parse_xetex_old(defs, uses)
    return _parse_xetex_new(defs, uses, stext_path)


def _parse_xetex_old(defs, uses):
    out = []
    for attrs in uses:
        gid = attrs.get("xlink:href", "").lstrip("#")
        m = re.search(
            r"matrix\(([-\d.eE]+),([-\d.eE]+),([-\d.eE]+),([-\d.eE]+),([-\d.eE]+),([-\d.eE]+)\)",
            attrs.get("transform", ""))
        if not m:
            continue
        a, _b, _c, d, e, f = (float(v) for v in m.groups())
        size = abs(a) if abs(a) == abs(d) else (a * a + _c * _c) ** 0.5
        txt = html.unescape(attrs.get("data-text", ""))
        rec = {"glyph": txt, "x": e, "y": f, "size": size}
        pb = _path_bbox(defs.get(gid, ""))
        if pb:
            xmin, ymin, xmax, ymax = pb
            # Path space is y-up em units; y' = d*y + f with d<0 flips to
            # y-down page coords.
            rec["ink"] = [e + a * xmin, f + d * ymax, e + a * xmax, f + d * ymin]
        out.append(rec)
    return out


def _parse_xetex_new(defs, uses, stext_path=None):
    out = []
    for attrs in uses:
        gid = attrs.get("xlink:href", "").lstrip("#")
        if not gid or "x" not in attrs or "y" not in attrs:
            continue
        x, y = float(attrs["x"]), float(attrs["y"])
        rec = {"glyph": None, "x": x, "y": y, "size": None}
        pb = _path_bbox(defs.get(gid, ""))
        if pb:
            xmin, ymin, xmax, ymax = pb  # y-down offset from the use origin
            rec["ink"] = [x + xmin, y + ymin, x + xmax, y + ymax]
        out.append(rec)
    if stext_path and os.path.exists(stext_path):
        _pair_stext(out, _stext_chars(stext_path))
    return [r for r in out if r.get("glyph")]


# ---------------------------------------------------------------- records

def record(engine, i, glyphs):
    gs = []
    for g in glyphs:
        if not g.get("glyph", ""):
            continue
        rec = {"glyph": g["glyph"], "x": g["x"], "y": g["y"], "size": g["size"]}
        if g.get("ink") is not None:
            rec["ink"] = [float(v) for v in g["ink"]]
        gs.append(rec)
    return {
        "engine": engine,
        "formula": CORPUS[i - 1],
        "unit": "pt",
        "up": False,
        "base_size_pt": BASE_SIZE[engine],
        "glyphs": gs,
    }


def main():
    os.makedirs(WORK, exist_ok=True)
    manifest = []
    for i, formula in enumerate(CORPUS, 1):
        # ztex
        svg = render_ztex(i, formula)
        ztex_rec = record("ztex", i, parse_ztex_svg(svg))
        with open(os.path.join(OUT, f"ztex_{i}.json"), "w") as f:
            json.dump(ztex_rec, f, ensure_ascii=False, indent=1)
        # MicroTeX
        svg = render_micro(i, formula)
        micro_rec = record("micro", i, parse_micro_svg(svg))
        with open(os.path.join(OUT, f"micro_{i}.json"), "w") as f:
            json.dump(micro_rec, f, ensure_ascii=False, indent=1)
        # XeTeX
        svg, stext = render_xetex(i, formula)
        xetex_rec = record("xetex", i, parse_xetex_svg(svg, stext))
        with open(os.path.join(OUT, f"xetex_{i}.json"), "w") as f:
            json.dump(xetex_rec, f, ensure_ascii=False, indent=1)
        manifest.append((i, formula, ztex_rec, micro_rec, xetex_rec))
    # report
    print(f"{'i':>2} {'formula':<22} {'ztex':>22} {'micro':>22} {'xetex':>22}")
    for i, formula, z, m, x in manifest:
        row = lambda r: " ".join(f"{g['glyph']}@{g['x']:.1f},{g['y']:.1f}" for g in r["glyphs"])
        print(f"{i:>2} {formula:<22} {row(z):>22} {row(m):>22} {row(x):>22}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
