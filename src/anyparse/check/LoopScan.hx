package anyparse.check;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.OccurrenceScan;
import anyparse.query.QueryNode;
import anyparse.query.SourceText;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;

/**
 * The subtree scans the two COLLECTION-LOOP rewrite rules share — `prefer-keyvalue-loop` (an indexed `for` whose body opens by binding `X[i]`) and `dead-binder-counter-loop` (a `var i = 0;` counter threaded through a `for`-in whose binder nothing reads). Both move a name into, or drop one out of, a loop HEADER, so both must prove the same things about the body: the names involved are not written, not re-declared, not captured by a closure, and — for the collection itself — used only in positions that cannot change its LENGTH.
 *
 * That last one is the non-obvious gate. A `for (i in 0...X.length)` evaluates its bound ONCE, whereas `for (v in X)` re-asks the iterator every step; converting either way while the body can grow or shrink `X` changes how many iterations run (an added element turns a terminating loop into a runaway one). So a rewrite is licensed only when every mention of `X` in the body READS it through the size member or an index — never a call on it, never a method value taken off it, never a bare mention that hands the reference to something else, never a write to or through it. That is a WHITELIST of two positions, not a list of banned ones: the next hazardous shape nobody has thought of fails by construction.
 *
 * Its limit is that the scan is BODY-LOCAL. An alias handed out before the loop, or a call that mutates the same collection through a field the callee owns, is outside what a per-file check can see; both rules state that caveat in their own type docs rather than pretending the gate is a proof.
 *
 * Grammar-agnostic: every node kind arrives through `LoopSeams`, built once per run by `seamsOf`, and a grammar leaving any required kind unset makes both rules a no-op.
 *
 * ## The JUMP-BINDING scans — a second, independent seam bundle
 *
 * Beside the collection scans this class also hosts the loop-body scans every rule that MOVES a jump needs: `loopBody` (the body block, last child for `for` / `while`, first for `do … while`) and `escapesIteration` (does this subtree leave the CURRENT iteration). They read `LoopJumpSeams`, a bundle of their own — `LoopSeams` demands field access, index access and numeric literals, none of which a jump scan asks about, so making one bundle serve both would refuse a grammar that answers everything the jump scan needs.
 *
 * `escapesIteration` is where the one non-obvious language fact lives: a `break` inside a `switch` inside a loop breaks the LOOP, not the switch (measured on `--interp`), so the scan DESCENDS into switch bodies — while a `break` inside a nested `for` / `while` / `do … while` binds to that inner loop, so `inInnerLoop` turns the loop-jump kinds off below one. A nested function or lambda gets neither: its jumps and returns belong to it, so the scan stops at its boundary.
 */
@:nullSafety(Strict)
final class LoopScan {

	/** A field access has exactly [receiver] as its children — the member name lives on the node. */
	private static inline final FIELD_ACCESS_CHILD_COUNT: Int = 1;

	/** An index access has exactly [receiver, index] children. */
	private static inline final INDEX_ACCESS_CHILD_COUNT: Int = 2;

	/** The one numeric literal a counter / range may start from. */
	private static inline final ZERO_LITERAL: String = '0';

	/** An `if` with no `else` has exactly [condition, then-branch] children. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	/** The shortest loop body a leading guard can be lifted out of: the guard plus one statement. */
	private static inline final GUARD_PLUS_ONE: Int = 2;

	/** The name `node` carries when it is a bare identifier, else null. */
	public static inline function bareIdentName(node: QueryNode, s: LoopSeams): Null<String> {
		return node.kind == s.identKind ? node.name : null;
	}

	/**
	 * Whether every mention of `name` in `node`'s subtree sits in a position that cannot change the collection it denotes: a READ of `sizeMember` on it (`name.length`, including through `?.` / `!.`) or an index READ (`name[e]`). Everything else answers false — a call on it (`name.push(v)`), a method VALUE taken off it (`f(name.pop)`), a bare mention handing the reference to a callee (`f(name)`), a write to the binding, a write THROUGH it (`name.length = 0`, `name[k] = v`), a receiverless use.
	 *
	 * The scan is BODY-LOCAL, which is its documented limit: an alias handed out before the loop, or a call that reaches the same collection through a field the callee owns, is invisible to it. Closing that would need whole-program alias analysis; each rule's type doc repeats the caveat.
	 */
	public static inline function usedOnlyAsStableCollection(node: QueryNode, name: String, sizeMember: String, s: LoopSeams): Bool {
		return stableUseScan(node, null, null, name, sizeMember, s);
	}

