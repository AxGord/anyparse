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
 * `Same` and `Next` are wired through opt.<flag> directly. `Keep`
 * (ω-case-body-keep) reads `Trivial<T>.newlineBefore` of the body's
 * first element to flatten only when the source had the stmt on the
 * same line as `:`. `FitLine` falls through to the `Next` path.
 *
 * ω-issue-423-mech-a flipped the dual-flag gate from OR-of-both to
 * dispatch on `opt._inExprPosition`: top-level switch case bodies
 * (statement-position) consult `caseBody`; cases nested in another
 * case's body (expression-position via
 * `@:fmt(propagateExprPosition)`) consult `expressionCase`. Tests in
 * this file exercise statement-position only — see
 * `HxCaseExprPositionPropagateTest` for expression-position coverage.
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

	public function testDefaultsCaseBodyKeepExpressionCaseKeep():Void {
		// Slice D6 (dogfood) — `caseBody` default flipped from `Next` to
		// `Keep` so the no-config (dogfood) writer-equals path preserves
		// user-written `case X(v): body;` shape. The fork-canonical `Next`
		// is preserved by re-baselining in `HaxeFormatConfigLoader.
		// loadHxFormatJson` before `applySameLine` merges JSON overrides.
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(BodyPolicy.Keep, defaults.caseBody);
		Assert.equals(BodyPolicy.Keep, defaults.expressionCase);
	}

	public function testNextKeepsSingleStmtMultiline():Void {
		final src:String = 'class M { function f():Void { switch (x) { case 1: foo(); } } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.caseBody = BodyPolicy.Next;
		opts.expressionCase = BodyPolicy.Next;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('case 1:\n') != -1, 'expected multiline `case 1:\\n` in: <$out>');
		Assert.isTrue(out.indexOf('case 1: foo();') == -1, 'did not expect inline `case 1: foo();` in: <$out>');
	}

	public function testCaseBodySameFlattensSingleStmt():Void {
		final src:String = 'class M { function f():Void { switch (x) { case 1: foo(); } } }';
		final out:String = writeWithCaseBody(src, BodyPolicy.Same);
		Assert.isTrue(out.indexOf('case 1: foo();') != -1, 'expected inline `case 1: foo();` in: <$out>');
	}

	public function testExpressionCaseSameAtStatementPositionDoesNotFlatten():Void {
		// ω-issue-423-mech-a: at statement-position (top-level switch in
		// fn body) the dispatched gate consults `caseBody` only. Setting
		// `expressionCase=Same` no longer forces flatten — only `caseBody`
		// can. Regression coverage for the OR→dispatch semantic flip.
		final src:String = 'class M { function f():Void { switch (x) { case 1: foo(); } } }';
		final out:String = writeWithExpressionCase(src, BodyPolicy.Same);
		Assert.isTrue(out.indexOf('case 1: foo();') == -1, 'expressionCase=Same must NOT flatten at statement-position: <$out>');
		Assert.isTrue(out.indexOf('case 1:\n') != -1, 'expected multiline `case 1:\\n` at statement-position: <$out>');
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
		Assert.equals(BodyPolicy.Keep, opts.expressionCase);
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
		Assert.equals(BodyPolicy.Keep, opts.expressionCase);
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
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.caseBody = BodyPolicy.FitLine;
		opts.expressionCase = BodyPolicy.Next;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('case 1:\n') != -1, 'FitLine must not flatten today (degrades to Next): <$out>');
	}

	public function testKeepFlattensSameLineSource():Void {
		final src:String = 'class M { function f():Void { switch (x) { case 1: foo(); } } }';
		final out:String = writeWithCaseBody(src, BodyPolicy.Keep);
		Assert.isTrue(out.indexOf('case 1: foo();') != -1, 'Keep should flatten same-line source: <$out>');
	}

	public function testKeepPreservesNextLineSource():Void {
		final src:String = 'class M { function f():Void { switch (x) {\n\t\t\tcase 1:\n\t\t\t\tfoo();\n\t\t} } }';
		final out:String = writeWithCaseBody(src, BodyPolicy.Keep);
		Assert.isTrue(out.indexOf('case 1: foo();') == -1, 'Keep should not flatten next-line source: <$out>');
		Assert.isTrue(out.indexOf('case 1:\n') != -1, 'expected multiline `case 1:\\n` for next-line source: <$out>');
	}

	public function testKeepMultiStmtForcedMultiline():Void {
		final src:String = 'class M { function f():Void { switch (x) { case 1: foo(); bar(); } } }';
		final out:String = writeWithCaseBody(src, BodyPolicy.Keep);
		Assert.isTrue(out.indexOf('case 1: foo();') == -1, 'multi-stmt body must stay multiline under Keep: <$out>');
		Assert.isTrue(out.indexOf('case 1:\n') != -1, 'expected multiline `case 1:\\n` for multi-stmt under Keep: <$out>');
	}

	public function testExpressionCaseKeepAtVarInitFlattensSameLine():Void {
		// ω-issue-423-mech-a: `HxVarDecl.init` is wired with
		// `@:fmt(propagateExprPosition)`, so a var-init switch puts its
		// cases in expression-position. Default `expressionCase=Keep`
		// + same-line source flattens the case body. Mirrors fork's
		// `isReturnExpression` walk-up that hits `=` (Binop) and routes
		// to `markExpressionCase`.
		final src:String = 'class M { function f():Void { var v = switch (x) { case 1: 10; }; } }';
		final out:String = writeWithExpressionCase(src, BodyPolicy.Keep);
		Assert.isTrue(out.indexOf('case 1: 10;') != -1, 'var-init switch case should flatten under expressionCase=Keep + sameLine source: <$out>');
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
