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
 * A grammar may also cut text at its own line-break ESCAPE, and at each SEPARATOR
 * boundary its text carries (a space run, a comma, an opening bracket) — together those
 * are what give a literal carrying no interpolation any seam at all. The pieces still
 * append, so re-rendering is value-identical either way. The space and comma cuts also
 * re-arise identically on re-decomposition; a bracket cut reads its space/comma
 * INTRODUCER, which a group boundary can strand in the previous piece, so re-decomposing
 * an output can yield a COARSER list — a lost seam stays lost, which is what keeps the
 * grouping idempotent.
 *
 * `SegIdent` is the `$name` shorthand: a bare identifier operand, or an `Ident`
 * fragment of an interpolated literal.
 *
 * `SegExpr` carries an expression's verbatim source plus `primary` — whether it
 * binds at least as tightly as concatenation, so `renderBare` may emit it WITHOUT
 * the parentheses a ternary or another lower-binding shape needs. The flag is read
 * off the NODE at decomposition time; re-deriving it from `src` would be a second,
 * worse parser. A source carrying a bare `$` outside a nested string
 * literal, a line break, a backslash, an unbalanced brace or an unbalanced QUOTE (a regex literal can carry one) cannot go inside a `${ … }` block, so `renderGroup` refuses a group containing one and the
 * segment can only ever be emitted bare; a `$` INSIDE a nested string is
 * harmless — the block's re-parse reads it exactly as the bare operand did. A source
 * carrying the interpolation host's OWN quote is kept out by the same mechanism for a
 * different reason: it lexes fine and reads badly.
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
	 * `literal` re-spelled with `quote` as its delimiter and its raw content copied
	 * VERBATIM, or null when that copy would not denote the same string — the
	 * "can this literal simply change quotes" question `prefer-single-quotes` asks.
	 *
	 * It belongs to the grammar and not to the caller because the answer is pure
	 * lexer knowledge: which characters end the target quoting, and which of them a
	 * content byte can spell INDIRECTLY. Haxe decodes `\x24` to `$` before it scans a
	 * single-quoted literal for interpolation, so a raw scan for `$` passes a content
	 * that starts interpolating the moment it changes quotes — a silent VALUE change,
	 * which is what this seam exists to make impossible for every caller at once.
	 *
	 * Returns the WHOLE new literal text (delimiters included), so a grammar whose
	 * quoting is not a single character on each side can still answer.
	 */
	public function requoteVerbatim(literal: StringLiteral, quote: String): Null<String>;

	/**
	 * `node` decomposed into its `ConcatSegment` pieces when it IS a string literal,
	 * else null. A plain literal yields its text cut at each line-break escape and each
	 * separator boundary; an interpolated one yields its child sequence mapped
	 * piece-per-fragment. Re-decomposing this check's OWN output reproduces the same list,
	 * except that a bracket cut whose introducer a group boundary stranded in the previous
	 * piece loses its seam — the list only gets COARSER, so grouping stays idempotent (see
	 * `ConcatSegment`). `source` is the file
	 * text the spans index into.
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

	/**
	 * Whether a call written as the bare, unqualified name `name` reads its ARGUMENTS AS
	 * SYNTAX rather than as values — the question the fold asks about a callee NOTHING in
	 * the resolution scope declares.
	 *
	 * It belongs to the grammar because the answer is a naming CONVENTION, not a fact any
	 * index carries: a compiler intrinsic has no declaration anywhere to resolve to, which
	 * is exactly why the fold's macro gate — which refuses a name some `macro` member
	 * declares, and a name an import could route out of scope — clears it. A gate that
	 * passes on an unresolvable callee is fail-OPEN, and the target intrinsics are the one
	 * family that never resolves by construction.
	 *
	 * Measured on Haxe 4.3.7, `untyped __lua__("{x=" + "1}")` compiles CLEAN and emits
	 * `__lua__(Std.string("{x=") .. Std.string("1}"))` — a call to a Lua function no runtime
	 * declares; `__python__` does the same; `js.Syntax.code` rejects it with "must be a
	 * string constant". So the concatenation is refused whether the target errors or not.
	 *
	 * A grammar with no such convention answers `false` for every name and the gate stays
	 * exactly as wide as it was.
	 */
	public function readsArgumentsAsSyntax(name: String): Bool;

}
