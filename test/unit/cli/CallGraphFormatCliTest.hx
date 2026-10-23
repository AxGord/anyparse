package unit.cli;

import anyparse.query.Cli;
import anyparse.query.format.json.CodeGraphJson;
import anyparse.query.format.json.CodeGraphJsonParser;
import unit.query.graph.GraphFixture;
#if (sys || nodejs)
import anyparse.grammar.mermaid.MermaidParser;
#end

/**
 * `--format mermaid|json` on `callees`, `callers`, `reach` and `clusters`, end to end over the graph
 * fixture written to disk: the Mermaid a walk prints is pinned byte for byte, every document parses with
 * its grammar's parser, and an unknown format is a usage error.
 */
class CallGraphFormatCliTest extends Test {

	/** `callees --format mermaid` prints the fixture's golden flowchart and exits 0. */
	public function testCalleesMermaid(): Void {
		#if nodejs
		withFixture(root -> {
			var code: Int = -1;
			final out: String = CliFixture.captureStdout(() ->
				code = Cli.run(['callees', 'Alpha.run', root, '--depth', '3', '--format', 'mermaid'])
			);
			Assert.equals(0, code);
			Assert.equals(GraphFixture.CALLEES_MERMAID, out);
		});
		#else
		Assert.pass('stdout capture is node-only');
		#end
	}

	/** `reach --format json` reads back through its schema, both ends of the path focused. */
	public function testReachJson(): Void {
		#if nodejs
		withFixture(root -> {
			final out: String = CliFixture.captureStdout(() ->
				Cli.run(['reach', '--from', 'Alpha.run', '--to', 'Gamma.tick', root, '--format', 'json'])
			);
			final doc: CodeGraphJson = CodeGraphJsonParser.parse(out);
			Assert.equals('pkg.a.Alpha.run,pkg.b.Gamma.tick', [for (n in doc.nodes) if (n.focus) n.name].join(','));
			Assert.equals(2, doc.edges.length);
		});
		#else
		Assert.pass('stdout capture is node-only');
		#end
	}

	/** `callers` and `clusters` print Mermaid the Mermaid parser reads. */
	public function testCallersAndClustersMermaidParse(): Void {
		#if nodejs
		withFixture(root -> for (args in [['callers', 'Gamma.tick', root, '--depth', '2'], ['clusters', 'Alpha', root]]) {
			final out: String = CliFixture.captureStdout(() -> Cli.run(args.concat(['--format', 'mermaid'])));
			Assert.isTrue(out.indexOf('flowchart LR\n') >= 0, args[0]);
			MermaidParser.parse(out);
		});
		#else
		Assert.pass('stdout capture is node-only');
		#end
	}

	/** A member nobody calls draws a graph with no edge, which `--exit-on-empty` reports as empty. */
	public function testAnEdgelessGraphIsEmpty(): Void {
		#if (sys || nodejs)
		withFixture(root -> {
			var code: Int = -1;
			CliFixture.captureStdout(() -> code = Cli.run(['callers', 'Gamma.back', root, '--format', 'json', '--exit-on-empty']));
			Assert.equals(1, code);
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** An unknown format is a usage error naming the formats there are. */
	public function testAnUnknownFormatIsAUsageError(): Void {
		#if (sys || nodejs)
		withFixture(root -> {
			var code: Int = -1;
			final err: String = CliFixture.captureStderr(() -> code = Cli.run(['callees', 'Alpha.run', root, '--format', 'dot']));
			Assert.equals(2, code);
			#if nodejs
			Assert.equals('apq callees: unknown --format "dot" (text, mermaid, json)\n', err);
			#end
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** Run `body` over the graph fixture written to a fresh directory, removed afterwards. */
	private static function withFixture(body: (root:String) -> Void): Void {
		final root: String = CliFixture.writeTree('graphformat', [for (f in GraphFixture.FILES) { name: f.file, source: f.source }]);
		CliFixture.always(CliFixture.removeDir.bind(root), body.bind(root));
	}
	#end

}
