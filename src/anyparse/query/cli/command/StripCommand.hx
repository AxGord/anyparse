package anyparse.query.cli.command;

import anyparse.query.Cli.ReconCluster;
import anyparse.query.cli.CliContext;
import anyparse.query.cli.command.ReconCommand.ReconWalkResult;
import anyparse.runtime.ParseError;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

#if (sys || nodejs)
import sys.FileSystem;
#end

@:nullSafety(Strict)
typedef StripOpts = {
	var lang: String;
	var showSource: Bool;
	var dryRun: Bool;
	var perPattern: Bool;
	var fromCluster: Null<String>;
	var regexMode: Bool;
	var files: Array<String>;
	var patterns: Array<String>;
	var replacements: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};

/**
 * `apq strip` — sed-strip + parse-check (sole-blocker confirmation).
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class StripCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'strip';
	}

	public function summary(): String {
		return 'Sed-strip + parse-check (sole-blocker confirmation)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runStrip(args);
	}

	public function usage(): Void {
		printStripUsage();
	}

	/** Terminal-case StripOpts: a flag/usage path that the caller returns immediately, ignoring every other field. */
	private static inline function stripParseExit(code: Int): StripOpts {
		return {
			lang: '',
			showSource: false,
			dryRun: false,
			perPattern: false,
			fromCluster: null,
			regexMode: false,
			files: [],
			patterns: [],
			replacements: [],
			errExit: code
		};
	}

	/**
	 * `apq strip <file> --replace <pat> --with <repl> [...]` — machinised
	 * strip-test for the skip-parse campaign. Applies one or more
	 * literal string substitutions to a file's bytes in declaration
	 * order, then tries to parse the result via the grammar plugin.
	 * Emits a single `PARSE OK` / `PARSE FAIL: <err>` verdict to stdout;
	 * with `--show` also dumps the stripped source to stderr so a manual
	 * scratch-file dance (`cat > /tmp/probe.hx <<EOF … EOF; hxq ast …`)
	 * collapses to one command. Exits 0 on PARSE OK, non-zero on FAIL —
	 * scriptable for batch sole-blocker confirmation.
	 *
	 * Pairing rule: each `--with <repl>` consumes the immediately
	 * preceding `--replace <pat>`. Mismatch (more replaces than withs,
	 * or `--with` first) is a usage error. `--delete <pat>` is the
	 * shortcut for `--replace <pat> --with ''`. Repeat `--replace
	 * <pat>` / `--delete <pat>` for multi-substitution; subs apply in
	 * the order given. Substitutions are literal (no regex). Replaces
	 * EVERY occurrence (`StringTools.replace` semantics) — use a more
	 * specific pattern when only the first match should change.
	 *
	 * Lit-stripping context: `.hxtest` corpus fixtures carry a JSON
	 * config block above a `---` separator. Strip operates on raw bytes;
	 * pass an `.hx` scratch extract (the post-`---` body) or accept
	 * that the config bytes will pass through unchanged.
	 */
	private static function runStrip(args: Array<String>): Int {
		final o: StripOpts = parseStripArgs(args);
		if (o.errExit != null) return o.errExit;
		// Compile every pattern AHEAD of any FS I/O so a regex typo
		// surfaces as a single usage error instead of an N-file partial
		// apply. Indices stay aligned with `patterns` / `replacements`.
		// Plain (literal) mode leaves `compiledRegex` null and falls
		// through to the StringTools.replace path further down.
		final compiledRegex: Null<Array<EReg>> = o.regexMode ? compileStripRegexes('strip', o.patterns) : null;
		if (o.regexMode && compiledRegex == null) return EXIT_USAGE;
		// `--per-pattern` constraints: single-file only (the matrix
		// would be NxM otherwise), incompatible with `--dry-run` (the
		// dry-run path skips parse entirely so isolation diagnostics
		// have no PARSE OK/FAIL signal) and `--from-cluster` (the
		// cluster-mode discovers N files from a recon walk, never one).
		if (o.perPattern) {
			if (o.dryRun) {
				CliIo.stderr('apq strip: --per-pattern is incompatible with --dry-run (dry-run skips the parse step)\n');
				return EXIT_USAGE;
			}
			if (o.fromCluster != null) {
				CliIo.stderr('apq strip: --per-pattern is incompatible with --from-cluster (single-file isolation only)\n');
				return EXIT_USAGE;
			}
		}
		// `--from-cluster` mode: discover files via recon walk, then
		// fall through into the existing per-file substitution loop.
		// Conflict guards live here so a bad mix is surfaced before
		// any FS I/O or plugin call.
		final fromCluster: Null<String> = o.fromCluster;
		if (fromCluster != null) {
			if (o.files.length > 1) {
				CliIo.stderr(
					'apq strip: --from-cluster takes at most one positional (corpus root); got ${o.files.length} (${o.files.join(', ')})\n'
				);
				return EXIT_USAGE;
			}
			final discovered: Null<Array<String>> = resolveStripFromCluster(o.lang, o.files.length == 1 ? o.files[0] : null, fromCluster);
			if (discovered == null) return EXIT_RUNTIME;
			// Replace the positional list with the cluster's path list so
			// the rest of runStrip is mode-agnostic. A non-null `discovered`
			// is non-empty by construction (any cluster keyed in the map
			// has at least one path; the no-match path returned null
			// above), so no zero-length branch needed here.
			o.files.resize(0);
			for (p in (discovered: Array<String>)) o.files.push(p);
		} else if (o.files.length == 0) {
			CliIo.stderr('apq strip: missing <file> argument (one or more, applies same substitutions to each)\n');
			printStripUsage();
			return EXIT_USAGE;
		}
		final plugin: GrammarPlugin = CliArgs.pickPlugin(o.lang);
		if (!o.perPattern) return executeStrip(plugin, o, compiledRegex);
		if (o.files.length != 1) {
			CliIo.stderr('apq strip: --per-pattern takes exactly one file (got ${o.files.length})\n');
			return EXIT_USAGE;
		}
		if (o.patterns.length < 2) {
			CliIo.stderr(
				'apq strip: --per-pattern requires ≥2 patterns (got ${o.patterns.length}'
				+ ') — isolation diagnostic only useful when patterns can be tested independently\n'
			);
			return EXIT_USAGE;
		}
		return runStripPerPattern(plugin, o.files[0], o.patterns, o.replacements, compiledRegex);
	}

	/**
	 * `--per-pattern` isolation diagnostic. Runs the parse on:
	 *  1. baseline (no patterns applied — the original source)
	 *  2. each pattern in isolation (only that one applied)
	 *  3. combined (all patterns applied, the regular strip behaviour)
	 *
	 * Output is one line per row, plus a final verdict that calls out
	 * the interlocking-blockers signature: every isolated row FAIL +
	 * combined OK means the slice needs N separate code mechanisms
	 * (one per pattern), not one. The verdict is informational — exit
	 * code follows the combined row, so a passing combination still
	 * exits 0 even when every isolated row failed.
	 *
	 * Single-file only (caller-enforced) — for multi-file matrices the
	 * `--dry-run` per-pattern totals + per-file PARSE OK/FAIL combination
	 * already covers the use-case.
	 */
	private static function runStripPerPattern(
		plugin: GrammarPlugin, filePath: String, patterns: Array<String>, replacements: Array<String>, compiledRegex: Null<Array<EReg>>
	): Int {
		final source: String = CliIo.readSourceForParse(filePath);
		final regexMode: Bool = compiledRegex != null;
		final regexes: Array<EReg> = compiledRegex ?? [];
		final baseline: { ok: Bool, msg: String } = stripTryParse(plugin, source);
		CliIo.sysPrint('baseline (no patterns): ${baseline.ok ? 'PARSE OK' : 'PARSE FAIL: ' + baseline.msg}\n');
		final isolatedResults: Array<{ ok: Bool, hits: Int }> = [];
		for (idx in 0...patterns.length) {
			final hits: Int = regexMode ? countRegexHits(regexes[idx], source) : countOccurrences(source, patterns[idx]);
			final isolated: String = regexMode
				? regexes[idx].replace(source, replacements[idx])
				: source.replace(patterns[idx], replacements[idx]);
			final r: { ok: Bool, msg: String } = stripTryParse(plugin, isolated);
			isolatedResults.push({ ok: r.ok, hits: hits });
			final pat: String = patterns[idx];
			CliIo.sysPrint('pattern[$idx] "$pat" ($hits match${hits == 1 ? '' : 'es'}): ${r.ok ? 'PARSE OK' : 'PARSE FAIL: ' + r.msg}\n');
		}
		var combinedStripped: String = source;
		for (idx in 0...patterns.length)
			combinedStripped = regexMode
				? regexes[idx].replace(combinedStripped, replacements[idx])
				: combinedStripped.replace(patterns[idx], replacements[idx]);
		final combined: { ok: Bool, msg: String } = stripTryParse(plugin, combinedStripped);
		CliIo.sysPrint('combined (all patterns): ${combined.ok ? 'PARSE OK' : 'PARSE FAIL: ' + combined.msg}\n');
		reportStripVerdict(baseline.ok, combined.ok, isolatedResults, patterns.length);
		return combined.ok ? EXIT_OK : EXIT_RUNTIME;
	}

	/**
	 * Resolve the `strip --from-cluster <key>` path list: run a recon
	 * walk over the corpus root, filter by cluster key, return absolute
	 * paths (so the file loop reads the actual files, not the
	 * stripped-relative names recon stores). On miss (unknown key) or
	 * setup error, prints to stderr and returns `null` — caller exits
	 * `EXIT_RUNTIME`.
	 *
	 * `rootArg` is the explicit positional (if any); fall back to
	 * `defaultReconRoot()` (env var) on null.
	 */
	private static function resolveStripFromCluster(lang: String, rootArg: Null<String>, key: String): Null<Array<String>> {
		#if (sys || nodejs)
		final root: String = rootArg ?? ReconCommand.defaultReconRoot();
		if (root == '') {
			CliIo.stderr("apq strip: --from-cluster requires a corpus root (positional <dir> or $ANYPARSE_HXFORMAT_FORK env var).\n");
			return null;
		}
		if (!FileSystem.exists(root) || !FileSystem.isDirectory(root)) {
			CliIo.stderr('apq strip: --from-cluster: "$root" is not a directory.\n');
			return null;
		}
		final plugin: GrammarPlugin = CliArgs.pickPlugin(lang);
		final walk: ReconWalkResult = ReconCommand.collectReconSkipRecords(plugin, root);
		if (!walk.wired) {
			CliIo.stderr('apq strip: --from-cluster: no recon parser wired up for lang "$lang"\n');
			return null;
		}
		final cluster: Null<ReconCluster> = walk.clusters[key];
		if (cluster == null) {
			CliIo.stderr('apq strip: --from-cluster "$key" matched no cluster key (exact match).\n');
			final keyEntries: Array<{ key: String, count: Int }> = [
				for (k => v in walk.clusters) { key: k, count: v.count }
			];
			keyEntries.sort((a, b) -> b.count - a.count);
			final preview: Int = keyEntries.length > ReconCommand.CLUSTER_PREVIEW_LIMIT
				? ReconCommand.CLUSTER_PREVIEW_LIMIT
				: keyEntries.length;
			if (preview == 0) {
				CliIo.stderr('  (no skip-parse failures in this sweep)\n');
			} else {
				CliIo.stderr('  available keys (${keyEntries.length} total, showing top $preview by frequency):\n');
				for (idx in 0...preview) CliIo.stderr('    "${keyEntries[idx].key}"  (${keyEntries[idx].count}×)\n');
				if (keyEntries.length > preview)
					CliIo.stderr(
						'    … (${keyEntries.length - preview} more — run `apq recon` on the same root to see the full histogram)\n'
					);
			}
			return null;
		}
		// ReconCluster.paths are root-relative (e.g. `issue_582.hxtest`);
		// rejoin with the root so file IO uses absolute paths regardless
		// of CWD.
		final out: Array<String> = [for (p in cluster.paths) '$root/$p'];
		out.sort((a: String, b: String) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		return out;
		#else
		CliIo.stderr('apq strip: --from-cluster requires a sys target (filesystem walk)\n');
		return null;
		#end
	}

	/**
	 * Count non-overlapping occurrences of `needle` in `haystack`.
	 * Matches `StringTools.replace`'s scan semantics — used by `apq
	 * strip --dry-run` so the per-pattern hit count exactly tracks
	 * how many substitutions the non-dry-run path would perform.
	 */
	public static function countOccurrences(haystack: String, needle: String): Int {
		if (needle.length == 0) return 0;
		var count: Int = 0;
		var from: Int = 0;
		while (true) {
			final idx: Int = haystack.indexOf(needle, from);
			if (idx < 0) break;
			count++;
			from = idx + needle.length;
		}
		return count;
	}

	/**
	 * Compile every `--replace` / `--delete` pattern as an `EReg` with
	 * the global flag `g` (needed so `replace` and `map` walk every
	 * occurrence, matching the literal-mode `StringTools.replace`
	 * semantics). On compile failure prints the offending pattern + EReg
	 * error to stderr and returns `null` — caller exits `EXIT_USAGE`
	 * before any FS I/O. Tool tag (`'strip'` / `'recon'`) is threaded for
	 * the error message prefix so the user sees which subcommand owned
	 * the typo.
	 */
	public static function compileStripRegexes(tool: String, patterns: Array<String>): Null<Array<EReg>> {
		final out: Array<EReg> = [];
		for (idx => pat in patterns) {
			try {
				out.push(new EReg(pat, 'g'));
			} catch (e: Exception) {
				CliIo.stderr('apq $tool: --regex: pattern[$idx] "$pat" is not a valid EReg: ${e.message}\n');
				return null;
			}
		}
		return out;
	}

	/**
	 * Count every match of `re` in `s`. Uses `EReg.map` for the side
	 * effect — the callback fires once per match (including zero-length
	 * matches, which `EReg` advances past internally) and returns the
	 * matched text unchanged so the produced string equals the input.
	 * Cheap enough for predict-strip / strip --dry-run sweeps.
	 */
	public static function countRegexHits(re: EReg, s: String): Int {
		var n: Int = 0;
		re.map(s, m -> {
			n++;
			m.matched(0);
		});
		return n;
	}

	private static function printStripUsage(): Void {
		CliIo.sysPrint('Usage: apq strip [options] <file> [<file2> ...] --replace <pat> --with <repl> [...]\n');
		CliIo.sysPrint('       apq strip --from-cluster <key> [<dir>] --replace <pat> --with <repl> [...]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --replace <pat>     Literal substring to replace (paired with the next --with)\n');
		CliIo.sysPrint('  --with <repl>       Replacement for the most recent --replace\n');
		CliIo.sysPrint('  --delete <pat>      Shortcut for --replace <pat> --with \'\'\n');
		CliIo.sysPrint('  --regex             Treat --replace / --delete patterns as EReg (global match)\n');
		CliIo.sysPrint('                      instead of literal substrings. Backrefs in --with via $1.\n');
		CliIo.sysPrint('  --show              Dump the stripped source to stderr (debug)\n');
		CliIo.sysPrint('  --dry-run           Skip parse, only verify each pattern matched ≥1 occurrence somewhere (typo guard)\n');
		CliIo.sysPrint('  --per-pattern       Isolation diagnostic for multi-pattern strip on a single file. Runs baseline,\n');
		CliIo.sysPrint('                      each pattern alone, and combined. Surfaces interlocking blockers (combined OK +\n');
		CliIo.sysPrint('                      every isolated row FAIL = slice needs N separate code mechanisms, not one).\n');
		CliIo.sysPrint('                      Requires single file and ≥2 patterns; incompatible with --dry-run / --from-cluster.\n');
		CliIo.sysPrint('  --from-cluster <key>\n');
		CliIo.sysPrint('                      Discover file list via a recon walk and filter by EXACT cluster\n');
		CliIo.sysPrint('                      key (same shape as `apq recon --cluster <key>`). Positional <dir>\n');
		CliIo.sysPrint("                      becomes the corpus root (env fallback to $ANYPARSE_HXFORMAT_FORK\n");
		CliIo.sysPrint('                      /test/testcases). Apply complement of `recon --predict-strip`.\n');
		CliIo.sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Apply literal substitutions in order, then parse the result via the\n');
		CliIo.sysPrint('grammar plugin. Emits PARSE OK / PARSE FAIL: <err> and exits 0/2 —\n');
		CliIo.sysPrint('scriptable sole-blocker confirmation for the skip-parse campaign.\n');
		CliIo.sysPrint('StringTools.replace semantics: every occurrence is replaced.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Pass multiple file paths to run the SAME substitutions against each\n');
		CliIo.sysPrint('(batch mode); per-file output is prefixed with the path, and a final\n');
		CliIo.sysPrint('summary line totals pass/fail counts. Exit 0 only when ALL files\n');
		CliIo.sysPrint('PARSE OK; exit 2 when any file PARSE FAIL — useful for sole-blocker\n');
		CliIo.sysPrint('sweeps across a list of candidate fixtures.\n');
	}

	/**
	 * Parse `strip` argv into a StripOpts. A terminal case (`-h`/`--help`
	 * or any usage error) prints its message and returns with `errExit`
	 * set; the caller returns that code immediately. The natural end
	 * returns the full struct with `errExit: null`.
	 */
	private static function parseStripArgs(args: Array<String>): StripOpts {
		var lang: String = 'haxe';
		var showSource: Bool = false;
		// --dry-run: skip the parse step, only verify that every supplied
		// --replace/--delete pattern actually matched at least once in
		// at least one file. Typo guard for batch strip-sweeps — when
		// the pattern silently doesn't match, the corpus delta misleads;
		// a single dry-run pass surfaces the typo before any apply.
		var dryRun: Bool = false;
		// --per-pattern: isolation diagnostic for multi-pattern strip on a
		// single file. Runs the parse N+2 times — baseline (no patterns),
		// each pattern in isolation, and the combined apply — surfacing
		// whether each pattern is a sole-blocker, a partial contributor,
		// or a no-op. Catches the interlocking-blockers trap where a
		// combined-strip PARSE OK can mask that NO individual pattern
		// unblocks alone (i.e. the slice requires N separate code
		// mechanisms, not one). Single-file only — for multi-file sweeps
		// the matrix would be NxM and the signal is in --dry-run +
		// per-file PARSE OK/FAIL combinations.
		var perPattern: Bool = false;
		// `--from-cluster <key>` switches positional mode: the (single)
		// positional becomes the corpus root (recon-style, env fallback
		// to ANYPARSE_HXFORMAT_FORK/test/testcases); the file list is
		// derived from a recon walk of that root, filtered to the named
		// cluster. Direct complement to `recon --predict-strip`'s
		// upper-bound prediction — this is the actual sweep apply.
		var fromCluster: Null<String> = null;
		// --regex: treat every --replace / --delete pattern as an EReg
		// pattern (PCRE-ish, Haxe EReg dialect) instead of a literal
		// substring. Application path switches to EReg.replace (global)
		// for substitution and EReg.map for hit counting. The replacement
		// string keeps its literal semantics — to use a backref, write
		// e.g. `$1` per EReg.replace docs. Malformed regex is reported at
		// arg-validation time with EXIT_USAGE before any FS I/O.
		var regexMode: Bool = false;
		final files: Array<String> = [];
		final patterns: Array<String> = [];
		final replacements: Array<String> = [];
		var pendingReplace: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--replace':
					if (pendingReplace != null) {
						CliIo.stderr('apq strip: --replace "$pendingReplace" needs a --with before the next --replace\n');
						return stripParseExit(EXIT_USAGE);
					}
					pendingReplace = CliArgs.expectValue(args, ++i, '--replace');
				case '--with':
					if (pendingReplace == null) {
						CliIo.stderr('apq strip: --with requires a preceding --replace\n');
						return stripParseExit(EXIT_USAGE);
					}
					patterns.push(pendingReplace);
					replacements.push(CliArgs.expectValue(args, ++i, '--with'));
					pendingReplace = null;
				case '--delete':
					if (pendingReplace != null) {
						CliIo.stderr('apq strip: --replace "$pendingReplace" needs a --with before --delete\n');
						return stripParseExit(EXIT_USAGE);
					}
					patterns.push(CliArgs.expectValue(args, ++i, '--delete'));
					replacements.push('');
				case '--regex':
					regexMode = true;
				case '--show':
					showSource = true;
				case '--dry-run':
					dryRun = true;
				case '--per-pattern':
					perPattern = true;
				case '--from-cluster':
					fromCluster = CliArgs.expectValue(args, ++i, '--from-cluster');
				case '-h', '--help':
					printStripUsage();
					return stripParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq strip: unknown option "$a"\n');
						return stripParseExit(EXIT_USAGE);
					}
					files.push(a);
			}
			i++;
		}
		if (pendingReplace != null) {
			CliIo.stderr('apq strip: --replace "$pendingReplace" needs a --with\n');
			return stripParseExit(EXIT_USAGE);
		}
		if (patterns.length != 0) return {
			lang: lang,
			showSource: showSource,
			dryRun: dryRun,
			perPattern: perPattern,
			fromCluster: fromCluster,
			regexMode: regexMode,
			files: files,
			patterns: patterns,
			replacements: replacements,
			errExit: null
		};
		CliIo.stderr('apq strip: missing at least one --replace/--with or --delete\n');
		printStripUsage();
		return stripParseExit(EXIT_USAGE);
	}

	/**
	 * --dry-run summary: print each pattern's total match count, then
	 * warn (and return EXIT_RUNTIME) when nothing changed anywhere or
	 * when any single pattern matched 0 occurrences. EXIT_OK otherwise.
	 */
	private static function reportStripDryRun(patterns: Array<String>, patternHits: Array<Int>, anyChanged: Bool): Int {
		// Per-pattern summary first so a sweep over N files exposes
		// each pattern's match count individually. Exit non-zero
		// when ANY supplied pattern matched 0 occurrences — the
		// guard's whole purpose is to catch a typo even when a
		// sibling pattern in the same call did match. Use the
		// global zero case for a stronger error message.
		var anyZero: Bool = false;
		for (idx => pat in patterns) {
			final total: Int = patternHits[idx];
			if (total == 0) anyZero = true;
			CliIo.sysPrint('  pattern[$idx] "$pat" — $total match${total == 1 ? '' : 'es'}\n');
		}
		if (!anyChanged) {
			CliIo.stderr('apq strip: --dry-run: WARNING: no pattern matched in any file (typo? pattern bytes vs. file bytes mismatch?)\n');
			return EXIT_RUNTIME;
		}
		if (!anyZero) return EXIT_OK;
		CliIo.stderr('apq strip: --dry-run: WARNING: one or more patterns matched 0 occurrences — see per-pattern totals above\n');
		return EXIT_RUNTIME;
	}

	/**
	 * Apply the strip substitutions to every file in `o.files` via
	 * stripOneFile: dry-run defers to reportStripDryRun; otherwise each
	 * stripped file is re-parsed and PARSE OK/FAIL reported, with a
	 * no-change warning and a multi-file summary. EXIT_RUNTIME if any
	 * file failed to parse, EXIT_OK otherwise.
	 */
	private static function executeStrip(plugin: GrammarPlugin, o: StripOpts, compiledRegex: Null<Array<EReg>>): Int {
		final multi: Bool = o.files.length > 1;
		var anyFailed: Bool = false;
		var anyChanged: Bool = false;
		var passCount: Int = 0;
		var failCount: Int = 0;
		// --dry-run: track per-pattern match totals across all files so a
		// pattern that matched 0 occurrences ANYWHERE surfaces as a typo,
		// even when other patterns in the same call did match.
		final patternHits: Array<Int> = o.dryRun ? [for (_ in 0...o.patterns.length) 0] : [];
		// Narrow `Null<Array<EReg>>` to `Array<EReg>` in one place — the
		// inline `(compiledRegex : Array<EReg>)` cast does not satisfy
		// strict null safety. Empty fallback keeps the regex-mode-off
		// branch from indexing it.
		final regexes: Array<EReg> = compiledRegex ?? [];
		for (filePath in o.files) {
			final result: { changed: Bool, status: Int } = stripOneFile(plugin, o, regexes, filePath, multi, patternHits);
			if (result.changed) anyChanged = true;
			switch result.status {
				case 0:
					passCount++;
				case 1:
					failCount++;
					anyFailed = true;
				case _:
			}
		}
		if (o.dryRun) return reportStripDryRun(o.patterns, patternHits, anyChanged);
		if (!anyChanged) {
			final scope: String = multi ? 'across all ${o.files.length} files' : '';
			CliIo.stderr(
				'apq strip: WARNING: no substitution changed the source (patterns matched 0 occurrences${scope == '' ? '' : ' $scope'})\n'
			);
		}
		if (multi) {
			CliIo.sysPrint('--- $passCount PARSE OK, $failCount PARSE FAIL (total ${o.files.length}) ---\n');
		}
		return anyFailed ? EXIT_RUNTIME : EXIT_OK;
	}

	/**
	 * Apply every substitution to one file and report it: in dry-run,
	 * accumulate per-pattern hits into `patternHits` and print the
	 * WOULD CHANGE / NO MATCH line; otherwise re-parse the stripped
	 * source and print PARSE OK / PARSE FAIL. Returns whether the file
	 * changed and a status (-1 dry-run, 0 parse ok, 1 parse fail).
	 */
	private static function stripOneFile(
		plugin: GrammarPlugin, o: StripOpts, regexes: Array<EReg>, filePath: String, multi: Bool, patternHits: Array<Int>
	): { changed: Bool, status: Int } {
		final source: String = CliIo.readSourceForParse(filePath);
		var stripped: String = source;
		var fileHits: Int = 0;
		for (idx in 0...o.patterns.length) {
			if (o.dryRun) {
				final hits: Int = o.regexMode ? countRegexHits(regexes[idx], stripped) : countOccurrences(stripped, o.patterns[idx]);
				patternHits[idx] += hits;
				fileHits += hits;
			}
			stripped = o.regexMode
				? regexes[idx].replace(stripped, o.replacements[idx])
				: stripped.replace(o.patterns[idx], o.replacements[idx]);
		}
		final changed: Bool = stripped != source;
		if (o.showSource) {
			CliIo.stderr('--- stripped source (${filePath}) ---\n$stripped\n--- end ---\n');
		}
		final prefix: String = multi ? '$filePath: ' : '';
		if (o.dryRun) {
			final tag: String = fileHits > 0 ? 'WOULD CHANGE' : 'NO MATCH';
			CliIo.sysPrint('${prefix}$tag ($fileHits substitution${CliIo.plural(fileHits)})\n');
			return { changed: changed, status: -1 };
		}
		try {
			plugin.parseFile(stripped);
			CliIo.sysPrint('${prefix}PARSE OK\n');
			return { changed: changed, status: 0 };
		} catch (e: ParseError) {
			CliIo.sysPrint('${prefix}PARSE FAIL: $e\n');
			return { changed: changed, status: 1 };
		} catch (e: Exception) {
			CliIo.sysPrint('${prefix}PARSE FAIL: ${e.message}\n');
			return { changed: changed, status: 1 };
		}
	}

	/**
	 * Parse a candidate source under the plugin's file parser, returning a
	 * PARSE OK / PARSE FAIL flag plus the failure message.
	 */
	private static function stripTryParse(plugin: GrammarPlugin, s: String): { ok: Bool, msg: String } {
		return try {
			plugin.parseFile(s);
			{ ok: true, msg: '' };
		} catch (e: ParseError) {
			{ ok: false, msg: e.toString() };
		} catch (e: Exception) {
			{ ok: false, msg: e.message };
		}
	}

	/**
	 * Print the per-pattern strip verdict. Interlocking-blockers signature:
	 * combined OK + every isolated row FAIL — the slice needs N code
	 * mechanisms, not one. Otherwise report how many patterns unblock alone,
	 * or flag the no-op case where the baseline already parses.
	 */
	private static function reportStripVerdict(
		baselineOk: Bool, combinedOk: Bool, isolatedResults: Array<{ ok: Bool, hits: Int }>, patternCount: Int
	): Void {
		if (combinedOk && !baselineOk) {
			final anyIsolatedOk: Bool = isolatedResults.exists(r -> r.ok);
			if (anyIsolatedOk) {
				var soleCount: Int = 0;
				for (r in isolatedResults) if (r.ok) soleCount++;
				CliIo.sysPrint(
					'VERDICT $soleCount of $patternCount pattern${CliIo.plural(patternCount)}'
					+ ' unblock alone — the rest are redundant (or compose into a tighter slice).\n'
				);
			} else {
				CliIo.sysPrint(
					'VERDICT interlocking blockers — every pattern alone still fails; the combination is required. Slice scope likely '
					+ 'needs $patternCount separate code mechanisms.\n'
				);
			}
		} else if (!combinedOk && baselineOk) {
			CliIo.sysPrint('VERDICT no-op — baseline already parses; the strip diagnostic does not apply.\n');
		}
	}

}
