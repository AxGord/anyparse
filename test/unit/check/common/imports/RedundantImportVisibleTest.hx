package unit.check.common.imports;

import anyparse.check.Check;
import anyparse.check.common.imports.RedundantImport;
import anyparse.query.CanonicalEdit;
import unit.cli.CliFixture;

/**
 * `redundant-import`'s visibility arm: a statement whose every type the file sees without it — a main type of the
 * module's own package or a parent one, a type the module itself declares, a type an ambient source already binds. The
 * typing layer reads the resolution order with and without the statement; the deletion is a no-op exactly where both
 * readings bind the same declarations.
 */
@:nullSafety(Strict)
class RedundantImportVisibleTest extends Test {

	private static final HELPER: String = 'package app;\n\nclass Helper {}\n';

	@:pin('control') @:killer('M-KEPTWITHOUT-NULL')
	public function testOwnPackageImportIsRedundant(): Void {
		final vs: Array<Violation> = violations([
			{ file: 'app/C.hx', source: 'package app;\n\nimport app.Helper;\n\nclass C {\n\n\tvar h:Helper;\n\n}\n' },
			{ file: 'app/Helper.hx', source: HELPER }
		]);
		Assert.equals(1, vs.length);
		Assert.equals('redundant-import', vs[0].rule);
		Assert.isTrue(vs[0].message.contains('own package \'app\''), vs[0].message);
	}

	public function testParentPackageImportIsRedundant(): Void {
		final vs: Array<Violation> = violations([
			{ file: 'app/sub/C.hx', source: 'package app.sub;\n\nimport app.Helper;\n\nclass C {\n\n\tvar h:Helper;\n\n}\n' },
			{ file: 'app/Helper.hx', source: HELPER }
		]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('parent package \'app\''), vs[0].message);
	}

	public function testRootPackageImportIsRedundant(): Void {
		final vs: Array<Violation> = violations([
			{ file: 'app/C.hx', source: 'package app;\n\nimport Top;\n\nclass C {\n\n\tvar t:Top;\n\n}\n' },
			{ file: 'Top.hx', source: 'class Top {}\n' }
		]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('root package'), vs[0].message);
	}

	/** A module importing its own sub-type: the module's own types outrank every statement. */
	public function testImportOfTheModulesOwnSubTypeIsRedundant(): Void {
		final vs: Array<Violation> = violations([
			{
				file: 'app/C.hx',
				source: 'package app;\n\nimport app.C.Extra;\n\nclass C {\n\n\tvar e:Extra;\n\n}\n\nclass Extra {}\n'
			}
		]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('this module declares them'), vs[0].message);
	}

	public function testFixDeletesTheStatement(): Void {
		final src: String = 'package app;\n\nimport app.Helper;\n\nclass C {\n\n\tvar h:Helper;\n\n}\n';
		final files: Array<{ file: String, source: String }> =
			[{ file: 'app/C.hx', source: src }, { file: 'app/Helper.hx', source: HELPER }];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: RedundantImport = new RedundantImport();
		final fixed: String = CanonicalEdit.applyEdits(
			src, check.fix(src, CheckFixture.violationsIn(check, files, plugin), plugin, CheckFixture.index(files, plugin))
		);
		Assert.isFalse(fixed.contains('import app.Helper;'));
	}

	// --- kept ---

	/** A nearer package declaring a module of the same name is what the name binds once the statement goes. */
	@:pin('control') @:killer('M-KEPTWITHOUT-STATEMENT-KEPT')
	public function testNearerPackageModuleOfTheNameKeepsIt(): Void {
		Assert.equals(
			0, violations([
				{ file: 'app/sub/C.hx', source: 'package app.sub;\n\nimport app.Helper;\n\nclass C {\n\n\tvar h:Helper;\n\n}\n' },
				{ file: 'app/Helper.hx', source: HELPER },
				{ file: 'app/sub/Helper.hx', source: 'package app.sub;\n\nclass Helper {}\n' }
			]).length
		);
	}

	/** A package wildcard is asked before the package tiers, so it decides the name once the statement goes. */
	public function testWildcardOfAnotherPackageKeepsIt(): Void {
		Assert.equals(
			0, violations([
				{
					file: 'app/sub/C.hx',
					source: 'package app.sub;\n\nimport w.*;\nimport app.Helper;\n\nclass C {\n\n\tvar h:Helper;\n\n}\n'
				},
				{ file: 'app/Helper.hx', source: HELPER },
				{ file: 'w/Helper.hx', source: 'package w;\n\nclass Helper {}\n' }
			]).length
		);
	}

	/** An enum import brings its constructors, which no package lookup does. */
	public function testEnumImportBindingConstructorsIsKept(): Void {
		Assert.equals(
			0, violations([
				{ file: 'app/C.hx', source: 'package app;\n\nimport app.Color;\n\nclass C {\n\n\tvar c:Color = Red;\n\n}\n' },
				{ file: 'app/Color.hx', source: 'package app;\n\nenum Color {\n\tRed;\n}\n' }
			]).length
		);
	}

	/** A module import brings the module's sub-types too, which the package lookup never reaches. */
	public function testModuleWithSubTypesIsKept(): Void {
		Assert.equals(
			0, violations([
				{ file: 'app/C.hx', source: 'package app;\n\nimport app.Helper;\n\nclass C {\n\n\tvar e:Extra;\n\n}\n' },
				{ file: 'app/Helper.hx', source: 'package app;\n\nclass Helper {}\n\nclass Extra {}\n' }
			]).length
		);
	}

