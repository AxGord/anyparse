package dev;

import devkit.Args;
import devkit.Summary.Outcome;
import haxe.io.Path;
import sys.FileSystem;

using StringTools;

/**
 * The one answer to "which lint findings does this tree add against a base commit": the lint row of `dev slice-gate`
 * (`GateLint.lintOutcome`) run alone, so a commit step refuses on the multiset the gate will decide with — a finding on a
 * line the slice only renamed in, or on a moved file, is not new — instead of on every changed line. Exits 0 when nothing is
 * new, 1 when something is, 2 when it could not tell.
 */
@:nullSafety(Strict)
final class LintNew {

	public static inline final USAGE: String = 'usage: dev lint-new <base> [--tree <dir>] [--logs <dir>] [--no-oracle]';

	/** The row's name in the printed table, the gate's own. */
	private static inline final ROW: String = 'lint';

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final oracle: Bool = !args.flag('--no-oracle');
		final treeOption: Null<String> = args.option('--tree');
		final logsOption: Null<String> = args.option('--logs');
		final tree: String = FileSystem.fullPath(treeOption ?? Sys.getCwd());
		if (!FileSystem.exists(Path.join([tree, 'tools/dev.hxml']))) throw new UsageError('$tree is not an anyparse tree');
		final base: String = GateTree.gitIn(tree, ['rev-parse', '--verify', args.positionals(['<base>'])[0] + '^{commit}']).trim();
		final logsDir: String = logsOption ?? Path.join(['${Path.removeTrailingSlashes(tree)}-logs', 'lint-new']);
		FileSystem.createDirectory(logsDir);
		final logs: String = FileSystem.fullPath(logsDir);
		return run(
			new GateTree({
				tree: tree,
				logs: logs,
				baseline: false,
				base: base,
				frozen: [],
				infra: [],
				arms: [],
				allow: [],
				allowArms: [],
				noArms: true,
				threads: null,
				run: ''
			}),
			oracle
		);
	}

	/** Print the row `gate`'s tree earns against its base and answer the exit status. */
	public static function run(gate: GateTree, oracle: Bool): Int {
		final outcome: Outcome = gate.summary.time(ROW, new GateLint(gate, oracle).lintOutcome);
		Sys.println(gate.summary.table());
		final excerpts: String = gate.summary.excerpts();
		if (excerpts != '') Sys.println(excerpts);
		return switch outcome {
			case Passed, Skipped(_): 0;
			case Failed(_): 1;
			case NotRun(_): 2;
		}
	}

}
