package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;

/**
 * The name-visibility model the de-nesting checks share: which bindings are already live where a
 * statement run is about to be moved TO, so a de-nested local cannot silently re-declare — or
 * re-bind a later read of — an outer one.
 *
 * `RedundantElse` and `GuardReturn` both hoist a nested statement run into its enclosing statement
 * list, and both read the BRANCH-AWARE projection, where a `#if` region's branches are
 * `CondBranch` statement lists nested inside the real block. A gate that scanned only the moved
 * run's immediate siblings would therefore miss the enclosing block's own locals, the enclosing
 * function's parameters, and — the case that motivated this — a local declared in a DIFFERENT
 * `#if` region of the same block.
 *
 * ## The model
 *
 * A set of visible names is threaded down the tree. Whether a child RESETS it is decided by the
 * grammar's own scope seam (`RefShape.scopeKinds`), NOT by the block seam: a real `{ … }` block, a
 * function body, a `for`, a `catch` clause all open a scope, so a name de-nested inside one
 * legally SHADOWS an outer binding. Everything else — a conditional region and its `CondBranch`es
 * included — passes the set through, which is exactly how a `#if` branch keeps seeing the
 * enclosing function's parameters and the innermost real block's locals.
 *
 * A statement list unions its OWN frame onto what it inherited: every `localDeclKinds` node in its
 * subtree down to the next scope boundary — the model `UnusedLocal` / `SelfAssignment` /
 * `TypeResolver` resolve names with.
 *
 * A conditional region is the one child treated specially: it receives the block's frame MINUS its
 * own subtree, so each branch starts from what the region inherited and adds only its own locals.
 * Sibling branches therefore never see each other's — mutually exclusive configurations can never
 * coexist.
 *
 * Because a braced body is itself in `scopeKinds`, the frame of the block a run is moving INTO
 * never holds that run's own locals, so a candidate never collides with itself. An un-braced
 * `if (c) var n;` body IS collected, though Haxe scopes that binding to the branch — counting it
 * can only REFUSE a de-nest that would have been legal, never allow a wrong one.
 */
@:nullSafety(Strict)
final class ScopeFrames {

	/**
	 * The names visible inside `node` itself: `inherited` for anything that is not a statement
	 * list, and `inherited` unioned with the list's own frame for one that is.
	 */
	public static function ownScopeNames(node: QueryNode, seams: FrameSeams, inherited: Array<String>): Array<String> {
		return seams.blockKinds.contains(node.kind) ? inherited.concat(frameLocalNames(node, seams, null)) : inherited;
	}

	/** `node`'s own parameter names when it is a function, else null — see `paramNames`. */
	public static function ownParamNames(node: QueryNode, seams: FrameSeams): Null<Array<String>> {
		return seams.functionKinds.contains(node.kind) ? paramNames(node, seams) : null;
	}

	/**
	 * The names `child` inherits from `node`, where `ownParams` is `ownParamNames(node, …)` and
	 * `scopeNames` is `ownScopeNames(node, …)` — both hoisted out of the caller's child loop.
	 *
	 * A function hands its OWN parameters to every child, which is how its body block gets them; a
	 * scope-opening child starts fresh; a conditional region gets the block's frame minus its own
	 * subtree; anything else continues with what `node` sees.
	 */
	public static function childScopeNames(
		node: QueryNode, child: QueryNode, seams: FrameSeams, inherited: Array<String>, scopeNames: Array<String>,
		ownParams: Null<Array<String>>
	): Array<String> {
		return ownParams ?? (
			seams.scopeKinds.contains(child.kind)
				? []
				: seams.blockKinds.contains(node.kind) && child.kind == seams.condKind
					? inherited.concat(frameLocalNames(node, seams, child))
					: scopeNames
		);
	}

	/**
	 * The parameter names of a function node: its direct children that carry a name and are not
	 * blocks (that excludes the body block; the return-type node's name is harmless — a local can
	 * never share a type's name, so it never causes a false collision).
	 */
	public static function paramNames(fn: QueryNode, seams: FrameSeams): Array<String> {
		final names: Array<String> = [];
		for (c in fn.children) {
			final nm: Null<String> = c.name;
			if (nm != null && !seams.blockKinds.contains(c.kind)) names.push(nm);
		}
		return names;
	}

	/**
	 * The local-declaration names bound in `block`'s own frame: every `localDeclKinds` node in its
	 * subtree down to the next scope boundary (`RefShape.scopeKinds`). `skip`'s subtree is left
	 * out — callers pass the conditional region a child is about to descend into, so a branch
	 * never inherits what a SIBLING branch of its own region binds.
	 */
	public static function frameLocalNames(block: QueryNode, seams: FrameSeams, skip: Null<QueryNode>): Array<String> {
		final names: Array<String> = [];
		collect(block, seams, skip, names);
		return names;
	}

