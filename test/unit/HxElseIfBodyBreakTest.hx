package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-elseif-body-break — under `sameLine.ifBody:fitLine` +
 * `fitLineIfWithElse:false` (default), a single-statement body of an `if`
 * that is itself the `else` branch of an enclosing `if` (an `else if`)
 * BREAKS onto its own line even though it fits, mirroring haxe-formatter's
 * `MarkSameLine.isPartOfIfElse` "if inside else" clause. The signal is a
 * one-level marker (`_inElseIfBranch`) set only when the else-branch runtime
 * ctor is `IfStmt`, and cleared on the inner `if`'s then-body recursion — so
 * a statement nested inside the else-if body (or inside an else-BLOCK) is not
 * itself treated as an else-branch and keeps its own body inline.
 *
 * Trivia pair only (per feedback_unit_test_trivia_writer.md).
 */
@:nullSafety(Strict)
final class HxElseIfBodyBreakTest extends Test {

	public function new(): Void {
		super();
	}

	public function testElseIfBodyBreaks(): Void {
		// else if body fits but must break: the inner if is in else position.
		final src: String = 'class M { function f() { if (a) { p(); } else if (q(v) == -1) w(v); } }';
		final out: String = writeFitLineNext(src);
		Assert.isTrue(out.indexOf('else if (q(v) == -1) w(v)') == -1, 'else-if body must not stay inline: <$out>');
		Assert.isTrue(out.indexOf('else if (q(v) == -1)\n') != -1, 'expected break after the else-if header: <$out>');
	}

	public function testAllSingleStmtChainElseIfBreaks(): Void {
		// No block sibling anywhere; the else-if body still breaks.
		final src: String = 'class M { function f() { if (a) r(); else if (q(v) == -1) w(v); } }';
		final out: String = writeFitLineNext(src);
		Assert.isTrue(out.indexOf('else if (q(v) == -1) w(v)') == -1, 'else-if body must break in an all-single-stmt chain: <$out>');
	}

	public function testPlainIfNoElseInlines(): Void {
		// A truly standalone if (no else, not an else branch) keeps its body inline.
		final src: String = 'class M { function f() { if (q(v) == -1) w(v); } }';
		final out: String = writeFitLineNext(src);
		Assert.isTrue(out.indexOf('if (q(v) == -1) w(v);') != -1, 'a plain no-else if must inline via ifBody=fitLine: <$out>');
	}

	public function testNestedIfInElseIfBodyInlines(): Void {
		// The inner-inner if is the then-body of the else-if, NOT an else branch,
		// so its own body stays inline (the signal is cleared on the then-body).
		final src: String = 'class M { function f() { if (a) { p(); } else if (b) if (c) d(); } }';
		final out: String = writeFitLineNext(src);
		Assert.isTrue(out.indexOf('if (c) d();') != -1, 'an if nested as an else-if body must keep its own body inline: <$out>');
	}

	public function testIfInElseBlockInlines(): Void {
		// An if inside an else-BLOCK has a block parent, not an else — inline.
		final src: String = 'class M { function f() { if (a) { p(); } else { if (c) d(); } } }';
		final out: String = writeFitLineNext(src);
		Assert.isTrue(out.indexOf('if (c) d();') != -1, 'an if inside an else-block must keep its body inline: <$out>');
	}

	public function testChainElseBlockNoLeak(): Void {
		// if {} else if {} else { if (c) d(); } — the final else-BLOCK must not
		// inherit the else-if signal from the middle chain link.
		final src: String = 'class M { function f() { if (a) { p(); } else if (b) { r(); } else { if (c) d(); } } }';
		final out: String = writeFitLineNext(src);
		Assert.isTrue(out.indexOf('if (c) d();') != -1, 'an if inside a chain-final else-block must keep its body inline: <$out>');
	}

	public function testFitLineIfWithElseKeepsInline(): Void {
		// With fitLineIfWithElse:true the whole if/else may keep fitting halves
		// inline, so the else-if body stays on the header line.
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine":{"ifBody":"fitLine","expressionIf":"next","fitLineIfWithElse":true}}'
		);
		final src: String = 'class M { function f() { if (a) { p(); } else if (q(v) == -1) w(v); } }';
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('else if (q(v) == -1) w(v);') != -1, 'fitLineIfWithElse:true must keep the else-if body inline: <$out>');
	}

	public function testDefaultConfigElseIfUntouched(): Void {
		// Under the default config (ifBody=Next) the else-if body already breaks
		// for a different reason; assert the change did not collapse it inline.
		final src: String = 'class M { function f() { if (a) { p(); } else if (q(v) == -1) w(v); } }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('else if (q(v) == -1) w(v)') == -1, 'default config must not collapse the else-if body inline: <$out>');
	}

	private inline function writeFitLineNext(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine":{"ifBody":"fitLine","expressionIf":"next"}}'
		);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
