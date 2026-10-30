package unit.cli;

import anyparse.query.Cli;
import anyparse.query.ExitCode;
import anyparse.query.format.json.CodeGraphJson;
import anyparse.query.format.json.CodeGraphJsonParser;
import anyparse.query.format.json.GraphPageJson;
import anyparse.query.format.json.GraphPageJsonParser;
import anyparse.query.format.json.GraphPageViewJson;
import unit.cli.CliFixture.CliRun;
import unit.query.graph.GraphFixture;
#if nodejs
import anyparse.grammar.mermaid.MermaidParser;
import sys.io.File;
#end

/**
 * `apq graph --diff` end to end over a scratch git repository of two commits: the scope read at each revision without a
 * checkout — named as a directory, the top and a glob alike — compared as text, as Mermaid the Mermaid parser reads and
 * as JSON; an unknown revision and the options a comparison does not take refused.
 */
@:nullSafety(Strict)
class GraphDiffCliTest extends Test {

	/** The comparison `withMovedModule` runs: the moved module's edited member changed, its new call drawn. */
	private static final MOVED_REPORT: String = [
		'4 node(s), 1 edge(s), 0 mutual pair(s)',
		'changed:',
		'  ~ member p.A.idle',
		'edges:',
		'  + p.A.idle -> p.B  call 1',
		''
	].join('\n');

