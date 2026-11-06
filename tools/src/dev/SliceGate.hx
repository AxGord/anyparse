package dev;

import anyparse.core.PoolLease;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JsonFormat;
import dev.ArmRegistry.ArmRegistryError;
import dev.GateArms.ArmPlan;
import dev.GateTree.GateOptions;
import dev.Shard.Tally;
import dev.SuiteImpact.SuiteScope;
import dev.XconfigFmt.XconfigStand;
import devkit.Args;
import devkit.Branches;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.Excerpt;
import devkit.Lease;
import devkit.Pool;
import devkit.Result;
import devkit.Summary;
import devkit.TempDir;
import haxe.Exception;
import haxe.Timer;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * `dev slice-gate <worktree>` — every gate a worker's slice must pass, as ONE command whose report is one row per gate
 * and a verdict, a failed row quoting its first error (docs/testing.md § "The slice gate"). `--baseline`, run once on the
 * untouched worktree, records what the gates later compare with: the base commit, the registry counts, the whole-tree
 * lint, the infra trees' lint and the frozen trees' diff digests; the base suite's counts and corpus snapshot are read
 * by a branch of the first whole-suite gate that compares with them (`BaseSuite`). The rows run as
 * branches at once (`devkit.Branches`, each branch a `--rows` process of this tool): a run its caller gave a pool lease
 * splits that lease among them, and a run without one, inside a workflow, lets the build and each branch take a lease of
 * their own (`devkit.Lease`). Everything it writes goes to `<worktree>-logs/slice-gate/`, never into the worktree.
 */
@:nullSafety(Strict)
final class SliceGate {

	public static inline final USAGE: String = 'usage: dev slice-gate <worktree> [--baseline [--frozen <dir>]... [--infra-tree <dir>]...] '
		+ '[--arm <NAME>]... [--allow-arm <NAME>]... [--no-arms] [--allow <gate>]... [--logs <dir>]';

	/** The environment variable that names the script the branches run instead of this tool's own: a test's stand-in. */
	public static inline final SELF_VAR: String = 'SLICE_GATE_SELF';

	/** The most threads the arms phase takes. */
	public static inline final ARMS_THREADS: Int = 6;

	/** The row the arms phase runs. */
	public static inline final ARMS_ROW: String = 'arms';

	/** The file of the logs that keeps the table a run printed (not `table.txt`, which the workflows redirect the gate's stdout into). */
	public static inline final TABLE_FILE: String = 'printed-table.txt';

	/**
	 * The branches of a gate run, all at once, each running its rows in order: `corpus` reads the sweep `suite` wrote; the
	 * three short rows share one branch, so they hold one thread between them. `arms` is not among them: it is the phase
	 * that follows (`ARMS_BRANCHES`). A whole-suite gate whose base suite is not yet read adds the `base` branch beside them
	 * (`BaseSuite.plan`): the suite row and the corpus row wait for it where they need the base.
	 */
	public static final GATE_BRANCHES: Array<Array<String>> = [
		['suite', 'corpus'],
		['lists', 'fmt', 'scrub', 'artifacts'],
		['lint'],
		['jvm'],
		['infra4'],
		['kits']
	];

	/**
	 * The phase after every other branch has ended: the arms row alone, on a lease of its own. The kill run is a compile
	 * server and a suite process per job, so it asks for a range from one thread up to `ARMS_THREADS`: it
	 * takes what the pool has free when it starts, its `--jobs` follow the lease granted (never the top
	 * of the range), and the threads go back the moment it ends, instead of keeping a gate's lease for it.
	 */
	public static final ARMS_BRANCHES: Array<Array<String>> = [[ARMS_ROW]];

	/** What a branch may run before it is killed: a wedged run, not a slow one. */
	private static inline final BRANCH_TIMEOUT_MS: Int = 2 * 60 * 60 * 1000;

	/** The registries `bin/test.js` lists, each counted in the lists row. */
	private static final LISTINGS: Array<String> = ['classes', 'pins', 'arms', 'claims', 'dead', 'bases'];

