#!/usr/bin/env python3
"""Curated benchmark and stress-test suite for ztex rendering analysis."""

CORPUS = [
    # 1. Fractions & Binomials & Continued Fractions
    {"cat": "fractions", "id": "frac_basic", "tex": r"\frac{a+b}{c+d}"},
    {"cat": "fractions", "id": "frac_nested", "tex": r"\frac{1}{1+\frac{1}{1+\frac{1}{x}}}"},
    {"cat": "fractions", "id": "cfrac", "tex": r"\cfrac{1}{a_1 + \cfrac{1}{a_2 + \cfrac{1}{a_3}}}"},
    {"cat": "fractions", "id": "dfrac_tfrac", "tex": r"\dfrac{x+1}{x-1} + \tfrac{1}{2}"},
    {"cat": "fractions", "id": "binom_basic", "tex": r"\binom{n}{k}"},
    {"cat": "fractions", "id": "binom_complex", "tex": r"\binom{n+1}{k} = \binom{n}{k} + \binom{n}{k-1}"},

    # 2. Radicals & Nested Roots
    {"cat": "radicals", "id": "sqrt_simple", "tex": r"\sqrt{x^2+y^2}"},
    {"cat": "radicals", "id": "sqrt_nested", "tex": r"\sqrt{1 + \sqrt{1 + \sqrt{1 + \sqrt{1 + x}}}}"},
    {"cat": "radicals", "id": "sqrt_frac", "tex": r"\sqrt{\frac{a^2+b^2}{c^2+d^2}}"},
    {"cat": "radicals", "id": "sqrt_index", "tex": r"\sqrt[3]{x+y} + \sqrt[n]{\frac{1}{x}}"},

    # 3. Big Operators, Integrals, Sums, Limits
    {"cat": "bigops", "id": "int_gaussian", "tex": r"\int_{-\infty}^{\infty} e^{-x^2} dx = \sqrt{\pi}"},
    {"cat": "bigops", "id": "sum_series", "tex": r"\sum_{k=1}^{\infty} \frac{1}{k^2} = \frac{\pi^2}{6}"},
    {"cat": "bigops", "id": "prod_wallis", "tex": r"\prod_{n=1}^{\infty} \left(\frac{2n}{2n-1} \cdot \frac{2n}{2n+1}\right) = \frac{\pi}{2}"},
    {"cat": "bigops", "id": "lim_def", "tex": r"\lim_{x \to 0} \frac{\sin x}{x} = 1"},
    {"cat": "bigops", "id": "oint_contour", "tex": r"\ointctrclockwisectr_C \frac{f(z)}{z-z_0} dz = 2\pi i f(z_0)"},

    # 4. Delimiters & Matrix Environments
    {"cat": "delims_matrices", "id": "matrix_2x2", "tex": r"\begin{matrix} a & b \\ c & d \end{matrix}"},
    {"cat": "delims_matrices", "id": "pmatrix_3x3", "tex": r"\begin{pmatrix} 1 & 0 & 0 \\ 0 & 1 & 0 \\ 0 & 0 & 1 \end{pmatrix}"},
    {"cat": "delims_matrices", "id": "bmatrix_inv", "tex": r"\begin{bmatrix} a & b \\ c & d \end{bmatrix}^{-1} = \frac{1}{ad-bc} \begin{bmatrix} d & -b \\ -c & a \end{bmatrix}"},
    {"cat": "delims_matrices", "id": "vmatrix_det", "tex": r"\det A = \begin{vmatrix} a_{11} & a_{12} \\ a_{21} & a_{22} \end{vmatrix}"},
    {"cat": "delims_matrices", "id": "cases_piecewise", "tex": r"f(x) = \begin{cases} \frac{\sin x}{x} & x \neq 0 \\ 1 & x = 0 \end{cases}"},
    {"cat": "delims_matrices", "id": "aligned_eqs", "tex": r"\begin{aligned} x &= r\cos\theta \\ y &= r\sin\theta \end{aligned}"},

    # 5. Scripts, Accents, Primes & Substack
    {"cat": "scripts_accents", "id": "primes", "tex": r"f'(x) + f''(x) + f'''(x) + x_0'^2"},
    {"cat": "scripts_accents", "id": "nested_scripts", "tex": r"x^{y^{z}} + a_{b_{c}} + e^{i\pi} + 1 = 0"},
    {"cat": "scripts_accents", "id": "accents_math", "tex": r"\hat{x} + \bar{y} + \tilde{z} + \vec{v} + \dot{x} + \ddot{y}"},
    {"cat": "scripts_accents", "id": "substack_sum", "tex": r"\sum_{\substack{0 < i < m \\ 0 < j < n}} a_{ij}"},

    # 6. Math Styles, Operators, Spaces & Spacing
    {"cat": "styles_spacing", "id": "styles", "tex": r"\mathbf{F} = m\mathbf{a} + \mathbb{R} + \mathcal{H} + \mathfrak{g}"},
    {"cat": "styles_spacing", "id": "operatorname", "tex": r"\operatorname{argmin}_{x \in X} f(x) + \sin^2\theta + \cos^2\theta = 1"},
    {"cat": "styles_spacing", "id": "spaces", "tex": r"a\,b\;c\quad d\qquad e\!f"},
    {"cat": "styles_spacing", "id": "text_in_math", "tex": r"x > 0 \quad \text{for all } x \in \mathbb{N}"},
    {"cat": "styles_spacing", "id": "mathchoice", "tex": r"\mathchoice{D}{T}{S}{SS}"},
    {"cat": "styles_spacing", "id": "overline_underline", "tex": r"\overline{A \cup B} = \overline{A} \cap \overline{B}"}
]
