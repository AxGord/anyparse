package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrapRules;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-methodchain-wraprules-capability — capability/parity unit tests for
 * the `methodChainWrap` `WrapRules` cascade.
 *
 *  - default cascade matches the 6-rule shape ported from
 *    `default-hxformat.json`'s `wrapping.methodChain` (including
 *    upstream's leading `lineLength >= 160` rule — adopted in
 *    ω-chain-itemlen-bg-defer once `chainItemLength` was aligned
 *    with `fitsFlat`'s `BodyGroup` deferral; see
 *    `HaxeFormat.defaultMethodChainWrap` doc);
 *  - `wrapping.methodChain.defaultWrap` + `rules:[]` flip the cascade's
 *    `defaultMode` and reset the rules array (slice ω-peg-byname-array
 *    lifted the rules-ingest limitation; full rule round-trip coverage
 *    lives in `HxWrapRulesIngestTest`);
 *  - empty `{}` config returns the seeded defaults — sanity gate that
 *    `loadHxFormatJson`'s base struct copy carried the new field.
 */
@:nullSafety(Strict)
class HxMethodChainWrapCapabilityTest extends Test {

	public function new(): Void {
		super();
	}

	public function testDefaultCascadeShape(): Void {
		final defaults: HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		final wrap: WrapRules = defaults.methodChainWrap;
		Assert.equals(WrapMode.NoWrap, wrap.defaultMode);
		Assert.equals(6, wrap.rules.length);
	}

	public function testJsonDefaultWrapOverridesDefaultMode(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"methodChain":{"defaultWrap":"onePerLine","rules":[]}}}'
		);
		Assert.equals(WrapMode.OnePerLine, opts.methodChainWrap.defaultMode);
		Assert.equals(0, opts.methodChainWrap.rules.length);
	}

	public function testEmptyJsonKeepsSeededDefaults(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(WrapMode.NoWrap, opts.methodChainWrap.defaultMode);
		Assert.equals(6, opts.methodChainWrap.rules.length);
	}

}
