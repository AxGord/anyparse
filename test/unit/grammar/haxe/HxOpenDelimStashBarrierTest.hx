package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * ω-open-delim-interiority — a trivia stash captured BEFORE a Star's open
 * literal is not the first element's own leading gap.
 *
 * `HxFnExpr.body` is `@:optional @:absentOn(...)`, and `Lowering.
 * emitAbsentOnRefField` runs a `collectTrivia` for that absence peek. In
 * trivia mode any signal it finds is parked in `ctx.pendingTrivia`, and on
 * the PRESENT branch it stays parked — nothing between it and the body
 * drains it. So for
 *
 * ```
 * var t = function(a, b)
 * 	return [for (key in o) key => 1];
 * ```
 *
 * the newline that precedes `return` travelled past `[` and was drained by
 * the ARRAY's element 0, whose `newlineBefore` the `reflowSourceMultiline`
 * scan (`TriviaSepLowering.triviaSepPredicateScanExpr`) reads as "a
 * comprehension element genuinely starts on its own line after `[`". The
 * bracket then broke open on a source line the source never had.
 *
 * The fix is positional, not a classifier tweak: consuming the open literal
 * PROVES the elements are inside the bracket, so both trivia-Star open-lit
 * emitters (`lowerTriviaStarBranch` for an Alt branch, `emitTriviaStar
 * FieldSteps` for a struct field) push `stashNewlineClearExpr` right after
 * their `expectLit`. Only the newline / blank signals are cleared; leading
 * COMMENTS keep travelling, which is a separate, still-open mis-attribution
 * (`function(a, b)\n\t// c\n\treturn [x]` puts `// c` inside the bracket)
 * and deliberately out of this slice.
 *
 * The counter-example is what keeps the fix honest: a newline that really
 * IS between `[` and the first element must still break the bracket open.
 * Deleting the carve-out in the classifier instead — the blunt fix S16
 * priced — passes this file's first assertion and fails that one.
 *
 * The barrier is wider than the reported bug: the two emitters serve every
 * `@:lead` + `@:trivia` Star in the grammar. Measured base-vs-new over a
 * probe file, three families move — an array or comprehension bracket (the
 * report), an object literal or anon type written flat on the line after a
 * break, and Keep mode; Allman braces, parameter and argument lists, lambda
 * bodies, case bodies, ternary branches and `#if` regions all came back
 * byte-identical. `testBareObjectLiteralOnItsOwnLineStaysFlat` and
 * `testKeepModeHonoursOnlyInBracketNewlines` are here so the widened scope
 * is pinned rather than only described.
 *
 * Mutation coverage, measured: dropping the barrier from
 * `lowerTriviaStarBranch` kills
 * `testBracelessAnonFnBodyComprehensionStaysFlat` and
 * `testNewlineBeforeOpenBracketStaysFlat`; dropping it from
 * `emitTriviaStarFieldSteps` kills
 * `testBracelessAnonFnBodyObjectLiteralStaysFlat`; widening the clear to
 * `leadingComments` kills `testLeadingCommentSurvivesTheBarrier`.
 *
 * Two are green at base BY CONSTRUCTION, and they are not the same kind of
 * guard. `testInBracketNewlineStillBreaksOpen` IS the over-reach guard —
 * its newline really is inside the bracket, so it fails the moment the
 * barrier reaches too far, and it is also what the blunt alternative (S16
 * priced the carve-out deletion at net 0) would fail.
 * `testBlockStatementComprehensionStaysFlat` cannot fail from over-reach at
 * all: its shape produces no stash, so the barrier is a literal no-op on
 * it. It is a control — it pins only that nothing changed there.
 */
@:nullSafety(Strict)
class HxOpenDelimStashBarrierTest extends Test {

	/** The reported shape: the newline sits before `return`, outside the bracket. */
	private static inline final BRACELESS_FN_ARRAY: String =
		'class M {\n\tstatic function f(o:Array<String>) {\n\t\tvar t = function(a, b)\n\t\t\treturn [for (key in o) key => 1];\n\t\treturn t;\n\t}\n}\n';

	/** Same statement, newline moved INSIDE the bracket — the break is then the source's own. */
	private static inline final IN_BRACKET_NEWLINE: String =
		'class M {\n\tstatic function f(o:Array<String>) {\n\t\tvar t = function(a, b) return [\n\t\t\tfor (key in o) key => 1];\n\t\treturn t;\n\t}\n}\n';

	/** Struct-field Star (`HxObjectLit.fields`) reached through the same stash. */
	private static inline final BRACELESS_FN_OBJECT: String =
		'class M {\n\tstatic function f(o:Array<String>) {\n\t\tvar t = function(a, b)\n\t\t\treturn {k: [for (key in o) key => 1]};\n\t\treturn t;\n\t}\n}\n';

	/** No anon fn at all: the Pratt no-match stash left by `=` before an own-line `[`. */
	private static inline final NEWLINE_BEFORE_OPEN_BRACKET: String =
		'class M {\n\tstatic function f(o:Array<String>) {\n\t\tvar b =\n\t\t\t[for (key in o) key => 1];\n\t\treturn b;\n\t}\n}\n';

	/** The stash also carries a leading comment; that half must reach the element intact. */
	private static inline final BRACELESS_FN_LEADING_COMMENT: String =
		'class M {\n\tstatic function f(o:Array<String>) {\n\t\tvar t = function(a, b)\n\t\t\t// MARKER\n\t\t\treturn [for (key in o) key => 1];\n\t\treturn t;\n\t}\n}\n';

