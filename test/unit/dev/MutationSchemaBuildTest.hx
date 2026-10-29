package unit.dev;

import dev.MutationSchemaBuild;
import utest.Assert;
import utest.Test;

/**
 * The composed build's three readings: which arms a failed compile names (so they are left out and the rest built
 * again), which arms the build embeds as text, and the `--macro` calls that type those modules in the macro context.
 */
@:nullSafety(Strict)
final class MutationSchemaBuildTest extends Test {

	/** Two arms composed into one file (copies at 50-60 and 61-70, dispatched from 10 and 20), one into another. */
	private static inline final PLACEMENTS: String = '1\tok\tsrc/a/B.hx\t10\t50\t60\tB\n' + '2\tok\tsrc/a/B.hx\t20\t61\t70\tB\n'
		+ '3\tok\tsrc/a/C.hx\t5\t30\t40\tCHelper\n' + '4\tskip\tsrc/a/D.hx\tnot composed\n';

	public function testAnErrorInACopyOrOnItsDispatchNamesThatArm(): Void {
		Assert.same([2], MutationSchemaBuild.culprits(PLACEMENTS, 'src/a/B.hx:65: characters 1-2 : Unknown identifier : x\n'));
		Assert.same([1], MutationSchemaBuild.culprits(PLACEMENTS, './src/a/B.hx:10: characters 1-2 : Type not found\n'));
	}

	public function testAnErrorElsewhereInAComposedFileNamesEveryArmOfIt(): Void {
		Assert.same(
			[1, 2, 3], MutationSchemaBuild.culprits(PLACEMENTS, 'src/a/B.hx:3: characters 1-2 : x\nsrc/a/C.hx:35: lines 35-36 : y\n')
		);
		Assert.same(
			[], MutationSchemaBuild.culprits(PLACEMENTS, 'src/a/E.hx:3: characters 1-2 : x\nno position here\n'),
			'a file no arm is composed into'
		);
	}

	public function testAnEmbeddedArmIsFoundByItsDispatchLineInTheOutput(): Void {
		final plan: String = '1\tsrc/a/B.hx\tFnMember:run\t/w/A.new\n2\tsrc/a/B.hx\tFnMember:walk\t/w/B.new\n';
		final output: String =
			'x = "if (__mutOn(2)) return __mut2_walk(a);"; if (B.__mutOn(1)) return B.__mut1_run(a);\n"(__mutOn(9)) return __mut9_other("';
		Assert.same(
			[2], MutationSchemaBuild.embedded(plan, output), 'compiled code spells the call another way; an unplanned id is no arm'
		);
	}

	public function testAnEmbeddedModuleIsTypedThroughItsOwnerType(): Void {
		Assert.same(
			['--macro', 'a.B.__mutOn(0)', '--macro', 'a.C.CHelper.__mutOn(0)'], MutationSchemaBuild.embeddedMacros(PLACEMENTS, [3, 2, 1])
		);
		Assert.same([], MutationSchemaBuild.embeddedMacros(PLACEMENTS, [4]), 'a skipped arm is no copy');
	}

}
