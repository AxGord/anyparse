package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * omega-elseif-comment-reflow: `sameLine.elseIfCommentReflow: true` glues an
 * `else if` whose nested `if` carries ONE interposed line comment, and re-emits
 * that comment as a trailing comment on the nested `if`'s head line.
 *
 * The pre-knob layout is what the old haxe-formatter produced and what the
 * writer still treats as canonical:
 *
 * ```
 * } else
 *     // note
 * if (b) {
 * ```
 *
 * The `else` sits alone, the comment sits one indent deeper, and the nested
 * `if` drops back to the outer indent - three lines where the construct is one.
 * With the knob the link glues (`} else if (b) {`) and the comment trails the
 * head: after the `{` when the then-body is braced, after the `)` when the body
 * policy already puts a bare body on the next line.
 *
 * The refusals fail CLOSED - a block comment, more than one comment, or a
 * non-`if` else branch keeps the pre-knob layout byte for byte, so a shape the
 * relocation cannot model never loses its comment.
 *
 * Every fixture is pinned in BOTH directions: the knob-off column is the
 * byte-inertness net (the fork corpus and the default config must not move),
 * and the knob-on column is the contract. The target forms are separately
 * pinned as idempotent - they are already writer-canonical, so the reflow
 * output has to be a fixed point rather than a shape that keeps drifting.
 */
@:nullSafety(Strict)
final class HxElseIfCommentReflowSliceTest extends Test {

