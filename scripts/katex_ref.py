#!/usr/bin/env python3
"""KaTeX reference renderer for ztex's --ref comparison images.

Pipeline (see notes/katex-reference.md for the full writeup):

  1. formula  --(katex CLI, nix-installed)-->  HTML span tree
  2. HTML     --(CSS/box model, see below)-->  per-glyph geometry (x, y, size, font)
  3. fonts    --(fontTools woff2 -> ttf)-->    PIL draws each glyph with the
                                               KaTeX font KaTeX assigned
  4. rules / SVG paths (sqrt surd, braces, arrows) are drawn as primitives

KaTeX's HTML output (dist/katex.js, 0.16.x) is a self-describing layout DSL:

  * The .katex span is the root; its base font-size is 1.21em of the wrapper.
    Every em value in the HTML is relative to this base (we choose the base
    = the requested pt size, so 1em = size_pt exactly).
  * .katex-html contains one .base per unbreakable chunk; inline-block bases
    share ONE line baseline B (all .base baselines coincide).
  * A .vlist-t (inline-table) stacks children. Rows: [.vlist main cell,
    .vlist-s ZWSP strut cell], plus a second row (depth strut) when the list
    has depth (.vlist-t2). The ROW baseline is the baseline of the ZWSP text
    at font-size 1px; the main cell top therefore sits ~0.9px below the line
    baseline (1px-font metrics of KaTeX_Main, half-leading included).
  * Each vlist child is <span style="top:-Xem"> containing a .pstrut of
    explicit height P and the content. The child's line baseline is
    (top + P) em below the cell top, i.e. the pstrut bottom pins the
    baseline exactly (KaTeX's strut trick: an empty inline-block's baseline
    is its bottom edge).
  * Glyph spans carry classes that map to font faces (katex.css):
    mathnormal -> KaTeX_Math, op-symbol small-op -> KaTeX_Size1,
    large-op -> KaTeX_Size2, delimsizing.sizeN -> KaTeX_SizeN, and the
    default (mord/mbin/mrel/...) -> KaTeX_Main. Sizing classes
    (reset-sizeN.sizeM) scale font-size by the katex.css size table.
  * Rules (.frac-line, .overline-line, .rule), glues (.mspace margins),
    italic corrections (margin-right on glyph spans), accent offsets
    (left/top styles), and stretchy SVG paths (sqrt, braces, arrows) are
    all explicit em styles on the spans.

The rasterizer replays this model in pt at 96 dpi (1pt = 4/3 px), exactly
like the ztex PIL rasterizer, with 2x supersampling for consistent glyph
edges. The KaTeX .woff2 fonts are converted to .ttf once with fontTools
(cached under XDG_CACHE_HOME/ztex-katex) and PIL draws every glyph with the
font KaTeX chose.

Runtime deps: PIL, fontTools, brotli, and the nix-installed `katex` CLI.
No Zig, no browser.

Usage (module):
    import katex_ref
    png, cmd, desc = katex_ref.render_katex_ref(formula, workdir, size_pt)
"""

import base64
from html.parser import HTMLParser as _HTMLParser
import json
import math
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from fontTools.pens.boundsPen import BoundsPen
from fontTools.ttLib import TTFont

PT_TO_PX = 96.0 / 72.0
SUPERSAMPLE = 2

# ----------------------------------------------------------------------------
# KaTeX install discovery: `katex` on PATH lives in a nix store dir that also
# carries dist/fonts/*.woff2 and dist/katex.js.
# ----------------------------------------------------------------------------
def katex_store_dir():
    exe = shutil.which("katex")
    if not exe:
        raise FileNotFoundError(
            "katex not on PATH. Install it with: nix profile install nixpkgs#katex")
    p = Path(exe).resolve()
    for cand in (p.parent.parent, p.parent.parent.parent):
        if (cand / "lib").exists():
            return cand
    return p.parent.parent


def katex_fonts_dir():
    store = katex_store_dir()
    for c in (store / "lib/node_modules/katex/dist/fonts",
              store / "lib/node_modules/katex/fonts",
              store / "share/katex/fonts"):
        if c.is_dir():
            return str(c)
    raise FileNotFoundError(f"KaTeX fonts not found under {store}")


def katex_version():
    return subprocess.run(["katex", "--version"], capture_output=True, text=True).stdout.strip() or "?"


# ----------------------------------------------------------------------------
# font conversion: woff2 -> ttf (cached), glyph metrics
# ----------------------------------------------------------------------------
_FONT_CACHE_DIR = None


def _font_cache_dir():
    global _FONT_CACHE_DIR
    if _FONT_CACHE_DIR is None:
        base = os.environ.get("XDG_CACHE_HOME",
                              os.path.join(os.path.expanduser("~"), ".cache"))
        _FONT_CACHE_DIR = os.path.join(base, "ztex-katex", "fonts")
        os.makedirs(_FONT_CACHE_DIR, exist_ok=True)
    return _FONT_CACHE_DIR


def ttf_path(woff2_name):
    """Convert one KaTeX .woff2 to a .ttf (cached) and return its path."""
    src = os.path.join(katex_fonts_dir(), woff2_name)
    dst = os.path.join(_font_cache_dir(), woff2_name.replace(".woff2", ".ttf"))
    if not os.path.exists(dst) or os.path.getmtime(dst) < os.path.getmtime(src):
        f = TTFont(src)
        f.flavor = None
        f.save(dst)
    return dst


_FACE_TTF = {}


def face_ttf(face):
    """Absolute ttf for a KaTeX font face name (e.g. 'KaTeX_Main-Regular')."""
    if face not in _FACE_TTF:
        _FACE_TTF[face] = ttf_path(face + ".woff2")
    return _FACE_TTF[face]


def convert_all_fonts():
    return [ttf_path(fn) for fn in sorted(os.listdir(katex_fonts_dir()))
            if fn.endswith(".woff2")]


