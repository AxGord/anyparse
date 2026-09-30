package anyparse.query;

import anyparse.query.CompilerFacts.FactPos;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

/**
 * What every part of a `MemberReach` analysis reads the project through: the plugin and its shape seams, the
 * index types resolve against, and the project files — a toucher of a project member lives in one of them —
 * with their text by path.
 */
@:nullSafety(Strict)
final class ReachProject {

	/**
	 * The compiler facts of the run's builds, as the analysis reads them (`FactsView`): set once by the analysis that owns
	 * this scope (`readThrough`), null for syntax alone.
	 */
	public var facts(default, null): Null<FactsView> = null;

	/** What types resolve against: the index the scope was made with, less the files no build runs (`readThrough`). */
	public var index(default, null): SymbolIndex;

	/** Project file -> its text. */
	public final sources: Map<String, String> = [];

	public final plugin: GrammarPlugin;
	public final shape: RefShape;
	public final files: Array<{ file: String, source: String }>;

	/** What the facts say the builds made of the index and the text (`FactsProvenance`), made on first need. */
	private var _provenance: Null<FactsProvenance> = null;

	/** The files the builds typed a type in (`typeHomes`), read on first need. */
	private var _typeHomes: Null<Map<String, Bool>> = null;

	public function new(plugin: GrammarPlugin, index: SymbolIndex, files: Array<{ file: String, source: String }>) {
		this.plugin = plugin;
		shape = plugin.refShape();
		this.index = index;
		this.files = files;
		for (f in files) sources[f.file] = f.source;
	}

	/**
	 * Read the project through the compiler facts `view` from here on. Under the truth (`FactsView.truth`) a project file no
	 * build runs (`runsInNoBuild`) declares nothing either: the index loses it, so a type of it is no second declaration of
	 * a name a build compiles, and no member, supertype or site it declares answers for one.
	 */
	public function readThrough(view: Null<FactsView>): Void {
		facts = view;
		final idle: Array<String> = [for (f in files) if (runsInNoBuild(f.file)) f.file];
		if (idle.length > 0) index = index.without(idle);
	}

	/**
	 * Whether the file `file`, which did not parse, may hold code or a declaration a build compiles: always without
	 * compiler facts; with them, only when some configuration typed code of it or a type it declares. A file no build
	 * reads (a source of another language on a classpath, a template) can declare no subtype and run no code.
	 */
	public function mayCompile(file: String): Bool {
		final view: Null<FactsView> = facts;
		return view == null || view.table.compiled(file) || typeHomes(view).exists(view.table.keyOf(file));
	}

	/**
	 * Whether no build runs code of the project file `file`: the compiler facts are the truth (`FactsView.truth`) and no
	 * listed build read the file as it is now (`CompilerFacts.mayCompileNow`). False otherwise: a build the list does not
	 * name may compile it, and without the facts nothing says which files a build reads.
	 */
	public function runsInNoBuild(file: String): Bool {
		final view: Null<FactsView> = facts;
		return view != null && view.truth && !view.table.mayCompileNow(file);
	}

	/** What the compiler facts say the builds made of the index and the text; null without facts. */
	public function provenance(): Null<FactsProvenance> {
		final view: Null<FactsView> = facts;
		if (view == null) return null;
		final made: FactsProvenance = _provenance ?? new FactsProvenance(view, this);
		_provenance = made;
		return made;
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

	/**
	 * The table keys of the files the builds typed a type in, read once: a file of declarations alone (an interface, a
	 * typedef) carries no code facts, yet a build compiles it.
	 */
	private function typeHomes(view: FactsView): Map<String, Bool> {
		final held: Null<Map<String, Bool>> = _typeHomes;
		if (held != null) return held;
		final out: Map<String, Bool> = [];
		for (id in view.table.typeIds()) {
			final at: Null<FactPos> = view.table.typePosition(id);
			if (at != null) out[at.file] = true;
		}
		_typeHomes = out;
		return out;
	}

}
