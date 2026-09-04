package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.OccurrenceScan;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.SourceText;
import anyparse.runtime.Span;

/**
 * Where a binding is VISIBLE — the scope geometry the `naming` and `no-underscore-prefix`
 * checks reason about before they dare rewrite a name.
 *
 * Split out of `Naming` because it is the one part of that check that answers a question about
 * the TREE rather than about a name: given an offset, which enclosing region does the binding
 * declared there reach, and which occurrences of the same spelling belong to a DIFFERENT binding.
 * `hxq clusters Naming src/anyparse/check` on the pre-split type put these members in their own
 * connected component, joined to the rest only through hub calls — the seam was measured, not
 * chosen. It was
 * already reached from outside: `NoUnderscorePrefix` called `enclosingScopeSpan` through an
 * `@:access(anyparse.check.Naming)`, which is what a shared question looks like before it has a
 * home.
 *
 * Two entry points, and they are NOT interchangeable; each function's own doc says which
 * direction of imprecision is safe for it. `enclosingScopeSpan` is the region to SCAN (wider =
 * more vetoes = fail-closed); `otherBindingSpans` decides which occurrences may be EXCLUDED from
 * the rename-completeness gate (wider = fewer vetoes = a rename that ships with a real reference
 * unrewritten), so it goes through the stricter `visibleRegion` instead.
 *
 * Not to be confused with `Rename.innermostOfKinds`, the same walk declared a second time and
 * resolved by a different rule: last match in walk order rather than largest `span.from`, and
 * with no `exclude`. `unit.query.InnermostScopeSpanParityTest` pins what that costs. The
 * tie-break difference is REAL and it is unreachable: the two answer differently only when two
 * matches share a `span.from` (`BindingScope` keeps the outer, `Rename` the inner), and the
 * Haxe grammar's own `scopeKinds` vocabulary never puts two of its nodes at the same start —
 * measured over a fixture spelling every scope-opening construct, at every offset in it, where
 * the two walks agree. `exclude` is the whole reason the two are kept apart.
 */
@:nullSafety(Strict)
final class BindingScope {

	/**
	 * The tightest enclosing scope span (whose kind is in `kinds`) containing `pos`, with the local
	 * FUNCTION declared AT `pos` excluded from the answer - the form every lookup made FROM a
	 * declaration position needs, and the reason `innermostSpanOfKinds` should not be called with one
	 * directly.
	 *
	 * A local `function` / `inline function` declaration is BOTH a binding and a `scopeKinds` node, so
	 * the raw walk answers with the declaration's OWN span while the scope its name binds into is the
	 * ENCLOSING one. Five sites need that pairing; three wrote it out by hand, `otherBindingSpans` and
	 * `NoUnderscorePrefix.isUnreferenced` did not. In `otherBindingSpans` the omission made a local
	 * function's call sites fall outside its "container", stay unattributed, and the completeness gate
	 * refuse an UNRELATED same-named binding's rename.
	 *
	 * NOT the only such kind: a method (`FnMember`) and a type declaration are `scopeKinds` nodes and
	 * decl hosts too, and `localFunctionDeclSpan` deliberately does not match them - widening it would
	 * change the comment-along container for members, which is a separate decision. The same
	 * unattributed-call-site refusal therefore still holds for a bare call to a same-named METHOD; it
	 * is fail-closed (a lost rename, never a wrong one) and is left standing.
	 */
	public static function enclosingScopeSpan(tree: QueryNode, kinds: Array<String>, pos: Int, shape: RefShape): Null<Span> {
		return innermostSpanOfKinds(tree, kinds, pos, localFunctionDeclSpan(tree, pos, shape));
	}

	/**
	 * The offsets, inside `tree`, of every occurrence of `name` that belongs to a binding OTHER than
	 * the one declared at `declFrom`.
	 *
	 * Fail-closed attribution: an occurrence is excluded as belonging to a different binding only
	 * when it sits inside THAT binding's own lexical container. The guard outlives the leak it was
	 * written for (a `case` arm now opens its own frame, `RefShape.branchScopeKinds`, so an arm local
	 * no longer captures a bare field use): any resolver over-reach puts the occurrence OUTSIDE the
	 * binding's container, where it stays uncovered and the completeness gate blocks the whole rename
	 * rather than silently excluding - and orphaning - a real reference.
	 */
	public static function otherBindingSpans(source: String, tree: QueryNode, name: String, declFrom: Int, shape: RefShape): Array<Span> {
		final out: Array<Span> = [];
		final seen: Array<Int> = [];
		final containerKinds: Array<String> = shape.scopeKinds.concat(['CaseBranch', 'DefaultBranch']);
		for (h in Refs.find(name, tree, shape)) {
			final bindingSpan: Null<Span> = h.bindingSpan;
			final boundFrom: Null<Int> = h.kind == RefKind.Decl ? h.span.from : (bindingSpan?.from);
			if (boundFrom == null || boundFrom == declFrom) continue;
			final off: Int = SourceText.identTokenOffset(source, h.span, name);
			if (off < 0) continue;
			final container: Null<Span> = visibleRegion(tree, containerKinds, boundFrom, shape);
			if (container == null || off < container.from || off >= container.to) continue;
			OccurrenceScan.pushUniqueSpan(out, seen, off, name.length);
		}
		return out;
	}

