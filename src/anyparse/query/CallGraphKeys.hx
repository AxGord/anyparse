package anyparse.query;

import anyparse.query.CallGraph.FnDeclaration;
import anyparse.query.CallGraph.FnNode;
import anyparse.query.CallGraphImports.WrittenIn;
import anyparse.query.CallGraphNames.DeclaredParams;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.query.ValueNameBinding.ImportedStatics;

using Lambda;
using StringTools;

/**
 * The types one file writes, spelled as a `CallGraph` keys them (`CallGraphImports.typeOf`),
 * each written by the path of the type it binds to (`writtenAs`): a name an import or an
 * alias of the file binds, or a dotted path, is the type it names — a library type never merges into a project type of its simple
 * name. The declared types a `TypeInfoProvider` reads, re-keyed; an unannotated local holds its initializer's type, which the
 * shared walk reads (`NominalTypes.localInitializer`). A type another file declares is keyed through THAT file's imports (`keyedIn`,
 * `keyedInFiles`, `paramTypesOf`): a declaration names what its own file binds the name to, wherever the value is read.
 */
@:nullSafety(Strict)
@:access(anyparse.query.CallGraph)
final class CallGraphKeys {

	/** Binding offset -> the declaration's written type, the type it names (`Null<…>` peeled) spelled as the graph keys it. */
	public final typeSources: Map<Int, String> = [];

	/** Every type-parameter name a declaration of the file declares. */
	private final _paramNames: Array<String> = [];

	private final _imports: CallGraphImports;
	private final _file: String;
	private final _typeSyntax: TypeSyntaxReader;

	/** The file's tree, for the type parameters in scope at a declaration (`unkeyedAt`); null when not handed. */
	private final _tree: Null<QueryNode>;

	/** The grammar's function kinds, whose type parameters are in scope inside them. */
	private final _functionKinds: Array<String>;

	/** Each declaration of the file declaring type parameters (by its key, `TypeInfoProvider.typeParamNames`) -> their names. */
	private final _typeParams: Map<Int, Array<String>>;

	/**
	 * The keys of the declarations `provider` reads in `source`, the text of `file` (none without a provider), `tree` its
	 * tree: a name a type parameter in scope at the declaration (`CallGraphGenerics.inScopeAt`, the functions among
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
		final writtenSources: Map<Int, String> = provider == null ? [] : provider.declaredTypeSources(source);
		for (at => written in writtenSources) typeSources[at] = keyed(written, at);
	}

	/**
	 * `typeSource`, written in the file at the offset `at`, with every type it names spelled as the graph keys it (`keyedIn`),
	 * a type parameter in scope there (`unkeyedAt`) left as written.
	 */
	public function keyed(typeSource: String, at: Int): String {
		return keyedIn(_imports, _file, _typeSyntax, typeSource, unkeyedAt(at, typeSource));
	}

	/** The dotted or simple path of the type `typeSource` names, `Null<…>` peeled unless `peelNull` is false; null for any other type. */
	public function outerPathOf(typeSource: Null<String>, peelNull: Bool = true): Null<String> {
		return typeSource == null ? null : NominalTypes.outerPathOf(typeSource, peelNull ? ['Null'] : [], _typeSyntax);
	}

