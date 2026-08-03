package anyparse.grammar.haxe;

import anyparse.grammar.haxe.HxStringEscape.HxDecodedChar;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/**
 * Re-projects the interpolation a `Literal` string fragment HIDES.
 *
 * `HxStringLitSegment` matches a run of plain characters and escapes, stopping
 * only at a RAW `$` — deliberately, because `@:rawString` keeps the author's
 * spelling for the writer. But Haxe decodes escapes BEFORE it scans a
 * single-quoted literal for interpolation, so `'\x24a'` is a read of the local
 * `a`, `'\x24{a}'` is `${a}`, and `'\x24\x24a'` is the escaped-dollar text `$a`
 * (see `HxStringEscape`). The parser sees ONE `Literal` in each case, and every
 * consumer reading that tree — the `unused-local` / `dead-store` /
 * `no-underscore-prefix` reference scans through `RefShape.stringInterpIdentKind`,
 * `StringFoldSupport.literalOf`'s "is this a PLAIN literal" answer, `rename`'s
 * interpolation-read blind-spot refusal — inherits the blindness. `unused-local`
 * measurably DELETED a local read only through such a literal.
 *
 * The fix belongs here rather than in each of those scans: one pass over the
 * query tree splits such a `Literal` into the segments the compiler sees, using
 * the SAME node kinds and span convention the parser emits for the raw spelling
 * (`Ident` spanning `$name`, `Dollar` spanning `$$`, `LoneDollar`, `Block`
 * spanning `${ … }`), so nothing downstream needs to learn a new shape.
 *
 * Spans stay RAW-source offsets throughout: a synthesized node covers the bytes
 * that SPELL it, so `--at`, `rename` and every span-driven edit address real
 * source. Only the query tree is rewritten — the writer runs off the parse AST,
 * which is untouched, so formatting stays byte-exact.
 *
 * ## What is NOT modelled
 *
 * A `${ … }` the rescan DISCOVERS — one the parser did not, because its `$` was
 * escape-spelled — carries no child expression: reconstructing one would mean
 * parsing text that does not exist contiguously in the source (the braces may
 * themselves be escape-spelled) and inventing spans for it. Childless is the
 * honest shape, and it is the REFUSING one for the two seams that ask about
 * literal content: `literalOf` and `segmentsOf` both reject a literal holding a
 * `Block`, so no fold or requote is built on a block anyparse cannot read.
 * Identifiers inside such a block stay invisible to reference scans, and `rename`
 * — which consults neither seam and looks only for `Ident` — does not refuse for
 * them either; that gap predates this pass and is not narrowed by it. A block the
 * parser DID read keeps its subtree: the rescan reuses the parser's node whenever
 * the spans agree, which is every raw `${ … }` in the literal.
 */
@:nullSafety(Strict)
final class HxInterpProjection {

	/** The query-tree kind of a single-quoted, interpolation-capable string literal. */
	private static inline final STRING_KIND: String = 'SingleStringExpr';

	/** The query-tree kind of one plain-text fragment of such a literal. */
	private static inline final TEXT_KIND: String = 'Literal';

	/** The query-tree kind of a `${ … }` interpolation block — the one segment kind that owns a subtree. */
	private static inline final BLOCK_KIND: String = 'Block';

	/**
	 * Rewrite every `SingleStringExpr` in `tree` that hides escape-spelled
	 * interpolation. Mutates in place — `QueryNode.children` is the array the walker
	 * just built, so the common file pays one tree walk and no allocation.
	 *
	 * The whole pass is skipped for a source carrying neither `\x` nor `\u`, the two
	 * spellings from which a decoded `$` can arrive: a raw `$` is already lexed as
	 * interpolation, and no other escape decodes to one.
	 */
	public static function reproject(tree: QueryNode, source: String): Void {
		if (source.indexOf('\\x') < 0 && source.indexOf('\\u') < 0) return;
		walk(tree, source);
	}

	/** Depth-first walk re-projecting each affected string node. */
	private static function walk(node: QueryNode, source: String): Void {
		if (node.kind == STRING_KIND) expand(node, source);
		for (c in node.children) walk(c, source);
	}

	/**
	 * Re-project `node`'s WHOLE inner text, not fragment by fragment.
	 *
	 * The compiler decodes the entire literal and only then scans it, so the two
	 * models differ at a seam the parser itself creates: `HxStringLitSegment` cuts a
	 * fragment at every RAW `$`, which is exactly where a decoded `$` can meet one.
	 * `'\x24$a'` is the TEXT `$a` — the two dollars pair into one escaped dollar and
	 * the `a` is literal — but a per-fragment reading sees a lone `$` and, separately,
	 * the parser's `Ident(a)`, i.e. a READ of `a`. Folding that literal printed the
	 * value of `a`, which is the very class this module exists to close.
	 *
	 * So the scan starts from the literal's own inner span. Any `${ … }` the rescan
	 * lands on at the SAME span keeps the parser's node — with its parsed expression
	 * subtree — and only a block the rescan discovers for itself is childless.
	 */
	private static function expand(node: QueryNode, source: String): Void {
		final span: Null<Span> = node.span;
		if (span == null || span.to - span.from < 2) return;
		final inner: String = source.substring(span.from + 1, span.to - 1);
		final decoded: Array<HxDecodedChar> = HxStringEscape.decode(inner);
		if (!decoded.exists(c -> c.code == HxStringEscape.DOLLAR && c.to - c.from > 1)) return;
		final parsed: Map<String, QueryNode> = [];
		for (c in node.children) {
			final childSpan: Null<Span> = c.span;
			if (childSpan != null && c.children.length > 0) parsed['${c.kind}:${childSpan.from}:${childSpan.to}'] = c;
		}
		final parts: Array<QueryNode> = segments(decoded, inner, span.from + 1);
		node.children.splice(0, node.children.length);
		for (p in parts) node.children.push(carryOver(parsed, p));
	}

