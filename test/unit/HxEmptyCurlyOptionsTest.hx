package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BracePlacement;
import anyparse.format.EmptyCurly;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-empty-curly-break — empty class / function bodies break to two
 * lines (`{\n}`) when `opt.emptyCurly == EmptyCurly.Break`. Drives
 * haxe-formatter's `lineEnds.emptyCurly: noBreak|break` knob via the
 * `@:fmt(emptyCurlyBreak)` flag on body Stars.
 *
 * Default `Same` keeps empty bodies flat — no regression on the bulk
 * of the corpus.
 */
@:nullSafety(Strict)
class HxEmptyCurlyOptionsTest extends Test {

	public function new(): Void {
		super();
	}

	public function testDefaultMatchesUpstream(): Void {
		final defaults: HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(EmptyCurly.Same, defaults.emptyCurly);
	}

	public function testSameKeepsEmptyClassFlat(): Void {
		final out: String = writeWith('class Main {}', EmptyCurly.Same);
		Assert.equals('class Main {}\n', out);
	}

	public function testBreakExpandsEmptyClass(): Void {
		final out: String = writeWith('class Main {}', EmptyCurly.Break);
		Assert.equals('class Main {\n}\n', out);
	}

	public function testBreakExpandsEmptyFnBody(): Void {
		final out: String = writeWith('class Main {\n\tfunction f() {}\n}', EmptyCurly.Break);
		Assert.equals('class Main {\n\tfunction f() {\n\t}\n}\n', out);
	}

	public function testBreakWithLeftCurlyNext(): Void {
		final opts: HxModuleWriteOptions = makeOpts(EmptyCurly.Break);
		opts.leftCurly = BracePlacement.Next;
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse('class Main {}'), opts);
		Assert.equals('class Main\n{\n}\n', out);
	}

	public function testConfigLoaderMapsBreak(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"emptyCurly": "break"}}');
		Assert.equals(EmptyCurly.Break, opts.emptyCurly);
	}

	public function testConfigLoaderMapsNoBreak(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"emptyCurly": "noBreak"}}');
		Assert.equals(EmptyCurly.Same, opts.emptyCurly);
	}

	public function testConfigLoaderMissingKeepsDefault(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(EmptyCurly.Same, opts.emptyCurly);
	}

	public function testBlockEmptyCurlyDefaultMatchesUpstream(): Void {
		final defaults: HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(EmptyCurly.Same, defaults.blockEmptyCurly);
	}

	public function testGlobalEmptyCurlyCascadesIntoBlockEmptyCurly(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"emptyCurly": "break"}}');
		Assert.equals(EmptyCurly.Break, opts.blockEmptyCurly);
	}

	public function testBlockCurlySubKeyOverridesGlobalForBlockEmptyCurly(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"lineEnds": {"emptyCurly": "break", "blockCurly": {"emptyCurly": "noBreak"}}}'
		);
		Assert.equals(EmptyCurly.Break, opts.emptyCurly);
		Assert.equals(EmptyCurly.Same, opts.blockEmptyCurly);
	}

	public function testBlockCurlySubKeyAloneSetsBlockEmptyCurly(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"blockCurly": {"emptyCurly": "break"}}}');
		Assert.equals(EmptyCurly.Same, opts.emptyCurly);
		Assert.equals(EmptyCurly.Break, opts.blockEmptyCurly);
	}

	public function testBreakExpandsEmptyBlockStmt(): Void {
		final src: String = 'class Main {\n\tstatic function f() {\n\t\tif (true) {}\n\t}\n}';
		final expected: String = 'class Main {\n\tstatic function f() {\n\t\tif (true) {\n\t\t}\n\t}\n}\n';
		final opts: HxModuleWriteOptions = makeOpts(EmptyCurly.Same);
		opts.blockEmptyCurly = EmptyCurly.Break;
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts));
	}

	public function testBreakExpandsEmptySwitchCases(): Void {
		final src: String = 'class Main {\n\tstatic function f(e:Int) {\n\t\tswitch (e) {}\n\t}\n}';
		final expected: String = 'class Main {\n\tstatic function f(e:Int) {\n\t\tswitch (e) {\n\t\t}\n\t}\n}\n';
		final opts: HxModuleWriteOptions = makeOpts(EmptyCurly.Same);
		opts.blockEmptyCurly = EmptyCurly.Break;
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts));
	}

	public function testSameKeepsEmptyBlockStmtFlat(): Void {
		final src: String = 'class Main {\n\tstatic function f() {\n\t\tif (true) {}\n\t}\n}';
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(EmptyCurly.Same));
		Assert.isTrue(out.indexOf('if (true) {}') != -1, 'expected flat empty block in: <$out>');
	}

	private inline function writeWith(src: String, ec: EmptyCurly): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(ec));
	}

	private inline function makeOpts(ec: EmptyCurly): HxModuleWriteOptions {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.emptyCurly = ec;
		// Mirror the loader's `lineEnds.emptyCurly` cascade for per-construct
		// EmptyCurly knobs that no longer fall back to the global at the
		// emit site. `blockEmptyCurly` (ω-blockempty) — driven by
		// `HxStatement.BlockStmt`, `HxExpr.BlockExpr`, `HxSwitchStmt.cases`,
		// `HxSwitchStmtBare.cases`. Add other per-construct EmptyCurly
		// siblings as their emit sites convert from bare-flag to knob-form.
		opts.blockEmptyCurly = ec;
		return opts;
	}

}
