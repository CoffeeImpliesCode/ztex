# KaTeX screenshotter corpus vs ztex

126 entries; **32 SUPPORTED / 94 FAILED**.

| name | display | status | error | tex |
|---|---|---|---|---|
| Accents | I | FAILED | UnknownCommand | `\vec{A}\vec{x}\vec x^2\vec{x}_2^2\vec{A}^2\vec{xA}^2\; \underbar{X}` |
| Align | D | FAILED | other | `\begin{align}   a &= 1 & b &= 2 \\   3a &= 3 & 17b &= 34 \\   \tag{$\ast$} a &\neq b \\   ` |
| Alignedat | I | FAILED | other | `\begin{alignedat}{3}     a &= 1 & b &= 2 &\quad c &= 3\\     3a &= 3 & 17b &= 34 &\quad 40` |
| Arrays | I | FAILED | UnknownCommand | `\left(\begin{array}{|rl:c||}     1&2&3\\ \hline     1+1&2+1&3+1\cr1\over2&\scriptstyle 1/2` |
| BinomTest | I | FAILED | UnknownCommand | `\dbinom{a}{b}\tbinom{a}{b}^{\binom{a}{b}+17}{\scriptscriptstyle \binom a b}` |
| BoldSpacing | I | FAILED | UnknownCommand | `\mathbf{A}^2+\mathbf{B}_3*\mathscr{C}'` |
| BoldSymbol | I | FAILED | UnknownCommand | `\sum_{\boldsymbol{\alpha}}^{\boldsymbol{\beta}} \boldsymbol{\omega}+ \boldsymbol{\int_\alp` |
| Boxed | I | FAILED | UnknownCommand | `\begin{array}{l}   \boxed{F=ma} \quad \boxed{ac}\color{magenta}{\boxed{F}}\boxed{F=mg} \\[` |
| CD | D | FAILED | other | `\begin{CD} A @<a<< B @>>b> C \\ @| @AcAA @VVdV \\ D @= E @>>> F \end{CD}` |
| Cases | I | FAILED | UnknownCommand | `f(a,b)=\begin{cases}     a+1&\text{if }b\text{ is odd} \\     a&\text{if }b=0 \\     a-1&\` |
| ColorImplicit | I | FAILED | UnknownCommand | `\begin{array}{l} bl{ack\color{red}red\textcolor{green}{green}red\color{blue}blue}black \\ ` |
| ColorSpacing | I | FAILED | UnknownCommand | `\textcolor{red}{\displaystyle \int x} + 1` |
| Colorbox | I | FAILED | UnknownCommand | `a \colorbox{teal} B \fcolorbox{blue}{red}{C} e+\colorbox{teal}x` |
| Colors | I | FAILED | UnknownCommand | `\blue{a}\textcolor{#0f0}{b}\textcolor{red}{c}` |
| DashesAndQuotes | I | FAILED | UnknownCommand | `\begin{array}{l}     \text{``a'' b---c -- d----`e'-{-}-f} -- \\     \text{\it ``a'' b---c ` |
| DeepFontSizing | I | FAILED | MissingArgument | `a^{\big| x^{\big(}}_{\Big\uparrow} + i^{i^{\Huge x}_y}_{\Huge z} + \dfrac{\Huge x}{y} ` |
| DelimiterSizing | I | FAILED | UnknownCommand | `\bigl\uparrow\Bigl\downarrow\biggl\updownarrow \Biggl\Uparrow\Biggr\Downarrow\biggr\langle` |
| DisplayStyle | I | FAILED | MissingArgument | `{\displaystyle\sqrt{x}}{\sqrt{x}} {\displaystyle \frac12}{\frac12}{\displaystyle x^1_2}{x^` |
| Dots | I | FAILED | UnknownCommand | `\begin{array}{l}   \cdots;\dots+\dots\int\dots,\dots \\   \cdots{};\ldots+\ldots\int\ldots` |
| Equation | D | FAILED | other | `\begin{equation}\begin{split}a& =b+c-d \\ & \quad +e-f \\ & =g+h \\ & =i \end{split}\end{e` |
| ExtensibleArrows | I | FAILED | UnknownCommand | `\begin{array}{l}     \xrightarrow[ab]{ABC} + \xRightarrow{ABC} \\     \xrightleftharpoons[` |
| FractionTest | I | FAILED | MissingArgument | `\begin{array}{l}     \dfrac{a}{b}\frac{a}{b}\tfrac{a}{b}\;-\dfrac12\;1\tfrac12\;{1 \atop 2` |
| Gather | D | FAILED | other | `\begin{gather} a=\frac 1 2 \\ e=b+c \end{gather}` |
| Gathered | I | FAILED | other | `\begin{gathered}   x = \frac{1}{2} \\   y = \sum_{i=1}^n i \end{gathered} \approx \begin{a` |
| GroupMacros | I | FAILED | UnknownCommand | `\startExp a+b\endExp` |
| HTML | I | FAILED | UnknownCommand | `\htmlId{a}{a+}b\htmlStyle{color:red;}{+c}` |
| HorizontalBraces | I | FAILED | UnknownCommand | `\overbrace{\displaystyle{\oint_S{\vec E\cdot\hat n\,\mathrm d a}}}^\text{emf} = \underbrac` |
| HorizontalBrackets | I | FAILED | UnknownCommand | `\overbracket{\displaystyle{a+b+c}}^{\text{note}} = \underbracket{x+y+z}_{\text{label}}` |
| Includegraphics | I | FAILED | UnknownCommand | `\def\logo{\includegraphics[height=0.8em, totalheight=0.9em, width=0.9em, alt=KA logo]{../.` |
| Integrands | I | FAILED | UnknownCommand | `\begin{array}{l}     \displaystyle \int + \oint + \iint + \oiint_i^n \\[0.6em]     \displa` |
| KaTeX | I | FAILED | UnknownCommand | `\KaTeX, \large \KaTeX` |
| Kern | I | FAILED | UnknownCommand | `\frac{a\kern{1em}b}{c}a\kern{1em}b\kern{1ex}c\kern{-0.25em}d` |
| LaTeX | I | FAILED | UnknownCommand | `\text{\LaTeX}, \text{\TeX}, \large \text{\LaTeX}, \text{\TeX}` |
| Lap | I | FAILED | UnknownCommand | `\begin{array}{l}     ab\mathllap{f}cd\mathrlap{g}hij\mathclap{k}lm \; ab\llap{f}cd\rlap{g}` |
| LargeRuleNumerator | I | FAILED | UnknownCommand | `\frac{\textcolor{blue}{\rule{1em}{2em}}}{x}` |
| LeftRightMiddle | I | FAILED | MissingArgument | `\left( x^2 \middle/ \right) \left\{ x^{x^{x^{x^x}}} \middle/ y \right.\left(x\middle|y\,\m` |
| LeftRightStyleSizing | I | FAILED | UnknownCommand | `+\left\{\rule{0.1em}{1em}\right. x^{+\left\{\rule{0.1em}{1em}\right. x^{+\left\{\rule{0.1e` |
| LineBreak | I | FAILED | UnknownCommand | `\frac{x^2}{y^2} + z^2 = z^2 + \frac{x^2}{y^2} = \frac{x^2}{y^2} +\nobreak z^2 = z^2 + \fra` |
| LowerAccent | I | FAILED | UnknownCommand | `\begin{matrix}     \underleftarrow{AB} \quad \underrightarrow{AB} \quad \underleftrightarr` |
| MathAtom | I | FAILED | UnknownCommand | `a\mathrel{\mathop{=}\limits^{\blue ?}}b` |
| MathAtom2 | I | FAILED | UnknownCommand | `\mathop{\overline{\mathrm{lim}}}\limits_{x\to\infty}f(x)` |
| MathBb | I | FAILED | UnknownCommand | `\mathbb{Ax2k\breve{a}\omega\Omega\imath+\KaTeX}` |
| MathBf | I | FAILED | UnknownCommand | `\mathbf{Ax2k\breve{a}\omega\Omega\imath+\KaTeX}` |
| MathCal | I | FAILED | UnknownCommand | `\mathcal{Ax2k\breve{a}\omega\Omega\imath+\KaTeX}` |
| MathDefaultFonts | I | FAILED | UnknownCommand | `Ax2k\breve{a}\omega\Omega\imath+\KaTeX` |
| MathFrak | I | FAILED | UnknownCommand | `\mathfrak{Ax2k\breve{a}\omega\Omega\imath+\KaTeX}` |
| MathIt | I | FAILED | UnknownCommand | `\mathit{Ax2k\breve{a}\omega\Omega\imath+\KaTeX}` |
| MathNormal | I | FAILED | UnknownCommand | `\mathnormal{Ax2k\breve{a}\omega\Omega\imath+\KaTeX}` |
| MathOp | I | FAILED | UnknownCommand | `a\mathop+b\mathop:c\mathop{\delta}e\mathop{\textrm{and}}f\mathrel{\mathop{:}}=g\sin h` |
| MathRm | I | FAILED | UnknownCommand | `\mathrm{Ax2k\breve{a}\omega\Omega\imath+\KaTeX}` |
| MathScr | I | FAILED | UnknownCommand | `\mathscr{Ax2k\breve{a}\omega\Omega\imath+\KaTeX}` |
| MathSf | I | FAILED | UnknownCommand | `\mathsf{Ax2k\breve{a}\omega\Omega\imath+\KaTeX}` |
| MathSfIt | I | FAILED | UnknownCommand | `\mathsfit{Ax2k\breve{a}\omega\Omega\imath+\KaTeX}` |
| MathTt | I | FAILED | UnknownCommand | `\mathtt{Ax2k\breve{a}\omega\Omega\imath+\KaTeX}` |
| MathtoolsMatrix | I | FAILED | other | `\begin{matrix*}[l] a & -1 \\ -1 & d \end{matrix*} \; \begin{pmatrix*}[r] a & -1 \\ -1 & d ` |
| ModSpacing | I | FAILED | UnknownCommand | `\begin{array}{l}     (a \cdot b) \bmod 257 \\     (a \cdot b) \mkern1mu\mathbin{\mathrm{mo` |
| NegativeSpace | I | FAILED | UnknownCommand | `\boxed{\$1,\!000,\!000}\KaTeX` |
| NewLine | I | FAILED | UnknownCommand | `\frac{a^2+b^2}{c^2} \newline \frac{a^2+b^2}{c^2} \\[1ex] \begin{pmatrix}     a & b \\     ` |
| NullDelimiterInteraction | I | FAILED | UnknownCommand | `a \bigl. + 2 \quad \left. + a \right)` |
| OldFont | I | FAILED | UnknownCommand | `\begin{matrix}   \rm rm & it & \it it & \bf bf & \sf sf & \tt tt \\   \text{\rm rm} & \tex` |
| OpLimits | I | FAILED | UnknownCommand | `\begin{matrix}     {\sin_2^2 \lim_2^2 \int_2^2 \sum_2^2}     {\displaystyle \lim_2^2 \int_` |
| OperatorName | I | FAILED | MissingArgument | `\begin{matrix}     \operatorname g (z) + 5\operatorname{g}z + \operatorname{Gam-ma}(z) \\ ` |
| OverUnderline | I | FAILED | UnknownCommand | `x\underline{x}\underline{\underline{x}}\underline{x_{x_{x_x}}}\underline{x^{x^{x^x}}}\over` |
| OverUnderset | I | FAILED | UnknownCommand | `\begin{array}{l} x\overset?=1 \quad \underset{*}{x}^2 \quad \overset{a}{b}b\underset{a}{b}` |
| Phantom | I | FAILED | UnknownCommand | `\begin{array}{l} \dfrac{1+\phantom{x^{\blue{2}}} = x}{1+x^{\blue{2}} = x} \left(\vphantom{` |
| Phase | I | FAILED | UnknownCommand | `120\text{V}\phase{-78.2^\circ}\;\Large\phase{78.2^\circ}` |
| Pmb | I | FAILED | UnknownCommand | `\mu\pmb{\mu}\pmb{=}\mu\pmb{+}\mu` |
| PrimeSuper | I | FAILED | env/structure error | `x'^2+x'''^2+x'^2_3+x_3'^2` |
| Raisebox | I | FAILED | UnknownCommand | `\begin{matrix} \frac{a}{a\raisebox{0.5em}{b}} \cdot \frac{a\raisebox{-0.5em}{b}}{a} \cdot ` |
| ReactionArrows | I | FAILED | UnknownCommand | `\begin{matrix}     A \xrightleftarrows{} B \xrightequilibrium{} C \xleftequilibrium{} D \\` |
| RelativeUnits | I | FAILED | UnknownCommand | `\begin{array}{ll}     a\kern1emb^{a\kern1emb^{a\kern1emb}} &     {\footnotesize a\kern1emb` |
| RlapBug | I | FAILED | UnknownCommand | `\frac{\mathrlap{x}}{2}` |
| Rule | I | FAILED | UnknownCommand | `\rule{1em}{0.5em}\rule{1ex}{2ex}\rule{1em}{1ex}\rule{1em}{0.431ex}` |
| Sizing | I | FAILED | UnknownCommand | `{\Huge x}{\LARGE y}{\normalsize z}{\scriptsize w}\sqrt[\small 3]{x+1} ` |
| SizingBaseline | I | FAILED | UnknownCommand | `{\tiny a+b}a+b{\Huge a+b}` |
| Smash | I | FAILED | UnknownCommand | `\left( X^{\smash 2} \right) \sqrt{\smash[b]{y=}}` |
| Spacing | I | FAILED | env/structure error | `\begin{matrix}     ^3+[-1][1-1]1=1(=1)\lvert a\rvert~b \\     \scriptstyle{^3+[-1][1-1]1=1` |
| Sqrt | I | FAILED | UnknownCommand | `\sqrt{\sqrt{\sqrt{x}}}_{\sqrt{\sqrt{x}}}^{\sqrt{\sqrt{\sqrt{x}}} ^{\sqrt{\sqrt{\sqrt{x}}}}` |
| SqrtRoot | I | FAILED | UnknownCommand | `\begin{array}{l}     1+\sqrt[3]{2}+\sqrt[1923^234]{2^{2^{2^{2^{2^{2^{2^{2^{2^{2^{2^2}}}}}}` |
| StackRel | I | FAILED | UnknownCommand | `a \stackrel{?}{=} b \stackrel{\text{def}}{=} c` |
| StretchyAccent | I | FAILED | UnknownCommand | `\begin{array}{l}     \overrightarrow{AB} \quad \overleftarrow{AB} \quad \Overrightarrow{AB` |
| StretchyAccentColor | I | FAILED | UnknownCommand | `\red{\overrightarrow{AB}} \quad \color{blue}{\overleftarrow{AB}} \quad \color{blue}{\green` |
| StrikeThrough | I | FAILED | UnknownCommand | `\begin{array}{l}     \cancel x \quad \cancel{2B} + \bcancel 5 +\bcancel{5ay} \\     \text{` |
| StrikeThroughColor | I | FAILED | UnknownCommand | `\begin{array}{l}     \red{\cancel x \quad \cancel{2B} + \bcancel 5 +\bcancel{5ay}} \\     ` |
| SvgReset | I | FAILED | UnknownCommand | `\underbrace{\sqrt{\vec{x}} + \sqrt{\vec{\color{#f00}y}}}` |
| Symbols1 | I | FAILED | UnknownCommand | `\maltese\degree\pounds\$\minuso \text{\maltese\degree\pounds\textdollar} ` |
| Tag | D | FAILED | UnknownCommand | `\tag{$+$hi} \frac{x^2}{y}+x^{2^y}` |
| TextSpace | I | FAILED | UnknownCommand | `\begin{array}{l} \texttt{12345678901234} \\ \texttt{A test  1~~2\ \ 3} \\ \verb|A test 1  ` |
| TextStacked | I | FAILED | UnknownCommand | `\begin{matrix} \textsf{abc123 \textbf{abc123} \textit{abc123}}\\ \text{abc123 \textbf{abc1` |
| TextWithMath | I | FAILED | UnknownCommand | `\begin{matrix} \text{for $a < b$ and $ c < d $}. \\ \textsf{for $a < b$ and $ c < d $}. \\` |
| Units | I | FAILED | MissingArgument | `\begin{array}{ll}   \mathrm H\kern 1em\mathrm H \text{\tiny (1em)}   & \mathrm H\kern 1ex\` |
| UnsupportedCmds | I | FAILED | UnknownCommand | `\err\,\frac\fracerr3\,2^\superr_\suberr\,\sqrt\sqrterr` |
| Verb | I | FAILED | UnknownCommand | `\begin{array}{ll}   \verb \verb ,   & \verb|\verb  |, \\   \verb* \verb* , & \verb*|\verb*` |
| VerticalSpacing | I | FAILED | UnknownCommand | `x^{\Huge y}z` |
| AccentsText | I | SUPPORTED |  | `\begin{array}{lccccc} \text{\'\i} & \text{\.\i} & \text{\`\i} & \text{\"\i} & \text{\H\i} ` |
| Aligned | I | SUPPORTED |  | `\begin{aligned}     a &= 1 & b &= 2 \\     3a &= 3 & 17b &= 34 \end{aligned} ` |
| ArrayMode | D | SUPPORTED |  | `\begin{matrix}     \frac{\partial^2 f}{\partial x_1^2} & \frac{\partial^2 f}{\partial x_1\` |
| ArrayRemoveEmptyLine | I | SUPPORTED |  | `\begin{pmatrix}     1 \\     2 \\ \end{pmatrix} ` |
| ArrayType | I | SUPPORTED |  | `1\begin{array}{c}2\\3\end{array}4` |
| Baseline | I | SUPPORTED |  | `a+b-c\cdot d/e` |
| BasicTest | I | SUPPORTED |  | `a` |
| BinCancellation | I | SUPPORTED |  | `\begin{array}{cccc}     +1 & 1+ & 1+1 & (,) \\     1++1 & 3\times) & 1+, & \left(,\right) ` |
| DisplayMode | D | SUPPORTED |  | `\sum_{i=0}^\infty \frac{1}{i}` |
| Exponents | I | SUPPORTED |  | `a^{a^a_a}_{a^a_a}` |
| Functions | I | SUPPORTED |  | `\sin\cos\tan\ln\log` |
| GreekLetters | I | SUPPORTED |  | `\alpha\beta\gamma\omega` |
| GreekUnicode | I | SUPPORTED |  | `\frac{αβγδεϵζηθϑικλμνξοπϖρϱςστυφϕχψω}{ΓΔΘΞΠΣΦΨΩϝ\mathbf{Ω}\mathbf{\Omega}}` |
| LeftRight | I | SUPPORTED |  | `\left( x^2 \right) \left\{ x^{x^{x^{x^x}}} \right.` |
| LeftRightListStyling | I | SUPPORTED |  | `a+\left(x+y\right)-x` |
| LimitControls | I | SUPPORTED |  | `\displaystyle\int\limits_2^3 3x^2\,dx + \sum\nolimits^n_{i=1}i + \textstyle\int\limits_x^y` |
| MathChoice | I | SUPPORTED |  | `{\displaystyle\mathchoice{D}{T}{S}{SS}} {\textstyle\mathchoice{D}{T}{S}{SS}} {\scriptstyle` |
| Mod | I | SUPPORTED |  | `\begin{array}{cc}     a \bmod 2 & b \pod 3 \\     c \pmod{4} & d \mod{56} \\     \displays` |
| ModScript | I | SUPPORTED |  | `\begin{array}{cc}     \scriptstyle a\bmod 2 & \scriptstyle b \pod 3 \\     \scriptstyle c\` |
| NegativeSpaceBetweenRel | I | SUPPORTED |  | `A =\!= B` |
| NestedFractions | I | SUPPORTED |  | `\dfrac{\frac{a}{b}}{\frac{c}{d}}\dfrac{\dfrac{a}{b}} {\dfrac{c}{d}}\frac{\frac{a}{b}}{\fra` |
| Not | I | SUPPORTED |  | `\begin{array}{l}     \not=\not>\not\geq\not\in\not<\not\leq\not{abc} \\     \not xy + ab \` |
| PrimeSpacing | I | SUPPORTED |  | `f'+f_2'+f^{f'}` |
| StyleSpacing | I | SUPPORTED |  | `\scriptstyle ab\;cd` |
| StyleSwitching | I | SUPPORTED |  | `a\cdot b\scriptstyle a\cdot ba\textstyle\cdot ba\scriptstyle\cdot b` |
| SupSubCharacterBox | I | SUPPORTED |  | `a_2f_2{f}_2{aa}_2{af}_2\mathbf{y}_Ay_A` |
| SupSubHorizSpacing | I | SUPPORTED |  | `x^{x^{x}}\Big|x_{x_{x_{x_{x}}}}\bigg|x^{x^{x_{x_{x_{x_{x}}}}}}\bigg| ` |
| SupSubLeftAlignReset | I | SUPPORTED |  | `\omega^8_{888} \quad \frac{1}{\hat{\omega}^{8}_{888}} \quad \displaystyle\sum_{\omega^{8}_` |
| SupSubOffsets | I | SUPPORTED |  | `\displaystyle \int_{2+3}x f^{2+3}+3\lim_{2+3+4+5}f` |
| SurrogatePairs | I | SUPPORTED |  | `\begin{array}{l}     𝐀𝐚𝟎𝐴𝑎𝑨𝒂𝔅𝔞𝔸𝒜 \\     𝖠𝖺𝟢𝗔𝗮𝟬𝘈𝘢𝙰𝚊𝟶 \\     \text{𝐀𝐚𝟎𝐴𝑎𝑨𝒂𝔅𝔞𝔸𝒜} \\     \text` |
| Text | I | SUPPORTED |  | `\frac{a}{b}\text{c~ {ab} \ e}+fg` |
| Unicode | I | SUPPORTED |  | `\begin{matrix}\text{ÀàÇçÉéÏïÖöÛû} \\ \text{БГДЖЗЙЛФЦШЫЮЯ} \\ \text{여보세요} \\ \text{私はバナナです}` |
