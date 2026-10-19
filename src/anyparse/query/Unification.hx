package anyparse.query;

import anyparse.query.ArgumentSlots.ArgumentFit;
import anyparse.query.SymbolIndex.ResolvedType;

/**
 * Whether a value of one PLAIN type unifies with another: the memo of the compiler's `unify` (`tUnification.ml`, Haxe
 * 4.3.7) over the declarations the index holds, step T2 of the typer by specification (`docs/typing-service.md`). Plain is
 * a class, an interface or an enum declaring no type parameter, reached directly or through plain `typedef` aliases: no
 * monomorph, no variance and no type argument takes part, so the answer is a function of the two declarations alone and
 * is remembered by the pair (`QueryCache.unifies`). The GIVEN side may declare type parameters when the wanted one is
 * plain: `unify (TInst (c1, tl1)) (TInst (c2, []))` walks `c1`'s supertypes for `c2` and has no argument to compare there
 * (`T3`, `docs/typing-service.md`), so `MyList<Int>` against a plain interface it implements is decided by the chain alone.
 *
 * The specification's arms, as a positive whitelist. One declaration unifies with itself. A class or an interface
 * unifies with every ancestor its supertype chain reaches (`TInst, TInst`: `loop` over `cl_super` then `cl_implements`) and,
 * when every link of that chain resolves, with nothing else. An enum unifies with no other declaration (`TEnum, TEnum`:
 * `ea != eb`), and a class or an interface with no enum nor the reverse (the closing `_, _` arm). Every other pair answers
 * `MayFit`: an abstract on either side (its `from` / `to` casts are step T4), a WANTED declaration with type parameters, one
 * declared under `#if` (its branches may extend different types, and one answer serves every configuration), and a chain
 * one link of which the index does not resolve.
 */
@:nullSafety(Strict)
final class Unification {

	/** The resolved supertype links and alias targets the walk reads. */
	private final _ancestors: AncestorTable;

	/** The owning service's remembered answers. */
	private final _cache: QueryCache;

	/** The cycle guard of a walk over declarations (`TypeRefIndex.markSeen`). */
	private final _refs: TypeRefIndex;

	/** Built once by the owning `TypingService`. */
	public function new(ancestors: AncestorTable, cache: QueryCache, refs: TypeRefIndex) {
		_ancestors = ancestors;
		_cache = cache;
		_refs = refs;
	}

	/**
	 * Whether a value of the type `given` declares unifies with the type `wanted` declares: `Fits`, `Misfits` or `MayFit`.
	 * One declaration with no type parameter is itself whatever its kind and its `#if` (`unify` starts with `a == b`): an
	 * abstract, an anonymous structure, a type declared under `#if`.
	 */
	public function unifies(given: ResolvedType, wanted: ResolvedType): ArgumentFit {
		return _cache.unifies.answer(
			DeclarationKey.ofPair(given, wanted),
			() -> AncestorTable.same(given, wanted) && given.type.typeParamArity == 0 ? Fits : verdict(nominal(given), plain(wanted))
		);
	}

	/** The verdict on two plain declarations; `MayFit` when either is not one. */
	private function verdict(given: Null<ResolvedType>, wanted: Null<ResolvedType>): ArgumentFit {
		// an enum writes no supertype link, so its chain reaches nothing: `Misfits` against any other declaration
		return if (given == null || wanted == null)
			MayFit
		else if (AncestorTable.same(given, wanted))
			Fits
		else
			reaches(given, wanted, []);
	}

	/**
	 * Whether the supertype chain of the class or interface `cur` reaches `target`: `Fits` when a link does, `Misfits` when
	 * every link resolves and none does, `MayFit` when one does not resolve. `implements Dynamic` names no ancestor (the
	 * compiler records it as the class's dynamic access, not as a link).
	 */
	private function reaches(cur: ResolvedType, target: ResolvedType, seen: Array<String>): ArgumentFit {
		if (!_refs.markSeen(cur, seen)) return Misfits;
		var open: Bool = false;
		for (link in _ancestors.links(cur)) if (!MemberLookup.dynamicSupertypeRef(link.raw)) {
			final up: Null<ResolvedType> = link.decl == null ? null : followed(link.decl);
			if (up == null || up.type.guarded) {
				open = true;
				continue;
			}
			if (AncestorTable.same(up, target)) return Fits;
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
		final at: Null<ResolvedType> = followed(r);
		return at == null || at.type.guarded || !SymbolIndex.PLAIN_NOMINAL_KINDS.contains(at.type.kind) ? null : at;
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

}
