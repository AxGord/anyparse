package dev;

import anyparse.grammar.json.JsonFormat;
import devkit.Cmd.cmd;
import devkit.Result;
import devkit.Summary.Step;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * The one answer to "which battery rows a slice gate already passed for the exact tree a land is about to verify": the gate
 * leaves a `GateRecord` in its own logs, a land finds it beside the worktree that holds its branch, and the battery takes a
 * row over only when the land's merge has the record's very tree, the record passed and every input the row read is the same.
 */
@:nullSafety(Strict)
final class GateReuse {

	/** The record's file inside the gate's logs. */
	public static inline final FILE: String = 'gate-record.json';

	/** The reading that holds how many classes an impact-selected suite ran; absent when the suite ran every class. */
	public static inline final IMPACT: String = 'impact';

	/** The corpus snapshot the gate's suite left, copied beside the record. */
	public static inline final SWEEP: String = 'gate-sweep.json';

	/** The gate's logs beside its worktree, the only place a record is ever read from. */
	public static inline final LOGS_SUFFIX: String = '-logs/slice-gate';

	/**
	 * Each gate row a battery row may take over, as the pair `[gate row, battery row]`. A row missing here — fmt, typer probes,
	 * oracle, lint, blast — measures more than its gate namesake, so it always runs.
	 */
	private static final COVERS: Array<Array<String>> = [
		['suite', 'suite'],
		['corpus', 'corpus'],
		['jvm', 'jvm probe'],
		['kits', 'kit probes']
	];

	/**
	 * Whether a check's verdict holds for the tree it `started` on: a commit or amend in the worktree while the rows ran leaves the
	 * tree clean, yet no row measured the tree it `ended` on, so the record must not say it passed.
	 */
	public static inline function heldTree(passed: Bool, started: String, ended: String): Bool {
		return passed && started == ended;
	}

	/** The record of the gate of the worktree that holds `branch` in `repo`'s worktree list, or null when there is none. */
	public static function locate(repo: String, branch: String): Null<String> {
		final listing: Result = cmd('git -C $repo worktree list --porcelain').run();
		if (!listing.ok) return null;
		var tree: Null<String> = null;
		for (line in listing.lines()) {
			if (line.startsWith('worktree ')) tree = line.substr('worktree '.length);
			final holder: Null<String> = tree;
			if (holder == null || line != 'branch refs/heads/$branch') continue;
			final file: String = Path.join([logsOf(holder), FILE]);
			return FileSystem.exists(file) ? file : null;
		}
		return null;
	}

	/** The gate's logs of the worktree `tree`, as `dev slice-gate` defaults them. */
	public static function logsOf(tree: String): String {
		return '${Path.removeTrailingSlashes(tree)}$LOGS_SUFFIX';
	}

	/** The record in `file`, or null when it is missing or not a record. */
	public static function read(file: String): Null<GateRecord> {
		if (!FileSystem.exists(file)) return null;
		return try GateRecordParser.parse(File.getContent(file)) catch (_: Exception) null;
	}

	public static function write(file: String, record: GateRecord): Void {
		File.saveContent(file, GateRecordWriter.write(record, JsonFormat.instance.defaultWriteOptions));
	}

	/** The names of the steps that passed; a skipped row measured nothing, so it covers nothing. */
	public static function passedRows(steps: Array<Step>): Array<String> {
		return [for (step in steps) if (step.outcome.match(Passed)) step.name];
	}

	/** The tree id of `rev` in `repo`. */
	public static function treeOf(repo: String, rev: String = 'HEAD'): String {
		return cmd('git -C $repo rev-parse $rev^{tree}').text().trim();
	}

	/** The node the suite and the kits are spawned under, as `node --version` names it. */
	public static function nodeVersion(): String {
		final version: Result = cmd('node --version').check();
		return (version.out + version.err).trim();
	}

	/** The corpus fork's state as both the gate and the battery read it, empty when the fork is unset. */
	public static function forkState(): String {
		final fork: String = Sys.getEnv(GateTree.FORK_VAR) ?? '';
		return if (fork == '')
			''
		else if (FileSystem.exists(fork))
			GateTree.treeState(fork)
		else
			'$fork missing';
	}

	/** What a battery run over `repo` is: its tree, its inputs and its options. */
	public static function factsOf(repo: String, quick: Bool): GateFacts {
		return {
			tree: treeOf(repo),
			toolchain: BaseEngine.toolchain(),
			node: nodeVersion(),
			fork: forkState(),
			quick: quick
		};
	}

