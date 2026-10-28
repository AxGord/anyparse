package dev;

import anyparse.query.Cli.TestSummaryFailureLocus;
import anyparse.query.Cli.TestSummaryResult;
import anyparse.query.cli.TestTranscript;
import dev.Census.CensusMode;
import dev.Census.CensusRun;
import dev.MergeArms.ArmRecord;
import dev.MergeArms.RecordFile;
import dev.Shard.SuiteCounts;
import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.Result;
import devkit.Summary;
import devkit.TempDir;
import haxe.DynamicAccess;
import haxe.Exception;
import haxe.Json;
import haxe.crypto.Sha1;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * `dev slice-gate <worktree>` — every gate a worker's slice must pass, as ONE command whose report is one row per gate
 * and a verdict, a failed row quoting its first error (docs/testing.md § "The slice gate"). `--baseline`, run once on the
 * untouched worktree, records what the gates later compare with: the base commit, the suite and registry counts, the
 * corpus snapshot, the whole-tree lint, the infra trees' lint and the frozen trees' diff digests. Everything it writes
 * goes to `<worktree>-logs/slice-gate/`, never into the worktree.
 */
@:nullSafety(Strict)
final class SliceGate {

	public static inline final USAGE: String = 'usage: dev slice-gate <worktree> [--baseline [--frozen <dir>]... [--infra-tree <dir>]...] '
		+ '[--arm <NAME>]... [--no-arms] [--allow <gate>]... [--logs <dir>]';

	/** What the suite may run before it is killed: a wedged run, not a slow one. */
	private static inline final SUITE_TIMEOUT_MS: Int = 2 * 60 * 60 * 1000;

	/** How long a quoted error may grow in a report row. */
	private static inline final QUOTE_WIDTH: Int = 150;

	/** How many arm names an arms row spells before it elides the rest. */
	private static inline final ARMS_SHOWN: Int = 6;

	/** The characters of a commit or a digest a report row spells. */
	private static inline final SHORT_HASH: Int = 9;

	/** The registry whose records the arms row selects from. */
	private static inline final ARMS_REGISTRY: String = 'test/testkit/mutation-arms.json';

	/** Why a gate that compares with the baseline cannot run. */
	private static inline final NO_BASELINE: String = 'no baseline — run `dev slice-gate <worktree> --baseline` before the first edit';

	/** The probe's own source: the jvm row runs when it moves, as when `src/` does. */
	private static inline final JVM_PROBE: String = 'tools/src/dev/JvmPortability.hx';

	/** The directories whose change can move a lint rule's findings: `query` and `check`, `query/cli` excepted. */
	private static final RULE_CODE: EReg = ~/^src\/anyparse\/(check|query)\/(?!cli\/)/;

	/** The registries `bin/test.js` lists, each counted in the lists row. */
	private static final LISTINGS: Array<String> = ['classes', 'pins', 'arms', 'claims', 'dead', 'bases'];

	/** The source roots whose files are modules a mutation arm can name. */
	private static final MODULE_ROOTS: Array<String> = ['src/', 'tools/src/', 'test/'];

	/** The scope of a whole-tree lint of this project. */
	private static final TREE_SCOPE: Array<String> = ['src', 'test', 'tools'];

	private final _summary: Summary = new Summary();
	private final _tree: String;
	private final _logs: String;
	private final _allow: Array<String>;

	private function new(tree: String, logs: String, allow: Array<String>) {
		_tree = tree;
		_logs = logs;
		_allow = allow;
	}

	private inline function apq(): String {
		return Path.join([_tree, 'bin/apq.js']);
	}

	private inline function log(name: String): String {
		return Path.join([_logs, name]);
	}

