package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.OverrideFamilyMember;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;

using Lambda;

/**
 * The project-wide INHERITANCE graph: who extends or implements whom, and what that closure
 * proves. Two directions over the same `supertypes` edges — DOWNWARD from a type to its subtypes
 * (`subtypesOf` and the `eachSubtype` walks over the lazily-built adjacency), and UPWARD from a
 * type through its supertype chain (`closureContains` / `closureExcludes`, the `isSubtype` and
 * `provablyNotSubtype` proofs, the override family a cross-file member rename must rewrite whole).
 *
 * Split out of `SymbolIndex`, which keeps the layer BELOW: which files declare a name, and which
 * declaration a written type reference denotes. This layer asks that question through `_index`
 * and adds nothing to it. The two maps it caches are instance state on the run-scoped index — the
 * index is immutable after construction, so one build per instance is safe and nothing here is
 * process-scoped.
 */
@:nullSafety(Strict)
@:allow(anyparse.query.StructuralTypes)
final class SubtypeGraph {

	/** The grammar kind an `abstract` declaration projects as. */
	private static final ABSTRACT_DECL_KIND: String = 'AbstractDecl';

	/**
	 * The owner decl kinds whose member a subtype may implement WITHOUT the override modifier — an
	 * interface method, and an `abstract` method on an abstract class. Under any other kind Haxe
	 * rejects a redeclaration that omits `override`, which makes the modifier a reliable filter on
	 * override-family candidates.
	 */
	private static final BARE_IMPLEMENTABLE_OWNER_KINDS: Array<String> = ['InterfaceDecl', 'AbstractClassDecl'];

	/**
	 * The decl kinds whose `supertypes` is NOT their complete set of inheritance edges: a `typedef`
	 * ALIAS (`typedef A = C`, legal in an `extends` position) and an abstract (`abstract W(C)` with
	 * `@:forward` / `@:from` / `@:to`) each reach another type through a link no `extends` /
	 * `implements` clause records. Their closure therefore looks EMPTY, which a negative-reachability
	 * proof would read as "excludes everything" — so `closureExcludes` refuses them at its ROOT. As a
	 * supertype LINK an abstract is a different matter: Haxe rejects one in either inheritance clause,
	 * so a link resolving to it is no edge at all and is stepped over (`supertypeLinkIsAbstract`). A
	 * POSITIVE proof (`closureContains`) needs no guard either way: an unseen edge only makes it miss,
	 * which is its safe direction.
	 */
	private static final ALIASING_DECL_KINDS: Array<String> = ['TypedefDecl', 'AbstractDecl'];

	/** Every indexed file's `FileInfo`, handed over by the owning index. */
	private final _files: Array<FileInfo>;

	/** Per-file source text, handed over by the owning index. */
	private final _sources: Map<String, String>;

	/** The name -> declaration layer this one resolves every written supertype reference through. */
	private final _refs: TypeRefIndex;

	/**
	 * Lazily-built subtype adjacency: a supertype's SIMPLE name -> every `(file, type)` pair
	 * naming it in `supertypes`, in file / declaration order. The index is immutable after
	 * construction, so one build per instance is safe; it replaces a full `_files` x `types`
	 * rescan per closure level in the subtype walks.
	 *
	 * A subtype is filed under every name that DENOTES its supertype, not only the one written —
	 * see `subtypesOf`.
	 */
	private var _subtypeAdjacency: Null<Map<String, Array<ResolvedType>>>;

	/**
	 * Lazily-built supertype union map: a type's SIMPLE name -> every simple name any declaration
	 * of it names in `supertypes`. Built once per instance for the same reason
	 * `_subtypeAdjacency` is — the index is immutable after construction — and read by
	 * `supertypeNameUnion`.
	 */
	private var _supertypeNames: Null<Map<String, Array<String>>>;

	/** Built once by the owning `SymbolIndex`, which hands over the shared, immutable index data. */
	public function new(files: Array<FileInfo>, sources: Map<String, String>, refs: TypeRefIndex) {
		_files = files;
		_sources = sources;
		_refs = refs;
	}

	/**
	 * Whether any (transitive) SUBTYPE of `owner` references the private backing field `field` the trivial-getter collapse would DELETE — a subclass reading `owner`'s private `_x` directly breaks with 'Unknown identifier' once `_x` is removed, since the rename only rewrites references inside `owner`. The subtype closure is walked DOWNWARD over the index by simple-name supertype edges, so only real descendants are visited (a sibling sharing an unresolvable ancestor never false-blocks). A subtype declaring its OWN `field` is skipped (a bare reference there binds to that member, not the inherited one); a subtype whose declaration span word-boundary-references `field` blocks the collapse, and an unscannable source — or a second type carrying `owner`'s own simple name, which the index cannot tell apart from `owner` — blocks conservatively. Sound over indexed subtypes; a subtype in an unindexed file is the inherent blind spot the accessor-override gate shares.
	 */
	public inline function subtypeReferencesField(owner: String, field: String): Bool {
		return subtypeDeclMatches(
			owner, field, (_, src, span, redeclares) -> !redeclares && SourceText.identTokenOffset(src, span, field) >= 0
		);
	}

