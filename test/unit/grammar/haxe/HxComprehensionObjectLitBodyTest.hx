package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * The placement of an object literal that is the body of a comprehension `for`. `sameLine.forBody: fitLine` keeps its
 * `{` on the `for` line, `sameLine.comprehensionFor: fitLine` lets its width alone decide its lines, and every other
 * config keeps the Allman placement `HxForExpr.body` falls back to.
 */
@:nullSafety(Strict)
final class HxComprehensionObjectLitBodyTest extends Test {

	/** The first field name of the wide literal. */
	private static inline final NAME_A: String = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

	/** The second field name of the wide literal. */
	private static inline final NAME_B: String = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

	/** `forBody: fitLine` alone, with `comprehensionFor` absent. */
	private static final CFG_FOR_BODY: String = cfg('"forBody": "fitLine"');

	/** `comprehensionFor: same` spelled out, which defers to `forBody` just as the absent key does. */
	private static final CFG_FOR_BODY_SAME: String = cfg('"forBody": "fitLine", "comprehensionFor": "same"');

	/** `comprehensionFor: keep` places the body itself, so `forBody` has no say. */
	private static final CFG_FOR_BODY_KEEP: String = cfg('"forBody": "fitLine", "comprehensionFor": "keep"');

	/** `comprehensionFor: next` places the body itself too. */
	private static final CFG_FOR_BODY_NEXT: String = cfg('"forBody": "fitLine", "comprehensionFor": "next"');

	/** `comprehensionFor: fitLine` alone. */
	private static final CFG_COMPREHENSION: String = cfg('"comprehensionFor": "fitLine"');

	/** Both knobs on `fitLine`. */
	private static final CFG_BOTH: String = cfg('"forBody": "fitLine", "comprehensionFor": "fitLine"');

	/** No `sameLine` key at all. */
	private static final CFG_DEFAULT: String = cfg('');

	/** The Allman placement every config without a `fitLine` knob gives a source-multi-line literal. */
	private static final ALLMAN: String = wrap(
		'var x = [\n\t\t\tfor (i in xs)\n\t\t\t\t{\n\t\t\t\t\ta: i,\n\t\t\t\t\tb: i\n\t\t\t\t}\n\t\t];'
	);

	/** The glued placement `forBody: fitLine` gives one. */
	private static final GLUED: String = wrap('var x = [\n\t\t\tfor (i in xs) {\n\t\t\t\ta: i,\n\t\t\t\tb: i\n\t\t\t}\n\t\t];');

	/** A literal too wide for the line, as the source wrote it flat. */
	private static final WIDE_FLAT: String = wrap('var x = [for (i in xs) {$NAME_A: i, $NAME_B: i}];');

	public function new(): Void {
		super();
	}

	/** The literal glues whichever line the source put its `{` on. */
	@:pin('control') @:killer('M-OBJLIT-GLUE-FORBODY-OFF')
	public function testForBodyFitLineGluesTheLiteral(): Void {
		Assert.equals(GLUED, write(cuddledSource(), CFG_FOR_BODY));
		Assert.equals(GLUED, write(allmanSource(), CFG_FOR_BODY));
		Assert.equals(GLUED, write(GLUED, CFG_FOR_BODY));
	}

	/** An absent key defers to `forBody` exactly as the spelled-out `same` does. */
	@:pin('control') @:killer('M-OBJLIT-GLUE-ABSENT-KEY')
	public function testAbsentComprehensionForDefersToForBody(): Void {
		Assert.equals(GLUED, write(cuddledSource(), CFG_FOR_BODY));
		Assert.equals(GLUED, write(cuddledSource(), CFG_FOR_BODY_SAME));
	}

	/** A wide literal the source wrote flat breaks in place behind the glued `{` rather than moving to Allman. */
	@:pin('control') @:killer('M-ALLMAN-GLUE-IGNORED')
	public function testForBodyFitLineGluesALiteralBrokenByWidth(): Void {
		final expected: String = wrap('var x = [\n\t\t\tfor (i in xs) {\n\t\t\t\t$NAME_A: i,\n\t\t\t\t$NAME_B: i\n\t\t\t}\n\t\t];');
		Assert.equals(expected, write(WIDE_FLAT, CFG_FOR_BODY));
		Assert.equals(expected, write(expected, CFG_FOR_BODY));
	}

	/** A `keep` or `next` comprehension places its body itself, whatever `forBody` says. */
	@:pin('control') @:killer('M-OBJLIT-GLUE-EVERY-VALUE')
	public function testAnExplicitComprehensionPlacementOutranksForBody(): Void {
		Assert.equals(ALLMAN, write(cuddledSource(), CFG_FOR_BODY_KEEP));
		Assert.equals(ALLMAN, write(cuddledSource(), CFG_FOR_BODY_NEXT));
	}

