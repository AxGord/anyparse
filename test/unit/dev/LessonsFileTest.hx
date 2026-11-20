package unit.dev;

import dev.LessonsFile;
import dev.QueueFile.QueueLine;
import dev.ScrubGuard;
import devkit.Args.UsageError;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * `dev lessons-file`: which records of a slice's logs dir become queue lines, which are left for the parent and why, over a
 * scratch tree, queue and queue CLI.
 */
@:nullSafety(Strict)
final class LessonsFileTest extends Test {

	private static final QUEUE: String =
		'tasks:\n  - id: OLD-1\n    status: backlog\n    touches: [ src/A.hx ]\n    text: |-\n      old brief with `Thing` in it\n';

	@:pin('control')
	@:killer('M-LESSONS-PRIORITY')
	public function testAnUnverifiedLessonIsLowAndAnArmRotIsHigh(): Void {
		final low: String = LessonsFile.mapping(lesson('unverified', ['src/A.hx']));
		final high: String = LessonsFile.mapping(lesson('arm-rot-on-base', ['src/A.hx']));
		Assert.stringContains('"priority":"low"', low);
		Assert.stringContains('"priority":"high"', high);
	}

	@:pin('control')
	@:killer('M-LESSONS-UNVERIFIED-BACKLOG')
	public function testAnUnverifiedLessonIsABacklogLineAndAnArmRotIsPending(): Void {
		final low: String = LessonsFile.mapping(lesson('unverified', ['src/A.hx']));
		final high: String = LessonsFile.mapping(lesson('arm-rot-on-base', ['src/A.hx']));
		Assert.stringContains('"status":"backlog"', low);
		Assert.stringContains('"difficulty"', high);
		Assert.isFalse(high.contains('"status"'));
	}

	@:pin('control')
	@:killer('M-LESSONS-FILEABLE-ALL')
	public function testOnlyTwoClassesAreFiledWithoutTheParent(): Void {
		TempDir.with(dir -> {
			final world: LessonWorld = world(dir);
			for (kind in ['reproduced-on-real-tree', 'loss', 'process']) switch LessonsFile.judge(lesson(kind, ['src/A.hx']), world) {
				case Triage(why):
					Assert.stringContains('parent', why);
				case other:
					Assert.fail('$kind: $other');
			}
			Assert.same(Admit, LessonsFile.judge(lesson('unverified', ['src/A.hx']), world));
			Assert.same(Admit, LessonsFile.judge(lesson('arm-rot-on-base', ['src/A.hx']), world));
		});
	}

	@:pin('control')
	@:killer('M-LESSONS-NO-TOUCHES')
	public function testARecordWithoutTouchesIsRefused(): Void {
		TempDir.with(dir -> refused(dir, lesson('unverified', []), 'no touches'));
	}

	@:pin('control')
	@:killer('M-LESSONS-TOO-WIDE')
	public function testARecordTouchingTooManyFilesIsRefused(): Void {
		TempDir.with(dir -> {
			final many: Array<String> = [ for (_ in 0...LessonsFile.MAX_TOUCHES + 1) 'src/A.hx' ];
			refused(dir, lesson('unverified', many), 'touches, over');
		});
	}

	@:pin('control')
	@:killer('M-LESSONS-MISSING-PATH')
	public function testAPathThatIsNotOnMainNeedsTheNewMark(): Void {
		TempDir.with(dir -> {
			refused(dir, lesson('unverified', ['src/Gone.hx']), 'does not exist');
			Assert.same(Admit, LessonsFile.judge(lesson('unverified', ['src/Gone.hx (new)']), world(dir)));
		});
	}

	@:pin('control')
	@:killer('M-LESSONS-DIRECTORY')
	public function testADirectoryIsRefusedBecauseItConflictsWithNothing(): Void {
		TempDir.with(dir -> refused(dir, lesson('unverified', ['src/sub']), 'directory'));
	}

