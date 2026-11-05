package unit.dev;

import anyparse.grammar.json.JsonText;
import dev.Expectation;
import dev.Parity.Outcome;
import dev.Probe;
import dev.Repo;
import devkit.TempDir;
import haxe.io.Path;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * `dev.Probe`: what deviates between a recorded answer and a new one, the run directory and the staged-probe pid normalized out
 * of a stream, and a tiny kit recorded on one stand-in engine that holds on it and deviates on another.
 */
@:nullSafety(Strict)
final class ProbeTest extends Test {

	@:pin('control')
	@:killer('M-PROBE-EXIT-BLIND')
	public function testTheDeviationsNameTheExitTheStreamsTheFilesAndTheCompiles(): Void {
		final recorded: Expectation = answer(0, 'a', [true, false]);
		Assert.same([], Probe.deviations(recorded, seen(answer(0, 'a', [true, false]), 'x'), true));
		Assert.same([
			'exit: 0 → 1',
			'stdout: digest a → b, now `first`',
			'files written: digest a → b',
			'compiles with define set #1: false → true'
		], Probe.deviations(recorded, seen(answer(1, 'b', [true, true]), 'first\nsecond'), true));
		Assert.same(['exit: 0 → 1'], Probe.deviations(recorded, seen(answer(1, 'a', [true, true]), ''), false), 'compiles unchecked');
		Assert.same(['not recorded: `dev probe --record` writes the expectation'], Probe.deviations(null, seen(recorded, ''), true));
	}

	@:pin('control')
	@:killer('M-PROBE-FAILURE-DROPPED')
	public function testAnInvocationWithNoAnswerNamesItsCause(): Void {
		final recorded: Expectation = answer(0, 'a', []);
		final failure: String = 'apq --batch gave no answer: boom';
		Assert.same([], Probe.deviations(recorded, seen(recorded, '', failure), false), 'a cause alone deviates nothing');
		final kit: Kit = {
			invocations: [
				{
					name: 'lost',
					argv: ['apq', 'echo'],
					stdin: null,
					files: []
				}
			],
			cases: [
				{
					compile: null,
					expect: recorded,
					knownDefect: null,
					fixpoint: null
				}
			]
		};
		Assert.same([
			'DEVIATES #0 lost: apq echo',
			'  failure: $failure',
			'  exit: 0 → 1'
		], Probe.judge(kit, [seen(answer(1, 'a', []), '', failure)], false).lines);
	}

	@:pin('control')
	@:killer('M-PROBE-SAME-RUN-BLIND')
	public function testARunSpecComparesWhatTheFixedAndTheOriginalProgramPrint(): Void {
		final tree: Null<String> = Repo.ofScript();
		if (tree == null) {
			Assert.fail('the suite runs from a tree\'s bin/');
			return;
		}
		TempDir.with(dir -> {
			final kitFile: String = dir.file('kit.json');
			final program: String = 'class Main { static function main() { Sys.println("one"); } }\n';
			File.saveContent(
				kitFile,
				'{"compile":{"args":["-cp",".","-main","Main","--interp"],"defines":[[]],"run":true},"invocations":['
				+ '{"name":"same","argv":["hxq","keep"],"files":{"Main.hx":${JsonText.quote(program)}}},'
				+ '{"name":"changes","argv":["hxq","change"],"files":{"Main.hx":${JsonText.quote(program)}}}]}'
			);
			final engineFile: String = dir.file('e.js');
			File.saveContent(engineFile, [
				'// takes --lang-default',
				"const fs = require('fs');",
				"if (process.argv[2] === 'change') fs.writeFileSync('Main.hx', fs.readFileSync('Main.hx', 'utf8').replace('one', 'two'));"
			].join('\n'));
			final seen: Array<Seen> = Probe.observe(tree, Path.normalize(engineFile), Probe.load(kitFile), true, 2, false);
			Assert.same([true], seen[0].answer.compiles);
			Assert.same([true], seen[0].answer.sameRun);
			Assert.same([true], seen[1].answer.compiles, 'the changed program still compiles');
			Assert.same([false], seen[1].answer.sameRun, 'but prints something else');
			final was: Expectation = {
				exit: 0,
				out: '',
				err: '',
				files: '',
				sameRun: [true]
			};
			Assert.same(
				['runs print the same as the original with define set #0: true → false'],
				Probe.deviations(was, seen[1], true).filter(line -> line.indexOf('runs print') == 0)
			);
		});
	}

	public function testTheRunDirectoryAndTheProbePidAreNormalized(): Void {
		Assert.equals(
			'<fixture>/a.hx and /t/anyparse-last-probe.N.hx',
			Probe.normalize('/no/such/run/a.hx and /t/anyparse-last-probe.4242.hx', '/no/such/run')
		);
	}

