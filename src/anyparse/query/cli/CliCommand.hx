package anyparse.query.cli;

/**
 * One `apq` subcommand, as a thing rather than as a `case` arm.
 *
 * `Cli` grew to 69 commands, and every one of them is the same four parts —
 * a name, the line it contributes to `apq --help`, its own `--help` page, and
 * the run — written out four times in four different places: a `case` in
 * `dispatch`, a literal in `printUsage`, a `printXUsage`, a `runX`. Nothing
 * held them together, so a command could be dispatched and never listed, or
 * listed and never dispatched, and only a reader would notice.
 *
 * This is the same answer S49 gave the test suite: the registry IS the
 * inventory. A command that is not in `CliRegistry.commands()` does not exist,
 * and one that is gets its help line for free.
 *
 * An implementation MUST be stateless — no instance fields. The registry hands
 * out fresh instances per run, and anything a run needs to remember belongs on
 * the `CliContext` it is given, never on the command. That is invariant 1 at
 * this layer: state is run-scoped or it is a bug.
 */
interface CliCommand {

	/** The subcommand word as it is typed: `cases`, `set-comment`, `make-final`. */
	public function name(): String;

	/** The one-line description `apq --help` lists this command with. */
	public function summary(): String;

	/** Print this command's own `--help` page to stdout. */
	public function usage(): Void;

	/**
	 * Run the command on `args` — argv with the subcommand word and the
	 * global flags already removed — and answer the process exit status.
	 */
	public function run(args: Array<String>, ctx: CliContext): Int;

}
