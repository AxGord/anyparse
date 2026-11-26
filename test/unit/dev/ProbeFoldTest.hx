package unit.dev;

import dev.Probe;
import dev.ProbeFold;
import dev.Repo;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * `dev.ProbeFold`: what becomes of a probe-additions row on an engine — dropped when the engine answers as the row expects,
 * appended to its area's kit as a known defect when it does not, queued when it cannot be judged or placed.
 */
@:nullSafety(Strict)
final class ProbeFoldTest extends Test {

	@:pin('control')
	@:killer('M-PROBE-FOLD-DROP-BLIND')
	public function testARowTheEngineAnswersAsItExpectsIsDropped(): Void {
		withTree((tree, dir) -> {
			final rows: String = recorded(tree, dir, 'cli', engine(dir.file('a.js'), 'A'));
			final folds: Array<Fold> = ProbeFold.fold(tree, dir.file('repo'), engine(dir.file('a.js'), 'A'), rows, 2, false);
			Assert.same(['Drop'], folds.map(fold -> Type.enumConstructor(fold.outcome)));
		});
	}

	@:pin('control')
	@:killer('M-PROBE-FOLD-KIT-UNMARKED')
	public function testADeviatingRowOfAKnownAreaJoinsItsKitAsAKnownDefect(): Void {
		withTree((tree, dir) -> {
			final a: String = engine(dir.file('a.js'), 'A');
			final b: String = engine(dir.file('b.js'), 'B');
			final rows: String = recorded(tree, dir, 'cli', a);
			final repo: String = dir.file('repo');
			final folds: Array<Fold> = ProbeFold.fold(tree, repo, b, rows, 2, false);
			Assert.same(['ToKit'], folds.map(fold -> Type.enumConstructor(fold.outcome)));
			Assert.same(['KIT r1 -> test/probes/cli/kit.json'], ProbeFold.apply(repo, folds));
			final kitFile: String = Probe.kitPath(repo, 'cli');
			final kit: Kit = Probe.load(kitFile);
			Assert.same(['r1'], kit.invocations.map(row -> row.name));
			Assert.notNull(kit.cases[0].knownDefect, 'the row is marked: the recorded answer is not the expected one');
			Assert.same(
				[[]],
				Probe.observe(tree, b, kit, false, 2, false).map(seen -> Probe.deviations(kit.cases[0].expect, seen, false)),
				'the kit holds on the engine that gave the recorded answer'
			);
			Assert.equals(
				1, Probe.deviations(kit.cases[0].expect, Probe.observe(tree, a, kit, false, 2, false)[0], false).length,
				'and moves on the engine that answers as the row expected'
			);
			Assert.same(
				['ToQueue'],
				ProbeFold.fold(tree, repo, b, rows, 2, false).map(fold -> Type.enumConstructor(fold.outcome)),
				'a second fold of the same row finds the name taken'
			);
		});
	}

	@:pin('control')
	@:killer('M-PROBE-FOLD-QUEUE-UNJUDGED')
	public function testARowWithNoExpectedAnswerOrNoAreaIsQueuedQuotingItsArgv(): Void {
		withTree((tree, dir) -> {
			final repo: String = dir.file('repo');
			final b: String = engine(dir.file('b.js'), 'B');
			final bare: String = dir.file('bare.json');
			File.saveContent(bare, rowsOf('cli'));
			final queued: Array<Fold> = ProbeFold.fold(tree, repo, b, bare, 2, false);
			Assert.same(['ToQueue'], queued.map(fold -> Type.enumConstructor(fold.outcome)));
			Assert.same([], ProbeFold.apply(repo, []));
			final text: String = switch queued[0].outcome {
				case ToQueue(held): held;
				case _: '';
			}
			Assert.stringContains('`apq echo y`', text);
			Assert.stringContains('echo answers its marker', text);
			Assert.stringContains('no expected answer', text);
			final lost: String = recorded(tree, dir, 'nowhere', engine(dir.file('a.js'), 'A'));
			final unplaced: Array<Fold> = ProbeFold.fold(tree, repo, b, lost, 2, false);
			Assert.stringContains(
				'no kit area nowhere', switch unplaced[0].outcome {
					case ToQueue(held): held;
					case _: '';
				}
			);
			Assert.isFalse(FileSystem.exists(Path.join([repo, Probe.KITS, 'nowhere'])), 'an unknown area is never created');
		});
	}

