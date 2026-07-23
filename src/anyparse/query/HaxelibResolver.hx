package anyparse.query;

import haxe.Exception;

/**
 * Resolves a haxelib library NAME to its on-disk source directory, so an
 * `apqlint.json` can declare a resolution-scope library by name
 * (`resolutionLibs`) instead of a brittle machine-specific path. `haxelib
 * libpath <name>` prints the library's install/dev root (honouring a `haxelib
 * dev` link and the currently-selected version); the library's `haxelib.json`
 * `classPath` then names the source subdir relative to that root (`"src"` for
 * openfl, absent/empty for a root-sourced lib).
 *
 * The impure edge is a single `haxelib libpath` spawn (target-conditional,
 * mirroring `CompilerOracle`); every other step — trimming the root, reading
 * `classPath`, joining the source dir — is the pure `sourceDirFrom`,
 * unit-tested WITHOUT a real haxelib. Every failure mode (no `haxelib` on PATH,
 * a non-zero exit, an uninstalled/misspelled lib, a missing or malformed
 * `haxelib.json`, empty output) returns null so the caller skips that lib and
 * the lint proceeds — never throws, never crashes the run.
 */
@:nullSafety(Strict)
final class HaxelibResolver {

	/** Total `haxelib libpath` spawns this process — a run whose resolution thunk never fires leaves this untouched (the laziness invariant tests read). */
	public static var invocations(default, null): Int = 0;

	/**
	 * The absolute source directory of installed library `name`, or null when it
	 * cannot be resolved. Spawns `haxelib libpath <name>`, reads the resulting
	 * root's `haxelib.json`, and joins its `classPath`. Graceful on every edge — a
	 * null return means "treat the lib as absent", not an error.
	 */
	public static function libSourceDir(name: String): Null<String> {
		invocations++;
		final libpathOutput: Null<String> = runLibpath(name);
		return libpathOutput == null ? null : sourceDirFrom(libpathOutput, readHaxelibJson(rootFrom(libpathOutput)));
	}

	/**
	 * PURE assembly: given the `haxelib libpath` stdout and the library's
	 * `haxelib.json` content, return the normalised absolute source directory, or
	 * null. The root is the trimmed `libpathOutput`; the source dir is
	 * `root/classPath`, where `classPath` defaults to the empty string (the root
	 * itself) when the key is absent, empty, or non-string. A null or malformed
	 * `haxelibJson` yields null — the lib is skipped rather than indexing an
	 * unknown tree from its root. No I/O, so it is unit-testable without a real
	 * haxelib.
	 */
	public static function sourceDirFrom(libpathOutput: String, haxelibJson: Null<String>): Null<String> {
		final root: Null<String> = rootFrom(libpathOutput);
		if (root == null || haxelibJson == null) return null;
		final parsed: Null<Dynamic> = try haxe.Json.parse(haxelibJson) catch (exception: Exception) null;
		if (parsed == null || !Reflect.isObject(parsed)) return null;
		final classPathRaw: Null<Dynamic> = Reflect.field(parsed, 'classPath');
		final classPath: String = classPathRaw != null && classPathRaw is String ? StringTools.trim(classPathRaw) : '';
		return haxe.io.Path.normalize(classPath == '' ? root : haxe.io.Path.join([root, classPath]));
	}

	/** The library root: the trimmed `haxelib libpath` output, or null when it is empty (lib not installed / no path printed). */
	public static function rootFrom(libpathOutput: String): Null<String> {
		final root: String = StringTools.trim(libpathOutput);
		return root == '' ? null : root;
	}

	/** Spawn `haxelib libpath <name>` and return its stdout on a zero exit, or null on any failure (mirrors `CompilerOracle`'s target-conditional spawn). */
	private static function runLibpath(name: String): Null<String> {
		#if nodejs
		final res = js.node.ChildProcess.spawnSync('haxelib', ['libpath', name], { encoding: 'utf8' });
		final launchError: Null<Dynamic> = (res.error: Dynamic);
		if (launchError != null) return null;
		final status: Null<Int> = (res.status: Null<Int>);
		if (status == null || status != 0) return null;
		final out: Dynamic = res.stdout;
		return out == null ? null : Std.string(out);
		#elseif sys
		try {
			final process: sys.io.Process = new sys.io.Process('haxelib', ['libpath', name]);
			final out: String = process.stdout.readAll().toString();
			final code: Int = process.exitCode();
			process.close();
			return code == 0 ? out : null;
		} catch (exception: haxe.Exception) {
			return null;
		}
		#else
		return null;
		#end
	}

	/** Read `<root>/haxelib.json`, or null when it is missing/unreadable (graceful — the lib is then skipped). A null `root` (empty libpath) short-circuits to null. */
	private static function readHaxelibJson(root: Null<String>): Null<String> {
		if (root == null) return null;
		#if (sys || nodejs)
		return try sys.io.File.getContent(haxe.io.Path.join([root, 'haxelib.json'])) catch (exception: haxe.Exception) null;
		#else
		return null;
		#end
	}

}
