package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.ResolvedType;

using Lambda;

/**
 * STRUCTURAL typing over the index: membership decided by what a type DECLARES, never by an
 * `implements` clause. Two questions live here — whether a value unifies with one of the
 * language's builtin structures (`Iterable` is whatever declares `iterator()`, `Iterator` whatever
 * declares `hasNext()` and `next()`; no stdlib container names either in an `implements`, so a
 * nominal proof answers null for every one of them), and what an anonymous structure PINS on the
 * member it unifies with — finalization, write access.
 *
 * Split out of `SymbolIndex`, one layer above `MemberLookup` and `SubtypeGraph`: a structural
 * proof is a member-set question asked over an inheritance family.
 */
@:nullSafety(Strict)
final class StructuralTypes {

	/**
	 * The two STRUCTURAL types the layer models, by MEMBERSHIP rather than by unification:
	 * `Iterable<A>` is whatever declares `iterator():Iterator<A>`, `Iterator<A>` is whatever
	 * declares `hasNext()` and `next()`. No stdlib container carries an `implements` clause for
	 * either, so a nominal subtype proof answers null for every one of them.
	 */
	private static final ITERABLE_TYPE_NAME: String = 'Iterable';

	/** The structural ITERATOR type's name — see `ITERABLE_TYPE_NAME`. */
	private static final ITERATOR_TYPE_NAME: String = 'Iterator';

	/** The member whose declaration IS `Iterable` membership. */
	private static final ITERATOR_MEMBER_NAME: String = 'iterator';

	/** The first of the two members whose declaration IS `Iterator` membership. */
	private static final HAS_NEXT_MEMBER_NAME: String = 'hasNext';

	/** The second of the two members whose declaration IS `Iterator` membership. */
	private static final NEXT_MEMBER_NAME: String = 'next';

	/** The member whose declaration IS `KeyValueIterable` membership. */
	private static final KEY_VALUE_ITERATOR_MEMBER_NAME: String = 'keyValueIterator';

	/**
	 * The member NAME SETS of the language's builtin structural types — the ones no project file
	 * declares, so the anon-structure walk over the index can never see them. A type declaring
	 * every name in a set is a value the compiler will unify with that structure, and every one
	 * of these declares its members as METHODS, which is why they pin only FINALIZATION (a
	 * `(default, null)` field of function type satisfies a structural method — measured).
	 *
	 * `Iterator` and `KeyValueIterator` share one set: the latter is an alias of the former.
	 */
	private static final BUILTIN_STRUCTURAL_MEMBER_SETS: Array<Array<String>> = [
		[HAS_NEXT_MEMBER_NAME, NEXT_MEMBER_NAME],
		[ITERATOR_MEMBER_NAME],
		[KEY_VALUE_ITERATOR_MEMBER_NAME]
	];

	/**
	 * The anon-structure member kinds that declare a MUTABLE field: the explicit `var x:T;` and
	 * the two shorthand forms `x:T` / `?x:T`. A value whose own member is `final` — or whose
	 * write access is restricted to `(default, null)` — cannot unify with one of these.
	 */
	private static final MUTABLE_ANON_FIELD_KINDS: Array<String> = ['VarField', 'Required', 'Optional'];

	/**
	 * The anon-structure member kind that declares a METHOD (`function x():T;`). A `final` field
	 * cannot unify with it (`Cannot unify final and non-final fields`); a `(default, null)` one
	 * can, so this kind pins only finalization.
	 */
	private static final METHOD_ANON_FIELD_KIND: String = 'FnField';

	/** Every indexed file's `FileInfo`, handed over by the owning index. */
	private final _files: Array<FileInfo>;

	/** The name -> declaration layer this one resolves every written member and receiver reference through. */
	private final _refs: TypeRefIndex;

	/** The inheritance layer: a structural proof is a member-set question asked over an inheritance family. */
	private final _subtypes: SubtypeGraph;

	/** The member layer: what the family members this one asks about actually declare. */
	private final _members: MemberLookup;

	/** Built once by the owning `SymbolIndex`, which hands over the shared, immutable index data. */
	public function new(files: Array<FileInfo>, refs: TypeRefIndex, subtypes: SubtypeGraph, members: MemberLookup) {
		_files = files;
		_refs = refs;
		_subtypes = subtypes;
		_members = members;
	}

