package unit.cli;

import unit.cli.CliFixture.CliRun;
#if nodejs
import sys.io.File;
#end

/**
 * `apq changed` end to end over a scratch git repository: a member inserted, a module moved with its type renamed, a
 * text file edited — each file classed, the moved one under its base path, against the working tree and against a
 * committed tip named through a symmetric range.
 */
@:nullSafety(Strict)
class ChangedCommandCliTest extends Test {

	public function testEachFileIsClassedAgainstTheRevision(): Void {
		#if nodejs
		final root: String = CliFixture.writeTree('apq_changed', [
			{
				name: 'A.hx',
				source: 'class A {\n\tpublic function f(): Int {\n\t\treturn 1;\n\t}\n\n\tpublic function g(): Int {\n\t\treturn 2;\n'
				+ '\t}\n}\n'
			},
			{ name: 'B.hx', source: 'class B {\n\tpublic function run(): Void {}\n}\n' },
			{ name: 'notes.txt', source: 'one\ntwo\n' }
		]);
		CliFixture.git(root, ['init', '-q']);
		CliFixture.git(root, ['add', '-A']);
		CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base']);
		File.saveContent(
			'$root/A.hx',
			'class A {\n\tpublic function f(): Int {\n\t\treturn 1;\n\t}\n\n\tpublic function e(): Int {\n\t\treturn 0;\n\t}\n\n'
			+ '\tpublic function g(): Int {\n\t\treturn 2;\n\t}\n}\n'
		);
		CliFixture.git(root, ['mv', 'B.hx', 'C.hx']);
		File.saveContent('$root/C.hx', 'class C {\n\tpublic function run(): Void {}\n}\n');
		File.saveContent('$root/notes.txt', 'one\nthree\n');
		final report: String = CliFixture.inDir(root, ['changed', 'HEAD']);
		final names: String = CliFixture.inDir(root, ['changed', 'HEAD', '--names']);
		CliFixture.git(root, ['add', '-A']);
		CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'tip']);
		// `A...B` is the merge base of the two against B, the spelling a branch review uses
		final symmetric: String = CliFixture.inDir(root, ['changed', 'HEAD~1...HEAD']);
		CliFixture.removeDir(root);
		Assert.isTrue(symmetric.indexOf('M A.hx  declarations') >= 0, symmetric);
		Assert.isTrue(symmetric.indexOf('R C.hx  <- B.hx  renamed') >= 0, symmetric);
		Assert.isTrue(report.indexOf('M A.hx  declarations') >= 0, report);
		Assert.isTrue(report.indexOf('    + FnMember:e') >= 0, report);
		Assert.equals(-1, report.indexOf('FnMember:g'), report);
		Assert.isTrue(report.indexOf('R C.hx  <- B.hx  renamed') >= 0, report);
		Assert.isTrue(report.indexOf('    rename B -> C') >= 0, report);
		Assert.isTrue(report.indexOf('M notes.txt  text  +1 -1') >= 0, report);
		Assert.equals('e\n', names);
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/**
	 * `changed --diff` prints the lines of each changed declaration, the unchanged ones far from an edit elided; with
	 * `<file>#<selector>` the one declaration in full, and a selector that names no changed declaration is refused.
	 */
	public function testDiffPrintsTheLinesOfTheChangedDeclaration(): Void {
		#if nodejs
		final body: String =
			'\t\tvar a: Int = 1;\n\t\tvar b: Int = 2;\n\t\tvar c: Int = 3;\n\t\tvar d: Int = 4;\n\t\tvar e: Int = 5;\n\t\treturn a;\n';
		final edited: String = '\t\tvar a: Int = 10;\n' + body.substr(body.indexOf('\n') + 1);
		final root: String = CliFixture.writeTree('apq_changed_diff', [
			{
				name: 'A.hx',
				source: 'class A {\n\tpublic function f(): Int {\n\t\treturn 1;\n\t}\n\n\tpublic function g(): Int {\n$body\t}\n}\n'
			}
		]);
		CliFixture.git(root, ['init', '-q']);
		CliFixture.git(root, ['add', '-A']);
		CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base']);
		File.saveContent(
			'$root/A.hx', 'class A {\n\tpublic function f(): Int {\n\t\treturn 1;\n\t}\n\n\tpublic function g(): Int {\n$edited\t}\n}\n'
		);
		final all: CliRun = CliFixture.runIn(root, ['changed', 'HEAD', '--diff', 'A.hx']);
		final one: CliRun = CliFixture.runIn(root, ['changed', 'HEAD', '--diff', 'A.hx#FnMember:g']);
		final refused: Array<CliRun> = [];
		final refusal: String = CliFixture.captureStderr(() ->
			refused.push(CliFixture.runIn(root, ['changed', 'HEAD', '--diff', 'A.hx#FnMember:f']))
		);
		final plain: CliRun = CliFixture.runIn(root, ['changed', 'HEAD']);
		CliFixture.removeDir(root);
		Assert.isTrue(all.out.indexOf('    ~ FnMember:g  +1 -1\n') >= 0, all.out);
		Assert.isTrue(all.out.indexOf('        - \t\tvar a:Int = 1;\n        + \t\tvar a:Int = 10;\n') >= 0, all.out);
		Assert.isTrue(all.out.indexOf('        ...\n') >= 0, all.out);
		Assert.equals(-1, all.out.indexOf('FnMember:f'), all.out);
		Assert.isTrue(one.out.indexOf('          \tpublic function g():Int {\n') >= 0, one.out);
		Assert.isTrue(one.out.indexOf('        ...') < 0, one.out);
		Assert.isTrue(refused[0].code != 0);
		Assert.isTrue(refusal.indexOf('no changed declaration "FnMember:f"') >= 0 && refusal.indexOf('FnMember:g') >= 0, refusal);
		Assert.isTrue(plain.out.indexOf('        ') < 0, plain.out);
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/**
	 * `changed --diff <file>` reports that file alone though others changed, a file added whole lists its declarations
	 * without a row unless a selector names one, and `--diff` with `--names` is a usage failure. The process entry needs
	 * no file argument to pick the grammar.
	 */
	public function testDiffRestrictsToItsFileAndShowsAnAddedFileOnRequest(): Void {
		#if nodejs
		final root: String = CliFixture.writeTree('apq_changed_diff_files', [
			{ name: 'A.hx', source: 'class A {\n\tpublic function f(): Int {\n\t\treturn 1;\n\t}\n}\n' },
			{ name: 'B.hx', source: 'class B {\n\tpublic function run(): Int {\n\t\treturn 1;\n\t}\n}\n' }
		]);
		CliFixture.git(root, ['init', '-q']);
		CliFixture.git(root, ['add', '-A']);
		CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base']);
		File.saveContent('$root/A.hx', 'class A {\n\tpublic function f(): Int {\n\t\treturn 2;\n\t}\n}\n');
		File.saveContent('$root/B.hx', 'class B {\n\tpublic function run(): Int {\n\t\treturn 2;\n\t}\n}\n');
		File.saveContent('$root/C.hx', 'class C {\n\tpublic function run(): Void {}\n}\n');
		CliFixture.git(root, ['add', '-A']);
		final only: CliRun = CliFixture.runIn(root, ['changed', 'HEAD', '--diff', 'A.hx']);
		final widened: CliRun = CliFixture.runIn(root, ['changed', 'HEAD', '--diff', 'A.hx', 'C.hx']);
		final added: CliRun = CliFixture.runIn(root, ['changed', 'HEAD', '--diff', 'C.hx']);
		final addedOne: CliRun = CliFixture.runIn(root, ['changed', 'HEAD', '--diff', 'C.hx#C']);
		final exclusive: Array<CliRun> = [];
		final refusal: String = CliFixture.captureStderr(() ->
			exclusive.push(CliFixture.runIn(root, ['changed', 'HEAD', '--diff', 'A.hx', '--names']))
		);
		CliFixture.removeDir(root);
		Assert.isTrue(only.out.indexOf('M A.hx') >= 0, only.out);
		Assert.equals(-1, only.out.indexOf('B.hx'), only.out);
		Assert.equals(-1, only.out.indexOf('C.hx'), only.out);
		// a path beside `--diff <file>` widens the report: `--diff` adds its file to the paths
		Assert.isTrue(widened.out.indexOf('M A.hx') >= 0 && widened.out.indexOf('A C.hx') >= 0, widened.out);
		Assert.isTrue(added.out.indexOf('A C.hx  new') >= 0, added.out);
		Assert.isTrue(added.out.indexOf('line(s)') >= 0, added.out);
		Assert.equals(-1, added.out.indexOf('        + '), added.out);
		Assert.isTrue(addedOne.out.indexOf('        + class C {\n') >= 0, addedOne.out);
		Assert.equals(2, exclusive[0].code);
		Assert.isTrue(refusal.indexOf('--diff and --names are exclusive') >= 0, refusal);
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/**
	 * A JSON file is classed `values` and named by key path with the old and new value, a record inserted in the middle
	 * of an array shifts no other one, and a file only re-laid is `layout`.
	 */
	public function testAJsonFileIsNamedByKeyPath(): Void {
		#if nodejs
		final root: String = CliFixture.writeTree('apq_changed_json', [
			{ name: 'k.json', source: '{"arms": [{"name": "A", "n": 1}, {"name": "B", "n": 2}], "version": 1}\n' },
			{ name: 'm.json', source: '{"a": 1, "b": [1, 2]}\n' }
		]);
		CliFixture.git(root, ['init', '-q']);
		CliFixture.git(root, ['add', '-A']);
		CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base']);
		File.saveContent('$root/k.json', '{"arms": [{"name": "A", "n": 1}, {"name": "X", "n": 9}, {"name": "B", "n": 3}], "version": 1}\n');
		File.saveContent('$root/m.json', '{\n\t"a": 1,\n\t"b": [1, 2]\n}\n');
		final report: String = CliFixture.inDir(root, ['changed', 'HEAD']);
		final names: String = CliFixture.inDir(root, ['changed', 'HEAD', '--names']);
		CliFixture.removeDir(root);
		Assert.isTrue(report.indexOf('M k.json  values  +1 -0 ~1\n') >= 0, report);
		Assert.isTrue(report.indexOf('    + arms.1  {"name":"X","n":9}\n') >= 0, report);
		Assert.isTrue(report.indexOf('    ~ arms.2.n  2 -> 3\n') >= 0, report);
		Assert.isTrue(report.indexOf('M m.json  layout\n') >= 0, report);
		Assert.equals('', names);
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/** A data file added whole prints its top-level keys and record count under the line count, as a changed one prints its key paths. */
	public function testADataFileAddedWholeNamesItsKeys(): Void {
		#if nodejs
		final root: String = CliFixture.writeTree('apq_changed_json', [{ name: 'notes.txt', source: 'one\n' }]);
		CliFixture.git(root, ['init', '-q']);
		CliFixture.git(root, ['add', '-A']);
		CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base']);
		File.saveContent('$root/arms.json', '{"arms": [{"name": "A"}, {"name": "B"}], "version": 1}\n');
		CliFixture.git(root, ['add', '-A']);
		final report: String = CliFixture.inDir(root, ['changed', 'HEAD']);
		CliFixture.removeDir(root);
		Assert.isTrue(report.indexOf('A arms.json  new  +2 -0') >= 0, report);
		Assert.isTrue(report.indexOf('    + .  {arms[2], version}') >= 0, report);
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

}
