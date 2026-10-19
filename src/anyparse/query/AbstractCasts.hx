package anyparse.query;

import anyparse.query.GrammarPlugin.CoreValueTypes;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SymbolIndex.CastClauses;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.TypeSyntax.TypeSyntaxReader;

using Lambda;
using StringTools;

/**
 * The cast graph of the abstracts the index holds (`docs/typing-service.md`, step T4): for each abstract declaration, the
 * types its header's `from` and `to` clauses write, one record per `#if` branch declaring it, and the `@:from` / `@:to`
 * members that convert a value implicitly — each resolved once, where the declaration writes it, into a `TypeEnd`. The
 * graph is what `Unification` walks for a pair an abstract takes part in (`tUnification.ml`: `unify_from` / `unify_to`
 * over the clauses) and for an argument's implicit cast (`abstractCast.ml`, `do_check_cast`: the members, then the first
 * `from` clause unequal to the abstract).
 *
 * A positive whitelist: a graph exists only for an abstract with no type parameter, whose header the index reads in
 * every branch (`TypeDeclInfo.castClauses`), that the compiler does not unify by hand (`RefShape.handUnifiedAbstractPaths`)
 * and whose casts are not picked by type arguments (`@:multiType`). Every other declaration answers null — not modelled.
 */
@:nullSafety(Strict)
final class AbstractCasts {

	/** The name -> declaration layer each written clause and member type is resolved through. */
	private final _refs: TypeRefIndex;

	/** The alias targets the ends of the graph follow. */
	private final _ancestors: AncestorTable;

	/** The owning service's remembered answers. */
	private final _cache: QueryCache;

	/** `GrammarPlugin.typeSyntax` — how a written type's head and arguments are read. */
	private final _typeSyntax: TypeSyntaxReader;

	/** The grammar's abstract declaration kinds (`RefShape.underlyingThisTypeKinds`). */
	private final _abstractKinds: Array<String>;

	/** The language's core value types (`RefShape.coreValueTypes`); null when the grammar declares none. */
	private final _core: Null<CoreValueTypes>;

	/** The abstracts the compiler unifies by hand (`RefShape.handUnifiedAbstractPaths`). */
	private final _handUnified: Array<String>;

	/** The member annotation of an inward conversion (Haxe `@:from`), or null. */
	private final _fromMeta: Null<String>;

	/** The member annotation of an outward conversion (Haxe `@:to`), or null. */
	private final _toMeta: Null<String>;

	/** The dynamic type's name (Haxe `Dynamic`), or null. */
	private final _dynamic: Null<String>;

	/** The language's nullable wrapper (Haxe `Null`), transparent to a unification. */
	private final _nullable: Null<String>;

	/** Built once by the owning `TypingService`. */
	public function new(
		refs: TypeRefIndex, ancestors: AncestorTable, cache: QueryCache, typeSyntax: TypeSyntaxReader, shape: RefShape
	) {
		_refs = refs;
		_ancestors = ancestors;
		_cache = cache;
		_typeSyntax = typeSyntax;
		_abstractKinds = shape.underlyingThisTypeKinds ?? [];
		_core = shape.coreValueTypes;
		_handUnified = shape.handUnifiedAbstractPaths ?? [];
		_fromMeta = shape.execution?.implicitConversionMetaName;
		_toMeta = shape.execution?.implicitOutwardConversionMetaName;
		_dynamic = shape.rawDynamicTypeName;
		_nullable = shape.optionalValueTypeName;
	}

	/**
	 * The cast graph of the declaration `r`: null for a declaration that is no abstract, and for one the graph does not
	 * model (a type parameter, a header one branch of which the index does not read, a hand-unified or a `@:multiType`
	 * abstract).
	 */
	public function graph(r: ResolvedType): Null<CastGraph> {
		return _cache.castGraphs.answer(DeclarationKey.ofType(r), () -> graphOf(r));
	}

	/**
	 * The graph of the core value type `name` the compiler represents as an abstract (`CoreValueTypes.classNames` names the
	 * rest): one branch, transitive (`@:coreType`), casting to what it `widens` to, declaring no member; null for a core
	 * class (`String`) and a name that is no core type.
	 */
	public function coreGraph(name: String): Null<CastGraph> {
		final core: Null<CoreValueTypes> = _core;
		if (core == null || !core.names.contains(name) || core.classNames.contains(name)) return null;
		return {
			branches: [{ from: [], to: [for (w in core.widens[name] ?? []) Core(w)], transitive: true }],
			fromFields: [],
			toFields: [],
			fieldsComplete: true
		};
	}

