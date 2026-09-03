package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferTryExpressionReturn;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-try-expression-return` check: a statement-position `try` whose body and EVERY
 * catch clause is a single valued `return` is flagged `Info` and `fix` collapses it to
 * `return try <value> catch (…) <value>;`. A value-less `return;`, a non-`return` / empty /
 * rethrowing catch, a multi-statement body and a comment in a dropped region are all left
 * alone.
 */
class PreferTryExpressionReturnCheckTest extends Test {

	private static final BASIC: String =
		'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn parse(text);\n\t\t} catch (e:String) {\n\t\t\treturn 0;\n\t\t}\n\t}\n}';

	/**
	 * Haxe binds a trailing `catch` to the INNERMOST open `try`, so a nested try-expression
	 * value must be parenthesised: unwrapped, `catch (e2:Int)` re-parents onto the inner
	 * `try` and an exception raised inside the inner CATCH stops being handled. The rule's
	 * own fixed point manufactures this shape (pass 1 collapses the inner `try`, pass 2 sees
	 * a single-valued-return body).
	 */
	public function testNestedTryValueParenthesised(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn try parse(text) catch (e1:String) boom();\n\t\t} catch (e2:Int) {\n'
			+ '\t\t\treturn 2;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('return try (try parse(text) catch (e1:String) boom()) catch (e2:Int) 2;', es[0].text);
	}

	/**
	 * A LINE comment anywhere in the `try` comments out whatever the one-line rebuild appends
	 * after it — here the value AND the terminating `;`. The dropped-comment guard cannot see
	 * it (the comment is INSIDE the verbatim-copied catch header, so it counts as riding
	 * along); the result then fails the `--fix` re-parse gate, which skips the WHOLE file and
	 * loses every other rule's fixes with it.
	 */
	public function testLineCommentInCatchHeaderNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn parse(text);\n\t\t} catch (e:String) // why\n\t\t{\n'
				+ '\t\t\treturn 0;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/** A `//` with more of the slice after it on later lines is copied verbatim, newline and all — safe, so the site fires. */
	public function testEarlierLineCommentInValueFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn parse(\n\t\t\t\ttext, // raw\n\t\t\t\t2\n\t\t\t);\n'
				+ '\t\t} catch (e:String) {\n\t\t\treturn 0;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/** A `try` sealed behind a closing bracket cannot absorb the following `catch`, so it needs no parentheses. */
	public function testSealedNestedTryNotParenthesised(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn g(1, try parse(text) catch (e1:String) 4);\n'
			+ '\t\t} catch (e2:Int) {\n\t\t\treturn 5;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('return try g(1, try parse(text) catch (e1:String) 4) catch (e2:Int) 5;', es[0].text);
	}

	/** A `try` at the value's right EDGE does absorb it, so it is parenthesised even under an enclosing operator. */
	public function testTailNestedTryParenthesised(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn 1 + try parse(text) catch (e1:String) 4;\n\t\t} catch (e2:Int) {\n'
			+ '\t\t\treturn 5;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('return try (1 + try parse(text) catch (e1:String) 4) catch (e2:Int) 5;', es[0].text);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-try-expression-return'));
		Assert.isTrue([for (c in Linter.builtins()) c.id()].contains('prefer-try-expression-return'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testBasicFlagged(): Void {
		final vs: Array<Violation> = violations(BASIC);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-try-expression-return', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this try/catch returning in every path can be a single try-expression return', vs[0].message);
	}

	public function testFixBasic(): Void {
		final es: Array<{ span: Span, text: String }> = edits(BASIC);
		Assert.equals(1, es.length);
		Assert.equals('return try parse(text) catch (e:String) 0;', es[0].text);
	}

	/** The catch header is sliced VERBATIM, so the variable's `:Type` (trivia in the projection) survives every clause. */
	public function testFixTwoCatches(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn parse(text);\n\t\t} catch (e:String) {\n\t\t\treturn 0;\n'
			+ '\t\t} catch (e:Exception) {\n\t\t\treturn -1;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('return try parse(text) catch (e:String) 0 catch (e:Exception) -1;', es[0].text);
	}

	/** An un-braced body is the same shape with the block level absent. */
	public function testUnbracedBodiesFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Int {\n\t\ttry return a catch (e:String) return 0;\n\t}\n}').length);
	}

	/** The rewrite touches only the `try` node, so no statement-list walk gates it inside a `#if`. */
	public function testInsideConditionalFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f():Int {\n\t\t#if sys\n\t\ttry {\n\t\t\treturn parse(text);\n\t\t} catch (e:String) {\n'
				+ '\t\t\treturn 0;\n\t\t}\n\t\t#end\n\t}\n}'
			).length
		);
	}

	public function testVoidReturnInCatchNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn parse(text);\n\t\t} catch (e:String) {\n\t\t\treturn;\n\t\t}\n'
				+ '\t}\n}'
			).length
		);
	}

	public function testNonReturnCatchNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn parse(text);\n\t\t} catch (e:String) {\n\t\t\tlog(e);\n\t\t}\n'
				+ '\t}\n}'
			).length
		);
	}

	public function testEmptyCatchNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn parse(text);\n\t\t} catch (e:String) {}\n\t}\n}').length
		);
	}

	public function testSecondCatchWithoutReturnNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn parse(text);\n\t\t} catch (e:String) {\n\t\t\treturn 0;\n'
				+ '\t\t} catch (e:Exception) {\n\t\t\tthrow e;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/**
	 * A deliberately grouped body is never collapsed. The `return` comes FIRST (the trailing
	 * statement is unreachable, which is the only way to reach this gate at all -- anything
	 * BEFORE a valued return is rejected one gate earlier, by the return check itself).
	 */
	public function testMultiStatementBodyNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn parse(text);\n\t\t\tlog(text);\n\t\t} catch (e:String) {\n'
				+ '\t\t\treturn 0;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/** The `try` keyword, the braces and each `return` are dropped, so a comment there fails the guard closed. */
	public function testCommentInDroppedRegionNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\t/* fast path */\n\t\t\treturn parse(text);\n\t\t} catch (e:String) {\n'
				+ '\t\t\treturn 0;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/** A comment INSIDE a copied returned expression rides along, so the site still fires. */
	public function testCommentInsideValueFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f():Int {\n\t\ttry {\n\t\t\treturn parse(/* raw */ text);\n\t\t} catch (e:String) {\n'
				+ '\t\t\treturn 0;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/** The TM shape this check was written for (`ScrollAxis.maxScroll`, anonymized). */
	public function testFixTmFixture(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f(node:Node, size:Float):Float {\n\t\ttry {\n\t\t\treturn Math.max(0, measure(node) - size);\n'
			+ '\t\t} catch (exception:Exception) {\n\t\t\treturn 0;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('return try Math.max(0, measure(node) - size) catch (exception:Exception) 0;', es[0].text);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferTryExpressionReturn().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferTryExpressionReturn = new PreferTryExpressionReturn();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
