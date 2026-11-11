package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * What a `HxWriteFixture` write takes as its configuration: a hxformat.json document, loaded as `HaxeFormatConfigLoader.loadHxFormatJson`
 * loads it, or typed `HxModuleWriteOptions` (`HxWriteOptionsKit`) used as given. Both convert implicitly, so a call site names neither.
 */
abstract HxWriteConfig(HxModuleWriteOptions) to HxModuleWriteOptions {

	private function new(options: HxModuleWriteOptions) {
		this = options;
	}

	@:from
	public static function ofJson(json: String): HxWriteConfig {
		return new HxWriteConfig(HaxeFormatConfigLoader.loadHxFormatJson(json));
	}

	@:from
	public static function ofOptions(options: HxModuleWriteOptions): HxWriteConfig {
		return new HxWriteConfig(options);
	}

}
