package unit;

import anyparse.check.Check;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Linter;
import anyparse.check.RedundantImport;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `redundant-import` — a sub-module type import (`import pkg.Mod.Sub;`) whose module is ALREADY
 * imported in the same file. A plain module import binds every top-level type the module declares,
 * so the second statement binds nothing new. The rule is the report side of the same fact
 * `TypeRefPrinter` prints by: the two must agree, or a fixer inserts what this rule then deletes.
 */
class RedundantImportCheckTest extends Test {

	/** The module whose main type is `Mod` and whose secondary type is `Sub`. */
	private static inline final MOD: String = 'package pkg.deep;\n\nclass Mod {}\n\ntypedef Sub = Int;\n';

	// --- reported ---

	public function testSubTypeImportBesideItsModuleImportIsRedundant(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Mod;\nimport pkg.deep.Mod.Sub;\n\nclass C {\n\n\tvar s:Sub;\n\n}\n';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('redundant-import', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('pkg.deep.Mod.Sub'));
		final span: Null<Span> = vs[0].span;
		Assert.notNull(span);
		if (span != null) Assert.equals(4, span.lineCol(src).line);
	}

	public function testFixDeletesTheRedundantImport(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Mod;\nimport pkg.deep.Mod.Sub;\n\nclass C {\n\n\tvar s:Sub;\n\n}\n';
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals('', es[0].text);
		Assert.equals('package app;\n\nimport pkg.deep.Mod;\n\n\nclass C {\n\n\tvar s:Sub;\n\n}\n', RefactorSupport.applyEdits(src, es));
	}

	/** `using pkg.Mod;` IS `import pkg.Mod;` plus static extension, so it binds the module's types too. */
	public function testUsingTheModuleAlsoBindsItsSecondaryTypes(): Void {
		final src: String = 'package app;\n\nusing pkg.deep.Mod;\nimport pkg.deep.Mod.Sub;\n\nclass C {\n\n\tvar s:Sub;\n\n}\n';
		Assert.equals(1, violations(src).length);
	}

	/** The module import may sit ANYWHERE in the file — import binding is order-free for distinct names. */
	public function testModuleImportBelowTheSubTypeImportStillCounts(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Mod.Sub;\nimport pkg.deep.Mod;\n\nclass C {\n\n\tvar s:Sub;\n\n}\n';
		Assert.equals(1, violations(src).length);
	}

	// --- kept ---

	public function testSubTypeImportWithoutTheModuleImportIsKept(): Void {
		Assert.equals(0, violations('package app;\n\nimport pkg.deep.Mod.Sub;\n\nclass C {\n\n\tvar s:Sub;\n\n}\n').length);
	}

	/**
	 * An ALIASED sub-type import binds the alias, a name the module import does not provide. Today
	 * the grammar exposes only the ALIAS in an import's `raw` (the documented `ImportInfo` limit),
	 * so the statement never even presents a dotted sub-type path — the kind gate is not what refuses
	 * THIS fixture. `testUsingOfASubModuleTypeIsKept` is the one that discriminates it.
	 */
	public function testAliasedSubTypeImportIsKept(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Mod;\nimport pkg.deep.Mod.Sub as S;\n\nclass C {\n\n\tvar s:S;\n\n}\n';
		Assert.equals(0, violations(src).length);
	}

	/** The `in` spelling of an alias is the same statement — never touched. */
	public function testAliasedSubTypeImportInFormIsKept(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Mod;\nimport pkg.deep.Mod.Sub in S;\n\nclass C {\n\n\tvar s:S;\n\n}\n';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * A `using pkg.Mod.SubTools;` is a STATIC EXTENSION on a sub-module type — deleting it removes
	 * the `.method()` calls it enables, which the module import does NOT restore. It is the fixture
	 * that discriminates the rule's import-KIND gate: its `raw` IS a dotted sub-type path, so every
	 * other gate would wave it through.
	 */
	public function testUsingOfASubModuleTypeIsKept(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Mod;\nusing pkg.deep.Mod.SubTools;\n\nclass C {\n\n\tvar s:Sub;\n\n}\n';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'app/C.hx', source: src },
			{
				file: 'pkg/deep/Mod.hx',
				source: 'package pkg.deep;\n\nclass Mod {}\n\ntypedef Sub = Int;\n\nclass SubTools {\n\n\tpublic static function twice(v:Int):Int {\n\t\treturn v * 2;\n\t}\n\n}\n'
			}
		];
		Assert.equals(0, new RedundantImport().run(files, new HaxeQueryPlugin()).length);
	}

