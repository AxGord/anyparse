package anyparse.query.cli.command;

import anyparse.query.CallGraph.EdgeKind;
import anyparse.query.CallGraphNames;
import anyparse.query.ExitCode.EXIT_OK;
import anyparse.query.ExitCode.EXIT_RUNTIME;
import anyparse.query.ExitCode.EXIT_USAGE;
import anyparse.query.cli.CliCallGraph.GraphOutput;
import anyparse.query.cli.CliCallGraph.GraphScope;
import anyparse.query.cli.DeclarationDelta;
import anyparse.query.format.GraphText;
import anyparse.query.graph.CodeGraph;
import anyparse.query.graph.GraphDiff;
import anyparse.query.graph.GraphView;
import anyparse.query.graph.ImportGraph;
import anyparse.query.graph.MemberGraphBuilder;

/** What a `graph` draws its edges from: the scope's imports, or its call graph lifted to the level asked. */
enum abstract GraphEdgeSource(String) to String {

	final Imports = 'imports';
	final Calls = 'calls';

}

/** What one `graph` run asks for, as its arguments spell it. */
typedef GraphRequest = {
	final lang: String;
	final level: GraphLevel;
	final edges: GraphEdgeSource;

	/** The `--kinds` value as written, parsed when the run starts. */
	final kinds: Null<String>;
	final minWeight: Int;

	/** Fold every package into its first so many segments; 0 keeps the packages as declared. */
	final packageDepth: Int;
	final focus: Array<String>;
	final radius: Int;
	final mutualOnly: Bool;
	final external: Bool;
	final output: GraphOutput;

	/** The two revisions `--diff` compares, the earlier first; null for the graph of the working tree. */
	final diff: Null<Array<String>>;
	final inputSpecs: Array<String>;
}

