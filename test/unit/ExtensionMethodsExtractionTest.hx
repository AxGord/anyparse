package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.StdResolver;
import utest.Assert;
import utest.Test;

/**
 * `HaxeQueryPlugin.knownExtensionMethods` now DERIVES the `using`-eligible extension
 * method names from the discovered std sources (any-visibility static `FnMember`
 * with a first param), falling back to the hardcoded `EXTENSION_METHODS` constant
 * when std is undiscovered. The extracted set must be a SUPERSET of that constant
 * (never drop a name a live `using` relies on) — asserted against the real constant
 * via `@:access`, so a shrunk extraction is caught. When std is present, extraction
 * also answers modules ABSENT from the constant (`DateTools`), proving it is the
 * live source rather than a pass-through of the table.
 */
class ExtensionMethodsExtractionTest extends Test {

	/** Every hardcoded `StringTools` name — including the PRIVATE statics — is still returned (superset, any-visibility). */
	@:access(anyparse.grammar.haxe.HaxeQueryPlugin)
	public function testStringToolsSuperset(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final got: Null<Array<String>> = plugin.knownExtensionMethods('StringTools');
		Assert.notNull(got, 'StringTools extension methods resolve (extraction or fallback)');
		final expected: Array<String> = HaxeQueryPlugin.EXTENSION_METHODS['StringTools'];
		if (got != null) for (name in expected)
			Assert.isTrue(got.contains(name), 'extraction is a superset — retains hardcoded StringTools.$name');
	}

	/** Every hardcoded `Lambda` name is still returned (superset). */
	@:access(anyparse.grammar.haxe.HaxeQueryPlugin)
	public function testLambdaSuperset(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final got: Null<Array<String>> = plugin.knownExtensionMethods('Lambda');
		Assert.notNull(got, 'Lambda extension methods resolve (extraction or fallback)');
		final expected: Array<String> = HaxeQueryPlugin.EXTENSION_METHODS['Lambda'];
		if (got != null) for (name in expected)
			Assert.isTrue(got.contains(name), 'extraction is a superset — retains hardcoded Lambda.$name');
	}

	/**
	 * A std module ABSENT from the hardcoded table: extraction answers it when std is
	 * discovered (proving the derivation is live), and the fallback returns null when
	 * std is absent (the table never knew it). `DateTools` is a stable `using` target
	 * with static `format` / `delta` helpers.
	 */
	public function testExtractionBeyondTable(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final got: Null<Array<String>> = plugin.knownExtensionMethods('DateTools');
		if (StdResolver.stdDir() == null) {
			Assert.isNull(got, 'std undiscovered — a non-tabled module falls back to null');
			return;
		}
		Assert.notNull(got, 'std discovered — DateTools extension methods are derived, not tabled');
		if (got != null) Assert.isTrue(got.contains('format'), 'DateTools.format is a derived using-eligible static');
	}

	/** A genuinely non-existent module resolves to null (no file to extract, not in the table). */
	public function testUnknownModuleIsNull(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.isNull(plugin.knownExtensionMethods('proj.NotARealModule'));
	}

}