	/** An ALIASED module import binds only the alias — it brings no secondary type into scope. Refused on the path shape: an alias's `raw` IS the alias, never a dotted module path. */
	public function testAliasedModuleImportDoesNotMakeTheSubTypeImportRedundant(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Mod as M;\nimport pkg.deep.Mod.Sub;\n\nclass C {\n\n\tvar s:Sub;\n\n}\n';
		Assert.equals(0, violations(src).length);
	}

	/** Nothing PROVES the module declares the name when the module is outside the resolution scope. */
	public function testUnindexedModuleIsNotReported(): Void {
		final src: String = 'package app;\n\nimport out.side.Mod;\nimport out.side.Mod.Sub;\n\nclass C {\n\n\tvar s:Sub;\n\n}\n';
		Assert.equals(0, violations(src).length);
	}

	/** A `#if`-guarded sub-type import is a line inside a conditional region — never deleted. */
	public function testGuardedSubTypeImportIsKept(): Void {
		final src: String =
			'package app;\n\nimport pkg.deep.Mod;\n#if js\nimport pkg.deep.Mod.Sub;\n#end\n\nclass C {\n\n\tvar s:Sub;\n\n}\n';
		Assert.equals(0, violations(src).length);
	}

	/** A GUARDED module import exists only in some builds, so it cannot make an unguarded import redundant. */
	public function testGuardedModuleImportDoesNotMakeItRedundant(): Void {
		final src: String =
			'package app;\n\n#if js\nimport pkg.deep.Mod;\n#end\nimport pkg.deep.Mod.Sub;\n\nclass C {\n\n\tvar s:Sub;\n\n}\n';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * Another module import binding the SAME simple name decides what the short name means — leave
	 * both alone. The competitor sits BETWEEN the two `pkg.deep.Mod` statements on purpose: that is
	 * the only position where the deletion actually changes the winner (Haxe lets the LAST import of
	 * a simple name win, so a competitor before the module import or after this one wins either way).
	 */
	public function testAnotherModuleBindingTheSameNameKeepsIt(): Void {
		final src: String =
			'package app;\n\nimport pkg.deep.Mod;\nimport other.Other;\nimport pkg.deep.Mod.Sub;\n\nclass C {\n\n\tvar s:Sub;\n\n}\n';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'app/C.hx', source: src },
			{ file: 'pkg/deep/Mod.hx', source: MOD },
			{ file: 'other/Other.hx', source: 'package other;\n\nclass Other {}\n\ntypedef Sub = Float;\n' }
		];
		Assert.equals(0, new RedundantImport().run(files, new HaxeQueryPlugin()).length);
	}

	/** A type the file itself declares under that name outranks every import — leave the statement alone. */
	public function testModuleLocalTypeOfTheSameNameKeepsIt(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Mod;\nimport pkg.deep.Mod.Sub;\n\nclass C {}\n\ntypedef Sub = String;\n';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * A lower-initial leaf is a STATIC / field import, not a type — the module import does not cover
	 * it. Two gates refuse it (the leaf-case pre-filter and the index proof that no TYPE of that
	 * name lives in the module); only the index one is discriminating, since a lower-initial type
	 * declaration is not a shape a real module carries.
	 */
	public function testStaticMemberImportIsNeverFlagged(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Mod;\nimport pkg.deep.Mod.helper;\n\nclass C {}\n';
		Assert.equals(0, violations(src).length);
	}

	/** An enum CONSTRUCTOR import names a member, not a top-level type — the index proves the difference. */
	public function testEnumConstructorImportIsNotFlagged(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Colors;\nimport pkg.deep.Colors.Red;\n\nclass C {}\n';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'app/C.hx', source: src },
			{ file: 'pkg/deep/Colors.hx', source: 'package pkg.deep;\n\nenum Colors {\n\tRed;\n\tBlue;\n}\n' }
		];
		Assert.equals(0, new RedundantImport().run(files, new HaxeQueryPlugin()).length);
	}

	/**
	 * A wildcard import brings statics / constructors, never a type name — never a CANDIDATE. Its
	 * `raw` leaf is `*`, so the kind gate and the leaf-case gate both refuse it; the assertion is on
	 * the BEHAVIOUR, not on which gate delivers it.
	 */
	public function testWildcardImportIsNeverFlagged(): Void {
		final src: String = 'package app;\n\nimport pkg.deep.Mod;\nimport pkg.deep.Mod.*;\n\nclass C {}\n';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * A package wildcard declaring the same name is NOT a second binder: an explicit module import
	 * outranks a wildcard in EITHER statement order (measured on 4.3.7), and the module import
	 * survives the deletion — so the wildcard can never become the winner and the finding stands.
	 */
	public function testPackageWildcardDoesNotSuppressTheFinding(): Void {
		final src: String =
			'package app;\n\nimport pkg.deep.Mod;\nimport pkg.deep.Mod.Sub;\nimport far.*;\n\nclass C {\n\n\tvar s:Sub;\n\n}\n';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'app/C.hx', source: src },
			{ file: 'pkg/deep/Mod.hx', source: MOD },
			{ file: 'far/Sub.hx', source: 'package far;\n\nclass Sub {}\n' }
		];
		Assert.equals(1, new RedundantImport().run(files, new HaxeQueryPlugin()).length);
	}

	// --- the live repro shape ---

	/**
	 * The TM shape that motivated the rule: a fixer materialised two sub-type annotations into a
	 * file whose modules were both already imported, and route 2 spliced an import for each into a
	 * fresh run below the file's `using`.
	 */
	public function testTwoRunFileWithBothSubTypeImportsRedundant(): Void {
		final src: String = 'package tests.unit;\n\nimport fs.FileSystemInterface;\nimport fs.cloud.CloudDatabase;\n'
			+ '\nusing tink.CoreApi;\n\nimport fs.FileSystemInterface.FileSystemCloudAction;\n'
			+ 'import fs.cloud.CloudDatabase.CloudDatabaseFilePath;\n\nclass T {\n\n\tvar a:FileSystemCloudAction;\n\n\tvar b:CloudDatabaseFilePath;\n\n}\n';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'tests/unit/T.hx', source: src },
			{
				file: 'fs/FileSystemInterface.hx',
				source: 'package fs;\n\ninterface FileSystemInterface {}\n\ntypedef FileSystemCloudAction = Int;\n'
			},
			{
				file: 'fs/cloud/CloudDatabase.hx',
				source: 'package fs.cloud;\n\nclass CloudDatabase {}\n\ntypedef CloudDatabaseFilePath = String;\n'
			}
		];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: RedundantImport = new RedundantImport();
		final vs: Array<Violation> = check.run(files, plugin);
		Assert.equals(2, vs.length);
		final fixed: String = RefactorSupport.applyEdits(src, check.fix(src, vs, plugin, SymbolIndex.build(files, plugin)));
		Assert.isFalse(fixed.contains('import fs.FileSystemInterface.FileSystemCloudAction;'));
		Assert.isFalse(fixed.contains('import fs.cloud.CloudDatabase.CloudDatabaseFilePath;'));
		Assert.isTrue(fixed.contains('import fs.FileSystemInterface;'));
		Assert.isTrue(fixed.contains('import fs.cloud.CloudDatabase;'));
	}

	// --- registration ---

	/**
	 * Registered, and a `RiskyFix`: the second-binder veto is only as complete as the RESOLUTION
	 * INDEX, so a deletion's safety is a property of the run's scope rather than a structurally
	 * provable shape — the deletions go through the oracle's typecheck-and-revert, and stay
	 * report-only where no oracle is configured.
	 */
	public function testRegisteredAsARiskyFix(): Void {
		final check: Null<Check> = Linter.byId('redundant-import');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, RiskyFix), 'redundant-import deletions are oracle-verified');
		Assert.equals(141, Linter.builtins().length);
	}

	// --- helpers -------------------------------------------------------------------

	/** The check's findings for `src`, resolved against a file set that also carries `pkg.deep.Mod`. */
	private function violations(src: String): Array<Violation> {
		return new RedundantImport().run(fileSet(src), new HaxeQueryPlugin());
	}

	/** The check's autofix edits for `src`. */
	private function edits(src: String): Array<{ span: Span, text: String }> {
		final files: Array<{ file: String, source: String }> = fileSet(src);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: RedundantImport = new RedundantImport();
		return check.fix(src, check.run(files, plugin), plugin, SymbolIndex.build(files, plugin));
	}

	private function fileSet(src: String): Array<{ file: String, source: String }> {
		return [{ file: 'app/C.hx', source: src }, { file: 'pkg/deep/Mod.hx', source: MOD }];
	}

}
