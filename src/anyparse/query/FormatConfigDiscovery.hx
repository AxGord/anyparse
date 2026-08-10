package anyparse.query;

#if (sys || nodejs)
import sys.io.File;
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
 * On a target without a filesystem the walk is compiled out and every lookup is
 * `null`.
 */
@:nullSafety(Strict)
final class FormatConfigDiscovery {

	// Directory -> the config text governing it, or null when no ancestor has one.
	// `Map.exists` distinguishes "not looked up yet" from "looked up, found nothing".
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
		var dir: String = start;
		while (dir != '') {
			final candidate: String = '$dir/hxformat.json';
			if (FileSystem.exists(candidate) && !FileSystem.isDirectory(candidate)) {
				final content: Null<String> = normalize(File.getContent(candidate));
				CACHE[start] = content;
				return content;
			}
			final parent: String = haxe.io.Path.directory(dir);
			if (parent == dir) break;
			dir = parent;
		}
		CACHE[start] = null;
		return null;
		#else
		return null;
		#end
	}

}
