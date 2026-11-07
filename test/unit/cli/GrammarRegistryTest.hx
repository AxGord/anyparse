package unit.cli;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.json.JsonQueryPlugin;
import anyparse.grammar.mermaid.MermaidQueryPlugin;
import anyparse.query.cli.CliArgs;
import anyparse.query.merge.StructuralMerge.MergeShape;

/**
 * The CLI's grammar registry is what `GrammarDiscovery` finds on the classpath: the shipped plugins and, in the
 * suite's build, the test tree's own `StubQueryPlugin`, which no line of the CLI names.
 */
@:nullSafety(Strict)
class GrammarRegistryTest extends Test {

	/** Every `*QueryPlugin` on the suite's classpath is a row, in module-path order. */
	@:killer('M-GRAMMAR-DISCOVERY-NONE')
	@:pin('control')
	public function testEveryDiscoveredPluginIsARow(): Void {
		Assert.same([
			HaxeQueryPlugin.LANG,
			JsonQueryPlugin.LANG,
			MermaidQueryPlugin.LANG,
			StubQueryPlugin.LANG
		], CliArgs.grammars().map(entry -> entry.lang));
	}

	/** A plugin only the test tree declares is dispatched by every registry reader, from the statics it declares. */
	@:killer('M-GRAMMAR-DISCOVERY-NO-CONTENT-TEST')
	@:pin('control')
	public function testAPluginOutsideTheCliIsDispatched(): Void {
		Assert.equals(StubQueryPlugin.LANG, CliArgs.langOfFile('notes.STUBGRAMMAR'));
		Assert.equals(StubQueryPlugin.LANG, CliArgs.langOfContent('${StubQueryPlugin.SHEBANG}\n'));
		Assert.equals(StubQueryPlugin.LANG, CliArgs.pickPlugin(StubQueryPlugin.LANG).langName());
		final merge: MergeShape = CliArgs.mergeShapeOf(StubQueryPlugin.LANG);
		Assert.equals(Records, merge);
	}

}
