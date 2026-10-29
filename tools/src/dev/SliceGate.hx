package dev;

import anyparse.core.PoolLease;
import dev.GateTree.GateOptions;
import dev.Shard.Tally;
import devkit.Args;
import devkit.Branches;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.Lease;
import devkit.Lease.LeaseMode;
import devkit.Pool;
import devkit.Result;
import devkit.Summary;
import haxe.DynamicAccess;
import haxe.Json;
import haxe.Timer;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * `dev slice-gate <worktree>` — every gate a worker's slice must pass, as ONE command whose report is one row per gate
 * and a verdict, a failed row quoting its first error (docs/testing.md § "The slice gate"). `--baseline`, run once on the
 * untouched worktree, records what the gates later compare with: the base commit, the suite and registry counts, the
 * corpus snapshot, the whole-tree lint, the infra trees' lint and the frozen trees' diff digests. The rows run as
 * branches at once (`devkit.Branches`, each branch a `--rows` process of this tool): a run its caller gave a pool lease
 * splits that lease among them, and a run without one, inside a workflow, lets the build and each branch take a lease of
 * their own (`devkit.Lease`). Everything it writes goes to `<worktree>-logs/slice-gate/`, never into the worktree.
 */
@:nullSafety(Strict)
final class SliceGate {

	public static inline final USAGE: String = 'usage: dev slice-gate <worktree> [--baseline [--frozen <dir>]... [--infra-tree <dir>]...] '
		+ '[--arm <NAME>]... [--no-arms] [--allow <gate>]... [--logs <dir>]';

	/** What a branch may run before it is killed: a wedged run, not a slow one. */
	private static inline final BRANCH_TIMEOUT_MS: Int = 2 * 60 * 60 * 1000;

	/** The registries `bin/test.js` lists, each counted in the lists row. */
	private static final LISTINGS: Array<String> = ['classes', 'pins', 'arms', 'claims', 'dead', 'bases'];

	/**
	 * The branches of a gate run, all at once, each running its rows in order: `corpus` reads the sweep `suite` wrote,
	 * and `arms` follows them so the two heavy rows take the same threads one after the other; the three short rows share
	 * one branch, so they hold one thread between them.
	 */
	private static final GATE_BRANCHES: Array<Array<String>> = [
		['suite', 'corpus', 'arms'],
		['lists', 'fmt', 'scrub'],
		['lint'],
		['jvm'],
		['infra4']
	];

	/** The branches' rows in table order; `decisions`, `frozen` and `porcelain` follow, once every branch has ended. */
	private static final GATE_ROWS: Array<String> = ['suite', 'lists', 'corpus', 'fmt', 'lint', 'jvm', 'arms', 'infra4', 'scrub'];

	/** The branches of a `--baseline` run; `frozen` follows them. */
	private static final BASELINE_BRANCHES: Array<Array<String>> = [['suite', 'corpus'], ['lists'], ['lint'], ['infra4']];

	private static final BASELINE_ROWS: Array<String> = ['suite', 'lists', 'corpus', 'lint', 'infra4'];

	/** What a branch reads for `--baseline` to record: the suite's counts and every registry's. */
	private final _readings: Map<String, Int> = [];

	private final _started: Float = Timer.stamp();
	private final _gate: GateTree;
	private final _lint: GateLint;

	/** Where the build's and the branches' threads come from. */
	private final _mode: LeaseMode;

	private function new(options: GateOptions, mode: LeaseMode) {
		_gate = new GateTree(options);
		_lint = new GateLint(_gate);
		_mode = mode;
	}

