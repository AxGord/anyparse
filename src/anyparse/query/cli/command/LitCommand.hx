package anyparse.query.cli.command;

import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.Lit.LitHit;
import anyparse.query.Matcher.Match;
import anyparse.query.cli.CliContext;
import anyparse.query.cli.CliWalk;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

/**
 * Parsed options for `apq lit` — `lang`, the `exact` / `kindFilter` / `includeComments` / `includeDirectives` match controls, the `target` literal, `flat`, `limit`, and `inputSpecs`. `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef LitOpts = {
	var lang: String;
	var exact: Bool;
	var flat: Bool;
	var limit: Int;
	var kindFilter: Null<Array<String>>;
	var includeComments: Bool;
	var includeDirectives: Bool;
	var target: Null<String>;
	var inputSpecs: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};

/**
 * `apq lit` — leaf-name probe (string literals, identifiers — prose-in-code).
 *
 * A multi-file WALK: the path specs go through `CliArgs`, the files through `CliWalk`,
 * and an empty result answers `ctx.emptyExit` so a script can tell "found nothing"
 * from "ran fine".
 */
@:nullSafety(Strict)
final class LitCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'lit';
	}

	public function summary(): String {
		return 'Leaf-name probe (string literals, identifiers — prose-in-code)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runLit(args, ctx);
	}

	public function usage(): Void {
		printLitUsage();
	}

	private static inline function litParseExit(code: Int): LitOpts {
		return {
			lang: '',
			exact: false,
			flat: false,
			limit: -1,
			kindFilter: null,
			includeComments: false,
			includeDirectives: false,
			target: null,
			inputSpecs: [],
			errExit: code
		};
	}

	/**
	 * `apq lit <text> <file-or-dir-or-glob>...` — leaf-name probe over
	 * the parsed AST. Default kind filter `Literal` catches every
	 * string-literal occurrence (the leaf inside `SingleStringExpr`
	 * / `DoubleStringExpr` / `RawString`); pass `--kind <K1,K2>` to
	 * widen (e.g. `Literal,IdentExpr`) or override.
	 *
	 * The structural alternative to `# HXQ_OK:prose`-escaped grep for
	 * annotation-key / config-string lookups inside parseable `.hx`.
	 * Skips comments and string interpolations as a side effect of
	 * routing through the parser — no false positives from prose
	 * inside doc-comments or `'$ident'` interpolation segments.
	 */
	private static function runLit(args: Array<String>, ctx: CliContext): Int {
		final o: LitOpts = parseLitArgs(args);
		if (o.errExit != null) return o.errExit;
		final target: Null<String> = o.target;
		if (target == null) {
			CliIo.stderr('apq lit: missing <text> argument\n');
			printLitUsage();
			return EXIT_USAGE;
		}
		if (o.inputSpecs.length == 0) {
			CliIo.stderr('apq lit: missing <file-or-dir-or-glob> argument\n');
			printLitUsage();
			return EXIT_USAGE;
		}
		final targetStr: String = target;
		final kindFilter: Null<Array<String>> = o.kindFilter;
		// Resolve smart-default kind filter from <text> shape:
		// `trailOptShapeGate` / `MAX_LEN` / `endsWith_close_brace` look like
		// identifiers, the default `Literal`-only would silently miss the
		// `IdentExpr` / field-name leaves and force a re-run with
		// `--kind Literal,IdentExpr` or `--any-kind`. Promote the default
		// to `Literal,IdentExpr` for queries whose shape is unambiguously
		// an identifier (camelCase: mixed-case letters; snake_case:
		// contains `_` plus letters). Pure-lowercase / all-uppercase single
		// words stay `Literal`-only — they ambiguously match string content
		// and an `IdentExpr` widening would add noise (e.g. `hxq lit 'foo'`
		// inside a corpus of strings).
		final effectiveKindFilter: Array<String> = kindFilter ?? (
			CliWalk.looksLikeMixedIdentifier(targetStr) ? ['Literal', 'IdentExpr'] : ['Literal']
		);
		// Comment scan fires when the user explicitly opted in (`--include-comments`),
		// when the kind filter is the catch-all (`--any-kind` ⇒ empty array),
		// or when `Comment` appears in an explicit `--kind` list. The
		// default kind filter (smart-resolved Literal or Literal+IdentExpr)
		// deliberately stays comment-free — silent `--include-comments`-by-
		// default would flood doc-comment-heavy queries with noise.
		final scanComments: Bool = o.includeComments || (kindFilter != null && kindFilter.length == 0)
			|| effectiveKindFilter.contains('Comment');
		// Directive scan is OPT-IN ONLY: `--include-directives`, or `Directive` named in an
		// explicit `--kind`. Unlike the comment scan it deliberately does NOT ride `--any-kind` —
		// directive lines are hit surface no `lit` query has ever returned, and widening a flag
		// that already ships would change what an existing query prints.
		final scanDirectives: Bool = o.includeDirectives || (kindFilter != null && kindFilter.contains('Directive'));
		// `lit` matches DECODED literal values; the raw file holds the
		// ESCAPED form, so a raw-substring pre-filter can false-negative
		// when the searched key carries a backslash. Opt the pre-filter OUT
		// for backslash-bearing keys; for plain keys the decoded value and
		// the raw bytes coincide, so the pre-filter is safe.
		final litPrefilterKey: Null<String> = targetStr.indexOf('\\') < 0 ? targetStr : null;

		final io = CliArgs.resolveInputPaths(o.lang, o.inputSpecs);
		final paths: Array<String> = io.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq lit: no input files matched ${CliArgs.quotedSpecs(o.inputSpecs)}\n');
			return EXIT_RUNTIME;
		}
		final plugin: GrammarPlugin = io.plugin;

		final skipEntries: Array<SkipEntry> = [];
		final collected: Null<{
			entries: Array<{ file: String, source: String, hits: Array<LitHit> }>,
			autoWidened: Bool
		}> = collectLitEntries(paths, plugin, io.singleFile, skipEntries, {
			target: targetStr,
			exact: o.exact,
			kinds: effectiveKindFilter,
			kindWasDefault: kindFilter == null,
			scanComments: scanComments,
			scanDirectives: scanDirectives,
			prefilterKey: litPrefilterKey
		});
		if (collected == null) return EXIT_RUNTIME;
		final allEntries: Array<{ file: String, source: String, hits: Array<LitHit> }> = collected.entries;

		if (allEntries.length == 0) {
			// DX v10: regex-like query → emit the regex-not-supported note
			// BEFORE the generic walker nudge. The generic nudge's dotted-
			// access heuristic mis-fires on patterns like `foo\|bar` and
			// sends the user toward `search '$x.field'`, which is wrong.
			final regexLabel: Null<String> = looksLikeRegex(targetStr);
			CliIo.stderr(
				regexLabel != null
					? 'apq lit: NOTE "$targetStr" looks like a regex (contains $regexLabel) — lit is substring-only. Run separate lit '
						+ 'calls per alternative, or use apq refs / apq uses / apq search for shape-aware lookup.\n'
					: '${CliWalk.emptyWalkerNudge('lit', targetStr, paths.length, paths.length - skipEntries.length, skipEntries, null)}\n'
			);
		} else if (collected.autoWidened) {
			final tried: String = effectiveKindFilter.join(',');
			CliIo.stderr(
				'apq lit: NOTE auto-widened to --any-kind (default kind=$tried'
				+ ' returned 0 hits). Pass `--any-kind` explicitly to silence this notice.\n'
			);
		}

		var totalHits: Int = 0;
		for (e in allEntries) totalHits += e.hits.length;
		final cappedLimit: Int = CliWalk.effectiveAutoLimit('lit', o.limit, totalHits);
		final shown: Array<{ file: String, source: String, hits: Array<LitHit> }> = CliWalk.limitEntries(
			allEntries, cappedLimit, e -> e.hits.length, (e, k) -> {file: e.file, source: e.source, hits: e.hits.slice(0, k) }
		);
		for (entry in shown) CliIo.sysPrint(Lit.render(entry.file, entry.source, entry.hits, o.flat));
		return ctx.emptyExit(allEntries.length == 0);
	}

	/**
	 * Comment lexer — scans `source` for C-style line comments (`//…`) and
	 * block comments (slash-star and slash-star-star doc forms), filters
	 * by `target`, and appends each match as a `Comment`-kind `LitHit`
	 * to `out`. Captured text is the comment BODY, not including the
	 * delimiters: a `//foo` line yields a body of `foo` (with any leading
	 * space the source happened to carry); a slash-star block yields
	 * everything between the open and close. Substring match by default;
	 * `exact=true` requires `body == target`.
	 *
	 * The lexer is string-literal-aware — `"…"` / `'…'` regions are
	 * skipped so a `//` inside a string does not start a comment match,
	 * and backslash-escaped quotes inside strings stay quoted. The lexer
	 * is grammar-agnostic for C-style comment syntax (Haxe, C/C++, Java,
	 * JavaScript/TypeScript, Rust, Go, Swift, …). Languages with different
	 * comment delimiters (Python `#`, SQL `--`, Lisp `;`) need a plugin-
	 * supplied scanner — deferred until a non-C-style grammar lands.
	 *
	 * UTF-16 unit indexing matches `Span`'s `from`/`to` convention so the
	 * rendered `line:col` resolves via the standard `Span.lineCol(source)`
	 * call without any conversion.
	 */
	private static function appendCommentHits(
		target: String, source: String, exact: Bool, out: Array<LitHit>, regions: Array<LexRegion>
	): Void {
		for (tok in RefactorSupport.collectCommentTokens(regions)) {
			final bodySpan: Span = RefactorSupport.commentBody(source, tok);
			final body: String = source.substring(bodySpan.from, bodySpan.to);
			final match: Bool = exact ? body == target : body.indexOf(target) >= 0;
			if (match) out.push(new LitHit('Comment', body, new Span(tok.from, tok.to)));
		}
	}

	/**
	 * Directive lexer — appends every conditional-compilation directive of `source` whose text
	 * matches `target` as a `Directive`-kind `LitHit`. Captured text is the directive itself
	 * (`#if (sys)`, `#elseif js`, `#end`) and never the code that follows it on an inline
	 * region's line; the span starts at the `#`, so the rendered `line:col` is the directive's
	 * own. Substring match by default; `exact=true` requires the whole directive text.
	 *
	 * The condition is neither a captured leaf nor a node — it survives only as trivia on the
	 * directive line — so before this scan `apq lit` could not reach it at all and the documented
	 * route was `# HXQ_OK:prose`-escaped grep. The scan shares `CondDirectives` with the
	 * `redundant-condcomp-parens` check (one directive reader, two consumers), so the keyword
	 * vocabulary comes from the grammar and a `#if` written inside a comment, a string or a regex
	 * is not a hit.
	 */
	private static function appendDirectiveHits(
		target: String, source: String, exact: Bool, plugin: GrammarPlugin, out: Array<LitHit>
	): Void {
		for (directive in CondDirectives.scan(source, plugin.refShape(), plugin.lexicalRegions.bind(source))) {
			final text: String = CondDirectives.text(source, directive);
			final match: Bool = exact ? text == target : text.indexOf(target) >= 0;
			if (match) out.push(new LitHit('Directive', text, directive.span));
		}
	}

	private static function printLitUsage(): Void {
		CliIo.sysPrint('Usage: apq lit [options] <text> <file-or-dir-or-glob>...\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --exact              Require exact string equality (default: substring)\n');
		CliIo.sysPrint('  --kind <K1,K2,...>   Restrict to leaves of these kinds (default: shape-based, see below)\n');
		CliIo.sysPrint('                       The synthetic kind `Comment` triggers a comment-only\n');
		CliIo.sysPrint('                       scan (no AST walk) — `--kind Comment` searches `//…`\n');
		CliIo.sysPrint('                       and `/* … */` bodies only.\n');
		CliIo.sysPrint('  --any-kind           Match every named leaf regardless of kind (also\n');
		CliIo.sysPrint('                       scans comments).\n');
		CliIo.sysPrint('  --include-comments   Scan source comments ALONGSIDE the AST walk. Sugar\n');
		CliIo.sysPrint('                       for "default kinds AS-IS, plus Comment" — keeps the\n');
		CliIo.sysPrint('                       smart-default `--kind` resolution and adds comment\n');
		CliIo.sysPrint('                       bodies. Use when the same text may live in either a\n');
		CliIo.sysPrint('                       string literal or a `//`/`/**` comment (TODO/FIXME\n');
		CliIo.sysPrint('                       hunts, doc-keyword cross-checks). Comments are\n');
		CliIo.sysPrint('                       string-literal-aware: `//` inside `"…"`/`\'…\'` is\n');
		CliIo.sysPrint('                       not a comment.\n');
		CliIo.sysPrint('  --include-directives Scan conditional-compilation DIRECTIVES alongside the AST\n');
		CliIo.sysPrint('                       walk — `#if (sys)`, `#elseif js`, `#end`. The condition is\n');
		CliIo.sysPrint('                       neither a literal leaf nor a node, so no other kind filter\n');
		CliIo.sysPrint('                       reaches it. OPT-IN ONLY: unlike --include-comments it does\n');
		CliIo.sysPrint('                       NOT ride --any-kind, so every existing query keeps exactly\n');
		CliIo.sysPrint('                       the hits it returns today. The synthetic kind `Directive`\n');
		CliIo.sysPrint('                       in --kind scans directives ONLY.\n');
		CliIo.sysPrint('  --flat               Legacy flat `file:line:col:` format (default: grouped-by-file)\n');
		CliIo.sysPrint('  --limit <n>          Stop after n hits total (default: no limit)\n');
		CliIo.sysPrint('  --lang <name>        Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Walks parsed AST for leaf nodes whose `name` slot matches <text>.\n');
		CliIo.sysPrint('Smart-default --kind: when <text> is camelCase / snake_case the\n');
		CliIo.sysPrint('default widens to `Literal,IdentExpr` (clearly an identifier query —\n');
		CliIo.sysPrint('`hxq lit trailOptShapeGate src/` finds both literals and identifier\n');
		CliIo.sysPrint('references without a re-run). Pure-lowercase / all-uppercase single\n');
		CliIo.sysPrint('words stay `Literal`-only — they ambiguously match string content and\n');
		CliIo.sysPrint('identifier widening would flood prose hits. Override with --kind /\n');
		CliIo.sysPrint('--any-kind. AST kinds skip comments and string interpolation by routing\n');
		CliIo.sysPrint('through the parser; `--include-comments` / `--kind Comment` re-enables\n');
		CliIo.sysPrint('them via a separate string-literal-aware scan over the raw source.\n');
		CliIo.sysPrint('Directive lines need `--include-directives` / `--kind Directive`; the\n');
		CliIo.sysPrint('matched text is the directive itself (keyword plus condition), never the\n');
		CliIo.sysPrint('code that follows it on a single-line `#if … #end` region.\n');
	}

	/**
	 * Heuristic: does the query look like a dotted member access
	 * (`TypeName.method`, `obj.field`, `pkg.Module.entry`)? A single `.`
	 * or `..` separator between identifier-shaped segments. Used by the
	 * 0-hit nudge on `lit` / `refs` / `uses`: a dotted name is never a
	 * leaf-name, value-binding, or type-position match — it's a Call /
	 * FieldAccess shape, the structural answer is `apq search`.
	 *
	 * Returns the split segments when the query qualifies, null otherwise.
	 * Each segment must be a non-empty identifier (`[A-Za-z_][A-Za-z0-9_]*`)
	 * and total segment count must be ≥ 2.
	 * DX v10: detect regex-like queries handed to `lit`. `lit` is
	 * substring-only; users who reach for `\|` (regex alternation),
	 * `[^...]` (character class negation), or `(?:...)` (non-capturing
	 * group) typically have a regex mental model and end up confused
	 * when the default 0-hit nudge talks about dotted access. Returns
	 * a short label describing what was detected, or null when the
	 * query carries no regex-specific syntax. Plain `?`, `*`, `[`, `]`
	 * are common in identifiers/globs and do NOT trip the heuristic
	 * alone — only the genuinely regex-only forms.
	 */
	private static function looksLikeRegex(s: String): Null<String> {
		return if (s.indexOf('\\|') >= 0)
			'`\\|` (regex alternation)'
		else if (s.indexOf('[^') >= 0)
			'`[^...]` (negated character class)'
		else if (s.indexOf('(?:') >= 0)
			'`(?:...)` (non-capturing group)'
		else if (s.indexOf('(?=') >= 0)
			'`(?=...)` (lookahead)'
		else if (s.indexOf('(?!') >= 0)
			'`(?!...)` (negative lookahead)'
		else
			null;
	}

	private static function parseLitArgs(args: Array<String>): LitOpts {
		var lang: String = 'haxe';
		var exact: Bool = false;
		var flat: Bool = false;
		var limit: Int = -1;
		var kindFilter: Null<Array<String>> = null;
		var includeComments: Bool = false;
		var includeDirectives: Bool = false;
		var target: Null<String> = null;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--exact':
					exact = true;
				case '--kind':
					kindFilter = CliArgs.expectValue(args, ++i, '--kind').split(',');
				case '--any-kind':
					kindFilter = [];
				case '--include-comments':
					includeComments = true;
				case '--include-directives':
					includeDirectives = true;
				case '--flat':
					flat = true;
				case '--limit':
					try limit = CliArgs.parseLimit(args, ++i) catch (e: Exception) {
						CliIo.stderr('${e.message}\n');
						return litParseExit(EXIT_USAGE);
					}
				case '-h', '--help':
					printLitUsage();
					return litParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq lit: unknown option "$a"\n');
						return litParseExit(EXIT_USAGE);
					}
					if (target == null)
						target = a;
					else
						inputSpecs.push(a);
			}
			i++;
		}
		return {
			lang: lang,
			exact: exact,
			flat: flat,
			limit: limit,
			kindFilter: kindFilter,
			includeComments: includeComments,
			includeDirectives: includeDirectives,
			target: target,
			inputSpecs: inputSpecs,
			errExit: null
		};
	}

	private static function collectLitEntries(
		paths: Array<String>, plugin: GrammarPlugin, singleFile: Bool, skipEntries: Array<SkipEntry>, query: {
			target: String,
			exact: Bool,
			kinds: Array<String>,
			kindWasDefault: Bool,
			scanComments: Bool,
			scanDirectives: Bool,
			prefilterKey: Null<String>
		}
	): Null<{ entries: Array<{ file: String, source: String, hits: Array<LitHit> }>, autoWidened: Bool }> {
		final allEntries: Array<{ file: String, source: String, hits: Array<LitHit> }> = [];
		// Cache parsed trees so the auto-widen retry path doesn't reparse.
		final trees: Array<{ path: String, source: String, tree: QueryNode }> = [];
		var scanned: Int = 0;
		for (path in paths) {
			final source: String = CliIo.readSourceForParse(path);
			final tree: Null<QueryNode> = CliWalk.parseWalked(
				'lit', plugin.parseFile, path, source, singleFile, skipEntries, query.prefilterKey
			);
			CliIo.streamProgress('lit', ++scanned, paths.length, singleFile);
			if (tree == null) {
				if (singleFile) return null;
				continue;
			}
			trees.push({ path: path, source: source, tree: tree });
			final hits: Array<LitHit> = Lit.find(query.target, tree, query.exact, query.kinds);
			if (query.scanComments) appendCommentHits(query.target, source, query.exact, hits, plugin.lexicalRegions(source));
			if (query.scanDirectives) appendDirectiveHits(query.target, source, query.exact, plugin, hits);
			if (hits.length == 0) continue;
			// AST walk emits in depth-first source order; comment and directive
			// hits are appended after. Sort by span.from so the rendered file
			// group stays in source order regardless of which pass produced the hit.
			if (query.scanComments || query.scanDirectives) hits.sort((a, b) -> a.span.from - b.span.from);
			allEntries.push({ file: path, source: source, hits: hits });
		}

		// Auto-widen on 0-hit when kind was the smart-default (user didn't
		// pass --kind / --any-kind). Retry with --any-kind; if THAT finds
		// hits, flag autoWidened so the caller emits a note. Common case:
		// CamelCase TypeName queries that live as `ImportDecl` / `NewExpr`
		// only — default kind set misses both. Silent on real 0-hits.
		var autoWidened: Bool = false;
		if (allEntries.length == 0 && query.kindWasDefault) {
			for (entry in trees) {
				final hits: Array<LitHit> = Lit.find(query.target, entry.tree, query.exact, []);
				if (hits.length == 0) continue;
				allEntries.push({ file: entry.path, source: entry.source, hits: hits });
			}
			if (allEntries.length > 0) autoWidened = true;
		}
		return { entries: allEntries, autoWidened: autoWidened };
	}

}