	/** The `--baseline` run: build, then record every reading the gate compares with. */
	private function recordBaseline(frozen: Array<String>, infra: Array<String>): Int {
		final base: String = git(['rev-parse', 'HEAD']).trim();
		final title: String = 'slice-gate --baseline $_tree @ ${short(base)}';
		if (!build()) return finish(title);
		var counts: SuiteCounts = { tests: 0, assertions: 0 };
		gate('suite', () -> {
			final summary: TestSummaryResult = runSuite();
			counts = { tests: summary.tests, assertions: summary.assertions };
			return suiteOutcome(summary, null);
		});
		final lists: DynamicAccess<Int> = {};
		gate('lists', () -> {
			for (name => count in listCounts()) lists[name] = count;
			_summary.detail([for (name in LISTINGS) '$name ${lists[name]}'].join(' '));
			return Passed;
		});
		final sweep: Null<String> = forkSet() ? log('sweep-base.json') : null;
		gate('corpus', () -> {
			if (sweep == null) return Skipped('ANYPARSE_HXFORMAT_FORK unset — the suite ran no corpus');
			final saved: Result = inTree(cmd('node bin/apq.js sweep --save $sweep'));
			_summary.detail(saved.lines()[0] ?? '');
			return saved.ok ? Passed : Failed(quote(saved));
		});
		final lint: String = log('lint-base.json');
		// the base engine's whole-tree findings are what INFRA gate 4 compares the new engine with; nothing else reads them
		gate(
			'lint',
			() -> infra.length == 0 ? Skipped('no --infra-tree, so INFRA gate 4 needs no base lint') : lintJson(_tree, TREE_SCOPE, lint)
		);
		final snapshots: Array<InfraSnapshot> = [for (i => dir in infra) { tree: dir, snapshot: log('infra-$i.json') }];
		gate('infra4', () -> {
			if (snapshots.length == 0) return Skipped('no --infra-tree');
			for (snapshot in snapshots) switch lintJson(snapshot.tree, ['.'], snapshot.snapshot) {
				case Passed:
				case other:
					return other;
			}
			return Passed;
		});
		final digests: Array<FrozenTree> = [for (dir in frozen) { dir: dir, digest: digest(dir) }];
		gate('frozen', () -> {
			if (digests.length == 0) return Skipped('no --frozen');
			_summary.detail([for (d in digests) '${Path.withoutDirectory(d.dir)} ${short(d.digest)}'].join(', '));
			return Passed;
		});
		final record: Baseline = {
			base: base,
			tests: counts.tests,
			assertions: counts.assertions,
			lists: lists,
			sweep: sweep,
			lint: lint,
			infra: snapshots,
			frozen: digests
		};
		File.saveContent(log('baseline.json'), Json.stringify(record, null, '\t'));
		return finish(title);
	}

	/** The gate run: every gate against the baseline, one row each. */
	private function check(extraArms: Array<String>, noArms: Bool): Int {
		final file: String = log('baseline.json');
		final baseline: Null<Baseline> = FileSystem.exists(file) ? Json.parse(File.getContent(file)) : null;
		final base: String = baseline?.base ?? git(['merge-base', 'HEAD', 'main']).trim();
		final touched: Array<String> = touchedFiles(base);
		final title: String =
			'slice-gate $_tree @ ${short(git(['rev-parse', 'HEAD']))} base ${short(base)}: ${touched.length} file(s) touched';
		if (!build()) return finish(title);
		gate('suite', () -> suiteOutcome(runSuite(), baseline));
		gate('lists', () -> listsOutcome(baseline));
		gate('corpus', () -> corpusOutcome(baseline));
		gate('fmt', fmtOutcome);
		gate('lint', lintOutcome.bind(base, touched));
		gate('jvm', jvmOutcome.bind(touched));
		gate('arms', armsOutcome.bind(base, touched, extraArms, noArms));
		gate('infra4', () -> infraOutcome(base, touched, baseline));
		gate('scrub', scrubOutcome.bind(base));
		gate('frozen', () -> frozenOutcome(baseline));
		gate('porcelain', () -> {
			final dirty: Array<String> = git(['status', '--porcelain']).split('\n').filter(l -> l != '');
			return dirty.length == 0 ? Passed : Failed('${dirty.length} entr(ies), first `${dirty[0]}`');
		});
		return finish(title);
	}

	/** The build every gate needs: both binaries and the developer CLI, at once. A failure ends the run. */
	private function build(): Bool {
		final outcome: Outcome = _summary.time(
			'build', () -> switch Binaries.compile(_tree, log('build.log')) {
				case Failed(why): Failed(clip(why));
				case other: other;
			}
		);
		return outcome.match(Passed);
	}

	/** Run the step `name` as `Summary.time` does; a failure of a gate named by `--allow` passes, saying so. */
	private function gate(name: String, step: () -> Outcome): Void {
		_summary.time(
			name, () -> switch step() {
				case Failed(why) if (_allow.contains(name)):
					_summary.detail('allowed: $why');
					Passed;
				case other: other;
			}
		);
	}

	/** Print the title, the table and the verdict; answers the exit status. */
	private function finish(title: String): Int {
		Sys.println(title);
		Sys.println(_summary.table());
		final passed: Bool = _summary.passed();
		Sys.println(passed ? 'slice-gate: PASS' : 'slice-gate: FAIL — logs $_logs');
		return passed ? 0 : 1;
	}