	/**
	 * Does any indexed type extend / implement `typeName` (matched by simple
	 * name)? The first gate of a cross-file-safe private-member rename — a
	 * subtype could reference the member.
	 *
	 * A supertype written as a TYPEDEF ALIAS of `typeName` counts; two alias shapes still do not,
	 * and `subtypesOf` names them.
	 */
	public function hasSubtype(typeName: String): Bool {
		return subtypesOf(typeName).length > 0;
	}

	/**
	 * Whether `a` and `b` are provably UNRELATED classes — both resolve to a unique indexed CLASS
	 * decl, are distinct, and neither is a transitive supertype of the other with BOTH supertype
	 * closures fully resolved inside the index. Sound for the always-false `is` check: two unrelated
	 * classes share no common subtype under Haxe single inheritance, so a value of one can never be an
	 * instance of the other.
	 *
	 * The two STARTING names are simple and must each be globally unique (`isUniqueClass`); the
	 * supertype EDGES inside each closure resolve by written path against the referring type's own file
	 * (`closureExcludesFrom`), so an ancestor whose simple name another package reuses no longer fails
	 * the proof. An edge that resolves to zero or several decls still does — the closure is then not
	 * fully enumerated, and unrelatedness is not proven.
	 */
	public function unrelatedClasses(a: String, b: String): Bool {
		return a != b && isUniqueClass(a) && isUniqueClass(b) && closureExcludes(a, b) && closureExcludes(b, a);
	}

	/**
	 * Whether `sub` is a transitive (proper) SUBTYPE of `sup` — `sup`'s simple name
	 * appears in `sub`'s transitive supertype closure (extends + implements). Positive
	 * direction: an unindexed or ambiguous supertype link simply ends that branch (a safe
	 * MISS, never a false claim of subtyping); not reflexive (`sub == sup` → false — the
	 * caller decides same-type separately). Names are SIMPLE; a same-named unrelated type
	 * in the chain is the residual soundness boundary, as in `unrelatedClasses`.
	 *
	 * A supertype written through an ALIAS is followed — both kinds, composing in either order. The
	 * `import pkg.Base as U;` hop is read off the DECLARING file's own imports (that binding exists in
	 * no other module); the `typedef U = Base;` hop off the declaration `U` itself resolves to.
	 *
	 * The UPWARD counterpart of `subtypesOf`, and deliberately NOT its equal. This walk never claims
	 * more than the downward one does and refuses two shapes it accepts: a name the index resolves to
	 * several declarations, and an alias bound inside a `#if` region. Both refusals are the same
	 * reason — `subtypesOf` is read as a veto, where over-breadth withholds, while this is read
	 * affirmatively by autofixes that DELETE.
	 */
	public function isSubtype(sub: String, sup: String): Bool {
		return closureContains(sub, sup, [sub]);
	}

	/**
	 * Whether `sub` is provably NOT a (transitive) subtype of `sup` — the POSITIVE proof of the
	 * negative, which a false `isSubtype` does NOT supply: `isSubtype` ends a branch on any
	 * unresolvable supertype link, so its `false` unions "provably unrelated" with "unprovable". True
	 * only when `sub` resolves to a single decl, its ENTIRE supertype closure likewise resolves, and
	 * `sup` appears nowhere in it. Reflexivity is not unrelatedness (`sub == sup` → false). For a
	 * caller that must act on "different owner" rather than merely skip on "not proven the same" —
	 * attributing an occurrence away from a rename on an unprovable negative drops a real reference and
	 * half-applies the edit.
	 *
	 * `sub` is a simple name and must be globally unique; every supertype EDGE resolves by written path
	 * against its referring type's file, so an ancestor sharing a simple name with another package's
	 * type is reached correctly instead of failing the proof (`closureExcludesFrom`).
	 */
	public function provablyNotSubtype(sub: String, sup: String): Bool {
		return sub != sup && closureExcludes(sub, sup);
	}

	/**
	 * An ancestor of `typeName` — superclass or interface — that declares `member`, or null when
	 * none does. This is the UPWARD question `overrideFamilyOf` never asks: it models the family
	 * from the BASE down, so a cursor sitting on an implementation finds nothing. In Haxe an
	 * implementation of an `abstract` method or an interface method carries NO `override`
	 * modifier, so a keyword check does not see it either.
	 */
	public function declaringAncestorOf(typeName: String, member: String): Null<String> {
		final declarers: Array<String> = [
			for (fi in _files) for (t in fi.types) if (t.members.exists(m -> m.name == member)) t.name
		];
		return declarers.find(n -> n != typeName && isSubtype(typeName, n));
	}

