package anyparse.check.scan;

import anyparse.query.ElementSpan;

using anyparse.util.Strings;

/**
 * The RAW-SOURCE removal geometry of the `@:isVar` annotation a self-backed collapse drops in the same edit as the property clause.
 * Where the clause itself sits is the grammar fact `AccessorClause.span` (`parenSpan` / `removalSpan`), never scanned here.
 */
@:nullSafety(Strict)
final class AccessorClauseText {

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

}
