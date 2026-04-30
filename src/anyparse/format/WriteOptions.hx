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
	 * End-of-line sequence emitted by the writer. Declared in σ;
	 * honored once the renderer gains line-ending awareness.
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
	 * `anyparse.format.text.BlockCommentNormalizer.processCapturedBlockComment` /
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
	 * Formats that don't opt into the gate leave this null; the writer
	 * helper checks `null` before invoking and falls back to the
	 * unconditional trail emission.
	 */
	?endsWithCloseBrace:Null<Dynamic -> Bool>,
};
