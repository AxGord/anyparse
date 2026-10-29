package anyparse.query;

import anyparse.query.Refs.RefKind;
import anyparse.query.SymbolIndex.AmbientImportGroup;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.TypeNameBinding.NameTarget;

/** The simple names one file's meaning is compared on, and where the file lives before and after the relocation. */
typedef BindingProbe = {
	final before: String;
	final after: String;
	final names: Array<String>;
}

/** One simple name whose meaning a relocation changed in one file. */
typedef BindingDrift = {
	final file: String;
	final name: String;
	final before: String;
	final after: String;

	/** The import path that gives the name its old meaning back (`pkg.Mod` / `pkg.Mod.Sub`), or null when none can. */
	final repair: Null<String>;
}

/** One qualified sub-type spelling (`Mod.Sub`) whose module-path reading a relocation changed in one file. */
typedef QualifiedDrift = {
	final file: String;
	final spelling: String;

	/** Where the spelling's first name starts in the file's text after the relocation. */
	final at: Int;

	final head: String;
	final before: String;
	final after: String;

	/** The module path that, written in place of the first name, reads as before (`pkg.Mod`), or null when none does. */
	final qualified: Null<String>;
}

/** One qualified sub-type spelling written in code: the module name it starts with, the sub-type, and where it starts. */
private typedef SubTypeSpelling = {
	final head: String;
	final sub: String;
	final at: Int;
}

/** The two indexes a qualified spelling is read through, and the relocated module paths (old -> new). */
private typedef QualifiedSides = {
	final pre: SymbolIndex;
	final post: SymbolIndex;
	final renamed: Map<String, String>;
}

/** How a qualified spelling `Head.Sub` reads at one site (`ModuleMoveBindings.headReading`). */
private enum HeadReading {

	/** The head binds no type there, or one declaring no member `Sub`: the compiler reads the spelling by module path. */
	ByModulePath;

	/** The head binds a type declaring a member named `Sub` (a static field, an enum constructor): a member access. */
	AsMember;

	/** What the head binds, or whether that declares `Sub`, is not something the index holds. */
	Unreadable;

}

/** What a simple name means in one file: a comparable key, and the one declaration it binds when it binds exactly one. */
private typedef Meaning = {
	final key: String;
	final single: Null<ResolvedType>;
}

/**
 * The proof a module relocation owes: every simple type name a moved module or one of its readers writes MEANS the same
 * declaration after the move as before — read through the resolution index's own reading of a bare name
 * (`TypeNameBinding.tierOf`), with each declaration of a relocated module identified by its NEW module path. A name whose
 * meaning drifted is reported with the import that restores it when one does, so the caller can write it and ask again.
 */
@:nullSafety(Strict)
final class ModuleMoveBindings {

	/** The key of a name the index cannot read — never the same meaning as anything, itself included. */
	public static inline final UNKNOWN: String = 'unknown';

	/**
	 * Give every indexed module that is NOT on disk the ambient chain its path would have, read from the analysed set
	 * itself — a relocated module's new path does not exist yet, so the grammar's chain walk (which reads the disk) finds
	 * nothing there. A chain position the set does not hold but the disk does leaves the chain unbounded, which the
	 * resolution reads as a name it cannot answer.
	 */
	public static function attachVirtualAmbient(index: SymbolIndex, plugin: GrammarPlugin): Void {
		final files: Array<FileInfo> = index.allFiles();
		final byFile: Map<String, FileInfo> = [for (fi in files) fi.file => fi];
		for (fi in files) if (!ConfigFinder.fileExists(fi.file)) {
			final groups: Array<AmbientImportGroup> = [];
			var bounded: Bool = true;
			for (site in plugin.ambientImportSites(fi.file, fi.pkg)) if (site != fi.file) {
				final member: Null<FileInfo> = byFile[site];
				if (member != null)
					groups.push({ file: site, imports: member.imports });
				else if (ConfigFinder.fileExists(site))
					bounded = false;
			}
			fi.ambientImports = groups;
			fi.ambientImportsBounded = bounded;
		}
	}

