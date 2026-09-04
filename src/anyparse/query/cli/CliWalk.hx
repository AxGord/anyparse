package anyparse.query.cli;

using StringTools;
using Lambda;

import anyparse.query.cli.CliWalk.SkipEntry;
import anyparse.runtime.EditDistance;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;
#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * The shared multi-file walk of the read-only `apq` commands: parse a visited
 * file or record why it was skipped, cap how many hits are rendered, and build
 * the nudge a 0-hit walk prints instead of staying silent.
 *
 * `refs`, `uses`, `meta`, `blast`, `lit`, `mentions`, `cases`, `search`,
 * `symbols`, `importers` and `declares` all walk the same way; the walk was
 * never a per-command concern, only a per-command copy of the same calls.
 *
 * Every member is a pure function of its arguments — the walk keeps no state
 * between files beyond what the caller passes in.
 */
@:nullSafety(Strict)
final class CliWalk {

	public static inline final SKIP_PATHS_SHOWN: Int = 5;

	private static inline final FUZZY_MAX_DIST: Int = 3;
	private static inline final FUZZY_TOP_K: Int = 3;

	/**
	 * Substring "did you mean" — `query` ≥ this length OR the substring
	 * pre-filter is skipped (avoids `Hx` matching every grammar type).
	 */
	private static inline final FUZZY_SUBSTRING_MIN_QUERY: Int = 4;

	/**
	 * Substring "did you mean" — candidate's extra char count over
	 * `query.length` must not exceed this (avoids `Foo` matching a huge
	 * `FooSomeReallyLongName` and crowding out true neighbours).
	 */
	private static inline final FUZZY_SUBSTRING_MAX_EXTRA: Int = 8;

	private static inline final AUTO_LIMIT_THRESHOLD: Int = 500;

	/**
	 * Keep at most `limit` hits total across the per-file entries,
	 * truncating the entry that crosses the budget and dropping the
	 * rest. `limit < 0` is "no limit" (the no-flag default). Generic
	 * over the entry shape: `len` reads a hit count, `trim` rebuilds an
	 * entry capped to the first `k` hits.
	 */
	public static function limitEntries<T>(entries: Array<T>, limit: Int, len: T -> Int, trim: (T, Int) -> T): Array<T> {
		if (limit < 0) return entries;
		final out: Array<T> = [];
		var remaining: Int = limit;
		for (e in entries) {
			if (remaining <= 0) break;
			final n: Int = len(e);
			if (n <= remaining) {
				out.push(e);
				remaining -= n;
			} else {
				out.push(trim(e, remaining));
				remaining = 0;
			}
		}
		return out;
	}

	/**
	 * Walker flood guard. When the caller did NOT pass `--limit` (`limit < 0`)
	 * and the total hit count exceeds `AUTO_LIMIT_THRESHOLD`, returns the
	 * threshold AND prints a stderr nudge so the user sees the truncation
	 * happened. Otherwise returns `limit` unchanged.
	 *
	 * Killer case: `apq lit '/*' src/ --any-kind` would flood ~165KB of leaf hits; the guard caps to `AUTO_LIMIT_THRESHOLD` automatically and surfaces the count so the user can re-run with an explicit `--limit N`
	 * for a precise budget.
	 *
	 * `--limit 0` (any explicit value) is honoured verbatim — the guard
	 * only fires on the implicit "no limit" default.
	 */
	public static function effectiveAutoLimit(cmdName: String, limit: Int, totalHits: Int): Int {
		if (limit >= 0 || totalHits <= AUTO_LIMIT_THRESHOLD) return limit;
		CliIo.stderr('apq $cmdName: auto-capped to $AUTO_LIMIT_THRESHOLD of $totalHits hits — pass `--limit N` for an explicit cap.\n');
		return AUTO_LIMIT_THRESHOLD;
	}

