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
	indentChar:IndentChar,

	/**
	 * Columns per indent level when `indentChar = Space`.
	 */
	indentSize:Int,

	/**
	 * Logical width of one tab character in columns. Used when
	 * `indentChar = Tab` to decide nesting width for line-fit
	 * calculations.
	 */
	tabWidth:Int,

	/**
	 * Target line width used by the Wadler-style renderer to pick
	 * between flat and broken layout for groups.
	 */
	lineWidth:Int,

	/**
	 * End-of-line sequence emitted by the writer for every break-mode
	 * `Line` / `OptHardline` (and as the trailing newline when
	 * `finalNewline` is true). Honored by `Renderer.render` directly.
	 * For Haxe grammar, fed by `lineEnds.lineEndCharacter` config:
	 * `"LF"` → `\n`, `"CRLF"` → `\r\n`, `"CR"` → `\r`, `"auto"` falls
	 * back to `\n` (no source-detection plumbing).
	 */
	lineEnd:String,

	/**
	 * Whether the output ends with a newline. Declared in σ;
	 * honored once the renderer gains final-newline awareness.
	 */
	finalNewline:Bool,

	/**
	 * When `true`, blank lines between content carry the surrounding
	 * block's indent rather than rendering bare. Opt-in gate on top of
	 * the renderer's default deferred-indent, which silently drops
	 * indent on empty rows. Matches haxe-formatter's
	 * `indentation.trailingWhitespace` knob; default `false` keeps every
	 * other corpus case byte-identical.
	 */
	trailingWhitespace:Bool,

	/**
	 * Output wrap style for multi-line block comments. `Plain` emits
	 * `/*…*\/` with content-only interior lines; `Javadoc` emits
	 * `/**…**\/` with ` * ` markers on each content line. The parser
	 * strips both `*` markers and leading whitespace at capture time,
	 * so this knob fully drives the output appearance — source style
	 * is not echoed.
	 */
	commentStyle:CommentStyle,

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
	addLineCommentSpace:Bool,

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
	compressSuccessiveParenthesis:Bool,

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
	arrayMatrixWrap:ArrayMatrixWrap,

	/**
	 * Indentation policy for preprocessor conditional-compilation
	 * (`#if`/`#elseif`/`#else`/`#end`) blocks. See
	 * `ConditionalIndentationPolicy`. Default `Aligned` keeps the writer
	 * byte-identical to the pre-policy behaviour (markers and body both
	 * at the surrounding statement indent). Fed by haxe-formatter's
	 * `indentation.conditionalPolicy` knob through `HaxeFormatConfigLoader`;
	 * format-neutral so any preprocessor-conditional grammar can reuse it.
	 */
	conditionalPolicy:ConditionalIndentationPolicy,

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
	maxConsecutiveBlanks:Int,

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
	?blockCommentAdapter:Null<(String, WriteOptions) -> Doc>,
	?lineCommentAdapter:Null<(String, Bool) -> String>,

	/**
	 * Plugin-supplied AST shape predicates bound at runtime. Read by
	 * conditionally-emitted writer helpers — currently only the
	 * `@:fmt(trailOptShapeGate(...))` knob on `@:trailOpt(...)` ctors.
	 * `Dynamic` argument because the same adapter must accept both
	 * Plain-mode AST nodes (raw enum values) and Trivia-mode nodes
	 * (`Trivial<...>` struct wrappers around paired-enum values); the
	 * plugin implementation pattern-matches the runtime form.
	 *
	 *  - `endsWithCloseBrace(raw) → Bool` — true iff the writer output
	 *    for `raw` ends with a `}`. Drives the var/final-rhs `;` gate
	 *    so `var x = switch (y) { ... }` round-trips without a trailing
	 *    semicolon, matching haxe-formatter's canonical output.
	 *
	 *  - `caseBodyRefusesFlat(raw) → Bool` — true iff the body's first
	 *    element should refuse inline emission regardless of the
	 *    `bodyPolicy` flat-gate verdict. Drives `@:fmt(refuseFlatOnComplexExpr)`
	 *    on `@:trivia @:tryparse` Star fields (case / default body):
	 *    even when `expressionCase=Keep` + same-line source would
	 *    flatten, an outermost shape the plugin classifies as
	 *    "complex" (Haxe: logical `&&` / `||`) breaks. Mirrors fork's
	 *    `MarkSameLine.markExpressionCase` body-shape heuristic.
	 *
	 *  - `betweenImportsPathDiffers(prevPath, currPath, level) → Bool` —
	 *    true iff the two paths fall into different groups at the
	 *    configured granularity. Drives the
	 *    `@:fmt(blankLinesBetweenSameCtorByLevel(...))` cascade in
	 *    `WriterLowering.triviaEofStarExpr`: the meta's last arg names
	 *    this opt field, the engine emits a pure
	 *    `opt.betweenImportsPathDiffers(prev, curr, level)` call. Args
	 *    are primitive (`String` paths + `Int` level) so the engine
	 *    stays format-neutral; the plugin's typed-enum helper plugs in
	 *    via the underlying-Int representation of its level enum
	 *    (e.g. `enum abstract HxBetweenImportsLevel(Int) from Int to Int`).
	 *
	 *  - `betweenImportsTailLeafClassify(payload) → Null<{ctorName,path}>` —
	 *    classifies the tail leaf decl of a "transparent" wrapper ctor
	 *    (e.g. `HxDecl.Conditional(inner:HxConditionalDecl)`). Drives
	 *    the `@:fmt(blankLinesBetweenSameCtorTailTransparent(...))`
	 *    extension to the between-cascade in
	 *    `WriterLowering.triviaEofStarExpr`: when the current element
	 *    matches the transparent ctor name, the engine emits a runtime
	 *    `opt.<adapterField>(payload)` call instead of resetting
	 *    `_currTailKindBetween/_currTailPathBetween` to (0,''). The plugin
	 *    walks the wrapper's body Stars (last non-empty branch's last
	 *    decl, recursively unwrapping nested wrappers) and returns the
	 *    leaf's ctor name + first-positional-arg path String, or
	 *    `null` when no leaf is recognised. The engine does the per-
	 *    info ctor-name match at runtime — `_r.ctorName == 'CtorA' ||
	 *    _r.ctorName == 'CtorB'` derived from each between info's own
	 *    ctorNames list — so the same adapter feeds multiple between
	 *    infos on the same Star (e.g. one walker shared by Imports +
	 *    Usings infos). Mirrors `betweenImportsPathDiffers` pattern:
	 *    format-neutral engine, primitive return shape, plugin handles
	 *    the AST traversal.
	 *
	 *  - `betweenImportsHeadLeafClassify(payload) → Null<{ctorName,path}>` —
	 *    head-side mirror of `betweenImportsTailLeafClassify`. Drives
	 *    `@:fmt(blankLinesBetweenSameCtorHeadTransparent(...))` and the
	 *    cross-subset transition cascade
	 *    (`@:fmt(blankLinesOnTransitionAcross(...))`) by classifying the
	 *    HEAD leaf decl of a transparent wrapper (first non-empty branch's
	 *    first element, recursing into nested wrappers head-first). Used
	 *    at curr-side classification — what the wrapper "starts with" for
	 *    the prev→curr boundary decision in this iteration. Tail-walker
	 *    feeds the next iteration's prev side; head-walker feeds this
	 *    iteration's curr side. Together they cover bidirectional
	 *    transparency for a `Conditional` containing imports/usings.
	 *
	 *  - `arrayBracketKind(raw) → Int` — classifies the first element of
	 *    an array-`[…]` ctor into a bracket kind code so the writer picks
	 *    the matching interior-spacing policy (one grammar ctor covers
	 *    array-literal / map-literal / comprehension; the kind is decided
	 *    by element shape at write time). Drives `@:fmt(bracketKindPad)`
	 *    on the array-literal ctor: the writer reads the kind, then
	 *    selects the corresponding `*BracketsOpen` / `*BracketsClose`
	 *    policy field. Returns the default kind (0) for null / non-enum
	 *    shapes — the tight bracket has no padding either way.
	 *
	 * Formats that don't opt into a gate leave the field null; the
	 * writer helper checks `null` before invoking and falls back to
	 * the unconditional non-refusal path.
	 */
	?endsWithCloseBrace:Null<Dynamic -> Bool>,
	?caseBodyRefusesFlat:Null<Dynamic -> Bool>,
	?betweenImportsPathDiffers:Null<(String, String, Int) -> Bool>,
	?betweenImportsTailLeafClassify:Null<Dynamic -> Null<{ctorName:String, path:String}>>,
	?betweenImportsHeadLeafClassify:Null<Dynamic -> Null<{ctorName:String, path:String}>>,
	?arrayBracketKind:Null<Dynamic -> Int>,
	/**
	 * `elementIsConditional(elementNode) → Bool` — true iff a cond-comp
	 * body / elseBody Star element is itself a nested preprocessor
	 * `Conditional`. Drives the `alignedNestedIncrease` indent rule:
	 * under that policy the engine wraps a nested-conditional element
	 * (markers + body) one indent step deeper than the surrounding
	 * region, accumulating per conditional depth (top-level → no shift).
	 * Null (every non-opt-in format) → the engine never wraps, byte-
	 * identical to the pre-policy layout.
	 */
	?elementIsConditional:Null<Dynamic -> Bool>,
};
