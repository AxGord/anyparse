package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.TryExpressionShape.TryParts;
import anyparse.check.TryExpressionShape.TrySeams;
import anyparse.query.BoolExprShape;
import anyparse.query.CanonicalEdit;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * Flags a local declaration whose initializer is a `try` EXPRESSION defaulting to `null` on
 * every catch clause, immediately followed by a null guard that leaves the function, and
 * collapses the two by moving the guard's terminator INTO every clause:
 *
 * ```haxe
 * final p:Process = try new Process(commandStr, commandArgs) catch (msg:String) null;
 * if (p == null) return;
 * // ->
 * final p:Process = try new Process(commandStr, commandArgs) catch (msg:String) return;
 * ```
 *
 * Purely structural (no type information). `Info` -- the code is correct, this is a
 * readability simplification. DEFAULT OFF. Shape-wise the downstream of
 * `prefer-try-expression-assignment`, which turns a `try` STATEMENT writing `null` in its catch
 * into exactly this declaration form. The two DO compose across `--fix` passes, measured on a
 * constructed input (`var p:P = null; try { p = new P(a); } catch (e:String) { p = null; }` plus
 * a null guard reaches the one-line form in three passes); no CORPUS instance exists, both
 * corpora holding zero sites for the assignment rule.
 *
 * The declaration keyword is copied VERBATIM: this check does one job (collapsing), and a
 * `var` -> `final` upgrade is `prefer-final`'s, which knows whether the local is reassigned.
 * The written `:type` is copied along with it, `Null<T>` wrapper included -- tightening it to
 * `T` would need the annotation as a NODE, and the default projection folds a local's type into
 * trivia, so the rule would have to hand-parse the slice it copies. `Null<T>` still accepts the
 * now-provably-non-null value, so nothing is lost by leaving it; narrowing a declared type is a
 * null-flow concern, not a collapse one.
 *
 * ## What is flagged
 *
 * A single-variable local declaration (`localDeclKinds`, one initializer child, not a
 * `var a = …, b = …` list) immediately followed -- same `ControlFlowSupport.blockKinds`
 * statement list, nothing between -- by an `if` guard, where:
 *
 * - the initializer is a `tryExpressionKinds` node whose EVERY catch clause body is exactly the
 *   bare `null` literal. One clause that rethrows, logs, falls through or is EMPTY refuses the
 *   site: the guard was never the only thing standing between that path and the code below;
 * - the try body `E` is NON-NULL BY CONSTRUCTION. This is the load-bearing gate, and it is a
 *   WHITELIST rather than a list of refusals: `new T(…)` and the object / array / string
 *   literals, nothing else. Before the collapse a null `E` ALSO hit the guard and left the
 *   function; after it, `E`'s null flows straight through into the code below -- a silent
 *   behaviour change. A call, an identifier, a field read, a cast: each could be null, so each
 *   is refused, and so is every shape nobody has thought of yet.
 *
 *   TWO KNOWN HOLES, both needing type information this check deliberately does not have, and
 *   both requiring an ABSTRACT to reach: `new T(…)` where `T` is an abstract whose inline
 *   constructor assigns a null (`this = s`), and any whitelist member implicitly converted by an
 *   `@:from` on the declaration's annotated type. In both the SHAPE is non-null and the VALUE
 *   reaching the local is not. They are why the rule is DEFAULT OFF and why its `--fix` is worth
 *   running behind a compiler oracle on a codebase that leans on abstracts;
 * - the guard is an `ifStatementKinds` node with NO else (an else branch has nowhere to go),
 *   whose condition is an `eqKind` comparison of the declared name against `null`. Either
 *   polarity is accepted -- `if (x == null)` and `if (null == x)` are the same guard;
 * - the guard's body is exactly one terminator -- bare, or a `{ … }` wrapping one -- and that
 *   statement leaves the function: a `valueReturnKinds` / `voidReturnKind` `return` or a
 *   `throwKinds` `throw`. A `break` / `continue` is NOT a terminator here: it means nothing
 *   inside an initializer expression, which is where the collapse puts it;
 * - the terminator does not READ the declared name (`if (x == null) return x;`) -- after the
 *   fold that is a self-reference in `x`'s own initializer, which the compiler rejects;
 * - the terminator does not read a name any catch clause BINDS. The collapse moves it inside the
 *   clause, so `catch (msg:String)` captures a `return msg` that used to name an outer binding --
 *   returning the caught message instead, or failing to compile when the two types differ. The
 *   mirror of `prefer-try-expression-assignment`'s shadowed-target gate, sharing its scan.
 *
 *   Both name gates go through `readsName`, which ORs the scope-correct `Refs` lookup with the
 *   structural `TryExpressionShape.referencesName`. Neither alone is sufficient: `Refs` does not
 *   project a BRACELESS `$x` interpolation read, so `throw new Error('bad: $x')` slipped the
 *   self-reference gate and the emitted initializer referred to its own variable;
 * - the terminator's RIGHT EDGE is not an open `try` (`TryExpressionShape.endsOpen`). Haxe binds
 *   a trailing `catch` to the innermost open `try`, so with two or more clauses the header the
 *   rebuild appends after the first terminator would re-parent onto it. A VALUE in that position
 *   is parenthesised; a `return` / `throw` cannot be, so the site is refused instead.
 *
 * ### Comments and `#if`
 *
 * No comment may sit in a region the rebuild drops -- the `= try` seam, each clause's `null`,
 * the whole `if (…)` header, the guard's braces and the two `;`. The declaration prefix, `E`,
 * each `catch (…)` header and the terminator are copied verbatim, so a comment inside one rides
 * along; anything else -- a comment in the GAP between the declaration and its guard included --
 * leaves the pair unflagged rather than silently losing it. One exception to "inside a copied
 * region rides along": a DANGLING line comment, one with no newline after it within its own
 * slice, refuses the site (`TryExpressionShape.danglingLineComment`) -- whatever the rebuild
 * appends after that slice, the next `catch (…)` header or the terminating `;`, would land
 * behind the `//`.
 *
 * The pair is read off the BRANCH-AWARE projection (`CheckScan.parseBranchAwareOrNull`): a
 * declaration and its guard inside a `#if sys` region are children of a conditional node, not of
 * a block, so on the plain tree the adjacency this check needs is invisible -- and the canary
 * site sits in exactly such a region.
 *
 * ## Autofix
 *
 * `fix` replaces the declaration THROUGH the guard with
 * `<decl prefix> = try <E> catch (…) <terminator> …;`. Each `catch (…)` header is sliced verbatim
 * from the source (so the exception variable's type annotation, which the default projection
 * folds into trivia, survives exactly as written), `E` from its span, and the terminator from
 * its own -- minus its trailing `;`, one being emitted at the end for the whole declaration. `E`
 * is never parenthesised: no member of the non-null whitelist can end in an open `try` (each
 * closes with `)`, `]`, `}` or a quote), so nothing it is followed by can re-parent onto it.
 *
 * Needs `tryExpressionKinds`, `catchClauseKind`, `nullLiteralKind`, `eqKind`,
 * `ifStatementKinds`, `localDeclKinds`, `controlFlowSupport`, a non-empty terminator set
 * (`valueReturnKinds` / `voidReturnKind` / `throwKinds`) and a non-empty non-null set
 * (`newExprKind` / `arrayLiteralKind` / `objectLiteralKind` / `stringLiteralKinds`) -- any unset
 * group makes the check a no-op. `blockStmtKind` is optional (without it only a bare guard body
 * is recognised), `parenKind` unwraps a parenthesized initializer, condition or operand, and
 * `stringInterpIdentKind` widens the capture scan to braceless `$name` reads.
 */
