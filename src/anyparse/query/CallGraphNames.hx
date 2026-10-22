package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.runtime.Span;

using Lambda;

/** The name arithmetic `CallGraph` resolves with: type declarations, module names, dotted paths, written type heads. */
@:nullSafety(Strict)
final class CallGraphNames {

	/** Whether `t` is a typedef naming another type of its own simple name — a re-export, not a second declaration. */
	public static inline function selfAlias(t: TypeDeclInfo): Bool {
		return t.aliasTargetNominal == t.name;
	}

	/**
	 * The written return type of the function or lambda `fn` among its file's `returns` (`returnSourcesOf`): what the grammar
	 * reads in its return-type slot, never the bound of a type parameter the query tree flattens beside it. Null when `fn` is
	 * written with none.
	 */
	public static function returnSourceOf(fn: QueryNode, returns: Map<Int, String>): Null<String> {
		final at: Null<Span> = fn.span;
		return at == null ? null : returns[at.from]?.trim();
	}

	/**
	 * The written return type of every function of `source`, by the offset of its declaration (`SpanTypeInfo.returnTypeSources`):
	 * none for a `plugin` with no batched span info, which then proves no return type.
	 */
	public static function returnSourcesOf(plugin: GrammarPlugin, source: String): Map<Int, String> {
		return plugin is SpanTypeInfoProvider ? (cast plugin: SpanTypeInfoProvider).spanTypeInfo(source).returnTypeSources : [];
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

	/**
	 * The written types of the parameters the function declared at `from` in `tree` (the text `source`) writes, as `provider`
	 * reads them, whether its last one is a rest parameter, and the position of the first one a call may skip — optional or
	 * carrying a default value; their count for none, 0 for a grammar naming no optional kind; null when unreadable.
	 */
	public static function declaredParams(
		tree: QueryNode, source: String, from: Int, shape: RefShape, provider: Null<TypeInfoProvider>
	): Null<DeclaredParams> {
		final found: Null<QueryNode> = functionNodeAt(tree, from, shape.functionKinds ?? []);
		return found == null ? null : paramsOf(found, provider?.declaredTypeSources(source) ?? [], shape);
	}

	/**
	 * `declaredParams` of the function node `fn` itself, its file's written annotations `sources` keyed by binding offset
	 * (`TypeInfoProvider.declaredTypeSources`).
	 */
	public static function paramsOf(fn: QueryNode, sources: Map<Int, String>, shape: RefShape): DeclaredParams {
		return paramsBy(fn, sources, shape.paramKinds ?? [], shape.typeAnnotationKinds ?? [], shape.optionalParamKind, shape.restParamKind);
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

	/**
	 * The parameters `fn` declares (`paramsOf`), read by the grammar's parameter kinds, its annotation kinds, its optional
	 * and its rest parameter kind — what the index records of every member it holds (`MemberInfo.paramSkippableFrom`).
	 */
	public static function paramsBy(
		fn: QueryNode, sources: Map<Int, String>, paramKinds: Array<String>, annotationKinds: Array<String>, optionalKind: Null<String>,
		restKind: Null<String>
	): DeclaredParams {
		final params: Array<QueryNode> = [for (c in fn.children) if (paramKinds.contains(c.kind)) c];
		// `?p` and `p = v` alike are skippable; a grammar naming no optional kind may skip any
		var skippable: Int = 0;
		while (
			optionalKind != null && skippable < params.length && params[skippable].kind != optionalKind
			&& !params[skippable].children.exists(c -> !annotationKinds.contains(c.kind))
		)
			skippable++;
		return {
			skippableFrom: skippable,
			params: [
				for (c in params) {
					final at: Null<Span> = c.span;
					at == null ? null : sources[at.from];
				}
			],
			rest: params.length > 0 && params[params.length - 1].kind == restKind
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

/** A function's parameters as its declaration writes them (`CallGraphNames.paramsOf`). */
typedef DeclaredParams = {
	/** The written type of each parameter, in order; null for one written without a type. */
	final params: Array<Null<String>>;

	/** Whether the last parameter is a rest parameter. */
	final rest: Bool;

	/** The position of the first parameter a call may skip — optional or carrying a default value; the count for none. */
	final skippableFrom: Int;
}
