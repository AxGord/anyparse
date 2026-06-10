package anyparse.query;

import anyparse.runtime.Span;

/**
 * Lexical scope stack maintained by the `Refs` walker while traversing
 * a `QueryNode` tree. The plugin declares which kinds introduce a
 * scope via `RefShape.scopeKinds`; the walker pushes a fresh frame on
 * entering one of those nodes and pops on exit, so the innermost
 * matching binding wins on `resolveInnermost`.
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
	 * Walk frames top-down (innermost first) and return the first
	 * binding span for `name`. Null when no enclosing scope declares
	 * the symbol — typically a cross-file or implicit-`this` reference.
	 */
	public function resolveInnermost(name: String): Null<Span> {
		var i: Int = _frames.length - 1;
		while (i >= 0) {
			final hit: Null<Span> = _frames[i].resolve(name);
			if (hit != null) return hit;
			i--;
		}
		return null;
	}

}

/**
 * One lexical scope's bindings. Names that re-declare an already-
 * bound symbol in the same scope keep the FIRST binding (matches the
 * walker's pre-collect pass order — first seen wins). Cross-scope
 * shadowing is handled by `ScopeStack.resolveInnermost`, not here.
 */
@:nullSafety(Strict)
final class ScopeFrame {

	public final node: QueryNode;
	private final _bindings: Map<String, Span> = [];

	public function new(node: QueryNode) {
		this.node = node;
	}

	public function declare(name: String, span: Span): Void {
		if (!_bindings.exists(name)) _bindings[name] = span;
	}

	public inline function resolve(name: String): Null<Span> {
		return _bindings[name];
	}

}
