package dev;

import anyparse.core.PoolLease;
import anyparse.query.format.json.CodeGraphJson;
import anyparse.query.format.json.CodeGraphJsonParser;
import dev.ArmRegistry.ArmRecord;
import dev.GateExcerpt.ArmRow;
import devkit.Cmd.cmd;
import devkit.Result;
import devkit.Summary;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * The arms row of a slice gate: `dev mutation-arm --fast` over the arms the slice added or re-encoded, every arm that cuts a
 * member the slice changed (every arm of a touched type whose changed members `hxq changed` cannot name), every arm a pin of a
 * changed test names, every arm on a direct call neighbour of a member it changed, and each
 * `--arm`. An arm whose only claim is a touched file that `hxq changed` classes as layout only runs
 * `--apply-only` instead: its cut must still apply, and no test can see a change of layout. A selection over `KILL_FLOOR`
 * kill-runs only the arms that cut a member the slice changed (or are new, or asked for) and apply-checks the rest, whose
 * claim is a pin or a call neighbour. A re-gate of one tree skips the arms the last gate killed that nothing since has
 * reached (`KILLED_FILE`). An arm that does not kill its
 * pin is run again at the base, and the row names it `rot on base` when it fails there too. The row says how many threads the
 * kill run and the base run held, since a pin of parallel work cannot kill its arm on one. The registry's whole `--all` is
 * a release run, never a slice gate.
 */
@:nullSafety(Strict)
final class GateArms {

	/**
	 * The selection size past which an arm reached only as a pin's killer or as a call neighbour is apply-checked instead of
	 * kill-run: a sweep that edits hundreds of files reaches almost every pin, and the kill run costs a build per arm.
	 */
	public static inline final KILL_FLOOR: Int = 400;

	/** The logs file a kill run leaves: the commit it ran at, then the arms it killed, one per line. */
	public static inline final KILLED_FILE: String = 'arms-killed.txt';

	/** What a command of the plan may run before it is killed: a hung call, not a slow one; the plan runs in the gate's own process. */
	private static inline final PLAN_TIMEOUT_MS: Int = 10 * 60 * 1000;

	/** How many arm names an arms row spells before it elides the rest. */
	private static inline final ARMS_SHOWN: Int = 6;

	/** The source roots whose files are modules a mutation arm can name. */
	private static final MODULE_ROOTS: Array<String> = ['src/', 'tools/src/', 'test/'];

	/** The scope and the format of every `hxq graph` call of the row: the sources an arm can cut, as json. */
	private static final GRAPH_SCOPE: Array<String> = ['src', 'tools/src', '--format', 'json'];

	/** The name prefixes `testkit.TestDiscovery` registers a test method by. */
	private static final TEST_PREFIXES: Array<String> = ['test', 'spec'];

	/**
	 * What the arms row of `gate` has to do: the outcome it settles without a run (`--no-arms`, a bad name, no arm selected), or
	 * the selection to run. It spends no kill run, so a caller can ask before it takes a lease for the run.
	 */
	public static function plan(gate: GateTree, floor: Int = KILL_FLOOR): ArmPlan {
		if (gate.options.noArms) return Settled(Skipped('--no-arms'));
		final now: Array<ArmRecord> = ArmRegistry.read(Path.join([gate.tree, ArmRegistry.DIRECTORY]));
		final old: Null<Array<ArmRecord>> = recordsAt(gate, gate.base);
		final seen: Reading = readingOf(gate, gate.base, gate.touched);
		final pins: Array<String> = pinListing(gate);
		final near: Array<String> = callNeighbours(gate, gate.base, seen.layout, seen.touches);
		final chosen: ArmSelection = select(
			now, old, seen.touches, seen.layout, killersOf(pins, seen.touches), gate.options.arms, near, floor
		);
		final skipped: Array<String> = carriedOver(gate, now, chosen.fast, pins);
		final picked: ArmSelection = {
			fast: chosen.fast.filter(name -> !skipped.contains(name)),
			applyOnly: chosen.applyOnly,
			demoted: chosen.demoted,
			carried: skipped
		};
		for (name in gate.options.arms) if (!picked.fast.contains(name))
			return Settled(Failed('--arm $name names no arm in ${ArmRegistry.DIRECTORY}'));
		for (name in gate.options.allowArms) if (!now.exists(r -> r.key == name))
			return Settled(Failed('--allow-arm $name names no arm in ${ArmRegistry.DIRECTORY}'));
		return picked.fast.length + picked.applyOnly.length > 0
			? Runs(picked, old)
			: Settled(Skipped(skipped.length == 0 ? 'no arm selected' : '${skipped.length} arms killed at the last gate, untouched since'));
	}

