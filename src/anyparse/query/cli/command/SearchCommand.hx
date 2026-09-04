package anyparse.query.cli.command;

import anyparse.query.Matcher.Match;
import anyparse.query.cli.CliArgs;
import anyparse.query.cli.CliContext;
import anyparse.query.format.Json;
import anyparse.query.format.Text;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

/**
 * Parsed options for `apq search` — `lang`, `json`, the `kind` filter, `explain`, `flat`, `limit`, the structural `pattern`, and `inputSpecs`. `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef SearchOpts = {
	var lang: String;
	var json: Bool;
	var kind: Null<String>;
	var limit: Int;
	var explain: Bool;
	var flat: Bool;
	var pattern: Null<String>;
	var inputSpecs: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};

/**
 * `apq search` — structural pattern search.
 *
 * A multi-file WALK: the path specs go through `CliArgs`, the files through `CliWalk`,
 * and an empty result answers `ctx.emptyExit` so a script can tell "found nothing"
 * from "ran fine".
 */
@:nullSafety(Strict)
final class SearchCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'search';
	}

	public function summary(): String {
		return 'Structural pattern search';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runSearch(args, ctx);
	}

	public function usage(): Void {
		printSearchUsage();
	}

	private static inline function searchParseExit(code: Int): SearchOpts {
		return {
			lang: '',
			json: false,
			kind: null,
			limit: -1,
			explain: false,
			flat: false,
			pattern: null,
			inputSpecs: [],
			errExit: code
		};
	}

	private static function runSearch(args: Array<String>, ctx: CliContext): Int {
		final o: SearchOpts = parseSearchArgs(args);
		if (o.errExit != null) return o.errExit;
		final pattern: Null<String> = o.pattern;
		if (pattern == null) {
			CliIo.stderr('apq search: missing <pattern> argument\n');
			printSearchUsage();
			return EXIT_USAGE;
		}
		if (o.inputSpecs.length == 0) {
			CliIo.stderr('apq search: missing <file-or-dir-or-glob> argument\n');
			printSearchUsage();
			return EXIT_USAGE;
		}
		final patternStr: String = pattern;

		// DX v10: macro reification (`$v{...}` / `$i{...}` / `$a{...}` /
		// `$b{...}` / `$p{...}` / `$e{...}` / `$es{...}`) is a Haxe macro-
		// time construct, not an AST shape — the pattern parser rejects it
		// with a generic "not valid as expression" message that sends the
		// user toward search debugging instead of `lit` (the right tool
		// for literal-string lookup, where the macro-time string slot lives).
		// Detect the sigil before parsing and point at the right tool.
		final reif: Null<String> = detectMacroReification(patternStr);
		if (reif != null) {
			CliIo.stderr(
				'apq search: pattern "$patternStr" contains macro reification ($reif'
				+ ') which is a macro-time construct, not an AST shape pattern. For literal-string lookup use: apq lit \'<text>\' <files>. '
				+ 'For identifier shape patterns use a metavar `$$x` (lowercase).\n'
			);
			return EXIT_USAGE;
		}

		final plugin: GrammarPlugin = CliArgs.pickPlugin(o.lang);
		final parsed: Pattern = try plugin.parsePattern(patternStr) catch (e: Exception) {
			CliIo.stderr('apq search: pattern: ${e.message}\n');
			return EXIT_RUNTIME;
		};

		// Non-fatal: a leaf pattern (bare name / lone metavar / bare
		// literal) has no code shape — search only hits it in
		// expression position, never a decl or type. Point at the
		// right tool (kind-aware) and proceed anyway.
		//
		// Kind branches:
		//  - Metavar           — lone `$x` matches every node; refs/uses
		//                        don't apply (no name to look up).
		//  - Literal / *Lit    — literal value; `apq lit '<value>'` is
		//                        the right tool (refs/uses don't apply).
		//  - IdentExpr / other — bare identifier; refs/uses/lit all
		//                        plausible depending on intent.
		if (parsed.isDegenerate()) CliIo.stderr('${CliWalk.degenerateNudge(patternStr, parsed.root.kind)}\n');

		// A metavar the grammar does not project as a node is dropped from the
		// pattern SILENTLY, and the search then answers a wider question than the
		// one written (a `:$t` annotation, a `cast($x, $T)` target type) or, for an
		// undecodable name slot such as `@:$m`, a question nothing can answer. Say
		// which ones, so a census built on the pattern is not read as exact.
		if (parsed.ignoredMetavars.length != 0) {
			final ignored: String = 'apq search: metavariable(s) $$${parsed.ignoredMetavars.join(', $')} are not part of the parsed '
				+ 'pattern - the grammar projects no node at that position, so the search is WIDER than written (a declared type is '
				+ 'not a node; a metadata name is not decoded). Searching anyway.\n';
			CliIo.stderr(ignored);
		}

		// `--explain`: emit the parsed pattern's S-expr to stderr at
		// scan start. When 0 matches across all scanned files the
		// closing diagnostic also prints the top input-kind histogram
		// — the most common reason a structurally-valid pattern misses
		// is a kind mismatch (e.g. searching `switch $x { … }` against
		// a tree whose actual kind is `SwitchExpr`, not `Switch`).
		if (o.explain) {
			CliIo.stderr('apq search: pattern parses as:\n');
			CliIo.stderr(Text.render(parsed.root));
		}

		final expanded: ExpandedInputs = CliArgs.expandInputs(o.inputSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq search: no input files matched ${CliArgs.quotedSpecs(o.inputSpecs)}\n');
			return EXIT_RUNTIME;
		}

		final collected: Null<{
			entries: Array<{ file: String, source: String, matches: Array<Match> }>,
			kindCounts: Map<String, Int>
		}> = collectSearchEntries(paths, plugin, expanded.singleFile, parsed, o.kind, o.explain);
		if (collected == null) return EXIT_RUNTIME;
		final allEntries: Array<{ file: String, source: String, matches: Array<Match> }> = collected.entries;

		// `--explain` closing diagnostic on 0 hits: print the kind
		// histogram so the user can see whether the pattern's root
		// kind even appears in the scanned input.
		if (o.explain && allEntries.length == 0) searchExplainHistogram(parsed.root.kind, collected.kindCounts);

		var totalHits: Int = 0;
		for (e in allEntries) totalHits += e.matches.length;
		final cappedLimit: Int = CliWalk.effectiveAutoLimit('search', o.limit, totalHits);
		final shown: Array<{ file: String, source: String, matches: Array<Match> }> = CliWalk.limitEntries(
			allEntries, cappedLimit, e -> e.matches.length, (e, k) -> {file: e.file, source: e.source, matches: e.matches.slice(0, k) }
		);
		renderSearchResults(shown, o.json, o.flat);
		return ctx.emptyExit(allEntries.length == 0);
	}

	private static function perMatchJson(file: String, source: String, m: Match): String {
		// Render a single match through the macro-generated writer by
		// wrapping it in a singleton envelope, then slicing the inner
		// JSON object out. Keeps every entry typed through the same path
		// as the multi-match render — no separate stringify code.
		final rendered: String = Json.renderSearchMatches(file, source, [m]);
		// Strip the `{"matches":[` prefix and `]}\n` suffix to get the
		// bare match object for inclusion in the multi-file array.
		final inner: String = rendered.trim();
		final openIdx: Int = inner.indexOf('[');
		final closeIdx: Int = inner.lastIndexOf(']');
		return openIdx < 0 || closeIdx <= openIdx ? rendered : inner.substring(openIdx + 1, closeIdx);
	}

	private static function printSearchUsage(): Void {
		CliIo.sysPrint('Usage: apq search [options] <pattern> <file-or-dir-or-glob>\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --json              Emit JSON instead of text\n');
		CliIo.sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('  --kind <Kind>       Only match nodes of this AST kind\n');
		CliIo.sysPrint('  --explain           Print parsed pattern AST; on 0 hits show input-kind histogram\n');
		CliIo.sysPrint('  --flat              Legacy flat `file:line:col:` format (default: grouped-by-file)\n');
		CliIo.sysPrint('  --limit <n>         Stop after n hits total (default: no limit)\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint("Pattern syntax: language source with `$X` / `$_` metavars and the `...` ellipsis.\n");
		CliIo.sysPrint("  $X      — bind a subtree; reuses must match structurally.\n");
		CliIo.sysPrint("  $_      — wildcard, no binding.\n");
		CliIo.sysPrint('  ...     — any run of siblings, zero or more. Binds NOTHING.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('`...` is what makes an ANY-ARITY question one pattern instead of one per arity:\n');
		CliIo.sysPrint("  new $T(...)        every construction        f(...)      every call\n");
		CliIo.sysPrint('  [...]              every array literal       g(1, ...)   calls whose FIRST arg is 1\n');
		CliIo.sysPrint('  g(..., 1)          calls whose LAST arg is 1  g(1, ..., 1) both ends\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('The children before the `...` anchor from the left, those after it from the right,\n');
		CliIo.sysPrint('and the star absorbs the run between — so ONE per child list (two is refused).\n');
		CliIo.sysPrint('It does not bind, so `apq rewrite` refuses a `...` pattern rather than dropping\n');
		CliIo.sysPrint('the children it absorbed; `--match` (op addressing) accepts one, it only locates.\n');
		CliIo.sysPrint('A constructor keeps its type arguments and its value arguments in ONE child list,\n');
		CliIo.sysPrint("so `new $T(...)` counts `new Map<K,V>()` too — write the type args out\n");
		CliIo.sysPrint("(`new $T<$K>(...)`) when that is the question.\n");
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Use `--` before a pattern that starts with `--` (e.g. the\n');
		CliIo.sysPrint("prefix-decrement pattern `--$x`): apq search -- '--\\$x' <file>\n");
	}

	/**
	 * Increment `counts[node.kind]` for every node in the tree. Used
	 * by `apq search --explain` to build the kind histogram that
	 * surfaces "pattern's root kind is not present in input" mismatches.
	 */
	private static function tallyKinds(root: QueryNode, counts: Map<String, Int>): Void {
		function walk(n: QueryNode): Void {
			final prev: Null<Int> = counts[n.kind];
			counts[n.kind] = prev == null ? 1 : prev + 1;
			for (c in n.children) walk(c);
		}
		walk(root);
	}

	/**
	 * DX v10: detect Haxe macro reification sigils in a search pattern.
	 * `$v{}` / `$i{}` / `$a{}` / `$b{}` / `$p{}` / `$e{}` / `$es{}` are
	 * macro-time constructs; the pattern parser rejects them with a
	 * generic message that misdirects the user. Returns the matched
	 * sigil (e.g. "`$v{}`") for the error message, or null when the
	 * pattern carries none. Plain metavars `$x` (followed by letter, not
	 * `{` + reif tag) pass through.
	 */
	private static function detectMacroReification(s: String): Null<String> {
		final tags: Array<String> = ['v', 'i', 'a', 'b', 'p', 'e', 'es'];
		for (tag in tags) {
			final probe: String = '$$$tag{';
			if (s.indexOf(probe) >= 0) return '`$$$tag{...}`';
		}
		return null;
	}

	private static function parseSearchArgs(args: Array<String>): SearchOpts {
		var lang: String = 'haxe';
		var json: Bool = false;
		var kind: Null<String> = null;
		var limit: Int = -1;
		var explain: Bool = false;
		var flat: Bool = false;
		var pattern: Null<String> = null;
		final inputSpecs: Array<String> = [];

		// `--` is the standard end-of-options sentinel: every token after
		// it is positional, never an option. A search pattern can legally
		// start with `--` (`--$x` = prefix-decrement), which would
		// otherwise be rejected as an unknown option — the sentinel is the
		// only way to reach those patterns.
		var optsEnded: Bool = false;
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			var isOption: Bool = false;
			if (!optsEnded) {
				isOption = true;
				switch a {
					case '--lang':
						lang = CliArgs.expectValue(args, ++i, '--lang');
					case '--json':
						json = true;
					case '--kind':
						kind = CliArgs.expectValue(args, ++i, '--kind');
					case '--explain':
						explain = true;
					case '--flat':
						flat = true;
					case '--limit':
						try limit = CliArgs.parseLimit(args, ++i) catch (e: Exception) {
							CliIo.stderr('${e.message}\n');
							return searchParseExit(EXIT_USAGE);
						}
					case '-h', '--help':
						printSearchUsage();
						return searchParseExit(EXIT_OK);
					case '--':
						optsEnded = true;
					case _:
						if (a.startsWith('--')) {
							CliIo.stderr('apq search: unknown option "$a"\n');
							return searchParseExit(EXIT_USAGE);
						}
						isOption = false;
				}
			}
			if (!isOption) {
				if (pattern == null)
					pattern = a;
				else
					inputSpecs.push(a);
			}
			i++;
		}
		return {
			lang: lang,
			json: json,
			kind: kind,
			limit: limit,
			explain: explain,
			flat: flat,
			pattern: pattern,
			inputSpecs: inputSpecs,
			errExit: null
		};
	}

	private static function collectSearchEntries(
		paths: Array<String>, plugin: GrammarPlugin, singleFile: Bool, parsed: Pattern, kind: Null<String>, explain: Bool
	): Null<{ entries: Array<{ file: String, source: String, matches: Array<Match> }>, kindCounts: Map<String, Int> }> {
		final allEntries: Array<{ file: String, source: String, matches: Array<Match> }> = [];
		final kindCounts: Map<String, Int> = [];
		for (path in paths) {
			final source: String = CliIo.readSourceForParse(path);
			final tree: Null<QueryNode> = CliWalk.parseWalked('search', plugin.parseFile, path, source, singleFile);
			if (tree == null) {
				if (singleFile) return null;
				continue;
			}
			if (explain) tallyKinds(tree, kindCounts);
			final matches: Array<Match> = Matcher.search(parsed, tree, kind);
			if (matches.length == 0) continue;
			allEntries.push({ file: path, source: source, matches: matches });
		}
		return { entries: allEntries, kindCounts: kindCounts };
	}

	private static function searchExplainHistogram(patternKind: String, kindCounts: Map<String, Int>): Void {
		final entries: Array<{ k: String, n: Int }> = [for (k => n in kindCounts) { k: k, n: n }];
		entries.sort((a, b) -> a.n == b.n ? (a.k < b.k ? -1 : 1) : b.n - a.n);
		final topN: Int = entries.length < 12 ? entries.length : 12; // noqa: magic-number
		CliIo.stderr('apq search: 0 matches; pattern root kind is "$patternKind". Top kinds seen in input (${entries.length} distinct):\n');
		for (k in 0...topN) {
			final e: { k: String, n: Int } = entries[k];
			final marker: String = e.k == patternKind ? ' ← matches pattern root' : '';
			CliIo.stderr('  ${e.k} (${e.n})$marker\n');
		}
		if (!entries.exists(e -> e.k == patternKind))
			CliIo.stderr(
				'  (pattern root kind "$patternKind" NOT present in any scanned file — likely the wrong kind for this construct; check '
				+ '`apq ast <file>` to see the actual node shape)\n'
			);
	}

	private static function renderSearchResults(
		shown: Array<{ file: String, source: String, matches: Array<Match> }>, json: Bool, flat: Bool
	): Void {
		if (json) {
			final combined: StringBuf = new StringBuf();
			combined.add('{"matches":[');
			var first: Bool = true;
			for (entry in shown) {
				for (m in entry.matches) {
					if (!first) combined.add(',');
					first = false;
					combined.add(perMatchJson(entry.file, entry.source, m));
				}
			}
			combined.add(']}\n');
			CliIo.sysPrint(combined.toString());
		} else {
			for (entry in shown) CliIo.sysPrint(Text.renderSearchMatches(entry.file, entry.source, entry.matches, flat));
		}
	}

}
