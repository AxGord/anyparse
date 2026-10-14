package anyparse.query;

import anyparse.query.CallGraph.FnDeclaration;
import anyparse.query.CallGraph.FnNode;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.runtime.Span;

/**
 * The types one file writes, spelled as a `CallGraph` keys them (`CallGraphImports.typeOf`): a name an import or an
 * alias of the file binds, or a dotted path, is the type it names — a library type never merges into a project type
 * of its simple name — and an unannotated local initialised by a `new` holds the type it makes. The declared types a
 * `TypeInfoProvider` reads by simple name, re-keyed. A type another file declares is keyed through THAT file's imports (`keyedIn`,
 * `keyedInFiles`, `paramTypesOf`): a declaration names what its own file binds the name to, wherever the value is read.
 */
@:nullSafety(Strict)
@:access(anyparse.query.CallGraph)
final class CallGraphKeys {

	/** Binding offset -> the type a declaration names, as the graph keys it. */
	public final declaredTypes: Map<Int, String> = [];

	/** Binding offset -> the declaration's written type, the type it names (`Null<…>` peeled) spelled as the graph keys it. */
	public final typeSources: Map<Int, String> = [];

	/** Binding offset -> the call a local written with no type is initialised by: the local holds what that call returns. */
	public final callInitializers: Map<Int, QueryNode> = [];

	/** The binding offsets of the locals whose initializing call `throughInitializer` is reading, against a cycle. */
	private final _reading: Array<Int> = [];

	private final _imports: CallGraphImports;
	private final _file: String;
	private final _typeSyntax: TypeSyntaxReader;

	/** The file's tree, for the type parameters in scope at a declaration (`unkeyedAt`); null when not handed. */
	private final _tree: Null<QueryNode>;

	/** The grammar's function kinds, whose type parameters are in scope inside them. */
	private final _functionKinds: Array<String>;

	/** Each declaration of the file declaring type parameters (by its key, `TypeInfoProvider.typeParamNames`) -> their names. */
	private final _typeParams: Map<Int, Array<String>>;

	/** Every type-parameter name a declaration of the file declares. */
	private final _paramNames: Array<String> = [];

	/**
	 * The keys of the declarations `provider` reads in `source`, the text of `file` (none without a provider), `tree` its
	 * tree: a name a type parameter in scope at the declaration (`TypeParamTable.inScopeAt`, the functions among
	 * `functionKinds`) shadows every import and stays as written.
	 */
	public function new(
		imports: CallGraphImports, file: String, typeSyntax: TypeSyntaxReader, provider: Null<TypeInfoProvider>, source: String,
		?tree: QueryNode, ?functionKinds: Array<String>
	) {
		_imports = imports;
		_file = file;
		_typeSyntax = typeSyntax;
		_tree = tree;
		_functionKinds = functionKinds ?? [];
		_typeParams = provider == null ? [] : provider.typeParamNames(source);
		for (names in _typeParams) for (n in names) if (!_paramNames.contains(n)) _paramNames.push(n);
		final simpleTypes: Map<Int, String> = provider == null ? [] : provider.declaredTypes(source);
		final writtenSources: Map<Int, String> = provider == null ? [] : provider.declaredTypeSources(source);
		for (at => simple in simpleTypes) {
			final written: Null<String> = outerPathOf(writtenSources[at]);
			declaredTypes[at] = written == null || simple == 'Null' || SourceText.lastSegment(written) != simple
				|| unkeyedAt(at, written).contains(written)
				? simple
				: imports.typeOf(file, written);
		}
		for (at => written in writtenSources) typeSources[at] = keyed(written, at);
	}

	/**
	 * `typeSource`, written in the file at the offset `at`, with every type it names spelled as the graph keys it (`keyedIn`),
	 * a type parameter in scope there (`unkeyedAt`) left as written.
	 */
	public function keyed(typeSource: String, at: Int): String {
		return keyedIn(_imports, _file, _typeSyntax, typeSource, unkeyedAt(at, typeSource));
	}

