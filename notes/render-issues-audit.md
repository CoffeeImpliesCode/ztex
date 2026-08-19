# Comprehensive Audit of ztex LaTeX Math Renders

Across 31 curated benchmark formulas covering fractions, radicals, big operators, matrices, delimiters, scripts, accents, styles, and spacing, renders were evaluated across four engines (**ztex**, **XeTeX**, **KaTeX**, and **MathJax**) and the 126-formula KaTeX screenshotter corpus.

Below is the complete catalog of defects, visual nits, and structural discrepancies categorized by subsystem.

---

## Subsystem 1: Lexer & Parser

| Issue ID | Severity | Formula / Input | Expected Behavior | Observed Behavior | Root Cause |
|---|---|---|---|---|---|
| **PARSE-01** | **Critical** | `x_0'^2` / `f'(x) + f''(x) + f'''(x) + x_0'^2` | Prime followed by explicit superscript `^2` on a subscripted base attaches both scripts to the base. | Parse failure `UnexpectedScript` at col 32. | `src/parse/parser.zig:954-1000` consumes scripts via `parseScripts` before trailing primes. On `x_0'`, prime is merged into sub-only script; subsequent `^2` is treated as unexpected leading script. |
| **PARSE-02** | **Critical** | `\ointctrclockwisectr_C` / `\ointctrclockwise_C` | Standard contour integral symbols parse into big-operator atoms. | `Unknown command (UnknownCommand)` at column 1. | `src/parse/parser.zig:189-190` maps only `\oint` (`op_oint`). Extended AMS/unicode-math contour symbols (`\ointctrclockwise`, `\oiint`, `\oiiint`) are absent from `cmd_map`. |
| **PARSE-03** | **Moderate** | KaTeX Corpus features (94/126 failed) | Support standard LaTeX math environments and macros (`\boxed`, `\color`, `\overset`, `\underset`, `\cancel`, `\substack`, `\begin{alignedat}`, `\begin{gather}`). | Parser rejects unknown macros and unsupported environments. | Macro table and environment dispatch in `src/parse/parser.zig` lacks AMS math extension set. |

---

## Subsystem 2: Font Metrics & Style Mapping

| Issue ID | Severity | Formula / Input | Expected Behavior | Observed Behavior | Root Cause |
|---|---|---|---|---|---|
| **METRICS-01** | **Moderate** | `\mathbf{F} = m\mathbf{a} + \mathbb{R} + \mathcal{H} + \mathfrak{g}` | `\mathcal{H}` renders calligraphic ℋ; `\mathfrak{g}` renders Fraktur 𝔤. | `\mathcal{H}` renders as plain Latin Modern `H`; `\mathfrak{g}` renders as plain `g`. Bold and blackboard work correctly. | `src/layout/layout.zig:589-670` and `src/layout/metrics.zig:1949-2004` only map Latin/Greek to italic, bold, and blackboard (AMS `bb`) tables; calligraphic (`\mathcal`) and Fraktur (`\mathfrak`) styles lack codepoint remap tables. |
| **METRICS-02** | **Moderate** | Display Big Operators in Substack: `\sum_{\substack{...}}` | `\sum` in display style should select full display-size variant (v1). | Emitted `∑` is ~28.9% narrower and 28.3% shorter, top sitting 3.93pt lower than XeTeX. | Layout box allocates display dimensions, but MATH-variant resolution fallback in rasterizer chooses text variant when nested in complex script/substack context. |
| **METRICS-03** | **Minor** | Horizontal under-spacing in operator chains | Horizontal span matches reference engines. | ztex is systematically ~5–10% narrower than XeTeX/MathJax across long formulas (e.g. Gaussian integral 152.51pt vs XeTeX 161.25pt). | Slight differences between bundled Latin Modern Math advance widths and XeTeX's OpenType metric tables, compounded across long atom chains. |

---

## Subsystem 3: Box Layout Engine

| Issue ID | Severity | Formula / Input | Expected Behavior | Observed Behavior | Root Cause |
|---|---|---|---|---|---|
| **LAYOUT-01** | **Moderate** | `\sqrt[3]{x+y} + \sqrt[n]{\frac{1}{x}}` | Degree index (`3`, `n`) sits to the upper-left of the radical stem (XeTeX relative offset +0.56pt / -0.44pt). | Degree `3` is placed at x=5.84 (root x=1.60, +4.24pt); `n` at x=94.68 (root x=88.40, +6.28pt) — 3.7pt to 6.7pt too far right. | `src/layout/layout.zig:2755-2760`: `deg_x = 0.073 * rad_ink_height + 0.278 * deg_size`. The positive `rad_ink_height` term pushes the degree index to the right as radical height grows. |
| **LAYOUT-02** | **Minor** | `\cfrac{1}{a_1 + \cfrac{1}{a_2 + \cfrac{1}{a_3}}}` | Fraction rules and column width match TeX continued fraction centering. | Outer bar is ~2.8pt wider than XeTeX (107.94pt vs 105.15pt); middle bar is 1.43pt wider. | `layoutFraction` in `src/layout/layout.zig` adds fixed horizontal padding (`pad = 1.2pt`) per nested cfrac stage, accumulating width in deep branches. |
| **LAYOUT-03** | **Minor** | `\frac{1}{1+\frac{1}{1+\frac{1}{x}}}` | Nested denominator baseline spacing matches TeX. | Inner denominator subtree `1 + 1/x` is ~0.55pt lower than XeTeX reference. | Residual clearance in `denomLastCharScale` and vertical shift accumulation in nested `layoutFraction` vboxes. |
| **LAYOUT-04** | **Minor** | CLI / Facade Math Style Support | Ability to render formulas in inline/text style (`\textstyle`) or display style (`\displaystyle`). | Root render hardcodes `.display` style (`src/layout/root.zig:43`). | CLI and top-level facade lack a style parameter, forcing display-style limit and fraction layouts everywhere. |

---

## Subsystem 4: SVG Serialization & Direct Rendering

| Issue ID | Severity | Formula / Input | Expected Behavior | Observed Behavior | Root Cause |
|---|---|---|---|---|---|
| **SVG-01** | **Critical** | Stretched Delimiters: `\binom{n}{k}`, `\begin{pmatrix}...`, `\begin{cases}...` | Valid SVG contains correctly sized or assembled bracket/brace/paren paths/glyphs. | Emits standard base `<text>` glyph (e.g. `(`) with custom attributes (`data-fixed-req`, `data-delim-form="v6"`). | `src/svg.zig:105-145` serializes raw base characters. External SVG renderers (browsers, inkscape, rsvg) ignore `data-*`, rendering short 20pt delimiters. The internal critique PIL rasterizer intercepts `data-*`, masking the bug in visual test suites. |
| **SVG-02** | **Critical** | Radical Signs: `\sqrt{...}`, `\sqrt[n]{...}` | Valid SVG contains stretched radical glyph or path assembly spanning radicand. | Emits base `√` character with `data-radical="vN"`. | `src/svg.zig` does not emit path outlines or font-variant glyph references for radical signs in standard SVG output. |