	/** The `--baseline` run: build, then record every reading the gate compares with. */
	private function recordBaseline(): Int {
		final title: String = 'slice-gate --baseline ${_gate.tree} @ ${GateTree.short(_gate.base)}';
		final self: String = keepSelf();
		if (!build()) return finish(title);
		fanOut(self, BASELINE_BRANCHES, BASELINE_ROWS);
		final digests: Array<FrozenTree> = [for (dir in _gate.options.frozen) { dir: dir, digest: GateTree.diffDigest(dir) }];
		gate('frozen', () -> {
			if (digests.length == 0) return Skipped('no --frozen');
			_gate.summary.detail([for (d in digests) '${Path.withoutDirectory(d.dir)} ${GateTree.short(d.digest)}'].join(', '));
			return Passed;
		});
		final lists: DynamicAccess<Int> = {};
		for (name in LISTINGS) lists[name] = _readings['list-$name'] ?? 0;
		final record: Baseline = {
			base: _gate.base,
			tests: _readings['tests'] ?? 0,
			assertions: _readings['assertions'] ?? 0,
			lists: lists,
			sweep: forkSet() ? _gate.log('sweep-base.json') : null,
			lint: _gate.log('lint-base.json'),
			infra: _gate.infraSnapshots(),
			frozen: digests
		};
		File.saveContent(_gate.log('baseline.json'), Json.stringify(record, null, '\t'));
		return finish(title);
	}

	/** The gate run: every gate against the baseline, one row each. */
	private function check(): Int {
		final head: String = GateTree.short(_gate.git(['rev-parse', 'HEAD']));
		final title: String =
			'slice-gate ${_gate.tree} @ $head base ${GateTree.short(_gate.base)}: ${_gate.touched.length} file(s) touched';
		final self: String = keepSelf();
		if (!build()) return finish(title);
		fanOut(self, GATE_BRANCHES, GATE_ROWS);
		gate('decisions', decisionsOutcome);
		gate('frozen', frozenOutcome);
		gate('porcelain', () -> {
			final dirty: Array<String> = _gate.git(['status', '--porcelain']).split('\n').filter(l -> l != '');
			return dirty.length == 0 ? Passed : Failed('${dirty.length} entr(ies), first `${dirty[0]}`');
		});
		return finish(title);
	}

	/** A `--rows` process: run `rows` in order and leave their steps and readings for the gate that started it. */
	private function runBranch(rows: Array<String>): Int {
		for (name in rows) gate(name, rowStep(name));
		Branches.leave(branchReport(rows), _gate.options.run, _gate.summary, _readings);
		return 0;
	}

	/** The step of the row `name` in this run's mode. */
	private function rowStep(name: String): () -> Outcome {
		final recording: Bool = _gate.options.baseline;
		return switch name {
			case 'suite': suiteOutcome.bind(recording);
			case 'corpus': recording ? corpusSaved : corpusOutcome;
			case 'lists': recording ? listsRead : listsOutcome;
			case 'lint': recording ? _lint.baseLint : _lint.lintOutcome;
			case 'infra4': recording ? _lint.infraBaseline : _lint.infraOutcome;
			case 'fmt': fmtOutcome;
			case 'jvm': jvmOutcome;
			case 'arms': GateArms.outcome.bind(_gate);
			case 'scrub': scrubOutcome;
			case _: () -> NotRun('no row named $name');
		};
	}

	/**
	 * This tool's own script, copied into the logs before the build replaces it: the branches run the code the gate
	 * runs, not the code the slice just built.
	 */
	private function keepSelf(): String {
		final dir: String = _gate.log('rows');
		FileSystem.createDirectory(dir);
		final self: String = Path.join([dir, 'dev.js']);
		File.copy(FileSystem.fullPath(js.Node.__filename), self);
		return self;
	}

	/**
	 * Run `branches` at once as `--rows` processes of `self`, their rows in `order`: under a held lease the heavy rows take
	 * what the lease leaves beside the others' `demand`, and without one each branch takes its own lease of the pool.
	 */
	private function fanOut(self: String, branches: Array<Array<String>>, order: Array<String>): Void {
		final threads: Null<Int> = switch _mode {
			case Held(held): Branches.share(held, Branches.light(branches, demand));
			case _: null;
		};
		final command: Array<String> -> Command = rows ->
			Command.of(['node', self, 'slice-gate'].concat(branchArgs(rows, threads)))
				.at(_gate.tree)
				.env('HXQ_BIN', _gate.apq())
				.timeout(BRANCH_TIMEOUT_MS);
		final label: String = 'slice-gate ${Path.withoutDirectory(_gate.tree)}';
		final leased: Array<String> -> Command = Branches.leased(_mode, branches, demand, command, label);
		for (name => value in Branches.run(_gate.options.run, branches, order, leased, branchReport, _gate.summary))
			_readings[name] = value;
	}

