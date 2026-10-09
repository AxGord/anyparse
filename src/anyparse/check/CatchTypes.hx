package anyparse.check;

import anyparse.query.CallGraphTypes;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;

using Lambda;

/**
 * Whether a `catch` clause PROVABLY catches what a `throw` raises — a positive answer, so a clause that may not is taken
 * to let the exception through. A clause catches everything when its variable is untyped or written as a catch-all
 * type (`RefShape.catchAllTypeNames`, or the language's exception type `RefShape.exceptionTypePath`, by its path or, with no project
 * type of that simple name — or no `types` to ask — by its simple name). A typed clause catches a thrown value of a known type: the
 * same written type, or a supertype of it by the index's type chain, both names declared once. A thrown value of no
 * known type — a raising call, a `throw` of anything but a string literal or a `new` — is caught by a catch-all only.
 */
@:nullSafety(Strict)
final class CatchTypes {

	/** The written type of a string literal's value. */
	private static inline final STRING_TYPE: String = 'String';

	/**
	 * The written type the `throw` node `node` raises a value of: a string literal's, a `new T(…)`'s `T`; null for any
	 * other value, whose type is unknown.
	 */
	public static function thrownType(node: QueryNode, shape: RefShape): Null<String> {
		final value: Null<QueryNode> = node.children.length == 1 ? node.children[0] : null;
		if (value == null) return null;
		if ((shape.stringLiteralKinds ?? []).contains(value.kind)) return STRING_TYPE;
		return value.kind == shape.newExprKind ? value.name : null;
	}

	/** Whether one of the `catch` clauses `clauses` provably catches a thrown value of the written type `thrown` (null: unknown). */
	public static function anyCatches(clauses: Array<QueryNode>, thrown: Null<String>, shape: RefShape, ?types: CallGraphTypes): Bool {
		return clauses.exists(c -> catches(c, thrown, shape, types));
	}

	/**
	 * Whether the `catch` clause `clause` provably catches a thrown value of the written type `thrown` (null: unknown),
	 * reading supertypes off `types` when given.
	 */
	public static function catches(clause: QueryNode, thrown: Null<String>, shape: RefShape, ?types: CallGraphTypes): Bool {
		final declared: Null<QueryNode> = clause.type;
		if (declared == null) return true;
		final written: Null<String> = writtenType(declared, shape);
		if (written == null) return false;
		if (catchesAll(written, shape, types)) return true;
		if (thrown == null) return false;
		if (written == thrown) return true;
		return types != null && types.declarationCount(thrown) == 1 && types.declarationCount(written) == 1
			&& types.firstOnChain(thrown, t -> t == written) != null;
	}

	/**
	 * The written type `declared` (a type annotation node) as text without whitespace — `Null<String>`, `haxe.io.Eof` —
	 * or null for a shape other than named types.
	 */
	public static function writtenType(declared: QueryNode, shape: RefShape): Null<String> {
		final name: Null<String> = declared.name;
		if (!(shape.typeAnnotationKinds ?? []).contains(declared.kind) || name == null) return null;
		final args: Array<Null<String>> = [for (c in declared.children) writtenType(c, shape)];
		if (args.contains(null)) return null;
		return args.length == 0 ? name : '$name<${args.join(',')}>';
	}

	/** Whether a clause written as `written` catches every thrown value. */
	private static function catchesAll(written: String, shape: RefShape, types: Null<CallGraphTypes>): Bool {
		if ((shape.catchAllTypeNames ?? []).contains(written)) return true;
		final exception: Null<String> = shape.exceptionTypePath;
		if (exception == null) return false;
		if (written == exception) return true;
		final simple: String = exception.substring(exception.lastIndexOf('.') + 1);
		return written == simple && (types == null || types.declarationCount(simple) == 0);
	}

}
