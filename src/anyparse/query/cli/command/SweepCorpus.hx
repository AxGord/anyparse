package anyparse.query.cli.command;

import anyparse.format.comment.CommentLossException;
import anyparse.query.GrammarPlugin;
import anyparse.runtime.ParseError;
import haxe.Exception;
#if (sys || nodejs)
import sys.io.File;
#end

using StringTools;

/**
 * One fixture's census row — the same pair `bin/.last-sweep.json` records
 * in its `fixtures` array, so a snapshot written from these entries is
 * interchangeable with the corpus harness's own.
 */
typedef SweepCorpusEntry = {
	final path: String;
	final status: String;
};

/**
 * A whole-corpus census: the six counters `apq sweep` prints plus the
 * per-fixture rows `apq sweep --diff` keys on.
 */
typedef SweepCorpusResult = {
	final entries: Array<SweepCorpusEntry>;
	final pass: Int;
	final fail: Int;
	final skipParse: Int;
	final skipWrite: Int;
	final skipConfig: Int;
	final skipMalformed: Int;
};

/**
 * Re-derives the corpus census that `bin/.last-sweep.json` records —
 * `apq sweep --run`'s engine.
 *
 * The numbers `781 pass / 120 fail / 43 skip-parse` are quoted as a gate in
 * every slice of this project, and until this walker existed the ONLY thing
 * that could produce them was `node bin/test.js` under
 * `$ANYPARSE_HXFORMAT_FORK` — `apq sweep` reads that run's snapshot and
 * `apq fmt` cannot even open a `.hxtest` (it reads the whole three-section
 * file and reports `unexpected input`). A gate nothing else can re-derive is
 * one bad refactor away from being decorative.
 *
 * This is a SECOND driver over the same engine, deliberately not a shared
 * one: it walks the fixtures itself and classifies with its own code, so
 * `apq sweep --run --diff bin/.last-sweep.json` is a real cross-check of the
 * snapshot rather than a restatement of it. The predicate it reproduces is
 * `HxFormatterCorpusTest.runCategory`, step for step:
 *
 * 1. three `\n---\n` sections or `MALFORMED`;
 * 2. `disableFormatting` / `excludes` in the fixture's own config mean the
 *    fork's formatter never ran, so the expected section is empty and the
 *    writer must not run either;
 * 3. the config loads (`SKIP_CONFIG` when it does not) — probed through
 *    `layoutMetrics`, which builds the same write options the round trip
 *    would, so the failure surfaces before the parse exactly as it does in
 *    the harness;
 * 4. the input parses (`SKIP_PARSE`) and writes (`SKIP_WRITE`);
 * 5. one trailing `\n` comes off the emitted text, because `.hxtest`
 *    sections carry one `\n` of padding that the fixture reader already
 *    stripped from `expected` — without this every PASS reads as a
 *    one-byte FAIL, which is exactly what `apq writer-equals F F` did on
 *    779 of the 781 passing fixtures;
 * 6. byte equality decides `PASS` / `FAIL`.
 *
 * Two places where this driver's mechanism differs from the harness's and
 * the VERDICT still agrees, both measured over all 946 fixtures:
 * `writeRoundTrip` refuses to hand back output that dropped a comment while
 * the harness compares the lossy bytes — a refusal cannot be byte-equal to
 * an expected section that still carries the comment, so both call it
 * `FAIL` (5 fixtures; setting `APQ_ALLOW_COMMENT_LOSS` turns the refusal
 * into the plain byte-diff and does not move the count). And the harness
 * enumerates ten named subdirectories where this walks the tree, so a
 * fixture in a directory the harness does not list would show up here as an
 * `ADDED` row under `--diff` rather than silently in neither.
 */
@:nullSafety(Strict)
final class SweepCorpus {

	/** Section separator of the `.hxtest` golden-file format. */
	private static inline final SECTION_SEP: String = '\n---\n';

	private static inline final SECTION_COUNT: Int = 3;
	private static inline final STATUS_PASS: String = 'PASS';
	private static inline final STATUS_FAIL: String = 'FAIL';
	private static inline final STATUS_SKIP_PARSE: String = 'SKIP_PARSE';
	private static inline final STATUS_SKIP_WRITE: String = 'SKIP_WRITE';
	private static inline final STATUS_SKIP_CONFIG: String = 'SKIP_CONFIG';
	private static inline final STATUS_MALFORMED: String = 'MALFORMED';