	/**
	 * Every name of `probes` whose meaning differs between `pre` (the tree before) and `post` (after), each declaration of
	 * `pre` read under its relocated module path (`renamed`: old module path -> new). Every occurrence is asked where it is
	 * written (`textBefore` / `textAfter` by path), so a statement inside a conditional region decides a use inside it; the
	 * rewrite changes no bare name, so the n-th occurrence before IS the n-th after.
	 */
	public static function drifts(
		pre: SymbolIndex, post: SymbolIndex, probes: Array<BindingProbe>, renamed: Map<String, String>, plugin: GrammarPlugin,
		textBefore: Map<String, String>, textAfter: Map<String, String>
	): Array<BindingDrift> {
		final preFiles: Map<String, FileInfo> = [for (fi in pre.allFiles()) fi.file => fi];
		final postFiles: Map<String, FileInfo> = [for (fi in post.allFiles()) fi.file => fi];
		final mapped: (String) -> String = module -> renamed[module] ?? module;
		final projectTypes: Map<String, String> = projectTypeModules(pre);
		final out: Array<BindingDrift> = [];
		for (probe in probes) {
			final before: Null<FileInfo> = preFiles[probe.before];
			final after: Null<FileInfo> = postFiles[probe.after];
			final was: Array<{ name: String, at: Int }> = occurrencesIn(textBefore[probe.before], probe.names, plugin);
			final now: Array<{ name: String, at: Int }> = occurrencesIn(textAfter[probe.after], probe.names, plugin);
			if (before == null || after == null || was.length != now.length) {
				out.push({
					file: probe.after,
					name: '',
					before: 'its names',
					after: 'a text this check cannot line up',
					repair: null
				});
				continue;
			}
			final seen: Array<String> = [];
			final byPath: Array<Int> = modulePathSites(pre, before, textBefore[probe.before], plugin);
			final asValue: Array<Int> = valueBoundSites(textBefore[probe.before], probe.names, plugin);
			for (i => use in was) if (!byPath.contains(use.at) && !asValue.contains(use.at)) {
				final then: Meaning = meaning(pre, before, use.name, use.at, mapped);
				final nowMeaning: Meaning = meaning(post, after, use.name, now[i].at, module -> module);
				final readable: Bool = then.key != UNKNOWN || !projectTypes.exists(use.name);
				if ((then.key == nowMeaning.key && readable) || seen.contains(use.name)) continue;
				seen.push(use.name);
				out.push({
					file: probe.after,
					name: use.name,
					before: then.key,
					after: nowMeaning.key,
					repair: repairOf(then.single, mapped)
				});
			}
		}
		return out;
	}

	/**
	 * Every qualified sub-type spelling (`Mod.Sub`, under `RefShape.qualifiedSubTypeByModulePath`) that reads by module path
	 * before the move (`headReading`) and does not name the same type after it, per file of `files` (old and new path): in a
	 * relocated module every such spelling, in another module those whose first name is a relocated module's (`relocated`) —
	 * no other spelling's reading can change. A spelling whose head comes to bind a type declaring the sub-type's name reads
	 * as a member access after the move, a drift too; and one the index places on either side whose reading it cannot decide
	 * before the move is one as well: nothing shows it still resolves.
	 */
	public static function qualifiedDrifts(
		pre: SymbolIndex, post: SymbolIndex, files: Array<{ before: String, after: String }>, renamed: Map<String, String>,
		relocated: Array<String>, plugin: GrammarPlugin, textBefore: Map<String, String>, textAfter: Map<String, String>
	): Array<QualifiedDrift> {
		final out: Array<QualifiedDrift> = [];
		if (plugin.refShape().qualifiedSubTypeByModulePath != true) return out;
		final sides: QualifiedSides = { pre: pre, post: post, renamed: renamed };
		final preFiles: Map<String, FileInfo> = [for (fi in pre.allFiles()) fi.file => fi];
		final postFiles: Map<String, FileInfo> = [for (fi in post.allFiles()) fi.file => fi];
		for (f in files) {
			final moved: Bool = f.before != f.after;
			final kept: (SubTypeSpelling) -> Bool = s -> moved || relocated.contains(s.head);
			final was: Array<SubTypeSpelling> = spellingsIn(textBefore[f.before], plugin).filter(kept);
			final now: Array<SubTypeSpelling> = spellingsIn(textAfter[f.after], plugin).filter(kept);
			final before: Null<FileInfo> = preFiles[f.before];
			final after: Null<FileInfo> = postFiles[f.after];
			if (was.length == 0 && now.length == 0) continue;
			if (before == null || after == null || was.length != now.length) {
				out.push({
					file: f.after,
					spelling: '',
					at: 0,
					head: '',
					before: 'its qualified names',
					after: 'a text this check cannot line up',
					qualified: null
				});
				continue;
			}
			for (i => s in was) {
				final drift: Null<QualifiedDrift> = spellingDrift(f.after, s, now[i].at, before, after, sides);
				if (drift != null) out.push(drift);
			}
		}
		return out;
	}

	/**
	 * Per type name an analysed module of the project declares (a library's excluded), one module declaring it. A name the
	 * index cannot read on either side keeps its meaning only when no such type could be the one it binds: the library types
	 * it may bind do not move, and a project type it may bind could be one the move takes out of reach.
	 */
	private static function projectTypeModules(index: SymbolIndex): Map<String, String> {
		final out: Map<String, String> = [];
		for (fi in index.allFiles()) if (!index.isThirdParty(fi.file)) for (t in fi.types) out[t.name] = fi.module;
		return out;
	}

