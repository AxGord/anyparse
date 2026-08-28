package anyparse.query;

import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * The four import-statement forms a Haxe file may carry, distinguished
 * structurally so a consumer can decide which forms participate in a
 * symbol move / rewrite. Modelled as a zero-cost `enum abstract(Int)`
 * because the kind carries no associated data.
 *
 *  - `Import` — `import pkg.Module;` / `import pkg.Module.SubType;`.
 *  - `Alias`  — `import pkg.Module as U;` (the grammar puts only the ALIAS in
 *    the node's name slot, so `raw` holds the alias; the aliased path is
 *    decoded out of the statement source into `ImportInfo.aliasTarget`).
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
 * `aliasTarget` is the DOTTED PATH an `Alias` statement binds that alias to —
 * the half `raw` cannot carry, decoded from the statement source by the one
 * decoder that reads it (`ModuleScan.aliasTargetOf`). Null for every other
 * kind and for an alias statement that does not decode. Without it the index
 * cannot tell that `class C extends U` under `import pkg.Base as U;` is a
 * subtype of `Base`, and `hasSubtype` answering false is a licence SIX autofix
 * consumers take to delete or rewrite: `prefer-inline` and `prefer-enum-abstract` read
 * it directly, and `unused-private` (both arms), `naming` and `unused-parameter` read it
 * through `RefactorSupport.isPrivateMemberConfined`. Count the seam, not the list — a
 * new reader of either one inherits the answer.
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
	var aliasTarget: Null<String>;
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

	/**
	 * The VERBATIM declared type SOURCE of the member's FIRST parameter (`static function
	 * trim(s:String)` → `String`), or null when the member declares no parameter, its first
	 * parameter carries no annotation, or it is not a function at all.
	 *
	 * The one fact a `using` STATIC EXTENSION needs that no other field here carries. `using M`
	 * makes `M.m(first, …)` reachable as `<recv>.m(…)` ONLY for a receiver the first parameter
	 * accepts, so nothing may take `returnNominal` as such a call's type without matching the
	 * receiver against THIS source first — `extensionReturnNominal` is that join.
	 */
	var firstParamTypeSource: Null<String>;

	/** The member's EXPLICIT visibility keyword as WRITTEN (`public` / `private`), or null when its modifier run carries none. Drives cross-file override-visibility resolution. */
	var visibility: Null<String>;

	/** True when the member's modifier run carries the grammar's override modifier — an unmarked override's effective visibility comes from the supertype, not the container default. */
	var isOverride: Bool;

	/** The grammar member-decl kind the member projected as (`VarMember` / `FinalMember` / `FnMember` / `SimpleCtor` / …) — lets a consumer tell a FIELD from a method or an enum constructor without re-walking the tree. */
	var kind: String;

	/**
	 * Byte offset where the member's DECLARATION node starts, in its own file's source. The
	 * position a rename takes as its cursor, so a consumer holding only the index can address a
	 * member declaration in a file it has not walked — `overrideFamilyOf` hands it out so an
	 * override in another file can be renamed with its base.
	 */
	var declFrom: Int;

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
	 * True when the member's modifier run carries the grammar's MACRO modifier
	 * (`RefShape.macroModifierKind`) — the member runs at COMPILE time and receives its
	 * arguments as unevaluated syntax. A consumer rewriting an argument expression must
	 * bail on such a call: a macro that pattern-matches the argument's SHAPE (a string
	 * constant, an identifier) sees the rewrite, and no structural check can tell whether
	 * it tolerates one. False for a grammar declaring no macro modifier.
	 */
	var isMacro: Bool;

	/**
	 * The node KIND the argument of every operator-overload annotation
	 * (`RefShape.operatorOverloadMetaName`) on this member projects as — `@:op(A + B)` records
	 * the grammar addition kind, `@:op(!A)` its logical-not kind. Empty for a member carrying
	 * none, which is every member of every non-abstract type: only an abstract may overload an
	 * operator.
	 *
	 * The KIND rather than the annotation text, because that is the form a consumer can compare
	 * WITHOUT spelling an operator symbol: a check holding an operator node already has its kind,
	 * and the two forms that share one symbol — the binary `A - B` and the prefix `-A` — project
	 * as different kinds, so the grammar tells them apart instead of a text rule here.
	 *
	 * This is what makes `OperatorSelection` answerable at all: whether the `+` a check is about
	 * to rewrite is string concatenation or an operator a type declares for itself is a question
	 * about a DECLARATION that usually lives in another file.
	 */
	var operatorOverloads: Array<String>;

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
	 * Whether the declaration carries a NON-PUBLIC visibility modifier — Haxe's module-`private`
	 * type, visible by simple name only inside its own module. A binding walk that answers what a
	 * name means in ANOTHER file must skip one: counting it invents a binding the compiler refuses
	 * (`Type not found`), and a mutation gate reading that phantom refuses a move that was correct.
	 * Inside the declaring module the flag is irrelevant — the module's own types are all visible.
	 *
	 * False for a declaration whose `private` sits inside a `#if` region: the modifier is a
	 * NAMELESS sibling node and only the type declaration itself is lifted out of the region, so
	 * the run never reaches this record. That direction keeps the phantom rather than inventing an
	 * invisibility, which is the conservative half.
	 */
	var isPrivate: Bool;

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
	 * the header segmentation (`NominalTypes.splitTypeArgumentList`) has to know every delimiter
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
	 * The VERBATIM head path of the same alias target — qualified when written qualified, type
	 * arguments stripped (`typedef List<T> = haxe.ds.List<T>` -> `haxe.ds.List`) — parallel to
	 * `aliasTargetNominal` exactly as `supertypesRaw` is to `supertypes`, and null under exactly
	 * the same conditions.
	 *
	 * The package a simple-name reduction throws away is what makes an alias hop RESOLVABLE. The
	 * std's two most common containers are top-level aliases re-pointing at a packaged type of
	 * the SAME simple name and importing nothing (`/std/List.hx`, `/std/Map.hx`), so a hop on the
	 * simple name resolves back to the ALIAS ITSELF and every closure walk through them stops
	 * dead. Read this wherever an alias link is FOLLOWED; read `aliasTargetNominal` only where the
	 * answer is compared against another simple name.
	 */
	var aliasTargetRaw: Null<String>;

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