	/** The command line of the branch running `rows`: this run's options, the rows, and the heavy rows' threads. */
	private function branchArgs(rows: Array<String>, threads: Null<Int>): Array<String> {
		final options: GateOptions = _gate.options;
		final args: Array<String> = [_gate.tree, '--logs', _gate.logs, '--rows', rows.join(','), '--run', options.run];
		if (options.baseline) args.push('--baseline');
		for (dir in options.infra) args.push('--infra-tree=$dir');
		for (arm in options.arms) args.push('--arm=$arm');
		for (name in options.allow) args.push('--allow=$name');
		if (options.noArms) args.push('--no-arms');
		if (threads != null) args.push('--threads=$threads');
		return args;
	}

	/** Where the branch running `rows` leaves its report. */
	private function branchReport(rows: Array<String>): String {
		return _gate.log('rows/${rows[0]}.json');
	}

	/**
	 * The threads the branch running `rows` holds: null for the heavy one (the suite and the arms), which takes what the
	 * others leave; one for the short rows; the lint row's two lints; the jvm probe; a lint per tree INFRA gate 4 reads beside
	 * the base tree's, which a `--baseline` run lints in its own row — each 0 when its rows will skip.
	 */
	private function demand(rows: Array<String>): Null<Int> {
		final recording: Bool = _gate.options.baseline;
		final infra: Int = _gate.options.infra.length;
		return switch rows[0] {
			case 'suite': null;
			case 'lists': recording ? 0 : 1;
			case 'lint': recording ? Std.int(Math.min(1, infra)) : touchedLints();
			case 'jvm': _gate.jvmMoved() ? 1 : 0;
			case 'infra4': recording ? infra : infraLints();
			case _: 0;
		};
	}

	/** The lints the lint row of a gate run holds at once: the touched files' at the base and now, when it lints any. */
	private function touchedLints(): Int {
		return _gate.touched.exists(f -> f.endsWith('.hx')) ? 2 : 0;
	}

	/** The lints INFRA gate 4 of a gate run holds at once: the base tree's and one per infra tree, when rule code moved. */
	private function infraLints(): Int {
		final baseline: Null<Baseline> = _gate.baseline;
		return _gate.ruleCodeMoved() && baseline != null ? 1 + baseline.infra.length : 0;
	}

	/** The build every gate needs: both binaries and the developer CLI, at once. A failure ends the run. */
	private function build(): Bool {
		final outcome: Outcome = _gate.summary.time(
			'build', () -> switch Binaries.compileWith(_gate.tree, _gate.log('build.log'), [], _mode) {
				case Failed(why): Failed(GateTree.clip(why));
				case other: other;
			}
		);
		return outcome.match(Passed);
	}

	/** Run the step `name` as `Summary.time` does; a failure of a gate named by `--allow` passes, saying so. */
	private function gate(name: String, step: () -> Outcome): Void {
		_gate.summary.time(
			name, () -> switch step() {
				case Failed(why) if (_gate.options.allow.contains(name)):
					_gate.summary.detail('allowed: $why');
					Passed;
				case other: other;
			}
		);
	}

	/** Print the title, the table and the verdict with the run's wall time; answers the exit status. */
	private function finish(title: String): Int {
		Sys.println(title);
		Sys.println(_gate.summary.table());
		final passed: Bool = _gate.summary.passed();
		final wall: String = '${Math.round(Timer.stamp() - _started)}s';
		Sys.println(passed ? 'slice-gate: PASS in $wall' : 'slice-gate: FAIL in $wall — logs ${_gate.logs}');
		return passed ? 0 : 1;
	}

