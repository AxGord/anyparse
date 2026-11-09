package anyparse.check.oracle;

import anyparse.check.config.OracleDeclarationReader;
import haxe.Exception;
import haxe.io.Path;

/**
 * The Haxe side of the `compilerOracle` key: where an hxml compiles from (`compileDir`, which reads its class paths) and
 * how a configuration is named. The key is read by `OracleDeclarationReader`, which this class supplies the probe for.
 */
@:nullSafety(Strict)
final class OracleDeclaration {

	/**
	 * The directory a compile of `hxml` must run from. `haxe <path>` resolves the hxml's
	 * relative `-cp` entries against the PROCESS cwd, and real projects write them against
	 * two different conventions: relative to the hxml's own directory (a root-level
	 * `build.hxml` named by a nested config as `"../build.hxml"`), or relative to the
	 * project root the build is invoked from — the config's directory (a lime-generated
	 * `dist/<target>/haxe/debug.hxml`, whose `-cp src` from the hxml's own dir resolves as
	 * `dist/<target>/haxe/src` and rejects the whole build with `Type not found`). Neither
	 * wins by fiat: the hxml's relative classpaths are PROBED under both candidates and the
	 * one resolving strictly more of them wins; a tie — no relative entries, an unreadable
	 * hxml, equal hit counts — keeps the hxml's own directory. `/` replaces an empty
	 * directory for an hxml directly under the filesystem root, where an empty cwd would
	 * fail the spawn instead of compiling at the root.
	 */
	public static function compileDir(hxml: String, baseDir: String): String {
		final own: String = dirOrRoot(Path.directory(hxml));
		final config: String = dirOrRoot(baseDir);
		if (config == own) return own;
		var ownHits: Int = 0;
		var configHits: Int = 0;
		for (rel in relativeClasspaths(hxml)) {
			if (OracleDeclarationReader.pathExists(Path.normalize(Path.join([own, rel])))) ownHits++;
			if (OracleDeclarationReader.pathExists(Path.normalize(Path.join([config, rel])))) configHits++;
		}
		return configHits > ownHits ? config : own;
	}

	/**
	 * One configuration named for a diagnostic: its hxml, plus the defines it adds when it
	 * declares any.
	 *
	 * Every message that used to quote a bare hxml path now has several configurations to tell
	 * apart, and two of them can share one hxml and differ only in a define.
	 */
	public static function describeOracle(oracle: OracleConfig): String {
		return oracle.defines.length == 0 ? oracle.hxml : '${oracle.hxml} -D ${oracle.defines.join(' -D ')}';
	}

	/**
	 * One string per distinct compile a configuration describes: hxml, directory, and defines in
	 * declared order, each separated by a newline no path or define name carries. The ONE spelling
	 * every "same configuration?" question shares — the coverage memo, the warm server's state file,
	 * a report's dedupe — so two of them cannot disagree on what counts as the same build.
	 */
	public static function oracleKey(oracle: OracleConfig): String {
		return [oracle.hxml, oracle.dir ?? ''].concat(oracle.defines).join('\n');
	}

	/** `dir`, or `/` for the empty string `Path.directory` yields at the filesystem root. */
	private static inline function dirOrRoot(dir: String): String {
		return dir == '' ? '/' : dir;
	}

	/**
	 * The relative classpath entries (`-cp` / `-p` / `--class-path`) declared inside `hxml`, read as the compiler reads
	 * it (`OracleCache.hxmlRefs`) — the probe set `compileDir` resolves under each candidate directory. Only INPUT paths
	 * qualify: they must already exist, where an output path (`-cpp`, `-js`) may not yet. Absolute entries prove nothing
	 * about the compile dir and are dropped; an unreadable hxml (or a non-sys target) yields the empty set — the tie. An
	 * include is not followed: it resolves against the compile directory, which is what is being decided.
	 */
	private static function relativeClasspaths(hxml: String): Array<String> {
		#if (sys || nodejs)
		final content: Null<String> = try sys.io.File.getContent(hxml) catch (exception: Exception) null;
		return content == null ? [] : [
			for (path in OracleCache.hxmlRefs(content).classPaths) if (path != '' && !Path.isAbsolute(path)) path
		];
		#else
		return [];
		#end
	}

}
