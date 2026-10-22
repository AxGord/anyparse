package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * A conditional-compilation region is one ELEMENT of the list it sits in, and the list separator
 * belongs wherever the source put it — INSIDE the region or outside. Get that wrong and the writer
 * emits a program the Haxe compiler rejects while this parser still accepts it, so the round-trip
 * gate never fires: `self-status`, `fmt --list` and `lint` all stay green.
 *
 * Two directions, one per list kind:
 *
 *  - metadata call arguments (`HxMetaCallArgs.args`) ADDED a comma after `#end` on top of the one
 *    the source wrote inside the region, so with the flag off the list read `(empty, , onTake)`;
 *  - function parameters (`HxConditionalParam.body`) DROPPED the comma written inside the region
 *    and emitted none outside either, so with the flag ON two parameters ran together.
 *
 * The fix is the same signal on both sides — per-element `sepAfter`, which only a `@:trivia` Star
 * captures — so the assertions here are about the SEPARATOR COUNT surviving, not about layout.
 */
class HxCondListSeparatorWriteTest extends Test {

	/** Every list one item per line with the trailing-comma knob on, the configuration that appended `,` after `#end`. */
	private static final TRAILING_ONE_PER_LINE: String = '{"wrapping": {"functionSignature": {"defaultWrap": "onePerLine", "rules": []}, '
		+ '"callParameter": {"defaultWrap": "onePerLine", "rules": []}, "anonType": {"defaultWrap": "fillLine", "rules": []}}, '
		+ '"trailingCommas": {"callArgumentDefault": "yes", "functionParameterDefault": "yes", "anonTypeDefault": "yes"}}';

	public inline function testMetaArgsKeepTheCommaOutsideTheRegionWhenTheSourceDoes(): Void {
		assertFixedPoint('@:forward(empty, #if flag changeEmpty #end, onTake)\nabstract A(Int) {}\n');
	}

	public inline function testMetaArgsWithNoRegionAreUnchanged(): Void {
		assertFixedPoint('@:forward(empty, onTake, onLost)\nabstract A(Int) {}\n');
	}

	public inline function testParamsKeepTheCommaOutsideTheRegionWhenTheSourceDoes(): Void {
		assertFixedPoint('class A {\n\tfunction f(a:Int, #if js b:String #end, c:Bool) {}\n}\n');
	}

	public inline function testParamsWithNoRegionAreUnchanged(): Void {
		assertFixedPoint('class A {\n\tfunction f(a:Int, b:Bool) {}\n}\n');
	}

	public function testMetaArgsKeepTheCommaInsideTheRegionAndAddNone(): Void {
		// The Pony shape (`pony.events.Event0`). The source's comma is the region's own, so with
		// `flag` off the list must read `empty, onTake, onLost` — one comma per gap, none stranded.
		final written: Null<String> =
			roundTrip('@:forward(\n\tempty,\n\t#if flag changeEmpty, #end\n\tonTake,\n\tonLost\n)\nabstract A(Int) {}\n');
		Assert.equals('@:forward(empty, #if flag changeEmpty, #end onTake, onLost)\nabstract A(Int) {}\n', written);
		Assert.isFalse((written ?? '').indexOf('#end,') >= 0, 'a comma after #end doubles the one inside the region');
	}

	public function testParamsKeepTheCommaInsideTheRegion(): Void {
		// `pony.heaps.HeapsApp`. Losing this comma only breaks under `-D js` — the one target most
		// builds never compile, which is why it survived a whole tree.
		final source: String = 'class A {\n\tpublic function new(?size:Int, #if js ?parentDom:String, #end sizeUpdate:Bool = true) {}\n}\n';
		Assert.stringContains('?parentDom:String, #end', roundTrip(source) ?? '');
	}

	@:pin('control')
	@:killer('M-COND-PARAM-ELSE-PLAIN')
	@:killer('M-ELIDED-SEP-KEPT')
	public function testParamsKeepTheCommaInsideTheElseRegion(): Void {
		// Without it the `#else` arm reads `baz:Int foobar:Int` — a program only the Haxe compiler rejects.
		assertFixedPoint('class A {\n\tstatic function foo(#if false bar:Int, #else baz:Int, #end foobar:Int) {}\n}\n');
	}

	@:pin('control')
	@:killer('M-ELIDED-GAP-HARD')
	@:killer('M-ELIDED-SEP-KEPT')
	public function testAnElidedOuterCommaAfterARegionIsNoLineBreak(): Void {
		// The comma the source put inside the region stands in for the outer one; the gap after `#end` is still a soft
		// gap, so a list that fits stays on its line.
		assertFixedPoint('class A {\n\tfunction f(#if false ?bar:Int, #end ?foobar:Int) {}\n}\n');
	}

