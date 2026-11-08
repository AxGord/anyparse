package dev;

import anyparse.core.PoolLease;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JsonFormat;
import anyparse.query.ShardPlan;
import dev.GateReuse.GateOffer;
import dev.Shard.Tally;
import dev.XconfigFmt.XconfigFailure;
import dev.XconfigFmt.XconfigRun;
import devkit.Args;
import devkit.Branches;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.Lease;
import devkit.Pool;
import devkit.Result;
import devkit.Summary;
import devkit.TmpLifecycle;
import haxe.Exception;
import haxe.Timer;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * `dev battery` — the end-of-slice proof as ONE command with one verdict (docs/testing.md § "The per-slice battery"): the
 * three binaries and a typecheck of the corpus drill, then four branches at once, each a `--rows` process of this tool
 * (`devkit.Branches`) whose transcript is replayed in a fixed order once all have joined. A step that could not run fails
 * the verdict on its own; `--snapshot` caches this HEAD, green or red, as the next run's "before" arm.
 */
@:nullSafety(Strict)
final class Battery {

	public static inline final USAGE: String = 'usage: dev battery [-n <N>] [--quick] [--snapshot] [--allow <row>]... [--base <key> | --no-base] [--cache <dir>] [--allow-blast] [--keep] '
		+ '[--client <tree> | --no-client] [--jvm | --no-jvm] [--reuse <gate-record.json>] [--only <class-list-file>] [--repo <tree>]';

	/** The characters of HEAD a snapshot is keyed by. */
	public static inline final KEY_LENGTH: Int = 8;

	/** The readings a branch leaves: the suite's counts, the corpus sweep's, and whether the client tree was linted. */
	private static inline final TESTS: String = 'tests';

	private static inline final ASSERTIONS: String = 'assertions';

	/** The reading of a suite row that ran only the classes the change reaches: how many, and what they counted. */
	private static inline final IMPACT: String = 'impact-classes';

	private static inline final IMPACT_TESTS: String = 'impact-tests';
	private static inline final IMPACT_ASSERTIONS: String = 'impact-assertions';
	private static inline final SWEEP_PASS: String = 'sweep-pass';
	private static inline final SWEEP_FAIL: String = 'sweep-fail';
	private static inline final SWEEP_SKIP: String = 'sweep-skip';
	private static inline final CLIENT_LINTED: String = 'lint-client';
	private static inline final LINTED: String = 'lint-anyparse';

	/** The table's seconds are given to a tenth. */
	private static inline final TENTHS_PER_SECOND: Int = 10;

	/** The prefix `devkit.TmpLifecycle` claims the run's work directory under. */
	private static inline final WORK_PREFIX: String = 'apq-battery';

	/** What a branch may run before it is killed: a wedged run, not a slow one. */
	private static inline final BRANCH_TIMEOUT_MS: Int = 3 * 60 * 60 * 1000;

	/** The build file only a typecheck reaches: the corpus drill's driver, a root-level module no binary's `-main` types. */
	private static inline final RECON_HXML: String = 'recon.hxml';

	/** The lines of a failed typer-probe run shown when it names no `DIFFERENT` probe. */
	private static inline final TAIL_LINES: Int = 20;

	/** The environment variable that pins which `apq.js` the `hxq` shim runs. */
	private static inline final ENGINE_VAR: String = 'HXQ_BIN';

	private static final CORPUS_ROW: String = 'corpus';
	private static final SUITE_ROW: String = 'suite';

	/** The branches, all at once, each running its steps in order: a step reads what the one before it wrote. */
	private static final BRANCHES: Array<Array<String>> = [
		[SUITE_ROW, CORPUS_ROW],
		['fmt', 'fmt xconfig'],
		['typer probes', 'jvm probe'],
		['oracle', 'lint', 'blast', 'kit probes']
	];

	private final _summary: Summary = new Summary();
	private final _readings: Map<String, Int> = [];
	private final _plan: BatteryPlan;

	/** Where the build's and the branches' threads come from; a branch's own process takes none. */
	private final _mode: LeaseMode;

	/** Whether this branch's suite step ended green: the corpus step reads a sweep only a green suite wrote. */
	private var _suiteGreen: Bool = false;

	private function new(plan: BatteryPlan, mode: LeaseMode) {
		_plan = plan;
		_mode = mode;
	}

	/** `hxq <args>` in the tree, on the engine the build just made. */
	private inline function hxq(args: Array<String>): Command {
		return GateTree.shim(_plan.repo, _plan.repo, args);
	}

	private inline function workFile(name: String): String {
		return Path.join([_plan.work, name]);
	}

