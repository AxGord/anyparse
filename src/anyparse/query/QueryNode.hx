package anyparse.query;

/**
 * Generic AST node view exposed by a `GrammarPlugin` to the query
 * engine. The engine never reads the raw `value` — it operates on
 * `kind` / `name` / `children` only. Plugins decide how their
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
 * `span` is reserved for future spans-on-AST work. Plain-mode parsers
 * do not emit spans in Phase 1 — null is the normal value.
 */
@:nullSafety(Strict)
final class QueryNode {

	public final kind:String;
	public final name:Null<String>;
	public final children:Array<QueryNode>;

	public function new(kind:String, name:Null<String>, children:Array<QueryNode>) {
		this.kind = kind;
		this.name = name;
		this.children = children;
	}
}
