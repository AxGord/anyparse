package dev;

import dev.LandSweep.Listing;
import dev.QueueFile.QueueLine;
import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Result;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;
using anyparse.util.Groups;

/** Where a lock run takes its footprint from. */
enum LockMode {

	/** The sweep command's listing over the tree as it stands: nothing of the line is written yet. */
	OnTree;

	/** The files the line's commit changes against its base: the sweep is already in the tree, a listing would read empty. */
	OnCommit;

	/** Put the line's declared touches back. */
	Release;

	/** Only ask whether the line has a sweep command: nothing is listed, read from the queue's other lines or written. */
	Probe;

}

/** What a lock run decided about a sweep line's `touches:`. */
enum LockVerdict {

	/** The line has no sweep command: nothing to hold. */
	Plain;

	/** The queue holds `touches` now: the declared files and the `footprint` beyond them. */
	Locked(touches: Array<String>, footprint: Array<String>);

	/** The command reports no file: the line holds its declared touches alone. */
	Barren;

	/** The rule the command names is not on this engine: the line's own commit brings it, the lock waits for that. */
	Deferred(why: String);

	/** A running line `id` holds `file` of the footprint: nothing was written. */
	Overlap(id: String, file: String);

	/** The footprint could not be read: a listing that fails never reads as an empty one. */
	Unread(why: String);

	/** The queue refused the write. */
	Refused(why: String);

	/** The declared touches are back. */
	Released;

	/** A probe: the line has a sweep command, so a lock run is due. */
	Sweeps;

}

/** One lock run: the queue file, the line, the tree to list or diff, the engine to list with, where the declared touches are kept. */
typedef LockRequest = {
	final queue: String;
	final id: String;
	final tree: String;
	final engine: String;
	final logs: String;
	final mode: LockMode;
}

/** What a lock run does outside the queue file: the listing, the commit's files, and the queue write (null when it took). */
typedef LockTools = {
	final listing: (engine: String, tree: String, command: Array<String>) -> Listing;
	final changed: (tree: String) -> Array<String>;
	final edit: (id: String, touches: Array<String>) -> Null<String>;
}

/**
 * The one answer to "which files does a sweep line hold while it runs": `dev sweep-lock <ID> --tree <worktree>` sets the line's
 * `touches:` to the files it declared plus its footprint, so a sweep line runs beside the lines that do not touch them instead
 * of alone. The footprint is the files the sweep command reports (`OnTree`) or the files the line's commit changes
 * (`OnCommit`); it is written only when no other running line holds one of its files. The declared touches are kept in the
 * logs dir on the first run, every recompute starts from them, and `--release` puts them back.
 */
@:nullSafety(Strict)
final class SweepLock {

	public static inline final USAGE: String = 'usage: dev sweep-lock <ID> --tree <worktree> [--commit | --release | --probe] [--engine <tree>] [--queue <file>] [--queue-cli <script>]'
		+ '\n  exit 0 held (or no sweep command), 10 the command reports no file, 11 a running line holds a footprint file (nothing written),'
		+ '\n  12 the footprint could not be read, 13 the queue refused the write, 14 the rule is not on the engine yet,'
		+ '\n  15 (--probe) the line has a sweep command, 0 it has none';
	public static inline final EXIT_BARREN: Int = 10;
	public static inline final EXIT_OVERLAP: Int = 11;
	public static inline final EXIT_UNREAD: Int = 12;
	public static inline final EXIT_REFUSED: Int = 13;
	public static inline final EXIT_DEFERRED: Int = 14;
	public static inline final EXIT_SWEEPS: Int = 15;

	/** The file of the logs dir that keeps the touches the line declared. */
	public static final DECLARED: String = 'touches.orig';

	/** What the engine says of a rule it does not know. */
	private static final UNKNOWN_RULE: String = 'unknown rule';

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final commit: Bool = args.flag('--commit');
		final release: Bool = args.flag('--release');
		final probe: Bool = args.flag('--probe');
		final tree: String = args.option('--tree') ?? throw new UsageError('missing --tree <worktree>');
		final repo: String = Repo.resolve(args.option('--repo'));
		final queue: String = args.option('--queue') ?? Path.join([repo, LandSweep.QUEUE]);
		final script: String = args.option('--queue-cli') ?? LessonsFile.queueCli();
		final engine: String = args.option('--engine') ?? (FileSystem.exists(Path.join([tree, 'bin/apq.js'])) ? tree : repo);
		final id: String = args.positionals(['<ID>'])[0];

