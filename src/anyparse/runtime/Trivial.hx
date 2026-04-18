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
 * Comment **text** is captured verbatim (no delimiters, no leading space
 * trimming). Comment **style** (`//` line vs `/* */` block) is deliberately
 * NOT stored — that is a writer policy concern, and preserving the source
 * style would leak grammar-author decisions into format-consumer decisions.
 *
 * Comment **position** IS stored (leading vs trailing) because it encodes
 * semantically meaningful authorial intent — unit annotations on a value,
 * branch labels, section headers, TODO markers each live in a specific
 * position for a reason. Collapsing position at parse time would prevent
 * writer policies from reproducing the author's layout.
 *
 * Fields:
 *  - `blankBefore` — at least one blank source line preceded the node.
 *    Writer uses this to emit a separator-level blank when preserving
 *    source grouping. Bool over Int is a YAGNI choice: haxe-formatter
 *    (and most style guides in the Haxe ecosystem) collapse multiple
 *    blanks to max one; grammars that need N>1 (Python PEP8 style)
 *    can promote this to `Int` when they land.
 *  - `leadingComments` — zero or more comments attached above the node,
 *    in source order. Text content only; writer chooses line vs block
 *    style per context policy.
 *  - `trailingComment` — a single same-line comment after the node (the
 *    `// seconds` attached to `var timeout = 30;`). Null when absent.
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
	var leadingComments:Array<String>;
	var trailingComment:Null<String>;
	var node:T;
}
