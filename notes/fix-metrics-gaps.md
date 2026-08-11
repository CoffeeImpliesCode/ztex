# fix-metrics-gaps — real CM metrics for the remaining glyphEstimate fallbacks

Date 2026-08-12. Closes audit-metrics.md finding #3: `\neg \ldots \ell \Re \Im \wp`
and ASCII `\# \% \& \_ \$` (plus `∀ ∃ ℵ ⊤`) previously fell back to
`glyphEstimate` (0.5em = 5.0pt width). All values are real Computer-Modern
metrics, transcribed from MicroTeX
`src/res/font/{cmr10,cmmi10,cmsy10,cmex10}.def.cpp` (em × 10) and
cross-checked against the TeX Live TFM files via tftopl
(cmsy10.tfm / cmr10.tfm / cmmi10.tfm, DESIGNSIZE 10.0). Font-slot mapping
from MicroTeX `src/res/sym/base.def.cpp` + Knuth's plain.tex mathcodes.

## Added to src/layout/metrics.zig `table` (15 rows, sorted by cp)

| cp   | glyph | TeX name      | font + slot                              | w        | h        | d        | ic |
|------|-------|---------------|------------------------------------------|----------|----------|----------|-----|
| 0x23  | #     | `\#`          | cmr10 35 (0x23, mathsharp)               | 8.33336  | 6.94445  | 1.94443  | 0   |
| 0x24  | $     | `\$`          | cmr10 36 (0x24, textdollar)              | 5.00002  | 7.5      | 0.55555  | 0   |
| 0x25  | %     | `\%`          | cmr10 37 (0x25, textpercent)             | 8.33336  | 7.5      | 0.55555  | 0   |
| 0x26  | &     | `\&`          | cmr10 38 (0x26, textampersand)           | 7.77781  | 6.94445  | 0        | 0   |
| 0x5F  | _     | `\_`          | cmr10 95 (0x5F)                          | 2.77779  | 6.67859  | 0        | 0   |
| 0x00AC| ¬     | `\neg`        | cmsy10 58 (plain.tex `\neg="023A`)       | 6.66669  | 4.30555  | 0        | 0   |
| 0x2026| …     | `\ldots`      | composite: 3 × `\ldotp` (cmmi10 58)      | 8.33337  | 1.05556  | 0        | 0   |
| 0x2111| ℑ     | `\Im`         | cmsy10 61 (`\Im="023D`)                  | 7.22224  | 6.94445  | 0        | 0   |
| 0x2113| ℓ     | `\ell`        | cmmi10 96 (base.def.cpp E(5,96,ell))     | 4.1667   | 6.94445  | 0        | 0   |
| 0x2118| ℘     | `\wp`         | cmmi10 125 (E(5,125,wp))                 | 6.36459  | 4.30555  | 1.94445  | 0   |
| 0x211C| ℜ     | `\Re`         | cmsy10 60 (`\Re="023C`)                  | 7.22224  | 6.94445  | 0        | 0   |
| 0x2135| ℵ     | `\aleph`      | cmsy10 64 (`\aleph="0240`)               | 6.11113  | 6.94445  | 0        | 0   |
| 0x2200| ∀     | `\forall`     | cmsy10 56 (`\forall="0238`)              | 5.55557  | 6.94445  | 0        | 0   |
| 0x2203| ∃     | `\exists`     | cmsy10 57 (`\exists="0239`)              | 5.55557  | 6.94445  | 0        | 0   |
| 0x22A4| ⊤     | `\top`        | cmsy10 62 (`\top="023E`)                 | 7.77781  | 6.94445  | 0        | 0   |

Notes on sourcing:

- `\ldots` is not a single cmsy10 slot: plain.tex/MicroTeX define it as
  `\mathinner{\ldotp\ldotp\ldotp}` (MicroTeX src/core/formula_def.cpp).
  `\ldotp` = cmmi10 slot 58, identical metrics to the cmr10 period already
  in the table (w=2.77779 h=1.05556); 3 × 2.77779 = 8.33337, matching the
  U+22EF `\cdots` composite convention.
- `\ell`/`\wp` italic correction: MicroTeX's 5-column METRICS rows give ic=0
  and the TFMs carry no CHARIC for cmmi10 slots 0140/0175 (the `KRN O 177`
  entries are kern-table data, not CHARIC) — consistent with the existing
  table convention (ic = TFM CHARIC), so ic = 0.
- ASCII `# $ % & _`: TeX control symbols render the current-text-font (cmr10)
  glyph; MicroTeX maps them at font id 18 (cmr10) slots 35-38, and `_` at
  cmr10 slot 95. Values verified against cmr10.tfm (CHARWD/CHARHT/CHARDP).
- Scan result: every codepoint in `layout.roleOfCp` (bin/rel/open/close/
  punct/op) and every codepoint the parser cmd_map can emit (`\cdot` → U+22C5,
  the eight big ops) was already present in the table; the 15 rows above are
  the complete remaining set of common raw-Unicode symbols the pipeline can
  emit that previously hit glyphEstimate. Deliberately NOT added (composite
  or non-CM-core): `\hbar` (composite `\mathchar'26\mkern-9muh`), suits,
  `\mho`, `\vdots`/`\ddots` (msam10).
- `table7`/`table5` untouched: script styles fall back to the 10pt table for
  these glyphs (linear scaling), per the existing glyphAt design.

## Tests

Added `metrics: remaining glyphEstimate-fallback symbols resolve with real CM
metrics` asserting each new cp resolves from the table with its exact CM width
(±0.001) and positive extent, and that the wide subset (> 5.0pt) beats the
glyphEstimate width. The existing `metrics: table is sorted by codepoint` test
now also covers the 15 new rows.

## Behavior

INTENTIONAL output change: these glyphs render at their real CM advance
instead of 0.5em. Goldens regenerate; tests/goldens deliberately untouched.
