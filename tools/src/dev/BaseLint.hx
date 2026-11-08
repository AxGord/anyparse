package dev;

import dev.BaseBranch.BaseGot;
import devkit.Command;
import devkit.Result;
import devkit.Summary.Outcome;
import haxe.Exception;
import haxe.crypto.Sha1;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * The one answer to "what did the base engine find linting the whole base tree, for INFRA gate 4 to compare the new engine
 * with": `lint --all --format json` with the oracle over `GateTree.TREE_SCOPE`, by the engine the base commit builds
 * (`BaseEngine`), in a detached checkout of the base, kept in the gate's logs and in a cache every worktree on this machine
 * shares, under the base and the compiler alone. A gate whose `infra4` row will compare starts it as a branch of its own beside
 * its rows (`plan`, `branch`) and the row waits for it; a `--baseline` run lints no base, and a land warms the next base's
 * entry (`BaselineWarm`), so a rule-code slice pays for it at most once per base.
 */
@:nullSafety(Strict)
final class BaseLint {

	/** The report in the gate's logs; `STAMP` beside it says which base and compiler it stands for. */
	public static inline final FILE: String = 'lint-base.json';

	public static inline final STAMP: String = 'lint-base.stamp';

	/** The announcement of the base lint branch (`BaseBranch.pendingFile`). */
	public static inline final PENDING: String = 'lint-base.pending';

	/** Why the base lint branch left no report. */
	public static inline final UNREAD: String = 'lint-base.unread';

	/** The gate row of the branch; it is no line of the gate's table. */
	public static inline final ROW: String = 'base-lint';

	/** The environment variable that names the cache of reports shared by every worktree instead of the default. */
	public static inline final CACHE_VAR: String = 'SLICE_BASE_LINT_CACHE';

	/** The announce-and-wait protocol of the branch, its markers and its shared cache. */
	private static final BRANCH: BaseBranch = new BaseBranch(ROW, PENDING, UNREAD, CACHE_VAR, 'anyparse-slice-base-lint');

	/** The cache the reports are kept in, one entry per stamp, for every gate on this machine. */
	public static inline function defaultCache(): String {
		return BRANCH.cache();
	}

	/** Whether `gate`'s `infra4` row will compare with the base lint: rule code moved, and the baseline names an infra tree. */
	public static function needed(gate: GateTree): Bool {
		final baseline: Null<Baseline> = gate.baseline;
		return gate.ruleCodeMoved() && baseline != null && baseline.infra.length > 0;
	}

	/**
	 * Whether the gate needs the base lint branch, and when it does the branch is announced: a gate whose `infra4` row will not
	 * compare, or whose base lint is kept (in its logs or in the shared cache), starts none.
	 */
	public static function plan(gate: GateTree): Bool {
		BRANCH.reset(gate);
		if (!needed(gate) || kept(gate, stampOf(gate.base, BaseEngine.toolchain())) != null) return false;
		BRANCH.announce(gate);
		return true;
	}

	/** The branch's row: lint the base unless its report is kept, leave why when it cannot, then lift the announcement. */
	public static function branch(gate: GateTree): Outcome {
		final stamp: String = stampOf(gate.base, BaseEngine.toolchain());
		return BRANCH.settle(gate, () -> kept(gate, stamp) != null ? null : measured(gate, stamp));
	}

	/** The report of the base lint in the gate's logs, waited for while the branch runs; linted here only when no branch was started. */
	public static function read(gate: GateTree): BaseGot<String> {
		final stamp: String = stampOf(gate.base, BaseEngine.toolchain());
		return BRANCH.read(
			gate, kept.bind(gate, stamp), measured.bind(gate, stamp), 'the base lint branch left no report — ${gate.log(FILE)}'
		);
	}

	/** What a report is valid for: the base commit and the compiler, hashed to one line. */
	public static function stampOf(base: String, toolchain: String): String {
		return Sha1.encode(['lint', base.trim(), toolchain].join('\n'));
	}

	/**
	 * The lint of the whole tree `dir` by `engine` with the oracle, its standard error in `errLog`: through the shim of `dir`, so
	 * the base is linted the way its own `hxq` lints it.
	 */
	public static function command(dir: String, engine: String, errLog: String): Command {
		return GateTree.logged(['sh', Path.join([dir, 'bin/hxq'])].concat(GateLint.lintArgs(GateTree.TREE_SCOPE, true)), errLog)
			.at(dir)
			.env(GateTree.ENGINE_VAR, engine);
	}

	/**
	 * Keep the report `run` printed as `report` (its stamp beside it) and as the entry `stamp` of `cache`: null, else why there is
	 * no report.
	 */
	public static function keep(run: Result, stamp: String, report: String, cache: String): Null<String> {
		if (!run.out.trim().startsWith('[')) return GateTree.clip('the base lint printed no report: ${GateTree.quote(run)}');
		File.saveContent(report, run.out);
		File.saveContent(Path.join([Path.directory(report), STAMP]), stamp);
		BaseEngine.keep(cache, stamp, staging -> File.copy(report, Path.join([staging, FILE])));
		return null;
	}

	/**
	 * The entry `stamp` of `cache` copied into `logs` as the report with
	 * its stamp; false when there is none. A hit marks the entry as used.
	 */
	public static function restore(cache: String, stamp: String, logs: String): Bool {
		final entry: String = Path.join([cache, stamp]);
		final kept: String = Path.join([entry, FILE]);
		if (!FileSystem.exists(kept)) return false;
		return try {
			File.copy(kept, Path.join([logs, FILE]));
			File.saveContent(Path.join([logs, STAMP]), stamp);
			BaseEngine.touch(entry);
			true;
		} catch (_: Exception) {
			false;
		};
	}

	/** The report kept for `stamp` in the gate's logs, or else in the shared cache (copied into the logs), or null. */
	private static function kept(gate: GateTree, stamp: String): Null<String> {
		final report: String = gate.log(FILE);
		final mark: String = gate.log(STAMP);
		final own: Bool = FileSystem.exists(report) && FileSystem.exists(mark) && File.getContent(mark) == stamp;
		return own || restore(defaultCache(), stamp, gate.logs) ? report : null;
	}

	/** The base linted by its own engine in a checkout of the base, kept in the gate's logs and in the shared cache: null, else why not. */
	private static function measured(gate: GateTree, stamp: String): Null<String> {
		final report: String = gate.log(FILE);
		final outcome: Outcome = GateTree.withCheckout(gate.tree, gate.base, checkout -> {
			final engine: String = BaseEngine.forCommit(gate.tree, gate.base, BaseEngine.defaultCache());
			final errLog: String = Path.withExtension(report, 'err');
			final why: Null<String> = keep(command(checkout, engine, errLog).run(), stamp, report, defaultCache());
			return why == null ? Passed : Failed('$why — stderr in $errLog');
		});
		return switch outcome {
			case Passed: null;
			case Failed(why), NotRun(why), Skipped(why): why;
		};
	}

}