	@:pin('control')
	@:killer('M-LESSONS-ID-TAKEN')
	public function testAnIdOfAnotherLineIsRefusedAndOfThisLessonIsAlready(): Void {
		TempDir.with(dir -> {
			final world: LessonWorld = world(dir);
			final same: Lesson = lesson('unverified', ['src/A.hx'], 'OLD-1');
			refused(dir, same, 'taken');
			final held: QueueLine = line('OLD-1', 'backlog', ['src/A.hx'], LessonsFile.composed(same));
			Assert.same(Already, LessonsFile.judge(same, { queue: [held], repo: world.repo, names: [] }));
		});
	}

	@:pin('control')
	@:killer('M-LESSONS-DUPLICATE')
	public function testAnOpenLineOnTheSameFilesNamingTheSameThingIsADuplicate(): Void {
		TempDir.with(dir -> {
			final twin: Lesson = lesson('unverified', ['src/A.hx'], 'NEW-1', 'another view of `Thing`');
			refused(dir, twin, 'duplicate of OLD-1');
			final elsewhere: Lesson = lesson('unverified', ['src/B.hx (new)'], 'NEW-2', 'another view of `Thing`');
			Assert.same(Admit, LessonsFile.judge(elsewhere, world(dir)));
		});
	}

	@:pin('control')
	@:killer('M-LESSONS-NAMES')
	public function testALessonNamingAPrivateProjectIsRefused(): Void {
		TempDir.with(dir -> {
			final world: LessonWorld = { queue: [], repo: world(dir).repo, names: ScrubGuard.loadRules('Acme==>X') };
			switch LessonsFile.judge(lesson('unverified', ['src/A.hx'], 'NEW-1', 'breaks the Acme build'), world) {
				case Triage(why): Assert.stringContains('private-names', why);
				case other: Assert.fail('$other');
			}
		});
	}

	@:pin('control')
	@:killer('M-LESSONS-FILED')
	public function testAnAdmittedLessonIsAddedThroughTheQueueCli(): Void {
		TempDir.with(dir -> {
			final paths: LessonPaths = paths(dir, 'exit 0');
			final report: LessonReport = LessonsFile.file(logs(dir, [record('NEW-1', 'unverified', '"src/A.hx"')]), 'SL-1', paths);
			Assert.equals('lessons=filed 1, triage 0', LessonsFile.summary(report));
			final added: String = File.getContent(dir.file('added.txt'));
			Assert.stringContains('"id":"NEW-1"', added);
			Assert.stringContains('"status":"backlog"', added);
			Assert.isFalse(FileSystem.exists(paths.triage));
		});
	}

	@:pin('control')
	@:killer('M-LESSONS-CLI-REFUSAL')
	public function testARecordTheQueueCliRefusesIsATriageRowNotALoss(): Void {
		TempDir.with(dir -> {
			final cli: LessonPaths = paths(dir, 'echo archived >&2; exit 2');
			final report: LessonReport = LessonsFile.file(logs(dir, [record('NEW-1', 'unverified', '"src/A.hx"')]), 'SL-1', cli);
			Assert.equals(0, report.filed);
			Assert.equals(1, report.triage.length);
			Assert.stringContains('refused it', report.triage[0]);
			Assert.stringContains('NEW-1', File.getContent(dir.file('triage.txt')));
		});
	}

	@:pin('control')
	@:killer('M-LESSONS-UNREADABLE-KEPT')
	public function testAFileThatDoesNotParseIsATriageRowWithItsContent(): Void {
		TempDir.with(dir -> {
			final logsDir: String = logs(dir, []);
			File.saveContent(Path.join([logsDir, 'review-lessons.json']), '{"lessons": [ oops this is the brief');
			final report: LessonReport = LessonsFile.file(logsDir, 'SL-1', paths(dir, 'exit 0'));
			Assert.equals(1, report.triage.length);
			Assert.stringContains('oops this is the brief', report.triage[0]);
		});
	}

