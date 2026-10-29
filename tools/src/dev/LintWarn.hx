package dev;

import devkit.Cmd.cmd;
import devkit.Result;
import haxe.Exception;
import haxe.Json;
import haxe.crypto.Sha1;
import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;

using Lambda;
using StringTools;

/**
 * `dev lint-warn` — the body of the PostToolUse hook `tools/hooks/hxq-lint-warn.sh`: reads the hook payload on stdin
 * and, after an hxq op that WROTE, lints what it wrote and answers the findings THIS edit added (`apq lint --baseline`
 * against a per-session, per-file-set snapshot) as the hook's `additionalContext`. It shows, never fixes, never blocks,
 * and stays silent whenever it cannot tell which tree the op wrote into or that tree has no engine of its own — a nudge
 * from another tree's engine is the phantom-findings hazard `HXQ_BIN` exists to avoid. The tree an op
 * wrote into is read off EVIDENCE in the command and its output (an absolute path under a registered
 * worktree, or a pinned `HXQ_BIN=`), never off the payload's `cwd`, which is the session's.
 */
@:nullSafety(Strict)
final class LintWarn {

	public static inline final USAGE: String = 'usage: dev lint-warn < <hook-payload.json>';

	/** Delta lines shown before the tail counts the rest: more than this is a `hxq lint` to run, not a nudge. */
	private static inline final SHOWN_MAX: Int = 25;

	/** Days a snapshot is kept: one lint report each, and a long campaign accumulates them per session. */
	private static inline final CACHE_DAYS: Int = 2;

	private static inline final SECONDS_PER_DAY: Float = 86400;
	private static inline final MS_PER_SECOND: Float = 1000;

	/** The hex digits a digest is cut to. */
	private static inline final DIGEST_LENGTH: Int = 16;

	/** The sentence every nudge ends with: a finding a rule can rewrite is that rule's to fix. */
	private static inline final FIX_HINT: String =
		'A mechanically-rewritable one is fixed with\n  hxq lint <file> --rule <id> --fix\nand never by hand.';

	/** An op reporting its own write: `apq <op>: wrote <path>` or `apq <op>: (re)wrote <n> file(s)`. */
	private static final WROTE: EReg = ~/^apq [a-z-]+: (re)?wrote /;

	/** An op reporting it changed nothing. */
	private static final WROTE_NOTHING: EReg = ~/(re)?wrote 0 file\(s\)/;

	/** The `.hx` path an op printed as written. */
	private static final WROTE_PATH: EReg = ~/^apq [a-z-]*: (re)?wrote (.*\.hx)( \(.*\))?$/;

	/** A text-report finding: `<file>:<line>:<col>:`. */
	private static final FINDING: EReg = ~/:[0-9]+:[0-9]+:/;

