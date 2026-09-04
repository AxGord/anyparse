package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.OverrideFamilyMember;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.SymbolIndex.TypeDeclInfo;

using Lambda;

/**
 * Member lookup on a NAMED type: does it declare `m`, what type does `m` have, what does `m`
 * return, how visible is it — each answered on the type itself and, where the question is about
 * what a VALUE of that type offers, over its inherited closure as well.
 *
 * Split out of `SymbolIndex`, which resolves NAMES to declarations; this layer resolves MEMBERS on
 * an already-resolved declaration. Every walk is cycle-guarded through the index's own `markSeen`,
 * and every one of them fails CLOSED — an unresolved supertype ends that branch instead of
 * asserting absence, so widening the resolution scope can only ever add information.
 */
@:nullSafety(Strict)
@:allow(anyparse.query.StructuralTypes)
@:allow(anyparse.query.MemberPathWalk)
final class MemberLookup {

	/** Every indexed file's `FileInfo`, handed over by the owning index. */
	private final _files: Array<FileInfo>;

	/** The name -> declaration layer this one resolves every written member and supertype reference through. */
	private final _refs: TypeRefIndex;

	/** Built once by the owning `SymbolIndex`, which hands over the shared, immutable index data. */
	public function new(files: Array<FileInfo>, refs: TypeRefIndex) {
		_files = files;
		_refs = refs;
	}