	/**
	 * The type parameters in scope at the offset `at` of the file (`CallGraphGenerics.inScopeAt`), asked only when `written`
	 * mentions a name some declaration of the file declares as one.
	 */
	private function unkeyedAt(at: Int, written: String): Array<String> {
		final tree: Null<QueryNode> = _tree;
		return tree == null || !CallGraphNames.mentionsTypeName(written, _paramNames, _typeSyntax)
			? []
			: CallGraphGenerics.inScopeAt(tree, at, _typeParams, _functionKinds);
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
					final spelled: String = imports.writtenAs(file, path);
					if (spelled != path) {
						out.add(typeSource.substring(at, from));
						out.add(spelled);
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
	 * The first of `keyingsIn` — null for none — the types each other keying names in its place joining `apart` once each
	 * (`keyedApart`): a reader typing a receiver by it dispatches on those as well (`apartFrom`).
	 */
	public static function firstKeying(
		imports: CallGraphImports, typeSyntax: TypeSyntaxReader, files: Array<String>, written: Null<String>, unkeyed: Array<String>,
		apart: Array<{ from: String, to: String }>
	): Null<String> {
		return firstOf(typeSyntax, keyingsIn(imports, typeSyntax, files, written, unkeyed), apart);
	}

	/**
	 * `firstKeying` for declarations that write a type differently — one per branch of a conditional region — each read
	 * where it is written (`keyedIn`), `unkeyed` as written: the first, the others dispatched on as well (`apartFrom`). Null
	 * when one of them writes no type, or two do not line up (`keyedApart`): the type is then unknown, never one of them alone.
	 */
	public static function firstKeyingEach(
		imports: CallGraphImports, typeSyntax: TypeSyntaxReader, declared: Array<WrittenIn>, unkeyed: Array<String>,
		apart: Array<{ from: String, to: String }>
	): Null<String> {
		final keyed: Array<String> = [];
		for (d in declared) {
			final written: Null<String> = d.written;
			if (written == null) return null;
			final key: String = keyedIn(imports, d.file, typeSyntax, written, unkeyed);
			if (!keyed.contains(key)) keyed.push(key);
		}
		return firstOf(typeSyntax, keyed, apart);
	}

	/** The types `apart` (`firstKeying`) names in place of the type keyed `typeName`, as the graph keys them. */
	public static function apartFrom(
		imports: CallGraphImports, apart: Array<{ from: String, to: String }>, typeName: String
	): Array<String> {
		return [
			for (pair in apart) if (imports.pathKey(pair.from) == typeName) imports.pathKey(pair.to)
		];
	}

	/**
	 * The types `other` names where `chosen` names another, two keyings of one type (`keyingsIn`, `firstKeyingEach`), each as
	 * a pair of the keys at the same position; null when the two do not line up — a different shape somewhere, or another
	 * number of type arguments.
	 */
	public static function keyedApart(
		typeSyntax: TypeSyntaxReader, chosen: String, other: String
	): Null<Array<{ from: String, to: String }>> {
		final a: Array<TypeSyntax> = typeSyntax(chosen)?.descendants() ?? [];
		final b: Array<TypeSyntax> = typeSyntax(other)?.descendants() ?? [];
		if (a.length != b.length) return null;
		final out: Array<{ from: String, to: String }> = [];
		for (i in 0...a.length) switch [a[i].shape, b[i].shape] {
			case [Nominal(from, x), Nominal(to, y)] if (x.length == y.length):
				if (from != to) out.push({ from: from, to: to });
			case [Function(_, _, _), Function(_, _, _)], [Structure(_), Structure(_)], [Intersection(_), Intersection(_)],
				[Conditional(_), Conditional(_)], [Other, Other]:
			case _:
				return null;
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
		// another signature a call may select takes other parameters (`@:overload`)
		return g._facts.overloadedParams.exists(id) ? null : declaredParamTypes(g, id);
	}

	/**
	 * Whether the argument at `index` of a call passing `count` arguments to `id` of `g` (`paramTypesOf` read) may bind a later
	 * parameter than the one at its position: a parameter the language may skip sits at or before it while the call passes
	 * fewer arguments than `id` declares, or a rest parameter takes what is left. Review R5 F3: `run(?a:Int, f, ?g)` called
	 * `run(l -> {}, l2 -> …)` binds `f` and `g`.
	 */
	public static function mayShift(g: CallGraph, id: String, index: Int, count: Int): Bool {
		final skippable: Null<{ from: Int, count: Int }> = g._facts.skippable[id];
		return skippable != null && skippable.from <= index && (count < skippable.count || g._facts.restParams.exists(id));
	}

	/**
	 * Whether the argument at `index` of a call passing `count` arguments to `id` of `g` binds the parameter at its position
	 * for sure: `id`'s declarations the run holds read their parameters alike (`paramTypesOf`), none it may skip shifts the
	 * argument (`mayShift`), and the position is a parameter of its own, before any rest parameter. A function the run
	 * declares nowhere — the index reads only a library member's first parameter — proves no position.
	 */
	public static function bindsItsPosition(g: CallGraph, id: String, index: Int, count: Int): Bool {
		final params: Null<Array<Null<String>>> = g.declarationsOf(id).length == 0 ? null : paramTypesOf(g, id);
		if (params == null) return false;
		final own: Int = g._facts.restParams.exists(id) ? params.length - 1 : params.length;
		return index < own && !mayShift(g, id, index, count);
	}

	/**
	 * The node of `g` of the static `member` of `owner` an import binds: its declaration, or a placeholder for one the graph
	 * has not loaded or one a type whose chain the index does not hold may declare; null for a static that is no function.
	 */
	public static function staticTarget(g: CallGraph, owner: String, member: String): Null<String> {
		final types: CallGraphTypes = g.types;
		return g.memberOnChain(owner, member) ?? (
			types.functionOnChain(owner, member) || !types.chainFullyIndexed(owner)
				? g.externalNode(types.declaringTypeOf(owner, member) ?? owner, member)
				: null
		);
	}

	/**
	 * The one static of `imported` — what the module and the imports of the file supply
	 * under the unbound `name` (`ValueNameBinding.importedStatics`) —, read where nothing
	 * nearer binds it: no member of `currentType`'s chain may (`memberMayBind`). Null when the module itself declares the name
	 * where it is read, or the imports bind none, more than one, or may bind one the index cannot list.
	 */
	public static function importedStatic(
		g: CallGraph, imported: ImportedStatics, name: String, currentType: Null<String>
	): Null<{ owner: String, member: String }> {
		return if (memberMayBind(g, currentType, name))
			null
		else if (imported.unknown || imported.statics.length != 1)
			null
		else
			{ owner: imported.statics[0].owner, member: imported.statics[0].member };
	}

	/**
	 * Whether a member of `currentType`'s chain in `g` may be what the bare name `name` read inside it means: one the chain
	 * declares, but a supertype's static (`staticOfSupertype`), or any one when the index does not hold the chain whole. Such
	 * a member comes before a module-level field and an imported static of the name (4.3.7, `hx/p3`, `hx/p4`). False in
	 * module-level code, which sees no type's members.
	 */
	public static function memberMayBind(g: CallGraph, currentType: Null<String>, name: String): Bool {
		final types: CallGraphTypes = g.types;
		return currentType != null
			&& (!types.chainFullyIndexed(currentType) || types.declaringTypeOf(currentType, name) != null
				&& !staticOfSupertype(g, currentType, name));
	}

	/**
	 * Whether the nearest declaration of `member` on `typeName`'s chain in `g` is a STATIC of a supertype, which a bare name inside
	 * `typeName` does not see: the language puts no inherited static in unqualified scope (checked on 4.3.7: `Unknown
	 * identifier`; an `import A.*` static of the name wins there). Review R5 F7.
	 */
	public static function staticOfSupertype(g: CallGraph, typeName: String, member: String): Bool {
		// a function the graph holds is the nearest it keys (a module function under the module pseudo-type), a field the index's
		final found: Null<String> = g.memberOnChain(typeName, member);
		final owner: Null<String> = found == null ? g.types.declaringTypeOf(typeName, member) : g.nodes[found]?.typeName;
		return owner != null && owner != typeName && g.types.isStatic(owner, member);
	}

	/**
	 * The node of `g` the type `typeName` itself declares `member` as, null for none: a module function keyed under the module
	 * pseudo-type, whose name the module's main class shares — a member that class inherits is none (review R5 F7).
	 */
	public static function declaredOn(g: CallGraph, typeName: String, member: String): Null<String> {
		final found: Null<String> = g.memberOnChain(typeName, member);
		return found == null || g.nodes[found]?.typeName != typeName ? null : found;
	}

	/**
	 * What the arguments of `call` bind each type parameter the function `target` of `g` declares itself to, in order, as the
	 * language infers it: the type `argType` gives every argument passed to a parameter written as that bare type parameter
	 * — a rest parameter taking every argument from its position on — when they all agree; `CallGraph.UNKNOWN_TYPE` for one
	 * no argument binds, arguments of different types bind, or an argument that may bind a later parameter (`mayShift`) may bind.
	 */
	public static function argumentBindings(
		g: CallGraph, target: String, call: QueryNode, argType: QueryNode -> Null<String>
	): Array<String> {
		final params: Array<Null<String>> = paramTypesOf(g, target) ?? [];
		final last: Int = params.length - 1;
		final rest: Bool = g._facts.restParams.exists(target);
		final count: Int = call.children.length - 1;
		// From the first argument that may bind a later parameter than its position's on (`mayShift`), no parameter is proven
		// bound: a type parameter one of those parameters is written as binds whatever the language picks (review L3 G3).
		var shiftsFrom: Int = count;
		for (i in 0...count) if (mayShift(g, target, i, count)) {
			shiftsFrom = i;
			break;
		}
		return [
			for (p in g._facts.typeParams[target] ?? []) {
				final passed: Array<Null<String>> = [
					for (j in 1...call.children.length) {
						final at: Int = rest && j - 1 > last ? last : j - 1;
						if (at <= last && (params[at] ?? '').trim() == p) argType(call.children[j]);
					}
				];
				final shifted: Bool = [for (i in shiftsFrom ... params.length) params[i]].exists(t -> (t ?? '').trim() == p);
				!shifted && passed.length > 0 && !passed.exists(a -> a != passed[0])
					? passed[0] ?? CallGraph.UNKNOWN_TYPE
					: CallGraph.UNKNOWN_TYPE;
			}
		];
	}

	/**
	 * The return type each declaration the function `id` of `g` folds writes (null for none), with its file — what a call of
	 * it may return when the declarations write it differently (`firstKeyingEach`); null for a declaration the graph cannot
	 * read too.
	 */
	public static function returnsWritten(g: CallGraph, id: String): Array<WrittenIn> {
		final kinds: Array<String> = (g._shape.functionKinds ?? []).concat(g._shape.inlineFunctionKinds ?? []);
		return [
			for (d in g.declarationsOf(id)) {
				final entry: Null<{ tree: QueryNode, source: String }> = g._entries[CallGraphNames.normalizePath(d.file)];
				final fn: Null<QueryNode> = entry == null ? null : CallGraphNames.functionNodeAt(entry.tree, d.span.from, kinds);
				final read: Null<String> = entry == null || fn == null
					? null
					: CallGraphNames.returnSourceOf(fn, entry.source, g._shape.typeAnnotationKinds ?? []);
				{ file: d.file, written: read };
			}
		];
	}

	/** `paramTypesOf` for a function offering no other signature: what its declarations write. */
	private static function declaredParamTypes(g: CallGraph, id: String): Null<Array<Null<String>>> {
		final cached: Null<Array<Null<String>>> = g._facts.paramTypes[id];
		if (cached != null) return cached;
		final n: Null<FnNode> = g.nodes[id];
		if (n == null) return null;
		final imports: CallGraphImports = g.types.imports;
		final typeSyntax: TypeSyntaxReader = g._plugin.typeSyntax;
		final declared: Array<FnDeclaration> = g.declarationsOf(id);
		if (declared.length == 0) return externalParamTypes(g, n);
		var out: Null<Array<Null<String>>> = null;
		var rest: Bool = false;
		var skippableFrom: Int = -1;
		final unkeyed: Array<String> = g.types.generics.typeParamsOf(n.typeName ?? '').concat(g._facts.typeParams[id] ?? []);
		for (d in declared) {
			final entry: Null<{ tree: QueryNode, source: String }> = g._entries[CallGraphNames.normalizePath(d.file)];
			final read: Null<DeclaredParams> = entry == null
				? null
				: CallGraphNames.declaredParams(entry.tree, entry.source, d.span.from, g._shape, g._provider);
			if (read == null) return null;
			final written: Array<Null<String>> = [
				for (p in read.params) p == null ? null : keyedIn(imports, d.file, typeSyntax, p, unkeyed)
			];
			final held: Null<Array<Null<String>>> = out;
			skippableFrom = skippableFrom < 0 ? read.skippableFrom : Std.int(Math.min(skippableFrom, read.skippableFrom));
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
		if (skippableFrom < params.length) g._facts.skippable[id] = { from: skippableFrom, count: params.length };
		g._facts.paramTypes[id] = params;
		return params;
	}

	/**
	 * `paramTypesOf` for the node `n` of `g` no declaration of the run folds (an external target): its first parameter's
	 * written type off the index, read where its member is declared, the owner's and the member's type parameters as written;
	 * null for a node without a type or a name.
	 */
	private static function externalParamTypes(g: CallGraph, n: FnNode): Null<Array<Null<String>>> {
		final type: Null<String> = n.typeName;
		final name: Null<String> = n.name;
		if (type == null || name == null) return null;
		final owner: String = g.types.declaringTypeOf(type, name) ?? type;
		final member: Null<MemberInfo> = g.types.memberOnChain(type, name);
		if (member?.hasOverloadMeta == true) return null;
		final unkeyed: Array<String> = g.types.generics.typeParamsOf(owner).concat(member?.typeParamNames ?? []);
		// which of its parameters a call may skip the index does not say: any of them
		final declared: Int = member?.paramTypeSources.length ?? 0;
		if (declared > 0) g._facts.skippable[n.id] = { from: 0, count: declared };
		return [
			keyedInFiles(
				g.types.imports, g._plugin.typeSyntax, g.types.imports.memberFilesOf(owner, name), member?.firstParamTypeSource, unkeyed
			)
		];
	}

	/**
	 * The first of `keyed` — the keyings of one type — the types each other one names in its place joining `apart` once each;
	 * null for none, and when one of them does not line up with the first (`keyedApart`).
	 */
	private static function firstOf(
		typeSyntax: TypeSyntaxReader, keyed: Array<String>, apart: Array<{ from: String, to: String }>
	): Null<String> {
		if (keyed.length == 0) return null;
		final pairs: Array<{ from: String, to: String }> = [];
		for (other in keyed.slice(1)) {
			final lined: Null<Array<{ from: String, to: String }>> = keyedApart(typeSyntax, keyed[0], other);
			if (lined == null) return null;
			for (pair in lined) pairs.push(pair);
		}
		for (pair in pairs) if (!apart.exists(p -> p.from == pair.from && p.to == pair.to)) apart.push(pair);
		return keyed[0];
	}

}
