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

	/** The grammar member-decl kind the member projected as (`VarMember` / `FinalMember` / `FnMember` / `SimpleCtor` / …) — lets a consumer tell a FIELD from a method or an enum constructor without re-walking the tree. */
	var kind: String;

	/**
	 * True when the member's modifier run carries the grammar's `static` modifier. A
	 * type-qualified `Type.member` reference normally resolves only to a static member —
	 * with one exception a consumer must handle itself: an enum-abstract VALUE is written
	 * without `static`, yet `Ea.VALUE` is exactly how it is referenced.
	 */
	var isStatic: Bool;

	/** True when the member's modifier run carries the grammar's `inline` modifier — an inlined field's value is a compile-time constant at every use site. */
	var isInline: Bool;

	/**
	 * True when the member's DECLARATION sits under a `conditionalMemberKind` host — the
	 * member is written inside a `#if` region rather than at plain type-body level.
	 * Mirrors `ImportInfo.guarded`: the declaration genuinely exists, but its presence is
	 * branch-dependent while the index is branch-blind, so a consumer that reasons about
	 * the member (a constant-folding rewrite) must bail on it. It does NOT cover a
	 * branch-dependent VALUE on an unconditional declaration
	 * (`static inline final A:Int = #if js 1 #else 2 #end;`): that member is a direct
	 * child of the type body, so `guarded` is false.
	 */
	var guarded: Bool;
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
	 * Whether the declaration carries the language's EXTERN modifier — a type whose runtime
	 * representation belongs to the target rather than to the compiler. Load-bearing for any
	 * consumer reasoning about what a runtime does with an instance: an extern type's methods
	 * are declarations over a foreign object, so a non-extern type's method is the one the
	 * compiler provably wires every use to. `redundant-tostring` reads it to tell a Haxe
	 * `toString` the runtime's string coercion also calls from an `extern class Date` /
	 * `extern class Array` whose coercion goes native and diverges.
	 */
	var isExtern: Bool;

	/**
	 * The number of type parameters written on the declaration header
	 * (`class Box<T, U>` → 2; 0 = non-generic). Drives bare-`new` local-type
	 * annotation: an arity-0 type's written name IS its complete type.
	 */
	var typeParamArity: Int;

	/**
	 * The WRITTEN names of the declaration header's type parameters, in header order
	 * (`class Box<T:Item, K>` → `['T', 'K']`). Lets a consumer substitute a member declared as
	 * one of them for the matching type ARGUMENT of the receiver that reached it.
	 *
	 * EMPTY when the header carried none OR when its `<…>` list could not be read as a plain
	 * name list (a segment that is not an identifier after its metadata run and before its `:`
	 * constraint or `=` default). Never read empty as "non-generic" — `typeParamArity` answers
	 * that question, and the two disagree exactly when the names were unreadable, which is the
	 * case a substituting consumer must refuse rather than guess at.
	 *
	 * The list is POSITIONAL — its index IS the argument index a consumer substitutes through — so
	 * a phantom entry is worse than an empty list: it shifts every parameter after it. That is why
	 * the header segmentation (`RefactorSupport.splitTypeArgumentList`) has to know every delimiter
	 * a Haxe constraint may nest a comma inside, structures (`<T:{a:Int, b:Int}>`) included.
	 */
	var typeParamNames: Array<String>;

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

	/**
	 * True when the declaration carries a `@:build` macro directly — the macro may add members
	 * this index never sees, so a check reasoning about the type's member set must bail.
	 */
	var hasBuild: Bool;

	/**
	 * True when the declaration carries `@:autoBuild`. Unlike `hasBuild` this says nothing about
	 * THIS type's members: the macro runs on every DESCENDANT (subclass / implementor), so the
	 * flag must be read while walking a chain UPWARD — a type whose ancestor carries it has an
	 * invisible generated member set of its own.
	 */
	var hasAutoBuild: Bool;

	/**
	 * True when the declaration carries `@:keep` — its members are reached by machinery no source
	 * scan models (reflection, a framework's runtime lookup), so none of them is provably dead.
	 */
	var hasKeep: Bool;

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

	/** The grammar kind an `abstract` declaration projects as. */
	private static final ABSTRACT_DECL_KIND: String = 'AbstractDecl';

	/** The grammar kind an anonymous structure projects as, in BOTH a typedef body and a type expression. */
	/** The decl kinds free of implicit-conversion / aliasing semantics — see `resolvesToPlainNominal`. */
	private static final PLAIN_NOMINAL_KINDS: Array<String> = [CLASS_DECL_KIND, 'InterfaceDecl', 'EnumDecl'];

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
	 * simple-name collision (a rebinding match wins). Resolution is by SIMPLE name (the index
	 * models no packages).
	 *
	 * An UNRESOLVED `@:forward` underlying yields `null`, not `true`. The underlying is stored as
	 * the abstract's own source spelling, which is an import ALIAS whenever its file wrote
	 * `import pkg.T as U` (lime's `@:forward abstract Bytes(HaxeBytes)` is the live case), and a
	 * simple-name index can never resolve an alias — so "underlying not found" carries no evidence
	 * either way. Answering `true` there made ADDING a library to the resolution scope turn a
	 * previously-flagged binding silent: with no library the name was unknown and the caller's own
	 * unknown policy (`RefactorSupport.abstractMethodMayMutate`'s stdlib whitelist) called it safe,
	 * while with the library it resolved to an abstract with an unresolvable underlying and was
	 * hard-vetoed. `null` hands the decision back to that one policy, so more resolution scope can
	 * only ever add information.
	 */
	public function abstractRebindsThis(typeName: String, abstractKinds: Array<String>): Null<Bool> {
		return abstractRebindsWalk(typeName, abstractKinds, []);
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
			for (fi in _files) for (t in fi.types) if (t.name == typeName) for (m in t.members) if (m.name == memberName)
				{ type: t, member: m }
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
	public inline function resolvePathFinalMemberTypeSource(
		fromFile: String, startTypeName: String, memberPath: Array<String>
	): Null<String> {
		return pathFinalMemberWalk(fromFile, startTypeName, memberPath, false);
	}

	/**
	 * `resolvePathFinalMemberTypeSource` with TYPE-ARGUMENT SUBSTITUTION: `startTypeSource` is the
	 * root's WRITTEN type (`Box<Item>`, arguments included), and a member declared as one of its
	 * type's parameters answers the matching argument instead of the parameter name. Resolves
	 * `Box<Item>.payload : T` to `Item`, which is what makes a generic container's element member
	 * reachable at all — the verbatim `T` resolves to no type.
	 *
	 * Strictly more conservative than the plain walk wherever it is unsure: substitution applies
	 * ONLY to a member declared DIRECTLY on the current type (an INHERITED member's `T` names the
	 * SUPERTYPE's parameter, and the extends-clause argument mapping is not modelled), and any
	 * effective source that STILL mentions a parameter name of the type it came from aborts THIS
	 * walk. Null on every unresolved / ambiguous link, exactly like the plain walk.
	 *
	 * "Aborts this walk" is the honest scope: the caller
	 * (`RefactorSupport.pathReceiverMemberTypeSource`) treats a null the same way it treats one from
	 * the plain walk and drops to its package-blind fallback, which may still answer the verbatim
	 * parameter source. That keeps the deep answer a superset of the shallow one, and a bare
	 * parameter name is not a type any consumer of this chain acts on.
	 */
	public inline function resolveGenericPathFinalMemberTypeSource(
		fromFile: String, startTypeSource: String, memberPath: Array<String>
	): Null<String> {
		return pathFinalMemberWalk(fromFile, startTypeSource, memberPath, true);
	}

	/**
	 * The shared body of the two path walks. With `substitute == false` it is the plain
	 * import-aware walk, byte for byte what `resolvePathFinalMemberTypeSource` always did; with
	 * `substitute == true` it additionally carries the receiver's written type ARGUMENTS alongside
	 * the current type and rewrites a parameter-typed member through them.
	 *
	 * `args` is re-seeded at every step from the effective member source, so the substitution
	 * follows a chain of generic containers (`Array<Box<Item>>` → `Box<Item>` → `Item`). The
	 * fail-closed rule that ends the walk when a parameter name survives substitution is what keeps
	 * that sound: without it an unsubstituted `T` would travel forward as if it were a concrete
	 * argument and could collide with the NEXT type's parameter of the same name, or with a project
	 * type literally called `T` / `K` / `V`.
	 */
	private function pathFinalMemberWalk(fromFile: String, startSource: String, memberPath: Array<String>, substitute: Bool): Null<String> {
		if (memberPath.length == 0) return null;
		final origin: Null<FileInfo> = _files.find(f -> f.file == fromFile);
		if (origin == null) return null;
		var args: Array<String> = [];
		var startName: String = startSource;
		if (substitute) {
			final startArgs: Null<Array<String>> = RefactorSupport.typeArgumentSourcesOf(startSource);
			if (startArgs != null) {
				final head: Null<String> = RefactorSupport.outerNominalOf(startSource);
				if (head == null) return null;
				args = startArgs;
				startName = head;
			}
		}
		var current: Null<ResolvedType> = resolveTypeRef(startName, origin);
		for (i in 0...memberPath.length - 1) {
			if (current == null) return null;
			final cur: ResolvedType = current;
			final memberSource: Null<String> = memberTypeSourceWalk(cur, memberPath[i], []);
			if (memberSource == null) return null;
			final effective: Null<String> = substitute ? substitutedMemberSource(cur, memberPath[i], memberSource, args) : memberSource;
			if (effective == null) return null;
			if (substitute) args = RefactorSupport.typeArgumentSourcesOf(effective) ?? [];
			final nominal: String = StringTools.trim(effective.split('<')[0]);
			current = resolveTypeRef(nominal, cur.file);
		}
		if (current == null) return null;
		final last: ResolvedType = current;
		final member: String = memberPath[memberPath.length - 1];
		final finalSource: Null<String> = memberTypeSourceWalk(last, member, []);
		if (finalSource == null || !substitute) return finalSource;
		return substitutedMemberSource(last, member, finalSource, args);
	}

	/**
	 * `memberSource` with `cur`'s type parameters resolved through `args`, or null when the result
	 * would still name one of them.
	 *
	 * Substitution fires only when ALL three hold: the member is declared DIRECTLY on `cur.type`
	 * (an inherited one's parameter name belongs to the supertype's header, a mapping this index
	 * does not model); its trimmed source is EXACTLY one parameter name (a source that merely
	 * CONTAINS one, `Array<T>`, would need a rewrite, not a lookup); and that name's position is
	 * covered by the arguments actually written on the receiver. Otherwise the verbatim source
	 * stands — and is then rejected by the parameter-mention gate if it names a parameter, so an
	 * unsubstitutable parameter can never leave this function as if it were a concrete type.
	 *
	 * The DIRECT-member gate is the one that stops a wrong CONCRETE type, not merely an
	 * unresolvable one: a subtype whose header parameter happens to share the supertype's name but
	 * passes something else up (`class Der<T:Item> extends Base<Str>`, `Base<T> { var u:T; }`)
	 * would otherwise substitute `Der`'s argument into `Base`'s parameter and resolve `u` to the
	 * wrong type entirely. `SimplifyNegatedCompoundCheckTest.testSupertypeParamNameCollisionKeepsWrap`
	 * is the fixture that fails if it is removed.
	 */
	private function substitutedMemberSource(cur: ResolvedType, member: String, memberSource: String, args: Array<String>): Null<String> {
		final params: Array<String> = cur.type.typeParamNames;
		final at: Int = params.indexOf(StringTools.trim(memberSource));
		final declaredHere: Bool = cur.type.members.exists(m -> m.name == member);
		final effective: String = declaredHere && at >= 0 && at < args.length ? args[at] : memberSource;
		return mentionsTypeParam(effective, params) ? null : effective;
	}

	/** Whether `text` names any of `params` as a WHOLE identifier token — `Item` does not mention `T`, `Array<T>` does. */
	private static function mentionsTypeParam(text: String, params: Array<String>): Bool {
		if (params.length == 0) return false;
		var i: Int = 0;
		while (i < text.length) {
			if (!RefactorSupport.isIdentStartChar(StringTools.fastCodeAt(text, i))) {
				i++;
				continue;
			}
			var end: Int = i + 1;
			while (end < text.length && RefactorSupport.isIdentChar(StringTools.fastCodeAt(text, end))) end++;
			if (params.contains(text.substring(i, end))) return true;
			i = end;
		}
		return false;
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
		) && declMayBeSubtype(t, typeName, [t.name]))
			return true;
		return false;
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
			final ds: Array<TypeDeclInfo> = declsNamed(sup);
			if (ds.length != 1) {
				if (ds.length > 1) return true;
				continue;
			}
			if (declMayBeSubtype(ds[0], target, seen)) return true;
		}
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
		var unknown: Bool = false;
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
			if (rec == true) return true;
			if (rec == null)
				unknown = true;
			else
				found = true;
		}
		return found && !unknown ? false : null;
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
			// An alias CYCLE proves nothing — unlike a supertype cycle, whose closure is still
			// fully enumerated, a chain that re-enters itself never reaches a member host at all.
			return target == null || seen.contains(target) ? false : lacksMemberClosure(target, member, seen);
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
	 * Mark `cur`'s resolved `(file, name)` identity in `seen` and answer whether this is its FIRST
	 * visit — the cycle guard every supertype walk opens with. A re-entered node answers false, and
	 * the caller ends that branch with its own not-found value.
	 */
	private inline function markSeen(cur: ResolvedType, seen: Array<String>): Bool {
		final key: String = '${cur.file.file}#${cur.type.name}';
		if (seen.contains(key)) return false;
		seen.push(key);
		return true;
	}

	/**
	 * `inheritsMemberUnambiguously`'s recursion: whether any UNAMBIGUOUSLY-resolved
	 * supertype of `cur` declares `member`, or transitively inherits it. `seen`
	 * cycle-guards on the resolved `(file, name)` identity.
	 */
	private function inheritsMemberWalk(cur: ResolvedType, member: String, seen: Array<String>): Bool {
		if (!markSeen(cur, seen)) return false;
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
		if (!markSeen(cur, seen)) return null;
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
		if (!markSeen(cur, seen)) return null;
		var declared: Bool = false;
		for (m in cur.type.members) if (m.name == field && !(inherited && m.isStatic)) {
			if (m.hasGetter) return true;
			declared = true;
		}
		if (declared) return inherited && (cur.type.hasBuild || autoBuildAtOrAbove(cur, [])) ? null : false;
		var found: Null<Bool> = null;
		for (raw in cur.type.supertypesRaw) {
			final anc: Null<ResolvedType> = resolveTypeRef(raw, cur.file);
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
		if (!markSeen(cur, seen)) return false;
		if (cur.type.hasAutoBuild) return true;
		for (raw in cur.type.supertypesRaw) {
			final anc: Null<ResolvedType> = resolveTypeRef(raw, cur.file) ?? uniqueDeclarationOf(raw);
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
		final declarers: Array<FileInfo> = declaringFiles(simple);
		return declarers.length == 1 ? findDeclaredType(declarers[0].file, simple) : null;
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
	 * `target` itself, as does an ALIASING decl at the walk's ROOT (see `ALIASING_DECL_KINDS`
	 * — its empty `supertypes` would "exclude" the target vacuously). A supertype LINK that
	 * resolves to an abstract is stepped over rather than doubted (`supertypeLinkIsAbstract`):
	 * no `extends` / `implements` clause can name one, so it is not an inheritance edge.
	 * `seen` guards cycles. Read only as a NEGATIVE proof: every doubt yields false.
	 */
	private function closureExcludes(name: String, target: String, seen: Array<String>): Bool {
		final ds: Array<TypeDeclInfo> = declsNamed(name);
		if (ds.length != 1 || ALIASING_DECL_KINDS.contains(ds[0].kind)) return false;
		for (sup in ds[0].supertypes) {
			if (sup == target) return false;
			if (seen.contains(sup)) continue;
			seen.push(sup);
			if (supertypeLinkIsAbstract(sup)) continue;
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
	 * Whether the supertype link `name` resolves to an abstract — NOT an inheritance edge. Haxe
	 * refuses an abstract in an `extends` clause ("Should extend by using a class") and in an
	 * `implements` clause, so the only way one reaches `supertypes` is the `implements Dynamic<T>`
	 * field-access directive (openfl's `DisplayObject` carries one inside a dead `#if` branch, which
	 * the branch-blind supertype scan records like any other). Nothing is reachable through such a
	 * link, so `closureExcludes` steps over it instead of doubting the whole closure. Only the LINK is
	 * stepped over — an abstract at the walk's ROOT keeps the `ALIASING_DECL_KINDS` refusal, whose
	 * `@:forward` / `@:to` edges a caller attributing member occurrences must not lose.
	 */
	private function supertypeLinkIsAbstract(name: String): Bool {
		final ds: Array<TypeDeclInfo> = declsNamed(name);
		return ds.length == 1 && ds[0].kind == ABSTRACT_DECL_KIND;
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
			for (cur in level) if (markSeen(cur, seen)) {
				for (i in 0...cur.type.supertypesRaw.length) {
					if (i < cur.type.supertypes.length && cur.type.interfaces.contains(cur.type.supertypes[i])) continue;
					final anc: Null<ResolvedType> = resolveTypeRef(cur.type.supertypesRaw[i], cur.file);
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
