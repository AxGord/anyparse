package anyparse.query.cli;

import anyparse.check.ConfigNotes;
import anyparse.check.LintConfig;
import anyparse.query.CachingGrammarPlugin.ResolutionScope;
import anyparse.query.cli.command.LintCommand;

/**
 * The resolution scope a SINGLE-FILE edit op reads its project by — what `lint` builds for its run, from the nearest
 * `apq.json` (`resolutionRoots`, `resolutionLibs`, `resolutionStd`), so an op and the rule it must agree with ask one
 * index. Read lazily: a file whose edit never asks (`ImportBindings.forPlugin` builds its reader over a thunk) pays nothing.
 */
@:nullSafety(Strict)
final class ProjectResolution {

	/**
	 * `plugin` for an edit of `file` (whose current text is `source`): the plugin itself, wrapped in a
	 * `CachingGrammarPlugin` carrying the project's resolution scope when the project (or the std) provides one.
	 */
	public static function hostFor(plugin: GrammarPlugin, file: String, source: String, ledger: RunLedger): GrammarPlugin {
		return hostOver(plugin, file, [{ file: file, source: source }], ledger);
	}

	/**
	 * `hostFor` for an op that reads several files: `files` is the report side of the resolution scope, so the index sees
	 * every file the op searches as well as the project's roots; `file` names the config that governs the run.
	 */
	public static function hostOver(
		plugin: GrammarPlugin, file: String, files: Array<{ file: String, source: String }>, ledger: RunLedger
	): GrammarPlugin {
		final notes: Array<ConfigNote> = [];
		final config: LintConfig = LintConfig.discover(file, notes);
		OracleProviders.reportDrops(config, plugin, notes);
		ConfigNotes.say(ledger, notes, CliIo.stderr);
		final scope: Null<ResolutionScope> = LintCommand.resolutionThunk(
			plugin.langName(), files, config.resolutionRoots(), config.resolutionLibs(), config.resolutionStd(), ledger
		);
		final host: CachingGrammarPlugin = new CachingGrammarPlugin(plugin);
		if (scope != null) host.setResolutionScope(scope);
		return host;
	}

}
