package anyparse.query;

import anyparse.runtime.Span;

/**
 * Generic AST node view exposed by a `GrammarPlugin` to the query
 * engine. The engine never reads the raw `value` — it operates on
 * `kind` / `name` / `children` / `span` only. Plugins decide how their
 * language-specific AST maps onto this shape.
 *
 * `kind` is the plugin-defined node vocabulary used by `--select` and
 * by JSON output. For Phase 1 the Haxe plugin uses bare enum
 * constructor names (`ClassDecl`, `FnDecl`, `IfStmt`, …) verbatim.
 *
 * `name` is the human-facing identifier for declarations and named
 * references; null when the node has no name. `--select kind:name`
 * filters on this slot.
 *
 * `span` is the source range this node occupies (UTF-16-code-unit
 * offsets from the start of the source string). Null when the plugin
 * built the node without span tracking — most current callers populate
 * spans for top-level grammar-node visits, with inner sub-expression
 * children carrying null. The `apq search` matcher reports
 * `file:line:col` for each match by resolving the outermost match
 * node's span via `Span.lineCol(source)`.
 */
@:nullSafety(Strict)
final class QueryNode {

	public final kind: String;
	public final name: Null<String>;
	public final children: Array<QueryNode>;
	public final span: Null<Span>;

	public function new(kind: String, name: Null<String>, children: Array<QueryNode>, ?span: Null<Span> = null) {
		this.kind = kind;
		this.name = name;
		this.children = children;
		this.span = span;
	}

}
