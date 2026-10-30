package anyparse.query;

import anyparse.query.AncestorTable.AncestorLink;
import anyparse.query.ArgumentSlots.ArgumentFit;
import anyparse.query.MemberLookup.HostedMembers;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.ModuleField;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.query.TypeNameBinding.ImportPath;

using Lambda;

/**
 * Which static extension a field access `recv.name` binds, step T3 of the typer by specification
 * (`docs/typing-service.md`): the compiler's order of `fields.ml` (`type_field`, Haxe 4.3.7) over the declarations the
 * index holds, each step compiled first (`docs/decisions.md`, FU14). A field of the receiver's type binds before any
 * extension. Then the type extensions of the receiver's type (`type_field_by_type_extension`, its `mt_using`): the
 * paths of its own `@:using` annotations, the LAST written first, then everything its superclass brings, then each
 * interface's, in that order; a `typedef` brings its own and then the aliased type's. Then the module extensions
 * (`type_field_by_module_extension`): the file's `using` statements, the LAST first, then each `import.hx` of the
 * ambient chain, the nearest first and its last `using` first. One path brings the types of its module in REVERSE
 * declaration order — a `typedef` alias of a class brings that class, an anonymous structure nothing — and the module's
 * own module-level functions after them. Each candidate is a public static function of the name taking a first
 * parameter, and the compiler binds the first whose first parameter accepts the receiver
 * (`StructuralTypes.receiverFitsParameter`), PASSING OVER one that rejects it — into the next type, the next path,
 * from the type's `@:using` into the file's.
 *
 * A positive whitelist: the walk answers only a binding it proves at every step before it, and `null` for everything
 * else — a path the index cannot read, a candidate type built by a macro or declared under `#if`, a candidate it
 * cannot type (an overload, a macro, a module-level function, a non-public or default-visibility static), a first
 * parameter that may or may not accept the receiver, a guarded `using` that may supply one, a module the
 * index holds in several files one of which supplies one, an ambient chain the index does not bound; and
 * when no file `using` binds, since the compiler's global extensions (`haxe.EnumTools`) come last.
 */
@:nullSafety(Strict)
final class StaticExtensions {

	/** The name -> declaration layer every `using` path and alias is read through. */
	private final _refs: TypeRefIndex;

	/** The owning service's remembered answers. */
	private final _cache: QueryCache;

	/** The supertype links, alias targets and build macros of the declarations the walk reads. */
	private final _ancestors: AncestorTable;

	/** Whether the receiver's own type declares the name, which binds before every extension. */
	private final _members: MemberLookup;

	/** Whether a candidate's first parameter accepts the receiver. */
	private final _structural: StructuralTypes;

	/** Built once by the owning `TypingService`. */
	public function new(
		refs: TypeRefIndex, cache: QueryCache, ancestors: AncestorTable, members: MemberLookup, structural: StructuralTypes
	) {
		_refs = refs;
		_cache = cache;
		_ancestors = ancestors;
		_members = members;
		_structural = structural;
	}

	/**
	 * The static extension `recv.name` binds in the file `fi` on a receiver of the declaration `receiver` — the one
	 * member and the type declaring it — or null when the walk proves none (the class doc). Remembered by the file and the
	 * receiver's declaration (`DeclarationKey.ofUse`): the answer reads the file's `using` statements and declarations
	 * only, never a body.
	 */
	public function binding(fi: FileInfo, receiver: ResolvedType, name: String): Null<HostedMembers> {
		return _cache.extensionBindings.answer(DeclarationKey.ofUse(fi.file, receiver, name), bindingOf.bind(fi, receiver, name));
	}