	/** The rows of `GATE_BRANCHES` in table order; `arms`, `decisions`, `frozen` and `porcelain` follow, once every branch has ended. */
	private static final GATE_ROWS: Array<String> = [
		'suite',
		'lists',
		'corpus',
		'fmt',
		'lint',
		'jvm',
		'infra4',
		'scrub',
		'artifacts',
		'kits'
	];

	/** The branches of a `--baseline` run; `frozen` follows them. */
	private static final BASELINE_BRANCHES: Array<Array<String>> = [['lists'], ['lint'], ['infra4']];

	private static final BASELINE_ROWS: Array<String> = ['lists', 'lint', 'infra4'];

	/** What a branch reads: the suite's counts for the gate record, every registry's for `--baseline`. */
	private final _readings: Map<String, Int> = [];

	private final _started: Float = Timer.stamp();
	private final _gate: GateTree;
	private final _lint: GateLint;

	/** Where the build's and the branches' threads come from. */
	private final _mode: LeaseMode;

	/** The classes this gate's suite ran on, or null when it ran every class or has not run. */
	private var _selected: Null<Array<String>> = null;

	private function new(options: GateOptions, mode: LeaseMode) {
		_gate = new GateTree(options);
		_lint = new GateLint(_gate);
		_mode = mode;
	}

	/** The `--baseline` run: build, then record every reading the gate compares with. */
	private function recordBaseline(): Int {
		final title: String = 'slice-gate --baseline ${_gate.tree} @ ${GateTree.short(_gate.base)}';
		final self: String = keepSelf();
		_gate.retireBaseline();
		final key: Null<String> = BaselineCache.keyOfRun(
			_gate.base, _gate.options.infra, _gate.options.allow, _gate.git(['status', '--porcelain']).trim() == '', BaseEngine.toolchain()
		);
		if (!build()) return finish(title);
		final digests: Array<FrozenTree> = [for (dir in _gate.options.frozen) { dir: dir, digest: GateTree.diffDigest(dir) }];
		final reused: Null<Baseline> = key == null ? null : BaselineCache.restore(BaselineCache.defaultCache(), key, _gate.logs, digests);
		if (reused != null) {
			final kept: Baseline = reused;
			gate('baseline', () -> {
				File.saveContent(_gate.log(GateTree.BASELINE_FILE), BaselineWriter.write(kept, JsonFormat.instance.defaultWriteOptions));
				_gate.summary.detail('reused the baseline recorded for ${GateTree.short(_gate.base)}, ${GateTree.short(key ?? '')}');
				return Passed;
			});
			return finish(title);
		}
		fanOut(self, BASELINE_BRANCHES, BASELINE_ROWS);
		gate('frozen', () -> {
			if (digests.length == 0) return Skipped('no --frozen');
			_gate.summary.detail([for (d in digests) '${Path.withoutDirectory(d.dir)} ${GateTree.short(d.digest)}'].join(', '));
			return Passed;
		});
		gate('baseline', () -> {
			final unfit: Array<String> = _gate.summary.unfit();
			if (unfit.length > 0)
				return Failed(GateTree.clip('not recorded: ${unfit.join(', ')} did not pass, so no gate may compare with this run'));
			final lists: JValue = BaselineLists.of(LISTINGS, name -> _readings['list-$name'] ?? 0);
			final record: Baseline = {
				base: _gate.base,

				lists: lists,

				lint: _gate.log('lint-base.json'),
				infra: _gate.infraSnapshots(),
				frozen: digests
			};
			File.saveContent(_gate.log(GateTree.BASELINE_FILE), BaselineWriter.write(record, JsonFormat.instance.defaultWriteOptions));
			final entry: Null<String> = key;
			if (entry != null) BaselineCache.store(BaselineCache.defaultCache(), entry, record);
			return Passed;
		});
		return finish(title);
	}

