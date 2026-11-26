package unit.dev;

import dev.LandCandidate;
import devkit.Cmd.cmd;
import devkit.Summary.Outcome;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/** What `advance` left behind. */
private typedef Run = {
	var outcome: Outcome;
	var advanced: Bool;
	var judged: String;
	var rebasedFrom: Null<String>;
	var commit: String;
	var head: String;
	var treeHead: String;
	var subject: String;
	var parents: Int;
	var files: Map<String, String>;
	var notes: Array<String>;
}

/**
 * `LandCandidate.advance` over a scratch main: a main that moved on while the candidate was judged is followed when the
 * commits it took touch only paths no test reads (`TolerantPaths`), and refused in every other case, main left as it was.
 */
@:nullSafety(Strict)
final class LandCandidateTest extends Test {

	@:pin('control')
	@:killer('M-LAND-FOLLOW-NEVER')
	public function testAMainThatMovedOnByAJournalCommitIsFollowed(): Void {
		TempDir.with(dir -> {
			final run: Run = advance(dir, repo -> commitFile(repo, 'docs/journal/log.md', 'a reading\n'));
			Assert.isTrue(run.outcome.match(Passed), 'advanced: ${run.outcome}');
			Assert.isTrue(run.advanced);
			Assert.equals(run.judged, run.rebasedFrom, 'the commit the battery judged is named');
			Assert.notEquals(run.judged, run.head, 'main holds the picked commit, not the judged one');
			Assert.equals(run.head, run.commit);
			Assert.equals('land', run.subject);
			Assert.equals(1, run.parents);
			Assert.isTrue(run.files.exists('b.txt') && run.files.exists('docs/journal/log.md'), 'both sides are in main');
			Assert.equals(1, run.notes.length);
			Assert.stringContains('picked onto it, not judged again', run.notes[0]);
		});
	}

	@:pin('control')
	@:killer('M-LAND-FOLLOW-ANY-MOVE')
	public function testAMainThatMovedOnBySourceIsRefusedAndLeftAsItWas(): Void {
		TempDir.with(dir -> {
			final run: Run = advance(dir, repo -> commitFile(repo, 'src/x.hx', 'class X {}\n'));
			Assert.isTrue(run.outcome.match(Failed(_)));
			Assert.stringContains('main moved since the landing began', reason(run.outcome));
			Assert.isFalse(run.advanced);
			Assert.isNull(run.rebasedFrom);
			Assert.equals('the user commits', run.subject, 'main stays at the commit the user made');
			Assert.isFalse(run.files.exists('b.txt'));
			Assert.equals(0, run.notes.length);
		});
	}

	@:pin('control')
	@:killer('M-LAND-FOLLOW-ANY-MOVE')
	public function testAMainThatMovedOnByAJournalAndASourceFileTogetherIsRefused(): Void {
		TempDir.with(dir -> {
			final run: Run = advance(dir, repo -> {
				File.saveContent('$repo/src/y.hx', 'class Y {}\n');
				commitFile(repo, 'docs/decisions.md', 'head\n---\na line\n');
			});
			Assert.isTrue(run.outcome.match(Failed(_)));
			Assert.isFalse(run.advanced);
		});
	}

	public function testAMainThatMovedOnByACommitOfNoFileIsRefused(): Void {
		TempDir.with(dir -> {
			final run: Run = advance(dir, repo -> git(repo, ['commit', '--quiet', '--allow-empty', '-m', 'the user commits']));
			Assert.isTrue(run.outcome.match(Failed(_)));
			Assert.isFalse(run.advanced);
		});
	}

	@:pin('control')
	@:killer('M-LAND-FOLLOW-NOT-AHEAD')
	public function testAMainTakenBackOnATolerantCommitIsRefused(): Void {
		TempDir.with(dir -> {
			final run: Run = advance(
				dir, repo -> git(repo, ['reset', '--quiet', '--hard', 'HEAD~1']), repo -> commitFile(repo, 'docs/journal/log.md', 'x\n')
			);
			Assert.isTrue(run.outcome.match(Failed(_)));
			Assert.isFalse(run.advanced);
			Assert.equals('first\n', run.files['docs/journal/log.md'], 'what the user took off main stays off');
		});
	}

