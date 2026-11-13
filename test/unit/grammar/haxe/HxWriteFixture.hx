package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxListsKeepSource;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;

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
	 * `src` parsed and re-emitted by the trivia writer under `config` (a hx-format document, or typed options from `HxWriteOptionsKit`),
	 * with `finalNewline` off so the expected text of a slice assertion needs no trailing newline. The caller's options are copied, so that
	 * switch never reaches them and one options object serves several writes.
	 */
	public static function triviaWrite(src: String, config: HxWriteConfig): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), withoutFinalNewline(config));
	}


	/**
	 * `src` parsed and re-emitted by the PLAIN writer (no trivia) under `config`, with
	 * `finalNewline` off for the same reason as `triviaWrite`. The plain writer captures no
	 * source-newline slots, so it is what a test asks when the question is the grammar's own
	 * shape gates rather than a formatting knob.
	 */
	public static function plainWrite(src: String, config: HxWriteConfig): String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), withoutFinalNewline(config));
	}

	/**
	 * `configJson` with every list that would otherwise reflow by width on a `onePerLine` fallback, which keeps a source
	 * break in an array or map literal (an object literal or anon type follows the cascade, an explicit `noWrap` keeps none):
	 * for a fixture whose subject is not how a list wraps.
	 */
	public static function listsKeepSource(configJson: String): String {
		return HxListsKeepSource.of(configJson);
	}

	/** The options `HaxeModuleTriviaWriter.write` defaults to, under `listsKeepSource`. */
	public static function listsKeepSourceOptions(): HxModuleWriteOptions {
		return HxWriteOptionsKit.strictJson(listsKeepSource('{}'));
	}

	private static function withoutFinalNewline(options: HxModuleWriteOptions): HxModuleWriteOptions {
		final opts: HxModuleWriteOptions = new HxModuleWriteOptions(options);
		opts.finalNewline = false;
		return opts;
	}

}
