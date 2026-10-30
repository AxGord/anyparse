package unit.cli;

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

}
