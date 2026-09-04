package anyparse.query.cli.command;

import anyparse.query.CallGraph.EdgeKind;
import anyparse.query.CallGraph.FnNode;
import anyparse.query.cli.CliContext;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq callees` — transitive call tree FROM a function (approximate call graph).
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class CalleesCommand implements CliCommand {

	private static inline final DEFAULT_CHAIN_LINES: Int = 200;

	public function new() {}

	public function name(): String {
		return 'callees';
	}

	public function summary(): String {
		return 'Transitive call tree FROM a function (approximate call graph)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runCallees(args, ctx);
	}

	public function usage(): Void {
		printCallChainsUsage('callees', true);
	}

	private static inline function runCallees(args: Array<String>, ctx: CliContext): Int {
		return runCallChains('callees', true, args, ctx);
	}

	/**
	 * The approximate-graph note for `callers` / `callees`. Severity does not swing with the
	 * unresolved COUNT but with `provenEmpty`: `CallChains.render` always emits the root label,
	 * so a one-line tree is an empty answer that reads exactly like a populated one, and there
	 * the omission is the dangerous kind. With edges shown the result is merely partial. Sister
	 * of `memberAccessNudge`, same two-severity shape; the caller invokes this only when
	 * something IS unresolved, so a fully resolved zero never claims to be inconclusive.
	 */
	private static function chainUnresolvedNote(cmd: String, target: String, unresolved: Int, provenEmpty: Bool): String {
		return provenEmpty
			? 'apq $cmd: no $cmd resolved, but $unresolved call site(s) in scope are unresolved — this is NOT proof "$target" has none'
			: 'apq $cmd: note — $unresolved call site(s) unresolved; the graph is approximate';
	}

	public static function runCallChains(cmd: String, outward: Bool, args: Array<String>, ctx: CliContext): Int {
		var lang: String = 'haxe';
		var depth: Int = 1;
		var limit: Int = -1;
		var kinds: Null<Array<EdgeKind>> = null;
		var target: Null<String> = null;
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--depth':
					final raw: String = CliArgs.expectValue(args, ++i, '--depth');
					final parsedDepth: Null<Int> = Std.parseInt(raw);
					if (parsedDepth == null || parsedDepth < 1) {
						CliIo.stderr('apq $cmd: --depth expects a positive integer\n');
						return EXIT_USAGE;
					}
					depth = parsedDepth;
				case '--limit':
					try limit = CliArgs.parseLimit(args, ++i) catch (exception: Exception) {
						CliIo.stderr('${exception.message}\n');
						return EXIT_USAGE;
					}
				case '--kinds':
					kinds = CliCallGraph.parseEdgeKinds(cmd, CliArgs.expectValue(args, ++i, '--kinds'));
					if (kinds == null) return EXIT_USAGE;
				case '-h', '--help':
					printCallChainsUsage(cmd, outward);
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq $cmd: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (target == null)
						target = a;
					else
						inputSpecs.push(a);
			}
			i++;
		}
		if (target == null) {
			CliIo.stderr('apq $cmd: missing <Type.method|method> argument\n');
			printCallChainsUsage(cmd, outward);
			return EXIT_USAGE;
		}
		if (inputSpecs.length == 0) {
			CliIo.stderr('apq $cmd: missing <file-or-dir-or-glob> argument\n');
			printCallChainsUsage(cmd, outward);
			return EXIT_USAGE;
		}
		final targetStr: String = target;

		final built: Null<{ graph: CallGraph, sources: Map<String, String> }> = CliCallGraph.buildCallGraphScope(cmd, inputSpecs, lang);
		if (built == null) return EXIT_RUNTIME;
		final graph: CallGraph = built.graph;
		final sources: Map<String, String> = built.sources;
		final matches: Array<FnNode> = graph.resolveTarget(targetStr);
		if (matches.length == 0) {
			CliIo.stderr('apq $cmd: no function in scope matches "$targetStr"\n');
			return ctx.emptyExit(true);
		}
		// --limit 0 = uncapped; unset = DEFAULT_CHAIN_LINES; the budget is
		final provenEmpty: Bool = renderChains(graph, matches, depth, outward, kinds, sources, limit);
		if (graph.unresolved.length > 0) CliIo.stderr('${chainUnresolvedNote(cmd, targetStr, graph.unresolved.length, provenEmpty)}\n');
		return ctx.emptyExit(provenEmpty);
	}

	/**
	 * Print every match's call tree and report whether the EMPTY answer is PROVEN: no tree
	 * carried an edge line AND every match was rendered. `CallChains.render` always emits the
	 * root label, so a one-line tree is the empty answer and the count cannot come from the
	 * `--limit` arm alone; and a budget break leaves later matches unrendered, where "we did
	 * not look" must never be reported as "there is nothing". The line budget is shared across
	 * the multiple matches of a bare-name target (`limit == 0` = uncapped).
	 */
	private static function renderChains(
		graph: CallGraph, matches: Array<FnNode>, depth: Int, outward: Bool, kinds: Null<Array<EdgeKind>>, sources: Map<String, String>,
		limit: Int
	): Bool {
		var budget: Int = if (limit == 0)
			0
		else if (limit > 0)
			limit
		else
			DEFAULT_CHAIN_LINES;
		var anyEdge: Bool = false;
		for (m in matches) {
			final rendered: String = CallChains.render(graph, m.id, depth, outward, kinds, f -> sources[f], budget);
			CliIo.sysPrint(rendered);
			final lines: Int = rendered.split('\n').length - 1;
			if (lines > 1) anyEdge = true;
			if (limit == 0) continue;
			budget -= lines;
			if (budget > 0) continue;
			// matches remain unrendered - the negative claim is no longer licensed
			return false;
		}
		return !anyEdge;
	}

	public static function printCallChainsUsage(cmd: String, outward: Bool): Void {
		final what: String = outward ? 'functions CALLED BY the target (out-edges)' : 'functions CALLING the target (in-edges)';
		CliIo.sysPrint('Usage: apq $cmd <Type.method|method> <file-or-dir-or-glob>... [options]\n\n');
		CliIo.sysPrint('Transitive call tree: $what.\n\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --depth <n>    Levels to expand (default 1)\n');
		CliIo.sysPrint('  --kinds <k,..> Edge kinds: call,ref,new,virtual,contains (default all)\n');
		CliIo.sysPrint('  --limit <n>    Max total tree lines across matches (default $DEFAULT_CHAIN_LINES; 0 = uncapped)\n');
		CliIo.sysPrint('  --lang <name>  Grammar plugin (default haxe)\n');
	}

}
