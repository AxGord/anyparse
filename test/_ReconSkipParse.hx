import haxe.Exception;
import sys.FileSystem;
import unit.HxFormatterCorpusHelpers;
import unit.HxFormatterCorpusHelpers.HxTestCase;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span.Position;

/**
 * Throwaway recon for the Phase 3 skip-parse drill campaign (plan
 * rosy-coalescing-clarke, step B1).
 *
 * Now that the parser carries a farthest-failure tracker
 * (`Parser.maxFailPos`/`maxFailExpected`, re-surfaced by the public
 * entry), `ParseError.span.from` points at the innermost blocker
 * instead of the module head. This recon keys its histogram on the
 * deepest `expected` terminal and prints `bucket/name :: L:C
 * expected=… :: <source window at the locus>` so misses cluster by
 * the actual stuck construct, not "expected HxDecl @file-head".
 * Member-bisect a cluster with `hxq`. NOT part of RunTests; delete
 * after recon.
 *
 * Build/run:
 *   haxe -cp src -cp test -lib hxnodejs -main _ReconSkipParse -js /tmp/recon.js
 *   ANYPARSE_HXFORMAT_FORK=/Users/axg/dev/libs/haxe-formatter node /tmp/recon.js
 */
typedef ReconCluster = {
	var count: Int;
	var examples: Array<String>;
	var rawSample: String;
};

// Deliberate recon fixture: the leading-underscore type name mirrors a skip-parse
// probe subject and is intentional, not a real naming-convention violation.
final class _ReconSkipParse { // noqa: naming

	private static final forceBuildParser: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final SUBDIRS: Array<String> = [
		'sameline', 'whitespace', 'indentation',        'wrapping', 'emptylines',
		'lineends',      'other', 'formatrange', 'expressionlevel',    'missing',
	];
	private static inline final HXTEST_EXT: String = '.hxtest';
	private static inline final HEAD_LEN: Int = 70;
	private static inline final LOCUS_LEN: Int = 20;
	private static inline final TOP_N_DEFAULT: Int = 30;
	private static inline final EXAMPLES_PER_CLUSTER: Int = 2;

