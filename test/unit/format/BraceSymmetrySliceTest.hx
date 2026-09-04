package unit.format;

import unit.grammar.haxe.HxWriteFixture;
import utest.Assert;
import utest.Test;

/**
 * `whitespace.bracesConfig.singleStatementBraces: "symmetric"` - the ADD direction of a policy
 * that until now only ever removed.
 *
 * The user decided it (2026-09-03), choosing the ADD direction, with the boundary stated:
 * an if/else with EXACTLY ONE braced branch gets the other braced; a bare single statement with
 * NO braced sibling is left alone. That second half is what makes this not "brace everything" -
 * Pony's `if (d.length != 4) throw '…';` must survive untouched, and `testABareBranchWithNoBracedSiblingIsUntouched`
 * is its pin.
 *
 * The value rides the SAME sibling probe the `remove` direction has always used (gate 7's
 * `siblingKeepsBraces`), so the two directions cannot drift apart: `"remove"` arms both,
 * `"symmetric"` only the repair, `"keep"` neither. `else if` and - per the same user's other
 * decision - `else switch` are exempt, because braces there would rebuild the very
 * `else { if … }` the chain form exists to avoid.
 *
 * Trivia writer throughout: the plain writer captures no source-newline slots, so a
 * "left alone" assertion against it passes vacuously.
 */
@:nullSafety(Strict)
class BraceSymmetrySliceTest extends Test {

	private static final BASE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}';
	private static final KEEP: String = '$BASE}';
	private static final SYMMETRIC: String = '$BASE, "whitespace": {"bracesConfig": {"singleStatementBraces": "symmetric"}}}';
	private static final REMOVE: String = '$BASE, "whitespace": {"bracesConfig": {"singleStatementBraces": "remove"}}}';

	public function testThenBracedElseBareGainsBraces(): Void {
		final out: String = HxWriteFixture.triviaWrite(wrap('if (a) {\n\t\t\tp();\n\t\t\tq();\n\t\t} else\n\t\t\tr();'), SYMMETRIC);
		Assert.isTrue(out.indexOf('} else {') != -1, 'the bare else must gain braces in: <$out>');
		Assert.isTrue(out.indexOf('r();') != -1, 'its statement must survive in: <$out>');
	}

	public function testThenBareElseBracedGainsBraces(): Void {
		final out: String = HxWriteFixture.triviaWrite(wrap('if (a)\n\t\t\tp();\n\t\telse {\n\t\t\tq();\n\t\t\tr();\n\t\t}'), SYMMETRIC);
		Assert.isTrue(out.indexOf('if (a) {') != -1, 'the bare then must gain braces in: <$out>');
	}

	/** The boundary the user drew: no braced sibling, nothing to be symmetric WITH, no change. */
	public function testABareBranchWithNoBracedSiblingIsUntouched(): Void {
		final src: String = wrap('if (d.length != 4)\n\t\t\tthrow \'bad\';');
		Assert.equals(HxWriteFixture.triviaWrite(src, KEEP), HxWriteFixture.triviaWrite(src, SYMMETRIC));
	}

	public function testBothBranchesBareIsUntouched(): Void {
		final src: String = wrap('if (a)\n\t\t\tp();\n\t\telse\n\t\t\tq();');
		Assert.equals(HxWriteFixture.triviaWrite(src, KEEP), HxWriteFixture.triviaWrite(src, SYMMETRIC));
	}

	/** An `else if` link is EXEMPT — bracing it rebuilds the `else { if … }` the chain avoids. */
	public function testAnElseIfLinkIsExempt(): Void {
		final out: String = HxWriteFixture.triviaWrite(wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b)\n\t\t\tq();'), SYMMETRIC);
		Assert.isTrue(out.indexOf('} else if (b)') != -1, 'the else-if link must stay a link in: <$out>');
		Assert.isTrue(out.indexOf('else {') == -1, 'the link must not be wrapped in a block in: <$out>');
	}

	/** An `else switch` is exempt for the same reason — the user asked for `} else switch s {`. */
	public function testAnElseSwitchIsExempt(): Void {
		final src: String = wrap('if (a) {\n\t\t\tp();\n\t\t} else\n\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\tq();\n\t\t\t}');
		final out: String = HxWriteFixture.triviaWrite(src, SYMMETRIC);
		Assert.isTrue(out.indexOf('else {') == -1, 'the switch else-body must not be wrapped in a block in: <$out>');
	}

	/**
	 * A `switch` in the else of a VALUE `if` is exempt too — the value path has its own skip
	 * list, spelled in the grammar as `@:fmt(valueBraceSymmetry(…))`'s tail, and it named only
	 * `IfExpr`. Found by the Pony sweep, not by a fixture: `pony/color/UColor.hx:216` came out
	 * `} else {` + `switch s {` instead of `} else switch s {`, because the statement skip list
	 * and the value one are two lists and only the first had been taught about `switch`.
	 */
	public function testAValueIfElseSwitchIsExempt(): Void {
		final src: String = 'class C {\n\tfunction f(s:String):Int {\n\t\treturn if (s == \'\') {\n\t\t\tp();\n\t\t\t0;\n'
			+ '\t\t} else\n\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\t1;\n\t\t\t}\n\t}\n}';
		final out: String = HxWriteFixture.triviaWrite(src, SYMMETRIC);
		Assert.isTrue(out.indexOf('else {') == -1, 'the value-if switch else-body must not be wrapped in a block in: <$out>');
	}

	/** A comment trailing the bare branch travels INTO the block the repair creates. */
	public function testATrailingCommentOnTheBareBranchSurvives(): Void {
		final out: String = HxWriteFixture.triviaWrite(wrap('if (a) {\n\t\t\tp();\n\t\t\tq();\n\t\t} else\n\t\t\tr(); // why'), SYMMETRIC);
		Assert.isTrue(out.indexOf('// why') != -1, 'the comment must survive the wrap in: <$out>');
	}

	/** `keep` is the default and is byte-inert on every shape above. */
	public function testKeepChangesNothing(): Void {
		final src: String = wrap('if (a) {\n\t\t\tp();\n\t\t\tq();\n\t\t} else\n\t\t\tr();');
		Assert.equals(src, HxWriteFixture.triviaWrite(src, KEEP));
	}

	/**
	 * `remove` still does BOTH: it de-braces where it can and repairs the asymmetry it cannot.
	 * Splitting the field must not split the behaviour of the value that already existed.
	 */
	public function testRemoveStillRepairsAsymmetry(): Void {
		final out: String = HxWriteFixture.triviaWrite(wrap('if (a) {\n\t\t\tp();\n\t\t\tq();\n\t\t} else\n\t\t\tr();'), REMOVE);
		Assert.isTrue(out.indexOf('} else {') != -1, 'remove must still brace the bare sibling in: <$out>');
	}

	public function testTheRepairIsIdempotent(): Void {
		final once: String = HxWriteFixture.triviaWrite(wrap('if (a) {\n\t\t\tp();\n\t\t\tq();\n\t\t} else\n\t\t\tr();'), SYMMETRIC);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, SYMMETRIC));
	}

	private function wrap(body: String): String {
		return 'class C {\n\tfunction f(a:Bool, b:Bool, d:String, s:String):Void {\n\t\t$body\n\t}\n}';
	}

}