	/**
	 * The type parameters in scope at the offset `at` of the file (`TypeParamTable.inScopeAt`), asked only when `written`
	 * mentions a name some declaration of the file declares as one.
	 */
	private function unkeyedAt(at: Int, written: String): Array<String> {
		final tree: Null<QueryNode> = _tree;
		if (tree == null || !CallGraphNames.mentionsTypeName(written, _paramNames, _typeSyntax)) return [];
		return TypeParamTable.inScopeAt(tree, at, _typeParams, _functionKinds);
	}

	/**
	 * Type every local of `tree` (a node of `localDeclKinds`) written with no annotation by its initializer, the type the
	 * language gives it: one a `newExprKind` node initialises is the type it makes; one a `callKind` node initialises holds
	 * what the call returns, which the graph reads where the call resolves (`callInitializers`).
	 */
	public function typeLocals(tree: QueryNode, localDeclKinds: Array<String>, newExprKind: Null<String>, callKind: String): Void {
		final at: Null<Span> = tree.span;
		final init: Null<QueryNode> = tree.children.length == 0 ? null : tree.children[tree.children.length - 1];
		if (at != null && init != null && localDeclKinds.contains(tree.kind) && !typeSources.exists(at.from)) {
			final made: Null<String> = init.kind == newExprKind ? init.name : null;
			if (made != null) {
				typeSources[at.from] = keyed(made, at.from);
				declaredTypes[at.from] = _imports.typeOf(_file, made);
			} else if (init.kind == callKind) {
				callInitializers[at.from] = init;
			}
		}
		for (c in tree.children) typeLocals(c, localDeclKinds, newExprKind, callKind);
	}

