package anyparse.query;

import anyparse.query.Matcher.Match;
import anyparse.query.RefactorSupport.EditResult;
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

	/**
	 * Rewrite every match of `patternText` in `source` using `replacementText`.
	 * Returns `Ok(rewritten)` or an `Err` describing why the rewrite failed
	 * (no match, bad pattern, unknown / non-integer metavariable, or a result
	 * that does not parse).
	 */
	public static function rewrite(
		source: String, patternText: String, replacementText: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		final pattern: Pattern = try plugin.parsePattern(patternText) catch (exception: Exception) return Err(
			'pattern: ${exception.message}'
		);

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

		final edits: Array<{ span: Span, text: String }> = [];
		for (m in accepted) {
			final text: Null<String> = expandTemplate(replacementText, source, m.bindings);
			if (text == null) return Err('replacement references an unknown or non-integer metavariable');
			edits.push({ span: m.span, text: text });
		}
		return RefactorSupport.canonicalize(source, edits, reformat, plugin, optsJson);
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
	 */
	private static function expandTemplate(template: String, source: String, bindings: Map<String, QueryNode>): Null<String> {
		final buf: StringBuf = new StringBuf();
		final n: Int = template.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = StringTools.fastCodeAt(template, i);
			if (c != '$'.code) {
				buf.addChar(c);
				i++;
				continue;
			}
			if (i + 1 < n && StringTools.fastCodeAt(template, i + 1) == '$'.code) {
				buf.addChar('$'.code);
				i += 2;
				continue;
			}
			if (i + 1 < n && StringTools.fastCodeAt(template, i + 1) == '{'.code) {
				final close: Int = template.indexOf('}', i + 2);
				if (close < 0) return null;
				final braced: Null<String> = expandSpec(template.substring(i + 2, close), source, bindings);
				if (braced == null) return null;
				buf.add(braced);
				i = close + 1;
				continue;
			}
			var j: Int = i + 1;
			while (j < n && isIdentChar(StringTools.fastCodeAt(template, j))) j++;
			if (j == i + 1) {
				buf.addChar('$'.code);
				i++;
				continue;
			}
			final bare: Null<String> = metavarSource(template.substring(i + 1, j), source, bindings);
			if (bare == null) return null;
			buf.add(bare);
			i = j;
		}
		return buf.toString();
	}

	// `name` (verbatim) | `name+N` / `name-N` (integer shift).
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

	// Verbatim source for a bound metavar: the captured name for a
	// name-position binding, else the node's source slice.
	private static function metavarSource(name: String, source: String, bindings: Map<String, QueryNode>): Null<String> {
		final node: Null<QueryNode> = bindings[name];
		if (node == null) return null;
		if (node.kind == 'NameOnly') return node.name;
		final span: Null<Span> = node.span;
		return span == null ? node.name : SourceSlice.slice(source, span);
	}

	private static inline function isIdentChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code;
	}

}