	/**
	 * Whether any indexed type that is a (transitive) SUBTYPE of `typeName` declares
	 * a member named `member` — i.e. `typeName`'s member is OVERRIDDEN somewhere
	 * below it. The subtype-ward, member-specific counterpart of
	 * `supertypeDeclaresMember`: it scans every indexed type, and for each that
	 * declares `member` tests `isSubtype` against `typeName` (transitive extends +
	 * implements). Names are SIMPLE (the index models no packages), so a same-named
	 * unrelated type is the residual soundness boundary, as in `isSubtype`. Used by
	 * `unused-parameter`'s rename fix to leave a base method's parameter alone when
	 * a subclass override may use it.
	 */
	public function subtypeDeclaresMember(typeName: String, member: String): Bool {
		for (fi in _files)
			for (t in fi.types)
				if (t.name != typeName && t.members.exists(m -> m.name == member) && declMayBeSubtype(t, typeName, [t.name])) return true;
		return false;
	}

	/**
	 * Whether collapsing `owner`'s property `prop` could break a subtype — the precise,
	 * per-property replacement for the blanket `hasSubtype` gate the accessor-collapse checks use.
	 * True when any indexed type declaring `get_<prop>` / `set_<prop>` / `<prop>` is a PROVEN
	 * transitive subtype of `owner` (its accessor override / property redeclaration would be
	 * stranded by the collapse), or OVERRIDES an accessor that cannot be attributed away from
	 * `owner`. An override is attributed by resolving the declaration it overrides
	 * (`overriddenDeclarer`) — a type overriding some OTHER hierarchy's same-named property never
	 * blocks, however unresolvable its own ancestry is above that declaration, and the declaring
	 * type is itself visited by this same loop, so a real override of `owner` still blocks through
	 * it. Only when no declaration resolves does the walk fall back to `provablyNotSubtype`, which
	 * keeps an unresolvable hierarchy blocked conservatively. A FRESH (non-override) same-named
	 * member never blocks: an unrelated class merely sharing the property name leaves the collapse
	 * alone. False when no subtype touches the property (or `owner` has none). Names are SIMPLE, so
	 * a same-named unrelated type is the residual soundness boundary, as in `isSubtype`.
	 */
	public function subtypeOverridesProperty(owner: String, prop: String): Bool {
		final names: Array<String> = ['get_$prop', 'set_$prop', prop];
		for (fi in _files) for (t in fi.types) if (t.name != owner) {
			final matches: Array<MemberInfo> = t.members.filter(m -> names.contains(m.name));
			if (matches.length == 0) continue;
			if (isSubtype(t.name, owner)) return true;
			if (!matches.exists(m -> m.isOverride)) continue;
			final declarer: Null<String> = overriddenDeclarer({ file: fi, type: t }, names, owner);
			if (declarer != null) {
				if (declarer == owner) return true;
				continue;
			}
			if (!provablyNotSubtype(t.name, owner)) return true;
		}
		return false;
	}

	/**
	 * The PROVEN override family of `owner.member` — every type that redeclares it and is provably a
	 * subtype, each paired with its file and declaration offset. The ACTIONABLE counterpart of
	 * `subtypeDeclaresMember` / `subtypeOverridesProperty`, and deliberately not the same set: those
	 * two answer a VETO, where being over-broad is the safe direction, so they say yes on an
	 * unresolvable hierarchy. Handing that set to an editor would rewrite unrelated same-named
	 * members, so the imprecision is split out of the result instead of folded into it:
	 *
	 * - `null` — a same-named declaration exists whose relation to `owner` is UNPROVABLE (no ancestor
	 *   declares the member and the type is not provably unrelated). The caller must refuse the whole
	 *   rename; a partial family is worse than none.
	 * - `[]` — no other type declares the member. The rename is the base's alone.
	 * - non-empty — exactly the members that must be renamed with the base.
	 *
	 * Membership is NOT gated on the override modifier: a Haxe implementation of an `abstract` or
	 * interface method carries no `override` keyword and is still a real override. What proves
	 * membership is the subtype relation (`isSubtype`) or the resolved declaration the member
	 * overrides (`overriddenDeclarer`) naming `owner`.
	 */
	public function overrideFamilyOf(owner: String, member: String): Null<Array<OverrideFamilyMember>> {
		final family: Array<OverrideFamilyMember> = [];
		// Whether the owner's own declaration can be implemented WITHOUT the override modifier: an
		// interface member, or an `abstract` method on an abstract class. Unknown owner reads as yes.
		final ownerKind: Null<String> = ownerDeclKind(owner);
		final bareImplementable: Bool = ownerKind == null || BARE_IMPLEMENTABLE_OWNER_KINDS.contains(ownerKind);
		for (fi in _files) for (t in fi.types) if (t.name != owner) {
			final decl: Null<MemberInfo> = t.members.find(m -> m.name == member);
			if (decl == null) continue;
			final entry: OverrideFamilyMember = { file: fi.file, typeName: t.name, declFrom: decl.declFrom };
			if (isSubtype(t.name, owner)) {
				family.push(entry);
				continue;
			}
			// The declaration this one overrides, resolved through the written supertype paths: a type
			// overriding some OTHER hierarchy's same-named member is not family, however unresolvable
			// its own ancestry is above that declaration.
			final declarer: Null<String> = overriddenDeclarer({ file: fi, type: t }, [member], owner);
			if (declarer != null) {
				if (declarer == owner) family.push(entry);
				continue;
			}
			// Neither proven in nor proven out. Before failing closed, one exclusion that costs nothing:
			// a redeclaration missing the OVERRIDE modifier is a compile error under a plain-class owner,
			// so such a type is no family candidate whatever its ancestry says. Without it the refusal is
			// near-universal in a framework tree — every class extends a library type the scope cannot
			// resolve, so `provablyNotSubtype` fails for every unrelated namesake as well.
			if (!decl.isOverride && !bareImplementable) continue;
			if (!provablyNotSubtype(t.name, owner)) return null;
		}
		return family;
	}