	/**
	 * What `read` makes of the call that initialises the local bound at `bound`, a local written with no type
	 * (`callInitializers`) — the type it holds; null for any other local, and for one whose initializer is being read already.
	 */
	public function throughInitializer(bound: Int, read: QueryNode -> Null<String>): Null<String> {
		final init: Null<QueryNode> = _reading.contains(bound) ? null : callInitializers[bound];
		if (init == null) return null;
		_reading.push(bound);
		final held: Null<String> = read(init);
		_reading.pop();
		return held;
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

	/**
	 * `typeSource`, written in `file`, with every type it names — the outer one, each argument, parameter, result and
	 * field type — spelled as the graph keys it there (`CallGraphImports.typeOf`): a name is read through the imports of
	 * the file that WROTE it, so the type a declaration names stays that type wherever its value is read. A name among
	 * `unkeyed` — a type parameter in scope where it is written, which shadows every import — stays as written: it is
	 * substituted by the type argument given where the value is read, keyed there.
	 */
	public static function keyedIn(
		imports: CallGraphImports, file: String, typeSyntax: TypeSyntaxReader, typeSource: String, ?unkeyed: Array<String>
	): String {
		final t: Null<TypeSyntax> = typeSyntax(typeSource);
		if (t == null) return typeSource;
		final out: StringBuf = new StringBuf();
		var at: Int = 0;
		for (d in t.descendants()) {
			final from: Int = d.span.from;
			switch d.shape {
				case Nominal(path, _) if (from >= at && typeSource.substr(from, path.length) == path && !(unkeyed ?? []).contains(path)):
					final key: String = imports.typeOf(file, path);
					if (key != path) {
						out.add(typeSource.substring(at, from));
						out.add(key);
						at = from + path.length;
					}
				case _:
			}
		}
		out.add(typeSource.substring(at));
		return out.toString();
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

	/**
	 * `written`, a type the declarations in `files` write, read through the imports of the file that wrote it (`keyingsIn`):
	 * null when two of them key it apart, a reader that needs ONE type then has none — and `written` as it stands when no
	 * file is known.
	 */
	public static function keyedInFiles(
		imports: CallGraphImports, typeSyntax: TypeSyntaxReader, files: Array<String>, written: Null<String>, ?unkeyed: Array<String>
	): Null<String> {
		final keyed: Array<String> = keyingsIn(imports, typeSyntax, files, written, unkeyed);
		return keyed.length == 1 ? keyed[0] : null;
	}

	/**
	 * Every type `written`, a type the declarations in `files` write, may be, each once: read through the imports of each
	 * file that wrote it (`keyedIn`), the names among `unkeyed` (the declaring type's or member's type parameters) as
	 * written — two declarations keying it apart (one per build) give both; `written` as it stands when no file is known,
	 * none when it is null.
	 */
	public static function keyingsIn(
		imports: CallGraphImports, typeSyntax: TypeSyntaxReader, files: Array<String>, written: Null<String>, ?unkeyed: Array<String>
	): Array<String> {
		if (written == null) return [];
		final source: String = written;
		final keyed: Array<String> = [];
		for (f in files) {
			final key: String = keyedIn(imports, f, typeSyntax, source, unkeyed);
			if (!keyed.contains(key)) keyed.push(key);
		}
		return keyed.length == 0 ? [source] : keyed;
	}

	/**
	 * The types `other` names where `chosen` names another, two keyings of one written type (`keyingsIn`), each as a pair
	 * of the keys at the same position; none when the two do not line up.
	 */
	public static function keyedApart(typeSyntax: TypeSyntaxReader, chosen: String, other: String): Array<{ from: String, to: String }> {
		final a: Array<TypeSyntax> = typeSyntax(chosen)?.descendants() ?? [];
		final b: Array<TypeSyntax> = typeSyntax(other)?.descendants() ?? [];
		final out: Array<{ from: String, to: String }> = [];
		if (a.length != b.length) return out;
		for (i in 0...a.length) switch [a[i].shape, b[i].shape] {
			case [Nominal(from, _), Nominal(to, _)] if (from != to):
				out.push({ from: from, to: to });
			case _:
		}
		return out;
	}

	/**
	 * The written types of the parameters of the function `id` of `g`, in order (`null` for one written without a type),
	 * read off its declarations — the ones every declaration the node folds (`declarationsOf`) writes alike; for an external
	 * target only the first, from the index — each read through the imports of the file that wrote it (`keyedIn`). Null
	 * when a declaration cannot be read, or two of them write the parameters differently: a call of the node may then run
	 * either.
	 */
	public static function paramTypesOf(g: CallGraph, id: String): Null<Array<Null<String>>> {
		final cached: Null<Array<Null<String>>> = g._facts.paramTypes[id];
		if (cached != null) return cached;
		final n: Null<FnNode> = g.nodes[id];
		if (n == null) return null;
		final imports: CallGraphImports = g.types.imports;
		final typeSyntax: TypeSyntaxReader = g._plugin.typeSyntax;
		final declared: Array<FnDeclaration> = g.declarationsOf(id);
		if (declared.length == 0) {
			final type: Null<String> = n.typeName;
			final name: Null<String> = n.name;
			if (type == null || name == null) return null;
			final owner: String = g.types.declaringTypeOf(type, name) ?? type;
			final files: Array<String> = imports.memberFilesOf(owner, name);
			final member: Null<MemberInfo> = g.types.memberOnChain(type, name);
			final unkeyed: Array<String> = g.types.generics.typeParamsOf(owner).concat(member?.typeParamNames ?? []);
			return [keyedInFiles(imports, typeSyntax, files, member?.firstParamTypeSource, unkeyed)];
		}
		var out: Null<Array<Null<String>>> = null;
		var rest: Bool = false;
		final unkeyed: Array<String> = g.types.generics.typeParamsOf(n.typeName ?? '').concat(g._facts.typeParams[id] ?? []);
		for (d in declared) {
			final entry: Null<{ tree: QueryNode, source: String }> = g._entries[CallGraphNames.normalizePath(d.file)];
			final read: Null<{ params: Array<Null<String>>, rest: Bool }> = entry == null
				? null
				: CallGraphNames.declaredParams(entry.tree, entry.source, d.span.from, g._shape, g._provider);
			if (read == null) return null;
			final written: Array<Null<String>> = [
				for (p in read.params) p == null ? null : keyedIn(imports, d.file, typeSyntax, p, unkeyed)
			];
			final held: Null<Array<Null<String>>> = out;
			if (held == null) {
				out = written;
				rest = read.rest;
			} else if (
				read.rest != rest || written.length != held.length || [for (i in 0...held.length) held[i] == written[i]].contains(false)
			) {
				return null;
			}
		}
		final params: Null<Array<Null<String>>> = out;
		if (params == null) return null;
		if (rest) g._facts.restParams[id] = true;
		g._facts.paramTypes[id] = params;
		return params;
	}

}
