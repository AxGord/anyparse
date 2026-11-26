package unit.dev;

import dev.SplitApply;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/** `dev split-apply`: which delivered lists of queue lines may replace a running line, over a scratch tree, queue and queue CLI. */
@:nullSafety(Strict)
final class SplitApplyTest extends Test {

	private static final QUEUE: String = [
		'tasks:',
		'  - id: PAR-1',
		'    status: running',
		'    difficulty: 9',
		'    priority: high',
		'    touches: [ src/A.hx ]',
		'    text: |-',
		'      User: «cut it» and «keep the order»',
		'  - id: OTHER-1',
		'    status: pending',
		'    difficulty: 3',
		'    owner: Own',
		'    touches: [ src/B.hx ]',
		'    text: |-',
		'      another line',
		''
	].join('\n');
	private static final QUOTES: String = '«cut it» and «keep the order»';

	@:pin('control')
	@:killer('M-SPLIT-WHOLE')
	public function testOneInvalidLineRefusesTheWholeList(): Void {
		TempDir.with(dir -> {
			final list: String = '[${line('NEW-1', 4, 'src/A.hx')}, ${line('NEW-2', null, 'src/A.hx')}]';
			final verdict: SplitVerdict = SplitApply.check('PAR-1', list, QUEUE, tree(dir));
			Assert.same(['NEW-2: no difficulty'], verdict.problems);
			Assert.same([], verdict.lines);
		});
	}

	@:pin('control')
	@:killer('M-SPLIT-REFUSED-UNAPPLIED')
	public function testARefusedListNeverReachesTheQueueCli(): Void {
		TempDir.with(dir -> {
			File.saveContent(dir.file('lines.json'), '[${line('NEW-1', null, 'src/A.hx')}]');
			Assert.equals(SplitApply.EXIT_REFUSED, SplitApply.main(argv(dir)));
			Assert.isFalse(FileSystem.exists(dir.file('added.txt')));
		});
	}

	@:pin('control')
	@:killer('M-SPLIT-PATHS')
	public function testATouchedPathMissingFromTheTreeIsRefusedUnlessMarkedNew(): Void {
		TempDir.with(dir -> {
			final list: String = '[${line('NEW-1', 4, 'src/Gone.hx')}, ${line('NEW-2', 4, 'src/Made.hx (new)')}]';
			Assert.same(
				['NEW-1: touches `src/Gone.hx` does not exist on main and is not marked (new)'],
				SplitApply.check('PAR-1', list, QUEUE, tree(dir)).problems
			);
		});
	}

	@:pin('control')
	@:killer('M-SPLIT-DIFFICULTY')
	public function testALineWithoutADifficultyIsRefused(): Void {
		TempDir.with(dir ->
			Assert.same(
				['NEW-1: no difficulty'], SplitApply.check('PAR-1', '[${line('NEW-1', null, 'src/A.hx')}]', QUEUE, tree(dir)).problems
			)
		);
	}

	@:pin('control')
	@:killer('M-SPLIT-QUOTES')
	public function testATextWithoutTheParentsUserQuotesIsRefused(): Void {
		TempDir.with(dir -> {
			final list: String = '[{"id": "NEW-1", "difficulty": 4, "touches": ["src/A.hx"], "text": "only «cut it»"}]';
			Assert.same(
				['NEW-1: the text lacks the parent\'s quote «keep the order»'], SplitApply.check('PAR-1', list, QUEUE, tree(dir)).problems
			);
		});
	}

	@:pin('control')
	@:killer('M-SPLIT-OVERLAP')
	public function testAnOpenLineOnATouchedPathMustBeNamed(): Void {
		TempDir.with(dir -> {
			final repo: String = tree(dir);
			final silent: Array<String> = SplitApply.check('PAR-1', '[${line('NEW-1', 4, 'src')}]', QUEUE, repo).problems;
			Assert.equals(1, silent.length);
			Assert.stringContains('OTHER-1 (pending) is open on the touched path src', silent[0]);
			final ordered: String = '[{"id": "NEW-1", "difficulty": 4, "touches": ["src"], "after": ["OTHER-1"], "text": "$QUOTES"}]';
			Assert.same([], SplitApply.check('PAR-1', ordered, QUEUE, repo).problems);
			final named: String = '[{"id": "NEW-1", "difficulty": 4, "touches": ["src"], "text": "$QUOTES, independent of OTHER-1"}]';
			Assert.same([], SplitApply.check('PAR-1', named, QUEUE, repo).problems);
		});
	}