	/** The arms row of `gate`, the heavy rows' threads as the arms' jobs. */
	public static function outcome(gate: GateTree, floor: Int = KILL_FLOOR): Outcome {
		return switch plan(gate, floor) {
			case Settled(outcome): outcome;
			case Runs(picked, old): run(gate, picked, old);
		}
	}

	/**
	 * The arms to run for the records `now` (`old` is the base's): `fast` get the kill run — every arm added or re-encoded,
	 * cutting a member of a `touches` module that the slice changed, asked for (`extra`), pinned by a touched test (`killers`), or cutting
	 * a member in `near`, a direct call neighbour of a member the slice changed: such a change can make the arm's own pin stop
	 * telling the cut from the original while no file of the arm's or its pin's is touched.
	 * `applyOnly` are the other arms on a `layout` file, whose cut only has to still apply: the writer emits the same text
	 * for both versions of that file, so no test can see it. A `fast` longer than `floor` (default `KILL_FLOOR`) keeps the kill run
	 * for the first three families only; the last two, `demoted`, join `applyOnly`.
	 */
	public static function select(
		now: Array<ArmRecord>, old: Null<Array<ArmRecord>>, touches: Array<ModuleTouch>, layout: Array<String>, killers: Array<String>,
		extra: Array<String>, near: Array<String>, floor: Int = KILL_FLOOR
	): ArmSelection {
		final fast: Array<String> = [];
		final own: Array<String> = [];
		final applyOnly: Array<String> = [];
		for (record in now) {
			final asked: Bool = changed(record, old) || onTouched(record, touches) || extra.contains(record.key);
			if (asked || killers.contains(record.key) || cutsMember(record, near)) {
				fast.push(record.key);
				if (asked) own.push(record.key);
			} else if (inModules(record, layout)) {
				applyOnly.push(record.key);
			}
		}
		if (fast.length <= floor) return {
			fast: fast,
			applyOnly: applyOnly,
			demoted: [],
			carried: []
		};
		final demoted: Array<String> = fast.filter(name -> !own.contains(name));
		return {
			fast: own,
			applyOnly: applyOnly.concat(demoted),
			demoted: demoted,
			carried: []
		};
	}

	/**
	 * The arms of `fast` the last kill run (`killed`, at the commit `last` is the registry of) already killed and nothing since
	 * has reached: their record is as it was, and `rerun` (the selection the changes since make) does not name them. An
	 * unreadable `last` carries nothing.
	 */
	public static function carriedOf(
		fast: Array<String>, now: Array<ArmRecord>, last: Null<Array<ArmRecord>>, killed: Array<String>, rerun: Array<String>
	): Array<String> {
		return fast.filter(name -> killed.contains(name) && !rerun.contains(name) && now.exists(r -> r.key == name && !changed(r, last)));
	}

	/** The paths a `hxq changed` report `text` classes as `layout`, a moved file by the path it has now. */
	public static function layoutOf(text: String): Array<String> {
		final row: EReg = ~/^\S+ (.+?)(?:  <- .+)?  layout$/;
		return [for (line in text.split('\n')) if (row.match(line)) row.matched(1)];
	}

	/**
	 * The lines naming a failed row's arms: those rotten at the base first, then the slice's own, then a base that could not be
	 * read. `held` is the lease of both kill runs: a rot read on one thread says so, since a pin of parallel work cannot tell its
	 * cut apart there.
	 */
	public static function rotLines(reading: RotReading, own: Array<String>, held: Null<Int>): Array<String> {
		final lines: Array<String> = [];
		final solo: String = held == 1 ? ' (both runs held ${leaseNote(held)})' : '';
		if (reading.rot.length > 0) lines.push('rot on base: ${reading.rot.join(', ')}$solo');
		if (own.length > 0) lines.push('not killed: ${own.join(', ')}');
		final failure: Null<String> = reading.failure;
		if (failure != null) lines.push('base not read: $failure');
		return lines;
	}

	/**
	 * The top of the arms lease for a kill run of `tracks` tracks: a run holds no more slots than it has tracks, and a thread no
	 * slot can use would still keep the pool closed to every waiter behind it for the whole-share window. One track asks for
	 * exactly one thread, with no window.
	 */
	public static function armsAsk(tracks: Int): Int {
		return Std.int(Math.min(SliceGate.ARMS_THREADS, Math.max(1, tracks)));
	}