	/**
	 * Whether `matches` holds for ANY (transitive) subtype of `owner`, given that subtype's
	 * whole source, its raw declaration span, and whether it REDECLARES `field` (shadowing
	 * the inherited member). True without consulting `matches` when the hierarchy is
	 * unresolvable: a subtype whose source was not retained, or a second type carrying
	 * `owner`'s own simple name. The predicate separates the callers, including what a
	 * redeclaration means to each — `subtypeReferencesField` reads it as "this mention is
	 * not about the inherited field", a finalization check as "an ambiguously-named member
	 * is exactly what I cannot rule out".
	 */
	public function subtypeDeclMatches(
		owner: String, field: String, matches: (subtype:String, source:String, span:Span, redeclares:Bool) -> Bool
	): Bool {
		final closure: Array<String> = [owner];
		var i: Int = 0;
		while (i < closure.length) {
			final parent: String = closure[i++];
			for (sub in subtypesOf(parent)) {
				final t: TypeDeclInfo = sub.type;
				// A SECOND type carrying `owner`'s own simple name extending into this closure: the
				// index keys types by simple name and cannot tell the two hierarchies apart.
				if (t.name == owner) return true;
				// Dedupe the WALK by name, not the predicate: two distinct types can share a
				// simple name, and each carries its own declaration slice. Expanding a name
				// twice would loop; skipping the second one's slice silently drops evidence.
				if (!closure.contains(t.name)) closure.push(t.name);
				final src: Null<String> = _sources[sub.file.file];
				if (src == null || matches(t.name, src, t.span, t.members.exists(m -> m.name == field))) return true;
			}
		}
		return false;
	}

	/**
	 * Every simple member name declared by a type in `owner`s transitive SUBTYPE closure.
	 * `prefer-inline` reads it as a veto list: a method whose name a subtype redeclares must stay
	 * physical, since inlining would bind the call statically and skip the override.
	 *
	 * The walk is `eachSubtype`, the memoised subtype adjacency expanded outward from `owner`.
	 * The consumer used to ask this question by scanning EVERY type in the index and testing
	 * `isSubtype` on each, which is one supertype-closure walk per type per class -
	 * O(classes x types) over a corpus, plus an
	 * `allFiles()` array COPY per class. Measured with `lint --rule prefer-inline` over a haxelib
	 * prefix: 8.4s / 500 files, 11.5s / 1000, 49.9s / 2000, 322.5s / 4000, against a ~25s parse
	 * baseline at 4000. The adjacency walk visits only the closure.
	 *
	 * Name-keyed like every other index query: two distinct types sharing one simple name both
	 * expand. That can only ADD names to the veto list, which is the conservative direction for
	 * the consumer - the same trade `subtypeDeclMatches` makes.
	 */
	public function subtypeMemberNames(owner: String): Array<String> {
		final out: Array<String> = [];
		eachSubtype(owner, sub -> if (sub.type.name != owner) for (m in sub.type.members) if (!out.contains(m.name)) out.push(m.name));
		return out;
	}

	/**
	 * The whole index projected as a supertype graph over SIMPLE names: a name -> every simple name
	 * that ANY declaration of it lists in `extends` / `implements`. The union is what makes the map
	 * answerable at all, since two files may declare the same simple name and neither is more
	 * authoritative than the other from here; a consumer reads a reachable edge as "SOME declaration
	 * of this name extends that one".
	 *
	 * The arrays are the index's own and callers must not write to them — they hold COPIES of each
	 * `TypeDeclInfo.supertypes`, never that array itself, so appending here would rewrite the index
	 * for every later reader of that type.
	 *
	 * Built ONCE per instance, like `_subtypeAdjacency` and for the same reason: the index is
	 * immutable after construction. The map used to be rebuilt inside the caller, per CALL — a
	 * whole `allFiles()` x `types` walk per method the naming carve-outs asked about, which is one
	 * per test method on a test-heavy tree (measured: 2.1s of a 95s project lint).
	 */
	public function supertypeNameUnion(): Map<String, Array<String>> {
		var names: Null<Map<String, Array<String>>> = _supertypeNames;
		if (names != null) return names;
		names = [];
		for (f in _files) for (t in f.types) {
			final known: Null<Array<String>> = names[t.name];
			if (known == null)
				names[t.name] = t.supertypes.copy()
			else
				for (s in t.supertypes) if (!known.contains(s)) known.push(s);
		}
		_supertypeNames = names;
		return names;
	}

