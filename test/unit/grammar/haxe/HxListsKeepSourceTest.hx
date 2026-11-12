package unit.grammar.haxe;

import anyparse.format.OptionsSource;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HxListsKeepSource;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.macro.OptionKnobs;
import utest.Assert;
import utest.Test;

/**
 * `HxListsKeepSource` — the document form `of` and the typed form `keep` of the one addition a `listsKeepSource` wrapper makes.
 */
final class HxListsKeepSourceTest extends Test {

	@:pin('control')
	@:killer('M-LISTS-KEEP-SOURCE-KEEP-ANON')
	public function testKeepGivesTheOptionsTheWrappedDocumentLoads(): Void {
		final kept: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		HxListsKeepSource.keep(kept);
		Assert.isTrue(same(kept, HaxeFormatConfigLoader.loadHxFormatJson(HxListsKeepSource.of('{}'))));
		Assert.isFalse(same(kept, HaxeFormatConfigLoader.loadHxFormatJson('{}')));
	}

	private static function same(a: HxModuleWriteOptions, b: HxModuleWriteOptions): Bool {
		return OptionsSource.changes(OptionKnobs.of(HxModuleWriteOptions), a, b, []).length == 0;
	}

}
