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

/**
 * A type declaration paired with its declaring file, for the inheritance-resolution walk.
 *
 * Public because the index's own query layers — `SubtypeGraph`, `MemberLookup`, `StructuralTypes`,
 * `MemberPathWalk`, `TypeTraits` — are separate modules, and a module-private typedef is invisible
 * to them.
 */
typedef ResolvedType = {
	var file: FileInfo;
	var type: TypeDeclInfo;
};

/**
 * The project-wide symbol index: a collection of per-file `FileInfo` records answering cross-file
 * questions a single-file parse cannot. It holds the indexed DATA — the files, their sources, the
 * paths the parser skipped — and hands that data to one query layer per QUESTION, each reachable
 * as a field on the index:
 *
 *  - `refs` (`TypeRefIndex`) — which files declare a name, and which declaration a written type
 *    reference denotes in a given file's scope. Every layer below resolves through it.
 *  - `subtypes` (`SubtypeGraph`) — the inheritance closure in both directions.
 *  - `members` (`MemberLookup`) — what a named type declares or inherits.
 *  - `structural` (`StructuralTypes`) — unification with an anonymous or builtin structure.
 *  - `paths` (`MemberPathWalk`) — the type a multi-hop `a.b.c` member walk lands on.
 *  - `text` (`RawSourceScan`) — the word-boundary scans over raw source bytes, the files the
 *    parser SKIPPED included.
 *  - `traits` (`TypeTraits`) — `@:rtti`, build-macro and abstract-`this`-rebinding closures.
 *
 * The layers are built in dependency order in the constructor and take exactly what they depend
 * on — the resolver, a sibling layer — never the index itself. Built once per run and queried by
 * rename / move ops and the type-aware checks; every cache any layer keeps is instance state on
 * that run-scoped object, never process-scoped.
 */
@:nullSafety(Strict)
@:allow(anyparse.query.SubtypeGraph)
@:allow(anyparse.query.MemberLookup)
@:allow(anyparse.query.StructuralTypes)
final class SymbolIndex {

	/** The grammar kind a `class` declaration projects as. */
	private static final CLASS_DECL_KIND: String = 'ClassDecl';

	/** The grammar kind a `typedef` declaration projects as — the only member host whose members sit under an `Anon`. */
	private static final TYPEDEF_DECL_KIND: String = 'TypedefDecl';

	/**
	 * The grammar kind an anonymous structure projects as, in BOTH a typedef body and a type expression.
	 * The decl kinds free of implicit-conversion / aliasing semantics — see `resolvesToPlainNominal`.
	 */
	private static final PLAIN_NOMINAL_KINDS: Array<String> = [CLASS_DECL_KIND, 'InterfaceDecl', 'EnumDecl'];

	/** The name -> DECLARATION layer: which files declare a name, and which declaration a written type reference denotes in a file's scope. */
	public final refs: TypeRefIndex;

	/** The INHERITANCE layer: subtype enumeration and supertype-closure proofs over the indexed `supertypes` edges. */
	public final subtypes: SubtypeGraph;

	/** The MEMBER layer: what a named type declares or inherits, and with what declared type, return type and visibility. */
	public final members: MemberLookup;

	/** The STRUCTURAL layer: unification with an anonymous structure, and membership of a builtin structural type. */
	public final structural: StructuralTypes;

	/** The receiver-PATH layer: the declared type source a multi-hop `a.b.c` member walk lands on. */
	public final paths: MemberPathWalk;

	/** The RAW-TEXT layer: word-boundary scans over source bytes, the files the parser SKIPPED included. */
	public final text: RawSourceScan;

	/** The type-TRAIT layer: `@:rtti`, build-macro and abstract-`this`-rebinding closures. */
	public final traits: TypeTraits;

	private final _files: Array<FileInfo>;
	private final _skipped: Array<String>;

	/** Per-file source text, retained so a subtype-ward body scan (`SubtypeGraph.subtypeReferencesField`) can inspect a subtype's raw declaration span for a backing-field reference. */
	private final _sources: Map<String, String>;

