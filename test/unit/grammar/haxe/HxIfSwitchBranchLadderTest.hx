package unit.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * A statement `if` with an `else` whose then-branch is a brace-led `switch` and whose chain holds a branch with no braces of
 * its own is a ladder: the `switch` goes on its own line under the head like any other body. Only a chain whose every
 * branch is brace-delimited keeps it glued; an `else switch` stays on the `else` line as an `else if` does.
 */
@:nullSafety(Strict)
final class HxIfSwitchBranchLadderTest extends Test {

	/** fitLine bodies with body glue, `sameLine.elseSwitch` at its default. */
	private static final CONFIG: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
		edited.lineWidth = 140;
		edited.ifBody = BodyPolicy.FitLine;
		edited.elseBody = BodyPolicy.FitLine;
		edited.caseBody = BodyPolicy.FitLine;
		edited.fitLineBodyGlue = true;
		edited.dropSingleStmtBraces = true;
		edited.singleStmtBraceSymmetry = true;
	});

	private static final THEN_SWITCH_SOURCE: String =
		'class C {\n\tfunction f() {\n\t\tif (c) switch e(1) {\n\t\t\tcase X: a();\n\t\t\tcase Y: b();\n\t\t} else\n\t\t\tfoo();\n\t}\n}';
	private static final THEN_SWITCH_LADDER: String = 'class C {\n\tfunction f() {\n\t\tif (c)\n\t\t\tswitch e(1) {\n\t\t\t\tcase X: a();\n'
		+ '\t\t\t\tcase Y: b();\n\t\t\t}\n\t\telse\n\t\t\tfoo();\n\t}\n}';
	private static final ELSE_SWITCH_SOURCE: String = 'class C {\n\tfunction f() {\n\t\tif (c)\n\t\t\tfoo();\n\t\telse switch e(1) {\n'
		+ '\t\t\tcase X: a();\n\t\t\tcase Y: b();\n\t\t}\n\t}\n}';
	private static final ELSE_IF_SOURCE: String = 'class C {\n\tfunction f() {\n\t\tif (c) switch e(1) {\n\t\t\tcase X: a();\n'
		+ '\t\t\tcase Y: b();\n\t\t} else if (d)\n\t\t\tfoo();\n\t}\n}';
	private static final ELSE_IF_LADDER: String = 'class C {\n\tfunction f() {\n\t\tif (c)\n\t\t\tswitch e(1) {\n\t\t\t\tcase X: a();\n'
		+ '\t\t\t\tcase Y: b();\n\t\t\t}\n\t\telse if (d)\n\t\t\tfoo();\n\t}\n}';
	private static final ELSE_BLOCK_SOURCE: String = 'class C {\n\tfunction f() {\n\t\tif (c) switch e(1) {\n\t\t\tcase X: a();\n'
		+ '\t\t\tcase Y: b();\n\t\t} else {\n\t\t\tfoo();\n\t\t}\n\t}\n}';
	private static final BOTH_SWITCH_GLUED: String = 'class C {\n\tfunction f() {\n\t\tif (c) switch e(1) {\n\t\t\tcase X: a();\n'
		+ '\t\t\tcase Y: b();\n\t\t} else switch g(1) {\n\t\t\tcase X: a();\n\t\t\tcase Y: b();\n'
		+ '\t\t}\n\t}\n}';
	private static final ELSE_SWITCH_BLOCK_SOURCE: String = 'class C {\n\tfunction f() {\n\t\tif (c) switch e(1) {\n\t\t\tcase X: a();\n'
		+ '\t\t\tcase Y: b();\n\t\t} else {\n\t\t\tswitch g(1) {\n\t\t\t\tcase X: a();\n\t\t\t\tcase Y: b();\n\t\t\t}\n\t\t}\n\t}\n}';
	private static final ELSE_IF_BLOCK_SOURCE: String = 'class C {\n\tfunction f() {\n\t\tif (c) switch e(1) {\n\t\t\tcase X: a();\n'
		+ '\t\t\tcase Y: b();\n\t\t} else {\n\t\t\tif (d) foo(); else bar();\n\t\t}\n\t}\n}';
	private static final ELSE_IF_BLOCK_LADDER: String = 'class C {\n\tfunction f() {\n\t\tif (c)\n\t\t\tswitch e(1) {\n\t\t\t\tcase X: a();\n'
		+ '\t\t\t\tcase Y: b();\n\t\t\t}\n\t\telse if (d)\n\t\t\tfoo();\n\t\telse\n\t\t\tbar();\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** A then-branch `switch` beside a brace-less `else` ladders the chain, and the `else` leaves its `}`. */
	@:pin('control')
	@:killer('M-SWITCH-BRANCH-LADDER-NONE')
	public function testThenSwitchWithBareElseLadders(): Void {
		Assert.equals(THEN_SWITCH_LADDER, triviaWrite(THEN_SWITCH_SOURCE));
		Assert.equals(THEN_SWITCH_LADDER, triviaWrite(THEN_SWITCH_LADDER));
	}

	/** An `else switch` beside a brace-less then-branch stays on the `else` line, as an `else if` does in a ladder. */
	@:pin('guard')
	public function testElseSwitchGluesLikeElseIf(): Void {
		Assert.equals(ELSE_SWITCH_SOURCE, triviaWrite(ELSE_SWITCH_SOURCE));
	}

	/** A brace-less branch further down an `else if` chain ladders the then-branch `switch` too. */
	@:pin('control')
	@:killer('M-SWITCH-LADDER-CLOSE-GLUED')
	public function testThenSwitchWithBareElseIfLadders(): Void {
		Assert.equals(ELSE_IF_LADDER, triviaWrite(ELSE_IF_SOURCE));
	}

	/** A `{ single; }` else the writer de-braces is a brace-less branch in the same pass. */
	@:pin('control')
	@:killer('M-LADDER-DEBRACE-OFF')
	public function testDeBracedElseBlockLadders(): Void {
		Assert.equals(THEN_SWITCH_LADDER, triviaWrite(ELSE_BLOCK_SOURCE));
	}

	/** An `else { switch … }` the writer de-braces is a brace-led `switch`: the chain stays glued, on the first pass. */
	@:pin('control')
	@:killer('M-LADDER-WRITTEN-CTOR-BLIND')
	public function testDeBracedElseSwitchStaysGlued(): Void {
		final once: String = triviaWrite(ELSE_SWITCH_BLOCK_SOURCE);
		Assert.equals(BOTH_SWITCH_GLUED, once);
		Assert.equals(once, triviaWrite(once));
	}

	/** An `else { if … else … }` the writer de-braces is an `else if` link whose brace-less branches ladder, on the first pass. */
	@:pin('control')
	@:killer('M-LADDER-DEBRACE-OFF')
	public function testDeBracedElseIfLinkLadders(): Void {
		final once: String = triviaWrite(ELSE_IF_BLOCK_SOURCE);
		Assert.equals(ELSE_IF_BLOCK_LADDER, once);
		Assert.equals(once, triviaWrite(once));
	}

	/** Every branch a brace-led `switch`: the chain stays glued. */
	@:pin('control')
	@:killer('M-SWITCH-BRANCH-LADDER-ALWAYS')
	public function testAllSwitchChainStaysGlued(): Void {
		Assert.equals(BOTH_SWITCH_GLUED, triviaWrite(BOTH_SWITCH_GLUED));
	}

	private static function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
