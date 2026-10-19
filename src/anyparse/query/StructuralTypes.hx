package anyparse.query;

import anyparse.query.ArgumentSlots.ArgumentFit;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.TypeSyntax.TypeSyntaxReader;

using StringTools;
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
	 * `(default, null)` field of function type satisfies a structural method).
	 *
	 * `Iterator` and `KeyValueIterator` share one set: the latter is an alias of the former.
	 */
	private static final BUILTIN_STRUCTURAL_MEMBER_SETS: Array<Array<String>> = [
		[HAS_NEXT_MEMBER_NAME, NEXT_MEMBER_NAME],
		[ITERATOR_MEMBER_NAME],
		[KEY_VALUE_ITERATOR_MEMBER_NAME]
	];

	/**
	 * The language's nullability WRAPPER. Transparent for a structure-field unification — `{var
	 * x:Null<Int>}` accepts a class declaring `var x:Int` and `{var x:Int}` accepts `var x:Null<Int>` — so
	 * `comparableNominalOf` answers on its ARGUMENT rather than on the wrapper. Spelled here rather than
	 * read off the grammar shape for the reason `MemberLookup.dynamicSupertypeRef` spells `Dynamic`: this
	 * layer holds the index, not the plugin.
	 */
	private static final NULLABLE_WRAPPER_TYPE_NAME: String = 'Null';

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

	/** `GrammarPlugin.typeSyntax` of the grammar that built the owning index. */
	private final _typeSyntax: TypeSyntaxReader;

	/** The typing service's unification of plain types: how a read-only structure field's type meets the class member's. */
	private final _unification: Unification;

	/** Built once by the owning `TypingService`, which hands over the shared, immutable index data. */
	public function new(
		files: Array<FileInfo>, refs: TypeRefIndex, subtypes: SubtypeGraph, members: MemberLookup, typeSyntax: TypeSyntaxReader,
		unification: Unification
	) {
		_files = files;
		_refs = refs;
		_subtypes = subtypes;
		_members = members;
		_typeSyntax = typeSyntax;
		_unification = unification;
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
	 * `function x():T`, so only a structural `var x:T` pins it.
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
		return ret != null && found.member.firstParamTypeSource == null
			&& (ret == ITERATOR_TYPE_NAME || satisfiesIterator(ret, found.file));
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
	 * Whether a receiver of the declaration `receiver` binds to the FIRST parameter of the static extension `m`, a static
	 * `host` declares — the question `fields.ml` answers by unifying the receiver with that parameter
	 * (`type_field_by_extension`: `unify_static_extension`, Haxe 4.3.7), which `StaticExtensions.binding` asks of each
	 * candidate in the compiler's order. `Fits` binds it, `Misfits` makes the compiler pass the candidate over to the next
	 * one, `MayFit` is not decided here and ends the walk.
	 *
	 * The parameter is read where `host` writes it. `Null<T>` is transparent (`f(s:Null<String>)` binds a `String`), and
	 * a bare `Dynamic` takes every receiver. A type parameter of the method takes whatever it is constrained to, which
	 * the index does not record (`<T>(t:T)` binds a `String`, `<T:Int>(t:T)` passes it over): `MayFit`. A named type is
	 * unified with the receiver by declaration (`Unification.unifies`: a class or an interface by its chain, an enum by
	 * itself; an abstract on either side, a type argument on the parameter, a declaration the index does not resolve are
	 * `MayFit`). The two structural types the layer models by membership come last: `Iterable<T>` / `Iterator<T>` over
	 * one of the method's own type parameters `Fits` a receiver that DECLARES the membership (`satisfiesIterable` /
	 * `satisfiesIterator`) — what lets `Lambda.exists(it:Iterable<A>, …)` bind on an `Array` that implements no interface
	 * for it — and is `MayFit` otherwise: membership is a proof of acceptance, never of rejection, and a concrete or nested
	 * element (`Iterable<Widget>`, `Lambda.flatten`'s `Iterable<Iterable<A>>`) is not proven to bind.
	 */
	public function receiverFitsParameter(receiver: ResolvedType, m: MemberInfo, host: ResolvedType): ArgumentFit {
		final written: Null<String> = m.firstParamTypeSource;
		return written == null ? MayFit : writtenFits(receiver, written, m, host);
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
	 * The shared core of `structuralConformanceForbidsFinal` /
	 * `structuralConformanceForbidsWriteRestriction`: whether some structure declares `field` in a way
	 * `typeName` could no longer satisfy after the rewrite. `methodMemberPins` is the one axis the two
	 * callers differ on — a structural METHOD member forbids `final` but tolerates `(default, null)`.
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
				if (members.contains(field) && familyDeclaresEveryMember(typeName, members.map(builtinMember), [])) return true;
		for (fi in _files) for (t in fi.types) if (t.isAnonStruct) {
			final declared: Null<MemberInfo> = t.members.find(m -> m.name == field);
			if (declared == null) continue;
			final pins: Bool = MUTABLE_ANON_FIELD_KINDS.contains(declared.kind)
				|| (methodMemberPins && declared.kind == METHOD_ANON_FIELD_KIND);
			final host: ResolvedType = { file: fi, type: t };
			if (pins && familyDeclaresEveryMember(typeName, t.members.map(structureMember.bind(host)), [])) return true;
		}
		return false;
	}

	/**
	 * Whether `typeName` or any type BELOW it declares every member named in `members`. The
	 * subtype arm is not optional: a subtype INHERITS the field under rewrite, so its own
	 * conformance pins the declaration exactly as the owner's does — a `final` on a superclass
	 * field is `Inconsistent setter for field x : ctor should be default` at the SUBTYPE's
	 * unification site, where the same field as a `var` unifies. `seen` stops a cycle
	 * in the adjacency, which is built from simple names and can therefore hold one.
	 */
	private function familyDeclaresEveryMember(typeName: String, members: Array<StructureMember>, seen: Array<String>): Bool {
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
	private function declaresEveryMember(typeName: String, members: Array<StructureMember>): Bool {
		return _refs.resolvedDeclsNamed(typeName).exists(r -> members.foreach(m -> memberCouldUnify(r, m)));
	}

	/**
	 * Whether `owner` could carry the structure member `want` — the two halves of a conformance PROOF.
	 *
	 * First a POSITIVE proof that the member is declared at all (`declaredMemberClosure`, not
	 * `!lacksMemberClosure`): the absence walk fails closed toward "cannot prove absent", so its
	 * negation reads an unresolvable supertype as declaring EVERY member and any subclass of a
	 * type outside the resolution scope conformed to any structure naming the field.
	 *
	 * Then a refutation on the two WRITTEN types, because a member set is not a unification. A structure's
	 * MUTABLE field is INVARIANT: `{var x:Float}` rejects a class declaring `var x:Int`, `{var x:Base}`
	 * rejects `var x:Sub` (a subtype is not enough), and `{var x:C}` for an abstract `C` with a `@:from
	 * Int` rejects `var x:Int` (an implicit cast does not bridge a mutable field either). So two declarations that differ REFUTE the
	 * unification of a mutable field, and no consumer of this predicate may pin on them. A READ-ONLY structure member (a `final` field, a
	 * method) unifies covariantly instead (`tUnification.ml` unifies the class member's type WITH the structure's): `{final x:Base}`
	 * accepts `var x:Sub`, so there the plain types are unified (`Unification.unifies`) and only a `Misfits` refutes. Two types are told
	 * apart by DECLARATION (namesakes of two packages are two types); a spelling the index does not resolve is compared by its simple name.
	 *
	 * Both halves only ever REMOVE a pin, and both fail toward keeping it: a member whose type
	 * either side leaves unwritten, or whose spelling `comparableNominalOf` cannot close, still
	 * conforms.
	 */
	private function memberCouldUnify(owner: ResolvedType, want: StructureMember): Bool {
		final found: Null<{ member: MemberInfo, host: ResolvedType }> = _members.declaredMember(owner, want.name);
		if (found == null) return false;
		final wantHost: Null<ResolvedType> = want.host;
		final wantSource: Null<String> = want.typeSource;
		final haveSource: Null<String> = found.member.typeSource;
		if (wantHost == null || wantSource == null || haveSource == null) return true;
		final wanted: Null<ComparableType> = comparableTypeOf(wantSource, wantHost, []);
		final have: Null<ComparableType> = comparableTypeOf(haveSource, found.host, []);
		if (wanted == null || have == null) return true;
		final wantDecl: Null<ResolvedType> = wanted.decl;
		final haveDecl: Null<ResolvedType> = have.decl;
		// a type the index does not resolve is compared by its written name: the residual `comparableTypeOf` documents
		return if (wantDecl == null || haveDecl == null)
			wanted.name == have.name
		else if (want.readOnly)
			_unification.unifies(haveDecl, wantDecl) != Misfits
		else
			AncestorTable.same(haveDecl, wantDecl);
	}

	/**
	 * The nominal two WRITTEN types may be compared on for a unification refutation — its simple name, and
	 * the declaration it resolves to where it is written (its PATH as written, so `a.T` is `a.T`) — or
	 * null when this spelling cannot carry one — every null is a REFUSAL to refute, so the pin survives.
	 *
	 * Four spellings are open by construction. A type PARAMETER of the declaring type binds to
	 * whatever the unification site supplies. `Dynamic` unifies with everything. `Null<T>` is
	 * transparent for this question (`{var x:Null<Int>}` accepts `var x:Int` and the reverse), so
	 * the wrapper is stripped and its argument answered instead. And an ANONYMOUS-STRUCTURE nominal
	 * is open on the STRUCTURE side: two differently-named anon typedefs of the same shape DO unify
	 * (`{var x:Shape}` accepts `var x:Shape2`), so comparing anon nominals by NAME would refute a
	 * unification the compiler performs. Mutable-field invariance still holds THROUGH such a field —
	 * `{var x:{a:Int}}` rejects a class declaring `var x:D` for a `D` that declares `a:Int` — so the
	 * class side is not what is open here.
	 *
	 * A plain `typedef A = C` alias is FOLLOWED, not refused: `{var x:MyInt}` with
	 * `typedef MyInt = Int` accepts `var x:Int`, so comparing the written spellings would refute a
	 * unification the compiler performs. An alias whose target does not resolve, or one that
	 * re-enters itself, is open.
	 *
	 * RESIDUAL, deliberately: a nominal that resolves NOWHERE in the index is treated as CLOSED and
	 * compared by its written simple name. It is wrong for exactly one shape — an out-of-scope
	 * `typedef` aliasing the other side's nominal, which would be followed if it resolved — which
	 * leaves the std path and whatever no configured root reaches, the configured library half being
	 * indexed. `unit.check.StructuralConformanceProofTest#testUnresolvableStructureMemberTypeRefutes`
	 * pins the residual, so a future instance is a test change rather than a silent one.
	 */
	private function comparableTypeOf(typeSource: String, host: ResolvedType, seen: Array<String>): Null<ComparableType> {
		final nominal: Null<String> = NominalTypes.outerNominalOf(typeSource, _typeSyntax);
		if (nominal == null || MemberLookup.dynamicSupertypeRef(nominal)) return null;
		if (host.type.typeParamNames.contains(nominal)) return null;
		if (nominal == NULLABLE_WRAPPER_TYPE_NAME) {
			final args: Null<Array<String>> = NominalTypes.typeArgumentSourcesOf(typeSource, _typeSyntax);
			return args == null || args.length != 1 ? null : comparableTypeOf(args[0], host, seen);
		}
		final path: String = NominalTypes.outerPathOf(typeSource, [], _typeSyntax) ?? nominal;
		final decl: Null<ResolvedType> = _refs.resolveTypeRef(path, host.file, host.type.span.from);
		if (decl == null) return { name: nominal, decl: null };
		if (decl.type.kind != SymbolIndex.TYPEDEF_DECL_KIND) return { name: nominal, decl: decl };
		if (decl.type.isAnonStruct) return null;
		final target: Null<String> = decl.type.aliasTargetRaw;
		return target == null || !_refs.markSeen(decl, seen) ? null : comparableTypeOf(target, decl, seen);
	}

	/** `receiverFitsParameter` on the parameter type `written` (the whole first parameter, or the argument of a `Null<…>`). */
	private function writtenFits(receiver: ResolvedType, written: String, m: MemberInfo, host: ResolvedType): ArgumentFit {
		final nominal: Null<String> = NominalTypes.outerNominalOf(written, _typeSyntax);
		if (nominal == null) return MayFit;
		final args: Array<String> = NominalTypes.typeArgumentSourcesOf(written, _typeSyntax) ?? [];
		if (nominal == NULLABLE_WRAPPER_TYPE_NAME) return args.length == 1 ? writtenFits(receiver, args[0], m, host) : MayFit;
		if (MemberLookup.dynamicSupertypeRef(nominal)) return args.length == 0 ? Fits : MayFit;
		if (m.typeParamNames.contains(nominal) || host.type.typeParamNames.contains(nominal)) return MayFit;
		if (nominal == ITERABLE_TYPE_NAME || nominal == ITERATOR_TYPE_NAME) {
			final element: Null<String> = args.length == 1 ? args[0].trim() : null;
			if (element == null || !m.typeParamNames.contains(element)) return MayFit;
			final member: Bool = nominal == ITERABLE_TYPE_NAME
				? satisfiesIterable(receiver.type.name, receiver.file.file)
				: satisfiesIterator(receiver.type.name, receiver.file.file);
			return member ? Fits : MayFit;
		}
		final path: String = NominalTypes.outerPathOf(written, [], _typeSyntax) ?? nominal;
		final decl: Null<ResolvedType> = _refs.resolveTypeRef(path, host.file, m.declFrom);
		return decl == null ? MayFit : _unification.unifies(receiver, decl);
	}

	/** A member of a builtin structural type: a method by its name, no written type (`BUILTIN_STRUCTURAL_MEMBER_SETS`). */
	private static function builtinMember(name: String): StructureMember {
		return {
			name: name,
			typeSource: null,
			host: null,
			readOnly: true
		};
	}

	/** The member `m` of the structure declared by `host`; read-only unless its kind is a mutable field's. */
	private static function structureMember(host: ResolvedType, m: MemberInfo): StructureMember {
		return {
			name: m.name,
			typeSource: m.typeSource,
			host: host,
			readOnly: !MUTABLE_ANON_FIELD_KINDS.contains(m.kind)
		};
	}

}

/**
 * One member of the anonymous structure a conformance question is asked about — its name, the
 * WRITTEN type source it declares when it has one, and the declaration that spelled that source.
 *
 * The HOST is what makes the type source ANSWERABLE rather than merely comparable as text: a
 * simple name resolves through its own declaring file's import scope, and a name matching one of
 * that declaration's type PARAMETERS is not a nominal at all. Null on both for the language's
 * BUILTIN structural sets, which are member names with no types — the refutation half of
 * `memberCouldUnify` then does not apply and only the positive proof runs.
 */
typedef StructureMember = {
	/** The member's name. */
	var name: String;

	/** The member's VERBATIM declared type source, or null when the structure spells none. */
	var typeSource: Null<String>;

	/** The declaration `typeSource` was written in — its import scope and type parameters. */
	var host: Null<ResolvedType>;

	/**
	 * Whether the structure member cannot be written through the structure — a `final` field or a method — so a type
	 * unifies with it covariantly (`tUnification.ml`: a read-only field unifies the class member's type WITH the
	 * structure's), where a mutable one asks for the same type.
	 */
	var readOnly: Bool;
};

/** A written type as a structure-member unification compares it (`StructuralTypes.comparableTypeOf`). */
private typedef ComparableType = {

	/** Its outer nominal, by simple name. */
	final name: String;

	/** The declaration it resolves to where it is written, or null when the index resolves none. */
	final decl: Null<ResolvedType>;

}
