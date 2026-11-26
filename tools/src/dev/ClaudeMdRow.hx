package dev;

import dev.QueueFile.QueueLine;
import devkit.Cmd.cmd;
import devkit.Result;
import devkit.Summary;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * The one answer to "is the root `CLAUDE.md`, which loads into every agent on every turn, within its byte budget, and did a
 * slice that changed it declare that in its queue line's `touches`": the slice gate's `claude-md` row. The budget is a dev
 * constant here, not an `apq.json` key: it prices this file for the agents, not any project's lint.
 */
@:nullSafety(Strict)
final class ClaudeMdRow {

	/** The most bytes the file may hold; a slice may grow it up to this and no further. */
	public static inline final BUDGET: Int = 14000;

	/** The file the row measures, at the root of the tree. */
	public static final FILE: String = 'CLAUDE.md';

	/** Whether the slice moved the file: it is among the paths changed since the base. */
	public static inline function reached(touched: Array<String>): Bool {
		return touched.contains(FILE);
	}

	/**
	 * Whether the queue line of the slice lists the file in its `touches`. The slice's id is the name of its worktree directory;
	 * the queue is the one of the checkout the tree belongs to. Null when that line cannot be read.
	 */
	public static function declared(tree: String): Null<Bool> {
		final queue: String = ReconFacts.queueOf(tree);
		if (!FileSystem.exists(queue)) return null;
		final line: Null<QueueLine> = QueueFile.find(File.getContent(queue), Path.withoutDirectory(Path.removeTrailingSlashes(tree)));
		return line?.touches.contains(FILE);
	}

	/**
	 * The verdict from the file's `bytes` now, its size at the base (`baseBytes`, null when it was not there), whether the slice
	 * `changed` it and whether its line `declared` it (null: the line could not be read). A file over budget fails only when
	 * the slice grew it, so a slice that shrinks an over-budget file is not held to the whole of the debt.
	 */
	public static function verdict(bytes: Int, baseBytes: Null<Int>, changed: Bool, declared: Null<Bool>): Outcome {
		if (bytes > BUDGET && bytes > (baseBytes ?? 0)) return Failed('$FILE is $bytes B, over its budget of $BUDGET B');
		if (!changed || declared == true) return Passed;
		return Failed(
			declared == null
				? '$FILE changed and the slice\'s queue line could not be read to see it declared'
				: '$FILE changed and the slice did not declare it: report `touches+: $FILE — <reason>`'
		);
	}

	/** What the row prints beside its verdict: the bytes, the delta against the base and the budget. */
	public static function note(bytes: Int, baseBytes: Null<Int>): String {
		final delta: String = baseBytes == null ? 'new' : GateTree.signed(bytes - baseBytes);
		return '$bytes B ($delta), budget $BUDGET B';
	}

	/** The row over `tree`: its size now against `base`, and the declaration of the slice when it changed the file. */
	public static function outcome(tree: String, base: String, touched: Array<String>, summary: Summary): Outcome {
		final path: String = Path.join([tree, FILE]);
		if (!FileSystem.exists(path)) return Skipped('no $FILE in the tree');
		final bytes: Int = FileSystem.stat(path).size;
		final was: Result = cmd('git -C $tree cat-file -s $base:$FILE').run();
		final baseBytes: Null<Int> = was.ok ? Std.parseInt(was.out.trim()) : null;
		summary.detail(note(bytes, baseBytes));
		final changed: Bool = reached(touched);
		return verdict(bytes, baseBytes, changed, changed ? declared(tree) : true);
	}

}
