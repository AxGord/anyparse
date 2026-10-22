package devkit;

import haxe.Exception;
import haxe.io.Path;
import js.node.Fs.Fs;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * The scratch directories this project's tools claim under the temp root, and the sweep that reclaims the ones no live
 * run owns: the Haxe twin of `tools/tmp-lifecycle.sh` — same prefixes, owner stamp, keep marker and predicate, each
 * overridable by the same environment variable. Every uncertainty resolves toward KEEPING a directory; the rationale
 * is `docs/testing.md` § "Scratch directories".
 */
@:nullSafety(Strict)
final class TmpLifecycle {

	private static inline final MS_PER_SECOND: Float = 1000;

	/** The six characters `mktemp` puts after a claimed directory's prefix and its dot. */
	private static inline final TEMPLATE_LENGTH: Int = 6;

	/** The silence a dead owner's directory needs before it is swept, unless `TMPL_GRACE_SECONDS` says otherwise. */
	private static inline final GRACE_SECONDS: Int = 300;

	/** The silence an unstamped directory needs before it is swept, unless `TMPL_LEGACY_SECONDS` says otherwise. */
	private static inline final LEGACY_SECONDS: Int = 21600;

	/** The prefixes, unless `TMPL_PREFIXES` names others. */
	private static inline final PREFIXES: String = 'anyparse-mutcheck anyparse-mutarm apq-battery apq-suite-shard apq-suite apq-dev';

	public final root: String;
	public final prefixes: Array<String>;

	/** The file naming a claimed directory's owner pid. */
	public final stamp: String;

	/** The file that keeps a directory past its owner's exit, whatever the sweep would say. */
	public final keepMarker: String;

	public final graceSeconds: Int;
	public final legacySeconds: Int;

	public function new(
		root: String, prefixes: Array<String>, stamp: String, keepMarker: String, graceSeconds: Int, legacySeconds: Int
	) {
		this.root = root;
		this.prefixes = prefixes;
		this.stamp = stamp;
		this.keepMarker = keepMarker;
		this.graceSeconds = graceSeconds;
		this.legacySeconds = legacySeconds;
	}

	/** Why `dir` is not one of this project's claimed directories, or null when it is: a direct child of `root` named `<prefix>.XXXXXX`. */
	public function refusal(dir: String): Null<String> {
		if (!dir.startsWith('$root/')) return 'refusing \'$dir\' — not under $root';
		final base: String = dir.substr(root.length + 1);
		if (base.indexOf('/') >= 0) return 'refusing \'$dir\' — not a direct child of $root';
		for (prefix in prefixes) if (isClaimName(base, prefix)) return null;
		return 'refusing \'$dir\' — \'$base\' is not one of this project\'s scratch prefixes';
	}

	/** A new directory `<root>/<prefix>.XXXXXX`, stamped with this process's pid. */
	public function claim(prefix: String): String {
		final dir: String = Fs.mkdtempSync('$root/$prefix.');
		File.saveContent(Path.join([dir, stamp]), 'pid ${js.Node.process.pid}\ntool $prefix\nstarted ${Std.int(Sys.time())}\n');
		return dir;
	}

	/** The newest mtime, in seconds, among `dir` and its top-level entries; null when none can be read. */
	public function newestMtime(dir: String): Null<Int> {
		var newest: Null<Int> = mtime(dir);
		final names: Array<String> = try FileSystem.readDirectory(dir) catch (exception: Exception) [];
		for (name in names) {
			final at: Null<Int> = mtime(Path.join([dir, name]));
			if (at != null && (newest == null || at > newest)) newest = at;
		}
		return newest;
	}

	/** The pid the stamp names, as written; null when there is no stamp or it names none. */
	public function ownerPid(dir: String): Null<String> {
		final file: String = Path.join([dir, stamp]);
		if (!FileSystem.exists(file) || FileSystem.isDirectory(file)) return null;
		final text: String = try File.getContent(file) catch (exception: Exception) '';
		for (line in text.split('\n')) {
			final fields: Array<String> = [for (field in ~/[ \t]+/g.split(line.trim())) if (field != '') field];
			if (fields.length > 1 && fields[0] == 'pid') return fields[1];
		}
		return null;
	}

	/** Keep `dir` past its owner's exit: every later sweep leaves it alone until someone removes it by hand. */
	public function markKeep(dir: String): Void {
		File.saveContent(Path.join([dir, keepMarker]), '');
	}

	/** Whether `dir` carries the keep marker. */
	public function isKept(dir: String): Bool {
		return FileSystem.exists(Path.join([dir, keepMarker]));
	}

