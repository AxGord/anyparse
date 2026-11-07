package anyparse.query;

import haxe.Exception;
import haxe.io.Path;

/**
 * The one answer to "which file is this path?": every site that keys, dedups or compares files by identity asks here,
 * so two spellings of one file — relative against absolute, through a symlinked root — can never key apart in one
 * place and together in another.
 */
@:nullSafety(Strict)
final class FileIdentity {

	/**
	 * `path` absolute, normalised and with every symlink resolved — the identity of a file however it is spelled. A path
	 * that does not exist yet resolves its nearest existing ancestor and keeps the rest, so it keys like the file it
	 * will become. On node an existing component takes the letter case the directory really carries, so two case
	 * spellings of one file on a case-insensitive volume are one identity. Two files NOT yet created whose names differ
	 * only in case stay two identities: nothing on disk decides them.
	 */
	public static function realPath(path: String): String {
		#if (sys || nodejs)
		final absolute: String = Path.removeTrailingSlashes(Path.normalize(sys.FileSystem.absolutePath(path)));
		if (sys.FileSystem.exists(absolute)) {
			// `fullPath` is declared non-null and on hxnodejs RETURNS null for a path it cannot resolve; the catch is for
			// the targets where it throws instead.
			final resolved: Null<String> = try resolveExisting(absolute) catch (exception: Exception) null;
			return resolved == null || resolved == '' ? absolute : Path.normalize(resolved);
		}
		final parent: String = Path.directory(absolute);
		return parent == '' || parent == absolute ? absolute : Path.join([realPath(parent), Path.withoutDirectory(absolute)]);
		#else
		return path;
		#end
	}

	/** Whether `a` and `b` name one file — the same spelling, or the same `realPath`. */
	public static function same(a: String, b: String): Bool {
		return a == b || realPath(a) == realPath(b);
	}

	#if (sys || nodejs)
	/**
	 * `path` resolved against `root` when relative, then symlink-resolved. Both sides of
	 * the membership test go through this: the compiler prints paths against ITS working
	 * directory and the lint run names files against the PROCESS one, and on a host whose
	 * temp dir is a symlink (`/tmp` on macOS) the two spellings of one file differ. A path that does not exist
	 * keys through its nearest existing ancestor (`FileIdentity.realPath`) rather than failing the lookup.
	 */
	public static function canonical(root: String, path: String): String {
		// `root` is absolutised FIRST, so a relative one cannot produce a key the membership
		// test can never match: `covers` resolves against the process cwd, and a relative `pkg/C.hx`
		// on one side would meet an absolute `/…/pkg/C.hx` on the other.
		final base: String = Path.isAbsolute(root) ? root : Path.join([Sys.getCwd(), root]);
		final joined: String = Path.normalize(Path.isAbsolute(path) ? path : Path.join([base, path]));
		return realPath(joined);
	}
	#end

	/**
	 * An existing `path` resolved by the kernel: every symlink followed and, on node, the letter case the directory entries
	 * really carry (`realpath.native`), which `fs.realpathSync` leaves as the caller spelled it.
	 */
	private static function resolveExisting(path: String): Null<String> {
		#if nodejs
		final native: Null<String> = try js.Syntax.code('require("fs").realpathSync.native({0})', path) catch (exception: Exception) null;
		if (native != null) return native;
		#end
		return #if (sys || nodejs) sys.FileSystem.fullPath(path) #else path #end;
	}

}
