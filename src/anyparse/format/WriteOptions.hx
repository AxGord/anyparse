package anyparse.format;

import anyparse.core.Doc;

/**
 * Base write options shared by all text writers.
 *
 * Per-grammar option typedefs extend this shape via struct intersection:
 * `typedef JValueWriteOptions = WriteOptions & { ... };`.
 * Resolution happens once in the generated `write()` entry point — the
 * internal `writeXxx` helpers see a fully populated, non-nullable struct.
 *
 * The format singleton owns the defaults (`JsonFormat.instance.defaultWriteOptions`,
 * `HaxeFormat.instance.defaultWriteOptions`): the format describes the
 * target language and therefore is the source of truth for its default
 * formatting style.
 */
typedef WriteOptions = {

	/**
	 * Character used to render one indent unit: tab or space.
	 */
	indentChar: IndentChar,

	/**
	 * Columns per indent level when `indentChar = Space`.
	 */
	indentSize: Int,

	/**
	 * Logical width of one tab character in columns. Used when
	 * `indentChar = Tab` to decide nesting width for line-fit
	 * calculations.
	 */
	tabWidth: Int,

	/**
	 * Target line width used by the Wadler-style renderer to pick
	 * between flat and broken layout for groups.
	 */
	lineWidth: Int,

	/**
	 * End-of-line sequence emitted by the writer for every break-mode
	 * `Line` / `OptHardline` (and as the trailing newline when
	 * `finalNewline` is true). Honored by `Renderer.render` directly.
	 * For Haxe grammar, fed by `lineEnds.lineEndCharacter` config:
	 * `"LF"` → `\n`, `"CRLF"` → `\r\n`, `"CR"` → `\r`, `"auto"` falls
	 * back to `\n` (no source-detection plumbing).
	 */
	lineEnd: String,

	/**
	 * Whether the output ends with a newline. Declared in σ;
	 * honored once the renderer gains final-newline awareness.
	 */
	finalNewline: Bool,

	/**
	 * When `true`, blank lines between content carry the surrounding
	 * block's indent rather than rendering bare. Opt-in gate on top of
	 * the renderer's default deferred-indent, which silently drops
	 * indent on empty rows. Matches haxe-formatter's
	 * `indentation.trailingWhitespace` knob; default `false` keeps every
	 * other corpus case byte-identical.
	 */
	trailingWhitespace: Bool,

	/**
	 * Output wrap style for multi-line DOC comments — content that opens
	 * `/**` and carries a physical newline. Everything else (a plain
	 * `/* … *\/` block, a one-line doc) takes the `Verbatim` path
	 * whatever this says, so the knob can neither mint a haxedoc where
	 * the author wrote none nor expand a one-liner.
	 *
	 * `Javadoc` emits `/**`, a ` * ` marker on each content line, and a
	 * star-aligned ` *\/` close; `JavadocNoStars` keeps the doc wrap but
	 * indents the body and closes flush `*\/`; `Plain` re-wraps as
	 * `/* … *\/`, which DEMOTES the doc — reachable only by setting this
	 * field directly, never from an `hxformat.json` token.
	 *
	 * Both doc styles COLLAPSE a block whose interior is a single content
	 * line to `/** <content> *\/`, gated on that line fitting `lineWidth`
	 * at its emission column (resolved by the renderer, not guessed here).
	 *
	 * The knob drives the wrap and the marker column, not every byte:
	 * whitespace a line carries beyond the block's common prefix is the
	 * author's indentation and echoes through (a gutter-marked line is
	 * the exception — its `ws` is the marker column and is dropped).
	 */
	commentStyle: CommentStyle,

	/**
	 * When `true`, single-line `//` comments are re-emitted with one
	 * space between `//` and a non-decoration body (`//foo` → `// foo`,
	 * `//<- foo` → `// <- foo`). Decoration runs (body starting with
	 * `/`, `*`, `-`, or whitespace) survive tight (`//*****`,
	 * `//---------`, `////`). When `false`, the body is rtrim/trim'd
	 * but no space is inserted. Lives on the base `WriteOptions` so
	 * the unconditionally-emitted `leadingCommentDoc` /
	 * `trailingCommentDoc(Verbatim)` writer helpers can read it
	 * regardless of grammar — formats without a `//` comment vocabulary
	 * still need a value here for the helpers to compile, even though
	 * their captured trivia stream never reaches the line-comment
	 * branch.
	 */
	addLineCommentSpace: Bool,

	/**
	 * When `true`, the leading whitespace of a `//` line-comment body is
	 * normalised to exactly one space and, across a contiguous run of
	 * `//` entries, the run's COMMON post-`//` indent is stripped first —
	 * so `//foo` becomes `// foo`, and a block of commented-out code
	 * keeps its relative indentation while losing the shared over-indent.
	 * A lone over-indented comment therefore collapses to a single space.
	 * When a run shares no common indent — a member sits flush against
	 * `//`, or members disagree on tab-vs-space — the pass never adds
	 * width: an already-indented body is re-emitted as authored and only a
	 * flush body gains the separating space.
	 * Tabs after `//` count as whitespace and normalise the same way.
	 *
	 * Only a body whose first non-whitespace character is an ASCII letter or
	 * digit feeds the run's common-indent fold. Every other body — an empty
	 * `//`, a divider (`//====`, `//----`, `//***`), a marker (`//!`), a
	 * `///`-style triple slash, a `}` closer, a string continuation —
	 * neither contributes to nor breaks its run, but still rides the run's
	 * shift when its own indent opens with that common prefix, so a
	 * commented-out block keeps its shape. One that does not share the
	 * prefix is left to the `addLineCommentSpace` path. A block-comment
	 * entry DOES break the run.
	 *
	 * While `true`, a body the pass rewrites gets exactly one space
	 * after `//` regardless of `addLineCommentSpace`. Default `false`
	 * leaves the writer byte-identical to the pre-knob output.
	 */
	normalizeLineCommentIndent: Bool,

	/**
	 * When `true` (default), whitespace between two successive opening
	 * brackets is compressed away: a call-arg open `(` immediately
	 * followed by a bracket-opening argument (`{` object literal) glues
	 * tight — `TPath({…})`. When `false`, the inner bracket keeps its
	 * own natural opening spacing, so an object-literal first argument
	 * renders `TPath( {…})` with a leading space. Mirrors haxe-formatter's
	 * `whitespace.compressSuccessiveParenthesis` (fork default `true`):
	 * the fork removes the brace's `Before` policy when its predecessor
	 * is an open `(`; this knob `false` preserves it. Default `true`
	 * keeps every corpus case byte-identical to the pre-knob glued
	 * layout. Format-neutral so any paren-call grammar can reuse it,
	 * though only the Haxe writer currently emits the space.
	 */
	compressSuccessiveParenthesis: Bool,

	/**
	 * Layout policy for matrix-shaped array literals (an array literal
	 * whose source rows each carry the same number of elements). When the
	 * writer detects such a grid it preserves the row structure — and,
	 * under `MatrixWrapWithAlign`, right-aligns each column — instead of
	 * reflowing the elements one-per-line or width-packing them.
	 * `NoMatrixWrap` disables detection and routes the literal through the
	 * normal wrap cascade. Fed by haxe-formatter's
	 * `wrapping.arrayMatrixWrap` knob through `HaxeFormatConfigLoader`;
	 * other grammars set it via their format default. Format-neutral so
	 * any array-of-rows grammar can reuse the policy.
	 */
	arrayMatrixWrap: ArrayMatrixWrap,

	/**
	 * Policy for the trailing separator after the LAST element of a
	 * MULTILINE list literal. `Keep` (default) round-trips the source
	 * comma and lets the per-construct `trailingComma*` knobs add one;
	 * `Remove` drops it. Only reaches grammar fields that opt in with
	 * `@:fmt(trailingCommaRemovable)`, so constructs whose trailing
	 * separator is mandatory stay untouched. Fed by the anyparse-specific
	 * `wrapping.trailingComma` knob through `HaxeFormatConfigLoader`;
	 * format-neutral so any delimited-list grammar can reuse it.
	 */
	trailingComma: TrailingCommaPolicy,

	/**
	 * Indentation policy for preprocessor conditional-compilation
	 * (`#if`/`#elseif`/`#else`/`#end`) blocks. See
	 * `ConditionalIndentationPolicy`. Default `Aligned` keeps the writer
	 * byte-identical to the pre-policy behaviour (markers and body both
	 * at the surrounding statement indent). Fed by haxe-formatter's
	 * `indentation.conditionalPolicy` knob through `HaxeFormatConfigLoader`;
	 * format-neutral so any preprocessor-conditional grammar can reuse it.
	 */
	conditionalPolicy: ConditionalIndentationPolicy,

	/**
	 * When `true`, an inline case body (`case X: expr` on one line) whose
	 * argument wraps does NOT receive the extra indent level the case `:`
	 * normally adds — the wrapped argument already indents relative to the
	 * case line via its own container, so a second level would over-indent
	 * the content and its closing bracket. Opt-in: a body that starts on
	 * its own line is unaffected (it never reaches the inline-flat path).
	 * Default `false` keeps the case `:` indent, matching the pre-knob
	 * layout where a wrapped inline body nests at case+2. Fed by
	 * haxe-formatter's `indentation.alignInlineSwitchCaseBody` knob through
	 * `HaxeFormatConfigLoader`; format-neutral so any colon-delimited
	 * case-body grammar can reuse it.
	 */
	alignInlineSwitchCaseBody: Bool,

	/**
	 * When `true`, a delimited list whose SOLE element is an expression-
	 * bodied `for` comprehension (`[for (x in xs) body]`, filter-`if` and
	 * `k => v` map forms included) keeps the comprehension HEAD on the
	 * opening-delimiter line — `[ for (x in xs)` — instead of breaking the
	 * delimiter onto its own line, whenever the segment through the head's
	 * closing `)` still fits the line. The body (and any filter `if`) wraps
	 * one indent level below the open-delimiter line and the close delimiter
	 * lands on its own line at container indent. A head that does not fit
	 * falls back to the delimiter-on-its-own-line layout.
	 *
	 * Three shapes are deliberately NOT covered and keep their pre-knob
	 * layout: BLOCK-bodied comprehensions (`[for (x in xs) { … }]`, which
	 * already head-hug under padded comprehension brackets), NESTED
	 * generators (a second `for` / `while` inside the body), and `while`
	 * comprehensions (whose body carries no placement policy to indent
	 * against). The inner-delimiter padding follows the construct's own
	 * bracket-spacing policy, so under tight brackets the head cuddles as
	 * `[for (x in xs)`.
	 *
	 * Default `false` — absent from config means byte-identical output to
	 * the pre-knob writer. Fed by `wrapping.comprehensionCuddledOpen`
	 * through `HaxeFormatConfigLoader`. Lives on the base options (rather
	 * than the Haxe extension) alongside the other cascade-independent
	 * layout policies the wrap engine reads directly; the element shape it
	 * recognises is Haxe's, exactly as for the sibling
	 * `WrapList.isBlockBodyComprehensionItem`.
	 */
	comprehensionCuddledOpen: Bool,

	/**
	 * When `true`, a BRACKET-delimited list (`[ … ]`) with exactly ONE element
	 * keeps both brackets CUDDLED to that element — `[for (x in xs) f({` … `})]`
	 * — instead of breaking the `[` onto its own line and nesting the element
	 * one level deeper, whenever the element's own natural first line fits the
	 * line AND ends at an open delimiter, i.e. the element already owns a wrap
	 * point of its own.
	 *
	 * The policy this states: a leading break is worth taking only when it
	 * RESCUES the line. For a sole element that lays out across lines anyway,
	 * it rescues nothing — it buys two extra lines and one indent level while
	 * the overflow is settled by the element's own break. Same reasoning the
	 * call-arg side already applies from the outside in
	 * `shapeSingleArgGlue`'s bracket arm ("a bracket-delimited collection owns
	 * its own multi-line layout: its `[` IS its wrap point"), read from the
	 * inside out.
	 *
	 * The decision is the RENDERER's, through
	 * `Doc.IfNaturalFirstLineFitsOpenDelim`: an element whose natural first
	 * line overflows, or which breaks at an operator / mid-argument rather
	 * than at an open delimiter, keeps the pre-knob exploded layout — so a
	 * sole element with no wrap point of its own can never be forced flat past
	 * `lineWidth`. Cascade-independent: it wraps whichever shape the cascade
	 * resolved (`OnePerLine`, `PackedOrOnePerLine`, the fill family) and
	 * declines outright for `NoWrap`, which already hugs.
	 *
	 * Deliberately NOT covered: multi-element lists (the cuddle would strand
	 * siblings), non-bracket delimiters (a `{` list's own hug policies own
	 * that question), arrow-body and method-chain elements (their dedicated
	 * glue intercepts run first and answer it better), and an element carrying
	 * a leading break or a leading / trailing LINE comment, where a cuddled
	 * bracket would land on a comment line.
	 *
	 * Default `false` — absent from config means byte-identical output to the
	 * pre-knob writer. Fed by `wrapping.soleItemCuddledBrackets` through
	 * `HaxeFormatConfigLoader`. Lives on the base options alongside the other
	 * cascade-independent layout policies the wrap engine reads directly; the
	 * shape it recognises is expressed purely in `Doc` terms, so any grammar
	 * emitting bracket lists through `WrapList` inherits it.
	 */
	soleItemCuddledBrackets: Bool,

	/**
	 * When `true`, a method-chain link whose PRECEDING link already rendered
	 * multi-line and ended in a dedented closing-delimiter run (`}` / `})` /
	 * `}]`) starts ON that closing line instead of on a fresh indented line of
	 * its own — the compact fluent shape
	 * `…postLocked(null, {\n\t…\n}).applied(… -> {\n\t…\n}).fault(…)` — while
	 * every other link keeps the dot-break the cascade chose. Applies only to
	 * the two dot-break chain shapers (`OnePerLineAfterFirst` / `OnePerLine`);
	 * the cuddled link joins the run of the link it rides on, so its own body
	 * indents from the statement head rather than gaining one extra level per
	 * link.
	 *
	 * The gate is emit-time and STRUCTURAL — `DocMeasure.endsWithForcedCloseLine`
	 * over the preceding link: a FORCED hardline whose entire tail is close
	 * delimiters and whitespace. Every conditional is read on its flat side, so
	 * a construct the RENDERER would break for being too wide answers `false`
	 * and keeps the pre-knob layout — no column measurement ever changes a
	 * chain's shape here. The closes-only tail requirement additionally pins the
	 * cuddle point to a low column (base indent plus two or three characters),
	 * so the cuddled `.method(` head cannot by itself blow the line.
	 *
	 * Which links therefore cuddle, measured rather than assumed: a link whose
	 * argument is a lambda BLOCK body with at least one statement always does
	 * (that body breaks even when the source wrote it on one line), which is
	 * what compacts the real fluent-callback shapes. A link whose argument is a
	 * BRACKETED LITERAL does iff that literal's own wrap cascade already
	 * committed to breaking it at build time — under the stock object-literal
	 * rules, an item count above the threshold breaks even a one-line source
	 * literal, while at or below it `Keep` semantics reproduce the source's own
	 * line breaks, so the same AST can cuddle or not depending on how it was
	 * written. A trailing comma is an output of that break, not its cause.
	 *
	 * Three shapes are deliberately NOT covered: `Keep`-mode chains (they
	 * already reproduce the source's own dot boundaries), chains carrying a
	 * trailing line comment (routed through `shapeKeep` by
	 * `commentBreakMask` — a link cuddled after a `//` would be swallowed),
	 * and links whose predecessor breaks only at render time, for width.
	 *
	 * Default `false` — absent from config means byte-identical output to the
	 * pre-knob writer, since both shapers early-return their pre-knob
	 * construction when no gap cuddles. Fed by
	 * `wrapping.methodChainCuddledLinks` through `HaxeFormatConfigLoader`.
	 * Lives on the base options alongside the other cascade-independent layout
	 * policies the wrap engine reads directly; the shapes it recognises are
	 * expressed purely in `Doc` terms, so any grammar emitting method chains
	 * through `MethodChainEmit` inherits it.
	 */
	methodChainCuddledLinks: Bool,

	/**
	 * Cuddle the `:` of a BROKEN ternary onto the then branch's own closing line
	 * (`} : {`) instead of opening a continuation line that holds nothing but
	 * `: {`. Only the `:` side moves; the `?` keeps its break, because the branch
	 * that gains a line by breaking has earned it while the `: {` line buys
	 * nothing — the else branch lays out across lines regardless, its own `{` IS
	 * its wrap point, and the separator line only pushes everything below it down
	 * one. `soleItemCuddledBrackets` reads the same policy from the other side: a
	 * break is worth taking only when it RESCUES the line.
	 *
	 * TWO ADMISSION LEGS, both in `BinaryChainEmit.ternaryBracesCuddle`. The
	 * STRUCTURAL one reads `DocMeasure.breakTailCloseNest` over the then branch,
	 * whose rendered tail must be a forced closing line whose leftmost closer is a
	 * BRACE landing at depth ZERO — the indent of the line the branch itself
	 * started on. That zero is what makes the cuddle safe rather than merely
	 * shorter: the else branch's `{` opens at the `?` line's indent, so its own `}`
	 * closes there too and neither delimiter sits below its opener. A then branch
	 * that rendered FLAT has no closing line to ride and answers `-1`, so a ternary
	 * whose branches both fit is never rebuilt onto one line.
	 *
	 * That read sees nothing under a config that defers every object-literal break
	 * to the RENDERER (`objectLiteral.defaultWrap: "ignore"` plus a single
	 * `exceedsMaxLineLength` rule). The SECOND leg resolves such a branch through
	 * `WrapList.renderPivotBreakArm` and pays for the render-time reading with a
	 * continuation-fits probe wrapped around the cuddled shape, slot-inverted so
	 * the PRE-KNOB layout is what every Doc walker resolves to: a branch that fits
	 * its own continuation line stays flat, and is never glued.
	 *
	 * The ELSE branch must additionally OPEN with a collection delimiter
	 * (`WrapList.startsWithCollectionDelim`) — the `} : {` shape is only legible
	 * when what follows the separator is itself a delimited body. A non-collection
	 * else operand (a call, a chain, a bare identifier) keeps the pre-knob line of
	 * its own.
	 *
	 * A THIRD gate, `BinaryChainEmit.cuddleShape`, answers about the else branch's
	 * WIDTH, because gluing does not move that branch — it SHIFTS it right by the
	 * then branch's whole closing-line CLOSER RUN and the space after it — two
	 * columns for a bare `}`, four for a `}))`. An else that fits its own
	 * separator line can overflow the line it rides once glued, and the renderer
	 * then breaks a branch that was a single line, spending several to save one.
	 * Two `IfArrowContinuationFitsWithRest` probes BRACKET that band — both
	 * failing, or both fitting, means the else lays out the same way either way and
	 * the cuddle is free — and only inside the band does the separator line
	 * survive. The rest-aware ctor is what makes those two widths honest: the line
	 * they measure ends where the HOST does, not where the branch does, so they
	 * charge what the render stack still emits after the ternary — the `;` of a
	 * statement, the `);` of a glued call argument, nothing at all when the host
	 * opened its own paren. `cuddleShape`'s own doc carries the arithmetic and the
	 * band a fixed one-column reserve straddled before it.
	 *
	 * Covers the two one-operand-per-line break shapes (`OnePerLineAfterFirst` /
	 * `OnePerLine`) — what a broken ternary is — and within them only the
	 * `beforeLast` separator location, the only one whose shaper reads the flag.
	 * Deliberately NOT covered: `Keep` (source-faithful by contract — the source's
	 * own `:` placement is the answer there), the fill family (its gaps break by
	 * packing, so the separator may not start a line at all), and `NoWrap`
	 * (already glued).
	 *
	 * Default `false` — absent from config means byte-identical output to the
	 * pre-knob writer, since the cuddle branch is entered only when the gate
	 * answers yes. Fed by `wrapping.ternaryCuddledBraces` through
	 * `HaxeFormatConfigLoader`. Lives on the base options alongside the other
	 * cuddle policies the wrap engine reads directly; the shape it recognises is
	 * expressed purely in `Doc` terms, so any grammar emitting a mixfix `? :`
	 * chain through `BinaryChainEmit` inherits it.
	 */
	ternaryCuddledBraces: Bool,

	/**
	 * Cap on consecutive line-end runs in the rendered output. Read once
	 * by `Renderer.render` as the final post-pass: any run of `N+1` or
	 * more consecutive `lineEnd` sequences is truncated to exactly
	 * `maxConsecutiveBlanks + 1` line-end occurrences (i.e. at most
	 * `maxConsecutiveBlanks` blank lines between any two non-empty
	 * lines). Default `-1` disables the cap and preserves whatever the
	 * Doc tree emitted. Fed by haxe-formatter's
	 * `emptyLines.maxAnywhereInFile` knob through
	 * `HaxeFormatConfigLoader`; other grammars leave it unbounded.
	 *
	 * Orthogonal to `trailingWhitespace`, which makes a blank row carry the
	 * block's indent: the cap counts such a row as blank and keeps the indent on
	 * the rows it keeps. The two used to be silently mutually exclusive — with
	 * `trailingWhitespace` on, no run matched and this knob did nothing.
	 *
	 *  - `maxConsecutiveBlanks = 0` — no blank lines anywhere; every
	 *    inter-line gap collapses to a single line-end.
	 *  - `maxConsecutiveBlanks = 1` — at most one blank line between
	 *    any two non-empty lines (fork's default value).
	 *  - `maxConsecutiveBlanks = N >= 0` — at most `N` blank lines.
	 *  - `maxConsecutiveBlanks = -1` — unbounded (no post-pass).
	 */
	maxConsecutiveBlanks: Int,

	/**
	 * Plugin-supplied trivia adapters bound at runtime. The macro-
	 * emitted `leadingCommentDoc` / `trailingCommentDoc(Verbatim)`
	 * helpers call these to convert captured trivia strings into Doc
	 * fragments — keeps the macro core format-neutral by routing the
	 * format-specific comment normalization through the writer's
	 * runtime config rather than hardcoded module references.
	 *
	 * Formats that don't use trivia capture leave these null; helpers
	 * that read them are only emitted when `{trivia: true}` is on, so
	 * non-trivia writers never invoke the adapters. The active format's
	 * `defaultWriteOptions` populates the fields with its own
	 * normalizer (e.g. `HaxeFormat` sets these from
	 * `anyparse.format.comment.BlockCommentNormalizer.processCapturedBlockComment` /
	 * `LineCommentNormalizer.normalizeLineComment`).
	 *
	 *  - `blockCommentAdapter(content, opt) → Doc` — full pipeline for
	 *    a captured `/*…*\/` body: parse → canonicalise → emit Doc.
	 *  - `lineCommentAdapter(run, index, opt) → String` — string-level
	 *    normalisation of `run[index]`; `run` is the captured contiguous
	 *    comment array so the adapter can compute a run-wide common
	 *    indent, and single-comment slots pass a 1-element array.
	 */
	?blockCommentAdapter: Null<(String, WriteOptions) -> Doc>,
	?lineCommentAdapter: Null<(Array<String>, Int, WriteOptions) -> String>,

	/**
	 * Plugin-supplied path-grouping predicate bound at runtime.
	 * `betweenImportsPathDiffers(prevPath, currPath, level) → Bool` —
	 * true iff the two paths fall into different groups at the
	 * configured granularity. Drives the
	 * `@:fmt(blankLinesBetweenSameCtorByLevel(...))` cascade in
	 * `TriviaEofLowering.triviaEofStarExpr`: the meta's last arg names
	 * this opt field, the engine emits a pure
	 * `opt.betweenImportsPathDiffers(prev, curr, level)` call. Args
	 * are primitive (`String` paths + `Int` level) so the engine
	 * stays format-neutral; the plugin's typed-enum helper plugs in
	 * via the underlying-Int representation of its level enum
	 * (e.g. `enum abstract HxBetweenImportsLevel(Int) from Int to Int`).
	 * Formats that don't opt in leave the field null; the emission
	 * short-circuits on the null check.
	 */
	?betweenImportsPathDiffers: Null<(String, String, Int) -> Bool>
};
