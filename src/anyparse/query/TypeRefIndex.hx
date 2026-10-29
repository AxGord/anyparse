package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.query.TypeNameBinding.Tier;
import anyparse.query.TypeSyntax.TypeSyntaxReader;

using Lambda;

/**
 * The name -> DECLARATION layer of the index: which files declare a simple name, and which
 * declaration a written type reference denotes when it is read from a given file's scope.
 * A SIMPLE name is bound by `names` (`TypeNameBinding`), the compiler's resolution order and the one implementation of it:
 * `resolveTypeRefAll` answers a simple reference through it, and `ImportBindings` lists an import line's names from its tables.
 * Every type a name may be on some build — what the call graph dispatches on — is `names.bindingsOf`,
 * and a bare VALUE name is `ValueNameBinding`'s (`SymbolIndex.values`); a consumer adding another
 * reading of import statements re-opens the package-blind match this layer exists to remove.
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

	/** What a simple type name written in a file binds to, tier by tier in the compiler's order — the one reading of a bare name. */
	public final names: TypeNameBinding;

	/** Simple name -> each file entry declaring it once, in index order (`declaringFiles`): built with `_byName`. */
	private final _filesByName: Map<String, Array<FileInfo>> = [];

	/** Every indexed file's `FileInfo`, handed over by the owning index. */
	private final _files: Array<FileInfo>;

	/** Every declaration by simple name, with its file, in index order (`named`): built on first need. */
	private var _byName: Null<Map<String, Array<ResolvedType>>> = null;

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

	/**
	 * The simple name of the type `name` stands for through its typedef alias hops (`typedef A = B`): each hop the ONE
	 * declaration of its name, its target resolved where that declaration writes it (`resolveTypeRef`). `name` itself when
	 * it aliases nothing (a typedef of a structure, one re-exporting a type of its own name); the target's written simple name
	 * when a hop leaves the index; the name reached when a hop is no single declaration, or loops.
	 */
	public function aliasedName(name: String): String {
		var at: String = name;
		final seen: Array<String> = [];
		while (!seen.contains(at)) {
			seen.push(at);
			final decls: Array<ResolvedType> = named(at);
			if (decls.length != 1) return at;
			final t: TypeDeclInfo = decls[0].type;
			final raw: Null<String> = t.aliasTargetRaw;
			if (raw == null || t.isAnonStruct || t.aliasTargetNominal == t.name) return at;
			final next: Null<ResolvedType> = resolveTypeRef(raw, decls[0].file, t.span.from);
			at = next == null ? SourceText.lastSegment(raw) : next.type.name;
		}
		return at;
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
	 * knows where, read in a type position: by `names`, the compiler's resolution order — `tierOf` for a simple name,
	 * `dottedTierOf` for a dotted one — empty wherever no tier provably answers.
	 */
	public function resolveTypeRefAll(raw: String, fromFile: FileInfo, ?at: Int): Array<ResolvedType> {
		final tier: Tier = raw.indexOf('.') < 0 ? names.tierOf(raw, fromFile, at) : names.dottedTierOf(raw, fromFile, false, at);
		return switch tier {
			case Bound(decls): decls;
			case Unknown, Free: [];
		};
	}

	/**
	 * Every decl a QUALIFIED type reference names, matched on import path. Needs no referring
	 * file: a dotted path means the same thing from everywhere, which is what lets a caller
	 * holding a full module path (the `using`-conflict scan) resolve with no context at all.
	 * The dotted forms that DO depend on the referring file — the module-relative
	 * `Mod.Sub`, a `p.Sub` an import names — are `TypeNameBinding.dottedTierOf`'s.
	 */
	public function resolveQualifiedRefAll(raw: String): Array<ResolvedType> {
		final simple: String = SourceText.lastSegment(raw);
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
	 * `resolveStartType`, or — the name reaching several declarations that are one std module each target's `_std`
	 * re-declares — the first of those copies (`oneDeclaration`), where a question the copies all answer alike may read one.
	 */
	public function resolveStartCopy(typeName: String, fromFile: Null<String>, ?at: Int): Null<ResolvedType> {
		final found: Null<ResolvedType> = resolveStartType(typeName, fromFile, at);
		if (found != null) return found;
		final host: Null<FileInfo> = fromFile == null ? null : _files.find(f -> f.file == fromFile);
		return oneDeclaration(
			if (host != null)
				resolveTypeRefAll(typeName, host, at)
			else if (typeName.indexOf('.') >= 0)
				resolveQualifiedRefAll(typeName)
			else
				resolvedDeclsNamed(typeName)
		);
	}

	/**
	 * Whether every type name the written type `text` spells resolves, read in the file `to`, to the declarations it resolves
	 * to read in `from` (`skip` the names that are no type there: type parameters) — whether a type written in one file may be
	 * carried into another as that one's own. A name neither file resolves is taken alike.
	 */
	public function readsAlike(text: String, from: FileInfo, to: FileInfo, skip: Array<String>, syntax: TypeSyntaxReader): Bool {
		if (from.file == to.file) return true;
		final written: Null<TypeSyntax> = syntax(text);
		if (written == null) return false;
		for (d in written.descendants()) switch d.shape {
			case Nominal(path, _) if (!skip.contains(path)):
				if (!nameReadsAlike(path, from, to)) return false;
			case _:
		}
		return true;
	}

	/**
	 * The written type `text`, read in the file `from`, spelled so the file `to` reads each of its type names as `from`
	 * does (`readsAlike`): a name `to` reads otherwise is written as the path of the one declaration it names in `from`
	 * (`TypeNameBinding.canonicalPath`), `skip` (the type parameters in scope) left alone. What a typed answer carries
	 * from the file declaring it into the file asking. Null when such a name cannot be spelled so: it names no single
	 * declaration of the index in `from`, a private one, or one whose path `to` reads as another.
	 */
	public function spelledIn(text: String, from: FileInfo, to: FileInfo, skip: Array<String>, syntax: TypeSyntaxReader): Null<String> {
		if (from.file == to.file) return text;
		final written: Null<TypeSyntax> = syntax(text);
		if (written == null) return null;
		final edits: Array<{ at: Int, length: Int, path: String }> = [];
		for (d in written.descendants()) switch d.shape {
			case Nominal(path, _) if (!skip.contains(path) && !nameReadsAlike(path, from, to)):
				final there: Array<ResolvedType> = resolveTypeRefAll(path, from);
				final named: Null<ResolvedType> = there.length == 1 && !there[0].type.isPrivate ? there[0] : null;
				final canonical: Null<String> = named == null ? null : TypeNameBinding.canonicalPath(named);
				if (named == null || canonical == null || !d.text.startsWith(path)) return null;
				final here: Array<ResolvedType> = resolveTypeRefAll(canonical, to);
				if (here.length != 1 || !AncestorTable.same(here[0], named)) return null;
				edits.push({ at: d.span.from, length: path.length, path: canonical });
			case _:
		}
		var out: String = text;
		edits.sort((a, b) -> b.at - a.at);
		for (e in edits) out = out.substr(0, e.at) + e.path + out.substr(e.at + e.length);
		return out;
	}

	/**
	 * Whether the written type `text` reads in the indexed file `to` as in each of the files `writers` writing it
	 * (`readsAlike`); true for a file the index does not hold, which no name of the index is read in.
	 */
	public function readsAlikeFromEach(
		text: String, writers: Array<FileInfo>, to: String, skip: Array<String>, syntax: TypeSyntaxReader
	): Bool {
		final reader: Null<FileInfo> = _files.find(f -> f.file == to);
		return reader == null || writers.foreach(w -> readsAlike(text, w, reader, skip, syntax));
	}

	/** Whether the type name `path` resolves in the file `to` to the declarations it resolves to in `from`. */
	private function nameReadsAlike(path: String, from: FileInfo, to: FileInfo): Bool {
		final there: Array<ResolvedType> = resolveTypeRefAll(path, from);
		final here: Array<ResolvedType> = resolveTypeRefAll(path, to);
		return there.length == here.length && there.foreach(r -> here.exists(h -> AncestorTable.same(r, h)));
	}

	/**
	 * The declarations named `name`, each with its file, in index order — what every lookup by simple name opened with
	 * as a scan of every type of every file. On a large project that scan, through `declaringFiles` alone, was a large share
	 * of a `--fix`. The files are the owning index's, which never changes them (`SymbolIndex.without` builds a new index), so
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

	/** The import path naming type `t` in file `fi`: its module when `t` is the module main type, else `module.name`. */
	public static inline function importPathFor(fi: FileInfo, t: TypeDeclInfo): String {
		return t.isMain ? fi.module : '${fi.module}.${t.name}';
	}

	/**
	 * The one declaration `found` holds: its only one, or — every one a copy of one std module a target's `_std` re-declares
	 * (`std/Array.hx` beside `js/_std/Array.hx`) — the first by file. Null otherwise.
	 */
	public static function oneDeclaration(found: Array<ResolvedType>): Null<ResolvedType> {
		if (found.length < 2) return found.length == 1 ? found[0] : null;
		final module: String = ModuleScan.pathOfTypeIn(found[0].file, found[0].type.name);
		if (!found.foreach(r -> StdResolver.isStdFile(r.file.file) && ModuleScan.pathOfTypeIn(r.file, r.type.name) == module)) return null;
		final ordered: Array<ResolvedType> = found.copy();
		ordered.sort((a, b) -> Reflect.compare(a.file.file, b.file.file));
		return ordered[0];
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
	 * Going UP (`SupertypeWalk`, for a link nothing resolves) the answer is read AFFIRMATIVELY by two autofixes that DELETE —
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

	/** The paths of the `using` statements `fi` itself writes, a guarded one included — the extensions it brings in by name. */
	public static function usings(fi: FileInfo): Array<String> {
		return [for (imp in fi.imports) if (imp.kind == ImportKind.Using) imp.raw];
	}

	/** The packages the file's package wildcards (`import p.*;`) name, the `.*` dropped. */
	public static function wildcardPackages(fi: FileInfo): Array<String> {
		return [
			for (imp in fi.imports) if (imp.kind == ImportKind.Wild) imp.raw.substr(0, imp.raw.lastIndexOf('.'))
		];
	}

	/** The dotted paths the file's alias imports (`import p.T as U;`) bind their aliases to, an undecodable one left out. */
	public static function aliasTargets(fi: FileInfo): Array<String> {
		final out: Array<String> = [];
		for (imp in fi.imports) if (imp.kind == ImportKind.Alias) {
			final target: Null<String> = imp.aliasTarget;
			if (target != null) out.push(target);
		}
		return out;
	}

	/**
	 * The paths of the plain `import` statements `fi` itself writes (no alias, no wildcard), a guarded one included — a
	 * static field import among them (`import pkg.Type.member;`).
	 */
	public static function plainImports(fi: FileInfo): Array<String> {
		return [for (imp in fi.imports) if (imp.kind == ImportKind.Import) imp.raw];
	}

	/**
	 * The one path an UNGUARDED plain `import` of `fi` binds the simple name `simple` through (its last segment), or
	 * null when none does or two disagree.
	 */
	public static function plainImportPathOf(fi: FileInfo, simple: String): Null<String> {
		var found: Null<String> = null;
		for (imp in fi.imports) if (!imp.guarded && imp.kind == ImportKind.Import && SourceText.lastSegment(imp.raw) == simple) {
			if (found != null && found != imp.raw) return null;
			found = imp.raw;
		}
		return found;
	}

	/**
	 * Whether `fi` brings `simple` into scope only under a conditional-compilation guard — an `ImportInfo.guarded` import
	 * or `using` whose last segment it is, an alias binding the name, or any guarded wildcard. The reference index is
	 * branch-blind, so such an import reads as unconditional.
	 */
	public static function bindsUnderGuard(fi: FileInfo, simple: String): Bool {
		for (imp in fi.imports) if (imp.guarded) switch imp.kind {
			case ImportKind.Import, ImportKind.Using:
				if (SourceText.lastSegment(imp.raw) == simple) return true;
			case ImportKind.Alias:
				if (imp.alias == simple) return true;
			case ImportKind.Wild:
				return true;
		}
		return false;
	}

}
