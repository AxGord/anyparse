package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.UnusedCaseBinder;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * A switch whose arms are a RUN of bare lowercase identifiers is listing constants the run
 * cannot see, not writing binders.
 *
 * `unused-case-binder`'s two gates both passed on `case red:` — the last arm of a switch over
 * a lowercase enum declared in a haxelib outside the lint scope. Widening it to `_` preserved
 * behaviour, which is what gate 2 proves, and quietly ended the exhaustiveness check: add a
 * constructor later and it lands in that arm instead of raising `Unmatched patterns`.
 *
 * The evidence is the SIBLINGS, not the subject's type. A real binder catch-all follows
 * constructor names or literals; it never follows a run of bare lowercase identifiers,
 * because everything after such an arm would be unreachable — the compiler warns
 * `WUnusedPattern` on every one (checked on 4.3.7). So refusing the whole switch costs
 * nothing that exists in real code, and needs no type resolution.
 */
class UnusedCaseBinderConstantLanguageTest extends Test {

	public function testARunOfBareLowercaseArmsIsRefused(): Void {
		// `ConsoleColor` is out of scope, so the declared-constant gate cannot see `red`.
		final source: String = 'package p;\n\nimport ext.Printer.ConsoleColor;\n\nclass C {\n\tstatic function pick(c: ConsoleColor): Int {'
			+ '\n\t\treturn switch (c) {\n\t\t\tcase none: 1;\n\t\t\tcase white: 2;\n\t\t\tcase red: 3;\n\t\t}\n\t}\n}\n';
		Assert.equals(0, run(source).length);
	}

	public function testACatchAllAfterConstructorArmsIsStillABinder(): Void {
		final source: String = 'package p;\n\nenum Colour {\n\tRed;\n\tGreen;\n}\n\nclass C {\n\tstatic function f(c: Colour): Int {\n'
			+ '\t\treturn switch (c) {\n\t\t\tcase Red: 1;\n\t\t\tcase rest: 2;\n\t\t}\n\t}\n}\n';
		final vs: Array<Violation> = run(source);
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.equals('case binder \'rest\' is never read; replace it with _', vs[0].message);
	}

	public function testANestedBinderIsUnaffectedByTheSiblingRule(): Void {
		// The gate is about WHOLE-pattern binders — a constructor argument cannot be a
		// constant reference, so a run of lowercase arms says nothing about it.
		final source: String = 'package p;\n\nenum Node {\n\tLeaf(v: Int);\n\tPair(a: Int, b: Int);\n}\n\nclass C {\n'
			+ '\tstatic function f(n: Node): Int {\n\t\treturn switch (n) {\n\t\t\tcase Leaf(v): v;\n\t\t\tcase Pair(a, b): b;\n'
			+ '\t\t}\n\t}\n}\n';
		Assert.equals(1, run(source).length);
	}

	private function run(source: String): Array<Violation> {
		return new UnusedCaseBinder().run([{ file: 'p/C.hx', source: source }], new HaxeQueryPlugin());
	}

}
