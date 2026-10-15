package anyparse.query;

import anyparse.query.CallGraphTypes.HeldFile;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.query.TypeNameBinding.NameTarget;
import anyparse.query.TypeNameBinding.NameTargets;

using Lambda;

/**
 * How a `CallGraph` keys the types its files write, and the declaration facts it reads by simple name: the key a
 * type name written in a file means (`typeOf` — the declaration the shared binding `TypeNameBinding.bindingsOf` binds it
 * to, a type outside the indexes by its path when a declaration bears its simple name), the other keys it may mean on
 * some build (`alternateTypes`), the spelling a written type is read by wherever its text goes (`writtenAs`), the static
 * extensions a file's `using`s bring (`ValueNameBinding.usingTypes`), and per type name the files declaring each member
 * and the enum constructors a bare call may build. No import statement is read here. Files are keyed by
 * `CallGraphNames.normalizePath`.
 */
@:nullSafety(Strict)
final class CallGraphImports {

	/** Enum constructor name -> the enums declaring one of that name. */
	private final _enumConstructors: Map<String, Array<String>> = [];

	/** Type simple name -> member name -> the files whose declarations of the type declare the member. */
	private final _memberFiles: Map<String, Map<String, Array<String>>> = [];

	/** Type simple name -> member name -> each declaration of the member: its file and the type it writes (null for none). */
	private final _memberTypes: Map<String, Map<String, Array<WrittenIn>>> = [];

	/** Type simple name -> the dotted paths that name a declaration of it (`pkg.Module.Name`; a main type's also `pkg.Module`). */
	private final _declaredPaths: Map<String, Array<String>> = [];


	/** Type simple name -> the paths `pathType` keyed apart from the declarations of that name, as it met them. */
	private final _foreign: Map<String, Array<String>> = [];

	/** File -> simple name -> every type the name may bind to there (`TypeNameBinding.bindingsOf`), read on its first question. */
	private final _targets: Map<String, Map<String, NameTargets>> = [];

	private final _enumConstructorKinds: Array<String>;

	/** Whether a type declares a member static — the tables that answer it live with the types. */
	private final _isStatic: (String, String) -> Bool;

	/** The index entry a file's declarations were read from (`CallGraphTypes.heldFile`), whose layers answer its names. */
	private final _held: String -> Null<HeldFile>;

	public function new(
		enumConstructorKinds: Array<String>, isStatic: (String, String) -> Bool, held: String -> Null<HeldFile>
	) {
		_enumConstructorKinds = enumConstructorKinds;
		_isStatic = isStatic;
		_held = held;
	}

	/**
	 * Whether an indexed enum declares a constructor named `name` — which a bare call may build without any
	 * import, since the language resolves a constructor against the expected type.
	 */
	public inline function isEnumConstructor(name: String): Bool {
		return _enumConstructors.exists(name);
	}

	/** The indexed enums declaring a constructor named `name`, by simple name. */
	public inline function enumsDeclaring(name: String): Array<String> {
		return _enumConstructors[name] ?? [];
	}


	/**
	 * The files (`normalizePath`d) whose declarations of the type of simple name `typeName` declare `member` itself, not a
	 * supertype's — where the types its record writes are to be read (`CallGraphKeys.keyedIn`).
	 */
	public inline function memberFilesOf(typeName: String, member: String): Array<String> {
		return _memberFiles[typeName]?.get(member) ?? [];
	}

	/**
	 * Each declaration of `member` the declarations of the type of simple name `typeName` hold — one per branch of a
	 * conditional region, one per declaration of the type — with its file and the type it writes, each once.
	 */
	public inline function memberTypesOf(typeName: String, member: String): Array<WrittenIn> {
		return _memberTypes[typeName]?.get(member) ?? [];
	}

	/** The qualified paths the type of simple name `name` is declared under (`recordFile`): by its module, by its package. */
	public inline function declaredPathsOf(name: String): Array<String> {
		return _declaredPaths[name] ?? [];
	}