	/**
	 * Whether type `typeName`'s member `field` is a getter-property (true → reading it runs code), a
	 * plain member (false → side-effect-free read), or unknown (null). The member may be declared on
	 * `typeName` ITSELF or INHERITED from a project-resolvable supertype — `memberGetterWalk` climbs
	 * `supertypesRaw` (`extends` and `implements` alike). A direct declaration is conclusive and stops
	 * the climb: Haxe forbids redeclaring an inherited field, so nothing above can contradict it.
	 *
	 * The ROOT entry is simple-name unioned across every same-simple-named declaration, exactly as it
	 * always was; only the inherited arm is resolution-anchored. That arm resolves each written
	 * supertype reference through `resolveTypeRef` — IMPORT-AWARE and UNAMBIGUOUS — so for the EVIDENCE
	 * climb an external or simple-name-ambiguous link simply ends its branch (a safe miss → null) and a
	 * namesake's member can never be folded in. Conservative under ambiguity, unchanged: any resolvable
	 * declaration that IS a getter wins over every plain one. The `@:autoBuild` SCAN below is the one
	 * place that does not stop there — a hit means REFUSE, so its miss direction is the unsafe one and
	 * it follows an unresolvable link through a unique simple-name fallback.
	 *
	 * Three gates apply to the INHERITED arm ONLY, leaving the direct answer byte-for-byte what
	 * shipped. Two directions of change survive that, both conservative for every consumer listed
	 * below: a previously-`null` answer can become `false` (the widening this exists for), and a
	 * previously-`false` one can be LIFTED to `true` — the root being a simple-name UNION, a
	 * same-simple-named SIBLING declaration that inherits a getter now contributes its `true`
	 * (`package a; class Sub {var f:Int;}` alongside `package b; class Sub extends Base {}` over a
	 * `b.Base {var f(get, never):Int;}` answers `true` where it answered `false`).
	 *
	 * - **Statics are not inherited.** A supertype's `static` member never answers a subtype's
	 *   instance access — the two namespaces are disjoint, the same split `OrphanAccessor.walkChain`
	 *   turns on `isStatic == wantStatic`. Without the gate a same-named static reads as the
	 *   subtype's field and answers `false` for a member the subtype does not have.
	 * - **`@:build` on an inherited declaring type.** The macro may rewrite that type's own field
	 *   into a property, so its accessor shape is not readable from source: the arm contributes no
	 *   `false` there and answers null.
	 * - **`@:autoBuild` at or above an inherited declaring type** (`autoBuildAtOrAbove`). That macro
	 *   generates into every DESCENDANT of its carrier, so a marker interface far above the type that
	 *   WRITES the field rewrites it into a property exactly as `@:build` on the declarer would —
	 *   verified against the compiler on `@:autoBuild(M.gen()) interface Marker {}` +
	 *   `class Base implements Marker {public var f:Int = 1;}` + `class Sub extends Base {}`, where
	 *   reading `s.f` runs a generated getter. A `false` is downgraded to null for every carrier the
	 *   scan can REACH: import-visible through `resolveTypeRef`, or — since skipping here fails OPEN —
	 *   reachable through `uniqueDeclarationOf`, the project-wide unique simple-name fallback. A
	 *   carrier that is neither (its simple name absent from the index, or declared 2+ times) is the
	 *   residual boundary and stays missed; the fallback is deliberately NOT a blanket refusal on any
	 *   unresolvable link, since a genuinely external supertype such as `Sprite` must keep letting a
	 *   plain inherited member answer `false`.
	 *
	 * ROOT ASYMMETRY — deliberate, recorded rather than closed. The root arm consults NONE of the
	 * three. It carries the same `@:autoBuild` hole and always did: on the shape above,
	 * `memberGetter('Base', 'f')` answered `false` before this walk existed and still does. Closing it
	 * at the root would not tighten the widening, it would change SHIPPED deletion policy —
	 * `ExtractRepeatedExpression` acts on `== true`, for which a root `false` turning null changes
	 * nothing at all, while the two `isPlainFieldRead` fixers act on `== false` and would stop
	 * performing deletions they have always performed. Out of scope for this walk.
	 *
	 * GENERIC supertypes need NO type-argument substitution here. The projection drops type arguments
	 * from an inheritance clause (`class A extends B<C>` → `(ExtendsClause (Named B))`), so
	 * `supertypesRaw` already carries the bare nominal `B` and the link resolves; and the answer is the
	 * member's ACCESSOR SHAPE (`hasGetter`), never its TYPE — `public final d:T` is accessor-less
	 * whatever `T` binds to. Nothing is substituted because nothing needs to be. A consumer that wants
	 * the member's RESOLVED TYPE must use `resolveGenericPathFinalMemberTypeSource`, the only walk that
	 * binds type parameters to arguments — and even that one substitutes for a DIRECTLY-declared member
	 * only, since it does not model the extends-clause argument mapping. On THIS very shape it does not
	 * fail closed either: `class Base<T> {public final d:T;}` + `class Sub extends Base<Int> {}` yields
	 * the UNBOUND parameter name `T`, because `substitutedMemberSource` runs `mentionsTypeParam` against
	 * the RECEIVER's `typeParamNames` (`Sub` → empty, and an empty list early-returns false) instead of
	 * the DECLARING type's. That is a separate PRE-EXISTING defect of `substitutedMemberSource`, left
	 * untouched here. Answering accessor shape rather than type is what makes the inherited arm
	 * answerable at all.
	 *
	 * `seen` is per-ROOT-declaration and SHARED across sibling supertype branches (matching
	 * `inheritsMemberWalk`). Sharing it is NEUTRAL, not conservative: a `true` returns immediately
	 * through every frame and a `false` propagates up through every frame it passes, so each node's
	 * local answer reaches the root on that node's FIRST visit — an engine that copied `seen` per
	 * branch would re-walk nodes and aggregate the identical set of local answers. Its one job is
	 * terminating a cycle.
	 *
	 * THREE call sites across TWO predicates, feeding THREE fixers — and the conservative direction
	 * points the same way for all of them, which is what makes widening this SHARED predicate in place
	 * legitimate. `TypeResolver.isPlainFieldRead` (2 call sites) acts on `== false` ("provably plain
	 * read") and feeds two code-DELETING fixers: `TypeResolver.isDeletionPure` → `UnusedLocal`'s
	 * `--fix`, and `DeadStore.rhsSafeToDelete` directly. So every new `false` is a positive proof — the
	 * direction this widening exists for — and every downgrade to null merely keeps code.
	 * `ExtractRepeatedExpression.isSideEffectingGetter` (1 call site) acts on `== true` ("getter,
	 * impure, bail"), for which `false` and `null` are indistinguishable, so new `true`s only make it
	 * MORE conservative. None of the three reads a spurious answer as a licence to act.
	 */
	public function memberGetter(typeName: String, field: String): Null<Bool> {
		var found: Null<Bool> = null;
		for (fi in _files) for (t in fi.types) if (t.name == typeName) {
			final r: Null<Bool> = memberGetterWalk({ file: fi, type: t }, field, false, []);
			if (r == true) return true;
			if (r == false) found = false;
		}
		return found;
	}

