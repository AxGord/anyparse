package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-if-tail-fork-parity — a single-statement `if` that is the tail of a
 * block-expression body (thin-arrow lambda) or a switch-case body is a
 * STATEMENT: its direct parent is a block brace / statement-switch colon,
 * for which the fork's `isExpression` is `false`, so the body uses
 * `sameLine.ifBody` (fitLine), NEVER `sameLine.expressionIf`. Only a
 * value-yielded case (`return switch …`) keeps the expression frame and
 * breaks under `expressionIf:next`.
 *
 * The barrier is gated on `expressionIfBody` being `Next` / `FitLine`
 * (the config where the inherited frame would otherwise force a break);
 * under the default `Keep` the source-preserving behaviour is untouched.
 * It fires for NO-ELSE `if`s only — a with-else chain keeps the frame so
 * the whole chain breaks together via `fitLineIfWithElse`.
 *
 * Per `feedback_unit_test_trivia_writer.md`: trivia pair only.
 */
@:nullSafety(Strict)
final class HxIfBodyBlockCaseBarrierTest extends Test {

	public function new(): Void {
		super();
	}

	public function testLambdaBlockTailNoElseIfInlines(): Void {
		final src: String = 'class M { function f() { call(() -> { if (a) b(); }); } }';
		final out: String = writeFitLineNext(src);
		Assert.isTrue(out.indexOf('if (a) b();') != -1, 'no-else if at a lambda block tail must inline via ifBody=fitLine: <$out>');
	}

	public function testStatementSwitchCaseNoElseIfInlines(): Void {
		final src: String = 'class M { function f() { switch (k) { case A: if (a) b(); } } }';
		final out: String = writeFitLineNext(src);
		Assert.isTrue(out.indexOf('if (a) b();') != -1, 'no-else if in a statement-switch case must inline via ifBody=fitLine: <$out>');
	}

	public function testReturnSwitchCaseNoElseIfBreaks(): Void {
		// Value-yielded (return) case: the `if` is a genuine expression, so the
		// inherited frame is kept and expressionIf=next force-breaks the body.
		final src: String = 'class M { function f():Int { return switch (k) { case A: if (a) b(); }; } }';
		final out: String = writeFitLineNext(src);
		Assert.isTrue(out.indexOf('if (a) b();') == -1, 'no-else if in a return-switch case must break (expression position): <$out>');
		Assert.isTrue(out.indexOf('if (a)\n') != -1, 'expected break before the return-switch case if body: <$out>');
	}

	public function testLambdaBlockWithElseIfBreaks(): Void {
		// A with-else if keeps the inherited frame so the chain breaks together.
		final src: String = 'class M { function f() { call(() -> { if (a) b() else c(); }); } }';
		final out: String = writeFitLineNext(src);
		Assert.isTrue(out.indexOf('if (a) b()') == -1, 'a with-else if at a block tail must break the chain: <$out>');
	}

	public function testDefaultConfigInlineSourceLambdaIfUntouched(): Void {
		// Under the default config (expressionIfBody=Keep) the barrier does NOT
		// fire — inline source is preserved (ifBody=Next would have broken it).
		final src: String = 'class M { function f() { call(() -> { if (a) b(); }); } }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('if (a) b();') != -1, 'default config must preserve inline source (barrier gated off): <$out>');
	}

	private inline function writeFitLineNext(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine":{"ifBody":"fitLine","expressionIf":"next"}}'
		);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
