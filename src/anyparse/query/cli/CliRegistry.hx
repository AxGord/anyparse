package anyparse.query.cli;

import anyparse.query.cli.command.CasesCommand;
import anyparse.query.cli.command.MakeFinalCommand;
import anyparse.query.cli.command.SetCommentCommand;

using Lambda;
using StringTools;

/**
 * The inventory of `apq` subcommands the dispatcher and `apq --help` both read.
 *
 * WAVE 1. Three commands live here — one read-only walk, one single-file edit
 * and one `--scope` edit, deliberately of three different shapes so the seam is
 * proved against all three rather than against one. The other 66 are still
 * `case` arms in `Cli.dispatch`; each later wave moves a batch across, and this
 * list is the only place that has to learn about them.
 *
 * `commands()` builds a FRESH array on every call instead of memoising one in a
 * `static final`. The list is small, the instances are stateless and the
 * allocation is once per process — and a shared registry is exactly the
 * process-scoped state invariant 1 exists to keep out of this layer, whatever
 * the current implementations happen to do.
 */
@:nullSafety(Strict)
final class CliRegistry {

	/**
	 * Column the `apq --help` listing indents a command's summary to, counted
	 * from the command name's first character. A name at or past the column
	 * gets a single separating space instead.
	 */
	private static inline final HELP_NAME_WIDTH: Int = 13;

	/** Every registered command, in the order `apq --help` would list them. */
	public static function commands(): Array<CliCommand> {
		return [new CasesCommand(), new MakeFinalCommand(), new SetCommentCommand()];
	}

	/** The command `name` selects, or null when the registry does not own that word yet. */
	public static function find(name: String): Null<CliCommand> {
		return commands().find(c -> c.name() == name);
	}

	/**
	 * The `apq --help` listing line for a registered command, newline included.
	 *
	 * `Cli.printUsage` calls this in place of the literal it used to print, so
	 * a registered command's description lives with the command and cannot
	 * drift from what the command does. The remaining literals in `printUsage`
	 * are the residue of the ops that have not moved yet.
	 */
	public static function helpLine(name: String): String {
		final command: Null<CliCommand> = find(name);
		if (command == null) throw 'apq: "$name" is not a registered command';
		final pad: Int = HELP_NAME_WIDTH - name.length;
		return '  $name${''.rpad(' ', pad > 0 ? pad : 0)} ${command.summary()}\n';
	}

}
