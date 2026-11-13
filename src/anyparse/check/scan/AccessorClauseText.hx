package anyparse.check.scan;

import anyparse.check.Check.FixEdit;
import anyparse.query.ElementSpan;
import anyparse.query.SourceText;

using anyparse.util.Strings;

/**
 * The RAW-SOURCE geometry of a property head: where its `(read, write)` accessor clause is and
 * which byte range a collapse must delete. What the two identifiers SAY is the grammar fact
 * `TypeInfoProvider.accessorClauses`, never read here.
 *
 * The query tree does not project the clause as nodes — it carries `var x(get, set):T;` as one
 * member — so where its parentheses and identifiers sit is span arithmetic over the member's own
 * span, and every answer here is scanned
 * forward from `span.from` at the `var` keyword rather than searched for: a `Map<K, V>`
 * annotation or a default value elsewhere in the declaration must never be mistaken for the
 * clause.
 *
 * Split out of `TrivialGetter`, where these eleven members formed their own connected component
 * (`hxq clusters`) joined to the rest only through hub calls — a measured seam, not a chosen one.
 * The removal spans belong with them: what to delete for a clause is the same arithmetic as
 * where the clause is, and `metaRemovalSpan` answers it for the `@:isVar` annotation the
 * self-backed collapse drops in the same edit.
 */
@:nullSafety(Strict)
final class AccessorClauseText {

	/** The accessor that admits no access at all. */
	private static final NEVER_ACCESSOR: String = 'never';

	/**
	 * The edit turning the read accessor of the property whose `var` keyword starts `propSpan` into `never`, or null
	 * when it has no well-formed clause.
	 */
	public static function neverReadEdit(source: String, propSpan: Span): Null<FixEdit> {
		final open: Int = accessorParenOpen(source, propSpan);
		if (open < 0) return null;
		final n: Int = source.length;
		final from: Int = skipSpace(source, open + 1, n);
		final read: Null<{ id: String, next: Int }> = identAt(source, from, n);
		return read == null ? null : { span: new Span(from, read.next), text: NEVER_ACCESSOR };
	}

	/**
	 * The span to delete for an `@:isVar` annotation: its whole LINE when it sits on one alone
	 * (`lineExtendedSpan` says so by returning a widened span), else the token plus the horizontal
	 * space that separated it from what follows — or, when it was the last thing on its line, plus
	 * the space that separated it from what precedes. Removing the bare token would otherwise leave
	 * a doubled or trailing space next to a sibling annotation.
	 */
	public static function metaRemovalSpan(source: String, meta: Span): Span {
		final line: Span = ElementSpan.lineExtendedSpan(source, meta);
		if (line.from != meta.from || line.to != meta.to) return line;
		var to: Int = meta.to;
		while (to < source.length && source.fastCodeAt(to).isSpaceOrTab()) to++;
		if (to > meta.to) return new Span(meta.from, to);
		var from: Int = meta.from;
		while (from > 0 && source.fastCodeAt(from - 1).isSpaceOrTab()) from--;
		return new Span(from, meta.to);
	}

	/** The `(read, write)` accessor-clause span `[open, close]` of a property (`span.from` at `var`), or null. */
	public static function accessorParenSpan(source: String, propSpan: Span): Null<Span> {
		final open: Int = accessorParenOpen(source, propSpan);
		if (open < 0) return null;
		var i: Int = open + 1;
		while (i < source.length && source.fastCodeAt(i) != ')'.code) i++;
		return i >= source.length ? null : new Span(open, i + 1);
	}

	/** The span to delete for a plain-field collapse — ` (read, write)` after `var <name>`, leading space included. */
	public static function clauseRemovalSpan(source: String, propSpan: Span): Null<Span> {
		final afterName: Int = nameEndAfterVar(source, propSpan);
		final paren: Null<Span> = accessorParenSpan(source, propSpan);
		return afterName < 0 || paren == null ? null : new Span(afterName, paren.to);
	}

	/** The identifier at `i` (already past whitespace) and the offset after it, or null. */
	private static function identAt(source: String, i: Int, n: Int): Null<{ id: String, next: Int }> {
		final start: Int = i;
		var j: Int = i;
		while (j < n && source.fastCodeAt(j).isIdentChar()) j++;
		return j > start ? { id: source.substring(start, j), next: j } : null;
	}

	/** Advance past a whitespace run starting at `i`. */
	private static function skipSpace(source: String, i: Int, n: Int): Int {
		var j: Int = i;
		while (j < n && SourceText.isSpace(source.fastCodeAt(j))) j++;
		return j;
	}

	/**
	 * The offset just past the `var name` prefix of `span` (keyword +
	 * whitespace + identifier), or -1 when it does not begin with `var <name>`.
	 */
	private static function nameEndAfterVar(source: String, span: Span): Int {
		final n: Int = source.length;
		final kw: String = 'var';
		if (span.from + kw.length > n || source.substring(span.from, span.from + kw.length) != kw) return -1;
		var i: Int = skipSpace(source, span.from + kw.length, n);
		final nameStart: Int = i;
		while (i < n && source.fastCodeAt(i).isIdentChar()) i++;
		return i == nameStart ? -1 : i;
	}

	/** The offset of the property's accessor-clause `(` (right after `var <name>`), or -1 when there is none. */
	private static function accessorParenOpen(source: String, span: Span): Int {
		final afterName: Int = nameEndAfterVar(source, span);
		if (afterName < 0) return -1;
		final open: Int = skipSpace(source, afterName, source.length);
		return open < source.length && source.fastCodeAt(open) == '('.code ? open : -1;
	}

}