	@:pin('control')
	@:killer('M-LESSONS-TRIAGE-RERUN')
	public function testASecondRunOverTheSameLogsDoesNotDoubleTheTriageRows(): Void {
		TempDir.with(dir -> {
			final logsDir: String = logs(dir, [record('NEW-1', 'process', '"src/A.hx"')]);
			final paths: LessonPaths = paths(dir, 'exit 0');
			final first: LessonReport = LessonsFile.file(logsDir, 'SL-1', paths);
			final second: LessonReport = LessonsFile.file(logsDir, 'SL-1', paths);
			Assert.equals('lessons=filed 0, triage 1', LessonsFile.summary(first));
			Assert.equals('lessons=filed 0, triage 0, already 1', LessonsFile.summary(second));
			Assert.equals(2, File.getContent(paths.triage).trim().split('\n').length);
		});
	}

	public function testALackOfThePrivateNamesListIsReportedNotSilent(): Void {
		TempDir.with(dir -> {
			final report: LessonReport = LessonsFile.file(logs(dir, []), 'SL-1', paths(dir, 'exit 0'));
			Assert.isFalse(report.namesChecked);
		});
	}

	@:pin('control')
	@:killer('M-LESSONS-SHORT-BRIEF')
	public function testAShortBriefInsideAnOpenLinesTextIsNotADuplicate(): Void {
		TempDir.with(dir -> {
			final short: Lesson = lesson('unverified', ['src/B.hx (new)'], 'NEW-1', 'old');
			Assert.same(Admit, LessonsFile.judge(short, world(dir)));
		});
	}

	@:pin('control')
	@:killer('M-LESSONS-TRIAGE-KEEPS-NEW')
	public function testARerunWithAnExtraRecordKeepsTheRowTheFirstRunNeverWrote(): Void {
		TempDir.with(dir -> {
			final cli: LessonPaths = paths(dir, 'exit 0');
			final first: LessonReport = LessonsFile.file(logs(dir, [record('NEW-1', 'process', '"src/A.hx"')]), 'SL-1', cli);
			Assert.equals(1, first.triage.length);
			final again: LessonReport = LessonsFile.file(
				logs(dir, [record('NEW-1', 'process', '"src/A.hx"'), record('NEW-2', 'loss', '"src/A.hx"')]), 'SL-1', cli
			);
			Assert.equals('lessons=filed 0, triage 1, already 1', LessonsFile.summary(again));
			final rows: Array<String> = File.getContent(cli.triage).trim().split('\n');
			Assert.equals(1, rows.filter(row -> row.startsWith('NEW-1 ')).length);
			Assert.equals(1, rows.filter(row -> row.startsWith('NEW-2 ')).length);
		});
	}

	@:pin('control')
	@:killer('M-LESSONS-MAIN-FILES')
	public function testTheCommandLineFilesTheRecordsOfALogsDir(): Void {
		TempDir.with(dir -> {
			final cli: LessonPaths = paths(dir, 'exit 0');
			final logsDir: String = logs(dir, [
				record('NEW-1', 'unverified', '"src/A.hx"'),
				record('NEW-2', 'loss', '"src/A.hx"')
			]);
			File.saveContent(dir.file('names.txt'), 'Acme==>X\n');
			final status: Int = LessonsFile.main(argv(dir, cli, logsDir).concat(['--private-names', dir.file('names.txt')]));
			Assert.equals(0, status);
			Assert.stringContains('"id":"NEW-1"', File.getContent(dir.file('added.txt')));
			Assert.stringContains('NEW-2 [loss]', File.getContent(cli.triage));
		});
	}

	@:pin('control')
	@:killer('M-LESSONS-MAIN-USAGE')
	public function testTheCommandLineWithoutASliceIsAUsageError(): Void {
		TempDir.with(dir -> {
			final cli: LessonPaths = paths(dir, 'exit 0');
			final call: Array<String> = argv(dir, cli, logs(dir, [])).filter(arg -> arg != '--slice' && arg != 'SL-1');
			Assert.raises(LessonsFile.main.bind(call), UsageError);
		});
	}

