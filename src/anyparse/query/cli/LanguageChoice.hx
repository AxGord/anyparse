package anyparse.query.cli;

/**
 * Which grammar a process-level `apq` call names when its argv carries no `--lang`: the one whose
 * registered extension (`CliArgs.langOfFile`) every file argument carries (none at all for a call its command
 * declares `LanguageFree` or `LanguageFreeWhen`), else — for a command that reads
 * its document from stdin — the one whose content test accepts stdin (`CliArgs.langOfContent`). The only
 * default is a preset's `--lang-default` (`hxq`), which yields to a file another grammar's extension names; a
 * call that names none is a usage error that says how to name one.
 *
 * Only the process entry asks (`Cli.run` with `chooseLanguage`); an in-process caller passes its own argv
 * through unchanged.
 */
@:nullSafety(Strict)
final class LanguageChoice {

	private static inline final LANG_FLAG: String = '--lang';

	/** A preset's grammar (`hxq` passes `--lang-default haxe`): taken only when no file argument names another. */
	private static inline final PRESET_FLAG: String = '--lang-default';

	/** The positional naming standard input. */
	private static inline final STDIN_POSITIONAL: String = '-';

	/** `ast`'s flag naming standard input. */
	private static inline final STDIN_FLAG: String = '--stdin';

	/**
	 * `given` (a command's own argv) with `--lang <name>` put first when it named none, and the stdin text read
	 * to decide it, if any. A `--lang-default <name>` is taken out and names the grammar only when no file argument
	 * names one, before stdin is consulted. `readStdin` is called at most once, and only for a `StdinDocument` command.
	 * Throws `UsageFailure` when no grammar is named, or — with no preset — more than one.
	 */
	public static function choose(given: Array<String>, command: CliCommand, readStdin: () -> String): LanguageChoiceResult {
		final at: Int = given.indexOf(PRESET_FLAG);
		final preset: Null<String> = presetAt(given, at);
		final args: Array<String> = preset == null ? given : given.slice(0, at).concat(given.slice(at + 2));
		if (args.contains(LANG_FLAG)) return { args: args, stdin: null };
		if (command is LanguageFree || languageFreeFor(command, args) || args.contains('--help') || args.contains('-h'))
			return preset == null ? { args: args, stdin: null } : named(preset, args);
		final ofFiles: Array<String> = [];
		// A `-`-led positional is stdin or a short option.
		for (file in fileArguments(args, command)) if (!file.startsWith(STDIN_POSITIONAL)) {
			final lang: Null<String> = CliArgs.langOfFile(file);
			if (lang != null && !ofFiles.contains(lang)) ofFiles.push(lang);
		}
		// Under a preset a mixed set reads as the preset's grammar, as it did before the preset yielded to extensions.
		if (ofFiles.length > 1 && preset == null)
			throw new UsageFailure('the files name more than one language (${ofFiles.join(', ')}) — pass --lang <name>');
		if (ofFiles.length == 1) return named(ofFiles[0], args);
		// A preset is a default, not an override: a file another grammar's extension names is read by that grammar.
		if (preset != null) return named(preset, args);
		if (command is StdinDocument && (args.contains(STDIN_POSITIONAL) || args.contains(STDIN_FLAG))) {
			final text: String = readStdin();
			final lang: String = CliArgs.langOfContent(text) ?? throw new UsageFailure(
				'stdin is not recognisably any registered language — pass --lang <name> (${known()})'
			);
			return { args: [LANG_FLAG, lang].concat(args), stdin: text };
		}
		throw new UsageFailure('no argument names a file of a known language — pass --lang <name> (${known()})');
	}

	/**
	 * The positionals of `args` that can name a file: by the command's own flag spec, so never a flag's value, and for a
	 * `LeadingQuery` command only the scope side of `CliArgs.routePositional`, so never the text it searches for, and
	 * for a `LeadingQueryCount` command none of the positionals its argv counts as text.
	 */
	private static function fileArguments(args: Array<String>, command: CliCommand): Array<String> {
		final positionals: Array<Int> = command.flags().positionals(args);
		if (command is LeadingQueryCount) {
			final texts: Int = cast(command, LeadingQueryCount).leadingQueryCount(args);
			return [for (n => i in positionals) if (n >= texts) args[i]];
		}
		if (!(command is LeadingQuery)) return [for (i in positionals) args[i]];
		final separator: Int = CliArgs.nameSeparatorIndex(args);
		final queries: Array<String> = [];
		final scope: Array<String> = [];
		for (i in positionals) CliArgs.routePositional(args[i], i, separator, queries, scope);
		return scope;
	}

	/** `args` led by `--lang <lang>`, with no stdin read. */
	private static function named(lang: String, args: Array<String>): LanguageChoiceResult {
		return { args: [LANG_FLAG, lang].concat(args), stdin: null };
	}

	/** The grammar `--lang-default` names at `at` (`-1`: none); throws `UsageFailure` when the flag ends the argv. */
	private static function presetAt(given: Array<String>, at: Int): Null<String> {
		if (at < 0) return null;
		if (at + 1 >= given.length) throw new UsageFailure('$PRESET_FLAG needs a language name');
		return given[at + 1];
	}

	/** Every registered `--lang` with its extensions, for a usage error: `haxe .hx, json .json`. */
	private static function known(): String {
		return [for (entry in CliArgs.grammars()) '${entry.lang} ${entry.extensions.join(' ')}'].join(', ');
	}

	/** Whether `command` declares this very call language-free (`LanguageFreeWhen`). */
	private static function languageFreeFor(command: CliCommand, args: Array<String>): Bool {
		return command is LanguageFreeWhen && cast(command, LanguageFreeWhen).languageFreeFor(args);
	}

}

/** What `LanguageChoice.choose` answers: the argv to run, and stdin if it was read to decide. */
typedef LanguageChoiceResult = {
	final args: Array<String>;
	final stdin: Null<String>;
};
