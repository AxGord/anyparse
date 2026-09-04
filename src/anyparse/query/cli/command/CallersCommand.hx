package anyparse.query.cli.command;

import anyparse.query.cli.CliContext;

/**
 * `apq callers` — transitive call tree INTO a function (approximate call graph).
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class CallersCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'callers';
	}

	public function summary(): String {
		return 'Transitive call tree INTO a function (approximate call graph)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runCallers(args, ctx);
	}

	public function usage(): Void {
		CalleesCommand.printCallChainsUsage('callers', false);
	}

	private static inline function runCallers(args: Array<String>, ctx: CliContext): Int {
		return CalleesCommand.runCallChains('callers', false, args, ctx);
	}

}
