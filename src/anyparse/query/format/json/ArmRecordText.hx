package anyparse.query.format.json;

import anyparse.grammar.json.JEntry;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import anyparse.grammar.json.JsonNative;
import anyparse.grammar.json.JsonQueryPlugin;
import anyparse.runtime.Span;
import haxe.Exception;
import haxe.ds.Either;

using Lambda;

/**
 * The one answer to "what does the JSON text of a mutation-arm record say, and how does the registry spell it": the record
 * is checked for the shape a reader needs to find it (`name`, `type`, `method`, `note` and one cut) and laid out as the
 * registry lays out its records. What the build checks of a record (a cut that applies, a member that exists) stays the
 * build's: this class reads no source.
 *
 * The forwarder to the JSON grammar for `ArmRecords`, which names no grammar.
 */
@:nullSafety(Strict)
final class ArmRecordText {

	/** The member of a registry document that holds its records. */
	public static final ARRAY_KEY: String = 'arms';

	/** The keys of a record, in the order they are written. */
	private static final KEYS: Array<String> = ['name', 'type', 'method', 'kind', 'force', 'find', 'replace', 'note'];

	/** The keys a record cannot do without. */
	private static final REQUIRED: Array<String> = ['name', 'type', 'method', 'note'];

	private static final LIST_KEYS: Array<String> = ['find', 'replace'];

	/** The record spelled by `json`, laid out for the registry; Left names what is wrong with it. */
	public static function read(json: String): Either<String, ArmRecord> {
		final root: JValue = try
			JValueParser.parse(json)
		catch (exception: Exception)
			return Left('an arm is not JSON: ${exception.message}');
		final entries: Array<JEntry> = switch root {
			case JObject(held): held;
			case _: return Left('an arm is not a JSON object');
		}
		final unknown: Null<JEntry> = entries.find(e -> !KEYS.contains(e.key));
		if (unknown != null) return Left('an arm has the unknown key "${unknown.key}" (known: ${KEYS.join(', ')})');
		final named: Null<JValue> = JValueTools.field(root, 'name');
		if (named != null && JValueTools.string(named) == null) return Left('an arm: "name" is not a string');
		final name: String = JValueTools.string(named) ?? '';
		final at: String = name == '' ? 'an arm' : 'arm $name';
		for (key in REQUIRED) if ((JValueTools.stringAt(root, key) ?? '') == '') return Left('$at has no non-empty "$key"');
		final cutProblem: Null<String> = cutError(root, at);
		if (cutProblem != null) return Left(cutProblem);
		final fields: Array<String> = [];
		for (key in KEYS) {
			final value: Null<JValue> = JValueTools.field(root, key);
			if (value == null) continue;
			final spelled: Null<String> = spell(value, LIST_KEYS.contains(key));
			if (spelled == null) return Left('$at: "$key" is not a string${LIST_KEYS.contains(key) ? ' or a list of strings' : ''}');
			fields.push('"$key": $spelled');
		}
		return Right({ name: name, type: JValueTools.stringAt(root, 'type') ?? '', text: '{' + fields.join(', ') + '}' });
	}

	/**
	 * `source` with `record` (the text of one record) appended to the array of its records, laid out by the JSON layout
	 * writer in the document's own indent unit and sibling shape; Left names why the document cannot take it.
	 */
	public static function append(source: String, record: String): Either<String, String> {
		final plugin: GrammarPlugin = new JsonQueryPlugin();
		final tree: QueryNode = switch ParseGate.parse(plugin, source, 'the registry document') {
			case Unparsed(message): return Left('does not parse: $message');
			case Parsed(parsed): parsed;
		}
		final offset: Int = switch Address.resolve(tree, source, plugin, { select: 'Member:$ARRAY_KEY > JArray' }) {
			case Ok(at, _): at;
			case Err(message): return Left('has no "$ARRAY_KEY" array ($message)');
		}
		final position: Position = new Span(offset, offset).lineCol(source);
		return switch AddElement.appendElement(source, position.line, position.col, record, false, plugin) {
			case Ok(text, _): Right(text);
			case Err(message): Left(message);
		}
	}

	/** A value of a record as the registry spells it: a string, or a list of strings on one line. */
	private static function spell(value: JValue, listed: Bool): Null<String> {
		return switch value {
			case JString(_): JsonNative.quote(JValueTools.string(value) ?? '');
			case JArray(items) if (listed):
				final spelled: Array<Null<String>> = items.map(item -> spell(item, false));
				spelled.contains(null) ? null : '[' + spelled.join(', ') + ']';
			case _: null;
		}
	}

	/** What is wrong with the way the record `root` says what it cuts, null when nothing is. */
	private static function cutError(root: JValue, at: String): Null<String> {
		final force: Null<JValue> = JValueTools.field(root, 'force');
		final find: Null<JValue> = JValueTools.field(root, 'find');
		final replace: Null<JValue> = JValueTools.field(root, 'replace');
		if (force == null && find == null) return '$at declares neither "force" nor "find" — an arm has to say what it cuts';
		if (force != null && find != null) return '$at declares both "force" and "find" — an arm cuts one way';
		if (find != null && replace == null) return '$at declares "find" without "replace"';
		if (force != null && replace != null) return '$at declares "replace" without "find"';
		return null;
	}

}

/** A record checked and laid out: its name, the type it cuts and its text in the registry's layout, without its indent. */
typedef ArmRecord = { final name: String; final type: String; final text: String; }