	/**
	 * The arms the pins of `listing` (`--list-pins` lines) name, for the pins a touch reaches: the pin's own test method changed, or a
	 * member of its class that is no test did (a helper or a fixture every
	 * test of the class reads), or the class's members cannot be named.
	 */
	public static function killersOf(listing: Array<String>, touches: Array<ModuleTouch>): Array<String> {
		final killers: Array<String> = [];
		for (line in listing) {
			final fields: Array<String> = line.split(' :: ');
			final pin: Array<String> = fields[0].split('#');
			if (fields.length < 3 || !touches.exists(t -> t.module == pin[0] && reaches(t, pin[1]))) continue;
			for (arm in fields[2].split(',').map(StringTools.trim)) if (arm != '' && !killers.contains(arm)) killers.push(arm);
		}
		return killers;
	}

	/**
	 * Whether the member `name` (`<type>.<member>`) of a `graph --diff` node changed in code: `graph --diff` compares by text, so a
	 * member whose doc comment alone changed reads as changed there, and the report's member list (`touches`) is what tells it apart.
	 * A member of a module the report does not name, or whose members it cannot name, is taken for changed.
	 */
	public static function codeChanged(name: String, touches: Array<ModuleTouch>): Bool {
		final at: Int = name.lastIndexOf('.');
		final owner: String = name.substring(0, at);
		final own: Array<ModuleTouch> = touches.filter(t -> belongs(owner, t.module));
		return own.length == 0 || own.exists(t -> changes(t, name.substring(at + 1)));
	}

	/** The file the arms branch is watched through: each track a kill run ends is a sign of life. */
	private static inline function progressOf(gate: GateTree): String {
		return gate.branchProgress(SliceGate.ARMS_ROW);
	}

	/** How many threads a kill run held, as the row says it: the lease the tracks' suites read as `WF_THREADS`, not the `--jobs` slots. */
	private static function leaseNote(held: Null<Int>): String {
		return switch (held) {
			case null: 'no lease';
			case 1: '1 thread';
			case _: '$held threads';
		};
	}

	/** The runs of a `picked` selection, `old` being the registry at the base: the apply check first, then the kill run. */
	private static function run(gate: GateTree, picked: ArmSelection, old: Null<Array<ArmRecord>>): Outcome {
		final read: ArmReading = { notes: [], rows: [] };
		final applied: Outcome = picked.applyOnly.length == 0 ? Passed : applyOutcome(gate, picked.applyOnly, read);
		if (!applied.match(Passed)) return applied;
		if (picked.demoted.length > 0)
			read.notes.push(
				'${picked.demoted.length} reached only by a pin or a call neighbour, apply-checked alone: selection over the floor'
			);
		if (picked.carried.length > 0) read.notes.push('${picked.carried.length} not run: killed at the last gate, untouched since');
		if (picked.fast.length > 0) return fastOutcome(gate, picked, old, read);
		gate.summary.detail(passNote(read, gate.options.allowArms));
		return Passed;
	}

	/**
	 * The `hxq changed --diff` report of the touched files of `gate` that are tracked `.hx` files (the diff lines let
	 * `ChangedMembers` tell a header whose comments alone changed), empty when it has none or the
	 * tool fails: it is read for what is layout only, so an empty report widens the selection and never narrows it.
	 */
	private static function changedReport(gate: GateTree, base: String, touched: Array<String>): String {
		final files: Array<String> = touched.filter(f -> f.endsWith('.hx'));
		if (files.length == 0) return '';
		final shown: Array<String> = [for (file in files) for (arg in ['--diff', file]) arg];
		final report: Result = gate.hxq(gate.tree, ['changed', base].concat(shown)).timeout(PLAN_TIMEOUT_MS).run();
		return report.ok ? report.out : '';
	}

	/**
	 * What the files `touched` since `base` changed, read off `changedReport`:
	 * the members of each module, and the modules of layout only.
	 */
	private static function readingOf(gate: GateTree, base: String, touched: Array<String>): Reading {
		final report: String = changedReport(gate, base, touched);
		final layout: Array<String> = layoutOf(report).map(moduleOf).filter(m -> m != '');
		final said: Map<String, Null<Array<String>>> = ChangedMembers.of(report);
		final touches: Array<ModuleTouch> = touched.map(file -> {
			module: moduleOf(file),
			members: said[file]
		}).filter(t -> t.module != '' && !layout.contains(t.module));
		return { touches: touches, layout: layout };
	}

