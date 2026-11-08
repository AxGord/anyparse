package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.json.JEntry;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueWriter;

using Lambda;

/**
 * Shared trivia-writer round-trip for the Haxe formatter slice tests.
 *
 * Every slice test asserts on `parse -> write` under some hx-format config; the
 * three moves that produce it (load the config, switch the trailing newline off so
 * an expected string need not carry one, write the parsed module) are the same
 * everywhere and only the config differs, so they live here once.
 */
@:nullSafety(Strict)
final class HxWriteFixture {

	// Force the Trivia-mode parser's @:build to complete before this module's bodies
	// reference the synth module types — the hook the slice tests carry, since
	// initialisation order between the marker class's build phase and a consumer is not
	// guaranteed without it.
	private static final forceBuild: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	/**
	 * `src` parsed and re-emitted by the trivia writer under the hx-format config
	 * `configJson`, with `finalNewline` off so the expected text of a slice assertion
	 * needs no trailing newline.
	 */
	public static function triviaWrite(src: String, configJson: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(configJson);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}


	/**
	 * `src` parsed and re-emitted by the PLAIN writer (no trivia) under `configJson`, with
	 * `finalNewline` off for the same reason as `triviaWrite`. The plain writer captures no
	 * source-newline slots, so it is what a test asks when the question is the grammar's own
	 * shape gates rather than a formatting knob.
	 */
	public static function plainWrite(src: String, configJson: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(configJson);
		opts.finalNewline = false;
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}

	/**
	 * `configJson` with every list that would otherwise reflow by width back on a `noWrap` fallback, whose cascade keeps a
	 * source break: for a fixture whose subject is not how a list wraps.
	 */
	public static function listsKeepSource(configJson: String): String {
		final config: JValue = JValueParser.parse(configJson);
		final wrapping: Array<JEntry> = objectAt(entriesOf(config), 'wrapping');
		for (key in ['objectLiteral', 'arrayWrap', 'mapWrap', 'anonType']) {
			final section: Array<JEntry> = objectAt(wrapping, key);
			if (!section.exists(entry -> (entry.key: String) == 'defaultWrap'))
				section.push({ key: 'defaultWrap', value: JString('noWrap') });
		}
		return JValueWriter.write(config);
	}

	/** The options `HaxeModuleTriviaWriter.write` defaults to, under `listsKeepSource`. */
	public static function listsKeepSourceOptions(): HxModuleWriteOptions {
		return HaxeFormatConfigLoader.loadHxFormatJson(listsKeepSource('{}'));
	}

	private static function entriesOf(value: JValue): Array<JEntry> {
		return switch value {
			case JObject(entries): entries;
			case _: throw 'a config document is an object';
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
