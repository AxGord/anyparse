package dev;

import dev.ArmRegistry.ArmRecord;
import dev.GateExcerpt.ArmRow;
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
 * a type it touched, every arm a pin of a touched test class names, every arm on a direct call neighbour of a member it
 * changed, and each `--arm`. An arm whose only claim is a touched file that `hxq changed` classes as layout only runs
 * `--apply-only` instead: its cut must still apply, and no test can see a change of layout. An arm that does not kill its
 * pin is run again at the base, and the row names it `rot on base` when it fails there too. The registry's whole `--all` is
 * a release run, never a slice gate.
 */
@:nullSafety(Strict)
final class GateArms {

	/** What a command of the plan may run before it is killed: a hung call, not a slow one; the plan runs in the gate's own process. */
	private static inline final PLAN_TIMEOUT_MS: Int = 10 * 60 * 1000;

	/** How many arm names an arms row spells before it elides the rest. */
	private static inline final ARMS_SHOWN: Int = 6;

	/** The source roots whose files are modules a mutation arm can name. */
	private static final MODULE_ROOTS: Array<String> = ['src/', 'tools/src/', 'test/'];

	/** The scope and the format of every `hxq graph` call of the row: the sources an arm can cut, as json. */
	private static final GRAPH_SCOPE: Array<String> = ['src', 'tools/src', '--format', 'json'];

	/**
	 * What the arms row of `gate` has to do: the outcome it settles without a run (`--no-arms`, a bad name, no arm selected), or
	 * the selection to run. It spends no kill run, so a caller can ask before it takes a lease for the run.
	 */
	public static function plan(gate: GateTree): ArmPlan {
		if (gate.options.noArms) return Settled(Skipped('--no-arms'));
		final now: Array<ArmRecord> = ArmRegistry.read(Path.join([gate.tree, ArmRegistry.DIRECTORY]));
		final old: Null<Array<ArmRecord>> = baseRecords(gate);
		final layout: Array<String> = [for (file in layoutOf(changedReport(gate))) moduleOf(file)].filter(m -> m != '');
		final modules: Array<String> = [for (file in gate.touched) moduleOf(file)].filter(m -> m != '' && !layout.contains(m));
		final near: Array<String> = callNeighbours(gate, layout);
		final picked: ArmSelection = select(now, old, modules, layout, pinnedKillers(gate, modules), gate.options.arms, near);
		for (name in gate.options.arms) if (!picked.fast.contains(name))
			return Settled(Failed('--arm $name names no arm in ${ArmRegistry.DIRECTORY}'));
		for (name in gate.options.allowArms) if (!now.exists(r -> r.key == name))
			return Settled(Failed('--allow-arm $name names no arm in ${ArmRegistry.DIRECTORY}'));
		return picked.fast.length + picked.applyOnly.length == 0 ? Settled(Skipped('no arm selected')) : Runs(picked, old);
	}

	/** The arms row of `gate`, the heavy rows' threads as the arms' jobs. */
	public static function outcome(gate: GateTree): Outcome {
		return switch plan(gate) {
			case Settled(outcome): outcome;
			case Runs(picked, old): run(gate, picked, old);
		}
	}