	public function testALedgerLineBothSidesAddedKeepsBothWhenMainFollows(): Void {
		TempDir.with(dir -> {
			final run: Run = advance(
				dir, repo -> commitFile(repo, 'docs/decisions.md', 'head\n---\nmain line\n'), null, 'docs/decisions.md',
				'head\n---\ncandidate line\n'
			);
			Assert.isTrue(run.outcome.match(Passed), 'advanced: ${run.outcome}');
			final ledger: String = run.files['docs/decisions.md'] ?? '';
			Assert.stringContains('main line', ledger);
			Assert.stringContains('candidate line', ledger);
		});
	}

	public function testALedgerLineThatCannotBeMergedRefusesAndLeavesTheCandidateTree(): Void {
		TempDir.with(dir -> {
			final run: Run = advance(
				dir, repo -> commitFile(repo, 'docs/journal/log.md', 'main\n'), null, 'docs/journal/log.md', 'candidate\n'
			);
			Assert.isTrue(run.outcome.match(Failed(_)));
			Assert.isFalse(run.advanced);
			Assert.equals('the user commits', run.subject);
			Assert.equals(run.judged, run.treeHead, 'the candidate tree is back at the candidate it was');
		});
	}

	/** `main` of a scratch repository with the ledger and a source file, and a candidate of one commit over it. */
	private static function advance(
		dir: TempDir, during: (repo: String) -> Void, ?after: (repo: String) -> Void, ?alsoPath: String, alsoContent: String = ''
	): Run {
		final repo: String = Path.join([dir.path, 'main']);
		FileSystem.createDirectory(repo);
		git(repo, ['init', '--quiet', '--initial-branch', 'main']);
		File.saveContent('$repo/.gitattributes', 'docs/decisions.md merge=union\n');
		commitFile(repo, 'docs/decisions.md', 'head\n---\n');
		commitFile(repo, 'docs/journal/log.md', 'first\n');
		commitFile(repo, 'src/a.hx', 'class A {}\n');
		if (after != null) after(repo);
		final candidate: LandCandidate = new LandCandidate(repo, Path.join([dir.path, 'candidate']));
		Assert.isTrue(candidate.open().match(Passed));
		File.saveContent('${candidate.tree}/b.txt', 'b\n');
		if (alsoPath != null) File.saveContent('${candidate.tree}/$alsoPath', alsoContent);
		git(candidate.tree, ['add', '.']);
		git(candidate.tree, ['commit', '--quiet', '-m', 'land']);
		final judged: String = cmd('git -C ${candidate.tree} rev-parse HEAD').run().out.trim();
		Assert.notEquals('', candidate.made());
		during(repo);
		final notes: Array<String> = [];
		final outcome: Outcome = candidate.advance(notes.push);
		return {
			outcome: outcome,
			advanced: candidate.advanced,
			judged: judged,
			rebasedFrom: candidate.rebasedFrom,
			commit: candidate.commit ?? '',
			head: cmd('git -C $repo rev-parse HEAD').run().out.trim(),
			treeHead: cmd('git -C ${candidate.tree} rev-parse HEAD').run().out.trim(),
			subject: cmd('git -C $repo log -1 --format=%s').run().out.trim(),
			parents: cmd('git -C $repo rev-list --parents -n 1 HEAD').run().out.trim().split(' ').length - 1,
			files: [ for (path in cmd('git -C $repo ls-files').run().lines()) path => File.getContent('$repo/$path') ],
			notes: notes
		};
	}

	private static function reason(outcome: Outcome): String {
		return switch outcome {
			case Failed(why): why;
			case _: '';
		};
	}

	private static function commitFile(repo: String, path: String, content: String): Void {
		FileSystem.createDirectory(Path.directory('$repo/$path'));
		File.saveContent('$repo/$path', content);
		git(repo, ['add', '.']);
		git(repo, ['commit', '--quiet', '-m', 'the user commits']);
	}

	private static function git(repo: String, words: Array<String>): Void {
		cmd('git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false -C $repo $words').run().check();
	}

}