	/** No anon fn: the Pratt no-match stash `=` leaves before an own-line `{`. */
	private static inline final BARE_OBJECT_LIT_OWN_LINE: String =
		'class M {\n\tstatic function f() {\n\t\tvar c =\n\t\t\t{k: 1, m: 2};\n\t\treturn c;\n\t}\n}\n';

	/** `a1` has the newline before `[`, `a2` after it — Keep must tell them apart. */
	private static inline final KEEP_MODE_ARRAYS: String =
		'class M {\n\tstatic function f() {\n\t\tvar a1 =\n\t\t\t[1, 2, 3];\n\t\tvar a2 = [\n\t\t\t1, 2, 3];\n\t\treturn [a1, a2];\n\t}\n}\n';

	/** Source-faithful array wrapping — `rules: []` clears the cascade so `keep` is what answers. */
	private static inline final KEEP_ARRAY_WRAP: String = '{"wrapping":{"arrayWrap":{"defaultWrap":"keep","rules":[]}}}';

	/** Control: an ordinary statement in a block — no stash is ever produced here. */
	private static inline final PLAIN_BLOCK_STATEMENT: String =
		'class M {\n\tstatic function f(o:Array<String>) {\n\t\tvar a = 1;\n\t\treturn [for (key in o) key => 1];\n\t}\n}\n';

	private static inline final FLAT: String = '[for (key in o) key => 1]';

	public function new(): Void {
		super();
	}

	public function testBracelessAnonFnBodyComprehensionStaysFlat(): Void {
		final out: String = write(BRACELESS_FN_ARRAY);
		Assert.isTrue(out.indexOf(FLAT) != -1, 'expected a flat comprehension bracket in: <$out>');
	}

	public function testInBracketNewlineStillBreaksOpen(): Void {
		final out: String = write(IN_BRACKET_NEWLINE);
		Assert.isTrue(out.indexOf(FLAT) == -1, 'a genuine in-bracket newline must still break the bracket open: <$out>');
		Assert.isTrue(out.indexOf('[\n') != -1, 'expected a break right after the open bracket in: <$out>');
	}

	public function testBracelessAnonFnBodyObjectLiteralStaysFlat(): Void {
		final out: String = write(BRACELESS_FN_OBJECT);
		Assert.isTrue(out.indexOf('{k: [for (key in o) key => 1]}') != -1, 'expected a flat object literal in: <$out>');
	}

	public function testNewlineBeforeOpenBracketStaysFlat(): Void {
		final out: String = write(NEWLINE_BEFORE_OPEN_BRACKET);
		Assert.isTrue(out.indexOf('var b = [for (key in o) key => 1];') != -1, 'expected a flat comprehension bracket in: <$out>');
	}

	public function testBlockStatementComprehensionStaysFlat(): Void {
		final out: String = write(PLAIN_BLOCK_STATEMENT);
		Assert.isTrue(out.indexOf(FLAT) != -1, 'expected a flat comprehension bracket in: <$out>');
	}

	/**
	 * The barrier clears newline and blank, never a comment — a leading comment is
	 * content, and dropping it would trip the writer's own comment-loss guard.
	 * Pins the half of the stash that must survive; it fails if the clear is widened
	 * to `leadingComments`.
	 */
	public function testLeadingCommentSurvivesTheBarrier(): Void {
		Assert.isTrue(write(BRACELESS_FN_LEADING_COMMENT).indexOf('// MARKER') != -1, 'the leading comment must not be dropped');
	}

	/**
	 * No anon fn and no comprehension — the plainest shape the widened barrier
	 * moves, and the one most likely to appear in real code. Same emitter as
	 * `testBracelessAnonFnBodyObjectLiteralStaysFlat`, so it is not separately
	 * mutation-killable; it is here because the scope deserves a fixture rather
	 * than only a sentence in a doc comment.
	 */
	public function testBareObjectLiteralOnItsOwnLineStaysFlat(): Void {
		final out: String = write(BARE_OBJECT_LIT_OWN_LINE);
		Assert.isTrue(out.indexOf('var c = {k: 1, m: 2};') != -1, 'expected a flat object literal in: <$out>');
	}

	/**
	 * Keep mode is the one place the classifier deliberately does NOT suppress
	 * element 0 (`triviaSepPredicateScanExpr` guards its carve-out with
	 * `!_keepEmit`), because Keep exists to reproduce the source breaks verbatim.
	 * The barrier runs UPSTREAM of that exemption, so both halves need pinning at
	 * once: a newline before `[` must stop re-emerging as a break after `[`, and a
	 * newline that really is after `[` must still be reproduced. Only the first
	 * assertion is red at base.
	 */
	public function testKeepModeHonoursOnlyInBracketNewlines(): Void {
		final out: String = write(KEEP_MODE_ARRAYS, KEEP_ARRAY_WRAP);
		Assert.isTrue(out.indexOf('var a1 = [1, 2, 3];') != -1, 'a newline before `[` is not a break inside it: <$out>');
		Assert.isTrue(out.indexOf('var a2 = [\n') != -1, 'a newline after `[` must still be reproduced: <$out>');
	}

	private inline function write(src: String, json: String = '{}'): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(json));
	}

}