	/**
	 * Whether `recv.name` in the file `fi`, on a receiver of the declaration `receiver`, may bind through `using <path>` —
	 * whether that statement takes part in the access at all. Where the walk proves a binding (`binding`), only when the
	 * bound type is one the path brings; where it proves none or decides nothing, unless every candidate the path brings
	 * passes the receiver over (`offers`). The question a rule deleting or moving a `using` asks of each access.
	 */
	public function mayBindThrough(fi: FileInfo, receiver: ResolvedType, name: String, path: String): Bool {
		final bound: Null<HostedMembers> = binding(fi, receiver, name);
		if (bound == null) return offers(path, receiver, name) != Misfits;
		final hosts: Null<UsingHosts> = usingHosts(path);
		return hosts == null || hosts.types.exists(h -> h.file.file == bound.host.file.file && h.type.name == bound.host.type.name);
	}

	/**
	 * What `using <path>` offers `recv.name` on a receiver of the declaration `receiver`, whatever else is in scope: `Fits`
	 * when a candidate it brings binds there, `Misfits` when every candidate passes the receiver over or none is declared,
	 * `MayFit` when the walk decides nothing (the path does not read, a candidate it cannot type, a first parameter that may
	 * or may not accept the receiver) — and always for a receiver that forwards (`forwardsAccess`), whose underlying type's
	 * extensions answer an access the receiver itself does not declare.
	 */
	public function offers(path: String, receiver: ResolvedType, name: String): ArgumentFit {
		if (forwardsAccess(receiver, [])) return MayFit;
		return switch pathStep(path, receiver, name) {
			case Bound(_): Fits;
			case Passed: Misfits;
			case Open: MayFit;
		};
	}

	/**
	 * The types the `using` statements of `fi` (its own, then its ambient chain's) bring static extensions from, by simple
	 * name, each once: every type a path brings (`usingHosts`), and the last segment of a path the index cannot read.
	 * What a call that names no receiver type may reach (`CallGraphImports.staticExtensionsOf`).
	 */
	public function usingTypes(fi: FileInfo): Array<String> {
		final out: Array<String> = [];
		for (u in usingsOf(fi)) {
			final hosts: Null<UsingHosts> = usingHosts(u.raw);
			final names: Array<String> = hosts == null ? [SourceText.lastSegment(u.raw)] : [for (t in hosts.types) t.type.name];
			for (n in names) if (!out.contains(n)) out.push(n);
		}
		return out;
	}

	/**
	 * Whether a `using` in scope of `fi` — its own, a guarded one, an ambient one — may supply a static extension named
	 * `name`: a type it brings declares a static of the name, its module a module-level field of it, or it is a path the
	 * index cannot read; true as well for an ambient chain the index does not bound. What a read that binds through an
	 * abstract's resolver asks first (`OperandBinder.resolveTier`), since an extension in scope binds before it.
	 */
	public function maySupply(fi: FileInfo, name: String): Bool {
		return !fi.ambientImportsBounded || usingsOf(fi).exists(u -> {
			final hosts: Null<UsingHosts> = usingHosts(u.raw);
			hosts == null
				|| hosts.moduleFields.exists(f -> f.name == name)
				|| hosts.types.exists(h -> h.type.members.exists(m -> m.name == name && m.isStatic));
		});
	}

	/**
	 * Which `using` of the file `fi` a call `recv.method(…)` may bind to, whatever the receiver — walking back from the last
	 * of the file's own: the first whose path the index cannot read (`hosts` null: what it brings is unknown) or whose
	 * module declares a static `method` it extends with on one of its types, or a module-level field of the name, every
	 * path after it read and built by no macro. Null when none may, at a type a macro builds, and when the file has a
	 * guarded `using` or an ambient one, whose order against its own this does not decide.
	 */
	public function bindingUsing(fi: FileInfo, method: String): Null<{ path: String, hosts: Null<Array<ResolvedType>> }> {
		if (fi.ambientImports.exists(g -> g.imports.exists(i -> i.kind == ImportKind.Using))) return null;
		final usings: Array<ImportInfo> = fi.imports.filter(i -> i.kind == ImportKind.Using);
		if (usings.exists(u -> u.guarded)) return null;
		var k: Int = usings.length;
		while (k-- > 0) {
			final path: String = usings[k].raw;
			final hosts: Null<UsingHosts> = usingHosts(path);
			if (hosts == null) return { path: path, hosts: null };
			if (hosts.types.exists(h -> _ancestors.builtAtOrAbove(h))) return null;
			final declares: Bool = hosts.moduleFields.exists(f -> f.name == method)
				|| hosts.types.exists(h -> h.type.members.exists(m -> extendsAs(m, method)));
			if (declares) return { path: path, hosts: hosts.types };
		}
		return null;
	}

