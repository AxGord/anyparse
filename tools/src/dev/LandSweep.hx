package dev;

import anyparse.query.ExitCode;
import anyparse.query.LintDiff;
import anyparse.query.format.json.LintFindingJson;
import dev.QueueFile.QueueLine;
import devkit.Cmd.cmd;
import devkit.Result;
import devkit.Summary;
import haxe.Exception;
import haxe.io.Path;

using anyparse.util.Groups;
using Lambda;
using StringTools;

/** What a listing run of a sweep command answered: the files it reports, or why it could not be read. */
enum Listing {
	Listed(files: Array<String>);
	Unlisted(why: String);
}

/**
 * The two runs of a sweep command a landing's `reapply` step makes. `findings` is the command without its write, run by the
 * engine of the tree `engine` over the tree `tree`; `fix` is the command as the line wrote it, in `tree`. `command` is the
 * engine's argument list (`LandSweep.wordsOf`).
 */
typedef ReapplyTools = {
	var findings: (engine: String, tree: String, command: Array<String>) -> Listing;
	var fix: (tree: String, command: Array<String>) -> Outcome;
}

/**
 * The one answer to "how does a landing carry a sweep line's commit over files a parallel landing changed": it never merges
 * them, it runs the sweep again. A line whose text holds a marker row `sweep: <command>` lands with its footprint — the files
 * of its commit the command reports on the commit's own base tree — put back as the candidate's HEAD has them, the command
 * run in the candidate tree, and the result staged; a finding the command leaves fails the step as residue. Files of the
 * commit outside the footprint (the rule itself, its tests) merge as any pick does.
 */
@:nullSafety(Strict)
final class LandSweep {

	/** The trailer the landing commit records the re-applied command under. */
	public static final TRAILER: String = 'Sweep-Applied';

	/** The queue document of a repository, whose lines carry the marker. */
	public static final QUEUE: String = '.claude/batch/queue.yaml';

	/** What opens the marker row of a line's text. */
	public static final MARKER: String = 'sweep:';

	/** The bound of one run of the command: a run past it fails the step instead of holding the landing. */
	private static inline final TIMEOUT_MS: Int = 30 * 60 * 1000;

	private static final ENGINES: Array<String> = ['hxq', 'apq'];
	private static final FIX: String = '--fix';

	/** The option of a lint the engine takes with `--fix` only; it is followed by its value. */
	private static final FIX_ONLY: String = '--review-budget';

	/** The options of a lint that change what its report holds or how it exits. */
	private static final REPORT_SHAPING: Array<String> = ['--fail-on', '--format', '--baseline', '--range', '--changed-since'];

	private static final PLAIN: EReg = ~/^[A-Za-z0-9_.,:=\/@*+-]+$/;

	/** Whether the step failed on findings the command left, the one failure a landing answers with the residue exit. */
	public var residue(default, null): Bool = false;

	private final _repo: String;
	private final _branch: String;
	private final _base: String;
	private final _command: String;
	private final _candidate: LandCandidate;
	private final _tools: ReapplyTools;
	private final _summary: Summary;

	private var _unmerged: Array<String> = [];
	private var _conflict: Null<() -> Outcome> = null;
	private var _applied: Bool = false;

	/**
	 * The step of the landing of `branch` in `repo` whose line names `command`; `base` is the directory the base tree of the
	 * branch's commit is opened in for the footprint.
	 */
	public function new(
		repo: String, branch: String, base: String, command: String, candidate: LandCandidate, tools: ReapplyTools, summary: Summary
	) {
		_repo = repo;
		_branch = branch;
		_base = base;
		_command = command;
		_candidate = candidate;
		_tools = tools;
		_summary = summary;
	}

	/**
	 * The pick left `unmerged` files in conflict: they are put back as HEAD has them and the landing goes on, since a
	 * footprint file is rewritten by the command and never merged. `conflict` is the failure of the pick, which `run` answers
	 * with once a file of `unmerged` turns out to lie outside the footprint.
	 */
	public function defer(unmerged: Array<String>, conflict: () -> Outcome): Outcome {
		_unmerged = unmerged;
		_conflict = conflict;
		final restored: Null<String> = restore(unmerged);
		return restored == null ? Passed : conflict();
	}

