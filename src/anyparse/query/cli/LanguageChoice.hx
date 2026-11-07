package anyparse.query.cli;

import anyparse.query.cli.LanguageDeclaration.ProjectLanguages;
import sys.FileSystem;

using Lambda;

/**
 * Which grammars a process-level `apq` call runs on when its argv carries no `--lang` — the one answer to that question.
 * In order: the grammars whose registered extension (`CliArgs.langOfFile`) the file arguments carry, yielding only to a
 * preset's `--lang-default` (`hxq`) when they name none or several; for a command reading its document from stdin, the
 * project's `lang`, else the grammar whose content test accepts it (`CliArgs.langOfContent`); the grammars of the
 * project's `languages` (default: every registered one) that have files under the other arguments; the project's
 * `lang`. A call several grammars answer runs once per grammar, each run over its own files, and a `PatternQuery` only
 * for the grammars its query parses in. A call nothing answers is a usage error that says how to name one; a command
 * declaring `LanguageFree` or `LanguageFreeWhen` is never asked.
 *
 * The project is what `LanguageDeclaration` reads above the first argument that exists.
 * Only the process entry asks (`Cli.run` with `chooseLanguage`); an in-process caller
 * passes its own argv through unchanged.
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

	/** The switch asking a command for a JSON document. */
	private static inline final JSON_SWITCH: String = '--json';

	/** The flag naming a report's format, and its JSON value. */
	private static inline final FORMAT_FLAG: String = '--format';

	private static inline final JSON_FORMAT: String = 'json';

	/**
	 * `given` (a command's own argv) as the runs to make, each led by `--lang <name>` when it named none, and the stdin
	 * text read to decide, if any. A `--lang-default <name>` is taken out and names the grammar only when the file
	 * arguments name no single one, before stdin is consulted. `readStdin` is called at most once, and only for a
	 * `StdinDocument` command. `base` is where the project config is looked for when no argument exists on disk.
	 * Throws `UsageFailure` when nothing names a grammar.
	 */
	public static function choose(
		given: Array<String>, command: CliCommand, readStdin: () -> String, base: String = '.'
	): LanguageChoiceResult {
		final at: Int = given.indexOf(PRESET_FLAG);
		final preset: Null<String> = presetAt(given, at);
		final args: Array<String> = preset == null ? given : given.slice(0, at).concat(given.slice(at + 2));
		if (args.contains(LANG_FLAG)) return { runs: [args], stdin: null };
		if (command is LanguageFree || languageFreeFor(command, args) || args.contains('--help') || args.contains('-h'))
			return preset == null ? { runs: [args], stdin: null } : named(preset, args);
		final files: Array<Int> = fileArguments(args, command);
		final ofFiles: Array<String> = [];
		final scopes: Array<String> = [];
		// A `-`-led positional is stdin or a short option.
		for (i in files) if (!args[i].startsWith(STDIN_POSITIONAL)) {
			final lang: Null<String> = CliArgs.langOfFile(args[i]);
			if (lang == null)
				scopes.push(args[i]);
			else if (!ofFiles.contains(lang))
				ofFiles.push(lang);
		}
		// Under a preset a mixed set reads as the preset's grammar, as it did before the preset yielded to extensions.
		if (ofFiles.length > 1 && preset == null) return perLanguage(ofFiles, args, files, command);
		if (ofFiles.length == 1) return named(ofFiles[0], args);
		// A preset is a default, not an override: a file another grammar's extension names is read by that grammar.
		if (preset != null) return named(preset, args);
		return byProject(args, command, files, scopes, readStdin, LanguageDeclaration.near(scopes.find(FileSystem.exists) ?? base));
	}

	/**
	 * The indices of the positionals of `args` that can name a file: by the command's own flag spec, so never a flag's
	 * value, and for a `LeadingQuery` command only the scope side of `CliArgs.routePositional`, so never the text it
	 * searches for, and for a `LeadingQueryCount` command none of the positionals its argv counts as text.
	 */
	private static function fileArguments(args: Array<String>, command: CliCommand): Array<Int> {
		final positionals: Array<Int> = command.flags().positionals(args);
		if (command is LeadingQueryCount) {
			final texts: Int = cast(command, LeadingQueryCount).leadingQueryCount(args);
			return [for (n => i in positionals) if (n >= texts) i];
		}
		if (!(command is LeadingQuery)) return positionals;
		final separator: Int = CliArgs.nameSeparatorIndex(args);
		final queries: Array<String> = [];
		final scope: Array<String> = [];
		final out: Array<Int> = [];
		for (i in positionals) {
			final before: Int = scope.length;
			CliArgs.routePositional(args[i], i, separator, queries, scope);
			if (scope.length > before) out.push(i);
		}
		return out;
	}

	/**
	 * The call run once per grammar of `langs`, each run without the file arguments another grammar's extension names
	 * and, when the scopes were walked (`held`: each grammar's scopes that hold its files), without the scopes that hold
	 * files of other grammars only; a `PatternQuery` runs only for the grammars its query parses in. Refused when the
	 * call asks for a JSON document, which several runs would print as several.
	 */
	private static function perLanguage(
		langs: Array<String>, args: Array<String>, files: Array<Int>, command: CliCommand, ?held: Map<String, Array<String>>
	): LanguageChoiceResult {
		final reading: Array<String> = command is PatternQuery
			? langs.filter(lang -> cast(command, PatternQuery).queryParsesIn(args, CliArgs.pickPlugin(lang)))
			: langs;
		if (reading.length == 0)
			throw new UsageFailure('the query parses in none of the grammars tried (${langs.join(', ')}) — pass --lang <name>');
		if (reading.length == 1) return named(reading[0], args);
		if (asksForJson(args))
			throw new UsageFailure(
				'the files are of several languages (${reading.join(', ')}) and a JSON report is one document — pass --lang <name>'
			);
		return { runs: reading.map(lang -> [LANG_FLAG, lang].concat(ownFiles(lang, args, files, held))), stdin: null };
	}

	/** `args` without the file arguments (`files`, indices) that are not `lang`'s own (`owns`). */
	private static function ownFiles(
		lang: String, args: Array<String>, files: Array<Int>, held: Null<Map<String, Array<String>>>
	): Array<String> {
		return [for (i => arg in args) if (!files.contains(i) || owns(lang, arg, held)) arg];
	}

	/**
	 * Whether the run of `lang` reads file argument `arg`: one whose extension names a grammar only when it is `lang`; a
	 * walked scope (`held`) only when it holds files of `lang` or of no grammar walked, so its "matched no files" warning
	 * is said by every run rather than by none.
	 */
	private static function owns(lang: String, arg: String, held: Null<Map<String, Array<String>>>): Bool {
		final named: Null<String> = CliArgs.langOfFile(arg);
		if (named != null) return named == lang;
		if (held == null || (held[lang] ?? []).contains(arg)) return true;
		return held.foreach(scopes -> !(scopes.contains(arg)));
	}

	/** Whether `args` asks for a JSON document: `--json`, or `--format json`. */
	private static function asksForJson(args: Array<String>): Bool {
		final format: Int = args.indexOf(FORMAT_FLAG);
		return args.contains(JSON_SWITCH) || (format >= 0 && format + 1 < args.length && args[format + 1] == JSON_FORMAT);
	}

	/** `args` led by `--lang <lang>`, one run, with no stdin read. */
	private static function named(lang: String, args: Array<String>): LanguageChoiceResult {
		return { runs: [[LANG_FLAG, lang].concat(args)], stdin: null };
	}

	/** The grammar `--lang-default` names at `at` (`-1`: none); throws `UsageFailure` when the flag ends the argv. */
	private static function presetAt(given: Array<String>, at: Int): Null<String> {
		if (at < 0) return null;
		if (at + 1 >= given.length) throw new UsageFailure('$PRESET_FLAG needs a language name');
		return given[at + 1];
	}

	/** Every registered `--lang` with its extensions, for a usage error: `haxe .hx, json .json`. */
	private static function known(): String {
		return CliArgs.grammars().map(entry -> '${entry.lang} ${entry.extensions.join(' ')}').join(', ');
	}

	/** Whether `command` declares this very call language-free (`LanguageFreeWhen`). */
	private static function languageFreeFor(command: CliCommand, args: Array<String>): Bool {
		return command is LanguageFreeWhen && cast(command, LanguageFreeWhen).languageFreeFor(args);
	}

	/**
	 * The runs of a call whose file arguments name no grammar, by what `project` declares: a stdin document by the project's
	 * `lang`, else by its content; the other arguments (`scopes`) by the project's `languages` that have files under them;
	 * else the project's `lang`.
	 */
	private static function byProject(
		args: Array<String>, command: CliCommand, files: Array<Int>, scopes: Array<String>, readStdin: () -> String,
		project: ProjectLanguages
	): LanguageChoiceResult {
		if (command is StdinDocument && (args.contains(STDIN_POSITIONAL) || args.contains(STDIN_FLAG))) {
			final text: String = readStdin();
			final lang: String = project.lang ?? CliArgs.langOfContent(text) ?? throw new UsageFailure(
				'stdin is not recognisably any registered language — pass --lang <name> (${known()})'
			);
			return { runs: [[LANG_FLAG, lang].concat(args)], stdin: text };
		}
		final held: Map<String, Array<String>> = [
			for (lang in project.languages) lang => scopes.filter(scope -> CliArgs.expandFor(lang, [scope]).paths.length > 0)
		];
		final walked: Array<String> = project.languages.filter(lang -> (held[lang] ?? []).length > 0);
		if (walked.length > 1) return perLanguage(walked, args, files, command, held);
		if (walked.length == 1) return named(walked[0], args);
		final lang: Null<String> = project.lang;
		if (lang != null) return named(lang, args);
		throw new UsageFailure('no argument names a file of a known language — pass --lang <name> (${known()})');
	}

}

/** What `LanguageChoice.choose` answers: the argv of each run, one per grammar the call reads, and stdin if it was read to decide. */
typedef LanguageChoiceResult = {
	final runs: Array<Array<String>>;
	final stdin: Null<String>;
};
