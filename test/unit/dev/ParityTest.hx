package unit.dev;

import dev.Parity;
import dev.Repo;
import devkit.TempDir;
import haxe.io.Path;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * `dev.Parity`: what it reports between two outcomes of one invocation, the command list it reads from `apq --help`, and a
 * run of two stand-in engines, each side starting from a fresh copy of the fixture at the same path.
 */
@:nullSafety(Strict)
final class ParityTest extends Test {

	public function testAStreamDifferenceNamesTheFirstPartingLine(): Void {
		Assert.isNull(Parity.streamDifference('stdout', 'a\nb\n', 'a\nb\n'));
		Assert.equals('stdout: line 2: base `b` / tip `c` (base 3 lines, tip 3)', Parity.streamDifference('stdout', 'a\nb\n', 'a\nc\n'));
		Assert.equals('stderr: line 2: base <end> / tip `x` (base 1 lines, tip 2)', Parity.streamDifference('stderr', 'a', 'a\nx'));
	}

	@:pin('control')
	@:killer('M-PARITY-EXIT-BLIND')
	public function testTheDifferencesNameTheExitTheStreamsAndTheFiles(): Void {
		final base: Outcome = outcome(0, 'same', ['a.hx' => 'one', 'gone.hx' => 'x']);
		Assert.same([], Parity.differences(base, outcome(0, 'same', ['a.hx' => 'one', 'gone.hx' => 'x'])));
		Assert.same([
			'exit: 0 → 1',
			'stdout: line 1: base `same` / tip `other` (base 1 lines, tip 1)',
			'files differ: a.hx',
			'only base wrote: gone.hx',
			'only tip wrote: new.hx'
		], Parity.differences(base, outcome(1, 'other', ['a.hx' => 'two', 'new.hx' => 'y'])));
	}

	public function testTheCommandsAreTheCommandsBlockOfTheHelp(): Void {
		final help: String = 'apq — x\n\nUsage: apq <command>\n\nCommands:\n  ast           Dump\n  move-member   Move\n'
			+ '  move-to-helper Move\n\nMore:\n  not-one  x\n';
		Assert.same(['ast', 'move-member', 'move-to-helper'], Parity.commandsOf(help));
	}

	public function testTwoEnginesRunFromFreshFixturesAndOnlyTheirDifferenceIsReported(): Void {
		final tree: Null<String> = Repo.ofScript();
		if (tree == null) {
			Assert.fail('the suite runs from a tree\'s bin/');
			return;
		}
		TempDir.with(dir -> {
			final base: String = engine(dir.file('base.js'), 'A');
			final tip: String = engine(dir.file('tip.js'), 'B');
			final files: Map<String, String> = ['log' => 'start\n'];
			final runs: Array<Comparison> = Parity.compare(tree, base, tip, [
				{
					name: 'same',
					argv: ['apq', 'echo', 'x'],
					stdin: 'in',
					files: files
				},
				{
					name: 'writes',
					argv: ['hxq', 'write'],
					stdin: null,
					files: files
				}
			], 2, false);
			Assert.same([], runs[0].differences, 'each side appends to a fresh log');
			Assert.equals('echo x in\n', runs[0].tip.out);
			Assert.equals('start\necho x in\n', runs[0].tip.files['log']);
			Assert.equals('write --lang-default haxe \n', runs[1].base.out, 'the hxq shim adds its language');
			Assert.same(['files differ: out.txt'], runs[1].differences);
		});
	}

	public function testTheEngineArgvIsWhatTheShimPassesOn(): Void {
		Assert.same(['fmt', '--lang-default', 'haxe', 'A.hx'], Parity.engineArgv(['hxq', 'fmt', 'A.hx']));
		Assert.same(['get', 'a.json', 'x'], Parity.engineArgv(['apq', 'get', 'a.json', 'x']));
		Assert.same([], Parity.engineArgv(['hxq']));
	}

	public function testAnEngineWithNoBatchEntryFailsEveryInvocationOfItsShare(): Void {
		final tree: Null<String> = Repo.ofScript();
		if (tree == null) {
			Assert.fail('the suite runs from a tree\'s bin/');
			return;
		}
		TempDir.with(dir -> {
			final stand: String = engine(dir.file('a.js'), 'A');
			final invocations: Array<Invocation> = [
				for (name in ['one', 'two'])
					{
						name: name,
						argv: ['apq', 'echo', name],
						stdin: null,
						files: []
					}
			];
			final outcomes: Array<Outcome> = TempDir.with(work -> Parity.side(tree, stand, invocations, work, 1, true));
			Assert.same([null, null], [for (outcome in outcomes) outcome.status]);
			for (outcome in outcomes) Assert.stringContains('apq --batch gave no answer', outcome.failure);
		});
	}

	@:pin('control')
	@:killer('M-PARITY-ONE-PROCESS-UNASKED')
	public function testOneProcessIsChosenOnlyForAnEngineThatAnswersTheBatchEntry(): Void {
		final tree: Null<String> = Repo.ofScript();
		if (tree == null) {
			Assert.fail('the suite runs from a tree\'s bin/');
			return;
		}
		TempDir.with(dir -> {
			final base: String = engine(dir.file('base.js'), 'A');
			final tip: String = engine(dir.file('tip.js'), 'B');
			final real: String = Path.join([tree, 'bin', 'apq.js']);
			Assert.isFalse(Parity.oneProcessFor(base, true), 'a stand-in engine has no batch entry');
			Assert.isTrue(Parity.oneProcessFor(real, true), 'this tree\'s engine has it');
			Assert.isFalse(Parity.oneProcessFor(real, false), 'per process when one process is not wanted');
			final invocations: Array<Invocation> = [
				for (name in ['one', 'two', 'three'])
					{
						name: name,
						argv: ['apq', 'echo', name],
						stdin: 'in',
						files: ['log' => '']
					}
			];
			final apart: Array<Comparison> = Parity.compare(tree, base, tip, invocations, 2, false);
			final wanted: Array<Comparison> = Parity.compare(tree, base, tip, invocations, 2, true);
			for (i => run in wanted) {
				Assert.equals(0, run.tip.status, 'answered, not failed: ${run.tip.failure}');
				Assert.equals(apart[i].tip.out, run.tip.out);
				Assert.same(apart[i].differences, run.differences);
			}
		});
	}

	/** A stand-in engine at `file`: echoes its arguments and standard input, logs them, and writes `mark` on `write`. */
	private static function engine(file: String, mark: String): String {
		File.saveContent(file, [
			// the shim downgrades `--lang-default` for an engine whose text never spells it
			'// takes --lang-default',
			"const fs = require('fs');",
			'const a = process.argv.slice(2);',
			"const input = a[0] === 'echo' ? fs.readFileSync(0, 'utf8') : '';",
			"const line = a.join(' ') + ' ' + input + '\\n';",
			"fs.appendFileSync('log', line);",
			'if (a[0] === "write") fs.writeFileSync("out.txt", "$mark");',
			'process.stdout.write(line);'
		].join('\n'));
		return Path.normalize(file);
	}

	private static function outcome(status: Int, out: String, files: Map<String, String>): Outcome {
		return {
			status: status,
			out: out,
			err: '',
			failure: '',
			files: files
		};
	}

}
