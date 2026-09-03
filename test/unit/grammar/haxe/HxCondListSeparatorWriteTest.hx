package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeQueryPlugin;
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

	/** `source` is already what the writer produces for it — the byte contract a canonical file has. */
	private function assertFixedPoint(source: String): Void {
		Assert.equals(source, roundTrip(source));
	}

	private function roundTrip(source: String): Null<String> return new HaxeQueryPlugin().writeRoundTrip(source);

}