	/**
	 * The suite row: `dev shard` over the heavy rows' threads (its own default outside a lease), green and counted, its
	 * counts beside the baseline's — or, when `recording`, kept for the baseline.
	 */
	private function suiteOutcome(recording: Bool): Outcome {
		final lines: Array<String> = [];
		var totals: Null<Tally> = null;
		final shards: Int = _gate.options.threads ?? Shard.DEFAULT_SHARDS;
		final status: Int = Shard.run({
			repo: _gate.tree,
			testJs: Path.join([_gate.tree, 'bin/test.js']),
			shards: shards,
			verify: false,
			expect: null,
			planOnly: false,
			keep: false,
			timings: null,
			fixtureCache: Shard.fixtureCacheOfEnv(),
			print: line -> lines.push(line),
			warn: line -> lines.push(line),
			counted: sum -> totals = sum
		});
		File.saveContent(_gate.log('suite.log'), lines.join('\n') + '\n');
		final sum: Null<Tally> = totals;
		if (sum == null || sum.tests == 0) return Failed(GateTree.clip('no suite totals: ${lines[0] ?? ''} — ${_gate.log('suite.log')}'));
		if (recording) {
			_readings['tests'] = sum.tests;
			_readings['assertions'] = sum.assertions;
		}
		final baseline: Null<Baseline> = _gate.baseline;
		final delta: String = baseline == null
			? ''
			: ' (${GateTree.signed(sum.tests - baseline.tests)} / ${GateTree.signed(sum.assertions - baseline.assertions)})';
		_gate.summary.detail(
			'${sum.tests} tests / ${sum.assertions} assertions / ${sum.failures}F / ${sum.errors}E$delta, $shards shard(s)'
		);
		if (status == 0) return Passed;
		final verdict: String = lines.find(l -> l.startsWith('suite-shard: FAILED')) ?? 'dev shard exited $status';
		final locus: Null<String> = lines.find(l -> ~/^  shard \d+ /.match(l));
		return Failed(GateTree.clip(locus == null ? verdict : '$verdict — ${locus.trim()}'));
	}

	/** The lists row of `--baseline`: every registry's count, kept for the baseline. */
	private function listsRead(): Outcome {
		final counts: Map<String, Int> = listCounts();
		for (name in LISTINGS) _readings['list-$name'] = counts[name] ?? 0;
		_gate.summary.detail([for (name in LISTINGS) '$name ${counts[name]}'].join(' '));
		return Passed;
	}

	/** The lists row: every registry's count beside the baseline's, and no dead fixture. */
	private function listsOutcome(): Outcome {
		final counts: Map<String, Int> = listCounts();
		final readings: Array<String> = [
			for (name in LISTINGS) {
				final was: Null<Int> = _gate.baseline?.lists[name];
				final now: Int = counts[name] ?? 0;
				was == null || was == now ? '$name $now' : '$name $now (${GateTree.signed(now - was)})';
			}
		];
		_gate.summary.detail(readings.join(' '));
		return (counts['dead'] ?? 0) > 0 ? Failed('a fixture-named method no runner reaches: `node bin/test.js --list-dead`') : Passed;
	}

	/** The corpus row of `--baseline`: the sweep the suite just wrote, saved for the gate to compare with. */
	private function corpusSaved(): Outcome {
		if (!forkSet()) return Skipped('ANYPARSE_HXFORMAT_FORK unset — the suite ran no corpus');
		final saved: Result = _gate.inTree(cmd('node bin/apq.js sweep --lang haxe --save ${_gate.log('sweep-base.json')}'));
		_gate.summary.detail(saved.lines()[0] ?? '');
		return saved.ok ? Passed : Failed(GateTree.quote(saved));
	}