	/**
	 * Whether making `field` of `typeName` FINAL may break a STRUCTURAL unification. Haxe
	 * unifies a class instance with an anonymous structure by member set, and a `final` field
	 * satisfies neither a structural `var x:T` (`Inconsistent setter for field x : ctor should
	 * be default`) nor a structural `function x():T` (`Cannot unify final and non-final
	 * fields`) — both measured. The unification is a READ position, so no write-based
	 * single-assignment proof can see it; this is the gate that does.
	 *
	 * CONSERVATIVE — it answers CONFORMANCE, not use: true when SOME structure that names `field`
	 * mutably could accept the type or a SUBtype of it at all (it declares every member that
	 * structure names, its own or inherited), whether or not any call site passes one. For a
	 * ONE-member structure that degenerates to a name test, since the candidate field is that
	 * member: a field named `iterator` or `keyValueIterator` is therefore never flagged, whatever
	 * its type. A full proof would have to follow every value of the type into every annotated
	 * position; this asks the question that bounds it from above, and over-declines exactly on a
	 * type that coincidentally has the right member set.
	 *
	 * Residual blind spots, all under-declining: an anonymous structure written INLINE in an
	 * annotation (`function f(): { x:Int }`) is no indexed type, nor is one NESTED inside another
	 * typedef's field type (only top-level declarations enter the walk), and a structure declared in
	 * a configured library root is outside the report-scoped file set.
	 */
	public inline function structuralConformanceForbidsFinal(typeName: String, field: String): Bool {
		return structuralConformancePins(typeName, field, true);
	}

	/**
	 * The write-restriction counterpart of `structuralConformanceForbidsFinal`: whether rewriting
	 * `field` of `typeName` to a read-only property may break a structural unification. Narrower
	 * by exactly one kind — a `(default, null)` field of function type DOES satisfy a structural
	 * `function x():T` (measured), so only a structural `var x:T` pins it.
	 */
	public inline function structuralConformanceForbidsWriteRestriction(typeName: String, field: String): Bool {
		return structuralConformancePins(typeName, field, false);
	}

	/**
	 * True iff every indexed type with simple name `name` is an anonymous-struct
	 * typedef (and at least one exists) — so a value of that type has only plain
	 * fields and `value.field` access is provably side-effect-free. Conservative
	 * under ambiguity: a single non-anon match (or no match) yields false.
	 */
	public function isAnonStructType(name: String): Bool {
		var found: Bool = false;
		for (fi in _files) for (t in fi.types) if (t.name == name) {
			if (!t.isAnonStruct) return false;
			found = true;
		}
		return found;
	}

	/**
	 * The RETURN nominal a `using <module>` STATIC EXTENSION gives at `<recv>.<method>(…)`, where
	 * `recv` carries the simple type `receiver` — or null when nothing here proves one.
	 *
	 * `module` resolves the same way `typeProvablyLacksMember` resolves its start type: against
	 * `fromFile`'s import scope when one is given, else by its own dotted path, else as a simple
	 * name that must be unique among indexed decls. Pass the `using` declaration's text verbatim
	 * and the file that declared it.
	 *
	 * Every gate fails closed, and one of them is the whole reason this is not `returnNominalOf`
	 * on the module: the first parameter must ACCEPT the receiver, not merely exist. Accepted are
	 * an exact nominal match, a proven NOMINAL subtype (`isSubtype`), and — only for the two
	 * structural types the layer models by MEMBERSHIP — a receiver that satisfies `Iterable` /
	 * `Iterator` while implementing neither (`receiverFitsParameter`), which is what lets
	 * `Lambda.exists(it:Iterable<A>, …)` bind on an `Array`.
	 *
	 * The rest: the member must be STATIC (an instance method is not reachable through a
	 * `using`), and must carry a WRITTEN return — an inference-typed one
	 * names no type at all, while `:Void` resolves to the nominal `Void`, exactly as
	 * `returnNominalOf` already answers it for an ordinary member. Every declaration of the name
	 * must agree, since a `#if` pair returning two different types proves nothing branch-blind. A
	 * module declaring the name with a non-accepting first parameter answers null rather than the
	 * next candidate's return: that IS the correct answer for that module, and the caller walks
	 * its remaining `using`s itself.
	 *
	 * What this deliberately does NOT decide is whether the receiver's own type declares `method`
	 * — a real member BEATS an extension and the extension must not be consulted at all. That
	 * gate belongs to the caller, which holds the receiver and must prove absence with
	 * `typeProvablyLacksMember` BEFORE asking here (`NominalTypes.staticExtensionNominal`).
	 */
	public function extensionReturnNominal(module: String, method: String, receiver: String, ?fromFile: String): Null<String> {
		final host: Null<ResolvedType> = _refs.resolveStartType(module, fromFile);
		if (host == null) return null;
		var found: Null<String> = null;
		for (m in host.type.members) if (m.name == method) {
			final paramSource: Null<String> = m.firstParamTypeSource;
			final ret: Null<String> = m.returnNominal;
			if (!m.isStatic || paramSource == null || ret == null) return null;
			final accepts: Null<String> = NominalTypes.outerNominalOf(paramSource);
			if (accepts == null || !receiverFitsParameter(receiver, accepts, paramSource, host, fromFile)) return null;
			if (found != null && found != ret) return null;
			found = ret;
		}
		return found;
	}

