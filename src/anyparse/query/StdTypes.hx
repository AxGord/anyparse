package anyparse.query;

import anyparse.query.CallGraph.FnNode;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import haxe.Exception;

using Lambda;

/**
 * The written member types of the Haxe std core — the toplevel, `haxe/` and `sys/` (`StdResolver.resolutionSpecs`), the
 * library every target shares — read one module at a time when a `CallGraph` asks: what a call of a library function
 * returns, what a library field or property holds. A receiver made by one (`Sys.stdin().readLine()`,
 * `socket.input.readLine()`) is then typed as one the project annotates is. By simple type name, as the graph keys types:
 * an answer stands only when every std type of that name declaring the member, through its supertypes and typedef targets,
 * gives one type the module it is written in resolves. Process-wide (the std does not change under a run); inert without a
 * discovered std (`StdResolver.stdDir`, `APQ_NO_STD`).
 */
@:nullSafety(Strict)
final class StdTypes {

	/** How deep a member is looked for through supertypes and typedef targets. */
	private static inline final MAX_DEPTH: Int = 8;

	/**
	 * The std's toplevel types every module reaches with no import, each mapped to the ONE path it denotes — its own name, or
	 * `haxe.ds.Map` for the root `Map` typedef that re-points at it: what the toplevel binds where the index does not hold the
	 * std (`toplevelPath`). The value half is load-bearing: matching the name alone would read `haxe.macro.Type` as `Type`.
	 */
	private static final TOPLEVEL: Map<String, String> = [
		'Int' => 'Int',
		'UInt' => 'UInt',
		'Float' => 'Float',
		'Bool' => 'Bool',
		'String' => 'String',
		'Void' => 'Void',
		'Dynamic' => 'Dynamic',
		'Any' => 'Any',
		'Null' => 'Null',
		'Array' => 'Array',
		'Map' => 'haxe.ds.Map',
		'Class' => 'Class',
		'Enum' => 'Enum',
		'EnumValue' => 'EnumValue',
		'Date' => 'Date',
		'DateTools' => 'DateTools',
		'Math' => 'Math',
		'Reflect' => 'Reflect',
		'Std' => 'Std',
		'StringBuf' => 'StringBuf',
		'StringTools' => 'StringTools',
		'Sys' => 'Sys',
		'Type' => 'Type',
		'EReg' => 'EReg',
		'Lambda' => 'Lambda',
		'Xml' => 'Xml'
	];

	/** Every std core module path, for resolving a simple name written inside one. */
	private static final modulePaths: Map<String, Bool> = [];

	/** Module path -> its declarations, null for one that cannot be read or parsed. */
	private static final moduleInfos: Map<String, Null<FileInfo>> = [];

	/** Every package a std core module sits in (the toplevel as ''), telling a package the core holds from a library's. */
	private static final packages: Map<String, Bool> = [];

	/** Module path -> the declarations of a std module outside the core (`moduleTypes`), null for one that cannot be read. */
	private static final outsideInfos: Map<String, Null<FileInfo>> = [];

	/** Type simple name -> the std core modules of that name (`haxe.io.Input`); null until the std is listed. */
	private static var _modules: Null<Map<String, Array<String>>> = null;

	/** The std root `_modules` lists — a discovery that answers another (`StdResolver.resetCache`) lists again. */
	private static var _listedRoot: Null<String> = null;

	/** The path the std's toplevel type `name` denotes with no import (`TOPLEVEL`), or null for a name the toplevel holds none of. */
	public static inline function toplevelPath(name: String): Null<String> {
		return TOPLEVEL[name];
	}

