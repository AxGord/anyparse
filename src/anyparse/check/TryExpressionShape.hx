package anyparse.check;

import anyparse.query.QueryNode;
import anyparse.runtime.Span;

/**
 * One `try` statement decomposed for the two try-expression collapse rules: the try body's
 * VALUE and, per catch clause, the verbatim `catch (…)` header plus that clause's value.
 * `prefer-try-expression-assignment` fills the values with assignment r-values,
 * `prefer-try-expression-return` with returned expressions; the shape is what they share.
 */
typedef TryParts = {
	/** The try body's value expression -- the r-value / returned expression the collapse hoists. */
	var value: QueryNode;

	/** Per catch clause, in source order: the verbatim header text, its span, and the clause's value. */
	var catches: Array<{ header: String, headerSpan: Span, value: QueryNode }>;
}

/**
 * Machinery shared by `prefer-try-expression-assignment` and `prefer-try-expression-return`:
 * decomposing a statement-position `try` / `catch` into per-clause bodies, and assembling the
 * `try <value> catch (…) <value> …` expression text. The rules differ only in what each body
 * must be (a plain `=` assignment to one target vs a valued `return`); everything structural
 * lives here.
 *
 * The grammar surfaces THREE body shapes behind one kind pair -- a braced `{ stmt }`, a bare
 * statement, and (in the bare-body `try e catch (…) e;` form) a raw expression -- so every
 * consumer goes through `singleBody`, which normalises all three to the one node inside.
 */
@:nullSafety(Strict)
final class TryExpressionShape {

	/** A `try` node's children are [body, catch, catch, …] -- the body plus at least one clause. */
	private static inline final MIN_TRY_CHILD_COUNT: Int = 2;

	private function new() {}

	/**
	 * The ONE node a try / catch body holds: the sole child of a `{ … }` wrapping exactly one,
	 * or the bare statement / expression itself. Null when the body is a block of zero or
	 * several statements -- a deliberately grouped body is never collapsed, and an EMPTY catch
	 * (`catch (e:String) {}`) lands here too, which is what refuses it (the declaration's
	 * initializer would stay live on that path).
	 */
	public static function singleBody(body: QueryNode, blockStmtKind: Null<String>): Null<QueryNode> {
		if (blockStmtKind != null && body.kind == blockStmtKind) return body.children.length == 1 ? body.children[0] : null;
		return body;
	}

	/**
	 * Decompose `tryNode` into its body value and per-clause values, using `valueOf` to pull the
	 * value out of each body (the rule's own gate: a plain `=` r-value, a returned expression).
	 * Null unless the node has a body plus at least one clause, EVERY following child is a
	 * `catchKind` with exactly one body child, and `valueOf` accepts every body -- so one
	 * rethrowing / logging / empty catch refuses the whole `try`.
	 *
	 * Each clause's header is `catch (…)` sliced VERBATIM from the source up to its body, so a
	 * catch variable's type annotation (which the default projection folds into trivia) survives
	 * the rebuild exactly as written.
	 */
	public static function decompose(
		tryNode: QueryNode, source: String, catchKind: Null<String>, blockStmtKind: Null<String>, valueOf: (QueryNode) -> Null<QueryNode>
	): Null<TryParts> {
		if (catchKind == null || tryNode.children.length < MIN_TRY_CHILD_COUNT) return null;
		final body: Null<QueryNode> = singleBody(tryNode.children[0], blockStmtKind);
		if (body == null) return null;
		final value: Null<QueryNode> = valueOf(body);
		if (value == null) return null;
		final catches: Array<{ header: String, headerSpan: Span, value: QueryNode }> = [];
		for (i in 1...tryNode.children.length) {
			final clause: QueryNode = tryNode.children[i];
			if (clause.kind != catchKind || clause.children.length != 1) return null;
			final clauseSpan: Null<Span> = clause.span;
			final bodySpan: Null<Span> = clause.children[0].span;
			if (clauseSpan == null || bodySpan == null) return null;
			final clauseBody: Null<QueryNode> = singleBody(clause.children[0], blockStmtKind);
			if (clauseBody == null) return null;
			final clauseValue: Null<QueryNode> = valueOf(clauseBody);
			if (clauseValue == null) return null;
			catches.push({
				header: StringTools.rtrim(source.substring(clauseSpan.from, bodySpan.from)),
				headerSpan: new Span(clauseSpan.from, bodySpan.from),
				value: clauseValue
			});
		}
		return { value: value, catches: catches };
	}

	/**
	 * Assemble `try <value> catch (…) <value> …` from verbatim source slices. The `try` keyword
	 * is emitted rather than copied (the region it occupies also holds the dropped braces), so a
	 * comment there is caught by the caller's comment guard instead of riding along.
	 */
	public static function buildValue(parts: TryParts, source: String): Null<String> {
		final valueSrc: Null<String> = slice(source, parts.value);
		if (valueSrc == null) return null;
		final buf: StringBuf = new StringBuf();
		buf.add('try ');
		buf.add(valueSrc);
		for (c in parts.catches) {
			final clauseSrc: Null<String> = slice(source, c.value);
			if (clauseSrc == null) return null;
			buf.add(' ');
			buf.add(c.header);
			buf.add(' ');
			buf.add(clauseSrc);
		}
		return buf.toString();
	}

	/** Every span the rebuild copies VERBATIM out of the `try` -- the comment guard's kept set. */
	public static function keptSpans(parts: TryParts): Array<Span> {
		final kept: Array<Span> = [];
		final valueSpan: Null<Span> = parts.value.span;
		if (valueSpan != null) kept.push(valueSpan);
		for (c in parts.catches) {
			kept.push(c.headerSpan);
			final clauseSpan: Null<Span> = c.value.span;
			if (clauseSpan != null) kept.push(clauseSpan);
		}
		return kept;
	}

	/** `node`'s verbatim source slice, or null when it carries no span. */
	public static function slice(source: String, node: QueryNode): Null<String> {
		final span: Null<Span> = node.span;
		return span == null ? null : source.substring(span.from, span.to);
	}

}