	/**
	 * The drift of the spelling `s` of `file` (its first name at `at` after the move; `before` / `after` the file's index
	 * records), or null when it keeps its reading: a member access before the move is the bare name's to compare (`drifts`),
	 * and a spelling the index places nowhere on either side is no sub-type it knows; a module-path reading must name the same
	 * type after the move (`TypeRefIndex.resolveTypeRefAll`), by module path still. Its full path is the module of the one
	 * type it named before (under its new path), when the index after the move finds the sub-type there.
	 */
	private static function spellingDrift(
		file: String, s: SubTypeSpelling, at: Int, before: FileInfo, after: FileInfo, sides: QualifiedSides
	): Null<QualifiedDrift> {
		final written: String = '${s.head}.${s.sub}';
		final was: Array<ResolvedType> = sides.pre.refs.resolveTypeRefAll(written, before, s.at);
		final now: Array<ResolvedType> = sides.post.refs.resolveTypeRefAll(written, after, at);
		if (was.length == 0 && now.length == 0) return null;
		final mapped: (String) -> String = module -> sides.renamed[module] ?? module;
		final wasKey: String = declsKey(was, mapped);
		final target: Null<String> = was.length == 1 ? mapped(was[0].file.module) : null;
		final full: Null<String> = target != null && sides.post.refs.resolveQualifiedRefAll('$target.${s.sub}').length > 0 ? target : null;
		final drift: (String, String, Null<String>) -> QualifiedDrift = (then, there, qualified) -> {
			file: file,
			spelling: written,
			at: at,
			head: s.head,
			before: then,
			after: there,
			qualified: qualified
		};
		final nowhere: String = 'nothing the analysed set holds';
		return switch [
			headReading(sides.pre, before, s.head, s.sub, s.at),
			headReading(sides.post, after, s.head, s.sub, at)
		] {
			case [AsMember, _]:
				null;
			case [Unreadable, _]:
				drift('a member of what "${s.head}" binds or a module path, which the index cannot tell', nowhere, null);
			case [ByModulePath, ByModulePath] if (wasKey == declsKey(now, module -> module)):
				null;
			case [ByModulePath, ByModulePath]:
				drift(was.length == 0 ? nowhere : wasKey, now.length == 0 ? nowhere : declsKey(now, module -> module), full);
			case [ByModulePath, _]:
				drift(wasKey, 'a member of what "${s.head}" binds there, or a reading the index cannot tell', full);
		};
	}

	/**
	 * How `head.sub` written at `at` in `info` reads, decided by what the bare `head` binds there — the reading every bare name
	 * of the move is compared by (`TypeNameBinding.tierOf`) — and by whether that type declares or inherits a member named
	 * `sub` (`MemberLookup`): a member access when it does (4.3.7: an imported `Mod`'s static field `Sub` wins over a module
	 * `Mod` holding a type `Sub`; `Expr.Field` names an enum constructor), by module path when it provably does not or the head
	 * binds no type, `Unreadable` when neither can be shown.
	 */
	private static function headReading(index: SymbolIndex, info: FileInfo, head: String, sub: String, at: Int): HeadReading {
		final targets: Null<Array<NameTarget>> = switch index.refs.names.tierOf(head, info, at) {
			case Free: [];
			case Bound(decls): [InIndex(decls)];
			case Unknown: index.refs.names.unknownCandidates(head, info, at);
		};
		if (targets == null) return Unreadable;
		var member: Bool = false;
		for (target in targets) switch target {
			case OutOfIndex(_):
				return Unreadable;
			case InIndex(decls):
				for (d in decls) if (index.typing.members.declaringMember(d, sub) != null)
					member = true;
				else if (!index.typing.members.declarationLacksMember(d, sub))
					return Unreadable;
		}
		return member ? AsMember : ByModulePath;
	}

	/** The offsets of the heads of `text`'s qualified spellings that read by module path before the move (`headReading`). */
	private static function modulePathSites(index: SymbolIndex, info: FileInfo, text: Null<String>, plugin: GrammarPlugin): Array<Int> {
		return plugin.refShape().qualifiedSubTypeByModulePath != true ? [] : [
			for (s in spellingsIn(text, plugin)) if (headReading(index, info, s.head, s.sub, s.at) == ByModulePath) s.at
		];
	}

