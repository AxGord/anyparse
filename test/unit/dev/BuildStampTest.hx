package unit.dev;

import anyparse.check.haxe.oracle.OracleCache;
import dev.Binaries;
import devkit.Cmd.cmd;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `BuildStamp` through `Binaries.compileBuilds`: a build line green on a tree's content as it stands is not run again while
 * that content and the binaries it left are unchanged, and runs again the moment either moves.
 */
@:nullSafety(Strict)
final class BuildStampTest extends Test {

	private static final HXML: String = 'test-js.hxml';

	@:pin('control')
	@:killer('M-BUILD-STAMP-NEVER-HELD')
	public function testASecondBuildOfTheSameContentTakesTheBinaries(): Void {
		TempDir.with(dir -> {
			final tree: Null<String> = project(dir);
			if (tree == null) return;
			Assert.isFalse(held(tree, dir.file('first.log')), 'the first build compiles');
			final built: String = File.getContent(Path.join([tree, 'bin/test.js']));
			Assert.isTrue(held(tree, dir.file('second.log')), 'the second takes the binary of the first');
			Assert.equals(built, File.getContent(Path.join([tree, 'bin/test.js'])));
			Assert.isFalse(held(tree, dir.file('other.log'), ['other.hxml']), 'a line that is none of the three always runs');
		});
	}

	@:pin('control')
	@:killer('M-BUILD-STAMP-CONTENT-BLIND')
	public function testAnUntrackedFileThatIsNoSourceBuildsAgain(): Void {
		TempDir.with(dir -> {
			final tree: Null<String> = project(dir);
			if (tree == null) return;
			Assert.isFalse(held(tree, dir.file('first.log')));
			File.saveContent(Path.join([tree, 'table.json']), '{}');
			Assert.isFalse(held(tree, dir.file('moved.log')), 'a file a macro could read is content');
			Assert.isTrue(held(tree, dir.file('again.log')));
		});
	}

	@:pin('control')
	@:killer('M-BUILD-STAMP-BINARIES-BLIND')
	public function testABinaryWrittenOverBuildsAgain(): Void {
		TempDir.with(dir -> {
			final tree: Null<String> = project(dir);
			if (tree == null) return;
			Assert.isFalse(held(tree, dir.file('first.log')));
			File.saveContent(Path.join([tree, 'bin/test.js']), '// another build\n');
			Assert.isFalse(held(tree, dir.file('over.log')), 'the binary is no longer the stamped one');
			Assert.stringContains('Good.main', File.getContent(Path.join([tree, 'bin/test.js'])), 'the build wrote it again');
		});
	}

	public function testATreeOutsideGitAlwaysBuilds(): Void {
		TempDir.with(dir -> {
			final tree: Null<String> = project(dir, false);
			if (tree == null) return;
			Assert.isFalse(held(tree, dir.file('first.log')));
			Assert.isFalse(held(tree, dir.file('second.log')), 'with no git there is no content to stamp');
		});
	}

	@:pin('control')
	@:killer('M-BUILD-STAMP-RED-STAMPED')
	public function testARedBuildLeavesNoMarkerSoTheSameContentFailsAgain(): Void {
		TempDir.with(dir -> {
			final tree: Null<String> = project(dir);
			if (tree == null) return;
			File.saveContent(Path.join([tree, 'Good.hx']), 'class Good {\n\tstatic function main() {\n\t\tvar x: Int = "no";\n\t}\n}\n');
			for (name in ['red.log', 'again.log']) {
				final log: String = dir.file(name);
				Assert.isTrue(Binaries.compileBuilds(tree, log, [[HXML]], Unpooled).match(Failed(_)), '$name: a red build fails');
				Assert.isFalse(File.getContent(log).contains(Binaries.CURRENT), '$name: nothing stamped a red build');
			}
		});
	}

	@:pin('control')
	@:killer('M-BUILD-STAMP-MOVED-CONTENT-STAMPED')
	public function testContentThatMovedDuringTheCompileLeavesNoMarker(): Void {
		TempDir.with(dir -> {
			final tree: Null<String> = project(dir);
			if (tree == null) return;
			File.saveContent(Path.join([tree, HXML]), '-cp .\n-main Good\n-js bin/test.js\n--cmd touch moved.txt\n');
			Assert.isFalse(held(tree, dir.file('moving.log')), 'the first build compiles, and its command writes a file');
			FileSystem.deleteFile(Path.join([tree, 'moved.txt']));
			Assert.isFalse(held(tree, dir.file('back.log')), 'the content the compile started on was not the one it ended on');
		});
	}

