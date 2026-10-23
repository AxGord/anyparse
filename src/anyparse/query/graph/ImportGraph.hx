package anyparse.query.graph;

import anyparse.query.ConfigFinder;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeRefIndex;
import anyparse.query.graph.CodeGraph.GraphLevel;
import haxe.io.Path;

/**
 * The import graph of a scope at the package or the type level: one edge per pair of packages (types)
 * an import joins, weighted by the import statements behind it. The statements are read through the
 * index's resolution layer (`TypeRefIndex`), so the graph holds for every grammar whose index records imports.
 *
 * An import names a type — or a static field of one — and draws an edge only when the scope declares
 * that type, so an import of anything outside the scope draws none; a package wildcard names its package
 * when the scope holds it, and draws no edge at the type level, where it names no type. An alias import
 * counts for the type it aliases. An import inside one package (type) joins nothing and is left out. An
 * ambient source — a file whose imports reach other files unwritten, which declares no package of its own —
 * counts once for each package of the files it reaches (`ownersOf`); the type level leaves it out, as it
 * declares no type.
 */
@:nullSafety(Strict)
final class ImportGraph {

	/** The label of the package whose files declare none. */
	private static inline final ROOT_PACKAGE_LABEL: String = '(root)';

	public static function build(index: SymbolIndex, level: GraphLevel): CodeGraph {
		if (level != Package && level != Type) throw new Exception('graph: an import joins packages or types, not ${level}s');
		final files: Array<FileInfo> = index.allFiles();
		final packages: Array<String> = [];
		// an ambient source -> the packages of the files it reaches
		final reached: Map<String, Array<String>> = [];
		for (f in files) {
			if (!packages.contains(f.pkg)) packages.push(f.pkg);
			for (group in f.ambientImports) {
				final owners: Array<String> = reached[group.file] ?? [];
				if (!owners.contains(f.pkg)) owners.push(f.pkg);
				reached[group.file] = owners;
			}
		}
		final graph: CodeGraph = new CodeGraph();
		for (f in files) if (level == Package || f.types.length > 0) {
			final targets: Array<{ pkg: String, type: String }> = [];
			for (path in TypeRefIndex.plainImports(f).concat(TypeRefIndex.usings(f)).concat(TypeRefIndex.aliasTargets(f))) {
				final target: Null<ResolvedType> = typeOf(index, path);
				if (target != null) targets.push({ pkg: target.file.pkg, type: target.type.name });
			}
			if (level == Package)
				for (pkg in TypeRefIndex.wildcardPackages(f))
					if (packages.contains(pkg)) targets.push({ pkg: pkg, type: '' });
			for (owner in ownersOf(reached, f, files)) {
				final from: String = nodeOf(graph, level, owner, SourceText.lastSegment(f.module));
				for (t in targets) {
					final to: String = nodeOf(graph, level, t.pkg, t.type);
					if (from != to) graph.addEdge(from, to, Import);
				}
			}
		}
		return graph;
	}

	/** The type an import `path` names in scope — the path itself, or the type a static-field import reaches into — or null. */
	private static function typeOf(index: SymbolIndex, path: String): Null<ResolvedType> {
		var prefix: String = path;
		while (prefix != '') {
			final found: Array<ResolvedType> = index.refs.resolveQualifiedRefAll(prefix);
			if (found.length > 0) return found[0];
			final dot: Int = prefix.lastIndexOf('.');
			prefix = dot < 0 ? '' : prefix.substr(0, dot);
		}
		return null;
	}

	/**
	 * The packages the imports of `f` count for. A file declaring neither a package nor a type may be an ambient source: it
	 * counts for the packages of the files it reaches — the plugin names a source by its absolute path
	 * (`ConfigFinder.absolute`) — else, reaching none, for the packages of the files beside it, and for nothing when none
	 * is. Any other file counts for its own package.
	 */
	private static function ownersOf(reached: Map<String, Array<String>>, f: FileInfo, files: Array<FileInfo>): Array<String> {
		if (f.pkg != '' || f.types.length > 0) return [f.pkg];
		final owners: Null<Array<String>> = reached[ConfigFinder.absolute(f.file)] ?? reached[f.file];
		if (owners != null) return owners;
		final dir: String = Path.directory(f.file);
		final siblings: Array<String> = [];
		for (other in files) if (other != f && Path.directory(other.file) == dir && !siblings.contains(other.pkg)) siblings.push(other.pkg);
		return siblings;
	}

	private static function nodeOf(graph: CodeGraph, level: GraphLevel, pkg: String, type: String): String {
		final packageLabel: String = pkg == '' ? ROOT_PACKAGE_LABEL : pkg;
		return level == Package
			? graph.addNode(Package, pkg, packageLabel, null, false)
			: graph.addNode(Type, pkg == '' ? type : '$pkg.$type', type, null, false);
	}

}