@:nullSafety(Strict)
final class TryCatchNullGuard implements Check implements DefaultOff {

	/** An `if` with no `else` has exactly [condition, then-branch] children. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	/** A binary comparison node has exactly [left, right] children. */
	private static inline final COMPARISON_CHILD_COUNT: Int = 2;

	private static inline final MESSAGE: String =
		'this null-defaulting try-expression and its following null guard can collapse into the catch clauses';

	public function new() {}

	public function id(): String {
		return 'try-catch-null-guard';
	}

	public function description(): String {
		return 'a declaration initialized by a try-expression defaulting to null, immediately followed by an if (x == null) '
			+ 'return/throw guard, collapsible by moving the terminator into every catch clause';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		return seams == null ? [] : [
			for (entry in files) for (m in collect(plugin, entry.source, seams))
				{
					file: entry.file,
					span: m.keySpan,
					rule: 'try-catch-null-guard',
					severity: Severity.Info,
					message: MESSAGE
				}
		];
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final byKey: Map<String, Match> = [];
		for (m in collect(plugin, source, seams)) byKey['${m.keySpan.from}:${m.keySpan.to}'] = m;
		return CanonicalEdit.dropContainedEdits(
			CheckScan.collectSpanEdits(violations, byKey, (m, _) -> ({ span: m.editSpan, text: m.text }))
		);
	}

