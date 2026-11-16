package unit.grammar.haxe;

import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * A `for` / `while` / `do` whose body is an `if` with a brace-less branch and an `else` is a ladder under the DEFAULT
 * config: the whole `if` sits one indent under the loop head, so its `else` is not read as a branch of the loop.
 */
@:nullSafety(Strict)
final class HxLoopBodyIfElseDefaultTest extends Test {

	private static final FOR_ELSE: String = 'class C {\n\tfunction f() {\n\t\tfor (x in xs) if (c) a(); else b();\n\t}\n}';
	private static final FOR_LADDER: String =
		'class C {\n\tfunction f() {\n\t\tfor (x in xs)\n\t\t\tif (c)\n\t\t\t\ta();\n\t\t\telse\n\t\t\t\tb();\n\t}\n}';
	private static final WHILE_ELSE: String = 'class C {\n\tfunction f() {\n\t\twhile (x) if (c) a(); else b();\n\t}\n}';
	private static final WHILE_LADDER: String =
		'class C {\n\tfunction f() {\n\t\twhile (x)\n\t\t\tif (c)\n\t\t\t\ta();\n\t\t\telse\n\t\t\t\tb();\n\t}\n}';

	@:pin('control')
	@:killer('M-LOOPIF-NEVER')
	public function testForIfElseLaddersByDefault(): Void {
		Assert.equals(FOR_LADDER, HxWriteFixture.triviaWrite(FOR_ELSE, defaults()));
		Assert.equals(FOR_LADDER, HxWriteFixture.triviaWrite(FOR_LADDER, defaults()));
	}

	@:pin('control')
	@:killer('M-LOOPIF-NEVER')
	public function testWhileIfElseLaddersByDefault(): Void {
		Assert.equals(WHILE_LADDER, HxWriteFixture.triviaWrite(WHILE_ELSE, defaults()));
	}

	/** The compiled defaults, where `forBody` / `whileBody` are still `fitLine`: no config document re-baselines them to `next`. */
	private static function defaults(): HxModuleWriteOptions {
		return HxWriteOptionsKit.rawWith(_ -> {});
	}

}