	/** The run over the claimed work directory: build, the four branches, their transcripts, the table; answers the exit status. */
	private function drive(): Int {
		final started: Float = Timer.stamp();
		final base: Null<String> = _plan.base;
		Sys.println(startLine(_plan.repo, _plan.head, base, _plan.cache));
		// the branches run the code this run started with, not the `dev.js` the build is about to replace
		final self: String = workFile('dev.js');
		File.copy(FileSystem.fullPath(js.Node.__filename), self);
		final built: Outcome = _summary.time(
			'build (parallel)', () -> Binaries.compileWith(_plan.repo, workFile('build.log'), [RECON_HXML], _mode)
		);
		if (!built.match(Passed)) {
			Sys.println(File.getContent(workFile('build.log')));
			Sys.println('battery: stopping — nothing below can be trusted against a failed build');
			return finish(started, null);
		}
		File.saveContent(workFile('plan.json'), BatteryPlanWriter.write(_plan, JsonFormat.instance.compactWriteOptions));
		Sys.println(
			'battery: running suite→corpus ∥ fmt ∥ jvm ∥ oracle→lint concurrently — output replays in a fixed order once they join'
		);
		final parallel: Float = Timer.stamp();
		final command: Array<String> -> Command = rows -> Command.of([
			'node',
			self,
			'battery',
			'--rows',
			rows.join(','),
			'--plan',
			workFile('plan.json')
		])
			.at(_plan.repo)
			.env(ENGINE_VAR, Path.join([_plan.repo, 'bin/apq.js']))
			.timeout(BRANCH_TIMEOUT_MS);
		final order: Array<String> = [for (rows in BRANCHES) for (row in rows) row];
		final leased: Array<String> -> Command = Branches.leased(_mode, BRANCHES, branchThreads, command, 'battery ${_plan.head}');
		for (name => value in Branches.run(_plan.run, BRANCHES, order, leased, branchReport, _summary)) _readings[name] = value;
		final span: Float = Timer.stamp() - parallel;
		for (rows in BRANCHES) {
			final log: String = '${branchReport(rows)}.log';
			if (FileSystem.exists(log)) Sys.print(File.getContent(log));
		}
		return finish(started, span);
	}

	/** A `--rows` process: run `rows` in order and leave their steps and readings for the run that started it. */
	private function runBranch(rows: Array<String>): Int {
		for (name in rows) {
			Sys.println('\n=== $name ===');
			final run: () -> Outcome = step(name);
			_summary.time(name, () -> {
				final outcome: Outcome = run();
				final waived: Null<String> = waiver(name, _plan.allow, outcome);
				if (waived == null) return outcome;
				_summary.detail('allowed: $waived');
				return Passed;
			});
		}
		Branches.leave(branchReport(rows), _plan.run, _summary, _readings);
		return 0;
	}

	/** The step named `name`. */
	private function step(name: String): () -> Outcome {
		final gate: Null<GateRecord> = _plan.gate;
		// the corpus row still judges the gate's snapshot against this run's base; every other row the gate stands for is its reading
		if (gate == null || name == CORPUS_ROW || !(_plan.reused ?? []).contains(name)) return switch name {
			case SUITE_ROW: suite;
			case CORPUS_ROW: corpus;
			case 'fmt': fmt;
			case 'fmt xconfig': fmtXconfig;
			case 'typer probes': typerProbes;
			case 'jvm probe': jvmProbe;
			case 'oracle': oracle;
			case 'lint': lint;
			case 'blast': blast;
			case 'kit probes': () -> {
				var failed: Array<String> = [];
				final outcome: Outcome = KitsRow.outcome(
					_plan.repo, _summary, lines -> Sys.println(lines.join('\n')), rows -> failed = rows
				);
				return RedOnBase.after(outcome, () -> RedOnBase.kits(RedOnBase.requestFor(_plan, 'kits', _mode), failed));
			};
			case _: () -> NotRun('no step named $name');
		};
		return reusedRow.bind(name, gate);
	}

	/**
	 * The totals, the table and the verdict; the snapshot when asked, whatever the verdict. Answers the exit status. A run stopped by its
	 * build (`span` null) has no branches to total or to overlap.
	 */
	private function finish(started: Float, span: Null<Float>): Int {
		Sys.println('');
		if (span != null) {
			for (line in totalsLines(_readings, _plan.base, _plan.baseSuite)) Sys.println(line);
			Sys.println('');
		}
		Sys.println(_summary.table());
		final wall: String = seconds(Timer.stamp() - started);
		Sys.println('');
		if (span == null) {
			Sys.println('total (wall) $wall');
		} else {
			Sys.println('concurrent span ${seconds(span)}, total (wall) $wall');
			Sys.println(
				'the branches\' rows OVERLAP — they ran concurrently and sum to more than the elapsed time. Battery timings measure the '
				+ 'battery, never the code; a benchmark arm runs alone and sequentially (docs/testing.md).'
			);
		}
		// a snapshot is a reading, not a verdict: a red tip is the next landing's base all the same
		final refused: Null<String> = _plan.snapshot && span != null ? snapshot() : null;
		if (refused != null) Sys.println('battery: no snapshot — $refused');
		final suffix: String = _summary.waitedSuffix();
		if (!_summary.passed() || refused != null) {
			Sys.println('--- battery: FAIL$suffix ---');
			return 1;
		}
		Sys.println('--- battery: PASS$suffix ---');
		return 0;
	}

