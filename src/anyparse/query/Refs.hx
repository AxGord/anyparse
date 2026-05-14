package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
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
 * Phase 3.1 scope: name-only matching, no lexical-scope shadowing.
 * Every textually matching identifier is emitted regardless of
 * enclosing scope. Scope-aware filtering (decl shadows outer name)
 * is Slice 3.2 territory; read-vs-write classification via assign-
 * parent context is Slice 3.3.
 *
 * Nodes carrying a null `span` are skipped — without source coordinates
 * the result is not addressable. In practice every span-mode plugin
 * populates spans on enum-ctor nodes (the only kinds that participate
 * here).
 */
@:nullSafety(Strict)
final class Refs {

	/**
	 * Walk `tree` and return every reference / declaration of `name`
	 * per `shape`. Hits are returned in pre-order traversal.
	 */
	public static function find(name:String, tree:QueryNode, shape:RefShape):Array<RefHit> {
		final out:Array<RefHit> = [];
		walk(name, tree, shape, out);
		return out;
	}

	private static function walk(target:String, node:QueryNode, shape:RefShape, out:Array<RefHit>):Void {
		final nname:Null<String> = node.name;
		if (nname == target) {
			final span:Null<Span> = node.span;
			if (span != null) {
				final kind:Null<RefKind> = classify(node.kind, shape);
				if (kind != null) out.push(new RefHit(kind, target, span));
			}
		}
		for (c in node.children) walk(target, c, shape, out);
	}

	private static inline function classify(kind:String, shape:RefShape):Null<RefKind> {
		// Decl-host takes precedence over identKind: a single grammar
		// would normally place the decl name on a different ctor than
		// the reference ctor, but the contract leaves the option open.
		if (shape.declHostKinds.contains(kind)) return RefKind.Decl;
		if (kind == shape.identKind) return RefKind.Read;
		return null;
	}
}

/**
 * One classified reference site discovered by `Refs.find`.
 *
 * `name` is redundant with the search target (the walker only emits
 * matching nodes) but is kept on the hit so downstream renderers can
 * be driven by the hit alone without threading the target separately.
 */
@:nullSafety(Strict)
final class RefHit {

	public final kind:RefKind;
	public final name:String;
	public final span:Span;

	public function new(kind:RefKind, name:String, span:Span) {
		this.kind = kind;
		this.name = name;
		this.span = span;
	}
}

/**
 * Reference classification per `docs/cli-query-tool.md` JSON schema.
 *
 * Phase 3.1 emits `Decl` and `Read` only. `Write` is reserved for
 * Slice 3.3 (assign-parent detection); 3.1 callers asking for
 * `--writes` get an empty result.
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
