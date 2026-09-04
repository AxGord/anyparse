package unit.check;

import anyparse.check.CasePatternSeparator;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `case-pattern-separator` check: a switch case label whose top-level pattern
 * separator is not the configured one is flagged `Info`, and `--fix` rewrites the
 * separator character.
 *
 * Both styles are driven by an INJECTED config so the repository's own
 * `apqlint.json` can never decide a verdict here. The comma style is the default,
 * asserted through a config that names no `style` at all.
 */
class CasePatternSeparatorCheckTest extends Test {

	/** The default style: an or-pattern is the finding, and the fix spells it with commas. */
	private static inline final COMMA_CONFIG: String = '{"rules":{"case-pattern-separator":{}}}';

	/** The opt-in style: a multi-pattern label is the finding, and the fix joins it with pipes. */
	private static inline final PIPE_CONFIG: String = '{"rules":{"case-pattern-separator":{"style":"pipe"}}}';

	/** An unrecognised `style` — must read as the comma default rather than disabling the rule. */
	private static inline final UNKNOWN_STYLE_CONFIG: String = '{"rules":{"case-pattern-separator":{"style":"pipes"}}}';

	public function testOrPatternFlaggedUnderCommaStyle(): Void {
		final vs: Array<Violation> = violations(switchOf('case PRIMARY | GOLDEN: a();'), COMMA_CONFIG);
		Assert.equals(1, vs.length);
		Assert.equals('case-pattern-separator', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('an or-pattern \'|\' in a case label; the configured separator style is \',\'', vs[0].message);
	}

	public function testCommaFixRewritesOrPattern(): Void {
		final out: String = applyFix(switchOf('case PRIMARY | GOLDEN: a();'), COMMA_CONFIG);
		Assert.isTrue(out.indexOf('case PRIMARY, GOLDEN:') != -1 && out.indexOf('|') == -1, 'expected comma separator, got: $out');
	}

	public function testCommaFixFlattensChain(): Void {
		final out: String = applyFix(switchOf('case PRIMARY | GOLDEN | SILVER: a();'), COMMA_CONFIG);
		Assert.isTrue(
			out.indexOf('case PRIMARY, GOLDEN, SILVER:') != -1 && out.indexOf('|') == -1, 'expected the whole chain flattened, got: $out'
		);
	}

	public function testCommaFixNormalisesMixedLabel(): Void {
		final out: String = applyFix(switchOf('case PRIMARY, GOLDEN | SILVER: a();'), COMMA_CONFIG);
		Assert.isTrue(
			out.indexOf('case PRIMARY, GOLDEN, SILVER:') != -1 && out.indexOf('|') == -1, 'expected one separator style, got: $out'
		);
	}

	public function testCommaFixKeepsGuard(): Void {
		final out: String = applyFix(switchOf('case PRIMARY | GOLDEN if (p): a();'), COMMA_CONFIG);
		Assert.isTrue(
			out.indexOf('case PRIMARY, GOLDEN if (p):') != -1 && out.indexOf('|') == -1, 'expected the guard preserved, got: $out'
		);
	}

	public function testNestedOrPatternNotFlagged(): Void {
		Assert.equals(0, violations(switchOf('case SOME(PRIMARY | GOLDEN): a();'), COMMA_CONFIG).length);
	}

	public function testCommaFixKeepsParenthesisedSubPattern(): Void {
		// The chain flattens down to the parenthesis and stops: inside it a comma is not a separator.
		final out: String = applyFix(switchOf('case PRIMARY | (GOLDEN | SILVER): a();'), COMMA_CONFIG);
		Assert.isTrue(out.indexOf('case PRIMARY, (GOLDEN | SILVER):') != -1, 'expected only the top-level separator respelled, got: $out');
	}

	public function testParenthesisedSubPatternNotJoined(): Void {
		Assert.equals(0, violations(switchOf('case PRIMARY, (GOLDEN | SILVER): a();'), PIPE_CONFIG).length);
	}

	public function testCaptureOverOrPatternNotFlagged(): Void {
		// `case v = A | B:` captures the whole alternation; `case v = A, B:` does not compile,
		// so the capture's or-pattern is not a separator this rule may respell.
		Assert.equals(0, violations(switchOf('case v = PRIMARY | GOLDEN: a();'), COMMA_CONFIG).length);
	}

	public function testCommaLabelCleanUnderCommaStyle(): Void {
		Assert.equals(0, violations(switchOf('case PRIMARY, GOLDEN: a();'), COMMA_CONFIG).length);
	}

	public function testCommaFixIsIdempotent(): Void {
		final once: String = applyFix(switchOf('case PRIMARY | GOLDEN | SILVER: a();'), COMMA_CONFIG);
		Assert.isTrue(once.indexOf('case PRIMARY, GOLDEN, SILVER:') != -1, 'expected one flattened label, got: $once');
		Assert.equals(0, violations(once, COMMA_CONFIG).length);
		Assert.equals(once, applyFix(once, COMMA_CONFIG));
	}

	public function testUnrecognisedStyleReadsAsComma(): Void {
		// The or-pattern is the finding and the comma label is clean — the comma reading exactly.
		Assert.equals(1, violations(switchOf('case PRIMARY | GOLDEN: a();'), UNKNOWN_STYLE_CONFIG).length);
		Assert.equals(0, violations(switchOf('case PRIMARY, GOLDEN: a();'), UNKNOWN_STYLE_CONFIG).length);
		final out: String = applyFix(switchOf('case PRIMARY | GOLDEN: a();'), UNKNOWN_STYLE_CONFIG);
		Assert.isTrue(out.indexOf('case PRIMARY, GOLDEN:') != -1 && out.indexOf('|') == -1, 'expected the comma fix, got: $out');
	}

	public function testNegatedNumericRoundTrips(): Void {
		final comma: String = applyFix(switchOf('case -1 | -2: a();'), COMMA_CONFIG);
		Assert.isTrue(comma.indexOf('case -1, -2:') != -1 && comma.indexOf('|') == -1, 'expected the split label, got: $comma');
		final back: String = applyFix(comma, PIPE_CONFIG);
		Assert.isTrue(back.indexOf('case -1 | -2:') != -1 && back.indexOf(',') == -1, 'expected the joined label back, got: $back');
	}

	public function testCommaLabelFlaggedUnderPipeStyle(): Void {
		final vs: Array<Violation> = violations(switchOf('case PRIMARY, GOLDEN: a();'), PIPE_CONFIG);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('comma-separated case patterns; the configured separator style is \'|\'', vs[0].message);
	}

	public function testPipeFixJoinsPatterns(): Void {
		final out: String = applyFix(switchOf('case PRIMARY, GOLDEN: a();'), PIPE_CONFIG);
		Assert.isTrue(out.indexOf('case PRIMARY | GOLDEN:') != -1 && out.indexOf(',') == -1, 'expected pipe separator, got: $out');
	}

	public function testPipeFixJoinsConstructorPatterns(): Void {
		// A MULTI-ARG constructor: the commas inside its argument list are not label seams, and the
		// exactly-one-separator scan reads the gap BETWEEN patterns, never their interiors.
		final out: String = applyFix(switchOf('case SOME(_, _), GOLDEN: a();'), PIPE_CONFIG);
		Assert.isTrue(
			out.indexOf('case SOME(_, _) | GOLDEN:') != -1 && out.indexOf('), ') == -1, 'expected the constructor arm joined, got: $out'
		);
	}

	public function testNullWildcardIdiomNotFlagged(): Void {
		// `case null | _:` compiles and behaves the same, but the comma spelling is the idiom.
		Assert.equals(0, violations(switchOf('case null, _: a();'), PIPE_CONFIG).length);
	}

	public function testNullConstantPairStillJoined(): Void {
		// The `null` literal is not what withdraws the idiom above — the bare wildcard beside it is.
		final out: String = applyFix(switchOf('case null, GOLDEN: a();'), PIPE_CONFIG);
		Assert.isTrue(out.indexOf('case null | GOLDEN:') != -1 && out.indexOf('null,') == -1, 'expected the pair joined, got: $out');
	}

	public function testCaptureRunNotFlagged(): Void {
		Assert.equals(0, violations(switchOf('case v = PRIMARY, w: a();'), PIPE_CONFIG).length);
	}

	public function testSingleCaptureUntouchedUnderPipeStyle(): Void {
		Assert.equals(0, violations(switchOf('case var q: a();'), PIPE_CONFIG).length);
	}

	public function testOrPatternCleanUnderPipeStyle(): Void {
		Assert.equals(0, violations(switchOf('case PRIMARY | GOLDEN: a();'), PIPE_CONFIG).length);
	}

	public function testPipeFixIsIdempotent(): Void {
		final once: String = applyFix(switchOf('case PRIMARY, GOLDEN | SILVER: a();'), PIPE_CONFIG);
		Assert.isTrue(once.indexOf('case PRIMARY | GOLDEN | SILVER:') != -1, 'expected one joined label, got: $once');
		Assert.equals(0, violations(once, PIPE_CONFIG).length);
	}

	public function testNestedSwitchReached(): Void {
		Assert.equals(
			1, violations(switchOf('case PRIMARY: switch j {\n\t\t\t\tcase GOLDEN | SILVER: a();\n\t\t\t}'), COMMA_CONFIG).length
		);
	}

	public function testMacroQuotationNotFlaggedUnderCommaStyle(): Void {
		// Inside a quotation the label is DATA: `case A | B:` reifies as ONE `EBinop(OpOr, …)` value
		// where `case A, B:` reifies as TWO, so respelling it changes what the macro builds.
		Assert.equals(0, violations(macroOf('case PRIMARY | GOLDEN: 1;'), COMMA_CONFIG).length);
	}

	public function testMacroQuotationNotFlaggedUnderPipeStyle(): Void {
		Assert.equals(0, violations(macroOf('case PRIMARY, GOLDEN: 1;'), PIPE_CONFIG).length);
	}

	public function testSwitchAfterMacroQuotationStillFlagged(): Void {
		// The skip is the quotation's SUBTREE, not everything following it.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tfinal e = macro switch m {\n\t\t\tcase PRIMARY | GOLDEN: 1;\n'
			+ '\t\t};\n\t\tswitch k {\n\t\t\tcase PRIMARY | GOLDEN: a();\n\t\t}\n\t}\n}';
		final vs: Array<Violation> = violations(src, COMMA_CONFIG);
		Assert.equals(1, vs.length);
		final span: Null<Span> = vs[0].span;
		Assert.isTrue(span != null && src.indexOf('switch k') < span.from, 'the finding must be the RUNTIME switch, not the quoted one');
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('case-pattern-separator'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('case-pattern-separator'));
	}

	/** DEFAULT OFF: the rule picks a house style, so it ships opt-in. */
	public function testDefaultOff(): Void {
		Assert.isTrue(Linter.byId('case-pattern-separator') is DefaultOff);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ', COMMA_CONFIG).length);
	}

	/** One switch statement wrapping `arm`, plus a wildcard arm so the fixtures read like real code. */
	private function switchOf(arm: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\tswitch k {\n\t\t\t$arm\n\t\t\tcase _: z();\n\t\t}\n\t}\n}';
	}

	/** The same switch, quoted — its every label is AST the macro builds rather than code that runs. */
	private function macroOf(arm: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\tfinal e = macro switch m {\n\t\t\t$arm\n\t\t\tcase _: 0;\n\t\t};\n\t}\n}';
	}

	/** The check with `configJson` injected — never `LintConfig.discover`, whose answer this repository's own config would decide. */
	private function checkOf(configJson: String): CasePatternSeparator {
		final check: CasePatternSeparator = new CasePatternSeparator();
		check.setConfigResolver(_ -> LintConfig.parse(configJson));
		return check;
	}

	private function violations(src: String, configJson: String): Array<Violation> {
		return checkOf(configJson).run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** Run `fix` and re-emit through the canonical writer — the separator edit leaves the spacing to it. */
	private function applyFix(src: String, configJson: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: CasePatternSeparator = checkOf(configJson);
		final found: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, found, plugin);
		return switch CanonicalEdit.canonicalize(src, edits, true, plugin) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