	/** Whether `node` is a loop of either body order. */
	public static inline function isLoop(node: QueryNode, s: LoopJumpSeams): Bool {
		return s.loopKinds.contains(node.kind) || s.doWhileKinds.contains(node.kind);
	}

	/**
	 * Bundle the `RefShape` kinds both loop rules read, or null when one the scans cannot work
	 * without is unset (the calling check is then a no-op). `identKind` is required by `RefShape`
	 * itself; the rest are optional there, so a grammar that does not name statements, blocks,
	 * `for` loops, field access or index access simply does not admit these rewrites.
	 */
	public static function seamsOf(shape: RefShape): Null<LoopSeams> {
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return null;
		final forStmtKind: Null<String> = shape.forStmtKind;
		if (forStmtKind == null) return null;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind == null) return null;
		final indexAccessKind: Null<String> = shape.indexAccessKind;
		if (indexAccessKind == null) return null;
		final callKind: Null<String> = shape.callKind;
		if (callKind == null) return null;
		final numericLiteralKinds: Array<String> = shape.numericLiteralKinds ?? [];
		if (numericLiteralKinds.length == 0) return null;
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		if (localDeclKinds.length == 0) return null;
		// `?.` / `!.` access reaches the same member as `.` does, so a length read through
		// either is still a read; they are listed only where a POSITION is judged, never as
		// the plain-access kind a match requires.
		final accessKinds: Array<String> = [fieldAccessKind];
		for (k in [(shape.nullSafeAccessKind: Null<String>), shape.forceFieldAccessKind]) if (k != null) accessKinds.push(k);
		return {
			shape: shape,
			identKind: shape.identKind,
			blockStmtKind: blockStmtKind,
			forStmtKind: forStmtKind,
			fieldAccessKind: fieldAccessKind,
			indexAccessKind: indexAccessKind,
			callKind: callKind,
			accessKinds: accessKinds,
			numericLiteralKinds: numericLiteralKinds,
			localDeclKinds: localDeclKinds,
			localDeclContinuationKinds: shape.localDeclContinuationKinds ?? [],
			writeParentKinds: shape.writeParentKinds,
			closureKinds: (shape.lambdaKinds ?? []).concat(shape.localFunctionKinds ?? []),
			opaqueKinds: shape.opaqueKinds ?? []
		};
	}

	/**
	 * The number of DIRECT writes of `name` in `node`'s subtree — a `writeParentKinds` node whose
	 * first child is the bare identifier `name`, so `arr[name] = v` / `obj.name = v` (whose target
	 * is not that identifier) count as reads. Reification subtrees are not counted.
	 */
	public static function countWrites(node: QueryNode, name: String, s: LoopSeams): Int {
		if (s.opaqueKinds.contains(node.kind)) return 0;
		var count: Int = 0;
		if (s.writeParentKinds.contains(node.kind) && node.children.length >= 1) {
			final target: QueryNode = node.children[0];
			if (target.kind == s.identKind && target.name == name) count++;
		}
		for (c in node.children) count += countWrites(c, name, s);
		return count;
	}

	/** Whether `node`'s subtree re-declares a local named `name`, skipping reification subtrees. */
	public static function declares(node: QueryNode, name: String, s: LoopSeams): Bool {
		return !s.opaqueKinds.contains(node.kind)
			&& (s.localDeclKinds.contains(node.kind) && node.name == name || node.children.exists(c -> declares(c, name, s)));
	}

	/** Whether `node`'s subtree contains a node of `kind`, skipping reification subtrees. */
	public static function containsKind(node: QueryNode, kind: String, s: LoopSeams): Bool {
		return !s.opaqueKinds.contains(node.kind) && (node.kind == kind || node.children.exists(c -> containsKind(c, kind, s)));
	}

	/**
	 * Whether any lambda / local-function subtree within `scope` references `name` (a
	 * word-boundary match inside the closure's span). Such a closure captures ONE
	 * function-scoped binding by reference, so a rewrite that re-scopes the name per
	 * iteration would change what the closure observes — a conservative bail.
	 */
	public static function capturedByClosure(scope: QueryNode, source: String, name: String, s: LoopSeams): Bool {
		if (s.opaqueKinds.contains(scope.kind)) return false;
		if (s.closureKinds.contains(scope.kind)) {
			final span: Null<Span> = scope.span;
			if (span != null && OccurrenceScan.referencedInRange(source, name, span.from, span.to, [])) return true;
		}
		return scope.children.exists(c -> capturedByClosure(c, source, name, s));
	}

	/** Whether `node` is the numeric literal `0` — the only lower bound either rewrite can transcribe. */
	public static function isZeroLiteral(node: QueryNode, source: String, s: LoopSeams): Bool {
		final span: Null<Span> = node.span;
		return span != null && s.numericLiteralKinds.contains(node.kind) && source.substring(span.from, span.to) == ZERO_LITERAL;
	}

	/**
	 * Whether `decl` is a single-variable local declaration (one initializer child, no
	 * multi-declaration comma) — the shape both rules consume, whose name is the binding
	 * they move. Null when it is not; the declared name otherwise.
	 */
	public static function singleLocalDeclName(decl: QueryNode, kinds: Array<String>, s: LoopSeams): Null<String> {
		return if (!kinds.contains(decl.kind) || decl.children.length != 1)
			null
		else if (SourceText.isMultiDeclarator(decl, s.localDeclContinuationKinds))
			null
		else
			decl.name;
	}

	/**
	 * The verbatim source of the `:Type` annotation the identifier `ident` binds to, or null
	 * when the binding is unresolved / unannotated. `typeSources` is a
	 * `TypeInfoProvider.declaredTypeSources` map; a plugin without that capability passes null
	 * and every operand stays unresolved (the conservative direction — no rewrite).
	 */
	public static function identTypeSource(
		ident: QueryNode, root: QueryNode, typeSources: Null<Map<Int, String>>, s: LoopSeams
	): Null<String> {
		if (typeSources == null) return null;
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(ident, root, s.shape);
		return bindingFrom == null ? null : typeSources[bindingFrom];
	}

	/**
	 * The number of `name[index]` accesses in `node`'s subtree whose index is exactly the bare
	 * identifier `index` — the occurrences a key-value rewrite would have to rename to the value
	 * binder, so a caller admits exactly the one it consumes.
	 */
	public static function countIndexReads(node: QueryNode, name: String, index: String, s: LoopSeams): Int {
		if (s.opaqueKinds.contains(node.kind)) return 0;
		var count: Int = 0;
		if (isIndexAccessOf(node, name, s) && bareIdentName(node.children[1], s) == index) count++;
		for (c in node.children) count += countIndexReads(c, name, index, s);
		return count;
	}

	/** Whether `node` is an index access whose receiver is the bare identifier `name`. */
	public static function isIndexAccessOf(node: QueryNode, name: String, s: LoopSeams): Bool {
		return node.kind == s.indexAccessKind && node.children.length == INDEX_ACCESS_CHILD_COUNT
			&& bareIdentName(node.children[0], s) == name;
	}

	/** The receiver name of a plain `<ident>.<member>` read, or null when `node` is not one. */
	public static function memberReadReceiver(node: QueryNode, member: String, s: LoopSeams): Null<String> {
		return node.kind != s.fieldAccessKind || node.name != member || node.children.length != FIELD_ACCESS_CHILD_COUNT
			? null
			: bareIdentName(node.children[0], s);
	}

	/**
	 * The loop's body: the LAST child for a body-last loop (`for` / `while`), the FIRST for a
	 * body-first `do … while`. Null when the node has no children at all.
	 */
	public static function loopBody(loop: QueryNode, doWhileKinds: Array<String>): Null<QueryNode> {
		final kids: Array<QueryNode> = loop.children;
		return if (kids.length == 0)
			null
		else if (doWhileKinds.contains(loop.kind))
			kids[0]
		else
			kids[kids.length - 1];
	}

	/**
	 * Whether `node`'s subtree can leave the CURRENT iteration of the loop it belongs to — a
	 * `hardExitKinds` node (`return` / `throw` / a grammar-specific exit) anywhere, or a
	 * `loopJumpKinds` node (`break` / `continue`, or whichever subset the caller asked about) that
	 * is NOT nested in an inner loop. `inInnerLoop` is threaded, not recomputed: an inner loop's own
	 * jumps bind to IT, so they never escape the outer iteration, while a `return` still does.
	 *
	 * A `switch` is descended into deliberately — a `break` there breaks the LOOP, not the switch
	 * (measured on `--interp`: the C/JS habit is wrong for Haxe). A nested function / lambda
	 * (`nestedScopeKinds`) and a reification subtree (`opaqueKinds`) are not descended into at all.
	 */
	public static function escapesIteration(node: QueryNode, s: LoopJumpSeams, inInnerLoop: Bool): Bool {
		if (s.opaqueKinds.contains(node.kind) || s.nestedScopeKinds.contains(node.kind)) return false;
		if (s.hardExitKinds.contains(node.kind)) return true;
		if (!inInnerLoop && s.loopJumpKinds.contains(node.kind)) return true;
		final inner: Bool = inInnerLoop || isLoop(node, s);
		return node.children.exists(c -> escapesIteration(c, s, inner));
	}

	/**
	 * The function / lambda / local-function kinds a jump scan must not descend into — a nested
	 * scope's own jumps and returns are unrelated to the loop being rewritten.
	 */
	public static function nestedScopeKinds(shape: RefShape): Array<String> {
		final out: Array<String> = [];
		for (grp in [
			shape.functionKinds ?? [],
			shape.lambdaKinds ?? [],
			shape.localFunctionKinds ?? []
		]) for (k in grp) if (!out.contains(k)) out.push(k);
		return out;
	}

	/**
	 * The LEADING `if (g) continue;` guard of a loop body block — the shape `loop-guard` lifts into the
	 * loop header — or null when the body does not open with one. Both the check that CLAIMS the shape
	 * and the check that must NOT claim it read this one predicate, so neither can drift from the
	 * other's idea of what the shape IS.
	 *
	 * It answers about a BODY, which is all it can see. `loop-guard`'s claim on a SITE is wider — the
	 * loop kind, the body kind, the shielded position and a clean inversion — and `GuardContinue.loopGuardClaims`
	 * is where those are asked, from state a body-level predicate does not have. Splitting it that way
	 * is what the deferral costs: get the site-level list wrong and NOBODY reports the site (measured
	 * twice — 14 ordered-comparison guards over 13251 external files, and every `do … while`).
	 *
	 * Three conditions beyond the guard itself, and all three are load-bearing:
	 *
	 * - There must be a statement AFTER the guard. A guard-only body is a no-op loop and the lift would
	 *   produce an empty one.
	 * - That statement must not be ANOTHER `if`-continue. `loop-guard` deliberately leaves a CASCADE
	 *   alone (the user keeps sequential `continue` guards, each introducing its own checks), so the
	 *   cascade is the one leading-guard shape `guard-continue` still owns. Reading the cascade as
	 *   claimed would silence BOTH rules on it.
	 * - No comment may sit in `[body.from, guard.to)` — before the guard OR inside it. The lift drops
	 *   that text, so `loop-guard` refuses there, and a `guard-continue` that deferred anyway would
	 *   silence both.
	 *
	 * The guard's then-branch is `continue;` bare or braced-single — the two spellings the loop-guard
	 * rewrite treats identically. A null `blockStmtKind` or `continueKind` answers null: a grammar that
	 * names neither cannot express the shape, and `loop-guard` is itself a no-op without both, so the
	 * caller must keep whatever it would have done without the question.
	 */
	public static function leadingContinueGuard(
		body: QueryNode, source: String, ifKinds: Array<String>, blockStmtKind: Null<String>, continueKind: Null<String>
	): Null<QueryNode> {
		if (continueKind == null || blockStmtKind == null) return null;
		final stmts: Array<QueryNode> = body.children;
		if (stmts.length < GUARD_PLUS_ONE) return null;
		final guard: QueryNode = stmts[0];
		if (!isIfContinue(guard, ifKinds, blockStmtKind, continueKind)) return null;
		if (isIfContinue(stmts[1], ifKinds, blockStmtKind, continueKind)) return null;
		final gs: Null<Span> = guard.span;
		final bs: Null<Span> = body.span;
		if (gs == null || bs == null) return null;
		// The span runs to the guard's END, so a comment INSIDE the guard counts as well as one before
		// it — both are text the lift drops, and both are what `loop-guard` refuses on.
		//
		// Named rather than folded into the return: the folded form is an `if`/return pair
		// `prefer-ternary-return` collapses onto the ternary below it, and the chain that writes is a
		// `prefer-if-expression-chain` finding. That cascade is confluent (both `--rule` orders give
		// the same bytes), so it is not this slice's order-dependent crossing — it is the tool telling
		// the reader to write something it then reports, on this very file.
		final glued: Bool = CheckScan.hasCommentMarker(source, bs.from, gs.to);
		return glued ? null : guard;
	}

	/** Recursive body of `usedOnlyAsStableCollection`, carrying the two ancestors a position verdict needs. */
	private static function stableUseScan(
		node: QueryNode, parent: Null<QueryNode>, grandParent: Null<QueryNode>, name: String, sizeMember: String, s: LoopSeams
	): Bool {
		return s.opaqueKinds.contains(node.kind)
			|| (node.kind != s.identKind || node.name != name || isStablePosition(node, parent, grandParent, sizeMember, s))
			&& node.children.foreach(c -> stableUseScan(c, node, parent, name, sizeMember, s));
	}

	/**
	 * Whether the identifier `ident` sits in a length-preserving position — the receiver of a READ
	 * of the SIZE MEMBER itself (`x.length`, through `.` / `?.` / `!.`), or the receiver of an index
	 * READ (`x[e]`). Naming the member is what makes this a whitelist rather than a hole: admitting
	 * "any field access that is not a call's callee" also admitted `x.push` handed out as a method
	 * VALUE, which the callee can then invoke. Both arms additionally refuse a WRITE target, since
	 * `x.length = 0` truncates and `x[x.length] = v` extends — neither is a read.
	 */
	private static function isStablePosition(
		ident: QueryNode, parent: Null<QueryNode>, grandParent: Null<QueryNode>, sizeMember: String, s: LoopSeams
	): Bool {
		if (parent == null || isWriteTarget(parent, grandParent, s)) return false;
		return s.accessKinds.contains(parent.kind)
			? parent.name == sizeMember && parent.children.length == FIELD_ACCESS_CHILD_COUNT && parent.children[0] == ident
			: parent.kind == s.indexAccessKind && parent.children.length == INDEX_ACCESS_CHILD_COUNT && parent.children[0] == ident;
	}

	/** Whether `node` is the l-value of an assignment / increment — the first child of a `writeParentKinds` parent. */
	private static function isWriteTarget(node: QueryNode, parent: Null<QueryNode>, s: LoopSeams): Bool {
		return parent != null && s.writeParentKinds.contains(parent.kind) && parent.children.length >= 1 && parent.children[0] == node;
	}

	/** Whether `stmt` is an else-less `if` whose then-branch is exactly `continue;`, bare or braced-single. */
	private static function isIfContinue(stmt: QueryNode, ifKinds: Array<String>, blockStmtKind: Null<String>, continueKind: String): Bool {
		if (!ifKinds.contains(stmt.kind) || stmt.children.length != IF_NO_ELSE_CHILD_COUNT) return false;
		final thenBranch: QueryNode = stmt.children[1];
		return thenBranch.kind == continueKind
			|| (thenBranch.kind == blockStmtKind && thenBranch.children.length == 1 && thenBranch.children[0].kind == continueKind);
	}

}