	/**
	 * What `using <path>` brings, in the order the compiler tries it (`ImportHandling.handle_using`, `filter_classes`): the
	 * non-private types of the module, the LAST declared first — a `typedef` alias as the class or abstract it re-points
	 * at, an anonymous structure and an enum as nothing — then the module's module-level fields; the one type a
	 * `Module.Sub` path names, and no module-level field. A module the index holds in several files (a library's copy
	 * beside the std's, a target's `_std` override) is the one the class path reaches first, which the index does not
	 * know: every file's candidates are listed and the answer is `ambiguous`. Null when the path does not decode, names a
	 * module the index holds in no file, names a type no file of the module declares, or brings an alias that does not
	 * resolve.
	 */
	public function usingHosts(path: String): Null<UsingHosts> {
		final split: Null<ImportPath> = TypeNameBinding.splitPath(path);
		if (split == null || split.rest.length > 1) return null;
		final files: Array<FileInfo> = _refs.names.filesOfModule(split.module);
		final sub: Null<String> = split.rest.length == 1 ? split.rest[0] : null;
		final types: Array<ResolvedType> = [];
		final fields: Array<ModuleField> = [];
		var named: Bool = false;
		for (fi in files) {
			final declared: Array<TypeDeclInfo> = fi.types.filter(t -> !t.isPrivate && (sub == null || t.name == sub));
			if (declared.length > 0) named = true;
			var k: Int = declared.length;
			while (k-- > 0) {
				final host: Null<ResolvedType> = hostOf({ file: fi, type: declared[k] }, []);
				if (host == null) return null;
				if (host.type.kind != SymbolIndex.TYPEDEF_DECL_KIND && host.type.kind != SymbolIndex.ENUM_DECL_KIND) types.push(host);
			}
			if (sub == null) for (f in fi.moduleFields) fields.push(f);
		}
		return files.length == 0 || sub != null && !named ? null : { types: types, moduleFields: fields, ambiguous: files.length > 1 };
	}

	/** `binding`, computed. */
	private function bindingOf(fi: FileInfo, receiver: ResolvedType, name: String): Null<HostedMembers> {
		if (!_members.declarationLacksMember(receiver, name)) return null;
		final own: ExtensionStep = typeStep(receiver, receiver, name, []);
		if (own != Passed) return bound(own);
		final ambient: Array<ImportInfo> = [for (group in fi.ambientImports) for (u in reversedUsings(group.imports)) u];
		for (u in reversedUsings(fi.imports).concat(ambient)) {
			final step: ExtensionStep = pathStep(u.raw, receiver, name);
			if (step != Passed) return u.guarded ? null : bound(step);
		}
		return null;
	}

