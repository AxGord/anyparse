package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.Matcher.Match;
import anyparse.query.ParenGuard.GuardedEdit;
import anyparse.query.Pattern.PatternStar;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;

/**
 * Structural search-and-replace — the fusion of `search` (find a pattern with
 * `$x` metavariables) and a span-replace, the gap that previously forced a
 * separate find-then-replace-by-position dance. For every node matching
 * `pattern`, the matched span is rewritten from `replacement`: a template in
 * which `$x` / `${x}` expands to the verbatim source of the captured
 * metavariable, and `${x+N}` / `${x-N}` shifts an integer-literal metavariable
 * by N. All matches are rewritten in one pass through the writer round-trip, so
 * the result is canonical + re-parse-validated (canonical-gated unless
 * `reformat`). This is `gofmt -r` / comby for the grammar's own AST.
 *
 * The source is never mutated; the caller decides whether to write the result.
 */
@:nullSafety(Strict)
final class Rewrite {

	private static final STAR_REFUSAL: String = 'rewrite: the pattern contains `...`, which matches a run of children but binds nothing, '
		+ 'so the replacement cannot name them and they would be dropped — use `apq search` to '
		+ 'census with `...`, and an explicit-arity pattern to rewrite';

	/**
	 * Rewrite every match of `patternText` in `source` using `replacementText`.
	 * Returns `Ok(rewritten)` or an `Err` describing why the rewrite failed
	 * (no match, bad pattern, unknown / non-integer metavariable, or a result
	 * that does not parse).
	 */
	public static function rewrite(
		source: String, patternText: String, replacementText: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err('source does not parse: $exception')
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		final pattern: Pattern = try plugin.parsePattern(patternText) catch (exception: Exception) return Err(
			'pattern: ${exception.message}'
		);

		// A `...` cannot survive a rewrite. The star absorbs a RUN of children
		// and does not bind, so the replacement template has no name for what it
		// took, and `Rewrite` splices over the whole matched span: `rewrite
		// 'g(...)' 'k()'` reads as "leave the arguments alone" and would delete
		// every one of them, silently and re-parseably. Refuse instead. `search`
		// and the `--match` op locator keep working — the locator only ADDRESSES
		// a node, it never rebuilds one from the pattern.
		if (PatternStar.contains(pattern.root)) return Err(STAR_REFUSAL);

		final matches: Array<Match> = Matcher.search(pattern, tree);
		if (matches.length == 0) return Err('no match for the pattern');

		// Matches arrive pre-order (outer first). Keep only non-overlapping
		// spans — a nested match inside a kept one would corrupt the edit.
		final accepted: Array<Match> = [];
		var lastTo: Int = -1;
		for (m in sortedByFrom(matches)) if (m.span.from >= lastTo) {
			accepted.push(m);
			lastTo = m.span.to;
		}

		final edits: Array<GuardedEdit> = [];
		for (m in accepted) {
			final expansion: Null<Expansion> = expandTemplate(replacementText, source, m.bindings);
			if (expansion == null) return Err('replacement references an unknown or non-integer metavariable');
			edits.push({ span: m.span, text: expansion.text, holes: expansion.holes });
		}
		// A template is written in AST terms (`$A * 2` reads "the capture, times
		// two") but expands as TEXT, and text has no precedence. `ParenGuard`
		// puts back the fewest parentheses that make the spliced fragments parse
		// as the nodes they were — none at all when the raw splice was already
		// faithful, which is the common case and byte-identical to before.
		final guarded: Array<{ span: Span, text: String }> = ParenGuard.guard(source, edits, plugin);
		return CanonicalEdit.canonicalize(source, guarded, reformat, plugin, optsJson);
	}

	private static inline function isIdentChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code;
	}

	private static function sortedByFrom(matches: Array<Match>): Array<Match> {
		final copy: Array<Match> = matches.copy();
		copy.sort((a, b) -> a.span.from != b.span.from ? a.span.from - b.span.from : b.span.to - a.span.to);
		return copy;
	}

	/**
	 * Expand `$x` / `${x}` (verbatim metavar source) and `${x+N}` / `${x-N}`
	 * (integer-literal metavar shifted by N) against `bindings`. `$$` emits a
	 * literal `$`. Returns null if a referenced metavar is unbound, or an int
	 * shift targets a non-integer metavar.
	 *
	 * Every expanded metavariable also reports the range it occupies in the
	 * result. Those are the SPLICES — text that came from the input rather than
	 * from the template author — and `ParenGuard` decides which of them the new
	 * context would re-read.
	 */
	private static function expandTemplate(template: String, source: String, bindings: Map<String, QueryNode>): Null<Expansion> {
		final buf: StringBuf = new StringBuf();
		final holes: Array<Span> = [];
		var written: Int = 0;
		final n: Int = template.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = template.fastCodeAt(i);
			if (c != '$'.code) {
				buf.addChar(c);
				written++;
				i++;
				continue;
			}
			if (i + 1 < n && template.fastCodeAt(i + 1) == '$'.code) {
				buf.addChar('$'.code);
				written++;
				i += 2;
				continue;
			}
			if (i + 1 < n && template.fastCodeAt(i + 1) == '{'.code) {
				final close: Int = template.indexOf('}', i + 2);
				if (close < 0) return null;
				final braced: Null<String> = expandSpec(template.substring(i + 2, close), source, bindings);
				if (braced == null) return null;
				buf.add(braced);
				holes.push(new Span(written, written + braced.length));
				written += braced.length;
				i = close + 1;
				continue;
			}
			var j: Int = i + 1;
			while (j < n && isIdentChar(template.fastCodeAt(j))) j++;
			if (j == i + 1) {
				buf.addChar('$'.code);
				written++;
				i++;
				continue;
			}
			final bare: Null<String> = metavarSource(template.substring(i + 1, j), source, bindings);
			if (bare == null) return null;
			buf.add(bare);
			holes.push(new Span(written, written + bare.length));
			written += bare.length;
			i = j;
		}
		return { text: buf.toString(), holes: holes };
	}

	/** `name` (verbatim) | `name+N` / `name-N` (integer shift). */
	private static function expandSpec(spec: String, source: String, bindings: Map<String, QueryNode>): Null<String> {
		final plus: Int = spec.indexOf('+');
		final minus: Int = spec.indexOf('-');
		final opAt: Int = plus >= 0 ? plus : minus;
		if (opAt <= 0) return metavarSource(spec, source, bindings);
		final num: Null<Int> = Std.parseInt(spec.substring(opAt + 1));
		if (num == null) return null;
		final shift: Int = plus >= 0 ? num : -num;
		final raw: Null<String> = metavarSource(spec.substring(0, opAt), source, bindings);
		if (raw == null) return null;
		final value: Null<Int> = Std.parseInt(StringTools.trim(raw));
		return value == null ? null : '${value + shift}';
	}

	/**
	 * Verbatim source for a bound metavar: the captured name for a
	 * name-position binding, else the node's source slice.
	 */
	private static function metavarSource(name: String, source: String, bindings: Map<String, QueryNode>): Null<String> {
		final node: Null<QueryNode> = bindings[name];
		if (node == null) return null;
		if (node.kind == 'NameOnly') return node.name;
		final span: Null<Span> = node.span;
		return span == null ? node.name : SourceSlice.slice(source, span);
	}

}

/** One expanded replacement: its text, and where in it each metavariable's source landed. */
private typedef Expansion = {
	text: String,
	holes: Array<Span>
};
