#!/usr/bin/env python3
"""Adversarial vision critique for ztex renders — two-stage propose/verify.

Pipeline:
  ztex (formula -> SVG)  ->  PIL rasterizer (SVG -> PNG)  ->  vision model (proposes defects)
                                             \\-> geometric verifier (SVG + LM font metrics) -- confirms/refutes

Stage 1 (PROPOSE): the vision model is an ADVERSARIAL critic. It hunts for
rendering defects (edge clipping, off-center big-op limits, glyph overlap,
truncated glyphs, misplaced scripts) and reports quantitative positions as
fractions of the image, never vague impressions.

Stage 2 (VERIFY): every vision claim is checked against DETERMINISTIC ground
truth computed from the ztex SVG itself: per-glyph ink boxes in SVG pt, union
ink bbox, per-edge clipping overflow, big-op/limit-op centering offsets,
pairwise ink-box overlaps, and glyphs that render nothing. Ink is taken from
where the document actually paints it — a <text> run from the real Latin
Modern OTF outline at the declared size (fontTools BoundsPen), a <path> from
its OWN `d` outline measured exactly (curve extrema included, never a
control box). The geometric verdict is AUTHORITATIVE: a vision claim fails
the verdict only when geometry confirms it; claims geometry contradicts are
marked "refuted (vision artifact)" and never fail. This stops the loop from
chasing vision hallucinations (e.g. a "0.05 offset" limit that is
geometrically 0.0, or "overlaps" with 1.6pt gaps).

The PNG follows the ACTUAL DOCUMENT. Resolved glyphs, MATH variants and
assemblies carry their painted outlines as absolute <path> coordinates.
The rasterizer fills those paths, including filled decoration bands, with
nonzero winding, the element's own alpha and the document's painter order.
Nothing is reconstructed from a nominal font metric. An unavailable glyph
remains a <text> fallback; its appearance depends on the available font.

Vision backend: OpenRouter chat-completions with a vision model
(OPENROUTER_API_KEY env var). When no key is present, the script still
renders, writes the ready-to-use prompt + JSON report skeleton, and skips
the model call (status "not-run") — an orchestrator can feed the PNG and
prompt to its own vision tool.

Usage:
  scripts/critique.py -i '\\int_0^1 x\\,dx + \\sum_{i=1}^{n} \\frac{1}{i^2}'
  scripts/critique.py 'x^2' --size 48 --no-critique

Outputs (per run):
  notes/critique-<n>.md                        render info + vision verdict
  notes/artifacts/critique-<n>/render.svg      ztex output
  notes/artifacts/critique-<n>/render.png      PIL raster (96 dpi, 1pt = 4/3 px)
  notes/artifacts/critique-<n>/critique-<n>.prompt.txt   prompt used
"""

import argparse
import base64
import glob
import json
import os
import math
import re
import struct
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.basePen import BasePen
from fontTools.svgLib.path import parse_path
from fontTools.ttLib import TTFont

DEFAULT_VISION_MODEL = "qwen/qwen-2.5-vl-72b-instruct"
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
OPENROUTER_TIMEOUT = 180

# ── PIL rasterizer (follows the actual document) ────────────────────────────
# The ztex SVG declares pt lengths (root width/height carry "pt", viewBox is
# unitless-pt). We rasterize at 96 dpi: every pt → 96/72 = 4/3 px, applied
# uniformly to the canvas, glyph positions AND font sizes, so a 1pt glyph
# renders at exactly 4/3 px — the same geometry a browser gives at 96 dpi.
PT_TO_PX = 96.0 / 72.0
# PIL's direct glyph rasterization at 48pt+ renders strokes measurably
# bolder than mutool's reference raster (per-glyph ink coverage ~+4% at the
# same px/pt — see rasterize_svg). Supersample 2x and LANCZOS-downscale so
# the critique compares glyph shapes, not raster antialiasing.
RASTER_SUPERSAMPLE = 2
# Scanlines sampled per pixel row when filling a <path>: the horizontal
# coverage of each span is exact, so 4 rows of samples already antialias the
# diagonal edges of a stem to under 1/8 of a pixel before the LANCZOS pass.
PATH_SUB_SCANLINES = 4
# Maximum chord error, in document pt, when a quadratic/cubic segment is
# flattened into the polyline the scanline filler walks. 0.01pt is 0.027px at
# 96 dpi — below the quantization of the raster it feeds, so the filled shape
# is the outline the document declares.
PATH_FLATTEN_TOL_PT = 0.01

DEFAULT_FONT_DIR = "/nix/store/wgpnygkr70hxa0vj5ka284cfc65bfzyn-devenv-profile/share/fonts/opentype"
LM_MATH_FONT = "latinmodern-math.otf"   # math runs (glyphs are math-italic already)
LM_ROMAN_FONT = "lmroman10-regular.otf"  # \text / \mathrm runs
LM_BOLD_FONT = "lmroman10-bold.otf"      # \mathbf runs

# ── Geometric verifier (deterministic ground truth) ────────────────────────
BIGOP_GLYPHS = set("∑∫∏⋃⋂⨆∐∮")        # operators that take over/under limits
# Delimiter codepoints a STRETCHED \left..\right fence can be built from. The
# ladder rung, the glyph assembly and the required cover are all already
# baked into the emitted <path> outline, so nothing here resolves a size —
# the pairing below only exists so the verifier can tell an intended wrap of
# the enclosed content from a real ink collision.
DELIMITER_CPS = (0x0028, 0x0029, 0x005B, 0x005D, 0x007B, 0x007D,
                 0x27E8, 0x27E9, 0x230A, 0x230B, 0x2308, 0x2309,
                 0x007C, 0x2223, 0x2016)
DELIM_PAIRS = {0x0028: 0x0029, 0x005B: 0x005D, 0x007B: 0x007D,
               0x27E8: 0x27E9, 0x230A: 0x230B, 0x2308: 0x2309,
               0x007C: 0x007C, 0x2223: 0x2223, 0x2016: 0x2016}  # open -> close
DELIM_OPENERS = frozenset(DELIM_PAIRS)
DELIM_CLOSERS = frozenset(DELIM_PAIRS.values())
DELIM_OPENER_OF = {close: open_ for open_, close in DELIM_PAIRS.items()}

LIMITOP_NAMES = frozenset("""lim liminf limsup injlim projlim max min sup inf
arg ker dim deg det Pr pr gcd hom exp ln log lg sin cos tan cot sec csc
arcsin arccos arctan sinh cosh tanh coth""".split())
OP_ALIASES = {  # vision may name an operator "\sum", "sum" or "∑" — canonicalize
    "sum": "∑", "prod": "∏", "int": "∫", "bigcup": "⋃", "bigcap": "⋂",
    "bigsqcup": "⨆", "coprod": "∐",
    "lim": "lim", "liminf": "liminf", "limsup": "limsup", "max": "max",
    "min": "min", "sup": "sup", "inf": "inf", "det": "det", "gcd": "gcd",
    "arg": "arg", "ker": "ker", "dim": "dim", "deg": "deg", "hom": "hom",
    "exp": "exp", "ln": "ln", "log": "log", "lg": "lg", "sin": "sin",
    "cos": "cos", "tan": "tan", "cot": "cot", "sec": "sec", "csc": "csc",
    "arcsin": "arcsin", "arccos": "arccos", "arctan": "arctan",
    "sinh": "sinh", "cosh": "cosh", "tanh": "tanh", "coth": "coth", "pr": "Pr",
}
ROW_BASELINE_TOL_PT = 1.0      # baselines within this form one row
LIMIT_TOUCH_TOL_PT = 2.0       # a limit may touch its operator up to this
BAR_MAX_HEIGHT_PT = 3.0        # rects thinner than this are fraction bars
LIMIT_OFFSET_FRACTION = 0.01   # |cx_op - cx_limit| > 1% of width = defect
OVERLAP_REPORT_PT2 = 0.01      # report intersections >= this area (pt^2)
CLIP_EPS_PT = 1e-9             # any ink past the canvas edge is clipping

PROMPT_TEMPLATE = r"""\
You are an adversarial critic for a LaTeX math renderer (ztex). Your job is to HUNT FOR DEFECTS in the rendered formula image. Assume defects exist. Inspect the image carefully; do not rubber-stamp.

GROUND TRUTH FORMULA: `{formula}`

The image is a PNG, {width}x{height} pixels. Report all positions as FRACTIONS of image width/height (0.0 = left/top edge, 1.0 = right/bottom edge), to 2-3 decimal places. If a measurement is ambiguous, say so and give your best estimate.

Check EVERY item below; missing a check is a failure of this critique.

1. EDGE CLIPPING — is any ink cut off at an image border?
   - For each edge (top, bottom, left, right) estimate the percentage of the cut glyph that is missing (0 = no clipping).
   - Estimate the ink bounding box of the whole formula: [x_left, x_right, y_top, y_bottom] as fractions.
   - A glyph touching the border is a FAIL even if only a sliver is missing.

2. BIG-OP LIMIT CENTERING — for every operator with limits (\sum, \prod, \int, \bigcup, ...):
   - Estimate the horizontal center of the operator glyph: cx_op.
   - Estimate the horizontal center of each attached limit (numerator/limit above or below, or the endpoint limits of an \int): cx_limit.
   - Report |cx_op - cx_limit| as a fraction of image width. > 0.01 (1% of width) is a FAIL.
   - Also check each limit is fully visible and not merged with the operator glyph.

3. ADJACENT-TERM OVERLAP — do neighboring symbols or lines overlap or touch?
   - For each suspicious pair, name both glyphs, estimate the overlapped fraction of the smaller glyph, and give the location.
   - Overlap > 2% of the smaller glyph is a FAIL. Flag lines that punch through fraction bars or strike through other glyphs.

4. COMPLETE GLYPHS — is every glyph complete (no stubs, no missing strokes, no shorn serifs)?
   - Pay special attention to large operators (\int, \sum, \sqrt, tall parentheses) and wide accents.
   - A truncated glyph is a FAIL even if the cut is at the canvas edge (also report it under clipping).

5. SUBSCRIPTS & LIMITS — for every sub/superscript and every limit:
   - Is it visible (not blank, not fused into the base glyph)?
   - Is its placement correct relative to the base (subscript below/right, superscript above/right, limits above/below the operator)?
   - Report each script's center as (x, y) fractions and whether placement is OK.

6. LATEX-LIKENESS — does this look like a professional LaTeX render of the given formula?
   - Score 0-10 (10 = indistinguishable from LaTeX).
   - List the top visual deviations, each with severity minor/major.

ANSWER FORMAT — output ONLY one JSON object, no prose before or after:

{{
  "verdict": "PASS" or "FAIL",
  "clipping": {{"top_pct": 0, "bottom_pct": 0, "left_pct": 0, "right_pct": 0, "ink_bbox": [0, 0, 0, 0], "note": ""}},
  "bigop_limits": [{{"operator": "", "cx_op": 0.0, "cx_limit": 0.0, "offset_pct": 0.0, "visible": true, "note": ""}}],
  "overlaps": [{{"pair": "", "overlap_pct": 0.0, "location": "", "note": ""}}],
  "glyphs": [{{"glyph": "", "complete": true, "note": ""}}],
  "scripts": [{{"script": "", "x": 0.0, "y": 0.0, "visible": true, "placement_ok": true, "note": ""}}],
  "latex_likeness": {{"score": 0, "top_deviations": [{{"issue": "", "severity": ""}}]}},
  "summary": "one or two sentences"
}}

Set "verdict" to "FAIL" if ANY check above fails. Empty arrays mean no problems found in that category. Do not invent problems that are not visible; but hunt for real ones.
"""


REF_PROMPT_TEMPLATE = r"""\
Four stacked panes of the same formula: `{formula}`. Top = ztex render (ours), then XeTeX, KaTeX, and MathJax (bottom) — the three web/TeX references.

Compare OURS against ALL THREE references. List EVERY visual nit in OURS vs any reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {{"nits": [{{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX|MathJax"}}], "verdict": "PASS|FAIL"}}.
"""


