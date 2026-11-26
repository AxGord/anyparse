package unit.dev;

import anyparse.grammar.json.JValueParser;
import dev.LandProbeFold;
import dev.LessonsFile.Lesson;
import dev.Probe;
import dev.ProbeFold.Fold;
import devkit.Cmd.cmd;
import devkit.Summary.Outcome;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * `dev.LandProbeFold`: the land's `probe-fold` step — kit rows of a landed slice's probe additions are written and committed
 * in a commit of their own, unplaceable rows are filed through the queue sink, and whatever goes wrong skips the step with the
 * tree as it was.
 */
@:nullSafety(Strict)
final class LandProbeFoldTest extends Test {

	private static final ROW: String = '{"name":"r1","argv":["apq","echo","y"],"knownDefect":"moved"}';

	@:pin('control')
	@:killer('M-LAND-PROBE-FOLD-COMMIT-DROPPED')
	public function testAKitRowIsWrittenAndCommittedInACommitOfItsOwn(): Void {
		withRepo((repo, rows) -> {
			final notes: Array<String> = [];
			final before: String = head(repo);
			final outcome: Outcome = LandProbeFold.afterwards(rows, repo, 'S1', folds([kit('r1')]), sink([]), notes.push);
			Assert.same(Passed, outcome);
			Assert.equals('', status(repo), 'the kit row left the tree clean');
			Assert.notEquals(before, head(repo));
			Assert.stringContains('Probe-Fold: S1', message(repo));
			Assert.same(['r1'], Probe.load(Probe.kitPath(repo, 'cli')).invocations.map(row -> row.name));
			Assert.stringContains('1 kit(s), committed', notes[0]);
		});
	}

	@:pin('control')
	@:killer('M-LAND-PROBE-FOLD-QUEUE-DROPPED')
	public function testAnUnplaceableRowIsFiledThroughTheSinkAndCommitsNothing(): Void {
		withRepo((repo, rows) -> {
			final filed: Array<Lesson> = [];
			final before: String = head(repo);
			final outcome: Outcome = LandProbeFold.afterwards(
				rows, repo, 'S1', folds([{ name: 'r1', outcome: ToQueue('cannot judge') }]), sink(filed), _ -> {}
			);
			Assert.same(Passed, outcome);
			Assert.equals(before, head(repo));
			Assert.same(['PROBE-ROW-S1-1'], filed.map(lesson -> lesson.id));
			Assert.same(['cannot judge'], filed.map(lesson -> lesson.text));
		});
	}

	@:pin('control')
	@:killer('M-LAND-PROBE-FOLD-REFUSAL-SILENT')
	public function testALineTheQueueRefusedIsNamedAndNeverFailsTheStep(): Void {
		withRepo((repo, rows) -> {
			final notes: Array<String> = [];
			final outcome: Outcome = LandProbeFold.afterwards(
				rows, repo, 'S1', folds([{ name: 'r1', outcome: ToQueue('t') }]), _ -> 'duplicate id', notes.push
			);
			Assert.same(Passed, outcome);
			Assert.stringContains('row r1 not queued as PROBE-ROW-S1-1: duplicate id', notes.join('\n'));
		});
	}

	@:pin('control')
	@:killer('M-LAND-PROBE-FOLD-NO-FILE-UNSKIPPED')
	public function testASliceWithNoProbeAdditionsFileSkipsTheStep(): Void {
		withRepo((repo, _) -> {
			final absent: Outcome = LandProbeFold.afterwards(Path.join([repo, 'absent.json']), repo, 'S1', folds([]), sink([]), _ -> {});
			Assert.same(Skipped('no probe-additions.json'), absent);
			Assert.same(Skipped('no probe-additions.json'), LandProbeFold.afterwards(null, repo, 'S1', folds([]), sink([]), _ -> {}));
		});
	}

	@:pin('control')
	@:killer('M-LAND-PROBE-FOLD-CAP-OFF')
	public function testAFileOverTheRowCapIsLeftToTheHandAndRunsNothing(): Void {
		withRepo((repo, _) -> {
			final rows: Array<String> = [ for (i in 0...LandProbeFold.MAX_ROWS + 1) '{"name":"r$i","argv":["apq","echo"]}' ];
			final file: String = Path.join([repo, 'many.json']);
			File.saveContent(file, '{"area":"cli","invocations":[${rows.join(',')}]}');
			var ran: Bool = false;
			final outcome: Outcome = LandProbeFold.afterwards(file, repo, 'S1', (_, _) -> {
				ran = true;
				return [];
			}, sink([]), _ -> {});
			Assert.isFalse(ran);
			Assert.isTrue(outcome.match(Skipped(_)));
		});
	}

