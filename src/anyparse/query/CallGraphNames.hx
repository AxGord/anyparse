package anyparse.query;

import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.SymbolIndex.TypeDeclInfo;
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
	 * The type parameters a function declaration spells between its name and its parameter list (`f<T, U:B>`),
	 * read from the source because the projection keeps only their constraints.
	 */
	public static function declaredTypeParams(source: String, span: Span, name: String): Array<String> {
		final open: Int = source.indexOf('(', span.from);
		if (open < 0) return [];
		final header: String = source.substring(span.from, open);
		final named: EReg = new EReg('(^|[^A-Za-z0-9_])$name\\s*<', '');
		if (!named.match(header)) return [];
		final head: String = header.substring(named.matchedPos().pos + named.matched(0).length - 1).trim();
		if (!head.startsWith('<') || !head.endsWith('>')) return [];
		final out: Array<String> = [];
		for (part in NominalTypes.splitTypeArgumentList(head.substring(1, head.length - 1))) {
			final colon: Int = part.indexOf(':');
			final param: String = StringTools.trim(colon < 0 ? part : part.substring(0, colon));
			if (param.length > 0) out.push(param);
		}
		return out;
	}

	/** Whether `typeSource` spells one of `names` as a whole type name (not as a segment of a dotted path). */
	public static function mentionsTypeName(typeSource: String, names: Array<String>): Bool {
		return names.length > 0 && typeNamePattern(names).match(typeSource);
	}

	/** `typeSource` with each whole type name `params[i]` in it replaced by `args[i]`, all at once. */
	public static function substituteTypeParams(typeSource: String, params: Array<String>, args: Array<String>): String {
		if (params.length == 0) return typeSource;
		return typeNamePattern(params).map(typeSource, m -> m.matched(1) + args[params.indexOf(m.matched(2))]);
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

	/** Inner simple name of a `Null<...>` annotation source, or null. */
	public static function unwrapNullable(typeSource: Null<String>): Null<String> {
		if (typeSource == null) return null;
		final trimmed: String = StringTools.trim(typeSource);
		final prefix: String = 'Null<';
		if (!trimmed.startsWith(prefix) || !trimmed.endsWith('>')) return null;
		var inner: String = trimmed.substring(prefix.length, trimmed.length - 1).trim();
		final lt: Int = inner.indexOf('<');
		if (lt != -1) inner = inner.substring(0, lt);
		final dot: Int = inner.lastIndexOf('.');
		if (dot != -1) inner = inner.substring(dot + 1);
		inner = inner.trim();
		return inner.length > 0 && isTypeLike(inner) ? inner : null;
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

	/** A pattern matching any of `names` standing alone as a type name: not inside an identifier, not after a `.`. */
	private static function typeNamePattern(names: Array<String>): EReg {
		return new EReg('(^|[^A-Za-z0-9_.])(' + names.join('|') + ')(?![A-Za-z0-9_])', 'g');
	}

}
