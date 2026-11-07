package anyparse.query.cli;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import anyparse.query.ConfigFinder;
import sys.FileSystem;

/** What a project config declares about its languages. */
typedef ProjectLanguages = {

	/** The grammars a directory walk takes: every registered one when no config declares `languages`. */
	final languages: Array<String>;

	/** The grammar of a call no file names (stdin, a template), or null when no config declares `lang`. */
	final lang: Null<String>;

};

/**
 * The one answer to "which languages does the project's `apq.json` declare": `languages` and `lang`, each from the
 * nearest document of the chain declaring it, read per call (no cache, invariant 1 in `docs/design-principles.md`).
 * `LanguageChoice` asks it when the file arguments of a call name no grammar.
 */
@:nullSafety(Strict)
final class LanguageDeclaration {

	/** The project key naming the grammars a directory walk takes. */
	private static inline final LANGUAGES_KEY: String = 'languages';

	/** The project key naming the grammar of a call no file names. */
	private static inline final LANG_KEY: String = 'lang';

	/**
	 * What the `apq.json` chain above `path` (a file, or a directory the walk enters) declares. A document that is not
	 * JSON is left to the readers that report it; a value naming no registered grammar is a usage error naming its file.
	 */
	public static function near(path: String): ProjectLanguages {
		var languages: Null<Array<String>> = null;
		var lang: Null<String> = null;
		// The walk starts in the directory holding its path, so a directory is entered through a name inside it.
		final from: String = FileSystem.isDirectory(path) ? '$path/${ConfigFinder.PROJECT_CONFIG}' : path;
		for (doc in ConfigFinder.findUpProject(from, ConfigFinder.PROJECT_ROOT_MARKERS).documents) {
			final root: Null<JValue> = try JValueParser.parse(doc.content) catch (exception: Exception) null;
			if (root == null) continue;
			languages ??= namesAt(root, doc.path);
			lang ??= nameAt(root, doc.path);
		}
		return { languages: languages ?? CliArgs.grammars().map(entry -> entry.lang), lang: lang };
	}

	/** The grammar names `root` declares under `languages`, or null when it declares none. */
	private static function namesAt(root: JValue, path: String): Null<Array<String>> {
		return switch JValueTools.field(root, LANGUAGES_KEY) {
			case null: null;
			case JArray(items): [
				for (item in items)
					switch item {
						case JString(name): registered(name, LANGUAGES_KEY, path);
						case _: throw new UsageFailure('$path: "$LANGUAGES_KEY" holds a value that is not a language name');
					}
			];
			case _: throw new UsageFailure('$path: "$LANGUAGES_KEY" is not an array of language names');
		};
	}

	/** The grammar name `root` declares under `lang`, or null when it declares none. */
	private static function nameAt(root: JValue, path: String): Null<String> {
		return switch JValueTools.field(root, LANG_KEY) {
			case null: null;
			case JString(name): registered(name, LANG_KEY, path);
			case _: throw new UsageFailure('$path: "$LANG_KEY" is not a language name');
		};
	}

	/** `name` when a grammar registers it; a `UsageFailure` naming the config at `path` and its `key` otherwise. */
	private static function registered(name: String, key: String, path: String): String {
		final names: Array<String> = CliArgs.grammars().map(entry -> entry.lang);
		if (names.contains(name)) return name;
		throw new UsageFailure('$path: "$key" names "$name", which no grammar registers (${names.join(', ')})');
	}

}
