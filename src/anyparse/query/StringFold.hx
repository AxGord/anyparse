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
 * A `+`-concatenation operand classified for the `prefer-interpolation`
 * chain fold. `StringLit` carries the quote char and the RAW inner source
 * (between the quotes); the check applies its own single-quoted-context
 * escaping. `InterpolatedStringLit` is a single-quoted literal that itself
 * contains interpolation — the chain is left alone. `NonStringOperand` is
 * anything else (identifier, call, arithmetic, ...).
 */
enum ConcatOperand {
	StringLit(quote: String, rawContent: String);
	InterpolatedStringLit;
	NonStringOperand;
}

/**
 * A grammar's string-concatenation folding capability, consumed by the
 * `fold-adjacent-string-literals` and `prefer-interpolation` checks — the seam
 * that keeps them grammar-agnostic (mirrors `NamingPolicy.NamingSupport`). A
 * grammar with no string-concatenation concept returns null from
 * `GrammarPlugin.stringFoldSupport` and the checks no-op for it.
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

	/** Classify `node` as a `+`-concatenation operand (see `ConcatOperand`). */
	public function stringConcatOperand(node: QueryNode, source: String): ConcatOperand;

}
