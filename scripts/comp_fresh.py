#!/usr/bin/env python3
"""Fresh large LaTeX formulas for the comp corpus — exercises features
not yet well covered in the existing /tmp/complex_corpus.json.

Each entry: a single-line LaTeX formula at display-style density.
Used by the vision verifier to find new nits.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = Path("/tmp/comp_fresh")
OUT_DIR.mkdir(parents=True, exist_ok=True)

# 12 formulas. Each targets features the existing corpus covers thinly.
# Categories covered:
#   - Continued fraction + nested radicals (large depth)
#   - Multiline piecewise with 5+ cases + per-case fractions
#   - Long chain of mixed subscripts/superscripts + primes
#   - Taylor/Maclaurin series (long product/sum)
#   - Commutator / anticommutator brackets with subscripts
#   - Fourier transform + inverse, with hat operator
#   - Matrix 4x4 with mixed entries (fracs, scripts, sqrt)
#   - Binomial theorem expansion with multiple terms
#   - Schrodinger equation with del + V + ψ
#   - Stirling's approximation with asymptotic
#   - Big-O notation with multiline expansion
#   - Quantum mechanical bra-ket sandwich with operator
FORMULAS: dict[str, str] = {
    # 1. Continued fraction + nested radical (deep nesting)
    "ContinuedFrac": (
        r"x = a_0 + \cfrac{1}{a_1 + \cfrac{1}{a_2 + \cfrac{1}{a_3 + \cfrac{1}{a_4}}}}"
    ),
    # 2. Big piecewise with 5 cases, each a fraction or expression
    "PiecewiseBig": (
        r"f(x) = "
        r"\begin{cases}"
        r"\frac{x^2 - 1}{x + 1}, & x < -1 \\"
        r"\sqrt{1 - x^2}, & -1 \le x \le 1 \\"
        r"\ln(x + \sqrt{x^2 + 1}), & 1 < x < 2 \\"
        r"\frac{\sin(\pi x)}{\pi x}, & 2 \le x < 3 \\"
        r"\sum_{k=0}^{\infty} \frac{(-1)^k x^{2k}}{(2k)!}, & x \ge 3"
        r"\end{cases}"
    ),
    # 3. Long chain of scripts + primes (deep)
    "ChainScripts": (
        r"\frac{d}{dx}\!\left(f^{(n)}(x)\,g^{(m)}(x)\right) "
        r"= \sum_{k=0}^{n} \binom{n}{k} f^{(k)}(x)\,g^{(n-k)}(x)"
    ),
    # 4. Taylor series with explicit remainder
    "TaylorSeries": (
        r"f(x) = \sum_{n=0}^{\infty} \frac{f^{(n)}(a)}{n!}(x-a)^n "
        r"= f(a) + f'(a)(x-a) + \frac{f''(a)}{2!}(x-a)^2 + \cdots"
    ),
    # 5. Commutator with deep subscripts
    "CommutatorDeep": (
        r"\left[\hat{x},\, \hat{p}\right] = i\hbar\,\mathbb{1}, \quad "
        r"\left[\hat{L}_i,\, \hat{L}_j\right] = i\hbar\,\varepsilon_{ijk}\,\hat{L}_k"
    ),
    # 6. Fourier transform pair
    "FourierPair": (
        r"\hat{f}(\xi) = \int_{-\infty}^{\infty} f(x)\,e^{-2\pi i x \xi}\,dx, \qquad "
        r"f(x) = \int_{-\infty}^{\infty} \hat{f}(\xi)\,e^{2\pi i x \xi}\,d\xi"
    ),
    # 7. 4x4 matrix with mixed entries
    "MatrixMixed": (
        r"M = \begin{pmatrix}"
        r"\frac{1}{\sqrt{2}} & 0 & \frac{1}{\sqrt{2}} & 0 \\"
        r"0 & \frac{i}{\sqrt{2}} & 0 & \frac{-i}{\sqrt{2}} \\"
        r"\sqrt{a^2 + b^2} & 0 & -\sqrt{a^2 + b^2} & 0 \\"
        r"e^{i\theta} & 0 & e^{-i\theta} & \cos\phi"
        r"\end{pmatrix}"
    ),
    # 8. Binomial theorem expansion
    "BinomialExpand": (
        r"(1 + x)^n = \sum_{k=0}^{n} \binom{n}{k} x^k "
        r"= 1 + nx + \frac{n(n-1)}{2!}x^2 + \frac{n(n-1)(n-2)}{3!}x^3 + \cdots + x^n"
    ),
    # 9. Schrodinger equation
    "Schrodinger": (
        r"i\hbar\frac{\partial}{\partial t}\Psi(\mathbf{r}, t) "
        r"= \left[-\frac{\hbar^2}{2m}\nabla^2 + V(\mathbf{r}, t)\right]\Psi(\mathbf{r}, t)"
    ),
    # 10. Stirling approximation
    "StirlingApprox": (
        r"n! \sim \sqrt{2\pi n}\,\left(\frac{n}{e}\right)^{\!n} "
        r"\left(1 + \frac{1}{12n} + \frac{1}{288n^2} - \frac{139}{51840n^3} + O(n^{-4})\right)"
    ),
    # 11. Big-O multiline expansion
    "BigOExpansion": (
        r"e^x = 1 + x + \frac{x^2}{2!} + \frac{x^3}{3!} + \cdots "
        r"= \sum_{n=0}^{\infty} \frac{x^n}{n!} \quad (x \in \mathbb{R})"
    ),
    # 12. Bra-ket sandwich with operator
    "BraKetOperator": (
        r"\langle\psi|\,\hat{A}^{\dagger}\hat{A}\,|\psi\rangle "
        r"= \sum_n |c_n|^2 \langle n|\hat{A}^{\dagger}\hat{A}|n\rangle "
        r"\ge 0"
    ),
}


def main() -> int:
    # write the corpus
    corpus_path = OUT_DIR / "corpus.json"
    corpus_path.write_text(json.dumps(FORMULAS, indent=2))
    print(f"wrote {len(FORMULAS)} formulas -> {corpus_path}")

    # render each (just ztex, fast — no --ref; ref will be a separate grid build)
    for name, latex in FORMULAS.items():
        out = OUT_DIR / name
        rc = subprocess.call(
            [
                "python3",
                str(ROOT / "scripts" / "critique.py"),
                "-i",
                latex,
                "-s",
                "30",
                "--out-dir",
                str(out),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=120,
        )
        print(f"  {name}: rc={rc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
