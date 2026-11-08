package unit.dev;

import dev.KitsRow;
import dev.Probe;
import dev.RedOnBase;
import dev.Repo;
import devkit.Cmd.cmd;
import devkit.Summary;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `dev.RedOnBase` end to end over a fixture repository: the base commit is checked out, built, and the candidate's failing
 * tests or kit rows re-run there, so a row reads `yes`, `partly` or `no` from what the base itself does.
 */
@:nullSafety(Strict)
final class RedOnBaseRerunTest extends Test {

	/** What a build of the fixture does: leave the mark that its binary needs to run. */
	private static inline final MARK: String = "require('fs').writeFileSync(process.argv[2], 'built');";

	/**
	 * The fake test runner of the base. It lists its classes, refuses to run unbuilt or to run a class it does not list, and reports
	 * each test of `red.txt` whose class it was asked for as a failing utest row; a class counts once however it is sliced.
	 */
	private static final RUNNER: String = [
		"const fs = require('fs'), path = require('path');",
		"const read = name => fs.readFileSync(path.join(__dirname, name), 'utf8').split('\\n').filter(l => l);",
		'(function () {',
		"const classes = read('classes.txt');",
		"if (process.argv.includes('--list-classes')) return process.stdout.write(classes.join('\\n') + '\\n');",
		"if (!fs.existsSync(path.join(__dirname, '..', 'test.built'))) {"
			+ " process.exitCode = 2; return process.stderr.write('not built\\n'); }",
		"const tokens = (process.env.APQ_TEST || '').split(',').filter(t => t);",
		"const run = tokens.length === 0 ? classes : tokens.map(t => t.split('#')[0]);",
		"if (run.some(c => !classes.includes(c))) { process.exitCode = 2; return process.stderr.write('no such class\\n'); }",
		"const counted = tokens.length === 0 ? classes : tokens.filter(t => !t.includes('#') || t.split('#')[1].startsWith('0/'));",
		"const red = read('red.txt').filter(t => run.includes(t.substring(0, t.lastIndexOf('.'))));",
		'const n = counted.length + red.length;',
		"const rows = run.filter(c => red.some(t => t.startsWith(c + '.'))).map(c => c + '\\n' + red.filter(t => t.startsWith(c + '.'))",
		"  .map(t => '  ' + t.substring(c.length + 1) + ': FAIL\\n    line: 1, nope\\n').join('')).join('');",
		"process.stdout.write(rows + 'tests executed: ' + n + '\\nassertations: ' + 2 * n + '\\nsuccesses: ' + (2 * n - red.length)",
		"  + '\\nerrors: 0\\nfailures: ' + red.length + '\\nwarnings: 0\\nresults: (success: ' + (red.length === 0) + ')\\n');",
		'process.exitCode = red.length === 0 ? 0 : 1;',
		'})();'
	].join('\n');

	/**
	 * The fake engine of the base: it echoes its arguments, adds `BROKEN`
	 * for a command line of `broken.txt`, and refuses to run unbuilt.
	 */
	private static final ENGINE: String = [
		"const fs = require('fs'), path = require('path');",
		"if (!fs.existsSync(path.join(__dirname, '..', 'engine.built'))) { process.stderr.write('not built\\n'); process.exit(1); }",
		"const broken = fs.readFileSync(path.join(__dirname, 'broken.txt'), 'utf8').split('\\n').filter(l => l);",
		"const line = process.argv.slice(2).join(' ');",
		"process.stdout.write(line + (broken.includes(line) ? ' BROKEN' : '') + '\\n');"
	].join('\n');

	private static final KIT_ALPHA: String =
		'{"files":{},"invocations":[{"name":"one","argv":["apq","one"]},{"name":"two","argv":["apq","two"]}]}';
	private static final KIT_BETA: String = '{"files":{},"invocations":[{"name":"one","argv":["apq","one"]}]}';

