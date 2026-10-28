package dev;

import dev.SliceGate.Baseline;
import dev.SliceGate.InfraSnapshot;
import devkit.Command;
import devkit.Pool;
import devkit.Result;
import devkit.Summary;
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
 * The lint rows of a slice gate — `lint` (the touched files against the base) and `infra4` (INFRA gate 4) — and of its
 * `--baseline`, every lint of one row at once. A base-side lint is cached in the logs by tree, scope and what the engine
 * is built from, so a later run of the gate on an engine built from the same sources reuses it.
 */
@:nullSafety(Strict)
final class GateLint {

	/** The engine's build flags, which with `src` make it what it is. */
	private static inline final ENGINE_FLAGS: String = 'bin/apq-js-common.hxml';

	/** The report of the lint row's touched files in the tree, and of the same files at the base, in the logs. */
	private static inline final TOUCHED_REPORT: String = 'lint-touched.json';

	private static inline final TOUCHED_BASE_REPORT: String = 'lint-touched-base.json';

	private final _gate: GateTree;

	/** What the engine is built from (`engineSources`), or null when no lint is cached. */
	private final _engine: Null<String>;

	public function new(gate: GateTree) {
		_gate = gate;
		_engine = engineSources(gate);
	}

	/** The lint row of `--baseline`: the base engine's lint of the whole tree, which INFRA gate 4 compares the new engine with. */
	public function baseLint(): Outcome {
		return _gate.options.infra.length == 0
			? Skipped('no --infra-tree, so INFRA gate 4 needs no base lint')
			: saveLint(
				lintCommand(_gate.tree, GateTree.TREE_SCOPE, true, _gate.log('lint-base.json')).run(), _gate.tree,
				_gate.log('lint-base.json')
			);
	}

	/** The infra4 row of `--baseline`: the base engine's lint of every infra tree, all at once. */
	public function infraBaseline(): Outcome {
		final snapshots: Array<InfraSnapshot> = _gate.infraSnapshots();
		if (snapshots.length == 0) return Skipped('no --infra-tree');
		final runs: Array<Result> = Pool.of(snapshots.length).map(snapshots, s -> lintCommand(s.tree, ['.'], false, s.snapshot));
		for (i => snapshot in snapshots) switch saveLint(runs[i], snapshot.tree, snapshot.snapshot) {
			case Passed:
			case other:
				return other;
		}
		return Passed;
	}

	/**
	 * The lint row: the touched `.hx` files linted with the oracle, against the same files linted the same way in a
	 * checkout of the base — one engine, one scope, so the only difference left is the slice's own code. A moved file is
	 * compared with the path it had at the base; the two lints run at once.
	 */
	public function lintOutcome(): Outcome {
		final files: Array<String> = _gate.touched.filter(f -> f.endsWith('.hx'));
		if (files.length == 0) return Skipped('no .hx touched');
		final atBase: Array<String> = _gate.git(['ls-tree', '-r', '--name-only', _gate.base]).split('\n');
		final pathsNow: Map<String, String> = [for (f in files) if (atBase.contains(_gate.baseOf(f))) _gate.baseOf(f) => f];
		final scope: Array<String> = [for (path in pathsNow.keys()) path];
		scope.sort(Reflect.compare);
		final key: Null<String> = cacheKey('base ${_gate.base}', scope);
		final cached: Null<String> = scope.length == 0 ? '[]' : cachedLint(key);
		final linted: Outcome = cached == null
			? _gate.withBaseCheckout(checkout -> lintPair(files, checkout, scope, key, null))
			: lintPair(files, null, scope, key, cached);
		if (!linted.match(Passed)) return linted;
		final old: String = _gate.log(TOUCHED_BASE_REPORT);
		File.saveContent(old, rebased(File.getContent(old), pathsNow));
		final moved: LintMove = lintDiff(old, _gate.log(TOUCHED_REPORT), 'lint-touched.txt');
		final notes: Array<String> = ['${moved.added} new on ${files.length} file(s)'];
		final renamed: Int = [for (base => now in pathsNow) if (base != now) now].length;
		if (renamed > 0) notes.push('$renamed moved');
		if (cached != null && scope.length > 0) notes.push('base lint reused');
		_gate.summary.detail(notes.join(', '));
		return moved.added == 0 ? Passed : Failed(GateTree.clip('${moved.added} new: ${moved.first} — ${_gate.log('lint-touched.txt')}'));
	}

