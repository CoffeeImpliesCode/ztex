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
truth computed from the ztex SVG and the actual Latin Modern OTF outlines
(fontTools BoundsPen): per-glyph ink boxes in SVG pt, union ink bbox, per-edge
clipping overflow, big-op/limit-op centering offsets, pairwise ink-box
overlaps, and glyphs that render nothing. The geometric verdict is
AUTHORITATIVE: a vision claim fails the verdict only when geometry confirms
it; claims geometry contradicts are marked "refuted (vision artifact)" and
never fail. This stops the loop from chasing vision hallucinations (e.g. a
"0.05 offset" limit that is geometrically 0.0, or "overlaps" with 1.6pt gaps).

The PNG is rasterized with PIL from the ztex SVG itself, drawing every
<text> glyph with the actual Latin Modern OTFs at the declared pt font-size
(96 dpi, 1pt = 4/3 px). This is the TRUSTWORTHY render on this host:
resvg/rsvg-convert/ImageMagick all break ztex <text> via font fallback and
overflow the frame, producing phantom edge clipping that is not in the SVG
(the SVG carries a ~34pt right margin at -s 48).

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
import io
import json
import os
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
from fontTools.ttLib import TTFont

DEFAULT_VISION_MODEL = "qwen/qwen-2.5-vl-72b-instruct"
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
OPENROUTER_TIMEOUT = 180

# ── PIL rasterizer (trustworthy render on this host) ────────────────────────
# The ztex SVG declares pt lengths (root width/height carry "pt", viewBox is
# unitless-pt). We rasterize at 96 dpi: every pt → 96/72 = 4/3 px, applied
# uniformly to the canvas, glyph positions AND font sizes, so a 1pt glyph
# renders at exactly 4/3 px — the same geometry a browser gives at 96 dpi,
# but with the real Latin Modern glyph shapes (no font-fallback shifts).
PT_TO_PX = 96.0 / 72.0
# PIL's direct glyph rasterization at 48pt+ renders strokes measurably
# bolder than mutool's reference raster (per-glyph ink coverage ~+4% at the
# same px/pt — see rasterize_svg). Supersample 2x and LANCZOS-downscale so
# the critique compares glyph shapes, not raster antialiasing.
RASTER_SUPERSAMPLE = 2

DEFAULT_FONT_DIR = "/nix/store/wgpnygkr70hxa0vj5ka284cfc65bfzyn-devenv-profile/share/fonts/opentype"
LM_MATH_FONT = "latinmodern-math.otf"   # math runs (glyphs are math-italic already)
LM_ROMAN_FONT = "lmroman10-regular.otf"  # \text / \mathrm runs
LM_BOLD_FONT = "lmroman10-bold.otf"      # \mathbf runs

# ── Geometric verifier (deterministic ground truth) ────────────────────────
BIGOP_GLYPHS = set("∑∫∏⋃⋂⨆∐∮")        # operators that take over/under limits
# Big-op codepoints whose DISPLAY glyph is a MATH-table .v1 variant (the cmap
# base glyph is what the SVG/browser shows; XeTeX draws the variant — e.g.
# summation.v1, integral.v1). The PIL rasterizer and the geometric verifier
# resolve the variant so the critique render matches XeTeX in width AND
# height (a single font-size scalar on the base glyph cannot: ∫ base aspect
# 0.498 vs .v1 0.399). Private-use chars address the variants through PIL
# (FreeType rasterizes by cmap; a patched font maps each PUA char to the
# .v1 glyph, drawn at the same size/baseline as the base glyph).
BIGOP_DISPLAY_CPS = (0x2211, 0x222B, 0x220F, 0x2210, 0x22C3, 0x22C2, 0x2A06, 0x222E)
BIGOP_PUA_BASE = 0xF000
BIGOP_PUA = {cp: BIGOP_PUA_BASE + i for i, cp in enumerate(BIGOP_DISPLAY_CPS)}
# Delimiter codepoints whose STRETCHED form is a MATH-table vertical size
# variant (parenleft.v1..v7 etc.) — the glyph XeTeX/KaTeX draw for a \left/
# \right delimiter. ztex emits every delimiter <text> at the BASE math size:
# the layout sizes the delimiter from the MATH size-variant ladder by the
# enclosed content's extent (TeX make_delim — see _delimiter_targets and
# _delimiter_resolution), so the intended size is NOT in the SVG. The
# rasterizer and the geometric verifier reconstruct it from the SVG geometry.
# Private-use chars address the variants through PIL exactly like the big-op
# .v1 glyphs (the patched font maps each PUA char to the variant glyph,
# drawn at its own size).
DELIMITER_CPS = (0x0028, 0x0029, 0x005B, 0x005D, 0x007B, 0x007D,
                 0x27E8, 0x27E9, 0x230A, 0x230B, 0x2308, 0x2309)
DELIM_PAIRS = {0x0028: 0x0029, 0x005B: 0x005D, 0x007B: 0x007D,
               0x27E8: 0x27E9, 0x230A: 0x230B, 0x2308: 0x2309}  # open -> close
DELIM_OPENERS = frozenset(DELIM_PAIRS)
DELIM_CLOSERS = frozenset(DELIM_PAIRS.values())
DELIM_OPENER_OF = {close: open_ for open_, close in DELIM_PAIRS.items()}
# TeX make_delim (tex.web §1114): a \left..\right delimiter must cover
# max(2·δ·901/1000, 2·δ − \delimitershortfall) of ink, where δ = max(h−a, d+a)
# of the enclosed content box vs the math axis. \delimitershortfall is the
# ABSOLUTE 5pt of plain TeX (not 0.1em — the src/layout/layout.zig floor uses
# 0.1em and over-requires by ~1pt at 30pt: it would draw parenleft.v7 where
# XeTeX draws .v6). Verified against the XeTeX references: `\left(
# \frac{x^2+1}{x} \right)` at 30pt (content δ = 37.7pt) → floor 70.4pt →
# parenleft.v6 (refs' ink 71.5pt), `\left( \frac{a}{b} \right)^2` (δ =
# 28.4pt) → 51.8pt → .v4 (refs 53.6pt), the EL fraction at 40pt (δ = 45.7pt)
# → 86.4pt → .v6, `\left( x+\frac{1}{2} \right)` (δ = 32.8pt) → 60.6pt →
# .v5 (refs' measured variant).
DELIM_MIN_COVER = 0.901
DELIM_SHORTFALL_PT = 5.0
AXIS_HEIGHT_EM = 0.25   # LM Math MATH-axis height (ztex GlueParams.axis_height 2.5/10pt)
DELIM_PUA_BASE = 0xF100
DELIM_PUA_SLOTS = 8   # address space per delimiter (slot k -> k-th MATH variant record)
# \big-family fixed-level recovery (see _delimiter_targets): the layout
# boxes \big/\Big/\bigg/\Bigg delimiters by their FIXED ladder entry at the
# BASE size — the level is not in the SVG, so the rasterizer recovers it
# from the box advance: the x-gap from the open delimiter to the first
# enclosed content (the layout places the next atom flush at the box edge,
# no inter-atom glue; a fraction/group adds its internal offset). A pair
# whose content-driven req contradicts the measured gap is a fixed-level
# pair. Tolerances in em of the delimiter size (scale with the size).
DELIM_GAP_TOL_EM = 0.02        # box-advance match tolerance for the level
DELIM_CONSISTENT_TOL_EM = 0.05  # content-driven variant box must match the gap
# LM Math brace tip overhang (em of the formula size): how far a stretched
# brace's tips extend beyond the required cover line (the math axis ∓ delta)
# once the delimiter is sized to the enclosed array. XeTeX assembles an
# arbitrary-tall brace from FIXED tip/mid pieces (U+23A7/23A8/23A9) plus
# { extenders — the tips are drawn at the formula size and stick out a fixed
# ~0.096em beyond the covered body, so the full extent is NOT capped by the
# largest ladder entry. Calibrated from the XeTeX 3-row \cases reference
# (brace extent 124.13pt vs 2·delta 118.38pt → 2·0.096em·30 overhang).
DELIM_TIP_OVERHANG_EM = 0.096

