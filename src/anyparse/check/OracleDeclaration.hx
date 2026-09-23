package anyparse.check;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.grammar.json.JEntry;
import anyparse.grammar.json.JValue;
import haxe.Exception;
import haxe.io.Path;

using StringTools;

/**
 * The `apqlint.json` `compilerOracle` key's reader: one JSON value → the configurations it
 * declares, every path resolved and every compile directory probed.
 *
 * Its own module rather than more of `LintConfig` because the two do different kinds of work: that
 * class MAPS a document, while deciding where an hxml compiles from is a filesystem probe with a
 * tie-break of its own. The key is also the one config surface with two spellings to reconcile — a
 * bare hxml path and a list of configurations — and per-entry leniency to report on.
 */
@:nullSafety(Strict)
final class OracleDeclaration {

	/**
	 * The `compilerOracle` value → its configurations. A JSON STRING is the one-element case (no
	 * extra defines); an ARRAY holds one `{hxml, defines?, dir?}` object per configuration.
	 *
	 * A value that is neither is not a configuration at all, so it is dropped with a line rather
	 * than guessed at — a project whose oracle silently went missing would read every risky fix
	 * as report-only and never learn why.
	 */
	public static function read(raw: JValue, baseDir: Null<String>, drops: Array<String>): Array<OracleConfig> {
		return switch raw {
			case JString(hxml):
				[at(hxml, null, [], baseDir)];
			case JArray(items):
				readList(items, baseDir, drops);
			case _:
				drops.push('compilerOracle is neither an hxml path nor a list of configurations — ignored');
				[];
		};
	}

	/** `dir`, or `/` for the empty string `Path.directory` yields at the filesystem root. */
	private static inline function dirOrRoot(dir: String): String {
		return dir == '' ? '/' : dir;
	}

	/**
	 * The ARRAY form's entries → their configurations, per-ENTRY lenient exactly as `rules` and
	 * `frameworks` are: an element that is not an object, names no `hxml`, spells a key with the
	 * wrong type, or names a key this reader does not know is dropped and the configurations
	 * beside it still apply.
	 *
	 * Every drop appends a diagnostic line, because a dropped element that said nothing is
	 * indistinguishable from one that works — and here that silence costs a whole build's worth
	 * of verification.
	 */
	private static function readList(items: Array<JValue>, baseDir: Null<String>, drops: Array<String>): Array<OracleConfig> {
		final out: Array<OracleConfig> = [];
		for (i in 0...items.length) switch items[i] {
			case JObject(fields):
				final declared: OracleFields = readFields(i, fields, drops);
				final hxml: Null<String> = declared.hxml;
				if (hxml == null) {
					drops.push('compilerOracle[$i] declares no "hxml" — dropped');
					continue;
				}
				out.push(at(hxml, declared.dir, declared.defines, baseDir));
			case _:
				drops.push('compilerOracle[$i] is not an object — dropped');
		}
		return out;
	}

	/** One array element's three keys as DECLARED, every wrong-typed or unknown one dropped with a line. */
	private static function readFields(index: Int, fields: Array<JEntry>, drops: Array<String>): OracleFields {
		var hxml: Null<String> = null;
		var dir: Null<String> = null;
		final defines: Array<String> = [];
		for (field in fields) switch [field.key, field.value] {
			case ['hxml', JString(v)]:
				hxml = v;
			case ['dir', JString(v)]:
				dir = v;
			case ['defines', JArray(values)]:
				final before: Int = defines.length;
				LintConfig.collectStrings(values, defines);
				final skipped: Int = values.length - (defines.length - before);
				if (skipped > 0) drops.push('compilerOracle[$index] "defines" ignored $skipped value(s) that are not strings');
			case ['hxml', _], ['dir', _]:
				drops.push('compilerOracle[$index] "${field.key}" is not a string — ignored');
			case ['defines', _]:
				drops.push('compilerOracle[$index] "defines" is not an array of strings — ignored');
			case _:
				drops.push('compilerOracle[$index] declares unknown key "${field.key}" — ignored');
		}
		return {
			hxml: hxml,
			dir: dir,
			defines: defines
		};
	}

	/**
	 * One configuration's declared paths resolved: the hxml against the config dir, and the
	 * compile directory either as the element declared it or PROBED.
	 *
	 * With neither a declared dir nor a base there is nothing to resolve against and nothing to
	 * claim, so the compile directory stays null and the caller runs in its own cwd.
	 */
	private static function at(hxml: String, dir: Null<String>, defines: Array<String>, baseDir: Null<String>): OracleConfig {
		final resolved: String = LintConfig.resolveAgainstConfigDir(baseDir, hxml);
		final probed: Null<String> = if (dir != null)
			LintConfig.resolveAgainstConfigDir(baseDir, dir)
		else if (baseDir == null)
			null
		else
			compileDir(resolved, baseDir);
		return {
			hxml: resolved,
			dir: probed,
			defines: defines
		};
	}

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
	private static function compileDir(hxml: String, baseDir: String): String {
		final own: String = dirOrRoot(Path.directory(hxml));
		final config: String = dirOrRoot(baseDir);
		if (config == own) return own;
		var ownHits: Int = 0;
		var configHits: Int = 0;
		for (rel in relativeClasspaths(hxml)) {
			if (pathExists(Path.normalize(Path.join([own, rel])))) ownHits++;
			if (pathExists(Path.normalize(Path.join([config, rel])))) configHits++;
		}
		return configHits > ownHits ? config : own;
	}

	/**
	 * The relative classpath entries (`-cp` / `-p` / `--class-path`) declared inside `hxml` —
	 * the probe set `compileDir` resolves under each candidate directory. Only INPUT
	 * paths qualify: they must already exist, where an output path (`-cpp`, `-js`) may not
	 * yet. Absolute entries prove nothing about the compile dir and are dropped; an
	 * unreadable hxml (or a non-sys target) yields the empty set — the tie.
	 */
	private static function relativeClasspaths(hxml: String): Array<String> {
		#if (sys || nodejs)
		final content: Null<String> = try sys.io.File.getContent(hxml) catch (exception: Exception) null;
		if (content == null) return [];
		final out: Array<String> = [];
		for (line in content.split('\n')) {
			final trimmed: String = line.trim();
			final path: Null<String> = if (trimmed.startsWith('-cp '))
				trimmed.substr(4)
			else if (trimmed.startsWith('-p '))
				trimmed.substr(3)
			else if (trimmed.startsWith('--class-path '))
				trimmed.substr(13)
			else
				null;
			if (path == null) continue;
			final cleaned: String = path.trim();
			if (cleaned != '' && !Path.isAbsolute(cleaned)) out.push(cleaned);
		}
		return out;
		#else
		return [];
		#end
	}

	/** Whether `path` exists on disk — false wholesale on a non-sys target, keeping the probe a tie there. */
	private static function pathExists(path: String): Bool {
		return #if (sys || nodejs) sys.FileSystem.exists(path) #else false #end;
	}

}

/**
 * One `compilerOracle` array element's three keys exactly as DECLARED — before any path is
 * resolved and before a missing `hxml` decides the element's fate.
 *
 * Module-private: it is the reading step's own shape, not a config surface.
 */
private typedef OracleFields = {
	var hxml: Null<String>;
	var dir: Null<String>;
	var defines: Array<String>;
}
