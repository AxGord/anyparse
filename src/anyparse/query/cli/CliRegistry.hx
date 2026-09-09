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
import anyparse.query.cli.command.CondCommand;
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
import anyparse.query.cli.command.ResolveDefineCommand;
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
			new CondCommand(),
			new ResolveDefineCommand(),
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
	 * Subcommands a mistyped `name` plausibly meant, best first, or empty when nothing is close.
	 *
	 * Delegates to the walkers' own two-tier matcher (`CliWalk.findFuzzy`: contiguous substring,
	 * then Levenshtein) so a near-miss ranks the same way at both entry points and neither can
	 * drift into its own notion of "close".
	 *
	 * The one thing added here is the PLURAL probe, and it is the case that motivated the whole
	 * function: the command vocabulary is singular (`add-member`, `move-member`,
	 * `remove-member`) while the miss a reader actually makes is `hxq members`, which is five
	 * edits from the nearest of them — past the distance tier's ceiling — and not a substring of
	 * any of them either. Its singular STEM is a substring of three real commands, so dropping a
	 * trailing `s` and asking again is what turns that miss from "no idea" into the right answer.
	 * Tried only when the direct query found nothing, so a real plural command name (none today)
	 * would still answer for itself.
	 */
	public static function nearest(name: String): Array<String> {
		// `findFuzzy` takes the pool as a Map because its walker callers hold one; the values
		// carry nothing.
		final pool: Map<String, Bool> = [for (c in commands()) c.name() => true];
		final direct: Array<String> = CliWalk.findFuzzy(name, pool);
		return direct.length > 0 || !name.endsWith('s') ? direct : CliWalk.findFuzzy(name.substr(0, name.length - 1), pool);
	}

	/**
	 * What `Cli.dispatch` says about a subcommand it cannot resolve: the miss, the nearest real
	 * names, and where the full list is.
	 *
	 * It replaces a `printUsage()` call, and that is the whole point. The dispatcher used to
	 * answer an unknown subcommand with the ENTIRE help page — measured 5440 bytes on `apq
	 * members Foo`, ~1360 tokens — for a reader who mistyped one word and needs one word back.
	 * The list is still one command away and is named here; what the reader gets by default is
	 * the answer.
	 *
	 * Returned as lines rather than printed because `CliIo.stderr` is a process write with no
	 * seam a test can read (`LintFixLedger.ledgerLines`' reason, and the same pin shape).
	 */
	public static function unknownCommandLines(name: String): Array<String> {
		final hints: Array<String> = nearest(name);
		final head: String = hints.length == 0
			? 'apq: unknown subcommand "$name"\n'
			: 'apq: unknown subcommand "$name" — did you mean: ${hints.join(', ')}?\n';
		return [
			head,
			'apq: run `apq --help` for all ${commands().length} commands, or `apq <command> --help` for one\n'
		];
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