	/** Fold the declarations of `fi`, held under `key`: their members and the paths they are declared under. */
	public function recordFile(fi: FileInfo, key: String): Void {
		for (t in fi.types) {
			recordMembers(t, key);
			// a type is named by its module's path and its own name, a main type by its module's path too; and by its package
			// and its name, whatever its module is called — what an import reads when a file does not name its module
			final inModule: String = '${fi.module}.${t.name}';
			final inPackage: String = fi.pkg == '' ? t.name : '${fi.pkg}.${t.name}';
			CallGraphTypes.unionInto(_declaredPaths, t.name, t.isMain ? [fi.module, inModule, inPackage] : [inModule, inPackage]);
		}
	}

	/** Fold the members of `t`, a declaration of the file keyed `key`: its enum constructors, and where each member is declared. */
	private function recordMembers(t: TypeDeclInfo, key: String): Void {
		final files: Map<String, Array<String>> = _memberFiles[t.name] ?? [];
		final written: Map<String, Array<WrittenIn>> = _memberTypes[t.name] ?? [];
		for (m in t.members) {
			if (_enumConstructorKinds.contains(m.kind)) CallGraphTypes.unionInto(_enumConstructors, m.name, [t.name]);
			CallGraphTypes.unionInto(files, m.name, [key]);
			final each: Array<WrittenIn> = written[m.name] ?? [];
			if (!each.exists(w -> w.file == key && w.written == m.typeSource)) each.push({ file: key, written: m.typeSource });
			written[m.name] = each;
		}
		_memberFiles[t.name] = files;
		_memberTypes[t.name] = written;
	}

	/**
	 * Every type a `using` in `file` brings in that declares a STATIC `member` — the static extensions a
	 * `value.member(…)` there may call when the value's own type declares no such member. All of them: which
	 * one wins depends on the order and on the first argument's type, so a caller that wants every target
	 * a call can run takes the lot.
	 */
	public function staticExtensionsOf(file: String, member: String): Array<String> {
		final held: Null<HeldFile> = _held(file);
		final usings: Array<String> = held == null ? [] : held.index.values.usingTypes(held.info);
		return [for (u in usings) if (_isStatic(u, member)) u];
	}

	/**
	 * The name the graph keys the type `written` in `file` by (`CallGraph` keys types by simple name): the simple name of
	 * the declaration the file binds it to (`TypeNameBinding.bindingsOf`), or — for a type outside the indexes, a dotted path
	 * written out — that path when a declaration the tables hold bears its simple name (`pathType`): `sys.thread.Lock` beside
	 * a project `utils.Lock` is another type, and merging the two by name would make a call of the library one run the
	 * project's. A name nothing binds stays as written.
	 */
	public function typeOf(file: String, written: String): String {
		if (written.indexOf('.') >= 0) return pathType(written);
		final bound: Null<NameTarget> = targetsOf(file, written)?.bound;
		return bound == null ? written : keyOf(bound, true);
	}

	/**
	 * The type `written` — the path each declaration writes, with the file writing it — names, read where written
	 * (`typeOf`): a library type a project type's simple name bears is keyed apart. `simple` when none is written, or two
	 * declarations key it apart.
	 */
	public function keyedWhereWritten(written: Array<{ path: String, file: String }>, simple: String): String {
		final keyed: Array<String> = [];
		for (w in written) {
			final key: String = typeOf(w.file, w.path);
			if (!keyed.contains(key)) keyed.push(key);
		}
		return keyed.length == 1 ? keyed[0] : simple;
	}

	/**
	 * Whether the type spelled `path` — as `writtenAs` spells a bound name, a dotted path written out, a bare name nothing
	 * binds — is the std type `standard` lists the spellings of: a declaration the index of `file` holds at that path is the
	 * std's only in a std file (a project `haxe/ds/Vector.hx` or a root `List.hx` shadows the std's, review L3 G2), and a
	 * path no declaration holds is the std's when `standard` lists it. The spelling carries the file that wrote it, so a type
	 * read in another file than its declaration's is decided as written there (review L3 G6).
	 */
	public function isStandard(file: String, path: String, standard: Array<String>): Bool {
		final held: Null<HeldFile> = _held(file);
		final decls: Array<ResolvedType> = held == null ? [] : held.index.refs.names.declsAt(path);
		return decls.length > 0 ? decls.foreach(d -> StdResolver.isStdFile(d.file.file)) : standard.contains(path);
	}