	/**
	 * The return-type OUTER nominal of type `typeName`'s member `memberName` — e.g. `Null`
	 * for a `Null<T>`-returning method — or null when unknown or AMBIGUOUS. A direct member
	 * wins; failing that, the member is resolved through the type's (unanimous) supertype
	 * closure, so an INHERITED `Null<T>` method is caught (an override's own return shadows
	 * the base, since the direct lookup runs first). Conservative: a simple-name collision
	 * whose matches disagree on the nominal — direct or inherited — yields null, so a
	 * cross-file nullable-source resolution never fires on an unresolved name. Resolution is by
	 * SIMPLE name (the index models no packages).
	 */
	public function returnNominalOf(typeName: String, memberName: String): Null<String> {
		return returnNominalWalk(typeName, memberName, []);
	}

	/**
	 * The VERBATIM declared type SOURCE of type `typeName`'s member `memberName` — the
	 * written `:Type` text of a `Type.member` reference, with any `Null<…>` wrapper
	 * PRESERVED (a read of `Null<T>` IS `Null<T>`) — or null when unknown or AMBIGUOUS.
	 * DIRECT members only: Haxe does not inherit statics, so a `Type.staticField` never
	 * resolves through a supertype. Unanimous across every same-named type + member: a
	 * simple-name collision whose matches disagree on the written type (e.g. a
	 * conditional-compilation `#if`/`#else` pair with differing types), or a member with
	 * no recoverable type source (an inference-typed field, a method), yields null. The
	 * returned source is the type's spelling IN ITS DECLARING FILE — its identity is
	 * pinned there, but the SIMPLE name may not resolve in a consumer file's import scope
	 * (a consumer copying it verbatim must confirm the name is in scope; the index models
	 * no packages, so resolution is by simple name).
	 */
	public function memberTypeSourceOf(typeName: String, memberName: String): Null<String> {
		var found: Null<String> = null;
		var count: Int = 0;
		for (fi in _files) for (t in fi.types) if (t.name == typeName) for (m in t.members) if (m.name == memberName) {
			final ts: Null<String> = m.typeSource;
			if (ts == null) return null;
			if (count == 0)
				found = ts;
			else if (ts != found)
				return null;
			count++;
		}
		return found;
	}

	/**
	 * Every indexed declaration of type `typeName`'s member `memberName`, each paired
	 * with the type declaration that hosts it — one entry per same-simple-name type
	 * across the index (the index models no packages, so resolution is by SIMPLE name)
	 * and one per `#if` branch that declares the member. DIRECT members only, like
	 * `memberTypeSourceOf`: a supertype's member is a different declaration and is not
	 * folded in here.
	 *
	 * Unlike the unanimity-collapsing queries next to it, this one hands the caller the
	 * raw set and takes no verdict of its own — a consumer needing a property of the
	 * member must require it of EVERY entry. An EMPTY result means the member is not
	 * resolvable in the indexed scope and must be read as "unknown", never as "absent":
	 * the index skips unparseable files and models neither packages nor macro-generated
	 * members.
	 */
	public function memberDeclarationsOf(typeName: String, memberName: String): Array<{ type: TypeDeclInfo, member: MemberInfo }> {
		return [
			for (fi in _files) for (t in fi.types) if (t.name == typeName)
				for (m in t.members) if (m.name == memberName) { type: t, member: m }
		];
	}

	/**
	 * The effective DECLARED visibility keyword of type `typeName`'s member
	 * `memberName`, resolved through the supertype closure: a direct member's own
	 * explicit keyword wins; an UNMARKED override defers to the supertypes (its
	 * visibility is inherited); an unmarked non-override yields null — the language
	 * default depends on the container (an extern / `@:publicFields` class defaults
	 * to public), which the index does not model, so it is not provable. Unanimous
	 * everywhere: a simple-name collision or a multi-supertype resolution whose
	 * answers disagree — or mix an explicit keyword with a deferring override —
	 * yields null. Drives the `missing-visibility` autofix on `override` members;
	 * calling it with the OVERRIDING type itself resolves through the defer rule.
	 */
	public function memberVisibilityOf(typeName: String, memberName: String): Null<String> {
		return memberVisibilityWalk(typeName, memberName, []);
	}

	/**
	 * Whether a (transitive) supertype of `typeName` declares a member named `field`.
	 * Such a field's property access is fixed by the supertype, so a check must not
	 * tighten it (`var` → `final` / `(default, null)`) — Haxe rejects an override /
	 * implementation whose access differs — and an interface-typed write to it
	 * attributes to the supertype, not `typeName`. The supertype-ward companion of
	 * `hasSubtype`, used by the public-field immutability checks as a soundness gate.
	 */
	public function supertypeDeclaresMember(typeName: String, field: String): Bool {
		return supertypeDeclares(typeName, field, []);
	}