	/** The `--apply-only` run of `names`, told to `read`: every cut still applies to a scratch copy of the base, or its arm is waived. */
	private static function applyOutcome(gate: GateTree, names: Array<String>, read: ArmReading): Outcome {
		final run: Result = gate.inTree(cmd('node bin/dev.js mutation-arm $names --apply-only'));
		final log: String = run.out + run.err;
		File.saveContent(gate.log('arms-apply.log'), log);
		final tally: EReg = ~/^\d+ arms: \d+ apply, (\d+) did not apply$/m;
		gate.summary.excerpt(GateExcerpt.arms(log));
		if (!tally.match(run.out)) return Failed('no apply verdict line — ${GateTree.quote(run)}');
		read.notes.push('${tally.matched(0)} apply-checked (${elided(names)})');
		final rows: Array<ArmRow> = GateExcerpt.armRows(log);
		for (row in rows) read.rows.push(row);
		final standing: Array<ArmRow> = rows.filter(row -> !gate.options.allowArms.contains(row.name));
		return run.ok || (tally.matched(1) != '0' && standing.length == 0)
			? Passed
			: Failed(GateTree.clip('${tally.matched(0)} — ${gate.log('arms-apply.log')}'));
	}

	/**
	 * The `--fast` kill run of `names`, the heavy rows' threads as its jobs, the last run of the row: it tells `read`, whose
	 * rows and notes the row's reading covers. A row `--allow-arm` names does not fail it, and only a waived row excuses the
	 * process's non-zero exit; an arm still standing that does not kill its pin is run again at the base (`rotOnBase`), so the
	 * row says whose it is.
	 */
	private static function fastOutcome(gate: GateTree, picked: ArmSelection, old: Null<Array<ArmRecord>>, read: ArmReading): Outcome {
		final names: Array<String> = picked.fast;
		final run: Result = gate.inTree(
			cmd('node bin/dev.js mutation-arm $names --fast ${jobsOf(gate)}').env(MutationSlot.PROGRESS_VAR, progressOf(gate))
		);
		final log: String = run.out + run.err;
		File.saveContent(gate.log('arms.log'), log);
		final tally: EReg = ~/^(\d+) tracks: (\d+) killed, .*$/m;
		final waived: Array<String> = gate.options.allowArms;
		final excerpt: Array<String> = GateExcerpt.arms(log);
		gate.summary.excerpt(excerpt);
		if (!tally.match(run.out)) return Failed('no verdict line — ${GateTree.quote(run)}');
		final rows: Array<ArmRow> = GateExcerpt.armRows(log);
		remember(gate, picked.carried.concat(GateExcerpt.killedNames(log).filter(name -> names.contains(name))));
		final standing: Array<ArmRow> = rows.filter(row -> !waived.contains(row.name));
		final held: Null<Int> = PoolLease.threads();
		read.notes.push('${tally.matched(0)} (${elided(names)})');
		read.notes.push('kill run held ${leaseNote(held)}');
		for (row in rows) read.rows.push(row);
		gate.summary.detail(passNote(read, waived));
		final killed: Int = Std.parseInt(tally.matched(2)) ?? 0;
		// a row that never became a track is outside the tally's count, and a standing one fails the run whatever the tracks say
		final tracks: Array<ArmRow> = rows.filter(row -> row.verdict != MutationArm.APPLY_FAIL);
		final waivedTracks: Int = tracks.filter(row -> waived.contains(row.name)).length;
		final accounted: Bool = '${killed + waivedTracks}' == tally.matched(1);
		final unrendered: Array<String> = standing.filter(row -> row.verdict == MutationArm.APPLY_FAIL).map(row -> row.name);
		if (accounted && unrendered.length == 0 && (run.ok || standing.length < rows.length)) return Passed;
		final atBase: Array<String> = standing.filter(row ->
			GateExcerpt.UNKILLED.contains(row.verdict) && old?.exists(r -> r.key == row.name) == true
		)
			.map(row -> row.name);
		final rot: RotReading = atBase.length == 0 ? { rot: [], failure: null } : rotOnBase(gate, atBase);
		final own: Array<String> = standing.map(row -> row.name).filter(name -> !rot.rot.contains(name) && !unrendered.contains(name));
		final named: Array<String> = rotLines(rot, own, held);
		if (unrendered.length > 0) named.push('did not render: ${unrendered.join(', ')}');
		final said: Array<String> = named.length == 0 ? ['no row explains the run (exit ${run.status})'] : named;
		final base: String = atBase.length > 0 && rot.failure == null ? ', base run held ${leaseNote(held)}' : '';
		final threads: String = 'kill run held ${leaseNote(held)}$base';
		gate.summary.excerpt(said.concat([threads]).concat(excerpt));
		return Failed(GateTree.clip('${said.join('; ')} — ${tally.matched(0)} — $threads — ${gate.log('arms.log')}'));
	}