def slugify(formula, limit=48):
    """Short filesystem-safe id for a formula (for display, not paths)."""
    s = re.sub(r"\\[a-zA-Z]+", "O", formula)
    s = re.sub(r"[^A-Za-z0-9_^+=.,()/ -]", "", s)
    s = re.sub(r"\s+", " ", s).strip()
    return (s[:limit] + "..") if len(s) > limit else (s or "formula")


def png_size(path):
    """(width, height) of a PNG by reading its IHDR; stdlib only."""
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"not a PNG: {path}")
    w, h = struct.unpack(">II", head[16:24])
    return w, h


def next_critique_number(out_dir):
    """Smallest n such that notes/critique-<n>.md does not exist yet."""
    existing = [int(m.group(1)) for m in
                (re.match(r"critique-(\d+)\.md$", p.name) for p in Path(out_dir).glob("critique-*.md"))
                if m]
    return (max(existing) + 1) if existing else 1


def next_ref_critique_number(out_dir):
    """Smallest n such that notes/critique-ref-<n>.md does not exist yet."""
    existing = [int(m.group(1)) for m in
                (re.match(r"critique-ref-(\d+)\.md$", p.name) for p in Path(out_dir).glob("critique-ref-*.md"))
                if m]
    return (max(existing) + 1) if existing else 1


def render_svg(ztex_binary, use_build_run, formula, size, bg, svg_path):
    """ztex: formula -> SVG. Returns the argv used (for the report)."""
    if use_build_run or not ztex_binary:
        cmd = ["zig", "build", "run", "--", "-i", formula, "-o", str(svg_path),
               "-s", str(size), "-b", bg]
    else:
        cmd = [ztex_binary, "-i", formula, "-o", str(svg_path), "-s", str(size), "-b", bg]
    subprocess.run(cmd, check=True, capture_output=True, text=True)
    return cmd


_LM_FONT_PATTERNS = {
    LM_MATH_FONT: [
        "{dir}/latinmodern-math.otf",
        "/nix/store/*/share/fonts/opentype/latinmodern-math.otf",
        "/usr/share/fonts/**/latinmodern-math.otf",
    ],
    LM_ROMAN_FONT: [
        "{dir}/public/lm/lmroman10-regular.otf",
        "/nix/store/*/share/fonts/opentype/public/lm/lmroman10-regular.otf",
        "/usr/share/fonts/**/lmroman10-regular.otf",
    ],
    LM_BOLD_FONT: [
        "{dir}/public/lm/lmroman10-bold.otf",
        "/nix/store/*/share/fonts/opentype/public/lm/lmroman10-bold.otf",
        "/usr/share/fonts/**/lmroman10-bold.otf",
    ],
}


_lm_font_cache: dict[tuple[str, str], str | None] = {}
_LM_FONT_SENTINEL = object()


def find_lm_font(name, font_dir=DEFAULT_FONT_DIR):
    """Absolute path to a Latin Modern face; None if not found.

    Tries the known devenv-profile path first, then globs the Nix store and
    system font dirs so the script still works when the store path moves.
    Cached: the same (name, font_dir) pair always returns the same result
    without re-globbing the filesystem.
    """
    key = (name, font_dir)
    cached = _lm_font_cache.get(key, _LM_FONT_SENTINEL)
    if cached is not _LM_FONT_SENTINEL:
        return cached
    for pat in _LM_FONT_PATTERNS[name]:
        for hit in sorted(glob.glob(pat.format(dir=font_dir))):
            _lm_font_cache[key] = hit
            return hit
    _lm_font_cache[key] = None
    return None


_font_cache = {}


def _font(path, size_px):
    """Cached ImageFont; keyed by (path, size) so per-run loads stay cheap."""
    key = (path, size_px)
    f = _font_cache.get(key)
    if f is None:
        f = ImageFont.truetype(path, size_px)
        _font_cache[key] = f
    return f


def _lm_font_name(attrs):
    """Font-face file name for one <text> element.

    The math family ("Latin Modern Math, ...") is the default: LM Math's
    glyphs ARE the math-italic shapes, so font-style="italic" needs no
    synthetic slant. Runs on the roman family get lmroman10-regular (bold
    face when font-weight="bold", falling back to regular). The math check
    must come first — the math family string contains "Latin Modern Roman"
    as a fallback member. Shared by the PIL rasterizer and the geometric
    verifier so both see identical glyph shapes.
    """
    family = (attrs.get("font-family") or "").lower()
    if "latin modern math" in family:
        return LM_MATH_FONT
    if "latin modern roman" in family:
        return LM_BOLD_FONT if (attrs.get("font-weight") or "").lower() == "bold" else LM_ROMAN_FONT
    return LM_MATH_FONT  # DejaVu/unknown families: LM Math fallback


def _face_for(attrs, font_dir, size_px):
    """ImageFont for one <text> element."""
    name = _lm_font_name(attrs)
    for cand in (name, LM_ROMAN_FONT) if name == LM_BOLD_FONT else (name,):
        path = find_lm_font(cand, font_dir)
        if path:
            return _font(path, size_px)
    raise RuntimeError(
        f"Latin Modern font not found: {name} (searched {font_dir} and the Nix store)")


def _svg_attrs(tag):
    """XML attribute map from an element's attribute substring."""
    return dict(re.findall(r'([a-z][a-z-]*)="([^"]*)"', tag))


def _pt(v):
    """'123.45pt' / '123.45' -> float in pt."""
    return float(str(v).replace("pt", "").strip())


def _parse_rgba(hexcolor):
    """'#RRGGBB' / '#RRGGBBAA' -> (r, g, b, a) with a in 0..255."""
    s = hexcolor.lstrip("#")
    if len(s) == 8:
        r, g, b, a = (int(s[i:i + 2], 16) for i in (0, 2, 4, 6))
        return (r, g, b, a)
    if len(s) == 6:
        return (*(int(s[i:i + 2], 16) for i in (0, 2, 4)), 255)
    return (0, 0, 0, 255)


def _parse_color(hexcolor):
    """Fill as an opaque RGB tuple, alpha already composited over white.

    Used for the primitives PIL draws into an RGB canvas in one step (<text>,
    <rect>, <line>), where the canvas backdrop is the document's own
    background rect. A <path> is composited with its real alpha instead
    (see _fill_path), so a translucent run stays translucent over whatever
    was painted before it."""
    r, g, b, a = _parse_rgba(hexcolor)
    return (round(c * a / 255 + 255 * (255 - a) / 255) for c in (r, g, b))


def _is_private_use(ch):
    """True for the layout's synthetic surd placeholders (U+F000..U+F8FF)."""
    return len(ch) == 1 and 0xF000 <= ord(ch) <= 0xF8FF


def _glyph_label(ch):
    """Report label for one logical glyph: the character itself, or its code
    point when the run names a private-use placeholder nothing can render."""
    return f"U+{ord(ch):04X}" if _is_private_use(ch) else ch


def _unescape(s):
    return (s.replace("&amp;", "&").replace("&lt;", "<")
             .replace("&gt;", ">").replace("&quot;", '"'))


def _parse_svg_primitives(svg):
    """(w_pt, h_pt, elements): the one SVG parse shared by the PIL rasterizer
    and the geometric verifier, so both see identical geometry. elements is a
    list of (kind, attrs, content) in document order, kind ∈
    text/path/rect/line.

    A <path> carries no x/y: its geometry IS the absolute unitless `d` it
    paints. The logical run it stands for is named by `data-text` (returned
    as content, XML-unescaped) and anchored at the run's original baseline
    `data-x`/`data-y`, which the parser normalizes into the same x/y keys a
    <text> carries so rows, operators and limits see one coordinate system.
    A radical can split into several paths; its pieces share data-x and
    font-size and are grouped by _path_runs. Other glyphs use one path.
    Unlabelled paths are painted decoration bands, not logical glyphs.
    """
    m = re.search(r"<svg\b[^>]*>", svg)
    if not m:
        raise ValueError(f"not an SVG: {svg}")
    root = _svg_attrs(m.group(0))
    w_pt = _pt(root["width"]) if root.get("width") else 0.0
    h_pt = _pt(root["height"]) if root.get("height") else 0.0
    if not w_pt or not h_pt:
        vb = root.get("viewBox", "").split()
        if len(vb) == 4:
            w_pt, h_pt = float(vb[2]), float(vb[3])
    elements = []
    for el in re.finditer(
            r"<(text|path|rect|line)\b([^>]*?)(/?)>(.*?)</\1>|<(text|path|rect|line)\b([^>]*?)/>",
            svg, re.S):
        if el.group(1):
            kind, attrs_raw, content = el.group(1), el.group(2), el.group(4)
        else:
            kind, attrs_raw, content = el.group(5), el.group(6), ""
        attrs = _svg_attrs(attrs_raw)
        if kind in ("text", "path"):
            content = _unescape(content) if kind == "text" else attrs.get("data-text", "")
        if kind == "path":
            # The painted outline needs no anchor; the logical run does.
            attrs["x"] = attrs.get("data-x", "0")
            attrs["y"] = attrs.get("data-y", "0")
        elements.append((kind, attrs, content))
    return w_pt, h_pt, elements



class _FlattenPen(BasePen):
    """Segment pen that turns a path's curves into chords within a tolerance.

    A quadratic's chord error after n segments is the control point's distance
    from the chord midpoint over 2n², so n follows directly from the tolerance
    and the drawn edge stays within PATH_FLATTEN_TOL_PT of the curve. The
    flattened points stay in the path's own coordinates; the filler scales
    them once, so a path is walked at the resolution it is painted at."""

    def __init__(self, tol):
        super().__init__(None)
        self.tol = tol
        self.contours = []
        self._cur = []

    def _flush(self):
        if len(self._cur) > 2:
            self.contours.append(self._cur)
        self._cur = []

    def moveTo(self, pt):
        self._flush()
        self._cur = [pt]

    def lineTo(self, pt):
        self._cur.append(pt)

    def closePath(self):
        self._flush()

    def endPath(self):
        self._flush()

    def _qCurveToOne(self, p1, p2):
        p0 = self._cur[-1]
        dev = math.hypot(p1[0] - (p0[0] + p2[0]) / 2.0, p1[1] - (p0[1] + p2[1]) / 2.0)
        n = max(1, min(256, int(math.ceil(math.sqrt(dev / (2.0 * self.tol))))))
        for i in range(1, n + 1):
            t = i / n
            u = 1.0 - t
            self._cur.append((u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
                              u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1]))

    def _curveToOne(self, p1, p2, p3):
        p0 = self._cur[-1]
        dev = (math.hypot(p1[0] - p0[0], p1[1] - p0[1])
               + math.hypot(p2[0] - p1[0], p2[1] - p1[1])
               + math.hypot(p3[0] - p2[0], p3[1] - p2[1]))
        n = max(1, min(256, int(math.ceil(math.sqrt(dev * 3.0 / (4.0 * self.tol))))))
        for i in range(1, n + 1):
            t = i / n
            u = 1.0 - t
            self._cur.append((
                u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
                u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1]))

    def arcTo(self, *_args):
        raise ValueError("path uses an elliptical arc; ztex emits M/L/Q/Z outlines only")


def _path_contours(d, tol=PATH_FLATTEN_TOL_PT):
    """Flatten a path's `d` into closed polylines in the path's own units."""
    pen = _FlattenPen(tol)
    parse_path(d, pen)
    pen.endPath()   # a path that does not end in Z leaves its last contour open
    return pen.contours


def _path_bounds(d):
    """Exact ink box (x0, y0, x1, y1) of a path's `d`, or None when it is empty.

    BoundsPen walks the real Bézier extrema, so a stem whose control points
    overshoot contributes its painted extent, not its control box. The path
    is already in document pt, so the box needs no origin or size."""
    pen = BoundsPen(None)
    parse_path(d, pen)
    return pen.bounds


