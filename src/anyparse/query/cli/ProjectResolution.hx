package anyparse.query.cli;

import anyparse.check.LintConfig;
import anyparse.query.CachingGrammarPlugin.ResolutionScope;
import anyparse.query.cli.command.LintCommand;

/**
 * The resolution scope a SINGLE-FILE edit op reads its project by — what `lint` builds for its run, from the nearest
 * `apqlint.json` (`resolutionRoots`, `resolutionLibs`, `resolutionStd`), so an op and the rule it must agree with ask one
 * index. Read lazily: a file whose edit never asks (`ImportBindings.forPlugin` builds its reader over a thunk) pays nothing.
 */
@:nullSafety(Strict)
final class ProjectResolution {

	/**
	 * `plugin` for an edit of `file` (whose current text is `source`): the plugin itself, wrapped in a
	 * `CachingGrammarPlugin` carrying the project's resolution scope when the project (or the std) provides one.
	 */
	public static function hostFor(plugin: GrammarPlugin, file: String, source: String): GrammarPlugin {
		final config: LintConfig = LintConfig.discover(file);
		final scope: Null<ResolutionScope> = LintCommand.resolutionThunk(
			[{ file: file, source: source }], config.resolutionRoots(), config.resolutionLibs(), config.resolutionStd()
		);
		final host: CachingGrammarPlugin = new CachingGrammarPlugin(plugin);
		if (scope != null) host.setResolutionScope(scope);
		return host;
	}

}
