package dev;

import dev.BaseBranch.BaseGot;
import dev.Shard.Tally;
import devkit.Cmd.cmd;
import devkit.Lease.LeaseMode;
import devkit.Result;
import devkit.Summary.Outcome;
import haxe.Exception;
import haxe.crypto.Sha1;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/** What the base commit's whole suite counted and, when a corpus ran, where its sweep snapshot is kept. */
typedef BaseReading = {
	var tests: Int;
	var assertions: Int;
	var sweep: Null<String>;
}

/** A base suite reading, or why there is none. */
enum BaseRead {
	Read(reading: BaseReading);
	Unread(why: String);
}

/**
 * The one answer to "what did the base commit's whole suite read, for a gate that compares with it": the test and
 * assertion counts and the corpus sweep, measured in a detached checkout of the base, kept under the base, the corpus
 * tree's state and the compiler in the gate's logs and in a cache every worktree on this machine shares. A whole-suite gate
 * measures it as a branch of its own beside its suite (`plan`, `branch`), and its rows wait for that branch instead of
 * measuring it behind their own; a `--baseline` run measures none of it, so a gate that never compares with the suite never pays for it.
 */
@:nullSafety(Strict)
final class BaseSuite {

	/** The reading's record in the gate's logs; its sweep snapshot is `GateTree.SWEEP_BASE` beside it. */
	public static inline final FILE: String = 'suite-base.txt';

	/** The announcement of a base branch still to leave its reading: the run's id; lifted when the branch has left it or why not. */
	public static inline final PENDING: String = 'suite-base.pending';

	/** Why the base branch left no reading, when it left none. */
	public static inline final UNREAD: String = 'suite-base.unread';

	/** The gate row that reads the base suite beside the gate's own suite; it is no line of the gate's table. */
	public static inline final ROW: String = 'base';

	/** The environment variable that names the cache of readings shared by every worktree instead of the default. */
	public static inline final CACHE_VAR: String = 'SLICE_BASE_SUITE_CACHE';

	private static inline final SUITE_LOG: String = 'suite-base.log';

	/** The announce-and-wait protocol of the base branch, its markers and its shared cache. */
	private static final BRANCH: BaseBranch = new BaseBranch(ROW, PENDING, UNREAD, CACHE_VAR, 'anyparse-slice-base-suite');

	/**
	 * Whether this run's base branch is still to leave its reading (`plan` started it): a reading is awaited then, never
	 * measured a second time beside it.
	 */
	public static inline function pending(gate: GateTree): Bool {
		return BRANCH.pending(gate);
	}

	/** The cache the readings are kept in, one entry per stamp, for every gate on this machine. */
	public static inline function defaultCache(): String {
		return BRANCH.cache();
	}

	/** The reading for `gate`'s base: the kept one when it still stands for this base, fork and compiler, else a fresh run. */
	public static function read(gate: GateTree, mode: LeaseMode): BaseRead {
		final stamp: String = stampOf(gate.base, GateReuse.forkState(), BaseEngine.toolchain());
		return switch BRANCH.read(
			gate, keptReading.bind(gate, stamp), measured.bind(gate, mode, stamp),
			'the base suite branch left no reading — ${gate.log(SUITE_LOG)}'
		) {
			case Got(reading): Read(reading);
			case NotGot(why): Unread(why);
		};
	}

	/**
	 * Whether a gate that ran the whole suite needs the base branch, and when it does the branch is announced: a gate with no
	 * baseline, an impact gate, or one whose base is already read (in its logs or in the cache shared by every worktree) starts none.
	 */
	public static function plan(gate: GateTree, whole: Bool): Bool {
		BRANCH.reset(gate);
		if (!whole || gate.baseline == null) return false;
		if (keptReading(gate, stampOf(gate.base, GateReuse.forkState(), BaseEngine.toolchain())) != null) return false;
		BRANCH.announce(gate);
		return true;
	}

	/**
	 * The base branch's row: read the base suite (or take the kept reading), leave why when there is none, and only then lift
	 * the announcement, so a gate waiting on it never sees the marker gone before the outcome is written.
	 */
	public static function branch(gate: GateTree, mode: LeaseMode): Outcome {
		final stamp: String = stampOf(gate.base, GateReuse.forkState(), BaseEngine.toolchain());
		return BRANCH.settle(gate, () -> keptReading(gate, stamp) != null ? null : measured(gate, mode, stamp));
	}

