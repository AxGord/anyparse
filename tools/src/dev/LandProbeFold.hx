package dev;

import dev.LessonsFile.Lesson;
import dev.ProbeFold.Fold;
import devkit.Cmd.cmd;
import devkit.Result;
import devkit.Summary.Outcome;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;

using anyparse.util.Groups;

/** The folds of a probe-additions file on the engine of a tree. */
typedef FoldSource = (repo: String, file: String) -> Array<Fold>;

/** Files one lesson as a queue line; null when the queue took it, else why it did not. */
typedef QueueSink = (lesson: Lesson) -> Null<String>;

/** The step `dev land` runs for a landed slice: its tree, its id and where a detail line goes. */
typedef FoldStep = (repo: String, slice: String, note: String -> Void) -> Outcome;

/**
 * `dev land`'s `probe-fold` step — the one answer to "what becomes of the probe rows a landed slice's review added, once its
 * engine is main's": the file runs through `dev probe --row` on the engine the land just installed, a deviating row of a known
 * area joins its kit as a known defect, a row nobody can judge or place is filed as a backlog line, and one detail line says
 * what happened. The kit rows are committed on main in a commit of their own, so the tree stays clean for the next land; the
 * step runs before the background jobs of the landed commit start, which are dropped the moment the checked-out tip moves.
 * It never fails a land that has already advanced: whatever goes wrong skips the step and leaves the tree as it was.
 */
@:nullSafety(Strict)
final class LandProbeFold {

	/** Rows over this count are left to `dev probe --row` by hand: the step holds the land lock while they run. */
	public static inline final MAX_ROWS: Int = 40;

	/** The trailer of the commit that carries the kit rows. */
	public static final TRAILER: String = 'Probe-Fold';

	private static final QUEUE_ID: String = 'PROBE-ROW';

	public static function afterwards(
		file: Null<String>, repo: String, slice: String, source: FoldSource, sink: QueueSink, note: String -> Void
	): Outcome {
		if (file == null || !FileSystem.exists(file)) return Skipped('no probe-additions.json');
		final paths: Array<String> = [];
		return try {
			final rows: Int = Probe.load(file).invocations.length;
			if (rows > MAX_ROWS) return Skipped('$rows rows, over $MAX_ROWS: fold them with `dev probe --row`');
			final folds: Array<Fold> = source(repo, file);
			// the kits apply may touch are named before it writes any, so a throw partway still restores them
			for (fold in folds) switch fold.outcome {
				case ToKit(area, _):
					final kit: String = Path.join([Probe.KITS, area, Probe.KIT_FILE]);
					paths.pushUnique(kit);
				case Drop, ToQueue(_):
			}
			final report: Array<String> = ProbeFold.apply(repo, folds);
			final failure: Null<String> = paths.length == 0 ? null : commit(repo, slice, paths, report);
			if (failure != null) {
				restore(repo, paths);
				return Skipped('kit rows not committed, tree restored: $failure');
			}
			note(summary(folds, paths.length));
			for (line in enqueue(folds, slice, sink)) note(line);
			Passed;
		} catch (exception: Exception) {
			if (paths.length > 0) restore(repo, paths);
			Skipped('probe-fold failed: ${exception.message}');
		}
	}

	/** The folds on the engine the land installed in `repo`. */
	public static function onEngine(repo: String, file: String): Array<Fold> {
		final engine: String = Path.join([repo, 'bin', 'apq.js']);
		return ProbeFold.fold(repo, repo, engine, file, Probe.GATE_THREADS, Parity.oneProcessFor(repo, engine, true));
	}

	/** The queue sink of `queue` through the queue CLI `script`; a missing queue file refuses every line. */
	public static function filing(script: String, queue: String): QueueSink {
		return lesson -> FileSystem.exists(queue) ? LessonsFile.add(script, queue, lesson) : 'no queue file $queue';
	}

	private static function summary(folds: Array<Fold>, kits: Int): String {
		var dropped: Int = 0;
		var kit: Int = 0;
		var queued: Int = 0;
		for (fold in folds) switch fold.outcome {
			case Drop:
				dropped++;
			case ToKit(_, _):
				kit++;
			case ToQueue(_):
				queued++;
		}
		return 'probe-fold: $kit row(s) to ${kits == 0 ? 'no kit' : '$kits kit(s), committed'}, $queued to queue, $dropped dropped';
	}

	private static function enqueue(folds: Array<Fold>, slice: String, sink: QueueSink): Array<String> {
		final refused: Array<String> = [];
		var index: Int = 0;
		for (fold in folds) switch fold.outcome {
			case ToQueue(text):
				index++;
				final id: String = '$QUEUE_ID-$slice-$index';
				final why: Null<String> = sink({
					slice: slice,
					id: id,
					kind: LessonsFile.UNVERIFIED,
					touches: [],
					repro: 'node bin/dev.js probe --row .claude/backups/slice-logs/$slice/probe-additions.json',
					text: text.length > LessonsFile.MAX_TEXT ? text.substr(0, LessonsFile.MAX_TEXT) : text
				});
				if (why != null) refused.push('probe-fold: row ${fold.name} not queued as $id: $why');
			case Drop, ToKit(_, _):
		}
		return refused;
	}

	private static function commit(repo: String, slice: String, paths: Array<String>, report: Array<String>): Null<String> {
		final added: Result = cmd('git -C $repo add -- $paths').run();
		if (!added.ok) return added.firstError();
		final message: String =
			'probe-fold: ${paths.length} kit(s) of $slice on the landed engine\n\n${report.join('\n')}\n\n$TRAILER: $slice\n';
		final made: Result = cmd('git -C $repo commit -m $message -- $paths').run();
		return made.ok ? null : made.firstError();
	}

	private static function restore(repo: String, paths: Array<String>): Void {
		// one path per call: a pathspec that matches nothing refuses the whole call, and the kit a throw never reached is such a path
		for (path in paths) {
			cmd('git -C $repo reset -q HEAD -- $path').run();
			cmd('git -C $repo checkout -- $path').run();
		}
	}

}
