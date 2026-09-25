package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

/**
 * What every part of a `MemberReach` analysis reads the project through: the plugin and its shape seams, the
 * index types resolve against, and the project files — a toucher of a project member lives in one of them —
 * with their text by path.
 */
@:nullSafety(Strict)
final class ReachProject {

	/** Project file -> its text. */
	public final sources: Map<String, String> = [];

	/**
	 * The compiler facts of the run's builds, as the analysis reads them (`FactsView`): set once by the analysis that owns
	 * this scope, null for syntax alone.
	 */
	public var facts: Null<FactsView> = null;

	public final plugin: GrammarPlugin;
	public final shape: RefShape;
	public final index: SymbolIndex;
	public final files: Array<{ file: String, source: String }>;

	public function new(plugin: GrammarPlugin, index: SymbolIndex, files: Array<{ file: String, source: String }>) {
		this.plugin = plugin;
		shape = plugin.refShape();
		this.index = index;
		this.files = files;
		for (f in files) sources[f.file] = f.source;
	}

	/**
	 * The declaration site of `type`: the index's, or — when the index answers none because a TYPEDEF of the same
	 * simple name aliases it (the std `typedef IMap<K, V> = haxe.Constraints.IMap<K, V>;`) — the one declaration
	 * that is not such an alias. Null when the name is genuinely declared more than once, or not at all.
	 */
	public function siteOf(type: String): Null<{ file: String, span: Span }> {
		final direct: Null<{ file: String, span: Span }> = index.declarationSiteOf(type);
		if (direct != null) return direct;
		final found: Array<{ file: String, span: Span }> = [];
		for (fi in index.allFiles())
			for (t in fi.types)
				if (t.name == type && !CallGraphNames.selfAlias(t)) found.push({ file: fi.file, span: t.span });
		return found.length == 1 ? found[0] : null;
	}

}