	/**
	 * The type extensions of `cur` (its `mt_using`) asked for `name` on `receiver`: the paths its `@:using` annotations
	 * write, the last first, then — a `typedef` — the aliased type's, or — a class or an interface — its superclass's and
	 * then each interface's, every link resolved (`AncestorTable.links`). `Open` for a declaration whose annotations do
	 * not read as paths, an alias that does not resolve, a `@:forward` abstract (its underlying's extensions apply), a link that resolves
	 * to no single declaration, and — for a type under `#if`, whose links are the union of its branches — any link that does not pass.
	 */
	private function typeStep(cur: ResolvedType, receiver: ResolvedType, name: String, seen: Array<String>): ExtensionStep {
		if (!_refs.markSeen(cur, seen)) return Passed;
		final t: TypeDeclInfo = cur.type;
		final paths: Null<Array<String>> = t.extensionTypesRaw;
		if (paths == null) return Open;
		var k: Int = paths.length;
		while (k-- > 0) {
			final step: ExtensionStep = pathStep(paths[k], receiver, name);
			if (step != Passed) return step;
		}
		if (t.kind == SymbolIndex.TYPEDEF_DECL_KIND) {
			if (t.isAnonStruct) return Passed;
			final next: Null<ResolvedType> = _ancestors.aliasTarget(cur);
			return next == null ? Open : typeStep(next, receiver, name, seen);
		}
		if (t.abstractForwardUnderlying != null) return Open;
		final links: Array<AncestorLink> = _ancestors.links(cur).filter(l -> !AncestorTable.dynamicSupertypeRef(l.raw));
		// the superclass's list before every interface's (`typeloadFields.ml`: `inherit_using` of `csup`, then each interface)
		final ordered: Array<AncestorLink> = links.filter(l -> !implemented(t, l)).concat(links.filter(l -> implemented(t, l)));
		for (link in ordered) {
			final up: Null<ResolvedType> = link.decl;
			if (up == null) return Open;
			final step: ExtensionStep = typeStep(up, receiver, name, seen);
			// the links of a type under `#if` are its branches' union: one that brings a candidate may be another build's
			if (step != Passed) return t.guarded ? Open : step;
		}
		return Passed;
	}

	/**
	 * What the candidates `using <path>` brings (`usingHosts`) say about `name` on `receiver`, in their order; of a module
	 * held in several files, `Passed` only when every file's candidates pass, since which file the compiler loads is unknown.
	 */
	private function pathStep(path: String, receiver: ResolvedType, name: String): ExtensionStep {
		final hosts: Null<UsingHosts> = usingHosts(path);
		if (hosts == null) return Open;
		for (host in hosts.types) {
			final step: ExtensionStep = candidateStep(host, receiver, name);
			if (step != Passed) return hosts.ambiguous ? Open : step;
		}
		// a module-level function would be the module's last candidate, and the index records no signature for it
		return hosts.moduleFields.exists(f -> f.name == name) ? Open : Passed;
	}

	/**
	 * Whether the static `name` of `host` binds on `receiver` (`Bound`), is passed over (`Passed`: none declared, a
	 * `@:noUsing` one, one taking no parameter, one whose first parameter rejects the receiver) or is not decided
	 * (`Open`: a type a macro may give the static, a static declared twice or under `#if`, one that is not a plain
	 * function, a macro, an `@:overload`, one not public, a first parameter that may accept the receiver).
	 */
	private function candidateStep(host: ResolvedType, receiver: ResolvedType, name: String): ExtensionStep {
		if (_ancestors.builtAtOrAbove(host)) return Open;
		final statics: Array<MemberInfo> = host.type.members.filter(m -> m.name == name && m.isStatic);
		if (statics.length == 0) return Passed;
		final m: MemberInfo = statics[0];
		if (statics.length > 1 || host.type.guarded || m.guarded) return Open;
		if (m.excludedFromExtensions) return Passed;
		if (!MemberKinds.FN_DECL_KINDS.contains(m.kind) || m.isMacro || m.hasOverloadMeta || !accessible(m, host)) return Open;
		if (m.paramTypeSources.length == 0) return Passed;
		return switch _structural.receiverFitsParameter(receiver, m, host) {
			case Fits: Bound({ members: [m], host: host });
			case Misfits: Passed;
			case MayFit: Open;
		};
	}