	/**
	 * Whether the type named `typeName` DECLARED IN `file` provably inherits a member
	 * named `member` from a supertype, resolved through UNAMBIGUOUS, import-aware links
	 * only. The enclosing type is pinned to its `(file, name)` declaration, so a
	 * same-named unrelated type elsewhere in the set can never contribute the proof;
	 * each supertype reference is resolved to the SINGLE in-set type its written path
	 * names (a qualified path by identity, a simple name through the declaring file's
	 * import scope or its own package), so a base that is external — or whose simple
	 * name merely collides with an unrelated in-set type — yields NO proof. Every
	 * unresolved or ambiguous link is skipped (a safe miss); `true` is returned only on
	 * a POSITIVE proof that a uniquely-resolved ancestor declares `member`. The precise
	 * counterpart of `supertypeDeclaresMember` for a caller that must never over-claim
	 * membership (stripping a load-bearing `this.`).
	 */
	public function inheritsMemberUnambiguously(file: String, typeName: String, member: String): Bool {
		final start: Null<ResolvedType> = _refs.findDeclaredType(file, typeName);
		return start != null && inheritsMemberWalk(start, member, []);
	}

	/**
	 * Whether `typeName` DECLARED IN `file` provably inherits an INSTANCE member named `member` -
	 * one a subtype body can still name through `this.<member>`. The instance-aware sibling of
	 * `inheritsMemberUnambiguously`, and like it resolved through UNAMBIGUOUS, import-aware links
	 * only: the loose simple-name walk behind `supertypeDeclaresMember` answers for whatever type
	 * happens to share the name, which is the SAFE direction for a caller that bails on a `true` and
	 * the acting direction here (a spurious `true` writes a `this.` the compiler rejects).
	 *
	 * The walk stops at the FIRST supertype declaring the name - the one resolution would bind - so a
	 * `static` declaration answers `false` rather than letting a deeper instance one win. An
	 * unresolvable link contributes nothing and leaves the answer `false` (fail-closed).
	 */
	public function inheritsInstanceMember(file: String, typeName: String, member: String): Bool {
		final start: Null<ResolvedType> = _refs.findDeclaredType(file, typeName);
		return start != null && inheritsInstanceMemberWalk(start, member, []) == true;
	}

	/**
	 * Whether the type `typeName` — together with its ENTIRE supertype closure — provably
	 * declares no member named `member`. True only when `typeName` resolves to exactly one
	 * indexed decl, every transitive supertype likewise resolves, and none of them declares
	 * `member`. Any unresolved / ambiguous type anywhere in the closure yields false — the
	 * member could be declared out of the lint scope, so its absence is not provable. The
	 * green-light companion of `supertypeDeclaresMember`, used by `trivial-getter` to prove an
	 * implemented interface does not require the property's `get_` accessor before collapsing
	 * it to `(default, null)`.
	 *
	 * Both the STARTING type and every supertype EDGE resolve by written path, not by globally
	 * unique simple name: an edge against its own referring type's file, the start against
	 * `fromFile` when the caller supplies one or against its own dotted path when it is
	 * qualified (`resolveStartType`). A caller holding neither — no file, unqualified name —
	 * still needs the name to be unique among indexed decls. Pass `fromFile` whenever the name
	 * came out of a specific file's `implements` clause or receiver expression; pass the full
	 * module path when you have it.
	 *
	 * The walk FOLLOWS a plain `typedef A = C` alias to `C` and refuses a `@:forward` abstract,
	 * whose underlying's members reach it through a link `supertypes` does not carry — the
	 * positive companions (`typeDeclaresMember` / `supertypeDeclaresMember`) do NOT, so a caller
	 * needing the shadow answer on an aliased nominal must read a false here as "unprovable"
	 * rather than as "declared".
	 */
	public function typeProvablyLacksMember(typeName: String, member: String, ?fromFile: String): Bool {
		// A caller may pass `Dynamic` itself — it reaches an `interfaces` list from an
		// `implements Dynamic<T>` clause — and it declares no named member (see `dynamicSupertypeRef`).
		if (dynamicSupertypeRef(typeName)) return true;
		final start: Null<ResolvedType> = _refs.resolveStartType(typeName, fromFile);
		return start != null && lacksMemberClosure(start, member, []);
	}

