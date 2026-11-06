package unit.ds;

import anyparse.ds.Bits;
import unit.ds.BitsDomains;

/** `anyparse.ds.Bits`: the set contract on a one-`Int` store and on a word-vector store, and the bit algebra on both. */
class BitsTest extends Test {

	public function testEnumMembership(): Void {
		var hues: Bits<Hue> = new Bits<Hue>();
		Assert.isTrue(hues.isEmpty());
		hues.add(Blue);
		hues.add(Blue);
		Assert.isTrue(hues.has(Blue));
		Assert.isFalse(hues.has(Red));
		Assert.isFalse(hues.isEmpty());
		Assert.isTrue(hues.remove(Blue));
		Assert.isFalse(hues.remove(Blue));
		Assert.isTrue(hues.isEmpty());
	}

	/** Bit 0 and bit 31 of one word. */
	public function testNarrowEdgeBits(): Void {
		var bits: Bits<Narrow> = new Bits<Narrow>();
		bits.add(Narrow.Top);
		bits.add(Narrow.Low);
		Assert.isTrue(bits.has(Narrow.Low));
		Assert.isTrue(bits.has(Narrow.Top));
		Assert.isFalse(bits.has(Narrow.Next));
		Assert.isTrue(bits.remove(Narrow.Top));
		Assert.same([Narrow.Low], [for (value in bits) value]);
	}

	/** Bits 0, 31, 32 and 63: each edge of both words. */
	public function testWideEdgeBits(): Void {
		var bits: Bits<Wide> = new Bits<Wide>();
		for (value in [Wide.Top, Wide.First, Wide.Last, Wide.Low]) bits.add(value);
		for (value in [Wide.Top, Wide.First, Wide.Last, Wide.Low]) Assert.isTrue(bits.has(value));
		Assert.isTrue(bits.remove(Wide.First));
		Assert.isFalse(bits.has(Wide.First));
		Assert.isTrue(bits.has(Wide.Last));
		Assert.same([Wide.Low, Wide.Last, Wide.Top], [for (value in bits) value]);
		bits.clear();
		Assert.isTrue(bits.isEmpty());
	}

	/** Members come out in ascending bit order, whatever order they went in. */
	public function testIterationAscendsByBit(): Void {
		var hues: Bits<Hue> = new Bits<Hue>();
		for (hue in [Blue, Red, Green]) hues.add(hue);
		Assert.same([Red, Green, Blue], [for (hue in hues) hue]);
		var narrow: Bits<Narrow> = new Bits<Narrow>();
		for (value in [Narrow.Top, Narrow.Next, Narrow.Low]) narrow.add(value);
		Assert.same([Narrow.Low, Narrow.Next, Narrow.Top], [for (value in narrow) value]);
		Assert.isFalse(new Bits<Wide>().iterator().hasNext());
	}

	/** A domain of 32 values is one `Int`; one value more and it is a word vector. */
	@:pin('control')
	@:killer('M-DS-BITS-WIDTH')
	public function testStoreWidthFollowsTheDomain(): Void {
		Assert.isTrue(Std.isOfType((cast new Bits<Narrow>(): Any), Int));
		Assert.isFalse(Std.isOfType((cast new Bits<Wide>(): Any), Int));
	}

	public function testUnionAndIntersection(): Void {
		final left: Bits<Wide> = [Wide.Low, Wide.First];
		final right: Bits<Wide> = [Wide.First, Wide.Top];
		Assert.same([Wide.Low, Wide.First, Wide.Top], [for (value in left | right) value]);
		Assert.same([Wide.First], [for (value in left & right) value]);
		final warm: Bits<Hue> = [Red, Green];
		final cool: Bits<Hue> = [Green, Blue];
		Assert.same([Red, Green, Blue], [for (hue in warm | cool) hue]);
		Assert.same([Green], [for (hue in warm & cool) hue]);
		Assert.same([Narrow.Low, Narrow.Top], [for (value in (Narrow.Low: Bits<Narrow>) | Narrow.Top) value]);
	}