	public function testTwoRevisionsCompareInEveryOutput(): Void {
		#if nodejs
		final root: String = CliFixture.writeTree('apq_graphdiff', [{ name: 'p/A.hx', source: GraphFixture.DIFF_BEFORE }]);
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			CliFixture.git(root, ['init', '-q']);
			CliFixture.git(root, ['add', '-A']);
			CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base']);
			File.saveContent('$root/p/A.hx', GraphFixture.DIFF_AFTER);
			CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qam', 'tip']);
			// the working tree changes again: the comparison reads the revisions, never the files on disk
			File.saveContent('$root/p/A.hx', 'package p;\n');
			final text: CliRun = CliFixture.runIn(root, ['graph', 'p', '--diff', 'HEAD~1', 'HEAD']);
			Assert.equals(ExitCode.EXIT_OK, text.code);
			Assert.equals(GraphFixture.DIFF_REPORT, text.out);
			final mermaid: String = CliFixture.inDir(root, ['graph', 'p/*.hx', '--diff', 'HEAD~1', 'HEAD', '--format', 'mermaid']);
			MermaidParser.parse(mermaid);
			Assert.equals([
				'%% graph --diff HEAD~1 HEAD --level member --edges calls',
				'flowchart LR',
				'subgraph p_p[p]',
				'    subgraph t_p_dA[A]',
				'        m_p_dA_dfresh(fresh)',
				'        m_p_dA_dgone(gone)',
				'        m_p_dA_drun(run)',
				'    end',
				'    t_p_dB[[B]]',
				'    subgraph t_p_dC[+ C]',
				'        m_p_dC_dgo(go)',
				'    end',
				'end',
				'm_p_dA_dgone --> t_p_dA',
				'm_p_dA_drun --> m_p_dA_dfresh',
				'm_p_dA_drun --> m_p_dA_drun',
				'm_p_dA_drun -->|2 was 3| t_p_dA',
				'm_p_dC_dgo --> m_p_dA_drun',
				'm_p_dC_dgo ==>|new| t_p_dA',
				't_p_dB --> m_p_dA_drun',
				'classDef added fill:#dfd,stroke:#2a2',
				'class m_p_dA_dfresh,m_p_dC_dgo added',
				'classDef removed fill:#eee,stroke:#999,stroke-dasharray:4 3',
				'class m_p_dA_dgone removed',
				'classDef changed fill:#ffd,stroke:#d90',
				'class m_p_dA_drun changed',
				'linkStyle 1,4,5 stroke:#2a2,stroke-width:2px',
				'linkStyle 0 stroke:#999,stroke-dasharray:4 3',
				'linkStyle 3 stroke:#d90,stroke-width:2px',
				''
			].join('\n'), mermaid);
			final doc: CodeGraphJson = CodeGraphJsonParser.parse(
				CliFixture.inDir(root, ['graph', '.', '--diff', 'HEAD~1', 'HEAD', '--format', 'json'])
			);
			Assert.equals('changed', [for (n in doc.nodes) if (n.name == 'p.A.run') n.change].join(','));
			Assert.equals('removed', [for (n in doc.nodes) if (n.name == 'p.A.gone') n.change].join(','));
			Assert.equals('3', [for (e in doc.edges) if (e.change == 'changed') '${e.before}'].join(','));
			final same: CliRun = CliFixture.runIn(root, ['graph', 'p', '--diff', 'HEAD', 'HEAD', '--exit-on-empty']);
			Assert.equals('0 node(s), 0 edge(s), 0 mutual pair(s)\n', same.out);
			Assert.notEquals(ExitCode.EXIT_OK, same.code, 'two equal revisions are the empty answer');
		});
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/** A module-level function, which the call graph places in a type named for its module, changes under that name. */
	@:killer('M-GRAPH-DIFF-MODULE-FUNCTION-UNNAMED')
	@:pin('control')
	public function testAModuleLevelFunctionChanges(): Void {
		#if nodejs
		final root: String = CliFixture.writeTree('apq_graphdiff', [
			{ name: 'p/Util.hx', source: 'package p;\n\nfunction top(): Int {\n\treturn 1;\n}\n' }
		]);
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			CliFixture.git(root, ['init', '-q']);
			CliFixture.git(root, ['add', '-A']);
			CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base']);
			File.saveContent('$root/p/Util.hx', 'package p;\n\nfunction top(): Int {\n\treturn 2;\n}\n');
			CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qam', 'tip']);
			Assert.equals(
				'3 node(s), 0 edge(s), 0 mutual pair(s)\nchanged:\n  ~ member p.Util.top\n',
				CliFixture.inDir(root, ['graph', '.', '--diff', 'HEAD~1', 'HEAD'])
			);
			// a comparison with changed members and no edge is no empty answer, as a page as in the report
			final page: CliRun = CliFixture.runIn(root, [
				'graph',
				'.',
				'--diff',
				'HEAD~1',
				'HEAD',
				'--html',
				'top.html',
				'--exit-on-empty'
			]);
			Assert.equals(ExitCode.EXIT_OK, page.code);
		});
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/** A file git finds renamed is paired with its earlier path, so an edit inside it changes its member. */
	@:killer('M-GRAPH-DIFF-RENAME-UNPAIRED')
	@:pin('control')
	public function testARenamedFileKeepsItsEdits(): Void {
		#if nodejs
		withMovedModule(root -> Assert.equals(MOVED_REPORT, CliFixture.inDir(root, ['graph', 'src', '--diff', 'HEAD~1', 'HEAD'])));
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/** An absolute scope names what its path relative to the cwd names at each revision. */
	@:killer('M-GRAPH-DIFF-ABSOLUTE-SPEC-UNREAD')
	@:pin('control')
	public function testAnAbsoluteScopeIsReadRelativeToTheCwd(): Void {
		#if nodejs
		withMovedModule(root -> Assert.equals(MOVED_REPORT, CliFixture.inDir(root, ['graph', '$root/src', '--diff', 'HEAD~1', 'HEAD'])));
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/** A revision git does not know ends the run; the options that prune one graph, another level or the imports are refused. */
	public function testRefusals(): Void {
		#if nodejs
		var code: Int = -1;
		final err: String = CliFixture.captureStderr(() -> CliFixture.captureStdout(() -> code = Cli.run([
			'graph',
			'src/anyparse/query/graph',
			'--diff',
			'no-such-revision-anywhere',
			'HEAD'
		])));
		Assert.equals(ExitCode.EXIT_RUNTIME, code);
		Assert.isTrue(err.indexOf('apq graph: git lists no tree for "no-such-revision-anywhere"') >= 0, err);
		for (extra in [
			['--level', 'type'],
			['--edges', 'imports'],
			['--focus', 'A'],
			['--min-weight', '2'],
			['--mutual'],
			['--package-depth', '1']
		]) {
			final refused: String = CliFixture.captureStderr(
				() -> CliFixture.captureStdout(() -> code = Cli.run(['graph', '.', '--diff', 'A', 'B'].concat(extra)))
			);
			Assert.equals(ExitCode.EXIT_USAGE, code, extra.join(' '));
			Assert.isTrue(refused.indexOf('--diff') >= 0, refused);
		}
		#else
		Assert.pass('stderr capture is node-only');
		#end
	}

	/**
	 * `--diff` with `--html` writes the comparison as a page whose first view draws the packages, changed ones coloured;
	 * `--level` chooses another first view, and the imports, which a comparison does not read, are refused.
	 */
	public function testAComparisonWritesAPage(): Void {
		#if nodejs
		final root: String = CliFixture.writeTree('apq_graphdiff', [{ name: 'p/A.hx', source: GraphFixture.DIFF_BEFORE }]);
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			CliFixture.git(root, ['init', '-q']);
			CliFixture.git(root, ['add', '-A']);
			CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base']);
			File.saveContent('$root/p/A.hx', GraphFixture.DIFF_AFTER);
			CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qam', 'tip']);
			final run: CliRun = CliFixture.runIn(root, ['graph', 'p', '--diff', 'HEAD~1', 'HEAD', '--html', 'diff.html']);
			Assert.equals(ExitCode.EXIT_OK, run.code);
			Assert.equals('apq graph: wrote diff.html, 4 views\n', run.out);
			final first: GraphPageViewJson = pageOf('$root/diff.html').views[0];
			Assert.equals('graph --diff HEAD~1 HEAD --level package', first.title);
			Assert.isTrue(first.mermaid.indexOf('class p_p changed') >= 0, first.mermaid);
			final typed: CliRun = CliFixture.runIn(root, [
				'graph',
				'p',
				'--diff',
				'HEAD~1',
				'HEAD',
				'--html',
				'types.html',
				'--level',
				'type'
			]);
			Assert.equals(ExitCode.EXIT_OK, typed.code);
			Assert.equals('graph --diff HEAD~1 HEAD --level type', pageOf('$root/types.html').views[0].title);
			final imports: CliRun = CliFixture.runIn(root, [
				'graph',
				'p',
				'--diff',
				'HEAD~1',
				'HEAD',
				'--html',
				'x.html',
				'--edges',
				'imports'
			]);
			Assert.equals(ExitCode.EXIT_USAGE, imports.code);
			Assert.isFalse(sys.FileSystem.exists('$root/x.html'));
		});
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/**
	 * Run `body` over a scratch repository of two commits: `A` beside `B`, then `A` moved to another directory, its
	 * package kept, with its member `idle` now calling `B`.
	 */
	private static function withMovedModule(body: (root:String) -> Void): Void {
		#if nodejs
		final root: String = CliFixture.writeTree('apq_graphdiff', [
			{ name: 'src/p/A.hx', source: 'package p;\n\nclass A {\n\tpublic function idle(): Int {\n\t\treturn 0;\n\t}\n}\n' },
			{ name: 'src/p/B.hx', source: 'package p;\n\nclass B {\n\tpublic static function go(): Int {\n\t\treturn 1;\n\t}\n}\n' }
		]);
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			CliFixture.git(root, ['init', '-q']);
			CliFixture.git(root, ['add', '-A']);
			CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base']);
			sys.FileSystem.createDirectory('$root/src/q');
			CliFixture.git(root, ['mv', 'src/p/A.hx', 'src/q/A.hx']);
			File.saveContent(
				'$root/src/q/A.hx', 'package p;\n\nclass A {\n\tpublic function idle(): Int {\n\t\treturn 42 + B.go();\n\t}\n}\n'
			);
			CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qam', 'tip']);
			body(root);
		});
		#end
	}

	/** The data of the page written to `file`. */
	private static function pageOf(file: String): GraphPageJson {
		#if nodejs
		final page: String = File.getContent(file);
		final open: String = 'id="graph-data">';
		final start: Int = page.indexOf(open) + open.length;
		return GraphPageJsonParser.parse(page.substring(start, page.indexOf('</script>', start)));
		#else
		throw new haxe.Exception('a page is read on the nodejs target');
		#end
	}

}