	/** Every collapsible declaration/guard pair in `source`, read off the branch-aware projection (empty when it does not parse). */
	private static function collect(plugin: GrammarPlugin, source: String, s: Seams): Array<Match> {
		final tree: Null<QueryNode> = CheckScan.parseBranchAwareOrNull(plugin, source);
		if (tree == null) return [];
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = SourceComments.collectCommentTokens(plugin.lexicalRegions(source));
		final out: Array<Match> = [];
		collectMatches(tree, source, comments, s, out);
		return out;
	}

	/** Bundle the required + optional kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final tryKinds: Null<Array<String>> = shape.tryExpressionKinds;
		if (tryKinds == null || tryKinds.length == 0) return null;
		final catchKind: Null<String> = shape.catchClauseKind;
		final nullKind: Null<String> = shape.nullLiteralKind;
		final eqKind: Null<String> = shape.eqKind;
		if (catchKind == null || nullKind == null || eqKind == null) return null;
		final ifKinds: Null<Array<String>> = shape.ifStatementKinds;
		// Split, not `||`-chained: strict null-safety carries a narrowing fact into a later `||`
		// operand from the FIRST operand only.
		if (ifKinds == null || ifKinds.length == 0) return null;
		final declKinds: Null<Array<String>> = shape.localDeclKinds;
		if (declKinds == null || declKinds.length == 0) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		final termKinds: Array<String> = terminatorKinds(shape);
		final nonNullKinds: Array<String> = nonNullValueKinds(shape);
		if (termKinds.length == 0 || nonNullKinds.length == 0) return null;
		// A `try` nested in a try STATEMENT re-parents a following `catch` just as much as one
		// nested in a try EXPRESSION, so the terminator's open-edge test spans both sets.
		final allTryKinds: Array<String> = tryKinds.concat(shape.tryStatementKinds ?? []);
		return {
			tryKinds: tryKinds,
			tryShape: { catchKind: catchKind, blockStmtKind: shape.blockStmtKind, tryKinds: allTryKinds },
			nullKind: nullKind,
			eqKind: eqKind,
			ifKinds: ifKinds,
			declKinds: declKinds,
			termKinds: termKinds,
			nonNullKinds: nonNullKinds,
			identKind: shape.identKind,
			stringInterpKind: shape.stringInterpIdentKind,
			parenKind: shape.parenKind,
			blockStmtKind: shape.blockStmtKind,
			blockKinds: support.blockKinds(),
			shape: shape
		};
	}

	/** The statement kinds that LEAVE the function — a valued / value-less `return` or a `throw`. */
	private static function terminatorKinds(shape: RefShape): Array<String> {
		final kinds: Array<String> = (shape.valueReturnKinds ?? []).concat(shape.throwKinds ?? []);
		final voidReturn: Null<String> = shape.voidReturnKind;
		if (voidReturn != null) kinds.push(voidReturn);
		return kinds;
	}

	/**
	 * The expression kinds whose value is NON-NULL by construction — a constructor call and the
	 * object / array / string literals. A positive whitelist by design (see the class doc): the
	 * complement is unbounded and every shape outside it must fail closed.
	 */
	private static function nonNullValueKinds(shape: RefShape): Array<String> {
		final kinds: Array<String> = (shape.stringLiteralKinds ?? []).copy();
		for (kind in [shape.newExprKind, shape.arrayLiteralKind, shape.objectLiteralKind]) if (kind != null) kinds.push(kind);
		return kinds;
	}