	/**
	 * The arms to run for the records `now` (`old` is the base's): `fast` get the kill run — every arm added or re-encoded,
	 * on a `modules` file whose behaviour may have moved, pinned by a touched test (`killers`), asked for (`extra`), or cutting
	 * a member in `near`, a direct call neighbour of a member the slice changed: such a change can make the arm's own pin stop
	 * telling the cut from the original while no file of the arm's or its pin's is touched.
	 * `applyOnly` are the other arms on a `layout` file, whose cut only has to still apply: the writer emits the same text
	 * for both versions of that file, so no test can see it.
	 */
	public static function select(
		now: Array<ArmRecord>, old: Null<Array<ArmRecord>>, modules: Array<String>, layout: Array<String>, killers: Array<String>,
		extra: Array<String>, near: Array<String>
	): ArmSelection {
		final fast: Array<String> = [];
		final applyOnly: Array<String> = [];
		for (record in now) {
			if (
				changed(record, old)
				|| onModule(record, modules)
				|| killers.contains(record.key)
				|| extra.contains(record.key)
				|| cutsMember(record, near)
			)
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

	/** The lines naming a failed row's arms: those rotten at the base first, then the slice's own, then a base that could not be read. */
	public static function rotLines(reading: RotReading, own: Array<String>): Array<String> {
		final lines: Array<String> = [];
		if (reading.rot.length > 0) lines.push('rot on base: ${reading.rot.join(', ')}');
		if (own.length > 0) lines.push('not killed: ${own.join(', ')}');
		final failure: Null<String> = reading.failure;
		if (failure != null) lines.push('base not read: $failure');
		return lines;
	}

	/** The runs of a `picked` selection, `old` being the registry at the base: the apply check first, then the kill run. */
	private static function run(gate: GateTree, picked: ArmSelection, old: Null<Array<ArmRecord>>): Outcome {
		final read: ArmReading = { notes: [], rows: [] };
		final applied: Outcome = picked.applyOnly.length == 0 ? Passed : applyOutcome(gate, picked.applyOnly, read);
		if (!applied.match(Passed)) return applied;
		if (picked.fast.length > 0) return fastOutcome(gate, picked.fast, old, read);
		gate.summary.detail(passNote(read, gate.options.allowArms));
		return Passed;
	}

	/**
	 * The `hxq changed` report of the touched files of `gate` that are tracked `.hx` files, empty when it has none or the
	 * tool fails: it is read for what is layout only, so an empty report widens the selection and never narrows it.
	 */
	private static function changedReport(gate: GateTree): String {
		final files: Array<String> = gate.touched.filter(f -> f.endsWith('.hx'));
		if (files.length == 0) return '';
		final report: Result = gate.hxq(gate.tree, ['changed', gate.base].concat(files)).timeout(PLAN_TIMEOUT_MS).run();
		return report.ok ? report.out : '';
	}

	/** The `--apply-only` run of `names`, told to `read`: every cut still applies to a scratch copy of the base, or its arm is waived. */
	private static function applyOutcome(gate: GateTree, names: Array<String>, read: ArmReading): Outcome {
		final run: Result = gate.inTree(cmd('node bin/dev.js mutation-arm $names --apply-only'));
		final log: String = run.out + run.err;
		File.saveContent(gate.log('arms-apply.log'), log);
		final tally: EReg = ~/^\d+ arms: \d+ apply, (\d+) did not apply$/m;
		gate.summary.excerpt(GateExcerpt.arms(log));
		if (!tally.match(run.out)) return Failed('no apply verdict line — ${GateTree.quote(run)}');
		read.notes.push('${tally.matched(0)} on layout-only files (${elided(names)})');
		final rows: Array<ArmRow> = GateExcerpt.armRows(log);
		for (row in rows) read.rows.push(row);
		final standing: Array<ArmRow> = rows.filter(row -> !gate.options.allowArms.contains(row.name));
		return run.ok || tally.matched(1) != '0' && standing.length == 0
			? Passed
			: Failed(GateTree.clip('${tally.matched(0)} — ${gate.log('arms-apply.log')}'));
	}

	/**
	 * The `--fast` kill run of `names`, the heavy rows' threads as its jobs, the last run of the row: it tells `read`, whose
	 * rows and notes the row's reading covers. A row `--allow-arm` names does not fail it, and only a waived row excuses the
	 * process's non-zero exit; an arm still standing that does not kill its pin is run again at the base (`rotOnBase`), so the
	 * row says whose it is.
	 */
	private static function fastOutcome(gate: GateTree, names: Array<String>, old: Null<Array<ArmRecord>>, read: ArmReading): Outcome {
		final run: Result = gate.inTree(cmd('node bin/dev.js mutation-arm $names --fast ${jobsOf(gate)}'));
		final log: String = run.out + run.err;
		File.saveContent(gate.log('arms.log'), log);
		final tally: EReg = ~/^(\d+) tracks: (\d+) killed, .*$/m;
		final waived: Array<String> = gate.options.allowArms;
		final excerpt: Array<String> = GateExcerpt.arms(log);
		gate.summary.excerpt(excerpt);
		if (!tally.match(run.out)) return Failed('no verdict line — ${GateTree.quote(run)}');
		final rows: Array<ArmRow> = GateExcerpt.armRows(log);
		final standing: Array<ArmRow> = rows.filter(row -> !waived.contains(row.name));
		read.notes.push('${tally.matched(0)} (${elided(names)})');
		for (row in rows) read.rows.push(row);
		gate.summary.detail(passNote(read, waived));
		final killed: Int = Std.parseInt(tally.matched(2)) ?? 0;
		final accounted: Bool = '${killed + rows.length - standing.length}' == tally.matched(1);
		if (accounted && (run.ok || standing.length < rows.length)) return Passed;
		final atBase: Array<String> = standing.filter(row ->
			GateExcerpt.UNKILLED.contains(row.verdict) && old?.exists(r -> r.key == row.name) == true
		)
			.map(row -> row.name);
		final rot: RotReading = atBase.length == 0 ? { rot: [], failure: null } : rotOnBase(gate, atBase);
		final own: Array<String> = standing.map(row -> row.name).filter(name -> !rot.rot.contains(name));
		final named: Array<String> = rotLines(rot, own);
		final said: Array<String> = named.length == 0 ? ['no row explains the run (exit ${run.status})'] : named;
		gate.summary.excerpt(said.concat(excerpt));
		return Failed(GateTree.clip('${said.join('; ')} — ${tally.matched(0)} — ${gate.log('arms.log')}'));
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
		for (line in gate.inTree(cmd('node bin/test.js --list-pins').timeout(PLAN_TIMEOUT_MS)).check().lines()) {
			final fields: Array<String> = line.split(' :: ');
			if (fields.length < 3 || !modules.contains(fields[0].split('#')[0])) continue;
			for (arm in fields[2].split(',').map(StringTools.trim)) if (arm != '' && !killers.contains(arm)) killers.push(arm);
		}
		return killers;
	}

	/** Whether `record` is new or re-encoded since `old`. */
	private static function changed(record: ArmRecord, old: Null<Array<ArmRecord>>): Bool {
		final was: Null<ArmRecord> = old?.find(r -> r.key == record.key);
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

	/**
	 * The records of the registry at the base: its documents, or the single document an older base kept it in; null when
	 * the base has neither.
	 */
	private static function baseRecords(gate: GateTree): Null<Array<ArmRecord>> {
		final listed: Result = cmd('git -C ${gate.tree} ls-tree -r --name-only ${gate.base} ${ArmRegistry.DIRECTORY}').run();
		final documents: Array<String> = listed.ok ? listed.lines().filter(path -> path.endsWith('.json')) : [];
		final texts: Array<String> = [];
		final paths: Array<String> = documents.length > 0 ? documents : [ArmRegistry.LEGACY_FILE];
		for (path in paths) {
			final shown: Result = cmd('git -C ${gate.tree} show ${gate.base}:$path').run();
			if (!shown.ok) return null;
			texts.push(shown.out);
		}
		return ArmRegistry.parseAll(texts);
	}

	/** The `--jobs` of a kill run: the heavy rows' threads, when the gate leased any. */
	private static function jobsOf(gate: GateTree): Array<String> {
		final threads: Null<Int> = gate.options.threads;
		return threads == null ? [] : ['--jobs', '$threads'];
	}

	/** What an arms row shows: the tally of each run of `read`, the rows waived over all of them, the waivers with nothing to waive. */
	private static function passNote(read: ArmReading, waivers: Array<String>): String {
		final note: String = read.notes.join('; ');
		final waived: Array<String> = waivers.filter(name -> read.rows.exists(row -> row.name == name));
		final unused: Array<String> = waivers.filter(name -> !waived.contains(name));
		final withWaived: String = waived.length == 0 ? note : '$note; waived: ${waived.join(', ')}';
		return unused.length == 0 ? withWaived : '$withWaived; --allow-arm waives nothing: ${unused.join(', ')}';
	}

	/**
	 * Which of `names` do not kill their pin at the slice's base either: the rot is the base's and no edit of the slice can
	 * answer it. A base it cannot build or run is a `failure`, and then no arm is called rotten. A wall-clock pin can read
	 * differently on the two runs, since load decides it (`docs/testing.md` § "Declared arms").
	 */
	private static function rotOnBase(gate: GateTree, names: Array<String>): RotReading {
		final dev: String = Path.join([gate.tree, 'bin/dev.js']);
		var rot: Array<String> = [];
		final read: Outcome = gate.withBaseCheckout(checkout -> {
			final built: Result = cmd('node $dev worker-build $checkout/bin --repo $checkout').at(gate.tree).run();
			if (!built.ok) return NotRun('worker-build — ${GateTree.quote(built)}');
			final run: Result = cmd('node $dev mutation-arm $names --fast ${jobsOf(gate)} --repo $checkout')
				.at(checkout)
				.env('HXQ_BIN', '$checkout/bin/apq.js')
				.run();
			final log: String = run.out + run.err;
			File.saveContent(gate.log('arms-base.log'), log);
			if (!~/^\d+ tracks: \d+ killed, /m.match(run.out)) return NotRun('no verdict line — ${GateTree.quote(run)}');
			rot = GateExcerpt.armRows(log).filter(row -> GateExcerpt.UNKILLED.contains(row.verdict)).map(row -> row.name);
			return Passed;
		});
		return switch read {
			case NotRun(why), Failed(why), Skipped(why): { rot: [], failure: why };
			case Passed: { rot: rot, failure: null };
		};
	}

	/**
	 * The members one call edge away, either way, from a member the slice changed in place. `graph --diff` compares by text, so
	 * a member of a `layout` module is no seed; a member added or removed changes a caller too, so it is none either. A graph
	 * that cannot be read throws and the row does not run, because no neighbours would quietly narrow the selection.
	 */
	private static function callNeighbours(gate: GateTree, layout: Array<String>): Array<String> {
		final diff: MemberGraph = Json.parse(
			gate.hxq(gate.tree, ['graph', '--diff', gate.base, 'HEAD'].concat(GRAPH_SCOPE))
				.timeout(PLAN_TIMEOUT_MS)
				.check()
				.out
		);
		final seeds: Array<String> = [
			for (node in diff.nodes) if (
				node.level == 'member' && node.change == 'changed' && !layout.exists(m -> node.name.startsWith('$m.'))
			)
				node.name
		];
		if (seeds.length == 0) return [];
		final focus: Array<String> = [for (seed in seeds) for (arg in ['--focus', seed]) arg];
		final around: MemberGraph = Json.parse(
			gate.hxq(gate.tree, ['graph', '--level', 'member', '--edges', 'calls', '--radius', '1'].concat(focus).concat(GRAPH_SCOPE))
				.timeout(PLAN_TIMEOUT_MS)
				.check()
				.out
		);
		return [
			for (node in around.nodes) if (node.level == 'member' && !seeds.contains(node.name)) node.name
		];
	}

	/** Whether `record` cuts one of `members` (`<type>.<method>`). */
	private static function cutsMember(record: ArmRecord, members: Array<String>): Bool {
		final parsed: Any = Json.parse(record.text);
		final type: Null<Any> = Reflect.field(parsed, 'type');
		final method: Null<Any> = Reflect.field(parsed, 'method');
		return type is String && method is String && members.contains('$type.$method');
	}

}

/** What the arms row has to do: an outcome already settled, or the `picked` selection to run against the base's registry `old`. */
enum ArmPlan {

	Settled(outcome: Outcome);
	Runs(picked: ArmSelection, old: Null<Array<ArmRecord>>);

}

/** The arms of a slice gate by how they run: the kill run, and the apply check of arms on layout-only files. */
typedef ArmSelection = {
	var fast: Array<String>;
	var applyOnly: Array<String>;
}

/** What the re-run at the base read: the arms that do not kill their pin there, or why it could not read them. */
typedef RotReading = {
	var rot: Array<String>;
	var failure: Null<String>;
}

/** What the runs of an arms row have read so far: each run's tally and the arm rows that did not hold. */
private typedef ArmReading = {
	var notes: Array<String>;
	var rows: Array<ArmRow>;
}

/** The fields of `hxq graph --format json` the arms row reads. */
private typedef MemberGraph = {
	var nodes: Array<{ level: String, name: String, ?change: String }>;
}
