package anyparse.query;

import anyparse.grammar.haxe.HaxeFormatConfigDiagnostics;
import anyparse.query.ConfigFinder.ConfigFile;
#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * Finds the `hxformat.json` that governs a given file — the ONE copy of the
 * walk-up-from-the-file discovery both the `fmt` / writer CLI paths and the
 * width-aware checks depend on.
 *
 * Layout policy belongs to the writer, and the writer is configured per project:
 * a check that reasons about widths MUST read the config of the file it is
 * looking at, not a compiled default. A bare scratch file outside any project
 * therefore legitimately resolves to `null` (plugin defaults) — that is the
 * documented "a probe outside the tree lies about layout" trap, surfaced here
 * rather than papered over.
 *
 * Memoised by DIRECTORY, not by file: a lint run over one project asks the same
 * question once per file and the answer is identical for every file in a
 * directory. The cache is process-scoped and content-blind, so an
 * `hxformat.json` edited on disk mid-process keeps serving the old text — the
 * same trade the parse tiers make, and acceptable for a config that is read-only
 * for the life of a run.
 *
 * The walk itself is `ConfigFinder.findUpFile` — the shared walk-up every config lookup in
 * this package uses — so the loop lives in one place and this module owns only the memo,
 * the blank-payload fold and the diagnostic. One consequence of delegating: an
 * `hxformat.json` that EXISTS but cannot be read used to propagate the IO exception out of
 * `discover`; `findUpFile` answers null for it, so such a file now resolves to the writer's
 * defaults, the same answer as no config at all.
 *
 * On a target without a filesystem the walk is compiled out and every lookup is `null`.
 */
@:nullSafety(Strict)
final class FormatConfigDiscovery {

	/**
	 * Directory -> the config text governing it, or null when no ancestor has one.
	 * `Map.exists` distinguishes "not looked up yet" from "looked up, found nothing".
	 */
	private static final CACHE: Map<String, Null<String>> = [];

	/**
	 * `text` with a BLANK payload folded into "no config at all".
	 *
	 * A 0-byte or whitespace-only `hxformat.json` states no settings, so the answer is
	 * the writer's own defaults — but it is not JSON, and handing it to the config
	 * parser raises `unexpected input (expected {)`. The fold happens HERE, once, so
	 * every hop downstream (`layoutMetrics`, the caching plugin's memo key,
	 * `writeRoundTrip`) reads the same thing; a rule that measured through one hop and
	 * wrote through another otherwise reports findings it can never apply.
	 */
	public static inline function normalize(text: Null<String>): Null<String> {
		return text == null || StringTools.trim(text) == '' ? null : text;
	}

	/**
	 * The content of the nearest `hxformat.json` at or above `filePath`'s own
	 * directory, or null when no ancestor directory holds one, when the one it holds
	 * is blank (`normalize`), and on targets with no filesystem.
	 */
	public static function discover(filePath: String): Null<String> {
		#if (sys || nodejs)
		final start: String = haxe.io.Path.directory(FileSystem.absolutePath(filePath));
		if (CACHE.exists(start)) return CACHE[start];
		final found: Null<ConfigFile> = ConfigFinder.findUpFile(filePath, 'hxformat.json');
		final content: Null<String> = normalize(found?.content);
		CACHE[start] = content;
		// The one place that holds BOTH a config's text and the path it came from,
		// and reaches it exactly once per directory — so this is where "hxq will not
		// act on these settings" can name a file. A config handed straight to the
		// loader as a string (a corpus fixture's section 1, a test literal) has no
		// file to name and stays silent by construction.
		if (found != null && content != null) HaxeFormatConfigDiagnostics.warn(found.path, content);
		return content;
		#else
		return null;
		#end
	}

}
