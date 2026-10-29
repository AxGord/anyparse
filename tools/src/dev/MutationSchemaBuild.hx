package dev;

import devkit.Cmd.cmd;
import devkit.Result;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * The composed build of a `dev mutation-arm` run (`--schema-build <dir> <base>`, run in the background): every planned
 * arm's copy composed into one tree by `apq mutation-schema` and compiled ONCE, so such an arm costs a suite run and no
 * build. What may not be composed, and why, is `docs/testing.md` § "Mutation runs: killer-first, batched render,
 * schemata". The answer is `<dir>/state` (`ready` | `failed`) and, when ready, `<dir>/map` (`<arm> <id>` per arm the
 * build stands for); `MutationSlot` waits on it.
 */
@:nullSafety(Strict)
final class MutationSchemaBuild {

	/** Builds tried, each leaving out the arms the last one's errors named, unless `APQ_MUTATION_SCHEMA_ROUNDS` says otherwise. */
	private static inline final ROUNDS: Int = 6;

	/** How many times one round re-checks the embedded modules after leaving culprits out. */
	private static inline final CHECKS: Int = 20;

	/** The probe main the embedded modules are typed in the macro context under. */
	private static inline final PROBE: String = 'class AnyparseSchemaCheck {\n\tstatic function main() {}\n}\n';

	/** The state of a build that could not stand for any arm: every arm is built per arm. */
	private static inline final FAILED: String = 'failed';

	/** The composed build's files: what `apq mutation-schema` placed, and the arms it is asked to compose. */
	private static inline final PLACEMENTS: String = 'placements';

	private static inline final PLAN: String = 'plan';

	/** Compose and build in a worktree of `base`, the answer left in `dir`; always answers 0 (the state file is the answer). */
	public static function run(repo: String, dir: String, base: String): Int {
		final tree: String = Path.join([dir, 'tree']);
		// the answer first: every track waiting on it waits no longer than the build
		File.saveContent(Path.join([dir, 'state']), '${composeAndBuild(repo, dir, tree, base)}\n');
		cmd('git -C $repo worktree remove --force $tree').run();
		return 0;
	}

	/**
	 * The arm ids a failed compile's `log` names, out of the composed build's `placements` (`<id>\tok\t<file>\t<dispatch
	 * line>\t<copy from>\t<copy to>\t<owner>` per composed arm): an error inside an arm's copy, or on its dispatch line,
	 * names that arm; one anywhere else in a composed file names every arm of that file. Sorted.
	 */
	public static function culprits(placements: String, log: String): Array<Int> {
		final placed: Array<Placement> = parsePlacements(placements);
		final out: Array<Int> = [];
		final at: EReg = ~/^([^:]+\.hx):([0-9]+):/;
		for (line in log.split('\n')) if (at.match(line)) {
			var file: String = at.matched(1);
			if (file.startsWith('./')) file = file.substr(2);
			final row: Int = Std.parseInt(at.matched(2)) ?? 0;
			final own: Array<Placement> = placed.filter(p -> p.file == file);
			final hit: Array<Placement> = own.filter(p -> (row >= p.from && row <= p.to) || row == p.dispatch);
			for (p in (hit.length > 0 ? hit : own)) if (!out.contains(p.id)) out.push(p.id);
		}
		out.sort((a, b) -> a - b);
		return out;
	}

