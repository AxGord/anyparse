package anyparse.query;

import anyparse.check.LintConfig.ConfigNote;
import anyparse.grammar.haxe.HaxeFormatConfigDiagnostics;
import anyparse.query.ConfigFinder.ConfigFile;
import anyparse.query.cli.CliIo;
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
 * directory. The memo holds only what is on disk; what this run has already SAID about a config lives in the run's
 * `RunLedger`, so a new run reports it again. The cache is process-scoped and content-blind, so an
 * `hxformat.json` edited on disk mid-process keeps serving the old text — the
 * same trade the parse tiers make, and acceptable for a config that is read-only
 * for the life of a run.
 *
 * The walk itself is `ConfigFinder.findUpFile` — the shared walk-up every config lookup in
 * this package uses — so the loop lives in one place and this module owns only the memo,
 * the blank-payload fold and the once-per-run report of `HaxeFormatConfigDiagnostics`. One consequence of delegating: an
 * `hxformat.json` that EXISTS but cannot be read used to propagate the IO exception out of
 * `discover`; `findUpFile` answers null for it, so such a file now resolves to the writer's
 * defaults, the same answer as no config at all.
 *
 * On a target without a filesystem the walk is compiled out and every lookup is `null`.
 */
@:nullSafety(Strict)
final class FormatConfigDiscovery {

	/**
	 * The `RunLedger` topic of the config paths this run has reported, so
	 * a run that resolves one config for hundreds of files says it once.
	 */
	public static final REPORTED_TOPIC: String = 'hxformat-config';

	/**
	 * Directory -> the config governing it, its text already `normalize`d, or null when no ancestor has one (or the one it
	 * has is blank). `Map.exists` distinguishes "not looked up yet" from "looked up, found nothing". The path rides with the
	 * text so a memo hit can still name the file it reports on.
	 */
	private static final CACHE: Map<String, Null<ConfigFile>> = [];

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
		return text == null || text.trim() == '' ? null : text;
	}

	/**
	 * Forgets every directory's discovered config, so the next run reads the tree as it is now — what one engine process
	 * running several CLI calls does between them (`BatchRun`).
	 */
	public static inline function forgetRun(): Void {
		CACHE.clear();
	}

	/** The config paths this run has already reported. */
	public static inline function reportedPaths(ledger: RunLedger): Array<String> {
		return ledger.keysOf(REPORTED_TOPIC);
	}

	/**
	 * The content of the nearest `hxformat.json` at or above `filePath`'s own
	 * directory, or null when no ancestor directory holds one, when the one it holds
	 * is blank (`normalize`), and on targets with no filesystem. With `notes` the settings hxq will not act on go there,
	 * under `REPORTED_TOPIC`, for the command to say through its ledger; without, they are not said (`discoverFor`
	 * says them through a command's own ledger).
	 */
	public static function discover(filePath: String, ?notes: Array<ConfigNote>): Null<String> {
		#if (sys || nodejs)
		final start: String = haxe.io.Path.directory(FileSystem.absolutePath(filePath));
		if (!CACHE.exists(start)) remember(start, filePath);
		final found: Null<ConfigFile> = CACHE[start];
		if (found == null) return null;
		if (notes != null) {
			final line: Null<String> = ignoredSettingsLine(found.path, found.content);
			if (line != null) {
				final message: String = line;
				notes.push({ key: found.path, message: message, topic: REPORTED_TOPIC });
			}
		}
		return found.content;
		#else
		return null;
		#end
	}

	/**
	 * Says the settings of the config at `path` hxq will not act on, once per path per run — on a memo hit too, so a run in
	 * a long-lived engine process reports a config an earlier run already read. `discover` calls it for the file it found,
	 * a command for the file the user named (`writer-equals --config`); a config text with no file behind it (a `.hxtest`
	 * section, a test literal) never comes here, so it has no file to name and stays silent.
	 */
	public static function reportConfig(ledger: RunLedger, path: String, content: String): Void {
		#if (sys || nodejs)
		if (normalize(content) == null || !ledger.first(REPORTED_TOPIC, path)) return;
		final line: Null<String> = ignoredSettingsLine(path, content);
		if (line != null) CliIo.stderr(line);
		#end
	}

	/**
	 * `discover` for a command: the settings hxq will not act on are said once per run through `ledger`,
	 * the run's own, so no lookup falls back to a process ledger.
	 */
	public static function discoverFor(filePath: String, ledger: RunLedger): Null<String> {
		#if (sys || nodejs)
		final content: Null<String> = discover(filePath);
		if (content == null) return null;
		final found: Null<ConfigFile> = CACHE[haxe.io.Path.directory(FileSystem.absolutePath(filePath))];
		if (found != null) reportConfig(ledger, found.path, found.content);
		return content;
		#else
		return null;
		#end
	}

	/** The line naming the settings of `content` (the config at `path`) hxq will not act on; null when none or silenced. */
	private static function ignoredSettingsLine(path: String, content: String): Null<String> {
		#if (sys || nodejs)
		final stated: Null<String> = normalize(content);
		return stated == null || Sys.getEnv(HaxeFormatConfigDiagnostics.SILENCE_VAR) == '1'
			? null
			: HaxeFormatConfigDiagnostics.message(path, HaxeFormatConfigDiagnostics.diagnose(stated));
		#else
		return null;
		#end
	}

	#if (sys || nodejs)
	/** Walks up from `filePath` for the config governing directory `start`, and memoises the answer under `start`. */
	private static function remember(start: String, filePath: String): Void {
		final file: Null<ConfigFile> = ConfigFinder.findUpFile(filePath, 'hxformat.json');
		final content: Null<String> = normalize(file?.content);
		CACHE[start] = file == null || content == null ? null : { path: file.path, content: content };
	}
	#end

}