	/**
	 * Whether `typeName` satisfies the structural `Iterable` — it DECLARES, itself or anywhere in
	 * its supertype closure, an `iterator()` method whose return satisfies `Iterator`. That is the
	 * whole definition of `Iterable<A>` in the language, and it is the only reason `Lambda`'s
	 * statics reach an `Array`: no stdlib container implements an interface for it, so
	 * `isSubtype` answers (correctly) false and a nominal proof can never be found.
	 *
	 * MEMBERSHIP, deliberately not unification. Three facts about the declaration are checked and
	 * nothing else is inferred: it carries a WRITTEN return (a FIELD named `iterator` answers null
	 * here — a field's type is a `typeSource`, never a `returnNominal` — and so does an
	 * inference-typed method, which names no type to follow), it declares no annotated FIRST
	 * parameter (an `iterator(n:Int)` is a different method that happens to share the name), and
	 * its return is the structural `Iterator` by name or by its own membership. The element TYPE
	 * is not part of the answer: this says the receiver is iterable, never over WHAT — the caller
	 * that needs the element type must gate on it separately.
	 *
	 * The `Iterator`-by-name shortcut is what makes the std reachable without indexing
	 * `StdTypes`: `Map.iterator():Iterator<V>` names it directly, while
	 * `Array.iterator():haxe.iterators.ArrayIterator<T>` is followed one link further into
	 * `ArrayIterator`'s own membership. A project type named `Iterator` that is not an iterator
	 * would be taken at its word — a false accept whose only consumer is a disambiguation gate
	 * between two `using` modules, never a rewrite.
	 *
	 * False for a receiver whose type, or a link in its supertype closure, the run does not index:
	 * this is a positive PROOF, and it fails closed exactly like `typeProvablyLacksMember`.
	 */
	public function satisfiesIterable(typeName: String, ?fromFile: String): Bool {
		if (typeName == ITERABLE_TYPE_NAME) return true;
		final found: Null<{ member: MemberInfo, file: String }> = structuralMemberOf(typeName, fromFile, ITERATOR_MEMBER_NAME, []);
		if (found == null) return false;
		final ret: Null<String> = found.member.returnNominal;
		return
			ret != null && found.member.firstParamTypeSource == null && (ret == ITERATOR_TYPE_NAME || satisfiesIterator(ret, found.file));
	}

	/**
	 * Whether `typeName` satisfies the structural `Iterator` — it DECLARES, itself or anywhere in
	 * its supertype closure, both `hasNext()` and `next()`, neither of them an annotated FIELD.
	 *
	 * The field test is the only discriminator available, and that is a measured limit rather than
	 * a choice: `haxe.iterators.ArrayIterator` writes both methods with an INFERRED return, so a
	 * membership rule demanding `hasNext():Bool` would refuse the single most common iterator in
	 * the language. An unannotated `var hasNext = false;` therefore passes; the failure direction
	 * is one extra candidate offered to a `using`-disambiguation gate, never a rewrite.
	 */
	public function satisfiesIterator(typeName: String, ?fromFile: String): Bool {
		if (typeName == ITERATOR_TYPE_NAME) return true;
		final has: Null<{ member: MemberInfo, file: String }> = structuralMemberOf(typeName, fromFile, HAS_NEXT_MEMBER_NAME, []);
		final next: Null<{ member: MemberInfo, file: String }> = structuralMemberOf(typeName, fromFile, NEXT_MEMBER_NAME, []);
		return has != null && next != null && has.member.typeSource == null && next.member.typeSource == null;
	}

