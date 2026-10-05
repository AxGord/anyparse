package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A `//` comment trailing a block's CLOSE brace before the keyword that continues the construct
 * (`} // c` and then `while` / `else` / `catch`) leaves that keyword at the statement indent, under
 * every value of the `sameLine` knob that places it, and the result is a fixed point.
 *
 * The comment sits in the block's close-trailing slot, and the block emits it with a forward
 * hardline that drops before a following break. Under a same-line policy the parent's gap before the
 * keyword is a plain space, and it reached the renderer while that hardline was still pending: the
 * hardline was flushed for the blank and the blank written after it, one space past the indent
 * (` while`, ` else`, and ` catch` in a value position). `Renderer.emitText` now lets a pending
 * forward hardline absorb an all-blank gap. A statement `catch` already had a gap that drops after a
 * break (`OptSpaceSkipAfterHardline`), which is why it was the one keyword that came out right.
 */
@:nullSafety(Strict)
final class HxCloseTrailKeywordWriteTest extends Test {

	/** Every value a `sameLine` placement knob takes. */
	private static final MODES: Array<String> = ['same', 'next', 'keep', 'fitLine'];

	public function new(): Void {
		super();
	}

	/** `do { … } // c` + `while (x);` under `sameLine.doWhile`. */
	@:pin('control')
	@:killer('M-PENDING-HARDLINE-BLANK-FLUSHED')
	public function testDoWhileKeepsItsIndent(): Void {
		assertSeams('doWhile', 'do {\n\t\t\tx();\n\t\t} // c\n\t\twhile (x);', ['} // c\n\t\twhile (x);']);
	}

	/** A statement `if` with a block `else` under `sameLine.ifElse`. */
	@:pin('control')
	@:killer('M-PENDING-HARDLINE-BLANK-FLUSHED')
	public function testStatementElseKeepsItsIndent(): Void {
		assertSeams('ifElse', 'if (a) {\n\t\t\tb();\n\t\t} // c\n\t\telse {\n\t\t\td();\n\t\t}', ['} // c\n\t\telse {']);
	}

	/** The same seam ahead of an `else if` link and of the chain's last `else`. */
	@:pin('control')
	@:killer('M-PENDING-HARDLINE-BLANK-FLUSHED')
	public function testStatementElseIfChainKeepsItsIndent(): Void {
		assertSeams(
			'ifElse', 'if (a) {\n\t\t\tb();\n\t\t} // c\n\t\telse if (d) {\n\t\t\te();\n\t\t} // f\n\t\telse {\n\t\t\tg();\n\t\t}',
			['} // c\n\t\telse if (d) {', '} // f\n\t\telse {']
		);
	}

	/** A value `if` under `sameLine.expressionIf` — `same` is the compiled default. */
	@:pin('control')
	@:killer('M-PENDING-HARDLINE-BLANK-FLUSHED')
	public function testValueElseKeepsItsIndent(): Void {
		assertSeams('expressionIf', 'var y = if (a) {\n\t\t\t1;\n\t\t} // c\n\t\telse 3;', ['} // c\n\t\telse']);
	}

	/** A value `if` chain: both seams, the `else if` link and the closing `else`. */
	@:pin('control')
	@:killer('M-PENDING-HARDLINE-BLANK-FLUSHED')
	public function testValueElseIfChainKeepsItsIndent(): Void {
		assertSeams(
			'expressionIf', 'var y = if (a) {\n\t\t\t1;\n\t\t} // c\n\t\telse if (d) {\n\t\t\t2;\n\t\t} // f\n\t\telse {\n\t\t\t3;\n\t\t}',
			['} // c\n\t\telse if (d) {', '} // f\n\t\telse {']
		);
	}

	/** A value `try` under `sameLine.expressionTry`. */
	@:pin('control')
	@:killer('M-PENDING-HARDLINE-BLANK-FLUSHED')
	public function testValueCatchKeepsItsIndent(): Void {
		assertSeams(
			'expressionTry', 'var z = try {\n\t\t\tf();\n\t\t} // c\n\t\tcatch (e:Dynamic) {\n\t\t\t0;\n\t\t}',
			['} // c\n\t\tcatch (e:Dynamic) {']
		);
	}

	/**
	 * A statement `try` under `sameLine.tryCatch`: the keyword whose gap already dropped after a
	 * break. It pins that the absorbed blank changes nothing for a gap that never was one.
	 */
	@:pin('guard')
	public function testStatementCatchKeepsItsIndent(): Void {
		assertSeams(
			'tryCatch', 'try {\n\t\t\tf();\n\t\t} // c\n\t\tcatch (e:Dynamic) {\n\t\t\tg();\n\t\t}', ['} // c\n\t\tcatch (e:Dynamic) {']
		);
	}

	/**
	 * `statements` in a method body, written under each `sameLine.<knob>` value: every seam in
	 * `seams` appears verbatim (the keyword at the brace's own indent, nothing before it), and the
	 * output is its own fixed point.
	 */
	private function assertSeams(knob: String, statements: String, seams: Array<String>): Void {
		final source: String = 'class Foo {\n\tfunction bar() {\n\t\t$statements\n\t}\n}';
		for (mode in MODES) {
			final config: String = '{"sameLine": {"$knob": "$mode"}}';
			final out: String = HxWriteFixture.triviaWrite(source, config);
			for (seam in seams) Assert.isTrue(out.indexOf(seam) != -1, '$knob=$mode: the keyword after `$seam` lost its indent:\n$out');
			Assert.equals(out, HxWriteFixture.triviaWrite(out, config), '$knob=$mode: not a fixed point');
		}
	}

}
