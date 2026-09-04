package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.SymbolIndex.TypeDeclInfo;

using StringTools;
using Lambda;

/**
 * The name -> DECLARATION layer of the index: which files declare a simple name, and which
 * declaration a written type reference denotes when it is read from a given file's scope.
 * Import, `using`, alias and same-package visibility all resolve here, and nothing above this
 * layer re-derives them — a package-blind simple-name match is exactly the flaw it exists to
 * remove.
 *
 * Split out of `SymbolIndex`, which keeps the indexed DATA and hands a `TypeRefIndex` to each of
 * its query layers at construction. Those layers depend on reference RESOLUTION, not on the
 * index object, and saying so in the constructor is what lets every layer be built before the
 * index finishes initialising.
 *
 * The `seen`-set helpers live here for the same reason: a `ResolvedType` is what this layer
 * produces, so its identity is this layer's to define.
 */
@:nullSafety(Strict)
final class TypeRefIndex {

	/** Every indexed file's `FileInfo`, handed over by the owning index. */
	private final _files: Array<FileInfo>;

	/** Built once by the owning `SymbolIndex`, before any layer that resolves through it. */
	public function new(files: Array<FileInfo>) {
		_files = files;
	}

	/**
	 * Mark `cur`'s resolved `(file, name)` identity in `seen` and answer whether this is its FIRST
	 * visit — the cycle guard every supertype walk opens with. A re-entered node answers false, and
	 * the caller ends that branch with its own not-found value.
	 */
	public inline function markSeen(cur: ResolvedType, seen: Array<String>): Bool {
		final key: String = seenKey(cur);
		if (seen.contains(key)) return false;
		seen.push(key);
		return true;
	}

	/** The `seen`-set identity of a resolved type: its declaring file plus its name — see `markSeen`. */
	public inline function seenKey(cur: ResolvedType): String {
		return '${cur.file.file}#${cur.type.name}';
	}

	/**
	 * Files declaring a top-level type named `typeName`. Length 0 / 1 /
	 * many is the ambiguity signal a move-symbol op tests before
	 * proceeding.
	 */
	public function declaringFiles(typeName: String): Array<FileInfo> {
		return _files.filter(f -> f.types.exists(t -> t.name == typeName));
	}

	/** Every indexed type decl whose simple name is `name`, across all files. */
	public function declsNamed(name: String): Array<TypeDeclInfo> {
		return [for (r in resolvedDeclsNamed(name)) r.type];
	}

	/**
	 * Every indexed decl named `typeName` (simple name), each paired with its declaring file.
	 */
	public function resolvedDeclsNamed(typeName: String): Array<ResolvedType> {
		return [
			for (fi in _files) for (t in fi.types) if (t.name == typeName) { file: fi, type: t }
		];
	}

	/** The `{file, type}` for the type named `typeName` declared in `file`, or null. */
	public function findDeclaredType(file: String, typeName: String): Null<ResolvedType> {
		final fi: Null<FileInfo> = _files.find(f -> f.file == file);
		if (fi == null) return null;
		final host: FileInfo = fi;
		final t: Null<TypeDeclInfo> = host.types.find(td -> td.name == typeName);
		return t == null ? null : { file: host, type: t };
	}

	/**
	 * Resolve a written supertype reference `raw` (as it appears in `fromFile`) to the
	 * SINGLE in-set type it names, or null when it is external (no in-set match) or
	 * AMBIGUOUS (more than one distinct in-set match). A qualified `raw` matches an
	 * in-set type whose import path equals it; a simple `raw` matches a type in scope of
	 * `fromFile` — named by an explicit `import` / `using`, reached through a `pkg.*`
	 * wildcard, or declared in `fromFile`'s own package.
	 */
	public function resolveTypeRef(raw: String, fromFile: FileInfo): Null<ResolvedType> {
		final matches: Array<ResolvedType> = resolveTypeRefAll(raw, fromFile);
		return matches.length == 1 ? matches[0] : null;
	}

	/** Every in-scope declaration `raw` resolves to from `fromFile` (see `resolveTypeRef`), deduped by declaring file. */
	public function resolveTypeRefAll(raw: String, fromFile: FileInfo): Array<ResolvedType> {
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
	 * Every decl a QUALIFIED type reference names, matched on import path. Needs no referring
	 * file: a dotted path means the same thing from everywhere, which is what lets a caller
	 * holding a full module path (the `using`-conflict scan) resolve with no context at all.
	 * The one dotted form it cannot answer — the module-relative `Mod.Sub` — is exactly the one
	 * that DOES depend on the referring file; `moduleRelativeRefAll` owns it.
	 */
	public function resolveQualifiedRefAll(raw: String): Array<ResolvedType> {
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
	public function resolveStartType(typeName: String, fromFile: Null<String>): Null<ResolvedType> {
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

	/** The import path naming type `t` in file `fi`: its module when `t` is the module main type, else `module.name`. */
	private inline function importPathFor(fi: FileInfo, t: TypeDeclInfo): String {
		return t.isMain ? fi.module : '${fi.module}.${t.name}';
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
	public static function importAliasEdges(fi: FileInfo, followGuarded: Bool): Map<String, Array<String>> {
		final edges: Map<String, Array<String>> = [];
		for (imp in fi.imports) if (imp.kind == ImportKind.Alias && (followGuarded || !imp.guarded)) {
			final alias: Null<String> = imp.alias;
			final target: Null<String> = imp.aliasTarget;
			if (alias == null || target == null) continue;
			final simple: String = SourceText.lastSegment(target);
			if (simple == alias) continue;
			final bucket: Array<String> = edges[alias] ?? [];
			if (!bucket.contains(simple)) bucket.push(simple);
			edges[alias] = bucket;
		}
		return edges;
	}

	/** The last segment of a dotted module path — `pkg.Mod` -> `Mod`, a root-package `Mod` unchanged. */
	private static inline function moduleSimpleName(module: String): String {
		final dot: Int = module.lastIndexOf('.');
		return dot < 0 ? module : module.substr(dot + 1);
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

}