	/** The unfiltered suite on the worktree's engine, its transcript kept in the logs. */
	private function runSuite(): TestSummaryResult {
		final run: Result = inTree(cmd('node bin/test.js').timeout(SUITE_TIMEOUT_MS));
		File.saveContent(log('suite.log'), run.out + run.err);
		return TestTranscript.parseTestSummary(run.out);
	}

	/** The suite row: green and counted, its counts beside the baseline's. */
	private function suiteOutcome(summary: TestSummaryResult, baseline: Null<Baseline>): Outcome {
		if (!summary.counted || summary.noTests) return Failed('no utest summary in ${log('suite.log')}');
		final delta: String = baseline == null
			? ''
			: ' (${signed(summary.tests - baseline.tests)} / ${signed(summary.assertions - baseline.assertions)})';
		_summary.detail('${summary.tests} tests / ${summary.assertions} assertions / 0F / 0E$delta');
		if (summary.failures + summary.errors == 0) return Passed;
		final first: Null<TestSummaryFailureLocus> = summary.firstFailure;
		final where: String = first == null ? '' : ' — ${first.className}.${first.testName}: ${first.message}';
		return Failed(clip('${summary.failures}F ${summary.errors}E$where'));
	}

	/** The lists row: every registry's count beside the baseline's, no dead fixture, and the census in sync with them. */
	private function listsOutcome(baseline: Null<Baseline>): Outcome {
		final counts: Map<String, Int> = listCounts();
		final readings: Array<String> = [
			for (name in LISTINGS) {
				final was: Null<Int> = baseline?.lists[name];
				final now: Int = counts[name] ?? 0;
				was == null || was == now ? '$name $now' : '$name $now (${signed(now - was)})';
			}
		];
		final report: Array<String> = [];
		final census: CensusRun = Census.run(_tree, Path.join([_tree, 'bin/test.js']), CensusMode.Check, report.push);
		_summary.detail(readings.join(' '));
		if ((counts['dead'] ?? 0) > 0) return Failed('a fixture-named method no runner reaches: `node bin/test.js --list-dead`');
		if (census.ok) return Passed;
		final first: String = report.find(l -> l.indexOf(': in sync') < 0) ?? '';
		return Failed(clip('census $first — `node bin/dev.js census --write`'));
	}

	/** The corpus row: the sweep the suite just wrote against the baseline's snapshot, no fixture moved. */
	private function corpusOutcome(baseline: Null<Baseline>): Outcome {
		if (baseline == null) return NotRun(NO_BASELINE);
		final sweep: Null<String> = baseline.sweep;
		if (sweep == null || !forkSet()) return NotRun('no corpus: ANYPARSE_HXFORMAT_FORK unset at the baseline or now');
		final diff: Result = inTree(cmd('node bin/apq.js sweep --diff $sweep'));
		if (!diff.ok) return Failed(quote(diff));
		final line: String = diff.lines().find(l -> l.startsWith('--- sweep --diff')) ?? '';
		_summary.detail(diff.lines()[0] ?? '');
		return line.indexOf(': 0 fixtures changed') >= 0 ? Passed : Failed(clip(line));
	}

	/** The fmt row: no file the writer would rewrite, none needing a second pass. */
	private function fmtOutcome(): Outcome {
		final fmt: Result = hxq(_tree, ['fmt', '--list', '--one-pass'].concat(TREE_SCOPE));
		final line: String = '${fmt.out}\n${fmt.err}'.split('\n').find(l -> l.indexOf('would be rewritten') >= 0) ?? '';
		_summary.detail(line.replace('apq fmt --list: ', ''));
		return fmt.ok && line.indexOf(': 0 of ') >= 0 ? Passed : Failed(line == '' ? quote(fmt) : clip(line));
	}