	/**
	 * Parse one walked file for the scan subcommands
	 * (`refs`/`uses`/`meta`/`search`). The behaviour on a parse failure
	 * depends on how the input was given. When the user named exactly
	 * one file (`singleFile`), the failure IS the query's answer: it is
	 * reported and the caller turns it into a hard error, mirroring
	 * `apq ast`. In directory / glob / multi-file scan mode an
	 * unparseable file is out of scope by nature, so it is skipped
	 * silently — no per-file error noise on every walk. Returns the
	 * parsed tree, or `null` to skip (scan) / fail (single file).
	 *
	 * Substring pre-filter: a name-walker only ever emits hits whose
	 * leaf text equals `searchKey`. An identifier / annotation key is
	 * carried verbatim into the AST (never escaped, case-sensitive), so
	 * `source.indexOf(searchKey) >= 0` is a strict necessary condition
	 * for ANY hit — if the raw bytes do not contain the key, no parse
	 * can produce a match. When `searchKey` is non-null and absent from
	 * `source`, the file is skipped WITHOUT parsing (the dominant cost
	 * on a corpus-wide walk) and WITHOUT a skip-entry: the file parses
	 * fine, it is a confirmed no-match, not a parse failure. The raw
	 * read is shared with the parse — the caller already read `source`
	 * once and passes the same buffer here, so the pre-filter adds no
	 * extra IO.
	 *
	 * `lit` searches the DECODED literal value while the raw file holds
	 * the ESCAPED form, so a raw `indexOf` can false-negative on a key
	 * containing escape sequences. Callers that cannot guarantee the key
	 * appears verbatim in source (e.g. `lit` on a backslash-bearing key)
	 * pass `searchKey == null` to opt out — correctness over speed.
	 *
	 * The pre-filter is suppressed in `singleFile` mode: there a `null`
	 * tree means "parse failed" and the caller turns it into a hard
	 * error. A pre-filter skip is a confirmed no-match, NOT a parse
	 * failure, so suppressing it preserves the single-file contract
	 * (parse the named file, emit 0 hits + nudge, exit 0). The win is a
	 * corpus-wide-scan win anyway — skipping one named file is moot.
	 */
	public static function parseWalked(
		cmd: String, parse: String -> QueryNode, path: String, source: String, singleFile: Bool, ?skipOut: Array<SkipEntry>,
		?searchKey: String
	): Null<QueryNode> {
		return !singleFile && searchKey != null && source.indexOf(searchKey) < 0
			? null
			: try parse(source) catch (exception: ParseError) {
				if (singleFile) CliIo.stderr('apq $cmd: $path: $exception\n');
				skipOut?.push({ path: path, locus: formatParseErrorLocus(exception, source) });
				null;
			}
			catch (exception: Exception) {
				if (singleFile) CliIo.stderr('apq $cmd: $path: ${exception.message}\n');
				skipOut?.push({ path: path, locus: exception.message });
				null;
			};
	}

	/**
	 * Build the per-kind nudge for `search` on a degenerate (single-leaf)
	 * pattern. Kind-aware: a lone metavar has no name to refs/uses; a
	 * literal value goes through `lit`; a bare identifier supports all
	 * three (refs/uses/lit). Sister of `emptyWalkerNudge` — both emit
	 * tool-suggestion messages on a structurally-valid-but-misaimed query.
	 */
	public static function degenerateNudge(patternStr: String, rootKind: String): String {
		final prefix: String = 'apq search: pattern "$patternStr" ';
		return switch rootKind {
			case 'Metavar':
				'${prefix}is a lone metavar — matches every node. Narrow with structural context ('
					+ 'e.g. "$$x.field", "func($$x)"), or look up by name: apq refs <name> --decls / apq uses <Type>. Searching anyway.';
			case 'Literal', 'StringLit', 'BoolLit', 'IntLit', 'FloatLit', 'SingleStringExpr', 'DoubleStringExpr', 'RawString':
				'${prefix}is a bare literal — for literal-content lookup use: apq lit \'$patternStr\' <files>. Searching anyway.';
			case _:
				// Bare identifier (IdentExpr) and anything else that
				// parses to a single leaf.
				'${prefix}has no code structure — search matches shape, not bare names. Try one of: apq refs $patternStr'
					+ ' --decls (value binding), apq uses $patternStr (type position), apq lit \'$patternStr\' (string-literal content), '
					+ 'apq ast --select. Searching anyway.';
		}
	}

