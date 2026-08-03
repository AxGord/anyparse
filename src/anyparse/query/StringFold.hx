package anyparse.query;

/**
 * One plain string literal's folding ingredients: its `quote` character and its
 * `content` — the RAW inner source between the quotes (escapes and `$$`
 * preserved verbatim), so two same-`quote` literals fold by plain concatenation.
 */
typedef StringLiteral = {
	var quote: String;
	var content: String;
}

/**
 * One atom of a `+`-concatenation after operand expansion — the unit the
 * `fold-adjacent-string-literals` check groups. Decomposition either fully
 * decomposes an operand or REFUSES it (`segmentsOf` returns null for a shape it
 * cannot model); it never yields a partial one, so re-decomposing the check's own
 * output yields the SAME list and any deterministic grouping over it is idempotent
 * by construction.
 *
 * `SegText` carries the RAW inner source in ITS OWN quoting (escapes preserved
 * verbatim), so two same-`quote` texts concatenate by plain string append. A
 * lone `$` is normalised to the escaped `$$` form on the way in — otherwise
 * appending a text starting with a letter would silently create an interpolation.
 *
 * `SegIdent` is the `$name` shorthand: a bare identifier operand, or an `Ident`
 * fragment of an interpolated literal.
 *
 * `SegExpr` carries an expression's verbatim source plus `primary` — whether it
 * binds at least as tightly as concatenation, so `renderBare` may emit it WITHOUT
 * the parentheses a ternary or another lower-binding shape needs. The flag is read
 * off the NODE at decomposition time; re-deriving it from `src` would be a second,
 * worse parser. A source carrying a `$`, a line break, a backslash or an unbalanced
 * brace cannot go inside a `${ … }` block, so `renderGroup` refuses a group
 * containing one and the segment can only ever be emitted bare.
 */
enum ConcatSegment {
	SegText(quote: String, raw: String);
	SegIdent(name: String);
	SegExpr(src: String, primary: Bool);
}

/**
 * A grammar's string-literal capability, consumed by the
 * `fold-adjacent-string-literals` check — the seam that keeps it grammar-agnostic
 * (mirrors `NamingPolicy.NamingSupport`). A grammar with no string-concatenation
 * concept returns null from `GrammarPlugin.stringFoldSupport` and the check no-ops
 * for it.
 *
 * Two layers. `literalOf` answers the narrow "is this a PLAIN literal, and what is
 * its raw content" question that several other checks ask. `segmentsOf` /
 * `expressionSegment` decompose a construct into `ConcatSegment`s and `renderGroup`
 * / `renderBare` put a chosen grouping back together; that pair must ROUND-TRIP —
 * re-decomposing a rendered group has to yield the segments it came from — or the
 * width-aware check built on it stops being idempotent.
 */
@:nullSafety(Strict)
interface StringFoldSupport {

	/** The `QueryNode.kind` of the binary string-concatenation operator. */
	public function concatKind(): String;

	/**
	 * `node`'s quote + raw inner content when it is a PLAIN string literal — one
	 * with no interpolation, so concatenating its content into a sibling literal
	 * of the same quote is sound. Null otherwise (interpolated, non-literal, or
	 * unspanned). `source` is the file text the literal's span indexes into.
	 */
	public function literalOf(node: QueryNode, source: String): Null<StringLiteral>;

	/**
	 * `node` decomposed into its `ConcatSegment` pieces when it IS a string literal,
	 * else null. A plain literal yields one `SegText`; an interpolated one yields its
	 * child sequence mapped piece-per-fragment, so re-decomposing this check's OWN
	 * output reproduces the same list — the property idempotency rests on. `source` is
	 * the file text the spans index into.
	 *
	 * A null answer means two different things to the caller, and it knows which by the
	 * node's KIND: for a node it did not take for a literal, "treat it as a bare
	 * expression operand"; for one whose kind IS a string literal, "the seam cannot
	 * model this", and the caller abandons the whole construct rather than nesting a
	 * literal inside a `${ … }` block.
	 */
	public function segmentsOf(node: QueryNode, source: String): Null<Array<ConcatSegment>>;

	/**
	 * `node` as ONE `ConcatSegment` in expression position — `SegIdent` for a bare
	 * identifier, else `SegExpr` carrying its source and whether it binds tighter
	 * than concatenation (so a lone group can be emitted without parentheses).
	 * Null when the node has no span. A `Std.string(x)` wrapper is NOT unwrapped
	 * here; the caller does that before asking.
	 */
	public function expressionSegment(node: QueryNode, source: String): Null<ConcatSegment>;

	/**
	 * ONE group of consecutive segments rendered as a single concatenation
	 * operand: the plain literal `q + raws + q` when every segment is text of one
	 * shared quote `q` (so `"a" + "b"` still folds to `"ab"`, not `'ab'`), else one
	 * single-quoted interpolated literal. Null when a segment cannot be rendered
	 * into an interpolation (see `ConcatSegment.SegExpr`'s brace-safety note).
	 */
	public function renderGroup(segments: Array<ConcatSegment>): Null<String>;

	/**
	 * ONE segment rendered as a BARE `+` operand — the split direction — with
	 * parentheses added unless the segment is known to bind tighter than
	 * concatenation. Null for a text segment (text can only be a literal, never a
	 * bare operand).
	 */
	public function renderBare(segment: ConcatSegment): Null<String>;

}