	/**
	 * The lint row: the touched `.hx` files linted with the oracle, against the same files linted the same way in a
	 * checkout of the base — one engine, one scope, so the only difference left is the slice's own code.
	 */
	private function lintOutcome(base: String, touched: Array<String>): Outcome {
		final files: Array<String> = touched.filter(f -> f.endsWith('.hx'));
		if (files.length == 0) return Skipped('no .hx touched');
		final now: String = log('lint-touched.json');
		final linted: Outcome = lintJson(_tree, files, now);
		if (!linted.match(Passed)) return linted;
		final old: String = log('lint-touched-base.json');
		return withBaseCheckout(base, checkout -> {
			final existed: Array<String> = files.filter(f -> FileSystem.exists(Path.join([checkout, f])));
			if (existed.length == 0) {
				File.saveContent(old, '[]');
			} else {
				final before: Outcome = lintJson(checkout, existed, old);
				if (!before.match(Passed)) return before;
			}
			final moved: LintMove = lintDiff(old, now, 'lint-touched.txt');
			_summary.detail('${moved.added} new on ${files.length} file(s)');
			return moved.added == 0 ? Passed : Failed(clip('${moved.added} new: ${moved.first} — ${log('lint-touched.txt')}'));
		});
	}

	/** The jvm row, for a slice that touched `src/`: `dev jvm-portability` and its gate line. */
	private function jvmOutcome(touched: Array<String>): Outcome {
		if (!touched.exists(f -> f.startsWith('src/') || f == JVM_PROBE)) return Skipped('neither src/ nor the probe changed');
		final probe: Result = inTree(cmd('node bin/dev.js jvm-portability --repo $_tree'));
		File.saveContent(log('jvm.log'), probe.out + probe.err);
		final line: String = probe.lines().find(l -> l.startsWith('gate:')) ?? '';
		_summary.detail(line);
		return probe.ok ? Passed : Failed(line == '' ? quote(probe) : clip(line));
	}

	/**
	 * The arms row: `tools/mutation-arm.sh --fast` over the arms the slice added or re-encoded, every arm on a type it
	 * touched, and each `--arm`. The registry's whole `--all` is a release run, never a slice gate.
	 */
	private function armsOutcome(base: String, touched: Array<String>, extra: Array<String>, noArms: Bool): Outcome {
		if (noArms) return Skipped('--no-arms');
		final now: RecordFile = MergeArms.parse(File.getContent(Path.join([_tree, ARMS_REGISTRY])));
		final shown: Result = cmd('git -C $_tree show $base:$ARMS_REGISTRY').run();
		final old: Null<RecordFile> = shown.ok ? MergeArms.parse(shown.out) : null;
		final modules: Array<String> = [for (file in touched) moduleOf(file)].filter(m -> m != '');
		final killers: Array<String> = pinnedKillers(modules);
		final names: Array<String> = [
			for (record in now.records)
				if (changed(record, old) || onModule(record, modules) || killers.contains(record.key) || extra.contains(record.key))
					record.key
		];
		for (name in extra) if (!names.contains(name)) return Failed('--arm $name names no arm in $ARMS_REGISTRY');
		if (names.length == 0) return Skipped('no arm added, re-encoded or on a touched type');
		final run: Result = inTree(cmd('tools/mutation-arm.sh $names --fast'));
		File.saveContent(log('arms.log'), run.out + run.err);
		final tally: EReg = ~/^(\d+) tracks: (\d+) killed, .*$/m;
		if (!tally.match(run.out)) return Failed('no verdict line — ${quote(run)}');
		final list: String = names.slice(0, ARMS_SHOWN).join(', ') + (names.length > ARMS_SHOWN ? ', …' : '');
		_summary.detail('${tally.matched(0)} ($list)');
		return run.ok && tally.matched(1) == tally.matched(2) ? Passed : Failed(clip('${tally.matched(0)} — ${log('arms.log')}'));
	}

	/**
	 * The INFRA gate 4 row, for a slice that touched rule code: the base tree and every infra tree linted by this engine,
	 * against the baseline's lint of the same tree by the base engine. A finding that moved fails the row until it is
	 * explained and waived with `--allow infra4`.
	 */
	private function infraOutcome(base: String, touched: Array<String>, baseline: Null<Baseline>): Outcome {
		if (!touched.exists(f -> RULE_CODE.match(f))) return Skipped('no rule code touched');
		if (baseline == null) return NotRun(NO_BASELINE);
		if (baseline.infra.length == 0) return NotRun('rule code moved, but the baseline recorded no --infra-tree');
		return withBaseCheckout(base, checkout -> compareInfra([{ tree: checkout, snapshot: baseline.lint }].concat(baseline.infra)));
	}

