package anyparse.check;

import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using StringTools;

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
 * Machinery shared by the three try-expression rules -- `prefer-try-expression-assignment`,
 * `prefer-try-expression-return` and `try-catch-null-guard`: decomposing a `try` / `catch` into
 * per-clause bodies, and assembling the `try <value> catch (…) <value> …` expression text. The
 * first two differ only in what each body must be (a plain `=` assignment to one target vs a
 * valued `return`); the third reads a `try` already in EXPRESSION position and replaces each
 * clause's value rather than hoisting it, so it uses the decomposition and the slice / comment
 * helpers but not `buildValue`. Everything structural lives here, including the two hazards of
 * turning a multi-line statement into ONE expression:
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

	/**
	 * The ONE node a try / catch body holds: the sole child of a `{ … }` wrapping exactly one,
	 * or the bare statement / expression itself. Null when the body is a block of zero or
	 * several statements -- a deliberately grouped body is never collapsed, and an EMPTY catch
	 * (`catch (e:String) {}`) lands here too, which is what refuses it (the declaration's
	 * initializer would stay live on that path).
	 */
	public static function singleBody(body: QueryNode, blockStmtKind: Null<String>): Null<QueryNode> {
		return if (blockStmtKind == null || body.kind != blockStmtKind)
			body
		else if (body.children.length == 1)
			body.children[0]
		else
			null;
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
		final body: Null<QueryNode> = singleBody(tryNode.children[0], s.blockStmtKind);
		if (body == null) return null;
		final value: Null<QueryNode> = valueOf(body, null);
		if (value == null || danglingLineComment(source, value.span, comments)) return null;
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
			final header: String = source.substring(clauseSpan.from, bodySpan.from).rtrim();
			// The header is emitted RTRIMMED, so its effective end is where the copy stops —
			// testing against `bodySpan.from` would see the newline the rtrim just removed.
			final headerSpan: Span = new Span(clauseSpan.from, clauseSpan.from + header.length);
			if (danglingLineComment(source, headerSpan, comments) || danglingLineComment(source, resolved.span, comments)) return null;
			catches.push({ header: header, headerSpan: headerSpan, value: resolved });
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

	/**
	 * A local declaration's own prefix (`var x:T`, keyword and written type verbatim — the `var`
	 * -> `final` upgrade is `prefer-final`'s) plus the offset up to which the declaration source
	 * is copied verbatim, the kept region for a caller's comment guard: before the `=` for an
	 * initialized declaration, before the trailing `;` for a bare one. Null on a malformed
	 * declaration.
	 *
	 * The written type is sliced rather than read off a node because the default projection folds
	 * a local's `:type` into trivia — there is no annotation child to copy.
	 */
	public static function declPrefix(declSpan: Span, init: Null<QueryNode>, source: String): Null<{ text: String, keptTo: Int }> {
		final prefixEnd: Int = if (init != null) {
			final initSpan: Null<Span> = init.span;
			if (initSpan == null) return null;
			final eq: Int = source.lastIndexOf('=', initSpan.from);
			if (eq < declSpan.from) return null;
			eq;
		} else {
			if (declSpan.to <= declSpan.from || source.charAt(declSpan.to - 1) != ';') return null;
			declSpan.to - 1;
		}
		return { text: source.substring(declSpan.from, prefixEnd).rtrim(), keptTo: prefixEnd };
	}

	/** `node`'s verbatim source slice, or null when it carries no span. */
	public static function slice(source: String, node: QueryNode): Null<String> {
		final span: Null<Span> = node.span;
		return span == null ? null : source.substring(span.from, span.to);
	}

	/**
	 * Whether any descendant of `node` (or `node` itself) is an occurrence of `name` -- a plain
	 * `identKind` reference or a `stringInterpKind` one (a braceless `$name` inside a
	 * single-quoted string, which projects as a distinct kind).
	 *
	 * Both consumers ask it about the SAME hazard from opposite ends: moving text across a
	 * `catch (…)` boundary re-binds every name that clause declares. `prefer-try-expression-assignment`
	 * asks whether a clause's exception variable shadows the assignment TARGET; `try-catch-null-guard`
	 * asks whether it captures a name the TERMINATOR it moves inward reads.
	 */
	public static function referencesName(node: QueryNode, name: String, identKind: String, stringInterpKind: Null<String>): Bool {
		if ((node.kind == identKind || node.kind == stringInterpKind) && node.name == name) return true;
		for (c in node.children) if (referencesName(c, name, identKind, stringInterpKind)) return true;
		return false;
	}

	/**
	 * Whether `node`'s RIGHT EDGE is an open `try` -- one of `kinds` reached by walking the last
	 * child while that child ends exactly where its parent does. A `try` sealed behind a closing
	 * bracket cannot absorb anything (`g(1, try a catch (e:T) b)` ends at the `)`), so the walk
	 * stops there; one at the tail can (`x + try a catch (e:T) b`), so the walk reaches it.
	 *
	 * The same rightmost-spine test `RefShape.separatorGreedyExprKinds` documents for the mirror
	 * question in `redundant-parens`. A whole-subtree scan would answer this one too, but by
	 * over-parenthesising every sealed `try` -- and those parens are permanent, since no delimited
	 * host encloses a try-expression for `redundant-parens` to strip them from.
	 *
	 * Public for the third consumer, `try-catch-null-guard`, which asks the same question about
	 * a slice it CANNOT parenthesise (a `return` / `throw` terminator) and so refuses the site
	 * instead of wrapping it. That caller passes the terminator's returned / thrown CHILD, not
	 * the statement: a statement's span ends at the `;` its rebuild strips, one character past
	 * its last child, which would stop the spine walk at the top and always answer "sealed".
	 */
	public static function endsOpen(node: QueryNode, kinds: Array<String>): Bool {
		var current: QueryNode = node;
		while (true) {
			if (kinds.contains(current.kind)) return true;
			final span: Null<Span> = current.span;
			final last: Null<QueryNode> = current.children.length == 0 ? null : current.children[current.children.length - 1];
			final lastSpan: Null<Span> = last?.span;
			// Split, not `||`-chained: strict null-safety carries a narrowing fact into a later
			// `||` operand from the FIRST operand only.
			if (last == null || span == null || lastSpan == null) return false;
			if (lastSpan.to != span.to) return false;
			current = last;
		}
	}

	/**
	 * Whether a LINE comment inside `span` has NO newline after it within the span -- i.e. it is
	 * the last thing on its line in a slice the rebuild copies, so whatever the collapse appends
	 * next (the following `catch (…)` header, the terminating `;`) lands behind the `//`.
	 *
	 * The narrow form matters in both directions. A `//` EARLIER in a multi-line slice is
	 * harmless: the slice is copied verbatim, newlines included, so the append still starts on a
	 * fresh line -- refusing those would drop correct sites (a comment inside a multi-line
	 * argument list). And the guard cannot be delegated to the dropped-comment check, which
	 * classifies exactly these comments as SAFE: they sit INSIDE a verbatim-copied span, which is
	 * its definition of riding along.
	 *
	 * Each caller passes the spans IT copies -- so a rule that also copies something outside the
	 * `try` (the assignment rule's declaration prefix) must test that region too.
	 */
	public static function danglingLineComment(
		source: String, span: Null<Span>, comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Bool {
		if (span == null) return false;
		for (tok in comments) if (
			tok.isLine && tok.from >= span.from && tok.to <= span.to && source.substring(tok.to, span.to).indexOf('\n') < 0
		)
			return true;
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
		return if (src == null)
			null
		else if (endsOpen(node, s.tryKinds))
			'($src)'
		else
			src;
	}

}
