package anyparse.query;

import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/** The name arithmetic `CallGraph` resolves with: type declarations, module names, dotted paths, written type heads. */
@:nullSafety(Strict)
final class CallGraphNames {

	/**
	 * Type-decl kinds `RefactorSupport.typeDeclOf` does not cover: `abstract
	 * class` and `enum abstract` project as their own kinds with the name
	 * directly on the node. Without these the walks lose the enclosing type
	 * inside such bodies (members mis-registered under the module pseudo-type).
	 */
	private static final EXTRA_TYPE_DECL_KINDS: Array<String> = ['AbstractClassDecl', 'EnumAbstractDecl'];

	/**
	 * The written return type of the function `fn`: its last type annotation (one of `annotationKinds`)
	 * that is its own child rather than a parameter's, or null when it declares none.
	 */
	public static function returnSourceOf(fn: QueryNode, source: String, annotationKinds: Array<String>): Null<String> {
		var found: Null<String> = null;
		for (c in fn.children) {
			final at: Null<Span> = c.span;
			if (at != null && annotationKinds.contains(c.kind)) found = source.substring(at.from, at.to);
		}
		return found;
	}

	/**
	 * Whether `typeSource` names one of `names` as a type anywhere inside it (`Array<T>`, `T -> Void`); a text the
	 * grammar does not read as a type counts as naming them, since nothing proves it does not.
	 */
	public static function mentionsTypeName(typeSource: String, names: Array<String>, typeSyntax: TypeSyntaxReader): Bool {
		if (names.length == 0) return false;
		final t: Null<TypeSyntax> = typeSyntax(typeSource);
		return t == null || t.descendants().exists(d -> namedAmong(d, names));
	}

	/**
	 * `typeSource` with each type named `params[i]` in it replaced by `args[i]`, all at once — or unchanged when the
	 * grammar does not read it as a type.
	 */
	public static function substituteTypeParams(
		typeSource: String, params: Array<String>, args: Array<String>, typeSyntax: TypeSyntaxReader
	): String {
		final t: Null<TypeSyntax> = params.length == 0 ? null : typeSyntax(typeSource);
		if (t == null) return typeSource;
		final out: StringBuf = new StringBuf();
		var at: Int = 0;
		for (d in t.descendants()) switch d.shape {
			case Nominal(path, _) if (params.contains(path)):
				out.add(typeSource.substring(at, d.span.from));
				out.add(args[params.indexOf(path)]);
				at = d.span.from + path.length;
			case _:
		}
		out.add(typeSource.substring(at));
		return out.toString();
	}

	/**
	 * The written type of field `field` of the anonymous structure type `type` (`{ a: Int, ?b: T }`), or null
	 * when `type` is not one or declares no such field.
	 */
	public static function anonFieldTypeSource(type: Null<TypeSyntax>, field: String): Null<String> {
		return switch type?.shape {
			case Structure(fields): fields.find(f -> f.name == field)?.type.text;
			case _: null;
		};
	}

	/** Whether `t` is a typedef naming another type of its own simple name — a re-export, not a second declaration. */
	public static function selfAlias(t: TypeDeclInfo): Bool {
		return t.aliasTargetNominal == t.name;
	}

	/** The function declaration of `tree` (a node of one of `fnKinds`) starting at `from`, or null. */
	public static function functionNodeAt(tree: QueryNode, from: Int, fnKinds: Array<String>): Null<QueryNode> {
		var decl: Null<QueryNode> = null;
		function find(node: QueryNode): Void {
			if (decl != null) return;
			if (node.span?.from == from && fnKinds.contains(node.kind)) {
				decl = node;
				return;
			}
			for (c in node.children) find(c);
		}
		find(tree);
		return decl;
	}

	/** Simple name of the type declaration `node` introduces, or null. */
	public static function typeNameOf(node: QueryNode): Null<String> {
		final td: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
		if (td != null) return td.name;
		final name: Null<String> = node.name;
		return name != null && EXTRA_TYPE_DECL_KINDS.contains(node.kind) ? name : null;
	}

	/** `a.b.C.m` → last `count` dot-segments joined (`C.m` for count 2). */
	public static function lastSegments(path: String, count: Int): String {
		final parts: Array<String> = path.split('.');
		return parts.length <= count ? path : parts.slice(parts.length - count).join('.');
	}

	public static function isTypeLike(name: String): Bool {
		final c: Int = name.fastCodeAt(0);
		return c >= 'A'.code && c <= 'Z'.code;
	}

	/**
	 * `file` in one spelling per path: separators as `/`, no `./` segment, no doubled separator — the key two
	 * spellings of the same file (`./src/Y.hx`, `src/Y.hx`) share.
	 */
	public static function normalizePath(file: String): String {
		var path: String = file.replace('\\', '/');
		while (path.indexOf('//') >= 0) path = path.replace('//', '/');
		while (path.indexOf('/./') >= 0) path = path.replace('/./', '/');
		while (path.startsWith('./')) path = path.substr(2);
		return path;
	}

	public static function moduleTypeName(file: String): String {
		var base: String = file;
		final slash: Int = base.lastIndexOf('/');
		if (slash != -1) base = base.substring(slash + 1);
		final backslash: Int = base.lastIndexOf('\\');
		if (backslash != -1) base = base.substring(backslash + 1);
		final dot: Int = base.indexOf('.');
		return dot == -1 ? base : base.substring(0, dot);
	}

	/** The written result of the function type `type` (`Int -> S`, `(a: Int) -> S`), or null when `type` is not a function type. */
	public static function functionReturnSource(type: Null<TypeSyntax>): Null<String> {
		return switch type?.shape {
			case Function(_, ret, _): ret.text;
			case _: null;
		};
	}

	/** Whether `t` is a type named by one of `names`. */
	private static function namedAmong(t: TypeSyntax, names: Array<String>): Bool {
		return switch t.shape {
			case Nominal(path, _): names.contains(path);
			case _: false;
		};
	}

}