	@:pin('control')
	@:killer('M-LAND-PROBE-FOLD-RESTORE-DROPPED')
	public function testACommitThatFailsRestoresTheKitAndSkipsTheStep(): Void {
		withRepo((repo, rows) -> {
			final hook: String = Path.join([repo, '.git', 'hooks', 'pre-commit']);
			FileSystem.createDirectory(Path.directory(hook));
			File.saveContent(hook, '#!/bin/sh\nexit 1\n');
			cmd('chmod +x $hook').run().check();
			final before: String = head(repo);
			final kitBefore: String = File.getContent(Probe.kitPath(repo, 'cli'));
			final outcome: Outcome = LandProbeFold.afterwards(rows, repo, 'S1', folds([kit('r1')]), sink([]), _ -> {});
			Assert.isTrue(outcome.match(Skipped(_)));
			Assert.equals(before, head(repo));
			Assert.equals('', status(repo), 'the tree is as it was');
			Assert.equals(kitBefore, File.getContent(Probe.kitPath(repo, 'cli')));
		});
	}

	@:pin('control')
	@:killer('M-LAND-PROBE-FOLD-FILING-BLIND')
	public function testTheQueueSinkRefusesAQueueFileThatIsNotThere(): Void {
		withRepo((repo, _) -> {
			final lesson: Lesson = {
				slice: 'S1',
				id: 'PROBE-ROW-S1-1',
				kind: 'unverified',
				touches: [],
				repro: 'r',
				text: 't'
			};
			Assert.notNull(LandProbeFold.filing('true', Path.join([repo, 'no-queue.yaml']))(lesson));
			Assert.isNull(LandProbeFold.filing('true', Path.join([repo, 'a.txt']))(lesson));
		});
	}

	@:pin('control')
	@:killer('M-LAND-PROBE-FOLD-RESTORE-DROPPED')
	public function testAFoldThatThrowsPartwayRestoresTheKitsItAlreadyWrote(): Void {
		withRepo((repo, rows) -> {
			final before: String = head(repo);
			final missing: Fold = { name: 'r2', outcome: ToKit('absent', JValueParser.parse(ROW)) };
			final outcome: Outcome = LandProbeFold.afterwards(rows, repo, 'S1', folds([kit('r1'), missing]), sink([]), _ -> {});
			switch outcome {
				case Skipped(why):
					Assert.stringContains('probe-fold failed', why);
				case _:
					Assert.fail('expected a skipped step, got $outcome');
			}
			Assert.equals(before, head(repo));
			Assert.equals('', status(repo), 'the kit the first row reached is back as it was');
		});
	}

	private static function kit(name: String): Fold {
		return { name: name, outcome: ToKit('cli', JValueParser.parse(ROW)) };
	}

	private static function folds(all: Array<Fold>): FoldSource {
		return (_, _) -> all;
	}

	private static function sink(filed: Array<Lesson>): QueueSink {
		return lesson -> {
			filed.push(lesson);
			return null;
		};
	}

	private static function read(repo: String, words: Array<String>): String {
		return cmd('git -C $repo $words').run().check().out.trim();
	}

	private static function head(repo: String): String {
		return read(repo, ['rev-parse', 'HEAD']);
	}

	private static function status(repo: String): String {
		return read(repo, ['status', '--porcelain']);
	}

	private static function message(repo: String): String {
		return read(repo, ['log', '-1', '--format=%B']);
	}

	private static function withRepo(body: (repo: String, rows: String) -> Void): Void {
		TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			final kits: String = Path.join([repo, Probe.KITS, 'cli']);
			FileSystem.createDirectory(repo);
			FileSystem.createDirectory(Path.join([repo, 'test']));
			FileSystem.createDirectory(Path.join([repo, Probe.KITS]));
			FileSystem.createDirectory(kits);
			File.saveContent(Path.join([kits, Probe.KIT_FILE]), '{"invocations":[]}\n');
			File.saveContent(Path.join([repo, 'a.txt']), 'a\n');
			git(repo, ['init', '-q', '-b', 'main']);
			git(repo, ['config', 'user.name', 'fold']);
			git(repo, ['config', 'user.email', 'fold@example.com']);
			git(repo, ['config', 'commit.gpgsign', 'false']);
			git(repo, ['add', '.']);
			git(repo, ['commit', '-q', '-m', 'base']);
			final rows: String = dir.file('rows.json');
			File.saveContent(rows, '{"area":"cli","invocations":[$ROW]}');
			body(repo, rows);
		});
	}

	private static function git(repo: String, words: Array<String>): Void {
		read(repo, words);
	}

}