	private function new(files: Array<FileInfo>, skipped: Array<String>, sources: Map<String, String>, plugin: GrammarPlugin) {
		_files = files;
		_skipped = skipped;
		_sources = sources;
		refs = new TypeRefIndex(files);
		subtypes = new SubtypeGraph(files, sources, refs);
		members = new MemberLookup(files, refs);
		structural = new StructuralTypes(files, refs, subtypes, members);
		paths = new MemberPathWalk(files, refs, members);
		text = new RawSourceScan(files, skipped, sources, plugin);
		traits = new TypeTraits(files, sources, refs);
	}

	/** Every indexed file's `FileInfo`, in input order. */
	public inline function allFiles(): Array<FileInfo> {
		return _files.copy();
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
		return host != null && refs.resolveTypeRef(name, host) != null;
	}

	/**
	 * The import path that names `typeName`, when EXACTLY ONE file
	 * declares it: the file's `module` when the type is the module's
	 * main type, else `module + '.' + typeName` (a sub-type). Null when
	 * zero or more than one file declares it — the path is ambiguous and
	 * a move cannot pick one without more context.
	 */
	public function importPathOf(typeName: String): Null<String> {
		final declarers: Array<FileInfo> = refs.declaringFiles(typeName);
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
		for (file in refs.declaringFiles(typeName)) {
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
	 * The single declaring file + decl span of the type named `typeName`, or null when
	 * zero or more than one file declares it (ambiguous — a write-confinement query
	 * cannot pin a unique decl range and must bail). The decl span is the type's full
	 * source range, used to tell an internal write from an external one.
	 */
	public function declarationSiteOf(typeName: String): Null<{ file: String, span: Span }> {
		final declarers: Array<FileInfo> = refs.declaringFiles(typeName);
		if (declarers.length != 1) return null;
		final f: FileInfo = declarers[0];
		final t: Null<TypeDeclInfo> = f.types.find(td -> td.name == typeName);
		return t == null ? null : { file: f.file, span: t.span };
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
		final ds: Array<TypeDeclInfo> = refs.declsNamed(typeName);
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
		return fi == null ? [] : refs.resolveTypeRefAll(raw, fi);
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
		return new SymbolIndex(extracted.files, extracted.skipped, extracted.sources, plugin);
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
			if (segment.length > 0 && SourceText.isUpperInitial(segment)) return out.join('.');
		}
		return path;
	}

	/**
	 * The dotted MODULE PATH an import statement names — `imp.raw` for every kind except
	 * `Alias`, whose `raw` is the ALIAS the statement binds and whose path lives in
	 * `aliasTarget`. Null only for an alias statement whose path did not decode. Distinct from `importPathOf`,
	 * which answers about a TYPE: the path some other file would import it by.
	 *
	 * That null is read in OPPOSITE directions by the consumers, which any future tightening has
	 * to weigh — the same trade `ModuleScan.aliasTargetOf` records for its own: comparing it to a
	 * path makes `filesImportingModule` omit the file and `MoveSymbol`s cross-package gate refuse
	 * (both withhold), while `MoveSymbol`s importer loop then leaves that file unrepointed and
	 * `duplicate-import`s `?? raw` fallback keys two undecoded aliases alike. Undecodable is not a
	 * shape the grammar can currently produce — an `ImportAliasDecl` node with no `as` / `in` run
	 * past position 0 — so none of that is reachable today; it is written down because this is now
	 * the single seat everything routes through.
	 *
	 * The one seat of the MODULE-PATH question — not of every question about an import. A rule
	 * asking about the BOUND NAME (`unused-import`, `redundant-import`) is right to read `raw`,
	 * which for an alias is exactly the name it binds; those are deliberately left alone. What
	 * reading `raw` cannot answer is "which module does this statement name", and every consumer
	 * that asked it that way got it wrong differently: `filesImportingModule` did not list
	 * an alias importer at all, `MoveSymbol` left it unrepointed and separately mistook its
	 * own statement for a fully-qualified code reference, and `duplicate-import` keyed both
	 * branches of `#if js import p.A as U; #else import p.B as U; #end` as one import and
	 * deleted the second — while its own doc says two imports are duplicates only when the
	 * module PATH matches, which is exactly what `raw` is not here.
	 */
	public static function pathImportedBy(imp: ImportInfo): Null<String> {
		return imp.kind == ImportKind.Alias ? imp.aliasTarget : imp.raw;
	}

}
