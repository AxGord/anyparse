package anyparse.query;

import anyparse.query.AbstractCasts.CastBranch;
import anyparse.query.AbstractCasts.CastField;
import anyparse.query.AbstractCasts.CastGraph;
import anyparse.query.AbstractCasts.TypeEnd;
import anyparse.query.ArgumentSlots.ArgumentFit;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SymbolIndex.ResolvedType;

using Lambda;

/**
 * Whether a value of one type unifies with another, and whether an argument of one type is accepted where another is
 * expected: the memo of the compiler's `unify` (`tUnification.ml`, Haxe 4.3.7) and of the implicit cast an argument takes
 * (`abstractCast.ml`, `cast_or_unify`) over the declarations the index holds — steps T2 and T4 of the typer by
 * specification (`docs/typing-service.md`). A pair of declarations is remembered by the pair (`QueryCache.unifies`,
 * `QueryCache.casts`); each side is read as a `TypeEnd` (`AbstractCasts.declEnd`): a declaration, a core value type, the
 * dynamic type.
 *
 * The specification's arms, as a positive whitelist. One declaration with no type parameter unifies with itself, whatever
 * its kind and its `#if` (`a == b`); every value with the dynamic type (`_, TDynamic None`); two core value types when they
 * are the same or one widens to the other. A class or an interface unifies with every ancestor its supertype chain reaches
 * (`TInst, TInst`: `loop` over `cl_super` then `cl_implements`) and, when every link of that chain resolves, with nothing
 * else; an enum with no other declaration (`TEnum, TEnum`: `ea != eb`), and a core value type with no class, interface or
 * enum. An ABSTRACT on either side unifies through its cast graph (`AbstractCasts`, `unify_to` / `unify_from` /
 * `unify_abstracts`): when a type one of the given side's `to` clauses writes unifies with the wanted side, or the given
 * side with a type one of the wanted side's `from` clauses writes — a cast through the clause of an abstract that is not
 * transitive (`get_abstract_context`) allowing no second abstract cast — in every `#if` branch that declares it. Every
 * other pair answers `MayFit`: an abstract the graph does not model, a WANTED declaration with type parameters, a class
 * declared under `#if`, a chain one link of which the index does not resolve, the dynamic type on the given side.
 *
 * An argument's cast (`casts`) adds the members a unification does not read (`do_check_cast`): an `@:to` member of the
 * given abstract returning a type that unifies with the wanted one, an `@:from` member of the wanted abstract taking one
 * the given type unifies with and, for a given type that is no abstract, the first `from` clause of the wanted abstract
 * unequal to it, cast to again (or the first `to` clause of a given abstract, for a wanted type that is no abstract) —
 * the compiler tries no other clause.
 */
@:nullSafety(Strict)
final class Unification {

	/** The resolved supertype links and alias targets the walk reads. */
	private final _ancestors: AncestorTable;

	/** The owning service's remembered answers. */
	private final _cache: QueryCache;

	/** The cycle guard of a walk over declarations (`TypeRefIndex.markSeen`). */
	private final _refs: TypeRefIndex;

	/** The cast graph of every abstract, and the ends each side of a question is read as. */
	private final _casts: AbstractCasts;

	/** Core value type -> the core types it widens to (`CoreValueTypes.widens`). */
	private final _widens: Map<String, Array<String>>;

	/** Built once by the owning `TypingService`. */
	public function new(
		ancestors: AncestorTable, cache: QueryCache, refs: TypeRefIndex, casts: AbstractCasts, shape: RefShape
	) {
		_ancestors = ancestors;
		_cache = cache;
		_refs = refs;
		_casts = casts;
		_widens = shape.coreValueTypes?.widens ?? [];
	}

	/**
	 * Whether a value of the type `given` declares unifies with the type `wanted` declares: `Fits`, `Misfits` or `MayFit`.
	 * One declaration with no type parameter is itself whatever its kind and its `#if` (`unify` starts with `a == b`): an
	 * abstract, an anonymous structure, a type declared under `#if`.
	 */
	public function unifies(given: ResolvedType, wanted: ResolvedType): ArgumentFit {
		return _cache.unifies.answer(
			DeclarationKey.ofPair(given, wanted),
			() ->
				AncestorTable.same(given, wanted) && given.type.typeParamArity == 0
					? Fits
					: unifyEnds(_casts.declEnd(given), _casts.declEnd(wanted), true, [])
		);
	}