	/** The corpus row: the sweep the suite just wrote against the baseline's snapshot, no fixture moved. */
	private function corpusOutcome(): Outcome {
		final baseline: Null<Baseline> = _gate.baseline;
		if (baseline == null) return NotRun(GateTree.NO_BASELINE);
		final sweep: Null<String> = baseline.sweep;
		if (sweep == null || !forkSet()) return NotRun('no corpus: ANYPARSE_HXFORMAT_FORK unset at the baseline or now');
		final diff: Result = _gate.inTree(cmd('node bin/apq.js sweep --lang haxe --diff $sweep'));
		if (!diff.ok) return Failed(GateTree.quote(diff));
		final line: String = diff.lines().find(l -> l.startsWith('--- sweep --diff')) ?? '';
		_gate.summary.detail(diff.lines()[0] ?? '');
		return line.indexOf(': 0 fixtures changed') >= 0 ? Passed : Failed(GateTree.clip(line));
	}

	/** The fmt row: no file the writer would rewrite, none needing a second pass. */
	private function fmtOutcome(): Outcome {
		final fmt: Result = _gate.hxq(_gate.tree, ['fmt', '--list', '--one-pass'].concat(GateTree.TREE_SCOPE)).run();
		final line: String = '${fmt.out}\n${fmt.err}'.split('\n').find(l -> l.indexOf('would be rewritten') >= 0) ?? '';
		_gate.summary.detail(line.replace('apq fmt --list: ', ''));
		return fmt.ok && line.indexOf(': 0 of ') >= 0 ? Passed : Failed(line == '' ? GateTree.quote(fmt) : GateTree.clip(line));
	}

	/** The jvm row, for a slice that touched `src/`: `dev jvm-portability` and its gate line. */
	private function jvmOutcome(): Outcome {
		if (!_gate.jvmMoved()) return Skipped('neither src/ nor the probe changed');
		final probe: Result = _gate.inTree(cmd('node bin/dev.js jvm-portability --repo ${_gate.tree}'));
		File.saveContent(_gate.log('jvm.log'), probe.out + probe.err);
		final line: String = probe.lines().find(l -> l.startsWith('gate:')) ?? '';
		_gate.summary.detail(line);
		return probe.ok ? Passed : Failed(line == '' ? GateTree.quote(probe) : GateTree.clip(line));
	}

	/** The scrub row: `dev scrub-guard` over the tree and over what the slice's commits add. */
	private function scrubOutcome(): Outcome {
		final tree: Result = _gate.inTree(cmd('node bin/dev.js scrub-guard'));
		final range: Result = _gate.inTree(cmd('node bin/dev.js scrub-guard --range ${_gate.base}..HEAD'));
		if ('${tree.err}${range.err}'.indexOf('nothing checked') >= 0)
			return NotRun('no token list — set ANYPARSE_SCRUB_LIST (or ANYPARSE_SCRUB_PRIVATE_ROOTS)');
		_gate.summary.detail('tree and ${GateTree.short(_gate.base)}..HEAD clean');
		return tree.ok && range.ok ? Passed : Failed(GateTree.quote(tree.ok ? range : tree));
	}

	/**
	 * The decisions row: every line the slice added to `docs/decisions.md` has the shape `dev decision` writes — one line,
	 * one sentence, ending `→ <ID>`; the first that does not is quoted.
	 */
	private function decisionsOutcome(): Outcome {
		final ledger: String = Decision.LEDGER;
		if (!_gate.touched.contains(ledger)) return Skipped('$ledger untouched');
		final shown: Result = cmd('git -C ${_gate.tree} show ${_gate.base}:$ledger').run();
		final added: Array<String> = Decision.addedLines(shown.ok ? shown.out : '', File.getContent(Path.join([_gate.tree, ledger])));
		for (line in added) {
			final why: Null<String> = Decision.entryProblem(line);
			if (why != null) return Failed(GateTree.clip('$why: $line'));
		}
		_gate.summary.detail('${added.length} new line(s)');
		return Passed;
	}