/**
 * The `RefShape` kinds `LoopScan` reads, bundled once by `seamsOf` so every scan takes one
 * argument. A rule adds its own kinds beside a `core: LoopSeams` field rather than extending
 * this structurally — the scans then take `s.core` and stay independent of which rule calls them.
 */
typedef LoopSeams = {
	var shape: RefShape;
	var identKind: String;
	var blockStmtKind: String;
	var forStmtKind: String;
	var fieldAccessKind: String;
	var indexAccessKind: String;
	var callKind: String;
	var accessKinds: Array<String>;
	var numericLiteralKinds: Array<String>;
	var localDeclKinds: Array<String>;
	var localDeclContinuationKinds: Array<String>;
	var writeParentKinds: Array<String>;
	var closureKinds: Array<String>;
	var opaqueKinds: Array<String>;
}

/**
 * The kinds the JUMP-BINDING scans (`loopBody`, `isLoop`, `escapesIteration`) read — deliberately
 * separate from `LoopSeams`, which demands field access, index access and numeric literals that a
 * jump scan never asks about. `hardExitKinds` are the exits an inner loop does NOT shield
 * (`return` / `throw`); `loopJumpKinds` are the ones it does, and a caller narrows that list to ask
 * a narrower question (`break` alone, when a `continue` is provably harmless).
 */
typedef LoopJumpSeams = {
	var loopKinds: Array<String>;
	var doWhileKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var nestedScopeKinds: Array<String>;
	var hardExitKinds: Array<String>;
	var loopJumpKinds: Array<String>;
}