	/**
	 * This HEAD as the next run's "before" arm: the lint snapshots, the corpus sweep and the suite's counts, keyed by the
	 * commit. Answers why it could not be written, or null.
	 */
	private function snapshot(): Null<String> {
		final refused: Null<String> = keepSnapshot(
			_plan.cache, _plan.head, _plan.work, _readings, file -> hxq(sweepRead().concat(['--save', file])).run(), _plan.base
		);
		if (refused == null) Sys.println('battery: snapshot written for ${_plan.head} in ${_plan.cache}');
		return refused;
	}

	/** The suite, sharded through `dev shard` (the monolith cross-check unless `--quick`), its counts kept. */
	private function suite(): Outcome {
		GateTree.clearSnapshotIn(_plan.repo);
		final only: Null<Array<String>> = _plan.only;
		if (only != null) return impactSuite(only);
		var totals: Null<Tally> = null;
		var failing: Array<String> = [];
		final status: Int = Shard.run({
			repo: _plan.repo,
			testJs: Path.join([_plan.repo, 'bin/test.js']),
			shards: _plan.ownLease ? PoolLease.threads() ?? _plan.shards : _plan.shards,
			verify: !_plan.quick,
			expect: null,
			planOnly: false,
			keep: false,
			timings: null,
			fixtureCache: Shard.fixtureCacheOfEnv(),
			print: Sys.println,
			warn: Sys.println,
			counted: sum -> totals = sum,
			failing: names -> failing = names
		});
		final sum: Null<Tally> = totals;
		if (sum != null) {
			_readings[TESTS] = sum.tests;
			_readings[ASSERTIONS] = sum.assertions;
			_summary.detail('${sum.tests} tests / ${sum.assertions} assertions');
		}
		_suiteGreen = status == 0;
		return RedOnBase.after(
			_suiteGreen ? Passed : Failed('the suite is not green (dev shard keeps its own per-shard logs on failure)'),
			() -> RedOnBase.suite(RedOnBase.requestFor(_plan, SUITE_ROW, _mode), failing)
		);
	}

	/**
	 * The corpus sweep the suite just wrote, against the base's snapshot rather than the previous run — that
	 * one is the same tree once a run is repeated, and blind to a regression two runs old.
	 */
	private function corpus(): Outcome {
		if (!_suiteGreen) return NotRun('the suite was red — the sweep snapshot it writes proves nothing');
		final only: Null<Array<String>> = _plan.only;
		if (only != null && !only.contains(ShardPlan.CORPUS_CLASS))
			return Skipped('the impact suite ran no corpus case — the whole suite after the land runs it');
		final base: Null<String> = baseFile('sweep.json');
		final sweep: Result = hxq(sweepRead().concat(base == null ? [] : ['--prev', base])).run();
		final text: String = sweep.out + sweep.err;
		Sys.print(text);
		if (!sweep.ok) return Failed('could not read the corpus sweep snapshot — did the corpus layer run?');
		final counts: Array<Int> = sweepCounts(text);
		_readings[SWEEP_PASS] = counts[0];
		_readings[SWEEP_FAIL] = counts[1];
		_readings[SWEEP_SKIP] = counts[2];
		_summary.detail('${counts[0]} pass / ${counts[1]} fail / ${counts[2]} skip-parse, against ${_plan.base ?? 'no base'}');
		return corpusRegressed(text) ? Failed('the corpus regressed against ${_plan.base} — see the Δ line above') : Passed;
	}

	/**
	 * No file under `src`, `test` and `tools` the writer would rewrite or
	 * settles only on a second rewrite, and on the fork's tree — which is
	 * not canonical, so every round trip is exercised — no rewrite that changes more than whitespace.
	 */
	private function fmt(): Outcome {
		final why: Array<String> = [];
		final list: Result = hxq(['fmt', '--list', '--one-pass'].concat(GateTree.TREE_SCOPE)).run();
		// a stderr line is printed, never a verdict: the gate is a drifted file, and that is on stdout
		Sys.print(list.err);
		if (!list.ok || list.out != '') {
			Sys.print(list.out);
			why.push(
				'fmt --list --one-pass is not empty (or exited ${list.status} — a non-zero exit with an EMPTY list is the one-pass gate)'
			);
		}
		final fork: String = '${Sys.getEnv('ANYPARSE_HXFORMAT_FORK') ?? ''}/src';
		final verify: Result = hxq(['fmt', '--verify', '--one-pass', fork]).run();
		final text: String = verify.out + verify.err;
		final lines: Array<String> = text.split('\n');
		for (line in lines) if (line.indexOf('fmt --verify:') >= 0) Sys.println(line);
		if (text.indexOf('formatting changed more than whitespace') >= 0) {
			Sys.print(text);
			why.push('fmt --verify found a non-whitespace divergence in $fork');
		}
		if (text.indexOf('fmt --one-pass:') >= 0) {
			for (line in lines) if (line.indexOf('fmt --one-pass:') >= 0 || line.indexOf('rewrites to reach its fixed point') >= 0)
				Sys.println(line);
			why.push('the writer needed more than one rewrite on a file in $fork');
		}
		return why.length == 0 ? Passed : Failed(why.join('; '));
	}

