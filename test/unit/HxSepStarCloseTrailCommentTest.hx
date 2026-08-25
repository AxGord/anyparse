package unit;

import haxe.Exception;
import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

using StringTools;

/**
 * Round-trip tests for the sep-Star CLOSE-TRAILING comment slot: a same-line
 * comment that sits AFTER a braced or bracketed literal's closing delimiter.
 *
 * ```
 * var xs = [
 *     {iso: 'a', unix: 1}, // first
 *     {iso: 'b', unix: 2} // last
 * ];
 * ```
 *
 * `// last` is NOT captured on the array element's `Trivial.trailingComment`.
 * The object literal's own field Star grabs it first, into its close-trailing
 * slot (`fieldsTrailingClose`, the `_trailClose` local of
 * `TriviaSepLowering.triviaSepStarExpr`) — so the enclosing list cannot rescue
 * it. Only three of that function's emit paths ever read the slot back out:
 * the two empty-list shapes and the force-multi branch. Everything the
 * fit-driven wrap cascade renders — which is every SHORT literal, the
 * overwhelmingly common one — dropped it. `apq fmt` caught the loss and
 * refused the file, so no bytes were corrupted, but the file could not be
 * formatted at all.
 *
 * The slot is shared by every `@:trivia @:sep` Star, so the defect reached the
 * array literal, the object literal, the anon-type hint and the declaration
 * parameter list alike, in whichever position the literal appeared. A call
 * ARGUMENT list is a `@:postfix` Star with its own `closeTrailing` slot and was
 * never affected — that slot is the mechanism that saved `g(2) // c`, and it is
 * why the defect looked like it was about object literals specifically.
 *
 * The sibling half is emission SHAPE: a `//` close-trailing ends its source
 * line, so anything the caller glues after it — the enclosing list's `,` — is
 * swallowed into the comment text. Both the cascade path and the pre-existing
 * force-multi path emit through `trailingCommentDocGuarded`, whose
 * forward-looking break drops when the next emit is already a hardline, so
 * every seam that was already sound stays byte-identical.
 */
class HxSepStarCloseTrailCommentTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	/** The source that reaches the force-multi arm with a LINE close-trailing. */
	private static final FORCE_MULTI_LINE_COMMENT: String =
		'class C {\n\tstatic function f() {\n\t\tvar xs = [\n\t\t\t{\n\t\t\t\ta: 1\n\t\t\t} // c\n\t\t\t,\n\t\t\t2\n\t\t];\n\t}\n}';

	/** The same shape with a BLOCK close-trailing — the seam was always sound. */
	private static final FORCE_MULTI_BLOCK_COMMENT: String =
		'class C {\n\tstatic function f() {\n\t\tvar xs = [\n\t\t\t{\n\t\t\t\ta: 1\n\t\t\t} /* c */,\n\t\t\t2\n\t\t];\n\t}\n}';

	// --- 1. the named defect: the wrap-cascade path dropped the slot -----

	/** The live TM shape: last array item is an object literal, no trailing comma. */
	public inline function testArrayLastObjectLiteralKeepsCloseTrail(): Void {
		assertUnchanged('class C {\n\tstatic function f() {\n\t\treturn [\n\t\t\t{a: 1},\n\t\t\t{a: 2} // last\n\t\t];\n\t}\n}', '// last');
	}

	/** A block-style close-trailing on a NON-last element — the slot, not `_isLast`. */
	public inline function testArrayInnerObjectLiteralKeepsCloseTrail(): Void {
		assertUnchanged('class C {\n\tstatic function f() {\n\t\tvar xs = [{a: 1} /* c */, 2];\n\t}\n}', '/* c */');
	}

	/** A sole array item that is an object literal. */
	public inline function testArraySoleObjectLiteralKeepsCloseTrail(): Void {
		assertUnchanged('class C {\n\tstatic function f() {\n\t\treturn [\n\t\t\t{a: 1} // sole\n\t\t];\n\t}\n}', '// sole');
	}

	/** A nested ARRAY as the last item — the same Star, a different close delimiter. */
	public inline function testArrayLastNestedArrayKeepsCloseTrail(): Void {
		assertUnchanged(
			'class C {\n\tstatic function f() {\n\t\tvar xs = [\n\t\t\t[1, 2],\n\t\t\t[3, 4] // last\n\t\t];\n\t}\n}', '// last'
		);
	}

	/** An object literal as the last FIELD VALUE of an object literal. */
	public inline function testObjectLitLastFieldObjectValueKeepsCloseTrail(): Void {
		assertUnchanged(
			'class C {\n\tstatic function f() {\n\t\tvar o = {\n\t\t\ta: 1,\n\t\t\tb: {c: 2} // last\n\t\t};\n\t}\n}', '// last'
		);
	}

	/** An anon-type hint whose last field type is itself an anon type. */
	public inline function testAnonTypeLastFieldAnonKeepsCloseTrail(): Void {
		assertUnchanged('class C {\n\tstatic function f(p:{\n\t\ta:Int,\n\t\tb:{c:Int} // last\n\t}) {}\n}', '// last');
	}

	/**
	 * An object literal as the last CALL ARGUMENT.
	 *
	 * ω-item-close-trail: this used to expect `g(1, {a: 2} // last` with a lone
	 * `);` under it — the multi-arg collection glue
	 * (`WrapList.shapeMultiArgCollection`) overriding a cascade that had
	 * already resolved to a breaking mode, after which the comment guard broke
	 * the seam and left the closer by itself under a fully packed call. The
	 * slot SURVIVED, which is this class's subject, so the shape rode along as
	 * expected bytes rather than being chosen.
	 *
	 * The glue now declines a list whose last item ends in `//` and the mode's
	 * own shape emits instead. Under these compiled defaults that mode is
	 * `FillLine`, so the closer moves to the continuation indent rather than
	 * all the way onto its own opened list — a smaller improvement than the one
	 * `HxFillAfterCollectionTest` pins under a `fillLineWithLeadingBreak`
	 * cascade, where the call opens and the closer returns to the statement
	 * indent. Both are the cascade's own answer; neither is this glue's.
	 */
	public inline function testCallLastArgObjectLiteralKeepsCloseTrail(): Void {
		assertRewrites(
			'class C {\n\tstatic function f() {\n\t\tg(\n\t\t\t1,\n\t\t\t{a: 2} // last\n\t\t);\n\t}\n}',
			'class C {\n\tstatic function f() {\n\t\tg(1,\n\t\t\t{a: 2} // last\n\t\t\t);\n\t}\n}\n', '// last'
		);
	}

	/** An object literal as a declaration parameter's DEFAULT value. */
	public inline function testParamDefaultObjectLiteralKeepsCloseTrail(): Void {
		assertRewrites(
			'class C {\n\tstatic function f(\n\t\ta:Int,\n\t\tb:Dynamic = {c: 2} // last\n\t) {}\n}',
			'class C {\n\tstatic function f(a:Int,\n\t\tb:Dynamic = {c: 2} // last\n\t\t) {}\n}\n', '// last'
		);
	}

	// --- 2. the emission shape: a `//` must not swallow the next token ---

	/**
	 * The force-multi path did emit the slot, but VERBATIM: the enclosing
	 * array's separator was glued after the `//` and became comment text
	 * (`} // c,`), so the round trip silently changed the comment.
	 */
	public inline function testForceMultiCloseTrailKeepsSeparatorOut(): Void {
		assertUnchanged(FORCE_MULTI_LINE_COMMENT, '// c');
	}

	// --- 3. shapes that already worked must not regress ------------------

	/** An EMPTY object literal keeps its close-trailing (the `_arr.length == 0` arm). */
	public inline function testEmptyObjectLiteralKeepsCloseTrail(): Void {
		assertUnchanged('class C {\n\tstatic function f() {\n\t\tvar xs = [{} /* c */, 2];\n\t}\n}', '/* c */');
	}

	/** A force-multi object literal keeps its close-trailing (the `_forceMulti` arm). */
	public inline function testForceMultiObjectLiteralKeepsCloseTrail(): Void {
		assertUnchanged(FORCE_MULTI_BLOCK_COMMENT, '/* c */');
	}

	/** A scalar last item routes the comment to the ELEMENT slot, never to this one. */
	public inline function testScalarLastItemUnaffected(): Void {
		assertUnchanged('class C {\n\tstatic function f() {\n\t\treturn [\n\t\t\t1,\n\t\t\t2 // last\n\t\t];\n\t}\n}', '// last');
	}

	/** A call as the last item is saved by the postfix Star's own `closeTrailing`. */
	public inline function testCallLastItemUnaffected(): Void {
		assertUnchanged('class C {\n\tstatic function f() {\n\t\treturn [\n\t\t\tg(1),\n\t\t\tg(2) // last\n\t\t];\n\t}\n}', '// last');
	}

	/** A comment-free literal is byte-inert. */
	public inline function testNoCommentIsByteInert(): Void {
		final source: String = 'class C {\n\tstatic function f() {\n\t\tvar xs = [{a: 1}, {a: 2}];\n\t}\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/** The comment survives and the source is already a fixed point. */
	private inline function assertUnchanged(source: String, comment: String): Void {
		assertRewrites(source, '$source\n', comment);
	}

	/**
	 * The seam assertion: the emitted source must carry the comment VERBATIM,
	 * must match `expected` byte for byte, must re-parse, and must be a fixed
	 * point of a second pass.
	 */
	private function assertRewrites(source: String, expected: String, comment: String): Void {
		final out: String = roundTrip(source);
		// A LINE comment must still END ITS LINE: the pre-slice force-multi path
		// emitted the slot verbatim and the enclosing list's `,` was glued into
		// the comment text (`} // c,`), which `indexOf(comment)` alone reports
		// as survival.
		final needle: String = comment.startsWith('//') ? '$comment\n' : comment;
		Assert.isTrue(out.indexOf(needle) >= 0, 'comment lost or mangled: <$out>');
		Assert.equals(expected, out);
		try {
			HaxeModuleTriviaParser.parse(out);
		} catch (exception: Exception) {
			Assert.fail('emitted source does not re-parse: <$out>');
			return;
		}
		Assert.equals(out, roundTrip(out), 'not idempotent: <$out>');
	}

	private function roundTrip(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

}