	/**
	 * Whether ANY indexed type named `typeName` DIRECTLY declares a member named
	 * `member` — methods included, supertypes NOT consulted. The SHADOW companion of
	 * `typeProvablyLacksMember` (which proves absence across the whole closure) and of
	 * `supertypeDeclaresMember` (which asks the same question of the INHERITED half):
	 * this one answers the direct half, and the two together decide whether an
	 * instance member would take precedence over a static extension of the same name.
	 * Unioned across same-simple-name decls, so a positive answer is a conservative
	 * "some type by that name has it" — the safe direction for a caller that treats a
	 * hit as "do not rewrite".
	 */
	public function typeDeclaresMember(typeName: String, member: String): Bool {
		for (fi in _files) for (t in fi.types) if (t.name == typeName && t.members.exists(m -> m.name == member)) return true;
		return false;
	}

	/**
	 * Whether a receiver of type `typeName` reaches an INSTANCE member named `member` — declared by
	 * its own body or anywhere in its supertype closure — so a `using` static extension of that name
	 * is never consulted at the call.
	 *
	 * Haxe resolves a real member BEFORE any static extension, which makes this the one question a
	 * rule rewriting `<recv>.<member>(…)` through a `using` has to ask about its receiver. The
	 * measured case is `Map`: `haxe.ds.Map` declares `exists(key:K)`, so `m.exists(x -> …)` binds
	 * the lambda into the KEY slot and does not compile. `prefer-exists`, `prefer-foreach`,
	 * `prefer-find`, `dead-binder-counter-loop` and `prefer-static-extension` all emit such a call
	 * and all ask here, so there is ONE spelling of the answer rather than five.
	 *
	 * A POSITIVE proof, and the direction matters: true means "a member provably shadows the
	 * extension, do not rewrite", while false unions "provably no such member" with "this run cannot
	 * tell". Callers keep whatever they already did on a false — refusing everything unproven would
	 * drop every site whose receiver type is outside the resolution scope. The absence half is a
	 * DIFFERENT question with a different answer (`typeProvablyLacksMember`), which
	 * `prefer-static-extension` asks as well because it must tell a claimable site from a hedged one.
	 *
	 * The two halves are the pair `typeDeclaresMember` / `supertypeDeclaresMember` already name in
	 * their own docs. The direct half unions across same-simple-name decls, which is conservative in
	 * the safe direction and is what reaches `haxe.ds.Map` past the top-level `typedef Map` whose
	 * package `aliasTargetNominal` drops.
	 */
	public function memberShadowsExtension(typeName: String, member: String): Bool {
		return typeDeclaresMember(typeName, member) || supertypeDeclaresMember(typeName, member);
	}

	/**
	 * EVERY declaration of `member` on `typeName`. A type declares one member more than once only
	 * when the declarations sit in different branches of a `#if` region, so they are ONE logical
	 * member: rewriting a single branch leaves every other build target with accesses that no
	 * declaration matches.
	 */
	public function declarationsOf(typeName: String, member: String): Array<OverrideFamilyMember> {
		return [
			for (fi in _files) for (t in fi.types) if (t.name == typeName)
				for (m in t.members) if (m.name == member) { file: fi.file, typeName: t.name, declFrom: m.declFrom }
		];
	}

	/**
	 * Whether `typeName` IMPLEMENTS an interface that declares a member named `field` —
	 * or implements an interface that cannot be resolved in the current scope. Such a
	 * field is pinned to the interface's declared property access, so a `var → final`
	 * rewrite would break the access parity Haxe requires ("Field `field` has different
	 * property access than in <Interface>"). An unresolvable interface is blocked
	 * CONSERVATIVELY: out of scope, it MAY declare `field` as a mutable member, so the
	 * safe direction is to skip the rewrite. Interfaces are enumerated from the type's
	 * `implements` clause only (`TypeDeclInfo.interfaces`), and each is tested with
	 * `typeProvablyLacksMember`, whose false result already unions "declares the member
	 * (transitively)" with "unresolvable". Superclass `extends` supertypes are NOT
	 * consulted — a subclass cannot redeclare an inherited field, so only implemented
	 * interfaces can pin a field's access here.
	 */
	public function implementsInterfaceDeclaringMember(typeName: String, field: String): Bool {
		// The `interfaces` entries are SIMPLE names lifted from the owner's own `implements`
		// clause, so they resolve against the OWNER's file — not globally.
		for (r in _refs.resolvedDeclsNamed(typeName))
			for (iface in r.type.interfaces)
				if (!typeProvablyLacksMember(iface, field, r.file.file)) return true;
		return false;
	}

