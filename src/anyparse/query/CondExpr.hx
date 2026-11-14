package anyparse.query;

/**
 * A conditional-compilation condition as the operations `CondRegionLiveness` evaluates, in no grammar's spelling — the
 * one answer to "what does a directive's condition say". A grammar's `RefShape.conditionExpr` reads a condition's text
 * into it, so the three-valued evaluation over it is the same for every grammar.
 */
enum CondExpr {

	/** A define, a dotted name being one name. */
	Flag(name: String);

	/** A number literal's text. */
	Number(text: String);

	/** A string literal's content, its quotes removed and its escapes not decoded. */
	Text(content: String);

	/** The content of a version literal (Haxe `version("…")`), its escapes not decoded. */
	Version(content: String);
	Not(operand: CondExpr);

	/** A comparison, `op` spelled as `CondValues.compare` takes it (`==`, `!=`, `>`, `>=`, `<`, `<=`). */
	Compare(op: String, left: CondExpr, right: CondExpr);
	And(left: CondExpr, right: CondExpr);
	Or(left: CondExpr, right: CondExpr);

}