	/**
	 * Every key the name `written` may mean in `file`, recording nothing: the one the file binds it to, then each one a
	 * `#if`-guarded statement or a wildcard the order cannot list may bind it to instead; none when nothing binds it. A
	 * dotted path is its own key (`pathKey`).
	 */
	public function keysOf(file: String, written: String): Array<String> {
		if (written.indexOf('.') >= 0) return [pathKey(written)];
		final targets: Null<NameTargets> = targetsOf(file, written);
		final bound: Null<NameTarget> = targets?.bound;
		final out: Array<String> = bound == null ? [] : [keyOf(bound, false)];
		for (t in maybeOf(targets)) {
			final key: String = keyOf(t, false);
			if (!out.contains(key)) out.push(key);
		}
		return out;
	}

	/**
	 * `name`, a simple type name written in `file`, spelled by the path of the type the file binds it to — what a type
	 * written there means wherever the text is read (`CallGraphKeys.keyedIn`): a declaration's canonical path
	 * (`TypeNameBinding.canonicalPath`), the path of a type outside the indexes, a `StdTypes` type by its bare name (the name
	 * every reader matches a built-in by), `name` itself when nothing binds it — or the path of a type an `#if`-guarded
	 * statement binds it to instead on some build. Each spelling keys as `name` does in `file`.
	 */
	public function writtenAs(file: String, name: String): String {
		final targets: Null<NameTargets> = name.indexOf('.') >= 0 ? null : targetsOf(file, name);
		final bound: Null<NameTarget> = targets?.bound;
		// the key every spelling reads as is met here, a type outside the indexes recorded as `pathType` records it
		final key: String = bound == null ? name : keyOf(bound, true);
		final spelled: String = bound == null ? name : spellingOf(bound, name);
		// a type an `#if`-guarded statement binds the name to on some build, keyed alike, is what the text spells: no reader
		// may take it for the one `bound` names alone (review R5 F2)
		for (g in targets?.guarded ?? []) {
			final other: String = spellingOf(g, name);
			if (other != spelled && keyOf(g, false) == key) return other;
		}
		return spelled;
	}

	/**
	 * The other types a value `file` keys as `type` (`typeOf`) may be, which a call on it may run too: a name an `#if`-guarded
	 * statement binds to another type on some builds, or a package wildcard the order cannot list may supply
	 * (`TypeNameBinding.bindingsOf`). Read off the file, not the value: a value of `type` the file did not write takes them
	 * too.
	 */
	public function alternateTypes(file: String, type: String): Array<String> {
		final name: String = SourceText.lastSegment(type);
		final maybe: Array<NameTarget> = maybeOf(targetsOf(file, name));
		if (maybe.length == 0 || typeOf(file, name) != type) return [];
		final out: Array<String> = [];
		for (t in maybe) {
			final alternate: String = keyOf(t, true);
			if (alternate != type && !out.contains(alternate)) out.push(alternate);
		}
		return out;
	}

	/**
	 * The `alternateTypes` of `type` as each file of `files` reads it, each once: a value of `type` read off a declaration of
	 * another file is the name that file wrote, which may be another type there.
	 */
	public function alternateTypesIn(files: Array<String>, type: String): Array<String> {
		final out: Array<String> = [];
		for (f in files) for (alternate in alternateTypes(f, type)) if (!out.contains(alternate)) out.push(alternate);
		return out;
	}

	/**
	 * `typeOf` for a dotted path, which needs no file: its last segment unless the path names a type outside the tables
	 * whose simple name a declaration they hold bears. A path starting at a type (`Module.Sub`) is read by its last segment.
	 */
	public function pathType(path: String): String {
		final key: String = pathKey(path);
		if (key == path && path.indexOf('.') >= 0) CallGraphTypes.unionInto(_foreign, SourceText.lastSegment(path), [path]);
		return key;
	}