	/**
	 * Recursive closure walk for `typeProvablyLacksMember`, cycle-guarded by `seen` through
	 * `markSeen` — keyed by declaring file, so two same-named types are distinct nodes.
	 * Each supertype edge resolves from its VERBATIM reference against `cur`'s own file
	 * (`resolveTypeRef`); a `Dynamic` one is skipped rather than counted as unresolvable
	 * (`dynamicSupertypeRef`).
	 */
	private function lacksMemberClosure(cur: ResolvedType, member: String, seen: Array<String>): Bool {
		// A supertype CYCLE still enumerates the whole closure, so re-entering a type proves
		// nothing new and nothing is lost by stopping — unlike the alias cycle below.
		if (!_refs.markSeen(cur, seen)) return true;
		final t: TypeDeclInfo = cur.type;
		if (t.members.exists(m -> m.name == member)) return false;
		// An ALIASING_DECL_KINDS decl reaches members through a link `supertypes` never records, so
		// its own empty member list proves NOTHING — the same hole `closureExcludes` refuses outright,
		// resolved here instead of refused: a plain `typedef A = C` continues the proof on `C`, while
		// an unreadable alias and a `@:forward` abstract (every underlying member is exposed under a
		// name the index cannot enumerate here) are not provable at all.
		if (t.kind == SymbolIndex.TYPEDEF_DECL_KIND && !t.isAnonStruct) {
			// The RAW path, not the simple name: `typedef List<T> = haxe.ds.List<T>` written in
			// the root package with no import resolves its own simple name back to ITSELF, so the
			// hop lands on the alias, hits the cycle test below and proves nothing.
			final target: Null<String> = t.aliasTargetRaw;
			if (target == null) return false;
			final next: Null<ResolvedType> = _refs.resolveTypeRef(target, cur.file);
			// An alias CYCLE proves nothing — unlike a supertype cycle, whose closure is still
			// fully enumerated, a chain that re-enters itself never reaches a member host at all.
			return next == null || seen.contains(_refs.seenKey(next)) ? false : lacksMemberClosure(next, member, seen);
		}
		if (t.abstractForwardUnderlying != null) return false;
		// Each supertype is resolved from its VERBATIM written reference against THIS type's own
		// file (`resolveTypeRef` -> `simpleRefInScope`), so a simple name shared by several
		// packages picks the one actually in scope instead of failing the whole proof. A
		// reference resolving to zero OR to several decls is refused identically: unresolved.
		for (raw in t.supertypesRaw) if (!dynamicSupertypeRef(raw)) {
			final anc: Null<ResolvedType> = _refs.resolveTypeRef(raw, cur.file);
			if (anc == null || !lacksMemberClosure(anc, member, seen)) return false;
		}
		return true;
	}

	/** Recursive supertype walk for `supertypeDeclaresMember`, cycle-guarded by `seen`. */
	private function supertypeDeclares(typeName: String, field: String, seen: Array<String>): Bool {
		if (seen.contains(typeName)) return false;
		seen.push(typeName);
		for (fi in _files)
			for (t in fi.types)
				if (t.name == typeName)
					for (sup in t.supertypes)
						if (typeDeclaresMember(sup, field) || supertypeDeclares(sup, field, seen)) return true;
		return false;
	}

	/**
	 * Recursive supertype walk for `inheritsMemberUnambiguously`, cycle-guarded by `seen`. Expressed
	 * through `inheritsInstanceMemberWalk`, which asks the strictly finer question over the same
	 * traversal: it returns non-null exactly when some ancestor in the closure declares `member`, and
	 * discriminates instance from static on top of that.
	 */
	private function inheritsMemberWalk(cur: ResolvedType, member: String, seen: Array<String>): Bool {
		return inheritsInstanceMemberWalk(cur, member, seen) != null;
	}

	/**
	 * Recursive supertype walk for `inheritsInstanceMember`, cycle-guarded by `seen` on the same
	 * `file#type` key as every sibling walk (the shared `markSeen`): `true` when the first supertype
	 * declaring `member` declares it non-statically, `false` when that one is `static`, null when
	 * nobody in the closure declares it.
	 */
	private function inheritsInstanceMemberWalk(cur: ResolvedType, member: String, seen: Array<String>): Null<Bool> {
		if (!_refs.markSeen(cur, seen)) return null;
		for (raw in cur.type.supertypesRaw) {
			final anc: Null<ResolvedType> = _refs.resolveTypeRef(raw, cur.file);
			if (anc == null) continue;
			final ancestor: ResolvedType = anc;
			final declared: Null<Bool> = declaredInstanceMember(ancestor.type, member);
			if (declared != null) return declared;
			final inherited: Null<Bool> = inheritsInstanceMemberWalk(ancestor, member, seen);
			if (inherited != null) return inherited;
		}
		return null;
	}

