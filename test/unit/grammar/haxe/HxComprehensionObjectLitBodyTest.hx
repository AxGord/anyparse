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

	/** `comprehensionFor: next` places the body itself too. */
	private static final CFG_FOR_BODY_NEXT: String = cfg('"forBody": "fitLine", "comprehensionFor": "next"');

	/** `comprehensionFor: fitLine` alone. */
	private static final CFG_COMPREHENSION: String = cfg('"comprehensionFor": "fitLine"');

	/** Both knobs on `fitLine`. */
	private static final CFG_BOTH: String = cfg('"forBody": "fitLine", "comprehensionFor": "fitLine"');

	/** No `sameLine` key at all. */
	private static final CFG_DEFAULT: String = cfg('');

	/** `comprehensionFor: same` alone: a placement with no `fitLine` knob anywhere. */
	private static final CFG_SAME: String = cfg('"comprehensionFor": "same"');

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
		Assert.equals(GLUED, write(cuddledSource(), CFG_FOR_BODY_SAME));
		Assert.equals(GLUED, write(allmanSource(), CFG_FOR_BODY_SAME));
		Assert.equals(GLUED, write(GLUED, CFG_FOR_BODY_SAME));
	}

	/** An absent key defers to `forBody` exactly as the spelled-out `same` does: a literal broken by width glues under both. */
	@:pin('control') @:killer('M-OBJLIT-GLUE-ABSENT-KEY')
	public function testAbsentComprehensionForDefersToForBody(): Void {
		final expected: String = wrap('var x = [\n\t\t\tfor (i in xs) {\n\t\t\t\t$NAME_A: i,\n\t\t\t\t$NAME_B: i\n\t\t\t}\n\t\t];');
		Assert.equals(expected, write(WIDE_FLAT, CFG_FOR_BODY));
		Assert.equals(expected, write(WIDE_FLAT, CFG_FOR_BODY_SAME));
	}

	/** A wide literal the source wrote flat breaks in place behind the glued `{` rather than moving to Allman. */
	@:pin('control') @:killer('M-ALLMAN-GLUE-IGNORED')
	public function testForBodyFitLineGluesALiteralBrokenByWidth(): Void {
		final expected: String = wrap('var x = [\n\t\t\tfor (i in xs) {\n\t\t\t\t$NAME_A: i,\n\t\t\t\t$NAME_B: i\n\t\t\t}\n\t\t];');
		Assert.equals(expected, write(WIDE_FLAT, CFG_FOR_BODY));
		Assert.equals(expected, write(expected, CFG_FOR_BODY));
	}

	/** A `next` comprehension places its body itself, whatever `forBody` says. */
	@:pin('control') @:killer('M-OBJLIT-GLUE-EVERY-VALUE')
	public function testAnExplicitComprehensionPlacementOutranksForBody(): Void {
		Assert.equals(ALLMAN, write(cuddledSource(), CFG_FOR_BODY_NEXT));
	}

	/** Without a `fitLine` placement the literal stays in Allman position and keeps the lines the source gave it. */
	@:pin('control') @:killer('M-REFLOW-ANY-POLICY')
	public function testSameKeepsAllman(): Void {
		Assert.equals(ALLMAN, write(cuddledSource(), CFG_SAME));
	}

	/** With no `sameLine` key the comprehension body takes `fitLine`, so a literal that fits collapses onto the head line. */
	@:pin('guard')
	public function testDefaultConfigCollapsesALiteralThatFits(): Void {
		Assert.equals(wrap('var x = [for (i in xs) {a: i, b: i}];'), write(cuddledSource(), CFG_DEFAULT));
	}

	/**
	 * The glue is about the literal: another body under the same knob keeps the placement its policy gave it, so one too
	 * wide for the head line stays below it.
	 */
	@:pin('control') @:killer('M-ALLMAN-GLUE-ANY-CTOR')
	public function testGlueLeavesAnotherBodyAlone(): Void {
		final source: String = wrap('var x = [\n\t\t\tfor (i in xs)\n\t\t\t\t$NAME_A${NAME_B.substr(0, 36)}\n\t\t];');
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
	@:pin('control') @:killer('M-PAREN-FRAME-ANY-BODY')
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

	/** A parenthesised literal body takes the frame a bare one takes: its source lines count for nothing. */
	@:pin('control') @:killer('M-PAREN-FRAME-OFF')
	public function testParenthesisedLiteralCollapses(): Void {
		final expected: String = wrap('var x = [ for (i in xs) ({a: i, b: i}) ];');
		assertLandsOn(expected, multiLine('({', '})'), CFG_COMPREHENSION);
	}

	/** A parenthesised literal too wide to collapse takes one shape whichever way the source wrote it. */
	public function testParenthesisedWideLiteralIgnoresItsSourceLines(): Void {
		final expected: String = wrap(
			'var x = [\n\t\t\tfor (i in xs)\n\t\t\t\t({\n\t\t\t\t\t$NAME_A: i,\n\t\t\t\t\t$NAME_B: i\n\t\t\t\t})\n\t\t];'
		);
		assertLandsOn(expected, wrap('var x = [for (i in xs) ({$NAME_A: i, $NAME_B: i})];'), CFG_COMPREHENSION);
	}

	/** The frame crosses a nested paren too, so a redundant pair changes nothing. */
	@:pin('control') @:killer('M-PAREN-FRAME-STOPS-AT-NESTED')
	public function testDoubleParenthesisedLiteralCollapses(): Void {
		final expected: String = wrap('var x = [ for (i in xs) (({a: i, b: i})) ];');
		assertLandsOn(expected, multiLine('(({', '}))'), CFG_COMPREHENSION);
	}

	/**
	 * A paren around anything but a literal consumes the frame: a literal deeper in that expression is not the body.
	 */
	public function testALiteralInAParenthesisedCallKeepsItsLines(): Void {
		final source: String = wrap(
			'var x = [\n\t\t\tfor (i in xs)\n\t\t\t\t(foo(({\n\t\t\t\t\ta: i,\n\t\t\t\t\tb: i\n\t\t\t\t})))\n\t\t];'
		);
		Assert.equals(source, write(source, CFG_COMPREHENSION));
	}

	/** The literal must be the paren's whole content: as a receiver in it, the literal is not the body. */
	@:pin('control') @:killer('M-PAREN-FRAME-ANY-INNER')
	public function testAReceiverLiteralInAParenKeepsItsLines(): Void {
		final source: String = wrap('var x = [\n\t\t\tfor (i in xs)\n\t\t\t\t({\n\t\t\t\t\ta: i,\n\t\t\t\t\tb: i\n\t\t\t\t}.a)\n\t\t];');
		Assert.equals(source, write(source, CFG_COMPREHENSION));
	}

	/**
	 * Only a literal that IS the body enters the frame: a leftmost operand inherits its parent's opt.
	 */
	@:pin('control') @:killer('M-REFLOW-ANY-CTOR')
	public function testAReceiverLiteralBodyKeepsItsLines(): Void {
		final source: String = wrap('var x = [\n\t\t\tfor (i in xs)\n\t\t\t\t{\n\t\t\t\t\ta: i,\n\t\t\t\t\tb: i\n\t\t\t\t}.a\n\t\t];');
		Assert.equals(source, write(source, CFG_COMPREHENSION));
	}

	/**
	 * The frame crosses a paren only from the comprehension body: a parenthesised value-if branch inside it keeps its lines.
	 */
	@:pin('control') @:killer('M-PAREN-FRAME-ANY-STATE')
	public function testAParenthesisedValueIfBranchKeepsItsLines(): Void {
		final source: String = wrap('var x = [\n\t\t\tfor (i in xs) if (c) ({\n\t\t\t\ta: i,\n\t\t\t\tb: i\n\t\t\t}) else 2\n\t\t];');
		Assert.equals(source, write(source, CFG_COMPREHENSION));
	}

	/** Without a `fitLine` placement a parenthesised literal keeps the lines the source gave it. */
	@:pin('control') @:killer('M-PAREN-FRAME-ANY-POLICY')
	public function testSameKeepsAParenthesisedLiteralsLines(): Void {
		final source: String = wrap('var x = [\n\t\t\tfor (i in xs) ({\n\t\t\t\ta: i,\n\t\t\t\tb: i\n\t\t\t})\n\t\t];');
		Assert.equals(source, write(source, CFG_SAME));
	}

	/** A comment inside a parenthesised literal keeps its lines, as in a bare one. */
	public function testACommentInAParenthesisedLiteralKeepsItsLines(): Void {
		final source: String = wrap(
			'var x = [\n\t\t\tfor (i in xs)\n\t\t\t\t({\n\t\t\t\t\t// note\n\t\t\t\t\ta: i,\n\t\t\t\t\tb: i\n\t\t\t\t})\n\t\t];'
		);
		Assert.equals(source, write(source, CFG_COMPREHENSION));
	}

	/** The frame crosses only a paren directly around the next one: a paren below a receiver is not the body. */
	@:pin('control') @:killer('M-PAREN-FRAME-ANY-WRAPPED')
	public function testAParenthesisedReceiverInAParenKeepsItsLines(): Void {
		final source: String = wrap('var x = [\n\t\t\tfor (i in xs)\n\t\t\t\t(({\n\t\t\t\t\ta: i,\n\t\t\t\t\tb: i\n\t\t\t\t}).a)\n\t\t];');
		Assert.equals(source, write(source, CFG_COMPREHENSION));
	}

	/** A source newline inside the paren counts for nothing: the literal's width alone decides its lines. */
	public function testASourceNewlineInsideTheParenCountsForNothing(): Void {
		assertLandsOn(wrap('var x = [ for (i in xs) ({a: i, b: i}) ];'), multiLine('(\n\t\t\t{', '}\n\t\t)'), CFG_COMPREHENSION);
		final wide: String = wrap(
			'var x = [\n\t\t\tfor (i in xs)\n\t\t\t\t({\n\t\t\t\t\t$NAME_A: i,\n\t\t\t\t\t$NAME_B: i\n\t\t\t\t})\n\t\t];'
		);
		assertLandsOn(wide, wrap('var x = [for (i in xs) (\n\t\t\t{$NAME_A: i, $NAME_B: i}\n\t\t)];'), CFG_COMPREHENSION);
		assertLandsOn(
			wide, wrap('var x = [for (i in xs) (\n\t\t\t{\n\t\t\t\t$NAME_A: i,\n\t\t\t\t$NAME_B: i\n\t\t\t}\n\t\t)];'), CFG_COMPREHENSION
		);
	}

	/** A comment beside the literal inside the paren survives, the literal still collapses, and the result is a fixed point. */
	public function testACommentBesideAParenthesisedLiteralSurvivesTheCollapse(): Void {
		assertLandsOn(wrap('var x = [ for (i in xs) (/* o */ {a: i, b: i}) ];'), multiLine('(/* o */ {', '})'), CFG_COMPREHENSION);
		assertLandsOn(wrap('var x = [ for (i in xs) ({a: i, b: i} /* c */) ];'), multiLine('({', '} /* c */)'), CFG_COMPREHENSION);
		assertLandsOn(
			wrap('var x = [\n\t\t\tfor (i in xs)\n\t\t\t\t( // note\n\t\t\t\t\t{a: i, b: i}\n\t\t\t\t)\n\t\t];'),
			multiLine('( // note\n\t\t\t{', '})'), CFG_COMPREHENSION
		);
		assertLandsOn(
			wrap('var x = [\n\t\t\tfor (i in xs)\n\t\t\t\t({a: i, b: i} // note\n\t\t\t\t)\n\t\t];'), multiLine('({', '} // note\n\t\t)'),
			CFG_COMPREHENSION
		);
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

	private static function multiLine(open: String, close: String): String {
		return wrap('var x = [for (i in xs) $open\n\t\t\ta: i,\n\t\t\tb: i\n\t\t$close];');
	}

}
