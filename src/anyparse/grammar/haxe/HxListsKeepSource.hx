package anyparse.grammar.haxe;

import anyparse.grammar.json.JEntry;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueWriter;
import haxe.Exception;

using Lambda;

/**
 * The one answer to "which hxformat.json document is a document under `listsKeepSource`, and what is it as typed options":
 * `of(document)` is the document with every list that would otherwise reflow by width on a `onePerLine` fallback, which keeps
 * a source break in an array or map literal (an object literal or anonymous type follows the cascade, an explicit `noWrap` keeps
 * none), and `keep(options)` is the same addition on typed options. A test fixture
 * applies `of` to the document it loads, and the typed-options rewrite reads a constant document through it and emits `keep`.
 */
@:nullSafety(Strict)
final class HxListsKeepSource {

	/** The `wrapping` sections whose list wraps by width unless told to keep the source break. */
	private static final SECTIONS: Array<String> = ['objectLiteral', 'arrayWrap', 'mapWrap', 'anonType'];

	/** `configJson` with `defaultWrap: onePerLine` added to each of the list sections that does not name one. */
	public static function of(configJson: String): String {
		final config: JValue = JValueParser.parse(configJson);
		final wrapping: Array<JEntry> = objectAt(entriesOf(config), 'wrapping');
		for (key in SECTIONS) {
			final section: Array<JEntry> = objectAt(wrapping, key);
			if (!section.exists(entry -> (entry.key: String) == 'defaultWrap'))
				section.push({ key: 'defaultWrap', value: JString('onePerLine') });
		}
		return JValueWriter.write(config);
	}

	/**
	 * `options` with the list wraps `of` adds, set to what a document under `of` loads to: the typed counterpart of the wrapper, so a call
	 * site keeps the intent ("the defaults, with a `onePerLine` fallback") instead of a frozen copy of today's rule tables.
	 */
	public static function keep(options: HxModuleWriteOptions): Void {
		final wrapped: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(of('{}'));
		options.objectLiteralWrap = wrapped.objectLiteralWrap;
		options.arrayLiteralWrap = wrapped.arrayLiteralWrap;
		options.mapLiteralWrap = wrapped.mapLiteralWrap;
		options.anonTypeWrap = wrapped.anonTypeWrap;
	}

	private static function entriesOf(value: JValue): Array<JEntry> {
		return switch value {
			case JObject(entries): entries;
			case _: throw new Exception('a config document is an object');
		};
	}

	private static function objectAt(entries: Array<JEntry>, key: String): Array<JEntry> {
		final found: Null<JEntry> = entries.find(entry -> (entry.key: String) == key);
		if (found != null) return entriesOf(found.value);
		final fresh: Array<JEntry> = [];
		entries.push({ key: key, value: JObject(fresh) });
		return fresh;
	}

}