	/** Lint every tree of `pairs` (the first the base checkout) and compare it with its snapshot. */
	private function compareInfra(pairs: Array<InfraSnapshot>): Outcome {
		final moves: Array<String> = [];
		for (i => pair in pairs) {
			final now: String = log('infra-now-$i.json');
			final linted: Outcome = lintJson(pair.tree, i == 0 ? TREE_SCOPE : ['.'], now);
			if (!linted.match(Passed)) return linted;
			final moved: LintMove = lintDiff(pair.snapshot, now, 'infra-$i.txt');
			final name: String = i == 0 ? 'base tree' : Path.withoutDirectory(pair.tree);
			if (moved.added + moved.removed > 0) moves.push('$name +${moved.added} -${moved.removed}');
		}
		_summary.detail('${pairs.length} tree(s), nothing moved');
		return moves.length == 0 ? Passed : Failed('findings moved: ${moves.join(', ')} — ${log('infra-<k>.txt')}');
	}

	/** The scrub row: `dev scrub-guard` over the tree and over what the slice's commits add. */
	private function scrubOutcome(base: String): Outcome {
		final tree: Result = inTree(cmd('node bin/dev.js scrub-guard'));
		final range: Result = inTree(cmd('node bin/dev.js scrub-guard --range $base..HEAD'));
		if ('${tree.err}${range.err}'.indexOf('nothing checked') >= 0)
			return NotRun('no token list — set ANYPARSE_SCRUB_LIST (or ANYPARSE_SCRUB_PRIVATE_ROOTS)');
		_summary.detail('tree and $base..HEAD clean'.replace(base, short(base)));
		return tree.ok && range.ok ? Passed : Failed(quote(tree.ok ? range : tree));
	}

	/** The frozen row: every tree recorded by `--frozen` still has the `git diff` it had at the baseline. */
	private function frozenOutcome(baseline: Null<Baseline>): Outcome {
		if (baseline == null) return NotRun(NO_BASELINE);
		if (baseline.frozen.length == 0) return Skipped('none recorded at --baseline');
		final moved: Array<String> = [for (f in baseline.frozen) if (digest(f.dir) != f.digest) f.dir];
		_summary.detail([
			for (f in baseline.frozen) '${Path.withoutDirectory(f.dir)} ${short(f.digest)} unchanged'
		].join(', '));
		return moved.length == 0 ? Passed : Failed('the git diff of ${moved.join(', ')} changed since the baseline');
	}

	/** `hxq lint <scope> --all --format json` on `tree` by this engine, the report written to `out`. */
	private function lintJson(tree: String, scope: Array<String>, out: String): Outcome {
		final lint: Result = hxq(tree, ['lint'].concat(scope).concat(['--all', '--format', 'json']));
		if (!lint.out.trim().startsWith('[')) return NotRun('lint of $tree printed no report: ${quote(lint)}');
		File.saveContent(out, lint.out);
		return Passed;
	}

	/** `hxq lint-diff` of two snapshots, its report kept as `name` in the logs. */
	private function lintDiff(old: String, now: String, name: String): LintMove {
		final diff: Result = hxq(_tree, ['lint-diff', '--old', old, '--new', now]);
		File.saveContent(log(name), diff.out + diff.err);
		final head: EReg = ~/(\d+) added \/ (\d+) removed/;
		if (!head.match(diff.out)) throw new Exception('lint-diff printed no headline: ${quote(diff)}');
		final first: String = diff.lines().find(l -> l.startsWith('  + ')) ?? '';
		return { added: Std.parseInt(head.matched(1)) ?? 0, removed: Std.parseInt(head.matched(2)) ?? 0, first: first.trim() };
	}

	/** The line count of every registry `bin/test.js` lists. */
	private function listCounts(): Map<String, Int> {
		return [
			for (name in LISTINGS) name => inTree(cmd('node bin/test.js --list-$name')).check().lines().length
		];
	}

	/** The files the slice changed against `base`, committed or not, untracked ones included, that still exist. */
	private function touchedFiles(base: String): Array<String> {
		final names: Array<String> = git(['diff', '--name-only', base])
			.split('\n')
			.concat(git(['ls-files', '--others', '--exclude-standard']).split('\n'));
		final seen: Array<String> = [];
		for (name in names) if (name != '' && !seen.contains(name) && FileSystem.exists(Path.join([_tree, name]))) seen.push(name);
		return seen;
	}

	/** `git <args>` in the tree, its standard output; a failure throws. */
	private function git(args: Array<String>): String {
		return cmd('git -C $_tree $args').text();
	}

	/** `command` run in the worktree on its engine. */
	private function inTree(command: Command): Result {
		return command.at(_tree).env('HXQ_BIN', apq()).run();
	}