	/**
	 * What `member` of the std type `typeName` (a simple name, or a module path) is: the module path of the type it
	 * returns (a function) or holds (a field) — null when the type written is none the module resolves (a type
	 * parameter, a function type, a core type) — and its accessors. Null when no std type of that name declares it, or
	 * when two say different things of it.
	 */
	public static function memberOf(plugin: GrammarPlugin, typeName: String, member: String): Null<StdMember> {
		final modules: Map<String, Array<String>> = listed();
		final candidates: Array<String> = typeName.indexOf('.') >= 0 ? [typeName] : modules[typeName] ?? [];
		final found: Array<StdMember> = [];
		for (module in candidates) lookUp(plugin, module, member, 0, [], found, false);
		if (found.length == 0) return null;
		final first: StdMember = found[0];
		final agree: Bool = found.foreach(
			f ->
				f.type == first.type && f.isFunction == first.isFunction && f.hasGetter == first.hasGetter && f.hasSetter == first.hasSetter
		);
		return agree ? first : null;
	}

	/** What a call of `target` returns when it is a placeholder for a std function: the module path; else null. */
	public static function returnOf(plugin: GrammarPlugin, target: Null<FnNode>): Null<String> {
		final owner: Null<String> = target?.typeName;
		final name: Null<String> = target?.name;
		final m: Null<StdMember> = target == null || !target.isExternal || owner == null || name == null
			? null
			: memberOf(plugin, owner, name);
		return m != null && m.isFunction ? m.type : null;
	}

	/** The module path of the type the std field `member` of `typeName` holds; null for none, or for a function. */
	public static function fieldOf(plugin: GrammarPlugin, typeName: String, member: String): Null<String> {
		final m: Null<StdMember> = memberOf(plugin, typeName, member);
		return m != null && !m.isFunction ? m.type : null;
	}

	/**
	 * Whether the std type `typeName` (a simple name, or a module path) provably declares `member` as an INSTANCE member,
	 * itself or through its supertypes and typedef targets — `MemberLookup.instanceMemberBinds` for a receiver whose type
	 * the index does not hold. Stricter than `memberOf`, which unions every std type of a simple name: here EVERY std
	 * module the name may mean must prove it (`Map` is the toplevel typedef and `haxe.ds.Map`, and both reach
	 * `haxe.ds.Map.exists`), and every declaration found must be a non-static one reached through no `#if` — neither
	 * guarded itself nor on or behind a guarded type (`haxe.http.HttpJs` is declared under `#if js`).
	 */
	public static function declaresInstanceMember(plugin: GrammarPlugin, typeName: String, member: String): Bool {
		final candidates: Array<String> = typeName.indexOf('.') >= 0 ? [typeName] : listed()[typeName] ?? [];
		return candidates.length > 0 && candidates.foreach(module -> {
			final found: Array<StdMember> = [];
			lookUp(plugin, module, member, 0, [], found, false);
			found.length > 0 && found.foreach(f -> !f.isStatic && !f.guarded);
		});
	}

	/**
	 * Whether the std core declares the module `pkg.name` (`name` for the toplevel
	 * `pkg` "") — what a wildcard `import pkg.*;` brings in under `name`. Null when
	 * that cannot be told: no std discovered, or `pkg` a package the core does not hold (a library's, a target's).
	 */
	public static function declaresModule(pkg: String, name: String): Null<Bool> {
		listed();
		return packages.exists(pkg) ? modulePaths.exists(pkg == '' ? name : '$pkg.$name') : null;
	}

	/**
	 * The simple names of the std core modules directly in `pkg` — every name a wildcard `import pkg.*;` may bring in from the
	 * core. Null when that cannot be told, as for `declaresModule`.
	 */
	public static function moduleNamesIn(pkg: String): Null<Array<String>> {
		final modules: Map<String, Array<String>> = listed();
		return packages.exists(pkg) ? [
			for (name => paths in modules) if (paths.exists(p -> SourceText.parentPath(p) == pkg)) name
		] : null;
	}