	/** The gate run: every gate against the baseline, one row each. */
	private function check(): Int {
		final head: String = GateTree.short(_gate.git(['rev-parse', 'HEAD']));
		final started: String = GateReuse.treeOf(_gate.tree);
		final title: String =
			'slice-gate ${_gate.tree} @ $head base ${GateTree.short(_gate.base)}: ${_gate.touched.length} file(s) touched';
		final self: String = keepSelf();
		GateReuse.retire(_gate);
		final refusal: Null<String> = registryRefusal();
		if (refusal != null) {
			final why: String = GateTree.clip(refusal);
			_gate.summary.time(ARMS_ROW, () -> Failed(why));
			return finish(title);
		}
		if (!build()) return finish(title);
		fanOut(self, BaseSuite.plan(_gate, wholeSuite()) ? GATE_BRANCHES.concat([[BaseSuite.ROW]]) : GATE_BRANCHES, GATE_ROWS);
		armsPhase(self);
		gate('decisions', decisionsOutcome);
		gate('frozen', frozenOutcome);
		gate('porcelain', () -> {
			final dirty: Array<String> = _gate.git(['status', '--porcelain']).split('\n').filter(l -> l != '');
			_gate.summary.excerpt(dirty);
			return dirty.length == 0 ? Passed : Failed('${dirty.length} entr(ies), first `${dirty[0]}`');
		});
		GateReuse.keep(_gate, _readings, started);
		return finish(title);
	}

	/**
	 * A `--rows` process: run `rows` in order and leave their steps and readings for the gate that started it. Each row names
	 * itself in the branch's progress file as it starts, and the report is left after every row, so a branch cut for silence
	 * costs only the row it stood in.
	 */
	private function runBranch(rows: Array<String>): Int {
		for (name in rows) {
			File.saveContent(branchProgress(rows), name);
			gate(name, rowStep(name));
			Branches.leave(branchReport(rows), _gate.options.run, _gate.summary, _readings);
		}
		return 0;
	}

	/** The step of the row `name` in this run's mode. */
	private function rowStep(name: String): () -> Outcome {
		final recording: Bool = _gate.options.baseline;
		return switch name {
			case 'suite': suiteOutcome;
			case 'corpus': corpusOutcome;
			case 'base': () -> BaseSuite.branch(_gate, _mode);
			case 'lists': recording ? listsRead : listsOutcome;
			case 'lint': recording ? _lint.baseLint : _lint.lintOutcome;
			case 'infra4': recording ? _lint.infraBaseline : _lint.infraOutcome;
			case 'fmt': fmtOutcome;
			case 'jvm': jvmOutcome;
			case 'arms': GateArms.outcome.bind(_gate);
			case 'scrub': scrubOutcome;
			case 'artifacts': artifactsOutcome;
			case 'kits': () ->
				KitsRow.reached(_gate.touched)
					? KitsRow.outcome(_gate.tree, _gate.summary, lines -> File.saveContent(_gate.log('kits.log'), lines.join('\n') + '\n'))
					: Skipped('neither the engine nor a kit changed');
			case _: () -> NotRun('no row named $name');
		};
	}

	/**
	 * This tool's own script (`SELF_VAR` names another), copied into the logs before the build replaces it: the branches
	 * run the code the gate runs, not the code the slice just built.
	 */
	private function keepSelf(): String {
		final dir: String = _gate.log('rows');
		FileSystem.createDirectory(dir);
		final self: String = Path.join([dir, 'dev.js']);
		File.copy(Sys.getEnv(SELF_VAR) ?? FileSystem.fullPath(js.Node.__filename), self);
		return self;
	}

	/**
	 * Run `branches` at once as `--rows` processes of `self`, their rows in `order`: under a held lease the heavy rows take
	 * what the lease leaves beside the others' `demand`, and without one each branch takes its own lease of the pool.
	 */
	private function fanOut(self: String, branches: Array<Array<String>>, order: Array<String>): Void {
		final threads: Null<Int> = switch _mode {
			case Held(held): Branches.perHeavy(held, branches, demand);
			case _: null;
		};
		final label: String = 'slice-gate ${Path.withoutDirectory(_gate.tree)}';
		final leased: Array<String> -> Command = Branches.leased(_mode, branches, demand, branchCommand(self, threads), label);
		for (name => value in Branches.run(_gate.options.run, branches, order, leased, branchReport, _gate.summary))
			_readings[name] = value;
	}