	public static function main(argv: Array<String>): Int {
		new devkit.Args(argv).done();
		final input: String = js.Syntax.code("require('fs').readFileSync(0, 'utf8')");
		final body: Null<String> = try nudge(input, Repo.ofScript()) catch (exception: Exception) {
			// a hook that fails must fail open: say why where a verbose harness shows it, never block the tool call
			Sys.stderr().writeString('dev lint-warn: ${exception.message}\n');
			null;
		};
		if (body != null) Sys.println(Json.stringify({
			hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: 'hxq lint-warn (nudge — nothing was fixed):\n$body' }
		}));
		return 0;
	}

	/** The nudge for the hook payload `input`, or null when there is nothing to say; `own` is the tree this tool sits in. */
	public static function nudge(input: String, own: Null<String>): Null<String> {
		if (input.indexOf(': wrote ') < 0 && input.indexOf(': rewrote ') < 0) return null;
		final payload: HookPayload = Json.parse(input);
		final said: String = (payload.tool_response?.stdout ?? '') + '\n' + (payload.tool_response?.stderr ?? '');
		final wrote: Array<String> = [
			for (line in said.split('\n')) if (WROTE.match(line) && !WROTE_NOTHING.match(line)) line
		];
		final project: Null<String> = mainTree(own);
		if (wrote.length == 0 || project == null) return null;
		final tokens: Array<String> = words(payload.tool_input?.command ?? '');
		final into: Null<Target> = target(tokens, payload.cwd ?? '', project);
		if (into == null) return null;
		final files: Array<String> = written(wrote, tokens, into.root);
		return files.length == 0 ? null : lint(into.engine, into.root, files, payload.session_id ?? 'default');
	}

	/** The `.hx` files of `root` the op wrote: the paths it printed, then the `.hx` words of its command line, deduplicated. */
	public static function written(wrote: Array<String>, tokens: Array<String>, root: String): Array<String> {
		final candidates: Array<String> = [for (line in wrote) if (WROTE_PATH.match(line)) WROTE_PATH.matched(2)];
		for (token in tokens) if (isHxWord(token)) candidates.push(beforeLine(unquoted(token)));
		final files: Array<String> = [];
		for (candidate in candidates) if (candidate != '') {
			final path: String = candidate.startsWith('/') ? normalised(candidate) : '$root/$candidate';
			if (
				path.startsWith('$root/') && path.endsWith('.hx') && FileSystem.exists(path) && !FileSystem.isDirectory(path)
				&& !files.contains(path)
			)
				files.push(path);
		}
		return files;
	}

	/** The whitespace-separated words of `command`, as an unquoted shell expansion with globbing off splits them. */
	public static function words(command: String): Array<String> {
		return [for (word in ~/[ \t\n]+/g.split(command)) if (word != '') word];
	}

	/** Where the per-session snapshots live: `${XDG_CACHE_HOME:-$HOME/.cache}/hxq/lint-warn`. */
	public static function cacheRoot(): String {
		final xdg: String = Sys.getEnv('XDG_CACHE_HOME') ?? '';
		return Path.join([xdg != '' ? xdg : '${Sys.getEnv('HOME')}/.cache', 'hxq/lint-warn']);
	}

	/** The short, stable token naming a session's or a file set's snapshot. */
	public static function digest(text: String): String {
		return Sha1.make(Bytes.ofString(text)).toHex().substr(0, DIGEST_LENGTH);
	}

	/**
	 * The tree the op wrote into and the engine to lint it with, from the evidence in its command line `tokens`: an absolute
	 * path under a registered worktree, else the tree of a pinned `HXQ_BIN=`, else the session's `cwd`, else `project`.
	 * Null when the evidence points where this hook cannot see, or the tree has no engine of its own.
	 */
	private static function target(tokens: Array<String>, cwd: String, project: String): Null<Target> {
		final trees: Array<String> = worktrees(project);
		var tree: Null<String> = null;
		var pinned: Null<String> = null;
		for (raw in tokens) {
			final token: String = unquoted(raw);
			if (token.startsWith('HXQ_BIN=/'))
				pinned = token.substr('HXQ_BIN='.length)
			else if (token.startsWith('/') && tree == null)
				tree = treeOf(trees, beforeLine(token));
		}
		if (tree == null && pinned != null) {
			tree = treeOf(trees, pinned);
			// a pinned engine whose tree the command never names ran somewhere this hook cannot see: silence beats a phantom
			if (tree == null) return null;
		}
		final home: String = cwd != '' && FileSystem.isDirectory(cwd) ? cwd : project;
		final root: String = tree ?? treeOf(trees, home) ?? project;
		final engine: Null<String> = if (root == project) {
			FileSystem.exists('$project/bin/apq.js') ? '$project/bin/apq.js' : null;
		} else if (FileSystem.exists('$root/bin/apq.js')) {
			'$root/bin/apq.js';
		} else {
			pinned != null && FileSystem.exists(pinned) ? pinned : null;
		};
		return engine == null ? null : { root: root, engine: engine };
	}

	/** One lint process over `files` in `root`, against the session's snapshot of that file set; the nudge, or null. */
	private static function lint(engine: String, root: String, files: Array<String>, session: String): Null<String> {
		final snapshots: String = cacheRoot();
		final cacheDir: String = '$snapshots/${digest(session)}';
		final sorted: Array<String> = files.copy();
		sorted.sort(Reflect.compare);
		var snapshot: Null<String> = '$cacheDir/${digest('$root\n${sorted.join('\n')}')}.json';
		sweep(snapshots);
		try
			FileSystem.createDirectory(cacheDir)
		catch (exception: Exception)
			snapshot = null;
		// an engine without `--baseline` would refuse the whole lint; one with `--full` would summarise a large report
		final help: String = cmd('node $engine lint --help').run().out;
		final baseline: Array<String> = snapshot != null && help.indexOf('--baseline') >= 0 ? ['--baseline', snapshot] : [];
		final full: Array<String> = help.indexOf('--full ') >= 0 ? ['--full'] : [];
		final run: Result = cmd('node $engine lint $files --all --no-oracle --flat $full $baseline')
			.at(root)
			.env('APQ_NO_CONFIG_WARN', '1')
			.run();
		final found: Array<String> = [for (line in run.lines()) if (FINDING.match(line)) line];
		if (found.length == 0) return null;
		final subtracted: Bool = ~/ new of .* finding\(s\)/.match(run.err);
		final shown: Array<String> = found.slice(0, SHOWN_MAX);
		if (found.length > SHOWN_MAX) shown.push('… ${found.length - SHOWN_MAX} more finding(s) not shown');
		final count: Int = found.length;
		final tail: String = if (subtracted) {
			'$count finding(s) this edit added, against the last nudge on these file(s).';
		} else if (baseline.length > 0) {
			final standing: String = 'the first nudge on them in this session; later ones show only what changed.';
			'$count finding(s) standing on the file(s) that op wrote — $standing';
		} else {
			'$count finding(s) on the file(s) that op wrote — standing ones included (this engine has no --baseline).';
		};
		return '${shown.join('\n')}\n\n$tail $FIX_HINT';
	}

	/**
	 * Drop the snapshots of `root` older than `CACHE_DAYS` days, then the directories left empty — the ROOT, because a
	 * session's own directory holds only what that session just wrote, so sweeping it would keep every past one forever.
	 */
	private static function sweep(root: String): Void {
		if (!FileSystem.exists(root)) return;
		final now: Float = Sys.time();
		function walk(dir: String): Bool {
			var empty: Bool = true;
			for (name in FileSystem.readDirectory(dir)) {
				final path: String = '$dir/$name';
				if (FileSystem.isDirectory(path)) {
					if (walk(path))
						FileSystem.deleteDirectory(path)
					else
						empty = false;
				} else if (
					name.endsWith('.json')
					&& Math.floor((now - FileSystem.stat(path).mtime.getTime() / MS_PER_SECOND) / SECONDS_PER_DAY) > CACHE_DAYS
				) {
					FileSystem.deleteFile(path);
				} else {
					empty = false;
				}
			}
			return empty;
		}
		walk(root);
	}

	/** The main worktree of the repository `own` belongs to: the hook's project. */
	private static function mainTree(own: Null<String>): Null<String> {
		if (own == null) return null;
		final trees: Array<String> = worktrees(own);
		return trees.length > 0 ? trees[0] : own;
	}

	/** The registered worktrees of the repository at `repo`, main first, as git spells them (real paths). */
	private static function worktrees(repo: String): Array<String> {
		final listed: Array<String> = [
			for (line in cmd('git -C $repo worktree list --porcelain')
				.run()
				.lines()) if (line.startsWith('worktree ')) line.substr('worktree '.length)
		];
		return listed.length > 0 ? listed : [repo];
	}

	/** The worktree of `trees` holding the absolute `path`, or null. */
	private static function treeOf(trees: Array<String>, path: String): Null<String> {
		final real: String = normalised(path);
		return trees.find(tree -> real == tree || real.startsWith('$tree/'));
	}

	/** `/tmp/…` as git prints it, `/private/tmp/…`. */
	private static function normalised(path: String): String {
		return path.startsWith('/tmp/') ? '/private$path' : path;
	}

	/** `word` without one leading and one trailing quote. */
	private static function unquoted(word: String): String {
		var cut: String = word;
		if (cut.startsWith('"') || cut.startsWith('\'')) cut = cut.substr(1);
		return cut.endsWith('"') || cut.endsWith('\'') ? cut.substr(0, cut.length - 1) : cut;
	}

	/** `path` up to a `:<digit>` position suffix. */
	private static function beforeLine(path: String): String {
		final at: EReg = ~/:[0-9]/;
		return at.match(path) ? at.matchedLeft() : path;
	}

	/** Whether `word` names a `.hx` file: it ends in `.hx`, or `.hx` stands before a character no identifier continues with. */
	private static function isHxWord(word: String): Bool {
		return word.endsWith('.hx') || ~/\.hx[^A-Za-z]/.match(word);
	}

}

/** The fields of a PostToolUse hook payload this hook reads. */
typedef HookPayload = {
	var ?session_id: String; // noqa: naming
	var ?cwd: String;
	var ?tool_input: { var ?command: String; }; // noqa: naming
	var ?tool_response: { var ?stdout: String; var ?stderr: String; }; // noqa: naming
}

/** The tree an op wrote into and the engine that lints it. */
typedef Target = {
	var root: String;
	var engine: String;
}