	/**
	 * Whether a `using` extension whose FIRST parameter is written `paramSource` (outer nominal
	 * `accepts`) binds at a call on a receiver of type `receiver` — the accept half of
	 * `extensionReturnNominal`, kept apart because it answers in three ways and only the first is
	 * nominal.
	 *
	 * An exact nominal match and a proven nominal subtype are the whole of what a nominal index
	 * can say. The third way is STRUCTURAL, and it exists because `Lambda`'s entire surface takes
	 * `Iterable<A>` while no container in the language declares that it implements one:
	 * `satisfiesIterable` / `satisfiesIterator` decide membership from the receiver's own declared
	 * members, which is exactly what the compiler unifies against.
	 *
	 * The structural way carries a gate the nominal ways do not need — the ELEMENT type. Proving
	 * the receiver is iterable is not proving that its element type binds the signature's
	 * parameter: `Iterable<Widget>` accepts a `Bag` of widgets and no other, while `Iterable<T>`
	 * over the method's own `T` accepts every one. A receiver NOMINAL carries no element type, so
	 * only the second form is provable, and it is recognised by the one fact that separates a
	 * method's type PARAMETER from a real type — the name resolves to no declaration in the scope
	 * where the signature is written. Everything else is refused: a concrete element
	 * (`Iterable<Widget>`), a nested application (`Iterable<Iterable<A>>`, so `Lambda.flatten`),
	 * and an unapplied `Iterable` naming no element at all.
	 *
	 * That refusal set is the per-member verdict on `Lambda` itself. CLAIMED, all generic in their
	 * element: `array` / `list` / `map` / `mapi` / `flatMap` / `has` / `exists` / `foreach` /
	 * `empty` / `count` / `indexOf` / `findIndex` / `iterator`. REFUSED here: `flatten`, whose
	 * parameter's element is itself an application. Refused one gate EARLIER, by
	 * `extensionReturnNominal`'s written-return requirement: `filter`, which the std declares with
	 * an inferred return. Refused DOWNSTREAM, where the answer names a type nothing declares:
	 * `fold` / `foldi`, returning a bare method type parameter, and `find`, returning `Null<T>` —
	 * both resolve to no unique declaration, so every consumer that must act keeps its
	 * conservative branch.
	 */
	private function receiverFitsParameter(
		receiver: String, accepts: String, paramSource: String, host: ResolvedType, fromFile: Null<String>
	): Bool {
		if (accepts == receiver || _subtypes.isSubtype(receiver, accepts)) return true;
		if (accepts != ITERABLE_TYPE_NAME && accepts != ITERATOR_TYPE_NAME) return false;
		final args: Null<Array<String>> = NominalTypes.typeArgumentSourcesOf(paramSource);
		if (args == null || args.length != 1) return false;
		final element: String = args[0];
		return SourceText.isIdentifier(element) && _refs.resolveTypeRef(element, host.file) == null
			&& (accepts == ITERABLE_TYPE_NAME ? satisfiesIterable(receiver, fromFile) : satisfiesIterator(receiver, fromFile));
	}

	/**
	 * The `member` declaration `typeName`'s own body or its supertype closure carries, together
	 * with the file that declared it — null when the closure declares none, or when any link in it
	 * is unresolvable. The declaring file rides along because a member's WRITTEN return is a
	 * reference in THAT file's scope: `Array.iterator()` names `haxe.iterators.ArrayIterator`,
	 * which resolves from `Array.hx` and from nowhere the call site can see.
	 *
	 * Each supertype is re-entered through `resolveStartType` against the CURRENT file, the same
	 * import-aware step `lacksMemberClosure` takes, so a simple name shared by several packages
	 * picks the one actually in scope. `seen` stops a supertype cycle.
	 */
	private function structuralMemberOf(
		typeName: String, fromFile: Null<String>, member: String, seen: Array<String>
	): Null<{ member: MemberInfo, file: String }> {
		// A member's written return may name a type that resolves nowhere near the reading file —
		// `Array.iterator()` answers `haxe.iterators.ArrayIterator`, written QUALIFIED and imported
		// by nobody, so the scope-aware step finds nothing and the package-blind one (a simple name
		// unique among indexed decls) is the only way the link is followed at all.
		final start: Null<ResolvedType> = _refs.resolveStartType(typeName, fromFile) ?? _refs.resolveStartType(typeName, null);
		if (start == null || !_refs.markSeen(start, seen)) return null;
		final host: String = start.file.file;
		final own: Null<MemberInfo> = start.type.members.find(m -> m.name == member);
		if (own != null) return { member: own, file: host };
		// A `typedef` hosts its members through a link neither `members` nor `supertypesRaw`
		// carries — both are EMPTY on an alias decl — so without this hop every aliased container
		// answers "declares nothing", which is the whole reason `List` and `Map` were unprovable.
		// Followed from the ALIAS's own file and by its WRITTEN path, the same two rules the
		// supertype hop below uses; `markSeen` above stops an alias cycle just as it stops a
		// supertype one. An anon-struct alias is excluded: its fields are the index's own members.
		if (start.type.kind == SymbolIndex.TYPEDEF_DECL_KIND && !start.type.isAnonStruct) {
			final target: Null<String> = start.type.aliasTargetRaw;
			return target == null ? null : structuralMemberOf(target, host, member, seen);
		}
		for (raw in start.type.supertypesRaw) {
			final up: Null<{ member: MemberInfo, file: String }> = structuralMemberOf(raw, host, member, seen);
			if (up != null) return up;
		}
		return null;
	}