	@:pin('control')
	@:killer('M-BUILD-STAMP-TYPECHECK-NEVER-HELD')
	public function testATypecheckGreenOnTheSameContentIsHeld(): Void {
		TempDir.with(dir -> {
			final tree: Null<String> = project(dir);
			if (tree == null) return;
			Assert.isFalse(held(tree, dir.file('first.log'), [HXML, '--no-output']), 'the first typecheck runs');
			Assert.isTrue(held(tree, dir.file('second.log'), [HXML, '--no-output']), 'the second is the first one\'s green');
		});
	}

	@:pin('control')
	@:killer('M-BUILD-STAMP-SPELLING-BLIND')
	public function testABuildThroughASymlinkedSpellingIsTakenAtTheRealOne(): Void {
		TempDir.with(dir -> {
			final tree: Null<String> = project(dir);
			if (tree == null) return;
			final link: String = dir.file('link');
			js.node.Fs.symlinkSync(tree, link);
			Assert.isFalse(held(link, dir.file('first.log')), 'the first build compiles');
			Assert.isTrue(held(tree, dir.file('second.log')), 'the real spelling takes the build of the symlinked one');
			Assert.isTrue(held(link, dir.file('third.log')), 'and the other way round');
			File.saveContent(Path.join([tree, 'Good.hx']), 'class Good {\n\tstatic function main() {\n\t\ttrace(2);\n\t}\n}\n');
			Assert.isFalse(held(tree, dir.file('moved.log')), 'a content change compiles again');
		});
	}

	/** A build the stamp takes holds no thread: the caller is told the threads of the builds that ran, none when none did. */
	@:pin('control')
	@:killer('M-BINARIES-HELD-NAMES-ALL-BUILDS')
	public function testTheThreadsReportedAreThoseOfTheBuildsThatRan(): Void {
		TempDir.with(dir -> {
			final tree: Null<String> = project(dir);
			if (tree == null) return;
			final reported: Array<Null<Int>> = [];
			for (name in ['first.log', 'second.log'])
				Assert.isTrue(Binaries.compileBuilds(tree, dir.file(name), [[HXML]], Held(4), reported.push.bind(_)).match(Passed));
			Assert.same([4, null], reported, 'the compile held the lease, the stamped build held nothing');
		});
	}

	/**
	 * Build `words` in `tree` and answer whether the stamp took it instead; a failed build fails the test. The log names a line
	 * taken from the stamp with `Binaries.CURRENT`.
	 */
	private static function held(tree: String, log: String, ?words: Array<String>): Bool {
		Assert.isTrue(Binaries.compileBuilds(tree, log, [words ?? [HXML]], Unpooled).match(Passed), File.getContent(log));
		return File.getContent(log).contains(Binaries.CURRENT);
	}

	/**
	 * A project whose `test-js.hxml` writes the ignored `bin/test.js`, in a git tree of its own unless `git` is false; null
	 * when the host has no compiler probe to fingerprint it with.
	 */
	private static function project(dir: TempDir, git: Bool = true): Null<String> {
		final tree: String = dir.file('tree');
		FileSystem.createDirectory(Path.join([tree, 'bin']));
		File.saveContent(Path.join([tree, 'Good.hx']), 'class Good {\n\tstatic function main() {\n\t\ttrace(1);\n\t}\n}\n');
		File.saveContent(Path.join([tree, HXML]), '-cp .\n-main Good\n-js bin/test.js\n');
		File.saveContent(Path.join([tree, 'other.hxml']), '-cp .\n-main Good\n-js bin/other.js\n');
		File.saveContent(Path.join([tree, '.gitignore']), 'bin/*.js\n');
		if (git) cmd('git -C $tree init -q').run().check();
		if (OracleCache.fingerprint(HXML, tree) != null) return tree;
		Assert.pass('no compiler probe on this host');
		return null;
	}

}
