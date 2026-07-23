package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.runtime.Span;
import haxe.Exception;

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
 * One import / using statement extracted from a file's top-level
 * declarations. `raw` is the verbatim payload the grammar exposes for
 * the kind (the dotted path for `Import` / `Using`, the alias for
 * `Alias`, `pkg.*` for `Wild`); `alias` is the bound alias when the
 * kind is `Alias`, else null; `span` is the statement's source range.
 */
typedef ImportInfo = {
	var raw: String;
	var kind: ImportKind;
	var alias: Null<String>;
	var span: Span;
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

	/** True when this is a `typedef X = {…}` anonymous struct — its fields can never be properties, so field access on it is side-effect-free. */
	var isAnonStruct: Bool;

	/** This type's directly-declared members (name + getter-property flag), for type-aware purity. */
	var members: Array<MemberInfo>;
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

	/** The decl kinds free of implicit-conversion / aliasing semantics — see `resolvesToPlainNominal`. */
	private static final PLAIN_NOMINAL_KINDS: Array<String> = [CLASS_DECL_KIND, 'InterfaceDecl', 'EnumDecl'];

	/**
	 * The bodyless declaration heads a `CondSharedBodyDecl` region can carry,
	 * mapped to the decl kind the same declaration projects as when written
	 * whole. `HxDeclHead` has exactly these two branches (`class` / `abstract`
	 * are the only forms observed splitting a header across `#if`).
	 */
	private static final DECL_HEAD_KINDS: Map<String, String> = [
		'ClassHead' => CLASS_DECL_KIND,
		'AbstractHead' => 'AbstractDecl'
	];

	private final _files: Array<FileInfo>;
	private final _skipped: Array<String>;

	private function new(files: Array<FileInfo>, skipped: Array<String>) {
		_files = files;
		_skipped = skipped;
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
		return _files.exists(f -> f.types.exists(t -> t.supertypes.contains(typeName)));
	}

	/**
	 * Does any indexed file grant itself `@:access(typeName)` (matched by simple
	 * name)? The second gate — such a file can read the type's private members.
	 */
	public function hasAccessGrant(typeName: String): Bool {
		return _files.exists(f -> f.accessGrants.contains(typeName));
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
	 * Whether the type named `typeName` resolves in the index to an `abstract` — a
	 * decl whose grammar kind is in `abstractKinds` (Haxe `AbstractDecl` /
	 * `EnumAbstractDecl`). `true` when ANY matching decl is one (conservative under a
	 * simple-name collision: an abstract match wins), `false` when it resolves only to
	 * non-abstract decls, `null` when NO indexed type declares the name (external /
	 * unknown). Lets the `final`-conversion checks tell an abstract-typed binding —
	 * whose method call may reassign the underlying `this` — from a class-typed or
	 * unresolved one. Resolution is by SIMPLE name (the index models no packages).
	 */
	public function isAbstractType(typeName: String, abstractKinds: Array<String>): Null<Bool> {
		var found: Bool = false;
		for (fi in _files) for (t in fi.types) if (t.name == typeName) {
			if (abstractKinds.contains(t.kind)) return true;
			found = true;
		}
		return found ? false : null;
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
	 * Whether the type `typeName` — together with its ENTIRE supertype closure —
	 * provably declares no member named `member`. True only when `typeName` resolves
	 * to exactly one indexed decl, every transitive supertype likewise resolves, and
	 * none of them declares `member`. Any unresolved / ambiguous type anywhere in the
	 * closure yields false — the member could be declared out of the lint scope, so its
	 * absence is not provable. The green-light companion of `supertypeDeclaresMember`,
	 * used by `trivial-getter` to prove an implemented interface does not require the
	 * property's `get_` accessor before collapsing it to `(default, null)`.
	 */
	public function typeProvablyLacksMember(typeName: String, member: String): Bool {
		return lacksMemberClosure(typeName, member, []);
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

	/** Recursive closure walk for `typeProvablyLacksMember`, cycle-guarded by `seen`. */
	private function lacksMemberClosure(typeName: String, member: String, seen: Array<String>): Bool {
		if (seen.contains(typeName)) return true;
		seen.push(typeName);
		final ds: Array<TypeDeclInfo> = declsNamed(typeName);
		if (ds.length != 1) return false;
		final t: TypeDeclInfo = ds[0];
		if (t.members.exists(m -> m.name == member)) return false;
		for (sup in t.supertypes) if (!lacksMemberClosure(sup, member, seen)) return false;
		return true;
	}

	/** Recursive supertype walk for `supertypeDeclaresMember`, cycle-guarded by `seen`. */
	private function supertypeDeclares(typeName: String, field: String, seen: Array<String>): Bool {
		if (seen.contains(typeName)) return false;
		seen.push(typeName);
		for (fi in _files) for (t in fi.types) if (t.name == typeName) for (sup in t.supertypes) if (
			declaresMember(sup, field) || supertypeDeclares(sup, field, seen)
		)
			return true;
		return false;
	}

	/** Whether any indexed type named `typeName` directly declares a member named `field`. */
	private function declaresMember(typeName: String, field: String): Bool {
		for (fi in _files) for (t in fi.types) if (t.name == typeName && t.members.exists(m -> m.name == field)) return true;
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
	 * Resolve a written supertype reference `raw` (as it appears in `fromFile`) to the
	 * SINGLE in-set type it names, or null when it is external (no in-set match) or
	 * AMBIGUOUS (more than one distinct in-set match). A qualified `raw` matches an
	 * in-set type whose import path equals it; a simple `raw` matches a type in scope of
	 * `fromFile` — named by an explicit `import` / `using`, reached through a `pkg.*`
	 * wildcard, or declared in `fromFile`'s own package.
	 */
	private function resolveTypeRef(raw: String, fromFile: FileInfo): Null<ResolvedType> {
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
		return matches.length == 1 ? matches[0] : null;
	}

	/**
	 * Whether a bare simple reference in `fromFile` resolves to type `t` of file `fi`:
	 * `fi` shares `fromFile`'s package, or `fromFile` names `t` through an explicit
	 * `import` / `using` (its raw equals `t`'s import path) or a `pkg.*` wildcard over
	 * `fi`'s package.
	 */
	private function simpleRefInScope(fromFile: FileInfo, fi: FileInfo, t: TypeDeclInfo): Bool {
		if (fi.pkg == fromFile.pkg) return true;
		final path: String = importPathFor(fi, t);
		final wild: String = '${fi.pkg}.*';
		for (imp in fromFile.imports) switch imp.kind {
			case ImportKind.Import | ImportKind.Using:
				if (imp.raw == path) return true;
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
	 * Whether `name`'s transitive supertype closure is FULLY index-resolved AND excludes
	 * `target`. A supertype name absent or ambiguous in the index (an external type, or a
	 * project file not in the set) makes the relation unknown → false, as does reaching
	 * `target` itself. `seen` guards cycles.
	 */
	private function closureExcludes(name: String, target: String, seen: Array<String>): Bool {
		final ds: Array<TypeDeclInfo> = declsNamed(name);
		if (ds.length != 1) return false;
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
		final infos: Array<FileInfo> = [];
		final skipped: Array<String> = [];
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final shape: RefShape = plugin.refShape();
		final visibilityKinds: Array<String> = shape.visibilityModifierKinds ?? [];
		final overrideKind: Null<String> = shape.overrideModifierKind;
		for (entry in files) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (_: Exception) null;
			if (tree == null) {
				skipped.push(entry.file);
				continue;
			}
			final accessors: Map<Int, Bool> = provider != null ? provider.propertyAccessors(entry.source) : [];
			final writeAccessors: Map<Int, Bool> = provider != null ? provider.propertyWriteAccessors(entry.source) : [];
			final returnTypes: Map<Int, String> = provider != null ? provider.returnTypes(entry.source) : [];
			final typeSources: Map<Int, String> = provider != null ? provider.declaredTypeSources(entry.source) : [];
			infos.push(extractFileInfo(
				entry.file, entry.source, tree, accessors, writeAccessors, returnTypes, typeSources, visibilityKinds, overrideKind
			));
		}
		return new SymbolIndex(infos, skipped);
	}

	/**
	 * The MODULE portion of a dotted import path: the segments up to and
	 * INCLUDING the first upper-case-initial segment (packages are
	 * lower-case, modules / types upper-case). Any remaining segments are
	 * sub-type access and are dropped. So `anyparse.query.Refs.RefHit` →
	 * `anyparse.query.Refs` (module `Refs`, sub-type `RefHit`),
	 * `anyparse.query.Rename` → `anyparse.query.Rename` (no sub-type),
	 * `pkg.sub.Foo` → `pkg.sub.Foo`. A path with no upper-case segment
	 * (all lower-case) is returned verbatim — there is no module segment
	 * to anchor on.
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
	 * Build a `FileInfo` from a parsed `parseFile` tree: walk the
	 * module's declarations for the `PackageDecl`, the import /
	 * using statements, and the type declarations. The basename
	 * drives the module path and the per-type `isMain` flag.
	 *
	 * The walk runs over `declNodes`, not over `tree.children`
	 * directly, so a type declared inside a `#if ... #end` region is
	 * indexed like a plain top-level one. Imports and usings are
	 * still read from the TOP LEVEL only - a guarded `import` stays
	 * invisible to the index.
	 */
	private static function extractFileInfo(
		file: String, source: String, tree: QueryNode, accessors: Map<Int, Bool>, writeAccessors: Map<Int, Bool>,
		returnTypes: Map<Int, String>, typeSources: Map<Int, String>, visibilityKinds: Array<String>, overrideKind: Null<String>
	): FileInfo {
		final basename: String = RefactorSupport.baseNameOf(file);
		var pkg: String = '';
		final imports: Array<ImportInfo> = [];
		final types: Array<TypeDeclInfo> = [];

		for (node in declNodes(tree)) {
			final typeDecl: Null<TypeDeclMatch> = typeDeclAt(node);
			if (typeDecl != null) {
				final supersRaw: Array<String> = collectSupertypesRaw(node);
				types.push({
					name: typeDecl.name,
					kind: typeDecl.kind,
					span: typeDecl.fullSpan,
					isMain: typeDecl.name == basename,
					typeParamArity: declTypeParamArity(source, typeDecl),
					supertypes: supersRaw.map(simpleName),
					supertypesRaw: supersRaw,
					// A `typedef X = {…}` projects an `Anon` child; its fields can
					// never be properties, so field access on it is side-effect-free.
					isAnonStruct: typeDecl.kind == 'TypedefDecl' && node.children.exists(c -> c.kind == 'Anon'),
					members: collectMembers(
						node, source, accessors, writeAccessors, returnTypes, typeSources, visibilityKinds, overrideKind
					)
				});
				continue;
			}

			final nullableName: Null<String> = node.name;
			final nullableSpan: Null<Span> = node.span;
			if (nullableName == null || nullableSpan == null) {
				if (node.kind == 'PackageDecl' && nullableName != null) pkg = nullableName;
				continue;
			}
			final name: String = nullableName;
			final span: Span = nullableSpan;
			switch node.kind {
				case 'PackageDecl':
					pkg = name;
				case 'ImportDecl':
					imports.push({
						raw: name,
						kind: ImportKind.Import,
						alias: null,
						span: span
					});
				case 'ImportAliasDecl' | 'ImportAliasInDecl':
					imports.push({
						raw: name,
						kind: ImportKind.Alias,
						alias: name,
						span: span
					});
				case 'ImportWildDecl':
					imports.push({
						raw: name,
						kind: ImportKind.Wild,
						alias: null,
						span: span
					});
				case 'UsingDecl':
					imports.push({
						raw: name,
						kind: ImportKind.Using,
						alias: null,
						span: span
					});
				case _:
			}
		}

		final module: String = pkg == '' ? basename : '$pkg.$basename';
		return {
			file: file,
			pkg: pkg,
			module: module,
			imports: imports,
			types: types,
			accessGrants: collectAccessGrants(tree)
		};
	}

	/**
	 * The VERBATIM written names of the `extends` / `implements` targets under
	 * `node` — its supertypes, qualified when written qualified — by reading each
	 * `Named` child of an `ExtendsClause` / `ImplementsClause`. The parallel
	 * simple-name form is derived by the caller; this preserves the dotted path a
	 * simple-name reduction loses, so a reference can be resolved to a single type.
	 */
	private static function collectSupertypesRaw(node: QueryNode): Array<String> {
		final out: Array<String> = [];
		collectInto(node, n -> {
			if (n.kind == 'ExtendsClause' || n.kind == 'ImplementsClause') for (c in n.children) {
				final nm: Null<String> = c.name;
				if (nm != null) out.push(nm);
			}
		});
		return out;
	}

	/** Simple names of every type referenced in an `@:access(...)` metadata in `tree`. */
	private static function collectAccessGrants(tree: QueryNode): Array<String> {
		final out: Array<String> = [];
		collectInto(tree, n -> {
			if (n.kind == 'MetaCall' && n.name == '@:access') for (c in n.children) {
				final nm: Null<String> = c.name;
				if (nm != null) out.push(simpleName(nm));
			}
		});
		return out;
	}

	/** Visit `node` and every descendant, applying `visit` to each. */
	private static function collectInto(node: QueryNode, visit: QueryNode -> Void): Void {
		visit(node);
		for (child in node.children) collectInto(child, visit);
	}

	/** The last `.`-separated segment of `path` (its simple name). */
	private static function simpleName(path: String): String {
		final segments: Array<String> = path.split('.');
		final last: Null<String> = segments[segments.length - 1];
		return last ?? path;
	}

	/**
	 * The directly-declared members of the type rooted at `node` — every
	 * field-member-kind descendant (a type body's own `var`/`final`/`fn` members;
	 * a method's LOCAL vars are `VarStmt`, a different kind, so excluded) — paired
	 * with its getter-property flag from the `accessors` span map (absent = plain)
	 * and its modifier-run visibility / override info. Modifier siblings precede
	 * the member they attach to inside the same parent, so each visited node scans
	 * its CHILDREN with a running modifier state, reset at every member.
	 */
	private static function collectMembers(
		node: QueryNode, source: String, accessors: Map<Int, Bool>, writeAccessors: Map<Int, Bool>, returnTypes: Map<Int, String>,
		typeSources: Map<Int, String>, visibilityKinds: Array<String>, overrideKind: Null<String>
	): Array<MemberInfo> {
		final out: Array<MemberInfo> = [];
		collectInto(node, n -> {
			var runVisibility: Null<String> = null;
			var runOverride: Bool = false;
			for (child in n.children) {
				final sp: Null<Span> = child.span;
				// Enum constructors (`SimpleCtor` / `ParamCtor`) are captured as members too, so a bare
				// `import pkg.Enum;` whose constructors are used as bare identifiers is not judged unused.
				// Enum-abstract values are already `FIELD_MEMBER_KINDS`.
				if (RefactorSupport.FIELD_MEMBER_KINDS.contains(child.kind) || child.kind == 'SimpleCtor' || child.kind == 'ParamCtor') {
					final nm: Null<String> = child.name;
					if (nm != null && sp != null) {
						// Re-bind to a non-null local — Strict null-safety takes a struct
						// literal's field type from the declared type, not the narrowed one.
						final memberName: String = nm;
						out.push({
							name: memberName,
							hasGetter: accessors[sp.from] ?? false,
							hasSetter: writeAccessors[sp.from] ?? false,
							returnNominal: returnTypes[sp.from],
							typeSource: typeSources[sp.from],
							visibility: runVisibility,
							isOverride: runOverride
						});
					}
					runVisibility = null;
					runOverride = false;
				} else if (sp != null && visibilityKinds.contains(child.kind))
					runVisibility = source.substring(sp.from, sp.to);
				else if (overrideKind != null && child.kind == overrideKind)
					runOverride = true;
			}
		});
		return out;
	}


	/**
	 * Count the type parameters written on `decl`'s header: locate the name token
	 * in the header text (the projection drops `<...>` params entirely, so no node's
	 * span points AT the name), then bracket-match a following `<...>` (a `->`
	 * return arrow's `>` is not a closer) and count the top-level commas. No `<`
	 * after the name yields 0 (non-generic).
	 *
	 * The scan starts at `decl.nameNode`'s span, falling back to `fullSpan`. The
	 * name node IS the header for every shape - the inner `ClassForm` of a `final
	 * class`, the `*Head` of a split-header conditional region - so the scan never
	 * has to cross a `final` keyword or a whole `#if` line to reach the name.
	 */
	private static function declTypeParamArity(source: String, decl: TypeDeclMatch): Int {
		final anchor: Null<Span> = decl.nameNode.span;
		final from: Int = anchor == null ? decl.fullSpan.from : anchor.from;
		final bodyAt: Int = source.indexOf('{', from);
		final nameAt: Int = source.indexOf(decl.name, from);
		if (nameAt < 0 || (bodyAt >= 0 && nameAt > bodyAt)) return 0;
		var i: Int = nameAt + decl.name.length;
		while (i < source.length && StringTools.isSpace(source, i)) i++;
		if (i >= source.length || StringTools.fastCodeAt(source, i) != '<'.code) return 0;
		var depth: Int = 0;
		var commas: Int = 0;
		while (i < source.length) {
			switch StringTools.fastCodeAt(source, i) {
				case '<'.code:
					depth++;
				case '>'.code if (StringTools.fastCodeAt(source, i - 1) != '-'.code):
					depth--;
					if (depth == 0) return commas + 1;
				case ','.code if (depth == 1):
					commas++;
				case _:
			}
			i++;
		}
		return 0;
	}


	/**
	 * `tree`'s top-level children with every conditional-compilation region
	 * REPLACED, in document order, by the type declarations it guards - the
	 * input `extractFileInfo` walks, so a type declared inside `#if ... #end`
	 * is indexed like a plain top-level one. Non-declaration children of a
	 * region (its imports, metadata and modifiers) are DROPPED: they are the
	 * caller's other concern and this slice does not change how they are read.
	 *
	 * Two grammar shapes carry a guarded declaration. A `Conditional` wrapper
	 * holds the region's decls FLATTENED - every branch's decls are its
	 * siblings, with no branch boundary visible in the projection (the shape
	 * `AddImport.guardedDuplicate` reads) - and is descended into. A
	 * `CondSharedBodyDecl` wrapper (a header split across `#if`, see
	 * `HxCondSharedBodyDecl`) is passed through as ITSELF: it is the node its
	 * declaration resolves from (`condSharedBodyDeclOf`).
	 */
	private static function declNodes(tree: QueryNode): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		final guardedNames: Array<String> = [];
		for (node in tree.children) switch node.kind {
			case 'Conditional':
				collectGuardedDecls(node, out, guardedNames);
			case 'CondSharedBodyDecl':
				pushGuardedDecl(node, out, guardedNames);
			case _:
				out.push(node);
		}
		return out;
	}

	/**
	 * Append every type declaration `node` - a `#if ... #end` region wrapper -
	 * guards to `out`, recursing through nested regions.
	 *
	 * The projection flattens all branches into one wrapper, so an `#if js
	 * class X {...} #else class X {...} #end` region yields TWO `ClassDecl X`
	 * children even though no compilation ever sees more than one of them.
	 * Indexing both would make `declaringFiles` (and `apq declares`) report an
	 * ambiguity that does not exist, so `pushGuardedDecl` keeps the FIRST
	 * declaration of a name and drops later same-named ones - the same
	 * "first branch live, alternates raw" rule the grammar already applies to
	 * split-header regions (`HxCondSharedBodyDecl`). Distinct names across
	 * branches (`#if js class A {} #elseif cpp class B {} #else typedef C =
	 * Int; #end`) are all kept.
	 */
	private static function collectGuardedDecls(node: QueryNode, out: Array<QueryNode>, guardedNames: Array<String>): Void {
		for (child in node.children) if (child.kind == 'Conditional')
			collectGuardedDecls(child, out, guardedNames);
		else
			pushGuardedDecl(child, out, guardedNames);
	}

	/**
	 * Append `node` to `out` when it is a type declaration whose name no
	 * conditional region has contributed yet, recording the name. A node that
	 * is not a declaration (an import, a metadata or a modifier lifted out of
	 * a region) is skipped.
	 */
	private static function pushGuardedDecl(node: QueryNode, out: Array<QueryNode>, guardedNames: Array<String>): Void {
		final decl: Null<TypeDeclMatch> = typeDeclAt(node);
		if (decl == null || guardedNames.contains(decl.name)) return;
		guardedNames.push(decl.name);
		out.push(node);
	}

	/**
	 * The type declaration `node` carries, across all three grammar shapes: a
	 * plain decl, a `final`-wrapped one (both via `RefactorSupport.typeDeclOf`)
	 * and a split-header conditional region. One resolver so the lifting done
	 * by `declNodes` and the indexing done by `extractFileInfo` can never
	 * disagree about what counts as a declaration.
	 */
	private static inline function typeDeclAt(node: QueryNode): Null<TypeDeclMatch> {
		return RefactorSupport.typeDeclOf(node) ?? condSharedBodyDeclOf(node);
	}

	/**
	 * The FIRST branch's type declaration of a split-header conditional region
	 * (`CondSharedBodyDecl`), or null for any other node and for a region
	 * carrying no recognised head. The head child holds the name, the type
	 * parameters and the heritage; the shared members are that head's
	 * SIBLINGS, written after `#end`.
	 *
	 * `fullSpan` is the WRAPPER's span, not the head's. It is the only span
	 * that CONTAINS the members, so a span-containment lookup (the
	 * innermost-enclosing-type scan in `RedundantBypassAccessor`) resolves
	 * them; and it is the only one that is a complete syntactic unit - the
	 * head stops at the `{` it opens, so a mutation addressed by the head span
	 * would leave a dangling `#else ... #end` and an unmatched `}`. `nameNode`
	 * is the head, which keeps the type-parameter scan anchored past the `#if`
	 * line.
	 */
	private static function condSharedBodyDeclOf(node: QueryNode): Null<TypeDeclMatch> {
		if (node.kind != 'CondSharedBodyDecl') return null;
		final span: Null<Span> = node.span;
		if (span == null) return null;
		// A plain `find` would have to re-read the map for the kind, so the head is
		// resolved and mapped in one pass.
		for (child in node.children) {
			final kind: Null<String> = DECL_HEAD_KINDS[child.kind];
			final name: Null<String> = child.name;
			if (kind != null && name != null) return {
				name: name,
				kind: kind,
				nameNode: child,
				fullSpan: span
			};
		}
		return null;
	}

}