	/**
	 * The accessors a use of the std property `member` of `typeName` runs — the getter (`prefixes[0]` + name) when it
	 * `reads`, the setter (`prefixes[1]` + name) when it `writes` — by their member names; none for a plain field.
	 */
	public static function accessorsOf(
		plugin: GrammarPlugin, typeName: String, member: String, reads: Bool, writes: Bool, prefixes: Array<String>
	): Array<String> {
		final m: Null<StdMember> = memberOf(plugin, typeName, member);
		return m == null || m.isFunction ? [] : [
			for (i in 0...2) if ((i == 0 ? reads && m.hasGetter : writes && m.hasSetter) && i < prefixes.length) prefixes[i] + member
		];
	}

	/** TEST-ONLY seam: forget the listing and the modules read, so a test that moves the std reads it again. */
	public static function resetCache(): Void {
		_modules = null;
		modulePaths.clear();
		packages.clear();
		moduleInfos.clear();
		outsideInfos.clear();
	}

	/**
	 * The types the std module `module` declares (`haxe.Timer`, the toplevel `StdTypes`, a target module such as
	 * `js.html.Element` outside the core the other answers here read), read once — what a name binding over an index that
	 * does not hold the std asks before it lets a lower tier answer. Null when that cannot be told: no std discovered, no
	 * std file of that module, or one that does not parse.
	 */
	public static function moduleTypes(plugin: GrammarPlugin, module: String): Null<Array<TypeDeclInfo>> {
		listed();
		if (modulePaths.exists(module)) return infoOf(plugin, module)?.types;
		if (outsideInfos.exists(module)) return outsideInfos[module]?.types;
		final root: Null<String> = StdResolver.stdDir();
		final info: Null<FileInfo> = root == null ? null : parsed(plugin, '$root/${module.split('.').join('/')}.hx');
		outsideInfos[module] = info;
		return info?.types;
	}

	/**
	 * Push into `found` what `member` of the type at `path` is, or, when it declares none, what its supertypes and typedef
	 * targets do. `viaGuard`: the walk reached `path` through a type under `#if`, which marks everything found from it
	 * `guarded`.
	 */
	private static function lookUp(
		plugin: GrammarPlugin, path: String, member: String, depth: Int, seen: Array<String>, found: Array<StdMember>, viaGuard: Bool
	): Void {
		if (depth > MAX_DEPTH || seen.contains(path)) return;
		seen.push(path);
		final info: Null<FileInfo> = infoOf(plugin, moduleOf(path));
		if (info == null) return;
		final simple: String = SourceText.lastSegment(path);
		final fnKinds: Array<String> = plugin.refShape().functionKinds ?? [];
		for (t in info.types) if (t.name == simple) {
			final guarded: Bool = viaGuard || t.guarded;
			final declared: Array<MemberInfo> = t.members.filter(m -> m.name == member);
			for (m in declared) found.push(described(plugin, info, m, fnKinds.contains(m.kind), guarded));
			if (declared.length > 0) continue;
			final next: Array<String> = t.supertypesRaw.copy();
			final alias: Null<String> = t.aliasTargetRaw;
			if (alias != null) next.push(alias);
			for (n in next) {
				final resolved: Null<String> = resolve(plugin, info, n);
				if (resolved != null) lookUp(plugin, resolved, member, depth + 1, seen, found, guarded);
			}
		}
	}

	/** The member `m` of a type in `info`, its written type resolved there; `viaGuard` as `lookUp` reads it. */
	private static function described(plugin: GrammarPlugin, info: FileInfo, m: MemberInfo, isFunction: Bool, viaGuard: Bool): StdMember {
		final written: Null<String> = isFunction ? m.returnSource : m.typeSource;
		return {
			type: written == null ? null : resolve(plugin, info, written),
			isFunction: isFunction,
			hasGetter: m.hasGetter,
			hasSetter: m.hasSetter,
			isStatic: m.isStatic,
			guarded: viaGuard || m.guarded
		};
	}

