package unit;

import anyparse.check.Check.Violation;
import anyparse.check.Severity;
import anyparse.check.UnusedImport;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * `using pkg.Mod;` brings the static extensions of EVERY top-level type the module
 * declares into scope — not only those of the type that shares the module's name.
 *
 * The check used to look the module up in a per-PATH member map, which answers a
 * different question, so a call resolving to a SUB-MODULE type's extension counted
 * as no use at all: `Math.abs(ms).toFixed('000')` in `pony.time.Time` resolves to
 * `pony.Tools.FloatTools.toFixed`, was reported as a verified-unused `Warning`, and
 * `--fix` deleted the `using`. `Float has no field toFixed`, on a green tree.
 *
 * The same site reported an honest `Info` under a NARROW scope (the module was not
 * in the set at all, so nothing could be proved) and an assertive `Warning` under a
 * wide one — the scope-dependent confidence that gave the defect away.
 */
class LintUsingSubmoduleExtensionTest extends Test {

	/** A module whose main type declares `doubled` and whose sub-module type declares `toFixed`. */
	private static final MODULE: String = 'package a.b;\n\nclass Tools {\n\n\tpublic static function doubled(v: Int): Int return v * 2;\n\n}\n\n'
		+ 'class FloatTools {\n\n\tpublic static function toFixed(v: Float): String return Std.string(v);\n\n}\n';

	/** An extension declared by a SUB-MODULE type of the used module keeps the `using`. */
	public function testSubmoduleTypeExtensionKeepsTheUsing(): Void {
		Assert.equals(
			0, run(MODULE, 'package pkg;\n\nusing a.b.Tools;\n\nclass C {\n\tfunction f(v: Float): String return v.toFixed();\n}').length
		);
	}

	/** An extension declared by the module's MAIN type keeps it too — the pre-existing behaviour, unchanged. */
	public function testMainTypeExtensionKeepsTheUsing(): Void {
		Assert.equals(
			0, run(MODULE, 'package pkg;\n\nusing a.b.Tools;\n\nclass C {\n\tfunction f(v: Int): Int return v.doubled();\n}').length
		);
	}

	/** No extension of ANY type of the module called, and the module never named — still a verified Warning. */
	public function testNoExtensionCallIsStillAWarning(): Void {
		final vs: Array<Violation> = run(
			MODULE, 'package pkg;\n\nusing a.b.Tools;\n\nclass C {\n\tfunction f(v: Float): Float return v;\n}'
		);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('unused using \'a.b.Tools\'', vs[0].message);
	}

	/** A module the run cannot read at all stays an unverifiable Info — no member set, no verdict. */
	public function testOutOfScopeModuleStaysInfo(): Void {
		final vs: Array<Violation> = new UnusedImport().run([
			{
				file: 'pkg/C.hx',
				source: 'package pkg;\n\nusing a.b.Tools;\n\nclass C {\n\tfunction f(v: Float): String return v.toFixed();\n}'
			}
		], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.equals(Severity.Info, vs[0].severity);
	}

	private function run(module: String, consumer: String): Array<Violation> {
		return new UnusedImport().run(
			[{ file: 'a/b/Tools.hx', source: module }, { file: 'pkg/C.hx', source: consumer }], new HaxeQueryPlugin()
		);
	}

}