	/**
	 * This tree formatted under the vendored second config, through a scratch root of symlinks (config discovery walks up
	 * lexically), so an interrupted run cannot leave the repo holding a foreign config. Its gate is the one-pass SET, not
	 * the drift, which a foreign config legitimately brings.
	 */
	private function fmtXconfig(): Outcome {
		final run: XconfigRun = XconfigFmt.xconfigRun(hxq, _plan.repo, workFile('xconfig'), null);
		for (line in run.shown) Sys.println(line);
		final failure: Null<XconfigFailure> = XconfigFmt.xconfigVerdict(run, XconfigFmt.XCONFIG_ONE_PASS, []);
		if (failure == null) return Passed;
		for (line in failure.detail) Sys.println(line);
		return Failed(failure.line);
	}

	/** The typer probe corpus (`tools/typer-facts/`): every probe the typer answers as the compiler does. */
	private function typerProbes(): Outcome {
		final run: Result = cmd('node bin/dev.js typer-conformance probes').at(_plan.repo).run();
		if (run.ok) return Passed;
		final lines: Array<String> = '${run.out}${run.err}'.split('\n');
		final different: Array<String> = lines.filter(l -> l.startsWith('DIFFERENT'));
		Sys.println((different.length > 0 ? different : lines.slice(-TAIL_LINES)).join('\n'));
		return Failed('the typer answered a probe otherwise than the compiler (DIFFERENT above)');
	}

	/** `dev jvm-portability` — its build and its gate line — when the core moved since the base (or `--jvm`). */
	private function jvmProbe(): Outcome {
		final skip: Null<String> = _plan.jvmSkip;
		if (skip != null) return Skipped(skip);
		final probe: Result = cmd('node bin/dev.js jvm-portability --repo ${_plan.repo}').at(_plan.repo).run();
		Sys.print(probe.out + probe.err);
		_summary.detail(probe.lines().find(l -> l.startsWith('gate:')) ?? '');
		if (probe.ok) return Passed;
		final refusal: Null<String> = probe.err.split('\n').find(l -> l.startsWith('dev jvm-portability: '));
		return Failed(refusal == null ? probe.firstError() : refusal.substr('dev jvm-portability: '.length));
	}

	/**
	 * The compiler's verdict on the tree, recorded under a fingerprint of the compile input so the lint step reuses it
	 * instead of compiling again. Not a gate: the lint step fails on the same verdict, with the compiler's error.
	 */
	private function oracle(): Outcome {
		final run: Result = hxq(['oracle', 'src']).run();
		File.saveContent(workFile('oracle.log'), run.out + run.err);
		return Passed;
	}

	/**
	 * The lint of the files `LintScope` names for this landing (the whole of `src` and `test` when the scope is null), with the base's
	 * findings carried for every other file, and of the client tree, at once.
	 */
	private function lint(): Outcome {
		final client: Null<String> = _plan.client;
		final baseReport: Null<String> = baseFile('anyparse.json');
		final scope: Null<Array<String>> = baseReport == null ? null : _plan.lintScope;
		final args: Null<Array<String>> = LintScope.lintArgs(scope);
		final jobs: Array<Command> = args == null ? [] : [hxq(args)];
		final own: Int = jobs.length;
		if (client != null) jobs.push(hxq(['lint', '--format', 'json', '--all', Path.join([client, 'src'])]));
		final runs: Array<Result> = jobs.length == 0 ? [] : Pool.of(jobs.length).run(jobs);
		final why: Array<String> = [];
		final report: Null<Result> = own == 0 ? null : runs[0];
		final text: String = report?.out ?? '[]';
		final whole: Null<String> = LintScope.whole(baseReport, scope, text, file -> FileSystem.exists(Path.join([_plan.repo, file])));
		if (scope != null) _summary.detail('lint scoped to ${scope.length} file(s), the rest is ${_plan.base ?? 'the base'}\'s');
		if (whole == null) why.push('the base snapshot $baseReport is no lint report to carry');
		File.saveContent(workFile('lint-anyparse.json'), whole ?? text);
		if (whole != null && isJson(whole)) _readings[LINTED] = 1;
		if (report != null && !report.ok) {
			Sys.print(report.err);
			why.push('lint of src+test exited ${report.status}');
		}
		final clientRun: Null<Result> = runs[own];
		if (client != null && clientRun != null) {
			File.saveContent(workFile('lint-client.json'), clientRun.out);
			if (isJson(clientRun.out)) _readings[CLIENT_LINTED] = 1;
			if (!clientRun.ok) {
				Sys.print(clientRun.err);
				why.push('lint of $client/src exited ${clientRun.status}');
			}
		}
		return why.length == 0 ? Passed : Failed(why.join('; '));
	}