	/**
	 * The module path of the type `written` names inside `info` (`Null<…>` peeled, arguments dropped): a dotted path as
	 * written; a simple name as the module resolves it — one of its own types, an import or an alias of it, a module of its
	 * package, a toplevel one. Null for anything else.
	 */
	private static function resolve(plugin: GrammarPlugin, info: FileInfo, written: String): Null<String> {
		final t: Null<TypeSyntax> = plugin.typeSyntax(written.trim());
		final path: Null<String> = switch (t?.wrapped(['Null']) ?? t)?.shape {
			case Nominal(p, _): p;
			case _: null;
		};
		if (path == null || path.indexOf('.') >= 0) return path;
		final name: String = path;
		if (info.types.exists(d -> d.name == name))
			return SourceText.lastSegment(info.module) == name ? info.module : '${info.module}.$name';
		var imported: Null<String> = null;
		for (imp in info.imports) {
			final target: Null<String> = imp.aliasTarget;
			if (imp.alias == name && target != null)
				imported = target
			else if (imp.alias == null && SourceText.lastSegment(imp.raw) == name)
				imported = imp.raw;
		}
		if (imported != null) return imported;
		final sibling: String = info.pkg == '' ? name : '${info.pkg}.$name';
		return if (modulePaths.exists(sibling))
			sibling
		else if (modulePaths.exists(name))
			name
		else
			null;
	}

	/** The module a type path lives in: the path itself when it names a module, else the path without its last segment. */
	private static function moduleOf(path: String): String {
		if (modulePaths.exists(path)) return path;
		final parent: String = SourceText.parentPath(path);
		return parent != '' && modulePaths.exists(parent) ? parent : path;
	}

	/** The declarations of the std module at `module`, read once; null when it is none or does not parse. */
	private static function infoOf(plugin: GrammarPlugin, module: String): Null<FileInfo> {
		if (moduleInfos.exists(module)) return moduleInfos[module];
		final root: Null<String> = StdResolver.stdDir();
		final info: Null<FileInfo> = root != null && modulePaths.exists(module)
			? parsed(plugin, '$root/${module.split('.').join('/')}.hx')
			: null;
		moduleInfos[module] = info;
		return info;
	}

	/** Type simple name -> the std core modules of that name, listed once. */
	private static function listed(): Map<String, Array<String>> {
		final root: Null<String> = StdResolver.stdDir();
		final held: Null<Map<String, Array<String>>> = _modules;
		if (held != null && root == _listedRoot) return held;
		resetCache();
		_listedRoot = root;
		final modules: Map<String, Array<String>> = [];
		if (root != null)
			for (spec in StdResolver.resolutionSpecs(root)) for (file in Glob.expand(spec, '.hx')) if (file.startsWith('$root/')) {
				final module: String = file.substring(root.length + 1, file.length - 3).split('/').join('.');
				modulePaths[module] = true;
				packages[module.substring(0, Std.int(Math.max(0, module.lastIndexOf('.'))))] = true;
				final simple: String = SourceText.lastSegment(module);
				final named: Array<String> = modules[simple] ?? [];
				named.push(module);
				modules[simple] = named;
			}
		_modules = modules;
		return modules;
	}

	private static function read(file: String): Null<String> {
		return #if (sys || nodejs) try sys.io.File.getContent(file) catch (exception: Exception) null #else null #end;
	}

	/** The declarations of the std file `file`, null when it cannot be read or does not parse. */
	private static function parsed(plugin: GrammarPlugin, file: String): Null<FileInfo> {
		final source: Null<String> = read(file);
		return source == null ? null : try IndexScope.declarationsOf(file, source, plugin) catch (exception: Exception) null;
	}

}

/**
 * What a std member is (`StdTypes.memberOf`): the module path of the type it returns
 * or holds (null when that does not resolve), whether a getter or a setter runs, and
 * whether it is static or sits under a `#if`.
 */
typedef StdMember = {
	var type: Null<String>;
	var isFunction: Bool;
	var hasGetter: Bool;
	var hasSetter: Bool;
	var isStatic: Bool;
	var guarded: Bool;
}