	#if (sys || nodejs)
	/**
	 * Walks every `.hxtest` under `root` and returns the census. `keyRoot`
	 * is what fixture paths are reported relative to — the FORK root when
	 * `root` sits inside it, so the rows key the same way the harness's
	 * snapshot does and `--diff` can pair them.
	 */
	public static function run(plugin: GrammarPlugin, root: String, keyRoot: String): SweepCorpusResult {
		final entries: Array<SweepCorpusEntry> = ReconCommand.hxtestPathsUnder(root).map(censusRow.bind(plugin, _, keyRoot));
		return {
			entries: entries,
			pass: countOf(entries, STATUS_PASS),
			fail: countOf(entries, STATUS_FAIL),
			skipParse: countOf(entries, STATUS_SKIP_PARSE),
			skipWrite: countOf(entries, STATUS_SKIP_WRITE),
			skipConfig: countOf(entries, STATUS_SKIP_CONFIG),
			skipMalformed: countOf(entries, STATUS_MALFORMED)
		};
	}

	/**
	 * The fork root when `root` lies under it, else `root` itself — the
	 * prefix fixture rows are reported relative to.
	 */
	public static function keyRootFor(root: String): String {
		final fork: Null<String> = Sys.getEnv('ANYPARSE_HXFORMAT_FORK');
		return fork != null && fork.length > 0 && root.startsWith('$fork/') ? fork : root;
	}

	/** One fixture's row: its key relative to `keyRoot`, and the verdict `classify` reaches. */
	private static function censusRow(plugin: GrammarPlugin, path: String, keyRoot: String): SweepCorpusEntry {
		final relPath: String = ReconCommand.stripRootPrefix(path, keyRoot);
		return { path: relPath, status: classify(plugin, path, relPath) };
	}

	private static function countOf(entries: Array<SweepCorpusEntry>, status: String): Int {
		var n: Int = 0;
		for (entry in entries) if (entry.status == status) n++;
		return n;
	}


	private static function classify(plugin: GrammarPlugin, path: String, relPath: String): String {
		final content: String = File.getContent(path);
		final parts: Array<String> = content.split(SECTION_SEP);
		if (parts.length != SECTION_COUNT) return STATUS_MALFORMED;
		final config: String = parts[0].trim();
		final input: String = stripPadNewlines(parts[1]);
		final expected: String = stripPadNewlines(parts[2]);
		if (formatterDisabled(config, relPath)) return expected == '' ? STATUS_PASS : STATUS_FAIL;
		try
			plugin.layoutMetrics(config)
		catch (_: Exception)
			return STATUS_SKIP_CONFIG;
		final emitted: Null<String> = try plugin.writeRoundTrip(input, config) catch (_: ParseError) return STATUS_SKIP_PARSE
		catch (_: CommentLossException) return STATUS_FAIL
		catch (_: Exception) return STATUS_SKIP_WRITE;
		if (emitted == null) return STATUS_SKIP_WRITE;
		final text: String = (emitted: String);
		final actual: String = text.length > 0 && text.fastCodeAt(text.length - 1) == '\n'.code ? text.substr(0, text.length - 1) : text;
		return actual == expected ? STATUS_PASS : STATUS_FAIL;
	}

	/**
	 * The fork's two driver-level meta-config keys: `disableFormatting`
	 * turns the formatter off for the fixture, `excludes` lists fork-rooted
	 * paths it must not touch. Neither maps to a write option — both mean
	 * the expected section is empty because nothing ran.
	 */
	private static function formatterDisabled(config: String, relPath: String): Bool {
		try {
			final obj: Dynamic = haxe.Json.parse(config);
			if (Reflect.field(obj, 'disableFormatting') == true) return true;
			final raw: Dynamic = Reflect.field(obj, 'excludes');
			if (Std.isOfType(raw, Array)) {
				final list: Array<Dynamic> = raw;
				for (item in list) if (Std.isOfType(item, String) && (item: String) == relPath) return true;
			}
		} catch (_: Exception) {/* malformed config JSON — the SKIP_CONFIG probe reports it */}
		return false;
	}

	/** Drops the one leading and one trailing `\n` each `.hxtest` section is padded with. */
	private static function stripPadNewlines(s: String): String {
		var r: String = s;
		if (r.length > 0 && r.charAt(0) == '\n') r = r.substr(1);
		return r.length > 0 && r.charAt(r.length - 1) == '\n' ? r.substr(0, r.length - 1) : r;
	}
	#end

}