	/**
	 * Whether EVERY supertype reference of `typeName`, transitively, names a declaration this
	 * index holds. `supertypeDeclaresMember` answers `false` both when no ancestor declares the
	 * member and when an ancestor is not indexed at all, and only the FIRST reading is a proof —
	 * a consumer that must prove the ABSENCE of an inherited member (an expected-type rewrite,
	 * which a shadowing field silently redirects) has to ask this too. Walks the same simple-name
	 * hops `supertypeDeclares` walks, so the two agree about which links exist; `supertypes`
	 * carries `implements` targets as well as `extends`, so an unindexed interface refuses
	 * too — and so does a `typeName` the index holds no declaration for at all, the same absence one
	 * hop earlier.
	 */
	public function supertypeChainResolved(typeName: String): Bool {
		return supertypeChainWalk(typeName, []);
	}

	/**
	 * Every FILE declaring a type in `owner`s transitive SUBTYPE closure. The walk is the
	 * memoised subtype adjacency (`subtypesOf`), so it answers about the SAME hierarchy every
	 * other subtype query does — alias hops included, which a hand-rolled
	 * `supertypes.contains(parent)` scan over `allFiles()` cannot see. `TrivialGetter` ran
	 * exactly that scan to decide which files its collapse must LOOK AT, and through `import
	 * p.Owner as O` it looked at only the owner: the subtype's `_v` references were left naming
	 * a field that no longer existed and the tree failed with `Unknown identifier : _v`. (Looking
	 * is not rewriting — through an alias the scan now reaches the subtype and the collapse
	 * WITHHOLDS, because `isSubtype`'s upward walk still cannot resolve the alias.)
	 *
	 * The closure walk and its name dedup are `eachSubtype`'s; the FILES are deduped by path —
	 * a file is collected for every subtype it declares, so a second same-named subtype in
	 * another file is not silently dropped from the answer, and neither is a subtype that happens
	 * to carry `owner`s OWN simple name (the walk seeds its closure with `owner`, so a
	 * name-guarded push would have skipped exactly that one).
	 *
	 * Name-keyed like every other index query, so the result over-approximates. That is the safe
	 * direction even for a caller that EDITS the files it gets back, not merely reads them:
	 * every occurrence in them is re-gated per site by `isSubtype`, which a homonym cannot pass
	 * (`closureContains` refuses an ambiguous simple name outright), so a spurious file can only
	 * ever add a refusal — never an edit.
	 */
	public function subtypeFiles(owner: String): Array<String> {
		final out: Array<String> = [];
		eachSubtype(owner, sub -> if (!out.contains(sub.file.file)) out.push(sub.file.file));
		return out;
	}

	/**
	 * Call `visit` for every declaration in `owner`s transitive SUBTYPE closure, expanding
	 * outward over the memoised adjacency (`subtypesOf`). The WALK is deduped by simple name —
	 * two distinct types sharing one expand once, which is what terminates it — while `visit`
	 * sees every declaration, since each carries its own file and its own members and skipping
	 * the second one's would silently drop evidence. `owner` itself is visited whenever some
	 * type in the closure names it; a collector that must exclude it says so.
	 *
	 * The shared seat of `subtypeMemberNames` and `subtypeFiles`, which differ only in what they
	 * collect. `subtypeDeclMatches` keeps its own copy: it answers by RETURNING out of the walk.
	 */
	private function eachSubtype(owner: String, visit: ResolvedType -> Void): Void {
		final closure: Array<String> = [owner];
		var i: Int = 0;
		while (i < closure.length) {
			final parent: String = closure[i++];
			for (sub in subtypesOf(parent)) {
				if (!closure.contains(sub.type.name)) closure.push(sub.type.name);
				visit(sub);
			}
		}
	}

	/** The SIMPLE-name lookup of a type's declaration kind, or null when the scope declares it zero or ambiguously many times. */
	private function ownerDeclKind(owner: String): Null<String> {
		final ds: Array<TypeDeclInfo> = _refs.declsNamed(owner);
		return ds.length == 1 ? ds[0].kind : null;
	}

	/**
	 * Whether `t` MAY be a transitive subtype of `target`. Deliberately NOT `isSubtype`: that one
	 * re-resolves a link by SIMPLE NAME and answers `false` when several types share it, which is
	 * the safe default only for a caller that acts on `true` (`redundant-upcast` rewrites a cast,
	 * `naming` rebinds an occurrence). Every caller of `subtypeDeclaresMember` reads `true` as
	 * "bail out" instead, so it needs the opposite default: an AMBIGUOUS link is a MAY. Two other
	 * differences follow from starting at the declaration rather than its name — the root type is
	 * never ambiguous (we hold it), and only a genuinely ambiguous ANCESTOR link goes conservative.
	 * A link naming no indexed type is skipped, as in `isSubtype`: it cannot be `target`, which is
	 * indexed by construction.
	 */
	private function declMayBeSubtype(t: TypeDeclInfo, target: String, seen: Array<String>): Bool {
		for (sup in t.supertypes) {
			if (sup == target) return true;
			if (seen.contains(sup)) continue;
			seen.push(sup);
			final ds: Array<TypeDeclInfo> = _refs.declsNamed(sup);
			if (ds.length != 1) {
				if (ds.length > 1) return true;
				continue;
			}
			if (declMayBeSubtype(ds[0], target, seen)) return true;
		}
		return false;
	}