# Radical codepoints whose STRETCHED form is a MATH-table vertical variant
# (radical.v1..v4 — NOT a Unicode character the browser can draw). ztex emits
# the √ <text> at the current math size with data-radical="vN"; the rasterizer
# and the geometric verifier resolve the variant the same way big-op .v1 and
# delimiter variants resolve: a patched font maps a PUA char to the variant
# glyph (radical.vN), drawn at the same size/baseline as the base √ — constant
# stroke, tall ink, slim width.
RADICAL_CPS = (0x221A,)  # √ \surd
RADICAL_PUA_BASE = 0xF200                  # PUA slot for radical variants
RADICAL_PUA = {i: RADICAL_PUA_BASE + i - 1 for i in range(1, 5)}  # v1..v4


def _delim_pua(cp, k):
    """PUA char addressing the k-th (1-based) MATH size variant of a delimiter cp."""
    return DELIM_PUA_BASE + DELIMITER_CPS.index(cp) * DELIM_PUA_SLOTS + k
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


def find_lm_font(name, font_dir=DEFAULT_FONT_DIR):
    """Absolute path to a Latin Modern face; None if not found.

    Tries the known devenv-profile path first, then globs the Nix store and
    system font dirs so the script still works when the store path moves.
    """
    for pat in _LM_FONT_PATTERNS[name]:
        for hit in sorted(glob.glob(pat.format(dir=font_dir))):
            return hit
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


def _parse_color(hexcolor):
    """'#RRGGBB' or '#RRGGBBAA' -> RGB tuple (alpha composited over white)."""
    s = hexcolor.lstrip("#")
    if len(s) == 8:
        r, g, b, a = (int(s[i:i + 2], 16) for i in (0, 2, 4, 6))
        return tuple(round(c * a / 255 + 255 * (255 - a) / 255) for c in (r, g, b))
    if len(s) == 6:
        return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))
    return (0, 0, 0)


def _unescape(s):
    return (s.replace("&amp;", "&").replace("&lt;", "<")
             .replace("&gt;", ">").replace("&quot;", '"'))