	/** Whether the end `e` is an abstract: a declaration of an abstract kind, or a core value type that is no class. */
	public function isAbstract(e: TypeEnd): Bool {
		return switch e {
			case Declared(r): _abstractKinds.contains(r.type.kind);
			case Core(name): coreGraph(name) != null;
			case Dyn | Open: false;
		};
	}

	/**
	 * The end the declaration `r` stands for: a core value type for a top-level declaration of a core type's name (the
	 * standard library's `Int`, `String`, …), the dynamic type for its `Dynamic`, else `r` itself through its plain
	 * `typedef` alias hops; `Open` for an alias that does not resolve, re-enters itself or names a structure.
	 */
	public function declEnd(r: ResolvedType): TypeEnd {
		final at: Null<ResolvedType> = followed(r);
		if (at == null) return Open;
		final name: String = at.type.name;
		if (at.file.pkg != '') return Declared(at);
		if (name == _dynamic) return Dyn;
		return _core != null && _core.names.contains(name) ? Core(name) : Declared(at);
	}

	/**
	 * The end the type `text`, written in `host` at `at`, stands for: its `Null<…>` peeled (`Null<T>` unifies as `T` both
	 * ways), the dynamic type written bare, the declaration it resolves to there (`declEnd`), a core value type no
	 * declaration bears the name of; `Open` for a type parameter of `host` or one of `params`, a type written with
	 * arguments, any other shape and a name that resolves to nothing.
	 */
	public function writtenEnd(text: String, host: ResolvedType, at: Int, params: Array<String>): TypeEnd {
		final trimmed: String = text.trim();
		return switch _typeSyntax(trimmed)?.shape {
			case Nominal(path, args) if (path == _nullable && args.length == 1):
				writtenEnd(NominalTypes.typeArgumentSourcesOf(trimmed, _typeSyntax)?.join(',') ?? '', host, at, params);
			case Nominal(path, args) if (args.length == 0 && !params.contains(path) && !host.type.typeParamNames.contains(path)):
				final r: Null<ResolvedType> = _refs.resolveTypeRef(path, host.file, at);
				r == null ? unresolvedEnd(path) : declEnd(r);
			case _: Open;
		};
	}

	/** The end a written name no declaration resolves stands for: the dynamic type, a core value type, else `Open`. */
	private function unresolvedEnd(path: String): TypeEnd {
		if (path == _dynamic) return Dyn;
		return _core != null && _core.names.contains(path) ? Core(path) : Open;
	}

	/** Whether `a` and `b` are one end: one declaration, one core type, both dynamic. */
	public static function same(a: TypeEnd, b: TypeEnd): Bool {
		return switch [a, b] {
			case [Declared(x), Declared(y)]: AncestorTable.same(x, y);
			case [Core(x), Core(y)]: x == y;
			case [Dyn, Dyn]: true;
			case _: false;
		};
	}

	/** `graph`'s computation. */
	private function graphOf(r: ResolvedType): Null<CastGraph> {
		final clauses: Null<Array<CastClauses>> = r.type.castClauses;
		if (!_abstractKinds.contains(r.type.kind) || clauses == null || r.type.typeParamArity > 0) return null;
		if (clauses.exists(c -> c.typeSelected) || _handUnified.contains(pathOf(r))) return null;
		final at: Int = r.type.span.from;
		final branches: Array<CastBranch> = [
			for (c in clauses)
				{
					from: [for (t in c.from) writtenEnd(t, r, at, [])],
					to: [for (t in c.to) writtenEnd(t, r, at, [])],
					transitive: c.transitive
				}
		];
		// a member of a type two branches declare may be another branch's; one under `#if` another build's
		final single: Bool = clauses.length == 1;
		final certain: MemberInfo -> Bool = m -> single && !m.guarded;
		final fromFields: Array<CastField> = [];
		final toFields: Array<CastField> = [];
		for (m in r.type.members) if (MemberKinds.FN_DECL_KINDS.contains(m.kind)) {
			if (_fromMeta != null && m.metaNames.contains(_fromMeta) && m.isStatic)
				fromFields.push({ end: inwardEnd(m, r), certain: certain(m) });
			if (_toMeta != null && m.metaNames.contains(_toMeta) && !m.isStatic)
				toFields.push({ end: outwardEnd(m, r), certain: certain(m) });
		}
		return {
			branches: branches,
			fromFields: fromFields,
			toFields: toFields,
			fieldsComplete: !r.type.hasBuild && !r.type.hasAutoBuild
		};
	}

