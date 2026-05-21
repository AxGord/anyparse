package anyparse.query;

import anyparse.runtime.Span;
import anyparse.runtime.Span.Position;

/**
 * String-literal / leaf-name walker for `apq lit` — finds verbatim
 * occurrences of a target text inside captured leaf-node `name` slots.
 *
 * Use case: annotation-key lookups and similar "prose inside code"
 * searches that are NOT structural patterns. The conventional grep
 * route is gated on parseable `.hx` files (the hxq skill's `# HXQ_OK:prose`
 * escape hatch). `apq lit` solves it inside the structural pipeline:
 * the parser already lifts every string literal into a `Literal`
 * leaf whose `name` carries the verbatim content, so walking the tree
 * is byte-for-byte equivalent to grepping the source for that string
 * — minus all the comment / interpolation / multi-line false positives
 * a raw text search produces.
 *
 * Default kind filter is `Literal` (the leaf inside `SingleStringExpr`
 * / `DoubleStringExpr` / `RawString` in the Haxe plugin); pass a
 * comma-separated list via `--kind` to widen or override. Common
 * widenings:
 *
 *  - `Literal,IdentExpr` — string literals + bare identifier uses.
 *  - `IdentExpr` — only identifier references (similar to `refs`
 *    but text-only, no scope or binding resolution).
 *
 * The plugin is consulted indirectly: `apq lit` reuses the standard
 * `plugin.parseFile` value-AST so every captured leaf surfaces through
 * the same `QueryNode.name` slot the engine already exposes for
 * `--select` / `refs` / `meta`. No plugin-specific code lives here.
 */
@:nullSafety(Strict)
final class Lit {

	/**
	 * Walk `tree`, collecting every leaf-or-named node whose `name`
	 * matches `target`. `exact=true` requires `name == target`; default
	 * is substring match (`name.indexOf(target) >= 0`).
	 *
	 * `kindFilter` (non-empty) restricts hits to nodes whose `kind` is
	 * in the set. Empty / null means no filter (match every node with
	 * a non-null name). The check is by exact string equality on
	 * `kind` — no kind-equivalence consultation (that is search-only;
	 * `lit` is a leaf-name probe with no pattern semantics).
	 */
	public static function find(target:String, tree:QueryNode, exact:Bool, ?kindFilter:Array<String>):Array<LitHit> {
		final out:Array<LitHit> = [];
		final filter:Null<Array<String>> = (kindFilter == null || kindFilter.length == 0) ? null : kindFilter;
		walk(target, tree, exact, filter, out);
		return out;
	}

	private static function walk(target:String, node:QueryNode, exact:Bool, filter:Null<Array<String>>, out:Array<LitHit>):Void {
		final n:Null<String> = node.name;
		if (n != null) {
			final kindOk:Bool = filter == null || filter.contains(node.kind);
			if (kindOk) {
				final hit:Bool = exact ? n == target : n.indexOf(target) >= 0;
				if (hit && node.span != null) out.push(new LitHit(node.kind, n, (node.span : Span)));
			}
		}
		for (c in node.children) walk(target, c, exact, filter, out);
	}

	public static function render(file:String, source:String, hits:Array<LitHit>, flat:Bool = false):String {
		final buf:StringBuf = new StringBuf();
		if (!flat && hits.length > 0) buf.add('$file:\n');
		for (h in hits) {
			final pos:Position = h.span.lineCol(source);
			if (flat) buf.add('$file:${pos.line}:${pos.col}: ${h.kind} \'${h.name}\'\n');
			else buf.add('  ${pos.line}:${pos.col}: ${h.kind} \'${h.name}\'\n');
		}
		return buf.toString();
	}
}

@:nullSafety(Strict)
final class LitHit {

	public final kind:String;
	public final name:String;
	public final span:Span;

	public function new(kind:String, name:String, span:Span) {
		this.kind = kind;
		this.name = name;
		this.span = span;
	}
}
