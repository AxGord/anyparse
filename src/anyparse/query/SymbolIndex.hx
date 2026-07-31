package anyparse.query;

import anyparse.runtime.Span;

using Lambda;

/**
 * The four import-statement forms a Haxe file may carry, distinguished
 * structurally so a consumer can decide which forms participate in a
 * symbol move / rewrite. Modelled as a zero-cost `enum abstract(Int)`
 * because the kind carries no associated data.
 *
 *  - `Import` — `import pkg.Module;` / `import pkg.Module.SubType;`.
 *  - `Alias`  — `import pkg.Module as U;` (the original path is NOT
 *    exposed by the grammar — only the alias is in the node's name
 *    slot, a known limitation; `raw` therefore holds the alias).
 *  - `Wild`   — `import pkg.*;` (the `raw` slot holds `pkg.*`).
 *  - `Using`  — `using pkg.Module;`.
 */
enum abstract ImportKind(Int) {

	final Import = 0;
	final Alias = 1;
	final Wild = 2;
	final Using = 3;

}

/**
 * One import / using statement extracted from a file's declarations. `raw`
 * is the verbatim payload the grammar exposes for the kind (the dotted path
 * for `Import` / `Using`, the alias for `Alias`, `pkg.*` for `Wild`); `alias`
 * is the bound alias when the kind is `Alias`, else null; `span` is the
 * statement's source range.
 *
 * `guarded` is true when the statement was LIFTED out of a `#if ... #end`
 * region rather than written at the file top level. It participates in type
 * resolution like any other import (it genuinely brings a name into scope
 * under its guard), but a consumer that MUTATES on the basis of an import —
 * placing a fresh import after the last one (`MoveSymbol`), or deleting an
 * unreferenced one (`unused-import`) — must treat it specially: its position
 * is inside a conditional region, and its "unused" verdict is unverifiable
 * because usage is `#if`-conditional while the reference scan is branch-blind.
 */
typedef ImportInfo = {
	var raw: String;
	var kind: ImportKind;
	var alias: Null<String>;
	var span: Span;
	var guarded: Bool;
}

/**
 * One top-level type declaration. `kind` is the grammar's decl-node
 * kind string (`ClassDecl` / `InterfaceDecl` / `EnumDecl` /
 * `TypedefDecl` / `AbstractDecl`); `isMain` is true when the type's
 * name equals the file basename — i.e. it is the module's main type,
 * importable as `import <package>.<Basename>;`.
 */
typedef MemberInfo = {
	/** The member's name. */
	var name: String;

	/** True when the member is a property whose READ accessor is a getter (`get` / `dynamic`) — reading it runs code. A plain field / method is false. */
	var hasGetter: Bool;

	/** True when the member is a property whose WRITE accessor is a setter (`set` / `dynamic`) - writing it runs code. A plain field / final / `(default|null|never)` write slot is false (no set-accessor). */
	var hasSetter: Bool;

	/** The member's return type OUTER nominal (last `.` segment, `Null<T>` → `Null`), or null for a field / `Void` / unannotated return. Drives cross-file `Null<T>`-return nullable-source resolution. */
	var returnNominal: Null<String>;

	/** The member's VERBATIM declared type SOURCE — the written `:Type` text (`Null<T>` preserved), or null for an unannotated / inference-typed / function member (whose annotation is a `returnType`, not a `type`). Drives cross-file `Type.staticField` read-type resolution. */
	var typeSource: Null<String>;

	/** The member's EXPLICIT visibility keyword as WRITTEN (`public` / `private`), or null when its modifier run carries none. Drives cross-file override-visibility resolution. */
	var visibility: Null<String>;

	/** True when the member's modifier run carries the grammar's override modifier — an unmarked override's effective visibility comes from the supertype, not the container default. */
	var isOverride: Bool;
};

/**
 * A cross-file index entry for one top-level type: its `name` / `kind` / `span`, whether it is the module `isMain` type, its direct `supertypes` and `members`, and `isAnonStruct`. Feeds cross-file-safe rename and move-symbol gates.
 */
