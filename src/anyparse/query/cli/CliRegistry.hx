package anyparse.query.cli;

import anyparse.query.cli.command.AddElementCommand;
import anyparse.query.cli.command.AddImportCommand;
import anyparse.query.cli.command.AddMemberCommand;
import anyparse.query.cli.command.AddMetaCommand;
import anyparse.query.cli.command.AddParamCommand;
import anyparse.query.cli.command.AstCommand;
import anyparse.query.cli.command.BlastCommand;
import anyparse.query.cli.command.CalleesCommand;
import anyparse.query.cli.command.CallersCommand;
import anyparse.query.cli.command.CasesCommand;
import anyparse.query.cli.command.ChangeSigCommand;
import anyparse.query.cli.command.ClustersCommand;
import anyparse.query.cli.command.CommentRewriteCommand;
import anyparse.query.cli.command.DeclaresCommand;
import anyparse.query.cli.command.DiffCommand;
import anyparse.query.cli.command.EncapsulateFieldCommand;
import anyparse.query.cli.command.ExtractConstantCommand;
import anyparse.query.cli.command.ExtractInterfaceCommand;
import anyparse.query.cli.command.ExtractMethodCommand;
import anyparse.query.cli.command.ExtractSuperclassCommand;
import anyparse.query.cli.command.ExtractVarCommand;
import anyparse.query.cli.command.FmtCommand;
import anyparse.query.cli.command.GatesCommand;
import anyparse.query.cli.command.ImportersCommand;
import anyparse.query.cli.command.InlineCommand;
import anyparse.query.cli.command.InlineMethodCommand;
import anyparse.query.cli.command.IntroduceParameterObjectCommand;
import anyparse.query.cli.command.LintCommand;
import anyparse.query.cli.command.LintDiffCommand;
import anyparse.query.cli.command.LitCommand;
import anyparse.query.cli.command.MakeFinalCommand;
import anyparse.query.cli.command.MentionsCommand;
import anyparse.query.cli.command.MetaCommand;
import anyparse.query.cli.command.MoveCommand;
import anyparse.query.cli.command.MoveMemberCommand;
import anyparse.query.cli.command.MutationVerdictCommand;
import anyparse.query.cli.command.NewCommand;
import anyparse.query.cli.command.OracleCommand;
import anyparse.query.cli.command.PatchCommand;
import anyparse.query.cli.command.ProbeCommand;
import anyparse.query.cli.command.PullUpCommand;
import anyparse.query.cli.command.PushDownCommand;
import anyparse.query.cli.command.ReachCommand;
import anyparse.query.cli.command.ReconCommand;
import anyparse.query.cli.command.RefsCommand;
import anyparse.query.cli.command.RemoveElementCommand;
import anyparse.query.cli.command.RemoveImportCommand;
import anyparse.query.cli.command.RemoveMemberCommand;
import anyparse.query.cli.command.RemoveParamCommand;
import anyparse.query.cli.command.RenameCommand;
import anyparse.query.cli.command.ReplaceNodeCommand;
import anyparse.query.cli.command.RewriteCommand;
import anyparse.query.cli.command.SafeDeleteCommand;
import anyparse.query.cli.command.SearchCommand;
import anyparse.query.cli.command.SelfStatusCommand;
import anyparse.query.cli.command.SetCommentCommand;
import anyparse.query.cli.command.SetDocCommand;
import anyparse.query.cli.command.SetModifierCommand;
import anyparse.query.cli.command.ShardPlanCommand;
import anyparse.query.cli.command.ShowCommand;
import anyparse.query.cli.command.SourceCommand;
import anyparse.query.cli.command.StdlibDupCommand;
import anyparse.query.cli.command.StripCommand;
import anyparse.query.cli.command.SweepCommand;
import anyparse.query.cli.command.SymbolsCommand;
import anyparse.query.cli.command.TestSummaryCommand;
import anyparse.query.cli.command.UsesCommand;
import anyparse.query.cli.command.WriterEqualsCommand;
import anyparse.query.cli.command.WriterProbeCommand;

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

	private static inline final ENCAPSULATE_FIELD_GAP: Int = 3;

	/** Every registered command, in the order `apq --help` would list them. */
	public static function commands(): Array<CliCommand> {
		return [
			new AstCommand(),
			new ProbeCommand(),
			new SearchCommand(),
			new RefsCommand(),
			new RenameCommand(),
			new MoveCommand(),
			new MoveMemberCommand(),
			new ExtractInterfaceCommand(),
			new PullUpCommand(),
			new PushDownCommand(),
			new ExtractSuperclassCommand(),
			new SafeDeleteCommand(),
			new EncapsulateFieldCommand(),
			new MakeFinalCommand(),
			new IntroduceParameterObjectCommand(),
			new SymbolsCommand(),
			new ImportersCommand(),
			new DeclaresCommand(),
			new LintCommand(),
			new LintDiffCommand(),
			new OracleCommand(),
			new MutationVerdictCommand(),
			new ShardPlanCommand(),
			new InlineCommand(),
			new InlineMethodCommand(),
			new ExtractVarCommand(),
			new ExtractConstantCommand(),
			new ExtractMethodCommand(),
			new AddParamCommand(),
			new ChangeSigCommand(),
			new RemoveParamCommand(),
			new AddMemberCommand(),
			new AddImportCommand(),
			new AddMetaCommand(),
			new AddElementCommand(),
			new ReplaceNodeCommand(),
			new PatchCommand(),
			new RemoveElementCommand(),
			new RemoveImportCommand(),
			new RemoveMemberCommand(),
			new UsesCommand(),
			new MetaCommand(),
			new BlastCommand(),
			new LitCommand(),
			new MentionsCommand(),
			new CasesCommand(),
			new CalleesCommand(),
			new CallersCommand(),
			new ReachCommand(),
			new ClustersCommand(),
			new StdlibDupCommand(),
			new GatesCommand(),
			new DiffCommand(),
			new StripCommand(),
			new WriterEqualsCommand(),
			new WriterProbeCommand(),
			new ReconCommand(),
			new SweepCommand(),
			new SetModifierCommand(),
			new TestSummaryCommand(),
			new RewriteCommand(),
			new SetDocCommand(),
			new SetCommentCommand(),
			new CommentRewriteCommand(),
			new SelfStatusCommand(),
			new NewCommand(),
			new SourceCommand(),
			new ShowCommand(),
			new FmtCommand()
		];
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
		return '  $name${''.rpad(' ', helpGap(name))}${command.summary()}\n';
	}

	/**
	 * Spaces between a command's name and its description in the `apq --help` listing.
	 *
	 * A name that fits `HELP_NAME_WIDTH` is padded to that column and the listing reads
	 * as one table. The nine names that overflow it were aligned one at a time, years
	 * before a registry existed, to no rule at all — three took a single space, five took
	 * two, one took three — and `--help` is pinned byte-for-byte against the pre-seam
	 * binary. So the leftovers are data this function carries, not noise to normalise:
	 * normalising them changes what every user sees and belongs in a change that says so.
	 */
	private static function helpGap(name: String): Int {
		final pad: Int = HELP_NAME_WIDTH - name.length;
		if (pad > 0) return pad + 1;
		return switch name {
			case 'encapsulate-field': ENCAPSULATE_FIELD_GAP;
			case 'comment-rewrite', 'extract-interface', 'extract-superclass', 'introduce-parameter-object', 'mutation-verdict': 2;
			case _: 1;
		}
	}

}
