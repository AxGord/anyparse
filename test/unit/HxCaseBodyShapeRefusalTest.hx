package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BodyPolicy;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-issue-423-mech-b — body-shape refusal of inline case-body.
 *
 * `HxCaseBranch.body` and `HxDefaultBranch.stmts` carry
 * `@:fmt(refuseFlatOnComplexExpr)`: the runtime `_flatCase` predicate
 * AND-s `!opt.caseBodyRefusesFlat(_arr[0].node)` (plugin-supplied
 * adapter wired in `HaxeFormat.defaultWriteOptions` to
 * `HxExprUtil.refusesCaseFlat`) so a single body statement whose
 * outermost expression is `&&` or `||` refuses inline regardless of
 * the dual flat-gate's verdict.
 *
 * Empirical scope (probed against fork CLI): only logical `And` /
 * `Or` make `dblDot.children.length > 1` in fork's token tree.
 * Arithmetic, comparison, bitwise, shift, null-coal, `is`, ternary,
 * and assignment variants nest hierarchically and stay inline. Tests
 * cover both directions — refusal for And/Or, allow for the rest.
 *
 * Per `feedback_unit_test_trivia_writer.md`: trivia pair only —
 * `HaxeModuleTriviaParser` / `HaxeModuleTriviaWriter`.
 */
@:nullSafety(Strict)
final class HxCaseBodyShapeRefusalTest extends Test {

	public function new(): Void {
		super();
	}

	public function testSimpleCallFlattensAtExpressionPosition(): Void {
		// Outer `case 1:` body is the inner switch (expression-position
		// for descendants). Inner case body = single Call — single-rooted,
		// not refused. expressionCase=Keep + same-line source → flatten.
		final src: String = 'class M { function f():Void { switch (x) { case 1: switch (y) { case 2: foo(); } } } }';
		final out: String = writeWithDefaults(src);
		Assert.isTrue(out.indexOf('case 2: foo();') != -1, 'simple call body must flatten at expression-position: <$out>');
	}

	public function testFieldAccessFlattensAtExpressionPosition(): Void {
		// Field access `A.B.C` is single-rooted (chained FieldAccess),
		// not refused.
		final src: String = 'class M { function f():Void { switch (x) { case 1: switch (y) { case 2: A.B.C; } } } }';
		final out: String = writeWithDefaults(src);
		Assert.isTrue(out.indexOf('case 2: A.B.C;') != -1, 'field-access chain must flatten at expression-position: <$out>');
	}

	public function testLogicalOrRefusesInlineAtExpressionPosition(): Void {
		// `A || B` is `Or(...)` → refused. Even with expressionCase=Keep
		// + same-line source, body must break.
		final src: String = 'class M { function f():Void { switch (x) { case 1: switch (y) { case 2: A || B; } } } }';
		final out: String = writeWithDefaults(src);
		Assert.isTrue(out.indexOf('case 2: A || B;') == -1, '|| must NOT flatten at expression-position: <$out>');
		Assert.isTrue(out.indexOf('case 2:\n') != -1, 'expected inner case 2 to break under shape refusal: <$out>');
	}

	public function testLogicalAndRefusesInlineAtExpressionPosition(): Void {
		// `A && B` is `And(...)` → refused — sibling check that refusal
		// covers both logical ops (`OpBoolAnd` / `OpBoolOr`).
		final src: String = 'class M { function f():Void { switch (x) { case 1: switch (y) { case 2: A && B; } } } }';
		final out: String = writeWithDefaults(src);
		Assert.isTrue(out.indexOf('case 2: A && B;') == -1, '&& must NOT flatten at expression-position: <$out>');
	}

	public function testArithmeticAddFlattensAtExpressionPosition(): Void {
		// `a + b` is `Add(...)` — NOT in refusal list (fork's token tree
		// nests arithmetic binops hierarchically — `dblDot` has one
		// child). Stays inline.
		final src: String = 'class M { function f():Void { switch (x) { case 1: switch (y) { case 2: a + b; } } } }';
		final out: String = writeWithDefaults(src);
		Assert.isTrue(out.indexOf('case 2: a + b;') != -1, 'arithmetic chain must flatten at expression-position: <$out>');
	}

	public function testTernaryFlattensAtExpressionPosition(): Void {
		// Ternary nests under a single root child — fork allows inline.
		final src: String = 'class M { function f():Void { switch (x) { case 1: switch (y) { case 2: a ? b : c; } } } }';
		final out: String = writeWithDefaults(src);
		Assert.isTrue(out.indexOf('case 2: a ? b : c;') != -1, 'ternary must flatten at expression-position: <$out>');
	}

	public function testAssignFlattensAtExpressionPosition(): Void {
		// `a = b` (`Assign`) — fork allows inline. Confirms the slice
		// does NOT regress `issue_452_braceless_function_with_switch`'s
		// `case null: handlers[name] = [];` inline shape.
		final src: String = 'class M { function f():Void { switch (x) { case 1: switch (y) { case 2: a = b; } } } }';
		final out: String = writeWithDefaults(src);
		Assert.isTrue(out.indexOf('case 2: a = b;') != -1, 'assignment must flatten at expression-position: <$out>');
	}

	public function testPrefixUnaryFlattensAtExpressionPosition(): Void {
		// `!A` is `Not(...)` — prefix unop, NOT in refusal list. Stays
		// inline.
		final src: String = 'class M { function f():Void { switch (x) { case 1: switch (y) { case 2: !A; } } } }';
		final out: String = writeWithDefaults(src);
		Assert.isTrue(out.indexOf('case 2: !A;') != -1, 'prefix unop must flatten at expression-position: <$out>');
	}

	public function testRefusalSurvivesCaseBodySameOverride(): Void {
		// At STATEMENT-position with caseBody=Same, refusal still wins —
		// `Same` would unconditionally flatten, but the AND-clause aborts
		// inline for logical chains. Confirms the refusal AND-s with the
		// dispatched gate, not OR-s past it.
		final src: String = 'class M { function f():Void { switch (x) { case 1: A || B; } } }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.caseBody = BodyPolicy.Same;
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('case 1: A || B;') == -1, 'refusal must override caseBody=Same: <$out>');
	}

	private inline function writeWithDefaults(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
