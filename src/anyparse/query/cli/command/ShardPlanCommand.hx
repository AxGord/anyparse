package anyparse.query.cli.command;

import anyparse.query.ShardPlan.ShardPlacement;
import anyparse.query.ShardPlan.ShardPlanResult;
import anyparse.query.cli.CliArgs;
import anyparse.query.cli.CliContext;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq shard-plan` — deal a runner's test classes onto N APQ_TEST shards.
 *
 * A multi-file WALK: the path specs go through `CliArgs`, the files through `CliWalk`,
 * and an empty result answers `ctx.emptyExit` so a script can tell "found nothing"
 * from "ran fine".
 */
@:nullSafety(Strict)
final class ShardPlanCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'shard-plan';
	}

	public function summary(): String {
		return 'Deal a runner\'s test classes onto N APQ_TEST shards';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		#if (sys || nodejs)
		return runShardPlan(args);
		#else
		CliIo.stderr('apq shard-plan: requires a sys target (file read)\n');
		return EXIT_USAGE;
		#end
	}

	public function usage(): Void {
		#if (sys || nodejs)
		printShardPlanUsage();
		#end
	}

	#if (sys || nodejs)
	/**
	 * `apq shard-plan` — the arithmetic `tools/suite-shard.sh` used to carry as
	 * fifteen awk blocks. This layer only reads and parses the runner and prints
	 * the result; every gate and the split itself are `ShardPlan`, under test.
	 */
	private static function runShardPlan(args: Array<String>): Int {
		var runner: Null<String> = null;
		var classesPath: Null<String> = null;
		var shardsText: Null<String> = null;
		var format: String = 'lines';
		var lang: String = 'haxe';
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--runner':
					runner = CliArgs.expectValue(args, ++i, '--runner');
				case '--classes':
					classesPath = CliArgs.expectValue(args, ++i, '--classes');
				case '--shards':
					shardsText = CliArgs.expectValue(args, ++i, '--shards');
				case '--format':
					format = CliArgs.expectValue(args, ++i, '--format');
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '-h', '--help':
					printShardPlanUsage();
					return EXIT_OK;
				case _:
					CliIo.stderr('apq shard-plan: unexpected argument "$a" — the class list is named by --runner or --classes\n');
					printShardPlanUsage();
					return EXIT_USAGE;
			}
			i++;
		}
		if (runner != null && classesPath != null) {
			CliIo.stderr('apq shard-plan: --runner and --classes are mutually exclusive — one class list per plan\n');
			printShardPlanUsage();
			return EXIT_USAGE;
		}
		if (shardsText == null) {
			CliIo.stderr('apq shard-plan: --shards <N> is required\n');
			printShardPlanUsage();
			return EXIT_USAGE;
		}
		if (format != 'lines' && format != 'filters') {
			CliIo.stderr('apq shard-plan: --format expects lines or filters, got "$format"\n');
			return EXIT_USAGE;
		}
		// The regex, not Std.parseInt alone: parseInt reads a leading number out
		// of "4x" and would silently plan four shards for a typo.
		final shardsRaw: String = shardsText;
		final shards: Null<Int> = new EReg('^[0-9]+$', '').match(shardsRaw) ? Std.parseInt(shardsRaw) : null;
		if (shards == null || shards < 1) {
			CliIo.stderr('apq shard-plan: --shards expects a positive integer, got "$shardsRaw"\n');
			return EXIT_USAGE;
		}
		final shardCount: Int = shards;

		// The generated-registry door. `tools/suite-shard.sh` asks the runner
		// itself (`node bin/test.js --list-classes`) and hands the answer here,
		// so the plan is made from the list the run will actually register
		// rather than from a re-derivation of it out of source text.
		final classes: Null<String> = classesPath;
		if (classes != null) {
			final listed: Array<String> = [
				for (line in CliIo.readFile(classes).split('\n')) if (line.trim() != '') line.trim()
			];
			return renderShardPlan(ShardPlan.planClasses(listed, shardCount, classes), format, shardCount);
		}
		if (runner == null) {
			CliIo.stderr('apq shard-plan: one of --runner <path> or --classes <path> is required\n');
			printShardPlanUsage();
			return EXIT_USAGE;
		}

		final io: ResolvedInputs = CliArgs.resolveInputPaths(lang, [runner]);
		final paths: Array<String> = io.paths;
		if (paths.length != 1) {
			CliIo.stderr('apq shard-plan: --runner must name ONE file, "$runner" matched ${paths.length}\n');
			return EXIT_RUNTIME;
		}
		final path: String = paths[0];
		final source: String = CliIo.readSourceForParse(path);
		final tree: Null<QueryNode> = CliWalk.parseWalked('shard-plan', io.plugin.parseFile, path, source, true);
		if (tree == null) return EXIT_RUNTIME;

		// Re-bound: a narrowed local never reaches an anonymous-structure literal
		// whose expected field is non-nullable.
		final parsed: QueryNode = tree;
		return renderShardPlan(
			ShardPlan.plan({
				tree: parsed,
				source: source,
				runner: path,
				shards: shardCount
			}),
			format, shardCount
		);
	}

	/** Print a finished shard plan in the requested format, or its refusal on stderr. */
	private static function renderShardPlan(result: ShardPlanResult, format: String, shardCount: Int): Int {
		return switch result {
			case Planned(placements):
				final rows: Array<ShardPlacement> = placements;
				CliIo.sysPrint(format == 'filters' ? ShardPlan.renderFilters(rows, shardCount) : ShardPlan.renderLines(rows));
				EXIT_OK;
			case Refused(message):
				CliIo.stderr('$message\n');
				EXIT_RUNTIME;
		};
	}

	/** `apq shard-plan --help`. */
	private static function printShardPlanUsage(): Void {
		CliIo.sysPrint('Usage: apq shard-plan (--runner <RunTests.hx> | --classes <list>) --shards <N>\n');
		CliIo.sysPrint('                      [--format lines|filters]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Deal N APQ_TEST shards for tools/suite-shard.sh, from one of two class lists.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('  --classes <path>  one fully-qualified class name per line, blank lines\n');
		CliIo.sysPrint('                    ignored — what `node bin/test.js --list-classes` prints,\n');
		CliIo.sysPrint('                    i.e. the GENERATED registry the run will actually use.\n');
		CliIo.sysPrint('  --runner <path>   a runner source file; its addCase(new X()) registrations\n');
		CliIo.sysPrint('                    are read as AST shapes, so both constructor arity and\n');
		CliIo.sysPrint('                    dotted-vs-bare names are structure rather than text.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Output:\n');
		CliIo.sysPrint('  lines    (default) one "<shard>\\t<class>" row per registered class\n');
		CliIo.sysPrint('  filters  N lines, line i being the comma-joined APQ_TEST value of shard i\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Exits 1, printing the reason on stderr, for a registration it cannot name, a\n');
		CliIo.sysPrint('class registered twice, an APQ_TEST substring collision, a pinned class that\n');
		CliIo.sysPrint('is no longer registered, a plan that does not cover the class list, and an\n');
		CliIo.sysPrint('empty shard. The per-class weights only balance the split — no gate reads\n');
		CliIo.sysPrint('them, so a stale weight costs balance and never correctness.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --runner <path>  utest runner to read the registrations from (required)\n');
		CliIo.sysPrint('  --shards <N>     How many shards to deal onto (required, >= 1)\n');
		CliIo.sysPrint('  --format <fmt>   lines (default) or filters\n');
		CliIo.sysPrint('  -h, --help       Show this help\n');
	}
	#end

}
