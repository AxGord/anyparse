package anyparse.query;

import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.runtime.Span;

/**
 * The types one file writes, spelled as a `CallGraph` keys them (`CallGraphImports.typeOf`): a name an import or an
 * alias of the file binds, or a dotted path, is the type it names — a library type never merges into a project type
 * of its simple name — and an unannotated local initialised by a `new` holds the type it makes. The declared types a
 * `TypeInfoProvider` reads by simple name, re-keyed.
 */
@:nullSafety(Strict)
final class CallGraphKeys {

	/** Binding offset -> the type a declaration names, as the graph keys it. */
	public final declaredTypes: Map<Int, String> = [];

	/** Binding offset -> the declaration's written type, the type it names (`Null<…>` peeled) spelled as the graph keys it. */
	public final typeSources: Map<Int, String> = [];

	private final _imports: CallGraphImports;
	private final _file: String;
	private final _typeSyntax: TypeSyntaxReader;

	/** The keys of the declarations `provider` reads in `source`, the text of `file` (none without a provider). */
	public function new(
		imports: CallGraphImports, file: String, typeSyntax: TypeSyntaxReader, provider: Null<TypeInfoProvider>, source: String
	) {
		_imports = imports;
		_file = file;
		_typeSyntax = typeSyntax;
		final simpleTypes: Map<Int, String> = provider == null ? [] : provider.declaredTypes(source);
		final writtenSources: Map<Int, String> = provider == null ? [] : provider.declaredTypeSources(source);
		for (at => simple in simpleTypes) {
			final written: Null<String> = outerPathOf(writtenSources[at]);
			declaredTypes[at] = written == null || simple == 'Null' || SourceText.lastSegment(written) != simple
				? simple
				: imports.typeOf(file, written);
		}
		for (at => written in writtenSources) typeSources[at] = keyed(written);
	}

	/**
	 * Type every local of `tree` (a node of `localDeclKinds`) written with no annotation whose initializer is a
	 * `newExprKind` node by the type it makes: the type the language gives it.
	 */
	public function typeNewLocals(tree: QueryNode, localDeclKinds: Array<String>, newExprKind: String): Void {
		final at: Null<Span> = tree.span;
		final init: Null<QueryNode> = tree.children.length == 0 ? null : tree.children[tree.children.length - 1];
		final made: Null<String> = init == null || init.kind != newExprKind ? null : init.name;
		if (at != null && made != null && localDeclKinds.contains(tree.kind) && !typeSources.exists(at.from)) {
			typeSources[at.from] = keyed(made);
			declaredTypes[at.from] = _imports.typeOf(_file, made);
		}
		for (c in tree.children) typeNewLocals(c, localDeclKinds, newExprKind);
	}

	/** The dotted or simple path of the type `typeSource` names, `Null<…>` peeled unless `peelNull` is false; null for any other type. */
	public function outerPathOf(typeSource: Null<String>, peelNull: Bool = true): Null<String> {
		final t: Null<TypeSyntax> = typeSource == null ? null : _typeSyntax(typeSource);
		return switch ((peelNull ? t?.wrapped(['Null']) : null) ?? t)?.shape {
			case Nominal(path, _): path;
			case _: null;
		};
	}

	/**
	 * The type a call returns, from `simple` — the provider's simple name of its return type — and `written`, the type
	 * written: that type's dotted path when it is written as one, a library type then keyed apart; `simple` otherwise.
	 */
	public function returnedPath(simple: Null<String>, written: Null<String>): Null<String> {
		final path: Null<String> = outerPathOf(written);
		return simple != null && path != null && path.indexOf('.') >= 0 && SourceText.lastSegment(path) == simple ? path : simple;
	}

	/** `typeSource`, written in the file, with the type it names (`Null<…>` peeled) spelled as the graph keys it. */
	public function keyed(typeSource: String): String {
		final t: Null<TypeSyntax> = _typeSyntax(typeSource);
		final outer: Null<TypeSyntax> = t?.wrapped(['Null']) ?? t;
		final from: Int = outer?.span.from ?? 0;
		return switch outer?.shape {
			case Nominal(path, _) if (typeSource.substr(from, path.length) == path):
				final key: String = _imports.typeOf(_file, path);
				key == path ? typeSource : typeSource.substring(0, from) + key + typeSource.substring(from + path.length);
			case _: typeSource;
		};
	}

	/**
	 * The dotted path a field access written off a package names (`sys.io.File`): every link a plain field read
	 * (`isLink`), the innermost an identifier `unbound` says binds to nothing; null for any other shape.
	 */
	public static function packagePathOf(access: QueryNode, isLink: QueryNode -> Bool, unbound: QueryNode -> Bool): Null<String> {
		final segments: Array<String> = [];
		var at: QueryNode = access;
		while (isLink(at) && at.children.length > 0) {
			final link: Null<String> = at.name;
			if (link == null) return null;
			segments.unshift(link);
			at = at.children[0];
		}
		final root: Null<String> = at.name;
		if (root == null || CallGraphNames.isTypeLike(root) || !unbound(at)) return null;
		segments.unshift(root);
		return segments.join('.');
	}

}
