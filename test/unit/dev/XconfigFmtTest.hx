package unit.dev;

import dev.GateTree;
import dev.XconfigFmt;
import devkit.Command;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * `dev.XconfigFmt`: the scratch tree a cross-config run formats, the one-pass set read off its standard error, and the
 * verdict against the filed set. The engine is faked by a command printing what `fmt --list --one-pass` prints.
 */
@:nullSafety(Strict)
final class XconfigFmtTest extends Test {

	private static inline final SUMMARY: String = 'apq fmt --list: 0 of 2 file(s) would be rewritten';

	public function testTheOnePassSetIsTheFilesUnderTheScratchRootSorted(): Void {
		final err: String = [
			'apq fmt: /w/xconfig/src/b/B.hx: the writer needed 2 rewrites to reach its fixed point',
			'apq fmt: /w/xconfig/src/a/A.hx: the writer needed 2 rewrites to reach its fixed point',
			'apq fmt: /elsewhere/C.hx: the writer needed 2 rewrites to reach its fixed point',
			'apq fmt --list: 3 of 9 file(s) would be rewritten'
		].join('\n');
		Assert.same(['src/a/A.hx', 'src/b/B.hx'], XconfigFmt.onePassSet(err, '/w/xconfig'));
	}

	public function testTheSetMovesNameEveryFileGoneAndJoined(): Void {
		Assert.same([], XconfigFmt.setMoves(['a', 'b'], ['a', 'b']));
		Assert.same(['- a', '+ c'], XconfigFmt.setMoves(['a', 'b'], ['b', 'c']));
	}

	public function testOnlyTheHxFilesUnderTheFormattedScopeAreCrossChecked(): Void {
		Assert.same(
			['src/A.hx', 'test/B.hx', 'tools/src/C.hx'],
			XconfigFmt.hxFilesOf(['src/A.hx', 'test/B.hx', 'tools/src/C.hx', 'docs/D.hx', 'src/E.md', 'bin/F.hx'])
		);
		Assert.same([], XconfigFmt.hxFilesOf(['docs/testing.md', 'bin/G.hx']));
	}

	/** The run formats exactly the files asked for, at their relative paths beside the vendored config, and nothing else. */
	public function testTheScratchTreeHoldsOnlyTheFilesAskedFor(): Void {
		TempDir.with(dir -> {
			final repo: String = fixtureRepo(dir, ['src/a/A.hx', 'src/a/Other.hx', 'tools/src/B.hx']);
			final root: String = dir.file('scratch');
			var seen: Array<String> = [];
			final run: XconfigRun = XconfigFmt.xconfigRun(args -> {
				seen = args;
				return printing(SUMMARY);
			}, repo, root, ['src/a/A.hx', 'tools/src/B.hx']);
			Assert.same(['fmt', '--list', '--one-pass', '$root/src/a/A.hx', '$root/tools/src/B.hx'], seen);
			Assert.isTrue(FileSystem.exists('$root/hxformat.json'), 'the vendored config sits at the root');
			Assert.isTrue(FileSystem.exists('$root/src/a/A.hx') && FileSystem.exists('$root/tools/src/B.hx'));
			Assert.isFalse(FileSystem.exists('$root/src/a/Other.hx'), 'an untouched sibling is not formatted');
			Assert.isTrue(run.finished);
			Assert.same([], run.onePass);
		});
	}

	/** A touched file the writer settles in one pass under the cross-config passes. */
	public function testAConvergingFilePasses(): Void {
		TempDir.with(dir -> {
			final run: XconfigRun = ranOver(dir, ['src/a/A.hx'], []);
			Assert.isNull(XconfigFmt.xconfigVerdict(run, [], []));
		});
	}