	public function testAliasAndGuardedStatementsAreKept(): Void {
		Assert.equals(
			0, violations([
				{
					file: 'app/C.hx',
					source: 'package app;\n\nimport app.Helper as H;\n#if js\nimport app.Helper;\n#end\n\nclass C {\n\n\tvar h:H;\n\n}\n'
				},
				{ file: 'app/Helper.hx', source: HELPER }
			]).length
		);
	}

	/** Two statements binding the name are each other's reason, so neither is flagged by this arm. */
	public function testSecondOwnBinderKeepsBoth(): Void {
		Assert.equals(
			0, violations([
				{
					file: 'app/C.hx',
					source: 'package app;\n\nimport app.Helper;\nimport app.Helper;\n\nclass C {\n\n\tvar h:Helper;\n\n}\n'
				},
				{ file: 'app/Helper.hx', source: HELPER }
			]).length
		);
	}

	/** A `using` of the same module is a second own statement binding the name, so the import is not this arm's to judge. */
	public function testImportBesideAUsingOfTheSameModuleIsKept(): Void {
		Assert.equals(
			0, violations([
				{ file: 'app/C.hx', source: 'package app;\n\nimport app.Tools;\n\nusing app.Tools;\n\nclass C {\n\n\tvar t:Tools;\n\n}\n' },
				{
					file: 'app/Tools.hx',
					source: 'package app;\n\nclass Tools {\n\n\tpublic static function twice(v:Int):Int {\n\t\treturn v * 2;\n\t}\n\n}\n'
				}
			]).length
		);
	}

	/** `StdTypes` binds `Float` ahead of every package, so an own-package `Float` needs its import; `Lambda` is not one of its names. */
	public function testAStdTypesNameKeepsItsImport(): Void {
		final vs: Array<Violation> = violations([
			{
				file: 'app/C.hx',
				source: 'package app;\n\nimport app.Float;\nimport app.Lambda;\n\nclass C {\n\n\tvar f:Float;\n\n\tvar l:Lambda;\n\n}\n'
			},
			{ file: 'app/Float.hx', source: 'package app;\n\nclass Float {}\n' },
			{ file: 'app/Lambda.hx', source: 'package app;\n\nclass Lambda {}\n' }
		]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs.length == 1 && vs[0].message.contains('\'app.Lambda\''), vs.length == 1 ? vs[0].message : '');
	}

	// --- on disk ---

	/** A nearer ambient source binding the name to another type is what the name means once the module's own import goes. */
	public function testAnAmbientBindingOfAnotherTypeKeepsTheImport(): Void {
		Assert.equals('', onDisk([
			{ name: 'src/app/Helper.hx', source: HELPER },
			{ name: 'src/w/Helper.hx', source: 'package w;\n\nclass Helper {}\n' },
			{ name: 'src/app/sub/import.hx', source: 'import w.Helper;\n' },
			{ name: 'src/app/sub/C.hx', source: 'package app.sub;\n\nimport app.Helper;\n\nclass C {\n\n\tvar h:Helper;\n\n}\n' }
		], ['src/app/Helper.hx', 'src/w/Helper.hx', 'src/app/sub/C.hx']));
	}

	/** A run that did not index a nearer same-named module on disk cannot tell what the name binds without the statement. */
	@:pin('control') @:killer('M-KEPTWITHOUT-NO-DISK')
	public function testUnindexedNearerModuleOnDiskKeepsIt(): Void {
		Assert.equals('', onDisk([
			{ name: 'src/app/Helper.hx', source: HELPER },
			{ name: 'src/app/sub/Helper.hx', source: 'package app.sub;\n\nclass Helper {}\n' },
			{ name: 'src/app/sub/C.hx', source: 'package app.sub;\n\nimport app.Helper;\n\nclass C {\n\n\tvar h:Helper;\n\n}\n' }
		], ['src/app/Helper.hx', 'src/app/sub/C.hx']));
	}

	/** An ambient source importing the module already binds the sub-type the module spells again. */
	public function testAmbientModuleImportMakesTheSubTypeImportRedundant(): Void {
		final found: String = onDisk([
			{ name: 'src/lib/import.hx', source: 'import a.Mod;\n' },
			{ name: 'src/a/Mod.hx', source: 'package a;\n\nclass Mod {}\n\nclass Sub {}\n' },
			{ name: 'src/lib/C.hx', source: 'package lib;\n\nimport a.Mod.Sub;\n\nclass C {\n\n\tvar s:Sub;\n\n}\n' }
		], ['src/a/Mod.hx', 'src/lib/C.hx']);
		#if (sys || nodejs)
		Assert.isTrue(found.contains('src/lib/C.hx') && found.contains('import.hx\' imports them'), found);
		#else
		Assert.equals('', found);
		#end
	}

	// --- helpers ---

	private static function violations(files: Array<{ file: String, source: String }>): Array<Violation> {
		return CheckFixture.violationsIn(new RedundantImport(), files);
	}

	/** The findings over `tree` written to disk with only `analysed` in the run, as `<file>: <message>` lines. */
	private static function onDisk(tree: Array<{ name: String, source: String }>, analysed: Array<String>): String {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_redundant_visible', tree);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final files: Array<{ file: String, source: String }> = [
				for (name in analysed) { file: '$root/$name', source: sys.io.File.getContent('$root/$name') }
			];
			out = [
				for (v in CheckFixture.violationsIn(new RedundantImport(), files)) '${v.file.substr(root.length + 1)}: ${v.message}'
			].join('\n');
		});
		return out;
		#else
		return '';
		#end
	}

}
