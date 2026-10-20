package anyparse.query;

import anyparse.query.GrammarPlugin.CoreValueTypes;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SymbolIndex.CastClauses;
import anyparse.query.SymbolIndex.DeclBranch;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.SymbolIndex.TypeDeclInfo;
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
 * every branch some build of the run compiles (`clausesOf`, step T6), that the compiler does not unify by hand
 * (`RefShape.handUnifiedAbstractPaths`) and whose casts are not picked by type arguments (`@:multiType`). Every other
 * declaration answers null — not modelled.
 */
@:nullSafety(Strict)
final class AbstractCasts {

	/** The aliases `appliedAlias` is reading right now, by declaration: one re-entering itself stands for no end. */
	private final _expanding: Array<String> = [];

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

	/** The grammar's field member kinds (`RefShape.fieldDeclKinds`): an enum-abstract value is one. */
	private final _fieldKinds: Array<String>;

	/** Which `#if` branches of a declaration the run's builds compile: the only ones an answer reads. */
	private final _builds: BuildBranches;

	/** Built once by the owning `TypingService`. */
	public function new(
		refs: TypeRefIndex, ancestors: AncestorTable, cache: QueryCache, typeSyntax: TypeSyntaxReader, shape: RefShape,
		builds: BuildBranches
	) {
		_builds = builds;
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
		_fieldKinds = shape.fieldDeclKinds ?? [];
	}

	/**
	 * The cast graph of the declaration `r`: null for a declaration that is no abstract, and for one the graph does not
	 * model (a type parameter, a header one branch of which the index does not read, a hand-unified or a `@:multiType`
	 * abstract).
	 */
	public function graph(r: ResolvedType): Null<CastGraph> {
		return _cache.castGraphs.answer(DeclarationKey.ofType(r), graphOf.bind(r));
	}

	/**
	 * The graph of the core value type `name` the compiler represents as an abstract (`CoreValueTypes.classNames` names the
	 * rest): one branch, transitive (`@:coreType`), casting to what it `widens` to, declaring no member; null for a core
	 * class (`String`) and a name that is no core type.
	 */
	public function coreGraph(name: String): Null<CastGraph> {
		final core: Null<CoreValueTypes> = _core;
		return core == null || !core.names.contains(name) || core.classNames.contains(name) ? null : {
			branches: [{ from: [], to: [for (w in core.widens[name] ?? []) Core(w)], transitive: true }],
			fromFields: [],
			toFields: [],
			fieldsComplete: true
		};
	}

	/** Whether the end `e` is an abstract: a declaration of an abstract kind, or a core value type that is no class. */
	public function isAbstract(e: TypeEnd): Bool {
		return switch e {
			case Declared(r), Applied(r, _): _abstractKinds.contains(r.type.kind);
			case Core(name): coreGraph(name) != null;
			case Dyn, Open, Param(_): false;
		};
	}

	/**
	 * The end the declaration `r` stands for: a core value type for a top-level declaration of a core type's name (the
	 * standard library's `Int`, `String`, …), the dynamic type for its `Dynamic`, else `r` itself through its plain
	 * `typedef` alias hops; `Open` for an alias that does not resolve, re-enters itself or names a structure.
	 */
	public function declEnd(r: ResolvedType): TypeEnd {
		final applied: Null<TypeEnd> = appliedAlias(r);
		if (applied != null) return applied;
		final at: Null<ResolvedType> = followed(r);
		if (at == null) return Open;
		final name: String = at.type.name;
		if (at.file.pkg != '') return Declared(at);
		if (name == _dynamic) return Dyn;
		return _core != null && _core.names.contains(name) ? Core(name) : Declared(at);
	}

	/**
	 * The end the type `text`, written in `host` at `at`, stands for (`endIn`), a type parameter of `host` or one of `params`
	 * standing for none (`Open`).
	 */
	public function writtenEnd(text: String, host: ResolvedType, at: Int, params: Array<String>): TypeEnd {
		return endIn(text, host.file, at, params.concat(host.type.typeParamNames));
	}

