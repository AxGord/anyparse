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
	 * Output wrap style for multi-line block comments. `Plain` emits
	 * `/*…*\/` with content-only interior lines; `Javadoc` emits
	 * `/**…**\/` with ` * ` markers on each content line. The parser
	 * strips both `*` markers and leading whitespace at capture time,
	 * so this knob fully drives the output appearance — source style
	 * is not echoed.
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
	 * bodied comprehension (`[for (x in xs) body]` / `[while (c) body]`,
	 * filter-`if` and `k => v` map forms included) keeps the comprehension
	 * HEAD on the opening-delimiter line — `[ for (x in xs)` — instead of
	 * breaking the delimiter onto its own line, whenever the segment
	 * through the head's closing `)` still fits the line. The body (and any
	 * filter `if`) wraps one indent level below the open-delimiter line and
	 * the close delimiter lands on its own line at container indent. A head
	 * that does not fit falls back to the delimiter-on-its-own-line layout.
	 *
	 * BLOCK-bodied comprehensions (`[for (x in xs) { … }]`) are NOT covered
	 * — they already head-hug unconditionally under padded comprehension
	 * brackets — and neither are NESTED comprehensions (a `for` / `while`
	 * inside the body): both stay on their pre-knob layout, deliberately
	 * conservative. The inner-delimiter padding follows the construct's own
	 * bracket-spacing policy, so under tight brackets the head cuddles as
	 * `[for (x in xs)`.
	 *
	 * Default `false` — absent from config means byte-identical output to
	 * the pre-knob writer. Fed by `wrapping.comprehensionCuddledOpen`
	 * through `HaxeFormatConfigLoader`; format-neutral so any grammar with
	 * a comprehension-shaped list element can reuse the policy.
	 */
	comprehensionCuddledOpen: Bool,

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
	 *  - `lineCommentAdapter(content, addSpace) → String` — string-level
	 *    normalisation of a captured `//` body (decoration-aware
	 *    `//foo` → `// foo` rewrite when `addSpace == true`).
	 */
	?blockCommentAdapter: Null<(String, WriteOptions) -> Doc>,
	?lineCommentAdapter: Null<(String, Bool) -> String>,

	/**
	 * Plugin-supplied path-grouping predicate bound at runtime.
	 * `betweenImportsPathDiffers(prevPath, currPath, level) → Bool` —
	 * true iff the two paths fall into different groups at the
	 * configured granularity. Drives the
	 * `@:fmt(blankLinesBetweenSameCtorByLevel(...))` cascade in
	 * `WriterLowering.triviaEofStarExpr`: the meta's last arg names
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
