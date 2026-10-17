package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.Matcher.Match;
import anyparse.query.ParenGuard.GuardedEdit;
import anyparse.query.Pattern.PatternStar;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;
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
		final tree: QueryNode = switch ParseGate.parse(plugin, source, 'source') {
			case Unparsed(message): return Err(message);
			case Parsed(parsed): parsed;
		};

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

		// Under a kind-equivalence one pattern can match a construct in two positions whose spans
		// END differently: a statement `try … catch (e) null;` owns its `;`, the same `try` as a
		// value does not. One template cannot be right for both, so when the matches disagree each
		// expansion is aligned to its own site's terminator. Matches of one shape are left alone.
		final trailers: Array<String> = [for (m in accepted) trailer(source, m.node)];
		final mixed: Bool = trailers.exists(t -> t != trailers[0]);
		final edits: Array<GuardedEdit> = [];
		for (k => m in accepted) {
			final expansion: Null<Expansion> = expandTemplate(replacementText, source, m.bindings);
			if (expansion == null) return Err('replacement references an unknown or non-integer metavariable');
			final aligned: Expansion = mixed ? alignTrailer(expansion, trailers[k], trailers) : expansion;
			edits.push({ span: m.span, text: aligned.text, holes: aligned.holes });
		}
		// A template is written in AST terms (`$A * 2` reads "the capture, times
		// two") but expands as TEXT, and text has no precedence. `ParenGuard`
		// puts back the fewest parentheses that make the spliced fragments parse
		// as the nodes they were — none at all when the raw splice was already
		// faithful, which is the common case and byte-identical to before.
		final guarded: Array<{ span: Span, text: String }> = ParenGuard.guard(source, edits, plugin);
		return CanonicalEdit.canonicalize(source, guarded, reformat, plugin, optsJson);
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
				final spec: String = template.substring(i + 2, close);
				final braced: Null<String> = expandSpec(spec, source, bindings);
				if (braced == null) return null;
				buf.add(braced);
				if (!isNameCapture(specName(spec), bindings)) holes.push(new Span(written, written + braced.length));
				written += braced.length;
				i = close + 1;
				continue;
			}
			var j: Int = i + 1;
			while (j < n && SourceText.isIdentChar(template.fastCodeAt(j))) j++;
			if (j == i + 1) {
				buf.addChar('$'.code);
				written++;
				i++;
				continue;
			}
			final bareName: String = template.substring(i + 1, j);
			final bare: Null<String> = metavarSource(bareName, source, bindings);
			if (bare == null) return null;
			buf.add(bare);
			if (!isNameCapture(bareName, bindings)) holes.push(new Span(written, written + bare.length));
			written += bare.length;
			i = j;
		}
		return { text: buf.toString(), holes: holes };
	}

	/** `name` (verbatim) | `name+N` / `name-N` (integer shift). */
	private static function expandSpec(spec: String, source: String, bindings: Map<String, QueryNode>): Null<String> {
		final plus: Int = spec.indexOf('+');
		final opAt: Int = shiftAt(spec);
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

	/** Where a `${name+N}` / `${name-N}` spec's shift operator sits, or a value `<= 0` for a plain `${name}`. */
	private static function shiftAt(spec: String): Int {
		final plus: Int = spec.indexOf('+');
		return plus >= 0 ? plus : spec.indexOf('-');
	}

	/** The metavariable a `${…}` spec names — the whole spec, or the part before its shift operator. */
	private static function specName(spec: String): String {
		final opAt: Int = shiftAt(spec);
		return opAt <= 0 ? spec : spec.substring(0, opAt);
	}

	/**
	 * Whether `name` captured a NAME slot (`new $C()`, `final $x = …`, `a.$f`) rather than a
	 * subtree. Such a splice is one identifier (or a dotted path) and never a hole `ParenGuard`
	 * should weigh: an identifier cannot be re-read by an operator around it, and the guard's
	 * premise that an illegal pair fails to parse does not hold everywhere a name sits —
	 * `new (A)()` parses, as a call of an identifier `new`, so a type name after `new` looked
	 * both wrappable and unfaithful and came back as `new(A)()`.
	 */
	private static function isNameCapture(name: String, bindings: Map<String, QueryNode>): Bool {
		return bindings[name]?.kind == 'NameOnly';
	}

	/**
	 * What a matched node's span carries past its last child — a statement's terminator (`;` after
	 * a `try … catch (e) null`), nothing for the same construct used as a value. Empty for a leaf.
	 */
	private static function trailer(source: String, node: QueryNode): String {
		final span: Null<Span> = node.span;
		final last: Null<QueryNode> = node.children.length == 0 ? null : node.children[node.children.length - 1];
		final lastSpan: Null<Span> = last?.span;
		return if (span == null || lastSpan == null)
			''
		else if (lastSpan.to > span.to)
			''
		else
			source.substring(lastSpan.to, span.to).trim();
	}

	/**
	 * `expansion` fitted to a site whose span ends in `own`, given the trailers every match carries.
	 * A site that owns a terminator the template did not write gets it appended; a site that owns
	 * none drops one the template wrote for the OTHER sites. Both edits touch template text only:
	 * a terminator inside a spliced capture is never stripped.
	 */
	private static function alignTrailer(expansion: Expansion, own: String, trailers: Array<String>): Expansion {
		final text: String = expansion.text.rtrim();
		if (own != '') return text.endsWith(own) ? expansion : { text: text + own, holes: expansion.holes };
		for (t in trailers) if (t != '' && text.endsWith(t)) {
			final cut: Int = text.length - t.length;
			if (!expansion.holes.exists(h -> h.to > cut)) return { text: text.substring(0, cut).rtrim(), holes: expansion.holes };
		}
		return expansion;
	}

}

/** One expanded replacement: its text, and where in it each metavariable's source landed. */
private typedef Expansion = {
	text: String,
	holes: Array<Span>
};
