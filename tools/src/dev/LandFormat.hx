package dev;

import devkit.Cmd.cmd;
import devkit.Result;
import devkit.Summary;
import devkit.Summary.Outcome;
import haxe.Exception;

using Lambda;
using StringTools;

/**
 * The one answer to "after a landing's pick, which merged files are off the writer's canonical form, and is rewriting them
 * layout only?". Two branches that were each canonical can merge into a tree that is not (a policy landed on one side, a file
 * added on the other), so `dev land` applies the writer to the `.hx` files of the pick that the battery's fmt row reads. A
 * rewrite `apq changed` classes as layout only, and that settles in one pass, is staged into the pick for the commit to
 * carry; any other change, or a file the writer still rewrites, fails the step and puts the pick's bytes back.
 */
@:nullSafety(Strict)
final class LandFormat {

	/** The trailer the landing commit names the rewritten files under. */
	public static inline final TRAILER: String = 'Fmt-Applied';

	/** How many rewritten files the trailer names before it counts the rest. */
	private static inline final NAMED: Int = 8;

	private final _repo: String;
	private final _tools: FormatTools;
	private final _summary: Summary;

	private var _formatted: Array<String> = [];

	/** The step over the tree `repo`; its readings go to `summary`. */
	public function new(repo: String, tools: FormatTools, summary: Summary) {
		_repo = repo;
		_tools = tools;

		_summary = summary;
	}

	/**
	 * The `fmt` step over the files the pick staged. A step that does not pass, or throws, puts the staged bytes back in the
	 * tree, so the rollback of the pick finds nothing of the rewrite.
	 */
	public function run(): Outcome {
		final paths: Array<String> = formattable(git(['diff', '--cached', '--name-only', '--diff-filter=ACMR']).lines());
		if (paths.length == 0) return Skipped('no .hx file of ${GateTree.TREE_SCOPE.join(', ')} in the pick');
		final outcome: Outcome = try {
			fold(paths);
		} catch (exception: Exception) {
			restore(paths);
			throw exception;
		};
		if (!outcome.match(Passed)) restore(paths);
		return outcome;
	}

	/** The trailer value naming the files the step folded in, or null when it folded none. */
	public function trailer(): Null<String> {
		if (_formatted.length == 0) return null;
		final rest: Int = _formatted.length - NAMED;
		return '${_formatted.slice(0, NAMED).join(', ')}${rest > 0 ? ', and $rest more' : ''}';
	}

	/** Rewrite `paths`, then stage what changed if every change is layout and settled. */
	private function fold(paths: Array<String>): Outcome {
		final staged: String = git(['write-tree']).out.trim();
		final written: Outcome = _tools.rewrite(_repo, paths);
		if (!written.match(Passed)) return written;
		final changed: Array<String> = git(['diff', '--name-only', '--'].concat(paths)).lines();
		if (changed.length == 0) {
			_summary.detail('already canonical');
			return Passed;
		}
		final classes: Null<String> = _tools.changes(_repo, staged, changed);
		if (classes == null) return Failed('`apq changed` could not classify the rewrite of ${changed.length} file(s)');
		final other: Array<String> = nonLayout(classes, changed);
		if (other.length > 0)
			return Failed('the writer changed more than layout in ${other.length} file(s), first ${other[0]} — the merge needs a hand');
		final settled: Outcome = _tools.settled(_repo, paths);
		if (!settled.match(Passed)) return settled;
		final staging: Result = git(['add', '--'].concat(changed));
		if (!staging.ok) return Failed('could not stage the rewrite: ${staging.firstError()}');
		_formatted = changed;
		_summary.detail('${changed.length} file(s) rewritten as layout, folded into the commit');
		return Passed;
	}

	/** `paths` put back to the bytes the pick staged. */
	private function restore(paths: Array<String>): Void {
		final back: Result = git(['checkout', '--'].concat(paths));
		if (!back.ok) _summary.add('restore', Failed('the rewritten files stay in the tree: ${back.firstError()}'));
	}

	private function git(words: Array<String>): Result {
		return cmd('git -C $_repo $words').run();
	}

	/** The `.hx` files of `staged` the battery's fmt row reads. */
	public static function formattable(staged: Array<String>): Array<String> {
		return staged.filter(path -> path.endsWith('.hx') && GateTree.TREE_SCOPE.exists(dir -> path.startsWith('$dir/')));
	}

	/**
	 * The files of `expected` that the `apq changed` report `output` does not class as layout: another class, or no mention
	 * at all (a file the report could not read counts against the rewrite, never for it).
	 */
	public static function nonLayout(output: String, expected: Array<String>): Array<String> {
		final layout: Array<String> = [];
		final row: EReg = ~/^[A-Z] (.+?)  layout(\s|$)/;
		for (line in output.split('\n')) if (row.match(line)) layout.push(row.matched(1));
		return expected.filter(path -> !layout.contains(path));
	}

	/** The fmt of a landing as the tree's own engine runs it: `apq fmt --write`, `apq changed`, `apq fmt --list --one-pass`. */
	public static function engine(): FormatTools {
		return {
			rewrite: (tree, files) -> {
				final run: Result = GateTree.shim(tree, tree, ['fmt', '--write'].concat(files)).run();
				run.ok ? Passed : Failed('fmt --write: ${run.firstError()}');
			},
			changes: (tree, base, files) -> {
				final run: Result = GateTree.shim(tree, tree, ['changed', base].concat(files)).run();
				run.ok ? run.out : null;
			},
			settled: (tree, files) -> {
				final run: Result = GateTree.shim(tree, tree, ['fmt', '--list', '--one-pass'].concat(files)).run();
				final first: String = run.lines()[0] ?? run.firstError();
				run.ok && run.out == '' ? Passed : Failed('fmt --list --one-pass still reports the tree after a rewrite: $first');
			}
		};
	}

}

/**
 * The three runs of the writer a landing's `fmt` step makes, in the tree it lands in: a rewrite of `files`, the `apq changed`
 * report of those files against the tree object `base` (null when it could not run), and whether the writer leaves `files`
 * alone after one pass.
 */
typedef FormatTools = {
	var rewrite: (tree:String, files:Array<String>) -> Outcome;
	var changes: (tree:String, base:String, files:Array<String>) -> Null<String>;
	var settled: (tree:String, files:Array<String>) -> Outcome;
}