	/**
	 * Whether `r`, through its `typedef` aliases, is a `@:forward` abstract — 4.3.7 hands an access it does not declare to
	 * the underlying type, where that type's extensions bind (`p.trim()` on a forward abstract over `String` compiles with
	 * `using StringTools` only) — or an alias that does not resolve.
	 */
	private function forwardsAccess(r: ResolvedType, seen: Array<String>): Bool {
		if (r.type.kind != SymbolIndex.TYPEDEF_DECL_KIND || r.type.isAnonStruct) return r.type.abstractForwardUnderlying != null;
		if (!_refs.markSeen(r, seen)) return true;
		final next: Null<ResolvedType> = _ancestors.aliasTarget(r);
		return next == null || forwardsAccess(next, seen);
	}

	/**
	 * `r` as the type a `using` of its module brings: itself, or the declaration its `typedef` alias re-points at, hop by
	 * hop; null for an alias that does not resolve or re-enters itself.
	 */
	private function hostOf(r: ResolvedType, seen: Array<String>): Null<ResolvedType> {
		if (r.type.kind != SymbolIndex.TYPEDEF_DECL_KIND || r.type.isAnonStruct) return r;
		if (!_refs.markSeen(r, seen)) return null;
		final next: Null<ResolvedType> = _ancestors.aliasTarget(r);
		return next == null ? null : hostOf(next, seen);
	}

	/**
	 * Whether the member `m` of `host` is accessible from any file (`fields.ml`: `can_access`): written `public`, or a
	 * member of an `extern` type or an interface written with no visibility, which defaults to public there. A private
	 * member is reached from its class and its subclasses only, which a question keyed by the file does not see.
	 */
	public static inline function accessible(m: MemberInfo, host: ResolvedType): Bool {
		return m.visibility == SymbolIndex.PUBLIC_VISIBILITY
			|| m.visibility == null
			&& (host.type.isExtern || host.type.kind == SymbolIndex.INTERFACE_DECL_KIND);
	}

	/** Whether the link `link` of `t` is an interface: every link of an interface, an `implements` link of a class. */
	private static inline function implemented(t: TypeDeclInfo, link: AncestorLink): Bool {
		return t.kind == SymbolIndex.INTERFACE_DECL_KIND || t.interfaces.contains(SourceText.lastSegment(link.raw));
	}

	/** Whether `m` is a static a `using` offers as the extension `method` — `@:noUsing` withholds it. */
	private static inline function extendsAs(m: MemberInfo, method: String): Bool {
		return m.name == method && m.isStatic && !m.excludedFromExtensions;
	}

	/** The `using` statements of `fi`: its own, then each group of its ambient chain, nearest first. */
	private static function usingsOf(fi: FileInfo): Array<ImportInfo> {
		final out: Array<ImportInfo> = fi.imports.filter(i -> i.kind == ImportKind.Using);
		for (group in fi.ambientImports) for (i in group.imports) if (i.kind == ImportKind.Using) out.push(i);
		return out;
	}

	/** The `using` statements among `imports`, the last first: the order the compiler tries them in. */
	private static function reversedUsings(imports: Array<ImportInfo>): Array<ImportInfo> {
		final out: Array<ImportInfo> = imports.filter(i -> i.kind == ImportKind.Using);
		out.reverse();
		return out;
	}

	/** The answer a step that is not `Passed` gives: its binding, or null. */
	private static function bound(step: ExtensionStep): Null<HostedMembers> {
		return switch step {
			case Bound(found): found;
			case _: null;
		};
	}

}

/** What one `using` path brings as static extensions (`StaticExtensions.usingHosts`). */
typedef UsingHosts = {

	/** The types whose statics are candidates, in the order the compiler tries them. */
	final types: Array<ResolvedType>;

	/** The module-level fields of the module, tried after its types; none for a `Module.Sub` path. */
	final moduleFields: Array<ModuleField>;

	/** Whether the index holds the module in several files: `types` and `moduleFields` list every file's, in no one order. */
	final ambiguous: Bool;

}

/** What one step of the walk says (`StaticExtensions`): it binds, it passes the access on, or it is not decided. */
private enum ExtensionStep {
	Bound(found: HostedMembers);
	Passed;
	Open;
}