	/** What a record is valid for: the base commit, the corpus tree's state and the compiler, hashed to one line. */
	public static function stampOf(base: String, fork: String, toolchain: String): String {
		return Sha1.encode([base.trim(), fork, toolchain].join('\n'));
	}

	/** The record of `reading` made under `stamp`. */
	public static function encode(stamp: String, reading: BaseReading): String {
		return [
			stamp,
			'${reading.tests}',
			'${reading.assertions}',
			reading.sweep == null ? 'no sweep' : 'sweep'
		].join('\n')
			+ '\n';
	}

	/**
	 * The reading `text` records, its sweep at `sweep`; null when it was made under another stamp, is damaged, or names a
	 * sweep that is gone.
	 */
	public static function decode(stamp: String, text: String, sweep: String): Null<BaseReading> {
		final lines: Array<String> = text.split('\n');
		if (lines.length < 4 || lines[0] != stamp) return null;
		final tests: Null<Int> = Std.parseInt(lines[1]);
		final assertions: Null<Int> = Std.parseInt(lines[2]);
		if (tests == null || assertions == null) return null;
		final withSweep: Bool = lines[3] == 'sweep';
		return withSweep && !FileSystem.exists(sweep) ? null : { tests: tests, assertions: assertions, sweep: withSweep ? sweep : null };
	}

	/**
	 * This gate's counts beside the base's, or empty. The base suite is read only for a gate whose own suite is green, ran every
	 * class and has a baseline: an impact gate never runs one. A base that cannot be read is a note, not a failure.
	 */
	public static function deltaNote(gate: GateTree, mode: LeaseMode, sum: Tally, status: Int, only: Null<Array<String>>): String {
		if (status != 0 || only != null || gate.baseline == null) return '';
		return switch read(gate, mode) {
			case Read(base): ' (${GateTree.signed(sum.tests - base.tests)} / ${GateTree.signed(sum.assertions - base.assertions)})';
			case Unread(why): ' (no base counts: $why)';
		};
	}

	/** The builds a base checkout needs before its suite can run: the engine its tests spawn beside the test runner, and the runner. */
	public static function builds(): Array<Array<String>> {
		return [['bin/apq-js.hxml'], ['test-js.hxml']];
	}

	/**
	 * `body` with the engine variable naming `checkout`'s own engine, restored afterwards: the base's tests must run the base's
	 * engine, never the one of the tree under gate.
	 */
	public static function withEngine(checkout: String, body: () -> Int): Int {
		final saved: Null<String> = Sys.getEnv(GateTree.ENGINE_VAR);
		setEngine(Path.join([checkout, 'bin/apq.js']));
		final status: Int = try {
			body();
		} catch (exception: Exception) {
			setEngine(saved);
			throw exception;
		};
		setEngine(saved);
		return status;
	}

	/** Set the engine variable to `engine`, or unset it when null: an empty value is not an absent one to the readers of it. */
	public static function setEngine(engine: Null<String>): Void {
		if (engine == null)
			js.Syntax.code('delete process.env[{0}]', GateTree.ENGINE_VAR);
		else
			Sys.putEnv(GateTree.ENGINE_VAR, engine);
	}

	/**
	 * Copy the entry `stamp` of `cache` (its record and, when it has one, its sweep) into the gate's logs; false when there is
	 * none or it is not whole. A hit marks the entry as used.
	 */
	public static function restore(cache: String, stamp: String, gate: GateTree): Bool {
		final entry: String = Path.join([cache, stamp]);
		final record: String = Path.join([entry, FILE]);
		if (!FileSystem.exists(record)) return false;
		return try {
			final sweep: String = Path.join([entry, GateTree.SWEEP_BASE]);
			if (FileSystem.exists(sweep)) File.copy(sweep, gate.log(GateTree.SWEEP_BASE));
			File.copy(record, gate.log(FILE));
			BaseEngine.touch(entry);
			true;
		} catch (_: Exception) {
			false;
		};
	}