	/**
	 * The key a written dotted path of a type names, for matching it (`CallGraph.matchIds`): `pathType`'s, without recording
	 * the path as met.
	 */
	public function pathKey(path: String): String {
		final simple: String = SourceText.lastSegment(path);
		final dot: Int = path.indexOf('.');
		if (dot < 0 || CallGraphNames.isTypeLike(path.substring(0, dot))) return simple;
		final declared: Null<Array<String>> = _declaredPaths[simple];
		return declared == null || declared.contains(path) ? simple : path;
	}

	/**
	 * The type keys a pattern `T.*` or `pkg.T.*` names, `written` its part before `.*` (`CallGraph.matchIds`): every type
	 * keyed by the simple name `T`, by it or by a path ending in it; the one declared at `pkg.T` alone (`pathKey`).
	 */
	public function typeKeys(written: String): Array<String> {
		final simple: String = SourceText.lastSegment(written);
		return written == simple ? foreignPaths(simple).concat([simple]) : [pathKey(written)];
	}

	/** The paths of types outside the tables that bear the simple name `simple`, each keyed by its path (`pathType`). */
	public inline function foreignPaths(simple: String): Array<String> {
		return _foreign[simple] ?? [];
	}

	/**
	 * The graph ids a member query names (`CallGraph.resolveTarget`): `T.m` names the member `m` of every type keyed by the
	 * simple name `T` — the one keyed so, and each `pathType` keyed by a path ending in `T`; `pkg.T.m` names the member of
	 * the type declared at that path alone (`pathKey`), never a namesake declared elsewhere.
	 */
	public function memberIds(query: String): Array<String> {
		final simple: String = CallGraphNames.lastSegments(query, 2);
		final dot: Int = simple.indexOf('.');
		final member: String = simple.substring(dot);
		if (query != simple) return [pathKey(query.substring(0, query.length - simple.length + dot)) + member];
		return [simple].concat([for (path in foreignPaths(simple.substring(0, dot))) path + member]);
	}

	/** Every type `name` may bind to in `file` (`TypeNameBinding.bindingsOf`), read once per file; null for a file the tables do not hold. */
	private function targetsOf(file: String, name: String): Null<NameTargets> {
		final key: String = CallGraphNames.normalizePath(file);
		final byName: Map<String, NameTargets> = _targets[key] ?? [];
		_targets[key] = byName;
		final known: Null<NameTargets> = byName[name];
		if (known != null) return known;
		final held: Null<HeldFile> = _held(file);
		if (held == null) return null;
		final read: NameTargets = held.index.refs.names.bindingsOf(name, held.info);
		byName[name] = read;
		return read;
	}

	/**
	 * The key of the type `target` binds a name to: a declaration's simple name, a type outside the indexes by its path when
	 * a declaration the tables hold bears its simple name (`pathType`, which records the path met when `record`).
	 */
	private function keyOf(target: NameTarget, record: Bool): String {
		return switch target {
			case InIndex(decls): decls[0].type.name;
			case OutOfIndex(path): record ? pathType(path) : pathKey(path);
		};
	}

	/** The spelling of the type `target` binds `name` to (`writtenAs`): a `StdTypes` type by its bare name. */
	private static function spellingOf(target: NameTarget, name: String): String {
		return switch target {
			case InIndex(decls) if (decls[0].file.module != TypeNameBinding.STD_TYPES_MODULE): TypeNameBinding.canonicalPath(decls[0]);
			case InIndex(_): name;
			case OutOfIndex(path): path;
		};
	}

	/** What `targets` binds a name to instead on some build: a guarded statement's type, then a wildcard's the order cannot list. */
	private static inline function maybeOf(targets: Null<NameTargets>): Array<NameTarget> {
		return targets == null ? [] : targets.guarded.concat(targets.unlisted);
	}

}

/** A type one declaration writes (null for none), and the file writing it, where its names are read (`CallGraphKeys.keyedIn`). */
typedef WrittenIn = {
	var file: String;
	var written: Null<String>;
}