	/**
	 * The type the `@:from` member `m` of `r` takes (its first parameter); `Open` when it takes none or another one too,
	 * or does not return `r` — what it converts into is then not `r` alone.
	 */
	private function inwardEnd(m: MemberInfo, r: ResolvedType): TypeEnd {
		final param: Null<String> = m.paramTypeSources.length == 1 ? m.paramTypeSources[0] : null;
		final returned: Null<String> = m.returnSource;
		if (param == null || returned == null) return Open;
		return same(writtenEnd(returned, r, m.declFrom, m.typeParamNames), Declared(r))
			? writtenEnd(param, r, m.declFrom, m.typeParamNames)
			: Open;
	}

	/** The type the `@:to` member `m` of `r` returns; `Open` for one taking a parameter or returning an inferred type. */
	private function outwardEnd(m: MemberInfo, r: ResolvedType): TypeEnd {
		final returned: Null<String> = m.returnSource;
		return returned == null || m.paramTypeSources.length > 0 ? Open : writtenEnd(returned, r, m.declFrom, m.typeParamNames);
	}

	/**
	 * `r`, or the declaration its plain `typedef` alias hops land on, each hop a declaration with no type parameter; null
	 * for a hop that does not resolve, a structure, and an alias that re-enters itself.
	 */
	private function followed(r: ResolvedType): Null<ResolvedType> {
		var at: ResolvedType = r;
		final seen: Array<String> = [];
		while (at.type.kind == SymbolIndex.TYPEDEF_DECL_KIND) {
			if (at.type.isAnonStruct || at.type.typeParamArity > 0 || !_refs.markSeen(at, seen)) return null;
			final next: Null<ResolvedType> = _ancestors.aliasTarget(at);
			if (next == null) return null;
			at = next;
		}
		return at;
	}

	/** The dotted path of the declaration `r`: its package, then its name. */
	private static inline function pathOf(r: ResolvedType): String {
		return r.file.pkg == '' ? r.type.name : '${r.file.pkg}.${r.type.name}';
	}

}

/** One end of a unification question or of a cast edge, as the cast graph reads a type (`AbstractCasts`). */
enum TypeEnd {

	/** A declaration the index resolves — a class, an interface, an enum, an abstract — its plain aliases followed. */
	Declared(r: ResolvedType);

	/** A core value type (`RefShape.coreValueTypes`) by name, whether or not the index holds its declaration. */
	Core(name: String);

	/** The dynamic type written with no argument: every value unifies with it. */
	Dyn;

	/** A type the graph does not model: a type parameter, a type with arguments, a structure, a function, an unresolved name. */
	Open;

}

/** One `#if` branch of an abstract's header (`CastClauses`), its clauses resolved. */
typedef CastBranch = {

	/** The types its `from` clauses write, in source order. */
	final from: Array<TypeEnd>;

	/** The types its `to` clauses write, in source order. */
	final to: Array<TypeEnd>;

	/** Whether a cast through one of them allows a further abstract cast (`@:coreType`, `@:transitive`). */
	final transitive: Bool;

}

/** A `@:from` or `@:to` member of an abstract: the type it takes or returns, and whether it is in every build. */
typedef CastField = {

	/** A `@:from` member's parameter type, a `@:to` member's return type. */
	final end: TypeEnd;

	/** Whether every build declaring the abstract declares the member — one declaration, the member not under `#if`. */
	final certain: Bool;

}

/** The cast graph of one abstract (`AbstractCasts.graph`). */
typedef CastGraph = {

	/** One record per `#if` branch declaring the abstract. */
	final branches: Array<CastBranch>;

	/** The `@:from` members, the union of every branch's. */
	final fromFields: Array<CastField>;

	/** The `@:to` members, the union of every branch's. */
	final toFields: Array<CastField>;

	/** False when a build macro may give the abstract a conversion no declaration shows. */
	final fieldsComplete: Bool;

}