	@:pin('control')
	@:killer('M-PROBE-FOLD-FILES-INHERITED')
	public function testAKitRowKeepsTheFilesItWasObservedWithNotTheKitsShared(): Void {
		withTree((tree, dir) -> {
			final repo: String = dir.file('repo');
			final kitFile: String = Probe.kitPath(repo, 'cli');
			File.saveContent(kitFile, '{"files":{"K.txt":"k\\n"},"invocations":[]}\n');
			final b: String = engine(dir.file('b.js'), 'B');
			final folds: Array<Fold> = ProbeFold.fold(tree, repo, b, recorded(tree, dir, 'cli', engine(dir.file('a.js'), 'A')), 2, false);
			Assert.same(['KIT r1 -> test/probes/cli/kit.json'], ProbeFold.apply(repo, folds));
			final kit: Kit = Probe.load(kitFile);
			Assert.same(
				[[]],
				Probe.observe(tree, b, kit, false, 2, false).map(seen -> Probe.deviations(kit.cases[0].expect, seen, false)),
				'the row runs in the tree it was observed in, not in the kit\'s K.txt'
			);
		});
	}

	@:pin('control')
	@:killer('M-PROBE-FOLD-MAIN-ROW-UNROUTED')
	public function testTheRowOptionReachesTheFoldThroughMainWithoutAKitPositional(): Void {
		withTree((tree, dir) -> {
			final repo: String = dir.file('repo');
			final rows: String = recorded(tree, dir, 'cli', engine(dir.file('a.js'), 'A'));
			final b: String = engine(dir.file('b.js'), 'B');
			Assert.equals(0, Probe.main(['--row', rows, '--engine', b, '--repo', repo, '--threads', '2']));
			Assert.same(['r1'], Probe.load(Probe.kitPath(repo, 'cli')).invocations.map(row -> row.name));
		});
	}

	@:pin('control')
	@:killer('M-PROBE-FOLD-PLACED-NAME-FORGOTTEN')
	public function testTwoDeviatingRowsOfOneNameDoNotBothJoinTheKit(): Void {
		withTree((tree, dir) -> {
			final rows: String = dir.file('twice.json');
			final row: String = '{"name":"r1","argv":["apq","echo","y"]}';
			File.saveContent(rows, '{"area":"cli","invocations":[$row,$row]}');
			Probe.write(rows, Probe.observe(tree, engine(dir.file('a.js'), 'A'), Probe.load(rows), false, 2, false));
			final folds: Array<Fold> = ProbeFold.fold(tree, dir.file('repo'), engine(dir.file('b.js'), 'B'), rows, 2, false);
			Assert.same(['ToKit', 'ToQueue'], folds.map(fold -> Type.enumConstructor(fold.outcome)));
		});
	}

	private static function withTree(body: (String, TempDir) -> Void): Void {
		final tree: Null<String> = Repo.ofScript();
		if (tree == null) {
			Assert.fail('the suite runs from a tree\'s bin/');
			return;
		}
		TempDir.with(dir -> {
			final kits: String = Path.join([dir.file('repo'), Probe.KITS, 'cli']);
			FileSystem.createDirectory(dir.file('repo'));
			FileSystem.createDirectory(Path.join([dir.file('repo'), 'test']));
			FileSystem.createDirectory(Path.join([dir.file('repo'), Probe.KITS]));
			FileSystem.createDirectory(kits);
			File.saveContent(Path.join([kits, Probe.KIT_FILE]), '{"invocations":[]}\n');
			FileSystem.createDirectory(dir.file('repo/bin'));
			for (shim in ['apq', 'hxq']) File.copy(Path.join([tree, 'bin', shim]), dir.file('repo/bin/$shim'));
			body(tree, dir);
		});
	}

	private static function rowsOf(area: String): String {
		return '{"area":"$area","invocations":[{"name":"r1","note":"echo answers its marker","argv":["apq","echo","y"]}]}';
	}

	private static function recorded(tree: String, dir: TempDir, area: String, engine: String): String {
		final file: String = dir.file('rows-$area.json');
		File.saveContent(file, rowsOf(area));
		Probe.write(file, Probe.observe(tree, engine, Probe.load(file), false, 2, false));
		return file;
	}

	private static function engine(file: String, mark: String): String {
		File.saveContent(file, [
			// the shim downgrades `--lang-default` for an engine whose text never spells it
			'// takes --lang-default',
			'const a = process.argv.slice(2);',
			'const listing = require("fs").readdirSync(".").sort().join(",");',
			'process.stdout.write("$mark " + a.join(" ") + " [" + listing + "]\\n");'
		].join('\n'));
		return Path.normalize(file);
	}

}
