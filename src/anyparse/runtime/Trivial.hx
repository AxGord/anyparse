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
 * Comment **text** is captured verbatim for both leading and trailing
 * comments — open and close delimiters are retained in the string
 * (line-style `//…`, block-style `/*…*\/`) so the writer can
 * round-trip source style without style-guessing heuristics. The
 * writer dispatches block-vs-line emission shape from the captured
 * prefix (`/*` vs `//`); a stripped body would force lossy
 * normalisation to line style at emit time.
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
 *  - `trailingComment` — a single same-line comment after the node
 *    (`// seconds` attached to `var timeout = 30;`, or `/*c*/` inline
 *    before a separator). Captured VERBATIM with delimiters intact;
 *    the writer emits via `trailingCommentDocVerbatim`. Null when
 *    absent. Only one trailing slot: multiple comments on the same
 *    trailing line are unusual enough to collapse into a single slot.
 *    Trailing capture rejects block comments with internal newlines —
 *    a newline-bearing block is left for the next element's leading
 *    capture, so this slot never carries `\n`.
 *  - `sepAfter` — source had a separator (e.g. `,`) immediately AFTER
 *    this element, before either the next element's leading trivia or
 *    the close literal. Defaults to `true` so non-tracking sites
 *    (postfix args, tryparse Stars, raw→paired bridge) preserve the
 *    legacy "always emit sep" behaviour. Sites that actually capture
 *    source presence (`@:sep` + `@:trivia` + `@:trail` Stars at
 *    `emitTriviaStarFieldSteps` and the matching Alt path) store the
 *    real `matchLit` result so the writer can suppress inter-element
 *    commas the source intentionally omitted (lineends/issue_111).
 *    Sister to the Star's own `trailPresent:Bool` synth slot — last
 *    element's `sepAfter` is the same value, kept separate to avoid
 *    cross-coupling existing trailing-comma logic.
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
	var sepAfter:Bool;
	var node:T;
}
