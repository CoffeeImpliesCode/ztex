# Round 2 Deep Render & Geometry Audit

Across three parallel audit partitions (Delimiters/Fences, Environments/Matrices, and Complex Fractions/Scripts), renders were evaluated against **XeTeX**, **KaTeX**, and **MathJax** at 20pt and 30pt.

---

## Findings by Subsystem

### 1. Parser & Syntax
| Issue ID | Severity | Formula / Input | Expected Behavior | Observed Behavior | Root Cause |
|---|---|---|---|---|---|
| **PARSE-R2-01** | **Critical** | `x_{i_1, i_2, \dots, i_k}` | `\dots` parses as ellipsis (matching `\ldots`). | Parse error: `Unknown command (UnknownCommand)` at col 14. | `\dots` is not registered in `src/parse/parser.zig` command map (only `\ldots`, `\cdots`, `\vdots`, `\ddots`). |

### 2. Rasterizer & Font Variant Mapping
| Issue ID | Severity | Formula / Input | Expected Behavior | Observed Behavior | Root Cause |
|---|---|---|---|---|---|
| **RASTER-R2-01** | **Critical** | `\begin{bmatrix} ... \end{bmatrix}` / `\left[ \dots \right]` in `--ppm` | Square bracket extenders and full vertical fence contours render across rows. | In direct `--ppm` rasterization, square brackets `[` / `]` only render the middle bracket stroke; top/bottom bracket extenders are missing. | `src/raster.zig` maps `(` / `)` variants to `parenleft.v1..v7` GIDs, but lacks GID dispatch for square brackets (`[`, `]`), braces (`{`, `}`), and vertical bars (`|`, `\|`). |
| **RASTER-R2-02** | **Moderate** | `\sum_{n=1}^\infty \frac{(-1)^{n-1}}{n} = \ln 2` (Zero padding) | All upper limit ink remains inside the raster buffer. | The top curve of `\infty` touches row $y=0$ (clipped by 0.5–1px at 0 padding). | Raster bounding box computation uses floor/ceil bounds without accounting for glyph ascender overshoot in top limits when `padding == 0`. |

### 3. Layout & Clearance
| Issue ID | Severity | Formula / Input | Expected Behavior | Observed Behavior | Root Cause |
|---|---|---|---|---|---|
| **LAYOUT-R2-01** | **Moderate** | $e^{-\frac{x^2}{2\sigma^2}} \cdot \frac{1}{\sigma\sqrt{2\pi}}$ | Denominator depth under the second fraction rule matches XeTeX. | Denominator is ~1.5pt–1.9pt lower than XeTeX reference (depth ~5px too large). | `layoutFraction` denominator depth adjustment when radicands appear in the denominator. |
| **LAYOUT-R2-02** | **Minor** | `\cfrac{1}{1 + \cfrac{1}{2 + \cfrac{1}{3 + \cfrac{1}{4}}}}` | Continued fraction rule widths remain tight. | Outer rule is ~4.1pt wider than XeTeX (472px vs 461px) due to cumulative +1.2pt padding per nested stage. | Additive padding accumulation across 4 nested cfrac levels. |

### 4. CLI / Output Contract
| Issue ID | Severity | Formula / Input | Expected Behavior | Observed Behavior | Root Cause |
|---|---|---|---|---|---|
| **CLI-R2-01** | **Moderate** | `ztex -i '...' -o out.png` | Produces a valid PNG file or reports unsupported raster format. | Writes SVG XML text into `out.png` (command succeeds with exit code 0). | `src/main.zig` only checks `.ppm`, `.pnm`, `.pgm` for raster mode, falling back to SVG file write for `.png` paths. |

---

## Actionable Fix Plan for Next Iteration
1. **Parser**: Add `\dots` alias in `src/parse/parser.zig`.
2. **Rasterizer**: Add GID mappings in `src/raster.zig:drawGlyph` for:
   - Square brackets `[` / `]` (`bracketleft.v1..v7`, `bracketright.v1..v7`)
   - Braces `{` / `}` (`braceleft.v1..v7`, `braceright.v1..v7`)
   - Vertical bars `|` / `\|` (`divides.v1..v4`, `parallel.v1..v4`)
   - Angle brackets `\langle` / `\rangle`
3. **Rasterizer Bounding Box**: Add minimum top-bearing headroom to prevent limit symbol clipping at 0 padding.
4. **CLI**: Detect `.png` extension and emit explicit notice/ppm fallback or auto-rasterize.
