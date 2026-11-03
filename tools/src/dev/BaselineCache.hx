package dev;

import dev.SliceGate.Baseline;
import dev.SliceGate.FrozenTree;
import dev.SliceGate.InfraSnapshot;
import haxe.Exception;
import haxe.Json;
import haxe.crypto.Sha1;
import haxe.io.Path;
import js.node.Fs.Fs;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * The one answer to "which recorded slice-gate baseline of this commit can a new `--baseline` run reuse": a baseline whose
 * every row passed is kept under the commit, the corpus tree's state and each infra tree's state, and a later run on
 * the same key copies it into its logs instead of measuring again. Nothing tree-bound is kept: the frozen trees' digests
 * are read afresh by the run that reuses the entry, and the entry is moved into place whole, so a reader never sees half of one.
 */
@:nullSafety(Strict)
final class BaselineCache {

	/** The environment variable that names the cache directory instead of the default. */
	public static inline final CACHE_VAR: String = 'SLICE_BASELINE_CACHE';

	/** The record's file inside an entry; written last, so an entry that has it is complete. */
	private static inline final RECORD: String = 'baseline.json';

	private static inline final SWEEP: String = 'sweep-base.json';
	private static inline final LINT: String = 'lint-base.json';

	/** The cache the entries are kept in when the caller names none. */
	public static function defaultCache(): String {
		return Sys.getEnv(CACHE_VAR) ?? Path.join([anyparse.core.TempScratch.root(), 'anyparse-slice-baseline']);
	}

	/**
	 * The entry name of a baseline measured on `base`: the corpus the suite read (`fork`, its state or empty when unset), the
	 * state of each infra tree in order, and the compiler, which all move a reading.
	 */
	public static function key(base: String, fork: String, infra: Array<String>, toolchain: String): String {
		return Sha1.encode([base.trim(), fork, toolchain].concat(infra).join('\n'));
	}

	/**
	 * The entry name for a `--baseline` run, or null when the run may neither take nor leave an entry: a tree already edited is
	 * not the commit's, and an `--allow`ed row may have passed only because it was waived. `fork` is the corpus directory the
	 * suite reads, or empty; each tree is read by `GateTree.treeState`.
	 */
	public static function keyOfRun(
		base: String, fork: String, infra: Array<String>, allow: Array<String>, pristine: Bool, toolchain: String
	): Null<String> {
		if (!pristine || allow.length > 0) return null;
		final stateOf: String -> String = dir -> FileSystem.exists(dir) ? '$dir ${GateTree.treeState(dir)}' : '$dir missing';
		return key(base, fork == '' ? '' : stateOf(fork), infra.map(stateOf), toolchain);
	}

	/**
	 * Copy the entry `key` of `cache` into `logs` and answer the record that points at the copies, its frozen digests `frozen`;
	 * null when there is no entry or it is not whole. A hit marks the entry as used.
	 */
	public static function restore(cache: String, key: String, logs: String, frozen: Array<FrozenTree>): Null<Baseline> {
		final entry: String = Path.join([cache, key]);
		final file: String = Path.join([entry, RECORD]);
		if (!FileSystem.exists(file)) return null;
		return try {
			final kept: Baseline = Json.parse(File.getContent(file));
			final infra: Array<InfraSnapshot> = [];
			for (i => s in kept.infra) {
				final snapshot: String = Path.join([logs, 'infra-$i.json']);
				File.copy(Path.join([entry, s.snapshot]), snapshot);
				infra.push({ tree: s.tree, snapshot: snapshot });
			}
			final sweep: Null<String> = kept.sweep == null ? null : Path.join([logs, SWEEP]);
			if (sweep != null) File.copy(Path.join([entry, SWEEP]), sweep);
			final lint: String = Path.join([logs, LINT]);
			if (FileSystem.exists(Path.join([entry, LINT]))) File.copy(Path.join([entry, LINT]), lint);
			final now: Date = Date.now();
			Fs.utimesSync(entry, now, now);
			{
				base: kept.base,
				tests: kept.tests,
				assertions: kept.assertions,
				lists: kept.lists,
				sweep: sweep,
				lint: lint,
				infra: infra,
				frozen: frozen
			};
		} catch (_: Exception) {
			null;
		};
	}

	/**
	 * Keep `record` (whose files are the ones it names) as the entry `key`: its files and the record with their names made
	 * relative to the entry, built in a staging directory and moved into place. Of two runs storing one key the first to move wins.
	 */
	public static function store(cache: String, key: String, record: Baseline): Void {
		final entry: String = Path.join([cache, key]);
		BaseEngine.prune(cache, BaseEngine.maxAgeDays());
		if (FileSystem.exists(entry)) return;
		FileSystem.createDirectory(cache);
		final staging: String = '$entry.${js.Node.process.pid}.tmp';
		BaseEngine.remove(staging);
		FileSystem.createDirectory(staging);
		try {
			final infra: Array<InfraSnapshot> = [];
			for (i => s in record.infra) {
				final name: String = 'infra-$i.json';
				File.copy(s.snapshot, Path.join([staging, name]));
				infra.push({ tree: s.tree, snapshot: name });
			}
			final sweep: Null<String> = record.sweep;
			if (sweep != null) File.copy(sweep, Path.join([staging, SWEEP]));
			if (FileSystem.exists(record.lint)) File.copy(record.lint, Path.join([staging, LINT]));
			final kept: Baseline = {
				base: record.base,
				tests: record.tests,
				assertions: record.assertions,
				lists: record.lists,
				sweep: sweep == null ? null : SWEEP,
				lint: LINT,
				infra: infra,
				frozen: []
			};
			File.saveContent(Path.join([staging, RECORD]), Json.stringify(kept, null, '\t'));
			FileSystem.rename(staging, entry);
		} catch (_: Exception) {
			BaseEngine.remove(staging);
		}
	}

}