	/**
	 * The verbatim declared type source of `member` on `cur`'s type or its supertype closure
	 * (import-aware via `resolveTypeRef` over `supertypesRaw`), or null when absent. The
	 * type-source counterpart of `inheritsMemberWalk` — resolution stays anchored to the SPECIFIC
	 * resolved type, so a same-simple-name namesake never contributes a member.
	 */
	private function memberTypeSourceWalk(cur: ResolvedType, member: String, seen: Array<String>): Null<String> {
		if (!_refs.markSeen(cur, seen)) return null;
		final direct: Null<MemberInfo> = cur.type.members.find(m -> m.name == member);
		if (direct != null) return direct.typeSource;
		for (raw in cur.type.supertypesRaw) {
			final anc: Null<ResolvedType> = _refs.resolveTypeRef(raw, cur.file);
			if (anc == null) continue;
			final src: Null<String> = memberTypeSourceWalk(anc, member, seen);
			if (src != null) return src;
		}
		return null;
	}

	/**
	 * `memberGetter`'s recursion: the accessor shape of `field` on `cur`'s type or, failing a direct
	 * declaration, on its `resolveTypeRef`-resolved supertype closure. `inherited` distinguishes the
	 * ROOT entry — where the three gates the public doc spells out are inert, preserving the shipped
	 * direct-member answer — from every level reached by climbing. `seen` cycle-guards on the resolved
	 * `(file, name)` identity, shared across sibling branches like `inheritsMemberWalk`.
	 *
	 * A DECLARATION found here is conclusive: Haxe forbids redeclaring an inherited field, so the climb
	 * stops even when the answer is null. A member a gate SKIPS is deliberately not such a declaration
	 * — a `static` lives in the other namespace, so the climb walks past it and can still reach an
	 * instance member further up (`Top {var f}` ← `Mid {static var f}` ← `Leaf` answers `false`).
	 */
	private function memberGetterWalk(cur: ResolvedType, field: String, inherited: Bool, seen: Array<String>): Null<Bool> {
		if (!_refs.markSeen(cur, seen)) return null;
		var declared: Bool = false;
		for (m in cur.type.members) if (m.name == field && !(inherited && m.isStatic)) {
			if (m.hasGetter) return true;
			declared = true;
		}
		if (declared) return inherited && (cur.type.hasBuild || autoBuildAtOrAbove(cur, [])) ? null : false;
		var found: Null<Bool> = null;
		for (raw in cur.type.supertypesRaw) {
			final anc: Null<ResolvedType> = _refs.resolveTypeRef(raw, cur.file);
			if (anc == null) continue;
			final up: Null<Bool> = memberGetterWalk(anc, field, true, seen);
			if (up == true) return true;
			if (up == false) found = false;
		}
		return found;
	}

	/**
	 * Whether `cur` or any `resolveTypeRef`-resolved ancestor of it carries `@:autoBuild` — the
	 * evidence that `cur`'s own members may have been rewritten, since that macro generates into
	 * every DESCENDANT of its carrier. Scanned separately rather than carried as a flag down the
	 * climb because `memberGetterWalk` reaches the DECLARING type before it would reach a marker
	 * interface above it, so the flag would arrive too late to veto the answer. `cur` itself counts:
	 * a type's own `@:autoBuild` does not apply to it, but folding it in costs one flag read and can
	 * only refuse. `seen` is this scan's own — the climb's set already holds `cur`.
	 */
	private function autoBuildAtOrAbove(cur: ResolvedType, seen: Array<String>): Bool {
		if (!_refs.markSeen(cur, seen)) return false;
		if (cur.type.hasAutoBuild) return true;
		for (raw in cur.type.supertypesRaw) {
			final anc: Null<ResolvedType> = _refs.resolveTypeRef(raw, cur.file) ?? uniqueDeclarationOf(raw);
			if (anc == null) continue;
			if (autoBuildAtOrAbove(anc, seen)) return true;
		}
		return false;
	}