	/**
	 * The region in which the binding declared at `declFrom` is VISIBLE: its enclosing scope, but
	 * starting AT the declaration when the declaration is itself a scope opener (a local `function`).
	 *
	 * A STRICTER contract than `enclosingScopeSpan`, and the two must not be conflated. The four
	 * callers of that one read its answer as "the region I must SCAN", where a wider span means more
	 * vetoes - fail-closed. `otherBindingSpans` reads this one as "the region inside which I may
	 * EXCLUDE an occurrence from the completeness gate", where a wider span means FEWER vetoes and a
	 * rename that ships with a real reference unrewritten. Haxe does not hoist a local function, so a
	 * read before its declaration binds to whatever it shadows - a parameter, a member - and must stay
	 * uncovered. Clamping the lower bound is what keeps that read blocking while the call sites AFTER
	 * the declaration are still attributed. `declaringFileRenameSpans` applies the same rule to the
	 * binding being renamed (`bodyScoped`); this is its counterpart for the OTHER bindings.
	 *
	 * MEASURED INERT TODAY, and kept anyway. Swapping this call for `enclosingScopeSpan` leaves
	 * 13 797 tests green and the whole Pony `lint --all --fix` tree byte-identical (697 edits /
	 * 210 files / 8 passes, `diff -r` 0), because the clamp can only change an answer for an
	 * occurrence that `Refs` binds to the local function while sitting BEFORE its declaration —
	 * and a function-body frame is position-scoped, so `Refs` binds such a read to the outer
	 * binding instead. The clamp is the fail-closed side of a resolver property, not of a shape
	 * seen today: make a local-function frame hoist and it starts carrying weight.
	 */
	private static function visibleRegion(tree: QueryNode, kinds: Array<String>, declFrom: Int, shape: RefShape): Null<Span> {
		final own: Null<Span> = localFunctionDeclSpan(tree, declFrom, shape);
		final scope: Null<Span> = innermostSpanOfKinds(tree, kinds, declFrom, own);
		return if (scope == null)
			null
		else if (own == null)
			scope
		else
			new Span(declFrom, scope.to);
	}

	/**
	 * The tightest enclosing node span (whose kind is in `kinds`) containing `pos`, or null when none
	 * does. `exclude` drops the node occupying exactly that span from consideration.
	 *
	 * The raw walk, with `exclude` REQUIRED rather than optional so a caller has to decide: the two that
	 * exist (`enclosingScopeSpan`, `visibleRegion`) both derive it from `localFunctionDeclSpan`. Reach it
	 * through one of them, never directly from a declaration position. PRIVATE for the same reason.
	 */
	private static function innermostSpanOfKinds(node: QueryNode, kinds: Array<String>, pos: Int, exclude: Null<Span>): Null<Span> {
		// Re-bound as Ints: strict null-safety does not narrow a captured parameter inside the
		// nested walker. A null `exclude` becomes an impossible span, matching nothing.
		final excludeFrom: Int = exclude == null ? -1 : exclude.from;
		final excludeTo: Int = exclude == null ? -1 : exclude.to;
		var bestFrom: Int = -1;
		var best: Null<Span> = null;
		function walk(n: QueryNode): Void {
			final s: Null<Span> = n.span;
			if (
				s != null && s.from <= pos && pos < s.to && kinds.contains(n.kind) && s.from > bestFrom
				&& (s.from != excludeFrom || s.to != excludeTo)
			) {
				bestFrom = s.from;
				best = s;
			}
			for (c in n.children) walk(c);
		}
		walk(node);
		return best;
	}

	/**
	 * The span of the local FUNCTION declared at `declFrom`, or null when the declaration there is
	 * anything else. A local `function` is the one declaration kind that opens a scope its own NAME
	 * does not bind into - the name belongs to the enclosing body - so a scope lookup made FROM such a
	 * declaration must exclude the declaration's own node. `enclosingScopeSpan` is the one place that
	 * pairs this with the walk; nothing else needs it. A self-scoped binding (a loop iterator, a catch
	 * variable) is the opposite case and is deliberately not matched: its own node IS the scope its
	 * name lives in.
	 */
	private static function localFunctionDeclSpan(tree: QueryNode, declFrom: Int, shape: RefShape): Null<Span> {
		final kinds: Array<String> = (shape.localFunctionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
		if (kinds.length == 0) return null;
		var found: Null<Span> = null;
		function walk(n: QueryNode): Void {
			final s: Null<Span> = n.span;
			if (s != null && s.from == declFrom && kinds.contains(n.kind)) found = s;
			for (c in n.children) walk(c);
		}
		walk(tree);
		return found;
	}

}
