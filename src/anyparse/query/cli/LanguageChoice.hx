package anyparse.query.cli;

/**
 * Which grammar a process-level `apq` call names when its argv carries no `--lang`: the one whose
 * registered extension (`CliArgs.langOfFile`) every file argument carries, else — for a command that reads
 * its document from stdin — the one whose content test accepts stdin (`CliArgs.langOfContent`). There is no
 * default grammar: a call that names none is a usage error that says how to name one.
 *
 * Only the process entry asks (`Cli.run` with `chooseLanguage`); an in-process caller passes its own argv
 * through unchanged.
 */
@:nullSafety(Strict)
final class LanguageChoice {

	private static inline final LANG_FLAG: String = '--lang';

	/** The positional naming standard input. */
	private static inline final STDIN_POSITIONAL: String = '-';

	/** `ast`'s flag naming standard input. */
	private static inline final STDIN_FLAG: String = '--stdin';

	/**
	 * `args` (a command's own argv) with `--lang <name>` put first when it named none, and the stdin text read
	 * to decide it, if any. `readStdin` is called at most once, and only for a `StdinDocument` command.
	 * Throws `UsageFailure` when no grammar, or more than one, is named.
	 */
	public static function choose(args: Array<String>, command: CliCommand, readStdin: () -> String): LanguageChoiceResult {
		if (command is LanguageFree || args.contains(LANG_FLAG) || args.contains('--help') || args.contains('-h'))
			return { args: args, stdin: null };
		final ofFiles: Array<String> = [];
		for (i in 0...args.length) if (isFileArgument(args, i)) {
			final lang: Null<String> = CliArgs.langOfFile(args[i]);
			if (lang != null && !ofFiles.contains(lang)) ofFiles.push(lang);
		}
		if (ofFiles.length > 1)
			throw new UsageFailure('the files name more than one language (${ofFiles.join(', ')}) — pass --lang <name>');
		if (ofFiles.length == 1) return { args: [LANG_FLAG, ofFiles[0]].concat(args), stdin: null };
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
	 * May `args[i]` be a file the command reads? Not a flag, and not right after a `--flag`, where it may be that
	 * flag's value (`sweep --save base.json` names an output, not the language): the command's flags are its own,
	 * so a file placed after one is not counted and the call asks for `--lang` instead of guessing.
	 */
	private static function isFileArgument(args: Array<String>, i: Int): Bool {
		return !args[i].startsWith('-') && (i == 0 || !args[i - 1].startsWith('--'));
	}

	/** Every registered `--lang` with its extensions, for a usage error: `haxe .hx, json .json`. */
	private static function known(): String {
		return [for (entry in CliArgs.grammars()) '${entry.lang} ${entry.extensions.join(' ')}'].join(', ');
	}

}

/** What `LanguageChoice.choose` answers: the argv to run, and stdin if it was read to decide. */
typedef LanguageChoiceResult = {
	final args: Array<String>;
	final stdin: Null<String>;
};