def _fill_path(img, d, rgba, scale):
    """Fill one <path> onto the RGB canvas in nonzero winding, in painter order.

    Nonzero winding is what keeps a glyph's counters (the hole in an 'o', the
    enclosed space of a curly brace) open: a contour wound against the one
    around it cancels, and PIL's polygon filler would not. Coverage is exact
    per span — a span's overlap with each pixel column is measured, not
    rounded — and the run's alpha scales the mask, so a translucent outline
    composites over what was already painted exactly as the document's
    painter order declares.
    """
    w, h = img.size
    edges = []
    for contour in _path_contours(d):
        n = len(contour)
        for i in range(n):
            (x0, y0), (x1, y1) = contour[i], contour[(i + 1) % n]
            x0, y0, x1, y1 = x0 * scale, y0 * scale, x1 * scale, y1 * scale
            if y0 == y1:
                continue      # horizontal edge: no crossing to count
            if y0 < y1:
                edges.append((y0, y1, x0, (x1 - x0) / (y1 - y0), 1))
            else:
                edges.append((y1, y0, x1, (x0 - x1) / (y0 - y1), -1))
    if not edges:
        return
    r0 = max(0, int(math.floor(min(e[0] for e in edges))))
    r1 = min(h - 1, int(math.ceil(max(e[1] for e in edges))))
    if r1 < r0:
        return
    c0 = max(0, int(math.floor(min(min(e[2], e[2] + (e[1] - e[0]) * e[3]) for e in edges))))
    c1 = min(w - 1, int(math.ceil(max(max(e[2], e[2] + (e[1] - e[0]) * e[3]) for e in edges))))
    if c1 < c0:
        return
    # Bucket the edges by the pixel rows they cross, so a row only tests the
    # handful of edges that can reach it instead of every edge in the glyph.
    buckets = [[] for _ in range(r1 - r0 + 1)]
    for e in edges:
        for row in range(max(r0, int(math.floor(e[0]))),
                         min(r1, int(math.ceil(e[1]))) + 1):
            buckets[row - r0].append(e)
    inv = 1.0 / PATH_SUB_SCANLINES
    mw = c1 - c0 + 1
    alpha = rgba[3]
    data = bytearray(mw * (r1 - r0 + 1))
    for row, bucket in enumerate(buckets):
        if not bucket:
            continue
        y = r0 + row
        row_cov = [0.0] * mw
        for k in range(PATH_SUB_SCANLINES):
            sy = y + (k + 0.5) * inv
            xs = sorted((ex + (sy - ey0) * slope, wind)
                        for ey0, ey1, ex, slope, wind in bucket if ey0 <= sy < ey1)
            winding = 0
            for i in range(len(xs) - 1):
                winding += xs[i][1]
                if winding == 0:
                    continue
                xa = max(xs[i][0], float(c0))
                xb = min(xs[i + 1][0], float(c1 + 1))
                if xb <= xa:
                    continue
                # Split the span across the columns it crosses and add each
                # column's exact covered length — the difference array a
                # rasterizer normally uses cannot express a span that ends on
                # a column boundary, which is most of them.
                pa, pb = int(xa), min(int(xb), c1)
                if pa == pb:
                    row_cov[pa - c0] += (xb - xa) * inv
                    continue
                row_cov[pa - c0] += (pa + 1 - xa) * inv
                for px in range(pa + 1, pb):
                    row_cov[px - c0] += inv
                if xb > pb:
                    row_cov[pb - c0] += (xb - pb) * inv
        base = row * mw
        for i in range(mw):
            data[base + i] = min(255, max(0, int(row_cov[i] * alpha + 0.5)))
    mask = Image.frombytes("L", (mw, r1 - r0 + 1), bytes(data))
    img.paste(rgba[:3], (c0, r0), mask)


def rasterize_svg(svg_path, png_path, font_dir=DEFAULT_FONT_DIR, scale=1.0):
    r"""PIL raster of a ztex SVG at 96 dpi × scale (1pt = 4/3 px), from the
    document itself.

    A <path> is the geometry ztex boxed: an absolute unitless `d` in the same
    coordinate space as every other primitive. It is filled exactly as
    declared — nonzero winding, the run's own fill alpha, document painter
    order — so a tall radical, a display big operator and a stretched fence
    are painted as the outline the SVG carries, holes and all. Nothing about
    them is re-derived from a font table or from the space around them, so an
    error in an emitted outline shows up in the PNG instead of being
    reconstructed away.

    A <text> run carries its BASELINE at y, in pt, and names the Latin Modern
    face, so it is drawn with the actual OTF at the declared font-size (anchor
    "ls" = left-baseline, so the baseline lands on y). Fraction bars and
    stroked decorations (<rect>/<line>) are drawn in painter order too.
    PIL draws those runs because resvg/rsvg/ImageMagick break ztex <text> on
    this host: they fall back to the wrong font and overflow the frame.
    Deterministic: same SVG + fonts -> same PNG.

    The raster is SUPERSAMPLED at 2x (8/3 px/pt) and LANCZOS-downscaled to
    the final 4/3 px/pt: PIL's direct glyph rasterization at 48pt+ looks
    measurably bolder than the mutool reference raster (per-glyph ink
    coverage ~+4% on x/n at the same pixel scale — measured on the
    `\sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx` corpus at 48pt), so the
    critique was flagging raster antialiasing as a glyph "bolder" nit. The
    2x pass antialiases the glyph edges to match the reference's look
    (same final geometry: positions and ink extents are unchanged).

    scale > 1 raises the FINAL pixel density (e.g. scale=2 -> 8/3 px/pt) for
    --ref mode, so the combined image can scale all panes to a common width
    without ever upscaling a pane below 8/3 px/pt. Returns (width_px, height_px).
    """
    svg = Path(svg_path).read_text(errors="replace")
    w_pt, h_pt, elements = _parse_svg_primitives(svg)
    if not w_pt or not h_pt:
        raise ValueError(f"no width/height in {svg_path}")
    w_px = max(1, int(round(w_pt * PT_TO_PX * scale)))
    h_px = max(1, int(round(h_pt * PT_TO_PX * scale)))
    # Supersample every coordinate by RASTER_SUPERSAMPLE × scale, then
    # LANCZOS-down-scale to the final size: smoother glyph edges at 4/3 px/pt
    # (the PIL direct draw at 48pt+ renders glyphs bolder than the mutool
    # reference). At scale=2 the draw is 4x and the downscale 2x — the same
    # 2x-supersampled quality, just at double the final resolution.
    ss = RASTER_SUPERSAMPLE * scale
    # Draw canvas is SUPERSAMPLE × the FINAL size (exactly the pre-scale
    # behavior at scale=1; at scale>1 it is scale× the old canvas — NOT
    # w_px×ss, which would be scale× too big and downscale the content to
    # 96dpi positions on a larger canvas). The SVG's pt margins absorb
    # the ±1px rounding.
    dw = w_px * RASTER_SUPERSAMPLE
    dh = h_px * RASTER_SUPERSAMPLE
    img = Image.new("RGB", (dw, dh), "white")
    draw = ImageDraw.Draw(img)
    # One pt -> one supersampled pixel: the single factor every primitive is
    # placed with, so a path's `d` and a glyph's baseline share one space.
    k = PT_TO_PX * ss
    for kind, a, content in elements:
        if kind == "text":
            draw.text((_pt(a.get("x", "0")) * k, _pt(a.get("y", "0")) * k), content,
                      font=_face_for(a, font_dir, _pt(a.get("font-size", "0")) * k),
                      fill=tuple(_parse_color(a.get("fill", "#000000"))), anchor="ls")
        elif kind == "path":
            _fill_path(img, a["d"], _parse_rgba(a.get("fill", "#000000")), k)
        elif kind == "rect":
            x = _pt(a.get("x", "0")) * k
            y = _pt(a.get("y", "0")) * k
            w = _pt(a["width"]) * k
            h = _pt(a["height"]) * k
            draw.rectangle((x, y, x + w, y + h), fill=tuple(_parse_color(a.get("fill", "#000000"))))
        else:  # line — stroked decoration
            width = max(1, int(round(_pt(a.get("stroke-width", "1")) * k)))
            draw.line([_pt(a[n]) * k for n in ("x1", "y1", "x2", "y2")],
                      fill=tuple(_parse_color(a.get("stroke", "#000000"))), width=width)
    if dw != w_px or dh != h_px:
        img = img.resize((w_px, h_px), Image.LANCZOS)
    img.save(png_path)
    return w_px, h_px


def convert_png(svg_path, png_path, font_dir=DEFAULT_FONT_DIR, scale=1.0):
    """SVG (pt geometry) -> PNG at 96 dpi × scale (1pt = 4/3 px) via PIL + LM OTFs.

    Returns a short description used in the report's "Convert cmd" line.
    """
    w_px, h_px = rasterize_svg(svg_path, png_path, font_dir, scale=scale)
    dpi = int(round(96 * scale))
    return [f"PIL rasterize_svg ({dpi}dpi, {w_px}x{h_px}px, "
            f"{RASTER_SUPERSAMPLE}x supersample + LANCZOS)"]


# ── XeTeX + KaTeX + MathJax reference renderers + 4-pane combiner (--ref mode)
# All four panes render at the SAME nominal pt size (--size) and the SAME
# pixel density. The base density is 96 dpi (4/3 px/pt); --ref mode renders
# every pane at REF_SCALE × that (2x = 192 dpi = 8/3 px/pt) so the combined
# image scales panes to a common width with LANCZOS downscale only — no pane
# is ever upscaled below 8/3 px/pt (previously the narrower panes were
# upscaled from 96 dpi in the combined image).
REF_SCALE = 2


def render_ref(formula, workdir, size_pt=10.0, dpi=96):
    """XeTeX reference render of the formula -> ref.png.

    Standalone preview doc, amsmath + unicode-math, display style, at the
    SAME font size as the ztex render (default 10) so both rasters have the
    same pixel density. xelatex embeds the fonts, so `mutool draw -F png`
    (mupdf, -r dpi; 96 = 4/3 px/pt like the PIL raster) gives a faithful
    reference raster. Returns (png_path, xelatex_cmd, mutool_cmd).
    """
    workdir = os.path.abspath(workdir)
    tex = os.path.join(workdir, "ref.tex")
    with open(tex, "w") as f:
        f.write("\\documentclass[preview,border=6pt]{standalone}\n"
                "\\usepackage{amsmath}\n\\usepackage{unicode-math}\n"
                "\\begin{document}\n"
                "\\fontsize{%f}{%f}\\selectfont\n"
                "$\\displaystyle %s$\n\\end{document}\n"
                % (size_pt, size_pt * 1.2, formula))
    cmd = ["xelatex", "-interaction=nonstopmode", "-halt-on-error",
           "-output-directory=" + workdir, tex]
    subprocess.run(cmd, check=True, capture_output=True, cwd=workdir)
    pdf = os.path.join(workdir, "ref.pdf")
    png = os.path.join(workdir, "ref.png")
    convert = ["nix-shell", "-p", "mupdf", "--run",
               "mutool draw -F png -r %d -o %s %s" % (dpi, png, pdf)]
    subprocess.run(convert, check=True, capture_output=True, cwd=workdir)
    return png, cmd, convert


def render_katex_ref(formula, workdir, size_pt=48.0, scale=1.0):
    """KaTeX reference render of the formula -> katex.png.

    Delegates to scripts/katex_ref.py (KaTeX CLI -> per-glyph geometry ->
    PIL raster with the KaTeX fonts). KaTeX's base font-size is 1.21em of
    the wrapper; katex_ref.py sets the base = size_pt so glyphs are the same
    nominal pt size as the ztex/XeTeX panes; scale raises the final pixel
    density (2 = 8/3 px/pt). Returns (png, cmd, convert).
    """
    import importlib.util
    kref_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "katex_ref.py")
    spec = importlib.util.spec_from_file_location("katex_ref", kref_path)
    kref = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(kref)
    return kref.render_katex_ref(formula, workdir, size_pt=size_pt, scale=scale)


def render_mathjax_ref(formula, workdir, size_pt=20.0, scale=1.0):
    """MathJax reference render of the formula -> mathjax.png.

    scripts/mathjax_render.mjs (mathjax-full tex2svg) emits an SVG with the
    glyph shapes as embedded <path> outlines (no font dependency) whose
    width/height are already in px at size_pt × 4/3 px/pt × scale (1em ==
    size_pt, MathJax TeX x-height 0.442em — see notes/mathjax-reference.md);
    resvg rasterizes it at its intrinsic pixel size. Returns (png, cmd, convert).
    """
    workdir = os.path.abspath(workdir)
    svg = os.path.join(workdir, "mathjax.svg")
    png = os.path.join(workdir, "mathjax.png")
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mathjax_render.mjs")
    cmd = ["node", script, formula, "--display", "--size", str(size_pt),
           "--scale", str(scale), "-o", svg]
    subprocess.run(cmd, check=True, capture_output=True)
    convert = ["resvg", "--background", "white", svg, png]
    subprocess.run(convert, check=True, capture_output=True)
    return png, cmd, convert