	/**
	 * The `reapply` step: footprint, reset, the command, staging, the residue check — then `rebuild`, since the binaries the
	 * landing built read the tree before the footprint was taken back and rewritten.
	 */
	public function run(rebuild: () -> Outcome): Outcome {
		final words: Null<Array<String>> = wordsOf(_command);
		if (words == null) return Failed('the sweep command `$_command` is not a plain `hxq lint … $FIX …`');
		final footprint: Array<String> = switch onBase(words) {
			case Listed(files): files;
			case Unlisted(why): return Failed('no footprint of the sweep command on the base tree of `$_branch`: $why');
		};
		final conflict: Null<() -> Outcome> = _conflict;
		if (conflict != null && _unmerged.exists(path -> !footprint.contains(path))) return conflict();
		if (footprint.length == 0) return Skipped('the sweep command reports no file of the pick on its base tree');
		final restored: Null<String> = restore(footprint);
		if (restored != null) return Failed('could not take the footprint from the candidate\'s HEAD: $restored');
		final before: Array<String> = untracked();
		final fixed: Outcome = _tools.fix(_candidate.tree, words);
		if (!fixed.match(Passed)) return fixed;
		// a file the command made is part of what it wrote: left untracked, the battery would judge a tree the commit lacks
		final created: Array<String> = untracked().filter(path -> !before.contains(path));
		final changed: Array<String> = _candidate.git(['diff', '--name-only']).lines().concat(created);
		if (changed.length > 0) {
			final staging: Result = _candidate.git(['add', '--'].concat(changed));
			if (!staging.ok) return Failed('could not stage what the sweep command wrote: ${staging.firstError()}');
		}
		switch _tools.findings(_candidate.tree, _candidate.tree, words) {
			case Unlisted(why):
				return Failed('the sweep command could not be read after its run: $why');
			case Listed(left) if (left.length > 0):
				residue = true;
				return Failed('${left.length} file(s) still carry findings after the sweep command, first ${left[0]}');
			case Listed(_):
		}
		_applied = true;
		_summary.detail('${footprint.length} footprint file(s) taken from HEAD, ${changed.length} rewritten by `$_command`');
		return rebuild();
	}

	/** The trailer value: the command the step re-applied, or null when it re-applied none. */
	public function trailer(): Null<String> {
		return _applied ? _command : null;
	}

	/**
	 * The footprint: the files of the branch's commit that the command reports on the tree of that commit's parent, read by
	 * the candidate's engine (the branch may be what brings the rule). The base tree is opened and removed here.
	 */
	private function onBase(words: Array<String>): Listing {
		final parent: String = '$_branch^';
		final gone: Result = cmd('git -C $_repo worktree remove --force $_base').run();
		final opened: Result = cmd('git -C $_repo worktree add --force --detach $_base $parent').run();
		if (!opened.ok) return Unlisted('no tree of $parent (${opened.firstError()}${gone.ok ? '' : ', after an earlier one stayed'})');
		final listed: Listing = try _tools.findings(_candidate.tree, _base, words) catch (exception: Exception) Unlisted(exception.message);
		cmd('git -C $_repo worktree remove --force $_base').run();
		final picked: Array<String> = cmd('git -C $_repo diff --name-only $parent $_branch').run().lines();
		return switch listed {
			case Listed(files): Listed(picked.filter(path -> files.contains(path)));
			case Unlisted(_): listed;
		};
	}

	/** `paths` in the candidate's index and files as its HEAD has them (absent when HEAD has none); the first error, or null. */
	private function restore(paths: Array<String>): Null<String> {
		final held: Array<String> = _candidate.git(['ls-tree', '-r', '--name-only', 'HEAD', '--'].concat(paths)).lines();
		final absent: Array<String> = paths.filter(path -> !held.contains(path));
		if (held.length > 0) {
			final taken: Result = _candidate.git(['checkout', 'HEAD', '--'].concat(held));
			if (!taken.ok) return taken.firstError();
		}
		if (absent.length > 0) {
			final removed: Result = _candidate.git(['rm', '-q', '-f', '--ignore-unmatch', '--'].concat(absent));
			if (!removed.ok) return removed.firstError();
		}
		return null;
	}