	/**
	 * Every indexed type extending / implementing `parent` — under that name or under any
	 * TYPEDEF or IMPORT alias of it — paired with its declaring file. The memoised form of a
	 * full `_files` x `types` scan, in the same order that scan visited. Empty when nothing
	 * names `parent`. The whole adjacency is built on first use; the index is immutable after
	 * construction, so one build per instance is sound. The returned array is the LIVE bucket,
	 * not a copy — read it, never mutate it, or the memo is corrupted for every later caller.
	 *
	 * The alias walk is not a refinement, it is the difference between an answer and a wrong one.
	 * `class Bad extends U` where `typedef U = Util` writes `U` in `supertypes`, so keying on the
	 * WRITTEN name alone reported `Util` as having no subtype — on a fully parseable tree, no
	 * skip-parse involved — and every consumer of that answer is a VETO: `unused-private` then
	 * proposed deleting `Util`'s private constructor, which `Bad`'s `super()` calls (measured:
	 * `--fix` deleted it, and the tree stopped compiling with `Util does not have a constructor`).
	 * Filing the subtype under both names is the conservative direction for all four consumers —
	 * `hasSubtype`, `subtypeDeclMatches`, `subtypeMemberNames`, `familyDeclaresEveryMember` — so
	 * the change can only ever WITHHOLD, never propose.
	 *
	 * Four alias shapes are closed and the walk is transitive over all of them, in either
	 * order: one hop (`typedef U = Util`), a chain (`typedef A = B; typedef B = Util`), a
	 * target written QUALIFIED or living in another module (`typedef C = pkg.Util`), since
	 * `aliasTargetNominal` is already the simple name — and an IMPORT alias
	 * (`import pkg.Util as U;`), whose path the grammar keeps out of the node entirely and
	 * which `ImportInfo.aliasTarget` now carries, decoded from the statement source by
	 * `ModuleScan.aliasTargetOf`. That decoder was already the ONLY one reading an alias
	 * import's path (the same-named `MapScopeScan.aliasTargetOf` answers about a TYPEDEF's
	 * underlying, from the AST), so this is its second caller rather than a second copy.
	 * Import aliases are per-FILE, so the hop is read from the file the SUBTYPE is declared
	 * in. It is applied to every name in the closure, not only the written one, so a name
	 * that arrived through ANOTHER file's typedef edge is also offered to this file's
	 * aliases — an over-approximation, in the withholding direction the paragraph above
	 * describes. A `#if` region binding ONE alias name to DIFFERENT targets carries BOTH:
	 * the dedup key an alias statement gets includes the path it binds, so no branch is
	 * dropped as a duplicate of another, and `importAliasEdges` maps an alias to an ARRAY.
	 * Keyed on the name alone the first branch won and the other compilation's supertype
	 * was left with no subtype — compile-proved: `unused-private --fix` then deleted its
	 * private constructor and the non-js build stopped at `p.Second does not have a
	 * constructor`. One shape is still NOT closed:
	 *
	 *  - a `#if`-GUARDED `typedef` — `aliasTargetNominal` is deliberately null for one, because
	 *    every branch projects under one `Conditional` and following the indexed branch would
	 *    commit to whichever happened to be first and be wrong for the other compilation. The
	 *    IMPORT-alias twin of that shape IS closed, above — a typedef has no statement text
	 *    to key a branch apart by, which is the whole difference.
	 *
	 * An ABSTRACT over the type (`abstract A(Util)`) is not a gap: Haxe gives it no `extends`, no
	 * `super()` and no access to the underlying type's privates, so the ctor really is dead there
	 * (verified — deleting it compiles).
	 */
	private function subtypesOf(parent: String): Array<ResolvedType> {
		var adjacency: Null<Map<String, Array<ResolvedType>>> = _subtypeAdjacency;
		if (adjacency == null) {
			adjacency = [];
			final aliases: Map<String, Array<String>> = aliasEdges();
			for (fi in _files) {
				// An `import pkg.Util as U;` binds `U` in THIS file and nowhere else, so its hop is
				// read off the file's own imports rather than from the project-wide `aliasEdges` a
				// `typedef` earns. It is consulted inside the walk, not only on the written name, so
				// the two alias kinds compose in either order.
				final importAliases: Map<String, Array<String>> = TypeRefIndex.importAliasEdges(fi, true);
				for (t in fi.types) {
					// A type naming one simple name TWICE (two differently-qualified supertypes reducing to
					// it) lands in that bucket once — `supertypes.contains` reported it once per scan too.
					// `named` doubles as the alias walk's worklist AND its cycle guard: a `typedef A = B;
					// typedef B = A` pair stops when the closure comes back round to a name already filed.
					final named: Array<String> = [];
					for (sup in t.supertypes) {
						var pending: Int = named.length;
						if (!named.contains(sup)) named.push(sup);
						while (pending < named.length) {
							final denoted: String = named[pending++];
							final bucket: Array<ResolvedType> = adjacency[denoted] ?? [];
							bucket.push({ file: fi, type: t });
							adjacency[denoted] = bucket;
							for (target in aliases[denoted] ?? []) if (!named.contains(target)) named.push(target);
							for (imported in importAliases[denoted] ?? []) if (!named.contains(imported)) named.push(imported);
						}
					}
				}
			}
			_subtypeAdjacency = adjacency;
		}
		return adjacency[parent] ?? [];
	}