	/** Without a `fitLine` knob the literal stays in Allman position and keeps the lines the source gave it. */
	@:pin('control') @:killer('M-REFLOW-ANY-POLICY')
	public function testDefaultConfigKeepsAllman(): Void {
		Assert.equals(ALLMAN, write(cuddledSource(), CFG_DEFAULT));
	}

	/** The glue is about the literal: another body under the same knob keeps the placement its policy gave it. */
	@:pin('control') @:killer('M-ALLMAN-GLUE-ANY-CTOR')
	public function testGlueLeavesAnotherBodyAlone(): Void {
		final source: String = wrap('var x = [\n\t\t\tfor (i in xs)\n\t\t\t\tf(i)\n\t\t];');
		Assert.equals(source, write(source, CFG_FOR_BODY));
	}

	/** Under `comprehensionFor: fitLine` a source-multi-line literal that fits collapses, and its source lines count for nothing. */
	@:pin('control') @:killer('M-REFLOW-OFF')
	public function testComprehensionFitLineCollapsesALiteralThatFits(): Void {
		final expected: String = wrap('var x = [ for (i in xs) {a: i, b: i} ];');
		Assert.equals(expected, write(cuddledSource(), CFG_COMPREHENSION));
		Assert.equals(expected, write(allmanSource(), CFG_COMPREHENSION));
		Assert.equals(expected, write(expected, CFG_COMPREHENSION));
	}

	/** A literal too wide to collapse takes the same shape whichever way the source wrote it. */
	public function testComprehensionFitLineWideLiteralIgnoresItsSourceLines(): Void {
		final expected: String = wrap(
			'var x = [\n\t\t\tfor (i in xs)\n\t\t\t\t{\n\t\t\t\t\t$NAME_A: i,\n\t\t\t\t\t$NAME_B: i\n\t\t\t\t}\n\t\t];'
		);
		Assert.equals(expected, write(WIDE_FLAT, CFG_COMPREHENSION));
		Assert.equals(expected, write(expected, CFG_COMPREHENSION));
	}

	/** Both knobs: a literal that fits collapses, a wide one glues. */
	public function testBothKnobs(): Void {
		Assert.equals(wrap('var x = [ for (i in xs) {a: i, b: i} ];'), write(allmanSource(), CFG_BOTH));
		final wide: String = wrap('var x = [\n\t\t\tfor (i in xs) {\n\t\t\t\t$NAME_A: i,\n\t\t\t\t$NAME_B: i\n\t\t\t}\n\t\t];');
		assertLandsOn(wide, WIDE_FLAT, CFG_BOTH);
	}

	/** A line comment inside the literal forces its lines, so it cannot collapse. */
	public function testACommentInTheLiteralKeepsItsLines(): Void {
		final source: String = wrap('var x = [for (i in xs) {\n\t\t\ta: i, // note\n\t\t\tb: i\n\t\t}];');
		final expected: String = wrap(
			'var x = [\n\t\t\tfor (i in xs)\n\t\t\t\t{\n\t\t\t\t\ta: i, // note\n\t\t\t\t\tb: i\n\t\t\t\t}\n\t\t];'
		);
		Assert.equals(expected, write(source, CFG_COMPREHENSION));
	}

	/** A literal the body only reaches through a call is the call's argument: its own source lines stand. */
	public function testALiteralInsideACallBodyKeepsItsLines(): Void {
		final source: String = wrap('var x = [for (i in xs) f({\n\t\t\ta: i,\n\t\t\tb: i\n\t\t})];');
		final expected: String = wrap('var x = [\n\t\t\tfor (i in xs)\n\t\t\t\tf({\n\t\t\t\t\ta: i,\n\t\t\t\t\tb: i\n\t\t\t\t})\n\t\t];');
		assertLandsOn(expected, source, CFG_COMPREHENSION);
	}

	/** The glue yields to a comment between the head and the `{`: it goes to the next line with the comment kept, in all three forms. */
	@:pin('control') @:killer('M-ALLMAN-GLUE-NO-COMMENT-WRAP')
	public function testGlueKeepsAHeadGapComment(): Void {
		assertHeadGapCommentsKept(CFG_FOR_BODY);
		assertHeadGapCommentsKept(CFG_BOTH);
	}

