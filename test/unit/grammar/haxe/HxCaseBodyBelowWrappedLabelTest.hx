package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * `fitLine` asks whether the whole construct stands on one line, so a case body never stands on a label that took
 * more than one, however short its last row, in either `caseSiblings` mode. What the label's flat width decides for
 * its siblings under `anyBreak` is unchanged, and so is everything about a label on one row.
 */
@:nullSafety(Strict)
final class HxCaseBodyBelowWrappedLabelTest extends Test {

	private static inline final WIDE: String = 'case Alpha, Beta, Gamma, Delta, Epsilon, Zeta';
	private static inline final ROWS: String = '\t\t\tcase Alpha, Beta, Gamma, Delta,\n\t\t\t\tEpsilon, Zeta:\n';

	/** A wrapped label alone in its switch, or beside a sibling with no body: no vote can move it, in either mode. */
	@:pin('control')
	@:killer('M-CASE-BODY-STANDS-ON-WRAPPED-LABEL')
	public function testNothingBesideItToMoveIt(): Void {
		for (mode in ['off', 'anyBreak']) {
			check(switchOf('$WIDE: qq(rr);'), switchOf('$ROWS\t\t\t\tqq(rr);'), cfg(mode));
			check(switchOf('$WIDE: qq(rr);\ncase Empty:'), switchOf('$ROWS\t\t\t\tqq(rr);\n\t\t\tcase Empty:'), cfg(mode));
		}
		// An empty body has no line to write after the last row; its wide label still leads a sibling that shares.
		check(switchOf('$WIDE:\ncase Fit: ss();'), switchOf('$ROWS\t\t\tcase Fit: ss();'), cfg('off'));
		check(switchOf('$WIDE:\ncase Fit: ss();'), switchOf('$ROWS\t\t\tcase Fit:\n\t\t\t\tss();'), cfg('anyBreak'));
	}

	/** Beside a fitting sibling the label leaves that sibling alone when each branch decides alone, and moves it when they share. */
	@:pin('control')
	@:killer('M-CASE-BODY-STANDS-ON-WRAPPED-LABEL')
	public function testBesideAFittingSibling(): Void {
		final src: String = switchOf('$WIDE: qq(rr);\ncase Fit: ss();');
		check(src, switchOf('$ROWS\t\t\t\tqq(rr);\n\t\t\tcase Fit: ss();'), cfg('off'));
		check(src, switchOf('$ROWS\t\t\t\tqq(rr);\n\t\t\tcase Fit:\n\t\t\t\tss();'), cfg('anyBreak'));
	}

	/** The last row can start where the label did, so the row's indent does not tell a wrapped label from one on one row. */
	@:pin('control')
	@:killer('M-CASE-BODY-STANDS-ON-WRAPPED-LABEL')
	public function testLastRowAtTheLabelIndent(): Void {
		final src: String = switchOf('case {aaaaaaaaaaaaaaa: 1, bbbbbbbbbbbbbbbbbb: 2, cccccccccccccc: 3}: qq(rr);');
		final out: String = switchOf(
			'\t\t\tcase {\n\t\t\t\taaaaaaaaaaaaaaa: 1,\n\t\t\t\tbbbbbbbbbbbbbbbbbb: 2,\n\t\t\t\tcccccccccccccc: 3\n\t\t\t}:\n'
			+ '\t\t\t\tqq(rr);'
		);
		for (mode in ['off', 'anyBreak']) check(src, out, cfg(mode));
	}

	/** A label wrapped by a rule rather than by width has a flat width that fits, so it casts no lead: only its own body moves. */
	@:pin('control')
	@:killer('M-CASE-BODY-STANDS-ON-WRAPPED-LABEL')
	public function testALabelWrappedByARuleMovesOnlyItsOwnBody(): Void {
		final rule: String = '"casePattern": {"defaultWrap": "noWrap", "rules": [{"type": "onePerLine", "conditions": ['
			+ '{"cond": "itemCount >= n", "value": 3}]}]}';
		final src: String = switchOf('case A, B, C: qq(rr);\ncase Fit: ss();');
		final out: String = switchOf('\t\t\tcase\n\t\t\t\tA,\n\t\t\t\tB,\n\t\t\t\tC\n\t\t\t:\n\t\t\t\tqq(rr);\n\t\t\tcase Fit: ss();');
		for (mode in ['off', 'anyBreak']) check(src, out, cfg(mode, 120, rule));
	}

