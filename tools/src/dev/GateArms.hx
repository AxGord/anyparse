package dev;

import dev.MergeArms.ArmRecord;
import dev.MergeArms.RecordFile;
import devkit.Cmd.cmd;
import devkit.Result;
import devkit.Summary;
import haxe.Json;
import haxe.io.Path;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * The arms row of a slice gate: `tools/mutation-arm.sh --fast` over the arms the slice added or re-encoded, every arm on
 * a type it touched, every arm a pin of a touched test class names, and each `--arm`. The registry's whole `--all` is a
 * release run, never a slice gate.
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
		final now: RecordFile = MergeArms.parse(File.getContent(Path.join([gate.tree, ARMS_REGISTRY])));
		final shown: Result = cmd('git -C ${gate.tree} show ${gate.base}:$ARMS_REGISTRY').run();
		final old: Null<RecordFile> = shown.ok ? MergeArms.parse(shown.out) : null;
		final modules: Array<String> = [for (file in gate.touched) moduleOf(file)].filter(m -> m != '');
		final killers: Array<String> = pinnedKillers(gate, modules);
		final extra: Array<String> = gate.options.arms;
		final names: Array<String> = [
			for (record in now.records)
				if (changed(record, old) || onModule(record, modules) || killers.contains(record.key) || extra.contains(record.key))
					record.key
		];
		for (name in extra) if (!names.contains(name)) return Failed('--arm $name names no arm in $ARMS_REGISTRY');
		if (names.length == 0) return Skipped('no arm added, re-encoded or on a touched type');
		final threads: Null<Int> = gate.options.threads;
		final jobs: Array<String> = threads == null ? [] : ['--jobs', '$threads'];
		final run: Result = gate.inTree(cmd('tools/mutation-arm.sh $names --fast $jobs'));
		File.saveContent(gate.log('arms.log'), run.out + run.err);
		final tally: EReg = ~/^(\d+) tracks: (\d+) killed, .*$/m;
		if (!tally.match(run.out)) return Failed('no verdict line — ${GateTree.quote(run)}');
		final list: String = names.slice(0, ARMS_SHOWN).join(', ') + (names.length > ARMS_SHOWN ? ', …' : '');
		gate.summary.detail('${tally.matched(0)} ($list)');
		return run.ok && tally.matched(1) == tally.matched(2)
			? Passed
			: Failed(GateTree.clip('${tally.matched(0)} — ${gate.log('arms.log')}'));
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