	/**
	 * The end the type `text`, written in the file `file` at `at`, stands for: its `Null<…>` peeled (`Null<T>` unifies as `T`
	 * both ways), the dynamic type written bare, the declaration it resolves to there (`declEnd`), a core value type no
	 * declaration bears the name of; `Open` for one of the type parameters `params`, a type written with arguments, any other
	 * shape and a name that resolves to nothing.
	 */
	public function endIn(text: String, file: FileInfo, at: Int, params: Array<String>): TypeEnd {
		final trimmed: String = text.trim();
		return switch _typeSyntax(trimmed)?.shape {
			case Nominal(path, args) if (path == _nullable && args.length == 1):
				endIn(NominalTypes.typeArgumentSourcesOf(trimmed, _typeSyntax)?.join(',') ?? '', file, at, params);
			case Nominal(path, args) if (args.length == 0 && !params.contains(path)):
				final r: Null<ResolvedType> = _refs.resolveTypeRef(path, file, at);
				r == null ? unresolvedEnd(path) : declEnd(r);
			case Nominal(path, args) if (!params.contains(path)):
				final r: Null<ResolvedType> = _refs.resolveTypeRef(path, file, at);
				final written: Array<String> = NominalTypes.typeArgumentSourcesOf(trimmed, _typeSyntax) ?? [];
				r == null ? Open : appliedEnd(r, [for (a in written) endIn(a, file, at, params)]);
			case _: Open;
		};
	}