	@:pin('control')
	@:killer('M-PROBE-ONE-PASS-BLIND')
	public function testATinyKitRecordedOnOneEngineHoldsThereAndDeviatesOnAnother(): Void {
		final tree: Null<String> = Repo.ofScript();
		if (tree == null) {
			Assert.fail('the suite runs from a tree\'s bin/');
			return;
		}
		TempDir.with(dir -> {
			final kitFile: String = dir.file('kit.json');
			File.saveContent(
				kitFile,
				'{"files":{"in.txt":"x\\n"},"compile":{"args":["--version"],"defines":[[],["--no-such-haxe-flag"]]},"invocations":['
				+ '{"name":"writes","argv":["hxq","write"]},{"name":"echoes","argv":["apq","echo","y"],"stdin":"in"},'
				+ '{"name":"formats","argv":["apq","fmt","in.txt"],"fixpoint":"in.txt"}]}'
			);
			final a: String = engine(dir.file('a.js'), 'A');
			final b: String = engine(dir.file('b.js'), 'B');
			Probe.write(kitFile, Probe.observe(tree, a, Probe.load(kitFile), true, 2, false));
			final kit: Kit = Probe.load(kitFile);
			Assert.same([true, false], kit.cases[0].expect?.compiles, 'haxe ran once per define set on the written fixture');
			final again: Array<Seen> = Probe.observe(tree, a, kit, true, 2, false);
			Assert.same([[], [], []], [for (i => row in again) Probe.deviations(kit.cases[i].expect, row, true)]);
			Assert.isTrue(kit.cases[2].expect?.onePass == true && kit.cases[2].expect?.commentsKept == true, 'A formats to a fixed point');
			final other: Array<Seen> = Probe.observe(tree, b, kit, true, 2, false);
			Assert.equals(1, Probe.deviations(kit.cases[0].expect, other[0], true).length, 'only what B writes differs');
			Assert.same([], Probe.deviations(kit.cases[1].expect, other[1], true));
			Assert.same([
				'stdout: digest ${kit.cases[2].expect?.out} → ${other[2].answer.out}, now `x`',
				'one pass (a second run over the output is a fixed point): true → false',
				'comments kept: true → false'
			], Probe.deviations(kit.cases[2].expect, other[2], true));
		});
	}

	@:pin('control')
	@:killer('M-PROBE-KNOWN-DEFECT-COUNTED')
	public function testAKnownDefectRowThatMovesIsReportedApartAndFailsNothing(): Void {
		final recorded: Expectation = answer(0, 'a', []);
		final kit: Kit = {
			invocations: [
				{
					name: 'plain',
					argv: ['apq', 'x'],
					stdin: null,
					files: []
				},
				{
					name: 'known',
					argv: ['apq', 'y'],
					stdin: null,
					files: []
				}
			],
			cases: [
				{
					compile: null,
					expect: recorded,
					knownDefect: null,
					fixpoint: null
				},
				{
					compile: null,
					expect: recorded,
					knownDefect: 'refuses a legal shape',
					fixpoint: null
				}
			]
		};
		final moved: Array<Seen> = [seen(answer(0, 'a', []), ''), seen(answer(1, 'a', []), '')];
		final verdict: Verdict = Probe.judge(kit, moved, false);
		Assert.equals(0, verdict.deviating);
		Assert.equals(1, verdict.knownMoved);
		Assert.same([
			'KNOWN-DEFECT ROW MOVED (maybe fixed) #1 known: refuses a legal shape',
			'  exit: 0 → 1'
		], verdict.lines);
		final both: Verdict = Probe.judge(kit, [moved[1], moved[1]], false);
		Assert.equals(1, both.deviating, 'an unmarked row still deviates');
	}

	public function testTheCommentsAreAMultisetOfLineAndBlockComments(): Void {
		Assert.same(['/* b c */', '// a', '// a'], Probe.commentsOf('x // a\ny /* b\n   c */ z // a\n'));
		Assert.same([], Probe.commentsOf('no comment'));
	}

	/** `--record` takes `--compile` as it takes every flag the other modes do, and the compile verdicts land in the kit. */
	public function testRecordAcceptsCompileAndWritesTheVerdicts(): Void {
		final tree: Null<String> = Repo.ofScript();
		if (tree == null) {
			Assert.fail('the suite runs from a tree\'s bin/');
			return;
		}
		TempDir.with(dir -> {
			final kitFile: String = dir.file('kit.json');
			File.saveContent(
				kitFile,
				'{"compile":{"args":["--version"],"defines":[[],["--no-such-haxe-flag"]]},'
				+ '"invocations":[{"name":"echoes","argv":["apq","echo","y"],"stdin":"in"}]}'
			);
			final status: Int = Probe.main([
				kitFile,
				'--engine',
				engine(dir.file('a.js'), 'A'),
				'--record',
				'--compile',
				'--repo',
				tree
			]);
			Assert.equals(0, status);
			Assert.same([true, false], Probe.load(kitFile).cases[0].expect?.compiles);
		});
	}