	/**
	 * The arms row, once every other branch has ended: a branch of its own that takes `armsThreads` of the caller's lease, or
	 * under no lease a pool lease of its own for the phase alone (`armsCommand`). A row the plan settles without a run
	 * (`--no-arms`, no arm selected) is read in this process and takes no lease. When a row of the
	 * first fan-out is already red the row is not run: the gate is red whatever the kill run says.
	 */
	private function armsPhase(self: String): Void {
		final plan: Null<ArmPlan> = armsPlan();
		final tracks: Int = switch plan {
			case Settled(outcome):
				gate(ARMS_ROW, () -> outcome);
				return;
			case Runs(picked, _): picked.fast.length;
			case null: ARMS_THREADS;
		};
		final red: Array<String> = _gate.summary.unfit();
		if (red.length > 0) {
			gate(
				ARMS_ROW, () -> NotRun(GateTree.clip('not run: ${red.join(', ')} did not pass, so the gate is red whatever the arms say'))
			);
		} else {
			final command: Array<String> -> Command = branchCommand(self, armsThreads(_mode, tracks));
			final label: String = 'slice-gate ${Path.withoutDirectory(_gate.tree)} arms';
			final leased: Array<String> -> Command = rows -> armsCommand(_mode, command(rows), label, tracks);
			for (name => value in Branches.run(_gate.options.run, ARMS_BRANCHES, [ARMS_ROW], leased, branchReport, _gate.summary))
				_readings[name] = value;
		}
	}

	/** The `--rows` process of a branch running `rows`, over the logs' copy `self` of this script, handed `threads`. */
	private function branchCommand(self: String, threads: Null<Int>): Array<String> -> Command {
		return rows ->
			Command.of(['node', self, 'slice-gate'].concat(branchArgs(_gate.options, rows, threads)))
				.at(_gate.tree)
				.env('HXQ_BIN', _gate.apq())
				.timeout(BRANCH_TIMEOUT_MS)
				.watched(BranchWatch.idleOf(rows), branchProgress(rows), true);
	}

	/** The file the branch running `rows` rewrites with the name of each row it starts: a branch that stops rewriting it is stalled. */
	private function branchProgress(rows: Array<String>): String {
		return _gate.branchProgress(rows[0]);
	}

	/** Where the branch running `rows` leaves its report. */
	private function branchReport(rows: Array<String>): String {
		return _gate.branchReport(rows[0]);
	}

	/** The threads the branch running `rows` holds in this run (`demandOf`). */
	private function demand(rows: Array<String>): Null<Int> {
		final baseline: Null<Baseline> = _gate.baseline;
		return demandOf({
			recording: _gate.options.baseline,
			infra: _gate.options.infra.length,
			touchedHx: _gate.touched.exists(f -> f.endsWith('.hx')),
			jvmMoved: _gate.jvmMoved(),
			kitsMoved: KitsRow.reached(_gate.touched),
			ruleInfra: _gate.ruleCodeMoved() && baseline != null ? baseline.infra.length : null
		}, rows);
	}