	/**
	 * `r`, or the declaration its plain `typedef` alias hops land on, each hop a declaration with no type parameter; null
	 * for a hop that does not resolve, a structure, and an alias that re-enters itself.
	 */
	public function followed(r: ResolvedType): Null<ResolvedType> {
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

	/**
	 * The casts the header of each `#if` branch declaring `r` writes (`DeclBranch.clauses`), over the branches some build of
	 * the run compiles (`BuildBranches`), in source order: null when one of them is no abstract, or an abstract whose clauses
	 * the index does not read.
	 */
	public function clausesOf(r: ResolvedType): Null<Array<CastClauses>> {
		final out: Array<CastClauses> = [];
		for (b in _builds.of(r)) {
			final clauses: Null<CastClauses> = b.clauses;
			if (clauses == null) return null;
			out.push(clauses);
		}
		return out;
	}

	/**
	 * The members of each `#if` branch declaring the abstract `r` that some build of the run compiles, in source order
	 * (`DeclBranch.span`): what one build of it declares. Null for a declaration one such branch of which the index does not
	 * read as an abstract (`clausesOf`), and for one with a type parameter.
	 */
	public function branchMembers(r: ResolvedType): Null<Array<Array<MemberInfo>>> {
		final live: Array<DeclBranch> = _builds.of(r);
		return clausesOf(r) == null || r.type.typeParamArity > 0 ? null : [for (b in live) membersOf(r, b)];
	}

	/**
	 * Whether `name`, read off the type name of `r`, is a VALUE of `r` written with no type — an enum-abstract value, of type
	 * `r` (`enum abstract E(Int) { var A = 1; final B = 2; }` reads `E.A : E`, Haxe 4.3.7, the deprecated `@:enum abstract`
	 * alike): every `#if` branch of `r` some build compiles is an abstract (`branchMembers`) declaring a field of that name
	 * with no written type, not static and not under `#if`, which an abstract declares only as an enum value ("Cannot declare
	 * member variable in abstract" otherwise). False for any other member, and for a declaration one such branch of which is
	 * no abstract the index reads (a `typedef` to a type of another build).
	 */
	public function holdsUntypedValue(r: ResolvedType, name: String): Bool {
		final branches: Null<Array<Array<MemberInfo>>> = branchMembers(r);
		return branches != null && branches.foreach(members -> members.exists(m -> m.name == name && isUntypedValue(m)));
	}

	/**
	 * The cast graph of the generic abstract `r` applied to the type arguments `args` (`apply_params`): a clause written as
	 * one of `r`'s type parameters reads as the argument at its position (`from T1` of `EitherType<String, Buffer>` is
	 * `String`), one naming a parameter inside another type as none (`Open`), a member's type naming one likewise. Null
	 * where `r` has no graph and for a count of arguments `r` does not declare; computed each time, a few clauses long.
	 */
	public function appliedGraph(r: ResolvedType, args: Array<TypeEnd>): Null<CastGraph> {
		final params: Array<String> = r.type.typeParamNames;
		final at: Int = r.type.span.from;
		return params.length != args.length || params.length == 0
			? null
			: graphWith(r, t -> {
				final i: Int = params.indexOf(t.trim());
				i >= 0 ? args[i] : writtenEnd(t, r, at, []);
			});
	}

	/** Whether `m` is a field written with no type, not static, not under `#if`: in an abstract, an enum value. */
	private inline function isUntypedValue(m: MemberInfo): Bool {
		return _fieldKinds.contains(m.kind) && !m.isStatic && !m.guarded && m.typeSource == null;
	}

	/** The end a written name no declaration resolves stands for: the dynamic type, a core value type, else `Open`. */
	private function unresolvedEnd(path: String): TypeEnd {
		if (path == _dynamic) return Dyn;
		return _core != null && _core.names.contains(path) ? Core(path) : Open;
	}

	/** `graph`'s computation: a declaration with no type parameter, each clause resolved where it is written. */
	private function graphOf(r: ResolvedType): Null<CastGraph> {
		final at: Int = r.type.span.from;
		return r.type.typeParamArity > 0 ? null : graphWith(r, t -> writtenEnd(t, r, at, []));
	}

	/**
	 * The cast graph of the abstract `r` with each clause read by `clauseEnd`, over the branches some build of the run
	 * compiles (`BuildBranches`): null for a declaration that is no abstract, one such branch of which the index does not
	 * read, a hand-unified or a `@:multiType` one.
	 */
	private function graphWith(r: ResolvedType, clauseEnd: String -> TypeEnd): Null<CastGraph> {
		final clauses: Null<Array<CastClauses>> = clausesOf(r);
		if (!_abstractKinds.contains(r.type.kind) || clauses == null) return null;
		if (clauses.exists(c -> c.typeSelected) || _handUnified.contains(pathOf(r))) return null;
		final branches: Array<CastBranch> = [
			for (c in clauses) { from: [for (t in c.from) clauseEnd(t)], to: [for (t in c.to) clauseEnd(t)], transitive: c.transitive }
		];
		// a member of a type two branches declare may be another branch's; one under `#if` another build's
		final single: Bool = clauses.length == 1;
		final certain: MemberInfo -> Bool = m -> single && !m.guarded;
		final fromFields: Array<CastField> = [];
		final toFields: Array<CastField> = [];
		final members: Array<MemberInfo> = [for (b in _builds.of(r)) for (m in membersOf(r, b)) m];
		for (m in members) if (MemberKinds.FN_DECL_KINDS.contains(m.kind)) {
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
	 * The end of the declaration `r` applied to the type-argument ends `args`: an abstract declaring that many type
	 * parameters, every argument an end the graph models, stands for itself applied (`Applied`); `Open` otherwise.
	 */
	private function appliedEnd(r: ResolvedType, args: Array<TypeEnd>): TypeEnd {
		final modelled: Bool = args.length > 0 && !args.exists(a -> a.match(Open | Param(_)));
		return modelled && _abstractKinds.contains(r.type.kind) && r.type.typeParamArity == args.length ? Applied(r, args) : Open;
	}

	/**
	 * The end a plain `typedef` alias `r` stands for when it aliases a generic abstract with type arguments
	 * (`typedef FsPath = EitherType<String, Buffer>`): that abstract applied (`endIn` of its written target, where `r`
	 * writes it); null for any other declaration, which `followed` reads. An alias whose target re-enters it stands for none.
	 */
	private function appliedAlias(r: ResolvedType): Null<TypeEnd> {
		final raw: Null<String> = r.type.aliasTargetWritten;
		if (r.type.kind != SymbolIndex.TYPEDEF_DECL_KIND || r.type.isAnonStruct || r.type.typeParamArity > 0 || raw == null) return null;
		final target: Null<ResolvedType> = _ancestors.aliasTarget(r);
		final applied: Bool = switch _typeSyntax(raw.trim())?.shape {
			case Nominal(path, args):
				path != _nullable && args.length > 0;
			case _: false;
		};
		if (!applied || target == null) return null;
		final aliased: TypeDeclInfo = target.type;
		if (!_abstractKinds.contains(aliased.kind) || aliased.typeParamArity == 0) return null;
		final key: String = '${r.file.file}@${r.type.span.from}';
		if (_expanding.contains(key)) return Open;
		_expanding.push(key);
		final end: TypeEnd = endIn(raw, r.file, r.type.span.from, []);
		_expanding.pop();
		return end;
	}

	/**
	 * The type the `@:from` member `m` of `r` takes (its first parameter); `Open` when it takes none or another one too,
	 * or does not return `r` — what it converts into is then not `r` alone.
	 */
	private function inwardEnd(m: MemberInfo, r: ResolvedType): TypeEnd {
		final param: Null<String> = m.paramTypeSources.length == 1 ? m.paramTypeSources[0] : null;
		final returned: Null<String> = m.returnSource;
		return param != null && returned != null && same(writtenEnd(returned, r, m.declFrom, m.typeParamNames), Declared(r))
			? writtenEnd(param, r, m.declFrom, m.typeParamNames)
			: Open;
	}

	/** The type the `@:to` member `m` of `r` returns; `Open` for one taking a parameter or returning an inferred type. */
	private function outwardEnd(m: MemberInfo, r: ResolvedType): TypeEnd {
		final returned: Null<String> = m.returnSource;
		return returned == null || m.paramTypeSources.length > 0 ? Open : writtenEnd(returned, r, m.declFrom, m.typeParamNames);
	}

	/** Whether `a` and `b` are one end: one declaration, one core type, both dynamic. */
	public static function same(a: TypeEnd, b: TypeEnd): Bool {
		return switch [a, b] {
			case [Declared(x), Declared(y)]: AncestorTable.same(x, y);
			case [Applied(x, xs), Applied(y, ys)]:
				AncestorTable.same(x, y) && xs.length == ys.length && [for (i in 0...xs.length) i].foreach(i -> same(xs[i], ys[i]));
			case [Core(x), Core(y)]: x == y;
			case [Dyn, Dyn]: true;
			case _: false;
		};
	}

	/** The dotted path of the declaration `r`: its package, then its name. */
	private static inline function pathOf(r: ResolvedType): String {
		return r.file.pkg == '' ? r.type.name : '${r.file.pkg}.${r.type.name}';
	}

	/** The members of `r` the branch `b` declares: those whose declaration starts inside its range. */
	private static function membersOf(r: ResolvedType, b: DeclBranch): Array<MemberInfo> {
		return [
			for (m in r.type.members) if (b.span.from <= m.declFrom && m.declFrom < b.span.to) m
		];
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

	/**
	 * A type parameter of the signature a call is matched against — `T` of `function f<T:Int>(x:T)` — which the call binds
	 * by unifying its arguments (`CallSelection`); every other reader takes it for `Open`.
	 */
	Param(name: String);

	/**
	 * A generic abstract applied to type arguments — `EitherType<String, Buffer>` — each an end the graph models: its
	 * clauses read with the arguments for its type parameters (`AbstractCasts.appliedGraph`, `apply_params`).
	 */
	Applied(r: ResolvedType, args: Array<TypeEnd>);

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
