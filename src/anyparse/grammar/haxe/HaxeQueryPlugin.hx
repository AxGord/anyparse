package anyparse.grammar.haxe;

import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;

/**
 * Haxe grammar binding for the `apq` query engine.
 *
 * Parses with the existing Plain-mode `HaxeModuleParser` and translates
 * the typed AST into a generic `QueryNode` tree using runtime type
 * introspection (`Type` / `Reflect`). The translation is intentionally
 * simple in Phase 1:
 *
 *  - **Enum values become nodes.** `kind` is the constructor name
 *    verbatim (`ClassDecl`, `FnDecl`, `IfStmt`, …). Plain-mode parses
 *    never wrap nodes in any extra envelope; what you see in the
 *    `enum` declarations of the grammar package is what `apq ast`
 *    emits.
 *  - **Anonymous structs are transparent.** Their fields contribute
 *    children to the enclosing enum-ctor node. A struct's `name` field
 *    (when a String) becomes the parent ctor's `name` slot.
 *  - **Arrays are transparent.** Their elements contribute children.
 *  - **Trivial-mode wrappers** (`{ node:T, leadingComments:…, … }`) are
 *    transparent on the `node` slot; the Plain-mode parser does not
 *    produce them, but the descent is in place for a future
 *    Trivia-mode switch.
 *  - **Primitive leaves** (`String`/`Int`/`Float`/`Bool`) do not emit
 *    nodes — they are absorbed into name detection when applicable.
 *
 * The root is a synthetic `module` node so users have a single
 * top-level handle in selectors and JSON output.
 */
@:nullSafety(Strict)
final class HaxeQueryPlugin implements GrammarPlugin {

	public function new() {}

	public function langName():String return 'haxe';

	public function parseFile(source:String):QueryNode {
		final ast:HxModule = HaxeModuleParser.parse(source);
		final children:Array<QueryNode> = [];
		appendNodes(ast.decls, children);
		return new QueryNode('module', null, children);
	}

	private function appendNodes(value:Dynamic, into:Array<QueryNode>):Void {
		if (value == null) return;
		if (value is String) return;
		final t:Type.ValueType = Type.typeof(value);
		switch t {
			case TEnum(_):
				into.push(makeEnumNode(value));
			case TObject:
				if (Reflect.hasField(value, 'node')) {
					appendNodes(Reflect.field(value, 'node'), into);
					return;
				}
				for (field in Reflect.fields(value)) {
					if (field == 'name') continue;
					appendNodes(Reflect.field(value, field), into);
				}
			case TClass(_):
				if (Std.isOfType(value, Array)) {
					final arr:Array<Dynamic> = cast value;
					for (e in arr) appendNodes(e, into);
				}
			case _:
		}
	}

	private function makeEnumNode(value:Dynamic):QueryNode {
		final ctor:String = Type.enumConstructor(value);
		final params:Array<Dynamic> = Type.enumParameters(value);
		var name:Null<String> = null;
		final children:Array<QueryNode> = [];
		for (p in params) {
			if (name == null) name = extractName(p);
			appendNodes(p, children);
		}
		return new QueryNode(ctor, name, children);
	}

	private function extractName(value:Dynamic):Null<String> {
		if (value == null) return null;
		if (value is String) return value;
		final t:Type.ValueType = Type.typeof(value);
		switch t {
			case TObject:
				if (Reflect.hasField(value, 'name')) {
					final n:Dynamic = Reflect.field(value, 'name');
					if (n is String) return n;
				}
				if (Reflect.hasField(value, 'node')) return extractName(Reflect.field(value, 'node'));
			case _:
		}
		return null;
	}
}