def _parse_svg_primitives(svg):
    """(w_pt, h_pt, elements): the one SVG parse shared by the PIL rasterizer
    and the geometric verifier, so both see identical geometry. elements is a
    list of (kind, attrs, content) in document order, kind ∈ text/rect/line
    (text content XML-unescaped; rect/line content '').
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
            r"<(text|rect|line)\b([^>]*?)(/?)>(.*?)</\1>|<(text|rect|line)\b([^>]*?)/>",
            svg, re.S):
        if el.group(1):
            kind, attrs_raw, content = el.group(1), el.group(2), el.group(4)
        else:
            kind, attrs_raw, content = el.group(5), el.group(6), ""
        elements.append((kind, _svg_attrs(attrs_raw),
                         _unescape(content) if kind == "text" else ""))
    return w_pt, h_pt, elements


def _base_math_size(elements):
    """Largest font-size among glyphs that are never stretched — everything
    except delimiters, which the layout now emits at the base size too. The
    em base for MATH-variant sizing; None when there are no such glyphs."""
    base = None
    for kind, a, content in elements:
        if kind != "text" or (len(content) == 1 and ord(content) in DELIMITER_CPS):
            continue
        s = _pt(a.get("font-size", "0"))
        if base is None or s > base:
            base = s
    return base


def _display_bigop(attrs):
    """True when this <text> is a DISPLAY big-op — the MATH-table .v1
    variant (what XeTeX draws for a display operator).

    The layout (layoutOp) marks display big-ops `data-op="v1"` in the SVG
    (the box's bigop_form.variant); text/script big-ops are unmarked and
    draw the CMAP base glyph at their declared size. The marker replaces
    the old font-size discriminator (`declared size == the pane's base math
    size`): since the text-op size fix BOTH the display and text \\int are
    declared at the pane's base size, so the declared size can no longer
    tell them apart."""
    return attrs.get("data-op") == "v1"


def rasterize_svg(svg_path, png_path, font_dir=DEFAULT_FONT_DIR, scale=1.0):
    r"""Faithful PIL raster of a ztex SVG at 96 dpi × scale (1pt = 4/3 px).

    ztex emits one <text> per char/run with its BASELINE at y, in pt, naming
    the Latin Modern faces. Each glyph is drawn with the actual OTF at the
    declared font-size (anchor "ls" = left-baseline, so the baseline lands on
    y); fraction bars and stroked decorations (<rect>/<line>) are drawn in
    painter order too. The result is a true picture of the SVG geometry —
    unlike resvg/rsvg/ImageMagick on this host, which fall back to wrong
    fonts and overflow the frame. Deterministic: same SVG + fonts -> same PNG.

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
    # Base math size + which delimiters the layout STRETCHED (their required
    # ink derived from the enclosed content — see _delimiter_targets). Every
    # \left..\right delimiter <text> is at the base size, so the intended
    # MATH variant is resolved from the geometry, not the font-size.
    base_size = _base_math_size(elements)
    delim_targets, _spans = _delimiter_targets(elements, w_pt, h_pt, font_dir, base_size)
    for kind, a, content in elements:
        fill = _parse_color(a.get("fill", "#000000"))
        if kind == "text":
            size_pt = _pt(a.get("font-size", "0"))
            x_pt, y_pt = _pt(a.get("x", "0")), _pt(a.get("y", "0"))
            pua = (BIGOP_PUA.get(ord(content))
                   if len(content) == 1 and _display_bigop(a)
                   else None)
            if pua is not None:
                # DISPLAY big-op (data-op="v1"): draw the MATH-table .v1
                # display variant (the glyph XeTeX draws) instead of the
                # cmap base glyph the SVG/browser shows: the patched font
                # maps the private-use char to the .v1 glyph, rasterized at
                # the same size and baseline. Unmarked big-ops (text/script
                # style) fall through and draw the CMAP BASE glyph at their
                # declared size — the smaller form all other engines use.
                font = _variant_font(find_lm_font(_lm_font_name(a), font_dir),
                                     size_pt * PT_TO_PX * ss)
                content = chr(pua)
            elif (len(content) == 1 and ord(content) in RADICAL_CPS
                    and a.get("data-radical")):
                # Stretchy √ glyph: the layout selected a MATH-table vertical
                # variant (radical.v1..v4) so the surd's height covers the
                # radicand while its width stays slim (1.0em advance, ∼0.91em
                # ink at the current size). The SVG declares font-size=size_pt;
                # data-radical="vN" tells the raster to draw the variant, not
                # the base √ the browser would render (which is 1.0em tall —
                # too short for fractions). The variant draws at the SAME size
                # and baseline (no shift needed: LM Math variants share the
                # base glyph's baseline convention).
                pua = RADICAL_PUA[int(a["data-radical"][1:])]
                font = _variant_font(find_lm_font(_lm_font_name(a), font_dir),
                                     size_pt * PT_TO_PX * ss)
                content = chr(pua)
            elif len(content) == 1 and (x_pt, y_pt, content) in delim_targets:
                # Stretched delimiter: draw the MATH size VARIANT (constant
                # stroke). Paired \left..\right delimiters draw at the declared
                # (base) size; unpaired fences and \big-family levels resolve
                # their own size — the resolution returns the variant, its draw
                # size and the baseline shift aligning the variant's ink center
                # with the base glyph's (both on the MATH axis — shift ≈ 0
                # for LM Math).
                res = _delimiter_resolution(find_lm_font(_lm_font_name(a), font_dir),
                                            ord(content), size_pt,
                                            delim_targets[(x_pt, y_pt, content)])
                if res is not None:
                    pua, _gname, size_v_pt, shift_pt = res
                    font = _variant_font(find_lm_font(_lm_font_name(a), font_dir),
                                         size_v_pt * PT_TO_PX * ss)
                    content = chr(pua)
                    y_pt += shift_pt
                else:
                    font = _face_for(a, font_dir, size_pt * PT_TO_PX * ss)
            else:
                font = _face_for(a, font_dir, size_pt * PT_TO_PX * ss)
            draw.text((x_pt * PT_TO_PX * ss, y_pt * PT_TO_PX * ss),
                      content, font=font, fill=fill, anchor="ls")
        elif kind == "rect":
            x = _pt(a.get("x", "0")) * PT_TO_PX * ss
            y = _pt(a.get("y", "0")) * PT_TO_PX * ss
            w = _pt(a["width"]) * PT_TO_PX * ss
            h = _pt(a["height"]) * PT_TO_PX * ss
            draw.rectangle((x, y, x + w, y + h), fill=fill)
        else:  # line — stroked decoration
            width = max(1, int(round(_pt(a.get("stroke-width", "1")) * PT_TO_PX * ss)))
            draw.line([_pt(a[k]) * PT_TO_PX * ss for k in ("x1", "y1", "x2", "y2")],
                      fill=fill, width=width)
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


def _delimiter_variants(tt, cp):
    """Ordered MATH-table vertical size variants (v1.., base excluded) of a
    delimiter codepoint, or the conventional '<base>.v1', '<base>.v2', ...
    names when the font has no MATH table. Empty list when the codepoint has
    no base glyph / no variants (the caller then draws the base glyph).
    """
    cmap = tt.getBestCmap()
    base = cmap.get(cp)
    if base is None:
        return []
    records = []
    math = tt.get("MATH")
    if math is not None:
        mv = math.table.MathVariants
        try:
            names = list(mv.VertGlyphCoverage.glyphs)
        except AttributeError:
            names = [c.glyphName for c in mv.VertGlyphCoverage]
        for name, gc in zip(names, mv.VertGlyphConstruction):
            if name == base and gc.MathGlyphVariantRecord:
                records = [r.VariantGlyph for r in gc.MathGlyphVariantRecord]
                break
    if not records:
        order = set(tt.getGlyphOrder())
        i = 1
        while f"{base}.v{i}" in order:
            records.append(f"{base}.v{i}")
            i += 1
    return [g for g in records if g != base]


_ink_em_cache = {}   # (path, glyph_name) -> (ink_height_em, ink_center_em)


def _glyph_ink_em(tt, path, gname):
    """(ink_height_em, ink_center_em) of a glyph from its real OTF outline.

    ink_center_em is the ink-center height ABOVE the baseline (font y up).
    Glyphs with no ink yield (0.0, 0.0).
    """
    key = (path, gname)
    v = _ink_em_cache.get(key)
    if v is None:
        pen = BoundsPen(tt.getGlyphSet())
        try:
            tt.getGlyphSet()[gname].draw(pen)
        except Exception:  # noqa: BLE001 — defensive: treat as no ink
            v = (0.0, 0.0)
        else:
            if not pen.bounds:
                v = (0.0, 0.0)
            else:
                x0, y0, x1, y1 = pen.bounds
                upem = tt["head"].unitsPerEm
                v = ((y1 - y0) / upem, (y1 + y0) / 2.0 / upem)
        _ink_em_cache[key] = v
    return v


_hmtx_advance_cache = {}   # (path, glyph_name) -> advance in em


def _hmtx_advance(path, gname):
    """Horizontal advance (em) of a glyph from the font's hmtx table."""
    key = (path, gname)
    v = _hmtx_advance_cache.get(key)
    if v is None:
        tt = _tt_font(path)
        upem = tt["head"].unitsPerEm
        m = tt["hmtx"].metrics.get(gname)
        v = (m[0] / upem) if m else 0.0
        _hmtx_advance_cache[key] = v
    return v


def _delimiter_targets(elements, w_pt, h_pt, font_dir, base_size):
    r"""(x, y, content) of STRETCHED delimiters -> resolution spec.

    The layout sizes a \left..\right delimiter from the MATH size-variant
    ladder by the enclosed content's extent, and emits every delimiter
    <text> at the BASE math size — the intended size is NOT in the SVG.
    Reconstruct the layout's TeX make_delim floor (tex.web §1114, the same
    formula src/layout/layout.zig layoutLeftRight runs) from the SVG
    geometry: pair each delimiter <text> with its matching partner (stack
    over x-sorted delimiters, honoring TeX nesting), union the ink boxes of
    the OTHER elements horizontally between the pair (the enclosed content;
    big-op display variants resolved like the raster draws them), and compute
    δ = max(h − a, d + a) where h/d are the content extent above/below the
    delimiter baseline and a = axis height (0.25em). The required ink is
    max(2·δ·901/1000, 2·δ − \delimitershortfall) with \delimitershortfall =
    5pt absolute (plain TeX; see DELIM_SHORTFALL_PT): a delimiter is
    STRETCHED when that floor exceeds its base glyph's ink, and the returned
    value (em of the delimiter size) is the minimum variant ink the
    resolution must cover.
    The keys (x, y, content) come from the <text> attributes, so the
    rasterizer and the geometric verifier resolve the SAME delimiters.

    FOUR stretched forms are resolved (the spec's "mode" selects the rule
    in _delimiter_resolution):

    · "pair" — \left..\right with both delimiters present (the current
      behavior): req = the make_delim floor in em of the delimiter size;
      the variant is drawn at the declared (base) size.

    · "scaled" — an UNPAIRED \left/\right fence whose partner is a null
      delimiter (\left. / \right.): the layout (layoutDelimScaled) emits
      the base glyph at the font-size whose axis-centered ink covers the
      enclosed content exactly (the SVG's declared font-size IS the scaled
      size, > the base math size). The target is the base glyph's OWN ink
      at the declared size; req = target in em of the BASE size; the
      variant is drawn at target / variant_ink (its "own" size), so the
      stroke stays constant — drawing the scaled base glyph would thicken
      it (the "bold brace" defect).

    · "level" — a \big/\Big/\bigg/\Bigg pair: the layout boxes the FIXED
      ladder entry at the base size (the level lives only in the parse, not
      the SVG), so the content-driven req is the wrong signal. The raster
      recovers the level from the box advance — the x-gap from the open
      delimiter to the first enclosed content (flush at the box edge; the
      layout places no inter-atom glue) — matched against the variant
      ladder advances. Fires only when the content-driven resolution
      contradicts the measured gap (a \left pair's box always agrees).
    · "level" also covers an UNPAIRED OPENING delimiter emitted at the BASE
      size with no matching close in the SVG — the amsmath \cases brace. The
      layout (layoutDelimChar) chose the smallest MATH variant whose ink
      covers the enclosed rows and flushed the array at that variant's
      advance, so the x-gap from the opener to its first enclosed cell IS the
      variant's advance; the level is recovered from that gap and the variant
      is drawn at the declared (base) size (constant stroke, filling the
      layout's box). (A \left\{...\right. is emitted by layoutDelimSized as a
      SCALED glyph and uses the "scaled" form above.)

    Delimiters with no partner at the base size, no enclosed content, or
    whose base glyph already covers the floor stay out of the map (drawn as
    the base glyph).

    Returns (targets, spans): targets maps each stretched delimiter key to
    {"req": float, "mode": "pair"|"scaled"|"level", "level": int|None,
    "base": float|None}; spans lists each stretched pair as {"open",
    "close" (the two keys), "lo", "hi"} — the horizontal ink span the pair
    encloses, for the verifier's intended-wrap exclusions.
    """
    delims, others, others_x = [], [], []
    # Parallel to `others`: the <text> font-size (0 for rect/line boxes) and
    # BASELINE y (the <text> y; None for rect/line boxes). The paired-fence
    # extent uses them to tell a fenced fraction's parts (baselines ~0.68em
    # off the delimiter line, scripts at SCRIPT size) apart from sibling
    # array rows (row-spacing off the line, base size) — see the row_tol
    # block below. The unpaired sections read only others/others_x.
    others_size, others_base = [], []
    for kind, a, content in elements:
        if kind != "text":
            if kind == "rect":
                x, y = _pt(a.get("x", "0")), _pt(a.get("y", "0"))
                box = (x, y, x + _pt(a["width"]), y + _pt(a["height"]))
                if not (box[2] >= 0.95 * w_pt and box[3] >= 0.95 * h_pt):
                    others.append(box)
                    others_x.append(x)
                    others_size.append(0.0)
                    others_base.append(None)
            else:
                sw = _pt(a.get("stroke-width", "1")) / 2.0
                x1, y1 = _pt(a.get("x1", "0")), _pt(a.get("y1", "0"))
                x2, y2 = _pt(a.get("x2", "0")), _pt(a.get("y2", "0"))
                others.append((min(x1, x2) - sw, min(y1, y2) - sw,
                               max(x1, x2) + sw, max(y1, y2) + sw))
                others_x.append(min(x1, x2))
                others_size.append(0.0)
                others_base.append(None)
            continue
        single = len(content) == 1 and ord(content) in DELIMITER_CPS
        # Delimiter <text>s are boxed as the BASE glyph at the declared size
        # (never resolved here); every char ink also goes into `others`, so a
        # nested pair's delimiters count toward its enclosing pair's extent.
        # Big-op display variants inside resolve from the element's own
        # data-op marker (the raster draws them that way).
        boxes = _glyph_ink_boxes(a, content, font_dir)
        if single:
            delims.append({"x": _pt(a.get("x", "0")), "y": _pt(a.get("y", "0")),
                           "cp": ord(content), "size": _pt(a.get("font-size", "0")),
                           "box": boxes[0],
                           "fixed_req": float(a["data-fixed-req"])
                           if a.get("data-fixed-req") else 0.0})
        for b in boxes:
            if b:
                others.append(b)
                others_x.append(_pt(a.get("x", "0")))
                others_size.append(_pt(a.get("font-size", "0")))
                others_base.append(_pt(a.get("y", "0")))
    stack, pairs = [], []
    cur_y = None
    for d in sorted(delims, key=lambda d: (round(d["y"]), d["x"])):
        ry = round(d["y"])
        if cur_y is None or ry != cur_y:
            stack = []   # delimiters never pair across baselines (array rows)
            cur_y = ry
        if d["cp"] in DELIM_OPENERS:
            stack.append(d)
        elif d["cp"] in DELIM_CLOSERS:
            for i in range(len(stack) - 1, -1, -1):
                # A close only pairs with an unmatched opener strictly LEFT
                # of it. LIFO alone mispairs sibling pairs whose x interleave
                # as `( ( ) )` (adjacent array columns) and pairs across rows:
                # that inflated the enclosed extent and drew parenleft.v7
                # (~3x) instead of the base paren (the giant-paren bug).
                if (stack[i]["cp"] == DELIM_OPENER_OF[d["cp"]] and
                        stack[i]["x"] < d["x"]):
                    pairs.append((stack.pop(i), d))
                    break
    matched = set()
    targets = {}
    spans = []
    for o, c in pairs:
        if not o["box"] or not c["box"] or o["size"] <= 0:
            continue
        matched.add((o["x"], o["y"], chr(o["cp"])))
        matched.add((c["x"], c["y"], chr(c["cp"])))
        lo, hi = o["box"][2], c["box"][0]
        # Enclosed content is the ink between the delimiters ON THE SAME
        # baseline. The x filter alone pulls sibling-array-row glyphs (other
        # rows share the parens' x), inflating the extent to the whole array
        # and drawing parenleft.v7 (~3x) instead of the base paren. Only count
        # boxes whose vertical center sits within ~0.6em of the delimiter line.
        row_tol = 0.60 * o["size"]
        inside = [b for b in others if lo < (b[0] + b[2]) / 2.0 < hi
                  and abs((b[1] + b[3]) / 2.0 - o["y"]) < row_tol]
        axis = AXIS_HEIGHT_EM * o["size"]
        # A fence around a FRACTION: the layout centers a \frac on the math
        # axis and emits its rule as a thin <rect> exactly ON the axis (the
        # row baseline minus 0.25em). TeX sizes the fence from the fraction's
        # FULL box — numerator ABOVE the axis + denominator below — but the
        # display numerator's baseline sits ~0.68em above the delimiter line
        # (num_up + axis) and its scripts higher, so the row_tol filter clips
        # them and the fence resolves one rung short (parenleft.v5 instead of
        # the refs' v6 for `\left( \frac{x^2+1}{x} \right)`; the numerator is
        # the tail that makes the required ink). When the fence row carries a
        # fraction rule, extend the extent to the fraction's parts: the part
        # BASELINES (the <text> y) lie within ~0.75em of the delimiter line
        # (display num_up + axis ≈ 0.68em, text-style ≈ 0.53em, script-style
        # ≈ 0.64em), and the parts' scripts are drawn at SCRIPT size (< the
        # delimiter's font-size) within ~1.35em (the raised superscript).
        # Sibling ARRAY rows stay excluded — they sit at the row spacing
        # (≥0.61em even for a tight matrix, 1.2em for \pmod's 4-row array) at
        # the BASE size and their fraction rules would sit off THIS row's
        # axis — the giant-paren guard: a fence in one array/cases row must
        # not absorb sibling rows' glyphs (that is why row_tol exists).
        frac_tol = 0.75 * o["size"]
        script_tol = 1.35 * o["size"]
        has_frac_bar = any(
            osz == 0 and lo < (b[0] + b[2]) / 2.0 < hi
            and (b[3] - b[1]) <= 0.15 * o["size"]
            and (b[2] - b[0]) >= 2.0 * (b[3] - b[1])
            and abs((b[1] + b[3]) / 2.0 - (o["y"] - axis)) <= 0.05 * o["size"]
            for b, osz in zip(others, others_size))
        if has_frac_bar:
            for b, base_y, osz in zip(others, others_base, others_size):
                if not (lo < (b[0] + b[2]) / 2.0 < hi) or base_y is None:
                    continue
                dy = abs(base_y - o["y"])
                if dy < frac_tol or (osz > 0 and osz < o["size"]
                                     and dy < script_tol):
                    inside.append(b)
        extent = _union(inside)
        if not extent:
            continue
        delta = max(o["y"] - axis - extent[1], extent[3] - o["y"] + axis)
        minh = max(2.0 * delta * DELIM_MIN_COVER,
                   2.0 * delta - DELIM_SHORTFALL_PT)
        req_em = minh / o["size"]
        # amsmath FIXED fraction-delimiter rule (fenced `\binom`/`\genfrac`,
        # the SVG data-fixed-req marker): the layout boxed these delimiters
        # by a style-driven fixed req (binomialDelimReqEm), independent of
        # the content — the ink-derived req undershoots it (the row_tol clips
        # a stacked `\binom`'s numerator, and the fixed rule is taller than
        # the ink floor at display). Use the layout's exact req so both the
        # box and the drawn glyph land on the same variant.
        if o.get("fixed_req", 0.0) > 0 or c.get("fixed_req", 0.0) > 0:
            req_em = max(o.get("fixed_req", 0.0), c.get("fixed_req", 0.0))
        ok = (o["x"], o["y"], chr(o["cp"]))
        ck = (c["x"], c["y"], chr(c["cp"]))
        spec = {"req": req_em, "mode": "pair", "level": None, "base": None}
        # Fixed-level (\big family) recovery: the pair's box advance is the
        # x-gap from the open delimiter to the first enclosed content (the
        # layout puts the next atom flush at the box edge). A content-driven
        # \left pair's box agrees with its variant's advance; a \big pair's
        # box is the FIXED ladder entry, which contradicts the content-driven
        # variant — the box wins, and the level is the ladder entry whose
        # advance matches the gap.
        if base_size is not None and o["size"] <= base_size + 1e-6:
            first_x = min((x0 for b, x0 in zip(others, others_x)
                           if lo < (b[0] + b[2]) / 2.0 < hi), default=None)
            gap = (first_x - o["x"]) if first_x is not None else None
            path = find_lm_font(LM_MATH_FONT, font_dir)
            res = _delimiter_resolution(path, o["cp"], o["size"], spec)
            consistent = res is not None and gap is not None and (
                abs(gap - _hmtx_advance(path, res[1]) * o["size"])
                <= DELIM_CONSISTENT_TOL_EM * o["size"])
            if not consistent and gap is not None:
                tt = _tt_font(path)
                variants = _delimiter_variants(tt, o["cp"])
                best_k, best_err = None, None
                for k, gname in enumerate(variants):  # k -> ladder level k+1
                    adv = _hmtx_advance(path, gname)
                    if adv <= 0:
                        continue
                    err = abs(gap - adv * o["size"])
                    if err <= DELIM_GAP_TOL_EM * o["size"]:
                        if best_k is None or err < best_err:
                            best_k, best_err = k + 1, err
                if best_k is not None:
                    spec = {"req": req_em, "mode": "level",
                            "level": best_k, "base": None}
        targets[ok] = spec
        targets[ck] = spec
        # The horizontal span the pair encloses (delimiter ink boxes as the
        # boundaries), for the verifier's intended-wrap exclusions.
        spans.append({"open": ok, "close": ck, "lo": lo, "hi": hi})
    # UNPAIRED stretched fences: a \left/\right delimiter whose partner is a
    # null delimiter (\left. / \right.) — no partner element in the SVG. The
    # layout (layoutDelimScaled) emits the base glyph at the font-size whose
    # axis-centered ink covers the enclosed content exactly, so the declared
    # font-size (> the base math size) IS the intended height. The target is
    # the base glyph's own ink at the declared size; resolving the MATH
    # variant for that target and drawing it at target/variant_ink keeps the
    # constant stroke (the scaled base glyph would look bold).
    for d in delims:
        key = (d["x"], d["y"], chr(d["cp"]))
        if key in matched or base_size is None or d["size"] <= base_size + 1e-6:
            continue
        if not d["box"]:
            continue
        target_pt = d["box"][3] - d["box"][1]
        if target_pt <= 0:
            continue
        targets[key] = {"req": target_pt / base_size, "mode": "scaled",
                        "level": None, "base": base_size}
    # UNPAIRED OPENING delimiters at the BASE size: an env left-fence typeset
    # with no closing delimiter in the SVG — the amsmath \cases brace (the
    # layout's envCloseDelim returns null for cases, so only the open `{` is
    # emitted). The layout (layoutDelimChar) chose the smallest MATH variant
    # whose ink covers the enclosed rows and flushed the array at that variant's
    # advance, so the x-gap from the opener to its first enclosed cell IS the
    # variant's advance. Recover the level from that gap — mode "level" draws the
    # variant at the declared (base) size (constant stroke, ink = variant_em ×
    # size), exactly filling the layout's box. (An unpaired \left\{...\right. is
    # emitted by layoutDelimSized as a SCALED glyph and is handled above.)
    for d in delims:
        key = (d["x"], d["y"], chr(d["cp"]))
        if key in matched or key in targets:
            continue
        if d["cp"] not in DELIM_OPENERS or base_size is None:
            continue
        if d["size"] > base_size + 1e-6 or not d["box"]:
            continue
        lo = d["box"][2]  # right ink edge of the opening fence
        first_x = min((x0 for b, x0 in zip(others, others_x)
                       if (b[0] + b[2]) / 2.0 > lo), default=None)
        if first_x is None:
            continue
        gap = first_x - d["x"]
        path = find_lm_font(LM_MATH_FONT, font_dir)
        tt = _tt_font(path)
        variants = _delimiter_variants(tt, d["cp"])
        best_k, best_err = None, None
        for k, gname in enumerate(variants):  # k -> ladder level k+1
            adv = _hmtx_advance(path, gname)
            if adv <= 0:
                continue
            err = abs(gap - adv * d["size"])
            if err <= DELIM_GAP_TOL_EM * d["size"]:
                if best_k is None or err < best_err:
                    best_k, best_err = k + 1, err
        if best_k is not None:
            # The recovered level's ink must cover the array's vertical
            # extent about the math axis plus the brace tip overhang. If no
            # ladder variant is tall enough (a tall \cases array: XeTeX
            # assembles an arbitrary-tall brace from fixed tip/mid pieces +
            # extenders, so its extent is NOT capped by the largest variant),
            # fall back to the continuous scaled-base path targeting that
            # exact extent. Small braces keep the constant-stroke level.
            axis_y = d["y"] - AXIS_HEIGHT_EM * d["size"]
            inside = [(b, x0) for b, x0 in zip(others, others_x)
                      if (b[0] + b[2]) / 2.0 > lo]
            top = min(b[1] for b, _ in inside)
            bottom = max(b[3] for b, _ in inside)
            delta = max(axis_y - top, bottom - axis_y)
            need_em = 2 * (delta + DELIM_TIP_OVERHANG_EM * d["size"]) / d["size"]
            best_ink = _glyph_ink_em(tt, path, variants[best_k - 1])[0]
            if best_ink >= need_em - 1e-6:
                targets[key] = {"req": gap / d["size"], "mode": "level",
                                "level": best_k, "base": None}
            else:
                targets[key] = {"req": need_em, "mode": "scaled",
                                "level": None, "base": base_size}
    return targets, spans


def _delimiter_resolution(path, cp, size_pt, spec):
    r"""MATH-table vertical size variant for a STRETCHED delimiter, or None.

    A delimiter is stretched when the layout's required ink exceeds the base
    glyph's ink; the layout then draws the SMALLEST MATH size variant whose
    ink covers it — the largest when none does — so the variants keep a
    constant stroke, while scaling the base glyph would thicken it ~linearly.
    XeTeX/KaTeX draw the same variant ladder (parenleft.v1..v7).

    `spec` (from _delimiter_targets) selects the rule:
      {"req": required ink in em, "mode": "pair"} — a \left..\right pair:
        variant at the declared (base) size, req in em of `size_pt`;
      {"req", "mode": "scaled", "base": base_size} — an UNPAIRED fence
        emitted at a scaled font-size: the target is its own base-glyph ink
        (req × base_size pt); the variant is drawn at its "own" size
        (target / variant_ink) so the stroke stays constant and the ink
        covers the target exactly;
      {"mode": "level", "level": k} — a \big/\Big/\bigg/\Bigg delimiter:
        the FIXED ladder entry k (1..7 = MATH .v1..v7) at the declared size.

    Returns (pua_char, variant_glyph_name, variant_size_pt, baseline_shift_pt)
    — the variant drawn with its ink center aligned to the base glyph's ink
    center (both sit on the MATH axis, so the shift is 0 for LM Math's
    parens/braces) — or None when the base glyph covers the requirement (the
    delimiter is not stretched) or the font has no variant.
    """
    cmap = _tt_cmap(path)
    base = cmap.get(cp)
    if base is None:
        return None
    tt = _tt_font(path)
    h_b, c_b = _glyph_ink_em(tt, path, base)
    if h_b <= 0.0:
        return None
    variants = _delimiter_variants(tt, cp)
    if not variants:
        return None
    mode = spec.get("mode", "pair")
    req_em = spec.get("req", 0.0)
    if mode == "level":
        k = spec.get("level", 1)
        if k < 1 or k > len(variants):
            return None
        best = variants[k - 1]  # ladder level k = MATH .v(k) = variants[k-1]
        size_v = size_pt
    else:
        if req_em <= h_b + 1e-6:
            return None
        best = None
        for gname in variants:
            h_v, _c_v = _glyph_ink_em(tt, path, gname)
            if h_v > 0.0 and h_v >= req_em - 1e-6:
                best = gname
                break
        if best is None:
            best = max(variants, key=lambda g: _glyph_ink_em(tt, path, g)[0])
        h_v, c_v = _glyph_ink_em(tt, path, best)
        if h_v <= 0.0:
            return None
        # "scaled" (unpaired fence): draw the variant at target/variant_ink
        # so its ink equals the target exactly — the constant-stroke size.
        size_v = (req_em * spec["base"] / h_v) if mode == "scaled" else size_pt
    h_v, c_v = _glyph_ink_em(tt, path, best)
    if h_v <= 0.0:
        return None
    shift = c_v * size_v - c_b * size_pt  # axis-centering (0 for LM Math)
    pua = _delim_pua(cp, variants.index(best) + 1)
    return pua, best, size_v, shift


_variant_font_cache = {}   # (path, size_px) -> patched PIL ImageFont
_variant_tt_bytes = {}     # path -> bytes of the patched font (PUA -> .v1)


def _variant_font(path, size_px):
    """PIL font drawing the MATH variants: big-op .v1 display glyphs AND the
    delimiter size variants.

    The base font is patched in memory (fontTools): a private-use codepoint
    per operator / delimiter variant is mapped to the variant glyph name in
    the cmap, so FreeType rasterizes the ACTUAL variant at the requested
    size — the glyph shape XeTeX draws, positioned by the baseline the
    caller picks (big ops: the base glyph's baseline; stretched delimiters:
    the base baseline plus the centering shift from _delimiter_resolution).
    Cached per (path, size_px); the patched bytes are built once per font.
    """
    key = (path, size_px)
    f = _variant_font_cache.get(key)
    if f is None:
        raw = _variant_tt_bytes.get(path)
        if raw is None:
            tt = TTFont(path)
            mapping = {}
            for cp, pua in BIGOP_PUA.items():
                gname = _bigop_variant_glyph(tt, cp)
                if gname:
                    mapping[pua] = gname
            for cp in DELIMITER_CPS:
                for k, gname in enumerate(_delimiter_variants(tt, cp), start=1):
                    mapping[_delim_pua(cp, k)] = gname
            # Radical vertical variants: map PUA chars to radical.v1..v4 so
            # the PIL raster draws the variant the layout requested (the
            # data-radical="vN" attribute — not the base √ the browser shows).
            radical_gnames = [f"radical.v{vi}" for vi in range(1, 5)]
            for vi, gname in enumerate(radical_gnames, start=1):
                if gname in tt.getGlyphOrder():
                    mapping[RADICAL_PUA[vi]] = gname
            for table in tt["cmap"].tables:
                if table.isUnicode():
                    table.cmap.update(mapping)
            buf = io.BytesIO()
            tt.save(buf)
            raw = buf.getvalue()
            _variant_tt_bytes[path] = raw
        f = ImageFont.truetype(io.BytesIO(raw), size_px)
        _variant_font_cache[key] = f
    return f


def _glyph_ink_boxes(attrs, content, font_dir, delim_targets=None):
    """Per-char ink boxes (SVG pt: [x0, y0, x1, y1], y down) for a <text>.

    Uses the real OTF outlines via BoundsPen at the declared font-size and
    baseline (anchor "ls": pen origin at x,y, font y up). A char with no
    ink (missing glyph / empty outline) yields None. Multi-char content
    advances by hmtx widths, matching the PIL raster. DISPLAY big-ops
    (data-op="v1" in the attrs) resolve the MATH .v1 variant — the SAME
    ink the PIL raster draws; unmarked (text/script) big-ops keep the cmap
    base glyph. delim_targets
    (the map from _delimiter_targets, keyed by (x, y, content)) lets a
    STRETCHED delimiter resolve its MATH size variant from the LAYOUT's
    intended height — the verifier then measures the SAME variant ink the
    PIL raster draws (variant at the declared size + shifted baseline), not
    the base glyph the SVG text declares.
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
        # Big ops draw the MATH .v1 display variant ONLY when the SVG marks
        # them data-op="v1" (DISPLAY ops — the PIL rasterizer does the
        # same), so the verifier measures the SAME ink the raster draws:
        # the variant's outline and hmtx advance, at the declared font-size.
        # Unmarked (text/script) big-ops keep the cmap base glyph (the
        # raster draws the base glyph for them too).
        if (len(ch) == 1 and ord(ch) in BIGOP_PUA
                and _display_bigop(attrs)):
            vname = _bigop_variant_glyph(font, ord(ch))
            if vname:
                gname = vname
        # Radical variants: when the SVG marks data-radical="vN" the verifier
        # measures the MATH vertical variant (radical.vN) — the SAME glyph
        # the PIL raster draws — not the base √ the browser renders. The
        # variant draws at the declared font-size (same as the SVG says), so
        # scale_ch stays `scale`.
        elif (len(ch) == 1 and ord(ch) in RADICAL_CPS
                and attrs.get("data-radical")):
            vi = int(attrs["data-radical"][1:])
            vname = f"radical.v{vi}"
            if vname in font.getGlyphOrder():
                gname = vname
        scale_ch, shift = scale, 0.0
        if len(ch) == 1 and ord(ch) in DELIMITER_CPS and delim_targets:
            # Stretched delimiter: the raster draws the MATH size variant at
            # the resolved size with a shifted baseline — measure that ink.
            spec = delim_targets.get((ex, ey, ch))
            if spec is not None:
                res = _delimiter_resolution(path, ord(ch), size, spec)
                if res is not None:
                    _pua, gname, size_v, shift = res
                    scale_ch = size_v / font["head"].unitsPerEm
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
        boxes.append((cx + xmin * scale_ch, ey + shift - ymax * scale_ch,
                      cx + xmax * scale_ch, ey + shift - ymin * scale_ch))
        cx += font["hmtx"][gname][0] * scale_ch
    return boxes


def _union(boxes):
    """Union of non-None boxes (pt), or None if there are none."""
    real = [b for b in boxes if b]
    if not real:
        return None
    return (min(b[0] for b in real), min(b[1] for b in real),
            max(b[2] for b in real), max(b[3] for b in real))


def _svg_geometry_elements(svg_path, font_dir):
    """Parse a ztex SVG into geometry primitives (all coords in SVG pt, y down).

    Returns (w_pt, h_pt, texts, rects, lines, delim_targets, delim_spans):
      texts: [{"content", "x", "y", "size", "font_name", "boxes": [pt box|None per char], "box": union|None}]
      rects: [{"box": [...], "background": bool}]   # background = fills the canvas
      lines: [{"box": [...]}]                       # stroked decorations, stroke-width included
      delim_targets / delim_spans: the stretched-delimiter map + spans from
      _delimiter_targets (the verifier measures the variant ink for the
      flagged delimiters, and compute_geometry excludes their intended
      wrap-around intersections with the enclosed content).
    """
    svg = Path(svg_path).read_text(errors="replace")
    w_pt, h_pt, elements = _parse_svg_primitives(svg)
    texts, rects, lines = [], [], []
    texts_raw = []
    for kind, a, content in elements:
        if kind == "text":
            texts_raw.append((a, content))
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
    # Base math size + stretched-delimiter map (same rules as rasterize_svg,
    # so the verifier measures the SAME variant ink the PIL raster draws).
    base_size = _base_math_size(elements)
    delim_targets, delim_spans = _delimiter_targets(
        elements, w_pt, h_pt, font_dir, base_size)
    for a, content in texts_raw:
        boxes = _glyph_ink_boxes(a, content, font_dir, delim_targets)
        texts.append({
            "content": content, "x": _pt(a.get("x", "0")), "y": _pt(a.get("y", "0")),
            "size": _pt(a.get("font-size", "0")), "font_name": _lm_font_name(a),
            "boxes": boxes, "box": _union(boxes),
        })
    return w_pt, h_pt, texts, rects, lines, delim_targets, delim_spans


def _cluster_rows(texts):
    """Group text elements into rows by baseline y (tolerance ROW_BASELINE_TOL_PT).

    Returns rows sorted top→bottom, each {"baseline", "items": [...], "box": union|None}.
    """
    rows = []
    for t in sorted(texts, key=lambda t: t["y"]):
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
                  and t["content"].isalpha()):
                run = [t]
                j = i + 1
                while j < len(items):
                    u = items[j]
                    if (u["font_name"] != LM_MATH_FONT and len(u["content"]) == 1
                            and u["content"].isalpha()):
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
    center (the base glyph's hmtx advance / 2 from its declared x) ±
    delta/2, where delta = the glyph's MATH-table italic correction at the
    declared size (TeX make_op: over-limit +delta/2, under-limit −delta/2;
    LM ∫/∮ 0.332em, all other big-ops 0). A limit-op WORD (\\lim etc.) also
    uses delta 0 but its ink center already equals its box center, so the
    caller falls back to the old ink-center check. Returns (box_cx,
    stagger_pt) or None when the geometry is unavailable.
    """
    if op.get("kind") != "bigop":
        return None
    t = op["elements"][0]
    cp = ord(t["content"])
    if cp not in BIGOP_PUA:
        return None
    path = find_lm_font(t["font_name"], font_dir)
    if not path:
        return None
    font = _tt_font(path)
    gname = _tt_cmap(path).get(cp)
    if gname is None:
        return None
    upem = font["head"].unitsPerEm
    box_cx = t["x"] + font["hmtx"][gname][0] * t["size"] / upem / 2.0
    return box_cx, _math_italic_correction(font, gname) * t["size"] / 2.0


def compute_geometry(svg_path, font_dir=DEFAULT_FONT_DIR):
    """Deterministic geometric ground truth for one ztex SVG, in pt.

    Every ink box comes from the real Latin Modern OTF outlines at the
    declared font-size/baseline — identical geometry to the PIL raster.
    Returns a JSON-safe dict; "defect_count" is the authoritative verdict.
    """
    w_pt, h_pt, texts, rects, lines, delim_targets, delim_spans = _svg_geometry_elements(svg_path, font_dir)
    rows = _cluster_rows(texts)
    bars = [r for r in rects if not r["background"]]
    ops = _associate_limits(_find_operators(rows), rows, bars)

    # ── ink bbox: every char box + non-background rect + line ──────────────
    ink_boxes = [b for t in texts for b in t["boxes"] if b]
    ink_boxes += [r["box"] for r in bars] + [ln["box"] for ln in lines]
    ink_bbox = _union(ink_boxes)

    # ── edge clipping: max ink overflow past [0,w]x[0,h] per edge ──────────
    clip_pt = {"top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0}
    clipped = []
    for t in texts:
        for ch, b in zip(t["content"], t["boxes"]):
            if not b:
                continue
            over = {"top": -b[1], "bottom": b[3] - h_pt, "left": -b[0], "right": b[2] - w_pt}
            bad = {e: v for e, v in over.items() if v > CLIP_EPS_PT}
            for edge, v in bad.items():
                if v > clip_pt[edge]:
                    clip_pt[edge] = v
            if bad:
                clipped.append({"element": f"{ch}@{t['x']:.1f},{t['y']:.1f}",
                                "edges": sorted(bad),
                                "overflow_pt": {e: round(bad[e], 3) for e in sorted(bad)}})
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
    # each limit against the op's BOX center (base-glyph advance / 2) plus
    # the expected stagger; a limit-op word (\lim etc.) has delta 0 and
    # keeps the old ink-center check.
    bigop_limits, operators = [], []
    for op in ops:
        limits = op.get("limits", {})
        operators.append({"label": op["label"], "has_limits": bool(limits)})
        box_cx, stagger = _limit_stagger(op, font_dir)
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
    boxes = []
    for ti, t in enumerate(texts):
        for ch, b in zip(t["content"], t["boxes"]):
            boxes.append({"id": ("text", id(t)), "label": ch, "box": b})
    for ri, r in enumerate(bars):
        boxes.append({"id": ("rect", ri), "label": "fraction bar", "box": r["box"]})
    for li, ln in enumerate(lines):
        boxes.append({"id": ("line", li), "label": "line", "box": ln["box"]})
    # intended overlaps: a limit touching its operator, a radical over its
    # radicand, and a big op's own attached BESIDE scripts. TeX attaches a
    # nolimits op's scripts at variant_advance −/+ its italic correction,
    # which for the ∫/∮ .v1 lands INSIDE the variant ink bbox (sub at 0.408em,
    # ink ends at 0.943em) — the XeTeX reference render has exactly this
    # ∫↔sub bbox intersection (measured on the ref raster), so op↔own-script
    # bbox intersections are intended adjacency, not defects. A script is the
    # op's own when it is script-sized (< op size, so beside scripts and never
    # the full-size following term), horizontally overlapping the op's ink
    # span, and vertically adjacent to the op's ink box.
    excluded_ids = set()
    excluded_reason = {}
    for op in ops:
        op_ids = {("text", id(t)) for t in op["elements"]}
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
                        pair = frozenset((a, ("text", id(t))))
                        excluded_ids.add(pair)
                        excluded_reason[pair] = "op's attached beside script"
        for side in ("above", "below"):
            lim = op.get("limits", {}).get(side)
            if not lim:
                continue
            lim_ids = {("text", id(t)) for t in lim["items"]}
            for a in op_ids:
                for b in lim_ids:
                    pair = frozenset((a, b))
                    excluded_ids.add(pair)
                    excluded_reason[pair] = "limit touching its operator"
    # A STRETCHED delimiter legitimately WRAPS its enclosed content: the
    # variant ink surrounds the content and may graze it (the LM variant
    # glyphs' ink is wider than the content span — measured sub-0.5pt
    # slivers on `\lfloor \frac{1}{2} \rfloor`, present in the XeTeX
    # reference render too), so delimiter↔enclosed-content intersections
    # are intended adjacency, like a radical over its radicand.
    delim_ids = {}
    for t in texts:
        if len(t["content"]) == 1 and (t["x"], t["y"], t["content"]) in delim_targets:
            delim_ids[(t["x"], t["y"], t["content"])] = ("text", id(t))
    for sp in delim_spans:
        oid, cid = delim_ids.get(sp["open"]), delim_ids.get(sp["close"])
        if not oid or not cid:
            continue
        lo, hi = sp["lo"], sp["hi"]
        enclosed = set()
        for t in texts:
            tid = ("text", id(t))
            if tid in (oid, cid):
                continue
            if any(b and lo < (b[0] + b[2]) / 2.0 < hi for b in t["boxes"]):
                enclosed.add(tid)
        for ri, r in enumerate(bars):
            if lo < (r["box"][0] + r["box"][2]) / 2.0 < hi:
                enclosed.add(("rect", ri))
        for li, ln in enumerate(lines):
            if lo < (ln["box"][0] + ln["box"][2]) / 2.0 < hi:
                enclosed.add(("line", li))
        for did in (oid, cid):
            for eid in enclosed:
                pair = frozenset((did, eid))
                excluded_ids.add(pair)
                excluded_reason[pair] = "delimiter wrapping its content"
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
                acx = (A["box"][0] + A["box"][2]) / 2.0
                bcx = (B["box"][0] + B["box"][2]) / 2.0
                if (A["label"] == "√" and bcx > acx) or (B["label"] == "√" and acx > bcx):
                    reason = "radical over its radicand"
            smaller = min((ax1 - ax0) * (ay1 - ay0), (bx1 - bx0) * (by1 - by0))
            overlaps.append({
                "a": A["label"], "b": B["label"], "area_pt2": round(area, 3),
                "pct_of_smaller": round(100.0 * area / smaller, 2) if smaller > 0 else 0.0,
                "excluded": reason is not None, "reason": reason,
            })
    overlaps.sort(key=lambda o: -o["area_pt2"])

    # ── glyph completeness: chars that render nothing ──────────────────────
    empty_glyphs = [{"element": f"{ch}@{t['x']:.1f},{t['y']:.1f}", "char": ch}
                    for t in texts for ch, b in zip(t["content"], t["boxes"]) if b is None]

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
        "glyph_count": sum(len(t["boxes"]) for t in texts),
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