	/**
	 * The reporting project's shape: tabs, 140 columns, `singleStatementBraces:
	 * remove` (so the bare-body variant is reachable) and `ifBody: fitLine`.
	 */
	private static final CONFIG_ON: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}, '
		+ '"whitespace": {"addLineCommentSpace": false, "bracesConfig": {"singleStatementBraces": "remove"}}, '
		+ '"sameLine": {"ifBody": "fitLine", "elseIfCommentReflow": true}}';

	private static final CONFIG_OFF: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}, '
		+ '"whitespace": {"addLineCommentSpace": false, "bracesConfig": {"singleStatementBraces": "remove"}}, '
		+ '"sameLine": {"ifBody": "fitLine"}}';
	private static final BRACED_SRC: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n\t\t} else\n'
		+ '\t\t\t// dispose the bitmap when the object is a bitmap\n\t\tif (b) {\n\t\t\ttwo();\n\t\t\ttwoMore();\n\t\t}\n\t}\n}';
	private static final BRACED_REFLOWED: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n'
		+ '\t\t} else if (b) { // dispose the bitmap when the object is a bitmap\n\t\t\ttwo();\n\t\t\ttwoMore();\n\t\t}\n\t}\n}';
	private static final BARE_SRC: String = 'class C {\n\tfunction g() {\n\t\tif (a)\n\t\t\tone();\n\t\telse\n'
		+ '\t\t\t// pick the second branch\n\t\tif (b)\n\t\t\ttwo();\n\t}\n}';
	private static final BARE_REFLOWED: String =
		'class C {\n\tfunction g() {\n\t\tif (a)\n\t\t\tone();\n\t\telse if (b) // pick the second branch\n\t\t\ttwo();\n\t}\n}';
	private static final CHAIN_SRC: String = 'class C {\n\tfunction h() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n\t\t} else\n'
		+ '\t\t\t// second branch\n\t\tif (b) {\n\t\t\ttwo();\n\t\t\ttwoMore();\n\t\t} else\n'
		+ '\t\t\t// third branch\n\t\tif (c) {\n\t\t\tthree();\n\t\t\tthreeMore();\n\t\t}\n\t}\n}';
	private static final CHAIN_REFLOWED: String = 'class C {\n\tfunction h() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n'
		+ '\t\t} else if (b) { // second branch\n\t\t\ttwo();\n\t\t\ttwoMore();\n'
		+ '\t\t} else if (c) { // third branch\n\t\t\tthree();\n\t\t\tthreeMore();\n\t\t}\n\t}\n}';
	private static final BLOCK_COMMENT_SRC: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n'
		+ '\t\t} else\n' + '\t\t\t/* dispose the bitmap */\n\t\tif (b) {\n\t\t\ttwo();\n\t\t\ttwoMore();\n\t\t}\n\t}\n}';
	private static final TWO_COMMENTS_SRC: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n'
		+ '\t\t} else\n' + '\t\t\t// first note\n\t\t\t// second note\n\t\tif (b) {\n\t\t\ttwo();\n\t\t\ttwoMore();\n\t\t}\n\t}\n}';
	private static final NON_IF_ELSE_SRC: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n\t\t} else\n'
		+ '\t\t\t// plain else block\n\t\t{\n\t\t\ttwo();\n\t\t\ttwoMore();\n\t\t}\n\t}\n}';

	/** Source braces that `singleStatementBraces: remove` drops in the same pass as the reflow. */
	private static final SSB_SRC: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tone();\n\t\t} else\n'
		+ '\t\t\t// single statement branch\n\t\tif (b) {\n\t\t\ttwo();\n\t\t}\n\t}\n}';

	private static final SSB_KEPT: String = 'class C {\n\tfunction f() {\n\t\tif (a)\n\t\t\tone();\n\t\telse\n'
		+ '\t\t\t// single statement branch\n\t\tif (b)\n\t\t\ttwo();\n\t}\n}';
	private static final SSB_REFLOWED: String =
		'class C {\n\tfunction f() {\n\t\tif (a)\n\t\t\tone();\n\t\telse if (b) // single statement branch\n\t\t\ttwo();\n\t}\n}';

	/**
	 * A `conditionWrapping` policy that opens the paren on overflow - the one
	 * config shape where the relocated comment is visible to a width decision.
	 */
	private static final CONFIG_COND_WRAP: String = '{"indentation": {"character": "tab", "tabWidth": 4}, '
		+ '"wrapping": {"maxLineLength": 140, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", '
		+ '"rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}, '
		+ '"whitespace": {"addLineCommentSpace": false, "bracesConfig": {"singleStatementBraces": "remove"}}, '
		+ '"sameLine": {"ifBody": "fitLine", "elseIfCommentReflow": true}}';

	private static final WIDE_SRC: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n\t\t} else\n'
		+ '\t\t\t// a fairly long trailing note that pushes the glued head line past the configured limit\n\t\tif ('
		+ 'subject is Bitmap && subject.parent != null && somethingElseEntirely.isReady) {\n\t\t\ttwo();\n\t\t\ttwoMore();\n\t\t}\n\t}\n}';
	private static final WIDE_GLUED: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n'
		+ '\t\t} else if (subject is Bitmap && subject.parent != null && somethingElseEntirely.isReady) { // a fairly long trailing note '
		+ 'that pushes the glued head line past the configured limit\n\t\t\ttwo();\n\t\t\ttwoMore();\n\t\t}\n\t}\n}';
	private static final WIDE_COND_OPENED: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n'
		+ '\t\t} else if (\n' + '\t\t\tsubject is Bitmap && subject.parent != null && somethingElseEntirely.isReady\n'
		+ '\t\t) { // a fairly long trailing note that pushes the glued head line past the configured limit\n'
		+ '\t\t\ttwo();\n\t\t\ttwoMore();\n\t\t}\n\t}\n}';

	/** A condition wrap policy that breaks EVERY operand, so the head line spans several lines. */
	private static final CONFIG_ONE_PER_LINE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, '
		+ '"wrapping": {"maxLineLength": 60, "conditionWrapping": {"defaultWrap": "onePerLine"}}, '
		+ '"whitespace": {"addLineCommentSpace": false, "bracesConfig": {"singleStatementBraces": "remove"}}, '
		+ '"sameLine": {"ifBody": "fitLine", "elseIfCommentReflow": true}}';

	private static final CONFIG_ONE_PER_LINE_OFF: String = '{"indentation": {"character": "tab", "tabWidth": 4}, '
		+ '"wrapping": {"maxLineLength": 60, "conditionWrapping": {"defaultWrap": "onePerLine"}}, '
		+ '"whitespace": {"addLineCommentSpace": false, "bracesConfig": {"singleStatementBraces": "remove"}}, '
		+ '"sameLine": {"ifBody": "fitLine"}}';

	/** `sameLine.elseBody: "keep"` routes the whole else through `buildBodyKeepLayout`. */
	private static final CONFIG_KEEP_ELSE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {'
		+ '"maxLineLength": 140}, "whitespace": {"addLineCommentSpace": false, "bracesConfig": {'
		+ '"singleStatementBraces": "remove"}}, "sameLine": {' + '"ifBody": "fitLine", "elseBody": "keep", "elseIfCommentReflow": true}}';

	/** The one config where a bare body reaches the writer as a width PROBE rather than a break. */
	private static final CONFIG_GLUED_BODY: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {'
		+ '"maxLineLength": 60}, "whitespace": {"addLineCommentSpace": false}, '
		+ '"sameLine": {"ifBody": "fitLine", "fitLineIfWithElse": true, "elseIfCommentReflow": true}}';

	private static final WRAPPED_COND_SRC: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n'
		+ '\t\t} else\n\t\t\t// see foo(alphaBetaGamma\n' + '\t\tif (alphaBetaGamma && deltaEpsilonZeta && etaThetaIota) {\n\t\t\ttwo();\n'
		+ '\t\t\ttwoMore();\n\t\t}\n\t}\n}';
	private static final WRAPPED_COND_REFLOWED: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n'
		+ '\t\t} else if (alphaBetaGamma\n\t\t\t&& deltaEpsilonZeta\n'
		+ '\t\t\t&& etaThetaIota) { // see foo(alphaBetaGamma\n\t\t\ttwo();\n\t\t\ttwoMore();\n\t\t}\n\t}\n}';

	/** Knob off: the condition wraps and the fork three-line layout stays. */
	private static final WRAPPED_COND_KEPT: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n'
		+ '\t\t} else\n\t\t\t// see foo(alphaBetaGamma\n\t\tif (alphaBetaGamma\n'
		+ '\t\t\t&& deltaEpsilonZeta\n\t\t\t&& etaThetaIota) {\n\t\t\ttwo();\n\t\t\ttwoMore();\n' + '\t\t}\n\t}\n}';

	private static final HEAD_TRAIL_SRC: String = 'class C {\n\tfunction braceTrail() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n'
		+ '\t\t} else\n\t\t\t// outer note\n\t\tif (b) { // inner note\n\t\t\ttwo();\n'
		+ '\t\t\ttwoMore();\n\t\t}\n\t}\n\n\tfunction condTrail() {\n\t\tif (a) {\n\t\t\tone();\n'
		+ '\t\t\toneMore();\n\t\t} else\n\t\t\t// outer note\n\t\tif (b) // inner note\n\t\t{\n'
		+ '\t\t\ttwo();\n\t\t\ttwoMore();\n\t\t}\n\t}\n}';
	private static final OPEN_DELIM_SRC: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n\t\t} else\n'
		+ '\t\t\t// open delims (  [  {\n\t\tif (b) {\n\t\t\ttwo();\n\t\t\ttwoMore();\n\t\t}\n\t}\n}';
	private static final OPEN_DELIM_REFLOWED: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n'
		+ '\t\t} else if (b) { // open delims (  [  {\n\t\t\ttwo();\n\t\t\ttwoMore();\n\t\t}\n\t}\n}';
	private static final KEEP_ELSE_SRC: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n\t\t} else\n'
		+ '\t\t\t// note\n\t\tif (b) {\n\t\t\ttwo();\n\t\t\ttwoMore();\n\t\t}\n\t}\n}';
	private static final KEEP_ELSE_CANON: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n\t\t} else\n'
		+ '\t\t\t// note\n\t\t\tif (b) {\n\t\t\t\ttwo();\n\t\t\t\ttwoMore();\n\t\t\t}\n\t}\n}';
	private static final GLUED_BODY_SRC: String = 'class C {\n\tfunction f() {\n\t\tif (a)\n\t\t\tone();\n\t\telse\n\t\t\t// note\n\t\tif ('
		+ 'b)\n\t\t\tcallWithSeveralArgs(alphaValue, betaValue, gammaValue, deltaValue);\n\t}\n}';
	private static final GLUED_BODY_CANON: String = 'class C {\n\tfunction f() {\n\t\tif (a) one();\n\t\telse\n\t\t\t// note\n\t\tif (b)\n'
		+ '\t\t\tcallWithSeveralArgs(alphaValue, betaValue,\n\t\t\t\tgammaValue, deltaValue);\n\t}\n}';

	/** The probe body followed by an `else`, so a walk that stepped OVER the probe would anchor there. */
	private static final GLUED_BODY_ELSE_SRC: String = 'class C {\n\tfunction f() {\n\t\tif (a)\n\t\t\tone();\n\t\telse\n\t\t\t// note\n'
		+ '\t\tif (b)\n\t\t\tcallWithSeveralArgs(alphaValue, betaValue, gammaValue, deltaValue);\n'
		+ '\t\telse\n\t\t\tfallbackStep();\n\t}\n}';

	private static final GLUED_BODY_ELSE_CANON: String = 'class C {\n\tfunction f() {\n\t\tif (a) one();\n\t\telse\n\t\t\t// note\n'
		+ '\t\tif (b)\n\t\t\tcallWithSeveralArgs(alphaValue, betaValue,\n'
		+ '\t\t\t\tgammaValue, deltaValue);\n\t\telse\n\t\t\tfallbackStep();\n\t}\n}';

	/**
	 * An EMPTY then-body renders as one closed `{}` token with no interior break,
	 * so the head line the walk is measuring has already ended. All three shapes:
	 * a following `else`, a following `else if`, and the empty body alone.
	 */
	private static final EMPTY_THEN_SRC: String = 'class C {\n\tfunction elseAfterEmpty() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n'
		+ '\t\t} else\n\t\t\t// note\n\t\tif (b) {\n\t\t} else {\n\t\t\tthree();\n\t\t}\n\t}\n\n'
		+ '\tfunction chainAfterEmpty() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n'
		+ '\t\t} else\n\t\t\t// note\n\t\tif (b) {\n\t\t} else if (c) {\n\t\t\tthree();\n'
		+ '\t\t\tthreeMore();\n\t\t}\n\t}\n\n\tfunction emptyAlone() {\n\t\tif (a) {\n\t\t\tone();\n'
		+ '\t\t\toneMore();\n\t\t} else\n\t\t\t// note\n\t\tif (b) {\n\t\t}\n\t}\n}';

	/** Only the empty-curly collapse moves; the comment stays where the source put it. */
	private static final EMPTY_THEN_CANON: String = 'class C {\n\tfunction elseAfterEmpty() {\n\t\tif (a) {\n\t\t\tone();\n'
		+ '\t\t\toneMore();\n' + '\t\t} else\n\t\t\t// note\n\t\tif (b) {} else {\n\t\t\tthree();\n\t\t}\n\t}\n\n'
		+ '\tfunction chainAfterEmpty() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n\t\t} else\n'
		+ '\t\t\t// note\n\t\tif (b) {} else if (c) {\n\t\t\tthree();\n\t\t\tthreeMore();\n\t\t}\n\t}\n\n'
		+ '\tfunction emptyAlone() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n\t\t} else\n' + '\t\t\t// note\n\t\tif (b) {}\n\t}\n}';

	/** A bare body that already carries hardlines: the writer wraps it in a glue PROBE. */
	private static final PROBE_BODY_SRC: String = 'class C {\n\tfunction f() {\n\t\tif (a)\n\t\t\tone();\n\t\telse\n\t\t\t// note\n'
		+ '\t\tif (b)\n\t\t\tfor (item in collection) {\n\t\t\t\thandle(item);\n\t\t\t}\n\t\telse\n' + '\t\t\tfallbackStep();\n\t}\n}';

	private static final PROBE_BODY_CANON: String = 'class C {\n\tfunction f() {\n\t\tif (a) one();\n\t\telse\n\t\t\t// note\n'
		+ '\t\tif (b) for (item in collection) {\n\t\t\thandle(item);\n\t\t}\n\t\telse\n\t\t\tfallbackStep();\n' + '\t}\n}';

	/** `ifBody`/`elseBody: same` - the one policy pair that leaves a bare body with no hardline. */
	private static final CONFIG_INLINE_BODY: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}, '
		+ '"whitespace": {"addLineCommentSpace": false}, "sameLine": {"ifBody": "same", "elseBody": "same", "elseIfCommentReflow": true}}';

	private static final NO_ANCHOR_SRC: String =
		'class C {\n\tfunction f() {\n\t\tif (a)\n\t\t\tone();\n\t\telse\n\t\t\t// note\n\t\tif (b)\n\t\t\ttwo();\n\t}\n}';
	private static final NO_ANCHOR_CANON: String =
		'class C {\n\tfunction f() {\n\t\tif (a) one();\n\t\telse\n\t\t\t// note\n\t\tif (b) two();\n\t}\n}';
	private static final INLINE_ELSE_SRC: String = 'class C {\n\tfunction f() {\n\t\tif (a)\n\t\t\tone();\n\t\telse\n\t\t\t// note\n'
		+ '\t\tif (b)\n\t\t\ttwo();\n\t\telse\n\t\t\tthree();\n\t}\n}';
	private static final INLINE_ELSE_CANON: String =
		'class C {\n\tfunction f() {\n\t\tif (a) one();\n\t\telse\n\t\t\t// note\n\t\tif (b) two();\n\t\telse three();\n\t}\n}';
	private static final AFTER_KW_SRC: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n'
		+ '\t\t} else // cuddled to else\n\t\t\t// interposed\n\t\tif (b) {\n\t\t\ttwo();\n' + '\t\t\ttwoMore();\n\t\t}\n\t}\n}';
	private static final DEFAULT_SRC: String = 'class C {\n\tfunction braced() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n'
		+ '\t\t} else\n\t\t\t// dispose the bitmap when the object is a bitmap\n\t\tif (b) {\n'
		+ '\t\t\ttwo();\n\t\t\ttwoMore();\n\t\t}\n\t}\n\n\tfunction bare() {\n\t\tif (a)\n'
		+ '\t\t\tone();\n\t\telse\n\t\t\t// pick the second branch\n\t\tif (b)\n\t\t\ttwo();\n\t}\n}';
	private static final DEFAULT_CANON: String = 'class C {\n\tfunction braced() {\n\t\tif (a) {\n\t\t\tone();\n\t\t\toneMore();\n'
		+ '\t\t} else\n\t\t\t// dispose the bitmap when the object is a bitmap\n\t\t\tif (b) {\n'
		+ '\t\t\t\ttwo();\n\t\t\t\ttwoMore();\n\t\t\t}\n\t}\n\n\tfunction bare() {\n\t\tif (a)\n'
		+ '\t\t\tone();\n\t\telse\n\t\t\t// pick the second branch\n\t\t\tif (b)\n\t\t\t\ttwo();\n' + '\t}\n}\n';

	public function new(): Void {
		super();
	}

	/** The reported shape: a braced then-body takes the comment after its `{`. */
	public function testBracedElseIfGluesAndTrailsCommentAfterOpenCurly(): Void {
		Assert.equals(BRACED_REFLOWED, reflow(BRACED_SRC));
	}

	/** A bare then-body on the next line takes the comment after the condition's `)`. */
	public function testBareBodyElseIfTrailsCommentAfterCondition(): Void {
		Assert.equals(BARE_REFLOWED, reflow(BARE_SRC));
	}

	/** Each link of a chain carries its own comment and reflows independently. */
	public function testChainReflowsEveryLinkIndependently(): Void {
		Assert.equals(CHAIN_REFLOWED, reflow(CHAIN_SRC));
	}

	/**
	 * `singleStatementBraces: remove` and the reflow meet on one site: the braces
	 * go in the same pass that glues the link, so one run reaches the bare form.
	 */
	public function testSingleStatementBraceRemovalAndReflowLandInOnePass(): Void {
		Assert.equals(SSB_REFLOWED, reflow(SSB_SRC));
		Assert.equals(SSB_KEPT, keep(SSB_SRC));
	}

	/** A block comment has no single-line trailing form - the layout stays. */
	public function testBlockCommentRefusesReflow(): Void {
		Assert.equals(BLOCK_COMMENT_SRC, reflow(BLOCK_COMMENT_SRC));
		Assert.equals(BLOCK_COMMENT_SRC, keep(BLOCK_COMMENT_SRC));
	}

	/** Two comments cannot both trail one head line - the layout stays. */
	public function testTwoCommentsRefuseReflow(): Void {
		Assert.equals(TWO_COMMENTS_SRC, reflow(TWO_COMMENTS_SRC));
		Assert.equals(TWO_COMMENTS_SRC, keep(TWO_COMMENTS_SRC));
	}

	/**
	 * A comment already cuddled to the `else` itself takes the head-line slot the
	 * reflow would move the interposed one into, so the whole shape is refused
	 * rather than emitting two comments on one line or dropping either.
	 */
	public function testCommentCuddledToElseRefusesReflow(): Void {
		Assert.equals(AFTER_KW_SRC, reflow(AFTER_KW_SRC));
		Assert.equals(AFTER_KW_SRC, keep(AFTER_KW_SRC));
	}

	/**
	 * A body policy that keeps a bare body ON the head line leaves no hardline to
	 * anchor against, so the splice refuses and the comment stays where it was.
	 * The braced fixtures above never exercise this arm - their block body always
	 * breaks after `{`.
	 */
	public function testInlineBodyPolicyLeavesNoAnchorAndRefuses(): Void {
		Assert.equals(NO_ANCHOR_CANON, write(NO_ANCHOR_SRC, CONFIG_INLINE_BODY));
		Assert.equals(NO_ANCHOR_CANON, write(NO_ANCHOR_CANON, CONFIG_INLINE_BODY));
		// With an `else` of its own the nested `if` DOES emit a hardline, but only
		// past its rendered then-body - the scan stops at that body's `;` instead
		// of hanging the head's comment off the end of a statement.
		Assert.equals(INLINE_ELSE_CANON, write(INLINE_ELSE_SRC, CONFIG_INLINE_BODY));
		Assert.equals(INLINE_ELSE_CANON, write(INLINE_ELSE_CANON, CONFIG_INLINE_BODY));
	}

	/** The knob is scoped to the `else if` glue - a block else branch is untouched. */
	public function testNonIfElseBranchIsUntouched(): Void {
		Assert.equals(NON_IF_ELSE_SRC, reflow(NON_IF_ELSE_SRC));
		Assert.equals(NON_IF_ELSE_SRC, keep(NON_IF_ELSE_SRC));
	}

	/**
	 * No fit gate on the relocated comment: a head line that only overflows
	 * BECAUSE of the comment still glues. The comment is spliced into the body
	 * Doc after every group inside it was built, and the group it lands in
	 * already holds the hardline it is anchored to, so it can never flip that
	 * group's flat-vs-broken answer.
	 */
	public function testOverLongGluedHeadLineIsAccepted(): Void {
		Assert.equals(WIDE_GLUED, reflow(WIDE_SRC));
		Assert.equals(WIDE_GLUED, reflow(WIDE_GLUED));
	}

	/**
	 * The ONE width decision the comment does reach, pinned rather than fought:
	 * a `conditionWrapping` policy that opens the paren on overflow measures the
	 * whole rendered head line, comment included, and opens. Suppressing that
	 * would cost idempotence - the reflow output would then re-wrap on the next
	 * pass - and the result is exactly what the writer emits for the same shape
	 * written by hand, which is the third assert.
	 */
	public function testConditionWrapPolicySeesTheRelocatedComment(): Void {
		Assert.equals(WIDE_COND_OPENED, write(WIDE_SRC, CONFIG_COND_WRAP));
		Assert.equals(WIDE_COND_OPENED, write(WIDE_COND_OPENED, CONFIG_COND_WRAP));
		Assert.equals(WIDE_COND_OPENED, write(WIDE_GLUED, CONFIG_COND_WRAP));
	}

	/**
	 * A condition that breaks every operand: the head spans several lines, and the
	 * anchor is still the block's `{` on the LAST of them. The condition is walked
	 * as ONE opaque unit precisely so its internal breaks - here a conditional
	 * newline right after the open paren - can never be mistaken for the end of
	 * the head. Anchoring on that inner break put the comment after `(`, where the
	 * next pass read the first operand as part of the comment and lost it.
	 */
	public function testWrappedConditionAnchorsAfterTheOpenCurly(): Void {
		Assert.equals(WRAPPED_COND_REFLOWED, write(WRAPPED_COND_SRC, CONFIG_ONE_PER_LINE));
		Assert.equals(WRAPPED_COND_REFLOWED, write(WRAPPED_COND_REFLOWED, CONFIG_ONE_PER_LINE));
		Assert.equals(WRAPPED_COND_KEPT, write(WRAPPED_COND_SRC, CONFIG_ONE_PER_LINE_OFF));
	}

	/**
	 * The body-side twin of the `AfterKw` refusal: a nested `if` whose head ALREADY
	 * carries a trailing `//` has no room for a second one - appending would put
	 * `// inner // note` on one line and the round trip would drop `// note`. Both
	 * head positions that can hold one are pinned: after the block's `{`, and after
	 * the condition's `)` with the `{` on the next line.
	 */
	public function testExistingHeadTrailingCommentRefusesReflow(): Void {
		Assert.equals(HEAD_TRAIL_SRC, reflow(HEAD_TRAIL_SRC));
		Assert.equals(HEAD_TRAIL_SRC, keep(HEAD_TRAIL_SRC));
	}

	/**
	 * A comment whose text ends in an open delimiter is harmless: the anchor is an
	 * UNCONDITIONAL break, so the comment is always the last thing on its line and
	 * nothing can be glued behind it.
	 */
	public function testCommentWithOpenDelimitersIsSafe(): Void {
		Assert.equals(OPEN_DELIM_REFLOWED, reflow(OPEN_DELIM_SRC));
		Assert.equals(OPEN_DELIM_REFLOWED, reflow(OPEN_DELIM_REFLOWED));
	}

	/**
	 * Scope limit, pinned rather than fixed: `sameLine.elseBody: "keep"` routes the
	 * whole else through `buildBodyKeepLayout`, whose own `Same` arm the knob does
	 * not reach. "Keep" means preserve the source shape, which is what the reader
	 * asked for, so the reflow staying out is coherent - it is documented at every
	 * doc site rather than silently absent.
	 */
	public function testKeepElsePolicyDisablesTheReflow(): Void {
		Assert.equals(KEEP_ELSE_CANON, write(KEEP_ELSE_SRC, CONFIG_KEEP_ELSE));
		Assert.equals(KEEP_ELSE_CANON, write(KEEP_ELSE_CANON, CONFIG_KEEP_ELSE));
	}

	/**
	 * A bare body that cannot render flat reaches the writer as a width PROBE, whose
	 * two branches are different shapes - there is no single break that is "the end
	 * of the head", so the walk refuses instead of picking one branch and losing the
	 * comment from the other. The catch-all arm of `scan` is what answers here.
	 */
	public function testProbeShapedBodyRefusesReflow(): Void {
		Assert.equals(GLUED_BODY_CANON, write(GLUED_BODY_SRC, CONFIG_GLUED_BODY));
		Assert.equals(GLUED_BODY_CANON, write(GLUED_BODY_CANON, CONFIG_GLUED_BODY));
		// Same body with an `else` after it: the refusal has to be the probe itself,
		// not "ran out of Doc". Stepping over the probe would anchor the head's
		// comment on the nested `else` instead.
		Assert.equals(GLUED_BODY_ELSE_CANON, write(GLUED_BODY_ELSE_SRC, CONFIG_GLUED_BODY));
		Assert.equals(GLUED_BODY_ELSE_CANON, write(GLUED_BODY_ELSE_CANON, CONFIG_GLUED_BODY));
		// A body that already holds hardlines arrives as the glue probe itself, with an
		// `else` behind it - the arm that answers here is `scan`'s catch-all.
		Assert.equals(PROBE_BODY_CANON, write(PROBE_BODY_SRC, CONFIG_GLUED_BODY));
		Assert.equals(PROBE_BODY_CANON, write(PROBE_BODY_CANON, CONFIG_GLUED_BODY));
	}

	/**
	 * A deep chain of refusals. Each link re-states the `Same` layout, and re-splicing
	 * the body Doc into both arms of that decision instead of binding it once made the
	 * work double per link - 31s at sixteen links, against 0.1s with the knob off.
	 * Asserted on OUTPUT, not on timing: a suite assert on wall clock is a flake, but
	 * the exponential shape cannot produce this answer in reasonable time either way.
	 */
	public function testDeepRefusedChainStaysCorrect(): Void {
		Assert.equals(deepChain(16, true), write(deepChain(16, false), CONFIG_INLINE_BODY));
	}

	/**
	 * An empty then-body closes on the SAME line it opened, so there is no break
	 * inside it to anchor against - and the next break belongs to the nested `if`'s
	 * own `else`. Walking on regardless moved the comment onto that else
	 * (`if (b) {} else { // note`), re-attributing it to the other branch, and two
	 * links away in a chain. It round-tripped and was idempotent, so only the
	 * meaning was wrong: the head line closes at `}`, and a head never closes a
	 * block it did not finish.
	 */
	public function testEmptyThenBodyDoesNotMigrateTheComment(): Void {
		Assert.equals(EMPTY_THEN_CANON, reflow(EMPTY_THEN_SRC));
		Assert.equals(EMPTY_THEN_CANON, keep(EMPTY_THEN_SRC));
		Assert.equals(EMPTY_THEN_CANON, reflow(EMPTY_THEN_CANON));
	}

	/** Byte-inertness with the knob off: every fixture keeps the pre-knob layout. */
	public function testKnobOffKeepsEveryPreKnobLayout(): Void {
		Assert.equals(BRACED_SRC, keep(BRACED_SRC));
		Assert.equals(BARE_SRC, keep(BARE_SRC));
		Assert.equals(CHAIN_SRC, keep(CHAIN_SRC));
		Assert.equals(WIDE_SRC, keep(WIDE_SRC));
	}

	/** Byte-inertness for a config-less run - the default options never reflow. */
	public function testDefaultOptionsAreByteInert(): Void {
		final opts: HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(DEFAULT_CANON, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(DEFAULT_SRC), opts));
	}

	/** Both reflowed forms are already writer-canonical, so a second pass changes nothing. */
	public function testReflowedFormsAreIdempotent(): Void {
		Assert.equals(BRACED_REFLOWED, reflow(BRACED_REFLOWED));
		Assert.equals(BARE_REFLOWED, reflow(BARE_REFLOWED));
		Assert.equals(CHAIN_REFLOWED, reflow(CHAIN_REFLOWED));
		Assert.equals(BRACED_REFLOWED, reflow(reflow(BRACED_SRC)));
		Assert.equals(BARE_REFLOWED, reflow(reflow(BARE_SRC)));
	}

	/** A refused shape stays a fixed point too - the refusal must not oscillate. */
	public function testRefusedFormsAreIdempotent(): Void {
		Assert.equals(BLOCK_COMMENT_SRC, reflow(reflow(BLOCK_COMMENT_SRC)));
		Assert.equals(TWO_COMMENTS_SRC, reflow(reflow(TWO_COMMENTS_SRC)));
	}

	private inline function reflow(src: String): String {
		return write(src, CONFIG_ON);
	}

	private inline function keep(src: String): String {
		return write(src, CONFIG_OFF);
	}

	private function write(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

	/**
	 * `n` chained `else if` links, each with its own interposed comment. `glued`
	 * picks the shape: `false` is the source form with every body on its own
	 * line, `true` the `CONFIG_INLINE_BODY` canonical form with each body on its
	 * condition. Under that config every link's reflow is refused, so the two
	 * forms are the input and the expected output of one run.
	 */
	private static function deepChain(n: Int, glued: Bool): String {
		final lines: Array<String> = ['class C {', '\tfunction f() {'];
		inline function link(i: Int): Void {
			if (glued)
				lines.push('\t\tif (c$i) step$i();');
			else {
				lines.push('\t\tif (c$i)');
				lines.push('\t\t\tstep$i();');
			}
		}
		link(0);
		for (i in 1...n + 1) {
			lines.push('\t\telse');
			lines.push('\t\t\t// note $i');
			link(i);
		}
		lines.push('\t}');
		lines.push('}');
		return lines.join('\n');
	}

}
