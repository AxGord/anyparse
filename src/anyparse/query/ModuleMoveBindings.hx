package anyparse.query;

import anyparse.query.SymbolIndex.AmbientImportGroup;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ResolvedType;

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
			for (i => use in was) {
				final then: Meaning = meaning(pre, before, use.name, use.at, mapped);
				final nowMeaning: Meaning = meaning(post, after, use.name, now[i].at, module -> module);
				if (then.key == nowMeaning.key || seen.contains(use.name)) continue;
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

	/** What `name` means in `info`: `Bound` declarations by `module#Type` (module through `mapped`), else `unknown` / `free`. */
	private static function meaning(index: SymbolIndex, info: FileInfo, name: String, at: Int, mapped: (String) -> String): Meaning {
		return switch index.refs.names.tierOf(name, info, at) {
			case Bound(decls):
				final keys: Array<String> = [for (d in decls) '${mapped(d.file.module)}#${d.type.name}'];
				keys.sort((a, b) -> if (a < b)
					-1
				else if (a > b)
					1
				else
					0);
				{ key: keys.join(','), single: decls.length == 1 ? decls[0] : null };
			case Unknown:
				{ key: 'unknown', single: null };
			case Free:
				{ key: 'free', single: null };
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

}