	/** The frozen row: every tree recorded by `--frozen` still has the `git diff` it had at the baseline. */
	private function frozenOutcome(): Outcome {
		final baseline: Null<Baseline> = _gate.baseline;
		if (baseline == null) return NotRun(GateTree.NO_BASELINE);
		if (baseline.frozen.length == 0) return Skipped('none recorded at --baseline');
		final moved: Array<String> = [for (f in baseline.frozen) if (GateTree.diffDigest(f.dir) != f.digest) f.dir];
		_gate.summary.detail([
			for (f in baseline.frozen) '${Path.withoutDirectory(f.dir)} ${GateTree.short(f.digest)} unchanged'
		].join(', '));
		return moved.length == 0 ? Passed : Failed('the git diff of ${moved.join(', ')} changed since the baseline');
	}

	/** The line count of every registry `bin/test.js` lists, all listed at once. */
	private function listCounts(): Map<String, Int> {
		final runs: Array<Result> = Pool.of(LISTINGS.length)
			.map(LISTINGS, name -> cmd('node bin/test.js --list-$name').at(_gate.tree).env('HXQ_BIN', _gate.apq()));
		return [for (i => name in LISTINGS) name => runs[i].check().lines().length];
	}

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final baseline: Bool = args.flag('--baseline');
		final noArms: Bool = args.flag('--no-arms');
		final frozen: Array<String> = args.options('--frozen');
		final infra: Array<String> = args.options('--infra-tree');
		final arms: Array<String> = args.options('--arm');
		final allow: Array<String> = args.options('--allow');
		final logsOption: Null<String> = args.option('--logs');
		final rows: Null<String> = args.option('--rows');
		final threads: Null<Int> = Std.parseInt(args.option('--threads') ?? '') ?? (rows == null ? null : PoolLease.threads());
		final run: String = args.option('--run') ?? Branches.newRunId();
		final tree: String = FileSystem.fullPath(args.positionals(['<worktree>'])[0]);
		if (!FileSystem.exists(Path.join([tree, 'tools/dev.hxml']))) throw new UsageError('$tree is not an anyparse tree');
		if (!baseline && frozen.length + infra.length > 0)
			throw new UsageError('--frozen and --infra-tree are recorded by --baseline; the gate reads them from there');
		final logs: String = logsOption ?? Path.join(['${Path.removeTrailingSlashes(tree)}-logs', 'slice-gate']);
		FileSystem.createDirectory(logs);
		final gate: SliceGate = new SliceGate({
			tree: tree,
			logs: FileSystem.fullPath(logs),
			baseline: baseline,
			frozen: frozen.map(FileSystem.fullPath),
			infra: infra.map(FileSystem.fullPath),
			arms: arms,
			allow: allow,
			noArms: noArms,
			threads: threads != null && threads > 0 ? threads : null,
			run: run
		}, rows == null ? Lease.ofEnvironment() : Unpooled);
		if (rows != null) return gate.runBranch(rows.split(','));
		return baseline ? gate.recordBaseline() : gate.check();
	}

	/** Whether the corpus harness runs: the fork it reads is named. */
	private static inline function forkSet(): Bool {
		return (Sys.getEnv('ANYPARSE_HXFORMAT_FORK') ?? '') != '';
	}

}

/** What `--baseline` records for the gate run, in `<logs>/baseline.json`. */
typedef Baseline = {
	var base: String;
	var tests: Int;
	var assertions: Int;

	/** Each registry's line count, by its `--list-<name>` name. */
	var lists: DynamicAccess<Int>;

	/** The corpus snapshot, or null when the suite ran no corpus. */
	var sweep: Null<String>;

	/** The base tree's whole lint by the base engine. */
	var lint: String;

	var infra: Array<InfraSnapshot>;
	var frozen: Array<FrozenTree>;
}

/** A tree outside this one and its lint by the base engine. */
typedef InfraSnapshot = {
	var tree: String;
	var snapshot: String;
}

/** A tree no slice may write, and the digest of its `git diff` at the baseline. */
typedef FrozenTree = {
	var dir: String;
	var digest: String;
}
