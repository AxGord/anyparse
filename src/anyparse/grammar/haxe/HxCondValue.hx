package anyparse.grammar.haxe;

/**
 * The VALUE of a Haxe preprocessor condition, declared once: `||` over `&&` over a comparison over `!` over one
 * operand — a parenthesised condition, `version("…")`, a quoted string, a possibly dotted flag or a number. A blank
 * (line breaks and block comments, `HxPpCondFormat`) may sit between any two tokens, as the compiler's lexer admits; a
 * `//` comment may not, so a condition holding one is not read.
 *
 * Comparisons are declared left-associative like every binary level, but the compiler's condition grammar takes ONE
 * comparison of two operands, so a comparison whose left operand is itself a comparison is a shape the reader of the
 * value refuses (`CondRegionLiveness`). `HxPpCond` is the sibling declaration of where a condition ENDS in raw text;
 * this one reads what a delimited condition MEANS.
 */
@:peg
@:schema(anyparse.grammar.haxe.HxPpCondFormat)
@:ws
enum HxCondValue {
	@:kw('version')
	@:lead('(')
	@:trail(')')
	VersionCall(raw: HxPpCondQuoted);
	@:wrap('(', ')')
	Group(inner: HxCondValue);
	Quoted(text: HxPpCondQuoted);
	Flag(name: HxPpCondFlag);
	Number(text: HxPpCondNumber);
	@:prefix('!')
	Not(operand: HxCondValue);
	@:infix('==', 3)
	Eq(left: HxCondValue, right: HxCondValue);
	@:infix('!=', 3)
	NotEq(left: HxCondValue, right: HxCondValue);
	@:infix('>=', 3)
	GtEq(left: HxCondValue, right: HxCondValue);
	@:infix('<=', 3)
	LtEq(left: HxCondValue, right: HxCondValue);
	@:infix('>', 3)
	Gt(left: HxCondValue, right: HxCondValue);
	@:infix('<', 3)
	Lt(left: HxCondValue, right: HxCondValue);
	@:infix('&&', 2)
	And(left: HxCondValue, right: HxCondValue);
	@:infix('||', 1)
	Or(left: HxCondValue, right: HxCondValue);
}