	/**
	 * Stderr nudge emitted by walker subcommands (refs/uses/meta/lit) when
	 * they return zero hits. Composes up to three diagnostic layers:
	 *
	 *  - SUMMARY: counts of files scanned vs parseable — turns a silent
	 *    miss into an observable signal.
	 *  - KIND HINT: when `name` is non-null, a kind-aware tool suggestion
	 *    (`refs <X>` on UpperCase → try `uses`/`blast`; `uses <x>` on
	 *    lowercase → try `refs`/`lit`; etc.). `meta` has no `<name>` and
	 *    skips this layer.
	 *  - SKIP-PARSE WARNING: when `skipEntries` lists files that failed to
	 *    parse, surface count + first few paths AND their failure locus
	 *    (`LINE:COL <message>`). The locus lets the reader judge whether
	 *    the parse failure is upstream of the searched-for content (the
	 *    file is effectively invisible — warning critical) or far past it
	 *    (warning can be ignored) without a follow-up `hxq ast` probe.
	 *  - FUZZY DID-YOU-MEAN: for refs/uses with a non-null `candidates`
	 *    name pool, suggest top-K candidates within Levenshtein distance.
	 *    Silent when nothing close enough qualifies.
	 */
	public static function emptyWalkerNudge(
		cmd: String, name: Null<String>, scanned: Int, parseable: Int, ?skipEntries: Array<SkipEntry>, ?candidates: Map<String, Bool>
	): String {
		final summary: String = 'apq $cmd: 0 hits ($scanned file(s) scanned, $parseable parseable)';
		final tail: StringBuf = new StringBuf();
		if (name != null) tail.add(nudgeNameHint(cmd, name));
		tail.add(nudgeSkipWarning(cmd, skipEntries));
		tail.add(nudgeFuzzy(cmd, name, candidates));
		return summary + tail.toString();
	}

	/**
	 * The warning `cmd` prints when the scope holds member-access occurrences of `name`
	 * (`Type.name`, `expr?.name`, `expr!.name`) that the value-binding walker cannot bind.
	 * `bindings` is the UNFILTERED count of resolved reads + writes, so the severity does
	 * not swing with `--decls` / `--reads`: at zero the omission is the dangerous kind (an
	 * empty result reads as "unreferenced"), otherwise the result is merely partial. The
	 * caller only invokes this when `memberAccesses > 0`, so a name with nothing missed
	 * never gets a line.
	 */
	public static function memberAccessNudge(cmd: String, name: String, memberAccesses: Int, bindings: Int): String {
		final head: String = bindings == 0
			? 'apq $cmd: no read/write resolved, but $memberAccesses member-access occurrence(s) of \'$name\' cannot be bound '
				+ 'lexically — this is NOT proof \'$name\' is unreferenced'
			: 'apq $cmd: $memberAccesses member-access occurrence(s) of \'$name\' are not shown';
		return '$head (refs resolves value bindings; \'Type.$name\' / \'expr?.$name\' bind through the receiver type). '
			+ 'Run: apq mentions $name <dir>';
	}