	@:pin('control')
	@:killer('M-SPLIT-OWNER')
	public function testAnOpenLineOfTheSameOwnerMustBeNamed(): Void {
		TempDir.with(dir -> {
			final list: String = '[{"id": "NEW-1", "difficulty": 4, "owner": "Own", "touches": ["src/A.hx"], "text": "$QUOTES"}]';
			final problems: Array<String> = SplitApply.check('PAR-1', list, QUEUE, tree(dir)).problems;
			Assert.equals(1, problems.length);
			Assert.stringContains('OTHER-1 (pending) is open on the same owner Own', problems[0]);
		});
	}

	@:pin('control')
	@:killer('M-SPLIT-PRIORITY')
	public function testALineWithoutAPriorityTakesTheParentsOne(): Void {
		TempDir.with(dir -> {
			final list: String = '['
				+ line('NEW-1', 4, 'src/A.hx')
				+ ', {"id": "NEW-2", "difficulty": 4, "priority": "low", "touches": ["src/A.hx"], "text": "$QUOTES"}]';
			final verdict: SplitVerdict = SplitApply.check('PAR-1', list, QUEUE, tree(dir));
			Assert.same(['high', 'low'], verdict.lines.map(added -> added.priority));
		});
	}

	@:pin('control')
	@:killer('M-SPLIT-BATCH-MARK')
	public function testAValidListGoesToTheBatchAddWithTheSplitMark(): Void {
		TempDir.with(dir -> {
			File.saveContent(dir.file('lines.json'), '[${line('NEW-1', 4, 'src/A.hx')}, ${line('NEW-2', 5, 'src/A.hx')}]');
			Assert.equals(0, SplitApply.main(argv(dir)));
			final args: Array<String> = File.getContent(dir.file('added.txt')).trim().split('\n');
			Assert.same(['--add-batch', dir.file('applied.json'), '--split', 'PAR-1'], args.slice(1));
			Assert.stringContains('"priority":"high"', File.getContent(dir.file('applied.json')));
		});
	}

	@:pin('control')
	@:killer('M-SPLIT-SUMMARY')
	public function testTheParentReadsOneSplitLine(): Void {
		TempDir.with(dir -> {
			final verdict: SplitVerdict = SplitApply.check(
				'PAR-1', '[${line('NEW-1', 4, 'src/A.hx')}, ${line('NEW-2', 5, 'src/A.hx')}]', QUEUE, tree(dir)
			);
			Assert.equals('SPLIT PAR-1 -> NEW-1, NEW-2', SplitApply.summary('PAR-1', verdict.lines));
		});
	}

	@:pin('control')
	@:killer('M-SPLIT-CLI-REFUSAL')
	public function testAListTheQueueCliRefusesIsRefusedAndLeavesNoRecord(): Void {
		TempDir.with(dir -> {
			File.saveContent(dir.file('lines.json'), '[${line('NEW-1', 4, 'src/A.hx')}]');
			final args: Array<String> = argv(dir);
			File.saveContent(dir.file('queue-cli.sh'), '#!/bin/sh\necho "refused, nothing written" >&2\nexit 1\n');
			Assert.equals(SplitApply.EXIT_REFUSED, SplitApply.main(args));
			Assert.isFalse(FileSystem.exists(dir.file('applied.json')));
		});
	}

	/** A delivered line carrying the parent's quotes; a null difficulty leaves the key out. */
	private static function line(id: String, difficulty: Null<Int>, touch: String): String {
		final level: String = difficulty == null ? '' : '"difficulty": $difficulty, ';
		return '{"id": "$id", ${level}"touches": ["$touch"], "text": "$QUOTES"}';
	}

	/** A tree with `src/A.hx` and `src/B.hx`; its path. */
	private static function tree(dir: TempDir): String {
		if (!FileSystem.exists(dir.file('src'))) {
			FileSystem.createDirectory(dir.file('src'));
			File.saveContent(dir.file('src/A.hx'), '');
			File.saveContent(dir.file('src/B.hx'), '');
		}
		return dir.path;
	}

	/** The command line over the scratch tree, its queue and a queue CLI that records its arguments in `added.txt`. */
	private static function argv(dir: TempDir): Array<String> {
		final script: String = dir.file('queue-cli.sh');
		File.saveContent(script, '#!/bin/sh\nprintf \'%s\\n\' "$$@" > "' + dir.file('added.txt') + '"\n');
		js.node.Fs.chmodSync(script, 493);
		File.saveContent(dir.file('queue.yaml'), QUEUE);
		return [
			'PAR-1',
			'--lines',
			dir.file('lines.json'),
			'--repo',
			tree(dir),
			'--queue',
			dir.file('queue.yaml'),
			'--queue-cli',
			script,
			'--record',
			dir.file('applied.json')
		];
	}

}