	/**
	 * Typedef ALIAS edges across the whole index: an alias declaration's simple name -> every
	 * simple name it re-points at, its target's own IMPORT alias in the declaring file included
	 * (`typedef Hop = L;` beside `import pkg.Leaf as L;` re-points at `Leaf`). NOT memoised,
	 * and does not need to be — its one caller is inside `subtypesOf`'s `adjacency == null`
	 * block, which runs at most once per instance.
	 *
	 * A name maps to an ARRAY because the index is keyed by simple name and two packages may each
	 * declare `U`; unioning their targets over-approximates in the same direction the rest of the
	 * index does, and every consumer of the adjacency reads it as a veto.
	 */
	private function aliasEdges(): Map<String, Array<String>> {
		final edges: Map<String, Array<String>> = [];
		for (fi in _files) {
			// A `typedef Hop = L;` whose `L` is an `import pkg.Leaf as L;` re-points at `Leaf`. The
			// alias binds per FILE, so the hop is read where the typedef is WRITTEN — not where its
			// name is later extended, which is a different file with different imports.
			final importAliases: Map<String, Array<String>> = TypeRefIndex.importAliasEdges(fi, true);
			for (t in fi.types) {
				// Null for every non-alias declaration, for an anon-struct typedef (its fields ARE its
				// members) and for an alias the builder could not read as a nominal path.
				final target: Null<String> = t.aliasTargetNominal;
				if (target == null || target == t.name) continue;
				final bucket: Array<String> = edges[t.name] ?? [];
				if (!bucket.contains(target)) bucket.push(target);
				for (imported in importAliases[target] ?? []) if (imported != t.name && !bucket.contains(imported)) bucket.push(imported);
				edges[t.name] = bucket;
			}
		}
		return edges;
	}

	/** Exactly one indexed decl is named `name`, and it is a class. */
	private function isUniqueClass(name: String): Bool {
		final ds: Array<TypeDeclInfo> = _refs.declsNamed(name);
		return ds.length == 1 && ds[0].kind == SymbolIndex.CLASS_DECL_KIND;
	}

	/**
	 * Whether `name`'s transitive supertype closure is FULLY index-resolved AND excludes
	 * `target`. A supertype name absent or ambiguous in the index (an external type, or a
	 * project file not in the set) makes the relation unknown → false, as does reaching
	 * `target` itself, as does an ALIASING decl at the walk's ROOT (see `ALIASING_DECL_KINDS`
	 * — its empty `supertypes` would "exclude" the target vacuously). A supertype LINK that
	 * resolves to an abstract is stepped over rather than doubted (`supertypeLinkIsAbstract`):
	 * no `extends` / `implements` clause can name one, so it is not an inheritance edge.
	 * `seen` guards cycles. Read only as a NEGATIVE proof: every doubt yields false.
	 */
	private function closureExcludes(name: String, target: String): Bool {
		final ds: Array<ResolvedType> = _refs.resolvedDeclsNamed(name);
		return ds.length == 1 && closureExcludesFrom(ds[0], target, []);
	}

	/**
	 * `closureExcludes` over a RESOLVED start: every supertype edge is taken from its VERBATIM
	 * written reference and resolved against `cur`'s own file (`resolveTypeRef`), so a supertype
	 * whose simple name another package reuses reaches the type actually in scope instead of
	 * failing the proof. An edge resolving to zero OR several decls is refused identically — the
	 * closure is then not fully enumerated and `target`'s absence is not proven.
	 */
	private function closureExcludesFrom(cur: ResolvedType, target: String, seen: Array<String>): Bool {
		if (!_refs.markSeen(cur, seen)) return true;
		// An ALIAS (`typedef A = C`, a `@:forward` abstract) reaches other types through `@:from` /
		// `@:to` edges the closure cannot follow, so its own supertype list proves nothing. An
		// ANONYMOUS STRUCTURE has no such edges — its only inheritance links are the `> Base`
		// structural extensions already in `supertypesRaw`, and a structure can never be a subtype
		// of a class — so the closure over it IS complete and the refusal does not apply.
		if (ALIASING_DECL_KINDS.contains(cur.type.kind) && !cur.type.isAnonStruct) return false;
		for (raw in cur.type.supertypesRaw) {
			final anc: Null<ResolvedType> = _refs.resolveTypeRef(raw, cur.file);
			if (anc == null) return false;
			final ancestor: ResolvedType = anc;
			if (ancestor.type.name == target) return false;
			// An ABSTRACT reached through a supertype link is stepped over rather than doubted:
			// Haxe refuses an abstract in `extends` / `implements`, so the only way one lands in
			// `supertypesRaw` is an `implements Dynamic<T>` field-access directive (openfl's
			// `DisplayObject` carries one inside a dead `#if` branch, which the branch-blind
			// supertype scan records like any other). Nothing is reachable through such a link.
			// Only the LINK is stepped over — an abstract at the walk's ROOT keeps the
			// `ALIASING_DECL_KINDS` refusal above, whose `@:forward` / `@:to` edges a caller
			// attributing member occurrences must not lose.
			if (ancestor.type.kind == ABSTRACT_DECL_KIND) continue;
			if (!closureExcludesFrom(ancestor, target, seen)) return false;
		}
		return true;
	}

