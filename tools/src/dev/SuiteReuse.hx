package dev;

import anyparse.query.ShardPlan;
import dev.GateReuse.GateFacts;
import dev.SuiteImpact.SuiteScope;
import devkit.Cmd.cmd;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * The one answer to "which test classes of a gate's impact suite keep an earlier check's pass instead of running again": a
 * class the record of the last vouching check holds keeps its pass when the change since that record's tree reaches it not
 * (`SuiteImpact` over the paths the two trees differ in), under the same compiler, node and corpus fork. The corpus class
 * keeps its pass only with the snapshot it left, which goes back where the corpus row reads it.
 */
@:nullSafety(Strict)
final class SuiteReuse {

	/** The record of the last check whose suite passed on a clean tree it held, in the gate's logs; no check retires it. */
	public static final FILE: String = 'suite-pass.json';

	/** The corpus snapshot that record's suite left, copied beside it. */
	public static final SWEEP: String = 'suite-pass-sweep.json';

	/** The classes a passing impact suite of the running check vouches for, one per line, until the check ends. */
	public static final CLASSES: String = 'suite-vouched.txt';

	private static final SUITE_ROW: String = 'suite';
	private static final PORCELAIN_ROW: String = 'porcelain';

	/** Whether `split` kept every class it was handed, so nothing is left to run. */
	public static inline function keptEvery(split: SuiteSplit): Bool {
		return split.kept.length > 0 && split.run?.length == 0;
	}

	/**
	 * Split `selected` into the classes that run and those `record` keeps: a class it vouched for that `reached`, the classes
	 * the change since its tree reaches, leaves out. Nothing is kept from a refused record or when `reached` is null, a change
	 * that reaches every class.
	 */
	public static function split(
		record: Null<GateRecord>, facts: GateFacts, selected: Array<String>, reached: Null<Array<String>>
	): SuiteSplit {
		final from: Null<GateRecord> = record == null || refusal(record, facts) != null ? null : record;
		final run: Array<String> = [];
		final kept: Array<String> = [];
		for (name in selected) (from != null && reached != null && keeps(from, reached, name) ? kept : run).push(name);
		return { run: run, kept: kept, from: from == null || kept.length == 0 ? null : from.tree };
	}

	/** Why no class of a check with `facts` keeps the pass `record` holds, or null when its classes may. */
	public static function refusal(record: GateRecord, facts: GateFacts): Null<String> {
		final judged: String = GateTree.short(record.tree);
		return if (!vouches(record, true))
			'the suite of $judged did not pass on a clean tree'
		else if (record.toolchain != facts.toolchain)
			'the suite of $judged built with another compiler'
		else if (record.node != facts.node)
			'the suite of $judged ran under another node'
		else if (record.fork != facts.fork)
			'the corpus fork moved since the suite of $judged'
		else
			null;
	}

	/** Whether the suite of `record` passed, unwaived, on a tree its check `held` from start to end and left clean. */
	public static function vouches(record: GateRecord, held: Bool): Bool {
		return held
			&& record.rows.contains(SUITE_ROW)
			&& record.rows.contains(PORCELAIN_ROW)
			&& !record.allow.contains(SUITE_ROW)
			&& !record.allow.contains(PORCELAIN_ROW);
	}

	/** The paths `tree` as it stands differs in from the tree id `recorded`, untracked ones included, or null when git cannot compare. */
	public static function changedSince(tree: String, recorded: String): Null<Array<String>> {
		return cmd('git -C $tree cat-file -e $recorded^{tree}').run().ok ? SuiteImpact.touchedSince(tree, recorded) : null;
	}

	/** The classes a scope runs when it bounds them, or null when it runs every class (a whole or trimmed suite). */
	public static function reachedIn(scope: SuiteScope): Null<Array<String>> {
		return switch scope {
			case Selected(classes): classes;
			case WholeSuite(_), Trimmed(_, _, _): null;
		};
	}