	/** `hxq <args>` run in `tree` on the worktree's engine, whatever tree it reads. */
	private function hxq(tree: String, args: Array<String>): Result {
		final shim: String = Path.join([_tree, 'bin/hxq']);
		return cmd('sh $shim $args').at(tree).env('HXQ_BIN', apq()).run();
	}

	/** `body` over a detached checkout of `base`, removed afterwards; a step that throws is `NotRun`. */
	private function withBaseCheckout(base: String, body: String -> Outcome): Outcome {
		final scratch: TempDir = TempDir.create();
		final checkout: String = scratch.file('base');
		final outcome: Outcome = try {
			cmd('git -C $_tree worktree add --detach $checkout $base').check();
			body(checkout);
		} catch (exception: Exception) NotRun(clip(exception.message));
		cmd('git -C $_tree worktree remove --force $checkout').run();
		scratch.dispose();
		return outcome;
	}

	/**
	 * The arms every pin of a touched test class names (`--list-pins`: `Class#method :: role :: ARM,ARM`): a fixture
	 * weakened in a touched test file must meet its killer even when the arm's own type is untouched.
	 */
	private function pinnedKillers(modules: Array<String>): Array<String> {
		final killers: Array<String> = [];
		for (line in inTree(cmd('node bin/test.js --list-pins')).check().lines()) {
			final fields: Array<String> = line.split(' :: ');
			if (fields.length < 3 || !modules.contains(fields[0].split('#')[0])) continue;
			for (arm in fields[2].split(',').map(StringTools.trim)) if (arm != '' && !killers.contains(arm)) killers.push(arm);
		}
		return killers;
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
		final tree: String = FileSystem.fullPath(args.positionals(['<worktree>'])[0]);
		if (!FileSystem.exists(Path.join([tree, 'tools/dev.hxml']))) throw new UsageError('$tree is not an anyparse tree');
		if (!baseline && frozen.length + infra.length > 0)
			throw new UsageError('--frozen and --infra-tree are recorded by --baseline; the gate reads them from there');
		final logs: String = logsOption ?? Path.join(['${Path.removeTrailingSlashes(tree)}-logs', 'slice-gate']);
		FileSystem.createDirectory(logs);
		final gate: SliceGate = new SliceGate(tree, logs, allow);
		return baseline ? gate.recordBaseline(frozen.map(FileSystem.fullPath), infra.map(FileSystem.fullPath)) : gate.check(arms, noArms);
	}

	/** Whether the corpus harness runs: the fork it reads is named. */
	private static inline function forkSet(): Bool {
		return (Sys.getEnv('ANYPARSE_HXFORMAT_FORK') ?? '') != '';
	}

	private static inline function short(hash: String): String {
		return hash.trim().substr(0, SHORT_HASH);
	}

	private static inline function signed(n: Int): String {
		return n >= 0 ? '+$n' : '$n';
	}

	/** The SHA-1 of `git diff` in `dir`, as `git -C <dir> diff | shasum` prints it. */
	private static function digest(dir: String): String {
		return Sha1.encode(cmd('git -C $dir diff').text());
	}

	/** Whether `record` is new or re-encoded since `old`. */
	private static function changed(record: ArmRecord, old: Null<RecordFile>): Bool {
		final was: Null<ArmRecord> = old?.records.find(r -> r.key == record.key);
		return was == null || was.text != record.text;
	}

	/** Whether the arm `record` cuts a member of one of `modules` (a module or one of its sub-types). */
	private static function onModule(record: ArmRecord, modules: Array<String>): Bool {
		final field: Null<Any> = Reflect.field(Json.parse(record.text), 'type');
		if (!(field is String)) return false;
		final type: String = Std.string(field);
		return modules.exists(m -> type == m || type.startsWith('$m.'));
	}

	/** The module path of the source file `file` under a module root, or empty for any other file. */
	private static function moduleOf(file: String): String {
		final root: Null<String> = MODULE_ROOTS.find(r -> file.startsWith(r));
		return root == null || !file.endsWith('.hx') ? '' : file.substring(root.length, file.length - '.hx'.length).replace('/', '.');
	}

	/** The first line of `run` that reads like an error, else its first line, clipped for a report row. */
	private static function quote(run: Result): String {
		return clip(run.firstError());
	}

	private static function clip(text: String): String {
		return text.length <= QUOTE_WIDTH ? text : '${text.substr(0, QUOTE_WIDTH - 1)}…';
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

/** What `hxq lint-diff` found moved, and its first added row. */
typedef LintMove = {
	var added: Int;
	var removed: Int;
	var first: String;
}
