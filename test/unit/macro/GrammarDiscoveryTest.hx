package unit.macro;

import anyparse.macro.GrammarDiscovery;
import unit.cli.CliFixture;

/** `GrammarDiscovery.pluginModules`: which files under the classpath roots are grammar plugin modules, and in what order. */
@:nullSafety(Strict)
class GrammarDiscoveryTest extends Test {

	/**
	 * Only a `*QueryPlugin.hx` outside every dot-entry is a plugin module, named by its path under the root; a root
	 * given twice yields each module once, the result is sorted by module path, and an empty root is skipped.
	 */
	@:killer('M-GRAMMAR-DISCOVERY-DOT-ENTRIES')
	@:pin('control')
	public function testOnlyAVisibleQueryPluginFileIsAModule(): Void {
		final root: String = CliFixture.writeTree('grammar_discovery', [
			{ name: 'a/b/YQueryPlugin.hx', source: '' },
			{ name: '.hidden/XQueryPlugin.hx', source: '' },
			{ name: '.WQueryPlugin.hx', source: '' },
			{ name: 'c/ZQueryPluginTest.hx', source: '' },
			{ name: 'c/VQueryPlugin.txt', source: '' },
			{ name: 'AQueryPlugin.hx', source: '' }
		]);
		CliFixture.always(
			CliFixture.removeDir.bind(root),
			() -> Assert.same(['AQueryPlugin', 'a.b.YQueryPlugin'], GrammarDiscovery.pluginModules(['', root, root]))
		);
	}

}