	/**
	 * The visible-name frame at every node of `root`: the names a statement moved to that node's position
	 * would land among. Threads `ownScopeNames` / `ownParamNames` / `childScopeNames` down the tree once, so a
	 * consumer that needs frames at several unrelated positions pays for one walk instead of one per position.
	 *
	 * The entry for a scope-opening node holds that scope's OWN frame — a consumer asking "may I unwrap this
	 * block into its parent" must read the entry of the PARENT container, not of the block.
	 */
	public static function frameIndex(root: QueryNode, seams: FrameSeams): Map<QueryNode, Array<String>> {
		final out: Map<QueryNode, Array<String>> = [];
		indexFrames(root, seams, [], out);
		return out;
	}

	/**
	 * Whether any top-level binding among `stmts` (kinds in `bindingKinds`) carries a name already bound in
	 * `scopeNames` — the frame the run is about to be moved INTO — so the move would redeclare it there.
	 *
	 * Haxe permits same-scope shadowing, so such a move COMPILES and no oracle catches it; it silently rebinds
	 * every later read of the outer binding. This refusal is the only thing between the rewrite and that.
	 */
	public static function collidesWithScope(stmts: Array<QueryNode>, bindingKinds: Array<String>, scopeNames: Array<String>): Bool {
		for (s in stmts) {
			final nm: Null<String> = s.name;
			if (nm != null && bindingKinds.contains(s.kind) && scopeNames.contains(nm)) return true;
		}
		return false;
	}

	/** The names `block`'s own direct children bind (kinds in `bindingKinds`) — what unwrapping it would hoist. */
	public static function topLevelBindingNames(block: QueryNode, bindingKinds: Array<String>): Array<String> {
		final names: Array<String> = [];
		for (c in block.children) {
			final nm: Null<String> = c.name;
			if (nm != null && bindingKinds.contains(c.kind)) names.push(nm);
		}
		return names;
	}

	/**
	 * Every statement kind that BINDS a name into its enclosing frame — `RefShape.localDeclKinds` widened with
	 * the expression-position and static local forms, and with the function-declaration kinds, whose names bind
	 * OUTSIDE the scope they open.
	 *
	 * Both sides of a de-nest gate must read the SAME set: a kind counted when testing what a moved run
	 * declares, but not when collecting the frame it lands in, is a silent hole — `LocalInlineFnStmt` was
	 * exactly that for `unnecessary-block`.
	 */
	public static function bindingKinds(shape: RefShape): Array<String> {
		return (shape.localDeclKinds ?? []).concat(shape.localDeclExprKinds ?? [])
			.concat(shape.staticLocalDeclKinds ?? [])
			.concat(shape.functionKinds ?? [])
			.concat(shape.localFunctionKinds ?? [])
			.concat(shape.inlineFunctionKinds ?? []);
	}

	/**
	 * Append every local-decl name under `node` to `out`, descending through anything that is not `skip` or a
	 * scope. A child that OPENS a scope still contributes its own name when the caller's `localDeclKinds` lists its
	 * kind — a local `function` / `inline function` declares into the enclosing frame while scoping only its body —
	 * so the name test runs before the descent test, not inside it.
	 */
	private static function collect(node: QueryNode, seams: FrameSeams, skip: Null<QueryNode>, out: Array<String>): Void {
		for (c in node.children) if (c != skip) {
			final nm: Null<String> = c.name;
			if (nm != null && seams.localDeclKinds.contains(c.kind)) out.push(nm);
			if (!seams.scopeKinds.contains(c.kind)) collect(c, seams, skip, out);
		}
	}

	/** Record `node`'s own frame in `out`, then descend with each child's inherited frame. */
	private static function indexFrames(
		node: QueryNode, seams: FrameSeams, inherited: Array<String>, out: Map<QueryNode, Array<String>>
	): Void {
		final scopeNames: Array<String> = ownScopeNames(node, seams, inherited);
		out[node] = scopeNames;
		final ownParams: Null<Array<String>> = ownParamNames(node, seams);
		for (c in node.children) indexFrames(c, seams, childScopeNames(node, c, seams, inherited, scopeNames, ownParams), out);
	}

}

/**
 * The grammar seams `ScopeFrames` reads. Both `RedundantElse`'s and `GuardReturn`'s own private
 * `Seams` unify with it structurally, so neither has to convert.
 */
typedef FrameSeams = {
	final blockKinds: Array<String>;
	final scopeKinds: Array<String>;
	final functionKinds: Array<String>;
	final localDeclKinds: Array<String>;
	final condKind: Null<String>;
}