	/**
	 * Each lint against the base's snapshot through `lint-diff`, whose exit 1 is movement (waived by `--allow-blast`, the
	 * flag for a slice that adds code) and 2 a comparison that could not run, which no flag waives.
	 */
	private function blast(): Outcome {
		final runs: Array<BlastRun> = [];
		final arms: Array<BlastArm> = [{ label: 'anyparse', root: _plan.repo }];
		final client: Null<String> = _plan.client;
		if (client != null) {
			final root: String = client;
			arms.push({ label: 'client', root: root });
		}
		for (arm in arms) {
			final old: Null<String> = baseFile('${arm.label}.json');
			if (old == null) {
				Sys.println('blast ${arm.label}: no cached baseline at ${_plan.base ?? ''} — nothing to compare');
				continue;
			}
			final diff: Result = hxq([
				'lint-diff',
				'--old',
				old,
				'--new',
				workFile('lint-${arm.label}.json'),
				'--root',
				arm.root,
				'--label',
				arm.label
			]).run();
			Sys.print(diff.out + diff.err);
			runs.push({ label: arm.label, status: diff.status });
		}
		return blastOutcome(runs, _plan.allowBlast, _plan.base);
	}

	/** The base snapshot's file ending `suffix`, or null when there is no base or it lacks that file. */
	private function baseFile(suffix: String): Null<String> {
		final base: Null<String> = _plan.base;
		if (base == null) return null;
		final file: String = Path.join([_plan.cache, '$base-$suffix']);
		return FileSystem.exists(file) ? file : null;
	}

	/** Where the branch running `rows` leaves its report. */
	private function branchReport(rows: Array<String>): String {
		return workFile('branch-${rows[0].replace(' ', '-')}.json');
	}

	/** A row the gate of the same tree already passed: the suite's counts are the gate's, so the snapshot keeps them. */
	private function reusedRow(name: String, gate: GateRecord): Outcome {
		final judged: String = 'reused gate ${GateTree.short(gate.tree)}';
		if (name != SUITE_ROW) return Skipped(judged);
		_readings[TESTS] = gate.tests;
		_readings[ASSERTIONS] = gate.assertions;
		_suiteGreen = true;
		return Skipped('$judged: ${gate.tests} tests / ${gate.assertions} assertions');
	}

	/** The `sweep` words that read this run's corpus snapshot: the gate's copy when the gate stands for the corpus row. */
	private function sweepRead(): Array<String> {
		final recorded: Null<String> = _plan.gate?.sweep;
		return recorded != null && (_plan.reused ?? []).contains(CORPUS_ROW) ? ['sweep', '--file', recorded] : ['sweep'];
	}

	/**
	 * The suite row of a land that ran only the classes its change reaches: no monolith cross-check, and no totals of the whole
	 * suite, which only the whole run beside it can give.
	 */
	private function impactSuite(only: Array<String>): Outcome {
		_readings[IMPACT] = only.length;
		_suiteGreen = true;
		if (only.length == 0) return Skipped('impact — no test class depends on the change');
		var totals: Null<Tally> = null;
		var failing: Array<String> = [];
		final status: Int = Shard.run({
			repo: _plan.repo,
			testJs: Path.join([_plan.repo, 'bin/test.js']),
			shards: _plan.ownLease ? PoolLease.threads() ?? _plan.shards : _plan.shards,
			verify: false,
			expect: null,
			planOnly: false,
			keep: false,
			timings: null,
			fixtureCache: Shard.fixtureCacheOfEnv(),
			print: Sys.println,
			warn: Sys.println,
			counted: sum -> totals = sum,
			failing: names -> failing = names,
			only: only
		});
		final sum: Null<Tally> = totals;
		if (sum == null || sum.tests == 0) {
			_suiteGreen = false;
			return Failed('impact — the ${only.length} selected class(es) counted no tests');
		}
		_readings[IMPACT_TESTS] = sum.tests;
		_readings[IMPACT_ASSERTIONS] = sum.assertions;
		_summary.detail('impact — ${only.length} class(es), ${sum.tests} tests / ${sum.assertions} assertions');
		_suiteGreen = status == 0;
		return RedOnBase.after(
			_suiteGreen ? Passed : Failed('the impact suite is not green (dev shard keeps its own per-shard logs on failure)'),
			() -> RedOnBase.suite(RedOnBase.requestFor(_plan, SUITE_ROW, _mode), failing)
		);
	}

	/** The threads every branch but the suite's holds while the battery runs — what a held lease's suite leaves them. */
	public static inline function lightThreads(): Int {
		return Branches.light(BRANCHES, branchThreads);
	}