	/**
	 * The split of the classes `only` a check of `gate` selected; a whole suite (null) keeps none, as its record stands for the
	 * battery's own suite, whose counts it then must hold whole.
	 */
	public static function ofGate(gate: GateTree, only: Null<Array<String>>, scopeOf: Array<String> -> SuiteScope): SuiteSplit {
		return only == null
			? { run: null, kept: [], from: null }
			: plan(gate.tree, gate.options.logs, GateReuse.factsOf(gate.tree, false), only, scopeOf);
	}

	/**
	 * The split of the classes a check of `tree` selected, against the record in `logs`; `scopeOf` answers the scope of a set of
	 * changed paths. A kept corpus class puts its snapshot back into `tree`.
	 */
	public static function plan(
		tree: String, logs: String, facts: GateFacts, selected: Array<String>, scopeOf: Array<String> -> SuiteScope
	): SuiteSplit {
		final read: Null<GateRecord> = GateReuse.read(Path.join([logs, FILE]));
		final record: Null<GateRecord> = read == null || refusal(read, facts) != null ? null : read;
		if (record == null) return split(null, facts, selected, null);
		final sweep: Null<String> = record.sweep;
		if (sweep != null && !FileSystem.exists(sweep)) record.sweep = null;
		final changed: Null<Array<String>> = changedSince(tree, record.tree);
		final planned: SuiteSplit = split(record, facts, selected, changed == null ? null : reachedIn(scopeOf(changed)));
		if (sweep != null && planned.kept.contains(ShardPlan.CORPUS_CLASS)) File.copy(sweep, Path.join([tree, GateTree.SWEEP_SNAPSHOT]));
		return planned;
	}

	/**
	 * Note the classes a passing impact suite of the running check vouches for, read by `keep` at the check's end; a whole suite
	 * (null) notes none.
	 */
	public static function ran(logs: String, selected: Null<Array<String>>): Void {
		if (selected != null) File.saveContent(Path.join([logs, CLASSES]), selected.join('\n') + '\n');
	}

	/** What the suite row's detail adds for `split`: how many classes it kept and from which tree, or nothing. */
	public static function note(split: SuiteSplit): String {
		final from: Null<String> = split.from;
		return from == null ? '' : '; ${split.kept.length} kept from ${GateTree.short(from)}';
	}

	/**
	 * Leave `record`, the check's own, as the one a later check keeps classes from when its suite vouches, with the classes it
	 * vouched for and the corpus snapshot of `tree`; a check that does not vouch leaves the earlier record standing.
	 */
	public static function keep(tree: String, logs: String, record: GateRecord, held: Bool): Void {
		final classes: String = Path.join([logs, CLASSES]);
		if (!vouches(record, held) || (record.impact != null && !FileSystem.exists(classes))) return;
		record.vouched = record.impact == null ? null : File.getContent(classes).split('\n').filter(name -> name != '');
		final snapshot: String = Path.join([tree, GateTree.SWEEP_SNAPSHOT]);
		final copy: String = Path.join([logs, SWEEP]);
		record.sweep = FileSystem.exists(snapshot) ? copy : null;
		if (FileSystem.exists(snapshot)) File.copy(snapshot, copy);
		GateReuse.write(Path.join([logs, FILE]), record);
	}

	/** Whether `record` keeps the pass of `name` when the change since its tree reaches only `reached`. */
	private static function keeps(record: GateRecord, reached: Array<String>, name: String): Bool {
		return !reached.contains(name)
			&& (record.impact == null || (record.vouched ?? []).contains(name))
			&& (name != ShardPlan.CORPUS_CLASS || record.sweep != null);
	}

}

/** A gate suite's selected classes, split by `SuiteReuse`. */
typedef SuiteSplit = {

	/** The classes that run, or null when every class does. */
	var run: Null<Array<String>>;

	/** The classes that keep the pass of the record's tree. */
	var kept: Array<String>;

	/** The tree whose pass the kept classes keep, or null when none is kept. */
	var from: Null<String>;

}
