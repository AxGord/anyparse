package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BodyPolicy;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-issue-257-else-in-return-switch — `HxIfStmt.thenBody` /
 * `elseBody` carry the dual-flag form
 * `bodyPolicy('ifBody', 'expressionIfBody')` /
 * `bodyPolicy('elseBody', 'expressionElseBody')`. The runtime gate
 * inside `bodyPolicyWrap` dispatches on `opt._inExprPosition`:
 * statement-position consults `ifBody` / `elseBody` (defaults `Next`
 * → break); expression-position (set by parent
 * `@:fmt(propagateExprPosition)` along the descent path —
 * `ReturnStmt.value` → switch-expr → `HxCaseBranch.body` → if/else
 * branches inherit) consults `expressionIfBody` / `expressionElseBody`.
 * Mirrors fork's `markIf` walking up via `isReturnExpression` to apply
 * the `expressionIf` knob to value-position ifs.
 *
 * Per `feedback_unit_test_trivia_writer.md`: trivia pair only —
 * `HaxeModuleTriviaParser` / `HaxeModuleTriviaWriter`.
 */
@:nullSafety(Strict)
final class HxIfStmtExprPositionDispatchTest extends Test {

	public function new():Void {
		super();
	}

	public function testStatementIfBodyNextBreaks():Void {
		// Top-level if in fn body — statement-position. Default
		// ifBody=Next forces a break before the then-body.
		final src:String = 'class M { function f():Void { if (c) foo(); } }';
		final out:String = writeWithDefaults(src);
		Assert.isTrue(out.indexOf('if (c) foo();') == -1, 'must not flatten at statement-position with ifBody=Next: <$out>');
		Assert.isTrue(out.indexOf('if (c)\n') != -1, 'expected break before then-body at statement-position: <$out>');
	}

	public function testStatementIfBodySameFlattens():Void {
		// ifBody=Same overrides the break — top-level if flattens.
		final src:String = 'class M { function f():Void { if (c) foo(); } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.ifBody = BodyPolicy.Same;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('if (c) foo();') != -1, 'ifBody=Same must flatten at statement-position: <$out>');
	}

	public function testIfInsideReturnSwitchExpressionIfBodySameFlattens():Void {
		// Inner if inside `case POpen:` of a return-switch sees
		// `_inExprPosition=true` propagated from `ReturnStmt.value`
		// down through case body. Default ifBody=Next, but
		// expressionIfBody=Same routes the dispatch to flatten.
		final src:String = 'class M { function f():Bool { return switch (t) { case A: if (c) foo(); }; } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.ifBody = BodyPolicy.Next;
		opts.expressionIfBody = BodyPolicy.Same;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('if (c) foo();') != -1, 'expressionIfBody=Same must flatten if-in-return-switch: <$out>');
	}

	public function testIfInsideReturnSwitchIfBodySameIgnoredAtExpressionPosition():Void {
		// At expression-position the dispatched gate consults
		// `expressionIfBody` only — `ifBody=Same` is dead-letter.
		// Verifies the dispatch is exclusive (not OR semantic).
		final src:String = 'class M { function f():Bool { return switch (t) { case A: if (c) foo(); }; } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.ifBody = BodyPolicy.Same;
		opts.expressionIfBody = BodyPolicy.Next;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('if (c) foo();') == -1, 'ifBody=Same must NOT override expressionIfBody at expression-position: <$out>');
	}

	public function testElseBodyDualFlagDispatchesAtExpressionPosition():Void {
		// `else`-body uses the paired knob `expressionElseBody`.
		// Expression-position via return-switch case body —
		// elseBody=Next, expressionElseBody=Same → flatten else.
		final src:String = 'class M { function f():Bool { return switch (t) { case A: if (c) a(); else b(); }; } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.ifBody = BodyPolicy.Same;
		opts.elseBody = BodyPolicy.Next;
		opts.expressionIfBody = BodyPolicy.Same;
		opts.expressionElseBody = BodyPolicy.Same;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('if (c) a(); else b();') != -1, 'expressionElseBody=Same must flatten else-body at expression-position: <$out>');
	}

	public function testStatementIfStillUsesIfBodyWhenExprFlagSet():Void {
		// Top-level if (statement-position) sees opt._inExprPosition
		// = false. expressionIfBody=Same is irrelevant; the dispatch
		// reads ifBody. Ensures backward compatibility for the dual-
		// flag rewrite — single-flag stmt-side semantics unchanged.
		final src:String = 'class M { function f():Void { if (c) foo(); } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.ifBody = BodyPolicy.Next;
		opts.expressionIfBody = BodyPolicy.Same;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('if (c) foo();') == -1, 'expressionIfBody must NOT bleed into statement-position: <$out>');
		Assert.isTrue(out.indexOf('if (c)\n') != -1, 'statement-position must keep ifBody=Next break: <$out>');
	}

	public function testReturnStmtBodyStillUsesSingleFlag():Void {
		// `HxStatement.ReturnStmt` keeps single-flag bodyPolicy
		// (`returnBody`) — backward-compat probe for the
		// `fmtReadString` → `fmtReadStringArgs` rewrite. With
		// returnBody=Next the body should break; default Same.
		final src:String = 'class M { function f():Int { return 42; } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.returnBody = BodyPolicy.Next;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('return\n') != -1, 'returnBody=Next must break before value: <$out>');
	}

	private inline function writeWithDefaults(src:String):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}
}