	/** The snapshot of HEAD's first parent in `repo`, or null at a root commit. */
	public static inline function defaultBase(repo: String): Null<String> {
		return keyOf(repo, 'HEAD^');
	}

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final rows: Null<String> = args.option('--rows');
		final planFile: Null<String> = args.option('--plan');
		if (rows != null) {
			args.done();
			if (planFile == null) throw new UsageError('--rows needs --plan');
			final plan: BatteryPlan = BatteryPlanParser.parse(File.getContent(planFile));
			return new Battery(plan, Unpooled).runBranch(rows.split(','));
		}
		final shards: Int = shardCount(args.option('-n') ?? args.option('--shards') ?? '${Shard.DEFAULT_SHARDS}');
		final baseOption: Null<String> = args.option('--base');
		final noBase: Bool = args.flag('--no-base');
		final cacheOption: Null<String> = args.option('--cache');
		final clientOption: Null<String> = args.option('--client');
		final quick: Bool = args.flag('--quick');
		final snapshot: Bool = args.flag('--snapshot');
		final noClient: Bool = args.flag('--no-client');
		final allowBlast: Bool = args.flag('--allow-blast');
		final allow: Array<String> = args.options('--allow');
		final keep: Bool = args.flag('--keep');
		final jvm: Bool = args.flag('--jvm');
		final noJvm: Bool = args.flag('--no-jvm');
		final reuse: Null<String> = args.option('--reuse');
		final onlyFile: Null<String> = args.option('--only');
		final repo: String = Repo.resolve(args.option('--repo'));
		args.done();
		for (name in allow) if (!rowNames().contains(name))
			throw new UsageError('--allow names no battery row: \'$name\' (rows: ${rowNames().join(', ')})');
		if (jvm && noJvm) throw new UsageError('pass --jvm or --no-jvm, not both');