	/** The parser's node for `synthesized`'s kind and span when it had one, else `synthesized` itself. */
	private static function carryOver(parsed: Map<String, QueryNode>, synthesized: QueryNode): QueryNode {
		final span: Null<Span> = synthesized.span;
		return span == null ? synthesized : parsed['${synthesized.kind}:${span.from}:${span.to}'] ?? synthesized;
	}

	/**
	 * `decoded` — the literal's inner text, whose verbatim source is `raw` starting at
	 * `base` in the file — split into the segment nodes the compiler's post-decode scan
	 * produces. Text between two triggers becomes a `Literal` carrying its own verbatim
	 * slice, so a consumer re-reading it by span gets exactly what it got before.
	 */
	private static function segments(decoded: Array<HxDecodedChar>, raw: String, base: Int): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		var textFrom: Int = 0;
		var i: Int = 0;
		while (i < decoded.length) {
			if (decoded[i].code != HxStringEscape.DOLLAR) {
				i++;
				continue;
			}
			flushText(out, decoded, textFrom, i, raw, base);
			i = trigger(out, decoded, i, base);
			textFrom = i;
		}
		flushText(out, decoded, textFrom, decoded.length, raw, base);
		return out;
	}

	/** Emit `decoded[from...to]` as one `Literal` node, or nothing when the run is empty. */
	private static function flushText(
		out: Array<QueryNode>, decoded: Array<HxDecodedChar>, from: Int, to: Int, raw: String, base: Int
	): Void {
		if (from >= to) return;
		final start: Int = decoded[from].from;
		final end: Int = decoded[to - 1].to;
		out.push(new QueryNode(TEXT_KIND, raw.substring(start, end), [], new Span(base + start, base + end)));
	}

	/**
	 * Emit the segment the `$` at `decoded[i]` opens and return the index after it —
	 * the same four-way decision the compiler's scanner makes over the DECODED text:
	 * `$$` is one escaped dollar, `${` opens a brace-counted block, an
	 * identifier-start begins the `$name` shorthand, and anything else (including the
	 * end of the literal) is a literal lone `$`.
	 */
	private static function trigger(out: Array<QueryNode>, decoded: Array<HxDecodedChar>, i: Int, base: Int): Int {
		final next: Int = i + 1 < decoded.length ? decoded[i + 1].code : -1;
		if (next == HxStringEscape.DOLLAR) {
			out.push(node('Dollar', null, decoded, i, i + 1, base));
			return i + 2;
		}
		if (next == '{'.code) {
			final close: Int = matchingBrace(decoded, i + 1);
			out.push(node(BLOCK_KIND, null, decoded, i, close, base));
			return close + 1;
		}
		if (HxStringEscape.isIdentStart(next)) {
			var end: Int = i + 1;
			final name: StringBuf = new StringBuf();
			while (end < decoded.length && HxStringEscape.isIdentContinue(decoded[end].code)) {
				name.addChar(decoded[end].code);
				end++;
			}
			out.push(node('Ident', name.toString(), decoded, i, end - 1, base));
			return end;
		}
		out.push(node('LoneDollar', null, decoded, i, i, base));
		return i + 1;
	}

	/**
	 * The index of the `}` closing the `{` at `open`, counting nested braces the way
	 * the compiler's scanner does — a brace inside a nested string still counts. An
	 * unclosed run (the compiler's "Unclosed brace") reports the last character, so
	 * the whole remainder projects as one refusing `Block` rather than as text.
	 */
	private static function matchingBrace(decoded: Array<HxDecodedChar>, open: Int): Int {
		var depth: Int = 0;
		for (i in open ... decoded.length) {
			if (decoded[i].code == '{'.code)
				depth++;
			else if (decoded[i].code == '}'.code && --depth == 0)
				return i;
		}
		return decoded.length - 1;
	}

	/** One segment node spanning `decoded[from]`'s first byte through `decoded[to]`'s last. */
	private static function node(
		kind: String, name: Null<String>, decoded: Array<HxDecodedChar>, from: Int, to: Int, base: Int
	): QueryNode {
		return new QueryNode(kind, name, [], new Span(base + decoded[from].from, base + decoded[to].to));
	}

}