typedef TypeDeclInfo = {
	var name: String;
	var kind: String;
	var span: Span;
	var isMain: Bool;

	/**
	 * The number of type parameters written on the declaration header
	 * (`class Box<T, U>` → 2; 0 = non-generic). Drives bare-`new` local-type
	 * annotation: an arity-0 type's written name IS its complete type.
	 */
	var typeParamArity: Int;

	/**
	 * Simple names (last `.` segment) of this type's `extends` / `implements`
	 * targets — its direct supertypes. Drives `hasSubtype`, the first gate of a
	 * cross-file-safe private-member rename (a subtype could access the member).
	 */
	var supertypes: Array<String>;

	/**
	 * The VERBATIM written names of this type's `extends` / `implements` targets
	 * (qualified when written qualified), parallel to `supertypes`. Preserves the
	 * dotted path a simple-name reduction loses, so a supertype reference can be
	 * resolved to a SINGLE declaring type — import / qualified-path aware — rather
	 * than unioned across every same-simple-name decl. Drives
	 * `inheritsMemberUnambiguously`.
	 */
	var supertypesRaw: Array<String>;

	/**
	 * Simple names (last `.` segment) of the type's `implements` targets ONLY — the
	 * interfaces it declares itself to satisfy, a subset of `supertypes` excluding the
	 * `extends` superclass / super-interfaces. Drives the interface-mutability gate: a
	 * field whose name an implemented interface declares as a member is pinned to that
	 * interface's property access and cannot become `final`.
	 */
	var interfaces: Array<String>;

	/** True when this is a `typedef X = {…}` anonymous struct — its fields can never be properties, so field access on it is side-effect-free. */
	var isAnonStruct: Bool;

	/**
	 * The SIMPLE outer nominal a plain `typedef T = <Target>;` re-points at (`Widget`,
	 * `pkg.Deep.Thing` -> `Thing`, `Array<Int>` -> `Array`), or null for every other decl AND
	 * for an alias the builder could not read as a nominal path (a function type, a constraint
	 * form). Read from source because the projection carries no alias link: a `TypedefDecl`
	 * naming another type has NO children. Null must be read as "not resolvable", never as
	 * "aliases nothing" — an alias whose target is unknown hosts unknown members.
	 */
	var aliasTargetNominal: Null<String>;

	/**
	 * True when the type declaration carries `@:rtti` metadata directly. Such a
	 * class is serialized by reflecting on its runtime field NAMES (e.g. drill
	 * Node), so a naming autofix must not rename its fields. Feeds
	 * `transitivelyCarriesRtti` for the subtype-ward serialization guard.
	 */
	var hasRtti: Bool;

	/** This type's directly-declared members (name + getter-property flag), for type-aware purity. */
	var members: Array<MemberInfo>;

	/**
	 * True for an `abstract` declaration that may REBIND its underlying `this` — it either writes
	 * `this` in a member OTHER than the constructor (a non-`new` `this =` compiles only in an
	 * `inline` member, and calling such a writer on a `final` binding is a transitive compile error),
	 * or carries a `@:build` / `@:autoBuild` macro that could generate an invisible such member
	 * (conservative). Always false for a non-abstract kind — its methods mutate the instance, never
	 * the binding.
	 */
	var abstractSelfRebind: Bool;

	/**
	 * The SIMPLE name of a `@:forward` abstract's underlying type (its first `Named` child), or null
	 * when the decl is not a `@:forward` abstract. `@:forward` routes method calls to the underlying,
	 * so whether such a call can rebind the binding is decided by the underlying: a class underlying
	 * mutates the object (final-safe), an abstract underlying recurses. Null for every non-forward or
	 * non-abstract decl.
	 */
	var abstractForwardUnderlying: Null<String>;
};
/**
 * A cross-file index entry for one source file: its `file` path, `pkg` / `module`, `imports`, declared `types`, and `accessGrants` (types it `@:access(...)`-grants itself private reach into). The unit `SymbolIndex` aggregates.
 */
typedef FileInfo = {
	var file: String;
	var pkg: String;
	var module: String;
	var imports: Array<ImportInfo>;
	var types: Array<TypeDeclInfo>;

	/**
	 * Simple names of every type referenced in an `@:access(...)` metadata in
	 * this file — types this file grants itself private access to. Drives
	 * `hasAccessGrant`, the second gate of a cross-file-safe private-member rename.
	 */
	var accessGrants: Array<String>;
}

/** A type declaration paired with its declaring file, for the inheritance-resolution walk. */
private typedef ResolvedType = {
	var file: FileInfo;
	var type: TypeDeclInfo;
};

/**
 * The project-wide symbol index: a collection of per-file `FileInfo` records answering cross-file questions (which files declare a type, its import path, subtype / access-grant reachability) that a single-file parse cannot. Built once and queried by rename / move ops and type-aware checks.
 */
@:nullSafety(Strict)
final class SymbolIndex {

	/** The grammar kind a `class` declaration projects as. */
	private static final CLASS_DECL_KIND: String = 'ClassDecl';

	/** The grammar kind a `typedef` declaration projects as — the only member host whose members sit under an `Anon`. */
	private static final TYPEDEF_DECL_KIND: String = 'TypedefDecl';

	/** The grammar kind an anonymous structure projects as, in BOTH a typedef body and a type expression. */
	/** The decl kinds free of implicit-conversion / aliasing semantics — see `resolvesToPlainNominal`. */
	private static final PLAIN_NOMINAL_KINDS: Array<String> = [CLASS_DECL_KIND, 'InterfaceDecl', 'EnumDecl'];

	/**
	 * The decl kinds whose `supertypes` is NOT their complete set of inheritance edges: a `typedef`
	 * ALIAS (`typedef A = C`) and an abstract (`abstract W(C)` with `@:forward` / `@:from` / `@:to`)
	 * each reach another type through a link no `extends` / `implements` clause records, and both
	 * are legal in an `extends` position. Their closure therefore looks EMPTY, which a
	 * negative-reachability proof would read as "excludes everything" — so `closureExcludes` refuses
	 * them outright. A POSITIVE proof (`closureContains`) needs no such guard: an unseen edge only
	 * makes it miss, which is its safe direction.
	 */
	private static final ALIASING_DECL_KINDS: Array<String> = ['TypedefDecl', 'AbstractDecl'];

	private final _files: Array<FileInfo>;
	private final _skipped: Array<String>;

	/** Per-file source text, retained so a subtype-ward body scan (`subtypeReferencesField`) can inspect a subtype's raw declaration span for a backing-field reference. */
	private final _sources: Map<String, String>;

	/**
	 * Lazily-built subtype adjacency: a supertype's SIMPLE name -> every `(file, type)` pair
	 * naming it in `supertypes`, in file / declaration order. The index is immutable after
	 * construction, so one build per instance is safe; it replaces a full `_files` x `types`
	 * rescan per closure level in the subtype walks.
	 */
	private var _subtypeAdjacency: Null<Map<String, Array<ResolvedType>>>;

