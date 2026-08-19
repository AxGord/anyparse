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
 * offsets from the start of the source string). The Haxe plugin now
 * populates spans comprehensively — deep sub-expressions, operators and
 * literals all carry tight spans, so a `--at` / `--at --kind` cursor can
 * address any node. A null span is the exception (a synthetic / transparent
 * node the plugin built without span tracking), not the rule. The `apq
 * search` matcher reports `file:line:col` for each match by resolving the
 * outermost match node's span via `Span.lineCol(source)`.
 */
@:nullSafety(Strict)
final class QueryNode {

	public final kind: String;
	public final name: Null<String>;
	public final children: Array<QueryNode>;
	public final span: Null<Span>;

	/**
	 * The DECLARED TYPE of this node, when the grammar projects one; null otherwise.
	 *
	 * A slot, not a child, and for the same reason `name` is one: it describes the node
	 * rather than sitting inside it. A `var` / `final` declaration's children are its
	 * initializer and its comma-continuations, and forty-odd consumers read them
	 * positionally — `decl.children[0]` IS the initializer, `children.length != 1` IS
	 * "one binding, no continuation". Putting the annotation among them would move every
	 * one of those indices by one, and only where the source happened to be annotated.
	 *
	 * The slot's subtree is the type's own shape: kind = the grammar's type ctor (for
	 * Haxe `Named` / `Anon` / `Arrow` / `ArrowFn` / …), name = the nominal head, children
	 * = the type ARGUMENTS. So `final xs:Array<CodePoint>` answers `Array` at the head and
	 * `CodePoint` at `type.children[0]`.
	 *
	 * A kind alone could not carry this: the type and expression vocabularies collide —
	 * Haxe's `Arrow` is BOTH the `->` of a function type and the `=>` of a map literal —
	 * so "which child is the annotation" is not answerable by kind, only by slot.
	 */
	public final type: Null<QueryNode>;

	public function new(
		kind: String, name: Null<String>, children: Array<QueryNode>, ?span: Null<Span>, ?type: Null<QueryNode>
	) {
		this.kind = kind;
		this.name = name;
		this.children = children;
		this.span = span;
		this.type = type;
	}

}
