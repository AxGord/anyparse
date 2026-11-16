package unit.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * An `if` chain whose ladder is decided by every link: a brace-less branch EARLIER in the chain ladders the `switch` of an inner
 * `else if (…) switch` link that has no `else` of its own, in a statement `if` and in a statement-frame expression `if` alike.
 */
@:nullSafety(Strict)
final class HxIfInnerLinkSwitchLadderTest extends Test {

	/** fitLine bodies with body glue, single-statement braces dropped. */
	private static final CONFIG: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
		edited.lineWidth = 140;
		edited.ifBody = BodyPolicy.FitLine;
		edited.elseBody = BodyPolicy.FitLine;
		edited.caseBody = BodyPolicy.FitLine;
		edited.fitLineBodyGlue = true;
		edited.dropSingleStmtBraces = true;
		edited.singleStmtBraceSymmetry = true;
	});

	/** The same bodies with every brace kept as written, so a braced link stays braced beside a brace-less one. */
	private static final KEEP_BRACES: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
		edited.lineWidth = 140;
		edited.ifBody = BodyPolicy.FitLine;
		edited.elseBody = BodyPolicy.FitLine;
		edited.caseBody = BodyPolicy.FitLine;
		edited.fitLineBodyGlue = true;
	});

	private static final LINK_SOURCE: String =
		'class C {\n\tfunction f() {\n\t\tif (c) foo(); else if (d) switch e(1) {\n\t\t\tcase X: a();\n\t\t\tcase Y: b();\n\t\t}\n\t}\n}';
	private static final LINK_LADDER: String = 'class C {\n\tfunction f() {\n\t\tif (c)\n\t\t\tfoo();\n\t\telse if (d)\n'
		+ '\t\t\tswitch e(1) {\n\t\t\t\tcase X: a();\n\t\t\t\tcase Y: b();\n\t\t\t}\n\t}\n}';
	private static final DEEP_LINK_SOURCE: String = 'class C {\n\tfunction f() {\n\t\tif (c) foo(); else if (d) {\n\t\t\tx();\n\t\t\ty();\n'
		+ '\t\t} else if (g) switch e(1) {\n\t\t\tcase X: a();\n\t\t\tcase Y: b();\n\t\t}\n\t}\n}';
	private static final DEEP_LINK_LADDER: String = 'class C {\n\tfunction f() {\n\t\tif (c)\n\t\t\tfoo();\n\t\telse if (d) {\n\t\t\tx();\n'
		+ '\t\t\ty();\n\t\t} else if (g)\n\t\t\tswitch e(1) {\n\t\t\t\tcase X: a();\n\t\t\t\tcase Y: b();\n\t\t\t}\n\t}\n}';
	private static final NESTED_CHAIN_GLUED: String = 'class C {\n\tfunction f() {\n\t\tif (c)\n\t\t\tfoo();\n\t\telse if (d) {\n\t\t\tx();\n'
		+ '\t\t\tif (g) switch e(1) {\n\t\t\t\tcase X: a();\n\t\t\t\tcase Y: b();\n\t\t\t} else {\n\t\t\t\ty();\n\t\t\t\tz();\n\t\t\t}\n'
		+ '\t\t}\n\t}\n}';
	private static final BRACED_CHAIN_GLUED: String = 'class C {\n\tfunction f() {\n\t\tif (c) {\n\t\t\tfoo();\n\t\t\tbar();\n'
		+ '\t\t} else if (d) switch e(1) {\n\t\t\tcase X: a();\n\t\t\tcase Y: b();\n\t\t}\n\t}\n}';
	private static final EXPR_LINK_SOURCE: String =
		'class C {\n\tfunction f()\n\t\tif (c) foo(); else if (d) switch e(1) {\n\t\t\tcase X: a();\n\t\t\tcase Y: b();\n\t\t}\n}';
	private static final EXPR_LINK_LADDER: String = 'class C {\n\tfunction f()\n\t\tif (c)\n\t\t\tfoo();\n\t\telse if (d)\n'
		+ '\t\t\tswitch e(1) {\n\t\t\t\tcase X: a();\n\t\t\t\tcase Y: b();\n\t\t\t}\n}';
	private static final EXPR_THEN_SOURCE: String =
		'class C {\n\tfunction f()\n\t\tif (c) switch e(1) {\n\t\t\tcase X: a();\n\t\t\tcase Y: b();\n\t\t} else foo();\n}';
	private static final EXPR_THEN_LADDER: String = 'class C {\n\tfunction f()\n\t\tif (c)\n\t\t\tswitch e(1) {\n\t\t\t\tcase X: a();\n'
		+ '\t\t\t\tcase Y: b();\n\t\t\t}\n\t\telse\n\t\t\tfoo();\n}';
	private static final DEBRACED_HEAD_SOURCE: String = 'class C {\n\tfunction f() {\n\t\tif (c) {\n\t\t\tfoo();\n\t\t} else if (d) switch e(1) {\n'
		+ '\t\t\tcase X: a();\n\t\t\tcase Y: b();\n\t\t}\n\t}\n}';
	private static final DEBRACED_DEEP_SOURCE: String = 'class C {\n\tfunction f() {\n\t\tif (c) {\n\t\t\tfoo();\n\t\t} else if (d) {\n'
		+ '\t\t\tbar();\n\t\t} else if (g) switch e(1) {\n\t\t\tcase X: a();\n'
		+ '\t\t\tcase Y: b();\n\t\t}\n\t}\n}';
	private static final DEBRACED_DEEP_LADDER: String = 'class C {\n\tfunction f() {\n\t\tif (c)\n\t\t\tfoo();\n\t\telse if (d)\n\t\t\tbar();\n'
		+ '\t\telse if (g)\n\t\t\tswitch e(1) {\n\t\t\t\tcase X: a();\n\t\t\t\tcase Y: b();\n\t\t\t}\n\t}\n}';
	private static final BRACE_ADDED_SOURCE: String = 'class C {\n\tfunction f() {\n\t\tif (c) foo(); else if (d) {\n\t\t\tw();\n\t\t\tv();\n'
		+ '\t\t} else if (g) switch e(1) {\n\t\t\tcase X: a();\n\t\t\tcase Y: b();\n\t\t}\n\t}\n}';
	private static final BRACE_ADDED_GLUED: String = 'class C {\n\tfunction f() {\n\t\tif (c) {\n\t\t\tfoo();\n\t\t} else if (d) {\n\t\t\tw();\n'
		+ '\t\t\tv();\n\t\t} else if (g) {\n\t\t\tswitch e(1) {\n\t\t\t\tcase X: a();\n\t\t\t\tcase Y: b();\n\t\t\t}\n\t\t}\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** A brace-less then-branch ladders the `switch` of the next `else if` link. */
	@:pin('control')
	@:killer('M-LADDER-LINK-BARE-DROPPED')
	public function testInnerLinkSwitchLadders(): Void {
		Assert.equals(LINK_LADDER, triviaWrite(LINK_SOURCE));
		Assert.equals(LINK_LADDER, triviaWrite(LINK_LADDER));
	}

	/** A function-body expression `if` link sees the brace-less branch above it as the statement `if` link does. */
	@:pin('control')
	@:killer('M-LADDER-LINK-BARE-DROPPED')
	public function testExprIfInnerLinkSwitchLadders(): Void {
		Assert.equals(EXPR_LINK_LADDER, triviaWrite(EXPR_LINK_SOURCE));
		Assert.equals(EXPR_LINK_LADDER, triviaWrite(EXPR_LINK_LADDER));
	}

	/** The brace-less branch two links up reaches the last link's `switch` across a braced link between them. */
	@:pin('control')
	@:killer('M-LADDER-LINK-BARE-NOT-INHERITED')
	public function testDeepLinkInheritsChainBare(): Void {
		Assert.equals(DEEP_LINK_LADDER, keepBracesWrite(DEEP_LINK_SOURCE));
	}

	/** An all-braced `if` nested in a link's block is a chain of its own: the verdict of the link's chain stops at the block. */
	@:pin('control')
	@:killer('M-LADDER-CHAIN-BARE-LEAKS')
	public function testNestedChainInLinkBlockStaysGlued(): Void {
		Assert.equals(NESTED_CHAIN_GLUED, keepBracesWrite(NESTED_CHAIN_GLUED));
	}

	/** Every branch braced: the inner link's `switch` stays glued. */
	@:pin('control')
	@:killer('M-SWITCH-BRANCH-LADDER-ALWAYS')
	public function testBracedChainLinkSwitchStaysGlued(): Void {
		Assert.equals(BRACED_CHAIN_GLUED, keepBracesWrite(BRACED_CHAIN_GLUED));
	}

	/** A function-body expression `if` ladders its then-branch `switch` beside a brace-less `else`, as a statement `if` does. */
	@:pin('control')
	@:killer('M-EXPR-IF-SWITCH-LADDER-OFF')
	public function testExprIfThenSwitchLadders(): Void {
		Assert.equals(EXPR_THEN_LADDER, triviaWrite(EXPR_THEN_SOURCE));
		Assert.equals(EXPR_THEN_LADDER, triviaWrite(EXPR_THEN_LADDER));
	}

	/**
	 * A `{ single; }` head the writer de-braces is brace-less for the
	 * chain: the links below it ladder their `switch`, on the first pass.
	 */
	@:pin('control')
	@:killer('M-LADDER-LINK-WRITTEN-BLIND')
	public function testDeBracedHeadLaddersLinkSwitch(): Void {
		Assert.equals(LINK_LADDER, triviaWrite(DEBRACED_HEAD_SOURCE));
		Assert.equals(DEBRACED_DEEP_LADDER, triviaWrite(DEBRACED_DEEP_SOURCE));
	}

	/**
	 * Symmetry braces a brace-less head beside a multi-statement link: the chain as written is all braced, so the last link's
	 * `switch` keeps its braces and its glue.
	 */
	@:pin('guard')
	public function testBraceAddedHeadKeepsLinkGlued(): Void {
		Assert.equals(BRACE_ADDED_GLUED, triviaWrite(BRACE_ADDED_SOURCE));
	}

	private static function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

	private static function keepBracesWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, KEEP_BRACES);
	}

}