	/** The first `ARMS_SHOWN` of `names`, then an ellipsis when there are more. */
	private static function elided(names: Array<String>): String {
		return names.slice(0, ARMS_SHOWN).join(', ') + (names.length > ARMS_SHOWN ? ', …' : '');
	}

	/**
	 * The arms every pin of a touched test class names (`--list-pins`: `Class#method :: role :: ARM,ARM`): a fixture
	 * weakened in a touched test file must meet its killer even when the arm's own type is untouched.
	 */
	private static function pinListing(gate: GateTree): Array<String> {
		return gate.inTree(cmd('node bin/test.js --list-pins').timeout(PLAN_TIMEOUT_MS)).check().lines();
	}

	/** Whether `record` is new or re-encoded since `old`. */
	private static function changed(record: ArmRecord, old: Null<Array<ArmRecord>>): Bool {
		final was: Null<ArmRecord> = old?.find(r -> r.key == record.key);
		return was == null || was.text != record.text;
	}

	/** Whether the arm `record` cuts a member of one of `modules` (a module or one of its sub-types). */
	private static function inModules(record: ArmRecord, modules: Array<String>): Bool {
		final type: Null<String> = ArmHeadParser.parse(record.text).type;
		return type != null && modules.exists(m -> belongs(type, m));
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
	private static function recordsAt(gate: GateTree, rev: String): Null<Array<ArmRecord>> {
		final listed: Result = cmd('git -C ${gate.tree} ls-tree -r --name-only $rev ${ArmRegistry.DIRECTORY}').run();
		final documents: Array<String> = listed.ok ? listed.lines().filter(path -> path.endsWith('.json')) : [];
		final texts: Array<String> = [];
		final paths: Array<String> = documents.length > 0 ? documents : [ArmRegistry.LEGACY_FILE];
		for (path in paths) {
			final shown: Result = cmd('git -C ${gate.tree} show $rev:$path').run();
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
		final read: Outcome = GateTree.withCheckout(gate.tree, gate.base, checkout -> {
			final built: Result = cmd('node $dev worker-build $checkout/bin --repo $checkout').at(gate.tree).run();
			if (!built.ok) return NotRun('worker-build — ${GateTree.quote(built)}');
			final run: Result = cmd('node $dev mutation-arm $names --fast ${jobsOf(gate)} --repo $checkout')
				.at(checkout)
				.env('HXQ_BIN', '$checkout/bin/apq.js')
				.env(MutationSlot.PROGRESS_VAR, progressOf(gate))
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
	 * a member of a `layout` module is no seed, nor is one whose doc comment alone changed (`codeChanged`); a member added or
	 * removed changes a caller too, so it is none either. A seed the calls graph holds no node for (a member with no call edge)
	 * is skipped by `graph --focus` and answers an empty graph, so it has no neighbours; a graph that cannot be read throws and
	 * the row does not run, because no neighbours would quietly narrow the selection.
	 */
	private static function callNeighbours(
		gate: GateTree, base: String, layout: Array<String>, touches: Array<ModuleTouch>
	): Array<String> {
		final diff: CodeGraphJson = CodeGraphJsonParser.parse(
			gate.hxq(gate.tree, ['graph', '--diff', base, 'HEAD'].concat(GRAPH_SCOPE))
				.timeout(PLAN_TIMEOUT_MS)
				.check()
				.out
		);
		final seeds: Array<String> = [
			for (node in diff.nodes)
				if (
					node.level == 'member'
					&& node.change == 'changed'
					&& !layout.exists(m -> node.name.startsWith('$m.'))
					&& codeChanged(node.name, touches)
				)
					node.name
		];
		if (seeds.length == 0) return [];
		final focus: Array<String> = [for (seed in seeds) for (arg in ['--focus', seed]) arg];
		final around: CodeGraphJson = CodeGraphJsonParser.parse(
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
		final head: ArmHead = ArmHeadParser.parse(record.text);
		return head.type != null && head.method != null && members.contains('${head.type}.${head.method}');
	}

	/**
	 * Whether the arm `record` cuts a member the slice changed: the member a `touches` entry names, or any member of a module whose
	 * changed members the report could not name. A module's change that reads no member at all (only its imports) selects nothing.
	 */
	private static function onTouched(record: ArmRecord, touches: Array<ModuleTouch>): Bool {
		final head: ArmHead = ArmHeadParser.parse(record.text);
		final type: Null<String> = head.type;
		return type != null && touches.exists(t -> belongs(type, t.module) && changes(t, head.method));
	}

	/** Whether `type` is the module `module` or a sub-type of it. */
	private static function belongs(type: String, module: String): Bool {
		return type == module || type.startsWith('$module.');
	}

	/**
	 * Whether `touch` changes the member `method`: an arm that names none,
	 * or a module whose members cannot be named, is taken for changed.
	 */
	private static function changes(touch: ModuleTouch, method: Null<String>): Bool {
		final members: Null<Array<String>> = touch.members;
		return members == null || (method == null || members.contains(method));
	}

	/** Whether `touch` reaches the pin whose test method is `test`: that method changed, or a member that is no test did. */
	private static function reaches(touch: ModuleTouch, test: Null<String>): Bool {
		final members: Null<Array<String>> = touch.members;
		return members == null || test == null || members.exists(m -> m == test || !TEST_PREFIXES.exists(p -> m.startsWith(p)));
	}

	/**
	 * The arms of `fast` that the last kill run of the tree killed and no later change reaches: the selection the changes
	 * since that run's commit make (`select` over them) does not name them and their record is as it was. No sidecar, a commit that
	 * is gone, or any tool of the reading failing carries nothing: a memo never narrows a run it cannot prove about.
	 */
	private static function carriedOver(gate: GateTree, now: Array<ArmRecord>, fast: Array<String>, pins: Array<String>): Array<String> {
		final file: String = gate.log(KILLED_FILE);
		if (fast.length == 0 || !FileSystem.exists(file)) return [];
		final lines: Array<String> = File.getContent(file).split('\n').filter(line -> line != '');
		if (lines.length == 0) return [];
		try {
			final last: Null<Array<ArmRecord>> = recordsAt(gate, lines[0]);
			if (last == null) return [];
			final seen: Reading = readingOf(gate, lines[0], GateTree.touchedSince(gate.tree, lines[0]).paths);
			final near: Array<String> = callNeighbours(gate, lines[0], seen.layout, seen.touches);
			final rerun: ArmSelection = select(
				now, last, seen.touches, seen.layout, killersOf(pins, seen.touches), gate.options.arms, near, now.length
			);
			return carriedOf(fast, now, last, lines.slice(1), rerun.fast);
		} catch (_: Exception) {
			return [];
		}
	}

	/**
	 * Records `killed` as what a kill run of the tree at HEAD killed, unless
	 * the tree holds edits HEAD does not (the commit then names no state).
	 */
	private static function remember(gate: GateTree, killed: Array<String>): Void {
		if (gate.git(['status', '--porcelain']).trim() != '') return;
		File.saveContent(gate.log(KILLED_FILE), [gate.git(['rev-parse', 'HEAD']).trim()].concat(killed).join('\n') + '\n');
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

	/** The part of `applyOnly` a selection over the floor moved out of `fast`. */
	var demoted: Array<String>;

	/** The arms the last kill run of the tree killed and nothing since reached: selected, and left out of `fast`. */
	var carried: Array<String>;

}

/**
 * A source module the slice changed and the members of it that it did:
 * null when its report cannot name them, and then every member counts.
 */
typedef ModuleTouch = {
	var module: String;
	var members: Null<Array<String>>;
}

/** What the re-run at the base read: the arms that do not kill their pin there, or why it could not read them. */
typedef RotReading = {
	var rot: Array<String>;
	var failure: Null<String>;
}

/** What the files touched since a commit changed: the members of each module, and the modules whose change is layout only. */
private typedef Reading = {
	var touches: Array<ModuleTouch>;
	var layout: Array<String>;
}

/** What the runs of an arms row have read so far: each run's tally and the arm rows that did not hold. */
private typedef ArmReading = {
	var notes: Array<String>;
	var rows: Array<ArmRow>;
}
