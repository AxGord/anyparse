package unit.runtime;

import anyparse.runtime.ByteOrderMark;

/** `ByteOrderMark.carry` — the written text opens with the mark exactly when the source did, and the mark is never doubled. */
class ByteOrderMarkTest extends Test {

	/** A source that opened with the mark hands it to text that lost it. */
	@:pin('control') @:killer('M-BOM-NOT-CARRIED')
	public function testTheMarkIsCarriedOver(): Void {
		final mark: String = String.fromCharCode(ByteOrderMark.CODE);
		Assert.equals('${mark}class A {}\n', ByteOrderMark.carry('${mark}class A{}', 'class A {}\n'));
		Assert.equals('$mark', ByteOrderMark.carry(mark, ''));
	}

	/** A source without the mark leaves the text as written, and text that already opens with it is not given a second. */
	public function testTheMarkIsNeverAddedNorDoubled(): Void {
		final mark: String = String.fromCharCode(ByteOrderMark.CODE);
		Assert.equals('class A {}\n', ByteOrderMark.carry('class A{}', 'class A {}\n'));
		Assert.equals('${mark}x', ByteOrderMark.carry('${mark}x', '${mark}x'));
		Assert.equals('', ByteOrderMark.carry('', ''));
	}

	/** `opens` reads the first character only — a mark further in is ordinary text. */
	public function testOpensReadsTheFirstCharacter(): Void {
		final mark: String = String.fromCharCode(ByteOrderMark.CODE);
		Assert.isTrue(ByteOrderMark.opens('${mark}x'));
		Assert.isFalse(ByteOrderMark.opens('x$mark'));
		Assert.isFalse(ByteOrderMark.opens(''));
	}

}
