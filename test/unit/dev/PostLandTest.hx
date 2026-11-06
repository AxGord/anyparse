package unit.dev;

import dev.PostLand;
import devkit.Summary.Outcome;
import devkit.TempDir;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/** `dev post-land`: the records a whole-suite run leaves, what a land does with them, and the command line of the run. */
final class PostLandTest extends Test {

	public function testACacheWithNoRecordRefusesNothing(): Void {
		TempDir.with(dir -> {
			Assert.isNull(PostLand.refusal(dir.path));
			Assert.same(['post-land: no record'], PostLand.statusLines(dir.path));
		});
	}

	@:pin('control')
	@:killer('M-POSTLAND-RED-RECORD-REFUSES-NOTHING')
	public function testARedRecordRefusesTheNextLandNamingTheCommitAndTheWayToClearIt(): Void {
		TempDir.with(dir -> {
			record(dir, 'abc12345.red', 'suite-shard: FAILED — see log');
			final refused: Null<String> = PostLand.refusal(dir.path);
			Assert.notNull(refused);
			Assert.stringContains('abc12345', refused);
			Assert.stringContains('suite-shard: FAILED', refused);
			Assert.stringContains('post-land clear abc12345', refused);
			Assert.stringContains('then land the fix', refused);
		});
	}

	public function testARunThatHasNotEndedIsReportedAndRefusesNothing(): Void {
		TempDir.with(dir -> {
			record(dir, 'abc12345.running', 'log');
			Assert.isNull(PostLand.refusal(dir.path));
			Assert.same(['abc12345'], PostLand.running(dir.path));
			Assert.same(['running  abc12345'], PostLand.statusLines(dir.path));
		});
	}

	public function testClearingARecordLiftsTheRefusalAndNamesWhatItCleared(): Void {
		TempDir.with(dir -> {
			record(dir, 'abc12345.red', 'x');
			record(dir, 'def67890.red', 'y');
			Assert.same(['abc12345'], PostLand.clear(dir.path, ['abc12345', 'nothere']));
			Assert.same(['def67890'], PostLand.red(dir.path));
			Assert.same(['def67890'], PostLand.clear(dir.path, PostLand.red(dir.path)));
			Assert.isNull(PostLand.refusal(dir.path));
		});
	}

	public function testTheTotalsOfTheShardTranscriptAreRead(): Void {
		Assert.same(
			[9, 31],
			PostLand.countsOf(
				'x\n--- suite-shard: 3 classes / 9 tests / 31 assertions / 0 failures / 0 errors in 1.2s across 2 shards ---\n'
			)
		);
		Assert.isNull(PostLand.countsOf('dev shard: no totals'));
	}

	public function testTheRunTakesALeaseOfItsOwnThroughThePoolAndKeepsItsOwnCopyOfTheTool(): Void {
		final argv: Array<String> = PostLand.argvOf(Own('/plugin/scripts/wf-run', 8), '/cache/abc.dev.js', '/repo', 'abc', '/cache');
		Assert.equals('/plugin/scripts/wf-run', argv[0]);
		Assert.isTrue(argv.contains('--threads'), argv.join(' '));
		final at: Int = argv.indexOf('--');
		Assert.same([
			'node',
			'/cache/abc.dev.js',
			'post-land',
			'run',
			'abc',
			'--repo',
			'/repo',
			'--cache',
			'/cache'
		], argv.slice(at + 1));
		Assert.same([
			'node',
			'/cache/abc.dev.js',
			'post-land',
			'run',
			'abc',
			'--repo',
			'/repo',
			'--cache',
			'/cache'
		], PostLand.argvOf(Unpooled, '/cache/abc.dev.js', '/repo', 'abc', '/cache'));
	}

	@:pin('control')
	@:killer('M-POSTLAND-STARTS-AFTER-WHOLE-BATTERY')
	public function testOnlyALandThatRanAnImpactSuiteStartsTheWholeSuite(): Void {
		final started: Array<String> = [];
		final start: (String, String, String) -> Outcome = (tree, sha, cache) -> {
			started.push(sha);
			return Passed;
		};
		Assert.isTrue(PostLand.afterwards(start, false, '/nowhere', 'abc', '/cache', _ -> {}).match(Skipped(_)));
		Assert.isTrue(PostLand.afterwards(null, true, '/nowhere', 'abc', '/cache', _ -> {}).match(Skipped(_)));
		Assert.isTrue(PostLand.afterwards(start, true, '/nowhere', 'abc', null, _ -> {}).match(Skipped(_)));
		Assert.same([], started);
		final notes: Array<String> = [];
		Assert.isTrue(PostLand.afterwards(start, true, '/nowhere', 'abc', '/cache', notes.push).match(Passed));
		Assert.same(['abc'], started);
		Assert.equals(1, notes.length);
	}

	public function testALandWithoutABatteryIsNotRefusedByARecord(): Void {
		Assert.isTrue(PostLand.unsettled(null, _ -> {}).match(Skipped(_)));
	}

	@:pin('control')
	@:killer('M-POSTLAND-GREEN-KEEPS-LOG')
	public function testAGreenRunLeavesNothingInTheCache(): Void {
		TempDir.with(dir -> {
			leftBy(dir, 'abc12345');
			PostLand.settle(dir.path, 'abc12345', Passed);
			Assert.same([], FileSystem.readDirectory(dir.file('post-land')));
		});
	}

	@:pin('control')
	@:killer('M-POSTLAND-RED-KEEPS-SCRIPT')
	public function testARedRunKeepsItsLogAndRecordAndDropsTheCopyOfTheTool(): Void {
		TempDir.with(dir -> {
			leftBy(dir, 'abc12345');
			PostLand.settle(dir.path, 'abc12345', Failed('suite-shard: FAILED'));
			final left: Array<String> = FileSystem.readDirectory(dir.file('post-land'));
			left.sort(Reflect.compare);
			Assert.same(['abc12345.log', 'abc12345.red'], left);
			Assert.stringContains('abc12345.log', File.getContent(dir.file('post-land/abc12345.red')));
			Assert.same(['abc12345'], PostLand.red(dir.path));
		});
	}

	private static function record(dir: TempDir, name: String, content: String): Void {
		final folder: String = dir.file('post-land');
		if (!FileSystem.exists(folder)) FileSystem.createDirectory(folder);
		File.saveContent('$folder/$name', '$content\n');
	}

	private static function leftBy(dir: TempDir, sha: String): Void {
		record(dir, '$sha.running', 'log');
		record(dir, '$sha.dev.js', 'tool');
		record(dir, '$sha.log', 'output');
	}

}
