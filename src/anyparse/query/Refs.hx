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
 * Phase 3.2b-α scope: self-scoped declarations via
 * `RefShape.selfScopeDeclKinds`. A scope-introducer in that set binds
 * its own `name` into the frame it opens (not the enclosing one), so a
 * Haxe `for (i in xs) …` iterator is a `Decl` visible only inside the
 * loop body. Reads inside resolve to it via the innermost frame; reads
 * after the loop fall through to any enclosing binding.
 *
 * Phase 3.2b-β scope: catch-clause exception names and lambda-parameter
 * names. Their `@:spanned`-tagged grammar structs now surface as
 * addressable nodes, so a catch-clause exception is a self-scoped decl
 * (visible only inside the clause body) and a lambda parameter is a
 * decl-host bound into the enclosing lambda scope frame.
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
	public static function find(name: String, tree: QueryNode, shape: RefShape): Array<RefHit> {
		return findMulti([name], tree, shape)[name] ?? [];
	}

	private static inline function classify(kind: String, shape: RefShape, isWriteTarget: Bool): Null<RefKind> {
		// Decl-host takes precedence over identKind: a single grammar
		// would normally place the decl name on a different ctor than
		// the reference ctor, but the contract leaves the option open.
		return shape.declHostKinds.contains(kind)
			? RefKind.Decl
			: shape.selfScopeDeclKinds.contains(kind)
				? RefKind.Decl
				: kind == shape.identKind ? isWriteTarget ? RefKind.Write : RefKind.Read : null;
	}

	/**
	 * Multi-name variant of `find` — ONE tree walk resolving every name in
	 * `names` simultaneously (duplicates tolerated). The call-graph layer needs
	 * bindings for dozens of names per file; per-name `find` walks made that
	 * quadratic. The result map is pre-seeded, so every requested name has an
	 * entry and `exists()` doubles as the membership test during the walk.
	 */
	public static function findMulti(names: Array<String>, tree: QueryNode, shape: RefShape): Map<String, Array<RefHit>> {
		final out: Map<String, Array<RefHit>> = [];
		for (n in names) if (!out.exists(n)) out[n] = [];
		if (names.length == 0) return out;
		final scopes: ScopeStack = new ScopeStack();
		walkMulti(tree, shape, scopes, out, false, false);
		return out;
	}

	private static function walkMulti(
		node: QueryNode, shape: RefShape, scopes: ScopeStack, out: Map<String, Array<RefHit>>, isWriteTarget: Bool, macroEmit: Bool
	): Void {
		// Inside a macro-reification subtree (`opaqueKinds`, e.g. `macro { … }`) a
		// plain identifier is a runtime emit spliced into generated code — NOT a
		// reference to the enclosing scope — and a reified `var` is not a real
		// binding. While in this `macroEmit` context suppress scope handling and
		// ref emission; only a macro interpolation (`interpolationKinds`: `${…}` /
		// `$v{…}`) re-opens normal resolution for its own subtree, where an
		// identifier IS a genuine compile-time reference.
		final isScope: Bool = !macroEmit && shape.scopeKinds.contains(node.kind);
		if (isScope) {
			final frame: ScopeFrame = new ScopeFrame(node);
			collectDeclsMulti(node, shape, frame, out);
			final selfSpan: Null<Span> = node.span;
			final selfName: Null<String> = node.name;
			if (selfSpan != null && selfName != null && out.exists(selfName) && shape.selfScopeDeclKinds.contains(node.kind))
				frame.declare(selfName, selfSpan);
			scopes.push(frame);
		}
		if (!macroEmit) {
			final nname: Null<String> = node.name;
			if (nname != null) {
				final hits: Null<Array<RefHit>> = out[nname];
				if (hits != null) {
					final span: Null<Span> = node.span;
					if (span != null) {
						final kind: Null<RefKind> = classify(node.kind, shape, isWriteTarget);
						if (kind != null) {
							final bindingSpan: Null<Span> = (kind == RefKind.Decl) ? span : scopes.resolveInnermost(nname);
							hits.push(new RefHit(kind, nname, span, bindingSpan));
						}
					}
				}
			}
		}
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final interpolationKinds: Array<String> = shape.interpolationKinds ?? [];
		final childMacroEmit: Bool = opaqueKinds.contains(node.kind) || (!interpolationKinds.contains(node.kind) && macroEmit);
		final isWriteParent: Bool = shape.writeParentKinds.contains(node.kind);
		final children: Array<QueryNode> = node.children;
		for (i in 0...children.length) walkMulti(children[i], shape, scopes, out, isWriteParent && i == 0, childMacroEmit);
		if (isScope) scopes.pop();
	}

	private static function collectDeclsMulti(
		scopeNode: QueryNode, shape: RefShape, frame: ScopeFrame, out: Map<String, Array<RefHit>>
	): Void {
		for (c in scopeNode.children) collectIntoMulti(c, shape, frame, out);
	}

	private static function collectIntoMulti(node: QueryNode, shape: RefShape, frame: ScopeFrame, out: Map<String, Array<RefHit>>): Void {
		final name: Null<String> = node.name;
		if (shape.scopeKinds.contains(node.kind)) {
			if (name != null && out.exists(name) && shape.declHostKinds.contains(node.kind)) {
				final span: Null<Span> = node.span;
				if (span != null) frame.declare(name, span);
			}
			return;
		}
		if (name != null && out.exists(name) && shape.declHostKinds.contains(node.kind)) {
			final span: Null<Span> = node.span;
			if (span != null) frame.declare(name, span);
		}
		for (c in node.children) collectIntoMulti(c, shape, frame, out);
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

	public final kind: RefKind;
	public final name: String;
	public final span: Span;
	public final bindingSpan: Null<Span>;

	public function new(kind: RefKind, name: String, span: Span, ?bindingSpan: Span) {
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

	public function toString(): String {
		return switch (cast this: RefKind) {
			case Decl: 'decl';
			case Read: 'read';
			case Write: 'write';
		}
	}

}
