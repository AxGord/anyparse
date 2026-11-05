package anyparse.macro;

/** The tree of a regex pattern `RegexScanReader` can read. Every quantifier in it is greedy. */
enum ScanNode {

	/** One code unit out of the set. */
	Chars(set: CodeSet);

	Seq(items: Array<ScanNode>);

	Alt(branches: Array<ScanNode>);

	/** `?` (`min` 0, not `many`), `*` (`min` 0, `many`) or `+` (`min` 1, `many`). */
	Repeat(body: ScanNode, min: Int, many: Bool);

	/** `(?=body)`, or `(?!body)` when `negative`. */
	Ahead(body: ScanNode, negative: Bool);

	/** `\b`. */
	WordBoundary;

}