	/**
	 * The INFRA gate 4 row, for a slice that touched rule code: the base tree and every infra tree linted by this engine,
	 * all at once, against the baseline's lint of the same tree by the base engine. A finding that moved fails the row
	 * until it is explained and waived with `--allow infra4`.
	 */
	public function infraOutcome(): Outcome {
		if (!_gate.ruleCodeMoved()) return Skipped('no rule code touched');
		final baseline: Null<Baseline> = _gate.baseline;
		if (baseline == null) return NotRun(GateTree.NO_BASELINE);
		if (baseline.infra.length == 0) return NotRun('rule code moved, but the baseline recorded no --infra-tree');
		final baseKey: Null<String> = cacheKey('base ${_gate.base}', GateTree.TREE_SCOPE);
		return cachedLint(baseKey) == null
			? _gate.withBaseCheckout(checkout -> compareInfra(checkout, baseKey, baseline))
			: compareInfra(null, baseKey, baseline);
	}

	/**
	 * Lint `files` in the tree and, when `checkout` is given, `scope` in it, at once; without a checkout the base report is
	 * `cached`. Both reports land in the logs, a fresh base one also in the cache under `key`.
	 */
	private function lintPair(
		files: Array<String>, checkout: Null<String>, scope: Array<String>, key: Null<String>, cached: Null<String>
	): Outcome {
		final commands: Array<Command> = [lintCommand(_gate.tree, files, true, _gate.log(TOUCHED_REPORT))];
		if (checkout != null) commands.push(lintCommand(checkout, scope, true, _gate.log(TOUCHED_BASE_REPORT)));
		final runs: Array<Result> = Pool.of(commands.length).run(commands);
		final now: Outcome = saveLint(runs[0], _gate.tree, _gate.log(TOUCHED_REPORT));
		if (!now.match(Passed)) return now;
		final old: String = _gate.log(TOUCHED_BASE_REPORT);
		if (checkout == null) {
			File.saveContent(old, cached ?? '[]');
			return Passed;
		}
		final before: Outcome = saveLint(runs[1], checkout, old);
		if (before.match(Passed)) storeLint(key, File.getContent(old));
		return before;
	}

	/** Lint the base `checkout` (unless the cache has it under `baseKey`) and every infra tree, and compare each with its snapshot. */
	private function compareInfra(checkout: Null<String>, baseKey: Null<String>, baseline: Baseline): Outcome {
		final trees: Array<InfraLint> = [
			{
				name: 'base tree',
				tree: checkout ?? _gate.tree,
				scope: GateTree.TREE_SCOPE,
				key: baseKey,
				oracle: true,
				snapshot: baseline.lint
			}
		].concat([
			for (s in baseline.infra)
				{
					name: Path.withoutDirectory(s.tree),
					tree: s.tree,
					scope: ['.'],
					key: cacheKey('tree ${s.tree} ${GateTree.treeState(s.tree)} no-oracle', ['.']),
					oracle: false,
					snapshot: s.snapshot
				}
		]);
		final reports: Array<Null<String>> = [for (t in trees) cachedLint(t.key)];
		final misses: Array<Int> = [for (i => report in reports) if (report == null) i];
		final runs: Array<Result> = misses.length == 0
			? []
			: Pool.of(misses.length)
				.map(misses, i -> lintCommand(trees[i].tree, trees[i].scope, trees[i].oracle, _gate.log('infra-now-$i.json')));
		for (j => i in misses) {
			final now: String = _gate.log('infra-now-$i.json');
			final linted: Outcome = saveLint(runs[j], trees[i].tree, now);
			if (!linted.match(Passed)) return linted;
			final report: String = File.getContent(now);
			reports[i] = report;
			storeLint(trees[i].key, report);
		}
		final moves: Array<String> = [];
		for (i => t in trees) {
			final now: String = _gate.log('infra-now-$i.json');
			File.saveContent(now, reports[i] ?? '[]');
			final moved: LintMove = lintDiff(t.snapshot, now, 'infra-$i.txt');
			if (moved.added + moved.removed > 0) moves.push('${t.name} +${moved.added} -${moved.removed}');
		}
		final reused: Int = trees.length - misses.length;
		_gate.summary.detail('${trees.length} tree(s), nothing moved${reused > 0 ? ', $reused lint(s) reused' : ''}');
		return moves.length == 0 ? Passed : Failed('findings moved: ${moves.join(', ')} — ${_gate.log('infra-<k>.txt')}');
	}

	/** The report of `run`, `lintCommand`'s `lint --format json` of `tree` for `out`, written there; `NotRun` when it printed none. */
	private function saveLint(run: Result, tree: String, out: String): Outcome {
		if (!run.out.trim().startsWith('['))
			return NotRun('lint of $tree printed no report: ${GateTree.quote(run)} — stderr in ${errLogOf(out)}');
		File.saveContent(out, run.out);
		return Passed;
	}