	/** `~` holds every value of the domain the operand does not, and never a bit no value stands for. */
	@:pin('control')
	@:killer('M-DS-BITS-COMPLEMENT')
	public function testComplementStaysInTheDomain(): Void {
		final green: Bits<Hue> = Green;
		Assert.same([Red, Blue], [for (hue in ~green) hue]);
		final flags: Bits<Flag> = [Flag.Two, Flag.Huge];
		Assert.same([Flag.One, Flag.Four], [for (flag in ~flags) flag]);
		final narrow: Bits<Narrow> = Narrow.Next;
		final others: Array<Narrow> = [for (value in ~narrow) value];
		Assert.equals(Narrow.Top, others[others.length - 1]);
		Assert.isFalse(others.contains(Narrow.Next));
		final wide: Bits<Wide> = Wide.Last;
		Assert.isFalse((~wide).has(Wide.Last));
		Assert.isTrue((~wide).has(Wide.Top));
		Assert.isTrue((~new Bits<Wide>() & wide) == wide);
	}

	/** A value's bit is its rank among the domain's values, so codes far apart and flags each take one bit of one `Int`. */
	@:pin('control')
	@:killer('M-DS-BITS-RANK')
	public function testASparseDomainTakesOneBitPerValue(): Void {
		Assert.isTrue(Std.isOfType((cast new Bits<Sparse>(): Any), Int));
		var sparse: Bits<Sparse> = Sparse.Far;
		Assert.isTrue(sparse.has(Sparse.Far));
		Assert.isFalse(sparse.has(Sparse.Zero));
		sparse.add(Sparse.Zero);
		Assert.same([Sparse.Zero, Sparse.Far], [for (value in sparse) value]);
		var flags: Bits<Flag> = new Bits<Flag>();
		flags.add(Flag.Huge);
		flags.add(Flag.Two);
		Assert.same([Flag.Two, Flag.Huge], [for (flag in flags) flag]);
		Assert.isFalse(flags.has(Flag.Four));
	}

	/** Two sets are equal when they hold the same values, on either store. */
	public function testEqualityIsByMembers(): Void {
		final left: Bits<Wide> = [Wide.Low, Wide.Top];
		final right: Bits<Wide> = [Wide.Top, Wide.Low];
		Assert.isTrue(left == right);
		Assert.isFalse(left != right);
		Assert.isTrue(left != (Wide.Low: Bits<Wide>));
		final hues: Bits<Hue> = [Red];
		Assert.isTrue(hues == (Red: Bits<Hue>));
		Assert.isTrue(hues != (Blue: Bits<Hue>));
	}

	/** A set is a value: changing one variable leaves every set it was assigned from or to as it was. */
	public function testAssignmentCopies(): Void {
		var wide: Bits<Wide> = Wide.Low;
		final kept: Bits<Wide> = wide;
		final copied: Bits<Wide> = wide.copy();
		wide.add(Wide.Top);
		Assert.isFalse(kept.has(Wide.Top));
		Assert.isFalse(copied.has(Wide.Top));
		var narrow: Bits<Narrow> = Narrow.Low;
		final keptNarrow: Bits<Narrow> = narrow;
		narrow.remove(Narrow.Low);
		Assert.isTrue(keptNarrow.has(Narrow.Low));
	}

	/** `add` and `remove` write back through a field, a method changing its own field, and an array element. */
	public function testChangesWriteBackThroughTheirPlace(): Void {
		final palette: Palette = new Palette();
		palette.hues.add(Red);
		palette.paint(Blue);
		Assert.same([Red, Blue], [for (hue in palette.hues) hue]);
		palette.wide.add(Wide.Top);
		Assert.isTrue(palette.wide.has(Wide.Top));
		final sets: Array<Bits<Hue>> = [new Bits<Hue>()];
		sets[0].add(Green);
		Assert.isTrue(sets[0].has(Green));
		Assert.isTrue(sets[0].remove(Green));
		Assert.isTrue(sets[0].isEmpty());
	}

}

/** Sets held in fields, the way a type keeps its flags. */
private final class Palette {

	public var hues: Bits<Hue> = new Bits<Hue>();
	public var wide: Bits<Wide> = new Bits<Wide>();

	public function new() {}

	public function paint(hue: Hue): Void { // noqa: prefer-inline
		hues.add(hue);
	}

}