def combine_panes(panes, combined_path):
    """N PNGs stacked vertically at their NATIVE scale (no width-matching).

    panes: list of (png_path, label). All panes are rendered at the same
    px/pt (8/3 = 192 dpi), so their native sizes ARE their true scales —
    rescaling to a common width would upscale narrower panes and distort
    the comparison. Panes are only DOWNScaled if they exceed max_w (to fit);
    never upscaled. 2px dividers + labels between panes.
    Returns (w_px, h_px).
    """
    imgs = [(Image.open(p).convert("RGB"), label) for p, label in panes]
    max_w = max(im.width for im, _ in imgs)
    target_w = max_w
    scaled = []
    for im, label in imgs:
        if im.width > max_w:
            im = im.resize((max_w, max(1, round(im.height * max_w / im.width))),
                           Image.LANCZOS)
        scaled.append((im, label))
    divider_h = 4
    font = ImageFont.load_default()
    label_h = max(14, int(font.size * 1.5))
    total_h = sum(label_h + im.height for im, _ in scaled) + divider_h * (len(scaled) - 1)
    canvas = Image.new("RGB", (target_w, total_h), "white")
    draw = ImageDraw.Draw(canvas)
    y = 0

    def center_label(text, y0, y1):
        w = draw.textlength(text, font=font)
        draw.text(((canvas.width - w) / 2.0, y0 + (y1 - y0 - font.size) / 2.0),
                  text, fill="black", font=font)

    for i, (im, label) in enumerate(scaled):
        center_label(label, y, y + label_h)
        canvas.paste(im, (0, y + label_h))
        y += label_h + im.height
        if i < len(scaled) - 1:
            dy = y + divider_h // 2 - 1
            draw.line([(0, dy), (canvas.width - 1, dy)], fill="black", width=2)
            y += divider_h
    canvas.save(combined_path)
    return canvas.width, canvas.height


# ── Geometric verifier (deterministic ground truth) ─────────────────────────
# The vision model PROPOSES defects; this layer VERIFIES each claim against
# exact geometry derived from the ztex SVG and the actual Latin Modern OTF
# outlines (fontTools BoundsPen), in SVG pt coordinates — the same geometry
# the PIL raster draws (1pt of layout = 4/3 px of ink). The geometric verdict
# is authoritative: vision claims pass only when geometry agrees.

_tt_cache = {}
_tt_cmap_cache = {}


def _tt_font(path):
    """Cached fontTools TTFont for a font path."""
    f = _tt_cache.get(path)
    if f is None:
        f = TTFont(path)
        _tt_cache[path] = f
    return f


def _tt_cmap(path):
    """Cached unicode->glyph-name map for a font path."""
    c = _tt_cmap_cache.get(path)
    if c is None:
        c = _tt_font(path).getBestCmap()
        _tt_cmap_cache[path] = c
    return c


def _bigop_variant_glyph(tt, cp):
    """MATH-table display-variant glyph name for a big-op codepoint, or None.

    The variant XeTeX draws for a DISPLAY operator (OpenType MATH
    MathVariants.VertGlyphConstruction). LM Math lists the base glyph then
    the .v1; the LAST record is the largest (vertical extent >=
    DisplayOperatorMinHeight 1.3em) and is the display variant. Falls back to
    the conventional '<base>.v1', '<base>.v2', ... naming when the font has
    no MATH table. Returns None when the font has no display variant (the
    caller then draws the cmap base glyph).
    """
    cmap = tt.getBestCmap()
    base = cmap.get(cp)
    if base is None:
        return None
    candidates = []
    math = tt.get("MATH")
    if math is not None:
        mv = math.table.MathVariants
        try:
            names = list(mv.VertGlyphCoverage.glyphs)
        except AttributeError:
            names = [c.glyphName for c in mv.VertGlyphCoverage]
        for name, gc in zip(names, mv.VertGlyphConstruction):
            if name == base and gc.MathGlyphVariantRecord:
                candidates = [r.VariantGlyph for r in gc.MathGlyphVariantRecord]
                break
    if not candidates:
        order = set(tt.getGlyphOrder())
        i = 1
        while f"{base}.v{i}" in order:
            candidates.append(f"{base}.v{i}")
            i += 1
    for gname in reversed(candidates):  # largest variant last; skip the base
        if gname != base:
            return gname
    return None



def _text_ink_boxes(attrs, content, font_dir):
    """Per-char ink boxes (SVG pt: [x0, y0, x1, y1], y down) for a <text>.

    Uses the real OTF outlines via BoundsPen at the declared font-size and
    baseline (anchor "ls": pen origin at x,y, font y up), advancing by hmtx
    widths exactly as the PIL raster does. A char with no ink (missing glyph /
    empty outline) yields None.

    A <text> run now always means the cmap base glyph at the declared size:
    every stretched form — a tall radical, a display big operator, a
    stretched fence — is a <path>, and its ink is measured from that outline
    (see _path_bounds). There is no MATH variant left to resolve here and
    nothing to infer from the geometry around the run.
    """
    name = _lm_font_name(attrs)
    path = find_lm_font(name, font_dir)
    if not path:
        raise RuntimeError(f"Latin Modern font not found: {name} (searched {font_dir} and the Nix store)")
    font = _tt_font(path)
    cmap = _tt_cmap(path)
    gs = font.getGlyphSet()
    size = _pt(attrs.get("font-size", "0"))
    scale = size / font["head"].unitsPerEm
    ex, ey = _pt(attrs.get("x", "0")), _pt(attrs.get("y", "0"))
    boxes = []
    cx = ex
    for ch in content:
        gname = cmap.get(ord(ch)) if len(ch) == 1 else None
        pen = None
        if gname is not None:
            pen = BoundsPen(gs)
            try:
                gs[gname].draw(pen)
            except Exception:  # noqa: BLE001 — defensive: treat as no ink
                pen = None
        if pen is None or not pen.bounds:
            boxes.append(None)
            cx += size * 0.5
            continue
        xmin, ymin, xmax, ymax = pen.bounds
        boxes.append((cx + xmin * scale, ey - ymax * scale,
                      cx + xmax * scale, ey - ymin * scale))
        cx += font["hmtx"][gname][0] * scale
    return boxes


def _union(boxes):
    """Union of non-None boxes (pt), or None if there are none."""
    real = [b for b in boxes if b]
    if not real:
        return None
    return (min(b[0] for b in real), min(b[1] for b in real),
            max(b[2] for b in real), max(b[3] for b in real))


def _text_run(attrs, content, font_dir):
    """One <text> run: the cmap glyphs it draws, as ink boxes in document pt."""
    return {
        "kind": "text", "content": content,
        "x": _pt(attrs.get("x", "0")), "y": _pt(attrs.get("y", "0")),
        "size": _pt(attrs.get("font-size", "0")), "font_name": _lm_font_name(attrs),
        "boxes": _text_ink_boxes(attrs, content, font_dir),
    }


def _path_runs(paths):
    """One logical glyph per <path> group, in document order.

    ztex emits a stretched radical as three <path> pieces (top, extenders,
    bottom) that share the surd's data-x and font-size but each carry their own
    data-y, and each piece deliberately overlaps the one above it. Measured as
    three glyphs, that overlap would be reported as a defect and the surd would
    be split across three baseline rows. Only consecutive SURD pieces at the
    same x and size are grouped; ordinary outlines at equal x and size may
    be distinct numerator and denominator glyphs. The first piece supplies
    the logical baseline and content.

    Returns [{"content", "x", "y", "size", "boxes", "surd"}]; `boxes` holds one
    exact ink box per part, so the union still spans the whole assembly.
    """
    runs, group = [], []
    for attrs, content in paths:
        part = {"x": _pt(attrs["x"]), "y": _pt(attrs["y"]),
                "size": _pt(attrs.get("font-size", "0")), "box": _path_bounds(attrs["d"])}
        joined_surd = (group and content == group[0]["content"] and
                       (content == "√" or _is_private_use(content)) and
                       (part["x"], part["size"]) == (group[0]["x"], group[0]["size"]))
        if group and not joined_surd:
            runs.append(group)
            group = []
        group.append(part)
        part["content"] = content
    if group:
        runs.append(group)
    return [{"kind": "path", "content": g[0]["content"], "x": g[0]["x"], "y": g[0]["y"],
             "size": g[0]["size"], "font_name": None,
             "surd": g[0]["content"] == "√" or _is_private_use(g[0]["content"]),
             "boxes": [p["box"] for p in g]}
            for g in runs]


def _svg_geometry_elements(svg_path, font_dir):
    """Parse a ztex SVG into geometry primitives (all coords in SVG pt, y down).

    Returns (w_pt, h_pt, runs, rects, lines, fence_spans):
      runs:  [{"content", "x", "y", "size", "font_name", "kind", "boxes",
               "box", "surd"}] in document order — one entry per logical
              glyph, whether it arrived as a <text> run or as the <path>
              outline ztex drew for it. `boxes` is a per-char (text) or
              per-part (path) ink box list, `box` their union.
      rects: [{"box": [...], "background": bool}]   # background = fills the canvas
      lines: [{"box": [...]}]                       # stroked or filled decoration bands
      fence_spans: [{"open", "close", "lo", "hi"}]  — the horizontal ink span
              each stretched fence pair wraps, from the painted
              outlines, so compute_geometry can tell that intended adjacency
              from a real ink collision.
    """
    svg = Path(svg_path).read_text(errors="replace")
    w_pt, h_pt, elements = _parse_svg_primitives(svg)
    runs, rects, lines, pending = [], [], [], []
    for kind, a, content in elements:
        if kind == "path" and content:
            pending.append((a, content))
            continue
        if pending:   # a run of paths is one logical glyph; close it here
            runs.extend(_path_runs(pending))
            pending = []
        if kind == "path":
            lines.append({"box": _path_bounds(a["d"])})
        elif kind == "text":
            runs.append(_text_run(a, content, font_dir))
        elif kind == "rect":
            x, y = _pt(a.get("x", "0")), _pt(a.get("y", "0"))
            box = (x, y, x + _pt(a.get("width", "0")), y + _pt(a.get("height", "0")))
            rects.append({"box": box, "background": box[2] >= 0.95 * w_pt and box[3] >= 0.95 * h_pt})
        else:
            sw = _pt(a.get("stroke-width", "1")) / 2.0
            x1, y1 = _pt(a.get("x1", "0")), _pt(a.get("y1", "0"))
            x2, y2 = _pt(a.get("x2", "0")), _pt(a.get("y2", "0"))
            lines.append({"box": (min(x1, x2) - sw, min(y1, y2) - sw,
                                  max(x1, x2) + sw, max(y1, y2) + sw)})
    if pending:
        runs.extend(_path_runs(pending))
    # Document order is the painter's order, and it is the order every ink
    # box, clip check and overlap below is measured in.
    for r in runs:
        r["box"] = _union(r["boxes"])
    return w_pt, h_pt, runs, rects, lines, _fence_spans(runs)


def _fence_spans(runs):
    """Spans a stretched \\left..\\right fence pair wraps around its content.

    Pairing uses only what the document painted: the two runs of a pair are
    <path> outlines whose data-text is the delimiter codepoint, and their
    actual ink boxes give the inner edges the enclosed content sits between.
    A fence whose partner is a null delimiter is emitted with no outline at
    all, so an unpaired fence wraps nothing and yields no span.
    """
    fences = [r for r in runs
              if r["kind"] == "path" and r["box"] and len(r["content"]) == 1
              and ord(r["content"]) in DELIMITER_CPS]
    spans, stack, cur_y = [], [], None
    for f in sorted(fences, key=lambda r: (round(r["y"]), r["x"])):
        y = round(f["y"])
        if cur_y is None or y != cur_y:
            stack = []   # fences never pair across baselines (array rows)
            cur_y = y
        cp = ord(f["content"])
        if cp in DELIM_CLOSERS:
            for i in range(len(stack) - 1, -1, -1):
                if stack[i]["cp"] == DELIM_OPENER_OF[cp] and stack[i]["x"] < f["x"]:
                    o = stack.pop(i)
                    spans.append({"open": o, "close": f,
                                  "lo": o["box"][2], "hi": f["box"][0]})
                    break
        elif cp in DELIM_OPENERS:
            stack.append({"cp": cp, "x": f["x"], "box": f["box"]})
    return spans