	/**
	 * Top-`FUZZY_TOP_K` "did you mean" candidates ranked in two tiers:
	 *
	 *  - Tier 0 — substring match: `query` is a contiguous substring of
	 *    `cand` (prefix/suffix/inner). Score = extra char count
	 *    `cand.length - query.length`. Catches the common grammar miss
	 *    `HxTypeParam` → `HxTypeParamDecl` (Levenshtein distance 4 from
	 *    appending "Decl" — beyond `FUZZY_MAX_DIST`, but `HxTypeParam` IS
	 *    a substring of `HxTypeParamDecl`). Guarded by
	 *    `FUZZY_SUBSTRING_MIN_QUERY` (avoids `Hx` matching everything)
	 *    and `FUZZY_SUBSTRING_MAX_EXTRA` (avoids `Foo` crowding out true
	 *    neighbours with a long-name match).
	 *
	 *  - Tier 1 — Levenshtein within `FUZZY_MAX_DIST`. Catches typos and
	 *    transpositions a substring scan can't.
	 *
	 * A candidate that qualifies under Tier 0 is NOT also evaluated under
	 * Tier 1 — the substring tier always wins, and we don't double-add.
	 * Returns empty when nothing qualifies; the caller emits the "did you
	 * mean" line only on a non-empty result (never fabricates hints).
	 */
	public static function findFuzzy(query: String, pool: Map<String, Bool>): Array<String> {
		final scored: Array<{ name: String, tier: Int, score: Int }> = [];
		final qLen: Int = query.length;
		final substringEnabled: Bool = qLen >= FUZZY_SUBSTRING_MIN_QUERY;
		for (cand in pool.keys()) if (cand != query) {
			if (substringEnabled && cand.length > qLen && cand.length - qLen <= FUZZY_SUBSTRING_MAX_EXTRA && cand.indexOf(query) >= 0) {
				scored.push({ name: cand, tier: 0, score: cand.length - qLen });
				continue;
			}
			// `FUZZY_MAX_DIST + 1` as the ceiling: every distance the tier
			// keeps comes back exact, and anything further comes back as the
			// ceiling itself, which the test below rejects.
			final d: Int = EditDistance.between(query, cand, FUZZY_MAX_DIST + 1);
			if (d <= FUZZY_MAX_DIST) scored.push({ name: cand, tier: 1, score: d });
		}
		scored.sort((a, b) ->
			if (a.tier != b.tier)
				a.tier - b.tier
			else if (a.score != b.score)
				a.score - b.score
			else if (a.name < b.name)
				-1
			else
				1
		);
		final take: Int = scored.length < FUZZY_TOP_K ? scored.length : FUZZY_TOP_K;
		return [for (i in 0...take) scored[i].name];
	}

	/**
	 * Heuristic: is the string clearly an identifier rather than a string
	 * fragment? Drives `lit`'s smart-default kind filter — when the query
	 * is camelCase (`trailOptShapeGate`) or snake_case (`MAX_LEN`,
	 * `endsWith_close_brace`) the user almost always wants the identifier
	 * tier promoted alongside `Literal`. Pure-lowercase single words
	 * (`foo`) and all-uppercase single words (`API`) stay ambiguous and
	 * keep the conservative `Literal`-only default — widening them would
	 * flood the result with prose hits.
	 *
	 * Rule: every char is alpha / digit / `_`, AND the string contains
	 * either a lower-then-upper transition (camelCase) or a `_` between
	 * letters (snake_case). Single letters / pure digits / strings with
	 * spaces / punctuation never qualify.
	 */
	public static function looksLikeMixedIdentifier(s: String): Bool {
		if (s.length < 2) return false;
		var hasLower: Bool = false;
		var hasUpper: Bool = false;
		var hasUnderscore: Bool = false;
		var hasLetter: Bool = false;
		var mixedTransition: Bool = false;
		var prevLower: Bool = false;
		for (idx in 0...s.length) {
			final c: Int = s.fastCodeAt(idx);
			final isLower: Bool = c >= 'a'.code && c <= 'z'.code;
			final isUpper: Bool = c >= 'A'.code && c <= 'Z'.code;
			final isDigit: Bool = c >= '0'.code && c <= '9'.code;
			final isUnderscore: Bool = c == '_'.code;
			if (!(isLower || isUpper || isDigit || isUnderscore)) return false;
			if (isLower) {
				hasLower = true;
				hasLetter = true;
			}
			if (isUpper) {
				hasUpper = true;
				hasLetter = true;
				if (prevLower) mixedTransition = true;
			}
			if (isUnderscore) hasUnderscore = true;
			prevLower = isLower;
		}
		return hasLetter && (mixedTransition || (hasUnderscore && (hasLower || hasUpper)));
	}

	/**
	 * Render a `ParseError` as the skip-entry locus suffix shown in the
	 * 0-hit walker nudge: `LINE:COL <message>[ (expected <X>)]`.
	 *
	 * The locus tells the reader whether the parse failure is at the
	 * top of the file (so the file is effectively invisible to the walk)
	 * or far past where the searched name would plausibly live (warning
	 * can be ignored). Saves a follow-up `hxq ast <path>` probe to read
	 * the same information.
	 */
	private static function formatParseErrorLocus(exception: ParseError, source: String): String {
		final pos: Position = exception.span.lineCol(source);
		final base: String = '${pos.line}:${pos.col} ${exception.message}';
		return exception.expected == null ? base : '$base (expected ${exception.expected})';
	}

