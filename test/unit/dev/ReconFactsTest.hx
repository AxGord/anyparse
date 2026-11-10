package unit.dev;

import dev.Dev;
import dev.GateTree;
import dev.ReconFacts;
import devkit.Cmd.cmd;
import devkit.TempDir;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `dev recon-facts` over a scratch repository, a queue file and a `<repo>-logs` directory: the route (full / update / skip /
 * refused) it answers from the state the previous recon left, and the sections of the facts it writes. The touched paths are
 * plain files, so no `hxq` engine is asked.
 */
@:nullSafety(Strict)
final class ReconFactsTest extends Test {

	private static final ID: String = 'S-1';
	private static final EARLY: String = 'c2 early on the notes day';

	@:pin('control')
	@:killer('M-RECON-FULL-WITHOUT-RECON')
	public function testWithoutAPreviousReconTheRouteIsFull(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			final verdict: ReconVerdict = start(dir);
			Assert.equals('full', kind(verdict.route));
			Assert.equals(0, ReconFacts.exitCode(verdict.route));
			final facts: String = File.getContent(factsFile(dir));
			Assert.isTrue(has(facts, 'head: ${headOf(dir)}'));
			Assert.isTrue(has(facts, '# recon facts $ID'));
			Assert.isTrue(has(facts, 'the recon text'));
		});
	}

	@:pin('control')
	@:killer('M-RECON-VERDICT-AT-BOTH-ENDS')
	public function testTheVerdictLeadsAndTrailsTheFactsBecauseAnExecKeepsTheTail(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			final text: String = start(dir).text;
			Assert.isTrue(text.startsWith('route: full (exit 0)\n'));
			Assert.isTrue(text.endsWith('route: full (exit 0)\n'));
		});
	}

	@:pin('control')
	@:killer('M-RECON-SKIP-WHEN-STILL-GOOD')
	public function testARecentReconOfAnUnchangedLineOnUntouchedPathsIsSkipped(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			begin(dir);
			finishRecon(dir);
			final before: String = File.getContent(factsFile(dir));
			final verdict: ReconVerdict = start(dir);
			Assert.equals('skip', kind(verdict.route));
			Assert.equals(11, ReconFacts.exitCode(verdict.route));
			Assert.equals(before, File.getContent(factsFile(dir)));
		});
	}

	@:pin('control')
	@:killer('M-RECON-SKIP-AND-REFUSAL-LEAVE-FACTS')
	public function testASkipPrintsOnlyItsReason(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			begin(dir);
			finishRecon(dir);
			final text: String = start(dir).text;
			Assert.isTrue(text.startsWith('route: skip (exit 11)\n'));
			Assert.isFalse(has(text, '# recon facts'));
		});
	}

	@:pin('control')
	@:killer('M-RECON-UPDATE-ON-TOUCHED-COMMIT')
	public function testACommitOnATouchedPathMakesItAnUpdate(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			begin(dir);
			finishRecon(dir);
			change(dir, 'docs/a.md', 'c2 change a');
			final verdict: ReconVerdict = start(dir);
			Assert.equals('update', kind(verdict.route));
			Assert.equals(10, ReconFacts.exitCode(verdict.route));
			final facts: String = File.getContent(factsFile(dir));
			Assert.isTrue(has(facts, '## since the previous recon'));
			Assert.isTrue(has(facts, 'c2 change a'));
		});
	}

	@:pin('control')
	@:killer('M-RECON-COMMITS-LIMITED-TO-TOUCHED')
	public function testACommitElsewhereKeepsTheSkip(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			begin(dir);
			finishRecon(dir);
			change(dir, 'docs/other.md', 'c2 change other');
			Assert.equals('skip', kind(start(dir).route));
		});
	}

	@:pin('control')
	@:killer('M-RECON-LINE-HASH-IGNORES-TEXT')
	public function testAChangedLineTextMakesItAnUpdate(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			begin(dir);
			finishRecon(dir);
			writeQueue(dir, [
				entry(ID, ['status: running', 'owner: Own', 'touches: [ docs/a.md ]'], 'the recon text, reworded')
			]);
			final verdict: ReconVerdict = start(dir);
			Assert.equals('update', kind(verdict.route));
			Assert.isTrue(has(File.getContent(factsFile(dir)), 'the queue line (text, touches or owner) changed'));
		});
	}

	@:pin('control')
	@:killer('M-RECON-NO-FACTS-FILE')
	public function testAReconWithoutRecordedFactsIsAnUpdate(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			FileSystem.createDirectory(logsOf(dir));
			File.saveContent(reconFile(dir), 'a recon of unknown base');
			Assert.equals('update', kind(start(dir).route));
		});
	}

	@:pin('control')
	@:killer('M-RECON-OLDER-THAN-FACTS')
	public function testAReconOlderThanTheFactsOfALaterRunIsAnUpdate(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			begin(dir);
			stamp(lockFile(dir), -10800);
			File.saveContent(reconFile(dir), 'the recon of an earlier run');
			stamp(reconFile(dir), -200);
			stamp(factsFile(dir), -100);
			Assert.equals('update', kind(start(dir).route));
		});
	}

	@:pin('control')
	@:killer('M-RECON-YOUNG-LOCK-REFUSES')
	public function testAYoungLockOfAnotherHolderRefusesASecondRecon(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			begin(dir, 'run-a');
			final before: String = File.getContent(factsFile(dir));
			final verdict: ReconVerdict = start(dir, 'run-b');
			Assert.equals('refused', kind(verdict.route));
			Assert.equals(12, ReconFacts.exitCode(verdict.route));
			Assert.isTrue(verdict.text.startsWith('route: refused (exit 12)\n'));
			Assert.isTrue(has(verdict.text, 'holder run-a'));
			Assert.equals(before, File.getContent(factsFile(dir)));
			Assert.equals('refused', kind(start(dir).route));
		});
	}

	@:pin('control')
	@:killer('M-RECON-SAME-HOLDER-REENTERS')
	public function testTheHolderOfALockTakesItAgainSoARetryIsNotRefused(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			begin(dir, 'run-a');
			Assert.equals('full', kind(start(dir, 'run-a').route));
			Assert.equals('holder run-a\n', File.getContent(lockFile(dir)));
		});
	}

	@:pin('control')
	@:killer('M-RECON-LOCK-EXPIRES')
	public function testALockPastTheTtlIsTakenByAnotherHolder(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			begin(dir, 'run-a');
			stamp(lockFile(dir), -7200);
			Assert.equals('full', kind(start(dir, 'run-b').route));
			Assert.equals('holder run-b\n', File.getContent(lockFile(dir)));
		});
	}

	@:pin('control')
	@:killer('M-RECON-FINISHED-RELEASES-LOCK')
	public function testAFinishedReconReleasesItsLock(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			begin(dir, 'run-a');
			finishRecon(dir);
			Assert.equals('skip', kind(start(dir, 'run-b').route));
		});
	}

	public function testTheFourRoutesHaveFourExitCodes(): Void {
		final codes: Array<Int> = [
			ReconFacts.exitCode(Full),
			ReconFacts.exitCode(Update('')),
			ReconFacts.exitCode(Skip('')),
			ReconFacts.exitCode(Refused(''))
		];
		for (code in codes) Assert.equals(1, codes.filter(other -> other == code).length);
		Assert.isFalse(codes.contains(2));
	}

	@:pin('control')
	@:killer('M-RECON-TOUCH-EXISTENCE')
	public function testEachTouchedPathIsReportedExistingOrMissing(): Void {
		TempDir.with(dir -> {
			scaffold(dir, ['status: running', 'touches: [ docs/a.md, docs/gone.md ]']);
			begin(dir);
			final facts: String = File.getContent(factsFile(dir));
			Assert.isTrue(has(facts, '- docs/a.md: exists'));
			Assert.isTrue(has(facts, '- docs/gone.md: MISSING'));
		});
	}

	@:pin('control')
	@:killer('M-RECON-BASE-NOTE-DATE')
	public function testWithoutARecordedCommitTheBaseIsTheNewestNoteDateAndSaysSo(): Void {
		TempDir.with(dir -> {
			scaffold(dir, [
				'status: running',
				'touches: [ docs/a.md ]',
				'notes:',
				'  - from: parent',
				'    date: 2099-01-01',
				'    text: later'
			]);
			begin(dir);
			final facts: String = File.getContent(factsFile(dir));
			Assert.isTrue(has(facts, 'base: date 2099-01-01, the newest note of the line'));
			Assert.isTrue(has(facts, 'records no base commit'));
			Assert.isFalse(has(facts, 'c1 base'));
			scaffold(dir, [
				'status: running',
				'touches: [ docs/a.md ]',
				'notes:',
				'  - from: parent',
				'    date: 2000-01-01',
				'    text: earlier'
			], false);
			stamp(lockFile(dir), -7200);
			begin(dir);
			Assert.isTrue(has(File.getContent(factsFile(dir)), 'c1 base'));
		});
	}

	@:pin('control')
	@:killer('M-RECON-BASE-RECORDED-COMMIT')
	public function testARecordedCommitBoundsTheCommitsAndIsNamed(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			final base: String = GateTree.gitIn(repoOf(dir), ['rev-parse', '--short', 'HEAD']).trim();
			change(dir, 'docs/a.md', 'c2 change a');
			change(dir, 'docs/a.md', 'c3 change a');
			scaffold(dir, ['status: running', 'touches: [ docs/a.md ]', 'base: $base'], false);
			begin(dir);
			final facts: String = File.getContent(factsFile(dir));
			Assert.isTrue(has(facts, 'base: the line\'s recorded commit $base'));
			Assert.isTrue(has(facts, 'c2 change a'));
			Assert.isTrue(has(facts, 'c3 change a'));
			Assert.isFalse(has(facts, 'c1 base'));
		});
	}

	@:pin('control')
	@:killer('M-RECON-AFTER-SLICE-COMMIT')
	public function testAnAfterLineQuotesTheCommitOfThatSlice(): Void {
		TempDir.with(dir -> {
			afterFixture(dir);
			begin(dir);
			final facts: String = File.getContent(factsFile(dir));
			Assert.isTrue(has(facts, '- P-1 (queue status done): '));
			Assert.isTrue(has(facts, 'p-1 done what P-1 did'));
			Assert.isTrue(has(facts, '- Q-9 (not a queue line): no commit on main carries `Slice: Q-9`'));
		});
	}

	@:pin('control')
	@:killer('M-RECON-AFTER-TRAILERS')
	public function testAnAfterLineDropsTheTrailersOfTheCommit(): Void {
		TempDir.with(dir -> {
			afterFixture(dir);
			begin(dir);
			final facts: String = File.getContent(factsFile(dir));
			Assert.isFalse(has(facts, 'Co-Authored-By'));
			Assert.isFalse(has(facts, 'Slice: P-1'));
		});
	}

	@:pin('control')
	@:killer('M-RECON-SIBLING-OWNER')
	public function testASiblingOfAnotherOwnerIsLeftOut(): Void {
		TempDir.with(dir -> {
			siblingFixture(dir);
			begin(dir);
			final facts: String = File.getContent(factsFile(dir));
			Assert.isFalse(has(facts, '- S-5:'));
			Assert.isFalse(has(facts, '- S-1:'));
		});
	}

	@:pin('control')
	@:killer('M-RECON-SIBLING-ENDED-BEFORE-BASE')
	public function testASiblingThatEndedBeforeTheBaseIsLeftOutAndOneAfterItIsListed(): Void {
		TempDir.with(dir -> {
			siblingFixture(dir);
			begin(dir);
			final facts: String = File.getContent(factsFile(dir));
			Assert.isFalse(has(facts, '- S-4:'));
			Assert.isTrue(has(facts, '- S-3: done 2026-06-01'));
		});
	}

	@:pin('control')
	@:killer('M-RECON-SIBLING-RUNNING')
	public function testARunningSiblingIsListed(): Void {
		TempDir.with(dir -> {
			siblingFixture(dir);
			begin(dir);
			Assert.isTrue(has(File.getContent(factsFile(dir)), '- S-2: running'));
		});
	}

	@:pin('control')
	@:killer('M-RECON-MENTIONS-ONE-PER-POSITION')
	public function testMentionsCountTheUnionOfUsesRefsAndLeavesOnceEachPerName(): Void {
		final output: String = [
			'=== QueueLine ===',
			'# uses (type positions)',
			'src/x/A.hx:',
			'  39:63: QueueLine',
			'  45:52: QueueLine',
			'test/y/BTest.hx:',
			'  43:20: QueueLine',
			'# refs (value bindings)',
			'src/x/A.hx:',
			'  13:1: [decl] QueueLine',
			'# lit (every leaf)',
			'src/x/A.hx:',
			'  13:1: TypedefDecl \'QueueLine\'',
			'  39:63: Named \'QueueLine\'',
			'src/x/C.hx:',
			'  3:1: ImportDecl \'dev.QueueFile.QueueLine\'',
			'=== Absent ===',
			''
		].join('\n');
		final counts: Map<String, MentionCount> = ReconFacts.countMentions(output, ['QueueLine', 'Absent']);
		Assert.equals(5, counts['QueueLine']?.hits);
		Assert.equals(3, counts['QueueLine']?.files);
		Assert.equals(0, counts['Absent']?.hits);
		Assert.equals(0, counts['Absent']?.files);
	}

	@:pin('control')
	@:killer('M-RECON-NAMES-DEDUPED')
	public function testBacktickedNamesAreTheLastSegmentOnceEach(): Void {
		Assert.same(['bar', 'baz'], ReconFacts.backtickedNames('see `Foo.bar` and `baz`, not `a`, again `baz` and `Foo.bar`'));
	}

	public function testALineTheQueueLacksThrows(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			Assert.raises(() -> ReconFacts.run('Z-9', repoOf(dir), queueOf(dir), null, null), Exception);
		});
	}

	public function testTheCommandWithoutAWorktreeExitsTwo(): Void {
		Assert.equals(2, Dev.run(['recon-facts', ID]));
	}

	@:pin('control')
	@:killer('M-RECON-SCOPE-FALLBACK')
	public function testALineWithoutATouchedSourcePathIsAskedAboutTheProjectRoots(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			final repo: String = repoOf(dir);
			Assert.same([], ReconFacts.mentionScope(repo, ['docs/gone.md']));
			FileSystem.createDirectory(Path.join([repo, 'src']));
			FileSystem.createDirectory(Path.join([repo, 'test']));
			Assert.same(['src', 'test'], ReconFacts.mentionScope(repo, []));
			Assert.same(['src', 'test'], ReconFacts.mentionScope(repo, ['docs/a.md']));
			write(repo, 'src/X.hx', 'class X {}');
			Assert.same(['src/X.hx'], ReconFacts.mentionScope(repo, ['src/X.hx', 'docs/a.md']));
		});
	}

	@:pin('control')
	@:killer('M-RECON-CLI-HOLDER')
	public function testTheHolderOptionReachesTheLock(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			begin(dir, 'run-a');
			Assert.equals(12, Dev.run(['recon-facts', ID, repoOf(dir), '--queue', queueOf(dir), '--holder', 'run-b']));
			Assert.equals(2, Dev.run(['recon-facts', ID, repoOf(dir), '--queue', queueOf(dir), '--holder']));
		});
	}

	@:pin('control')
	@:killer('M-RECON-CLI-QUEUE')
	public function testTheQueueOptionNamesTheQueueFile(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			Assert.equals(0, Dev.run(['recon-facts', ID, repoOf(dir), '--queue', queueOf(dir)]));
			Assert.isTrue(FileSystem.exists(factsFile(dir)));
		});
	}

	@:pin('control')
	@:killer('M-RECON-CLI-ENGINE')
	public function testTheEngineOptionIsWhatTheOwnerLookupRuns(): Void {
		TempDir.with(dir -> {
			scaffold(dir);
			FileSystem.createDirectory(Path.join([repoOf(dir), 'src']));
			final engine: String = dir.file('engine.js');
			File.saveContent(engine, 'console.log("fake-owner-answer");\n');
			Assert.equals(0, Dev.run(['recon-facts', ID, repoOf(dir), '--queue', queueOf(dir), '--engine', engine]));
			Assert.isTrue(has(File.getContent(factsFile(dir)), 'fake-owner-answer'));
		});
	}

	@:pin('control')
	@:killer('M-RECON-SINCE-START-OF-DAY')
	public function testACommitFromEarlierOnTheNotesDayIsListed(): Void {
		TempDir.with(dir -> {
			scaffold(dir, [
				'status: running',
				'touches: [ docs/a.md ]',
				'notes:',
				'  - from: parent',
				'    date: 2020-06-15',
				'    text: n'
			]);
			final repo: String = repoOf(dir);
			write(repo, 'docs/a.md', 'early');
			git(repo, ['add', '.']);
			cmd('git -C $repo -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m $EARLY')
				.env('GIT_COMMITTER_DATE', '2020-06-15T00:01:00')
				.env('GIT_AUTHOR_DATE', '2020-06-15T00:01:00')
				.run()
				.check();
			begin(dir);
			Assert.isTrue(has(File.getContent(factsFile(dir)), EARLY));
		});
	}

	private static function afterFixture(dir: TempDir): Void {
		scaffold(dir, ['status: running', 'touches: [ docs/a.md ]', 'after: [ P-1, Q-9 ]']);
		change(dir, 'docs/other.md', 'p-1 done', 'what P-1 did\n\nSlice: P-1\nCo-Authored-By: someone');
		change(dir, 'docs/other.md', 'later work');
		writeQueue(dir, [
			entry(ID, ['status: running', 'owner: Own', 'touches: [ docs/a.md ]', 'after: [ P-1, Q-9 ]'], 'the recon text'),
			entry('P-1', ['status: done'], 'earlier')
		]);
	}

	private static function siblingFixture(dir: TempDir): Void {
		scaffold(dir);
		writeQueue(dir, [
			entry(ID, [
				'status: running',
				'owner: Own',
				'touches: [ docs/a.md ]',
				'notes:',
				'  - from: parent',
				'    date: 2026-01-01',
				'    text: n'
			], 'the recon text'),
			entry('S-2', ['status: running', 'owner: Own', 'touches: [ docs/b.md ]'], 'two'),
			entry('S-3', ['status: done', 'owner: Own', 'ended: 2026-06-01', 'touches: [ docs/c.md ]'], 'three'),
			entry('S-4', ['status: done', 'owner: Own', 'ended: 2025-06-01', 'touches: [ docs/d.md ]'], 'four'),
			entry('S-5', ['status: running', 'owner: Other', 'touches: [ docs/e.md ]'], 'five')
		]);
	}

	/** A repository with one commit holding two plain files, and a queue holding line `ID` (the default fields, or `fields`). */
	private static function scaffold(dir: TempDir, ?fields: Array<String>, init: Bool = true): Void {
		final repo: String = repoOf(dir);
		if (init) {
			FileSystem.createDirectory(repo);
			git(repo, ['init', '-q', '-b', 'main']);
			write(repo, 'docs/a.md', 'base');
			write(repo, 'docs/other.md', 'base');
			commit(repo, 'c1 base', null);
		}
		writeQueue(dir, [
			entry(ID, fields ?? ['status: running', 'owner: Own', 'touches: [ docs/a.md ]'], 'the recon text')
		]);
	}

	private static function entry(id: String, fields: Array<String>, text: String): String {
		return '  - id: $id\n' + fields.map(row -> '    $row\n').join('') + '    text: |-\n      $text\n';
	}

	private static function writeQueue(dir: TempDir, entries: Array<String>): Void {
		File.saveContent(queueOf(dir), 'header: x\ntasks:\n' + entries.join(''));
	}

	private static function start(dir: TempDir, ?holder: String): ReconVerdict {
		return ReconFacts.run(ID, repoOf(dir), queueOf(dir), null, holder);
	}

	private static function kind(route: ReconRoute): String {
		return switch route {
			case Full: 'full';
			case Update(_): 'update';
			case Skip(_): 'skip';
			case Refused(_): 'refused';
		}
	}

	private static function has(text: String, part: String): Bool {
		return text.indexOf(part) >= 0;
	}

	/** The recon agent finished: its recon.md is newer than the facts and the lock it started from. */
	private static function finishRecon(dir: TempDir): Void {
		stamp(factsFile(dir), -100);
		File.saveContent(reconFile(dir), 'the recon');
		stamp(reconFile(dir), 10);
	}

	private static function stamp(file: String, secondsFromNow: Float): Void {
		final at: Date = Date.fromTime(Date.now().getTime() + secondsFromNow * 1000);
		js.node.Fs.utimesSync(file, at, at);
	}

	private static function headOf(dir: TempDir): String {
		return GateTree.gitIn(repoOf(dir), ['rev-parse', 'main']).trim();
	}

	private static function repoOf(dir: TempDir): String {
		return dir.file('repo');
	}

	private static function queueOf(dir: TempDir): String {
		return dir.file('queue.yaml');
	}

	private static function logsOf(dir: TempDir): String {
		return dir.file('repo-logs');
	}

	private static function factsFile(dir: TempDir): String {
		return Path.join([logsOf(dir), 'facts.md']);
	}

	private static function reconFile(dir: TempDir): String {
		return Path.join([logsOf(dir), 'recon.md']);
	}

	private static function lockFile(dir: TempDir): String {
		return Path.join([logsOf(dir), 'recon.lock']);
	}

	private static function write(repo: String, file: String, content: String): Void {
		final path: String = Path.join([repo, file]);
		FileSystem.createDirectory(Path.directory(path));
		File.saveContent(path, content);
	}

	/** A commit on main that changes `file`. */
	private static function change(dir: TempDir, file: String, subject: String, ?body: String): Void {
		final repo: String = repoOf(dir);
		write(repo, file, subject);
		commit(repo, subject, body);
	}

	private static function commit(repo: String, subject: String, body: Null<String>): Void {
		final message: String = body == null ? subject : '$subject\n\n$body';
		git(repo, ['add', '.']);
		git(repo, [
			'-c',
			'user.name=t',
			'-c',
			'user.email=t@t',
			'-c',
			'commit.gpgsign=false',
			'commit',
			'-q',
			'-m',
			message
		]);
	}

	private static function git(repo: String, args: Array<String>): Void {
		cmd('git -C $repo $args').run().check();
	}

	/** `start` for a test that reads only what the run left on disk. */
	private static function begin(dir: TempDir, ?holder: String): Void {
		start(dir, holder);
	}

}