	/** A label holding a line of its own text took two lines although nothing wrapped it. */
	@:pin('control')
	@:killer('M-LINE-SPAN-IGNORES-TEXT-LINES')
	public function testALabelWithALineBreakInItsToken(): Void {
		for (mode in ['off', 'anyBreak'])
			check(switchOf('case "a\nb": qq(rr);'), switchOf('\t\t\tcase "a\nb":\n\t\t\t\tqq(rr);'), cfg(mode));
	}

	/** `expressionCase` is the same decision on the same path. */
	@:pin('control')
	@:killer('M-CASE-BODY-STANDS-ON-WRAPPED-LABEL')
	public function testExpressionCase(): Void {
		final head: String = 'class A {\n\tfunction f(x) {\n\t\tvar y = switch x {\n';
		final tail: String = '\n\t\t}\n\t}\n}\n';
		final src: String = '$head$WIDE: 1;\ncase Fit: 2;$tail';
		check(src, '${head + ROWS}\t\t\t\t1;\n\t\t\tcase Fit: 2;$tail', cfg('off'));
		check(src, '${head + ROWS}\t\t\t\t1;\n\t\t\tcase Fit:\n\t\t\t\t2;$tail', cfg('anyBreak'));
	}

	/** A body that cannot render flat and a block lose the glue too, and each stands at the case indent plus one. */
	@:pin('control')
	@:killer('M-CASE-BODY-STANDS-ON-WRAPPED-LABEL')
	public function testABodyWithNoFlatForm(): Void {
		for (mode in ['off', 'anyBreak']) {
			check(
				switchOf('$WIDE: qq(function() { rr(); });'), switchOf('$ROWS\t\t\t\tqq(function() {\n\t\t\t\t\trr();\n\t\t\t\t});'),
				cfg(mode)
			);
			check(switchOf('$WIDE: { qq(); rr(); }'), switchOf('$ROWS\t\t\t\t{\n\t\t\t\t\tqq();\n\t\t\t\t\trr();\n\t\t\t\t}'), cfg(mode));
			// A trailing comment stays with the statement it rides when the body moves.
			check(switchOf('$WIDE: qq(rr); // trail'), switchOf('$ROWS\t\t\t\tqq(rr); // trail'), cfg(mode));
		}
	}

	/** A label on one row keeps its body when it fits and drops it when it does not; `default` reads no earlier label. */
	@:pin('guard')
	public function testALabelOnOneRowDecidesAsBefore(): Void {
		check(switchOf('case Fit: ss();'), switchOf('\t\t\tcase Fit: ss();'), cfg('off'));
		check(
			switchOf('case FittingLabelOnOneRow: aaaaaaaaaaaaaaaaaaaaaaa(bb);'),
			switchOf('\t\t\tcase FittingLabelOnOneRow:\n\t\t\t\taaaaaaaaaaaaaaaaaaaaaaa(bb);'), cfg('off')
		);
		check(switchOf('$WIDE: qq(rr);\ndefault: ss();'), switchOf('$ROWS\t\t\t\tqq(rr);\n\t\t\tdefault: ss();'), cfg('off'));
		// A comment above the case is written before the struct records its line, so its lines are not the label's.
		final commented: String = switchOf('\t\t\t/* a\n\t\t\t\tb */\n\t\t\tcase Fit: ss();');
		check(commented, commented, cfg('off'));
	}

	/** Only `fitLine` asks the question: a body committed to the label stays there whatever the label did. */
	@:pin('guard')
	public function testOtherPoliciesAreNotAsked(): Void {
		final same: String = '{"wrapping": {"maxLineLength": 50}, "sameLine": {"caseBody": "same"}}';
		check(switchOf('$WIDE: qq(rr);'), switchOf('\t\t\tcase Alpha, Beta, Gamma, Delta,\n\t\t\t\tEpsilon, Zeta: qq(rr);'), same);
	}

	private inline function write(src: String, config: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(config));
	}

	private function check(src: String, expected: String, config: String): Void {
		final out: String = write(src, config);
		Assert.equals(expected, out);
		Assert.equals(out, write(out, config), 'one write reaches the fixed point');
	}

	private function cfg(mode: String, width: Int = 50, ?wrapping: String): String {
		final extra: String = wrapping == null ? '' : ', $wrapping';
		return '{"wrapping": {"maxLineLength": $width$extra}, "sameLine": {"caseSiblings": "$mode'
			+ '", "caseBody": "fitLine", "expressionCase": "fitLine"}}';
	}

	private function switchOf(branches: String): String {
		return 'class A {\n\tfunction f(x) {\n\t\tswitch x {\n$branches\n\t\t}\n\t}\n}\n';
	}

}