	/** A file needing two rewrites only under the cross-config, and not filed, is `+`: the writer is the defect. */
	public function testAFileNeedingTwoRewritesThatIsNotFiledFailsAsAJoin(): Void {
		TempDir.with(dir -> {
			final run: XconfigRun = ranOver(dir, ['src/a/A.hx'], ['src/a/A.hx']);
			Assert.same(['src/a/A.hx'], run.onePass);
			final failure: Null<XconfigFailure> = XconfigFmt.xconfigVerdict(run, [], []);
			Assert.notNull(failure);
			Assert.stringContains('fix the writer', failure?.line ?? '');
			Assert.stringContains('XCONFIG_ONE_PASS', failure?.line ?? '');
			final detail: Array<String> = failure?.detail ?? [];
			Assert.contains('+ src/a/A.hx', detail);
			Assert.isTrue(detail.exists(line -> line.indexOf('decisions line') >= 0), 'the detail spells the remedy out');
		});
	}

	/** A filed file that now settles is `-`: the filed set has to shrink. */
	public function testAFiledFileThatNowSettlesFailsAsALeave(): Void {
		TempDir.with(dir -> {
			final run: XconfigRun = ranOver(dir, ['src/a/A.hx'], []);
			final failure: Null<XconfigFailure> = XconfigFmt.xconfigVerdict(run, ['src/a/A.hx'], []);
			Assert.notNull(failure);
			Assert.stringContains('remove from XCONFIG_ONE_PASS', failure?.line ?? '');
			Assert.contains('- src/a/A.hx', failure?.detail ?? []);
		});
	}

	/** A run cut short before its summary line proves nothing, whatever set it printed. */
	public function testARunWithoutItsSummaryLineFails(): Void {
		TempDir.with(dir -> {
			final repo: String = fixtureRepo(dir, ['src/a/A.hx']);
			final run: XconfigRun = XconfigFmt.xconfigRun(_ -> printing(''), repo, dir.file('scratch'), ['src/a/A.hx']);
			Assert.isFalse(run.finished);
			Assert.notNull(XconfigFmt.xconfigVerdict(run, [], []));
		});
	}

	/**
	 * A row quotes the failure line clipped: the half and its remedy survive it at any file count, and a run failing both halves
	 * still names both.
	 */
	public function testTheFailureLineKeepsBothHalvesAndTheirRemediesWhenClipped(): Void {
		TempDir.with(dir -> {
			final long: String = 'src/anyparse/check/common/design/threads/SomeVeryLongRuleNameForTheCensus';
			final joined: Array<String> = [for (i in 0...4) '$long$i.hx'];
			final filed: Array<String> = [for (i in 0...3) 'tools/src/dev/devkit/AnotherLongNamedFiledFileNumber$i.hx'];
			final both: XconfigRun = { shown: [], finished: true, onePass: joined };
			final failure: Null<XconfigFailure> = XconfigFmt.xconfigVerdict(both, filed, []);
			Assert.notNull(failure);
			final quoted: String = GateTree.clip(failure?.line ?? '');
			Assert.stringContains('fix the writer', quoted);
			Assert.stringContains('XCONFIG_ONE_PASS', quoted);
			Assert.stringContains('+4', quoted);
			Assert.stringContains('-3', quoted);
			Assert.stringContains('remove from XCONFIG_ONE_PASS', quoted);
			Assert.equals(joined.length + filed.length + 2, (failure?.detail ?? []).length, 'every move, one remedy per half');
		});
	}

	/** The filed files that are no longer in the tree are named, whatever was touched. */
	public function testAFiledFileGoneFromTheTreeIsMissing(): Void {
		TempDir.with(dir -> {
			final repo: String = fixtureRepo(dir, XconfigFmt.XCONFIG_ONE_PASS.slice(1));
			Assert.same(XconfigFmt.XCONFIG_ONE_PASS.slice(0, 1), XconfigFmt.missingFiled(repo));
			Assert.same([], XconfigFmt.missingFiled(fixtureRepo(dir, XconfigFmt.XCONFIG_ONE_PASS)));
		});
	}

	/** No touched `.hx` and nothing gone: the half is skipped, and the engine is not even asked. */
	public function testNoTouchedHxFileSkipsTheCrossConfigHalf(): Void {
		TempDir.with(dir -> {
			final repo: String = fixtureRepo(dir, XconfigFmt.XCONFIG_ONE_PASS);
			var asked: Bool = false;
			final stand: XconfigStand = XconfigFmt.touchedStand(_ -> {
				asked = true;
				return printing(SUMMARY);
			}, repo, ['docs/testing.md', 'bin/G.hx'], dir.file('scratch'));
			Assert.isTrue(stand.match(Skipped));
			Assert.isFalse(asked);
		});
	}

