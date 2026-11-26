package unit.query;

import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CallChains;
import anyparse.query.CallGraph;
import anyparse.query.CallGraphStore;
import anyparse.query.Cli;
import anyparse.query.QueryNode;
import anyparse.query.cli.CliCallGraph;
#if (sys || nodejs)
import sys.FileSystem;
#end
import unit.cli.CliFixture;

using StringTools;

/**
 * The disk store of a scope's call graph (`CallGraphStore`): what `callers` / `callees` read of a graph taken back from
 * it is what building the graph gives, and a scope whose files are not all as they were stored misses.
 */
class CallGraphStoreTest extends Test {

	private static final FOO: String = 'package a;\n\nclass Foo {\n\n\tpublic static function bar(): Int {\n\t\treturn 1;\n\t}\n\n}\n';
	private static final USER: String = 'package b;\n\nimport lib.Foo;\n\nclass User extends Base {\n\n'
		+ '\toverride public function run(): Int {\n\t\treturn Foo.bar() + a.Foo.bar() + unknown.go() + super.run();\n\t}\n\n}\n';
	private static final BASE: String = 'package b;\n\nclass Base {\n\n\tpublic function run(): Int {\n\t\treturn helper();\n\t}\n\n'
		+ '\tfunction helper(): Int {\n\t\treturn 0;\n\t}\n\n}\n';

