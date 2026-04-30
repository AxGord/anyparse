package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BodyPolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-case-body-policy — `opt.caseBody:BodyPolicy` and
 * `opt.expressionCase:BodyPolicy` driving single-stmt-flat emission of
 * `HxCaseBranch.body` / `HxDefaultBranch.stmts`. The two knobs feed the
 * same Star body site at runtime — `triviaTryparseStarExpr` ORs the
 * `Same` predicate across both and downgrades the `nestBody` wrap to
 * an inline ` <stmt>` when the body has exactly one element with no
 * leading or orphan-trailing trivia.
 *
 * Only `Same` and `Next` are wired in this slice. `FitLine` and `Keep`
 * fall through to the `Next` path.
 *
 * Per `feedback_unit_test_trivia_writer.md`: the knobs are visible only
 * via `HaxeModuleTriviaParser`/`HaxeModuleTriviaWriter` — the plain
 * writer takes a different lowering path that does not call
 * `triviaTryparseStarExpr`.
 */
@:nullSafety(Strict)
final class HxCaseBodyPolicySliceTest extends Test {

	public function new():Void {
		super();
	}

	public function testDefaultIsNext():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(BodyPolicy.Next, defaults.caseBody);
		Assert.equals(BodyPolicy.Next, defaults.expressionCase);
	}

	public function testNextKeepsSingleStmtMultiline():Void {
		final src:String = 'class M { function f():Void { switch (x) { case 1: foo(); } } }';
		final out:String = writeWithCaseBody(src, BodyPolicy.Next);
		Assert.isTrue(out.indexOf('case 1:\n') != -1, 'expected multiline `case 1:\\n` in: <$out>');
		Assert.isTrue(out.indexOf('case 1: foo();') == -1, 'did not expect inline `case 1: foo();` in: <$out>');
	}

	public function testCaseBodySameFlattensSingleStmt():Void {
		final src:String = 'class M { function f():Void { switch (x) { case 1: foo(); } } }';
		final out:String = writeWithCaseBody(src, BodyPolicy.Same);
		Assert.isTrue(out.indexOf('case 1: foo();') != -1, 'expected inline `case 1: foo();` in: <$out>');
	}

	public function testExpressionCaseSameFlattensSingleStmt():Void {
		final src:String = 'class M { function f():Void { switch (x) { case 1: foo(); } } }';
		final out:String = writeWithExpressionCase(src, BodyPolicy.Same);
		Assert.isTrue(out.indexOf('case 1: foo();') != -1, 'expected inline `case 1: foo();` (expressionCase=Same) in: <$out>');
	}

	public function testSameKeepsMultiStmtMultiline():Void {
		final src:String = 'class M { function f():Void { switch (x) { case 1: foo(); bar(); } } }';
		final out:String = writeWithCaseBody(src, BodyPolicy.Same);
		Assert.isTrue(out.indexOf('case 1: foo();') == -1, 'multi-stmt body must not flatten in: <$out>');
		Assert.isTrue(out.indexOf('case 1:\n') != -1, 'expected multiline `case 1:\\n` for multi-stmt in: <$out>');
	}

	public function testDefaultBranchSameFlattensSingleStmt():Void {
		final src:String = 'class M { function f():Void { switch (x) { default: foo(); } } }';
		final out:String = writeWithCaseBody(src, BodyPolicy.Same);
		Assert.isTrue(out.indexOf('default: foo();') != -1, 'expected inline `default: foo();` in: <$out>');
	}

	public function testConfigLoaderMapsCaseBodySame():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"caseBody": "same"}}'
		);
		Assert.equals(BodyPolicy.Same, opts.caseBody);
		Assert.equals(BodyPolicy.Next, opts.expressionCase);
	}

	public function testConfigLoaderMapsExpressionCaseSame():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"expressionCase": "same"}}'
		);
		Assert.equals(BodyPolicy.Same, opts.expressionCase);
		Assert.equals(BodyPolicy.Next, opts.caseBody);
	}

	public function testConfigLoaderEmptyKeepsDefaults():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(BodyPolicy.Next, opts.caseBody);
		Assert.equals(BodyPolicy.Next, opts.expressionCase);
	}

	public function testBothKnobsSameStillFlattens():Void {
		final src:String = 'class M { function f():Void { switch (x) { case 1: foo(); } } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.caseBody = BodyPolicy.Same;
		opts.expressionCase = BodyPolicy.Same;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('case 1: foo();') != -1, 'expected inline `case 1: foo();` (both knobs Same) in: <$out>');
	}

	public function testFitLineDegradesToNext():Void {
		final src:String = 'class M { function f():Void { switch (x) { case 1: foo(); } } }';
		final out:String = writeWithCaseBody(src, BodyPolicy.FitLine);
		Assert.isTrue(out.indexOf('case 1:\n') != -1, 'FitLine must not flatten today (degrades to Next): <$out>');
	}

	public function testKeepDegradesToNext():Void {
		final src:String = 'class M { function f():Void { switch (x) { case 1: foo(); } } }';
		final out:String = writeWithCaseBody(src, BodyPolicy.Keep);
		Assert.isTrue(out.indexOf('case 1:\n') != -1, 'Keep must not flatten today (degrades to Next): <$out>');
	}

	private inline function writeWithCaseBody(src:String, policy:BodyPolicy):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.caseBody = policy;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

	private inline function writeWithExpressionCase(src:String, policy:BodyPolicy):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.expressionCase = policy;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}
}
