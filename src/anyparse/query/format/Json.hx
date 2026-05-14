package anyparse.query.format;

import anyparse.format.text.JsonFormat;
import anyparse.query.QueryNode;
import anyparse.query.format.json.AstDumpJson;
import anyparse.query.format.json.AstDumpJsonWriter;
import anyparse.query.format.json.AstMatchesJson;
import anyparse.query.format.json.AstMatchesJsonWriter;
import anyparse.query.format.json.AstNodeJson;

/**
 * JSON renderer for `apq ast` output.
 *
 * Thin adapter — converts a generic `QueryNode` tree into the typed
 * `AstDumpJson` / `AstMatchesJson` schemas and delegates the actual
 * serialization to the macro-generated writers in
 * `anyparse.query.format.json`. The library claim is that any format
 * description can be expressed declaratively; this file dogfoods that
 * claim for `apq` itself.
 *
 * Schemas (see `docs/cli-query-tool.md`):
 *
 *  - Tree mode: `{ file:String, tree:Node }`
 *  - Select mode: `{ file:String, matches:Array<Node> }`
 *
 *  Node = { kind:String, ?name:String, children:Array<Node> }
 *
 * `span` is omitted in Phase 1 — Plain-mode parsers do not emit spans.
 */
@:nullSafety(Strict)
final class Json {

	public static function renderTree(file:String, tree:QueryNode):String {
		final dump:AstDumpJson = {file: file, tree: toAst(tree)};
		return AstDumpJsonWriter.write(dump, JsonFormat.instance.defaultWriteOptions) + '\n';
	}

	public static function renderMatches(file:String, matches:Array<QueryNode>):String {
		final out:AstMatchesJson = {file: file, matches: matches.map(toAst)};
		return AstMatchesJsonWriter.write(out, JsonFormat.instance.defaultWriteOptions) + '\n';
	}

	private static function toAst(node:QueryNode):AstNodeJson {
		final children:Array<AstNodeJson> = node.children.map(toAst);
		final n:Null<String> = node.name;
		if (n == null) return {kind: node.kind, children: children};
		final name:String = n;
		return {kind: node.kind, name: name, children: children};
	}
}
