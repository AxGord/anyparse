package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Scope.ScopeFrame;
import anyparse.query.Scope.ScopeStack;
import anyparse.runtime.Span;

/**
 * Lexical reference / declaration walker for `apq refs`.
 *
 * Walks a `QueryNode` tree and collects every node whose `name` slot
 * matches the target identifier. Each hit is classified per the
 * plugin's `RefShape`:
 *
 *  - `kind ∈ shape.declHostKinds` → `RefKind.Decl` (binding site).
 *  - `kind == shape.identKind`    → `RefKind.Read` (reference).
 *
 * Phase 3.2 scope: lexical scope tracking. The walker maintains a
 * `ScopeStack` and pushes a frame on every `kind ∈ shape.scopeKinds`
 * node. On entering a fresh scope its decl-host descendants are
 * pre-collected (walk stops at inner scope boundaries) so reads can
 * resolve to forward-declared bindings in the same scope.
 *
 * Each emitted hit carries a `bindingSpan`:
 *  - Decl hits self-bind (`bindingSpan == own span`).
 *  - Read / Write hits bind to the innermost in-file declaration with
 *    a matching name (null when unresolved — typically a cross-file or
 *    implicit-`this` reference).
 *
 * Phase 3.3 scope: Write classification via `RefShape.writeParentKinds`.
 * When a parent node's kind is in that set and the matching `identKind`
 * child sits at child-index 0 of the parent, the hit is emitted as
 * `Write` instead of `Read`. The flag does NOT propagate through
 * intermediate non-ident wrappers — only a direct `IdentExpr` child
 * of a write-parent ctor reclassifies. `arr[i] = v` and `obj.x = 1`
 * therefore keep `arr`/`obj` as Reads, which matches the semantic
 * intent of the `--writes` filter.
 *
 * Nodes carrying a null `span` are skipped — without source coordinates
 * the result is not addressable.
 */
@:nullSafety(Strict)
final class Refs {

	/**
	 * Walk `tree` and return every reference / declaration of `name`
	 * per `shape`. Hits are returned in pre-order traversal.
	 */
	public static function find(name:String, tree:QueryNode, shape:RefShape):Array<RefHit> {
		final out:Array<RefHit> = [];
		final scopes:ScopeStack = new ScopeStack();
		walk(name, tree, shape, scopes, out);
		return out;
	}

	private static function walk(target:String, node:QueryNode, shape:RefShape, scopes:ScopeStack, out:Array<RefHit>, isWriteTarget:Bool = false):Void {
		final isScope:Bool = shape.scopeKinds.contains(node.kind);
		if (isScope) {
			final frame:ScopeFrame = new ScopeFrame(node);
			collectDecls(target, node, shape, frame);
			scopes.push(frame);
		}
		final nname:Null<String> = node.name;
		if (nname == target) {
			final span:Null<Span> = node.span;
			if (span != null) {
				final kind:Null<RefKind> = classify(node.kind, shape, isWriteTarget);
				if (kind != null) {
					final bindingSpan:Null<Span> = (kind == RefKind.Decl)
						? span
						: scopes.resolveInnermost(target);
					out.push(new RefHit(kind, target, span, bindingSpan));
				}
			}
		}
		final isWriteParent:Bool = shape.writeParentKinds.contains(node.kind);
		final children:Array<QueryNode> = node.children;
		for (i in 0...children.length) {
			final childIsWriteTarget:Bool = isWriteParent && i == 0;
			walk(target, children[i], shape, scopes, out, childIsWriteTarget);
		}
		if (isScope) scopes.pop();
	}

	/**
	 * Pre-walk `scopeNode`'s descendants and record every matching
	 * decl-host into `frame`. The walk stops at inner scope boundaries
	 * so a same-named decl in a nested scope does NOT leak into the
	 * outer frame. Starts from `scopeNode.children` — the scope node
	 * itself is the binder of its own name (e.g. `FnMember.name`),
	 * which belongs in the ENCLOSING scope, not in its own frame.
	 */
	private static function collectDecls(target:String, scopeNode:QueryNode, shape:RefShape, frame:ScopeFrame):Void {
		for (c in scopeNode.children) collectInto(target, c, shape, frame);
	}

	private static function collectInto(target:String, node:QueryNode, shape:RefShape, frame:ScopeFrame):Void {
		if (shape.scopeKinds.contains(node.kind)) {
			// Decl on the inner scope-introducer itself (its own name slot)
			// still belongs to THIS frame — the scope-node names itself in
			// the enclosing scope, then opens a fresh scope for its body.
			if (node.name == target && shape.declHostKinds.contains(node.kind)) {
				final span:Null<Span> = node.span;
				if (span != null) frame.declare(target, span);
			}
			return;
		}
		if (node.name == target && shape.declHostKinds.contains(node.kind)) {
			final span:Null<Span> = node.span;
			if (span != null) frame.declare(target, span);
		}
		for (c in node.children) collectInto(target, c, shape, frame);
	}

	private static inline function classify(kind:String, shape:RefShape, isWriteTarget:Bool):Null<RefKind> {
		// Decl-host takes precedence over identKind: a single grammar
		// would normally place the decl name on a different ctor than
		// the reference ctor, but the contract leaves the option open.
		if (shape.declHostKinds.contains(kind)) return RefKind.Decl;
		if (kind == shape.identKind) return isWriteTarget ? RefKind.Write : RefKind.Read;
		return null;
	}
}

/**
 * One classified reference site discovered by `Refs.find`.
 *
 * `name` is redundant with the search target (the walker only emits
 * matching nodes) but is kept on the hit so downstream renderers can
 * be driven by the hit alone without threading the target separately.
 *
 * `bindingSpan` is the span of the declaration this hit resolves to:
 *  - Decl hits self-bind (`bindingSpan == span`).
 *  - Read / Write hits point to the innermost enclosing decl with a
 *    matching name, or null when unresolved (cross-file / implicit-
 *    `this` / grammar-gap on the binding's decl site).
 */
@:nullSafety(Strict)
final class RefHit {

	public final kind:RefKind;
	public final name:String;
	public final span:Span;
	public final bindingSpan:Null<Span>;

	public function new(kind:RefKind, name:String, span:Span, ?bindingSpan:Span) {
		this.kind = kind;
		this.name = name;
		this.span = span;
		this.bindingSpan = bindingSpan;
	}
}

/**
 * Reference classification per `docs/cli-query-tool.md` JSON schema.
 *
 * Phase 3.3 emits all three variants. `Write` covers any `identKind`
 * that sits at child-index 0 of a `RefShape.writeParentKinds` ctor —
 * see the walker docstring for the propagation rule.
 */
enum abstract RefKind(Int) {
	final Decl = 0;
	final Read = 1;
	final Write = 2;

	public function toString():String {
		return switch (cast this:RefKind) {
			case Decl: 'decl';
			case Read: 'read';
			case Write: 'write';
		}
	}
}
