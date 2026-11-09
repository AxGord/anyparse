package unit.cli;

import unit.cli.CliFixture.CliRun;
#if nodejs
import sys.io.File;
#end

using Lambda;
using StringTools;

/**
 * `apq changed <base> <path>...` answers what the no-path run answers for those paths, however many are named, and a
 * path that names no changed file is reported rather than dropped into a clean `0 file(s)`.
 */
@:nullSafety(Strict)
class ChangedCommandPathsTest extends Test {

	private static inline final COUNT: Int = 520;

	@:pin('guard')
	public function testNPathsAnswerTheNoPathRunFilteredByThem(): Void {
		#if nodejs
		final names: Array<String> = [for (i in 0...COUNT) 'src/f${pad(i)}.hx'];
		final root: String = CliFixture.writeTree('apq_changed_paths', names.map(n -> {name: n, source: 'class C${n.substr(5, 4)} {}\n' }));
		CliFixture.git(root, ['init', '-q']);
		CliFixture.git(root, ['add', '-A']);
		CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base']);
		for (n in names) File.saveContent('$root/$n', 'class C${n.substr(5, 4)} {\n\tvar x: Int;\n}\n');
		final all: CliRun = CliFixture.runIn(root, ['changed', 'HEAD']);
		final counts: Array<Int> = [1, 20, 500];
		final answers: Array<CliRun> = counts.map(n -> CliFixture.runIn(root, ['changed', 'HEAD'].concat(names.slice(0, n))));
		CliFixture.removeDir(root);
		Assert.isTrue(all.out.indexOf('$COUNT file(s)') >= 0, all.out);
		for (i => n in counts) {
			Assert.isTrue(answers[i].out.indexOf('changed against HEAD: $n file(s)') == 0, answers[i].out);
			Assert.equals(rowsOf(all.out, names.slice(0, n)), rowsOf(answers[i].out, names.slice(0, n)));
		}
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-CHANGED-UNMATCHED-SILENT')
	public function testAPathThatMatchesNothingIsReported(): Void {
		#if nodejs
		final root: String = CliFixture.writeTree('apq_changed_unmatched', [
			{ name: 'A.hx', source: 'class A {}\n' },
			{ name: 'B.hx', source: 'class B {}\n' }
		]);
		CliFixture.git(root, ['init', '-q']);
		CliFixture.git(root, ['add', '-A']);
		CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base']);
		File.saveContent('$root/A.hx', 'class A {\n\tvar x: Int;\n}\n');
		final runs: Array<CliRun> = [];
		final some: String = CliFixture.captureStderr(() ->
			runs.push(CliFixture.runIn(root, ['changed', 'HEAD', 'A.hx', 'gone/Nothing.hx']))
		);
		final none: String = CliFixture.captureStderr(() ->
			runs.push(CliFixture.runIn(root, ['changed', 'HEAD', 'gone/Nothing.hx', 'B.hx']))
		);
		final quiet: String = CliFixture.captureStderr(() -> runs.push(CliFixture.runIn(root, ['changed', 'HEAD', 'A.hx'])));
		CliFixture.removeDir(root);
		Assert.isTrue(runs[0].out.indexOf('1 file(s)') >= 0, runs[0].out);
		Assert.isTrue(some.indexOf('1 of 2 path(s) matched no changed file') >= 0 && some.indexOf('gone/Nothing.hx') >= 0, some);
		Assert.equals(-1, some.indexOf('"A.hx"'), some);
		Assert.isTrue(none.indexOf('2 of 2 path(s) matched no changed file') >= 0, none);
		Assert.equals('', quiet);
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/**
	 * A filter git reads as a pathspec (glob, absolute or `..` spelling, exclude) is not reported while git lists files for it.
	 */
	@:pin('control')
	@:killer('M-CHANGED-UNMATCHED-UNCONFIRMED')
	public function testAPathspecGitAcceptsIsNotReported(): Void {
		#if nodejs
		final root: String = CliFixture.writeTree('apq_changed_pathspec', [
			{ name: 'src/A.hx', source: 'class A {}\n' },
			{ name: 'src/deep/B.hx', source: 'class B {}\n' }
		]);
		CliFixture.git(root, ['init', '-q']);
		CliFixture.git(root, ['add', '-A']);
		CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base']);
		File.saveContent('$root/src/A.hx', 'class A {\n\tvar x: Int;\n}\n');
		File.saveContent('$root/src/deep/B.hx', 'class B {\n\tvar x: Int;\n}\n');
		final runs: Array<CliRun> = [];
		final notes: Array<String> = [];
		function ask(dir: String, args: Array<String>): Void {
			notes.push(CliFixture.captureStderr(() -> runs.push(CliFixture.runIn(dir, ['changed', 'HEAD'].concat(args)))));
		}
		ask(root, ['*.hx']);
		ask(root, ['$root/src/A.hx']);
		ask('$root/src', ['../src/A.hx']);
		ask(root, ['src', ':!src/deep/B.hx']);
		ask(root, ['*.hx', 'nothere.hx']);
		CliFixture.removeDir(root);
		final listed: Array<String> = ['2 file(s)', '1 file(s)', '1 file(s)', '1 file(s)', '2 file(s)'];
		for (i => count in listed) Assert.isTrue(runs[i].out.indexOf(count) >= 0, runs[i].out);
		for (i in 0...4) Assert.equals('', notes[i]);
		Assert.isTrue(notes[4].indexOf('1 of 2 path(s) matched no changed file: "nothere.hx"') >= 0, notes[4]);
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/** The report rows of `out` for `paths`: its lines after the summary that begin with a status letter and one of them. */
	private static function rowsOf(out: String, paths: Array<String>): String {
		return out.split('\n')
			.slice(1)
			.filter(l -> l.length > 2 && paths.exists(p -> l.substr(2).startsWith('$p ')))
			.join('\n');
	}

	private static function pad(i: Int): String {
		return '$i'.lpad('0', 4);
	}

}