	/**
	 * Build the kind/case-aware tool-suggestion hint for a 0-hit walker
	 * with a non-null query name. Leading-dot and dotted-access queries get
	 * a structural-search redirect; otherwise the per-command cascade
	 * (refs/uses/blast/lit) suggests the right walker for the name's case.
	 */
	private static function nudgeNameHint(cmd: String, n: String): String {
		final first: Int = n.length > 0 ? n.fastCodeAt(0) : 0;
		final isUpper: Bool = first >= 'A'.code && first <= 'Z'.code;
		final isLower: Bool = first >= 'a'.code && first <= 'z'.code;
		final leadingDot: Null<String> = CliWalk.looksLikeLeadingDotField(n);
		final dotted: Null<Array<String>> = CliWalk.looksLikeDottedAccess(n);
		if (leadingDot == null || cmd != 'lit' && cmd != 'refs' && cmd != 'uses')
			return dotted != null && (cmd == 'lit' || cmd == 'refs' || cmd == 'uses')
				? nudgeDottedHint(cmd, n, dotted)
				: nudgeCommandHint(cmd, n, isUpper, isLower);
		// Leading-dot query (`.expr`, `.body`) — user is hunting a
		// field-access shape but typed the SLOT name only. lit
		// won't capture the leading `.` (FieldAccess leaves are
		// the identifier after `.`, the `.` is a postfix
		// operator); refs/uses don't know about field positions.
		// The structural answer is `apq search '$x.<tail>'`.
		final t: String = leadingDot;
		return ' — "$n" is a leading-dot field-name slot. $cmd matches leaf names / single bindings / type positions, never `expr.field` '
			+ 'shape. Try: apq search \'$$x.$t\' <dir> (field-access shape), apq lit \'$t'
			+ '\' <dir> --any-kind (every leaf — field-name slots included), or apq refs $t <dir> --decls (where the field is declared).';
	}

	/**
	 * Hint for a dotted query (`TypeName.method`, `obj.field`) — never a
	 * leaf-name / value-binding / type-position match. LHS uppercase ⇒
	 * static-call shape; otherwise instance access.
	 */
	private static function nudgeDottedHint(cmd: String, n: String, dotted: Array<String>): String {
		final lhs: String = dotted[0];
		final rhs: String = dotted[dotted.length - 1];
		final lhsFirst: Int = lhs.fastCodeAt(0);
		final lhsIsUpper: Bool = lhsFirst >= 'A'.code && lhsFirst <= 'Z'.code;
		return lhsIsUpper
			? ' — "$n" is a dotted access (Type.method / pkg.Module). $cmd matches leaf names / single bindings / type positions, never '
				+ '`Type.method` shape. Try: apq search \'$n($$_)\' <dir> (call shape), apq search \'$lhs.$rhs'
				+ '\' <dir> (field-access shape), or apq refs $rhs <dir> --decls (where the method is declared).'
			: ' — "$n" is a dotted access (obj.field). $cmd'
				+ ' matches leaf names / single bindings, never `obj.field` shape. Try: apq search \'$$x.$rhs\' <dir> (field-access '
				+ 'shape), apq search \'$n\' <dir> (literal access), or apq refs $rhs <dir> --decls (where the field is declared).';
	}