/**
 * One PROVEN member of an override family — a type that redeclares the base's member and is
 * provably a subtype of it, paired with its declaring file and the offset of its own declaration.
 * A rename of the base must rewrite each of these in the same atomic edit set: leaving one behind
 * emits `override function f` overriding nothing, which does not compile.
 */
typedef OverrideFamilyMember = {
	var file: String;
	var typeName: String;

	/** Offset of the override's own declaration node, usable as a rename cursor. */
	var declFrom: Int;
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

	/**
	 * The owner decl kinds whose member a subtype may implement WITHOUT the override modifier — an
	 * interface method, and an `abstract` method on an abstract class. Under any other kind Haxe
	 * rejects a redeclaration that omits `override`, which makes the modifier a reliable filter on
	 * override-family candidates.
	 */
	private static final BARE_IMPLEMENTABLE_OWNER_KINDS: Array<String> = ['InterfaceDecl', 'AbstractClassDecl'];

	/**
	 * The grammar kind an anonymous structure projects as, in BOTH a typedef body and a type expression.
	 * The decl kinds free of implicit-conversion / aliasing semantics — see `resolvesToPlainNominal`.
	 */
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
	 *
	 * A subtype is filed under every name that DENOTES its supertype, not only the one written —
	 * see `subtypesOf`.
	 */
	private var _subtypeAdjacency: Null<Map<String, Array<ResolvedType>>>;

	private function new(files: Array<FileInfo>, skipped: Array<String>, sources: Map<String, String>) {
		_files = files;
		_skipped = skipped;
		_sources = sources;
	}

	/** Every indexed file's `FileInfo`, in input order. */
	public inline function allFiles(): Array<FileInfo> {
		return _files.copy();
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
		return pathFinalMemberWalk(fromFile, startTypeName, memberPath, false, []);
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
	 * (`NominalTypes.pathReceiverMemberTypeSource`) treats a null the same way it treats one from
	 * the plain walk and drops to its package-blind fallback, which may still answer the verbatim
	 * parameter source. That keeps the deep answer a superset of the shallow one, and a bare
	 * parameter name is not a type any consumer of this chain acts on.
	 */
	public inline function resolveGenericPathFinalMemberTypeSource(
		fromFile: String, startTypeSource: String, memberPath: Array<String>, ?transparentWrappers: Array<String>
	): Null<String> {
		return pathFinalMemberWalk(fromFile, startTypeSource, memberPath, true, transparentWrappers ?? []);
	}

	/**
	 * Whether any (transitive) SUBTYPE of `owner` references the private backing field `field` the trivial-getter collapse would DELETE — a subclass reading `owner`'s private `_x` directly breaks with 'Unknown identifier' once `_x` is removed, since the rename only rewrites references inside `owner`. The subtype closure is walked DOWNWARD over the index by simple-name supertype edges, so only real descendants are visited (a sibling sharing an unresolvable ancestor never false-blocks). A subtype declaring its OWN `field` is skipped (a bare reference there binds to that member, not the inherited one); a subtype whose declaration span word-boundary-references `field` blocks the collapse, and an unscannable source — or a second type carrying `owner`'s own simple name, which the index cannot tell apart from `owner` — blocks conservatively. Sound over indexed subtypes; a subtype in an unindexed file is the inherent blind spot the accessor-override gate shares.
	 */
	public inline function subtypeReferencesField(owner: String, field: String): Bool {
		return subtypeDeclMatches(
			owner, field, (_, src, span, redeclares) -> !redeclares && RefactorSupport.identTokenOffset(src, span, field) >= 0
		);
	}

	/** The `FileInfo` for `file`, or null when the file is not indexed. */
	public function fileInfo(file: String): Null<FileInfo> {
		return _files.find(f -> f.file == file);
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
	 * Whether `name` denotes a TYPE reachable from `fromFile` — same package, root package, or
	 * brought in by one of that file's imports (`resolveTypeRef` -> `simpleRefInScope`). Distinct
	 * from `declaringFiles`, which asks only whether the simple name is declared ANYWHERE.
	 *
	 * The question a reference resolver cannot answer on its own: the projection gives a type
	 * reference and a value read the same `IdentExpr` shape (`Event.ACTIVATE` and `trace(Event)`
	 * differ only in the parent node), so telling them apart needs the index. False when
	 * `fromFile` is not indexed, or the name resolves to no type or to several.
	 */
	public function declaresTypeInScope(name: String, fromFile: String): Bool {
		final host: Null<FileInfo> = _files.find(f -> f.file == fromFile);
		return host != null && resolveTypeRef(name, host) != null;
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
		return if (type == null)
			null
		else if (type.isMain)
			file.module
		else
			'${file.module}.$typeName';
	}

	/**
	 * EVERY import path under which `typeName` is declared in this index, main types and secondary
	 * (sub-module) ones alike — `Position` yields both `anyparse.runtime.Span.Position` and
	 * `haxe.macro.Expr.Position` when the resolution scope carries the standard library.
	 *
	 * The ambiguity-refusing `importPathOf` is the right answer for a caller holding only a simple
	 * name, but a caller that also holds the compiler's HYBRID spelling (`anyparse.runtime.Position`)
	 * can disambiguate with it, and needs the candidates to do so.
	 */
	public function importPathsOf(typeName: String): Array<String> {
		final out: Array<String> = [];
		for (file in declaringFiles(typeName)) {
			final type: Null<TypeDeclInfo> = file.types.find(t -> t.name == typeName);
			if (type == null) continue;
			final path: String = type.isMain ? file.module : '${file.module}.$typeName';
			if (!out.contains(path)) out.push(path);
		}
		return out;
	}

	/**
	 * Files that import the module `modulePath` — an `ImportInfo` whose
	 * path equals `modulePath` (the main type / module itself) OR
	 * starts with `modulePath + '.'` (a sub-type of the module, e.g.
	 * `anyparse.query.Refs.RefHit` for module `anyparse.query.Refs`).
	 *
	 * `Import`, `Alias` and `Using` kinds are considered: each carries a
	 * dotted path whose prefix can be compared. `Wild` (`pkg.*`) is
	 * skipped — its `raw` is a package-prefix glob, not a module path,
	 * so prefix-matching it against a module path is a different
	 * predicate left for a future package-prefix query.
	 *
	 * The path compared is `pathImportedBy`, not `raw`: for an `Alias`
	 * statement `raw` is the ALIAS, so a file that reaches the module ONLY
	 * through `import a.b.C as D;` answered as no importer at all, and
	 * `apq move` stranded exactly that file on a module that no longer
	 * defined the type. A statement whose path did not decode carries no
	 * path and is not matched.
	 */
	public function filesImportingModule(modulePath: String): Array<FileInfo> {
		final prefix: String = '$modulePath.';
		inline function under(imported: String): Bool return imported == modulePath || imported.startsWith(prefix);
		return _files.filter(f -> f.imports.exists(imp -> {
			final path: Null<String> = pathImportedBy(imp);
			imp.kind != ImportKind.Wild && path != null && under(path);
		}));
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
			for (fi in _files) for (t in fi.types) if (t.name == typeName)
				for (m in t.members) if (m.name == memberName) { type: t, member: m }
		];
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
		final host: Null<ResolvedType> = resolveStartType(module, fromFile);
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
		final start: Null<ResolvedType> = findDeclaredType(file, typeName);
		return start != null && inheritsInstanceMemberWalk(start, member, []) == true;
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
	public function structuralConformanceForbidsFinal(typeName: String, field: String): Bool {
		return structuralConformancePins(typeName, field, true);
	}

	/**
	 * The write-restriction counterpart of `structuralConformanceForbidsFinal`: whether rewriting
	 * `field` of `typeName` to a read-only property may break a structural unification. Narrower
	 * by exactly one kind — a `(default, null)` field of function type DOES satisfy a structural
	 * `function x():T` (measured), so only a structural `var x:T` pins it.
	 */
	public function structuralConformanceForbidsWriteRestriction(typeName: String, field: String): Bool {
		return structuralConformancePins(typeName, field, false);
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
		final start: Null<ResolvedType> = resolveStartType(typeName, fromFile);
		return start != null && lacksMemberClosure(start, member, []);
	}

	/**
	 * Whether `file` EXPLICITLY imports the name `name` as a static member — `import pkg.Type.name;`
	 * or an aliased `import pkg.Type.other as name;`. POSITIVE evidence that a bare `name` written in
	 * that file binds globally, and deliberately not the same kind of claim as
	 * `typeProvablyLacksMember`: that one proves no ancestor DECLARES the name, and declaration
	 * absence is precisely what a `@:build` / `@:autoBuild` macro undoes by adding members that appear
	 * in no source text. An import is written in the file and no macro can conjure one, so this answer
	 * survives a macro-extended closure.
	 *
	 * A wildcard `import pkg.Type.*;` answers FALSE — it introduces names this index cannot enumerate,
	 * so no individual one is proven. A `using` answers false too: a static extension is reachable
	 * only as `receiver.name()`, never as a bare `name`.
	 */
	public function fileImportsMemberName(file: String, name: String): Bool {
		final host: Null<FileInfo> = _files.find(f -> f.file == file);
		if (host == null) return false;
		for (imp in host.imports) switch imp.kind {
			case ImportKind.Import:
				final dot: Int = imp.raw.lastIndexOf('.');
				if ((dot < 0 ? imp.raw : imp.raw.substr(dot + 1)) == name) return true;
			case ImportKind.Alias:
				if (imp.alias == name) return true;
			case ImportKind.Wild, ImportKind.Using:
		}
		return false;
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
		for (r in resolvedDeclsNamed(typeName))
			for (iface in r.type.interfaces)
				if (!typeProvablyLacksMember(iface, field, r.file.file)) return true;
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
	 * Whether any SKIP-PARSED file's raw text mentions `name` as a whole word.
	 *
	 * The confinement gates — `prefer-final-field`, `prefer-read-only-field`,
	 * `prefer-final-public-field`, `unused-private` and their kin — all ask the same thing: could
	 * a file the index cannot read hold a reference or a write the in-file proof missed? They used
	 * to answer it with `skippedFiles().length > 0`, a whole-PROJECT veto: ONE unparseable file
	 * anywhere in the scope silenced those rules for every other file. Measured on an 855-file
	 * tree, adding a directory with three such files to the scope removed 1147 findings and the
	 * `prefer-final-field` family entirely — a SUPERSET scope reporting FEWER findings, with
	 * nothing said about it.
	 *
	 * The question is per-NAME, and the identifier is what answers it: a reference or a write to
	 * `name` — through a subtype, an `@:access` grant, `@:allow`, or reflection by string — must
	 * spell `name` in the file's text. So a skipped file that never contains the identifier cannot
	 * be the writer, whatever it declares. Keying on the MEMBER name rather than the owning type's
	 * dodges the alias hole (a skipped file may extend a `typedef` of the owner and never spell the
	 * owner's name; it cannot write the member without spelling the member).
	 *
	 * Conservative in the same direction as before wherever it cannot see: a skipped file whose
	 * source was not retained answers true.
	 */
	public function skippedMayReference(name: String): Bool {
		return name.length == 0 ? _skipped.length > 0 : _skipped.exists(file -> skippedSourceMentions(_sources[file], name));
	}

	/**
	 * The same question in the shape a REFUSAL needs: WHICH skipped files may reference any of
	 * `names`, rather than whether one does.
	 *
	 * A gate that only refuses needs the `Bool`; a gate that must TELL the user why needs the
	 * subject. `naming`'s cross-file rename is the second kind — it asks about three identifiers at
	 * once (the member's current name, its owner's, and the corrected name it would introduce) and
	 * writes the answer into `Violation.declineReason`, where "some file did not parse" with no file
	 * named is barely better than the whole-run veto it replaced.
	 *
	 * An empty name means the same here as there — every skipped file, since nothing was asked.
	 */
	public function skippedFilesMentioning(names: Array<String>): Array<String> {
		return _skipped.filter(file -> names.exists(name -> name.length == 0 || skippedSourceMentions(_sources[file], name)));
	}

	/**
	 * Whether `typeName` OR anything in its transitive supertype / interface closure is built by a
	 * macro (`@:build` / `@:autoBuild` / `@:genericBuild`), resolved through the index.
	 *
	 * A build macro may rewrite a member arbitrarily, so no rule that changes a field's MUTABILITY or
	 * PLACEMENT can reason about the declaration it can see. The motivating shape: an `@:autoBuild`
	 * interface whose builder strips the initializer off every non-inline `var` field and moves the
	 * assignment into the constructor — after which `var` -> `final` is `Static final variable must be
	 * initialized`, and a field moved to `static` is `Cannot access static field from a class instance`
	 * raised by the builder itself. The class carries no metadata of its own; the grant is inherited
	 * through `implements`, which is why the closure and not the declaring file alone.
	 *
	 * `fromFile` is the file of the container the caller is looking at, and naming it is what keeps the
	 * answer about THAT type. Hop zero is not a written type reference at all — the consumer holds the
	 * declaration — so resolving it by simple name across the whole index conflated every homonym:
	 * measured on `~/dev/haxelib` (16182 files, ~100 libraries in ONE index, the eight consumer rules,
	 * `--all`), the gate removed 16339 findings, of which 14426 were same-simple-name collisions and
	 * 1913 genuine. ONE `private typedef GL = js.html.webgl.GL2` in heaps' `h3d/impl/GlDriver.hx` — a
	 * file carrying a `@:build` of its own — silenced every `GL` in lime, hlsdl, hashlink/sdl and
	 * hashlink/mesa, 9800 findings from one line. Every consumer passes its file; a caller that has
	 * none keeps the whole-index answer it always got.
	 *
	 * Every hop ABOVE zero IS a written reference, and a Haxe supertype is a simple name most of the
	 * time, so those resolve through the referring file's own import scope (`buildMacroSupertypes`) and
	 * widen back to the union whenever that settles nothing. The widening is what is left of the
	 * conservatism, and it is cheap: of the 1913 the gate still removes, 205 are a token in the type's
	 * own file, 1375 a grant reached through a fully resolved chain, and 333 reached ONLY through a
	 * widened hop — a qualified path naming a type outside the scope, `haxe.io.Output` being the whole
	 * of that class. Deciding those would need the compiler's own std path in the resolution scope;
	 * nothing the index holds settles them, so do not narrow the widening without adding it.
	 *
	 * The narrowing can only ever turn a "yes" into a "no", so the consumers that pay for a wrong one
	 * are the DELETING ones (`trivial-getter`, `inline-constant`, `static-constant`), not only the
	 * rewriting ones. It is applied to all eight anyway because it is not a heuristic tightening: a
	 * `@:build` on a type in another package is not a fact about this type. What stays heuristic — the
	 * file-scoped text scan below, the widening above — stays conservative for all of them.
	 *
	 * `@:autoBuild` reaches subtypes and implementors, so the walk follows `supertypes`, which carries
	 * `implements` targets as well as `extends`. The per-file test is textual
	 * (`MemberWriteScan.carriesBuildMacro`), so an unrelated `@:build` elsewhere in the same file counts
	 * too — the conservative direction, which only ever keeps a field as it is (`ansi`'s `ANSI.hx`,
	 * whose second type carries the tag, is 6 of the 205). An unretained source ends the same way, as in
	 * `transitivelyCarriesRtti`.
	 */
	public function transitivelyCarriesBuildMacro(typeName: String, ?fromFile: String): Bool {
		final queue: Array<ResolvedType> = buildMacroRoots(typeName, fromFile);
		final seen: Array<String> = [];
		var i: Int = 0;
		while (i < queue.length) {
			final cur: ResolvedType = queue[i];
			i++;
			if (!markSeen(cur, seen)) continue;
			final source: Null<String> = _sources[cur.file.file];
			if (source == null || MemberWriteScan.carriesBuildMacro(source)) return true;
			for (hop in buildMacroSupertypes(cur)) queue.push(hop);
		}
		return false;
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

	/** The `seen`-set identity of a resolved type: its declaring file plus its name — see `markSeen`. */
	private inline function seenKey(cur: ResolvedType): String {
		return '${cur.file.file}#${cur.type.name}';
	}

	/**
	 * Mark `cur`'s resolved `(file, name)` identity in `seen` and answer whether this is its FIRST
	 * visit — the cycle guard every supertype walk opens with. A re-entered node answers false, and
	 * the caller ends that branch with its own not-found value.
	 */
	private inline function markSeen(cur: ResolvedType, seen: Array<String>): Bool {
		final key: String = seenKey(cur);
		if (seen.contains(key)) return false;
		seen.push(key);
		return true;
	}

	/** The import path naming type `t` in file `fi`: its module when `t` is the module main type, else `module.name`. */
	private inline function importPathFor(fi: FileInfo, t: TypeDeclInfo): String {
		return t.isMain ? fi.module : '${fi.module}.${t.name}';
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

	/**
	 * The declarations `transitivelyCarriesBuildMacro` starts its closure walk from: the ONE
	 * `typeName` declares in `fromFile` when the caller named the file it is linting, else every
	 * same-simple-name declaration in the index.
	 *
	 * The starting type is not a written type REFERENCE — it is the container the consumer is
	 * looking at, whose declaring file it already holds — so `fromFile` makes hop zero exact
	 * rather than a guess. Falling back to the whole-index union keeps the answer a caller with no
	 * file (or a name the named file does not declare) used to get.
	 */
	private function buildMacroRoots(typeName: String, fromFile: Null<String>): Array<ResolvedType> {
		if (fromFile != null) {
			final own: Null<ResolvedType> = findDeclaredType(fromFile, typeName);
			if (own != null) return [own];
		}
		return resolvedDeclsNamed(typeName);
	}

	/**
	 * `cur`'s direct supertypes and interfaces as RESOLVED declarations — the hop
	 * `transitivelyCarriesBuildMacro` takes upward.
	 *
	 * Unlike hop zero these ARE written type references, and a Haxe one is a simple name most of
	 * the time, so they are resolved against the REFERRING file's import scope (`supertypesRaw`
	 * keeps the verbatim path a simple-name reduction throws away). When that settles nothing — an
	 * alias import, a qualified path naming a type outside the scope (`haxe.io.Output`), a scope
	 * form the index does not model — the hop widens back to the same-simple-name union the walk
	 * always used, so a failure to resolve can only ever keep the conservative answer.
	 * `interfaces` is a subset of `supertypes` (`collectImplementsRaw` reads the `ImplementsClause`
	 * that `collectSupertypesRaw` also reads), so walking `supertypes` alone reaches every
	 * `@:autoBuild` grant the old two-list walk did.
	 */
	private function buildMacroSupertypes(cur: ResolvedType): Array<ResolvedType> {
		final out: Array<ResolvedType> = [];
		final raws: Array<String> = cur.type.supertypesRaw;
		final simples: Array<String> = cur.type.supertypes;
		for (i in 0...simples.length) {
			final resolved: Array<ResolvedType> = resolveTypeRefAll(i < raws.length ? raws[i] : simples[i], cur.file);
			final hops: Array<ResolvedType> = resolved.length > 0 ? resolved : resolvedDeclsNamed(simples[i]);
			for (r in hops) out.push(r);
		}
		return out;
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
		if (accepts == receiver || isSubtype(receiver, accepts)) return true;
		if (accepts != ITERABLE_TYPE_NAME && accepts != ITERATOR_TYPE_NAME) return false;
		final args: Null<Array<String>> = NominalTypes.typeArgumentSourcesOf(paramSource);
		if (args == null || args.length != 1) return false;
		final element: String = args[0];
		return RefactorSupport.isIdentifier(element) && resolveTypeRef(element, host.file) == null
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
		final start: Null<ResolvedType> = resolveStartType(typeName, fromFile) ?? resolveStartType(typeName, null);
		if (start == null || !markSeen(start, seen)) return null;
		final host: String = start.file.file;
		final own: Null<MemberInfo> = start.type.members.find(m -> m.name == member);
		if (own != null) return { member: own, file: host };
		// A `typedef` hosts its members through a link neither `members` nor `supertypesRaw`
		// carries — both are EMPTY on an alias decl — so without this hop every aliased container
		// answers "declares nothing", which is the whole reason `List` and `Map` were unprovable.
		// Followed from the ALIAS's own file and by its WRITTEN path, the same two rules the
		// supertype hop below uses; `markSeen` above stops an alias cycle just as it stops a
		// supertype one. An anon-struct alias is excluded: its fields are the index's own members.
		if (start.type.kind == TYPEDEF_DECL_KIND && !start.type.isAnonStruct) {
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
			|| subtypesOf(typeName).exists(sub -> familyDeclaresEveryMember(sub.type.name, members, seen));
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
		return resolvedDeclsNamed(typeName).exists(r -> members.foreach(m -> !lacksMemberClosure(r, m, [])));
	}

	/** The SIMPLE-name lookup of a type's declaration kind, or null when the scope declares it zero or ambiguously many times. */
	private function ownerDeclKind(owner: String): Null<String> {
		final ds: Array<TypeDeclInfo> = declsNamed(owner);
		return ds.length == 1 ? ds[0].kind : null;
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
	private function pathFinalMemberWalk(
		fromFile: String, startSource: String, memberPath: Array<String>, substitute: Bool, transparentWrappers: Array<String>
	): Null<String> {
		if (memberPath.length == 0) return null;
		final origin: Null<FileInfo> = _files.find(f -> f.file == fromFile);
		if (origin == null) return null;
		var args: Array<String> = [];
		var startName: String = startSource;
		if (substitute) {
			final startArgs: Null<Array<String>> = NominalTypes.typeArgumentSourcesOf(startSource);
			if (startArgs != null) {
				final head: Null<String> = NominalTypes.outerNominalOf(startSource);
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
			// An INTERMEDIATE link is a receiver for the next segment, so a member-transparent
			// wrapper on it is peeled (`res: Null<Res>` in `box.res.count`). The FINAL member's
			// source, returned below, is never peeled — a read of `Null<T>` IS `Null<T>`.
			final carried: String = NominalTypes.memberLookupReceiverSource(effective, transparentWrappers);
			if (substitute) args = NominalTypes.typeArgumentSourcesOf(carried) ?? [];
			final nominal: String = StringTools.trim(carried.split('<')[0]);
			current = resolveTypeRef(nominal, cur.file);
		}
		if (current == null) return null;
		final last: ResolvedType = current;
		final member: String = memberPath[memberPath.length - 1];
		final finalSource: Null<String> = memberTypeSourceWalk(last, member, []);
		return finalSource == null || !substitute ? finalSource : substitutedMemberSource(last, member, finalSource, args);
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
		final at: Int = params.indexOf(memberSource.trim());
		final declaredHere: Bool = cur.type.members.exists(m -> m.name == member);
		final effective: String = declaredHere && at >= 0 && at < args.length ? args[at] : memberSource;
		return mentionsTypeParam(effective, params) ? null : effective;
	}

	/**
	 * The single decl `typeName` names, or null when it cannot be pinned to one. Three arms, in
	 * order of how much the caller knows:
	 *
	 *  - `fromFile` names an indexed file: resolve against THAT file's package + imports, so a
	 *    simple name several packages share means what the analysed file says it means. This is
	 *    the `implements` / receiver-type case. A name the file's scope does not reach is a
	 *    refusal, not a fall-through — the caller supplied the context, so it decides.
	 *  - `typeName` is a dotted path: `resolveQualifiedRefAll` matches it on import path, needing
	 *    no referring file. This is the `using`-conflict case, which holds a full module path.
	 *  - neither: the name must be globally unique among indexed decls — the original rule, kept
	 *    as the fallback so an out-of-index `fromFile` degrades to it instead of refusing.
	 */
	private function resolveStartType(typeName: String, fromFile: Null<String>): Null<ResolvedType> {
		if (fromFile != null) {
			final host: Null<FileInfo> = _files.find(f -> f.file == fromFile);
			if (host != null) return resolveTypeRef(typeName, host);
		}
		if (typeName.indexOf('.') >= 0) {
			final qualified: Array<ResolvedType> = resolveQualifiedRefAll(typeName);
			return qualified.length == 1 ? qualified[0] : null;
		}
		final ds: Array<ResolvedType> = resolvedDeclsNamed(typeName);
		return ds.length == 1 ? ds[0] : null;
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
	 * Recursive closure walk for `typeProvablyLacksMember`, cycle-guarded by `seen` through
	 * `markSeen` — keyed by declaring file, so two same-named types are distinct nodes.
	 * Each supertype edge resolves from its VERBATIM reference against `cur`'s own file
	 * (`resolveTypeRef`); a `Dynamic` one is skipped rather than counted as unresolvable
	 * (`dynamicSupertypeRef`).
	 */
	private function lacksMemberClosure(cur: ResolvedType, member: String, seen: Array<String>): Bool {
		// A supertype CYCLE still enumerates the whole closure, so re-entering a type proves
		// nothing new and nothing is lost by stopping — unlike the alias cycle below.
		if (!markSeen(cur, seen)) return true;
		final t: TypeDeclInfo = cur.type;
		if (t.members.exists(m -> m.name == member)) return false;
		// An ALIASING_DECL_KINDS decl reaches members through a link `supertypes` never records, so
		// its own empty member list proves NOTHING — the same hole `closureExcludes` refuses outright,
		// resolved here instead of refused: a plain `typedef A = C` continues the proof on `C`, while
		// an unreadable alias and a `@:forward` abstract (every underlying member is exposed under a
		// name the index cannot enumerate here) are not provable at all.
		if (t.kind == TYPEDEF_DECL_KIND && !t.isAnonStruct) {
			// The RAW path, not the simple name: `typedef List<T> = haxe.ds.List<T>` written in
			// the root package with no import resolves its own simple name back to ITSELF, so the
			// hop lands on the alias, hits the cycle test below and proves nothing.
			final target: Null<String> = t.aliasTargetRaw;
			if (target == null) return false;
			final next: Null<ResolvedType> = resolveTypeRef(target, cur.file);
			// An alias CYCLE proves nothing — unlike a supertype cycle, whose closure is still
			// fully enumerated, a chain that re-enters itself never reaches a member host at all.
			return next == null || seen.contains(seenKey(next)) ? false : lacksMemberClosure(next, member, seen);
		}
		if (t.abstractForwardUnderlying != null) return false;
		// Each supertype is resolved from its VERBATIM written reference against THIS type's own
		// file (`resolveTypeRef` -> `simpleRefInScope`), so a simple name shared by several
		// packages picks the one actually in scope instead of failing the whole proof. A
		// reference resolving to zero OR to several decls is refused identically: unresolved.
		for (raw in t.supertypesRaw) if (!dynamicSupertypeRef(raw)) {
			final anc: Null<ResolvedType> = resolveTypeRef(raw, cur.file);
			if (anc == null || !lacksMemberClosure(anc, member, seen)) return false;
		}
		return true;
	}

	/** Every indexed decl named `typeName` (simple name), each paired with its declaring file. */

	private function resolvedDeclsNamed(typeName: String): Array<ResolvedType> {
		return [
			for (fi in _files) for (t in fi.types) if (t.name == typeName) { file: fi, type: t }
		];
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

	/** The `{file, type}` for the type named `typeName` declared in `file`, or null. */
	private function findDeclaredType(file: String, typeName: String): Null<ResolvedType> {
		final fi: Null<FileInfo> = _files.find(f -> f.file == file);
		if (fi == null) return null;
		final host: FileInfo = fi;
		final t: Null<TypeDeclInfo> = host.types.find(td -> td.name == typeName);
		return t == null ? null : { file: host, type: t };
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
		if (!markSeen(cur, seen)) return null;
		for (raw in cur.type.supertypesRaw) {
			final anc: Null<ResolvedType> = resolveTypeRef(raw, cur.file);
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
		if (dot >= 0) {
			final qualified: Array<ResolvedType> = resolveQualifiedRefAll(raw);
			return qualified.length > 0 ? qualified : moduleRelativeRefAll(raw, fromFile);
		}
		final matches: Array<ResolvedType> = [];
		final seen: Array<String> = [];
		for (fi in _files) for (t in fi.types) if (t.name == raw && simpleRefInScope(fromFile, fi, t)) {
			final key: String = '${fi.file}#${t.name}';
			if (!seen.contains(key)) {
				seen.push(key);
				matches.push({ file: fi, type: t });
			}
		}
		return matches;
	}

	/**
	 * Every decl the MODULE-RELATIVE form `Mod.Sub` names FROM `fromFile` — a sub-module type
	 * qualified by its own module's name, which Haxe accepts wherever the MODULE itself can be
	 * named. That is `moduleRefInScope`, a strictly narrower rule than the one a bare type name
	 * goes through, and the difference is measured rather than assumed.
	 *
	 * `resolveQualifiedRefAll` cannot answer this form and must not: it matches the ROOT-relative
	 * `pkg.Mod.Sub` and is deliberately context-free, while `Mod.Sub` names different types from
	 * different files. So this runs only as `resolveTypeRefAll`'s FALLBACK, after the root-relative
	 * match found nothing — it can turn a 0-match into a match, never change one.
	 */
	private function moduleRelativeRefAll(raw: String, fromFile: FileInfo): Array<ResolvedType> {
		final dot: Int = raw.lastIndexOf('.');
		final simple: String = raw.substr(dot + 1);
		final prefix: String = raw.substring(0, dot);
		final matches: Array<ResolvedType> = [];
		final seen: Array<String> = [];
		for (fi in _files) for (t in fi.types) if (
			!t.isMain && t.name == simple && moduleSimpleName(fi.module) == prefix && moduleRefInScope(fromFile, fi)
		) {
			final key: String = '${fi.file}#${t.name}';
			if (!seen.contains(key)) {
				seen.push(key);
				matches.push({ file: fi, type: t });
			}
		}
		return matches;
	}

	/**
	 * Every decl a QUALIFIED type reference names, matched on import path. Needs no referring
	 * file: a dotted path means the same thing from everywhere, which is what lets a caller
	 * holding a full module path (the `using`-conflict scan) resolve with no context at all.
	 * The one dotted form it cannot answer — the module-relative `Mod.Sub` — is exactly the one
	 * that DOES depend on the referring file; `moduleRelativeRefAll` owns it.
	 */
	private function resolveQualifiedRefAll(raw: String): Array<ResolvedType> {
		final simple: String = raw.substr(raw.lastIndexOf('.') + 1);
		final matches: Array<ResolvedType> = [];
		final seen: Array<String> = [];
		for (fi in _files) for (t in fi.types) if (t.name == simple && importPathFor(fi, t) == raw) {
			final key: String = '${fi.file}#${t.name}';
			if (!seen.contains(key)) {
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
			case ImportKind.Import, ImportKind.Using:
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

	/** Exactly one indexed decl is named `name`, and it is a class. */
	private function isUniqueClass(name: String): Bool {
		final ds: Array<TypeDeclInfo> = declsNamed(name);
		return ds.length == 1 && ds[0].kind == CLASS_DECL_KIND;
	}

	/** Every indexed type decl whose simple name is `name`, across all files. */
	private function declsNamed(name: String): Array<TypeDeclInfo> {
		return [for (r in resolvedDeclsNamed(name)) r.type];
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
				final importAliases: Map<String, Array<String>> = importAliasEdges(fi, true);
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
			final importAliases: Map<String, Array<String>> = importAliasEdges(fi, true);
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
		final ds: Array<ResolvedType> = resolvedDeclsNamed(name);
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
		if (!markSeen(cur, seen)) return true;
		// An ALIAS (`typedef A = C`, a `@:forward` abstract) reaches other types through `@:from` /
		// `@:to` edges the closure cannot follow, so its own supertype list proves nothing. An
		// ANONYMOUS STRUCTURE has no such edges — its only inheritance links are the `> Base`
		// structural extensions already in `supertypesRaw`, and a structure can never be a subtype
		// of a class — so the closure over it IS complete and the refusal does not apply.
		if (ALIASING_DECL_KINDS.contains(cur.type.kind) && !cur.type.isAnonStruct) return false;
		for (raw in cur.type.supertypesRaw) {
			final anc: Null<ResolvedType> = resolveTypeRef(raw, cur.file);
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
		final ds: Array<ResolvedType> = resolvedDeclsNamed(name);
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
		final aliases: Map<String, Array<String>> = importAliasEdges(decl.file, false);
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
	 * `supertypeChainResolved`'s cycle-guarded recursion. A name the index holds NO declaration for
	 * answers false — that is the whole question, and answering it here is what lets the recursive
	 * call stand alone where the caller used to test the next hop itself. A name already visited
	 * answers true: whatever made it unresolvable was reported by the visit that pushed it, and a
	 * false short-circuits the entire walk, so no later `seen` hit can mask one.
	 */
	private function supertypeChainWalk(typeName: String, seen: Array<String>): Bool {
		if (seen.contains(typeName)) return true;
		seen.push(typeName);
		final decls: Array<TypeDeclInfo> = declsNamed(typeName);
		if (decls.length == 0) return false;
		for (t in decls) for (sup in t.supertypes) if (!supertypeChainWalk(sup, seen)) return false;
		return true;
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

	/**
			 * The dotted MODULE PATH an import statement names — `imp.raw` for every kind except
			 * `Alias`, whose `raw` is the ALIAS the statement binds and whose path lives in
			 * `aliasTarget`. Null only for an alias statement whose path did not decode. Distinct from `importPathOf`,
	which answers about a TYPE: the path some other file would import it by.

	That null is read in OPPOSITE directions by the consumers, which any future tightening has
	to weigh — the same trade `ModuleScan.aliasTargetOf` records for its own: comparing it to a
	path makes `filesImportingModule` omit the file and `MoveSymbol`s cross-package gate refuse
	(both withhold), while `MoveSymbol`s importer loop then leaves that file unrepointed and
	`duplicate-import`s `?? raw` fallback keys two undecoded aliases alike. Undecodable is not a
	shape the grammar can currently produce — an `ImportAliasDecl` node with no `as` / `in` run
	past position 0 — so none of that is reachable today; it is written down because this is now
	the single seat everything routes through.
			 *
			 * The one seat of the MODULE-PATH question — not of every question about an import. A rule
		asking about the BOUND NAME (`unused-import`, `redundant-import`) is right to read `raw`,
		which for an alias is exactly the name it binds; those are deliberately left alone. What
		reading `raw` cannot answer is "which module does this statement name", and every consumer
		that asked it that way got it wrong differently: `filesImportingModule` did not list
			 * an alias importer at all, `MoveSymbol` left it unrepointed and separately mistook its
			 * own statement for a fully-qualified code reference, and `duplicate-import` keyed both
			 * branches of `#if js import p.A as U; #else import p.B as U; #end` as one import and
			 * deleted the second — while its own doc says two imports are duplicates only when the
			 * module PATH matches, which is exactly what `raw` is not here.
	 */
	public static function pathImportedBy(imp: ImportInfo): Null<String> {
		return imp.kind == ImportKind.Alias ? imp.aliasTarget : imp.raw;
	}

	/** The last segment of a dotted module path — `pkg.Mod` -> `Mod`, a root-package `Mod` unchanged. */
	private static inline function moduleSimpleName(module: String): String {
		final dot: Int = module.lastIndexOf('.');
		return dot < 0 ? module : module.substr(dot + 1);
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

	/** Whether `c` can be part of an identifier — the word boundary `mentionsWord` tests against. */
	private static inline function isWordChar(c: Int): Bool {
		return c == '_'.code || c >= 'a'.code && c <= 'z'.code || c >= 'A'.code && c <= 'Z'.code || c >= '0'.code && c <= '9'.code;
	}

	/**
	 * Whether a skip-parsed file whose retained `source` this is may reference `name` — the one
	 * predicate `skippedMayReference` and `skippedFilesMentioning` both answer with, so neither can
	 * drift from the other. A file whose source was not retained answers true: unreadable is not
	 * absent.
	 */
	private static inline function skippedSourceMentions(source: Null<String>, name: String): Bool {
		return source == null || mentionsWord(source, name);
	}

	/**
	 * ONE file's import-alias edges: the alias a `import pkg.Util as U;` statement binds -> the
	 * SIMPLE name of every path it points at. An ARRAY because a `#if` region may bind one
	 * alias name to a different target per branch. The import twin of `aliasEdges`, and per-FILE rather
	 * than project-wide because that is the scope such an alias actually has — a `U` bound in one
	 * module says nothing about a `U` written in another.
	 *
	 * `followGuarded` is the whole `#if` question, and it has OPPOSITE answers on the two sides of
	 * the subtype relation, so it is the caller's to give. Going DOWN (`subtypesOf`) the answer is a
	 * veto — offering both branch targets makes MORE types answer "something subtypes me", which is
	 * the withholding direction, and dropping either is what compile-proved a deleted private
	 * constructor. Going UP (`closureContains`) the answer is read AFFIRMATIVELY by two autofixes
	 * that DELETE — `unreachable-catch` removes a clause, `redundant-upcast` removes a cast — and
	 * offering both makes one type a subtype of two modules no single build agrees on: measured,
	 * `#if cpp import pkg.A as U; #else import pkg.Bee as U; #end class Both extends U` reported the
	 * `catch (e:Both)` after `catch (e:A)` AND the one after `catch (e:Bee)` unreachable, and `--fix`
	 * deleted both clauses. So the upward walk refuses a guarded alias, which is also what
	 * `SymbolIndexBuilder.aliasTargetPathOf` already does for a guarded TYPEDEF — the two alias kinds
	 * fail closed together rather than one each way.
	 *
	 * Simple names on both sides: `supertypes` is already reduced that way, and so is every name
	 * `subtypesOf` is asked about. An alias whose path did not decode carries no edge; a
	 * self-alias (`import pkg.U as U`, which Haxe accepts) carries none either, since the walk
	 * already holds that name.
	 */
	private static function importAliasEdges(fi: FileInfo, followGuarded: Bool): Map<String, Array<String>> {
		final edges: Map<String, Array<String>> = [];
		for (imp in fi.imports) if (imp.kind == ImportKind.Alias && (followGuarded || !imp.guarded)) {
			final alias: Null<String> = imp.alias;
			final target: Null<String> = imp.aliasTarget;
			if (alias == null || target == null) continue;
			final simple: String = RefactorSupport.lastSegment(target);
			if (simple == alias) continue;
			final bucket: Array<String> = edges[alias] ?? [];
			if (!bucket.contains(simple)) bucket.push(simple);
			edges[alias] = bucket;
		}
		return edges;
	}

	/**
	 * Whether the MODULE of `fi` can be named by its own simple name from `fromFile` — the
	 * visibility a module-relative `Mod.Sub` reference needs, which is NOT the one a bare TYPE
	 * name needs, so `simpleRefInScope` cannot stand in for it. Compiled on 4.3.7: same package
	 * resolves and `import pkg.*;` resolves, while BOTH `import pkg.Mod;` and `using pkg.Mod;`
	 * fail with `Type not found : Mod` — a module import puts the module's TYPES in simple-name
	 * scope, but the qualifier of `Mod.Sub` is read as a module PATH, which only the package
	 * itself or a wildcard over it supplies.
	 *
	 * A ROOT-package module needs no arm: its own import path already IS `Mod.Sub`, so the
	 * root-relative match in `resolveQualifiedRefAll` answers it and the fallback never runs.
	 */
	private static function moduleRefInScope(fromFile: FileInfo, fi: FileInfo): Bool {
		if (fi.pkg == fromFile.pkg) return true;
		final wild: String = '${fi.pkg}.*';
		return fromFile.imports.exists(imp -> imp.kind == ImportKind.Wild && imp.raw == wild);
	}

	/** Whether `text` names any of `params` as a WHOLE identifier token — `Item` does not mention `T`, `Array<T>` does. */
	private static function mentionsTypeParam(text: String, params: Array<String>): Bool {
		if (params.length == 0) return false;
		var i: Int = 0;
		while (i < text.length) {
			if (!RefactorSupport.isIdentStartChar(text.fastCodeAt(i))) {
				i++;
				continue;
			}
			var end: Int = i + 1;
			while (end < text.length && RefactorSupport.isIdentChar(text.fastCodeAt(end))) end++;
			if (params.contains(text.substring(i, end))) return true;
			i = end;
		}
		return false;
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

	private static function mentionsWord(source: String, name: String): Bool {
		var at: Int = source.indexOf(name);
		while (at >= 0) {
			final before: Int = at - 1;
			final after: Int = at + name.length;
			final leftFree: Bool = before < 0 || !isWordChar(source.fastCodeAt(before));
			final rightFree: Bool = after >= source.length || !isWordChar(source.fastCodeAt(after));
			if (leftFree && rightFree) return true;
			at = source.indexOf(name, at + 1);
		}
		return false;
	}

}