	/** Why no row of `record` stands for a battery of `facts`, or null when its rows may. */
	public static function refusal(record: GateRecord, facts: GateFacts): Null<String> {
		final judged: String = GateTree.short(record.tree);
		if (!record.passed) return 'the gate of $judged failed';
		if (record.tree != facts.tree) return 'the gate judged $judged, the land verifies ${GateTree.short(facts.tree)}';
		if (record.toolchain != facts.toolchain) return 'the gate of $judged built with another compiler';
		if (record.node != facts.node) return 'the gate of $judged ran under another node, or recorded none';
		if (record.fork != facts.fork) return 'the corpus fork moved since the gate of $judged';
		return null;
	}

	/**
	 * The battery rows `record` stands for. A row the gate waived is never taken: it passed
	 * only by its waiver, which the land must show and judge itself; the gate's suite
	 * never verifies the shard plan, so a full battery runs its own; a suite the gate ran on the classes its change reaches
	 * is no whole suite, so the land runs its own; the corpus row reads the suite's snapshot, so it is taken over only with
	 * the suite.
	 */
	public static function rows(record: GateRecord, facts: GateFacts): Array<String> {
		if (refusal(record, facts) != null) return [];
		final taken: Array<String> = [];
		for (pair in COVERS) {
			final gateRow: String = pair[0];
			final batteryRow: String = pair[1];
			if (!record.rows.contains(gateRow)) continue;
			if (record.allow.contains(gateRow)) continue;
			if (gateRow == 'suite' && (!facts.quick || record.impact != null)) continue;
			if (gateRow == 'corpus' && (record.sweep == null || !taken.contains('suite'))) continue;
			taken.push(batteryRow);
		}
		return taken;
	}

	/** The line a battery prints about the record it was offered. */
	public static function report(record: Null<GateRecord>, facts: GateFacts, taken: Array<String>): String {
		if (record == null) return 'battery: the gate record could not be read — every row runs';
		final refused: Null<String> = refusal(record, facts);
		if (refused != null) return 'battery: gate record not reused — $refused';
		if (taken.length == 0) return 'battery: the gate record covers no row this battery runs';
		return 'battery: reused gate ${GateTree.short(record.tree)} for ${taken.join(', ')}';
	}

	/** Drops the record and the snapshot an earlier check of `gate` left, so only the record of the check now running can be reused. */
	public static function retire(gate: GateTree): Void {
		for (name in [FILE, SWEEP]) if (FileSystem.exists(gate.log(name))) FileSystem.deleteFile(gate.log(name));
	}

	/**
	 * Leaves the verdict of `gate`'s check over `started`, the tree its
	 * build compiled, in its logs, where a land of that tree finds it.
	 */
	public static function keep(gate: GateTree, readings: Map<String, Int>, started: String): Void {
		final sweep: String = gate.log(SWEEP);
		write(gate.log(FILE), {
			tree: started,
			passed: heldTree(gate.summary.passed(), started, treeOf(gate.tree)),
			toolchain: BaseEngine.toolchain(),
			node: nodeVersion(),
			fork: forkState(),
			allow: gate.options.allow,
			rows: passedRows(gate.summary.steps()),
			tests: readings['tests'] ?? 0,
			assertions: readings['assertions'] ?? 0,
			impact: readings[IMPACT],
			sweep: FileSystem.exists(sweep) ? sweep : null
		});
	}

	/**
	 * The record in `file` and the battery rows it stands for over `repo`, said on `print`; with no file offered, nothing and
	 * no line. The record is kept only when it stands for a row.
	 */
	public static function offer(file: Null<String>, repo: String, quick: Bool, print: String -> Void): GateOffer {
		if (file == null) return { gate: null, rows: [] };
		final gate: Null<GateRecord> = read(file);
		final facts: GateFacts = factsOf(repo, quick);
		final taken: Array<String> = gate == null ? [] : rows(gate, facts);
		print(report(gate, facts, taken));
		return { gate: taken.length == 0 ? null : gate, rows: taken };
	}

}

/** What a battery run is, compared with a `GateRecord`. */
typedef GateFacts = {

	var tree: String;
	var toolchain: String;
	var node: String;
	var fork: String;

	/** Whether the battery's suite skips verifying the shard plan, as the gate's does. */
	var quick: Bool;

}

/** A record a battery was offered and the battery rows it stands for. */
typedef GateOffer = {
	var gate: Null<GateRecord>;
	var rows: Array<String>;
}