	/** Collect every collapsible declaration/guard pair reachable under `node`. */
	private static function collectMatches(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, out: Array<Match>
	): Void {
		if (s.blockKinds.contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length - 1) {
				final m: Null<Match> = match(kids[i], kids[i + 1], source, comments, s);
				if (m != null) out.push(m);
			}
		}
		for (c in node.children) collectMatches(c, source, comments, s, out);
	}

	/**
	 * The collapse match for `decl` immediately followed by `guard`, or null when they are not a
	 * null-defaulting try-expression declaration and its terminating null guard (see the class
	 * doc for every gate).
	 */
	private static function match(
		decl: QueryNode, guard: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		// A multi-variable list (`var a = …, b = …;`) carries its continuation as a SECOND child, so
		// the arity check alone refuses it — no `isMultiDeclarator` call is reachable past this.
		if (!s.declKinds.contains(decl.kind) || decl.children.length != 1) return null;
		final name: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		final guardSpan: Null<Span> = guard.span;
		if (name == null || declSpan == null || guardSpan == null) return null;

		final init: QueryNode = decl.children[0];
		if (!s.tryKinds.contains(BoolExprShape.unwrapParens(init, s.parenKind).kind)) return null;
		final bound: Array<String> = [];
		final parts: Null<TryParts> = decomposeNullDefaulting(BoolExprShape.unwrapParens(init, s.parenKind), source, comments, s, bound);
		if (parts == null) return null;
		if (!s.nonNullKinds.contains(BoolExprShape.unwrapParens(parts.value, s.parenKind).kind)) return null;

		final term: Null<QueryNode> = terminator(guard, name, s);
		if (term == null) return null;
		final termSpan: Null<Span> = term.span;
		if (termSpan == null) return null;
		if (readsName(term, name, s)) return null; // a self-reference in the folded initializer
		if (bound.exists(clauseName -> readsName(term, clauseName, s))) return null;
		if (terminatorEndsOpen(term, s.tryShape.tryKinds)) return null;
		final termText: Null<String> = terminatorText(source, termSpan);
		final prefix: Null<{ text: String, keptTo: Int }> = TryExpressionShape.declPrefix(declSpan, init, source);
		final valueSrc: Null<String> = TryExpressionShape.slice(source, parts.value);
		return termText == null || prefix == null || valueSrc == null
			? null
			: rebuild(declSpan, guardSpan, prefix, valueSrc, parts, termSpan, termText, source, comments);
	}

	/**
	 * The finished match for an already-gated pair — the emitted text plus the two comment guards
	 * that depend on it. Split out of `match` so neither function has to be read whole to follow
	 * the other: everything above is REFUSAL, everything here is CONSTRUCTION.
	 */
	private static function rebuild(
		declSpan: Span, guardSpan: Span, prefix: { text: String, keptTo: Int }, valueSrc: String, parts: TryParts, termSpan: Span,
		termText: String, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Null<Match> {
		// Both slices are copied onto ONE line, so a `//` at the end of either comments out what the
		// rebuild appends after it — the `= try …` for the prefix, a `catch (…)` header or the
		// terminating `;` for the terminator. Each span is the EMITTED region, not the node's: the
		// prefix and the terminator are both rtrimmed (the terminator also loses its `;`), and a
		// `//` can sit in exactly the tail that trimming removes.
		final prefixSpan: Span = new Span(declSpan.from, declSpan.from + prefix.text.length);
		final termEmitted: Span = new Span(termSpan.from, termSpan.from + termText.length);
		if (TryExpressionShape.danglingLineComment(source, prefixSpan, comments)) return null;
		if (TryExpressionShape.danglingLineComment(source, termEmitted, comments)) return null;

		// Built by hand rather than from `TryExpressionShape.keptSpans`: that set includes each
		// clause's VALUE, and here every one of them is the `null` the terminator REPLACES — a
		// comment sitting on one goes nowhere, so it must fail the guard.
		final kept: Array<Span> = [new Span(declSpan.from, prefix.keptTo), termSpan];
		final valueSpan: Null<Span> = parts.value.span;
		if (valueSpan != null) kept.push(valueSpan);
		for (c in parts.catches) kept.push(c.headerSpan);
		final region: Span = new Span(declSpan.from, guardSpan.to);
		return IfExpressionChain.droppedComment(region, kept, comments) ? null : {
			keySpan: declSpan,
			editSpan: region,
			text: build(prefix.text, valueSrc, parts, termText)
		};
	}

	/**
	 * Decompose `tryExpr` when EVERY catch clause body is exactly the bare `null` literal; null
	 * otherwise. The try body itself is taken as-is here — its own gate (non-null by
	 * construction) is the caller's, applied to `parts.value`. Each clause's exception variable is
	 * appended to `bound` on the way through, for the caller's capture gate.
	 */
	private static function decomposeNullDefaulting(
		tryExpr: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, bound: Array<String>
	): Null<TryParts> {
		return TryExpressionShape.decompose(tryExpr, source, comments, s.tryShape, (body, clause) -> {
			if (clause == null) return body;
			if (body.kind != s.nullKind) return null;
			final name: Null<String> = clause.name;
			if (name != null) bound.push(name);
			return body;
		});
	}

	/**
	 * Whether `term` mentions `name` at all. Both name gates ask it, of different names: the
	 * DECLARED one (whose mention would self-reference the folded initializer) and each name a
	 * catch clause BINDS (which the collapse would capture, since the terminator moves inside the
	 * clause — silently returning the caught value instead of the outer one, or failing to compile
	 * when their types differ; the mirror of `prefer-try-expression-assignment`'s shadowed-target
	 * gate).
	 *
	 * `Refs` alone is NOT enough, though it is scope-correct where it does look: it does not
	 * project a BRACELESS `$name` interpolation read, so `throw new Error('bad: $p')` passed the
	 * self-reference gate and the fix emitted an initializer referring to its own variable
	 * (`Unknown identifier : p`). The structural scan catches that form and the two are OR-ed —
	 * conservative in the only direction that matters, since a false "mentions it" merely refuses
	 * the site.
	 */
	private static function readsName(term: QueryNode, name: String, s: Seams): Bool {
		return Refs.find(name, term, s.shape).length > 0 || TryExpressionShape.referencesName(term, name, s.identKind, s.stringInterpKind);
	}

	/**
	 * The guard's terminator when `guard` is an else-less `if` comparing `name` against `null`
	 * with `==` (either operand order) and its body is exactly one function-leaving statement;
	 * null otherwise.
	 */
	private static function terminator(guard: QueryNode, name: String, s: Seams): Null<QueryNode> {
		if (!s.ifKinds.contains(guard.kind) || guard.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
		final cond: QueryNode = BoolExprShape.unwrapParens(guard.children[0], s.parenKind);
		if (cond.kind != s.eqKind || cond.children.length != COMPARISON_CHILD_COUNT) return null;
		if (!comparesToNull(cond, name, s)) return null;
		final body: Null<QueryNode> = TryExpressionShape.singleBody(guard.children[1], s.blockStmtKind);
		return body != null && s.termKinds.contains(body.kind) ? body : null;
	}

	/** Whether `cond`'s two operands are the `null` literal and a plain `name` reference, in either order. */
	private static function comparesToNull(cond: QueryNode, name: String, s: Seams): Bool {
		final left: QueryNode = BoolExprShape.unwrapParens(cond.children[0], s.parenKind);
		final right: QueryNode = BoolExprShape.unwrapParens(cond.children[1], s.parenKind);
		final subject: QueryNode = left.kind == s.nullKind ? right : left;
		final literal: QueryNode = left.kind == s.nullKind ? left : right;
		return literal.kind == s.nullKind && subject.kind == s.identKind && subject.name == name;
	}

	/**
	 * Whether the terminator's EMITTED text -- its slice minus the trailing `;` -- ends in an open
	 * `try`, which a following `catch (…)` header would re-parent onto. Asked of the terminator's
	 * last CHILD (the returned / thrown expression) rather than of the statement itself:
	 * `TryExpressionShape.endsOpen` walks the rightmost spine while each child ends exactly where
	 * its parent does, and the statement's own span ends one character later, at the `;` the
	 * rebuild strips -- so asking the statement always answers "sealed". A value-less `return;`
	 * has no child and can never end open.
	 */
	private static function terminatorEndsOpen(term: QueryNode, kinds: Array<String>): Bool {
		final last: Null<QueryNode> = term.children.length == 0 ? null : term.children[term.children.length - 1];
		return last != null && TryExpressionShape.endsOpen(last, kinds);
	}

	/**
	 * The terminator as it is emitted: its verbatim slice MINUS the trailing `;`, one being
	 * emitted once at the end for the whole declaration (keeping it would close the declaration
	 * in front of the second clause's header). Null when the slice does not end in `;` — an
	 * unexpected shape the rebuild has no reading for.
	 */
	private static function terminatorText(source: String, span: Span): Null<String> {
		final trimmed: String = source.substring(span.from, span.to).rtrim();
		return !trimmed.endsWith(';') ? null : trimmed.substring(0, trimmed.length - 1).rtrim();
	}

	/** Assemble `<prefix> = try <value> catch (…) <term> …;` — every clause takes the SAME terminator. */
	private static function build(prefix: String, valueSrc: String, parts: TryParts, termText: String): String {
		final buf: StringBuf = new StringBuf();
		buf.add(prefix);
		buf.add(' = try ');
		buf.add(valueSrc);
		for (c in parts.catches) {
			buf.add(' ');
			buf.add(c.header);
			buf.add(' ');
			buf.add(termText);
		}
		buf.add(';');
		return buf.toString();
	}

}

/** The kinds `TryCatchNullGuard` reads. */
private typedef Seams = {
	var tryKinds: Array<String>;
	var tryShape: TrySeams;
	var nullKind: String;
	var eqKind: String;
	var ifKinds: Array<String>;
	var declKinds: Array<String>;
	var termKinds: Array<String>;
	var nonNullKinds: Array<String>;
	var identKind: String;
	var stringInterpKind: Null<String>;
	var parenKind: Null<String>;
	var blockStmtKind: Null<String>;
	var blockKinds: Array<String>;
	var shape: RefShape;
}

/** A collapsible pair: the finding key span (the declaration), the replaced region, and the built replacement. */
private typedef Match = {
	var keySpan: Span;
	var editSpan: Span;
	var text: String;
}
