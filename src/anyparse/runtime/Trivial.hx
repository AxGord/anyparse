package anyparse.runtime;

/**
 * Source-fidelity wrapper for an AST node in Trivia-mode parsers.
 *
 * Generated Trivia-mode parsers emit `Array<Trivial<HxStatement>>` for
 * `@:trivia`-annotated Star containers, instead of the Plain-mode
 * `Array<HxStatement>`. The type distinction is compile-time: a function
 * that consumes plain statements cannot accidentally receive trivia-wrapped
 * ones, and vice versa.
 *
 * Comment **text** is captured verbatim for leading comments — the open
 * and close delimiters are retained in the string (line-style `//…`,
 * block-style `/*…*\/`) so the writer can round-trip source style
 * without style-guessing heuristics. Trailing comments (a single same-
 * line comment after the node) store the body only, with delimiters
 * stripped — trailing capture rejects internal newlines, so line style
 * is always safe at emit time and storing delimiters would just be
 * noise.
 *
 * Comment **position** IS stored (leading vs trailing) because it encodes
 * semantically meaningful authorial intent — unit annotations on a value,
 * branch labels, section headers, TODO markers each live in a specific
 * position for a reason. Collapsing position at parse time would prevent
 * writer policies from reproducing the author's layout.
 *
 * Fields:
 *  - `blankBefore` — at least one blank source line preceded the node
 *    (or its first leading comment, if any). Writer uses this to emit a
 *    separator-level blank when preserving source grouping. Bool over
 *    Int is a YAGNI choice: haxe-formatter (and most style guides in
 *    the Haxe ecosystem) collapse multiple blanks to max one; grammars
 *    that need N>1 (Python PEP8 style) can promote this to `Int` when
 *    they land.
 *  - `blankAfterLeadingComments` — at least one blank source line sat
 *    between the last captured leading comment and the node itself.
 *    Distinct from `blankBefore` so the writer can place the blank
 *    line in the correct position when the source has
 *    `\n\n// comment\n\nnode` (blank both sides) — `blankBefore` alone
 *    would force the writer to choose one side. False when
 *    `leadingComments` is empty.
 *  - `newlineBefore` — at least one source newline preceded the node
 *    (including the blank-line case where `blankBefore` is also true).
 *    Semantically the one-newline cousin of `blankBefore`: writers that
 *    allow elements on the same line by default (`sepExpr = space`)
 *    consult this to upgrade the separator to a hardline when the source
 *    had `prevElem\n  elem` — preserving the boundary without forcing a
 *    blank.
 *  - `leadingComments` — zero or more comments attached above the node,
 *    in source order. Each string carries its open/close delimiters
 *    verbatim (`// foo` or `/* foo *\/`); the writer emits the captured
 *    string as-is with one runtime post-process for javadoc-style
 *    close normalization on multi-line blocks.
 *  - `trailingComment` — a single same-line comment after the node (the
 *    ` seconds` body of `// seconds` attached to `var timeout = 30;`).
 *    Body only, delimiters stripped; the writer emits `// <body>`.
 *    Null when absent.
 *    Only one trailing slot: multiple comments on the same trailing
 *    line are unusual enough to collapse into a single slot.
 *  - `node` — the wrapped AST node itself.
 *
 * Shape is flat (no inner `trivia` struct) — until an actual use case
 * emerges for trivia-without-a-node, keeping trivia fields as siblings
 * of `node` avoids one concept and one nesting level in generated code
 * and consumer sites.
 */
typedef Trivial<T> = {
	var blankBefore:Bool;
	var blankAfterLeadingComments:Bool;
	var newlineBefore:Bool;
	var leadingComments:Array<String>;
	var trailingComment:Null<String>;
	var node:T;
}