def _cluster_rows(runs):
    """Group runs into rows by baseline y (tolerance ROW_BASELINE_TOL_PT).

    Returns rows sorted top→bottom, each {"baseline", "items": [...], "box": union|None}.
    """
    rows = []
    for t in sorted(runs, key=lambda t: t["y"]):
        for r in rows:
            if abs(r["baseline"] - t["y"]) <= ROW_BASELINE_TOL_PT:
                r["items"].append(t)
                break
        else:
            rows.append({"baseline": t["y"], "items": [t]})
    for r in rows:
        r["items"].sort(key=lambda t: t["x"])
        r["box"] = _union([t["box"] for t in r["items"] if t["box"]])
    return rows


def _find_operators(rows):
    """Detect big-op glyphs (∑ ∫ ∏ ⋃ ⋂ ⨆ ∐) and TeX limit-op runs (lim/max/...).

    Both forms of a big operator are found the same way, from the logical
    glyph: a <path> run is named by its data-text, so a DISPLAY operator the
    layout drew as an outline is detected exactly like the <text> one a
    text/script operator produces.

    A limit-op run is a maximal run of roman-family letters on one row whose
    lowercase text is a known TeX operator name ("lim", "max", ...). Math
    glyphs are never part of a run, so "sin" in `\\sin x` is a run while the
    operand x is not.
    """
    ops = []
    for row in rows:
        items = row["items"]
        i = 0
        while i < len(items):
            t = items[i]
            if len(t["content"]) == 1 and t["content"] in BIGOP_GLYPHS and t["box"]:
                ops.append({"kind": "bigop", "label": t["content"], "box": t["box"],
                            "row": row, "elements": [t]})
                i += 1
            elif (t["font_name"] != LM_MATH_FONT and len(t["content"]) == 1
                  and t["content"].isalpha()
                  and (t["kind"] == "text" or t["content"].isascii())):
                run = [t]
                j = i + 1
                while j < len(items):
                    u = items[j]
                    if (u["font_name"] != LM_MATH_FONT and len(u["content"]) == 1
                            and u["content"].isalpha()
                            and (u["kind"] == "text" or u["content"].isascii())):
                        run.append(u)
                        j += 1
                    else:
                        break
                text = "".join(u["content"] for u in run)
                if text.lower() in LIMITOP_NAMES:
                    ops.append({"kind": "run", "label": text,
                                "box": _union([u["box"] for u in run]),
                                "row": row, "elements": run})
                i = j
            else:
                i += 1
    return ops


def _bar_between(op_box, row_box, bars, side):
    """True if a fraction-bar rect lies between the op box and the row box.

    A bar must be thin (vertical extent <= BAR_MAX_HEIGHT_PT), horizontally
    overlap the operator's span, and sit in the gap between the two boxes.
    A row separated by a fraction bar is a fraction numerator/denominator,
    NOT a limit row.
    """
    for b in bars:
        if b["background"] or b["box"][3] - b["box"][1] > BAR_MAX_HEIGHT_PT:
            continue
        if not (b["box"][0] <= op_box[2] and b["box"][2] >= op_box[0]):
            continue
        if side == "above":
            if b["box"][3] <= op_box[1] + 0.01 and b["box"][1] >= row_box[3] - 0.01:
                return True
        elif b["box"][1] >= op_box[3] - 0.01 and b["box"][3] <= row_box[1] + 0.01:
            return True
    return False


def _cluster_row_items(row):
    """Split a row's elements into horizontally connected clusters.

    Consecutive elements whose ink boxes are within ~0.35 x the row's max
    font-size of each other belong to one cluster (one term / one limit).
    This keeps "k=1" and "j" apart when a shared limit row serves two
    operators, while a wide limit like "1000000" stays one cluster.
    """
    items = sorted((t for t in row["items"] if t["box"]), key=lambda t: t["box"][0])
    tol = 0.35 * max((t["size"] for t in items), default=1.0)
    clusters = []
    for t in items:
        if clusters:
            gap = max(t["box"][0] - clusters[-1][-1]["box"][2], 0.0)
            if gap <= tol:
                clusters[-1].append(t)
                continue
        clusters.append([t])
    return clusters


def _limit_group_for(op, clusters):
    """Row elements forming op's limit: every cluster whose center falls in
    the op's ink span (merged). If none does, the nearest cluster is taken so
    a floating (off-center) limit is still measured. Returns elements or None.
    """
    obox = op["box"]
    in_span = []
    for cl in clusters:
        cbox = _union([t["box"] for t in cl])
        ccx = (cbox[0] + cbox[2]) / 2.0
        if obox[0] <= ccx <= obox[2]:
            in_span.extend(cl)
    if in_span:
        return in_span
    if not clusters:
        return None
    ocx = (obox[0] + obox[2]) / 2.0
    nearest = min(clusters, key=lambda cl: abs(
        (cl[0]["box"][0] + cl[-1]["box"][2]) / 2.0 - ocx))
    return list(nearest)


def _associate_limits(ops, rows, bars):
    """Attach the nearest qualifying row above/below each operator as its limit.

    A limit row must be vertically beyond the operator's ink box (may touch
    up to LIMIT_TOUCH_TOL_PT), horizontally overlap the operator's span, and
    not be separated by a fraction bar. The row is then split into clusters
    and the clusters centered under the operator become its limit (side-
    placed \\int endpoints and neighboring operators' limits stay separate).
    """
    for op in ops:
        for side in ("above", "below"):
            best, best_gap = None, None
            for row in rows:
                if row is op["row"] or not row["box"]:
                    continue
                rbox = row["box"]
                if side == "above":
                    gap = op["box"][1] - rbox[3]
                    if gap < -LIMIT_TOUCH_TOL_PT:
                        continue
                    gap = max(gap, 0.0)
                else:
                    gap = rbox[1] - op["box"][3]
                    if gap < -LIMIT_TOUCH_TOL_PT:
                        continue
                    gap = max(gap, 0.0)
                if not (rbox[0] <= op["box"][2] and rbox[2] >= op["box"][0]):
                    continue
                if _bar_between(op["box"], rbox, bars, side):
                    continue
                if best is None or gap < best_gap:
                    best, best_gap = row, gap
            if best is None:
                continue
            group = _limit_group_for(op, _cluster_row_items(best))
            if group:
                op.setdefault("limits", {})[side] = {
                    "row": best, "items": group, "box": _union([t["box"] for t in group])}
    return ops


def _math_italic_correction(font, gname):
    """Italic correction (em) of a glyph from the MATH table's
    MathItalicsCorrection record; 0 when absent. The LM Math big-ops:
    ∫/∮ carry 0.332em, every other big-op has no record (0) — mirroring
    the layout's displayOp table, which TeX uses as the limits-stagger
    delta."""
    try:
        info = font["MATH"].table.MathGlyphInfo.MathItalicsCorrectionInfo
        cov = info.Coverage
        if gname in cov.glyphs:
            return info.ItalicsCorrection[cov.glyphs.index(gname)].Value / font["head"].unitsPerEm
    except Exception:  # noqa: BLE001 — defensive: no MATH table / no record
        pass
    return 0.0


def _limit_stagger(op, font_dir):
    """TeX make_op limit placement for one operator: (box center, stagger pt).

    For a BIG-OP glyph the expected over/under-limit center is the op's BOX
    center ± delta/2, where delta = the drawn form's MATH-table italic
    correction at the declared size (TeX make_op: over-limit +delta/2,
    under-limit −delta/2; LM ∫/∮ 0.332em on the base glyph, 0.591em on the
    display .v1, all other big-ops 0). A limit-op WORD (\\lim etc.) uses delta
    0 and its ink center already equals its box center, so the caller falls
    back to the ink-center check. Returns (box_cx, stagger_pt) or None when the
    geometry is unavailable.

    The metrics are the INTENDED ones, and they are read from the form the run
    actually draws: a DISPLAY big operator reaches this verifier as a <path>
    (the layout boxed the MATH .v1 variant), and the box it reserved is that
    variant's advance, not the base glyph's. Comparing the painted outline
    against the base advance instead would invent an offset that is not a
    defect, so the variant is resolved by codepoint and the comparison stays
    honest. \\bigint and friends draw the base glyph at a larger font-size and
    stay <text>, which is why the two forms need different metrics.
    """
    if op.get("kind") != "bigop":
        return None
    t = op["elements"][0]
    if t["content"] not in BIGOP_GLYPHS:
        return None
    cp = ord(t["content"])
    path = find_lm_font(LM_MATH_FONT, font_dir)
    if not path:
        return None
    font = _tt_font(path)
    gname = _tt_cmap(path).get(cp)
    if gname is None:
        return None
    if t["kind"] == "path":
        gname = _bigop_variant_glyph(font, cp) or gname
    upem = font["head"].unitsPerEm
    box_cx = t["x"] + font["hmtx"][gname][0] * t["size"] / upem / 2.0
    return box_cx, _math_italic_correction(font, gname) * t["size"] / 2.0


def _ink_entries(runs):
    """One ink box per reportable glyph, in document order.

    A <text> run contributes one entry per character, so a clipped or empty
    glyph is named. A <path> run contributes exactly one entry: its parts are
    ONE logical glyph and they deliberately overlap each other (a radical
    stacks pieces that overlap by a third of an em), so measuring the parts
    apart would report the glyph's own construction as a collision. The entry
    carries the run's union box — the extent a critic sees — and `surd`, which
    marks the layout's private-use surd placeholders.
    """
    entries = []
    for r in runs:
        rid = ("run", id(r))
        at = f"@{r['x']:.1f},{r['y']:.1f}"
        if r["kind"] == "path":
            entries.append({"id": rid, "label": _glyph_label(r["content"]),
                            "at": at, "box": r["box"], "surd": r["surd"]})
        else:
            for ch, b in zip(r["content"], r["boxes"]):
                entries.append({"id": rid, "label": ch, "at": at, "box": b, "surd": False})
    return entries