	/** The files of the candidate tree git neither tracks nor ignores. */
	private function untracked(): Array<String> {
		return _candidate.git(['ls-files', '--others', '--exclude-standard']).lines();
	}

	/** The sweep command of line `id` of the queue document `queue` (`commandIn`), or null when the line has none. */
	public static function commandOf(queue: String, id: String): Null<String> {
		return commandIn(QueueFile.find(queue, id));
	}

	/** The sweep command of a queue line: its `sweep:` key, else the first marker row of its text; null for a line without one. */
	public static function commandIn(line: Null<QueueLine>): Null<String> {
		final keyed: String = (line?.sweep ?? '').trim();
		if (keyed != '') return keyed;
		for (row in (line?.text ?? '').split('\n')) {
			final trimmed: String = row.trim();
			if (!trimmed.startsWith(MARKER)) continue;
			final command: String = trimmed.substr(MARKER.length).trim();
			if (command != '') return command;
		}
		return null;
	}

	/**
	 * The engine's argument list of `command` (`lint …`), or null when it is not one a landing runs: an `hxq`/`apq` lint with
	 * `--fix`, every word plain — the command is never handed to a shell, so a quote or an operator would be an argument. An
	 * option that shapes the report or its exit is refused, the listing reads both; so is a path from outside the tree, whose
	 * report would name files no commit path equals.
	 */
	public static function wordsOf(command: String): Null<Array<String>> {
		final words: Array<String> = ~/\s+/g.split(command.trim());
		final fits: Bool = words.length > 2
			&& ENGINES.contains(words[0])
			&& words[1] == 'lint'
			&& words.contains(FIX)
			&& words.foreach(word -> PLAIN.match(word))
			&& !words.exists(word -> REPORT_SHAPING.exists(option -> word == option || word.startsWith('$option=')))
			&& !words.exists(word -> word.startsWith('/') || word.split('/').contains('..'));
		return fits ? words.slice(1) : null;
	}

	/**
	 * The run that lists what `command` would rewrite without writing: the command less `--fix` and less the option the engine
	 * takes with `--fix` only, as a JSON report.
	 */
	public static function listing(command: Array<String>): Array<String> {
		final out: Array<String> = [];
		var index: Int = 0;
		while (index < command.length) {
			final word: String = command[index++];
			if (word == FIX_ONLY)
				index++;
			else if (word != FIX && !word.startsWith('$FIX_ONLY='))
				out.push(word);
		}
		return out.concat(['--format', 'json']);
	}

	/** The files of the findings in the JSON report `report` of a lint run, each once, as paths from the tree's root. */
	public static function filesOf(report: String): Listing {
		final files: Array<String> = [];
		final records: Array<LintFindingJson> = try
			LintDiff.parseReport(report)
		catch (exception: Exception)
			return Unlisted('its report is not a lint report (${exception.message})');
		for (record in records) files.pushUnique(Path.normalize(record.file));
		return Listed(files);
	}

	/** The sweep of a landing as the candidate's own engine runs it. */
	public static function engine(): ReapplyTools {
		return {
			findings: (engine, tree, command) -> {
				final run: Result = GateTree.shim(engine, tree, listing(command)).timeout(TIMEOUT_MS).run();
				run.ok ? filesOf(run.out) : Unlisted(run.firstError());
			},
			fix: (tree, command) -> {
				final run: Result = GateTree.shim(tree, tree, command).timeout(TIMEOUT_MS).run();
				// findings the run could not fix are told by the listing after it, with the files
				run.ok || run.status == ExitCode.EXIT_RESIDUE ? Passed : Failed('the sweep command did not finish: ${run.firstError()}');
			}
		};
	}

}
