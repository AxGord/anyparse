package unit.format;

import unit.grammar.haxe.HxWriteFixture;

/**
 * A comment between a branch head and its body — cuddled to `else` or to a catch clause's `)`, or an own-line run below
 * the head — under `singleStatementBraces: "symmetric"` and with the knob off: the braces the writer synthesizes go
 * AROUND the comment, the comment keeps its kind, and a body pushed off the head line by a comment is indented as a branch.
 */
@:nullSafety(Strict)
class HeadGapCommentWrapTest extends Test {

	private static final BASE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}';
	private static final KEEP: String = '$BASE}';
	private static final SYMMETRIC: String = '$BASE, "whitespace": {"bracesConfig": {"singleStatementBraces": "symmetric"}}}';

	/** The value-`if` mirror braces the bare else, and the comment cuddled to `else` opens the new block. */
	@:pin('control')
	@:killer('M-VALUE-WRAP-NO-ADOPT')
	@:killer('M-SSB-WRAP-FROM-UNLIFTED')
	public function testAValueElseHeadGapCommentMovesInsideTheWrap(): Void {
		final out: String = fmt(valueReturn('if (a) {\n\t\t\tg();\n\t\t\t1;\n\t\t} else // c2\n\t\t\t3;'), SYMMETRIC);
		Assert.isTrue(out.indexOf('} else { // c2\n\t\t\t3;\n\t\t};') != -1, 'the comment must open the wrapped block in: <$out>');
	}

	/** The then side of the same mirror reads the comment cuddled to the condition's `)`. */
	@:pin('control')
	@:killer('M-VALUE-WRAP-NO-ADOPT')
	@:killer('M-SSB-WRAP-FROM-UNLIFTED')
	public function testAValueThenHeadGapCommentMovesInsideTheWrap(): Void {
		final out: String = fmt(valueReturn('if (a) // t1\n\t\t\t3\n\t\telse {\n\t\t\tg();\n\t\t\t1;\n\t\t};'), SYMMETRIC);
		Assert.isTrue(
			out.indexOf('return if (a) { // t1\n\t\t\t3;\n\t\t} else {') != -1, 'the comment must open the wrapped block in: <$out>'
		);
	}

	/** A value `catch` body the try group braces takes the clause's comments inside — the cuddled one and an own-line run. */
	@:pin('control')
	@:killer('M-CLAUSE-GAP-NO-ADOPT')
	@:killer('M-SSB-WRAP-FROM-UNLIFTED')
	public function testAValueCatchHeadGapCommentMovesInsideTheWrap(): Void {
		final cuddled: String = fmt(valueReturn('try {\n\t\t\tg();\n\t\t\t1;\n\t\t} catch (e:Dynamic) // c2\n\t\t\t3;'), SYMMETRIC);
		Assert.isTrue(
			cuddled.indexOf('} catch (e:Dynamic) { // c2\n\t\t\t3;\n\t\t};') != -1,
			'the comment must open the wrapped block in: <$cuddled>'
		);
		final own: String = fmt(valueReturn('try {\n\t\t\tg();\n\t\t\t1;\n\t\t} catch (e:Dynamic)\n\t\t\t// c3\n\t\t\t3;'), SYMMETRIC);
		Assert.isTrue(
			own.indexOf('} catch (e:Dynamic) {\n\t\t\t// c3\n\t\t\t3;\n\t\t};') != -1, 'the comment must lead the wrapped body in: <$own>'
		);
	}

	/** The statement `try` takes the same move: an own-line comment before a bare catch body ends up inside its braces. */
	@:pin('control')
	@:killer('M-CLAUSE-GAP-NO-ADOPT')
	public function testAStatementCatchHeadGapCommentMovesInsideTheWrap(): Void {
		final out: String = fmt(stmtTry('\n\t\t\t// c\n\t\t\tg();'), SYMMETRIC);
		Assert.isTrue(
			out.indexOf('} catch (e:Dynamic) {\n\t\t\t// c\n\t\t\tg();\n\t\t}') != -1, 'the comment must lead the wrapped body in: <$out>'
		);
	}

	/** With the knob off nothing is braced, and the own-line comment before a bare catch body is written, not refused. */
	@:pin('control')
	@:killer('M-CATCH-BEFORE-LEADING-UNREAD')
	public function testAnOwnLineCommentBeforeABareCatchBodySurvives(): Void {
		final out: String = fmt(stmtTry('\n\t\t\t// c\n\t\t\tg();'), KEEP);
		Assert.isTrue(out.indexOf('} catch (e:Dynamic)\n\t\t\t// c\n\t\t\tg();') != -1, 'the comment must stay before the body in: <$out>');
	}

	/** The expression-bodied catch forms (statement `try` with bare bodies, value `try`) keep both comment shapes too. */
	@:pin('control')
	@:killer('M-CATCH-GAP-UNREAD')
	public function testACommentBeforeAnExpressionCatchBodySurvives(): Void {
		final bare: String = fmt(fn('try g() catch (e:Dynamic) /* c */ g();'), KEEP);
		Assert.isTrue(bare.indexOf('catch (e:Dynamic) /* c */\n\t\t\tg();') != -1, 'the block comment must stay after `)` in: <$bare>');
		final value: String = fmt(fn('var x = try g() catch (e:Dynamic)\n\t\t\t// c\n\t\t\tg();'), KEEP);
		Assert.isTrue(value.indexOf('catch (e:Dynamic)\n\t\t\t// c\n\t\t\tg();') != -1, 'the own-line comment must stay in: <$value>');
	}

	/** A block comment after `else` stays a block comment — with the knob off, and inside the braces the repair adds. */
	@:pin('control')
	@:killer('M-AFTERKW-STRIPPED')
	public function testABlockCommentAfterElseKeepsItsKind(): Void {
		final src: String = fn('if (a) {\n\t\t\tg();\n\t\t\tg();\n\t\t} else /* b2 */ g();');
		final kept: String = fmt(src, KEEP);
		Assert.isTrue(kept.indexOf('} else /* b2 */\n\t\t\tg();') != -1, 'the comment must stay a block comment in: <$kept>');
		final wrapped: String = fmt(src, SYMMETRIC);
		Assert.isTrue(
			wrapped.indexOf('} else { /* b2 */\n\t\t\tg();\n\t\t}') != -1, 'the comment must open the wrapped block in: <$wrapped>'
		);
	}

	/** A body a comment pushed off the `else` line is that branch's body, so it is indented one step — an `else if` too. */
	@:pin('control')
	@:killer('M-KW-SAME-UNNESTED')
	public function testABodyAfterAnElseCommentIsIndented(): Void {
		final value: String = fmt(valueReturn('if (a) {\n\t\t\tg();\n\t\t\t1;\n\t\t} else // c2\n\t\t\t3;'), KEEP);
		Assert.isTrue(value.indexOf('} else // c2\n\t\t\t3;') != -1, 'the value must sit one step in in: <$value>');
		final elseIf: String = fmt(fn('if (a) {\n\t\t\tg();\n\t\t} else\n\t\t\t// n2\n\t\t\tif (b) {\n\t\t\t\tg();\n\t\t\t}'), KEEP);
		Assert.isTrue(
			elseIf.indexOf('} else\n\t\t\t// n2\n\t\t\tif (b) {\n\t\t\t\tg();\n\t\t\t}') != -1,
			'the else-if must sit one step in in: <$elseIf>'
		);
	}

	/** A `switch` in THEN position has no keyword to glue to, so it gains braces opposite a braced else. */
	@:pin('control')
	@:killer('M-SSB-THEN-SKIP')
	public function testAThenSwitchGainsBracesOppositeABracedElse(): Void {
		final out: String = fmt(fn('if (a) switch k {\n\t\t\tcase _: g();\n\t\t} else {\n\t\t\tg();\n\t\t\tg();\n\t\t}'), SYMMETRIC);
		Assert.isTrue(out.indexOf('if (a) {\n\t\t\tswitch k {') != -1, 'the then switch must gain braces in: <$out>');
		Assert.isTrue(out.indexOf('\t\t\t}\n\t\t} else {') != -1, 'the braces must close before the else in: <$out>');
	}

	/**
	 * The same holds for a then-position `if`: it gains braces opposite a braced else, and the inner `else` stays bound to
	 * the inner `if`. An outer `if` with no `else` of its own has no sibling to mirror and stays bare.
	 */
	@:pin('control')
	@:killer('M-SSB-THEN-SKIP')
	public function testAThenIfGainsBracesOppositeABracedElse(): Void {
		final out: String = fmt(fn('if (a) if (b) x(); else y(); else {\n\t\t\tz();\n\t\t\tz();\n\t\t}'), SYMMETRIC);
		Assert.isTrue(
			out.indexOf('if (a) {\n\t\t\tif (b)\n\t\t\t\tx();\n\t\t\telse\n\t\t\t\ty();\n\t\t} else {') != -1,
			'the then if must gain braces in: <$out>'
		);
		final lone: String = fmt(fn('if (a) if (b) x(); else {\n\t\t\tz();\n\t\t\tz();\n\t\t}'), SYMMETRIC);
		Assert.isTrue(
			lone.indexOf('if (a)\n\t\t\tif (b) {\n\t\t\t\tx();\n\t\t\t} else {') != -1, 'only the inner pair is mirrored in: <$lone>'
		);
	}

	/** Every shape above is a fixed point of a second write. */
	public function testEveryShapeIsAFixedPoint(): Void {
		for (src in [
			valueReturn('if (a) {\n\t\t\tg();\n\t\t\t1;\n\t\t} else // c2\n\t\t\t3;'),
			valueReturn('try {\n\t\t\tg();\n\t\t\t1;\n\t\t} catch (e:Dynamic)\n\t\t\t// c3\n\t\t\t3;'),
			stmtTry('\n\t\t\t// c\n\t\t\tg();'),
			fn('if (a) {\n\t\t\tg();\n\t\t\tg();\n\t\t} else /* b2 */ g();')
		]) for (config in [KEEP, SYMMETRIC]) {
			final once: String = fmt(src, config);
			Assert.equals(once, fmt(once, config));
		}
	}

	private static function fmt(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

	private static function fn(body: String): String {
		return 'class C {\n\tfunction f(a:Bool, b:Bool, k:Int):Void {\n\t\t$body\n\t}\n}';
	}

	private static function valueReturn(body: String): String {
		return 'class C {\n\tfunction f(a:Bool):Int {\n\t\treturn $body\n\t}\n}';
	}

	/** A statement `try` whose block body has two statements and whose catch body is `catchBody`, written after `)`. */
	private static function stmtTry(catchBody: String): String {
		return fn('try {\n\t\t\tg();\n\t\t\tg();\n\t\t} catch (e:Dynamic)$catchBody');
	}

}