	@:pin('control')
	@:killer('M-REGION-GLUED')
	@:killer('M-ELIDED-SEP-KEPT')
	public function testParamsUnderLeadingBreakFillGainNoComma(): Void {
		// `fillLineWithLeadingBreak` packed the list with one uniform separator, so a comma the source wrote inside
		// a region came back doubled outside it — `a:Bool = false, , b:Int` once `air` is defined.
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping": {"functionSignature": {"defaultWrap": "fillLineWithLeadingBreak", "rules": []}}}'
		);
		final source: String = 'class A {\n\tfunction f(a:Bool = false\n\t\t#if air, b:Int #end) {}\n\n'
			+ '\tfunction g(#if x c:Int, #else d:Int, #end e:Int) {}\n}\n';
		// The region keeps its own line: glued after `false` it would re-parse as a splice tail of the default value.
		final expected: String = 'class A {\n\tfunction f(\n\t\ta:Bool = false\n\t\t#if air, b:Int #end\n\t) {}\n\n\tfunction g(\n'
			+ '\t\t#if x c:Int, #else d:Int, #end e:Int\n\t) {}\n}\n';
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts));
	}

	@:pin('control')
	@:killer('M-COND-PARAM-ELSEIF-PLAIN')
	public function testParamsKeepTheCommaInsideAnElseifRegion(): Void {
		final written: String = roundTrip('class A {\n\tfunction f(#if a x:Int, #elseif b y:Int, #else w:Int, #end q:Int) {}\n}\n') ?? '';
		Assert.stringContains('#elseif b y:Int,', written);
	}

	@:pin('control')
	@:killer('M-ENUM-CTOR-PARAMS-PLAIN')
	public function testEnumCtorParamsKeepTheirSeparatorsAroundARegion(): Void {
		// An enum constructor's parameters are a function's: with no per-element `sepAfter` every gap got a comma, so a region
		// already ending on its own was followed by `#end, c:Int` — `a:Int, , c:Int` under `-D x`.
		assertFixedPoint('enum E {\n\tA(#if x a:Int, #else b:Int, #end c:Int);\n\tB(#if x a:Int, #end c:Int);\n}\n');
	}

	@:pin('control')
	@:killer('M-TRAIL-AFTER-REGION')
	@:killer('M-TRAIL-CASCADE-UNGATED')
	public function testTheTrailingCommaKnobAddsNoneAfterARegionEndingTheList(): Void {
		// `#if x b:Int #end,` compiles to `a:Int, ,` once `x` is off: the region's branches carry their own separators.
		final source: String =
			'class A {\n\tfunction p(a:Int, #if x b:Int #end) {}\n\n\tfunction c() {\n\t\tv(1, #if x 2, #end);\n\t}\n}\n';
		final expected: String = 'class A {\n\tfunction p(\n\t\ta:Int,\n\t\t#if x b:Int #end\n\t) {}\n\n\tfunction c() {\n\t\tv(\n'
			+ '\t\t\t1,\n\t\t\t#if x 2, #end\n\t\t);\n\t}\n}\n';
		assertWritesOnce(source, expected);
	}

	@:pin('control')
	@:killer('M-TRAIL-AFTER-REGION')
	@:killer('M-TRAIL-FORCEMULTI-UNGATED')
	@:killer('M-TRAIL-CALL-FORCEMULTI-UNGATED')
	public function testALineCommentedListAddsNoTrailingCommaAfterARegion(): Void {
		// A line comment routes both lists past the wrap cascade into their one-per-line loops, which append on their own.
		final source: String = 'class A {\n\tfunction q(a:Int, // c\n\t\t#if x b:Int #end) {}\n\n\tfunction c() {\n\t\tv(1, // c\n'
			+ '\t\t\t#if x 2, #end);\n\t}\n}\n';
		final expected: String = 'class A {\n\tfunction q(\n\t\ta:Int, // c\n\t\t#if x b:Int #end\n\t) {}\n\n\tfunction c() {\n\t\tv(\n'
			+ '\t\t\t1, // c\n\t\t\t#if x 2, #end\n\t\t);\n\t}\n}\n';
		assertWritesOnce(source, expected);
	}

	@:pin('control')
	@:killer('M-TRAIL-AFTER-SEMI')
	public function testTheTrailingCommaKnobAddsNoneAfterAClassNotationField(): Void {
		// `var b:Int;,` is no structure at all: a field that ends on its own `;` takes no separator after it.
		final source: String = 'class A {\n\tvar s:{var a:Int; var b:Int;};\n}\n\ntypedef T = {\n\tvar a:Int;\n\tvar d:Int;\n};\n';
		assertWritesOnce(source, source);
	}

	/** `source` is already what the writer produces for it — the byte contract a canonical file has. */
	private function assertFixedPoint(source: String): Void {
		Assert.equals(source, roundTrip(source));
	}

	private function roundTrip(source: String): Null<String> return new HaxeQueryPlugin().writeRoundTrip(source);

	/** Under `TRAILING_ONE_PER_LINE`, `source` writes as `expected`, and `expected` writes as itself. */
	private function assertWritesOnce(source: String, expected: String): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(TRAILING_ONE_PER_LINE);
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts));
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(expected), opts));
	}

}