	/**
	 * Whether an argument of the type `given` is accepted where `wanted` is expected — a unification, or the implicit cast
	 * the compiler inserts for an abstract (`cast_or_unify`): `Fits`, `Misfits` or `MayFit`.
	 */
	public function casts(given: TypeEnd, wanted: TypeEnd): ArgumentFit {
		return switch [given, wanted] {
			case [Declared(a), Declared(b)]: _cache.casts.answer(DeclarationKey.ofPair(a, b), castVerdict.bind(given, wanted));
			case _: castVerdict(given, wanted);
		};
	}

	/**
	 * Whether a value of the type `given` unifies with `wanted` (`unify`, an abstract cast through a clause allowed): what a
	 * type parameter's bound asks of the type a call binds it to. `Fits`, `Misfits` or `MayFit`.
	 */
	public function unifiesEnds(given: TypeEnd, wanted: TypeEnd): ArgumentFit {
		return unifyEnds(given, wanted, true, []);
	}

	/** `casts`' computation: a unification, else the cast the compiler would insert. */
	private function castVerdict(given: TypeEnd, wanted: TypeEnd): ArgumentFit {
		return either(unifyEnds(given, wanted, true, []), castPath(wanted, given, []));
	}

	/**
	 * Whether `given` unifies with `wanted`, an abstract cast through a clause allowed when `allowCast` (`allow_abstract_cast`),
	 * `stack` the pairs an abstract arm is walking already (`abstract_cast_stack`).
	 */
	private function unifyEnds(given: TypeEnd, wanted: TypeEnd, allowCast: Bool, stack: Array<String>): ArgumentFit {
		if (AbstractCasts.same(given, wanted) && !generic(given)) return Fits;
		switch wanted {
			case Dyn:
				return Fits;
			case Open, Param(_):
				return MayFit;
			case _:
		}
		switch given {
			case Dyn, Open, Param(_):
				return MayFit;
			case _:
		}
		switch [given, wanted] {
			case [Core(a), Core(b)]:
				return (_widens[a] ?? []).contains(b) ? Fits : Misfits;
			case _:
		}
		return _casts.isAbstract(given) || _casts.isAbstract(wanted)
			? abstractUnify(given, wanted, allowCast, stack)
			: plainUnify(given, wanted);
	}

	/** Two ends neither of which is an abstract nor the dynamic type, not two core value types. */
	private function plainUnify(given: TypeEnd, wanted: TypeEnd): ArgumentFit {
		return switch [given, wanted] {
			case [Declared(a), Declared(b)]:
				verdict(nominal(a), plain(b));
			// a core value type has no ancestor, so a class, an interface or an enum the index reads in every build rejects it
			case [Core(_), Declared(b)]: nominal(b) == null ? MayFit : Misfits;
			case [Declared(a), Core(_)]:
				final at: Null<ResolvedType> = nominal(a);
				at == null ? MayFit : reaches(at, wanted, []);
			case _: MayFit;
		};
	}

	/**
	 * A pair one side of which is an abstract (`unify_to` / `unify_from` / `unify_abstracts`): the given side's `to`
	 * clauses, else the wanted side's `from` clauses. `MayFit` on a pair `stack` holds already.
	 */
	private function abstractUnify(given: TypeEnd, wanted: TypeEnd, allowCast: Bool, stack: Array<String>): ArgumentFit {
		final key: String = '${endKey(given)}>${endKey(wanted)}';
		if (stack.contains(key)) return MayFit;
		stack.push(key);
		final outward: ArgumentFit = _casts.isAbstract(given)
			? throughClauses(given, allowCast, b -> b.to, (b, t) -> unifyEnds(t, wanted, nextCast(b, allowCast), stack))
			: Misfits;
		final inward: ArgumentFit = _casts.isAbstract(wanted)
			? throughClauses(wanted, allowCast, b -> b.from, (b, t) -> unifyEnds(given, t, nextCast(b, allowCast), stack))
			: Misfits;
		stack.pop();
		return either(outward, inward);
	}

