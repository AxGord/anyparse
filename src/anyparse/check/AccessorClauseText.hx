package anyparse.check;

import anyparse.query.ElementSpan;
import anyparse.runtime.Span;

using StringTools;

/**
 * The RAW-SOURCE geometry of a property head: where its `(read, write)` accessor clause is, what
 * the two accessor identifiers spell, and which byte range a collapse must delete.
 *
 * A property's accessor clause is the one part of the shape `trivial-getter` rewrites that the
 * query tree does not project as nodes — the grammar carries `var x(get, set):T;` as one member,
 * so `get` / `set` and the parentheses around them exist only as source text. Every answer here
 * is therefore span arithmetic over the member's own span, and every one of them is scanned
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

	/**
	 * The two accessor identifiers of a property's `(read, write)` clause, read from the
	 * source right after the field name — or null when the member is a plain field (no `(`
	 * clause) or the clause is malformed. `span.from` is at the `var` keyword.
	 */
	public static function accessorClause(source: String, span: Span): Null<{ read: String, write: String }> {
		final open: Int = accessorParenOpen(source, span);
		if (open < 0) return null;
		final n: Int = source.length;
		final read: Null<{ id: String, next: Int }> = identAt(source, skipSpace(source, open + 1, n), n);
		if (read == null) return null;
		final i: Int = skipSpace(source, read.next, n);
		if (i >= n || source.fastCodeAt(i) != ','.code) return null;
		final write: Null<{ id: String, next: Int }> = identAt(source, skipSpace(source, i + 1, n), n);
		return write == null ? null : { read: read.id, write: write.id };
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
		while (to < source.length && isHorizontalSpace(source.fastCodeAt(to))) to++;
		if (to > meta.to) return new Span(meta.from, to);
		var from: Int = meta.from;
		while (from > 0 && isHorizontalSpace(source.fastCodeAt(from - 1))) from--;
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

	/** Whether `c` is an identifier character. */
	private static inline function isIdentChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code;
	}

	/** Whether `c` is whitespace. */
	private static inline function isSpace(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

	/** Whether `c` is a space or a tab (a line-internal separator, newline excluded). */
	private static inline function isHorizontalSpace(c: Int): Bool {
		return c == ' '.code || c == '\t'.code;
	}

	/** The identifier at `i` (already past whitespace) and the offset after it, or null. */
	private static function identAt(source: String, i: Int, n: Int): Null<{ id: String, next: Int }> {
		final start: Int = i;
		var j: Int = i;
		while (j < n && isIdentChar(source.fastCodeAt(j))) j++;
		return j > start ? { id: source.substring(start, j), next: j } : null;
	}

	/** Advance past a whitespace run starting at `i`. */
	private static function skipSpace(source: String, i: Int, n: Int): Int {
		var j: Int = i;
		while (j < n && isSpace(source.fastCodeAt(j))) j++;
		return j;
	}

	/** The offset just past the `var name` prefix of `span` (keyword + whitespace + identifier), or -1 when it does not begin with `var <name>`. */
	private static function nameEndAfterVar(source: String, span: Span): Int {
		final n: Int = source.length;
		final kw: String = 'var';
		if (span.from + kw.length > n || source.substring(span.from, span.from + kw.length) != kw) return -1;
		var i: Int = skipSpace(source, span.from + kw.length, n);
		final nameStart: Int = i;
		while (i < n && isIdentChar(source.fastCodeAt(i))) i++;
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