	/** The build every gate needs: both binaries and the developer CLI, at once. A failure ends the run. */
	private function build(): Bool {
		final outcome: Outcome = _gate.summary.time(
			'build', () -> switch Binaries.compileWith(_gate.tree, _gate.log('build.log'), [], _mode) {
				case Failed(why):
					_gate.summary.excerpt(GateExcerpt.compile(File.getContent(_gate.log('build.log'))));
					Failed(GateTree.clip(why));
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
		final table: String = _gate.summary.table();
		Sys.println(table);
		File.saveContent(_gate.log(TABLE_FILE), '$table\n');
		final excerpts: String = _gate.summary.excerpts();
		if (excerpts != '') Sys.println(excerpts);
		final passed: Bool = _gate.summary.passed();
		final wall: String = '${Math.round(Timer.stamp() - _started)}s${_gate.summary.waitedSuffix()}';
		Sys.println(passed ? 'slice-gate: PASS in $wall' : 'slice-gate: FAIL in $wall — logs ${_gate.logs}');
		return passed ? 0 : 1;
	}

	/**
	 * The suite row: `dev shard` over the heavy rows' threads (its own default outside a lease), green and counted. A check runs
	 * only the classes its change reaches (`SuiteImpact`), or every class when no text dependency bounds the change, and says
	 * which; only a whole run is set beside the base's counts (`BaseSuite`).
	 */
	private function suiteOutcome(): Outcome {
		GateTree.clearSnapshotIn(_gate.tree);
		final scope: SuiteScope = SuiteImpact.ofTree(_gate.tree, _gate.base);
		final only: Null<Array<String>> = switch scope {
			case Selected(classes): classes;
			case WholeSuite(_): null;
		};
		final mode: String = switch scope {
			case WholeSuite(why): 'whole suite — $why';
			case Selected(classes): 'impact — ${classes.length} class(es) the change reaches';
		};
		File.saveContent(_gate.log('suite-scope.txt'), [mode].concat(only ?? []).join('\n') + '\n');
		_selected = only;
		if (only != null) _readings[GateReuse.IMPACT] = only.length;
		if (only != null && only.length == 0) return Skipped('impact — no test class depends on the change');
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
			counted: sum -> totals = sum,
			only: only
		});
		File.saveContent(_gate.log('suite.log'), lines.join('\n') + '\n');
		final sum: Null<Tally> = totals;
		if (sum == null || sum.tests == 0) {
			_gate.summary.excerpt(GateExcerpt.suite(lines));
			return Failed(GateTree.clip('no suite totals: ${lines[0] ?? ''} — ${_gate.log('suite.log')}'));
		}
		// a check reads them too: its gate record hands them to a land of the same tree
		_readings['tests'] = sum.tests;
		_readings['assertions'] = sum.assertions;
		final delta: String = BaseSuite.deltaNote(_gate, _mode, sum, status, only);
		_gate.summary.detail(GateTree.clip(
			'${sum.tests} tests / ${sum.assertions} assertions / ${sum.failures}F / ${sum.errors}E$delta, $shards shard(s); $mode'
		));
		if (status == 0) return Passed;
		_gate.summary.excerpt(GateExcerpt.suite(lines));
		final verdict: String = lines.find(l -> l.startsWith('suite-shard: FAILED')) ?? 'dev shard exited $status';
		final locus: Null<String> = lines.find(l -> ~/^  shard \d+ /.match(l));
		return Failed(GateTree.clip(locus == null ? verdict : '$verdict — ${locus.trim()}'));
	}

	/** The lists row of `--baseline`: every registry's count, kept for the baseline. */
	private function listsRead(): Outcome {
		final listed: Map<String, Array<String>> = listings();
		for (name in LISTINGS) _readings['list-$name'] = listed[name]?.length ?? 0;
		_gate.summary.detail([for (name in LISTINGS) '$name ${listed[name]?.length ?? 0}'].join(' '));
		return Passed;
	}

	/** The lists row: every registry's count beside the baseline's, and no dead fixture. */
	private function listsOutcome(): Outcome {
		final listed: Map<String, Array<String>> = listings();
		final readings: Array<String> = [
			for (name in LISTINGS) {
				final was: Null<Int> = _gate.baseline == null ? null : BaselineLists.count(_gate.baseline.lists, name);
				final now: Int = listed[name]?.length ?? 0;
				was == null || was == now ? '$name $now' : '$name $now (${GateTree.signed(now - was)})';
			}
		];
		_gate.summary.detail(readings.join(' '));
		final dead: Array<String> = listed['dead'] ?? [];
		if (dead.length == 0) return Passed;
		_gate.summary.excerpt(dead);
		return Failed('a fixture-named method no runner reaches: `node bin/test.js --list-dead`');
	}

