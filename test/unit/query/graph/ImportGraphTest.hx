package unit.query.graph;

import anyparse.query.CallGraph;
import anyparse.query.SymbolIndex;
import anyparse.query.format.GraphMermaid;
import anyparse.query.graph.CodeGraph;
import anyparse.query.graph.ImportGraph;
#if (sys || nodejs)
import sys.io.File;
import unit.cli.CliFixture;
#end

/**
 * `ImportGraph` — what a scope's imports join, at the package and the type level: a static-field import
 * counts for its type, a wildcard for its package, an import of anything outside the scope or inside one
 * package (type) for nothing, and an ambient import file for each package it reaches.
 */
@:nullSafety(Strict)
class ImportGraphTest extends Test {

	/** `GraphFixture` plus a package importing by wildcard, by static field and from outside the scope. */
	private static final FILES: Array<{ file: String, source: String }> = GraphFixture.FILES.concat([
		{
			file: 'pkg/c/Delta.hx',
			source: 'package pkg.c;\n\nimport haxe.ds.StringMap;\nimport pkg.a.*;\nimport pkg.b.Beta.make;\n\nclass Delta {}\n'
		}
	]);

	/** The package map as Mermaid. */
	private static final PACKAGE_MERMAID: String = [
		'%% package map',
		'flowchart LR',
		'p_pkg_da[pkg.a]',
		'p_pkg_db[pkg.b]',
		'p_pkg_dc[pkg.c]',
		'p_pkg_da --> p_pkg_db',
		'p_pkg_db --> p_pkg_da',
		'p_pkg_dc -->|2| p_pkg_da',
		'p_pkg_dc --> p_pkg_db',
		''
	].join('\n');

	/** One edge per pair of packages; a wildcard names its package, a static-field import its type's. */
	public function testPackageLevel(): Void {
		final graph: CodeGraph = ImportGraph.build(indexOf(FILES), Package);
		Assert.equals('pkg.a -> pkg.b x1|pkg.b -> pkg.a x1|pkg.c -> pkg.a x1|pkg.c -> pkg.b x1', edges(graph).join('|'));
	}

	/** The type level joins the modules' types; a `using` inside one package joins two types, a wildcard none. */
	public function testTypeLevel(): Void {
		final graph: CodeGraph = ImportGraph.build(indexOf(FILES), Type);
		Assert.equals(
			'pkg.a.Alpha -> pkg.b.Beta x1|pkg.b.Beta -> pkg.b.Gamma x1|pkg.b.Gamma -> pkg.a.Alpha x1|pkg.c.Delta -> pkg.b.Beta x1',
			edges(graph).join('|')
		);
	}

	/** Two imports between one pair of packages are one edge of weight 2, written as the edge's label. */
	public function testPackageMapAsMermaid(): Void {
		final weighted: Array<{ file: String, source: String }> = FILES.concat([
			{ file: 'pkg/c/Epsilon.hx', source: 'package pkg.c;\n\nimport pkg.a.Alpha;\n\nclass Epsilon {}\n' }
		]);
		Assert.equals(PACKAGE_MERMAID, GraphMermaid.write(ImportGraph.build(indexOf(weighted), Package), 'package map'));
	}

	/** An import file declares no package: its imports count for each package of the files it reaches. */
	public function testAnAmbientImportFileCountsForThePackagesItReaches(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('importgraph', [
			{ name: 'pkg/a/import.hx', source: 'import pkg.b.Beta;\n' },
			{ name: 'pkg/a/Alpha.hx', source: 'package pkg.a;\n\nclass Alpha {}\n' },
			{ name: 'pkg/b/Beta.hx', source: 'package pkg.b;\n\nclass Beta {}\n' }
		]);
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final files: Array<{ file: String, source: String }> = [
				for (name in ['pkg/a/import.hx', 'pkg/a/Alpha.hx', 'pkg/b/Beta.hx'])
					{
						file: '$root/$name',
						source: File.getContent('$root/$name')
					}
			];
			Assert.equals('pkg.a -> pkg.b x1', edges(ImportGraph.build(indexOf(files), Package)).join('|'));
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** An import file no indexed file sits beside reaches no package, so it draws no edge — never one from the root package. */
	public function testAnUnreachedImportFileDrawsNothing(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('importgraph', [
			{ name: 'z/import.hx', source: 'import y.T;\n' },
			{ name: 'y/T.hx', source: 'package y;\n\nclass T {}\n' }
		]);
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final files: Array<{ file: String, source: String }> = [
				for (name in ['z/import.hx', 'y/T.hx']) { file: '$root/$name', source: File.getContent('$root/$name') }
			];
			final graph: CodeGraph = ImportGraph.build(indexOf(files), Package);
			Assert.equals('', edges(graph).join('|'));
			Assert.equals('y', [for (n in graph.nodes()) n.name].join(','));
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** An alias import counts for the type it aliases. */
	public function testAnAliasImportCountsForItsType(): Void {
		final files: Array<{ file: String, source: String }> = FILES.concat([
			{ file: 'pkg/d/Eta.hx', source: 'package pkg.d;\n\nimport pkg.a.Alpha as A;\n\nclass Eta {}\n' }
		]);
		Assert.isTrue(edges(ImportGraph.build(indexOf(files), Package)).contains('pkg.d -> pkg.a x1'));
	}

	/** An import joins packages or types; a member level is a caller's mistake. */
	public function testMemberLevelIsRefused(): Void {
		Assert.raises(() -> ImportGraph.build(indexOf(FILES), Member));
	}

	private static function indexOf(files: Array<{ file: String, source: String }>): SymbolIndex {
		final index: Null<SymbolIndex> = CallGraph.build(files, new HaxeQueryPlugin()).index;
		if (index == null) throw new Exception('the Haxe call graph carries its index');
		return index;
	}

	/** Every edge as `from -> to xweight`, by the nodes' names. */
	private static function edges(graph: CodeGraph): Array<String> {
		return [
			for (e in graph.edges()) '${graph.node(e.from)?.name} -> ${graph.node(e.to)?.name} x${e.weight}'
		];
	}

}
