package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.SymbolIndex.TypeDeclInfo;

using StringTools;
using Lambda;

/**
 * The name -> DECLARATION layer of the index: which files declare a simple name, and which
 * declaration a written type reference denotes when it is read from a given file's scope.
 * A SIMPLE name is bound by `names` (`TypeNameBinding`), the compiler's resolution order and the one implementation of it:
 * `resolveTypeRefAll` answers a simple reference through it, and `ImportBindings` lists an import line's names from its tables.
 * What still reads import statements its own way is the call graph's `CallGraphImports`, owned by the graph (`apqlint.json`
 * `ownedTypes`); a consumer adding another reading re-opens the package-blind match this layer exists to remove.
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
@:allow(anyparse.query.MemberLookup)
final class TypeRefIndex {

	/** Every indexed file's `FileInfo`, handed over by the owning index. */
	private final _files: Array<FileInfo>;

	/** Every declaration by simple name, with its file, in index order (`named`): built on first need. */
	private var _byName: Null<Map<String, Array<ResolvedType>>> = null;

	/** Simple name -> each file entry declaring it once, in index order (`declaringFiles`): built with `_byName`. */
	private final _filesByName: Map<String, Array<FileInfo>> = [];

	/**
	 * Built once by the owning `SymbolIndex`, before any layer that resolves through it; `skipped` are the files it could
	 * not parse, `sources` the texts of those it did, `plugin` the grammar a std module outside the index is read with.
	 */
	public function new(files: Array<FileInfo>, skipped: Array<String>, sources: Map<String, String>, plugin: GrammarPlugin) {
		_files = files;
		names = new TypeNameBinding(files, skipped, sources, plugin);
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
		named(typeName);
		return (_filesByName[typeName] ?? []).copy();
	}

	/** Every indexed type decl whose simple name is `name`, across all files. */
	public function declsNamed(name: String): Array<TypeDeclInfo> {
		return [for (r in resolvedDeclsNamed(name)) r.type];
	}

	/**
	 * Every indexed decl named `typeName` (simple name), each paired with its declaring file.
	 */
	public function resolvedDeclsNamed(typeName: String): Array<ResolvedType> {
		return [for (r in named(typeName)) { file: r.file, type: r.type }];
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
	 * Resolve a written type reference `raw` (as it appears in `fromFile`) to the SINGLE in-set
	 * declaration it names, or null when nothing in the index provably is that declaration (an external
	 * type, a tier the index cannot bound) or the answer is AMBIGUOUS (two class paths holding one
	 * module). A simple `raw` is bound by `names`, the compiler's resolution order; a qualified one
	 * matches on import path. `at`, the offset `raw` is written at in `fromFile`, lets a
	 * `#if`-guarded import decide a use inside its own branch (`TypeNameBinding.tierOf`).
	 */
	public function resolveTypeRef(raw: String, fromFile: FileInfo, ?at: Int): Null<ResolvedType> {
		final matches: Array<ResolvedType> = resolveTypeRefAll(raw, fromFile, at);
		return matches.length == 1 ? matches[0] : null;
	}

	/**
	 * Every declaration `raw` resolves to from `fromFile` (see `resolveTypeRef`), written at offset `at` of it when the caller
	 * knows where. A simple name is bound by `names` — the compiler's resolution order, empty wherever no tier provably
	 * answers; a dotted one matches on import path, the module-relative `Mod.Sub` as the fallback.
	 */
	public function resolveTypeRefAll(raw: String, fromFile: FileInfo, ?at: Int): Array<ResolvedType> {
		if (raw.indexOf('.') < 0) return names.bind(raw, fromFile, at) ?? [];
		final qualified: Array<ResolvedType> = resolveQualifiedRefAll(raw);
		return qualified.length > 0 ? qualified : moduleRelativeRefAll(raw, fromFile);
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
		for (r in named(simple)) if (importPathFor(r.file, r.type) == raw) {
			final key: String = '${r.file.file}#${r.type.name}';
			if (!seen.contains(key)) {
				seen.push(key);
				matches.push({ file: r.file, type: r.type });
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
	public function resolveStartType(typeName: String, fromFile: Null<String>, ?at: Int): Null<ResolvedType> {
		if (fromFile != null) {
			final host: Null<FileInfo> = _files.find(f -> f.file == fromFile);
			if (host != null) return resolveTypeRef(typeName, host, at);
		}
		if (typeName.indexOf('.') >= 0) {
			final qualified: Array<ResolvedType> = resolveQualifiedRefAll(typeName);
			return qualified.length == 1 ? qualified[0] : null;
		}
		final ds: Array<ResolvedType> = resolvedDeclsNamed(typeName);
		return ds.length == 1 ? ds[0] : null;
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
		for (r in named(simple)) if (!r.type.isMain && moduleSimpleName(r.file.module) == prefix && moduleRefInScope(fromFile, r.file)) {
			final key: String = '${r.file.file}#${r.type.name}';
			if (!seen.contains(key)) {
				seen.push(key);
				matches.push({ file: r.file, type: r.type });
			}
		}
		return matches;
	}

	/**
	 * ONE file's import-alias edges: the alias a `import pkg.Util as U;` statement binds -> the
	 * SIMPLE name of every path it points at. An ARRAY because a `#if` region may bind one
	 * alias name to a different target per branch. The import twin of `aliasEdges`, and per-FILE rather
	 * than project-wide because that is the scope such an alias actually has — a `U` bound in one
	 * module says nothing about a `U` written in another.
	 *
	 * `followGuarded` is the whole `#if` question, and it has OPPOSITE answers on the two sides of the
	 * subtype relation, so it is the caller's to give. Going DOWN (`subtypesOf`) the answer is a veto —
	 * offering both branch targets makes MORE types answer "something subtypes me", which is the
	 * withholding direction, and dropping either is what compile-proved a deleted private constructor.
	 * Going UP (`closureContains`) the answer is read AFFIRMATIVELY by two autofixes that DELETE —
	 * `unreachable-catch` removes a clause, `redundant-upcast` removes a cast — and offering both makes one
	 * type a subtype of two modules no single build agrees on: `#if cpp import pkg.A as U; #else import
	 * pkg.Bee as U; #end class Both extends U` reports the `catch (e:Both)` after `catch (e:A)` AND the one
	 * after `catch (e:Bee)` unreachable, and `--fix` deletes both clauses. So the upward walk refuses a
	 * guarded alias, which is also what `SymbolIndexBuilder.aliasTargetPathOf` already does for a guarded
	 * TYPEDEF — the two alias kinds fail closed together rather than one each way.
	 *
	 * Simple names on both sides: `supertypes` is already reduced that way, and so is every name
	 * `subtypesOf` is asked about. An alias whose path did not decode carries no edge; a
	 * self-alias (`import pkg.U as U`, which Haxe accepts) carries none either, since the walk
	 * already holds that name.
	 */
	public static function importAliasEdges(fi: FileInfo, followGuarded: Bool): Map<String, Array<String>> {
		final edges: Map<String, Array<String>> = [];
		// An alias bound by an AMBIENT source binds in this file too, and the map is already a
		// multi-valued union that every reader treats as "any of these may be meant" — so an ambient
		// target joins the bucket rather than replacing it, which is the withholding direction on both
		// sides of the subtype relation.
		inline function collect(imports: Array<ImportInfo>): Void {
			for (imp in imports) if (imp.kind == ImportKind.Alias && (followGuarded || !imp.guarded)) {
				final alias: Null<String> = imp.alias;
				final target: Null<String> = imp.aliasTarget;
				if (alias == null || target == null) continue;
				final simple: String = SourceText.lastSegment(target);
				if (simple == alias) continue;
				final bucket: Array<String> = edges[alias] ?? [];
				if (!bucket.contains(simple)) bucket.push(simple);
				edges[alias] = bucket;
			}
		}
		collect(fi.imports);
		for (group in fi.ambientImports) collect(group.imports);
		return edges;
	}

	/** The import path naming type `t` in file `fi`: its module when `t` is the module main type, else `module.name`. */
	public static inline function importPathFor(fi: FileInfo, t: TypeDeclInfo): String {
		return t.isMain ? fi.module : '${fi.module}.${t.name}';
	}

	/** The last segment of a dotted module path — `pkg.Mod` -> `Mod`, a root-package `Mod` unchanged. */
	private static inline function moduleSimpleName(module: String): String {
		final dot: Int = module.lastIndexOf('.');
		return dot < 0 ? module : module.substr(dot + 1);
	}

	/**
	 * Whether the MODULE of `fi` can be named by its own simple name from `fromFile` — the
	 * visibility a module-relative `Mod.Sub` reference needs, which is NOT the one a bare TYPE
	 * name needs, so the simple-name binding (`names`) cannot stand in for it. Compiled on 4.3.7: same package
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
		inline function supplies(imports: Array<ImportInfo>): Bool {
			return imports.exists(imp -> imp.kind == ImportKind.Wild && imp.raw == wild);
		}
		// An ambient source's wildcard supplies the qualifier exactly as the file's own would, and
		// this is a membership question with no precedence in it — a module either can be named by
		// its simple name here or cannot — so the two lists answer as a union.
		return supplies(fromFile.imports) || fromFile.ambientImports.exists(g -> supplies(g.imports));
	}

	/**
	 * The declarations named `name`, each with its file, in index order — what every lookup by simple name opened with
	 * as a scan of every type of every file. On TM that scan, through `declaringFiles` alone, was 140 of a 360 s
	 * `--fix`. The files are the owning index's, which never changes them (`SymbolIndex.without` builds a new index), so
	 * the table is built once. Iterated, never handed out: a caller gets its own array.
	 */
	private function named(name: String): Array<ResolvedType> {
		var table: Null<Map<String, Array<ResolvedType>>> = _byName;
		if (table == null) {
			final built: Map<String, Array<ResolvedType>> = [];
			for (fi in _files) {
				final own: Array<String> = [];
				for (t in fi.types) {
					final list: Array<ResolvedType> = built[t.name] ?? [];
					list.push({ file: fi, type: t });
					built[t.name] = list;
					if (!own.contains(t.name)) own.push(t.name);
				}
				for (n in own) {
					final declaring: Array<FileInfo> = _filesByName[n] ?? [];
					declaring.push(fi);
					_filesByName[n] = declaring;
				}
			}
			_byName = built;
			table = built;
		}
		return table[name] ?? [];
	}

	/** What a simple type name written in a file binds to, tier by tier in the compiler's order — the one reading of a bare name. */
	public final names: TypeNameBinding;

	/**
	 * The paths of the `using` statements `fi` receives from its AMBIENT chain (`import.hx`), nearest source first —
	 * the extensions in scope that the file itself does not spell. A guarded one included: the build that compiles it
	 * binds through it.
	 */
	public static function ambientUsings(fi: FileInfo): Array<String> {
		return [
			for (group in fi.ambientImports) for (imp in group.imports) if (imp.kind == ImportKind.Using) imp.raw
		];
	}

}
