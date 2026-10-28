package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.ByteOrderMark;
import utest.Assert;
import utest.Test;

/**
 * The Haxe plugin's whole-file write keeps a source's byte-order mark: the parser skips it as whitespace, so without the
 * plugin's own carry every `fmt` and every canonicalising op would strip it from the file.
 */
class HaxeQueryPluginByteOrderMarkTest extends Test {

	/** A file that opens with the mark is written back with it, comments and layout as without it. */
	@:pin('control') @:killer('M-BOM-HAXE-SEAT')
	public function testWriteRoundTripKeepsTheMark(): Void {
		final mark: String = String.fromCharCode(ByteOrderMark.CODE);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.equals('${mark}// head\nclass A {}\n', plugin.writeRoundTrip('${mark}// head\nclass A {}\n'));
		Assert.equals('${mark}class B {}\n', plugin.writeRoundTrip('${mark}class B {}\n'));
	}

	/** A file without the mark is not given one. */
	public function testWriteRoundTripAddsNoMark(): Void {
		Assert.equals('class B {}\n', new HaxeQueryPlugin().writeRoundTrip('class B {}\n'));
	}

}
