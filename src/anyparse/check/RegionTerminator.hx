package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using StringTools;

/**
 * The terminator a statement-position conditional-compilation region owns although its PARENT's
 * span holds it. A region whose last branch ends unterminated (`else #if d b() #else c() #end;`)
 * is closed by the `;` after its `#end`: the grammar parks that `;` in the enclosing `if` / loop
 * slot or in a following empty statement, so the region's own span stops at `#end`. A fix that
 * moves, swaps or deletes around such a region must carry the terminator with it, or the next
 * statement fails with `Missing ;`.
 *
 * Grammar-agnostic: the region kind is `RefShape.conditionalMemberKind`, the terminator
 * `RefShape.statementTerminator`; with either unset no region owns anything past its span.
 */
@:nullSafety(Strict)
final class RegionTerminator {

	/**
	 * `node`'s span extended over the terminator that directly follows it (whitespace only
	 * between) when `node` is a region, else `node`'s own span. Null when `node` has no span.
	 */
	public static function ownedSpan(node: QueryNode, source: String, shape: RefShape): Null<Span> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final at: Int = terminatorAt(node, span, source, shape);
		return at < 0 ? span : new Span(span.from, at + (shape.statementTerminator ?? '').length);
	}

	/** The source of `ownedSpan`, or null when `node` has no span. */
	public static function ownedText(node: QueryNode, source: String, shape: RefShape): Null<String> {
		final span: Null<Span> = ownedSpan(node, source, shape);
		return span == null ? null : source.substring(span.from, span.to);
	}

	/**
	 * Whether `node` is a region that owns NO terminator in the source: moved from a slot some
	 * following token closes (`if (c) #if … #end else …`) into one nothing closes, it may need a
	 * terminator the fix cannot prove it lacks, so such a move is refused.
	 */
	public static function unterminatedRegion(node: QueryNode, source: String, shape: RefShape): Bool {
		final span: Null<Span> = node.span;
		return span != null && isRegion(node, shape) && terminatorAt(node, span, source, shape) < 0;
	}

	/** Whether the empty statement `empty` is the terminator of the region `prev` directly before it. */
	public static function terminatesRegion(prev: Null<QueryNode>, empty: QueryNode, source: String, shape: RefShape): Bool {
		final prevSpan: Null<Span> = prev?.span;
		final emptySpan: Null<Span> = empty.span;
		return prev != null && prevSpan != null && emptySpan != null && terminatorAt(prev, prevSpan, source, shape) == emptySpan.from;
	}

	/** The offset of the terminator directly after region `node`, or -1. */
	private static function terminatorAt(node: QueryNode, span: Span, source: String, shape: RefShape): Int {
		final term: Null<String> = shape.statementTerminator;
		if (term == null || term == '' || !isRegion(node, shape)) return -1;
		var at: Int = span.to;
		while (at < source.length && source.isSpace(at)) at++;
		return source.substr(at, term.length) == term ? at : -1;
	}

	private static inline function isRegion(node: QueryNode, shape: RefShape): Bool {
		final kind: Null<String> = shape.conditionalMemberKind;
		return kind != null && node.kind == kind;
	}

}