	/**
	 * The ids of the plan's arms (`<id>\t<file>\t<kind>:<method>\t…` per row) whose dispatch line, as `apq
	 * mutation-schema` spliced it, occurs verbatim in the compiled `output`: an arm whose source the build EMBEDS as
	 * text, which a child compiler re-compiles under the suite. Compiled code spells the call differently, so only
	 * embedded source carries it. Sorted.
	 */
	public static function embedded(plan: String, output: String): Array<Int> {
		final want: Map<String, Int> = [];
		for (line in plan.split('\n')) {
			final cells: Array<String> = line.split('\t');
			if (cells.length < 3) continue;
			final id: String = cells[0];
			final colon: Int = cells[2].indexOf(':');
			want['(__mutOn($id)) return __mut${id}_${cells[2].substr(colon + 1)}('] = Std.parseInt(id) ?? 0;
		}
		final out: Array<Int> = [];
		final dispatch: EReg = ~/\(__mutOn\([0-9]+\)\) return __mut[0-9]+_[A-Za-z0-9_]+\(/g;
		var from: Int = 0;
		while (dispatch.matchSub(output, from)) {
			final id: Null<Int> = want[dispatch.matched(0)];
			if (id != null && !out.contains(id)) out.push(id);
			final pos: { pos: Int, len: Int } = dispatch.matchedPos();
			from = pos.pos + pos.len;
		}
		out.sort((a, b) -> a - b);
		return out;
	}

	/** The `--macro` argument typing the copies of each composed module holding an embedded arm (`ids`) in the macro context. */
	public static function embeddedMacros(placements: String, ids: Array<Int>): Array<String> {
		final modules: Array<String> = [];
		for (p in parsePlacements(placements)) if (ids.contains(p.id)) {
			final relative: String = p.file.startsWith('src/') ? p.file.substr('src/'.length) : p.file;
			final path: String = relative.endsWith('.hx') ? relative.substr(0, relative.length - '.hx'.length) : relative;
			final module: String = path.split('/').join('.');
			final typed: String = Path.withoutDirectory(path) == p.owner ? module : '$module.${p.owner}';
			if (!modules.contains(typed)) modules.push(typed);
		}
		modules.sort(Reflect.compare);
		return [for (m in modules) for (arg in ['--macro', '$m.__mutOn(0)']) arg];
	}

	/** Compose and build until a build compiles or no culprit is left to drop; answers `ready` or `failed`. */
	private static function composeAndBuild(repo: String, dir: String, tree: String, base: String): String {
		final added: Result = cmd('git -C $repo worktree add --detach --quiet $tree $base').run();
		if (!added.ok) {
			File.saveContent(Path.join([dir, 'why']), added.err + added.failure);
			return FAILED;
		}
		final rounds: Int = Std.parseInt(Sys.getEnv('APQ_MUTATION_SCHEMA_ROUNDS') ?? '') ?? ROUNDS;
		final macroLog: String = Path.join([dir, 'macro-log']);
		var round: Int = 0;
		while (round < rounds) {
			round++;
			if (!compose(repo, dir, tree)) return FAILED;
			if (FileSystem.exists(macroLog)) FileSystem.deleteFile(macroLog);
			final build: Result = cmd('haxe test-js-common.hxml -js ${Path.join([dir, 'test.js'])}')
				.at(tree)
				.env('APQ_MUTANT_MACRO_LOG', macroLog)
				.run();
			File.saveContent(Path.join([dir, 'build-$round.log']), build.out + build.err + build.failure);
			if (!build.ok) {
				final named: Array<Int> = culprits(read(dir, PLACEMENTS), build.out + build.err);
				if (named.length == 0) return FAILED;
				drop(dir, named);
				continue;
			}
			final embeddedIds: Array<Int> = embedded(read(dir, PLAN), File.getContent(Path.join([dir, 'test.js'])));
			save(dir, 'embedded', embeddedIds);
			// a copy the build embeds as text is typed by no part of it, and one that does not compile there would break
			// every child compile of every arm: the build is redone once the embedded modules type
			if (embeddedIds.length > 0 && !checkEmbedded(dir, tree, round, embeddedIds)) {
				clearEmbedded(repo, dir, tree, round, embeddedIds);
				continue;
			}
			writeMap(dir, macroLog);
			return 'ready';
		}
		return FAILED;
	}

	/** The tree reset and the plan composed into it (`apq mutation-schema`, its stdout the placements); false on a failure. */
	private static function compose(repo: String, dir: String, tree: String): Bool {
		final reset: Result = cmd('git -C $tree checkout -q -- .').run();
		if (!reset.ok) {
			append(dir, 'why', reset.err);
			return false;
		}
		final composed: Result = cmd('sh ${Path.join([repo, 'bin/hxq'])} mutation-schema ${Path.join([dir, PLAN])}').at(tree).run();
		File.saveContent(Path.join([dir, PLACEMENTS]), composed.out);
		append(dir, 'why', composed.err + composed.failure);
		return composed.ok;
	}

	/** Leave the arms `ids` out of the next round's plan. */
	private static function drop(dir: String, ids: Array<Int>): Void {
		final kept: Array<String> = [
			for (line in read(dir, PLAN).split('\n')) if (line != '' && !ids.contains(Std.parseInt(line.split('\t')[0]) ?? 0)) '$line\n'
		];
		File.saveContent(Path.join([dir, PLAN]), kept.join(''));
		append(dir, 'culprits', [for (id in ids) '$id\n'].join(''));
	}

	/** Type every module holding one of the embedded arms `ids` in the macro context over the composed tree. */
	private static function checkEmbedded(dir: String, tree: String, round: Int, ids: Array<Int>): Bool {
		final probe: String = Path.join([dir, 'probe']);
		if (!FileSystem.exists(probe)) FileSystem.createDirectory(probe);
		File.saveContent(Path.join([probe, 'AnyparseSchemaCheck.hx']), PROBE);
		final macros: Array<String> = embeddedMacros(read(dir, PLACEMENTS), ids);
		final checked: Result = cmd('haxe -cp src -cp $probe -main AnyparseSchemaCheck --interp --no-output $macros').at(tree).run();
		File.saveContent(Path.join([dir, 'embedded-$round.log']), checked.out + checked.err + checked.failure);
		return checked.ok;
	}

	private static function parsePlacements(text: String): Array<Placement> {
		return [
			for (line in text.split('\n')) {
				final cells: Array<String> = line.split('\t');
				if (cells.length >= 6 && cells[1] == 'ok') {
					id: Std.parseInt(cells[0]) ?? 0,
					file: cells[2],
					dispatch: Std.parseInt(cells[3]) ?? 0,
					from: Std.parseInt(cells[4]) ?? 0,
					to: Std.parseInt(cells[5]) ?? 0,
					owner: cells[6] ?? ''
				};
			}
		];
	}

	private static function read(dir: String, name: String): String {
		final file: String = Path.join([dir, name]);
		return FileSystem.exists(file) ? File.getContent(file) : '';
	}

	private static function save(dir: String, name: String, ids: Array<Int>): Void {
		File.saveContent(Path.join([dir, name]), [for (id in ids) '$id\n'].join(''));
	}

	private static function append(dir: String, name: String, text: String): Void {
		File.saveContent(Path.join([dir, name]), read(dir, name) + text);
	}

	/**
	 * Leave out the embedded arms `ids` whose copies the macro-context check names (all of them when it names none),
	 * recompose, and check again — the check takes seconds and the build minutes — until it passes or `CHECKS` ran out.
	 */
	private static function clearEmbedded(repo: String, dir: String, tree: String, round: Int, ids: Array<Int>): Void {
		var left: Array<Int> = ids;
		for (_ in 0...CHECKS) {
			final named: Array<Int> = culprits(read(dir, PLACEMENTS), read(dir, 'embedded-$round.log'));
			final dropped: Array<Int> = named.length > 0 ? named : left;
			drop(dir, dropped);
			left = left.filter(id -> !dropped.contains(id));
			save(dir, 'embedded', left);
			if (!compose(repo, dir, tree) || left.length == 0 || checkEmbedded(dir, tree, round, left)) return;
		}
	}

	/** The answer of a build that compiled: `<arm> <id>` for every composed arm whose switch no compile-time code reached. */
	private static function writeMap(dir: String, macroLog: String): Void {
		final reached: Array<String> = FileSystem.exists(macroLog)
			? [for (l in File.getContent(macroLog).split('\n')) l.split('\t')[0]]
			: [];
		final names: Map<String, String> = [];
		for (line in read(dir, 'names').split('\n')) {
			final space: Int = line.indexOf(' ');
			if (space > 0) names[line.substr(0, space)] = line.substr(space + 1);
		}
		final map: Array<String> = [
			for (p in parsePlacements(read(dir, PLACEMENTS))) if (!reached.contains('${p.id}')) '${names['${p.id}'] ?? ''} ${p.id}\n'
		];
		File.saveContent(Path.join([dir, 'map']), map.join(''));
	}

}

/** One composed arm of the build: where its copy and its dispatch line went, and the type that holds them. */
typedef Placement = {
	var id: Int;
	var file: String;
	var dispatch: Int;
	var from: Int;
	var to: Int;
	var owner: String;
}
