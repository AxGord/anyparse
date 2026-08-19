package unit;

import haxe.Exception;
import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * Round-trip tests for the sep-Star CLOSE-TRAILING comment slot: a same-line
 * comment that sits AFTER a braced/bracketed literal's closing delimiter.
 *
 * ```
 * var xs = [
 *     {iso: 'a', unix: 1}, // first
 *     {iso: 'b', unix: 2} // last
 * ];
 * ```
 *
 * The `// last` comment is NOT captured on the array element's
 * `Trivial.trailingComment` — the object literal's own field Star grabs it
 * first, into its close-trailing slot (`fieldsTrailingClose`, the
 * `_trailClose` local of `TriviaSepLowering.triviaSepStarExpr`). Only three
 * of that function's emit paths read the slot back out: the two empty-list
 * shapes and the force-multi branch. Everything the fit-driven wrap cascade
 * renders — which is every SHORT literal, the overwhelmingly common one —
 * silently dropped it. `apq fmt` caught the loss and refused the file, so no
 * bytes were corrupted, but the file could not be formatted at all.
 *
 * The slot is shared by every `@:trivia @:sep` Star, so the defect reached
 * the array literal, the object literal, the anon-type hint and the
 * declaration parameter list alike, in whichever position the literal
 * appeared. A call ARGUMENT list is a `@:postfix` Star with its own
 * `closeTrailing` slot and was never affected — the comment there is lost or
 * kept by the enclosing construct's Star, not by the call's.
 *
 * The sibling half is emission SHAPE: a `//` close-trailing comment ends its
 * source line, so anything the caller glues after it (the enclosing list's
 * `,`) is swallowed into the comment text. Both the cascade path and the
 * pre-existing force-multi path route through `trailingCommentDocGuarded`,
 * whose forward-looking break drops when the next emit is already a hardline.
 */
class HxSepStarCloseTrailCommentTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	// --- 1. the named defect: the wrap-cascade path dropped the slot -----

	/** The live TM shape: last array item is an object literal, no trailing comma. */
	public function testArrayLastObjectLiteralKeepsCloseTrail(): Void {
		assertSurvives('class C {\n\tstatic function f() {\n\t\treturn [\n\t\t\t{a: 1},\n\t\t\t{a: 2} // last\n\t\t];\n\t}\n}', '// last');
	}

	/** A block-style close-trailing on a NON-last element — same slot, no `_isLast` involved. */
	public function testArrayInnerObjectLiteralKeepsCloseTrail(): Void {
		final source: String = 'class C {\n\tstatic function f() {\n\t\tvar xs = [{a: 1} /* c */, 2];\n\t}\n}';
		assertSurvives(source, '/* c */');
		Assert.equals('$source\n', roundTrip(source));
	}

	/** A sole array item that is an object literal. */
	public function testArraySoleObjectLiteralKeepsCloseTrail(): Void {
		assertSurvives('class C {\n\tstatic function f() {\n\t\treturn [\n\t\t\t{a: 1} // sole\n\t\t];\n\t}\n}', '// sole');
	}

	/** A nested ARRAY as the last item — the same Star, a different close delimiter. */
	public function testArrayLastNestedArrayKeepsCloseTrail(): Void {
		assertSurvives('class C {\n\tstatic function f() {\n\t\tvar xs = [\n\t\t\t[1, 2],\n\t\t\t[3, 4] // last\n\t\t];\n\t}\n}', '// last');
	}

	/** An object literal as the last FIELD VALUE of an object literal. */
	public function testObjectLitLastFieldObjectValueKeepsCloseTrail(): Void {
		assertSurvives('class C {\n\tstatic function f() {\n\t\tvar o = {\n\t\t\ta: 1,\n\t\t\tb: {c: 2} // last\n\t\t};\n\t}\n}', '// last');
	}

	/** An anon-type hint whose last field type is itself an anon type. */
	public function testAnonTypeLastFieldAnonKeepsCloseTrail(): Void {
		assertSurvives('class C {\n\tstatic function f(p:{\n\t\ta:Int,\n\t\tb:{c:Int} // last\n\t}) {}\n}', '// last');
	}

	/** An object literal as the last CALL ARGUMENT. */
	public function testCallLastArgObjectLiteralKeepsCloseTrail(): Void {
		assertSurvives('class C {\n\tstatic function f() {\n\t\tg(\n\t\t\t1,\n\t\t\t{a: 2} // last\n\t\t);\n\t}\n}', '// last');
	}

	/** An object literal as a declaration parameter's DEFAULT value. */
	public function testParamDefaultObjectLiteralKeepsCloseTrail(): Void {
		assertSurvives('class C {\n\tstatic function f(\n\t\ta:Int,\n\t\tb:Dynamic = {c: 2} // last\n\t) {}\n}', '// last');
	}

	// --- 2. the emission shape: a `//` must not swallow the next token ---

	/**
	 * The force-multi path already emitted the slot, but VERBATIM: the
	 * enclosing array's separator was glued after the `//` and became
	 * comment text (`} // c,`), so the round trip changed the comment.
	 */
	public function testForceMultiCloseTrailDoesNotSwallowSeparator(): Void {
		final source: String = 'class C {\n\tstatic function f() {\n\t\tvar xs = [\n\t\t\t{\n\t\t\t\ta: 1,\n\t\t\t\tb: 2\n\t\t\t} // c\n\t\t\t,\n\t\t\t2\n\t\t];\n\t}\n}';
		assertSurvives(source, '// c');
	}

	// --- 3. shapes that already worked must not regress ------------------

	/** An EMPTY object literal keeps its close-trailing (the `_arr.length == 0` arm). */
	public function testEmptyObjectLiteralKeepsCloseTrail(): Void {
		final source: String = 'class C {\n\tstatic function f() {\n\t\tvar xs = [{} /* c */, 2];\n\t}\n}';
		assertSurvives(source, '/* c */');
		Assert.equals('$source\n', roundTrip(source));
	}

	/** A force-multi object literal keeps its close-trailing (the `_forceMulti` arm). */
	public function testForceMultiObjectLiteralKeepsCloseTrail(): Void {
		final source: String = 'class C {\n\tstatic function f() {\n\t\tvar xs = [\n\t\t\t{\n\t\t\t\ta: 1,\n\t\t\t\tb: 2\n\t\t\t} /* c */,\n\t\t\t2\n\t\t];\n\t}\n}';
		assertSurvives(source, '/* c */');
		Assert.equals('$source\n', roundTrip(source));
	}

	/** A scalar last item routes the comment to the ELEMENT slot, never to this one. */
	public function testScalarLastItemUnaffected(): Void {
		final source: String = 'class C {\n\tstatic function f() {\n\t\treturn [\n\t\t\t1,\n\t\t\t2 // last\n\t\t];\n\t}\n}';
		assertSurvives(source, '// last');
		Assert.equals('$source\n', roundTrip(source));
	}

	/** A call as the last item is saved by the postfix Star's own `closeTrailing`. */
	public function testCallLastItemUnaffected(): Void {
		final source: String = 'class C {\n\tstatic function f() {\n\t\treturn [\n\t\t\tg(1),\n\t\t\tg(2) // last\n\t\t];\n\t}\n}';
		assertSurvives(source, '// last');
		Assert.equals('$source\n', roundTrip(source));
	}

	/** A comment-free literal is byte-inert. */
	public function testNoCommentIsByteInert(): Void {
		final source: String = 'class C {\n\tstatic function f() {\n\t\tvar xs = [{a: 1}, {a: 2}];\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/**
	 * The seam assertion: the emitted source must still carry the comment
	 * VERBATIM, must re-parse, and must be a fixed point of a second pass.
	 */
	private function assertSurvives(source: String, comment: String): Void {
		final out: String = roundTrip(source);
		// A LINE comment must still END ITS LINE: the pre-slice force-multi
		// path emitted the slot verbatim and the enclosing list's `,` was
		// glued into the comment text (`} // c,`), which `indexOf(comment)`
		// alone reports as survival.
		final needle: String = StringTools.startsWith(comment, '//') ? '$comment\n' : comment;
		Assert.isTrue(out.indexOf(needle) >= 0, 'comment lost or mangled: <$out>');
		try {
			HaxeModuleTriviaParser.parse(out);
		} catch (exception: Exception) {
			Assert.fail('emitted source does not re-parse: <$out>, err=${exception.message}');
			return;
		}
		Assert.equals(out, roundTrip(out), 'not idempotent: <$out>');
	}

	private function roundTrip(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

}
