package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Slice D12 — `opt.keepSourceBlankAcrossConditional` opt-in knob.
 *
 * Default `false` keeps fork-compatible behaviour: head/tail-transparency
 * on `Conditional` resolves the inner first/last leaf for kind matching,
 * and `betweenImports=0` overrides any source blank between
 * `(prevImport, #if … import B; #end)` to 0.
 *
 * Opt-in `true` widens the between-rule emit to `max(opt.betweenImports, 1)`
 * when the current item carries a source blank, so a real blank survives
 * the transparency override.
 */
@:nullSafety(Strict)
class HxConditionalSourceBlankSliceTest extends Test {

	public function new():Void {
		super();
	}

	public function testDefaultIsFalse():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.isFalse(defaults.keepSourceBlankAcrossConditional);
	}

	public function testDefaultDropsSourceBlankBeforeConditional():Void {
		final out:String = writeWith('import a.B;\n\n#if sys\nimport sys.FileSystem;\n#end', false);
		Assert.isFalse(
			out.indexOf('B;\n\n#if') >= 0,
			'default knob=false: head-transparency + betweenImports=0 drops the source blank before #if'
		);
		Assert.isTrue(
			out.indexOf('B;\n#if') >= 0,
			'tight emit between import and #if when knob is off'
		);
	}

	public function testOptInPreservesSourceBlankBeforeConditional():Void {
		final out:String = writeWith('import a.B;\n\n#if sys\nimport sys.FileSystem;\n#end', true);
		Assert.isTrue(
			out.indexOf('B;\n\n#if') >= 0,
			'knob=true: source blank between import and #if survives the transparency override'
		);
	}

	public function testOptInDoesNotInsertBlankWhenSourceHasNone():Void {
		final out:String = writeWith('import a.B;\n#if sys\nimport sys.FileSystem;\n#end', true);
		Assert.isFalse(
			out.indexOf('B;\n\n#if') >= 0,
			'knob=true is preservation-only — does NOT synthesise a blank where source had none'
		);
	}

	public function testConfigLoaderParsesKnob():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"importAndUsing": {"keepSourceBlankAcrossConditional": true}}}'
		);
		Assert.isTrue(opts.keepSourceBlankAcrossConditional);
	}

	public function testConfigLoaderMissingKeyKeepsDefaultFalse():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"importAndUsing": {"beforeUsing": 2}}}'
		);
		Assert.isFalse(opts.keepSourceBlankAcrossConditional);
	}

	private inline function writeWith(src:String, keepBlank:Bool):String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(keepBlank));
	}

	private inline function makeOpts(keepBlank:Bool):HxModuleWriteOptions {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.keepSourceBlankAcrossConditional = keepBlank;
		opts.maxConsecutiveBlanks = -1;
		return opts;
	}
}
