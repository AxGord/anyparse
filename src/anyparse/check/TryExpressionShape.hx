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

	/** Per catch clause, in source order. */
	var catches: Array<TryCatchPart>;
}

/** One decomposed catch clause: its verbatim `catch (…)` header, that header's span, and the clause's value. */
typedef TryCatchPart = {
	var header: String;
	var headerSpan: Span;
	var value: QueryNode;
}

/**
 * The kinds `TryExpressionShape` reads, bundled so both consumers pass one argument:
 * the catch-clause kind, the optional statement-block kind (unset -> only bare bodies are
 * recognised) and the `try` kinds a value must be parenthesised for (`operand`).
 */
typedef TrySeams = {
	var catchKind: Null<String>;
	var blockStmtKind: Null<String>;
	var tryKinds: Array<String>;
}

/**
 * Machinery shared by `prefer-try-expression-assignment` and `prefer-try-expression-return`:
 * decomposing a statement-position `try` / `catch` into per-clause bodies, and assembling the
 * `try <value> catch (…) <value> …` expression text. The rules differ only in what each body
 * must be (a plain `=` assignment to one target vs a valued `return`); everything structural
 * lives here, including the two hazards of turning a multi-line statement into ONE expression:
 *
 * - a LINE comment anywhere inside the `try` refuses it. The rebuild joins every copied slice
 *   onto one line, so a `//` -- in a `catch (e:T) // why` header, trailing an r-value --
 *   comments out whatever the emitter appends after it, up to and including the terminating
 *   `;`. The dropped-comment guard cannot catch this: such a comment sits INSIDE a
 *   verbatim-copied span, so it is classified as riding along;
 * - a value whose subtree holds a `try` is PARENTHESISED. Haxe binds a trailing `catch` to the
 *   innermost open `try`, so an unwrapped nested one re-parents every clause that follows it
 *   -- changing which handler sees an exception, with no compile error unless the clause types
 *   collide. Both rules' own fixed points manufacture the shape by re-reading what they wrote.
 *
 * The grammar surfaces THREE body shapes behind one kind pair -- a braced `{ stmt }`, a bare
 * statement, and (in the bare-body `try e catch (…) e;` form) a raw expression -- so every
 * consumer goes through `singleBody`, which normalises all three to the one node inside.
 *
 * `decompose` hands each clause to the caller's `valueOf` alongside the clause NODE, so a rule
 * that cares about the exception variable it binds (the assignment rule's shadowed-target
 * gate) can see it.
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
		tryNode: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: TrySeams,
		valueOf: (QueryNode, Null<QueryNode>) -> Null<QueryNode>
	): Null<TryParts> {
		final trySpan: Null<Span> = tryNode.span;
		if (s.catchKind == null || trySpan == null || tryNode.children.length < MIN_TRY_CHILD_COUNT) return null;
		if (holdsLineComment(trySpan, comments)) return null;
		final body: Null<QueryNode> = singleBody(tryNode.children[0], s.blockStmtKind);
		if (body == null) return null;
		final value: Null<QueryNode> = valueOf(body, null);
		if (value == null) return null;
		final catches: Array<TryCatchPart> = [];
		for (i in 1...tryNode.children.length) {
			final clause: QueryNode = tryNode.children[i];
			if (clause.kind != s.catchKind || clause.children.length != 1) return null;
			final clauseSpan: Null<Span> = clause.span;
			final bodySpan: Null<Span> = clause.children[0].span;
			if (clauseSpan == null || bodySpan == null) return null;
			final clauseBody: Null<QueryNode> = singleBody(clause.children[0], s.blockStmtKind);
			if (clauseBody == null) return null;
			final clauseValue: Null<QueryNode> = valueOf(clauseBody, clause);
			if (clauseValue == null) return null;
			// Re-bound to a non-null local: narrowing does not reach the struct literal below.
			final resolved: QueryNode = clauseValue;
			catches.push({
				header: StringTools.rtrim(source.substring(clauseSpan.from, bodySpan.from)),
				headerSpan: new Span(clauseSpan.from, bodySpan.from),
				value: resolved
			});
		}
		return { value: value, catches: catches };
	}

	/**
	 * Assemble `try <value> catch (…) <value> …` from verbatim source slices. The `try` keyword
	 * is emitted rather than copied (the region it occupies also holds the dropped braces), so a
	 * comment there is caught by the caller's comment guard instead of riding along.
	 */
	public static function buildValue(parts: TryParts, source: String, s: TrySeams): Null<String> {
		final valueSrc: Null<String> = operand(source, parts.value, s);
		if (valueSrc == null) return null;
		final buf: StringBuf = new StringBuf();
		buf.add('try ');
		buf.add(valueSrc);
		for (c in parts.catches) {
			final clauseSrc: Null<String> = operand(source, c.value, s);
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

	/**
	 * Whether a LINE comment sits anywhere inside `span`. The collapse joins every copied
	 * slice onto ONE line, so a `//` comment in any of them — a `catch (e:T) // why` header,
	 * a trailing note on an r-value — comments out whatever the emitter appends next,
	 * including the terminating `;`. The dropped-comment guard cannot see this: such a
	 * comment is INSIDE a kept span, so it is classified as riding along, and the result
	 * either fails the `--fix` re-parse gate (which then skips the WHOLE file, losing every
	 * other rule's fixes too) or, worse, still parses. Block comments are inline-safe and
	 * keep riding along.
	 */
	private static function holdsLineComment(span: Span, comments: Array<{ from: Int, to: Int, isLine: Bool }>): Bool {
		for (tok in comments) if (tok.isLine && tok.from >= span.from && tok.to <= span.to) return true;
		return false;
	}

	/**
	 * One value slice as it is emitted: verbatim, PARENTHESISED when its subtree holds a
	 * `try`. Haxe binds a trailing `catch` to the INNERMOST open `try`, so an unwrapped
	 * nested one re-parents the clauses that follow it —
	 * `try try a catch (e:E) b catch (f:F) c` hands `f:F` to the inner `try`, silently
	 * moving which handler sees an exception raised in `b` (and, when the two clause types
	 * collide, failing to compile). Both this rule family's own output and hand-written
	 * try-expressions reach the shape, since the fixed point re-reads what it just wrote.
	 */
	private static function operand(source: String, node: QueryNode, s: TrySeams): Null<String> {
		final src: Null<String> = slice(source, node);
		return src == null ? null : (holdsKind(node, s.tryKinds) ? '($src)' : src);
	}

	/** Whether `node` or any descendant has one of `kinds`. */
	private static function holdsKind(node: QueryNode, kinds: Array<String>): Bool {
		if (kinds.contains(node.kind)) return true;
		for (c in node.children) if (holdsKind(c, kinds)) return true;
		return false;
	}

}
