package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Severity;
import anyparse.check.UnusedImport;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * `unused-import` and module SECONDARY types: `import pkg.Mod;` binds every
 * top-level type of module `Mod`, not only the main one. A consumer that
 * references only a secondary typedef/enum of the module never names `Mod`
 * itself — the bound-name scan alone would flag (and `--fix` would delete)
 * an import the compiler requires. When the module is present in the lint
 * file set, the check must consult ALL of its top-level type names before
 * declaring the import unused; an unresolvable module keeps the plain
 * bound-name verdict (stdlib modules are not in the set).
 */
class LintModuleSecondaryTypeSliceTest extends Test {

	/** A consumer referencing only a secondary typedef of an in-set module keeps the import. */
	public function testSecondaryTypedefUseKeepsModuleImport(): Void {
		final mod: String = 'package a.b;\n\ntypedef ModExtra = {\n\tvar id: Int;\n}\n\nclass Mod {}';
		final use: String = 'package pkg;\n\nimport a.b.Mod;\n\nclass C {\n\tvar x: ModExtra;\n}';
		final vs: Array<Violation> = new UnusedImport().run([
			{ file: 'a/b/Mod.hx', source: mod },
			{ file: 'pkg/C.hx', source: use },
		], plugin());

		Assert.equals(0, vs.length);
	}

	/** A secondary enum reference counts the same as a typedef. */
	public function testSecondaryEnumUseKeepsModuleImport(): Void {
		final mod: String = 'package a.b;\n\nenum ModAction {\n\tGo;\n\tStop;\n}\n\nclass Mod {}';
		final use: String = 'package pkg;\n\nimport a.b.Mod;\n\nclass C {\n\tfunction f(): ModAction return Go;\n}';
		final vs: Array<Violation> = new UnusedImport().run([
			{ file: 'a/b/Mod.hx', source: mod },
			{ file: 'pkg/C.hx', source: use },
		], plugin());

		Assert.equals(0, vs.length);
	}

	/** A secondary `enum abstract` reference counts too — `EnumAbstractDecl` is a top-level type declaration. */
	public function testSecondaryEnumAbstractUseKeepsModuleImport(): Void {
		final mod: String = 'package a.b;\n\nenum abstract ModKind(String) to String {\n\tfinal A = \'a\';\n}\n\nclass Mod {}';
		final use: String = 'package pkg;\n\nimport a.b.Mod;\n\nclass C {\n\tvar x: ModKind;\n}';
		final vs: Array<Violation> = new UnusedImport().run([
			{ file: 'a/b/Mod.hx', source: mod },
			{ file: 'pkg/C.hx', source: use },
		], plugin());

		Assert.equals(0, vs.length);
	}

	/** No type of the in-set module referenced at all — still a Warning. */
	public function testWhollyUnusedModuleImportStillFlagged(): Void {
		final mod: String = 'package a.b;\n\ntypedef ModExtra = {\n\tvar id: Int;\n}\n\nclass Mod {}';
		final use: String = 'package pkg;\n\nimport a.b.Mod;\n\nclass C {}';
		final vs: Array<Violation> = new UnusedImport().run([
			{ file: 'a/b/Mod.hx', source: mod },
			{ file: 'pkg/C.hx', source: use },
		], plugin());

		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	/**
	 * A SUB-TYPE import (`import a.b.Mod.ModExtra;`) binds only the named
	 * sub-type: a reference to a DIFFERENT secondary type of the same module
	 * does not keep it.
	 */
	public function testSubTypeImportNotWidened(): Void {
		final mod: String = 'package a.b;\n\ntypedef ModExtra = {\n\tvar id: Int;\n}\n\ntypedef ModOther = {\n\tvar n: Int;\n}\n\nclass Mod {}';
		final use: String = 'package pkg;\n\nimport a.b.Mod.ModExtra;\n\nclass C {\n\tvar x: ModOther;\n}';
		final vs: Array<Violation> = new UnusedImport().run([
			{ file: 'a/b/Mod.hx', source: mod },
			{ file: 'pkg/C.hx', source: use },
		], plugin());

		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	/** An out-of-set (unresolvable) module keeps the plain bound-name verdict. */
	public function testUnresolvableModuleKeepsBoundNameVerdict(): Void {
		final use: String = 'package pkg;\n\nimport a.b.Gone;\n\nclass C {\n\tvar x: GoneExtra;\n}';
		final vs: Array<Violation> = new UnusedImport().run([{ file: 'pkg/C.hx', source: use }], plugin());

		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

}
