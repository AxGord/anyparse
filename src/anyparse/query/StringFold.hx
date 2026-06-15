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
 * A grammar's adjacent-string-literal folding capability, consumed by the
 * `fold-adjacent-string-literals` check — the seam that keeps the check
 * grammar-agnostic (mirrors `NamingPolicy.NamingSupport`). A grammar with no
 * string-concatenation concept returns null from
 * `GrammarPlugin.stringFoldSupport` and the check no-ops for it.
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

}