	/** The corpus row: the sweep the suite just wrote against the baseline's snapshot, no fixture moved. */
	private function corpusOutcome(): Outcome {
		final baseline: Null<Baseline> = _gate.baseline;
		if (baseline == null) return NotRun(GateTree.NO_BASELINE);
		if (!GateTree.forkSet()) return NotRun('no corpus: ANYPARSE_HXFORMAT_FORK unset');
		final shortfall: Null<Outcome> = GateTree.corpusShortfall(GateTree.forkProblem(), _gate.snapshotProblem(), _selected);
		if (shortfall != null) return shortfall;
		final sweep: Null<String> = switch BaseSuite.read(_gate, _mode) {
			case Read(base): base.sweep;
			case Unread(why): return NotRun(GateTree.clip('no corpus snapshot of the base: $why'));
		};
		if (sweep == null) return NotRun('no corpus: the base suite ran no corpus case');
		_gate.inTree(cmd('node bin/apq.js sweep --lang haxe --save ${_gate.log(GateReuse.SWEEP)}'));
		final diff: Result = _gate.inTree(cmd('node bin/apq.js sweep --lang haxe --diff $sweep'));
		if (!diff.ok) {
			_gate.summary.excerpt(Excerpt.errors(diff.out + diff.err));
			return Failed(GateTree.quote(diff));
		}
		final line: String = diff.lines().find(l -> l.startsWith('--- sweep --diff')) ?? '';
		_gate.summary.detail(diff.lines()[0] ?? '');
		if (line.indexOf(': 0 fixtures changed') >= 0) return Passed;
		_gate.summary.excerpt(diff.lines().filter(l -> l != line));
		return Failed(GateTree.clip(line));
	}

	/**
	 * The project-config half of the fmt row: no file the writer would rewrite, none needing a second pass, over `GateTree.fmtScope`.
	 */
	private function projectFmtOutcome(): Outcome {
		final scope: Array<String> = GateTree.fmtScope(_gate.touched);
		if (scope.length == 0) return Skipped('no engine or formatter config change, no touched .hx');
		final fmt: Result = _gate.hxq(_gate.tree, ['fmt', '--list', '--one-pass'].concat(scope)).run();
		final line: String = '${fmt.out}\n${fmt.err}'.split('\n').find(l -> l.indexOf('would be rewritten') >= 0) ?? '';
		_gate.summary.detail(line.replace('apq fmt --list: ', ''));
		if (fmt.ok && line.indexOf(': 0 of ') >= 0) return Passed;
		_gate.summary.excerpt(Excerpt.linesOf('${fmt.out}\n${fmt.err}').filter(l -> l != line));
		return Failed(line == '' ? GateTree.quote(fmt) : GateTree.clip(line));
	}

	/** The jvm row, for a slice that touched `src/`: `dev jvm-portability` and its gate line. */
	private function jvmOutcome(): Outcome {
		if (!_gate.jvmMoved()) return Skipped('neither src/ nor the probe changed');
		final probe: Result = _gate.inTree(cmd('node bin/dev.js jvm-portability --repo ${_gate.tree}'));
		File.saveContent(_gate.log('jvm.log'), probe.out + probe.err);
		final line: String = probe.lines().find(l -> l.startsWith('gate:')) ?? '';
		_gate.summary.detail(line);
		if (probe.ok) return Passed;
		_gate.summary.excerpt(Excerpt.errors(probe.out + probe.err));
		return Failed(line == '' ? GateTree.quote(probe) : GateTree.clip(line));
	}

	/** The scrub row: `dev scrub-guard` over the tree and over what the slice's commits add. */
	private function scrubOutcome(): Outcome {
		final tree: Result = _gate.inTree(cmd('node bin/dev.js scrub-guard'));
		final range: Result = _gate.inTree(cmd('node bin/dev.js scrub-guard --range ${_gate.base}..HEAD'));
		final verdict: Outcome = ScrubRow.verdict(tree, range);
		switch verdict {
			case Failed(_):
				final failing: Result = tree.ok ? range : tree;
				_gate.summary.excerpt(Excerpt.linesOf(failing.out + failing.err));
			case NotRun(_):
				_gate.summary.detail('${GateTree.short(_gate.base)}..HEAD clean of home paths only');
			case _:
				_gate.summary.detail('tree and ${GateTree.short(_gate.base)}..HEAD clean');
		}
		return verdict;
	}

