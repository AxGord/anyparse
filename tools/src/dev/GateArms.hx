package dev;

import dev.ArmRegistry.ArmRecord;
import dev.ArmRegistry.RecordFile;
import devkit.Cmd.cmd;
import devkit.Result;
import devkit.Summary;
import haxe.Json;
import haxe.io.Path;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * The arms row of a slice gate: `dev mutation-arm --fast` over the arms the slice added or re-encoded, every arm on
 * a type it touched, every arm a pin of a touched test class names, and each `--arm`. An arm whose only claim is a touched
 * file that `hxq changed` classes as layout only runs `--apply-only` instead: its cut must still apply, and no test can see
 * a change of layout. The registry's whole `--all` is a release run, never a slice gate.
 */
@:nullSafety(Strict)
final class GateArms {

	/** How many arm names an arms row spells before it elides the rest. */
	private static inline final ARMS_SHOWN: Int = 6;

	/** The registry whose records the arms row selects from. */
	private static inline final ARMS_REGISTRY: String = 'test/testkit/mutation-arms.json';

	/** The source roots whose files are modules a mutation arm can name. */
	private static final MODULE_ROOTS: Array<String> = ['src/', 'tools/src/', 'test/'];

	/** The arms row of `gate`, the heavy rows' threads as the arms' jobs. */
	public static function outcome(gate: GateTree): Outcome {
		if (gate.options.noArms) return Skipped('--no-arms');
		final now: RecordFile = ArmRegistry.parse(File.getContent(Path.join([gate.tree, ARMS_REGISTRY])));
		final shown: Result = cmd('git -C ${gate.tree} show ${gate.base}:$ARMS_REGISTRY').run();
		final old: Null<RecordFile> = shown.ok ? ArmRegistry.parse(shown.out) : null;
		final layout: Array<String> = [for (file in layoutFiles(gate)) moduleOf(file)].filter(m -> m != '');
		final modules: Array<String> = [for (file in gate.touched) moduleOf(file)].filter(m -> m != '' && !layout.contains(m));
		final extra: Array<String> = gate.options.arms;
		final picked: ArmSelection = select(now.records, old, modules, layout, pinnedKillers(gate, modules), extra);
		for (name in extra) if (!picked.fast.contains(name)) return Failed('--arm $name names no arm in $ARMS_REGISTRY');
		if (picked.fast.length + picked.applyOnly.length == 0) return Skipped('no arm added, re-encoded or on a touched type');
		final applied: Outcome = picked.applyOnly.length == 0 ? Passed : applyOutcome(gate, picked.applyOnly);
		return picked.fast.length == 0 || !applied.match(Passed) ? applied : fastOutcome(gate, picked.fast);
	}

	/**
	 * The arms to run for the records `now` (`old` is the base's): `fast` get the kill run — every arm added or re-encoded,
	 * on a `modules` file whose behaviour may have moved, pinned by a touched test (`killers`) or asked for (`extra`).
	 * `applyOnly` are the other arms on a `layout` file, whose cut only has to still apply: the writer emits the same text
	 * for both versions of that file, so no test can see it.
	 */
	public static function select(
		now: Array<ArmRecord>, old: Null<RecordFile>, modules: Array<String>, layout: Array<String>, killers: Array<String>,
		extra: Array<String>
	): ArmSelection {
		final fast: Array<String> = [];
		final applyOnly: Array<String> = [];
		for (record in now) {
			if (changed(record, old) || onModule(record, modules) || killers.contains(record.key) || extra.contains(record.key))
				fast.push(record.key);
			else if (onModule(record, layout))
				applyOnly.push(record.key);
		}
		return { fast: fast, applyOnly: applyOnly };
	}

	/** The paths a `hxq changed` report `text` classes as `layout`, a moved file by the path it has now. */
	public static function layoutOf(text: String): Array<String> {
		final row: EReg = ~/^\S+ (.+?)(?:  <- .+)?  layout$/;
		return [for (line in text.split('\n')) if (row.match(line)) row.matched(1)];
	}

	/** The files `hxq changed` classes as layout only among the touched files of `gate` that are tracked `.hx` files. */
	private static function layoutFiles(gate: GateTree): Array<String> {
		final files: Array<String> = gate.touched.filter(f -> f.endsWith('.hx'));
		if (files.length == 0) return [];
		final report: Result = gate.hxq(gate.tree, ['changed', gate.base].concat(files)).run();
		return report.ok ? layoutOf(report.out) : [];
	}

	/** The `--apply-only` run of `names`: every cut still applies to a scratch copy of the base. */
	private static function applyOutcome(gate: GateTree, names: Array<String>): Outcome {
		final run: Result = gate.inTree(cmd('node bin/dev.js mutation-arm $names --apply-only'));
		File.saveContent(gate.log('arms-apply.log'), run.out + run.err);
		final tally: EReg = ~/^\d+ arms: \d+ apply, (\d+) did not apply$/m;
		if (!tally.match(run.out)) return Failed('no apply verdict line — ${GateTree.quote(run)}');
		gate.summary.detail('${tally.matched(0)} on layout-only files (${elided(names)})');
		return run.ok && tally.matched(1) == '0' ? Passed : Failed(GateTree.clip('${tally.matched(0)} — ${gate.log('arms-apply.log')}'));
	}

	/** The `--fast` kill run of `names`, the heavy rows' threads as its jobs. */
	private static function fastOutcome(gate: GateTree, names: Array<String>): Outcome {
		final threads: Null<Int> = gate.options.threads;
		final jobs: Array<String> = threads == null ? [] : ['--jobs', '$threads'];
		final run: Result = gate.inTree(cmd('node bin/dev.js mutation-arm $names --fast $jobs'));
		File.saveContent(gate.log('arms.log'), run.out + run.err);
		final tally: EReg = ~/^(\d+) tracks: (\d+) killed, .*$/m;
		if (!tally.match(run.out)) return Failed('no verdict line — ${GateTree.quote(run)}');
		gate.summary.detail('${tally.matched(0)} (${elided(names)})');
		return run.ok && tally.matched(1) == tally.matched(2)
			? Passed
			: Failed(GateTree.clip('${tally.matched(0)} — ${gate.log('arms.log')}'));
	}

	/** The first `ARMS_SHOWN` of `names`, then an ellipsis when there are more. */
	private static function elided(names: Array<String>): String {
		return names.slice(0, ARMS_SHOWN).join(', ') + (names.length > ARMS_SHOWN ? ', …' : '');
	}

	/**
	 * The arms every pin of a touched test class names (`--list-pins`: `Class#method :: role :: ARM,ARM`): a fixture
	 * weakened in a touched test file must meet its killer even when the arm's own type is untouched.
	 */
	private static function pinnedKillers(gate: GateTree, modules: Array<String>): Array<String> {
		final killers: Array<String> = [];
		for (line in gate.inTree(cmd('node bin/test.js --list-pins')).check().lines()) {
			final fields: Array<String> = line.split(' :: ');
			if (fields.length < 3 || !modules.contains(fields[0].split('#')[0])) continue;
			for (arm in fields[2].split(',').map(StringTools.trim)) if (arm != '' && !killers.contains(arm)) killers.push(arm);
		}
		return killers;
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

}

/** The arms of a slice gate by how they run: the kill run, and the apply check of arms on layout-only files. */
typedef ArmSelection = {
	var fast: Array<String>;
	var applyOnly: Array<String>;
}
