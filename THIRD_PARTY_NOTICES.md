# Third-party notices

## Latin Modern Roman fonts

- **Component:** Four embedded Latin Modern Roman OpenType faces.
- **Paths:** `src/fonts/lmroman_regular.zig`, `src/fonts/lmroman_italic.zig`, `src/fonts/lmroman_bold.zig`, and `src/fonts/lmroman_bold_italic.zig`.
- **License:** GUST Font License (GFL) 1.0 (2009-06-22), legally equivalent to LPPL 1.3c or later. The GFL requests, but does not legally require, renaming fonts and files in derived font works.
- **Copyright holder:** B. Jackowski and J. M. Nowacki, on behalf of TeX Users Groups (Latin Modern project; authors Bogusław Jackowski and Janusz M. Nowacki). The project is developed by GUST e-foundry.
- **Upstream:** [Latin Modern](https://www.gust.org.pl/projects/e-foundry/latin-modern); [GUST Font License](https://www.gust.org.pl/projects/e-foundry/licenses/GUST-FONT-LICENSE.txt).

## Latin Modern Math font

- **Component:** Embedded Latin Modern Math OpenType font (`latinmodern-math.otf`).
- **Paths:** `src/fonts/lmmath.zig`, `src/fonts/lmmath/part0.zig`, `src/fonts/lmmath/part1.zig`, `src/fonts/lmmath/part2.zig`, `src/fonts/lmmath/part3.zig`, and `src/fonts/lmmath/part4.zig`.
- **License:** GUST Font License (GFL) 1.0 (2009-06-22), legally equivalent to LPPL 1.3c or later. The GFL requests, but does not legally require, renaming fonts and files in derived font works.
- **Copyright holder:** B. Jackowski, P. Strzelczyk, and P. Pianowski, on behalf of TeX Users Groups (Latin Modern Math project; authors Bogusław Jackowski, Piotr Strzelczyk, and Piotr Pianowski). The project is developed by GUST e-foundry.
- **Upstream:** [Latin Modern Math](https://www.gust.org.pl/projects/e-foundry/lm-math); [GUST Font License](https://www.gust.org.pl/projects/e-foundry/licenses/GUST-FONT-LICENSE.txt).

The GUST Font License text is reproduced below. The GFL incorporates the [LPPL 1.3c or later](https://www.latex-project.org/lppl.txt); its full text is available at that link.

### GUST Font License, version 1.0

```text
% This is version 1.0, dated 22 June 2009, of the GUST Font License.
% (GUST is the Polish TeX Users Group, https://www.gust.org.pl)
%
% For the most recent version of this license see
% https://www.gust.org.pl/fonts/licenses/GUST-FONT-LICENSE.txt
% or
% https://tug.org/fonts/licenses/GUST-FONT-LICENSE.txt
%
% This work may be distributed and/or modified under the conditions
% of the LaTeX Project Public License, either version 1.3c of this
% license or (at your option) any later version.
% 
% Please also observe the following clause:
% 1) it is requested, but not legally required, that derived works be
%    distributed only after changing the names of the fonts comprising this
%    work and given in an accompanying "manifest", and that the
%    files comprising the Work, as listed in the manifest, also be given
%    new names. Any exceptions to this request are also given in the
%    manifest.
%    
%    We recommend the manifest be given in a separate file named
%    MANIFEST-<fontid>.txt, where <fontid> is some unique identification
%    of the font family. If a separate "readme" file accompanies the Work, 
%    we recommend a name of the form README-<fontid>.txt.
%
% The latest version of the LaTeX Project Public License is in
% https://www.latex-project.org/lppl.txt and version 1.3c or later
% is part of all distributions of LaTeX version 2006/05/20 or later.
```

## MicroTeX-derived layout data and behavior

- **Component:** Partial derivations and reimplementations of MicroTeX TeX metric values, style mappings, and layout behavior; this is not a port of the complete MicroTeX source.
- **Paths:** `src/layout/metrics.zig` and `src/layout/layout.zig`.
- **License:** MIT. The MIT license text is reproduced below.
- **Copyright holder:** Nano Michael (2020).
- **Upstream:** [NanoMichael/MicroTeX](https://github.com/NanoMichael/MicroTeX); [upstream LICENSE](https://github.com/NanoMichael/MicroTeX/blob/master/LICENSE).

```text
The MIT License (MIT)

Copyright (c) 2020 Nano Michael

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