	/**
	 * Per-command 0-hit hint (refs/uses/blast/lit), branching on the query
	 * name's leading case to point at the complementary walker.
	 */
	private static function nudgeCommandHint(cmd: String, n: String, isUpper: Bool, isLower: Bool): String {
		return switch cmd {
			case 'refs':
				if (isUpper)
					' — "$n" starts uppercase, looks like a TypeName. Try: apq uses $n <dir> (type positions), apq blast $n'
						+ ' <dir> (full change-impact incl. field-access), or apq lit \'$n'
						+ '\' <dir> --any-kind (every leaf — case-patterns / imports / new exprs).';
				else
					' — "$n" has no value-binding here. Locals/params are NOT indexed. Try: apq lit \'$n\' <dir> --any-kind (every '
						+ 'leaf — strings/idents/field-names) or apq search \'$$x.$n\' <dir> (field-access shape).${CliWalk.macroEmitHint(n)}';
			case 'uses':
				if (isLower)
					' — "$n" starts lowercase, not a TypeName. Try: apq refs $n <dir> (value bindings) or apq lit \'$n'
						+ '\' <dir> --any-kind (every leaf).${CliWalk.macroEmitHint(n)}';
				else
					' — no type-position references. For full change-impact incl. `.field` access try: apq blast $n <dir>, or apq lit \''
						+ '$n\' <dir> --any-kind (every leaf — incl. case-patterns).';
			case 'blast':
				' — no declaration of "$n" in the scanned set (the heuristic section needs it). Either widen the scan, or use apq uses $n'
					+ ' <dir> + apq refs $n <dir> directly.';
			case 'lit':
				if (CliWalk.looksLikeMixedIdentifier(n))
					' — no Literal/IdentExpr leaf matches "$n" (camelCase/snake_case query → default kind widened to Literal+IdentExpr; '
						+ '--exact for full equality). Try --any-kind (every leaf — incl. field-name slots), apq refs $n'
						+ ' <dir> --decls, or apq search \'$$x.$n\' <dir> (field-access shape).';
				else
					' — no string-literal content matches "$n'
						+ '" (default: substring on Literal leaves; --exact for full equality). Widen the kind set with --kind Literal,'
						+ 'IdentExpr or --any-kind (catches every leaf — incl. field-name slots), or try: apq refs $n <dir> --decls.';
			case 'meta':
				''; // meta has no <name> arg (annotation is its own thing) — leave silent.
			case _:
				'';
		};
	}

	/**
	 * Skip-parse warning: parseable < scanned means the answer may be hiding
	 * in unparsed files. Surface it loudly (with up to SKIP_PATHS_SHOWN
	 * loci) so a 0-hit query on a broken corpus is not silently trusted.
	 * Empty string when nothing skip-parsed.
	 */
	private static function nudgeSkipWarning(cmd: String, ?skipEntries: Array<SkipEntry>): String {
		if (skipEntries == null || skipEntries.length == 0) return '';
		final tail: StringBuf = new StringBuf();
		final n: Int = skipEntries.length;
		tail.add(
			'\napq $cmd: WARNING: $n file(s) skip-parse — answer may be hiding in unparsed files. Locus shows the parse-failure '
			+ 'position; if it is far past the construct you searched for, the warning can be ignored.'
		);
		final shown: Int = n < SKIP_PATHS_SHOWN ? n : SKIP_PATHS_SHOWN;
		for (i in 0...shown) {
			final entry: SkipEntry = skipEntries[i];
			tail.add('\n  skip: ${entry.path} :: ${entry.locus}');
		}
		if (n > shown) tail.add('\n  ... and ${n - shown} more');
		return tail.toString();
	}

	/**
	 * Fuzzy "did you mean": for refs/uses on 0 hits, propose the top-K
	 * decl/type names within Levenshtein distance. Empty string when no
	 * candidate qualifies — don't fabricate hints.
	 */
	private static function nudgeFuzzy(cmd: String, name: Null<String>, ?candidates: Map<String, Bool>): String {
		if (name == null || candidates == null || (cmd != 'refs' && cmd != 'uses')) return '';
		final suggestions: Array<String> = findFuzzy(name, candidates);
		return suggestions.length > 0 ? '\napq $cmd: Did you mean: ${suggestions.join(', ')}?' : '';
	}