	/**
	 * A failing test is red on the base when the base fails that very test, and each reading comes from a run of the base commit
	 * itself, built first: the candidate's own tree (a later commit that fails more) never answers.
	 */
	@:pin('control')
	@:killer('M-REDONBASE-SUITE-BASE-NOT-BUILT')
	@:killer('M-REDONBASE-RERUN-FAILING-NOT-COLLECTED')
	@:killer('M-REDONBASE-RERUN-UNLISTED-CLASS-RUN')
	public function testAFailingTestIsReadOnTheBuiltBaseCommitTestByTest(): Void {
		TempDir.with(dir -> {
			final repo: String = suiteRepo(dir);
			final request: BaseRerun = requestOf(repo, base(repo, 'HEAD~1'), dir);
			final both: Array<String> = ['unit.A.testOne', 'unit.B.testTwo'];
			Assert.same(OnBase.Red(['unit.A.testOne']), RedOnBase.suite(request, ['unit.A.testOne']));
			Assert.same(OnBase.Partly(['unit.A.testOne'], ['unit.B.testTwo']), RedOnBase.suite(request, both));
			final green: OnBase = RedOnBase.suite(request, ['unit.B.testTwo']);
			Assert.same(OnBase.Green, green);
			Assert.equals('red on base: no', RedOnBase.note(green));
			Assert.same(OnBase.Green, RedOnBase.suite(request, ['unit.A.testNine']), 'another method of a red class is not red there');
			Assert.same(OnBase.Green, RedOnBase.suite(request, ['unit.New.testAdded']), 'a class the base lacks is not red there');
			Assert.isFalse(cmd('git -C $repo worktree list --porcelain').text().contains('/base'), 'the base trees are removed');
		});
	}

	/** A failure that names no test class gives the base nothing to run: the reading is unknown, not green. */
	@:pin('control')
	@:killer('M-REDONBASE-SUITE-NO-CLASS-RUN')
	public function testAFailureNamingNoClassIsUnknown(): Void {
		TempDir.with(dir -> {
			final repo: String = suiteRepo(dir);
			Assert.same(
				OnBase.Unknown('the failing run names no test class'), RedOnBase.suite(requestOf(repo, base(repo, 'HEAD~1'), dir), [])
			);
		});
	}

	/**
	 * A failing kit row is red on the base only where the same row of the same area fails there: another row of an area that is
	 * red on the base is the candidate's own, and a kit is read from the base's own built engine.
	 */
	@:pin('control')
	@:killer('M-REDONBASE-KITS-COMPARE-BY-AREA')
	@:killer('M-REDONBASE-KITS-BASE-NOT-BUILT')
	public function testAKitRowIsReadRowByRowOnTheBuiltBaseCommit(): Void {
		final tree: Null<String> = Repo.ofScript();
		if (tree == null) {
			Assert.fail('the suite runs from a tree\'s bin/');
			return;
		}
		TempDir.with(dir -> {
			final repo: String = kitsRepo(dir, tree);
			final request: BaseRerun = requestOf(repo, base(repo), dir);
			Assert.same(OnBase.Red(['alpha #1 two']), RedOnBase.kits(request, ['alpha #1 two']));
			Assert.same(OnBase.Green, RedOnBase.kits(request, ['alpha #0 one']), 'a sound row of a red area is not red there');
			Assert.same(OnBase.Green, RedOnBase.kits(request, ['beta #0 one']));
			final partly: OnBase = RedOnBase.kits(request, ['alpha #0 one', 'alpha #1 two']);
			Assert.same(OnBase.Partly(['alpha #1 two'], ['alpha #0 one']), partly);
			Assert.equals('red on base: partly (yes: alpha #1 two; no: alpha #0 one)', RedOnBase.note(partly));
		});
	}

	/** The report of the kits names each failing row as `<area> #<index> <name>`, and only a row that fails. */
	@:pin('control')
	@:killer('M-PROBE-ROWS-NOT-NAMED')
	@:killer('M-PROBE-CHECKALL-ROWS-WITHOUT-AREA')
	public function testTheKitsReportNamesTheFailingRows(): Void {
		final tree: Null<String> = Repo.ofScript();
		if (tree == null) {
			Assert.fail('the suite runs from a tree\'s bin/');
			return;
		}
		TempDir.with(dir -> {
			final repo: String = kitsRepo(dir, tree);
			File.saveContent(Path.join([repo, 'bin', 'broken.txt']), 'two\none\n');
			File.saveContent(Path.join([repo, 'engine.built']), 'built');
			Assert.same(['alpha #0 one', 'alpha #1 two', 'beta #0 one'], Probe.checkAll(repo, 2).rows);
			File.saveContent(Path.join([repo, 'bin', 'broken.txt']), '');
			Assert.same([], Probe.checkAll(repo, 2).rows);
		});
	}