	/**
	 * Whether some clause `side` reads of each branch of the abstract `e` leads to a fit (`unifies_to` / `unifies_from`):
	 * the branches' agreed answer. A branch that is not transitive allows no clause where `allowCast` is off.
	 */
	private function throughClauses(
		e: TypeEnd, allowCast: Bool, side: CastBranch -> Array<TypeEnd>, through: (b:CastBranch, t:TypeEnd) -> ArgumentFit
	): ArgumentFit {
		final graph: Null<CastGraph> = graphOf(e);
		return graph == null
			? MayFit
			: agreed([
				for (b in graph.branches)
					!b.transitive && !allowCast ? Misfits : anyOf([for (t in side(b)) through(b, t)])
			]);
	}

	/**
	 * The implicit cast the compiler looks for once a unification fails (`do_check_cast`'s `loop`, `wanted` its `tleft`):
	 * a member of either abstract, else the first clause unequal to the abstract, cast to again. `Misfits` on a pair
	 * `stack` holds already (`Not_found`).
	 */
	private function castPath(wanted: TypeEnd, given: TypeEnd, stack: Array<String>): ArgumentFit {
		switch [given, wanted] {
			case [Open | Dyn, _], [_, Open | Dyn]:
				return MayFit;
			case _:
		}
		final key: String = '${endKey(wanted)}<${endKey(given)}';
		if (stack.contains(key)) return Misfits;
		stack.push(key);
		final toAbstract: Bool = _casts.isAbstract(wanted);
		final fromAbstract: Bool = _casts.isAbstract(given);
		final found: ArgumentFit = if (toAbstract && fromAbstract)
			either(outwardMembers(given, wanted), inwardMembers(given, wanted))
		else if (toAbstract)
			either(inwardMembers(given, wanted), firstClause(wanted, b -> b.from, t -> castPath(t, given, stack)))
		else if (fromAbstract)
			either(outwardMembers(given, wanted), firstClause(given, b -> b.to, t -> castPath(wanted, t, stack)))
		else
			Misfits;
		stack.pop();
		return found;
	}

	/**
	 * The cast through the first clause `side` reads of each branch of the abstract `e` that is not `e` itself (`loop2`):
	 * the branches' agreed answer; `Misfits` for a branch writing none.
	 */
	private function firstClause(e: TypeEnd, side: CastBranch -> Array<TypeEnd>, through: TypeEnd -> ArgumentFit): ArgumentFit {
		final graph: Null<CastGraph> = graphOf(e);
		return graph == null
			? MayFit
			: agreed([
				for (b in graph.branches) {
					final first: Null<TypeEnd> = side(b).find(t -> !AbstractCasts.same(t, e));
					first == null ? Misfits : through(first);
				}
			]);
	}

	/** Whether a `@:from` member of the abstract `wanted` takes a type `given` unifies with (`find_field_from`). */
	private function inwardMembers(given: TypeEnd, wanted: TypeEnd): ArgumentFit {
		final graph: Null<CastGraph> = graphOf(wanted);
		return graph == null ? MayFit : membersFit(graph, graph.fromFields, (f, allow) -> unifyEnds(given, f.end, allow, []));
	}

	/** Whether a `@:to` member of the abstract `given` returns a type that unifies with `wanted` (`find_field_to`). */
	private function outwardMembers(given: TypeEnd, wanted: TypeEnd): ArgumentFit {
		final graph: Null<CastGraph> = graphOf(given);
		return graph == null ? MayFit : membersFit(graph, graph.toFields, (f, allow) -> unifyEnds(f.end, wanted, allow, []));
	}

	/**
	 * Whether one of `fields` of the abstract `graph` describes casts: `Fits` when a member every build declares does,
	 * `Misfits` when none does and no build macro may add one. Each is asked in the abstract's own context
	 * (`get_abstract_context`): a further abstract cast only for a transitive abstract.
	 */
	private function membersFit(graph: CastGraph, fields: Array<CastField>, fit: (f:CastField, allow:Bool) -> ArgumentFit): ArgumentFit {
		var open: Bool = !graph.fieldsComplete;
		for (f in fields) switch agreed([for (b in graph.branches) fit(f, b.transitive)]) {
			case Fits if (f.certain):
				return Fits;
			case Misfits:
			case _:
				open = true;
		}
		return open ? MayFit : Misfits;
	}

	/** The cast graph of the abstract end `e`: an abstract declaration's, a core value type's; null for any other end. */
	private function graphOf(e: TypeEnd): Null<CastGraph> {
		return switch e {
			case Declared(r): _casts.graph(r);
			case Applied(r, args): _casts.appliedGraph(r, args);
			case Core(name): _casts.coreGraph(name);
			case Dyn, Open, Param(_): null;
		};
	}