	/**
	 * Keep `reading` of the gate's logs as the entry `stamp` of `cache`, built in a staging directory and moved into place whole
	 * (the record last in it); of two gates storing one stamp the first to move wins.
	 */
	public static function store(cache: String, stamp: String, gate: GateTree, reading: BaseReading): Void {
		BaseEngine.keep(cache, stamp, staging -> {
			if (reading.sweep != null) File.copy(reading.sweep, Path.join([staging, GateTree.SWEEP_BASE]));
			File.copy(gate.log(FILE), Path.join([staging, FILE]));
		});
	}

	/** The reading kept for `stamp` in the gate's logs, or else in the shared cache (copied into the logs), or null. */
	private static function keptReading(gate: GateTree, stamp: String): Null<BaseReading> {
		final record: String = gate.log(FILE);
		final sweep: String = gate.log(GateTree.SWEEP_BASE);
		final own: Null<BaseReading> = FileSystem.exists(record) ? decode(stamp, File.getContent(record), sweep) : null;
		if (own != null) return own;
		return restore(defaultCache(), stamp, gate) ? decode(stamp, File.getContent(record), sweep) : null;
	}

	/** A run of the base suite in a checkout of the base, kept in the gate's logs and in the shared cache: null, else why not. */
	private static function measured(gate: GateTree, mode: LeaseMode, stamp: String): Null<String> {
		final record: String = gate.log(FILE);
		final got: Array<BaseReading> = [];
		final outcome: Outcome = gate.withBaseCheckout(checkout -> switch measure(gate, checkout, mode) {
			case Read(reading):
				got.push(reading);
				Passed;
			case Unread(why):
				Failed(why);
		});
		if (got.length == 0) return switch outcome {
			case Failed(why), NotRun(why): why;
			case _: 'the base suite was not read';
		};
		File.saveContent(record, encode(stamp, got[0]));
		store(defaultCache(), stamp, gate, got[0]);
		return null;
	}

	/** Build the suite of `checkout` and run every class in it. */
	private static function measure(gate: GateTree, checkout: String, mode: LeaseMode): BaseRead {
		switch Binaries.compileBuilds(checkout, gate.log('suite-base-build.log'), builds(), mode) {
			case Failed(why):
				return Unread(GateTree.clip('the base suite did not build: $why'));
			case _:
		}
		GateTree.clearSnapshotIn(checkout);
		final lines: Array<String> = [];
		var totals: Null<Tally> = null;
		final status: Int = withEngine(
			checkout, () -> Shard.run({
				repo: checkout,
				testJs: Path.join([checkout, 'bin/test.js']),
				shards: gate.options.threads ?? Shard.DEFAULT_SHARDS,
				verify: false,
				expect: null,
				planOnly: false,
				keep: false,
				timings: null,
				fixtureCache: Shard.fixtureCacheOfEnv(),
				print: line -> lines.push(line),
				warn: line -> lines.push(line),
				counted: sum -> totals = sum,
				only: null
			})
		);
		File.saveContent(gate.log(SUITE_LOG), lines.join('\n') + '\n');
		final sum: Null<Tally> = totals;
		if (sum == null || sum.tests == 0) return Unread(GateTree.clip('the base suite counted no tests — ${gate.log(SUITE_LOG)}'));
		if (status != 0) {
			final verdict: String = lines.find(l -> l.startsWith('suite-shard: FAILED')) ?? 'dev shard exited $status';
			return Unread(GateTree.clip('the base suite is not green: $verdict'));
		}
		if (!GateTree.forkSet()) return Read({ tests: sum.tests, assertions: sum.assertions, sweep: null });
		final snapshot: String = Path.join([checkout, 'bin/.last-sweep.json']);
		if (!FileSystem.exists(snapshot)) return Unread('the base suite left no corpus snapshot under ${GateTree.FORK_VAR}');
		final sweep: String = gate.log(GateTree.SWEEP_BASE);
		final saved: Result = gate.inTree(cmd('node bin/apq.js sweep --lang haxe --file $snapshot --save $sweep'));
		return saved.ok ? Read({ tests: sum.tests, assertions: sum.assertions, sweep: sweep }) : Unread(GateTree.quote(saved));
	}

}
