package anyparse.query;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import haxe.Exception;

/**
 * A data file a project declares to hold TYPE PATHS at some of its keys — a mutation-arm registry's `type`, a lint
 * config's owned types. `keys` are dotted key paths from the document root, arrays transparent (`arms.type` is the
 * `type` of every element of `arms`).
 */
typedef TypePathRegistry = {
	final file: String;
	final keys: Array<String>;

	/** The registry is a directory of documents named after the package of the types they hold (`PackageDocuments`). */
	@:optional final byPackage: Bool;
}

/** A relocated type: its qualified path before and after. */
typedef TypePathMove = {
	final oldPath: String;
	final newPath: String;
}

/**
 * The declared-registry half of a module relocation. A registry value that spells a relocated path is rewritten by the
 * same token rewrite as every other text (`ModulePathTokens`); what only the declaration can show is a value that names
 * types WITHOUT spelling one — a glob (`pkg.Mod*`) — whose match over a relocated type would flip, which no token rewrite
 * can repair and the relocation therefore refuses.
 */
@:nullSafety(Strict)
final class TypePathRegistries {

	/**
	 * One line per value of `registry` (whose text is `json`) that names a relocated type in one place and not in the
	 * other, or the reason the file cannot be read as JSON. Empty when the relocation keeps every glob's reach.
	 */
	public static function globRefusals(registry: TypePathRegistry, json: String, moved: Array<TypePathMove>): Array<String> {
		final root: JValue = try {
			JValueParser.parse(json);
		} catch (exception: Exception) {
			return ['declared type-path registry ${registry.file} is not JSON: ${exception.message}'];
		};
		final out: Array<String> = [];
		for (key in registry.keys) for (value in valuesAt(root, key.split('.'), 0)) if (isGlob(value)) {
			final re: EReg = Glob.qualifiedNames(value);
			for (m in moved) if (re.match(m.oldPath) != re.match(m.newPath))
				out.push(
					'${registry.file} "$key" holds the pattern "$value", which matches ${re.match(m.oldPath) ? m.oldPath : m.newPath}'
					+ ' but not ${re.match(m.oldPath) ? m.newPath : m.oldPath}'
					+ ' — the move changes what it names; narrow or widen it by hand first'
				);
		}
		return out;
	}

	/** Whether `value` carries a glob metacharacter. */
	private static inline function isGlob(value: String): Bool {
		return value.indexOf('*') >= 0 || value.indexOf('?') >= 0 || value.indexOf('[') >= 0;
	}

	/** Every string at `path[i..]` under `node`, arrays transparent. */
	private static function valuesAt(node: Null<JValue>, path: Array<String>, i: Int): Array<String> {
		return switch node {
			case JArray(items):
				[for (item in items) for (v in valuesAt(item, path, i)) v];
			case JString(text):
				i == path.length ? [text] : [];
			case JObject(_) if (i < path.length):
				valuesAt(JValueTools.field(node, path[i]), path, i + 1);
			case _:
				[];
		};
	}

}