	/**
	 * The name `o` qualifies when `o` starts a qualified spelling `o.name.Sub` of `text` — `Sub` an identifier right after the
	 * dot, upper-initial under a grammar whose type names are (`upper`) — else ''.
	 */
	private static function subTypeAfter(text: String, o: { name: String, at: Int }, upper: Bool): String {
		final dot: Int = o.at + o.name.length;
		if (dot >= text.length || text.fastCodeAt(dot) != '.'.code) return '';
		var end: Int = dot + 1;
		while (end < text.length && SourceText.isIdentChar(text.fastCodeAt(end))) end++;
		final sub: String = text.substring(dot + 1, end);
		final initial: Int = sub.length == 0 ? 0 : sub.fastCodeAt(0);
		return SourceText.isIdentifier(sub) && (!upper || (initial >= 'A'.code && initial <= 'Z'.code)) ? sub : '';
	}

	/** Every qualified spelling `Head.Sub` written in code in `text` — interpolation holes included — read by its shape alone. */
	private static function spellingsIn(text: Null<String>, plugin: GrammarPlugin): Array<SubTypeSpelling> {
		if (text == null) return [];
		final source: String = text;
		final upper: Bool = plugin.refShape().typeNamesUpperInitial == true;
		final out: Array<SubTypeSpelling> = [];
		for (o in ModulePathTokens.bareNames(source, ModulePathTokens.inertSpans(source, plugin), upper)) {
			final sub: String = subTypeAfter(source, o, upper);
			if (sub != '') out.push({ head: o.name, sub: sub, at: o.at });
		}
		return out;
	}

	/**
	 * What `name` means in `info`: `Bound` declarations by `module#Type` (module through `mapped`); a name `#if`-guarded
	 * statements decide by the declarations it may bind on each build, in the order the binding lists them; else `free`, or
	 * `UNKNOWN` where a statement the index cannot read may bind it.
	 */
	private static function meaning(index: SymbolIndex, info: FileInfo, name: String, at: Int, mapped: (String) -> String): Meaning {
		return switch index.refs.names.tierOf(name, info, at) {
			case Bound(decls):
				{ key: declsKey(decls, mapped), single: decls.length == 1 ? decls[0] : null };
			case Unknown:
				final candidates: Null<Array<NameTarget>> = index.refs.names.unknownCandidates(name, info, at);
				{
					key: candidates == null ? UNKNOWN : 'either ${[for (c in candidates) targetKey(c, mapped)].join(' | ')}',
					single: null
				};
			case Free:
				{ key: 'free', single: null };
		};
	}

	/** One declaration set as a comparable key: each `module#Type` (module through `mapped`), sorted. */
	private static function declsKey(decls: Array<ResolvedType>, mapped: (String) -> String): String {
		final keys: Array<String> = [for (d in decls) '${mapped(d.file.module)}#${d.type.name}'];
		keys.sort(Reflect.compare);
		return keys.join(',');
	}

	/** One type a guarded name may bind as a comparable key. */
	private static function targetKey(target: NameTarget, mapped: (String) -> String): String {
		return switch target {
			case InIndex(decls): declsKey(decls, mapped);
			case OutOfIndex(path): path;
		};
	}

	/** The import path naming `decl` after the relocation, or null when it cannot be imported (none, or module-private). */
	private static function repairOf(decl: Null<ResolvedType>, mapped: (String) -> String): Null<String> {
		if (decl == null || decl.type.isPrivate) return null;
		final module: String = mapped(decl.file.module);
		return decl.type.isMain ? module : '$module.${decl.type.name}';
	}

	/** The occurrences of `names` written bare in code — interpolation holes included — in `text` (none for a missing text). */
	private static function occurrencesIn(
		text: Null<String>, names: Array<String>, plugin: GrammarPlugin
	): Array<{ name: String, at: Int }> {
		if (text == null) return [];
		final upper: Bool = plugin.refShape().typeNamesUpperInitial == true;
		return ModulePathTokens.bareNames(text, ModulePathTokens.inertSpans(text, plugin), upper).filter(o -> names.contains(o.name));
	}

	/**
	 * Where a name of `names` is written in `text` as a value the file itself declares or binds — a local, a parameter, a
	 * member, an `enum abstract` value, and each such declaration's own name: a value binding shadows a type of that name, so
	 * no relocation changes what the name means there.
	 */
	private static function valueBoundSites(text: Null<String>, names: Array<String>, plugin: GrammarPlugin): Array<Int> {
		if (text == null) return [];
		final source: String = text;
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		return tree == null ? [] : [
			for (name => hits in Refs.findMulti(
				names, tree, plugin.refShape()
			)) for (h in hits) if (h.kind == RefKind.Decl || h.bindingSpan != null) SourceText.identTokenOffset(source, h.span, name)
		];
	}

}