	/**
	 * The shared core of `structuralConformanceForbidsFinal` / `structuralConformanceForbidsWriteRestriction`:
	 * whether some structure declares `field` in a way `typeName` could no longer satisfy after
	 * the rewrite. `methodMemberPins` is the one axis the two callers differ on — a structural
	 * METHOD member forbids `final` but tolerates `(default, null)`.
	 *
	 * Two arms, both requiring `typeName` OR A SUBTYPE of it to declare the structure's WHOLE
	 * member set (that is what makes the unification possible in the first place): the language's
	 * builtin structural aliases, which no project file declares, and every anonymous-structure
	 * typedef the index holds. A structure declaring `field` as `final` is not an arm — a mutable
	 * field already fails to unify with it, so finalizing can only repair that, never break it.
	 */
	private function structuralConformancePins(typeName: String, field: String, methodMemberPins: Bool): Bool {
		if (methodMemberPins)
			for (members in BUILTIN_STRUCTURAL_MEMBER_SETS)
				if (members.contains(field) && familyDeclaresEveryMember(typeName, members, [])) return true;
		for (fi in _files) for (t in fi.types) if (t.isAnonStruct) {
			final declared: Null<MemberInfo> = t.members.find(m -> m.name == field);
			if (declared == null) continue;
			final pins: Bool = MUTABLE_ANON_FIELD_KINDS.contains(declared.kind)
				|| (methodMemberPins && declared.kind == METHOD_ANON_FIELD_KIND);
			if (pins && familyDeclaresEveryMember(typeName, [for (m in t.members) m.name], [])) return true;
		}
		return false;
	}

	/**
	 * Whether `typeName` or any type BELOW it declares every member named in `members`. The
	 * subtype arm is not optional: a subtype INHERITS the field under rewrite, so its own
	 * conformance pins the declaration exactly as the owner's does — a `final` on a superclass
	 * field is `Inconsistent setter for field x : ctor should be default` at the SUBTYPE's
	 * unification site, where the same field as a `var` unifies (measured). `seen` stops a cycle
	 * in the adjacency, which is built from simple names and can therefore hold one.
	 */
	private function familyDeclaresEveryMember(typeName: String, members: Array<String>, seen: Array<String>): Bool {
		if (seen.contains(typeName)) return false;
		seen.push(typeName);
		return declaresEveryMember(typeName, members)
			|| _subtypes.subtypesOf(typeName).exists(sub -> familyDeclaresEveryMember(sub.type.name, members, seen));
	}

	/**
	 * Whether some declaration named `typeName` declares — itself or through a supertype — every
	 * member named in `members`.
	 *
	 * Each candidate declaration is asked from its OWN file rather than package-blind, because a
	 * simple name two packages both declare resolves to NOTHING package-blind, and "declares
	 * nothing" is the UNSAFE answer here: it un-gates the rewrite that this whole predicate
	 * exists to refuse. Any one declaration conforming is enough — the consumers address an owner
	 * by simple name too, so they cannot tell which declaration their candidate belongs to either,
	 * and the union is the only reading that cannot under-fire.
	 */
	private function declaresEveryMember(typeName: String, members: Array<String>): Bool {
		return _refs.resolvedDeclsNamed(typeName).exists(r -> members.foreach(m -> !_members.lacksMemberClosure(r, m, [])));
	}

}
