package unit.check.common.unused;

import anyparse.check.Check;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.common.unused.UnusedType;
import haxe.io.Path;
import sys.io.File;

/**
 * The `unused-type` check: a type declaration whose name occurs nowhere in scope outside its own declaration and whose
 * removal `SafeDeleteType` proves safe. Report-only, `DefaultOff`.
 */
@:nullSafety(Strict)
class UnusedTypeCheckTest extends Test {

	/** The check's id, asserted on every finding. */
	private static inline final RULE: String = 'unused-type';

	public function testUnreferencedClassFlagged(): Void {
		final vs: Array<Violation> = violationsOf([{ file: 'Orphan.hx', source: 'class Orphan {}' }]);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(RULE, vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('unused type Orphan: no reference to it anywhere in scope', vs[0].message);
	}

	public function testUnreferencedEnumAndTypedefFlagged(): Void {
		Assert.equals(1, violationsOf([{ file: 'Mood.hx', source: 'enum Mood {\n\tHappy;\n}' }]).length);
		Assert.equals(1, violationsOf([{ file: 'Shape.hx', source: 'typedef Shape = {\n\tfinal x: Int;\n}' }]).length);
		Assert.equals(1, violationsOf([{ file: 'IFoo.hx', source: 'interface IFoo {}' }]).length);
		Assert.equals(1, violationsOf([{ file: 'Ab.hx', source: 'abstract Ab(Int) {}' }]).length);
	}

	public function testTypeNamedInAnotherFileNotFlagged(): Void {
		final user: String = 'class User {\n\tpublic static function f(): Orphan return new Orphan();\n}';
		Assert.equals(
			0,
			violationsOf([
				{ file: 'Orphan.hx', source: 'class Orphan {}' },
				{ file: 'User.hx', source: user }
			]).filter(v -> v.file == 'Orphan.hx').length
		);
	}

	public function testTypeNamedInAStringNotFlagged(): Void {
		final user: String = 'class User {\n\tpublic static function f(): Dynamic return Type.resolveClass("Orphan");\n}';
		Assert.equals(
			0,
			violationsOf([
				{ file: 'Orphan.hx', source: 'class Orphan {}' },
				{ file: 'User.hx', source: user }
			]).filter(v -> v.file == 'Orphan.hx').length
		);
	}

	@:pin('control')
	@:killer('M-UNUSED-TYPE-ENTRY-POINT')
	public function testClassHoldingTheEntryFunctionNotFlagged(): Void {
		Assert.equals(
			0,
			violationsOf([
				{ file: 'App.hx', source: 'class App {\n\tpublic static function main(): Void {}\n}' }
			]).length
		);
	}

	@:pin('control')
	@:killer('M-UNUSED-TYPE-FRAMEWORK-REACH')
	public function testTestClassItsFrameworkDrivesNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'Test.hx', source: 'class Test {}' },
			{ file: 'CTest.hx', source: 'class CTest extends Test {\n\tpublic function testX(): Void {}\n}' }
		];
		Assert.equals(0, violationsOf(files).filter(v -> v.file == 'CTest.hx').length);
	}

	@:pin('control')
	@:killer('M-UNUSED-TYPE-NO-WHOLE-SCOPE-PROOF')
	public function testEnumWhoseConstructorIsSpelledBareNotFlagged(): Void {
		final user: String = 'class User {\n\tpublic static function f(): Int {\n\t\tfinal c = Happy;\n\t\treturn 1;\n\t}\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'Mood.hx', source: 'enum Mood {\n\tHappy;\n}' },
			{ file: 'User.hx', source: user }
		];
		Assert.equals(0, violationsOf(files).filter(v -> v.file == 'Mood.hx').length);
	}

	public function testKeepExternAndBuildTypesNotFlagged(): Void {
		Assert.equals(0, violationsOf([{ file: 'K.hx', source: '@:keep class K {}' }]).length);
		Assert.equals(0, violationsOf([{ file: 'E.hx', source: 'extern class E {}' }]).length);
		Assert.equals(0, violationsOf([{ file: 'B.hx', source: '@:build(Macros.go()) class B {}' }]).length);
	}

	public function testDefaultOffSuppressedAndOptInEnabled(): Void {
		final files: Array<{ file: String, source: String }> = [{ file: 'Orphan.hx', source: 'class Orphan {}' }];
		Assert.equals(0, runGated(files, '{}', true).length);
		Assert.equals(1, runGated(files, '{"rules":{"unused-type":{"enabled":true}}}', true).length);
		Assert.equals(1, runGated(files, '{}', false).length);
	}

	@:pin('control')
	@:killer('M-UNUSED-TYPE-BUILD-NAMED')
	public function testTypesAnHxmlNamesWithNoWrittenReferenceNotFlagged(): Void {
		final init: String = 'class Init {\n\tpublic static function run(): Void {\n\t\tSys.println(\'x\');\n\t}\n}';
		final entry: String = 'class Entry {\n\tpublic function new() {}\n}';
		final packaged: String = 'package pkg;\n\nclass Packaged {}';
		final trees: ConfigTrees = new ConfigTrees('unused-type-build');
		final dir: String = trees.make('names');
		final pkgDir: String = Path.join([dir, 'pkg']);
		sys.FileSystem.createDirectory(pkgDir);
		File.saveContent(Path.join([dir, 'apq.json']), '{}');
		File.saveContent(Path.join([dir, 'build.hxml']), '-cp .\n-main Entry\n--macro Init.run()\n--macro include(\'pkg\')\n');
		final files: Array<{ file: String, source: String }> = [
			{ file: Path.join([dir, 'Init.hx']), source: init },
			{ file: Path.join([dir, 'Entry.hx']), source: entry },
			{ file: Path.join([pkgDir, 'Packaged.hx']), source: packaged }
		];
		final named: Int = violationsOf(files).length;
		File.saveContent(Path.join([dir, 'build.hxml']), '-cp .\n');
		final unnamed: Int = violationsOf(files).length;
		trees.removeAll();
		Assert.equals(0, named);
		Assert.equals(3, unnamed);
	}

	@:pin('control')
	@:killer('M-UNUSED-TYPE-BUILD-ROOT-ONLY')
	public function testAnHxmlOutsideTheProjectRootIsNotRead(): Void {
		final trees: ConfigTrees = new ConfigTrees('unused-type-build');
		final project: String = trees.make('project');
		final outside: String = trees.make('outside');
		File.saveContent(Path.join([project, 'apq.json']), '{}');
		File.saveContent(Path.join([outside, 'build.hxml']), '-cp .\n-main Orphan\n');
		final files: Array<{ file: String, source: String }> = [{ file: Path.join([project, 'Orphan.hx']), source: 'class Orphan {}' }];
		final previous: String = Sys.getCwd();
		Sys.setCwd(outside);
		final found: Int = try {
			violationsOf(files).length;
		} catch (exception: haxe.Exception) {
			Sys.setCwd(previous);
			throw exception;
		};
		Sys.setCwd(previous);
		trees.removeAll();
		Assert.equals(1, found);
	}

	private function violationsOf(files: Array<{ file: String, source: String }>): Array<Violation> {
		final check: Null<Check> = Linter.byId(RULE);
		return check == null ? [] : CheckFixture.violationsIn(check, files);
	}

	private function runGated(files: Array<{ file: String, source: String }>, json: String, applyEnablement: Bool): Array<Violation> {
		function resolver(file: String): LintConfig return LintConfig.parse(json);
		return Linter.run(files, new HaxeQueryPlugin(), [new UnusedType()], resolver, applyEnablement);
	}

}
