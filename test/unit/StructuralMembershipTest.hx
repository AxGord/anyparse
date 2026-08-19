package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;

/**
 * STRUCTURAL membership in the symbol index: whether a container satisfies `Iterable` /
 * `Iterator`, and the static-extension accept gate that consumes it.
 *
 * Membership is decided by the members a type DECLARES — `iterator()` for an `Iterable`,
 * `hasNext()` + `next()` for an `Iterator` — never by an `implements` clause, which no stdlib
 * container carries. Kept out of `SymbolIndexSliceTest` because that class sits at its
 * `oversized-type` maximum, so every member added there would trip a warning the tree does not
 * carry today.
 */
class StructuralMembershipTest extends Test {

	/** Each membership, and one refusal per way the same member name can carry the WRONG signature. */
	public function testStructuralIterableMembership(): Void {
		final index: SymbolIndex = SymbolIndex.build(iterableFiles(), new HaxeQueryPlugin());

		Assert.isTrue(index.satisfiesIterable('Bag'));
		// Inherited through the supertype closure, exactly as a member lookup is.
		Assert.isTrue(index.satisfiesIterable('SubBag'));
		// `iterator()` may name the structural `Iterator` itself, or a type that satisfies it.
		Assert.isTrue(index.satisfiesIterable('DirectBag'));
		// Each refusal is a DIFFERENT wrong signature for the same member name.
		Assert.isFalse(index.satisfiesIterable('ArityBag'));
		Assert.isFalse(index.satisfiesIterable('PlainBag'));
		Assert.isFalse(index.satisfiesIterable('FieldBag'));
		// An `Iterator` is not an `Iterable` — the two memberships are separate.
		Assert.isFalse(index.satisfiesIterable('BagIter'));
		// The `iterator()` return is written QUALIFIED and imported by nobody — the shape of
		// `Array.iterator():haxe.iterators.ArrayIterator`, and unreachable without the
		// package-blind fallback.
		Assert.isTrue(index.satisfiesIterable('DeepBag'));

		Assert.isTrue(index.satisfiesIterator('BagIter'));
		// One half of the membership is not the membership.
		Assert.isFalse(index.satisfiesIterator('HalfIter'));
		// Annotated FIELDS carrying those names are not the methods an iterator declares.
		Assert.isFalse(index.satisfiesIterator('FieldIter'));
		Assert.isFalse(index.satisfiesIterator('Widget'));
	}

	/**
	 * The accept gate reads that membership, and refuses every parameter whose ELEMENT type it
	 * cannot prove the receiver matches — proving the receiver is iterable is not the same as
	 * proving its element type binds the signature's type parameter.
	 */
	public function testStructuralParameterAcceptGate(): Void {
		final index: SymbolIndex = SymbolIndex.build(iterableFiles(), new HaxeQueryPlugin());

		Assert.equals('Widget', index.extensionReturnNominal('IterExt', 'pick', 'Bag'));
		Assert.equals('Widget', index.extensionReturnNominal('IterExt', 'step', 'BagIter'));
		// A receiver satisfying neither membership, and one satisfying the OTHER one.
		Assert.isNull(index.extensionReturnNominal('IterExt', 'pick', 'Widget'));
		Assert.isNull(index.extensionReturnNominal('IterExt', 'step', 'Bag'));
		// The type ARGUMENT gate: a concrete element type binds nothing, a nested application is
		// not a bare parameter, and an unapplied `Iterable` names no element at all.
		Assert.isNull(index.extensionReturnNominal('IterExt', 'fixed', 'Bag'));
		Assert.isNull(index.extensionReturnNominal('IterExt', 'nest', 'Bag'));
		Assert.isNull(index.extensionReturnNominal('IterExt', 'bare', 'Bag'));
	}

	/** The fixture set: one iterable pair, six near-misses, a cross-package iterator, and a generic extension module. */
	private function iterableFiles(): Array<{ file: String, source: String }> {
		return [
			{ file: 'Bag.hx', source: 'class Bag {\n\tpublic function iterator():BagIter return null;\n}' },
			{
				file: 'BagIter.hx',
				source: 'class BagIter {\n\tpublic function hasNext():Bool return false;\n\n\tpublic function next():Widget return null;\n}'
			},
			{ file: 'SubBag.hx', source: 'class SubBag extends Bag {}' },
			{ file: 'DirectBag.hx', source: 'class DirectBag {\n\tpublic function iterator():Iterator<Widget> return null;\n}' },
			{ file: 'ArityBag.hx', source: 'class ArityBag {\n\tpublic function iterator(n:Widget):BagIter return null;\n}' },
			{ file: 'PlainBag.hx', source: 'class PlainBag {\n\tpublic function iterator():Widget return null;\n}' },
			{ file: 'FieldBag.hx', source: 'class FieldBag {\n\tpublic var iterator:BagIter;\n}' },
			{ file: 'HalfIter.hx', source: 'class HalfIter {\n\tpublic function hasNext():Bool return false;\n}' },
			{ file: 'FieldIter.hx', source: 'class FieldIter {\n\tpublic var hasNext:Bool;\n\n\tpublic var next:Widget;\n}' },
			{ file: 'Widget.hx', source: 'class Widget {}' },
			{
				file: 'deep/DeepIter.hx',
				source: 'package deep;\n\nclass DeepIter {\n\tpublic function hasNext():Bool return false;\n\n'
					+ '\tpublic function next():Widget return null;\n}'
			},
			{ file: 'DeepBag.hx', source: 'class DeepBag {\n\tpublic function iterator():deep.DeepIter return null;\n}' },
			{
				file: 'IterExt.hx',
				source: 'class IterExt {\n\tpublic static function pick<T>(it:Iterable<T>):Widget return null;\n\n'
					+ '\tpublic static function step<T>(it:Iterator<T>):Widget return null;\n\n\tpublic static function '
					+ 'fixed(it:Iterable<Widget>):Widget return null;\n\n\tpublic static function nest<T>(it:Iterable<Iterable<T>>):Widget '
					+ 'return null;\n\n\tpublic static function bare(it:Iterable):Widget return null;\n}'
			}
		];
	}

}