	// Recon driver: the dense arg-parse + per-bucket sweep loop is intentional for a
	// throwaway fixture, so the elevated cyclomatic complexity is accepted here.
	public static function main(): Void { // noqa: complexity
		final args: Array<String> = Sys.args();
		// Parse args: `--top N` / `--all` are flags for sweep-mode; any
		// non-flag arg is the single-file probe path.
		var topN: Int = TOP_N_DEFAULT;
		var probePath: Null<String> = null;
		{
			var i: Int = 0;
			while (i < args.length) {
				final a: String = args[i];
				switch a {
					case '--top':
						if (i + 1 < args.length) {
							final v: Null<Int> = Std.parseInt(args[i + 1]);
							if (v != null && v > 0) topN = v;
							i++;
						}
					case '--all':
						topN = 999999;
					case _:
						if (!StringTools.startsWith(a, '--') && probePath == null) probePath = a;
				}
				i++;
			}
		}
		if (probePath != null) {
			probeFile(probePath);
			return;
		}
		final root: Null<String> = HxFormatterCorpusHelpers.forkRoot();
		if (root == null) {
			Sys.println('RECON: ANYPARSE_HXFORMAT_FORK env var unset or points at a missing dir — abort.');
			Sys.println('  set it to the haxe-formatter fork checkout containing test/testcases/, e.g.:');
			Sys.println('    ANYPARSE_HXFORMAT_FORK=/path/to/haxe-formatter node /tmp/recon.js');
			Sys.println('  rebuild after a grammar edit with:');
			Sys.println('    haxe recon.hxml');
			return;
		}
		final clusters: Map<String, ReconCluster> = [];
		var total: Int = 0;
		for (bucket in SUBDIRS) {
			final dir: String = '$root/test/testcases/$bucket';
			if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir)) continue;
			final names: Array<String> = FileSystem.readDirectory(dir);
			names.sort((a: String, b: String) -> a < b ? -1 : (a > b ? 1 : 0));
			for (name in names) if (StringTools.endsWith(name, HXTEST_EXT)) {
				final tc: Null<HxTestCase> = HxFormatterCorpusHelpers.readHxTest('$dir/$name');
				if (tc == null) continue;
				try {
					HaxeModuleTriviaParser.parse(tc.input);
				} catch (exception: ParseError) {
					total++;
					final pos: Position = exception.span.lineCol(tc.input);
					final exp: String = normalize(exception.expected);
					final src: String = normalize(snippet(tc.input, exception.span.from));
					final rawLocus: String = rawLocus(tc.input, exception.span.from);
					final key: String = normalizeLocus(rawLocus);
					addCluster(clusters, key, '$bucket/$name', rawLocus);
					Sys.println('SKIP $bucket/$name :: ${pos.line}:${pos.col} expected="$exp" :: src="$src"');
				} catch (exception: Exception) {
					total++;
					final key: String = '<non-ParseError> ' + normalize(exception.message);
					addCluster(clusters, key, '$bucket/$name', '<exception>');
					Sys.println('SKIP $bucket/$name :: $key :: head="${head(tc.input)}"');
				}
			}
		}
		// Sort by count descending, take top N. Cluster key = normalized
		// forward-locus from the fail position (identifiers > 4 chars
		// collapsed to `_`, keywords ≤ 4 kept verbatim) — `final ?<id>`
		// shapes from N different files cluster into ONE bucket, not N.
		// `expected="…"` (almost always `//`) is dropped: the parser's
		// expected-terminator carousel is uninformative; the locus IS
		// the construct the parser couldn't consume.
		final entries: Array<{ key: String, cluster: ReconCluster }> = [
			for (k => v in clusters) { key: k, cluster: v }
		];
		entries.sort((a, b) -> b.cluster.count - a.cluster.count);
		final shown: Int = entries.length > topN ? topN : entries.length;
		Sys.println('');
		Sys.println(
			'--- skip-parse construct-locus histogram (total $total, showing top $shown of ${entries.length}; --all overrides) ---'
		);
		for (idx in 0...shown) {
			final entry = entries[idx];
			final c: ReconCluster = entry.cluster;
			final examplesStr: String = c.examples.length == 1 ? c.examples[0] : c.examples.join(', ');
			final raw: String = normalize(c.rawSample);
			Sys.println('  ${c.count}× "${entry.key}"  e.g. "${raw}"  in: $examplesStr');
		}
		if (entries.length > shown) Sys.println('  … (${entries.length - shown} more, use --top N or --all to see)');
	}

	private static function addCluster(map: Map<String, ReconCluster>, key: String, file: String, rawLocus: String): Void {
		final prev: Null<ReconCluster> = map[key];
		if (prev == null) {
			map[key] = { count: 1, examples: [file], rawSample: rawLocus };
		} else {
			prev.count++;
			if (prev.examples.length < EXAMPLES_PER_CLUSTER) prev.examples.push(file);
		}
	}

	/**
	 * Raw forward locus — `LOCUS_LEN` chars starting AT the fail position.
	 * Used both as the cluster's raw sample (display) and as input to the
	 * normalizer (cluster key).
	 */
	private static function rawLocus(input: String, offset: Int): String {
		final start: Int = offset > input.length ? input.length : offset;
		final end: Int = start + LOCUS_LEN > input.length ? input.length : start + LOCUS_LEN;
		return input.substring(start, end);
	}

	/**
	 * Normalize the forward locus into a cluster key — identifier runs of
	 * length > 4 collapse to `_`, shorter runs (Haxe short keywords
	 * `var`, `is`, `as`, `in`, `for`, `try`, `new`, `if`, `else`, `case`,
	 * etc.) are kept verbatim so they remain visible in the histogram.
	 * Punctuation, operators, and whitespace pass through unchanged; the
	 * existing `normalize` then escapes whitespace for one-line display.
	 */
	private static function normalizeLocus(raw: String): String {
		final buf: StringBuf = new StringBuf();
		var i: Int = 0;
		while (i < raw.length) {
			final c: Int = StringTools.fastCodeAt(raw, i);
			final isIdStart: Bool = (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || c == '_'.code;
			if (isIdStart) {
				var j: Int = i + 1;
				while (j < raw.length) {
					final cj: Int = StringTools.fastCodeAt(raw, j);
					final isIdCont: Bool = (cj >= 'a'.code && cj <= 'z'.code) || (cj >= 'A'.code && cj <= 'Z'.code)
						|| (cj >= '0'.code && cj <= '9'.code) || cj == '_'.code;
					if (!isIdCont) break;
					j++;
				}
				final identLen: Int = j - i;
				if (identLen > 4)
					buf.add('_');
				else
					for (k in i ... j) buf.addChar(StringTools.fastCodeAt(raw, k));
				i = j;
			} else {
				buf.addChar(c);
				i++;
			}
		}
		return normalize(buf.toString());
	}

	private static function probeFile(path: String): Void {
		final src: String = StringTools.endsWith(path, HXTEST_EXT) ? {
			final tc: Null<HxTestCase> = HxFormatterCorpusHelpers.readHxTest(path);
			tc == null ? '' : tc.input;
		} : sys.io.File.getContent(path);
		try {
			HaxeModuleTriviaParser.parse(src);
			Sys.println('PARSE OK');
		} catch (exception: ParseError) {
			final pos: Position = exception.span.lineCol(src);
			Sys.println('PARSE FAIL :: ${pos.line}:${pos.col} expected="${normalize(exception.expected)}" :: src="${normalize(snippet(src, exception.span.from))}"');
		} catch (exception: Exception) {
			Sys.println('PARSE FAIL :: <non-ParseError> ${normalize(exception.message)}');
		}
	}

	/**
	 * Source window of `HEAD_LEN` characters centred on `offset` — the
	 * text around the farthest-failure locus, for construct clustering.
	 */
	private static function snippet(input: String, offset: Int): String {
		final half: Int = Std.int(HEAD_LEN / 2);
		final centre: Int = offset > input.length ? input.length : offset;
		final start: Int = centre - half < 0 ? 0 : centre - half;
		final end: Int = centre + half > input.length ? input.length : centre + half;
		return input.substring(start, end);
	}

	private static function normalize(message: Null<String>): String {
		if (message == null || message == '') return '<no message>';
		return StringTools.replace(StringTools.replace(message, '\n', '\\n'), '\t', '\\t');
	}

	private static function head(input: String): String {
		final cut: String = input.length > HEAD_LEN ? input.substr(0, HEAD_LEN) : input;
		return StringTools.replace(StringTools.replace(cut, '\n', '\\n'), '\t', '\\t');
	}

}