	/**
	 * A `lint` of `scope` in `dir` that will report to `out`, its standard error in the file beside it (`errLogOf`): a lint
	 * whose oracle is unavailable is chatty there, more than a pipe can be trusted to carry. `oracle` is
	 * false for a tree that has no project to build.
	 */
	private function lintCommand(dir: String, scope: Array<String>, oracle: Bool, out: String): Command {
		return _gate.hxqLogged(dir, lintArgs(scope, oracle), errLogOf(out));
	}

	/** `hxq lint-diff` of two snapshots, its report kept as `name` in the logs. */
	private function lintDiff(old: String, now: String, name: String): LintMove {
		final diff: Result = _gate.hxq(_gate.tree, ['lint-diff', '--old', old, '--new', now]).run();
		File.saveContent(_gate.log(name), diff.out + diff.err);
		final head: EReg = ~/(\d+) added \/ (\d+) removed/;
		if (!head.match(diff.out)) throw new Exception('lint-diff printed no headline: ${GateTree.quote(diff)}');
		final first: String = diff.lines().find(l -> l.startsWith('  + ')) ?? '';
		return { added: Std.parseInt(head.matched(1)) ?? 0, removed: Std.parseInt(head.matched(2)) ?? 0, first: first.trim() };
	}

	/** The cache entry of the lint of `scope` in the tree `tree` names by this engine; null when the engine has none. */
	private function cacheKey(tree: String, scope: Array<String>): Null<String> {
		final engine: Null<String> = _engine;
		return engine == null ? null : Sha1.encode([tree, engine].concat(scope).join('\n'));
	}

	/** The report an earlier run of the gate cached under `key`, or null. */
	private function cachedLint(key: Null<String>): Null<String> {
		if (key == null) return null;
		final file: String = _gate.log('lint-cache/$key.json');
		return FileSystem.exists(file) ? File.getContent(file) : null;
	}

	/** Cache `report` under `key` (nothing without a key), staged beside its file so a reader never sees half of it. */
	private function storeLint(key: Null<String>, report: String): Void {
		if (key == null) return;
		final dir: String = _gate.log('lint-cache');
		FileSystem.createDirectory(dir);
		final staged: String = Path.join([dir, '$key.${js.Node.process.pid}.tmp']);
		File.saveContent(staged, report);
		FileSystem.rename(staged, Path.join([dir, '$key.json']));
	}

	/**
	 * The lint report `report` with every record of a file `pathsNow` maps filed under the path it maps to: a moved file's
	 * findings at the base, under the path they are compared at. A report with nothing to rename is answered as it is.
	 */
	public static function rebased(report: String, pathsNow: Map<String, String>): String {
		if ([for (base => now in pathsNow) if (base != now) now].length == 0) return report;
		final records: Array<DynamicAccess<Any>> = Json.parse(report);
		for (record in records) {
			final file: Null<String> = pathsNow[Std.string(record['file'])];
			if (file != null) record['file'] = file;
		}
		return Json.stringify(records, null, '  ');
	}

	/** The arguments of a `lint --all --format json` of `scope`, with the compiler oracle unless `oracle` is false. */
	public static function lintArgs(scope: Array<String>, oracle: Bool): Array<String> {
		return ['lint'].concat(scope).concat(['--all', '--format', 'json']).concat(oracle ? [] : ['--no-oracle']);
	}

	/** The file the standard error of the lint reporting to `out` goes to. */
	private static inline function errLogOf(out: String): String {
		return Path.withExtension(out, 'err');
	}

	/**
	 * What the engine of `gate`'s tree is built from — the committed `src` tree and its build flags — or null while either
	 * has uncommitted changes. The sources, not the binary: two builds of one source differ in their bytes.
	 */
	private static function engineSources(gate: GateTree): Null<String> {
		return gate.git(['status', '--porcelain', '--', 'src', ENGINE_FLAGS]).trim() == ''
			? gate.git(['rev-parse', 'HEAD:src', 'HEAD:$ENGINE_FLAGS'])
				.split('\n')
				.join(' ')
				.trim()
			: null;
	}

}

/**
 * A tree INFRA gate 4 lints: how its row names it, what to lint and whether
 * with the oracle, its cache entry and the snapshot it is compared with.
 */
typedef InfraLint = {
	var name: String;
	var tree: String;
	var scope: Array<String>;
	var key: Null<String>;
	var oracle: Bool;
	var snapshot: String;
}

/** What `hxq lint-diff` found moved, and its first added row. */
typedef LintMove = {
	var added: Int;
	var removed: Int;
	var first: String;
}