		if ((Sys.getEnv('ANYPARSE_HXFORMAT_FORK') ?? '') == '') {
			// the corpus layer skips in silence without it, and "corpus clean" must never read like "corpus not run"
			Sys.stderr().writeString('dev battery: ANYPARSE_HXFORMAT_FORK is unset — the corpus layer would skip silently\n');
			return 2;
		}
		final cacheDir: String = cacheOption ?? Land.cacheDir(Sys.getEnv);
		// created before it is resolved: a full path is a real path, and a directory that does not exist has none
		FileSystem.createDirectory(cacheDir);
		final cache: String = FileSystem.fullPath(cacheDir);
		final base: Null<String> = baseOf(baseOption, noBase, repo);
		final dirs: TmpLifecycle = TmpLifecycle.fromEnv();
		final work: String = dirs.claimAfterSweep(WORK_PREFIX, repo);
		final mode: LeaseMode = Lease.ofEnvironment();
		final offer: GateOffer = GateReuse.offer(reuse, repo, quick, Sys.println);
		final plan: BatteryPlan = {
			repo: repo,
			work: work,
			cache: cache,
			head: cmd('git -C $repo rev-parse --short=$KEY_LENGTH HEAD').text().trim(),
			base: base,
			baseSuite: base == null ? null : suiteCounts(Path.join([cache, '$base-suite.txt'])),
			only: onlyFile == null ? null : File.getContent(onlyFile).split('\n').filter(line -> line != ''),
			shards: shards,
			quick: quick,
			snapshot: snapshot,
			allowBlast: allowBlast,
			allow: allow,
			client: noClient ? null : clientOf(clientOption ?? Sys.getEnv('ANYPARSE_CLIENT_TREE')),
			jvmSkip: jvmSkip(repo, base, jvm ? true : noJvm ? false : null),
			lintScope: LintScope.ofImpact(repo, base, onlyFile != null),
			run: Branches.newRunId(),
			ownLease: mode.match(Own(_, _)),
			gate: offer.gate,
			reused: offer.rows
		};
		final status: Int = try {
			new Battery(plan, mode).drive();
		} catch (exception: Exception) {
			Sys.stderr().writeString('dev battery: logs kept in $work\n');
			throw exception;
		};
		release(dirs, work, repo, status == 0 && !keep, keep);
		return status;
	}

	/** Every row the battery reports, by the name `--allow` takes. */
	public static function rowNames(): Array<String> {
		return [for (rows in BRANCHES) for (row in rows) row];
	}

	/**
	 * Why the failed `outcome` of the row `name` does not fail the verdict, or null: the row is named by `allow` (a slice the
	 * gate already sanctioned for it) and it failed. A row that did not run, and a row not named, keep their outcome.
	 */
	public static function waiver(name: String, allow: Array<String>, outcome: Outcome): Null<String> {
		return switch outcome {
			case Failed(why) if (allow.contains(name)): why;
			case _: null;
		};
	}

	/**
	 * The snapshot key of `rev` in `repo`, or null when it names no commit. Whatever else the cache holds — a run of another
	 * tree, a worker's gate — is never a baseline: a snapshot compares the tree it was taken of.
	 */
	public static function keyOf(repo: String, rev: String): Null<String> {
		final run: Result = cmd('git -C $repo rev-parse --verify --quiet --short=$KEY_LENGTH $rev^{commit}').run();
		return run.ok ? run.out.trim() : null;
	}

	/**
	 * The baseline of a run: `named` (`--base`), none at all (`--no-base`, for the run that makes a snapshot and compares
	 * nothing), else the snapshot of HEAD's first parent, the commit a landing merged onto.
	 */
	public static function baseOf(named: Null<String>, none: Bool, repo: String): Null<String> {
		if (none && named != null) throw new UsageError('pass --base or --no-base, not both');
		return none ? null : named ?? defaultBase(repo);
	}

	/** The two counts of a snapshot's suite line at `file` (tests, assertions), or null when there is none. */
	public static function suiteCounts(file: String): Null<Array<Int>> {
		if (!FileSystem.exists(file)) return null;
		final words: Array<String> = ~/\s+/g.split(File.getContent(file).trim());
		final tests: Null<Int> = Std.parseInt(words[0] ?? '');
		final assertions: Null<Int> = Std.parseInt(words[1] ?? '');
		return tests == null || assertions == null ? null : [tests, assertions];
	}

	/**
	 * Why the jvm probe does not apply, or null when it runs: `forced` true is `--jvm`, false `--no-jvm`; unforced, it runs
	 * when anything it compiles moved since `base`. A probe that should run without `java` on the machine is a skip.
	 */
	public static function jvmSkip(repo: String, base: Null<String>, forced: Null<Bool>): Null<String> {
		if (forced == false) return '--no-jvm';
		if (forced == null) {
			if (base == null || !cmd('git -C $repo cat-file -e $base^{commit}').run().ok)
				return 'no baseline commit to diff the core against';
			final moved: Result = cmd('git -C $repo diff --name-only --no-renames $base').run();
			if (moved.ok && !moved.lines().exists(GateTree.isJvmInput)) return 'neither src/ nor the probe moved since $base';
		}
		return cmd('java -version').run().ok ? null : 'src/ moved but java is absent';
	}

	/** The pass, fail and skip-parse counts of a sweep's summary line in `text`; zeros when it has none. */
	public static function sweepCounts(text: String): Array<Int> {
		final counts: Array<Int> = [0, 0, 0];
		final names: Array<String> = ['pass', 'fail', 'skip-parse'];
		for (line in text.split('\n')) if (line.indexOf('pass /') >= 0) {
			final words: Array<String> = ~/\s+/g.split(line.trim());
			for (i in 0...words.length - 1) {
				final slot: Int = names.indexOf(words[i + 1]);
				if (slot >= 0) counts[slot] = Std.parseInt(words[i]) ?? 0;
			}
		}
		return counts;
	}

	/** Whether the sweep in `text` reports more failures than its base: `sweep` signs the delta, `+N` for a regression. */
	public static function corpusRegressed(text: String): Bool {
		return ~/Δfail \+[1-9]/.match(text);
	}

	/**
	 * The blast step's verdict from the `lint-diff` exit status of each compared snapshot (`runs`), against `base`: none compared
	 * is a skip; 1 is movement, which `allowBlast` waives; any other status is a comparison that could not run, which nothing waives.
	 */
	public static function blastOutcome(runs: Array<BlastRun>, allowBlast: Bool, base: Null<String>): Outcome {
		if (runs.length == 0) return Skipped('no cached baseline at ${base ?? '<none>'} — run --snapshot to make one');
		final why: Array<String> = [];
		var changed: Bool = false;
		for (run in runs) switch run.status {
			case 0:
			case 1:
				changed = true;
			case status:
				why.push('lint-diff could not compare the ${run.label} snapshots (exit $status) — the blast gate did not run');
		}
		if (changed && !allowBlast) why.push('the blast radius changed — explain each line above, then re-run with --allow-blast');
		return why.length == 0 ? Passed : Failed(why.join('; '));
	}

	/**
	 * The suite and corpus lines that close a run, from the branches' `readings`: the suite beside the base's counts when
	 * there is a base `baseSuite`, the corpus as `not run` when no sweep was read.
	 */
	public static function totalsLines(readings: Map<String, Int>, base: Null<String>, baseSuite: Null<Array<Int>>): Array<String> {
		final tests: Int = readings[TESTS] ?? 0;
		final assertions: Int = readings[ASSERTIONS] ?? 0;
		final suite: String = 'suite  $tests tests / $assertions assertions';
		final lines: Array<String> = [];
		if (readings.exists(IMPACT)) {
			lines.push(
				'suite  impact — ${readings[IMPACT]} class(es), ${readings[IMPACT_TESTS] ?? 0} tests / ${readings[IMPACT_ASSERTIONS] ?? 0} '
				+ 'assertions (the whole suite runs after the land)'
			);
		} else if (baseSuite == null || baseSuite[0] <= 0) {
			lines.push(suite);
		} else {
			final delta: String = '${GateTree.signed(tests - baseSuite[0])} / ${GateTree.signed(assertions - baseSuite[1])}';
			lines.push('$suite (base $base: ${baseSuite[0]} / ${baseSuite[1]}, delta $delta)');
		}
		lines.push(
			readings.exists(SWEEP_PASS)
				? 'corpus ${readings[SWEEP_PASS]} pass / ${readings[SWEEP_FAIL]} fail / ${readings[SWEEP_SKIP]} skip-parse'
				: 'corpus not run'
		);
		return lines;
	}

	/**
	 * The snapshot of the commit `head` in `cache`, from what this run read: a file is written only when its row produced its
	 * reading, whatever the verdict was; a row that read nothing leaves the commit's earlier file in place, since a weaker
	 * reading never replaces a kept one. The suite's counts file goes last — it is what says a snapshot exists.
	 * `saveSweep` writes the corpus sweep to the file it is given. Answers why it could not be written, or null.
	 */
	public static function keepSnapshot(
		cache: String, head: String, work: String, readings: Map<String, Int>, saveSweep: String -> Result, ?carried: String
	): Null<String> {
		final key: String = Path.join([cache, head]);
		final lint: String = Path.join([work, 'lint-anyparse.json']);
		if (readings.exists(LINTED) && FileSystem.exists(lint)) File.copy(lint, '$key-anyparse.json');
		final client: String = Path.join([work, 'lint-client.json']);
		if (readings.exists(CLIENT_LINTED) && FileSystem.exists(client)) File.copy(client, '$key-client.json');
		if (readings.exists(SWEEP_PASS)) {
			final save: Result = saveSweep('$key-sweep.json');
			if (!save.ok) return 'the corpus sweep could not be saved: ${save.firstError()}';
		}
		if (readings.exists(TESTS)) File.saveContent('$key-suite.txt', '${readings[TESTS] ?? 0} ${readings[ASSERTIONS] ?? 0}\n');
		if (readings.exists(IMPACT) && carried != null) carryOver(Path.join([cache, carried]), key, readings.exists(SWEEP_PASS));
		return null;
	}

	/** The line that opens a run: the snapshot it compares against, or why it compares nothing. */
	public static function startLine(repo: String, head: String, base: Null<String>, cache: String): String {
		final opening: String = 'battery: repo $repo at $head, ';
		if (base == null) return '${opening}no cached baseline (first run — use --snapshot)';
		if (!FileSystem.exists(Path.join([cache, '$base-suite.txt']))) return '${opening}base $base has no snapshot — nothing compared';
		return '${opening}comparing against $base';
	}

	/**
	 * The threads the branch running `rows` holds: null for the suite's, which takes what the others leave; the two
	 * lints of the lint branch, which also run its kit probes (`Probe.GATE_THREADS`, the same two); one for each other.
	 */
	private static function branchThreads(rows: Array<String>): Null<Int> {
		return switch rows[0] {
			case SUITE_ROW: null;
			case 'oracle': 2;

			case _: 1;
		};
	}

	/** The shard count `text` names; anything but a positive integer is a usage error. */
	private static function shardCount(text: String): Int {
		final shards: Null<Int> = Std.parseInt(text);
		if (shards == null || '$shards' != text || shards < 1) throw new UsageError('-n expects a positive integer, got \'$text\'');
		return shards;
	}

	/** The client tree `given` names, as a full path, when it has a `src` to lint; else null. */
	private static function clientOf(given: Null<String>): Null<String> {
		return given != null && given != '' && FileSystem.isDirectory(Path.join([given, 'src'])) ? FileSystem.fullPath(given) : null;
	}

	/**
	 * The work directory `work` removed when `discard`, else kept with its path printed. Only an explicit `keep` outlives the
	 * startup sweep; a red run's directory ages out like a crashed one's.
	 */
	private static function release(dirs: TmpLifecycle, work: String, repo: String, discard: Bool, keep: Bool): Void {
		if (discard) {
			final refused: Null<String> = dirs.discard(work, repo);
			if (refused != null) Sys.stderr().writeString('dev battery: $refused\n');
			return;
		}
		if (keep) dirs.markKeep(work);
		Sys.stderr().writeString('dev battery: logs kept in $work\n');
	}

	/** `elapsed` seconds to a tenth, with an `s`. */
	private static function seconds(elapsed: Float): String {
		return '${Math.round(elapsed * TENTHS_PER_SECOND) / TENTHS_PER_SECOND}s';
	}

	/** Whether `text` is a parseable JSON document: the lint prints one only when it ran to its end. */
	private static function isJson(text: String): Bool {
		try {
			JValueParser.parse(text);
			return true;
		} catch (_: Exception) {
			return false;
		}
	}

	/**
	 * What an impact run could not measure, taken from the snapshot it compared with: the sweep (no corpus case ran, so the
	 * corpus is the base's) and provisionally the suite counts, which the whole suite after the land rewrites. A snapshot with
	 * no suite line does not exist for the next land, which would then measure its base in full.
	 */
	private static function carryOver(from: String, to: String, swept: Bool): Void {
		if (!swept && FileSystem.exists('$from-sweep.json')) File.copy('$from-sweep.json', '$to-sweep.json');
		if (FileSystem.exists('$from-suite.txt')) File.copy('$from-suite.txt', '$to-suite.txt');
	}

}

/** One lint the blast step compares with its base snapshot: the snapshot's label and the tree its paths are under. */
typedef BlastArm = {
	var label: String;
	var root: String;
}

/** One `lint-diff` the blast step ran: the snapshot's label and the exit status, null when it gave none. */
typedef BlastRun = {
	var label: String;
	var status: Null<Int>;
}
