package unit.cli;

import anyparse.query.Cli;
import anyparse.query.format.json.CodeGraphJson;
import anyparse.query.format.json.CodeGraphJsonParser;
import unit.query.graph.GraphFixture;
#if (sys || nodejs)
import anyparse.grammar.mermaid.MermaidParser;
#end

/**
 * `apq graph` end to end over the graph fixture written to disk: the package map of its imports with the mutual pair
 * listed, the type map as Mermaid the Mermaid parser reads with the pair drawn red, the member graph around a focus as
 * JSON, and the refusals.
 */
class GraphCliTest extends Test {

	/** The fixture's two packages import each other: one pair, one import each way. */
	public function testThePackageMapListsTheMutualPair(): Void {
		#if nodejs
		withFixture(root -> {
			var code: Int = -1;
			final out: String = CliFixture.captureStdout(() -> code = Cli.run(['graph', root]));
			Assert.equals(0, code);
			Assert.equals([
				'2 node(s), 2 edge(s), 1 mutual pair(s)',
				'mutual:',
				'  pkg.a <-> pkg.b  1/1',
				'edges:',
				'  pkg.a -> pkg.b  import 1',
				'  pkg.b -> pkg.a  import 1',
				''
			].join('\n'), out);
		});
		#else
		Assert.pass('stdout capture is node-only');
		#end
	}

	/** The package map as Mermaid parses, and draws the links of the packages importing each other red. */
	public function testThePackageMapAsMermaid(): Void {
		#if nodejs
		withFixture(root -> {
			final out: String = CliFixture.captureStdout(() -> Cli.run(['graph', root, '--format', 'mermaid']));
			MermaidParser.parse(out);
			Assert.equals([
				'%% graph --level package --edges imports',
				'flowchart LR',
				'p_pkg_da[pkg.a]',
				'p_pkg_db[pkg.b]',
				'p_pkg_da --> p_pkg_db',
				'p_pkg_db --> p_pkg_da',
				'linkStyle 0,1 stroke:#d33,stroke-width:2px',
				''
			].join('\n'), out);
		});
		#else
		Assert.pass('stdout capture is node-only');
		#end
	}

	/** The member graph around a focus reads back as JSON with the focus marked and every edge touching what lies within one edge of it. */
	public function testTheMemberGraphAroundAFocus(): Void {
		#if nodejs
		withFixture(root -> {
			final out: String = CliFixture.captureStdout(() -> Cli.run([
				'graph',
				root,
				'--level',
				'member',
				'--focus',
				'Alpha.run',
				'--radius',
				'0',
				'--format',
				'json'
			]));
			final doc: CodeGraphJson = CodeGraphJsonParser.parse(out);
			Assert.equals('pkg.a.Alpha.run', [for (n in doc.nodes) if (n.focus) n.name].join(','));
			Assert.equals('', [for (e in doc.edges) e.from].join(','), 'radius 0 keeps the focus alone, its own recursion aside');
			final wider: CodeGraphJson = CodeGraphJsonParser.parse(
				CliFixture.captureStdout(() -> Cli.run(['graph', root, '--level', 'member', '--focus', 'Alpha.run', '--format', 'json']))
			);
			Assert.isTrue(wider.edges.length > 0);
		});
		#else
		Assert.pass('stdout capture is node-only');
		#end
	}

	/** A focus naming no node is the empty answer `--exit-on-empty` reports. */
	public function testAnUnknownFocusIsEmpty(): Void {
		#if (sys || nodejs)
		withFixture(root -> {
			var code: Int = -1;
			CliFixture.captureStderr(
				() -> CliFixture.captureStdout(() -> code = Cli.run(['graph', root, '--focus', 'Nowhere', '--exit-on-empty']))
			);
			Assert.equals(1, code);
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** An import joins no members, `--kinds` needs the call graph, and a level must be one there is. */
	public function testRefusals(): Void {
		#if (sys || nodejs)
		withFixture(root -> for (args in [
			['--level', 'member', '--edges', 'imports'],
			['--kinds', 'call'],
			['--level', 'module'],
			['--min-weight', '0'],
			['--html', 'x.html', '--focus', 'Alpha'],
			['--html', 'x.html', '--diff', 'HEAD', 'HEAD', '--edges', 'imports'],
			['--html', 'x.html', '--format', 'json']
		]) {
			var code: Int = -1;
			CliFixture.captureStderr(() -> code = Cli.run(['graph', root].concat(args)));
			Assert.equals(2, code, args.join(' '));
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `--html` writes one page holding the vendored Mermaid library and a view per node a reader can open — the imports
	 * open the two packages into their types, the call graph also the three types into their members — and says where.
	 */
	public function testTheHtmlPage(): Void {
		#if nodejs
		withFixture(root -> {
			final file: String = '$root/imports.html';
			var code: Int = -1;
			final out: String = CliFixture.captureStdout(() -> code = Cli.run(['graph', root, '--html', file]));
			Assert.equals(0, code);
			Assert.equals('apq graph: wrote $file, 3 views\n', out);
			Assert.isTrue(sys.io.File.getContent(file).indexOf('__esbuild_esm_mermaid_nm') >= 0, 'the library is inlined');
			final calls: String = '$root/calls.html';
			final said: String = CliFixture.captureStdout(() -> code = Cli.run(['graph', root, '--edges', 'calls', '--html', calls]));
			Assert.equals(0, code);
			Assert.equals('apq graph: wrote $calls, 6 views\n', said);
		});
		#else
		Assert.pass('stdout capture is node-only');
		#end
	}

	/** A focus names nodes of the level asked: at the type level over the lifted call graph, a package name answers no type. */
	public function testAFocusNamingOnlyAPackageAnswersNoType(): Void {
		#if nodejs
		withFixture(root -> {
			var code: Int = -1;
			final err: String = CliFixture.captureStderr(() -> CliFixture.captureStdout(() -> code = Cli.run([
				'graph',
				root,
				'--level',
				'type',
				'--edges',
				'calls',
				'--focus',
				'a',
				'--exit-on-empty'
			])));
			Assert.equals(1, code);
			Assert.isTrue(err.indexOf('apq graph: no type in the graph is named "a"\n') >= 0, err);
		});
		#else
		Assert.pass('stderr capture is node-only');
		#end
	}

	/** A file that fails to parse is named on stderr on the import path too: its imports are missing from the graph. */
	public function testTheImportPathWarnsOfAnUnparsedFile(): Void {
		#if nodejs
		final root: String = CliFixture.writeTree('graphcli', [
			for (f in GraphFixture.FILES)
				{
					name: f.file,
					source: f.source
				}
		].concat([{ name: 'pkg/c/Broken.hx', source: 'package pkg.c;\n\nclass Broken {\n' }]));
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			var code: Int = -1;
			final err: String = CliFixture.captureStderr(() -> CliFixture.captureStdout(() -> code = Cli.run(['graph', root])));
			Assert.equals(0, code);
			Assert.isTrue(err.indexOf('apq graph: WARNING 1 file(s) failed to parse and are invisible to the graph:\n') >= 0, err);
			Assert.isTrue(err.indexOf('Broken.hx') >= 0, err);
		});
		#else
		Assert.pass('stderr capture is node-only');
		#end
	}

	#if (sys || nodejs)
	/** Run `body` over the graph fixture written to a fresh directory, removed afterwards. */
	private static function withFixture(body: (root:String) -> Void): Void {
		final root: String = CliFixture.writeTree('graphcli', [for (f in GraphFixture.FILES) { name: f.file, source: f.source }]);
		CliFixture.always(CliFixture.removeDir.bind(root), body.bind(root));
	}
	#end

}
