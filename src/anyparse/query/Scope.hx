package anyparse.query;

import anyparse.runtime.Span;

/**
 * Lexical scope stack maintained by the `Refs` walker while traversing
 * a `QueryNode` tree. The plugin declares which kinds introduce a
 * scope via `RefShape.scopeKinds`; the walker pushes a fresh frame on
 * entering one of those nodes and pops on exit, so the innermost matching
 * binding wins on `resolveInnermost`.
 *
 * A frame is HOISTING or POSITION-SCOPED (`RefShape.positionScopedKinds`). In a hoisting
 * frame — a type body — every binding is visible to every reference in it, which is what
 * lets a method read a field declared further down. In a position-scoped frame — a
 * function body, a block, a `switch` arm — a binding is visible only from the offset it
 * takes effect at, so a reference that PRECEDES the declaration resolves past the frame.
 * That is why `resolveInnermost` takes the reference's own offset.
 *
 * Non-features (per `docs/cli-query-tool.md`):
 *  - No cross-file binding resolution — each file is walked
 *    independently, unresolved reads stay unresolved.
 *  - No type-driven resolution — name-only matching, no overload
 *    selection, no `this.foo` vs `local.foo` disambiguation beyond
 *    lexical scope.
 */
@:nullSafety(Strict)
final class ScopeStack {

	private final _frames: Array<ScopeFrame> = [];

	public function new() {}

	public inline function push(frame: ScopeFrame): Void {
		_frames.push(frame);
	}

	public inline function pop(): Void {
		_frames.pop();
	}

	/**
	 * Whether the innermost frame is position-scoped.
	 *
	 * Read when a frame that is NOT a lexical scope of its own opens on top of it — the
	 * branch-aware projection's `CondBranch`, which is a resolution PREFERENCE layered over
	 * the enclosing frame rather than a container. Such a frame must apply the enclosing
	 * frame's visibility policy: hoisting inside a `#if` region what the frame around it does
	 * not hoist would resurrect, per region, exactly the mis-binding the policy removes.
	 */
	public inline function currentPositionScoped(): Bool {
		return _frames.length > 0 && _frames[_frames.length - 1].positionScoped;
	}

	/**
	 * Walk frames top-down (innermost first) and return the first
	 * binding for `name`. Null when no enclosing scope declares
	 * the symbol — typically a cross-file or implicit-`this` reference.
	 */
	public function resolveInnermost(name: String, at: Int): Null<ScopeBinding> {
		var i: Int = _frames.length - 1;
		while (i >= 0) {
			final hit: Null<ScopeBinding> = _frames[i].resolve(name, at);
			if (hit != null) return hit;
			i--;
		}
		return null;
	}

}

/**
 * One lexical scope's bindings. A name may be bound MORE THAN ONCE in one frame: a
 * position-scoped frame re-declares it (`var x = 1; … var x = "s";` in one block is legal
 * Haxe, and the second declaration takes over from its own position on — measured, `x.length`
 * typechecks after it), while a hoisting frame can carry the same name on two mutually
 * exclusive `#if` arms. `resolve` picks between them BY POSITION; cross-scope shadowing is
 * handled by `ScopeStack.resolveInnermost`, not here.
 */
@:nullSafety(Strict)
final class ScopeFrame {

	public final node: QueryNode;

	/**
	 * Whether a binding in this frame takes effect only from its own position onward
	 * rather than for the whole frame — see `ScopeStack` for what the two policies mean
	 * and `RefShape.positionScopedKinds` for which kinds carry which.
	 */
	public final positionScoped: Bool;

	/**
	 * The earliest offset at which ANY binding of this frame can be seen — a lower bound
	 * applied on top of each binding's own answer.
	 *
	 * `0` for an ordinary frame. A construct that binds a name AND spells a HEADER inside its
	 * own span sets it to the start of its body: a `for` iterator is not in scope in the
	 * iterable that produces it (`for (i in 0...i)` reads the OUTER `i` — measured), and a
	 * catch exception is not in scope in the caught-type clause. Without the floor the
	 * iterator's own span start answers for the whole construct and the header binds to it.
	 *
	 * A floor rather than a per-binding rule because the construct can bind more than one name
	 * (`for (k => v in m)` binds the key on the loop node and the value on a `KeyValueBinder`
	 * child) and every one of them is out of scope in the same header.
	 */
	public final visibleFloor: Int;

	/** Every binding of a name this frame declares, in pre-collect (source) order. */
	private final _bindings: Map<String, Array<ScopeBinding>> = [];

	public function new(node: QueryNode, positionScoped: Bool, visibleFloor: Int = 0) {
		this.node = node;
		this.positionScoped = positionScoped;
		this.visibleFloor = visibleFloor;
	}

	/**
	 * The declaration bound to `name` and visible at source offset `at`, or null when
	 * this frame binds the name nowhere — or binds it only from a later offset, which is the
	 * whole point of a position-scoped frame: the reference belongs to an enclosing binding.
	 *
	 * Of several bindings of one name the LATEST one already in effect wins: a re-declaration
	 * shadows its predecessor from its own position on, so a read past it must not keep
	 * answering the earlier declaration's type. Equal `visibleFrom` keeps the FIRST — a
	 * hoisting frame records every binding at `0`, so a type body carrying one name on two
	 * mutually exclusive `#if` arms answers exactly as it did before.
	 */
	public function resolve(name: String, at: Int): Null<ScopeBinding> {
		final bindings: Null<Array<ScopeBinding>> = _bindings[name];
		if (bindings == null) return null;
		var best: Null<ScopeBinding> = null;
		for (binding in bindings) {
			final prev: Null<ScopeBinding> = best;
			if (at >= binding.visibleFrom && (prev == null || binding.visibleFrom > prev.visibleFrom)) best = binding;
		}
		return best;
	}

	public function declare(name: String, node: QueryNode, span: Span, visibleFrom: Int): Void {
		final bindings: Array<ScopeBinding> = _bindings[name] ?? [];
		_bindings[name] = bindings;
		bindings.push(({
			node: node,
			span: span,
			visibleFrom: visibleFrom < visibleFloor ? visibleFloor : visibleFrom
		}: ScopeBinding));
	}

}

/**
 * One binding recorded in a `ScopeFrame`: where it is declared, and from where a
 * reference can see it (never below the frame's `visibleFloor`).
 *
 * `visibleFrom` is a source offset. A hoisting frame records every binding at `0`, so
 * every reference in the frame resolves to it. A position-scoped frame records the offset
 * the binding takes effect at, which is NOT simply the declaration's start: a `var`'s own
 * initializer must still see the enclosing binding of the same name (`var x = x;` reads
 * the outer `x` — verified against the compiler), while a local `function` must see
 * itself so it can recurse. `Refs.visibleFrom` derives the offset per declaration kind.
 */
typedef ScopeBinding = {
	/**
	 * The node that DECLARES the binding — the very node `Refs` bound the name from, not one
	 * re-found later by span arithmetic. A consumer asking what a reference actually binds to
	 * (a local? a parameter? a member?) reads its `kind` and its position in the tree directly;
	 * `TypeResolver.bindsToValueDeclaration` is the one that does.
	 */
	final node: QueryNode;

	final span: Span;
	final visibleFrom: Int;
};