	/**
	 * The kits row of a red tree hands its hook the failing rows (`<area> #<index> <name>`), the very names that
	 * `RedOnBase.kits` compares with the base's: the land chain from the row to the reading on the base.
	 */
	@:pin('control')
	@:killer('M-KITSROW-HOOK-GETS-AREAS')
	public function testTheKitsRowHandsItsFailingRowsToTheHook(): Void {
		final tree: Null<String> = Repo.ofScript();
		if (tree == null) {
			Assert.fail('the suite runs from a tree\'s bin/');
			return;
		}
		TempDir.with(dir -> {
			final repo: String = kitsRepo(dir, tree);
			File.saveContent(Path.join([repo, 'engine.built']), 'built');
			var handed: Array<String> = [];
			final outcome: Outcome = KitsRow.outcome(repo, new Summary(), _ -> {}, rows -> handed = rows);
			Assert.same(['alpha #1 two'], handed);
			Assert.isTrue(outcome.match(Failed(_)));
		});
	}

	private static function requestOf(repo: String, base: String, dir: TempDir): BaseRerun {
		return {
			repo: repo,
			base: base,
			log: dir.file('red-on-base.log'),
			shards: 1,
			mode: Unpooled
		};
	}

	/**
	 * A repository whose base commit has a runner listing `unit.A` and `unit.B` and failing `unit.A.testOne`, and a later commit
	 * that fails `unit.B.testTwo` too.
	 */
	private static function suiteRepo(dir: TempDir): String {
		final repo: String = skeleton(dir.file('suite'));
		File.saveContent(Path.join([repo, 'bin', 'test.js']), RUNNER);
		File.saveContent(Path.join([repo, 'bin', 'classes.txt']), 'unit.A\nunit.B\n');
		File.saveContent(Path.join([repo, 'bin', 'red.txt']), 'unit.A.testOne\n');
		commit(repo, 'base');
		File.saveContent(Path.join([repo, 'bin', 'red.txt']), 'unit.A.testOne\nunit.B.testTwo\n');
		commit(repo, 'candidate');
		return repo;
	}

	/**
	 * A repository whose base commit holds two kits recorded on a sound engine and the same engine broken for `apq two`, so the
	 * base fails exactly `alpha #1 two`. Its work tree stays unbuilt: no `engine.built`.
	 */
	private static function kitsRepo(dir: TempDir, tree: String): String {
		final repo: String = skeleton(dir.file('kits'));
		for (shim in ['apq', 'hxq']) File.copy(Path.join([tree, 'bin', shim]), Path.join([repo, 'bin', shim]));
		File.saveContent(Path.join([repo, 'bin', 'apq.js']), ENGINE);
		File.saveContent(Path.join([repo, 'bin', 'broken.txt']), '');
		File.saveContent(Path.join([repo, 'engine.built']), 'built');
		for (area => kit in ['alpha' => KIT_ALPHA, 'beta' => KIT_BETA]) {
			final folder: String = Path.join([repo, Probe.KITS, area]);
			FileSystem.createDirectory(folder);
			final file: String = Path.join([folder, Probe.KIT_FILE]);
			File.saveContent(file, kit);
			Probe.write(file, Probe.observe(tree, Path.join([repo, 'bin', 'apq.js']), Probe.load(file), false, 2, false));
		}
		FileSystem.deleteFile(Path.join([repo, 'engine.built']));
		File.saveContent(Path.join([repo, 'bin', 'broken.txt']), 'two\n');
		commit(repo, 'base');
		return repo;
	}

	/** A git repository in `repo` whose two hxml builds only leave the mark their binary needs. */
	private static function skeleton(repo: String): String {
		FileSystem.createDirectory(repo);
		FileSystem.createDirectory(Path.join([repo, 'bin']));
		File.saveContent(Path.join([repo, 'mark.js']), MARK);
		File.saveContent(Path.join([repo, 'test-js.hxml']), '--cmd node mark.js test.built\n');
		File.saveContent(Path.join([repo, 'bin', 'apq-js.hxml']), '--cmd node mark.js engine.built\n');
		cmd('git -C $repo init -q').check();
		return repo;
	}

	private static function commit(repo: String, message: String): Void {
		cmd('git -C $repo add -A').check();
		cmd('git -C $repo -c user.name=t -c user.email=t@t commit -q -m $message').check();
	}

	private static function base(repo: String, revision: String = 'HEAD'): String {
		return cmd('git -C $repo rev-parse $revision').text().trim();
	}

}