# ----------------------------------------------------------------------------
# font-face selection (class -> KaTeX face), katex.css rules
# ----------------------------------------------------------------------------
_SIZING_MULT = {1: 1.0, 2: 1.2, 3: 1.4, 4: 1.6, 5: 1.8, 6: 2.0,
                7: 2.4, 8: 2.88, 9: 3.456, 10: 4.148, 11: 4.976}


def sizing_factor(classes):
    m = re.search(r"reset-size(\d+)", classes)
    sizes = re.findall(r"size(\d+)", classes)
    if m and sizes:
        # sizes are listed 'reset-size6 size3': the LAST sizeN is the target
        return _SIZING_MULT[int(sizes[-1])] / _SIZING_MULT[int(m.group(1))]
    return 1.0


def font_face(classes):
    """KaTeX face (woff2 stem) for a glyph span's classes."""
    if "boldsymbol" in classes:
        return "KaTeX_Math-BoldItalic"
    if "mathnormal" in classes or "mathitsf" in classes or "mathsfit" in classes:
        return "KaTeX_Math-Italic"
    if "mathbf" in classes or "textbf" in classes:
        return "KaTeX_Main-Bold"
    if "textit" in classes and "textsf" in classes:
        return "KaTeX_SansSerif-Italic"
    if "textit" in classes:
        return "KaTeX_Main-Italic"
    if "texttt" in classes or "mathtt" in classes:
        return "KaTeX_Typewriter-Regular"
    if "mathbb" in classes or "amsrm" in classes or "textbb" in classes:
        return "KaTeX_AMS-Regular"
    if "mathcal" in classes or "textcal" in classes:
        return "KaTeX_Caligraphic-Regular"
    if "mathfrak" in classes or "textfrak" in classes:
        return "KaTeX_Fraktur-Regular"
    if "mathscr" in classes or "textscr" in classes:
        return "KaTeX_Script-Regular"
    if "mathsf" in classes or "textsf" in classes:
        return "KaTeX_SansSerif-Regular"
    if "op-symbol" in classes:
        return "KaTeX_Size2-Regular" if "large-op" in classes else "KaTeX_Size1-Regular"
    if "delimsizing" in classes:
        m = re.search(r"delimsizing size(\d)", classes)
        return f"KaTeX_Size{m.group(1)}-Regular" if m else "KaTeX_Size1-Regular"
    if "delimsizinginner" in classes:
        m = re.search(r"size(\d)", classes)
        return f"KaTeX_Size{m.group(1)}-Regular" if m else "KaTeX_Size1-Regular"
    m = re.search(r"delim-size(\d)", classes)
    if m:
        return f"KaTeX_Size{m.group(1)}-Regular"
    return "KaTeX_Main-Regular"


# ----------------------------------------------------------------------------
# HTML parsing
# ----------------------------------------------------------------------------
class El:
    __slots__ = ("tag", "cls", "style", "attrs", "text", "children")

    def __init__(self, tag, cls, style, attrs):
        self.tag = tag
        self.cls = cls
        self.style = style
        self.attrs = attrs
        self.text = ""
        self.children = []


_STYLE_RE = re.compile(r"([a-zA-Z-]+)\s*:\s*([^;]+)")


def _parse_style(s):
    return {k: v.strip() for k, v in _STYLE_RE.findall(s or "")}