	private function new(files: Array<FileInfo>, skipped: Array<String>, sources: Map<String, String>) {
		_files = files;
		_skipped = skipped;
		_sources = sources;
	}

	/** The `FileInfo` for `file`, or null when the file is not indexed. */
	public function fileInfo(file: String): Null<FileInfo> {
		return _files.find(f -> f.file == file);
	}

	/** Every indexed file's `FileInfo`, in input order. */
	public function allFiles(): Array<FileInfo> {
		return _files.copy();
	}

	/** Files that failed to parse and were excluded from the index. */
	public function skippedFiles(): Array<String> {
		return _skipped.copy();
	}

	/**
	 * Files declaring a top-level type named `typeName`. Length 0 / 1 /
	 * many is the ambiguity signal a move-symbol op tests before
	 * proceeding.
	 */
	public function declaringFiles(typeName: String): Array<FileInfo> {
		return _files.filter(f -> f.types.exists(t -> t.name == typeName));
	}

	/**
	 * The import path that names `typeName`, when EXACTLY ONE file
	 * declares it: the file's `module` when the type is the module's
	 * main type, else `module + '.' + typeName` (a sub-type). Null when
	 * zero or more than one file declares it — the path is ambiguous and
	 * a move cannot pick one without more context.
	 */
	public function importPathOf(typeName: String): Null<String> {
		final declarers: Array<FileInfo> = declaringFiles(typeName);
		if (declarers.length != 1) return null;
		final file: FileInfo = declarers[0];
		final type: Null<TypeDeclInfo> = file.types.find(t -> t.name == typeName);
		return type == null ? null : type.isMain ? file.module : '${file.module}.$typeName';
	}

	/**
	 * Files that import the module `modulePath` — an `ImportInfo` whose
	 * `raw` equals `modulePath` (the main type / module itself) OR
	 * starts with `modulePath + '.'` (a sub-type of the module, e.g.
	 * `anyparse.query.Refs.RefHit` for module `anyparse.query.Refs`).
	 *
	 * `Import`, `Alias` and `Using` kinds are considered: each carries a
	 * dotted path whose prefix can be compared. `Wild` (`pkg.*`) is
	 * skipped — its `raw` is a package-prefix glob, not a module path,
	 * so prefix-matching it against a module path is a different
	 * predicate left for a future package-prefix query. (`Alias` only
	 * matches when its exposed `raw` — the alias — coincides with the
	 * path, since the grammar does not expose the aliased original
	 * path; this is the documented alias limitation carried from
	 * `ImportInfo`.)
	 */
	public function filesImportingModule(modulePath: String): Array<FileInfo> {
		final prefix: String = '$modulePath.';
		return _files.filter(
			f -> f.imports.exists(imp -> imp.kind != ImportKind.Wild && (imp.raw == modulePath || StringTools.startsWith(imp.raw, prefix)))
		);
	}

	/**
	 * Does any indexed type extend / implement `typeName` (matched by simple
	 * name)? The first gate of a cross-file-safe private-member rename — a
	 * subtype could reference the member.
	 */
	public function hasSubtype(typeName: String): Bool {
		return subtypesOf(typeName).length > 0;
	}

	/**
	 * Does any indexed file grant itself `@:access(typeName)` (matched by simple
	 * name)? The second gate — such a file can read the type's private members.
	 */
	public function hasAccessGrant(typeName: String): Bool {
		return _files.exists(f -> f.accessGrants.contains(typeName));
	}

	/**
	 * Whether `matches` holds for the WHOLE source of any indexed file granting itself
	 * `@:access(typeName)`. The grant is file-scoped — every member of such a file reaches
	 * the type's privates — so the scan must be too, unlike the declaration-span scan a
	 * subtype gets. True without consulting `matches` when such a file's source was not
	 * retained. The precise counterpart of `hasAccessGrant`, for a caller that can say what
	 * it actually fears from a grantee rather than vetoing on the grant's existence.
	 */
	public function accessGrantMatches(typeName: String, matches: (source:String) -> Bool): Bool {
		for (fi in _files) if (fi.accessGrants.contains(typeName)) {
			final src: Null<String> = _sources[fi.file];
			if (src == null || matches(src)) return true;
		}
		return false;
	}