	/**
	 * A graph stored and taken back answers every target as the build does: the same functions resolve, the same chains
	 * render both ways — a library path a file imports included — and the same sites stay unresolved.
	 */
	@:pin('control')
	@:killer('M-CALL-GRAPH-STORE-EDGES')
	@:killer('M-CALL-GRAPH-STORE-FOREIGN')
	public function testRestoredGraphAnswersAsTheBuild(): Void {
		#if (sys || nodejs)
		withPrivateTemp(root -> {
			final files: Array<{ file: String, source: String }> = fixture(root);
			final built: CallGraph = CallGraph.build(files, plugin());
			new CallGraphStore('haxe').keep(files, built);
			final stored: Null<StoredCallGraph> = new CallGraphStore('haxe').lookup(files);
			Assert.notNull(stored, 'the graph just kept is read back');
			if (stored == null) return;
			final restored: CallGraph = CallGraph.build(files, plugin(), null, null, stored);
			final sources: Map<String, String> = [ for (f in files) f.file => f.source ];
			for (target in ['Foo.bar', 'lib.Foo.bar', 'a.Foo.bar', 'User.run', 'Base.run', 'helper']) {
				final ids: Array<String> = built.resolveTarget(target).map(n -> n.id);
				Assert.same(ids, restored.resolveTarget(target).map(n -> n.id), 'the functions "$target" names');
				for (id in ids) for (outward in [true, false])
					Assert.equals(
						CallChains.render(built, id, 3, outward, null, f -> sources[f], 0),
						CallChains.render(restored, id, 3, outward, null, f -> sources[f], 0),
						'the ${outward ? 'callees' : 'callers'} of $id'
					);
			}
			Assert.isTrue(built.resolveTarget('Foo.bar').length > 1, 'the imported library path is one of the functions');
			Assert.equals(built.unresolved.length, restored.unresolved.length, 'the unresolved sites');
			Assert.isTrue(built.unresolved.length > 0, 'the fixture leaves a site unresolved');
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A scope where one file's text changed, or a file came or went, misses; the scope as stored hits. */
	@:pin('control')
	@:killer('M-CALL-GRAPH-STORE-CONTENT')
	public function testChangedScopeMisses(): Void {
		#if (sys || nodejs)
		withPrivateTemp(root -> {
			final files: Array<{ file: String, source: String }> = fixture(root);
			final store: CallGraphStore = new CallGraphStore('haxe');
			store.keep(files, CallGraph.build(files, plugin()));
			Assert.notNull(store.lookup(files), 'the scope as stored');
			final edited: Array<{ file: String, source: String }> = files.map(f -> { file: f.file, source: f.source });
			edited[0] = { file: files[0].file, source: '${files[0].source}// edited\n' };
			Assert.isNull(store.lookup(edited), 'a file whose text changed');
			Assert.isNull(store.lookup(files.slice(1)), 'a file gone from the scope');
			Assert.isNull(store.lookup(files.concat([{ file: '$root/Extra.hx', source: FOO }])), 'a file added to the scope');
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `APQ_CALL_GRAPH_STORE=0` stores nothing and reads nothing. */
	@:pin('control')
	@:killer('M-CALL-GRAPH-STORE-SWITCH')
	public function testSwitchedOffStoreHoldsNothing(): Void {
		#if (sys || nodejs)
		withPrivateTemp(root -> {
			final files: Array<{ file: String, source: String }> = fixture(root);
			Sys.putEnv('APQ_CALL_GRAPH_STORE', '0');
			CliFixture.always(() -> Sys.putEnv('APQ_CALL_GRAPH_STORE', ''), () -> {
				final store: CallGraphStore = new CallGraphStore('haxe');
				store.keep(files, CallGraph.build(files, plugin()));
				Assert.isNull(store.lookup(files), 'nothing is read');
			});
			Assert.equals(0, storedEntries(root), 'nothing is written');
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The second `callers` over an unchanged scope takes the graph from the store, holding no parse of any file, and
	 * prints what the first one printed, its unresolved-sites note included.
	 */
	@:pin('control')
	@:killer('M-CALL-GRAPH-STORE-ROUTE')
	public function testSecondRunReadsTheStoreAndPrintsTheSame(): Void {
		#if nodejs
		withPrivateTemp(root -> {
			final files: Array<{ file: String, source: String }> = fixture(root);
			final runs: Array<String> = [ for (_ in 0...2) {
				var out: String = '';
				final err: String = CliFixture.captureStderr(() ->
					out = CliFixture.captureStdout(() -> Cli.run(['callers', 'Foo.bar', root]))
				);
				out + err;
			} ];
			Assert.equals(runs[0], runs[1], 'the stored graph prints what the built one did');
			Assert.isTrue(runs[0].contains('unresolved'), 'the note on unresolved sites is printed');
			Assert.isNull(treeAfterRun(root, files[0].file), 'an unchanged scope takes the stored graph');
			sys.io.File.saveContent(files[0].file, '${files[0].source}// edited\n');
			Assert.notNull(treeAfterRun(root, files[0].file), 'a changed scope is parsed and built');
		});
		#else
		Assert.pass('stdout capture is node-only');
		#end
	}

	private static function plugin(): CachingGrammarPlugin {
		return new CachingGrammarPlugin(new HaxeQueryPlugin());
	}

	/** The fixture written under `root`, as a graph command reads it. */
	private static function fixture(root: String): Array<{ file: String, source: String }> {
		final files: Array<{ file: String, source: String }> = [
			{ file: '$root/Base.hx', source: BASE },
			{ file: '$root/Foo.hx', source: FOO },
			{ file: '$root/User.hx', source: USER }
		];
		#if (sys || nodejs)
		for (f in files) sys.io.File.saveContent(f.file, f.source);
		#end
		return files;
	}

	/** Run `body` with the temp root, where the store lives, set to a directory of its own. */
	private static function withPrivateTemp(body: (root: String) -> Void): Void {
		#if (sys || nodejs)
		final before: Null<String> = Sys.getEnv('TMPDIR');
		final root: String = CliFixture.writeDir('callgraphstore', []);
		Sys.putEnv('TMPDIR', root);
		CliFixture.always(() -> {
			Sys.putEnv('TMPDIR', before ?? '');
			CliFixture.removeDir(root);
		}, () -> body(root));
		#end
	}

	/** The tree the graph of a `callers` run over `root` holds of `file`: none when the graph came from the store. */
	private static function treeAfterRun(root: String, file: String): Null<QueryNode> {
		return CliCallGraph.storedCallGraphScope('callers', [root], 'haxe')?.graph.treeOf(file);
	}

	/** How many call-graph entries lie anywhere under `directory`. */
	private static function storedEntries(directory: String): Int {
		var count: Int = 0;
		#if (sys || nodejs)
		for (name in FileSystem.readDirectory(directory)) {
			final path: String = '$directory/$name';
			if (FileSystem.isDirectory(path))
				count += storedEntries(path)
			else if (name.endsWith('.call-graph'))
				count++;
		}
		#end
		return count;
	}

}