	/**
	 * Heuristic: does the query look like a leading-dot field-name slot
	 * (`.expr`, `.body`)? A single `.` prefix followed by an identifier-
	 * shaped tail. Used by the 0-hit nudge on `lit` / `refs` / `uses`:
	 * a leading-dot literal is never a captured leaf (lit) / value
	 * binding (refs) / type position (uses) — the user is looking for
	 * a `$x.<rest>` field-access shape, the structural answer is
	 * `apq search`.
	 *
	 * Returns the dot-stripped tail (`.expr` → `expr`) when the query
	 * qualifies, null otherwise. Composes with `looksLikeDottedAccess`
	 * (which rejects empty leading segments) — that heuristic is for
	 * `Type.method` / `obj.field` SOURCE notation; this one is for the
	 * field-name-only `.x` lookup intent.
	 */
	private static function looksLikeLeadingDotField(s: String): Null<String> {
		if (s.length < 2) return null;
		if (s.fastCodeAt(0) != '.'.code) return null;
		final tail: String = s.substr(1);
		// Tail must be a single identifier — multi-segment chains like
		// `.obj.field` are not the intended shape (they would also
		// produce false positives on the `obj.field` SOURCE form).
		if (tail.indexOf('.') >= 0) return null;
		final first: Int = tail.fastCodeAt(0);
		final firstOk: Bool = (first >= 'a'.code && first <= 'z'.code) || (first >= 'A'.code && first <= 'Z'.code) || first == '_'.code;
		if (!firstOk) return null;
		for (idx in 1...tail.length) {
			final c: Int = tail.fastCodeAt(idx);
			final ok: Bool = (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code)
				|| c == '_'.code;
			if (!ok) return null;
		}
		return tail;
	}

	private static function looksLikeDottedAccess(s: String): Null<Array<String>> {
		if (s.indexOf('.') < 0) return null;
		final parts: Array<String> = s.split('.');
		if (parts.length < 2) return null;
		for (p in parts) {
			if (p.length == 0) return null;
			final first: Int = p.fastCodeAt(0);
			final firstOk: Bool = (first >= 'a'.code && first <= 'z'.code) || (first >= 'A'.code && first <= 'Z'.code) || first == '_'.code;
			if (!firstOk) return null;
			for (idx in 1...p.length) {
				final c: Int = p.fastCodeAt(idx);
				final ok: Bool = (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code)
					|| c == '_'.code;
				if (!ok) return null;
			}
		}
		return parts;
	}

	/**
	 * Append a hint when `name` appears to be macro-generated — scan
	 * `src/anyparse/macro/*.hx` for a `<name>Field` Field-builder function
	 * declaration (the canonical `Codegen.<name>Field()` shape that emits
	 * runtime helpers like `peekKw` / `matchLit` / `expectLit`). When found,
	 * point the user at the macro source where the literal name appears,
	 * since the runtime caller search (refs/uses) cannot reach the FFun
	 * `name: '<name>'` string-literal slot inside the builder body.
	 *
	 * Returns empty string when:
	 *  - `sys` target not available (no FileSystem access);
	 *  - `src/anyparse/macro` doesn't exist (running outside the project);
	 *  - no `<name>Field` function found in any macro source.
	 *
	 * Sniff is conservative (substring match for the exact FFun signature
	 * prefix `function <name>Field(`) — false positives require an
	 * unrelated function with that exact suffix, which the project does
	 * not produce.
	 */
	private static function macroEmitHint(name: String): String {
		#if (sys || nodejs)
		final macroDir: String = 'src/anyparse/macro';
		if (!FileSystem.exists(macroDir) || !FileSystem.isDirectory(macroDir)) return '';
		final marker: String = 'function ${name}Field(';
		try {
			for (entry in FileSystem.readDirectory(macroDir)) if (StringTools.endsWith(entry, '.hx')) {
				final src: String = sys.io.File.getContent('$macroDir/$entry');
				if (src.indexOf(marker) < 0) continue;
				return ' If "$name" is a macro-emitted parser runtime helper, the emit site lives in src/anyparse/macro/$entry'
					+ ' — try apq lit \'$name\' src/anyparse/macro/ --any-kind to see the FFun name slot.';
			}
		} catch (_: Exception) {
			// best-effort: return '' if building the hint text fails
		}
		return '';
		#else
		return '';
		#end
	}

}

/**
 * Skip-entry for a walker's 0-hit nudge: a path the walk could not parse
 * plus a human-readable failure locus (`LINE:COL <message>`). The locus
 * lets the reader judge whether the parse failure is upstream of the
 * searched-for content (warning critical) or far past it (can ignore)
 * without a follow-up `hxq ast <path>` probe.
 */
typedef SkipEntry = { path: String, locus: String };