	/**
	 * Whether `name` occurs as a word-boundary identifier token in ANY indexed
	 * source, ignoring offsets inside `excludedSpan` of `excludedFile` (a member's
	 * own declaration). A raw-text scan (sees inside `#if` regions, comments and
	 * strings), so a `false` result proves `name` unreferenced in every branch of
	 * every indexed file — the cross-file zero-occurrence proof `unused-private`'s
	 * `--fix` uses to lift its whole-file conditional-compilation veto.
	 */
	public function nameOccursOutside(name: String, excludedFile: String, excludedSpan: Span): Bool {
		for (file => src in _sources) {
			final excluded: Array<Span> = file == excludedFile ? [excludedSpan] : [];
			if (RefactorSupport.referencedInRange(src, name, 0, src.length, excluded)) return true;
		}
		return false;
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
	 * Whether the abstract named `typeName` may REBIND its underlying `this` through a method call on
	 * a binding of it — the precise `final`-conversion gate, tri-state like the other name-keyed
	 * queries: `null` when NO indexed type declares the name (external / unknown), `false` when the name
	 * resolves only to declarations that provably cannot rebind (a non-abstract class, or an abstract
	 * whose only `this`-writes are in its constructor and whose `@:forward` — if any — reaches a
	 * non-rebinding underlying), `true` when a matching abstract may rebind. Conservative under a
	 * simple-name collision (a rebinding match wins) and under an unresolved `@:forward` underlying (a
	 * call it forwards could rebind). Resolution is by SIMPLE name (the index models no packages).
	 */
	public function abstractRebindsThis(typeName: String, abstractKinds: Array<String>): Null<Bool> {
		return abstractRebindsWalk(typeName, abstractKinds, []);
	}

	/**
	 * Whether type `typeName`'s member `field` is a getter-property (true → reading
	 * it runs code), a plain member (false → side-effect-free read), or not a known
	 * direct member (null). Conservative under ambiguity: any matching type whose
	 * `field` is a getter yields true.
	 */
	public function memberGetter(typeName: String, field: String): Null<Bool> {
		var found: Null<Bool> = null;
		for (fi in _files) for (t in fi.types) if (t.name == typeName) for (m in t.members) if (m.name == field) {
			if (m.hasGetter) return true;
			found = false;
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
	 * The single declaring file + decl span of the type named `typeName`, or null when
	 * zero or more than one file declares it (ambiguous — a write-confinement query
	 * cannot pin a unique decl range and must bail). The decl span is the type's full
	 * source range, used to tell an internal write from an external one.
	 */
	public function declarationSiteOf(typeName: String): Null<{ file: String, span: Span }> {
		final declarers: Array<FileInfo> = declaringFiles(typeName);
		if (declarers.length != 1) return null;
		final f: FileInfo = declarers[0];
		final t: Null<TypeDeclInfo> = f.types.find(td -> td.name == typeName);
		return t == null ? null : { file: f.file, span: t.span };
	}

	/**
	 * The verbatim declared type SOURCE of a receiver path's FINAL member, resolved IMPORT- and
	 * INHERITANCE-aware from `fromFile`'s scope. `startTypeName` is the path root's type name (a
	 * value's declared type, `this`'s enclosing type, or a static TYPE-name root); it resolves via
	 * `resolveTypeRef` to the SPECIFIC type in scope, then each `memberPath[i]` is looked up on
	 * that exact type + its supertype closure and its nominal resolved import-aware to the next
	 * type in ITS declaring file's scope. Package-safe by construction: a same-simple-named type in
	 * ANOTHER package never contributes a member (the flaw of the package-blind simple-name walk).
	 * Null when the root, any intermediate type, or any member is unresolved / ambiguous (fails
	 * closed). Feeds `RefactorSupport.staticRootPathTypeSource` and the value-root gate.
	 */
	public function resolvePathFinalMemberTypeSource(fromFile: String, startTypeName: String, memberPath: Array<String>): Null<String> {
		if (memberPath.length == 0) return null;
		final origin: Null<FileInfo> = _files.find(f -> f.file == fromFile);
		if (origin == null) return null;
		var current: Null<ResolvedType> = resolveTypeRef(startTypeName, origin);
		for (i in 0...memberPath.length - 1) {
			if (current == null) return null;
			final cur: ResolvedType = current;
			final memberSource: Null<String> = memberTypeSourceWalk(cur, memberPath[i], []);
			if (memberSource == null) return null;
			final nominal: String = StringTools.trim(memberSource.split('<')[0]);
			current = resolveTypeRef(nominal, cur.file);
		}
		return current == null ? null : memberTypeSourceWalk(current, memberPath[memberPath.length - 1], []);
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
		final start: Null<ResolvedType> = findDeclaredType(file, typeName);
		return start != null && inheritsMemberWalk(start, member, []);
	}

	/**
	 * Whether `a` and `b` are provably UNRELATED classes — both resolve to a unique
	 * indexed CLASS decl, are distinct, and neither is a transitive supertype of the
	 * other with BOTH supertype closures fully resolved inside the index. Sound for the
	 * always-false `is` check: two unrelated classes share no common subtype under Haxe
	 * single inheritance, so a value of one can never be an instance of the other. Names
	 * are SIMPLE; an ambiguous simple name (0 or >1 indexed decls) → false. Resolution is by SIMPLE name (the index models no packages), so a simple-name collision with an external supertype is the residual soundness boundary.
	 */
	public function unrelatedClasses(a: String, b: String): Bool {
		return a != b && isUniqueClass(a) && isUniqueClass(b) && closureExcludes(a, b, [a]) && closureExcludes(b, a, [b]);
	}

	/**
	 * Whether `sub` is a transitive (proper) SUBTYPE of `sup` — `sup`'s simple name
	 * appears in `sub`'s transitive supertype closure (extends + implements). Positive
	 * direction: an unindexed or ambiguous supertype link simply ends that branch (a safe
	 * MISS, never a false claim of subtyping); not reflexive (`sub == sup` → false — the
	 * caller decides same-type separately). Names are SIMPLE; a same-named unrelated type
	 * in the chain is the residual soundness boundary, as in `unrelatedClasses`.
	 */
	public function isSubtype(sub: String, sup: String): Bool {
		return closureContains(sub, sup, [sub]);
	}

	/**
	 * Whether `sub` is provably NOT a (transitive) subtype of `sup` — the POSITIVE proof of the
	 * negative, which a false `isSubtype` does NOT supply: `isSubtype` ends a branch on any
	 * unindexed or AMBIGUOUS supertype link (a simple name with 0 or >1 indexed decls), so its
	 * `false` unions "provably unrelated" with "unprovable". True only when `sub` resolves to a
	 * single decl, its ENTIRE supertype closure likewise resolves, and `sup` appears nowhere in
	 * it. Reflexivity is not unrelatedness (`sub == sup` → false). For a caller that must act on
	 * "different owner" rather than merely skip on "not proven the same" — attributing an
	 * occurrence away from a rename on an unprovable negative drops a real reference and
	 * half-applies the edit.
	 */
	public function provablyNotSubtype(sub: String, sup: String): Bool {
		return sub != sup && closureExcludes(sub, sup, [sub]);
	}

	/**
		 * Whether the type `typeName` — together with its ENTIRE supertype closure —
		 * provably declares no member named `member`. True only when `typeName` resolves
		 * to exactly one indexed decl, every transitive supertype likewise resolves, and
		 * none of them declares `member`. Any unresolved / ambiguous type anywhere in the
		 * closure yields false — the member could be declared out of the lint scope, so its
		 * absence is not provable. The green-light companion of `supertypeDeclaresMember`,
		  * used by `trivial-getter` to prove an implemented interface does not require the
	 * property's `get_` accessor before collapsing it to `(default, null)`.
	 *
	 * The walk FOLLOWS a plain `typedef A = C` alias to `C` and refuses a `@:forward` abstract,
	 * whose underlying's members reach it through a link `supertypes` does not carry — the
	 * positive companions (`typeDeclaresMember` / `supertypeDeclaresMember`) do NOT, so a caller
	 * needing the shadow answer on an aliased nominal must read a false here as "unprovable"
	 * rather than as "declared".
	 */
	public function typeProvablyLacksMember(typeName: String, member: String): Bool {
		return lacksMemberClosure(typeName, member, []);
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
		for (fi in _files) for (t in fi.types) if (t.name == typeName) for (iface in t.interfaces) if (!typeProvablyLacksMember(
			iface, field
		))
			return true;
		return false;
	}

	/**
	 * Whether `typeName` resolves in the index to EXACTLY ONE declaration and that
	 * declaration is a PLAIN nominal type — a class, interface or enum. Excludes
	 * abstracts (their implicit `@:from` / `@:to` conversions and operator overloads
	 * make a value's RUNTIME behaviour depend on its STATIC type, so changing a
	 * binding's declared type can change semantics even though it compiles) and
	 * typedefs (which may alias an abstract or `Dynamic`). An unresolved name — a
	 * stdlib or out-of-scope type — yields false: not provable, so not eligible.
	 * The green-light gate of the `avoid-dynamic` local narrowing.
	 */
	public function resolvesToPlainNominal(typeName: String): Bool {
		final ds: Array<TypeDeclInfo> = declsNamed(typeName);
		return ds.length == 1 && PLAIN_NOMINAL_KINDS.contains(ds[0].kind);
	}

	/**
	 * The unanimous type-parameter arity of every indexed declaration named
	 * `typeName` (simple name), or null when the name is undeclared or the
	 * declarations disagree — an ambiguous arity must never prove non-genericity.
	 */
	public function typeParamArityOf(typeName: String): Null<Int> {
		var arity: Null<Int> = null;
		for (f in _files) for (t in f.types) if (t.name == typeName) {
			if (arity == null)
				arity = t.typeParamArity;
			else if (arity != t.typeParamArity)
				return null;
		}
		return arity;
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
		for (fi in _files) for (t in fi.types) if (t.name != typeName && t.members.exists(m ->
			m.name == member
		) && isSubtype(t.name, typeName))
			return true;
		return false;
	}

	/**
	 * Whether collapsing `owner`'s property `prop` could break a subtype — the precise,
	 * per-property replacement for the blanket `hasSubtype` gate the accessor-collapse checks
	 * use. True when any indexed type declaring `get_<prop>` / `set_<prop>` / `<prop>` is a PROVEN
	 * transitive subtype of `owner` (its accessor override / property redeclaration would be
	 * stranded by the collapse), OR is an OVERRIDE of the accessor whose supertype chain cannot be
	 * resolved to rule `owner` out — an unresolvable hierarchy could hide the override, so it is
	 * kept conservatively. A type whose chain is fully resolved and EXCLUDES `owner`, or a FRESH
	 * (non-override) same-named member on an unresolvable type, never blocks: an unrelated class
	 * merely sharing the property name leaves the collapse alone. False when no subtype touches the
	 * property (or `owner` has none). Names are SIMPLE, so a same-named unrelated type is the
	 * residual soundness boundary, as in `isSubtype`.
	 */
	public function subtypeOverridesProperty(owner: String, prop: String): Bool {
		final names: Array<String> = ['get_$prop', 'set_$prop', prop];
		for (fi in _files) for (t in fi.types) if (t.name != owner) {
			final matches: Array<MemberInfo> = t.members.filter(m -> names.contains(m.name));
			if (matches.length == 0) continue;
			if (isSubtype(t.name, owner)) return true;
			if (!provablyNotSubtype(t.name, owner) && matches.exists(m -> m.isOverride)) return true;
		}
		return false;
	}

	/**
	 * Whether any (transitive) SUBTYPE of `owner` references the private backing field `field` the trivial-getter collapse would DELETE — a subclass reading `owner`'s private `_x` directly breaks with 'Unknown identifier' once `_x` is removed, since the rename only rewrites references inside `owner`. The subtype closure is walked DOWNWARD over the index by simple-name supertype edges, so only real descendants are visited (a sibling sharing an unresolvable ancestor never false-blocks). A subtype declaring its OWN `field` is skipped (a bare reference there binds to that member, not the inherited one); a subtype whose declaration span word-boundary-references `field` blocks the collapse, and an unscannable source — or a second type carrying `owner`'s own simple name, which the index cannot tell apart from `owner` — blocks conservatively. Sound over indexed subtypes; a subtype in an unindexed file is the inherent blind spot the accessor-override gate shares.
	 */
	public inline function subtypeReferencesField(owner: String, field: String): Bool {
		return subtypeDeclMatches(
			owner, field, (_, src, span, redeclares) -> !redeclares && RefactorSupport.identTokenOffset(src, span, field) >= 0
		);
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
	 * Whether `typeName` OR any type in its transitive supertype closure carries
	 * `@:rtti` (resolved via the index). True marks a serialization-sensitive
	 * hierarchy - a class reflected on its field NAMES at runtime (a drill Node) -
	 * whose fields a naming autofix must not rename. An unresolved / ambiguous
	 * supertype simply ends that branch (a safe miss, matching `isSubtype`); the
	 * direct-`@:rtti` case is caught by the projection's `renameUnsafe` regardless.
	 */
	public function transitivelyCarriesRtti(typeName: String): Bool {
		final seen: Array<String> = [typeName];
		var i: Int = 0;
		while (i < seen.length) {
			final name: String = seen[i];
			i++;
			for (f in _files) for (t in f.types) if (t.name == name) {
				if (t.hasRtti) return true;
				for (s in t.supertypes) if (!seen.contains(s)) seen.push(s);
			}
		}
		return false;
	}

	/**
	 * The retained raw source text of an indexed `file`, or null when the file is
	 * not in this index's scope. Lets a consumer parse a declaring file it located
	 * via `declaringFiles` / `resolveTypeRef` (e.g. `prefer-arrow-callback`
	 * extracting a callee's parameter signature) without re-reading the disk.
	 */
	public function sourceOf(file: String): Null<String> {
		return _sources[file];
	}

	/**
	 * EVERY declaration a WRITTEN type reference resolves to against `fromFile`'s
	 * import scope — the multi-candidate counterpart of `resolveTypeRefFrom` for a
	 * consumer that can tolerate ambiguity by AGREEMENT (e.g. `prefer-arrow-callback`
	 * accepting two same-module declarations — a vendored std fork next to the real
	 * std — when every candidate yields the same verdict). Empty when `fromFile` is
	 * not indexed or nothing matches.
	 */
	public function resolveTypeRefsFrom(raw: String, fromFile: String): Array<{ file: FileInfo, type: TypeDeclInfo }> {
		final fi: Null<FileInfo> = fileInfo(fromFile);
		return fi == null ? [] : resolveTypeRefAll(raw, fi);
	}

	/**
	 * `abstractRebindsThis`'s recursion, cycle-guarded by `seen` (a cycle is treated as
	 * possibly-rebinding — conservative). A non-abstract match contributes "found" without rebinding; an
	 * abstract with `abstractSelfRebind` rebinds; a `@:forward` abstract defers to its underlying (an
	 * unresolved or rebinding underlying rebinds, a non-rebinding one contributes "found"); any other
	 * abstract contributes "found". `null` when nothing named `typeName` is indexed, else `false`.
	 */
	private function abstractRebindsWalk(typeName: String, abstractKinds: Array<String>, seen: Array<String>): Null<Bool> {
		if (seen.contains(typeName)) return true;
		seen.push(typeName);
		var found: Bool = false;
		for (fi in _files) for (t in fi.types) if (t.name == typeName) {
			if (!abstractKinds.contains(t.kind)) {
				found = true;
				continue;
			}
			if (t.abstractSelfRebind) return true;
			final underlying: Null<String> = t.abstractForwardUnderlying;
			if (underlying == null) {
				found = true;
				continue;
			}
			final rec: Null<Bool> = abstractRebindsWalk(underlying, abstractKinds, seen);
			if (rec == null || rec == true) return true;
			found = true;
		}
		return found ? false : null;
	}

	/**
	 * Recursive closure walk for `typeProvablyLacksMember`, cycle-guarded by `seen`.
	 * A `Dynamic` supertype is skipped, not treated as an unresolvable dead end:
	 * `implements Dynamic<T>` marks dynamic FIELD ACCESS, it declares no NAMED member,
	 * so it can never be the inherited `_x` a rename would redefine. It reaches
	 * `supertypes` from a clause like openfl `DisplayObject`'s `#if (…) implements
	 * Dynamic<DisplayObject> #end`; counting it as unresolvable (`ds.length != 1`)
	 * would wrongly block every `openfl` display subclass's field rename.
	 */
	private function lacksMemberClosure(typeName: String, member: String, seen: Array<String>): Bool {
		if (typeName == 'Dynamic' || seen.contains(typeName)) return true;
		seen.push(typeName);
		final ds: Array<TypeDeclInfo> = declsNamed(typeName);
		if (ds.length != 1) return false;
		final t: TypeDeclInfo = ds[0];
		if (t.members.exists(m -> m.name == member)) return false;
		// An ALIASING_DECL_KINDS decl reaches members through a link `supertypes` never records, so
		// its own empty member list proves NOTHING — the same hole `closureExcludes` refuses outright,
		// resolved here instead of refused: a plain `typedef A = C` continues the proof on `C`, while
		// an unreadable alias and a `@:forward` abstract (every underlying member is exposed under a
		// name the index cannot enumerate here) are not provable at all.
		if (t.kind == TYPEDEF_DECL_KIND && !t.isAnonStruct) {
			final target: Null<String> = t.aliasTargetNominal;
			return target == null ? false : lacksMemberClosure(target, member, seen);
		}
		if (t.abstractForwardUnderlying != null) return false;
		for (sup in t.supertypes) if (!lacksMemberClosure(sup, member, seen)) return false;
		return true;
	}

	/** Recursive supertype walk for `supertypeDeclaresMember`, cycle-guarded by `seen`. */
	private function supertypeDeclares(typeName: String, field: String, seen: Array<String>): Bool {
		if (seen.contains(typeName)) return false;
		seen.push(typeName);
		for (fi in _files) for (t in fi.types) if (t.name == typeName) for (sup in t.supertypes) if (
			typeDeclaresMember(sup, field) || supertypeDeclares(sup, field, seen)
		)
			return true;
		return false;
	}

	/** The `{file, type}` for the type named `typeName` declared in `file`, or null. */
	private function findDeclaredType(file: String, typeName: String): Null<ResolvedType> {
		final fi: Null<FileInfo> = _files.find(f -> f.file == file);
		if (fi == null) return null;
		final host: FileInfo = fi;
		final t: Null<TypeDeclInfo> = host.types.find(td -> td.name == typeName);
		return t == null ? null : { file: host, type: t };
	}

	/**
	 * `inheritsMemberUnambiguously`'s recursion: whether any UNAMBIGUOUSLY-resolved
	 * supertype of `cur` declares `member`, or transitively inherits it. `seen`
	 * cycle-guards on the resolved `(file, name)` identity.
	 */
	private function inheritsMemberWalk(cur: ResolvedType, member: String, seen: Array<String>): Bool {
		final key: String = '${cur.file.file}#${cur.type.name}';
		if (seen.contains(key)) return false;
		seen.push(key);
		for (raw in cur.type.supertypesRaw) {
			final anc: Null<ResolvedType> = resolveTypeRef(raw, cur.file);
			if (anc == null) continue;
			final ancestor: ResolvedType = anc;
			if (ancestor.type.members.exists(m -> m.name == member)) return true;
			if (inheritsMemberWalk(ancestor, member, seen)) return true;
		}
		return false;
	}

	/**
	 * The verbatim declared type source of `member` on `cur`'s type or its supertype closure
	 * (import-aware via `resolveTypeRef` over `supertypesRaw`), or null when absent. The
	 * type-source counterpart of `inheritsMemberWalk` — resolution stays anchored to the SPECIFIC
	 * resolved type, so a same-simple-name namesake never contributes a member.
	 */
	private function memberTypeSourceWalk(cur: ResolvedType, member: String, seen: Array<String>): Null<String> {
		final key: String = '${cur.file.file}#${cur.type.name}';
		if (seen.contains(key)) return null;
		seen.push(key);
		final direct: Null<MemberInfo> = cur.type.members.find(m -> m.name == member);
		if (direct != null) return direct.typeSource;
		for (raw in cur.type.supertypesRaw) {
			final anc: Null<ResolvedType> = resolveTypeRef(raw, cur.file);
			if (anc == null) continue;
			final src: Null<String> = memberTypeSourceWalk(anc, member, seen);
			if (src != null) return src;
		}
		return null;
	}

	/**
	 * Resolve a written supertype reference `raw` (as it appears in `fromFile`) to the
	 * SINGLE in-set type it names, or null when it is external (no in-set match) or
	 * AMBIGUOUS (more than one distinct in-set match). A qualified `raw` matches an
	 * in-set type whose import path equals it; a simple `raw` matches a type in scope of
	 * `fromFile` — named by an explicit `import` / `using`, reached through a `pkg.*`
	 * wildcard, or declared in `fromFile`'s own package.
	 */
	private function resolveTypeRef(raw: String, fromFile: FileInfo): Null<ResolvedType> {
		final matches: Array<ResolvedType> = resolveTypeRefAll(raw, fromFile);
		return matches.length == 1 ? matches[0] : null;
	}

	/** Every in-scope declaration `raw` resolves to from `fromFile` (see `resolveTypeRef`), deduped by declaring file. */
	private function resolveTypeRefAll(raw: String, fromFile: FileInfo): Array<ResolvedType> {
		final dot: Int = raw.lastIndexOf('.');
		final simple: String = dot < 0 ? raw : raw.substr(dot + 1);
		final matches: Array<ResolvedType> = [];
		final seen: Array<String> = [];
		for (fi in _files) for (t in fi.types) if (t.name == simple) {
			final inScope: Bool = dot < 0 ? simpleRefInScope(fromFile, fi, t) : importPathFor(fi, t) == raw;
			final key: String = '${fi.file}#${t.name}';
			if (inScope && !seen.contains(key)) {
				seen.push(key);
				matches.push({ file: fi, type: t });
			}
		}
		return matches;
	}

	/**
	 * Whether a bare simple reference in `fromFile` resolves to type `t` of file `fi`:
	 * `fi` shares `fromFile`'s package, or `fromFile` names `t` through an explicit
	 * `import` / `using` (its raw equals `t`'s import path) or a `pkg.*` wildcard over
	 * `fi`'s package.
	 */
	private function simpleRefInScope(fromFile: FileInfo, fi: FileInfo, t: TypeDeclInfo): Bool {
		if (fi.pkg == fromFile.pkg) return true;
		// A ROOT-package type (`Array`, `Math`, a package-less project module) is visible by
		// simple name from every file, with no import — the rule that puts the std top level in
		// scope, so a member type such as `Array<T>.length` resolves from any package.
		if (fi.pkg == '') return true;
		final path: String = importPathFor(fi, t);
		final wild: String = '${fi.pkg}.*';
		for (imp in fromFile.imports) switch imp.kind {
			case ImportKind.Import | ImportKind.Using:
				// A module import carries EVERY type the module declares into simple-name scope,
				// not just its main one — `import pkg.Mod;` makes a sub-module `pkg.Mod.Sub`
				// referable as `Sub`, which is how a response typedef beside its main type is used.
				if (imp.raw == path || (!t.isMain && imp.raw == fi.module)) return true;
			case ImportKind.Wild:
				if (imp.raw == wild) return true;
			case ImportKind.Alias:
		}
		return false;
	}

	/** The import path naming type `t` in file `fi`: its module when `t` is the module main type, else `module.name`. */
	private inline function importPathFor(fi: FileInfo, t: TypeDeclInfo): String {
		return t.isMain ? fi.module : '${fi.module}.${t.name}';
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
			if (rn != null) {
				if (supers == 0)
					inherited = rn;
				else if (rn != inherited)
					return null;
				supers++;
			}
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
			if (v != null) {
				if (supers > 0 && v != inherited) return null;
				inherited = v;
				supers++;
			}
		}
		return inherited;
	}

	/** Exactly one indexed decl is named `name`, and it is a class. */
	private function isUniqueClass(name: String): Bool {
		final ds: Array<TypeDeclInfo> = declsNamed(name);
		return ds.length == 1 && ds[0].kind == CLASS_DECL_KIND;
	}

	/** Every indexed type decl whose simple name is `name`, across all files. */
	private function declsNamed(name: String): Array<TypeDeclInfo> {
		final out: Array<TypeDeclInfo> = [for (fi in _files) for (t in fi.types) if (t.name == name) t];
		return out;
	}

	/**
	 * Every indexed type directly extending / implementing `parent` (matched by simple name),
	 * paired with its declaring file — the memoised form of a full `_files` x `types` scan, in
	 * the same order that scan visited. Empty when nothing names `parent`. The whole adjacency
	 * is built on first use; the index is immutable after construction, so one build per
	 * instance is sound. The returned array is the LIVE bucket, not a copy — read it, never
	 * mutate it, or the memo is corrupted for every later caller.
	 */
	private function subtypesOf(parent: String): Array<ResolvedType> {
		var adjacency: Null<Map<String, Array<ResolvedType>>> = _subtypeAdjacency;
		if (adjacency == null) {
			adjacency = [];
			for (fi in _files) for (t in fi.types) {
				// A type naming one simple name TWICE (two differently-qualified supertypes reducing to
				// it) lands in that bucket once — `supertypes.contains` reported it once per scan too.
				final named: Array<String> = [];
				for (sup in t.supertypes) if (!named.contains(sup)) {
					named.push(sup);
					final bucket: Array<ResolvedType> = adjacency[sup] ?? [];
					bucket.push({ file: fi, type: t });
					adjacency[sup] = bucket;
				}
			}
			_subtypeAdjacency = adjacency;
		}
		return adjacency[parent] ?? [];
	}

	/**
	 * Whether `name`'s transitive supertype closure is FULLY index-resolved AND excludes
	 * `target`. A supertype name absent or ambiguous in the index (an external type, or a
	 * project file not in the set) makes the relation unknown → false, as does reaching
	 * `target` itself, as does an ALIASING decl anywhere in the walk (see
	 * `ALIASING_DECL_KINDS` — its empty `supertypes` would "exclude" the target vacuously).
	 * `seen` guards cycles. Read only as a NEGATIVE proof: every doubt yields false.
	 */
	private function closureExcludes(name: String, target: String, seen: Array<String>): Bool {
		final ds: Array<TypeDeclInfo> = declsNamed(name);
		if (ds.length != 1 || ALIASING_DECL_KINDS.contains(ds[0].kind)) return false;
		for (sup in ds[0].supertypes) {
			if (sup == target) return false;
			if (seen.contains(sup)) continue;
			seen.push(sup);
			if (!closureExcludes(sup, target, seen)) return false;
		}
		return true;
	}

	/** Whether `target` appears in `name`'s transitive supertype closure. `seen` guards cycles. */
	private function closureContains(name: String, target: String, seen: Array<String>): Bool {
		final ds: Array<TypeDeclInfo> = declsNamed(name);
		if (ds.length != 1) return false;
		for (sup in ds[0].supertypes) {
			if (sup == target) return true;
			if (seen.contains(sup)) continue;
			seen.push(sup);
			if (closureContains(sup, target, seen)) return true;
		}
		return false;
	}

	/**
	 * Parse every `(file, source)` entry through `plugin.parseFile` and
	 * build the index. A file whose parse throws is recorded in
	 * `skippedFiles()` and EXCLUDED from the index — `build` never
	 * throws. The file basename (the path tail sans `.hx`) drives the
	 * module path and the `isMain` flag for each type, mirroring
	 * `CrossRename`'s parse-each-file pattern.
	 */
	public static function build(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): SymbolIndex {
		final extracted: {
			files: Array<FileInfo>,
			skipped: Array<String>,
			sources: Map<String, String>
		} = SymbolIndexBuilder.extract(files, plugin);
		return new SymbolIndex(extracted.files, extracted.skipped, extracted.sources);
	}

	/**
	 * The MODULE portion of a dotted import path — see `SymbolIndexBuilder.moduleOf`, which
	 * owns the implementation. Kept here because the index's own callers reach it as
	 * `SymbolIndex.moduleOf`.
	 */
	public static function moduleOf(path: String): String {
		final segments: Array<String> = path.split('.');
		final out: Array<String> = [];
		for (segment in segments) {
			out.push(segment);
			if (segment.length > 0 && RefactorSupport.isUpperInitial(segment)) return out.join('.');
		}
		return path;
	}

}