	/** Whether `target` appears in `name`'s transitive supertype closure. `seen` guards cycles. */
	private function closureContains(name: String, target: String, seen: Array<String>): Bool {
		final ds: Array<ResolvedType> = _refs.resolvedDeclsNamed(name);
		if (ds.length != 1) return false;
		final decl: ResolvedType = ds[0];
		// `denoted` is every name this declaration's supertype list can be spelling, and doubles as
		// the hop worklist AND its cycle guard, exactly as `subtypesOf`s `named` does. `supertypes`
		// belongs to the shared index, so the copy is load-bearing.
		final denoted: Array<String> = decl.type.supertypes.copy();
		// A `typedef U = Base;` names its target where the typedef is WRITTEN, so the hop for THIS
		// declaration is its own `aliasTargetNominal`, read one recursion deeper than the name that
		// denoted it — no project-wide map is needed for it. Null for a guarded typedef, which is
		// where the two alias kinds agree to fail closed (see `importAliasEdges`).
		final hop: Null<String> = decl.type.aliasTargetNominal;
		if (hop != null && hop != name) denoted.push(hop);
		if (denoted.length == 0) return false;
		// `false`: going UP, this answer is read affirmatively by autofixes that delete, so a `#if`
		// region binding one alias name to two modules must not make this type a subtype of both.
		final aliases: Map<String, Array<String>> = TypeRefIndex.importAliasEdges(decl.file, false);
		var i: Int = 0;
		while (i < denoted.length) {
			final written: String = denoted[i++];
			if (written == target) return true;
			for (aliased in aliases[written] ?? []) if (!denoted.contains(aliased)) denoted.push(aliased);
			if (seen.contains(written)) continue;
			seen.push(written);
			if (closureContains(written, target, seen)) return true;
		}
		return false;
	}

	/**
	 * The nearest ancestor of `start` declaring any of `names` — the type whose member an `override`
	 * on `start` actually overrides — or null when no ancestor declares one (an ancestor outside the
	 * index ends its branch silently, so null means "unknown", never "none"). Only `extends` edges are
	 * walked: Haxe grants `override` against a SUPERCLASS member, never against an interface's, so
	 * attributing an override to an interface that merely names the same member would drop a real
	 * superclass link the index could not resolve. Resolution is import-aware (`supertypesRaw` +
	 * `resolveTypeRef`), so it answers for the SINGLE written supertype rather than unioning every
	 * same-simple-name decl, and it needs only the chain up to the declaring type — an unindexed
	 * ancestor ABOVE that one cannot make it fail. When several ancestors at the same distance declare
	 * a name, `owner` wins: the caller reads a match against `owner` as "blocked", the conservative side.
	 */
	private function overriddenDeclarer(start: ResolvedType, names: Array<String>, owner: String): Null<String> {
		final seen: Array<String> = [];
		var level: Array<ResolvedType> = [start];
		while (level.length > 0) {
			final next: Array<ResolvedType> = [];
			for (cur in level) if (_refs.markSeen(cur, seen)) {
				for (i in 0...cur.type.supertypesRaw.length) {
					if (i < cur.type.supertypes.length && cur.type.interfaces.contains(cur.type.supertypes[i])) continue;
					final anc: Null<ResolvedType> = _refs.resolveTypeRef(cur.type.supertypesRaw[i], cur.file);
					if (anc != null) next.push(anc);
				}
			}
			final declarers: Array<ResolvedType> = next.filter(a -> a.type.members.exists(m -> names.contains(m.name)));
			if (declarers.exists(a -> a.type.name == owner)) return owner;
			if (declarers.length > 0) return declarers[0].type.name;
			level = next;
		}
		return null;
	}

	/**
	 * `supertypeChainResolved`'s cycle-guarded recursion. A name the index holds NO declaration for
	 * answers false — that is the whole question, and answering it here is what lets the recursive
	 * call stand alone where the caller used to test the next hop itself. A name already visited
	 * answers true: whatever made it unresolvable was reported by the visit that pushed it, and a
	 * false short-circuits the entire walk, so no later `seen` hit can mask one.
	 */
	private function supertypeChainWalk(typeName: String, seen: Array<String>): Bool {
		if (seen.contains(typeName)) return true;
		seen.push(typeName);
		final decls: Array<TypeDeclInfo> = _refs.declsNamed(typeName);
		if (decls.length == 0) return false;
		for (t in decls) for (sup in t.supertypes) if (!supertypeChainWalk(sup, seen)) return false;
		return true;
	}

}
