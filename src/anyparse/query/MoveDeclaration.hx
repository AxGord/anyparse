package anyparse.query;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import anyparse.query.DeclaredSortedLists.SortedListPart;
import anyparse.query.ModuleMove.TestMirror;
import anyparse.query.TypePathRegistries.TypePathRegistry;
import haxe.Exception;
import haxe.ds.Either;
import haxe.io.Path;

using Lambda;

/**
 * What a project declares to `move` about itself, every path resolved against the declaring config's directory:
 *
 *  - `scope` — the source roots a relocation reads and rewrites (the default for `--scope`);
 *  - `text` / `textExclude` / `textExtensions` — the non-module files whose spellings of a module path follow it
 *    (a listed FILE is read whatever its extension; a listed directory contributes its files with one of the extensions);
 *  - `registries` — data files holding type paths at declared keys (`TypePathRegistries`);
 *  - `sortedLists` — lists of string literals kept sorted, each a sequence of parts (`DeclaredSortedLists`);
 *  - `mirrors` — where a module's tests live, so they relocate with it (`ModuleMove.TestMirror`).
 */
typedef MoveDeclarationData = {
	final scope: Array<String>;
	final text: Array<String>;
	final textExclude: Array<String>;
	final textExtensions: Array<String>;
	final registries: Array<TypePathRegistry>;
	final sortedLists: Array<Array<SortedListPart>>;
	final mirrors: Array<TestMirror>;
}

/**
 * The `move` section of a project config (`apq.json`) — the declaration that tells a module relocation which other
 * files spell module paths and how. STRICT, unlike the lint keys: a relocation that silently lost a registry would rewrite
 * the code and leave the registry naming modules that no longer exist, so any malformed entry refuses the whole section.
 */
@:nullSafety(Strict)
final class MoveDeclaration {

	/** The section's own name in the config document. */
	public static inline final KEY: String = 'move';

	/** A declaration with nothing declared. */
	public static function empty(): MoveDeclarationData {
		return {
			scope: [],
			text: [],
			textExclude: [],
			textExtensions: [],
			registries: [],
			sortedLists: [],
			mirrors: []
		};
	}

	/**
	 * The `move` section of the config `json` (null when the document has none), every path resolved against `baseDir`;
	 * `Left` names the first malformed entry.
	 */
	public static function read(json: String, baseDir: String): Either<String, Null<MoveDeclarationData>> {
		final root: JValue = try JValueParser.parse(json) catch (exception: Exception) return Left('not JSON: ${exception.message}');
		final section: Null<JValue> = JValueTools.field(root, KEY);
		if (section == null) return Right(null);
		switch section {
			case JObject(_):
			case _:
				return Left('"$KEY" is not an object');
		}
		final at: (String) -> String = p -> Path.isAbsolute(p) ? Path.normalize(p) : Path.normalize(Path.join([baseDir, p]));
		final unknown: Null<String> = unknownKey(section, KEY, [
			'scope',
			'text',
			'textExclude',
			'textExtensions',
			'registries',
			'sortedLists',
			'mirrors'
		]);
		if (unknown != null) return Left(unknown);
		return try Right({
			scope: strings(section, 'scope').map(at),
			text: strings(section, 'text').map(at),
			textExclude: strings(section, 'textExclude').map(at),
			textExtensions: strings(section, 'textExtensions'),
			registries: [
				for (r in objects(section, 'registries', ['file', 'keys', 'byPackage'])) registry(r, at)
			],
			sortedLists: [
				for (list in objects(section, 'sortedLists', ['parts'])) [
					for (part in objects(list, 'parts', ['file', 'select']))
						{
							file: at(string(part, 'sortedLists.parts', 'file')),
							select: string(part, 'sortedLists.parts', 'select')
						}
				]
			],
			mirrors: [
				for (m in objects(section, 'mirrors', ['source', 'test', 'suffixes']))
					{
						source: at(string(m, 'mirrors', 'source')),
						test: at(string(m, 'mirrors', 'test')),
						suffixes: strings(m, 'suffixes')
					}
			]
		}) catch (exception: Exception) Left(exception.message);
	}

	/** The string array at `key` of `node` (empty when absent); throws naming the key when it is anything else. */
	private static function strings(node: Null<JValue>, key: String): Array<String> {
		return switch JValueTools.field(node, key) {
			case null:
				[];
			case JArray(items):
				[
					for (item in items) switch item {
						case JString(text): text;
						case _: throw new Exception('"$KEY.$key" holds a non-string');
					}
				];
			case _:
				throw new Exception('"$KEY.$key" is not an array of strings');
		};
	}

	/**
	 * The object array at `key` of `node` (empty when absent), each object carrying only `allowed` keys; throws naming the
	 * key when it is anything else.
	 */
	private static function objects(node: Null<JValue>, key: String, allowed: Array<String>): Array<JValue> {
		final items: Array<JValue> = switch JValueTools.field(node, key) {
			case null: [];
			case JArray(held): held;
			case _: throw new Exception('"$KEY.$key" is not an array of objects');
		};
		for (item in items) switch item {
			case JObject(_):
				final unknown: Null<String> = unknownKey(item, '$KEY.$key', allowed);
				if (unknown != null) throw new Exception(unknown);
			case _:
				throw new Exception('"$KEY.$key" holds a non-object');
		}
		return items;
	}

	/** The required string `key` of an entry of `owner`; throws naming both when it is missing or not a string. */
	private static function string(node: JValue, owner: String, key: String): String {
		return switch JValueTools.field(node, key) {
			case JString(text): text;
			case _: throw new Exception('an entry of "$KEY.$owner" has no string "$key"');
		};
	}

	/** The diagnostic for the first key of `node` outside `allowed` (`label` naming where it sits), or null when there is none. */
	private static function unknownKey(node: JValue, label: String, allowed: Array<String>): Null<String> {
		return switch node {
			case JObject(entries):
				for (entry in entries) if (!allowed.contains(entry.key))
					return '"$label" declares unknown key "${entry.key}" (known: ${allowed.join(', ')})';
				null;
			case _:
				null;
		};
	}

	/** One `registries` entry; a `byPackage` one names the array and the type field of its records by a two-segment key. */
	private static function registry(entry: JValue, at: (String) -> String): TypePathRegistry {
		final keys: Array<String> = strings(entry, 'keys');
		final byPackage: Bool = switch JValueTools.field(entry, 'byPackage') {
			case JBool(true): true;
			case _: false;
		};
		if (byPackage && !keys.exists(k -> k.split('.').length == 2))
			throw new Exception('"$KEY.registries" marks "byPackage" a registry with no key of the form "<array>.<field>"');
		return { file: at(string(entry, 'registries', 'file')), keys: keys, byPackage: byPackage };
	}

}
