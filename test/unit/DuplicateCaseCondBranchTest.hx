package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.DuplicateCase;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * `duplicate-case` and conditional compilation.
 *
 * A `#if` region inside a case list projects as ONE child of the switch whose own children are
 * the case branches of EVERY branch of the region, flattened into one sibling list — the tree
 * carries no branch boundary. Reading that list as neighbours made
 * `#if new … case TObject: … #else … case TObject: … #end` a repeated label, and `--fix` cut the
 * `#else` body out, leaving an empty region: on the older compiler the arm simply vanished.
 *
 * The four cases below are the whole contract. Excluding the region wholesale would fix the
 * first and silently lose the third; comparing only DIRECT children would fix the first and
 * lose the fourth. Both are real duplicates, so the boundaries have to be recovered rather than
 * stepped around — `CondBranchPath` reads them off the directive lines.
 */
class DuplicateCaseCondBranchTest extends Test {

	public function testArmsInDifferentBranchesAreNotDuplicates(): Void {
		Assert.equals(0, run('#if new\n\t\t\tcase 1: a();\n\t\t\t#else\n\t\t\tcase 1: b();\n\t\t\t#end').length);
	}

	public function testAPlainRepeatIsStillADuplicate(): Void {
		Assert.equals(1, run('case 1: a();\n\t\t\tcase 1: b();').length);
	}

	public function testARepeatInsideONEBranchIsStillADuplicate(): Void {
		Assert.equals(1, run('#if f\n\t\t\tcase 1: a();\n\t\t\tcase 1: b();\n\t\t\t#else\n\t\t\tcase 2: c();\n\t\t\t#end').length);
	}

	public function testAnArmOutsideARegionRepeatedInsideItIsADuplicate(): Void {
		// The build that takes the branch sees both, so this one is real — and it is the case a
		// direct-children-only comparison cannot reach, because the second arm is a child of the
		// region node rather than of the switch.
		Assert.equals(1, run('case 1: a();\n\t\t\t#if f\n\t\t\tcase 1: b();\n\t\t\t#end').length);
	}

	public function testThreeBranchesEachRepeatingTheLabelAreAllAlternatives(): Void {
		Assert.equals(
			0, run('#if a\n\t\t\tcase 1: x();\n\t\t\t#elseif b\n\t\t\tcase 1: y();\n\t\t\t#else\n\t\t\tcase 1: z();\n\t\t\t#end').length
		);
	}

	private function run(arms: String): Array<Violation> {
		final source: String =
			'class C {\n\tstatic function f(v: Int): Void {\n\t\tswitch (v) {\n\t\t\t$arms\n\t\t\tcase _: n();\n\t\t}\n\t}\n}\n';
		return new DuplicateCase().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

}
