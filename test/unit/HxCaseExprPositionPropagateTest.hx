package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BodyPolicy;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-issue-423-mech-a — case-body context dispatch via
 * `_inExprPosition` opt-fanout.
 *
 * `HxCaseBranch.body` / `HxDefaultBranch.stmts` carry
 * `@:fmt(propagateExprPosition)`: the runtime `_writerOpt` becomes an
 * always-copy whose `_inExprPosition = true`, propagated through
 * descendants. The dual-flag flat-gate
 * `bodyPolicy('caseBody', 'expressionCase')` dispatches on
 * `opt._inExprPosition` at runtime: top-level statement-position
 * cases consult `caseBody` (default `Next` → break); cases nested
 * inside another case's body inherit `_inExprPosition=true` and
 * consult `expressionCase` (default `Keep` → flatten on same-line
 * source). Mirrors fork's `isReturnExpression` walk-up heuristic in
 * `MarkSameLine.markCase`.
 *
 * Per `feedback_unit_test_trivia_writer.md`: trivia pair only —
 * `HaxeModuleTriviaParser` / `HaxeModuleTriviaWriter`.
 */
@:nullSafety(Strict)
final class HxCaseExprPositionPropagateTest extends Test {

	public function new():Void {
		super();
	}

	public function testStatementCaseBodyNextBreaks():Void {
		// Top-level switch in fn body — statement-position. Defaults
		// caseBody=Next → break.
		final src:String = 'class M { function f():Void { switch (x) { case 1: foo(); } } }';
		final out:String = writeWithDefaults(src);
		Assert.isTrue(out.indexOf('case 1:\n') != -1, 'expected multiline at statement-position: <$out>');
		Assert.isTrue(out.indexOf('case 1: foo();') == -1, 'must not flatten at statement-position with caseBody=Next: <$out>');
	}

	public function testStatementCaseBodySameFlattens():Void {
		// caseBody=Same overrides the break — top-level case flattens.
		final src:String = 'class M { function f():Void { switch (x) { case 1: foo(); } } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.caseBody = BodyPolicy.Same;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('case 1: foo();') != -1, 'caseBody=Same must flatten at statement-position: <$out>');
	}

	public function testNestedCaseExpressionCaseKeepFlattensSameLine():Void {
		// Inner switch is the body of the outer case `1` — inner case
		// `2` is in expression-position. Source has both inner cases
		// same-line. expressionCase=Keep (default) + sameLine=true →
		// flatten inner cases. Outer caseBody=Next (default) →
		// outer case body breaks (the nested switch lands on the next
		// line). caseBody intentionally Same to confirm it is IGNORED
		// at expression-position.
		final src:String = 'class M { function f():Void { switch (x) { case 1: switch (y) { case 2: foo(); case 3: bar(); } } } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.caseBody = BodyPolicy.Next;
		opts.expressionCase = BodyPolicy.Keep;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('case 2: foo();') != -1, 'expected inline inner case 2 at expression-position: <$out>');
		Assert.isTrue(out.indexOf('case 3: bar();') != -1, 'expected inline inner case 3 at expression-position: <$out>');
		Assert.isTrue(out.indexOf('case 1:\n') != -1, 'expected outer case 1 to break (nested switch body): <$out>');
	}

	public function testNestedCaseExpressionCaseNextBreaks():Void {
		// expressionCase=Next at expression-position → inner cases
		// break despite same-line source.
		final src:String = 'class M { function f():Void { switch (x) { case 1: switch (y) { case 2: foo(); } } } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.expressionCase = BodyPolicy.Next;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('case 2: foo();') == -1, 'expressionCase=Next must break inner case: <$out>');
		Assert.isTrue(out.indexOf('case 2:\n') != -1, 'expected multiline inner case 2 under expressionCase=Next: <$out>');
	}

	public function testNestedCaseCaseBodySameIgnoredAtExpressionPosition():Void {
		// caseBody=Same at expression-position is IGNORED — the
		// dispatched gate consults expressionCase only. Default
		// expressionCase=Keep + sameLine source still drives flatten;
		// caseBody=Same is dead-letter for the inner case. Verifies
		// the dispatch is exclusive (not OR semantic).
		final src:String = 'class M { function f():Void { switch (x) { case 1: switch (y) { case 2: foo(); } } } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.caseBody = BodyPolicy.Same;
		opts.expressionCase = BodyPolicy.Next;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		// Inner case picks expressionCase=Next → break. caseBody=Same
		// does NOT override.
		Assert.isTrue(out.indexOf('case 2: foo();') == -1, 'caseBody=Same must NOT override expressionCase at expression-position: <$out>');
		// Outer case picks caseBody=Same → flatten. (Outer case body
		// is the inner switch — flat means `case 1: switch (y) {...}`
		// on one line, which holds at the `case 1: switch` prefix.)
		Assert.isTrue(out.indexOf('case 1: switch') != -1, 'caseBody=Same must flatten outer (statement-position) case: <$out>');
	}

	public function testNewlineBeforeBlocksKeepFlattenAtExpressionPosition():Void {
		// At expression-position, expressionCase=Keep flattens only
		// when source has body same-line as `:`. With a source-side
		// newline before the body, Keep preserves the break.
		final src:String = 'class M { function f():Void { switch (x) { case 1: switch (y) {\n\t\t\tcase 2:\n\t\t\t\tfoo();\n\t\t} } } }';
		final out:String = writeWithDefaults(src);
		Assert.isTrue(out.indexOf('case 2: foo();') == -1, 'Keep must NOT flatten when source has newline before body: <$out>');
	}

	public function testDefaultBranchPropagatesExprPosition():Void {
		// `default` branch also propagates _inExprPosition=true to
		// descendants — a case nested inside a default body picks
		// expressionCase, not caseBody.
		final src:String = 'class M { function f():Void { switch (x) { default: switch (y) { case 2: foo(); } } } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.caseBody = BodyPolicy.Next;
		opts.expressionCase = BodyPolicy.Keep;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('case 2: foo();') != -1, 'default-body-nested case must flatten via expressionCase=Keep: <$out>');
	}

	private inline function writeWithDefaults(src:String):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}
}