	/** The verdict on two plain declarations; `MayFit` when either is not one. */
	private function verdict(given: Null<ResolvedType>, wanted: Null<ResolvedType>): ArgumentFit {
		// an enum writes no supertype link, so its chain reaches nothing: `Misfits` against any other declaration
		return if (given == null || wanted == null)
			MayFit
		else if (AncestorTable.same(given, wanted))
			Fits
		else
			reaches(given, Declared(wanted), []);
	}

	/**
	 * Whether the supertype chain of the class or interface `cur` reaches `target`: `Fits` when a link does, `Misfits` when
	 * every link resolves and none does, `MayFit` when one does not resolve. `implements Dynamic` names no ancestor (the
	 * compiler records it as the class's dynamic access, not as a link).
	 */
	private function reaches(cur: ResolvedType, target: TypeEnd, seen: Array<String>): ArgumentFit {
		if (!_refs.markSeen(cur, seen)) return Misfits;
		var open: Bool = false;
		for (link in _ancestors.links(cur)) if (!MemberLookup.dynamicSupertypeRef(link.raw)) {
			final up: Null<ResolvedType> = link.decl == null ? null : _casts.followed(link.decl);
			if (up == null || up.type.guarded) {
				open = true;
				continue;
			}
			if (AbstractCasts.same(_casts.declEnd(up), target)) return Fits;
			switch reaches(up, target, seen) {
				case Fits:
					return Fits;
				case MayFit:
					open = true;
				case Misfits:
			}
		}
		return open ? MayFit : Misfits;
	}

	/** `r` as a plain declaration (`nominal`, declaring no type parameter), or null. */
	private function plain(r: ResolvedType): Null<ResolvedType> {
		final at: Null<ResolvedType> = nominal(r);
		return at == null || at.type.typeParamArity > 0 ? null : at;
	}

	/**
	 * `r` as a class, an interface or an enum (`followed`, not under `#if`), its type parameters whatever they are — the
	 * given side of a pair whose wanted side is plain, where the chain alone decides — or null.
	 */
	private function nominal(r: ResolvedType): Null<ResolvedType> {
		final at: Null<ResolvedType> = _casts.followed(r);
		return at == null || at.type.guarded || !SymbolIndex.PLAIN_NOMINAL_KINDS.contains(at.type.kind) ? null : at;
	}

	/** The context a cast through a clause of the branch `b` leaves (`get_abstract_context`): unchanged when it is transitive. */
	private static inline function nextCast(b: CastBranch, allowCast: Bool): Bool {
		return b.transitive && allowCast;
	}

	/** `Fits` when either answer is, `Misfits` when both are, else `MayFit`. */
	private static inline function either(a: ArgumentFit, b: ArgumentFit): ArgumentFit {
		return anyOf([a, b]);
	}

	/** Whether `e` is a declaration with type parameters: its arguments, not the declaration, decide what it unifies with. */
	private static function generic(e: TypeEnd): Bool {
		return switch e {
			case Declared(r): r.type.typeParamArity > 0;
			case _: false;
		};
	}

	/** The stack identity of an end. */
	private static function endKey(e: TypeEnd): String {
		return switch e {
			case Declared(r): '${r.file.file}@${r.type.span.from}';
			case Core(name): name;
			case Dyn: '*';
			case Open: '?';
			case Param(name): '<$name';
			case Applied(r, args): '${r.file.file}@${r.type.span.from}<${[for (a in args) endKey(a)].join(',')}>';
		};
	}

	/** `Fits` when some answer of `all` is, `Misfits` when every one is (none at all included), else `MayFit`. */
	private static function anyOf(all: Array<ArgumentFit>): ArgumentFit {
		return if (all.contains(Fits))
			Fits
		else if (all.contains(MayFit))
			MayFit
		else
			Misfits;
	}

	/** One answer every branch gives — `Fits` or `Misfits` — else `MayFit`. */
	private static function agreed(all: Array<ArgumentFit>): ArgumentFit {
		return if (all.length > 0 && all.foreach(a -> a == Fits))
			Fits
		else if (all.length > 0 && all.foreach(a -> a == Misfits))
			Misfits
		else
			MayFit;
	}

}
