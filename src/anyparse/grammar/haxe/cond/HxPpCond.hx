package anyparse.grammar.haxe.cond;

/**
 * Where a Haxe preprocessor condition ends, declared once: `!`* (a blank, line breaks included, may follow each `!`)
 * and ONE operand — a parenthesised group at any depth, a quoted string, a dotted flag name or a number. A binary
 * operator outside parentheses is not part of it, so `#if lime && x` reads `lime` and an inline region
 * (`#if sys trace(1); #end`) keeps its body as code.
 *
 * Declared for its extent only: `HxPpCondScan` is generated from it, and `HxPpCondLit` captures the text it spans
 * verbatim. Nothing between two parts is skipped implicitly, so every blank the condition admits is a declared part.
 */
@:peg
enum HxPpCond {
	@:lead('!')
	Not(blank: HxPpCondBlank, operand: HxPpCond);
	Group(group: HxPpCondGroup);
	Quoted(text: HxPpCondQuoted);
	Flag(name: HxPpCondFlag);
	Number(text: HxPpCondNumber);
}
