package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.runtime.ParseError;

/**
 * Expression-position ident atom is keyword-guarded (`HxExprIdentLit`):
 * a control-flow keyword can no longer be re-matched as a bare
 * identifier when its structured keyword-atom branch fail-rewinds —
 * `if (a == b)` with no then-branch must FAIL instead of mis-parsing
 * as `Call(IdentExpr if, …)`. The mis-parse used to poison ordered
 * choice: a bare if-head token-splice conditional
 * (`#if x if (cond) #end stmt;`) was "successfully" consumed by the
 * structured `Conditional` statement, so the `CondSpliceStmt` fallback
 * never fired.
 *
 * Fallout covered here too: `break;` / `continue;` used to ride
 * `ExprStmt(IdentExpr)` — they are dedicated `BreakStmt` /
 * `ContinueStmt` ctors now; reification-headed `for` patterns
 * (`for ($head) $body`, `for ($i{_} in $_) $_`) used to ride the same
 * `Call(IdentExpr for, …)` mis-parse — they are `ForReifExpr` now.
 */
@:nullSafety(Strict)
final class HxExprIdentGuardSliceTest extends Test {

	public function new(): Void {
		super();
	}

	public function testControlFlowKeywordRejectedAsIdentAtom(): Void {
		Assert.raises(() -> HaxeModuleParser.parse('class C { var x = f(if); }'), ParseError);
		Assert.raises(() -> HaxeModuleParser.parse('class C { var x = f(else); }'), ParseError);
		Assert.raises(() -> HaxeModuleParser.parse('class C { var x = f(break); }'), ParseError);
	}

	public function testKeywordPrefixedIdentsStillMatch(): Void {
		final src: String = 'class C {\n\tvar x = f(iffy, variance, catchAll, defaultValue);\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testBreakContinueParseAsDedicatedStmts(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\twhile (true) {\n\t\t\tbreak;\n\t\t\tcontinue;\n\t\t}\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testBareIfHeadSpliceFallsToCondSpliceStmt(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\t#if js if (a == b) #end c = 0;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testForReifWholeHead(): Void {
		final src: String = "class C {\n\tvar x = macro for ($head) $body;\n}";
		Assert.equals(src, triviaWrite(src));
	}

	public function testForReifIteratorVar(): Void {
		final src: String = "class C {\n\tvar x = macro for ($i{_} in $_) $_;\n}";
		Assert.equals(src, triviaWrite(src));
	}

	public function testForReifMapValueSlot(): Void {
		final src: String = "class C {\n\tvar x = macro [for (key => $i{a.name} in $i{b}) key];\n}";
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