	/** A touched file that settles holds; a filed file nobody touched is not compared, so it is never a `-`. */
	public function testAnUntouchedFiledFileIsNotCompared(): Void {
		TempDir.with(dir -> {
			final repo: String = fixtureRepo(dir, ['src/a/A.hx'].concat(XconfigFmt.XCONFIG_ONE_PASS));
			final stand: XconfigStand = XconfigFmt.touchedStand(_ -> printing(SUMMARY), repo, ['src/a/A.hx'], dir.file('scratch'));
			Assert.isTrue(stand.match(Holds), '$stand');
		});
	}

	/** A touched file that is filed and now settles is a `-`, and a touched file joining the set is a `+`. */
	public function testATouchedFiledFileThatSettlesBreaksTheStand(): Void {
		TempDir.with(dir -> {
			final filed: String = XconfigFmt.XCONFIG_ONE_PASS[0];
			final repo: String = fixtureRepo(dir, ['src/a/A.hx'].concat(XconfigFmt.XCONFIG_ONE_PASS));
			switch XconfigFmt.touchedStand(_ -> printing(SUMMARY), repo, [filed], dir.file('scratch')) {
				case Breaks(failure):
					Assert.contains('- $filed', failure.detail);
				case other:
					Assert.fail('expected Breaks, got $other');
			}
			final root: String = dir.file('scratch2');
			final joining: String = 'apq fmt: $root/src/a/A.hx: the writer needed 2 rewrites to reach its fixed point\n$SUMMARY';
			switch XconfigFmt.touchedStand(_ -> printing(joining), repo, ['src/a/A.hx'], root) {
				case Breaks(failure):
					Assert.contains('+ src/a/A.hx', failure.detail);
				case other:
					Assert.fail('expected Breaks, got $other');
			}
		});
	}

	/** A slice that deletes a filed file fails with nothing else touched: the battery would read it as a file that settled. */
	public function testADeletedFiledFileBreaksTheStandWithNothingElseTouched(): Void {
		TempDir.with(dir -> {
			final repo: String = fixtureRepo(dir, XconfigFmt.XCONFIG_ONE_PASS.slice(1));
			final gone: String = XconfigFmt.XCONFIG_ONE_PASS[0];
			switch XconfigFmt.touchedStand(_ -> printing(SUMMARY), repo, [], dir.file('scratch')) {
				case Breaks(failure):
					Assert.contains('- $gone (gone from the tree)', failure.detail);
					Assert.stringContains('remove from XCONFIG_ONE_PASS', failure.line);
				case other:
					Assert.fail('expected Breaks, got $other');
			}
		});
	}

	/** A repo holding the vendored config and `files`, each a stub. */
	private static function fixtureRepo(dir: TempDir, files: Array<String>): String {
		final repo: String = dir.file('repo');
		for (file in files.concat([XconfigFmt.XCONFIG])) {
			FileSystem.createDirectory(Path.directory('$repo/$file'));
			File.saveContent('$repo/$file', 'x');
		}
		return repo;
	}

	/** The run over `files` whose fake engine reports the `settling` ones as needing a second rewrite. */
	private static function ranOver(dir: TempDir, files: Array<String>, settling: Array<String>): XconfigRun {
		final repo: String = fixtureRepo(dir, files);
		final root: String = dir.file('scratch');
		final lines: Array<String> = [
			for (file in settling) 'apq fmt: $root/$file: the writer needed 2 rewrites to reach its fixed point'
		];
		return XconfigFmt.xconfigRun(_ -> printing(lines.concat([SUMMARY]).join('\n')), repo, root, files);
	}

	/** A command that prints `text` on its standard error. */
	private static function printing(text: String): Command {
		return Command.of(['sh', '-c', 'printf "%s\\n" "$$1" >&2', 'sh', text]);
	}

}