	/** The artifacts row: no touched file is build output or over 1 MB, unless `--allow` names its path. */
	private function artifactsOutcome(): Outcome {
		final found: Array<String> = ArtifactRow.offendersAtBase(_gate.tree, _gate.base, _gate.touched, _gate.options.allow);
		_gate.summary.detail('${_gate.touched.length} touched file(s) checked');
		if (found.length == 0) return Passed;
		_gate.summary.excerpt(found);
		return Failed(GateTree.clip('${found.length} artifact(s), first ${found[0]}'));
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
			if (why == null) continue;
			_gate.summary.excerpt([why, line]);
			return Failed(GateTree.clip('$why: $line'));
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

	/** The lines of every registry `bin/test.js` lists, all listed at once. */
	private function listings(): Map<String, Array<String>> {
		final runs: Array<Result> = Pool.of(LISTINGS.length)
			.map(LISTINGS, name -> cmd('node bin/test.js --list-$name').at(_gate.tree).env('HXQ_BIN', _gate.apq()));
		return [for (i => name in LISTINGS) name => runs[i].check().lines()];
	}

	/**
	 * Why the arm registry cannot be read (`ArmRegistryError`: a misplaced arm, a broken document), null when it can or when
	 * `--no-arms` leaves it unread: a registry that does not read ends the gate before the build, unwaivable, so no row
	 * shows it only as branches that never ran.
	 */
	private function registryRefusal(): Null<String> {
		if (_gate.options.noArms) return null;
		return try {
			ArmRegistry.verify(Path.join([_gate.tree, ArmRegistry.DIRECTORY]));
			null;
		} catch (exception: ArmRegistryError) {
			'arm registry unreadable: ${exception.message}';
		};
	}

	/**
	 * The plan of the arms row, null when it cannot be made: that is left to the branch, whose row then says why, so a bad
	 * plan never ends the gate after every other row has run.
	 */
	private function armsPlan(): Null<ArmPlan> {
		return try GateArms.plan(_gate) catch (_: Exception) null;
	}

	/**
	 * The fmt row: the project-config half and the cross-config half. A slice that moves a file the vendored second config needs two
	 * rewrites for fails here, not in the battery after the merge.
	 */
	private function fmtOutcome(): Outcome {
		return fmtCombined(projectFmtOutcome(), crossConfigFmtOutcome());
	}

	/**
	 * The cross-config half of the fmt row: the `.hx` files the slice touched, formatted one-pass under the vendored second
	 * config, against the part of `XconfigFmt.XCONFIG_ONE_PASS` they hold.
	 */
	private function crossConfigFmtOutcome(): Outcome {
		final stand: XconfigStand = TempDir.with(
			scratch -> XconfigFmt.touchedStand(args -> _gate.hxq(_gate.tree, args), _gate.tree, _gate.touched, scratch.file('xconfig'))
		);
		return switch stand {
			case Skipped: Skipped('no touched .hx');
			case Holds: Passed;
			case Breaks(failure):
				_gate.summary.excerpt(failure.detail);
				Failed(GateTree.clip(failure.line));
		};
	}

	/** Whether the suite row runs every class: no text dependency bounds the slice's change (`SuiteImpact`). */
	private function wholeSuite(): Bool {
		return switch SuiteImpact.ofTree(_gate.tree, _gate.base) {
			case WholeSuite(_): true;
			case Selected(_): false;
		};
	}

	/** The command line of the branch running `rows`: this run's options, the rows, and the heavy rows' threads. */
	public static function branchArgs(options: GateOptions, rows: Array<String>, threads: Null<Int>): Array<String> {
		final args: Array<String> = [
			options.tree,
			'--logs',
			options.logs,
			'--rows',
			rows.join(','),
			'--run',
			options.run
		];
		if (options.baseline) args.push('--baseline');
		for (dir in options.infra) args.push('--infra-tree=$dir');
		for (arm in options.arms) args.push('--arm=$arm');
		for (name in options.allow) args.push('--allow=$name');
		for (arm in options.allowArms) args.push('--allow-arm=$arm');
		if (options.noArms) args.push('--no-arms');
		if (threads != null) args.push('--threads=$threads');
		return args;
	}

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final baseline: Bool = args.flag('--baseline');
		final noArms: Bool = args.flag('--no-arms');
		final frozen: Array<String> = args.options('--frozen');
		final infra: Array<String> = args.options('--infra-tree');
		final arms: Array<String> = args.options('--arm');
		final allow: Array<String> = args.options('--allow');
		final allowArms: Array<String> = args.options('--allow-arm');
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
			allowArms: allowArms,
			noArms: noArms,
			threads: threads != null && threads > 0 ? threads : null,
			run: run
		}, leaseModeOf(rows));
		if (rows != null) return gate.runBranch(rows.split(','));
		return baseline ? gate.recordBaseline() : gate.check();
	}

	/**
	 * The threads the branch running `rows` holds under `facts`: null for the heavy one (the suite), which takes
	 * what the others leave; one for the short rows; the lint row's two lints (the touched files at the base and now); the
	 * jvm probe; a lint per tree INFRA gate 4 reads beside the base tree's, which a `--baseline` run lints in its own row —
	 * each 0 when its rows will skip.
	 */
	public static function demandOf(facts: GateDemand, rows: Array<String>): Null<Int> {
		return switch rows[0] {
			case 'suite', BaseSuite.ROW: null;
			case 'lists': facts.recording ? 0 : 1;
			case 'lint': if (facts.recording)
				Std.int(Math.min(1, facts.infra))
			else if (facts.touchedHx)
				2
			else
				0;
			case 'jvm': facts.jvmMoved ? 1 : 0;
			case 'kits': facts.recording || !facts.kitsMoved ? 0 : Probe.GATE_THREADS;
			case 'infra4': facts.recording ? facts.infra : 1 + (facts.ruleInfra ?? -1);
			case _: 0;
		};
	}

	/**
	 * The lease mode of a run: a `--rows` branch (`rows` given) runs inside the lease its gate took for it, or none, and never
	 * asks the pool itself; the gate reads its environment.
	 */
	public static function leaseModeOf(rows: Null<String>): LeaseMode {
		return rows == null ? Lease.ofEnvironment() : Unpooled;
	}

	/**
	 * The threads the arms branch takes of a lease its caller `mode` holds: what that
	 * lease has, up to the ask for a kill run of `tracks` tracks (`GateArms.armsAsk`); null
	 * when the caller holds none (the branch's own lease says it).
	 */
	public static function armsThreads(mode: LeaseMode, tracks: Int): Null<Int> {
		return switch mode {
			case Held(held): Std.int(Math.min(held, GateArms.armsAsk(tracks)));
			case _: null;
		};
	}

	/**
	 * `command` of the arms branch as `mode` runs it: under `Own` a lease of its own from one thread up to
	 * the ask for `tracks` tracks (`GateArms.armsAsk`; exactly one thread, with no wait, for one track),
	 * labelled `label`, which goes back to the pool as the arms end; under `Held` and `Unpooled` as it is.
	 */
	public static function armsCommand(mode: LeaseMode, command: Command, label: String, tracks: Int): Command {
		return Lease.take(mode, command, { min: 1, max: GateArms.armsAsk(tracks) }, label);
	}

	/**
	 * The fmt row from its two halves: the cross-config half only adds to the project half (it skipped is no news; the project half
	 * skipped leaves the cross half's word), and a row
	 * failing both ways says both.
	 */
	public static function fmtCombined(project: Outcome, cross: Outcome): Outcome {
		return switch [project, cross] {
			case [Skipped(_), Skipped(_)]: project;
			case [Skipped(_), _]: cross;
			case [Passed, Skipped(_)]: Passed;
			case [Passed, _]: cross;
			case [Failed(first), Failed(second)]: Failed('$first; $second');
			case _: project;
		};
	}

}

/** What the threads of a slice gate's branches depend on (`SliceGate.demandOf`). */
typedef GateDemand = {
	/** Whether the run is a `--baseline` one. */
	var recording: Bool;

	/** The infra trees the run was given. */
	var infra: Int;

	/** Whether the slice touched a `.hx` file, which the lint row lints at the base and now. */
	var touchedHx: Bool;

	var jvmMoved: Bool;

	/** Whether the engine or a probe kit moved, so the kits row runs (`KitsRow.reached`). */
	var kitsMoved: Bool;

	/** The infra trees of the baseline when rule code moved, or null when INFRA gate 4 does not run. */
	var ruleInfra: Null<Int>;
}