	/** A row recording a shape holds when the list changes under it and deviates when a line leaves the shape. */
	public function testAShapeRowIgnoresWhatTheListHoldsAndNotesALineOffTheShape(): Void {
		final shape: String = '^[a-z]+ +\\S';
		Assert.equals(Probe.digest('every line fits'), Probe.digest(Probe.shapeOf('abc  one\nxy  two\n', shape)));
		Assert.equals(Probe.shapeOf('abc  one\n', shape), Probe.shapeOf('abc  one\nxy  two\nzz  three\n', shape));
		Assert.notEquals(Probe.shapeOf('abc  one\n', shape), Probe.shapeOf('abc  one\n!oops\n', shape));
		Assert.notEquals(Probe.shapeOf('abc  one\n', shape), Probe.shapeOf('\n', shape), 'an empty list is not the shape');
		Assert.equals('every line fits', Probe.shapeOf('abc  one\nxy  two\n', shape, 2));
		Assert.notEquals('every line fits', Probe.shapeOf('abc  one\n', shape, 2), 'a list under its floor is not the shape');
		final outcome: Outcome = {
			status: 0,
			failure: '',
			out: 'abc  one\nxy  two\n',
			err: '',
			files: []
		};
		final shorter: Outcome = {
			status: 0,
			failure: '',
			out: 'abc  one\n',
			err: '',
			files: []
		};
		Assert.equals(Probe.answerOf([], outcome, '/d', shape).out, Probe.answerOf([], shorter, '/d', shape).out);
		Assert.notEquals(
			Probe.answerOf([], outcome, '/d').out, Probe.answerOf([], shorter, '/d').out, 'without a shape the list is the answer'
		);
	}

	/**
	 * A kit run fails on a deviating row and, when strict, on a known-defect
	 * row that moved; the areas are the directories holding a kit.
	 */
	public function testAStrictRunFailsOnAMovedKnownDefectAndTheAreasAreTheKitDirectories(): Void {
		Assert.isTrue(Probe.holds({ lines: [], deviating: 0, knownMoved: 1 }, false));
		Assert.isFalse(Probe.holds({ lines: [], deviating: 0, knownMoved: 1 }, true));
		Assert.isFalse(Probe.holds({ lines: [], deviating: 1, knownMoved: 0 }, false));
		TempDir.with(dir -> {
			final kits: String = dir.file(Probe.KITS);
			sys.FileSystem.createDirectory(dir.file('test'));
			sys.FileSystem.createDirectory(kits);
			for (area in ['z', 'a', 'empty']) sys.FileSystem.createDirectory(Path.join([kits, area]));
			for (area in ['z', 'a']) File.saveContent(Path.join([kits, area, Probe.KIT_FILE]), '{}');
			Assert.same(['a', 'z'], Probe.areas(dir.file('')));
			Assert.same([], Probe.areas(dir.file('no-such-tree')));
		});
	}

	public function testOneProcessAnswersEachInvocationAsItsOwnProcessDoes(): Void {
		final tree: Null<String> = Repo.ofScript();
		if (tree == null) {
			Assert.fail('the suite runs from a tree\'s bin/');
			return;
		}
		TempDir.with(dir -> {
			final kitFile: String = dir.file('kit.json');
			File.saveContent(
				kitFile,
				'{"files":{"A.hx":"class A {\\n  var x:Int;\\n}\\n","hxformat.json":"{\\"noSuchKnobAtAll\\": 1}"},"invocations":['
				+ '{"name":"formats","argv":["hxq","fmt","A.hx"]},{"name":"writes","argv":["hxq","fmt","--write","A.hx"]},'
				+ '{"name":"probes","argv":["hxq","probe","-"],"stdin":"var x = 1;"},{"name":"unknown","argv":["apq","no-such-command"]}]}'
			);
			Assert.same([], Probe.processParity(tree, Path.join([tree, 'bin', 'apq.js']), Probe.load(kitFile), 2));
		});
	}

	/** A stand-in engine at `file`: echoes its arguments, standard input and run directory, and writes `mark` on `write`. */
	private static function engine(file: String, mark: String): String {
		File.saveContent(file, [
			// the shim downgrades `--lang-default` for an engine whose text never spells it
			'// takes --lang-default',
			"const fs = require('fs');",
			'const a = process.argv.slice(2);',
			"const input = a[0] === 'echo' ? fs.readFileSync(0, 'utf8') : '';",
			'if (a[0] === "write") fs.writeFileSync("out.txt", "$mark");',
			// `fmt` of engine A is a fixed point keeping every comment; any other engine appends a comment on each pass
			"const text = a[0] === 'fmt' ? fs.readFileSync(a[a.length - 1], 'utf8') : '';",
			'const tail = "$mark" === "A" ? "" : "// $mark\\n";',
			"process.stdout.write(a[0] === 'fmt' ? text + tail : a.join(' ') + ' ' + input + ' in ' + process.cwd() + '\\n');"
		].join('\n'));
		return Path.normalize(file);
	}

	private static function answer(exit: Int, digest: String, compiles: Array<Bool>): Expectation {
		return {
			exit: exit,
			out: digest,
			err: 'e',
			files: digest,
			compiles: compiles
		};
	}

	private static function seen(answer: Expectation, out: String, failure: String = ''): Seen {
		return {
			answer: answer,
			out: out,
			err: '',
			failure: failure
		};
	}

}