	/** The reflow keeps those comments as well. */
	public function testReflowKeepsAHeadGapComment(): Void {
		assertHeadGapCommentsKept(CFG_COMPREHENSION);
	}

	/** A comment inside a glued literal forces its lines under `forBody: fitLine`. */
	public function testGlueKeepsACommentInsideTheLiteral(): Void {
		final source: String = wrap('var x = [for (i in xs) {\n\t\t\t// lead\n\t\t\ta: i\n\t\t}];');
		assertLandsOn(wrap('var x = [\n\t\t\tfor (i in xs) {\n\t\t\t\t// lead\n\t\t\t\ta: i\n\t\t\t}\n\t\t];'), source, CFG_FOR_BODY);
	}

	/** Under both knobs that literal cannot collapse, so the padded brackets hug it. */
	public function testBothKnobsKeepACommentInsideTheLiteral(): Void {
		final source: String = wrap('var x = [for (i in xs) {\n\t\t\t// lead\n\t\t\ta: i\n\t\t}];');
		assertLandsOn(wrap('var x = [ for (i in xs) {\n\t\t\t// lead\n\t\t\ta: i\n\t\t} ];'), source, CFG_BOTH);
	}

	/** A comment after the literal stays behind it under the glue. */
	public function testGlueKeepsACommentAfterTheLiteral(): Void {
		final lineComment: String = wrap('var x = [\n\t\t\tfor (i in xs) {a: i} // note\n\t\t];');
		assertLandsOn(lineComment, wrap('var x = [for (i in xs) { a: i } // note\n\t\t];'), CFG_FOR_BODY);
		assertLandsOn(lineComment, wrap('var x = [for (i in xs) { a: i } // note\n\t\t];'), CFG_BOTH);
		final blockComment: String = 'var x = [for (i in xs) {a: i} /* note */];';
		assertLandsOn(wrap(blockComment), wrap(blockComment), CFG_FOR_BODY);
	}

	/** A wide literal takes one shape whichever way the source broke it. */
	public function testGlueWideLiteralIgnoresHowTheSourceBrokeIt(): Void {
		final expected: String = wrap('var x = [\n\t\t\tfor (i in xs) {\n\t\t\t\t$NAME_A: i,\n\t\t\t\t$NAME_B: i\n\t\t\t}\n\t\t];');
		final hugged: String = wrap('var x = [ for (i in xs) {\n\t\t\t$NAME_A: i,\n\t\t\t$NAME_B: i\n\t\t} ];');
		for (config in [CFG_FOR_BODY, CFG_BOTH]) {
			assertLandsOn(expected, hugged, config);
			assertLandsOn(expected, WIDE_FLAT, config);
		}
	}

	private static function write(source: String, config: String): String {
		return HxWriteFixture.triviaWrite(source, config);
	}

	private static function cuddledSource(): String {
		return wrap('var x = [for (i in xs) {\n\t\t\ta: i,\n\t\t\tb: i\n\t\t}];');
	}

	private static function allmanSource(): String {
		return wrap('var x = [for (i in xs)\n\t\t{\n\t\t\ta: i,\n\t\t\tb: i\n\t\t}];');
	}

	private static function wrap(statement: String): String {
		return 'class M {\n\tfunction f() {\n\t\t$statement\n\t}\n}';
	}

	private static function cfg(sameLine: String): String {
		return '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 120}, "sameLine": {$sameLine}}';
	}

	/** Asserts that the three forms of a comment between the head and the `{` survive `config` and stay put on a second pass. */
	private static function assertHeadGapCommentsKept(config: String): Void {
		assertLandsOn(
			wrap('var x = [\n\t\t\tfor (i in xs) // note\n\t\t\t\t{a: i}\n\t\t];'), wrap('var x = [for (i in xs) // note\n\t\t\t{a: i}];'),
			config
		);
		assertLandsOn(
			wrap('var x = [\n\t\t\tfor (i in xs)\n\t\t\t\t// note\n\t\t\t\t{a: i}\n\t\t];'),
			wrap('var x = [for (i in xs)\n\t\t\t// note\n\t\t\t{a: i}];'), config
		);
		assertLandsOn(
			wrap('var x = [\n\t\t\tfor (i in xs) /* note */\n\t\t\t\t{a: i}\n\t\t];'), wrap('var x = [for (i in xs) /* note */ {a: i}];'),
			config
		);
	}

	/** Asserts that `source` writes as `expected` under `config`, and that `expected` is a fixed point. */
	private static function assertLandsOn(expected: String, source: String, config: String): Void {
		Assert.equals(expected, write(source, config));
		Assert.equals(expected, write(expected, config));
	}

}
