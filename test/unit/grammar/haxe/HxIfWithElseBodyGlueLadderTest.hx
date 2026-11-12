package unit.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * Under `sameLine.fitLineIfWithElse` with `sameLine.fitLineBodyGlue`, an `if` that has an `else` lays its whole chain out as a ladder:
 * each brace-less body on its own line one indent deeper, `else` at the `if`'s indent, whether a body is multi-line or fits.
 * An `if` without an `else` keeps gluing its body to the head.
 */
@:nullSafety(Strict)
final class HxIfWithElseBodyGlueLadderTest extends Test {

	/** fitLine bodies, fitLine with an else, body glue on. */
	private static final CONFIG: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
		edited.lineWidth = 80;
		edited.ifBody = BodyPolicy.FitLine;
		edited.elseBody = BodyPolicy.FitLine;
		edited.fitLineIfWithElse = true;
		edited.fitLineBodyGlue = true;
		edited.dropSingleStmtBraces = true;
		edited.singleStmtBraceSymmetry = true;
	});

	private static final CALL_SOURCE: String = 'class C {\n\tfunction f() {\n\t\tif (retryCount == 0)\n'
		+ "\t\t\tattachCollectedLabel(defaultPreviewSurface, 'some long label text here', anotherArgument, yetAnother);\n"
		+ "\t\telse\n\t\t\tlog('long message that fits after else');\n\t}\n}";
	private static final CALL_LADDER: String = 'class C {\n\tfunction f() {\n\t\tif (retryCount == 0)\n'
		+ "\t\t\tattachCollectedLabel(defaultPreviewSurface,\n\t\t\t\t'some long label text here', anotherArgument, yetAnother);\n"
		+ "\t\telse\n\t\t\tlog('long message that fits after else');\n\t}\n}";
	private static final FOR_SOURCE: String = 'class C {\n\tfunction f() {\n\t\tif (retryCount == 0)\n\t\t\tfor (x in xs) {\n'
		+ "\t\t\t\tlog(x);\n\t\t\t}\n\t\telse\n\t\t\tlog('long message that fits after else');\n\t}\n}";
	private static final FOR_LADDER: String = 'class C {\n\tfunction f() {\n\t\tif (retryCount == 0)\n\t\t\tfor (x in xs)\n'
		+ "\t\t\t\tlog(x);\n\t\telse\n\t\t\tlog('long message that fits after else');\n\t}\n}";
	private static final CHAIN_HEAD_SOURCE: String = 'class C {\n\tfunction f() {\n\t\tif (retryCount == 0)\n'
		+ "\t\t\tattachCollectedLabel(defaultPreviewSurface, 'some long label text here', anotherArgument, yetAnother);\n"
		+ "\t\telse if (retryCount == 1)\n\t\t\tlog('x');\n\t\telse\n\t\t\tlog('long message that fits after else');\n\t}\n}";
	private static final CHAIN_HEAD_LADDER: String = 'class C {\n\tfunction f() {\n\t\tif (retryCount == 0)\n'
		+ "\t\t\tattachCollectedLabel(defaultPreviewSurface,\n\t\t\t\t'some long label text here', anotherArgument, yetAnother);\n"
		+ "\t\telse if (retryCount == 1)\n\t\t\tlog('x');\n\t\telse\n\t\t\tlog('long message that fits after else');\n\t}\n}";
	private static final CHAIN_MIDDLE_SOURCE: String = "class C {\n\tfunction f() {\n\t\tif (retryCount == 0) log('x');\n"
		+ '\t\telse if (retryCount == 1)\n'
		+ "\t\t\tattachCollectedLabel(defaultPreviewSurface, 'some long label text here', anotherArgument, yetAnother);\n"
		+ "\t\telse log('y');\n\t}\n}";
	private static final CHAIN_MIDDLE_LADDER: String = "class C {\n\tfunction f() {\n\t\tif (retryCount == 0)\n\t\t\tlog('x');\n"
		+ '\t\telse if (retryCount == 1)\n'
		+ "\t\t\tattachCollectedLabel(defaultPreviewSurface,\n\t\t\t\t'some long label text here', anotherArgument, yetAnother);\n"
		+ "\t\telse\n\t\t\tlog('y');\n\t}\n}";
	private static final ONE_LINER_SOURCE: String = 'class C {\n\tfunction f() {\n\t\tif (c) a(); else b();\n\t}\n}';
	private static final ONE_LINER_LADDER: String = 'class C {\n\tfunction f() {\n\t\tif (c)\n\t\t\ta();\n\t\telse\n\t\t\tb();\n\t}\n}';
	private static final FITTING_CHAIN_SOURCE: String = 'class C {\n\tfunction f() {\n\t\tif (a) x(); else if (b) y(); else z();\n\t}\n}';
	private static final FITTING_CHAIN_LADDER: String =
		'class C {\n\tfunction f() {\n\t\tif (a)\n\t\t\tx();\n\t\telse if (b)\n\t\t\ty();\n\t\telse\n\t\t\tz();\n\t}\n}';
	private static final NO_ELSE_SOURCE: String = 'class C {\n\tfunction f() {\n\t\tif (retryCount == 0)\n'
		+ "\t\t\tattachCollectedLabel(defaultPreviewSurface, 'some long label text here', anotherArgument, yetAnother);\n\t}\n}";
	private static final NO_ELSE_GLUED: String = 'class C {\n\tfunction f() {\n'
		+ '\t\tif (retryCount == 0) attachCollectedLabel(defaultPreviewSurface,\n'
		+ "\t\t\t'some long label text here', anotherArgument, yetAnother);\n\t}\n}";
	private static final NESTED_SOURCE: String = 'class C {\n\tfunction f() {\n\t\tif (a) attachCollectedLabel(defaultPreviewSurface, '
		+ "'some long label text here', anotherArgument, yetAnother); else for (i in xs) if (b) y(); else z();\n"
		+ '\t\tif (a) for (i in xs) { if (b) y(); else z(); } else w();\n\t}\n}';
	private static final NESTED_LADDER: String = 'class C {\n\tfunction f() {\n\t\tif (a)\n'
		+ '\t\t\tattachCollectedLabel(defaultPreviewSurface,\n'
		+ '\t\t\t\t\'some long label text here\', anotherArgument, yetAnother);\n\t\telse\n'
		+ '\t\t\tfor (i in xs)\n\t\t\t\tif (b)\n\t\t\t\t\ty();\n\t\t\t\telse\n\t\t\t\t\tz();\n\t\tif (a)\n\t\t\tfor ('
		+ 'i in xs)\n\t\t\t\tif (b)\n\t\t\t\t\ty();\n\t\t\t\telse\n\t\t\t\t\tz();\n\t\telse\n\t\t\tw();\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** A wrapped call in the then-branch takes the ladder instead of gluing to the head. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-OFF')
	public function testWrappedCallBodyLaddersTheChain(): Void {
		Assert.equals(CALL_LADDER, triviaWrite(CALL_SOURCE));
	}

	/** A `for` whose own body goes below it takes the ladder too. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-OFF')
	public function testForBodyLaddersTheChain(): Void {
		Assert.equals(FOR_LADDER, triviaWrite(FOR_SOURCE));
	}

	/** An else-if chain whose head branch is multi-line goes as a ladder in every branch. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-OFF')
	public function testElseIfChainWithMultiLineHeadIsALadder(): Void {
		Assert.equals(CHAIN_HEAD_LADDER, triviaWrite(CHAIN_HEAD_SOURCE));
	}

	/** A multi-line branch in the middle of an else-if chain ladders the branches before and after it. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-OFF')
	public function testElseIfChainWithMultiLineMiddleIsALadder(): Void {
		Assert.equals(CHAIN_MIDDLE_LADDER, triviaWrite(CHAIN_MIDDLE_SOURCE));
	}

	/** Every branch fits: the chain is a ladder all the same. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-OFF')
	public function testFittingOneLinerLadders(): Void {
		Assert.equals(ONE_LINER_LADDER, triviaWrite(ONE_LINER_SOURCE));
		Assert.equals(FITTING_CHAIN_LADDER, triviaWrite(FITTING_CHAIN_SOURCE));
	}

	/** An `if` without an `else` still glues its wrapped body to the head. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-NO-ELSE')
	public function testNoElseStillGlues(): Void {
		Assert.equals(NO_ELSE_GLUED, triviaWrite(NO_ELSE_SOURCE));
	}

	/** Every ladder is a fixed point of the writer. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-OFF')
	public function testLaddersAreIdempotent(): Void {
		for (ladder in [
			CALL_LADDER,
			FOR_LADDER,
			CHAIN_HEAD_LADDER,
			CHAIN_MIDDLE_LADDER,
			ONE_LINER_LADDER,
			FITTING_CHAIN_LADDER
		]) Assert.equals(ladder, triviaWrite(ladder));
	}

	/** A chain nested in a branch body that is not an `else if` link is a ladder of its own. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-OFF')
	public function testNestedChainIsItsOwnChain(): Void {
		Assert.equals(NESTED_LADDER, triviaWrite(NESTED_SOURCE));
		Assert.equals(NESTED_LADDER, triviaWrite(NESTED_LADDER));
	}

	private static function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
