package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Severity;
import anyparse.check.UnusedImport;
import anyparse.grammar.haxe.HaxeQueryPlugin;

using StringTools;

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

	/**
	 * An out-of-set (unresolvable) module downgrades to an unverifiable Info advisory.
	 */
	public function testUnresolvableModuleKeepsBoundNameVerdict(): Void {
		final use: String = 'package pkg;\n\nimport a.b.Gone;\n\nclass C {\n\tvar x: GoneExtra;\n}';
		final vs: Array<Violation> = new UnusedImport().run([{ file: 'pkg/C.hx', source: use }], plugin());

		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('not in lint scope'));
	}

	/** A module import used ONLY via a bare enum constructor (the type name never appears) is kept — the ctor is bare-referenceable via expected-type resolution. */
	public function testBareEnumConstructorKeepsModuleImport(): Void {
		final mod: String = 'package a.b;\n\nenum Mod {\n\tGo;\n\tStop;\n}';
		final use: String = 'package pkg;\n\nimport a.b.Mod;\n\nclass C {\n\tvar x = Go;\n}';
		final vs: Array<Violation> = new UnusedImport().run([
			{ file: 'a/b/Mod.hx', source: mod },
			{ file: 'pkg/C.hx', source: use },
		], plugin());

		Assert.equals(0, vs.length);
	}

	/** A sub-module `enum abstract` import used only via a bare value is kept (path keyed as module.Type). */
	public function testBareEnumAbstractValueKeepsSubModuleImport(): Void {
		final mod: String = 'package a.b;\n\nenum abstract Kind(Int) {\n\tfinal First = 0;\n\tfinal Second = 1;\n}\n\nclass Mod {}';
		final use: String = 'package pkg;\n\nimport a.b.Mod.Kind;\n\nclass C {\n\tvar x = First;\n}';
		final vs: Array<Violation> = new UnusedImport().run([
			{ file: 'a/b/Mod.hx', source: mod },
			{ file: 'pkg/C.hx', source: use },
		], plugin());

		Assert.equals(0, vs.length);
	}

	/** An enum import with NO constructor referenced is still flagged — the ctor carve-out does not over-keep. */
	public function testWhollyUnusedEnumImportStillFlagged(): Void {
		final mod: String = 'package a.b;\n\nenum Mod {\n\tGo;\n\tStop;\n}';
		final use: String = 'package pkg;\n\nimport a.b.Mod;\n\nclass C {}';
		final vs: Array<Violation> = new UnusedImport().run([
			{ file: 'a/b/Mod.hx', source: mod },
			{ file: 'pkg/C.hx', source: use },
		], plugin());

		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	/**
	 * A `#if`-guarded unused import is NEVER a `Warning` — its usage is
	 * `#if`-conditional and the reference scan is branch-blind, so it cannot be
	 * verified unused, and the fix must not delete a line inside a `#if` region.
	 * The unreferenced case is reported `Info` only (advisory, unfixed). The
	 * module is IN the lint set, so absent the guard downgrade this identical
	 * import would be a deletable `Warning` (cf. `testWhollyUnusedModuleImport…`)
	 * — the guard alone drops it to `Info`.
	 */
	public function testGuardedUnusedImportIsInfoNotWarning(): Void {
		final mod: String = 'package a.b;\n\nclass Mod {}';
		final use: String = 'package pkg;\n\n#if js\nimport a.b.Mod;\n#end\n\nclass C {}';
		final vs: Array<Violation> = new UnusedImport().run([
			{ file: 'a/b/Mod.hx', source: mod },
			{ file: 'pkg/C.hx', source: use },
		], plugin());

		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	/** A guarded import whose bound name IS referenced anywhere in the file text is not flagged at all. */
	public function testGuardedReferencedImportNotFlagged(): Void {
		final mod: String = 'package a.b;\n\nclass Mod {}';
		final use: String = 'package pkg;\n\n#if js\nimport a.b.Mod;\n#end\n\nclass C {\n\tvar x: Mod;\n}';
		final vs: Array<Violation> = new UnusedImport().run([
			{ file: 'a/b/Mod.hx', source: mod },
			{ file: 'pkg/C.hx', source: use },
		], plugin());

		Assert.equals(0, vs.length);
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

}