	/**
	 * The SINGLE project-wide declaration of `raw`'s simple name, or null when that name is absent
	 * from the index (a genuinely EXTERNAL type) or declared more than once (AMBIGUOUS). Mirrors
	 * `OrphanAccessor.uniqueDeclaration`, and exists for `autoBuildAtOrAbove` alone: that scan's
	 * miss direction is the unsafe one, so an import-invisible link must still be followed, whereas
	 * the evidence walks want the import-aware `resolveTypeRef` answer and nothing more.
	 */
	private function uniqueDeclarationOf(raw: String): Null<ResolvedType> {
		final dot: Int = raw.lastIndexOf('.');
		final simple: String = dot < 0 ? raw : raw.substr(dot + 1);
		final declarers: Array<FileInfo> = _refs.declaringFiles(simple);
		return declarers.length == 1 ? _refs.findDeclaredType(declarers[0].file, simple) : null;
	}

	/**
	 * `returnNominalOf`'s recursion: a direct member's return nominal (unanimous across
	 * same-named types, else null), or — when no direct member — the unanimous nominal
	 * resolved through the supertype closure. `seen` cycle-guards the walk.
	 */
	private function returnNominalWalk(typeName: String, memberName: String, seen: Array<String>): Null<String> {
		if (seen.contains(typeName)) return null;
		seen.push(typeName);
		var found: Null<String> = null;
		var direct: Int = 0;
		for (fi in _files) for (t in fi.types) if (t.name == typeName) for (m in t.members) if (m.name == memberName) {
			if (direct == 0)
				found = m.returnNominal;
			else if (m.returnNominal != found)
				return null;
			direct++;
		}
		if (direct > 0) return found;
		var inherited: Null<String> = null;
		var supers: Int = 0;
		for (fi in _files) for (t in fi.types) if (t.name == typeName) for (sup in t.supertypes) {
			final rn: Null<String> = returnNominalWalk(sup, memberName, seen);
			if (rn == null) continue;
			if (supers == 0)
				inherited = rn;
			else if (rn != inherited)
				return null;
			supers++;
		}
		return inherited;
	}

	/**
	 * `memberVisibilityOf`'s recursion: a direct member's explicit keyword
	 * (unanimous across same-named types, else null), an unmarked-override direct
	 * member defers to the (unanimous) supertype closure, an unmarked non-override
	 * bails. Mixing an explicit keyword with a deferring override across a
	 * simple-name collision is a disagreement → null. `seen` cycle-guards the walk.
	 */
	private function memberVisibilityWalk(typeName: String, memberName: String, seen: Array<String>): Null<String> {
		if (seen.contains(typeName)) return null;
		seen.push(typeName);
		var direct: Null<String> = null;
		var directCount: Int = 0;
		var deferring: Bool = false;
		for (fi in _files) for (t in fi.types) if (t.name == typeName) for (m in t.members) if (m.name == memberName) {
			final v: Null<String> = m.visibility;
			if (v == null) {
				if (!m.isOverride) return null;
				deferring = true;
			} else {
				if (directCount > 0 && v != direct) return null;
				direct = v;
				directCount++;
			}
		}
		if (directCount > 0) return deferring ? null : direct;
		var inherited: Null<String> = null;
		var supers: Int = 0;
		for (fi in _files) for (t in fi.types) if (t.name == typeName) for (sup in t.supertypes) {
			final v: Null<String> = memberVisibilityWalk(sup, memberName, seen);
			if (v == null) continue;
			if (supers > 0 && v != inherited) return null;
			inherited = v;
			supers++;
		}
		return inherited;
	}

	/**
	 * Whether a supertype reference is `Dynamic`. `implements Dynamic<T>` marks dynamic FIELD
	 * ACCESS and declares no NAMED member, so it can never be the inherited `_x` a rename would
	 * redefine — it must be SKIPPED rather than counted as an unresolvable dead end, which would
	 * wrongly block every `openfl` display subclass (`DisplayObject` carries such a clause under
	 * `#if`). Matched on the last path segment, so a qualified spelling is skipped too.
	 */
	private static inline function dynamicSupertypeRef(raw: String): Bool {
		final dot: Int = raw.lastIndexOf('.');
		return (dot < 0 ? raw : raw.substr(dot + 1)) == 'Dynamic';
	}

	/**
	 * Whether `type` itself declares `member` as an INSTANCE member: `true` when it declares it
	 * non-statically, `false` when ANY declaration of that name is `static`, null when the type
	 * declares no member of that name at all.
	 */
	private static function declaredInstanceMember(type: TypeDeclInfo, member: String): Null<Bool> {
		var found: Null<Bool> = null;
		for (m in type.members) if (m.name == member) {
			if (m.isStatic) return false;
			found = true;
		}
		return found;
	}

}
