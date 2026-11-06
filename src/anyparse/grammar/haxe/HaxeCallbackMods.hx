package anyparse.grammar.haxe;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.ShapeVocab;
import anyparse.runtime.Span;

using Lambda;

/**
 * The one answer to "is this Haxe method a callback": a method that returns no value, or that its own file reads as a
 * function value, carries the neutral modifier `callback` in the `NamingSupport` projection - so a naming rule about
 * listeners selects on it through `requireMods` and a value-returning method that is only ever called is left alone.
 *
 * "Reads as a function value" is a read of THIS type's member within the file: a bare name that binds no local or
 * parameter (`Refs`) inside the type, or `this.name` / `Type.name`; either way not the callee of a call. A read off any
 * other receiver, in another file, or inside `macro` is unseen, which can only leave a callback unflagged. Known
 * unflagged shape: a no-parameter method whose type-parameter constraint sits where a result type would
 * (`function onX<T:Y>() {}`) - the node kinds alone cannot tell the constraint from the result.
 */
@:nullSafety(Strict)
final class HaxeCallbackMods {

	/** The neutral modifier a callback method carries. */
	public static inline final CALLBACK_MOD: String = 'callback';

	private static final NON_RESULT_KINDS: Array<String> = ['Required', 'Optional', 'Rest', 'BlockBody', 'ExprBody', 'NoBody'];
	private static final VALUE_RETURN_KIND: String = 'ReturnStmt';
	private static final MACRO_KIND: String = 'MacroExpr';
	private static final SELF_NAME: String = 'this';
	private static final SUPER_NAME: String = 'super';

	private final _reads: Array<String> = [];
	private final _readMethods: Array<QueryNode> = [];
	private final _nested: Array<String>;

	public function new(tree: QueryNode) {
		final shape: RefShape = HaxeRefShape.shape();
		_nested = ShapeVocab.nestedFunctionKinds(shape);
		final bare: Map<Int, String> = [];
		collect(tree, null, null, bare);
		final hits: Map<String, Array<RefHit>> = Refs.findMulti([for (name in bare) name], tree, shape);
		for (name => found in hits) for (hit in found) {
			final target: Null<QueryNode> = hit.bindingNode;
			if (
				hit.kind == RefKind.Read
				&& target != null
				&& bare[hit.span.from] == name
				&& HaxeNamingSupport.categoryOf(target, []) == NamingCategory.Method
			)
				_readMethods.push(target);
		}
	}

	/** `[CALLBACK_MOD]` for a method declaration `node` named `name` of the type `owner` that is a callback, else an empty list. */
	public function modsOf(node: QueryNode, category: NamingCategory, name: String, owner: Null<String>): Array<String> {
		if (category != NamingCategory.Method) return [];
		return returnsNoValue(node) || _readMethods.contains(node) || _reads.contains(key(owner, name)) ? [CALLBACK_MOD] : [];
	}

	private function note(owner: Null<String>, name: String): Void {
		final k: String = key(owner, name);
		if (!_reads.contains(k)) _reads.push(k);
	}

	/**
	 * Records every non-callee read of a name inside `node`: a bare identifier waits in `bare` for `Refs` to say whether it
	 * binds a member, a field access off `this` or a type name is a read of that type's member right away.
	 */
	private function collect(node: QueryNode, parent: Null<QueryNode>, owner: Null<String>, bare: Map<Int, String>): Void {
		if (node.kind == MACRO_KIND) return;
		final here: Null<String> = HaxeNamingSupport.categoryOf(node, []) == NamingCategory.Type ? node.name ?? owner : owner;
		final name: Null<String> = node.name;
		final callee: Bool = parent != null && parent.kind == 'Call' && parent.children[0] == node;
		if (name != null && !callee) {
			final span: Null<Span> = node.span;
			if (node.kind == 'IdentExpr' && span != null && name != SELF_NAME && name != SUPER_NAME) {
				bare[span.from] = name;
			} else if (node.kind == 'FieldAccess' && node.children.length > 0) {
				final receiver: QueryNode = node.children[0];
				final of: Null<String> = if (receiver.kind != 'IdentExpr' || receiver.name == SUPER_NAME)
					null
				else if (receiver.name == SELF_NAME)
					here
				else
					receiver.name;
				if (of != null) note(of, name);
			}
		}
		for (child in node.children) collect(child, node, here, bare);
	}

	/**
	 * A declared result type `Void`, or - with none declared - a body that holds no `return <value>` of its own; a result
	 * type that is anything else, or an expression body, is a value.
	 */
	private function returnsNoValue(fn: QueryNode): Bool {
		final kids: Array<QueryNode> = fn.children;
		if (kids.length == 0) return true;
		final body: QueryNode = kids[kids.length - 1];
		final before: Null<QueryNode> = kids.length > 1 ? kids[kids.length - 2] : null;
		return before != null && !NON_RESULT_KINDS.contains(before.kind)
			? before.kind == 'Named' && before.name == 'Void'
			: body.kind == 'NoBody' || (body.kind == 'BlockBody' && !holdsValueReturn(body));
	}

	private function holdsValueReturn(node: QueryNode): Bool {
		return node.kind == VALUE_RETURN_KIND || (!_nested.contains(node.kind) && node.children.exists(holdsValueReturn));
	}

	private static function key(owner: Null<String>, name: String): String {
		return '${owner ?? ''}.$name';
	}

}