class _TreeBuilder(_HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = None
        self.stack = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        el = El(tag, a.get("class", ""), _parse_style(a.get("style", "")), a)
        if self.stack:
            self.stack[-1].children.append(el)
        else:
            self.root = el
        self.stack.append(el)

    def handle_startendtag(self, tag, attrs):
        a = dict(attrs)
        el = El(tag, a.get("class", ""), _parse_style(a.get("style", "")), a)
        if self.stack:
            self.stack[-1].children.append(el)
        else:
            self.root = el

    def handle_endtag(self, tag):
        if self.stack:
            self.stack.pop()

    def handle_data(self, data):
        if self.stack and data:
            self.stack[-1].text += data


def _postprocess(el):
    """Tree-wide fixes that need parent info (CSS descendant rules)."""
    for c in el.children:
        if "root" in c.cls and "sqrt" in el.cls:
            # .sqrt > .root { margin-left: 0.2777777778em; margin-right: -0.5555555556em }
            c.style.setdefault("margin-left", "0.2777777778em")
            c.style.setdefault("margin-right", "-0.5555555556em")
        _postprocess(c)


def parse_html(html_text):
    p = _TreeBuilder()
    p.feed(html_text)
    p.close()
    if p.root is None:
        raise ValueError("no HTML parsed from katex output")
    _postprocess(p.root)
    return p.root


def find_html_subtree(root):
    """Return the .katex-html element (or root if not found)."""
    stack = [root]
    while stack:
        el = stack.pop()
        if "katex-html" in el.cls:
            return el
        stack.extend(el.children)
    return root


# ----------------------------------------------------------------------------
# glyph metrics (from the converted KaTeX fonts)
# ----------------------------------------------------------------------------
_GLYPH_CACHE = {}  # ttf -> {cp: (adv_em, ink_bbox_em)}


def _glyph_data(ttf):
    if ttf in _GLYPH_CACHE:
        return _GLYPH_CACHE[ttf]
    f = TTFont(ttf)
    gs = f.getGlyphSet()
    upem = f["head"].unitsPerEm
    hmtx = f["hmtx"]
    data = {}
    for cp, gname in f.getBestCmap().items():
        adv = hmtx[gname][0] / upem
        pen = BoundsPen(gs)
        try:
            gs[gname].draw(pen)
        except Exception:
            continue
        if pen.bounds is None:
            continue
        x0, y0, x1, y1 = (v / upem for v in pen.bounds)
        data[cp] = (adv, (x0, y0, x1, y1))
    # KaTeX fonts carry no space glyph; the browser uses the fallback font's
    # space advance (0.25em in Times). Give spaces that metric, no ink.
    for cp in (0x20, 0xA0):
        if cp not in data:
            data[cp] = (0.25, None)
    _GLYPH_CACHE[ttf] = data
    return data


def _advance(ttf, text, em_pt):
    data = _glyph_data(ttf)
    return sum((data.get(ord(ch), (0.0, None))[0] for ch in text)) * em_pt


def _ink_box(ttf, ch, em_pt, x, baseline):
    d = _glyph_data(ttf).get(ord(ch))
    if not d or d[1] is None:
        return None
    x0, y0, x1, y1 = d[1]
    return (x + x0 * em_pt, baseline - y1 * em_pt,
            x + x1 * em_pt, baseline - y0 * em_pt)


_FONT_VMETRICS = {}


def _vmetrics(ttf):
    if ttf not in _FONT_VMETRICS:
        f = TTFont(ttf)
        upem = f["head"].unitsPerEm
        _FONT_VMETRICS[ttf] = (f["hhea"].ascent / upem, -f["hhea"].descent / upem)
    return _FONT_VMETRICS[ttf]


def _vlist_baseline_offset_pt():
    """Row-baseline to cell-bottom offset in pt (0.1875px, measured).

    The vlist cell aligns bottom to the row; the row's baseline (the
    vlist-s ZWSP strut line at font-size 1px) sits ~0.1875px above the row
    bottom. Verified empirically in Chromium 151 against real KaTeX HTML
    (constant across sizes: the ZWSP is always 1px). This is the anchor for
    every vlist child: child baseline = cell_bottom + (top + pstrut) em.
    """
    return 0.1875 / PT_TO_PX


# ----------------------------------------------------------------------------
# layout
# ----------------------------------------------------------------------------
class Prim:
    __slots__ = ("kind", "kw")

    def __init__(self, kind, **kw):
        self.kind = kind
        self.kw = kw

    def to_json(self):
        d = {"kind": self.kind}
        for k, v in self.kw.items():
            d[k] = round(v, 4) if isinstance(v, float) else v
        return d


class Layout:
    def __init__(self):
        self.prims = []
        self.x0 = self.y0 = self.x1 = self.y1 = None

    def add(self, prim):
        self.prims.append(prim)

    def include_box(self, x0, y0, x1, y1):
        if self.x0 is None:
            self.x0, self.y0, self.x1, self.y1 = x0, y0, x1, y1
        else:
            self.x0, self.y0 = min(self.x0, x0), min(self.y0, y0)
            self.x1, self.y1 = max(self.x1, x1), max(self.y1, y1)

    def ink_bbox(self):
        if self.x0 is None:
            return [0.0, 0.0, 0.0, 0.0]
        return [round(self.x0, 3), round(self.y0, 3),
                round(self.x1, 3), round(self.y1, 3)]


class Ctx:
    """Layout context. base_pt: 1em in pt; B: line baseline (canvas y, pt);
    mult: font-size multiplier; cell_x/cell_w: enclosing vlist cell (pt),
    used by full-width rules (.frac-line etc.) and stretchy SVGs."""
    __slots__ = ("base_pt", "B", "mult", "cell_x", "cell_w")

    def __init__(self, base_pt, B, mult=1.0, cell_x=None, cell_w=None):
        self.base_pt = base_pt
        self.B = B
        self.mult = mult
        self.cell_x = cell_x
        self.cell_w = cell_w


def _em(ctx, v):
    return v * ctx.base_pt * ctx.mult


def _css_margins(el, ctx):
    ml = mr = 0.0
    for k in ("margin-left", "margin-right"):
        v = el.style.get(k)
        if v is not None:
            val = _em(ctx, float(v.rstrip("em")))
            if k == "margin-left":
                ml += val
            else:
                mr += val
    return ml, mr


def _padding(el, ctx):
    pl = pr = 0.0
    for k in ("padding-left", "padding-right"):
        v = el.style.get(k)
        if v is not None:
            val = _em(ctx, float(v.rstrip("em")))
            if k == "padding-left":
                pl += val
            else:
                pr += val
    return pl, pr


def _text_align(el):
    if any(k in el.cls for k in ("op-limits", "mfrac", "accent", "x-arrow",
                                 "mover", "munder", "col-align-c")):
        return "center"
    if "col-align-r" in el.cls:
        return "right"
    return "left"


def _rel_shift(el, ctx):
    """(dx, dy) pt from position:relative left/right/top/bottom styles."""
    dx = dy = 0.0
    if "left" in el.style:
        dx += _em(ctx, float(el.style["left"].rstrip("em")))
    if "right" in el.style:
        dx -= _em(ctx, float(el.style["right"].rstrip("em")))
    if "top" in el.style:
        dy -= _em(ctx, float(el.style["top"].rstrip("em")))
    if "bottom" in el.style:
        dy += _em(ctx, float(el.style["bottom"].rstrip("em")))
    return dx, dy


# ---- inline flow ------------------------------------------------------------
def _inline_width(layout, el, ctx):
    """Width (pt) an element contributes to an inline flow."""
    cls = el.cls
    ml, mr = _css_margins(el, ctx)
    if el.text and el.text.strip("\u200b"):
        ttf = face_ttf(font_face(cls))
        return ml + _advance(ttf, el.text, _em(ctx, 1.0)) + mr
    if "vlist-t" in cls or "vlist-t2" in cls:
        return ml + _vlist_width(layout, el, ctx) + mr
    if "mspace" in cls:
        return ml + mr
    if "nulldelimiter" in cls:
        return ml + _em(ctx, 0.12) + mr
    if "rule" in cls:
        w = _em(ctx, float(el.style.get("border-right-width", "0").rstrip("em")))
        return ml + w + mr
    if "hide-tail" in cls or "stretchy" in cls:
        # width:100% -> fills the vlist cell; only the min-width floors it
        minw = _em(ctx, float(el.style.get("min-width", "0").rstrip("em")))
        return ml + minw + mr
    if "accent-body" in cls:
        return ml + mr  # width: 0 in katex.css
    if "strut" in cls or "pstrut" in cls or "vlist-s" in cls:
        return 0.0
    pl, pr = _padding(el, ctx)
    w = 0.0
    for c in el.children:
        w += _inline_width(layout, c, _ctx_with(el, ctx))
    return ml + pl + w + pr + mr


def _ctx_with(el, ctx):
    """Child context: apply the element's sizing multiplier."""
    f = sizing_factor(el.cls)
    if f == 1.0:
        return ctx
    return Ctx(ctx.base_pt, ctx.B, ctx.mult * f, ctx.cell_x, ctx.cell_w)


def _vlist_width(layout, el, ctx):
    """Width (pt) of a .vlist-t: the main cell's content width."""
    cell = _vlist_main_cell(el)
    if cell is None:
        return 0.0
    w = 0.0
    for wrap in cell.children:
        if wrap.tag != "span" or "pstrut" in wrap.cls:
            continue
        ml = mr = 0.0
        if "margin-left" in wrap.style:
            ml = _em(ctx, float(wrap.style["margin-left"].rstrip("em")))
        if "margin-right" in wrap.style:
            mr = _em(ctx, float(wrap.style["margin-right"].rstrip("em")))
        inner = [c for c in wrap.children if "pstrut" not in c.cls]
        subctx = Ctx(ctx.base_pt, ctx.B, ctx.mult, ctx.cell_x, ctx.cell_w)
        cw = 0.0
        for c in inner:
            cw += _inline_width(layout, c, subctx)
        w = max(w, ml + cw + mr)
    return w


def _vlist_main_cell(el):
    for row in el.children:
        if "vlist-r" not in row.cls:
            continue
        for cell in row.children:
            if "vlist" in cell.cls and "vlist-s" not in cell.cls:
                return cell
    return None


def _wrap_pstrut_em(wrap):
    """Raw em height of the wrap's .pstrut (converted by the caller)."""
    for c in wrap.children:
        if "pstrut" in c.cls:
            return float(c.style.get("height", "0").rstrip("em"))
    return 0.0


def _emit_inline(layout, els, ctx, x):
    """Emit primitives for an inline flow starting at x; returns advance."""
    total = 0.0
    for el in els:
        total += _emit_one(layout, el, ctx, x + total)
    return total


def _emit_one(layout, el, ctx, x, parent=None):
    """Emit one element; returns its advance width (pt)."""
    cls = el.cls
    ml, mr = _css_margins(el, ctx)
    pl, pr = _padding(el, ctx)
    dx, dy = _rel_shift(el, ctx)
    subctx = _ctx_with(el, ctx)
    ex = x + ml + pl + dx

    if el.text and el.text.strip("\u200b"):
        face = font_face(cls)
        ttf = face_ttf(face)
        em = _em(subctx, 1.0)
        baseline = ctx.B + dy
        adv = 0.0
        for ch in el.text:
            if ch == "\u200b":
                continue
            box = _ink_box(ttf, ch, em, ex, baseline)
            if box:
                layout.include_box(*box)
        layout.add(Prim("text", x=ex, y=baseline, size=em, text=el.text, font=face))
        return ml + pl + _advance(ttf, el.text, em) + pr + mr
    if "vlist-t" in cls or "vlist-t2" in cls:
        return ml + pl + _emit_vlist(layout, el, subctx, ex, ctx.B + dy, parent) + pr + mr
    if "mspace" in cls:
        return ml + pl + pr + mr
    if "nulldelimiter" in cls:
        return ml + pl + _em(subctx, 0.12) + pr + mr
    if "rule" in cls:
        w = _em(subctx, float(el.style.get("border-right-width", "0").rstrip("em")))
        h = _em(subctx, float(el.style.get("border-top-width", "0").rstrip("em")))
        ry = ctx.B + dy - h  # rule sits ON the baseline (bottom at baseline)
        layout.include_box(ex, ry, ex + w, ctx.B + dy)
        layout.add(Prim("rect", x=ex, y=ry, w=w, h=h))
        return ml + pl + w + pr + mr
    if "frac-line" in cls or "overline-line" in cls or "underline-line" in cls or "hline" in cls:
        # full-width rule: bottom edge at the line baseline
        h = _em(subctx, float(el.style.get("border-bottom-width", "0.04").rstrip("em")))
        w = ctx.cell_w if ctx.cell_w else 0.0
        rx = ctx.cell_x if ctx.cell_x is not None else ex
        layout.include_box(rx, ctx.B + dy - h, rx + w, ctx.B + dy)
        layout.add(Prim("rect", x=rx, y=ctx.B + dy - h, w=w, h=h))
        return ml + pl + w + pr + mr
    if "accent-body" in cls:
        for c in el.children:
            _emit_one(layout, c, subctx, ex)
        return ml + pl + pr + mr  # width 0
    if "hide-tail" in cls:
        # .hide-tail { width: 100% } of its block wrap -> the vlist CELL
        # width (min-width is only a floor); the surd's overline bar
        # subpath extends across this whole box.
        h = _em(subctx, float(el.style.get("height", "0").rstrip("em")))
        minw = _em(subctx, float(el.style.get("min-width", "0").rstrip("em")))
        w = max(minw, ctx.cell_w or 0.0)
        return _emit_svg_container(layout, el, subctx, ex, ctx.B + dy, w, h)
    if "stretchy" in cls:
        # .stretchy { width: 100% } of the cell (braces/arrows stretch).
        h = _em(subctx, float(el.style.get("height", "0").rstrip("em")))
        minw = _em(subctx, float(el.style.get("min-width", "0").rstrip("em")))
        w = max(minw, ctx.cell_w or 0.0)
        return _emit_svg_container(layout, el, subctx, ex, ctx.B + dy, w, h)
    if "strut" in cls or "pstrut" in cls or "vlist-s" in cls:
        return 0.0
    w = 0.0
    for c in el.children:
        w += _emit_one(layout, c, subctx, ex + w, el)
    return ml + pl + w + pr + mr


def _emit_svg_container(layout, el, ctx, x, baseline, box_w, box_h):
    """Emit the svg(s) inside a .hide-tail / .stretchy span.

    The container is an inline-block: its bottom edge sits on the line
    baseline; svgs fill it (position:absolute; width:100%; height:inherit),
    each clipped to its overflow window. Two window kinds (katex.css):
      * .hide-tail (sqrt surd): one svg filling the whole box.
      * .stretchy (braces/arrows): svgs inside .brace-left/.brace-center/
        .brace-right/.halfarrow-* pieces, absolutely positioned windows
        (left 0/25%, widths 25.1%/50%, etc.), each with overflow:hidden.
    Returns the advance width (the container width).
    """
    top = baseline - box_h
    for svg, win in _svg_windows(el):
        vb = svg.attrs.get("viewbox") or svg.attrs.get("viewBox") or "0 0 0 0"
        vb = vb.split()
        vw, vh = (float(vb[2]), float(vb[3])) if len(vb) == 4 else (0.0, 0.0)
        d = ""
        stack = [svg]
        while stack and not d:
            n = stack.pop()
            if n.tag == "path":
                d = n.attrs.get("d", "")
            stack.extend(n.children)
        preserve = svg.attrs.get("preserveaspectratio") or svg.attrs.get("preserveAspectRatio") or ""
        if not d or vw <= 0 or vh <= 0:
            continue
        fx, fw = win
        wx, ww = fx * box_w, fw * box_w
        layout.add(Prim("svg", x=x + wx, y=top, w=ww, h=box_h,
                        d=base64.b64encode(d.encode()).decode(),
                        vb=[vw, vh], preserve=preserve))
        _svg_ink(layout, d, vw, vh, ww, box_h, preserve, x + wx, top)
    return box_w


def _svg_windows(el):
    """Yield (svg_el, (window_x, window_w)) pairs for a container's svgs."""
    out = []
    stack = [(el, None)]
    while stack:
        node, piece_cls = stack.pop()
        for c in node.children:
            cls = c.cls
            pc = None
            for k in ("brace-left", "brace-center", "brace-right",
                      "halfarrow-left", "halfarrow-right"):
                if k in cls:
                    pc = k
                    break
            if c.tag == "svg":
                out.append((c, (0.0, 1.0) if piece_cls is None else _piece_rect(piece_cls)))
            else:
                stack.append((c, pc or piece_cls))
    return out


def _piece_rect(piece_cls):
    """(window_x_fraction, window_w_fraction) of a stretchy piece (katex.css)."""
    return {
        "brace-left": (0.0, 0.251),
        "brace-center": (0.25, 0.5),
        "brace-right": (0.749, 0.251),
        "halfarrow-left": (0.0, 0.502),
        "halfarrow-right": (0.498, 0.502),
    }[piece_cls]


def _svg_ink(layout, d, vw, vh, box_w, box_h, preserve, x, y):
    polys = _svg_to_polys(d, vw, vh, box_w, box_h, preserve)
    for poly in polys:
        xs = [p[0] + x for p in poly]
        ys = [p[1] + y for p in poly]
        layout.include_box(min(xs), min(ys), max(xs), max(ys))


# ---- vlists -----------------------------------------------------------------
def _emit_vlist(layout, el, ctx, x, baseline, parent=None):
    """Emit a .vlist-t; returns its advance width. baseline = line baseline.

    text-align comes from the PARENT (CSS: .op-limits > .vlist-t, .mfrac
    > .vlist-t, .accent > .vlist-t are centered; msupsub is left).
    """
    cell = _vlist_main_cell(el)
    if cell is None:
        return 0.0
    # KaTeX vlist geometry (measured against Chromium): the main cell's
    # BOTTOM sits ~0.1875px below the line baseline, and every child wrap's
    # line baseline = cell_bottom + (wrap.top + pstrut.height) em.
    cell_bottom = baseline + _vlist_baseline_offset_pt()
    align = _text_align(parent or el)
    # measure wraps
    wraps = [w for w in cell.children if w.tag == "span"]
    widths = []
    for wrap in wraps:
        ml = _em(ctx, float(wrap.style.get("margin-left", "0").rstrip("em")))
        mr = _em(ctx, float(wrap.style.get("margin-right", "0").rstrip("em")))
        top_em = float(wrap.style.get("top", "0").rstrip("em"))
        pstrut = _wrap_pstrut_em(wrap)
        lb = cell_bottom + (top_em + pstrut) * ctx.base_pt * ctx.mult
        subctx = Ctx(ctx.base_pt, lb, ctx.mult, None, None)
        cw = 0.0
        for c in wrap.children:
            if "pstrut" in c.cls:
                continue
            cw += _inline_width(layout, c, subctx)
        widths.append(ml + cw + mr)
    cell_w = max(widths) if widths else 0.0
    # emit
    for wrap, w in zip(wraps, widths):
        if "pstrut" in wrap.cls:
            continue
        ml = _em(ctx, float(wrap.style.get("margin-left", "0").rstrip("em")))
        mr = _em(ctx, float(wrap.style.get("margin-right", "0").rstrip("em")))
        top_em = float(wrap.style.get("top", "0").rstrip("em"))
        pstrut = _wrap_pstrut_em(wrap)
        lb = cell_bottom + (top_em + pstrut) * ctx.base_pt * ctx.mult
        full_width = any(("stretchy" in c.cls or "hide-tail" in c.cls)
                         for c in wrap.children)
        if full_width:
            # .stretchy/.hide-tail are width:100% blocks: they start at the
            # cell's LEFT edge and span the whole cell (text-align ignored).
            ix = x + ml
        elif align == "center":
            ix = x + (cell_w - w) / 2.0 + ml
        elif align == "right":
            ix = x + cell_w - w + ml
        else:
            ix = x + ml
        subctx = Ctx(ctx.base_pt, lb, ctx.mult, x, cell_w)
        acc = 0.0
        for c in wrap.children:
            if "pstrut" in c.cls:
                continue
            acc += _emit_one(layout, c, subctx, ix + acc)
    return cell_w


# ---- svg path flattening -----------------------------------------------------
_PATH_CMD = re.compile(r"([MmLlHhVvCcSsQqTtZz])|([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)")


def _flatten_svg_path(d):
    """Flatten an SVG path into polygons (list of point-lists, y-up units)."""
    tokens = []
    for m in _PATH_CMD.finditer(d):
        tokens.append((m.group(1), None) if m.group(1) else (None, float(m.group(2))))
    pos = 0
    n = len(tokens)

    def num():
        nonlocal pos
        while pos < n and tokens[pos][0] is None:
            v = tokens[pos][1]
            pos += 1
            return v
        return 0.0

    out = []
    cur = (0.0, 0.0)
    start = (0.0, 0.0)
    prev_cmd = None
    prev_ctl = None
    max_splits = 2000

    def cubic(x0, y0, x1, y1, x2, y2, x3, y3):
        pts = []
        stack = [(x0, y0, x1, y1, x2, y2, x3, y3, 0)]
        while stack:
            x0, y0, x1, y1, x2, y2, x3, y3, depth = stack.pop()
            dx, dy = x3 - x0, y3 - y0
            denom = max(1e-9, math.hypot(dx, dy))
            d1 = abs((x1 - x0) * dy - (y1 - y0) * dx) / denom
            d2 = abs((x2 - x3) * dy - (y2 - y3) * dx) / denom
            if max(d1, d2) < 0.12 or depth > max_splits:
                pts.append((x3, y3))
            else:
                ax, ay = (x0 + x1) / 2, (y0 + y1) / 2
                bx, by = (x1 + x2) / 2, (y1 + y2) / 2
                cx_, cy_ = (x2 + x3) / 2, (y2 + y3) / 2
                dx1, dy1 = (ax + bx) / 2, (ay + by) / 2
                ex, ey = (bx + cx_) / 2, (by + cy_) / 2
                fx, fy = (dx1 + ex) / 2, (dy1 + ey) / 2
                stack.append((fx, fy, ex, ey, cx_, cy_, x3, y3, depth + 1))
                stack.append((x0, y0, ax, ay, dx1, dy1, fx, fy, depth + 1))
        return pts

    def quad(x0, y0, x1, y1, x2, y2):
        pts = []
        stack = [(x0, y0, x1, y1, x2, y2, 0)]
        while stack:
            x0, y0, x1, y1, x2, y2, depth = stack.pop()
            dx, dy = x2 - x0, y2 - y0
            denom = max(1e-9, math.hypot(dx, dy))
            d = abs((x1 - x0) * dy - (y1 - y0) * dx) / denom
            if d < 0.12 or depth > max_splits:
                pts.append((x2, y2))
            else:
                ax, ay = (x0 + x1) / 2, (y0 + y1) / 2
                bx, by = (x1 + x2) / 2, (y1 + y2) / 2
                mx, my = (ax + bx) / 2, (ay + by) / 2
                stack.append((mx, my, bx, by, x2, y2, depth + 1))
                stack.append((x0, y0, ax, ay, mx, my, depth + 1))
        return pts

    while pos < n:
        tok = tokens[pos][0]
        if tok is None:
            pos += 1
            continue
        pos += 1
        if tok == "M":
            cur = start = (num(), num())
            prev_cmd, prev_ctl = "M", None
        elif tok == "m":
            cur = start = (cur[0] + num(), cur[1] + num())
            prev_cmd, prev_ctl = "M", None
        elif tok == "L":
            p2 = (num(), num())
            out.append(("L", cur, p2))
            cur = p2
            prev_cmd, prev_ctl = "L", None
        elif tok == "l":
            p2 = (cur[0] + num(), cur[1] + num())
            out.append(("L", cur, p2))
            cur = p2
            prev_cmd, prev_ctl = "L", None
        elif tok == "H":
            p2 = (num(), cur[1])
            out.append(("L", cur, p2))
            cur = p2
            prev_cmd, prev_ctl = "L", None
        elif tok == "h":
            p2 = (cur[0] + num(), cur[1])
            out.append(("L", cur, p2))
            cur = p2
            prev_cmd, prev_ctl = "L", None
        elif tok == "V":
            p2 = (cur[0], num())
            out.append(("L", cur, p2))
            cur = p2
            prev_cmd, prev_ctl = "L", None
        elif tok == "v":
            p2 = (cur[0], cur[1] + num())
            out.append(("L", cur, p2))
            cur = p2
            prev_cmd, prev_ctl = "L", None
        elif tok == "C":
            x1, y1, x2, y2, x3, y3 = num(), num(), num(), num(), num(), num()
            out.append(("C", cur, (x1, y1), (x2, y2), (x3, y3)))
            cur = (x3, y3)
            prev_cmd, prev_ctl = "C", (x2, y2)
        elif tok == "c":
            x1, y1 = cur[0] + num(), cur[1] + num()
            x2, y2 = cur[0] + num(), cur[1] + num()
            x3, y3 = cur[0] + num(), cur[1] + num()
            out.append(("C", cur, (x1, y1), (x2, y2), (x3, y3)))
            cur = (x3, y3)
            prev_cmd, prev_ctl = "C", (x2, y2)
        elif tok == "S":
            x2, y2, x3, y3 = num(), num(), num(), num()
            x1, y1 = (2 * cur[0] - prev_ctl[0], 2 * cur[1] - prev_ctl[1]) \
                if prev_cmd == "C" else cur
            out.append(("C", cur, (x1, y1), (x2, y2), (x3, y3)))
            cur = (x3, y3)
            prev_cmd, prev_ctl = "C", (x2, y2)
        elif tok == "s":
            x2, y2 = cur[0] + num(), cur[1] + num()
            x3, y3 = cur[0] + num(), cur[1] + num()
            x1, y1 = (2 * cur[0] - prev_ctl[0], 2 * cur[1] - prev_ctl[1]) \
                if prev_cmd == "C" else cur
            out.append(("C", cur, (x1, y1), (x2, y2), (x3, y3)))
            cur = (x3, y3)
            prev_cmd, prev_ctl = "C", (x2, y2)
        elif tok == "Q":
            x1, y1, x2, y2 = num(), num(), num(), num()
            out.append(("Q", cur, (x1, y1), (x2, y2)))
            cur = (x2, y2)
            prev_cmd, prev_ctl = "Q", (x1, y1)
        elif tok == "q":
            x1, y1 = cur[0] + num(), cur[1] + num()
            x2, y2 = cur[0] + num(), cur[1] + num()
            out.append(("Q", cur, (x1, y1), (x2, y2)))
            cur = (x2, y2)
            prev_cmd, prev_ctl = "Q", (x1, y1)
        elif tok == "T":
            x2, y2 = num(), num()
            x1, y1 = (2 * cur[0] - prev_ctl[0], 2 * cur[1] - prev_ctl[1]) \
                if prev_cmd == "Q" else cur
            out.append(("Q", cur, (x1, y1), (x2, y2)))
            cur = (x2, y2)
            prev_cmd, prev_ctl = "Q", (x1, y1)
        elif tok == "t":
            x2, y2 = cur[0] + num(), cur[1] + num()
            x1, y1 = (2 * cur[0] - prev_ctl[0], 2 * cur[1] - prev_ctl[1]) \
                if prev_cmd == "Q" else cur
            out.append(("Q", cur, (x1, y1), (x2, y2)))
            cur = (x2, y2)
            prev_cmd, prev_ctl = "Q", (x1, y1)
        elif tok in ("Z", "z"):
            out.append(("Z", cur, start))
            cur = start
            prev_cmd, prev_ctl = "Z", None
        else:
            raise ValueError(f"unsupported svg path command {tok}")
    # build polygons
    polys = []
    cur_poly = None
    for seg in out:
        if seg[0] == "Z":
            if cur_poly and len(cur_poly) > 2:
                polys.append(cur_poly)
            cur_poly = None
            continue
        op = seg[0]
        if cur_poly is None:
            if op == "L":
                cur_poly = [seg[1]]
            elif op == "C":
                cur_poly = [seg[1]] + cubic(seg[1][0], seg[1][1], seg[2][0], seg[2][1],
                                            seg[3][0], seg[3][1], seg[4][0], seg[4][1])
            elif op == "Q":
                cur_poly = [seg[1]] + quad(seg[1][0], seg[1][1], seg[2][0], seg[2][1],
                                           seg[3][0], seg[3][1])
        else:
            if op == "L":
                cur_poly.append(seg[2])
            elif op == "C":
                cur_poly.extend(cubic(seg[1][0], seg[1][1], seg[2][0], seg[2][1],
                                      seg[3][0], seg[3][1], seg[4][0], seg[4][1]))
            elif op == "Q":
                cur_poly.extend(quad(seg[1][0], seg[1][1], seg[2][0], seg[2][1],
                                     seg[3][0], seg[3][1]))
    if cur_poly and len(cur_poly) > 2:
        polys.append(cur_poly)
    return polys


def _svg_to_polys(d, vw, vh, box_w, box_h, preserve):
    """Flatten d into device polygons for box (box_w x box_h), y-down,
    clipped to the box (KaTeX svgs are clipped by overflow:hidden windows)."""
    if vw <= 0 or vh <= 0:
        return []
    scale = max(box_w / vw, box_h / vh)
    par = preserve or ""
    if "xMid" in par:
        ox = (box_w - vw * scale) / 2.0
    elif "xMax" in par:
        ox = box_w - vw * scale
    else:
        ox = 0.0
    if "yMid" in par:
        oy = (box_h - vh * scale) / 2.0
    elif "yMax" in par:
        oy = box_h - vh * scale
    else:
        oy = 0.0
    out = []
    for poly in _flatten_svg_path(d):
        # SVG viewBox is y-DOWN (like CSS), so no flip: device y = path y.
        dev = [(px * scale + ox, py * scale + oy) for px, py in poly]
        clipped = _clip_poly(dev, 0.0, 0.0, box_w, box_h)
        if clipped:
            out.append(clipped)
    return out


def _clip_poly(poly, x0, y0, x1, y1):
    """Sutherland-Hodgman clip of a polygon to an axis-aligned rect."""
    def inside(p, edge):
        x, y = p
        return (edge == 0 and x >= x0) or (edge == 1 and x <= x1) or \
               (edge == 2 and y >= y0) or (edge == 3 and y <= y1)

    def intersect(a, b, edge):
        xa, ya = a; xb, yb = b
        if edge == 0:
            t = (x0 - xa) / (xb - xa) if xb != xa else 0.0
        elif edge == 1:
            t = (x1 - xa) / (xb - xa) if xb != xa else 0.0
        elif edge == 2:
            t = (y0 - ya) / (yb - ya) if yb != ya else 0.0
        else:
            t = (y1 - ya) / (yb - ya) if yb != ya else 0.0
        return (xa + t * (xb - xa), ya + t * (yb - ya))

    cur = poly
    for edge in range(4):
        if not cur:
            return []
        nxt = []
        n = len(cur)
        for i in range(n):
            a, b = cur[i], cur[(i + 1) % n]
            ai, bi = inside(a, edge), inside(b, edge)
            if ai and bi:
                nxt.append(b)
            elif ai and not bi:
                nxt.append(intersect(a, b, edge))
            elif not ai and bi:
                nxt.append(intersect(a, b, edge))
                nxt.append(b)
        cur = nxt
    return cur


# ----------------------------------------------------------------------------
# top-level layout + raster
# ----------------------------------------------------------------------------
def layout_katex(html_text, size_pt):
    """Full layout of the katex-html subtree. Returns (Layout, baseline)."""
    root = parse_html(html_text)
    html_node = find_html_subtree(root)
    B = 0.0
    layout = Layout()
    ctx = Ctx(size_pt, B)
    x = 0.0
    for base in html_node.children:
        if "base" not in base.cls:
            continue
        x += _emit_one(layout, base, ctx, x)
    return layout, B


def render_katex_ref(formula, workdir, size_pt=48.0, background="white", scale=1.0):
    """Formula -> KaTeX HTML -> PIL raster. Returns (png, cmd, convert_desc).

    scale > 1 raises the FINAL pixel density (scale=2 -> 8/3 px/pt at 192
    dpi) for the --ref 4-pane comparison, so the combined image can scale
    all panes to a common width without upscaling any pane below 8/3 px/pt.
    The draw is always supersampled 2x of the final density (SUPERSAMPLE).
    """
    workdir = os.path.abspath(workdir)
    os.makedirs(workdir, exist_ok=True)
    html_path = os.path.join(workdir, "katex.html")
    # The katex CLI reads the formula from STDIN (no positional argument).
    cmd = ["katex", "-d", "-o", html_path]
    subprocess.run(cmd, input=formula, check=True, capture_output=True, text=True)
    html_text = Path(html_path).read_text()
    layout, B = layout_katex(html_text, size_pt)
    pad = 6.0  # pt, like the XeTeX standalone border
    x0, y0, x1, y1 = layout.ink_bbox()
    w_pt = x1 - x0 + 2 * pad
    h_pt = y1 - y0 + 2 * pad
    w_px = max(1, int(round(w_pt * PT_TO_PX * scale)))
    h_px = max(1, int(round(h_pt * PT_TO_PX * scale)))
    ss = int(SUPERSAMPLE * scale)
    # Draw canvas is SUPERSAMPLE × the FINAL size (exactly the pre-scale
    # behavior at scale=1; at scale>1 it is scale× the old canvas — NOT
    # w_px×ss, which would be scale× too big and downscale the content to
    # 96dpi positions on a larger canvas). The 6pt pad absorbs rounding.
    dw = w_px * SUPERSAMPLE
    dh = h_px * SUPERSAMPLE
    img = Image.new("RGB", (dw, dh), background)
    draw = ImageDraw.Draw(img)
    ox = (pad - x0) * PT_TO_PX * ss
    oy = (pad - y0) * PT_TO_PX * ss
    for p in layout.prims:
        if p.kind == "text":
            ttf = face_ttf(p.kw["font"])
            fnt = ImageFont.truetype(ttf, int(round(p.kw["size"] * PT_TO_PX * ss)))
            draw.text((p.kw["x"] * PT_TO_PX * ss + ox,
                       p.kw["y"] * PT_TO_PX * ss + oy),
                      p.kw["text"], font=fnt, fill="black", anchor="ls")
        elif p.kind == "rect":
            draw.rectangle([(p.kw["x"] * PT_TO_PX * ss + ox,
                             p.kw["y"] * PT_TO_PX * ss + oy),
                            ((p.kw["x"] + p.kw["w"]) * PT_TO_PX * ss + ox,
                             (p.kw["y"] + p.kw["h"]) * PT_TO_PX * ss + oy)],
                           fill="black")
        elif p.kind == "svg":
            d = base64.b64decode(p.kw["d"]).decode()
            for poly in _svg_to_polys(d, p.kw["vb"][0], p.kw["vb"][1],
                                      p.kw["w"], p.kw["h"], p.kw["preserve"]):
                pts = [((px + p.kw["x"]) * PT_TO_PX * ss + ox,
                        (py + p.kw["y"]) * PT_TO_PX * ss + oy) for px, py in poly]
                draw.polygon(pts, fill="black")
    if dw != w_px or dh != h_px:
        img = img.resize((w_px, h_px), Image.LANCZOS)
    png_path = os.path.join(workdir, "katex.png")
    img.save(png_path)
    convert_desc = [f"KaTeX {katex_version()} PIL raster ({int(round(96*scale))}dpi, "
                    f"{w_px}x{h_px}px, {ss}x supersample + LANCZOS)"]
    return png_path, cmd, convert_desc


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="Render a formula with KaTeX to PNG.")
    ap.add_argument("formula")
    ap.add_argument("-s", "--size", type=float, default=48.0)
    ap.add_argument("-o", "--output", default=None)
    ap.add_argument("--json", action="store_true", help="dump geometry json")
    args = ap.parse_args()
    outdir = tempfile.mkdtemp(prefix="ztex-katex-")
    png, cmd, desc = render_katex_ref(args.formula, outdir, size_pt=args.size)
    dest = args.output
    if dest:
        if os.path.abspath(dest) != os.path.abspath(png):
            shutil.copyfile(png, dest)
    else:
        dest = png
    print(f"katex: {' '.join(cmd)}")
    print(f"raster: {desc[0]}")
    print(f"png: {dest}")
    if args.json:
        html_text = Path(os.path.join(outdir, "katex.html")).read_text()
        layout, B = layout_katex(html_text, args.size)
        print(f"ink bbox (pt): {layout.ink_bbox()}")
        for p in layout.prims:
            print(json.dumps(p.to_json()))
