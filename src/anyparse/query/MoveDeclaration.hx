package anyparse.query;

import anyparse.query.DeclaredSortedLists.SortedListPart;
import anyparse.query.ModuleMove.TestMirror;
import anyparse.query.TypePathRegistries.TypePathRegistry;
import haxe.Exception;
import haxe.Json;
import haxe.ds.Either;
import haxe.io.Path;

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
 * The `move` section of a project config (`apqlint.json`) — the declaration that tells a module relocation which other
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
		final root: Dynamic = try Json.parse(json) catch (exception: Exception) return Left('not JSON: ${exception.message}');
		final section: Dynamic = Reflect.field(root, KEY);
		if (section == null) return Right(null);
		final at: (String) -> String = p -> Path.isAbsolute(p) ? Path.normalize(p) : Path.normalize(Path.join([baseDir, p]));
		return try Right({
			scope: strings(section, 'scope').map(at),
			text: strings(section, 'text').map(at),
			textExclude: strings(section, 'textExclude').map(at),
			textExtensions: strings(section, 'textExtensions'),
			registries: [
				for (r in objects(section, 'registries')) { file: at(string(r, 'registries', 'file')), keys: strings(r, 'keys') }
			],
			sortedLists: [
				for (list in objects(section, 'sortedLists')) [
					for (part in objects(list, 'parts'))
						{
							file: at(string(part, 'sortedLists.parts', 'file')),
							select: string(part, 'sortedLists.parts', 'select')
						}
				]
			],
			mirrors: [
				for (m in objects(section, 'mirrors'))
					{
						source: at(string(m, 'mirrors', 'source')),
						test: at(string(m, 'mirrors', 'test')),
						suffixes: strings(m, 'suffixes')
					}
			]
		}) catch (exception: Exception) Left(exception.message);
	}

	/** The string array at `key` of `node` (empty when absent); throws naming the key when it is anything else. */
	private static function strings(node: Dynamic, key: String): Array<String> {
		final value: Dynamic = Reflect.field(node, key);
		if (value == null) return [];
		if (!Std.isOfType(value, Array)) throw new Exception('"$KEY.$key" is not an array of strings');
		final items: Array<Dynamic> = value;
		return [
			for (item in items) Std.isOfType(item, String) ? (item: String) : throw new Exception('"$KEY.$key" holds a non-string')
		];
	}

	/** The object array at `key` of `node` (empty when absent); throws naming the key when it is anything else. */
	private static function objects(node: Dynamic, key: String): Array<Dynamic> {
		final value: Dynamic = Reflect.field(node, key);
		if (value == null) return [];
		if (!Std.isOfType(value, Array)) throw new Exception('"$KEY.$key" is not an array of objects');
		final items: Array<Dynamic> = value;
		for (item in items) if (item == null || !Reflect.isObject(item) || Std.isOfType(item, String) || Std.isOfType(item, Array))
			throw new Exception('"$KEY.$key" holds a non-object');
		return items;
	}

	/** The required string `key` of an entry of `owner`; throws naming both when it is missing or not a string. */
	private static function string(node: Dynamic, owner: String, key: String): String {
		final value: Dynamic = Reflect.field(node, key);
		if (!Std.isOfType(value, String)) throw new Exception('an entry of "$KEY.$owner" has no string "$key"');
		return value;
	}

}
