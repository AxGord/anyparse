package anyparse.check;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * The subtree scans the two COLLECTION-LOOP rewrite rules share — `prefer-keyvalue-loop` (an indexed `for` whose body opens by binding `X[i]`) and `dead-binder-counter-loop` (a `var i = 0;` counter threaded through a `for`-in whose binder nothing reads). Both move a name into, or drop one out of, a loop HEADER, so both must prove the same things about the body: the names involved are not written, not re-declared, not captured by a closure, and — for the collection itself — used only in positions that cannot change its LENGTH.
 *
 * That last one is the non-obvious gate. A `for (i in 0...X.length)` evaluates its bound ONCE, whereas `for (v in X)` re-asks the iterator every step; converting either way while the body can grow or shrink `X` changes how many iterations run (an added element turns a terminating loop into a runaway one). So a rewrite is licensed only when every mention of `X` in the body READS it through the size member or an index — never a call on it, never a method value taken off it, never a bare mention that hands the reference to something else, never a write to or through it. That is a WHITELIST of two positions, not a list of banned ones: the next hazardous shape nobody has thought of fails by construction.
 *
 * Its limit is that the scan is BODY-LOCAL. An alias handed out before the loop, or a call that mutates the same collection through a field the callee owns, is outside what a per-file check can see; both rules state that caveat in their own type docs rather than pretending the gate is a proof.
 *
 * Grammar-agnostic: every node kind arrives through `LoopSeams`, built once per run by `seamsOf`, and a grammar leaving any required kind unset makes both rules a no-op.
 */
@:nullSafety(Strict)
final class LoopScan {

	/** A field access has exactly [receiver] as its children — the member name lives on the node. */
	private static inline final FIELD_ACCESS_CHILD_COUNT: Int = 1;

	/** An index access has exactly [receiver, index] children. */
	private static inline final INDEX_ACCESS_CHILD_COUNT: Int = 2;

	/** The one numeric literal a counter / range may start from. */
	private static inline final ZERO_LITERAL: String = '0';

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
		if (s.opaqueKinds.contains(node.kind)) return false;
		if (s.localDeclKinds.contains(node.kind) && node.name == name) return true;
		for (c in node.children) if (declares(c, name, s)) return true;
		return false;
	}

	/** Whether `node`'s subtree contains a node of `kind`, skipping reification subtrees. */
	public static function containsKind(node: QueryNode, kind: String, s: LoopSeams): Bool {
		if (s.opaqueKinds.contains(node.kind)) return false;
		if (node.kind == kind) return true;
		for (c in node.children) if (containsKind(c, kind, s)) return true;
		return false;
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
			if (span != null && RefactorSupport.referencedInRange(source, name, span.from, span.to, [])) return true;
		}
		for (c in scope.children) if (capturedByClosure(c, source, name, s)) return true;
		return false;
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
		else if (RefactorSupport.isMultiDeclarator(decl, s.localDeclContinuationKinds))
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

	/** Recursive body of `usedOnlyAsStableCollection`, carrying the two ancestors a position verdict needs. */
	private static function stableUseScan(
		node: QueryNode, parent: Null<QueryNode>, grandParent: Null<QueryNode>, name: String, sizeMember: String, s: LoopSeams
	): Bool {
		if (s.opaqueKinds.contains(node.kind)) return true;
		if (node.kind == s.identKind && node.name == name && !isStablePosition(node, parent, grandParent, sizeMember, s)) return false;
		for (c in node.children) if (!stableUseScan(c, node, parent, name, sizeMember, s)) return false;
		return true;
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
