package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A BLOCK comment trailing a block's close brace (`} /* c *\/`) before the keyword that continues
 * the construct changes nothing but its own presence: under every `sameLine` placement the result is
 * the uncommented construct's layout with ` /* c *\/` after each `}`, and a fixed point.
 *
 * The comment sits in the block's close-trailing slot. Its statement and value block arms used to
 * append a forward hardline after it whatever its style, so `} /* c *\/ else` broke before the
 * keyword under a same-line policy, and the statement `try`'s first-catch separator assumed every
 * close-trailing comment had ended its line and dropped the gap, gluing `} /* c *\/catch` under
 * every policy. A LINE comment still breaks: it carries its own forward hardline, emitted by the
 * one guarded emitter every close-trailing site now shares — the empty block (`{} // c`) included,
 * which used to break with a hard newline and push the keyword one space out.
 */
@:nullSafety(Strict)
final class HxCloseTrailBlockCommentWriteTest extends Test {

	/** Every value a `sameLine` placement knob takes. */
	private static final MODES: Array<String> = ['same', 'next', 'keep', 'fitLine'];

	/** The marker a fixture writes after each `}` that a comment trails. */
	private static inline final MARK: String = '}@';

	public function new(): Void {
		super();
	}

	/** `do { … } /* c *\/ while (x);` under `sameLine.doWhile`. */
	@:pin('control')
	@:killer('M-CLOSE-TRAIL-BLOCK-BREAKS')
	public function testDoWhileKeepsTheKeywordGlued(): Void {
		assertAsUncommented('doWhile', 'do {\n\t\t\tx();\n\t\t}@ while (x);');
	}

	/** A statement `if` / `else if` / `else` chain under `sameLine.ifElse`. */
	@:pin('control')
	@:killer('M-CLOSE-TRAIL-BLOCK-BREAKS')
	public function testStatementElseChainKeepsTheKeywordGlued(): Void {
		assertAsUncommented('ifElse', 'if (a) {\n\t\t\tb();\n\t\t}@ else if (d) {\n\t\t\te();\n\t\t}@ else {\n\t\t\tg();\n\t\t}');
	}

	/** A value `if` chain under `sameLine.expressionIf`. */
	@:pin('control')
	@:killer('M-CLOSE-TRAIL-BLOCK-BREAKS')
	public function testValueElseChainKeepsTheKeywordGlued(): Void {
		assertAsUncommented('expressionIf', 'var y = if (a) {\n\t\t\t1;\n\t\t}@ else if (d) {\n\t\t\t2;\n\t\t}@ else 3;');
	}

	/** A value `try` under `sameLine.expressionTry`. */
	@:pin('control')
	@:killer('M-CLOSE-TRAIL-BLOCK-BREAKS')
	public function testValueCatchKeepsTheKeywordGlued(): Void {
		assertAsUncommented('expressionTry', 'var z = try {\n\t\t\tf();\n\t\t}@ catch (e:Dynamic) {\n\t\t\t0;\n\t\t}');
	}

	/**
	 * A statement `try` under `sameLine.tryCatch`, both seams: the try body's (the first-catch
	 * separator override) and a catch body's (the subsequent-catch separator).
	 */
	@:pin('control')
	@:killer('M-CLOSE-TRAIL-BLOCK-BREAKS')
	@:killer('M-CATCH-CLOSE-TRAIL-ANY')
	public function testStatementCatchKeepsItsGap(): Void {
		assertAsUncommented(
			'tryCatch', 'try {\n\t\t\tf();\n\t\t}@ catch (e:Dynamic) {\n\t\t\tg();\n\t\t}@ catch (e:String) {\n\t\t\th();\n\t\t}'
		);
	}

	/** An EMPTY block's close-trailing comment, statement `else` and `while`. */
	@:pin('control')
	@:killer('M-CLOSE-TRAIL-EMPTY-HARD')
	public function testEmptyBlockKeepsTheKeywordGlued(): Void {
		assertAsUncommented('ifElse', 'if (a) {}@ else 3;');
		assertAsUncommented('doWhile', 'do {}@ while (x);');
	}

	/**
	 * A LINE comment after an EMPTY block breaks, and the keyword lands at the statement indent —
	 * the hard newline it used to get was flushed for the parent's space, which then followed it.
	 */
	@:pin('control')
	@:killer('M-CLOSE-TRAIL-EMPTY-HARD')
	public function testEmptyBlockLineCommentKeepsTheKeywordAtItsIndent(): Void {
		assertSeam('ifElse', 'if (a) {} // c\n\t\telse 3;', 'if (a) {} // c\n\t\telse');
		assertSeam('doWhile', 'do {} // c\n\t\twhile (x);', 'do {} // c\n\t\twhile (x);');
	}

	/**
	 * A LINE comment after a block holding only an open-trailing block comment (`{ /* n *\/ }`)
	 * ends its line: emitted unguarded it swallowed the keyword after it, so the round trip lost
	 * `else 3`.
	 */
	@:pin('control')
	@:killer('M-OPEN-TRAIL-EMPTY-UNGUARDED')
	public function testOpenCommentBlockLineCommentBreaks(): Void {
		assertSeam('ifElse', 'if (a) { /* n */ } // c\n\t\telse 3;', 'if (a) {/* n */} // c\n\t\telse');
	}

	/** The same seam on an empty parameter list: `function f(/* n *\/) // c` and then the body. */
	@:pin('control')
	@:killer('M-OPEN-TRAIL-SEP-UNGUARDED')
	public function testOpenCommentParamsLineCommentBreaks(): Void {
		final source: String = 'class Foo {\n\tfunction bar(/* n */) // c\n\t{}\n}';
		final out: String = HxWriteFixture.triviaWrite(source, '{}');
		Assert.equals(source, out);
		Assert.equals(out, HxWriteFixture.triviaWrite(out, '{}'), 'not a fixed point');
	}

	/**
	 * `statements` (each `}@` marking a seam) written under every `sameLine.<knob>` value with a
	 * `/* c *\/` at each seam equals the same statements written WITHOUT the comments, with the comment
	 * inserted after each seam's `}`; and it is a fixed point.
	 */
	private function assertAsUncommented(knob: String, statements: String): Void {
		for (mode in MODES) {
			final config: String = '{"sameLine": {"$knob": "$mode"}}';
			final plain: String = HxWriteFixture.triviaWrite(wrap(statements.split(MARK).join('}')), config);
			final expected: String = ~/\}(\s+)(else|while|catch)/g.map(plain, m -> '} /* c */' + m.matched(1) + m.matched(2));
			final out: String = HxWriteFixture.triviaWrite(wrap(statements.split(MARK).join('} /* c */')), config);
			Assert.equals(expected, out, '$knob=$mode');
			Assert.equals(out, HxWriteFixture.triviaWrite(out, config), '$knob=$mode: not a fixed point');
		}
	}

	/** `statements` under every `sameLine.<knob>` value renders `seam` verbatim and is a fixed point. */
	private function assertSeam(knob: String, statements: String, seam: String): Void {
		for (mode in MODES) {
			final config: String = '{"sameLine": {"$knob": "$mode"}}';
			final out: String = HxWriteFixture.triviaWrite(wrap(statements), config);
			Assert.isTrue(out.indexOf(seam) != -1, '$knob=$mode: expected `$seam` in:\n$out');
			Assert.equals(out, HxWriteFixture.triviaWrite(out, config), '$knob=$mode: not a fixed point');
		}
	}

	private static inline function wrap(statements: String): String return 'class Foo {\n\tfunction bar() {\n\t\t$statements\n\t}\n}';

}