		if ([commit, release, probe].filter(on -> on).length > 1)
			throw new UsageError('--commit, --release and --probe are exclusive modes');
		final verdict: LockVerdict = lock({
			queue: queue,
			id: id,
			tree: tree,
			engine: engine,
			logs: '${Path.removeTrailingSlashes(tree)}-logs',
			mode: probe ? Probe : release ? Release : commit ? OnCommit : OnTree
		}, tools(queue, script));
		Sys.println(sentence(verdict));
		return exitOf(verdict);
	}

	/** Hold, recompute or release the touches of line `request.id`. */
	public static function lock(request: LockRequest, tools: LockTools): LockVerdict {
		final line: Null<QueueLine> = QueueFile.find(File.getContent(request.queue), request.id);
		if (line == null) return Unread('no line ${request.id} in ${request.queue}');
		final saved: String = Path.join([request.logs, DECLARED]);
		if (request.mode == Release) return release(line, saved, tools);
		final command: Null<String> = LandSweep.commandIn(line);
		if (command == null) return Plain;
		if (request.mode == Probe) return Sweeps;
		final declared: Array<String> = declaredOf(line, saved);
		return switch footprint(request, command, tools) {
			case Unlisted(why): why.contains(UNKNOWN_RULE) ? Deferred(why) : Unread(why);
			case Listed(files): settle(request, line, declared, files, tools);
		};
	}

	/** Whether the touches entry `held` of a running line keeps `file` from another: the same file, or a directory over it. */
	public static function holds(held: String, file: String): Bool {
		return held == file || file.startsWith(Path.addTrailingSlash(held));
	}

	public static function exitOf(verdict: LockVerdict): Int {
		return switch verdict {
			case Plain, Locked(_, _), Released: 0;
			case Barren: EXIT_BARREN;
			case Overlap(_, _): EXIT_OVERLAP;
			case Unread(_): EXIT_UNREAD;
			case Refused(_): EXIT_REFUSED;
			case Deferred(_): EXIT_DEFERRED;
			case Sweeps: EXIT_SWEEPS;
		};
	}

	public static function sentence(verdict: LockVerdict): String {
		return switch verdict {
			case Plain: 'sweep-lock: the line has no sweep command';
			case Locked(touches, footprint): 'sweep-lock: holds ${touches.length} file(s), ${footprint.length} of them the footprint';
			case Barren: 'sweep-lock: the sweep command reports no file, the line holds its declared touches alone';
			case Deferred(why): 'sweep-lock: deferred to the line\'s commit ($why)';
			case Overlap(id, file): 'blocked_reason: footprint overlaps $id ($file)';
			case Unread(why): 'sweep-lock: the footprint could not be read: $why';
			case Refused(why): 'sweep-lock: the queue refused the write: $why';
			case Released: 'sweep-lock: the declared touches are back';
			case Sweeps: 'sweep-lock: the line has a sweep command';
		};
	}

	/** The tools of a real run: the command's listing, the commit's files against `main`, the queue CLI `script` over `queue`. */
	public static function tools(queue: String, script: String): LockTools {
		return {
			listing: LandSweep.engine().findings,
			changed: tree -> {
				final base: Result = cmd('git -C $tree merge-base HEAD main').run();
				if (!base.ok) throw new Exception('no merge base of $tree and main: ${base.firstError()}');
				final diff: Result = cmd('git -C $tree diff --name-only ${base.out.trim()} HEAD').run();
				if (!diff.ok) throw new Exception('no diff of $tree: ${diff.firstError()}');
				diff.lines();
			},
			edit: (id, touches) -> {
				final run: Result = cmd('$script $queue --edit $id --set touches=${touches.join(',')}').run();
				run.ok ? null : run.firstError();
			}
		};
	}

	private static function footprint(request: LockRequest, command: String, tools: LockTools): Listing {
		try {
			if (request.mode == OnCommit) return Listed(tools.changed(request.tree));
			final words: Null<Array<String>> = LandSweep.wordsOf(command);
			return words == null
				? Unlisted('the sweep command `$command` is not a plain `hxq lint … --fix …`')
				: tools.listing(request.engine, request.tree, words);
		} catch (exception: Exception) {
			return Unlisted(exception.message);
		}
	}

	/** The touches the line declared: kept in `saved` on the first run, read back from it on every later one. */
	private static function declaredOf(line: QueueLine, saved: String): Array<String> {
		if (FileSystem.exists(saved)) return File.getContent(saved).split('\n').filter(entry -> entry != '');
		FileSystem.createDirectory(Path.directory(saved));
		File.saveContent(saved, line.touches.map(entry -> '$entry\n').join(''));
		return line.touches;
	}

	private static function settle(
		request: LockRequest, line: QueueLine, declared: Array<String>, files: Array<String>, tools: LockTools
	): LockVerdict {
		final wanted: Array<String> = declared.copy();
		wanted.pushAllUnique(files);

		final others: Array<QueueLine> = QueueFile.read(File.getContent(request.queue))
			.filter(other -> other.status == 'running' && other.id != line.id);
		// every file, the held ones too: two lines that computed at once each hold the file the other holds
		for (file in wanted) for (other in others) if (other.touches.exists(held -> holds(held, file))) return Overlap(other.id, file);
		final refused: Null<String> = sameSet(line.touches, wanted) ? null : tools.edit(line.id, wanted);
		if (refused != null) return Refused(refused);
		return files.length == 0 ? Barren : Locked(wanted, wanted.filter(file -> !declared.contains(file)));
	}

	private static function release(line: QueueLine, saved: String, tools: LockTools): LockVerdict {
		if (!FileSystem.exists(saved)) return Released;
		final declared: Array<String> = File.getContent(saved).split('\n').filter(entry -> entry != '');
		final refused: Null<String> = sameSet(line.touches, declared) ? null : tools.edit(line.id, declared);
		if (refused != null) return Refused(refused);
		FileSystem.deleteFile(saved);
		return Released;
	}

	private static function sameSet(left: Array<String>, right: Array<String>): Bool {
		return left.length == right.length && left.foreach(entry -> right.contains(entry));
	}

}