/**
 * `apq graph` — the dependency graph of a whole scope at the package, type or member level, filtered by
 * weight, by a focus and a radius, or to the pairs that depend on each other.
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class GraphCommand implements CliCommand {

	private static inline final COMMAND: String = 'graph';
	private static inline final DEFAULT_RADIUS: Int = 1;

	public function new() {}

	public function name(): String {
		return COMMAND;
	}

	public function summary(): String {
		return 'Dependency graph of a scope by package, type or member (weights, focus, mutual pairs)';
	}

	public function usage(): Void {
		printGraphUsage();
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		final request: Null<GraphRequest> = parseRequest(args);
		if (request == null) return EXIT_OK;
		final kindsSpec: Null<String> = request.kinds;
		final kinds: Null<Array<EdgeKind>> = kindsSpec == null ? null : CliCallGraph.parseEdgeKinds(COMMAND, kindsSpec);
		if (kindsSpec != null && kinds == null) return EXIT_USAGE;
		final revisions: Null<Array<String>> = request.diff;
		if (revisions != null) {
			final changes: Null<CodeGraph> = diffGraph(request, revisions, kinds);
			if (changes == null) return EXIT_RUNTIME;
			printView(request.output, changes, '$COMMAND --diff ${revisions[0]} ${revisions[1]} --level member --edges calls');
			return ctx.emptyExit(changes.nodes().length == 0);
		}
		final drawn: Null<CodeGraph> = request.edges == Imports
			? importGraph(request.inputSpecs, request.lang, request.level)
			: callGraph(request.inputSpecs, request.lang, request.level, kinds);
		if (drawn == null) return EXIT_RUNTIME;
		final full: CodeGraph = request.packageDepth > 0 ? GraphView.foldPackages(drawn, request.packageDepth) : drawn;
		final focusIds: Array<String> = [];
		for (query in request.focus) {
			final found: Array<GraphNode> = GraphView.named(full, query, request.level);
			if (found.length == 0) {
				CliIo.stderr('apq $COMMAND: no ${request.level} in the graph is named "$query"\n');
				return ctx.emptyExit(true);
			}
			for (n in found) if (!focusIds.contains(n.id)) focusIds.push(n.id);
		}
		final view: CodeGraph = GraphView.filter(full, {
			minWeight: request.minWeight,
			focus: focusIds,
			radius: request.radius,
			mutualOnly: request.mutualOnly,
			external: request.external
		});
		printView(request.output, view, '$COMMAND --level ${request.level} --edges ${request.edges}');
		return ctx.emptyExit(view.edges().length == 0);
	}

	/** The request `args` spell, or null after printing the usage for `--help`; a `UsageFailure` on anything the run cannot use. */
	private static function parseRequest(args: Array<String>): Null<GraphRequest> {
		var lang: String = 'haxe';
		var level: Null<GraphLevel> = null;
		var diff: Null<Array<String>> = null;
		// the options that prune one graph, which a comparison of two does not take
		final pruning: Array<String> = [];
		var source: Null<GraphEdgeSource> = null;
		var kinds: Null<String> = null;
		var minWeight: Int = 1;
		var packageDepth: Int = 0;
		var radius: Int = DEFAULT_RADIUS;
		var mutualOnly: Bool = false;
		var external: Bool = false;
		var output: GraphOutput = Text;
		final focus: Array<String> = [];
		final inputSpecs: Array<String> = [];
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, a);
				case '--level':
					level = levelOf(CliArgs.expectValue(args, ++i, a));
				case '--edges':
					source = sourceOf(CliArgs.expectValue(args, ++i, a));
				case '--kinds':
					kinds = CliArgs.expectValue(args, ++i, a);
				case '--min-weight':
					minWeight = count(CliArgs.expectValue(args, ++i, a), a, 1);
					pruning.push(a);
				case '--package-depth':
					packageDepth = count(CliArgs.expectValue(args, ++i, a), a, 1);
					pruning.push(a);
				case '--focus':
					focus.push(CliArgs.expectValue(args, ++i, a));
					pruning.push(a);
				case '--radius':
					radius = count(CliArgs.expectValue(args, ++i, a), a, 0);
					pruning.push(a);
				case '--mutual':
					mutualOnly = true;
					pruning.push(a);
				case '--diff':
					final earlier: String = CliArgs.expectValue(args, ++i, a);
					diff = [earlier, CliArgs.expectValue(args, ++i, a)];
				case '--external':
					external = true;
				case '--format':
					output = CliCallGraph.parseGraphOutput(CliArgs.expectValue(args, ++i, a));
				case '-h', '--help':
					printGraphUsage();
					return null;
				case _ if (a.startsWith('--')):
					throw new UsageFailure('unknown option "$a"');
				case _:
					inputSpecs.push(a);
			}
			i++;
		}
		if (inputSpecs.length == 0) throw new UsageFailure('missing <file-or-dir-or-glob> argument');
		if (diff != null) {
			if (level != null && level != Member) throw new UsageFailure('--diff compares members: it draws --level member');
			if (source == Imports) throw new UsageFailure('--diff compares the call graph: it draws --edges calls');
			if (pruning.length > 0) throw new UsageFailure('${pruning[0]} prunes one graph: it does not combine with --diff');
			level = Member;
		}
		final drawn: GraphLevel = level ?? Package;
		final edges: GraphEdgeSource = source ?? (drawn == Member ? Calls : Imports);
		if (edges == Imports && drawn == Member)
			throw new UsageFailure('an import joins packages or types: --level member draws --edges calls');
		if (edges == Imports && kinds != null) throw new UsageFailure('--kinds selects call-graph edges: it needs --edges calls');
		return {
			lang: lang,
			level: drawn,
			edges: edges,
			kinds: kinds,
			minWeight: minWeight,
			packageDepth: packageDepth,
			focus: focus,
			radius: radius,
			mutualOnly: mutualOnly,
			external: external,
			output: output,
			inputSpecs: inputSpecs,
			diff: diff
		};
	}

	/** The import graph of the scope at `level`; null on an empty scope (message printed). */
	private static function importGraph(inputSpecs: Array<String>, lang: String, level: GraphLevel): Null<CodeGraph> {
		final scope: Null<GraphScope> = CliCallGraph.readScope(COMMAND, inputSpecs, lang);
		if (scope == null) return null;
		final index: SymbolIndex = IndexScope.report(scope.files, scope.plugin);
		return CliCallGraph.skippedEndRun(COMMAND, index.skippedFiles(), scope) ? null : ImportGraph.build(index, level);
	}

	/** The call graph of the scope lifted to `level`; null on an empty scope (message printed). */
	private static function callGraph(
		inputSpecs: Array<String>, lang: String, level: GraphLevel, kinds: Null<Array<EdgeKind>>
	): Null<CodeGraph> {
		final built: Null<{ graph: CallGraph, sources: Map<String, String> }> = CliCallGraph.buildCallGraphScope(COMMAND, inputSpecs, lang);
		if (built == null) return null;
		final calls: CallGraph = built.graph;
		if (calls.unresolved.length > 0)
			CliIo.stderr('apq $COMMAND: note — ${calls.unresolved.length} call site(s) unresolved; the graph is approximate\n');
		final members: CodeGraph = MemberGraphBuilder.whole(calls, kinds);
		return level == Member ? members : GraphView.lift(members, level);
	}

	/**
	 * The member graph of the scope at the first of `revisions` compared with the one at the second (`GraphDiff`), each
	 * read from git with no checkout; null when either cannot be read or neither holds a file of the scope (message printed).
	 */
	private static function diffGraph(request: GraphRequest, revisions: Array<String>, kinds: Null<Array<EdgeKind>>): Null<CodeGraph> {
		// object id -> text: a file both revisions hold alike is read once
		final texts: Map<String, String> = [];
		final earlier: Null<GraphScope> = CliCallGraph.revisionScope(COMMAND, revisions[0], request.inputSpecs, request.lang, texts);
		if (earlier == null) return null;
		final later: Null<GraphScope> = CliCallGraph.revisionScope(COMMAND, revisions[1], request.inputSpecs, request.lang, texts);
		if (later == null) return null;
		if (earlier.files.length == 0 && later.files.length == 0) {
			CliIo.stderr('apq $COMMAND: no input files matched ${CliArgs.quotedSpecs(request.inputSpecs)} at either revision\n');
			return null;
		}
		final renamed: Null<Map<String, String>> = GitRevision.renamedBetween(revisions[0], revisions[1], request.inputSpecs);
		if (renamed == null) {
			CliIo.stderr('apq $COMMAND: git cannot compare "${revisions[0]}" with "${revisions[1]}"\n');
			return null;
		}
		final callsBefore: Null<CallGraph> = CliCallGraph.callGraphOf(COMMAND, earlier);
		final callsAfter: Null<CallGraph> = CliCallGraph.callGraphOf(COMMAND, later);
		return callsBefore == null || callsAfter == null
			? null
			: GraphDiff.compare(
				declaredView(callsBefore, kinds, request.external), declaredView(callsAfter, kinds, request.external),
				changedMembers(earlier, later, renamed, callsAfter.index)
			);
	}

	/** Every member `calls` declares and every edge of a kind in `kinds`; a node outside the scope only when `external`. */
	private static function declaredView(calls: CallGraph, kinds: Null<Array<EdgeKind>>, external: Bool): CodeGraph {
		return GraphView.filter(MemberGraphBuilder.declared(calls, kinds), {
			minWeight: 1,
			focus: [],
			radius: 0,
			mutualOnly: false,
			external: external
		});
	}

	/**
	 * The qualified names of the members whose text differs from `earlier` to `later`: each declaration `DeclarationDelta`
	 * reports in a file both hold with another text, a file git finds renamed (`renamed`, later path to
	 * earlier) paired with its earlier path, under the package `index` reads for the file — a module-level one
	 * also under its module's name, which the call graph gives a function of no type.
	 */
	private static function changedMembers(
		earlier: GraphScope, later: GraphScope, renamed: Map<String, String>, index: Null<SymbolIndex>
	): Array<String> {
		final packages: Map<String, String> = [];
		if (index != null) for (info in index.allFiles()) packages[info.file] = info.pkg;
		final names: Array<String> = [];
		for (f in later.files) {
			final was: Null<String> = earlier.sources[renamed[f.file] ?? f.file];
			if (was == null || was == f.source) continue;
			final pkg: String = packages[f.file] ?? '';
			final prefix: String = pkg == '' ? '' : '$pkg.';
			final delta: FileDelta = DeclarationDelta.compare(later.plugin, was, f.source, CliArgs.discoverFormatConfig(f.file));
			for (change in delta.declarations) {
				names.push(prefix + change.key);
				if (change.depth == 0) names.push('$prefix${CallGraphNames.moduleTypeName(f.file)}.${change.key}');
			}
		}
		return names;
	}

	/** `view` as `output` asks: the text report, or the graph as Mermaid headed by `caption`, or as JSON. */
	private static function printView(output: GraphOutput, view: CodeGraph, caption: String): Void {
		if (output == Text)
			CliIo.sysPrint(GraphText.write(view))
		else
			CliCallGraph.printGraph(output, view, caption);
	}

	private static function levelOf(raw: String): GraphLevel {
		return switch raw {
			case 'package': Package;
			case 'type': Type;
			case 'member': Member;
			case _: throw new UsageFailure('unknown --level "$raw" (package, type, member)');
		};
	}

	private static function sourceOf(raw: String): GraphEdgeSource {
		return switch raw {
			case 'imports': Imports;
			case 'calls': Calls;
			case _: throw new UsageFailure('unknown --edges "$raw" (imports, calls)');
		};
	}

	/** `raw` as a count of at least `least`, the value of `flag`. */
	private static function count(raw: String, flag: String, least: Int): Int {
		final parsed: Null<Int> = Std.parseInt(raw);
		if (parsed == null || parsed < least || '$parsed' != raw)
			throw new UsageFailure('$flag expects an integer of at least $least, not "$raw"');
		return parsed;
	}

	private static function printGraphUsage(): Void {
		CliIo.sysPrint('Usage: apq graph <file-or-dir-or-glob>... [options]\n\n');
		CliIo.sysPrint('The dependency graph of a whole scope: one node per package, type or member, one\n');
		CliIo.sysPrint('edge per pair and kind weighted by the sites behind it; the pairs that depend on\n');
		CliIo.sysPrint('each other are listed (text), drawn red (mermaid) or marked "mutual" (json).\n\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --level <l>       package (default), type or member\n');
		CliIo.sysPrint('  --edges <e>       imports (default at package and type) or calls (the call graph lifted to the level;\n');
		CliIo.sysPrint('                    the only source at member)\n');
		CliIo.sysPrint('  --kinds <k,..>    Call edge kinds: call,ref,new,virtual,contains,accessor (default all; calls only)\n');
		CliIo.sysPrint('  --package-depth <n>  Fold every package into its first n dotted segments (a.b.c into a.b at 2)\n');
		CliIo.sysPrint('  --min-weight <n>  Draw a direction of a pair whose weight reaches n, or whose way back does\n');
		CliIo.sysPrint('  --focus <name>    Centre on the nodes named so (qualified, or a dotted suffix); repeatable\n');
		CliIo.sysPrint('  --radius <n>      Edges a node may lie from a focus node, either way (default $DEFAULT_RADIUS)\n');
		CliIo.sysPrint('  --mutual          Only the pairs that depend on each other\n');
		CliIo.sysPrint('  --external        Keep the call targets outside the scope (calls only; left out by default)\n');
		CliIo.sysPrint('  --diff <a> <b>    The member call graph at git revision <a> against the one at <b>, both read\n');
		CliIo.sysPrint('                    from git without a checkout: each member added (+), removed (-) or changed (~,\n');
		CliIo.sysPrint('                    by its text), each edge added, removed or reweighted; an unchanged member folds\n');
		CliIo.sysPrint('                    into its type, and an edge between unchanged nodes is left out. Takes --kinds,\n');
		CliIo.sysPrint('                    --external, --format, --lang; refuses the pruning options and another level\n');
		CliIo.sysPrint('  --format <f>      text (the report, default), mermaid or json\n');
		CliIo.sysPrint('  --lang <name>     Grammar plugin (default haxe)\n');
	}

}