def compute_geometry(svg_path, font_dir=DEFAULT_FONT_DIR):
    """Deterministic geometric ground truth for one ztex SVG, in pt.

    Every ink box comes from the document: a <path> from its own outline, a
    <text> run from the real Latin Modern OTF outline at the declared size and
    baseline — the same geometry the PIL raster paints. Returns a JSON-safe
    dict; "defect_count" is the authoritative verdict.
    """
    w_pt, h_pt, runs, rects, lines, fence_spans = _svg_geometry_elements(svg_path, font_dir)
    rows = _cluster_rows(runs)
    bars = [r for r in rects if not r["background"]]
    ops = _associate_limits(_find_operators(rows), rows, bars)
    entries = _ink_entries(runs)

    # ── ink bbox: every glyph box + non-background rect + line ─────────────
    ink_boxes = [e["box"] for e in entries if e["box"]]
    ink_boxes += [r["box"] for r in bars] + [ln["box"] for ln in lines]
    ink_bbox = _union(ink_boxes)

    # ── edge clipping: max ink overflow past [0,w]x[0,h] per edge ──────────
    clip_pt = {"top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0}
    clipped = []
    for e in entries:
        b = e["box"]
        if not b:
            continue
        over = {"top": -b[1], "bottom": b[3] - h_pt, "left": -b[0], "right": b[2] - w_pt}
        bad = {edge: v for edge, v in over.items() if v > CLIP_EPS_PT}
        for edge, v in bad.items():
            if v > clip_pt[edge]:
                clip_pt[edge] = v
        if bad:
            clipped.append({"element": f"{e['label']}{e['at']}", "edges": sorted(bad),
                            "overflow_pt": {edge: round(bad[edge], 3) for edge in sorted(bad)}})
    for box in [r["box"] for r in bars] + [ln["box"] for ln in lines]:
        over = {"top": -box[1], "bottom": box[3] - h_pt, "left": -box[0], "right": box[2] - w_pt}
        for edge, v in over.items():
            if v > CLIP_EPS_PT and v > clip_pt[edge]:
                clip_pt[edge] = v
    clip_pt = {k: round(v, 3) for k, v in clip_pt.items()}

    # ── big-op / limit-op centering ────────────────────────────────────────
    # TeX make_op staggers a big-op's limits horizontally by ±delta/2 around
    # the op's BOX center (delta = the op's italic correction): the
    # over-limit shifts right by delta/2, the under-limit left by delta/2
    # (measured: XeTeX's \textstyle\int\limits_x^y puts the over-limit y
    # 4.97pt right of the ∫ ink center; ztex matches to 0.3pt). A naive
    # ink-center comparison false-flags this intentional stagger AND the
    # display ∫/∮ .v1's right-skewed ink (its ink center sits ~5pt right of
    # the box center, so its under-limit '2' measures ~10pt off the ink
    # center while sitting exactly at −delta/2 of the box center). Compare
    # each limit against the box the layout reserved — the drawn form's
    # advance / 2 from the run's x — plus the expected stagger (see
    # _limit_stagger for which form's metrics apply); a limit-op word (\lim
    # etc.) has delta 0 and keeps the old ink-center check.
    bigop_limits, operators = [], []
    for op in ops:
        limits = op.get("limits", {})
        operators.append({"label": op["label"], "has_limits": bool(limits)})
        box_cx, stagger = _limit_stagger(op, font_dir) or (None, 0.0)
        for side in ("above", "below"):
            lim = limits.get(side)
            if not lim:
                continue
            cx_lim = (lim["box"][0] + lim["box"][2]) / 2.0
            if box_cx is None:
                cx_op = (op["box"][0] + op["box"][2]) / 2.0
                offset = abs(cx_op - cx_lim)
            else:
                # expected limit center: box center ± delta/2 (TeX make_op)
                cx_op = box_cx + (stagger if side == "above" else -stagger)
                offset = abs(cx_op - cx_lim)
            empty_in_limit = sum(1 for t in lim["items"] for b in t["boxes"] if b is None)
            bigop_limits.append({
                "operator": op["label"], "limit": "".join(t["content"] for t in lim["items"]),
                "side": side, "cx_op": round(cx_op, 3), "cx_limit": round(cx_lim, 3),
                "offset_pt": round(offset, 3),
                "limit_empty_glyphs": empty_in_limit,
            })

    # ── pairwise ink-box overlaps ──────────────────────────────────────────
    boxes = list(entries)
    for ri, r in enumerate(bars):
        boxes.append({"id": ("rect", ri), "label": "fraction bar", "box": r["box"], "surd": False})
    for li, ln in enumerate(lines):
        boxes.append({"id": ("line", li), "label": "line", "box": ln["box"], "surd": False})
    # intended overlaps: a limit touching its operator, a radical over its
    # radicand, a fence wrapping its content, and a big op's own attached
    # BESIDE scripts. TeX attaches a nolimits op's scripts at variant_advance
    # −/+ its italic correction, which for the ∫/∮ .v1 lands INSIDE the variant
    # ink bbox (sub at 0.408em, ink ends at 0.943em) — the XeTeX reference
    # render has exactly this ∫↔sub bbox intersection (measured on the ref
    # raster), so op↔own-script bbox intersections are intended adjacency, not
    # defects. A script is the op's own when it is script-sized (< op size, so
    # beside scripts and never the full-size following term), horizontally
    # overlapping the op's ink span, and vertically adjacent to the op's box.
    excluded_ids = set()
    excluded_reason = {}
    for op in ops:
        op_ids = {("run", id(t)) for t in op["elements"]}
        if op["kind"] == "bigop":
            op_size = max((t["size"] for t in op["elements"]), default=0.0)
            for row in rows:
                if row is op["row"]:
                    continue
                for t in row["items"]:
                    if not t["box"] or t["size"] >= op_size:
                        continue
                    if not (t["box"][0] <= op["box"][2] + 1e-9 and t["box"][2] >= op["box"][0] - 1e-9):
                        continue
                    if not (t["box"][1] <= op["box"][3] + LIMIT_TOUCH_TOL_PT
                            and t["box"][3] >= op["box"][1] - LIMIT_TOUCH_TOL_PT):
                        continue
                    for a in op_ids:
                        pair = frozenset((a, ("run", id(t))))
                        excluded_ids.add(pair)
                        excluded_reason[pair] = "op's attached beside script"
        for side in ("above", "below"):
            lim = op.get("limits", {}).get(side)
            if not lim:
                continue
            lim_ids = {("run", id(t)) for t in lim["items"]}
            for a in op_ids:
                for b in lim_ids:
                    pair = frozenset((a, b))
                    excluded_ids.add(pair)
                    excluded_reason[pair] = "limit touching its operator"
    # A STRETCHED fence legitimately WRAPS its enclosed content: the drawn
    # outline surrounds the content and may graze it (the LM variant glyphs'
    # ink is wider than the content span — measured sub-0.5pt slivers on
    # `\lfloor \frac{1}{2} \rfloor`, present in the XeTeX reference render
    # too), so fence↔enclosed-content intersections are intended adjacency,
    # like a radical over its radicand. The spans come from the painted fence
    # outlines (see _fence_spans): no intent is read from a marker attribute.
    for sp in fence_spans:
        lo, hi = sp["lo"], sp["hi"]
        enclosed = set()
        for e in entries:
            if e["id"] in (("run", id(sp["open"])), ("run", id(sp["close"]))):
                continue
            if e["box"] and lo < (e["box"][0] + e["box"][2]) / 2.0 < hi:
                enclosed.add(e["id"])
        for ri, r in enumerate(bars):
            if lo < (r["box"][0] + r["box"][2]) / 2.0 < hi:
                enclosed.add(("rect", ri))
        for li, ln in enumerate(lines):
            if lo < (ln["box"][0] + ln["box"][2]) / 2.0 < hi:
                enclosed.add(("line", li))
        for did in (("run", id(sp["open"])), ("run", id(sp["close"]))):
            for eid in enclosed:
                pair = frozenset((did, eid))
                excluded_ids.add(pair)
                excluded_reason[pair] = "fence wrapping its content"
    overlaps = []
    for i in range(len(boxes)):
        for j in range(i + 1, len(boxes)):
            A, B = boxes[i], boxes[j]
            if not A["box"] or not B["box"]:
                continue
            ax0, ay0, ax1, ay1 = A["box"]
            bx0, by0, bx1, by1 = B["box"]
            dx = min(ax1, bx1) - max(ax0, bx0)
            dy = min(ay1, by1) - max(ay0, by0)
            if dx <= 1e-9 or dy <= 1e-9:
                continue
            area = dx * dy
            if area < OVERLAP_REPORT_PT2:
                continue
            reason = None
            pair = frozenset((A["id"], B["id"]))
            if pair in excluded_ids:
                reason = excluded_reason[pair]
            else:
                # A surd covers the radicand that follows it: the radical bar
                # reaches over it, so the ink boxes meet by design.
                acx = (A["box"][0] + A["box"][2]) / 2.0
                bcx = (B["box"][0] + B["box"][2]) / 2.0
                if (A["surd"] and bcx > acx) or (B["surd"] and acx > bcx):
                    reason = "radical over its radicand"
            smaller = min((ax1 - ax0) * (ay1 - ay0), (bx1 - bx0) * (by1 - by0))
            overlaps.append({
                "a": A["label"], "b": B["label"], "area_pt2": round(area, 3),
                "pct_of_smaller": round(100.0 * area / smaller, 2) if smaller > 0 else 0.0,
                "excluded": reason is not None, "reason": reason,
            })
    overlaps.sort(key=lambda o: -o["area_pt2"])

    # ── glyph completeness: glyphs that paint nothing ──────────────────────
    empty_glyphs = [{"element": f"{e['label']}{e['at']}", "char": e["label"]}
                    for e in entries if e["box"] is None]

    # ── geometric defects (authoritative) ──────────────────────────────────
    offcenter = [o for o in bigop_limits
                 if o["offset_pt"] > LIMIT_OFFSET_FRACTION * w_pt]
    real_overlaps = [o for o in overlaps if not o["excluded"]]
    clipped_edges = [e for e, v in clip_pt.items() if v > CLIP_EPS_PT]
    defect_count = (len(clipped_edges) + len(offcenter)
                    + len(real_overlaps) + len(empty_glyphs))

    def _frac(box):
        if not box:
            return None
        return [round(box[0] / w_pt, 4), round(box[1] / h_pt, 4),
                round(box[2] / w_pt, 4), round(box[3] / h_pt, 4)]

    return {
        "svg_w_pt": round(w_pt, 3), "svg_h_pt": round(h_pt, 3),
        "ink_bbox_pt": [round(v, 3) for v in ink_bbox] if ink_bbox else None,
        "ink_bbox_frac": _frac(ink_bbox),
        "clipping_pt": clip_pt, "clipped": clipped,
        "bigop_limits": bigop_limits, "operators": operators,
        "overlaps": overlaps, "empty_glyphs": empty_glyphs,
        "glyph_count": len(entries),
        "defects": {
            "clipped_edges": clipped_edges,
            "offcenter_limits": offcenter,
            "overlaps": [f"{o['a']}/{o['b']}" for o in real_overlaps],
            "empty_glyphs": [g["char"] for g in empty_glyphs],
        },
        "defect_count": defect_count,
    }


def _normalize_op(label):
    """'\\sum', 'sum', '∑' -> '∑'; '\\lim'/'lim' -> 'lim' (canonical op label)."""
    s = (label or "").replace("\\", "").strip().lower()
    if s in OP_ALIASES:
        return OP_ALIASES[s]
    if s in BIGOP_GLYPHS:
        return s
    return s


def _find_gt_op(geom, label):
    """First detected operator in the geometry matching a canonical label."""
    for op in geom.get("operators", []):
        if op["label"] == label:
            return op
    return None


def _claim(category, claim, gt, confirmed, disposition):
    return {"category": category, "claim": claim, "gt": gt,
            "confirmed": bool(confirmed), "disposition": disposition}


def resolve_vision_claims(verdict, geom):
    """Confirm/refute every vision defect claim against geometric ground truth.

    A claim is CONFIRMED only when the deterministic geometry agrees (e.g.
    vision right_pct > 0 AND gt right overflow > 0; vision limit offset >
    threshold AND gt offset > threshold). Claims geometry contradicts are
    marked "refuted (vision artifact)" and never fail the verdict.
    """
    resolutions = []
    if not isinstance(verdict, dict) or verdict.get("status") in ("vision-error", "unparseable", "not-run"):
        return resolutions

    # 1. Edge clipping
    clip = verdict.get("clipping") or {}
    for edge, key in (("top", "top_pct"), ("bottom", "bottom_pct"),
                      ("left", "left_pct"), ("right", "right_pct")):
        claimed = clip.get(key) or 0
        if not claimed:
            continue
        gt_v = geom["clipping_pt"][edge]
        confirmed = gt_v > CLIP_EPS_PT
        resolutions.append(_claim(
            "clipping", f"{edge}_pct={claimed}",
            f"gt {edge} overflow {gt_v}pt",
            confirmed, "confirmed" if confirmed else "refuted (vision artifact)"))

    # 2. Big-op / limit-op centering and visibility
    for bl in verdict.get("bigop_limits") or []:
        op_label = _normalize_op(bl.get("operator", ""))
        gtop = _find_gt_op(geom, op_label)
        off = bl.get("offset_pct") or 0
        if off > 1.0:  # vision FAIL threshold: >1% of image width
            if gtop is None:
                resolutions.append(_claim(
                    "bigop_limits", f"{bl.get('operator')} offset {off}%",
                    "no such operator in the geometry",
                    False, "refuted (no geometric counterpart)"))
            else:
                gt_off = [o for o in geom["bigop_limits"] if o["operator"] == op_label]
                gt_max = max((o["offset_pt"] for o in gt_off), default=0.0)
                confirmed = gt_max > LIMIT_OFFSET_FRACTION * geom["svg_w_pt"]
                resolutions.append(_claim(
                    "bigop_limits", f"{bl.get('operator')} offset {off}%",
                    f"gt max offset {gt_max}pt (threshold {LIMIT_OFFSET_FRACTION * geom['svg_w_pt']:.2f}pt)",
                    confirmed, "confirmed" if confirmed else "refuted (vision artifact)"))
        if bl.get("visible") is False:
            if gtop and gtop["has_limits"]:
                gt_rows = [o for o in geom["bigop_limits"] if o["operator"] == op_label]
                any_empty = any(o.get("limit_empty_glyphs", 0) > 0 for o in gt_rows)
                resolutions.append(_claim(
                    "bigop_limits", f"{bl.get('operator')} limit not visible",
                    "limit glyphs render nothing" if any_empty else "limit row glyphs have ink",
                    any_empty, "confirmed" if any_empty else "refuted (vision artifact)"))
            else:
                resolutions.append(_claim(
                    "bigop_limits", f"{bl.get('operator')} limit not visible",
                    "no over/under limit row in the geometry",
                    False, "refuted (no geometric counterpart)"))

    # 3. Adjacent-term overlap
    if verdict.get("overlaps"):
        real = [o for o in geom["overlaps"] if not o["excluded"]]
        confirmed = len(real) > 0
        resolutions.append(_claim(
            "overlaps", f"{len(verdict['overlaps'])} overlap claim(s)",
            f"gt {len(real)} real ink-box intersection(s)" if real else "gt no ink-box intersections",
            confirmed, "confirmed" if confirmed else "refuted (vision artifact)"))

    # 4. Glyph completeness
    empty_chars = {g["char"] for g in geom["empty_glyphs"]}
    for g in verdict.get("glyphs") or []:
        if g.get("complete") is False:
            name = _normalize_op(g.get("glyph", ""))
            confirmed = name in empty_chars
            resolutions.append(_claim(
                "glyphs", f"{g.get('glyph')} incomplete",
                "glyph has no ink (renders nothing)" if confirmed else "glyph ink box present",
                confirmed, "confirmed" if confirmed else "refuted (vision artifact)"))

    # 5. Scripts (visibility -> empty box; placement -> overlap evidence)
    real_chars = set()
    for o in geom["overlaps"]:
        if not o["excluded"]:
            real_chars.update((o["a"], o["b"]))
    for s in verdict.get("scripts") or []:
        label = s.get("script") or ""
        name = _normalize_op(label)
        if s.get("visible") is False:
            confirmed = name in empty_chars
            resolutions.append(_claim(
                "scripts", f"{label} not visible",
                "script glyph renders nothing" if confirmed else "script glyph has ink",
                confirmed, "confirmed" if confirmed else "refuted (vision artifact)"))
        if s.get("placement_ok") is False:
            confirmed = name in empty_chars or name in real_chars
            resolutions.append(_claim(
                "scripts", f"{label} misplaced",
                ("script glyph empty or overlapping other ink"
                 if confirmed else "no geometric placement defect; script box clean"),
                confirmed, "confirmed" if confirmed else "refuted (no geometric counterpart)"))

    return resolutions


def summarize(verdict, geom):
    """(status, defect_count, one_line, claim_resolutions) for the merged verdict.

    The GEOMETRIC verdict is authoritative: status is FAIL iff the geometry
    found a defect. Vision claims pass only when geometry confirms them, and
    a confirmed claim always corresponds to a geometric defect — so the OR
    with confirmed claims is implicit. Vision transport failures (no key,
    HTTP error) never fail a geometrically clean render.
    """
    vstatus = None
    reason = None
    if not isinstance(verdict, dict):
        vstatus, reason = "error", "no verdict"
    elif verdict.get("status") in ("vision-error", "unparseable", "not-run"):
        vstatus = {"not-run": "SKIPPED", "vision-error": "VISION-ERROR",
                   "unparseable": "UNPARSEABLE"}.get(verdict.get("status"), "ERROR")
        reason = verdict.get("reason") or verdict.get("error") or "no verdict"
    resolutions = resolve_vision_claims(verdict, geom) if vstatus is None else []
    n_confirmed = sum(1 for r in resolutions if r["confirmed"])
    n_defects = geom["defect_count"]
    status = "FAIL" if n_defects else "PASS"

    def _first_defect():
        d = geom["defects"]
        if d["clipped_edges"]:
            return f"ink clipped at {', '.join(d['clipped_edges'])} edge(s)"
        if d["offcenter_limits"]:
            o = d["offcenter_limits"][0]
            return f"{o['operator']} limit off-center by {o['offset_pt']}pt"
        if d["overlaps"]:
            return f"ink overlap: {d['overlaps'][0]}"
        if d["empty_glyphs"]:
            return f"glyph renders nothing: {d['empty_glyphs'][0]}"
        return "geometric defect"

    if status == "FAIL":
        one_line = _first_defect()
        if vstatus:
            one_line += f" (vision {vstatus}: {reason})"
    else:
        one_line = "geometric verifier clean"
        if vstatus:
            one_line += f"; vision {vstatus} ({reason})"
        elif n_confirmed:
            one_line += f"; {n_confirmed} vision claim(s) geometrically confirmed"
        elif verdict.get("verdict") == "FAIL":
            one_line += "; vision FAIL claims refuted (vision artifact)"
        else:
            one_line += "; vision PASS"
    return status, n_defects, one_line, resolutions


def build_prompt(formula, png_path):
    w, h = png_size(png_path)
    return PROMPT_TEMPLATE.format(formula=formula, width=w, height=h)


def _extract_json(text):
    """Best-effort parse of the model's JSON answer (may be markdown-wrapped).

    String-aware brace balancing: nit descriptions legitimately quote literal
    braces ("The closing brace '}' ..."), which a naive depth counter would
    mistake for the JSON's own delimiters.
    """
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    start = text.find("{")
    if start < 0:
        return None
    depth = 0
    in_str = False
    esc = False
    for i in range(start, len(text)):
        c = text[i]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            continue
        if c == '"':
            in_str = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(text[start:i + 1])
                except json.JSONDecodeError:
                    return None
    return None


def call_vision(prompt, png_path, model, api_key, timeout):
    """OpenRouter vision call. Returns (verdict_dict, raw_text)."""
    with open(png_path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode()
    payload = {
        "model": model,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url",
                 "image_url": {"url": f"data:image/png;base64,{b64}"}},
            ],
        }],
        "max_tokens": 2048,
    }
    req = urllib.request.Request(
        OPENROUTER_URL,
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = json.loads(resp.read().decode())
        raw = body["choices"][0]["message"]["content"]
        parsed = _extract_json(raw)
        if parsed is None:
            return {"status": "unparseable", "raw": raw, "error": "model output was not JSON"}, raw
        return parsed, raw
    except urllib.error.HTTPError as e:
        return {"status": "vision-error", "error": f"HTTP {e.code}: {e.read().decode()[:300]}"}, ""
    except Exception as e:  # noqa: BLE001 — surface any transport failure
        return {"status": "vision-error", "error": str(e)}, ""


def _geometry_section(g):
    """Markdown for the deterministic geometric verification."""
    if not g:
        return []
    lines = ["", "## Geometric verification", ""]
    if g.get("ink_bbox_pt"):
        lines.append(f"- **Ink bbox (gt)**: `{g['ink_bbox_pt']}` pt "
                     f"= `{g['ink_bbox_frac']}` of the {g['svg_w_pt']}×{g['svg_h_pt']} pt canvas")
    else:
        lines.append("- **Ink bbox (gt)**: no ink")
    clip = g["clipping_pt"]
    lines.append(f"- **Edge clipping (gt)**: top {clip['top']} pt, bottom {clip['bottom']} pt, "
                 f"left {clip['left']} pt, right {clip['right']} pt")
    for c in g.get("clipped", []):
        lines.append(f"  - clipped: `{c['element']}` ({', '.join(c['edges'])}, "
                     f"{', '.join(f'{e}={v}pt' for e, v in c['overflow_pt'].items())})")
    if g.get("bigop_limits"):
        lines += ["", "### Big-op / limit-op centering (gt)", "",
                  "| operator | limit | side | expected cx (box±δ/2) | limit cx | offset (pt) |",
                  "|---|---|---|---|---|---|"]
        for o in g["bigop_limits"]:
            lines.append(f"| `{o['operator']}` | `{o['limit']}` | {o['side']} | "
                         f"{o['cx_op']} | {o['cx_limit']} | **{o['offset_pt']}** |")
    if g.get("overlaps"):
        lines += ["", "### Ink-box intersections (gt)", "",
                  "| pair | area (pt²) | % of smaller | excluded | reason |",
                  "|---|---|---|---|---|"]
        for o in g["overlaps"]:
            lines.append(f"| `{o['a']}` × `{o['b']}` | {o['area_pt2']} | {o['pct_of_smaller']} "
                         f"| {o['excluded']} | {o['reason'] or ''} |")
    if g.get("empty_glyphs"):
        lines += ["", "### Glyphs that render nothing (gt)", ""]
        lines += [f"- `{e['element']}`" for e in g["empty_glyphs"]]
    lines += ["", f"**Geometric defect count: {g['defect_count']}**", ""]
    return lines


def render_report(report, prompt):
    r = report
    v = r.get("vision") or {}
    lines = [
        f"# Critique {r['number']} — ztex render review",
        "",
        f"- **Formula**: `{r['formula']}`",
        f"- **Size**: {r['size']} pt, background: `{r['background']}`",
        f"- **Rendered**: {r['timestamp']}",
        f"- **SVG**: {r['svg_path']} ({r['svg_w']:.2f} × {r['svg_h']:.2f} pt)",
        f"- **PNG**: {r['png_path']} ({r['png_w']} × {r['png_h']} px)",
        f"- **Render cmd**: `{' '.join(r['render_cmd'])}`",
        f"- **Convert cmd**: `{' '.join(r['convert_cmd'])}`",
        f"- **Vision model**: {r['vision_model']}",
        f"- **Verdict**: **{r['status']}** — {r['one_line']}",
        "",
    ]
    lines += _geometry_section(r.get("geometry") or {})
    lines += [
        "## Vision critique",
        "",
        "### Parsed verdict",
        "",
        "```json",
        json.dumps(v, indent=2),
        "```",
        "",
    ]
    res = r.get("claim_resolutions") or []
    if res:
        lines += ["### Vision claim resolution (geometric confirm/refute)", "",
                  "| category | claim | geometric truth | disposition |",
                  "|---|---|---|---|"]
        for c in res:
            lines.append(f"| {c['category']} | {c['claim']} | {c['gt']} | **{c['disposition']}** |")
        lines.append("")
    lines += [
        "### Raw response",
        "",
        "```text",
        r["raw_verdict"] or "(no raw response)",
        "```",
        "",
        "## Prompt used",
        "",
        "```text",
        prompt,
        "```",
        "",
    ]
    return "\n".join(lines)


def render_ref_report(report, prompt):
    r = report
    v = r.get("nits_verdict") or {}
    lines = [
        f"# Ref critique {r['number']} — ztex vs XeTeX vs KaTeX vs MathJax",
        "",
        f"- **Formula**: `{r['formula']}`",
        f"- **Size**: {r['size']} pt, background: `{r['background']}`",
        f"- **Rendered**: {r['timestamp']}",
        f"- **SVG (ztex)**: {r['svg_path']} ({r['svg_w']:.2f} × {r['svg_h']:.2f} pt)",
        f"- **PNG (ztex)**: {r['png_path']} ({r['png_w']} × {r['png_h']} px)",
        f"- **PNG (XeTeX ref)**: {r['ref_png']} ({r['ref_w']} × {r['ref_h']} px)",
        f"- **PNG (KaTeX ref)**: {r['katex_png']} ({r['katex_w']} × {r['katex_h']} px)",
        f"- **PNG (MathJax ref)**: {r['mathjax_png']} ({r['mathjax_w']} × {r['mathjax_h']} px)",
        f"- **Combined**: {r['combined_path']} ({r['combined_w']} × {r['combined_h']} px)",
        f"- **Render cmd (ztex)**: `{' '.join(r['render_cmd'])}`",
        f"- **Convert cmd (ztex)**: `{' '.join(r['convert_cmd'])}`",
        f"- **Ref cmd (xelatex)**: `{' '.join(r['ref_cmd'])}`",
        f"- **Ref convert cmd (mutool)**: `{' '.join(r['ref_convert_cmd'])}`",
        f"- **KaTeX cmd**: `{' '.join(r['katex_cmd'])}`",
        f"- **KaTeX convert cmd**: `{' '.join(r['katex_convert_cmd'])}`",
        f"- **MathJax cmd**: `{' '.join(r['mathjax_cmd'])}`",
        f"- **MathJax convert cmd**: `{' '.join(r['mathjax_convert_cmd'])}`",
        f"- **Vision model**: {r['vision_model']}",
        f"- **Verdict**: **{r['status']}** ({r['n_nits']} nits)",
        "",
        "## Nits (JSON)",
        "",
        "```json",
        json.dumps(v, indent=2),
        "```",
        "",
        "## Raw response",
        "",
        "```text",
        r["raw_verdict"] or "(no raw response)",
        "```",
        "",
        "## Prompt used",
        "",
        "```text",
        prompt,
        "```",
        "",
    ]
    return "\n".join(lines)


def run_ref_critique(args, formula):
    """--ref mode: ours + XeTeX + KaTeX + MathJax references stacked, vision
    lists every nit in OURS vs the references. The nits are SUGGESTIONS only —
    they are never merged into a geometric verdict (this mode runs no verifier).
    All four panes render at the same nominal pt size (--size) and the same
    pixel density (REF_SCALE × 96 dpi = 8/3 px/pt), so the combined image
    scales each pane to a common width without ever upscaling below 8/3 px/pt.
    """
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    n = next_ref_critique_number(out_dir)
    work = out_dir / "artifacts" / f"critique-ref-{n}"
    work.mkdir(parents=True, exist_ok=True)
    svg_path, png_path = work / "render.svg", work / "render.png"

    # a. Render ours exactly like the normal mode (ztex -> SVG -> PIL raster),
    #    at REF_SCALE × 96 dpi so the combined image never upscales a pane
    #    below 8/3 px/pt (the previous 96 dpi render upscaled the narrower
    #    panes — e.g. ztex at 73px -> 85px — in the combined image).
    render_cmd = render_svg(args.ztex_binary, args.use_build_run,
                            formula, args.size, args.background, svg_path)
    convert_cmd = convert_png(svg_path, png_path, args.font_dir, scale=REF_SCALE)
    png_w, png_h = png_size(png_path)

    # b. Render the XeTeX reference into the same work dir (absolute path:
    #    xelatex -output-directory is relative to cwd, which is the workdir)
    ref_png, ref_cmd, ref_convert_cmd = render_ref(
        formula, str(work.resolve()), size_pt=args.size, dpi=96 * REF_SCALE)
    ref_w, ref_h = png_size(ref_png)

    # b2. Render the KaTeX reference (second master reference, same size)
    katex_png, katex_cmd, katex_convert_cmd = render_katex_ref(
        formula, str(work.resolve()), size_pt=args.size, scale=REF_SCALE)
    katex_w, katex_h = png_size(katex_png)

    # b3. Render the MathJax reference (fourth pane; native SVG paths)
    mathjax_png, mathjax_cmd, mathjax_convert_cmd = render_mathjax_ref(
        formula, str(work.resolve()), size_pt=args.size, scale=REF_SCALE)
    mathjax_w, mathjax_h = png_size(mathjax_png)

    # c. Combine: ours / XeTeX / KaTeX / MathJax, same width, stacked + labels
    combined_path = work / "combined.png"
    combined_w, combined_h = combine_panes(
        [(png_path, "ztex (ours)"), (ref_png, "XeTeX (reference)"),
         (katex_png, "KaTeX (reference)"), (mathjax_png, "MathJax (reference)")],
        combined_path)

    # d. Vision: every visual nit in the LEFT (ztex) half vs the reference
    prompt = REF_PROMPT_TEMPLATE.format(formula=formula)
    prompt_path = work / f"critique-ref-{n}.prompt.txt"
    prompt_path.write_text(prompt)
    api_key = os.environ.get("OPENROUTER_API_KEY")
    vision_model = args.vision_model if api_key and not args.no_critique else "(not called)"
    if api_key and not args.no_critique:
        verdict, raw = call_vision(prompt, combined_path, args.vision_model, api_key, args.timeout)
    else:
        reason = "skipped by --no-critique" if args.no_critique else "no OPENROUTER_API_KEY set"
        verdict = {"status": "not-run", "reason": reason}
        raw = ""

    # e. Nit list (SUGGESTIONS; never merged into a geometric verdict)
    nits = []
    if isinstance(verdict, dict) and isinstance(verdict.get("nits"), list):
        nits = verdict["nits"]
    vstatus = verdict.get("status") if isinstance(verdict, dict) else None
    if vstatus is None:
        vverdict = verdict.get("verdict") if isinstance(verdict, dict) else None
        status = vverdict if vverdict in ("PASS", "FAIL") else ("FAIL" if nits else "PASS")
    else:
        status = {"not-run": "not-run", "vision-error": "VISION-ERROR",
                  "unparseable": "UNPARSEABLE"}.get(vstatus, "ERROR")

    # SVG canvas size for the report (cheap parse of the root element)
    svg_text = Path(svg_path).read_text(errors="replace")
    m = re.search(r"<svg\b[^>]*>", svg_text)
    root = _svg_attrs(m.group(0)) if m else {}
    svg_w = _pt(root["width"]) if root.get("width") else 0.0
    svg_h = _pt(root["height"]) if root.get("height") else 0.0

    report = {
        "number": n,
        "formula": formula,
        "size": args.size,
        "background": args.background,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"),
        "svg_path": svg_path, "svg_w": svg_w, "svg_h": svg_h,
        "png_path": png_path, "png_w": png_w, "png_h": png_h,
        "ref_png": ref_png, "ref_w": ref_w, "ref_h": ref_h,
        "katex_png": katex_png, "katex_w": katex_w, "katex_h": katex_h,
        "mathjax_png": mathjax_png, "mathjax_w": mathjax_w, "mathjax_h": mathjax_h,
        "combined_path": combined_path, "combined_w": combined_w, "combined_h": combined_h,
        "render_cmd": [str(c) for c in render_cmd],
        "convert_cmd": [str(c) for c in convert_cmd],
        "ref_cmd": [str(c) for c in ref_cmd],
        "ref_convert_cmd": [str(c) for c in ref_convert_cmd],
        "katex_cmd": [str(c) for c in katex_cmd],
        "katex_convert_cmd": [str(c) for c in katex_convert_cmd],
        "mathjax_cmd": [str(c) for c in mathjax_cmd],
        "mathjax_convert_cmd": [str(c) for c in mathjax_convert_cmd],
        "vision_model": vision_model,
        "nits_verdict": verdict,
        "raw_verdict": raw,
        "status": status,
        "n_nits": len(nits),
    }
    report_path = out_dir / f"critique-ref-{n}.md"
    report_path.write_text(render_ref_report(report, prompt))

    print(f"combined: {combined_path}")
    print(f"prompt:   {prompt_path}")
    print(f"report:   {report_path}")
    print(f"ref-critique-{n}: {status} ({len(nits)} nits)")
    for nit in nits:
        sev = nit.get("severity", "minor") if isinstance(nit, dict) else "minor"
        region = nit.get("region", "") if isinstance(nit, dict) else ""
        desc = nit.get("description", str(nit)) if isinstance(nit, dict) else str(nit)
        print(f"  [{sev}] {region}: {desc}" if region else f"  [{sev}] {desc}")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Adversarial vision critique of a ztex formula render.")
    ap.add_argument("-i", "--input", help="formula (LaTeX); may also be given positionally")
    ap.add_argument("formula_pos", nargs="?", help=argparse.SUPPRESS)
    ap.add_argument("-s", "--size", type=float, default=20.0, help="font size in pt (default 20)")
    ap.add_argument("-b", "--background", default="white", help="background (default white)")
    ap.add_argument("--font-dir", default=DEFAULT_FONT_DIR,
                    help="Latin Modern font directory (default: devenv profile opentype dir)")
    ap.add_argument("--out-dir", default="notes", help="report directory (default notes)")
    ap.add_argument("--ztex-binary", default="zig-out/bin/ztex",
                    help="path to built ztex binary; falls back to 'zig build run --'")
    ap.add_argument("--use-build-run", action="store_true",
                    help="render via 'zig build run --' instead of the built binary")
    ap.add_argument("--vision-model", default=os.environ.get("ZTEX_VISION_MODEL", DEFAULT_VISION_MODEL))
    ap.add_argument("--no-critique", action="store_true",
                    help="render only; emit prompt + image + JSON skeleton, skip the model call")
    ap.add_argument("--ref", action="store_true",
                    help="adversarial ref mode: also render the XeTeX + KaTeX + MathJax "
                         "references (all at 2x 96dpi = 8/3 px/pt, same nominal pt size), "
                         "combine ours + all three references stacked, and have the vision "
                         "model list every visual nit in ours vs any reference (nits stay "
                         "suggestions)")
    ap.add_argument("--timeout", type=int, default=OPENROUTER_TIMEOUT,
                    help="vision API timeout in seconds (default 180)")
    args = ap.parse_args(argv)

    formula = args.input or args.formula_pos
    if not formula:
        ap.error("no formula given: pass -i 'FORMULA' or a positional argument")

    if args.ref:
        return run_ref_critique(args, formula)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    n = next_critique_number(out_dir)
    work = out_dir / "artifacts" / f"critique-{n}"
    work.mkdir(parents=True, exist_ok=True)
    svg_path, png_path = work / "render.svg", work / "render.png"

    # 1. Render + convert
    render_cmd = render_svg(args.ztex_binary, args.use_build_run,
                            formula, args.size, args.background, svg_path)
    convert_cmd = convert_png(svg_path, png_path, args.font_dir)
    png_w, png_h = png_size(png_path)

    # 2. Geometric verification (deterministic ground truth; always on)
    geometry = compute_geometry(svg_path, args.font_dir)
    svg_w, svg_h = geometry["svg_w_pt"], geometry["svg_h_pt"]

    # 3. Prompt
    prompt = build_prompt(formula, png_path)
    prompt_path = work / f"critique-{n}.prompt.txt"
    prompt_path.write_text(prompt)

    # 4. Vision critique (adversarial proposer; geometry is the verifier)
    api_key = os.environ.get("OPENROUTER_API_KEY")
    vision_model = args.vision_model if api_key and not args.no_critique else "(not called)"
    if api_key and not args.no_critique:
        verdict, raw = call_vision(prompt, png_path, args.vision_model, api_key, args.timeout)
    else:
        reason = "skipped by --no-critique" if args.no_critique else "no OPENROUTER_API_KEY set"
        verdict = {"status": "not-run", "reason": reason}
        raw = ""
    status, n_defects, one_line, claim_resolutions = summarize(verdict, geometry)

    # 5. Report
    report = {
        "number": n,
        "formula": formula,
        "size": args.size,
        "background": args.background,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"),
        "svg_path": svg_path, "svg_w": svg_w, "svg_h": svg_h,
        "png_path": png_path, "png_w": png_w, "png_h": png_h,
        "render_cmd": [str(c) for c in render_cmd],
        "convert_cmd": [str(c) for c in convert_cmd],
        "vision_model": vision_model,
        "vision": verdict,
        "geometry": geometry,
        "claim_resolutions": claim_resolutions,
        "raw_verdict": raw,
        "status": status,
        "one_line": one_line,
        "defect_count": n_defects,
    }
    report_path = out_dir / f"critique-{n}.md"
    report_path.write_text(render_report(report, prompt))

    print(f"image:  {png_path}")
    print(f"prompt: {prompt_path}")
    print(f"report: {report_path}")
    print(f"critique-{n}: {status} ({n_defects} defects) — {one_line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
