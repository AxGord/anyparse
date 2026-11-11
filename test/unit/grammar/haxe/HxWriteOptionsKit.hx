package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigDiagnostics;
import anyparse.grammar.haxe.HaxeFormatConfigIssues;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * The one answer to "how does a test hand the writer typed `HxModuleWriteOptions` instead of a hxformat.json string, and how does a
 * JSON-driven test refuse a key the loader would ignore".
 *
 * A typed edit starts from a baseline and the baseline is a choice, because the two differ: `forkWith` starts from what a config
 * document starts from, `HaxeFormatConfigLoader.loadHxFormatJson('{}')`, which re-baselines the six body policies, the curly blanks and the
 * comprehension padding to the fork's values; `rawWith` starts from the compiled `defaultWriteOptions`. A test names the baseline it
 * was written against. `strictJson` keeps a test on JSON and fails it when the document names a setting the loader would not act on.
 */
@:nullSafety(Strict)
final class HxWriteOptionsKit {

	/** The options a hxformat.json document without settings loads, after `edit` changed them: the baseline every JSON-driven test has. */
	public static function forkWith(edit: HxModuleWriteOptions -> Void): HxModuleWriteOptions {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		edit(opts);
		return opts;
	}

	/** The compiled `HaxeFormat` defaults, after `edit` changed them: no config re-baselining applied. */
	public static function rawWith(edit: HxModuleWriteOptions -> Void): HxModuleWriteOptions {
		final opts: HxModuleWriteOptions = new HxModuleWriteOptions(HaxeFormat.instance.defaultWriteOptions);
		edit(opts);
		return opts;
	}

	/**
	 * `HaxeFormatConfigLoader.loadHxFormatJson(json)`, refused with every setting `HaxeFormatConfigDiagnostics.diagnose` reports as
	 * not acted on: a key with no schema field, a wrap string with no runtime mapping, an unsupported `keep`, an unreadable value.
	 * A document that does not parse fails in the loader itself.
	 */
	public static function strictJson(json: String): HxModuleWriteOptions {
		final issues: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose(json);
		final ignored: Array<String> = HaxeFormatConfigDiagnostics.ignored(issues);
		if (ignored.length > 0) throw 'hxformat.json settings the loader does not act on: ${ignored.join('; ')}';
		return HaxeFormatConfigLoader.loadHxFormatJson(json);
	}

}
