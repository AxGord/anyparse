package anyparse.runtime;

/**
 * Source-fidelity wrapper for an AST node in Trivia-mode parsers. Generated Trivia-mode
 * parsers emit `Array<Trivial<HxStatement>>` for `@:trivia`-annotated Star containers instead
 * of the Plain-mode `Array<HxStatement>`; the type distinction is compile-time, so a function
 * that consumes plain statements cannot accidentally receive trivia-wrapped ones.
 *
 * Comment TEXT is captured verbatim for both leading and trailing comments — open and close
 * delimiters retained (`//…`, `/*…*\/`) so the writer dispatches block-vs-line emission from
 * the captured prefix and round-trips source style without style-guessing heuristics.
 * Comment POSITION is stored (leading vs trailing) because it encodes authorial intent — unit
 * annotations on a value, branch labels, section headers each live in a specific position —
 * and collapsing it at parse time would prevent writer policies from reproducing the layout.
 *
 * The blank / newline flags are `Bool`, not counts: haxe-formatter and most Haxe style guides
 * collapse multiple blanks to at most one; a grammar that needs N > 1 promotes the field when
 * it lands. `blankBefore` and `blankAfterLeadingComments` are distinct so the writer can place
 * the blank on the right side of `\n\n// comment\n\nnode`; `newlineBefore` is the one-newline
 * cousin that upgrades a space separator to a hardline. The `@:optional` fields are set only
 * by the one Star loop that can compute them and read as `false` everywhere else, so every
 * other `Trivial<T>` literal site stays byte-identical. The shape is flat (no inner `trivia`
 * struct): until a use case for trivia-without-a-node emerges, siblings of `node` avoid one
 * concept and one nesting level in generated code and consumer sites.
 */
typedef Trivial<T> = {
	/**
	 * At least one blank source line preceded the node — or its first leading comment when it has any; the writer
	 * emits a separator-level blank from it when preserving source grouping.
	 */
	var blankBefore: Bool;
	@:optional var blankBefore2: Int;

	/**
	 * At least one blank source line sat between the last captured leading comment and the node; always `false`
	 * when `leadingComments` is empty.
	 */
	var blankAfterLeadingComments: Bool;

	/**
	 * At least one source newline preceded the node — true whenever `blankBefore` is; a writer whose default
	 * separator is a space reads it to upgrade that separator to a hardline.
	 */
	var newlineBefore: Bool;
	var leadingComments: Array<String>;

	/**
	 * A single same-line comment after the node (`// seconds` on `var timeout = 30;`, or an inline
	 * `/*c*\/` before a separator), captured VERBATIM with delimiters intact; null when absent. One
	 * slot only. Trailing capture rejects a block comment with internal newlines — it is left for
	 * the next element's leading capture, so this slot never carries `\n`.
	 */
	var trailingComment: Null<String>;

	/**
	 * True when the captured `trailingComment` sat between the element and the separator in source
	 * (`elem /*c*\/, next`), false when after the separator (`elem, /*c*\/`). Default `false` keeps
	 * the after-sep emission position; sites that capture before-sep trivia set `true` so the
	 * writer routes the comment to the source-faithful position. Ignored when `trailingComment` is
	 * null; sister of `sepAfter`.
	 */
	var trailingBeforeSep: Bool;

	/**
	 * Source had a separator (e.g. `,`) immediately AFTER this element, before the next element's
	 * leading trivia or the close literal. Defaults to `true` so non-tracking sites (postfix args,
	 * tryparse Stars, the raw→paired bridge) keep "always emit sep"; the `@:sep` + `@:trivia` +
	 * `@:trail` Stars store the real `matchLit` result so the writer can suppress an inter-element
	 * comma the source omitted. The last element's value equals the Star's own `trailPresent`
	 * synth slot, kept separate so trailing-comma logic stays uncoupled.
	 */
	var sepAfter: Bool;

	/**
	 * At least one source newline sat AFTER this element's leading separator literal (the
	 * `@:lead(',')` of a link such as `HxVarMore`), before the link payload — the forward-looking
	 * cousin of `newlineBefore`: for a link whose first token is the separator, `newlineBefore`
	 * records the gap BEFORE the comma, while the break a `Keep` wrap must reproduce lands AFTER it.
	 * Consumed ONLY under `WrapMode.Keep`; byte-inert for every non-keep construct.
	 */
	@:optional var newlineAfterSep: Bool;

	/**
	 * The LAST captured leading comment sat on the SAME source line as the node AND is block-style —
	 * the `/* c *\/ field` glue intent, so the writer keeps the comment on the field's line instead
	 * of force-breaking after it. A line-style `//` leading comment always ends its source line and
	 * is never glued.
	 */
	@:optional var leadingCommentsGlued: Bool;
	var node: T;
}