	/**
	 * Whether no live run owns `dir` at `now` (seconds): not kept, its stamped owner gone (or no stamp at all), and nothing
	 * written into it for the grace period (the legacy period when unstamped).
	 */
	public function isOrphan(dir: String, now: Int): Bool {
		if (isKept(dir)) return false;
		final limit: Int = if (FileSystem.exists(Path.join([dir, stamp]))) {
			final pid: Null<String> = ownerPid(dir);
			if (pid != null && isAlive(pid)) return false;
			graceSeconds;
		} else {
			legacySeconds;
		}
		final newest: Null<Int> = newestMtime(dir);
		return newest != null && now - newest >= limit;
	}

	/**
	 * Remove `dir`, one of this project's directories, and let the git repository `repo` (when given) forget any worktree
	 * registered inside it — removal first, prune second. Answers the refusal when `dir` is not ours; a missing `dir` is
	 * nothing to do.
	 */
	public function discard(dir: String, ?repo: String): Null<String> {
		if (dir == '' || !FileSystem.exists(dir)) return null;
		final refused: Null<String> = refusal(dir);
		if (refused != null) return refused;
		remove(dir);
		if (repo != null) prune(repo);
		return null;
	}

	/** Every claimed directory under `root`, prefix by prefix, each prefix's in name order. */
	public function claimed(): Array<String> {
		final names: Array<String> = try FileSystem.readDirectory(root) catch (exception: Exception) [];
		// collated, as a shell's glob lists them, not by code unit
		names.sort((a, b) -> js.Syntax.code('{0}.localeCompare({1})', a, b));
		return [
			for (prefix in prefixes) for (name in names) if (isClaimName(name, prefix) && FileSystem.isDirectory('$root/$name'))
				'$root/$name'
		];
	}

	/** Remove every orphaned claimed directory, then prune `repo`'s worktrees when one went; answers how many went. */
	public function sweep(now: Int, ?repo: String): Int {
		var swept: Int = 0;
		for (dir in claimed()) if (isOrphan(dir, now) && refusal(dir) == null) {
			remove(dir);
			swept++;
		}
		if (swept > 0 && repo != null) prune(repo);
		return swept;
	}

	/** The configuration the environment gives, as `tools/tmp-lifecycle.sh` reads it. */
	public static function fromEnv(): TmpLifecycle {
		return new TmpLifecycle(
			defaultRoot(), ~/[ \t\n]+/g.split(env('TMPL_PREFIXES', PREFIXES)).filter(p -> p != ''), env('TMPL_STAMP', TempDir.STAMP),
			env('TMPL_KEEP_MARKER', '.apq-keep'), Std.parseInt(env('TMPL_GRACE_SECONDS', '')) ?? GRACE_SECONDS,
			Std.parseInt(env('TMPL_LEGACY_SECONDS', '')) ?? LEGACY_SECONDS
		);
	}

	/** `${TMPDIR:-/tmp}` with every trailing slash removed. */
	public static function defaultRoot(): String {
		var root: String = env('TMPDIR', '/tmp');
		while (root != '/' && root.endsWith('/')) root = root.substr(0, root.length - 1);
		return root;
	}

	/** The current time in whole seconds. */
	public static function now(): Int {
		return Std.int(Sys.time());
	}

	private static inline function remove(dir: String): Void {
		js.Syntax.code("require('fs').rmSync({0}, { recursive: true, force: true })", dir);
	}

	/** Whether `base` is `<prefix>.` and six more characters. */
	private static function isClaimName(base: String, prefix: String): Bool {
		return base.length == prefix.length + 1 + TEMPLATE_LENGTH && base.startsWith('$prefix.');
	}

	/** Whether the process `pid` exists; a pid this process may not signal still exists, so it counts as alive. */
	private static function isAlive(pid: String): Bool {
		final id: Null<Int> = Std.parseInt(pid);
		if (id == null || '$id' != pid) return false;
		return try {
			js.Syntax.code('process.kill({0}, 0)', id);
			true;
		} catch (exception: Exception) {
			Reflect.field(exception.native, 'code') == 'EPERM';
		};
	}

	/** The mtime of `path` itself (a symlink's own), in whole seconds; null when it cannot be read. */
	private static function mtime(path: String): Null<Int> {
		return try Std.int(Fs.lstatSync(path).mtime.getTime() / MS_PER_SECOND) catch (exception: Exception) null;
	}

	/** `git worktree prune` in `repo`, whose failure is nothing to report: the directories are gone either way. */
	private static function prune(repo: String): Void {
		Cmd.cmd('git -C $repo worktree prune').run();
	}

	private static function env(name: String, fallback: String): String {
		final value: Null<String> = Sys.getEnv(name);
		return value == null || value == '' ? fallback : value;
	}

}
