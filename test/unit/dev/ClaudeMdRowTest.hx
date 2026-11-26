package unit.dev;

import dev.ClaudeMdRow;
import dev.SliceGate;
import devkit.Cmd.cmd;
import devkit.Summary;
import sys.FileSystem;
import sys.io.File;

using StringTools;
using Lambda;

/** `dev.ClaudeMdRow`: the slice gate's `claude-md` row, the budget of the file every agent loads and the declaration of a change to it. */
@:nullSafety(Strict)
final class ClaudeMdRowTest extends Test {

	private static final SLICE: String = 'SLICE-X';

	@:pin('control')
	@:killer('M-CLAUDE-MD-BUDGET-IGNORED')
	public function testAFileGrownPastTheBudgetFailsAndOneWithinItPasses(): Void {
		final within: Outcome = ClaudeMdRow.verdict(ClaudeMdRow.BUDGET, ClaudeMdRow.BUDGET - 10, false, null);
		Assert.isTrue(within.match(Passed));
		Assert.isTrue(ClaudeMdRow.verdict(ClaudeMdRow.BUDGET + 1, ClaudeMdRow.BUDGET, false, null).match(Failed(_)));
		Assert.isTrue(ClaudeMdRow.verdict(ClaudeMdRow.BUDGET + 1, null, false, null).match(Failed(_)));
	}

	@:pin('control')
	@:killer('M-CLAUDE-MD-SHRINK-HELD')
	public function testASliceThatShrinksAFileOverBudgetIsNotHeldToTheDebt(): Void {
		Assert.isTrue(ClaudeMdRow.verdict(ClaudeMdRow.BUDGET + 5, ClaudeMdRow.BUDGET + 50, true, true).match(Passed));
		Assert.isTrue(ClaudeMdRow.verdict(ClaudeMdRow.BUDGET + 5, ClaudeMdRow.BUDGET + 5, false, null).match(Passed));
	}

	@:pin('control')
	@:killer('M-CLAUDE-MD-UNDECLARED-PASSES')
	public function testAChangeWithoutADeclarationFailsAndADeclaredOnePasses(): Void {
		Assert.isTrue(ClaudeMdRow.verdict(100, 90, true, false).match(Failed(_)));
		Assert.isTrue(ClaudeMdRow.verdict(100, 90, true, null).match(Failed(_)));
		Assert.isTrue(ClaudeMdRow.verdict(100, 90, true, true).match(Passed));
		Assert.isTrue(ClaudeMdRow.verdict(100, 100, false, false).match(Passed));
	}

	public function testTheNotePrintsTheBytesTheDeltaAndTheBudget(): Void {
		Assert.equals('13057 B (+43), budget ${ClaudeMdRow.BUDGET} B', ClaudeMdRow.note(13057, 13014));
		Assert.equals('90 B (-10), budget ${ClaudeMdRow.BUDGET} B', ClaudeMdRow.note(90, 100));
	}

	@:pin('control')
	@:killer('M-CLAUDE-MD-DECLARED-BLIND')
	public function testTheRowReadsTheDeclarationFromTheQueueLineNamedByTheTreeDirectory(): Void {
		withRepo(queue(''), repo -> {
			File.saveContent('$repo/CLAUDE.md', 'rules, changed by the slice\n');
			final base: String = cmd('git -C $repo rev-parse HEAD').run().out.trim();
			final undeclared: Outcome = ClaudeMdRow.outcome(repo, base, [ClaudeMdRow.FILE], new Summary());
			Assert.isTrue(undeclared.match(Failed(_)), 'changed, not declared: $undeclared');
			File.saveContent('$repo/.claude/batch/queue.yaml', queue('CLAUDE.md'));
			final declared: Outcome = ClaudeMdRow.outcome(repo, base, [ClaudeMdRow.FILE], new Summary());
			Assert.isTrue(declared.match(Passed), 'changed and declared: $declared');
			Assert.isTrue(ClaudeMdRow.outcome(repo, base, [], new Summary()).match(Passed), 'untouched: no declaration needed');
		});
	}

	@:pin('guard')
	public function testTheGateRunsTheRowInABranch(): Void {
		Assert.isTrue(SliceGate.GATE_BRANCHES.exists(rows -> rows.contains('claude-md')));
	}

	private static function queue(touches: String): String {
		return [
			'tasks:',
			'  - id: $SLICE',
			'    status: running',
			'    touches: [ $touches ]',
			'    text: |-',
			'      x',
			''
		].join('\n');
	}

	/** A repository in a directory named as the slice, holding a `CLAUDE.md` and the queue file, committed. */
	private static function withRepo(queueText: String, body: (repo: String) -> Void): Void {
		TempDir.with(dir -> {
			final repo: String = dir.file(SLICE);
			FileSystem.createDirectory('$repo/.claude/batch');
			git(repo, ['init', '-q', '-b', 'main']);
			File.saveContent('$repo/CLAUDE.md', 'rules\n');
			File.saveContent('$repo/.claude/batch/queue.yaml', queueText);
			git(repo, ['add', '.']);
			git(repo, ['commit', '-q', '-m', 'base']);
			body(repo);
		});
	}

	private static function git(repo: String, words: Array<String>): Void {
		cmd('git -c user.name=gate -c user.email=gate@example.com -c commit.gpgsign=false -C $repo $words').run().check();
	}

}
