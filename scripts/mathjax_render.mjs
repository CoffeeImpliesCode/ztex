#!/usr/bin/env node
/* MathJax SVG renderer for ztex --ref comparisons.

Renders a LaTeX math formula with MathJax (mathjax-full) to SVG whose glyph
shapes are embedded as <path> outlines (no font dependency — crisp at any
raster resolution, unlike font-based panes). The output is scaled so that
1em = <size> pt — the SAME nominal font size as the ztex / XeTeX / KaTeX
panes — and the svg width/height attributes are rewritten to px so resvg
rasterizes at exactly 4/3 px/pt (96 dpi) or 2x that (8/3 px/pt) with no
reinterpretation of ex units.

Units: MathJax SVG viewBox coordinates are em/1000 (1em = 1000 units;
MathJax TeX x-height = 0.442em = 442 units, so the ex width/height
attributes equal viewBox/442). To make 1em == size pt we multiply every
viewBox unit by size/1000 pt, then by PT_TO_PX (96/72 = 4/3 px/pt) and the
optional --scale supersample factor.

Usage:
  node scripts/mathjax_render.mjs 'FORMULA' [--display|--inline]
       [--size PT] [--scale N] [-o out.svg]
  Formula may also be read from stdin (useful for shell quoting pain).

Output: the SVG document on stdout (or -o FILE), with width/height already
in px. Exit 0 on success.
*/

import { readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function makeRequire() {
  // Prefer normal node_modules resolution (e.g. npm-installed at repo
  // root); fall back to the project-local install under tools/mathjax.
  try {
    const r = createRequire(import.meta.url);
    r.resolve("mathjax-full/js/mathjax.js");
    return r;
  } catch {
    const toolsDir = path.resolve(__dirname, "..", "tools", "mathjax");
    return createRequire(path.join(toolsDir, "package.json"));
  }
}
const require = makeRequire();

// mathjax-full's npm package ships js/ but not the built js/tex-svg.js
// convenience entry (that file is a repo build artifact), so wire the TeX
// input jax + SVG output jax manually — exactly what tex-svg.js does.
const { mathjax } = require("mathjax-full/js/mathjax.js");
const { TeX } = require("mathjax-full/js/input/tex.js");
const { SVG } = require("mathjax-full/js/output/svg.js");
const { liteAdaptor } = require("mathjax-full/js/adaptors/liteAdaptor.js");
const { RegisterHTMLHandler } = require("mathjax-full/js/handlers/html.js");
const { AllPackages } = require("mathjax-full/js/input/tex/AllPackages.js");

const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);
const tex = new TeX({ packages: AllPackages });
const svgJax = new SVG({ fontCache: "local" });
const html = mathjax.document("", { InputJax: tex, OutputJax: svgJax });

function tex2svg(math, options = {}) {
  if (options.display == null) options.display = false;
  const node = html.convert(math, options);
  return adaptor.outerHTML(node);
}

const PT_TO_PX = 96.0 / 72.0; // 1pt -> px at 96 dpi (matches the other panes)
const EM_UNITS = 1000;        // viewBox units per em

function usage(out) {
  out.write(
    "usage: mathjax_render.mjs 'FORMULA' [--display|--inline] [--size PT] [--scale N] [-o out.svg]\n" +
    "       (formula may also be piped on stdin)\n");
}

function parseArgs(argv) {
  const opts = { display: false, size: 20.0, scale: 1.0, out: null, formula: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--display" || a === "-d") opts.display = true;
    else if (a === "--inline" || a === "-i") opts.display = false;
    else if (a === "--size" || a === "-s") opts.size = parseFloat(argv[++i]);
    else if (a === "--scale") opts.scale = parseFloat(argv[++i]);
    else if (a === "-o") opts.out = argv[++i];
    else if (a === "--help" || a === "-h") { usage(process.stdout); process.exit(0); }
    else if (a.startsWith("-")) { usage(process.stderr); process.exit(2); }
    else opts.formula = a;
  }
  return opts;
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  let formula = opts.formula;
  if (formula === null || formula === undefined || formula === "") {
    formula = readFileSync(0, "utf8").trim();
  }
  if (!formula) {
    usage(process.stderr);
    process.exit(2);
  }
  let svg = tex2svg(formula, { display: opts.display });
  // resvg requires <svg> as the document root; strip MathJax's
  // <mjx-container> wrapper (its style attrs are irrelevant to raster).
  svg = svg.replace(/^<mjx-container[^>]*>/, "").replace(/<\/mjx-container>$/, "");

  // Rewrite width/height to px so resvg rasterizes at the exact target
  // density. viewBox is em/1000 units; scale factor per viewBox unit:
  //   pt per unit = size / 1000 ; px per pt = 96/72 ; supersample = scale.
  const vb = /viewBox="([-0-9.eE+ ]+)"/.exec(svg);
  if (!vb) {
    process.stderr.write("mathjax_render: no viewBox in MathJax SVG output\n");
    process.exit(1);
  }
  const [x0, y0, w, h] = vb[1].trim().split(/\s+/).map(Number);
  const pxPerUnit = opts.size / EM_UNITS * PT_TO_PX * opts.scale;
  const wPx = w * pxPerUnit;
  const hPx = h * pxPerUnit;
  const round = (v) => (Math.round(v * 100) / 100).toString();
  svg = svg.replace(
    /<svg([^>]*?)\swidth="[^"]*"\sheight="[^"]*"/,
    (m, pre) => `<svg${pre} width="${round(wPx)}" height="${round(hPx)}"`);

  if (opts.out) writeFileSync(opts.out, svg);
  else process.stdout.write(svg);
}

main();