	@:pin('control')
	@:killer('M-LESSONS-MAIN-ENV-LIST')
	public function testThePipelinesScrubListIsTheDefaultPrivateNamesList(): Void {
		TempDir.with(dir -> {
			final cli: LessonPaths = paths(dir, 'exit 0');
			final named: String = record('NEW-1', 'unverified', '"src/A.hx"').replace('a brief', 'breaks the Acme build');
			final logsDir: String = logs(dir, [named]);
			File.saveContent(dir.file('names.txt'), 'Acme==>X\n');
			final before: String = Sys.getEnv('ANYPARSE_SCRUB_LIST') ?? '';
			Sys.putEnv('ANYPARSE_SCRUB_LIST', dir.file('names.txt'));
			final status: Int = try {
				LessonsFile.main(argv(dir, cli, logsDir));
			} catch (exception: Exception) {
				Sys.putEnv('ANYPARSE_SCRUB_LIST', before);
				throw exception;
			}
			Sys.putEnv('ANYPARSE_SCRUB_LIST', before);
			Assert.equals(0, status);
			Assert.isFalse(FileSystem.exists(dir.file('added.txt')));
			Assert.stringContains('private-names', File.getContent(cli.triage));
		});
	}

	private static function lesson(kind: String, touches: Array<String>, id: String = 'NEW-1', text: String = 'a brief'): Lesson {
		return {
			slice: 'SL-1',
			id: id,
			kind: kind,
			touches: touches,
			repro: 'run it',
			text: text
		};
	}

	private static function line(id: String, status: String, touches: Array<String>, text: String): QueueLine {
		return {
			id: id,
			status: status,
			owner: '',
			text: text,
			ended: '',
			base: '',
			touches: touches,
			sweep: '',
			after: [],
			notes: [],
			exclusive: false
		};
	}

	/** A tree with `src/A.hx` and `src/sub/`, and a queue holding the one line OLD-1. */
	private static function world(dir: TempDir): LessonWorld {
		if (!FileSystem.exists(dir.file('src'))) {
			FileSystem.createDirectory(dir.file('src'));
			FileSystem.createDirectory(dir.file('src/sub'));
			File.saveContent(dir.file('src/A.hx'), '');
		}
		return { queue: [line('OLD-1', 'backlog', ['src/A.hx'], 'old brief with `Thing` in it')], repo: dir.path, names: [] };
	}

	private static function refused(dir: TempDir, lesson: Lesson, containing: String): Void {
		switch LessonsFile.judge(lesson, world(dir)) {
			case Triage(why):
				Assert.stringContains(containing, why);
			case other:
				Assert.fail('${lesson.id}: expected a refusal containing `$containing`, got $other');
		}
	}

	private static function record(id: String, kind: String, touches: String): String {
		return '{"id": "$id", "kind": "$kind", "touches": [$touches], "repro": "run it", "text": "a brief"}';
	}

	/** A logs dir whose `lessons.json` holds `records`. */
	private static function logs(dir: TempDir, records: Array<String>): String {
		final logsDir: String = dir.file('logs');
		FileSystem.createDirectory(logsDir);
		File.saveContent(Path.join([logsDir, 'lessons.json']), '{"lessons": [${records.join(',')}]}');
		return logsDir;
	}

	/** The paths of a scratch run: a tree, a queue holding OLD-1 and a queue CLI that saves the row it was given, then runs `body`. */
	private static function paths(dir: TempDir, body: String): LessonPaths {
		final repo: String = world(dir).repo;
		final script: String = dir.file('queue-cli.sh');
		File.saveContent(script, '#!/bin/sh\nprintf \'%s\\n\' "$$3" > "' + dir.file('added.txt') + '"\n$body\n');
		js.node.Fs.chmodSync(script, 493);
		File.saveContent(dir.file('queue.yaml'), QUEUE);
		return {
			repo: repo,
			queue: dir.file('queue.yaml'),
			triage: dir.file('triage.txt'),
			script: script,
			names: dir.file('no-such-names.txt')
		};
	}

	/** The command line the pipeline runs, over a scratch run's paths. */
	private static function argv(dir: TempDir, cli: LessonPaths, logsDir: String): Array<String> {
		return [
			logsDir,
			'--slice',
			'SL-1',
			'--repo',
			dir.path,
			'--queue',
			cli.queue,
			'--triage',
			cli.triage,
			'--queue-cli',
			cli.script
		];
	}

}
