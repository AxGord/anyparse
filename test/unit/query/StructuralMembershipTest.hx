package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import utest.Assert;
import utest.Test;

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

	/**
	 * A top-level `typedef` re-pointing at a PACKAGED type of the same simple name — the exact
	 * shape `/std/List.hx` and `/std/Map.hx` carry — is followed to the target that declares the
	 * members. The fixtures reproduce the std sources verbatim in shape: the alias writes its
	 * target QUALIFIED and imports nothing, so only the written PATH can name the target.
	 */
	public function testAliasedContainerSatisfiesIterable(): Void {
		final index: SymbolIndex = SymbolIndex.build(aliasFiles(), new HaxeQueryPlugin());

		// `typedef List<T> = haxe.ds.List<T>` -> a class whose `iterator()` returns a sub-module
		// type of its OWN module, which only the target's file can resolve.
		Assert.isTrue(index.satisfiesIterable('List', 'Use.hx'));
		// `typedef Map<K, V> = haxe.ds.Map<K, V>` -> an abstract naming `Iterator` directly.
		Assert.isTrue(index.satisfiesIterable('Map', 'Use.hx'));
		// The same hop where the alias and its target do NOT share a simple name.
		Assert.isTrue(index.satisfiesIterable('Renamed', 'Use.hx'));
		// Two hops: an alias to an alias.
		Assert.isTrue(index.satisfiesIterable('Chained', 'Use.hx'));
		// The hop carries no proof of its own — a target that is not iterable stays refused.
		Assert.isFalse(index.satisfiesIterable('PlainAlias', 'Use.hx'));
		// An alias whose target nothing indexes is unresolvable, not iterable.
		Assert.isFalse(index.satisfiesIterable('Outside', 'Use.hx'));
		// An alias to an anonymous structure hosts no nominal target at all.
		Assert.isFalse(index.satisfiesIterable('Anon', 'Use.hx'));
		// An anon-struct typedef is NOT an alias: it hosts its own fields, and a `> Base`
		// structural extension is a SUPERTYPE link the walk below must still take.
		Assert.isTrue(index.satisfiesIterable('IterStruct', 'Use.hx'));
		Assert.isTrue(index.satisfiesIterable('SubStruct', 'Use.hx'));
		// A function-type alias has no nominal head to follow.
		Assert.isFalse(index.satisfiesIterable('Fn', 'Use.hx'));
		// The head is RAW source, so a comment before the path rides along in it. The raw answer
		// falls back to the simple name there rather than handing a comment on as a type
		// reference — which resolves here, because `Sack` is unique among the indexed decls.
		Assert.isTrue(index.satisfiesIterable('Commented', 'Use.hx'));
		// The same fallback with a target whose SIMPLE name is not enough leaves it unproven,
		// which is where the raw path would have been needed and is not available.
		Assert.isFalse(index.satisfiesIterable('CommentedDup', 'Use.hx'));

		// The second half of the same hop, and the one the REAL path reaches first:
		// `NominalTypes.staticExtensionNominal` consults an extension only after the receiver is
		// PROVEN to declare no such member, and that proof walks the alias too.
		Assert.isTrue(index.typeProvablyLacksMember('List', 'pick', 'Use.hx'));
		Assert.isTrue(index.typeProvablyLacksMember('Map', 'pick', 'Use.hx'));
		// The hop proves presence as readily as absence — `iterator()` IS declared on the target.
		Assert.isFalse(index.typeProvablyLacksMember('List', 'iterator', 'Use.hx'));

		// The accept gate consumes it: `Lambda`-shaped extensions now bind on an aliased container.
		Assert.equals('Widget', index.extensionReturnNominal('IterExt', 'pick', 'List', 'Use.hx'));
		Assert.equals('Widget', index.extensionReturnNominal('IterExt', 'pick', 'Map', 'Use.hx'));
		Assert.isNull(index.extensionReturnNominal('IterExt', 'pick', 'PlainAlias', 'Use.hx'));
	}

	/**
	 * `aliasTargetNominal` and `aliasTargetRaw` come from ONE source read and must never disagree:
	 * the nominal is `simpleName` of the raw, for every alias form the fixtures carry. Two of the
	 * nominal's three consumers compare it against another SIMPLE name — `PreferCaseGuard` looks
	 * it up through `declaringFiles`, `ComparisonToBoolean.typeNameIsPinned` tests it for equality
	 * with the receiver type — so re-pointing the FIELD, rather than adding one beside it, would
	 * have broken both silently.
	 */
	public function testAliasTargetPairAgrees(): Void {
		final index: SymbolIndex = SymbolIndex.build(aliasFiles(), new HaxeQueryPlugin());

		Assert.equals('List', aliasNominal(index, 'List'));
		Assert.equals('haxe.ds.List', aliasRaw(index, 'List'));
		Assert.equals('Map', aliasNominal(index, 'Map'));
		Assert.equals('haxe.ds.Map', aliasRaw(index, 'Map'));
		Assert.equals('Sack', aliasNominal(index, 'Renamed'));
		Assert.equals('deep.Sack', aliasRaw(index, 'Renamed'));
		// The comment fallback answers the SIMPLE name on both sides, never the raw head.
		Assert.equals('Sack', aliasNominal(index, 'Commented'));
		Assert.equals('Sack', aliasRaw(index, 'Commented'));
		// Null on one side is null on the other, for every form that yields none.
		for (form in ['Anon', 'Fn', 'Bag', 'IterStruct']) {
			Assert.isNull(aliasNominal(index, form), 'expected no alias nominal for $form');
			Assert.isNull(aliasRaw(index, form), 'expected no alias raw for $form');
		}
	}

	/** The `aliasTargetNominal` of the single decl named `name`, or null. */
	private function aliasNominal(index: SymbolIndex, name: String): Null<String> {
		for (fi in index.declaringFiles(name)) for (t in fi.types) if (t.name == name) return t.aliasTargetNominal;
		return null;
	}

	/** The `aliasTargetRaw` of the single decl named `name`, or null. */
	private function aliasRaw(index: SymbolIndex, name: String): Null<String> {
		for (fi in index.declaringFiles(name)) for (t in fi.types) if (t.name == name) return t.aliasTargetRaw;
		return null;
	}

	/** The alias fixture set: the two std container shapes verbatim, plus one refusal per alias form. */
	private function aliasFiles(): Array<{ file: String, source: String }> {
		return iterableFiles().concat([
			{ file: 'Use.hx', source: 'class Use {}' },
			{ file: 'List.hx', source: 'typedef List<T> = haxe.ds.List<T>;' },
			{
				file: 'haxe/ds/List.hx',
				source: 'package haxe.ds;\n\nclass List<T> {\n\tpublic function iterator():ListIterator<T> return null;\n}\n\n'
				+ 'private class ListIterator<T> {\n\tpublic function hasNext() return false;\n\n\tpublic function next() return null;\n}'
			},
			{ file: 'Map.hx', source: 'typedef Map<K, V> = haxe.ds.Map<K, V>;' },
			{
				file: 'haxe/ds/Map.hx',
				source: 'package haxe.ds;\n\nabstract Map<K, V>(IMap<K, V>) {\n\t'
				+ 'public inline function iterator():Iterator<V> return null;\n}'
			},
			{ file: 'Renamed.hx', source: 'typedef Renamed = deep.Sack;' },
			{ file: 'deep/Sack.hx', source: 'package deep;\n\nclass Sack {\n\tpublic function iterator():DeepIter return null;\n}' },
			{ file: 'Chained.hx', source: 'typedef Chained = Renamed;' },
			{ file: 'PlainAlias.hx', source: 'typedef PlainAlias = Widget;' },
			{ file: 'Outside.hx', source: 'typedef Outside = nowhere.Gone;' },
			{ file: 'Anon.hx', source: 'typedef Anon = { var a:Int; };' },
			{ file: 'Fn.hx', source: 'typedef Fn = Bag -> Widget;' },
			{ file: 'IterStruct.hx', source: 'typedef IterStruct = {\n\tfunction iterator():BagIter;\n}' },
			{ file: 'SubStruct.hx', source: 'typedef SubStruct = {\n\t> IterStruct,\n\tvar a:Widget;\n}' },
			{ file: 'Commented.hx', source: 'typedef Commented = /* c */ deep.Sack;' },
			{ file: 'CommentedDup.hx', source: 'typedef CommentedDup = /* c */ deep.Twin;' },
			{ file: 'deep/Twin.hx', source: 'package deep;\n\nclass Twin {\n\tpublic function iterator():DeepIter return null;\n}' },
			{ file: 'other/Twin.hx', source: 'package other;\n\nclass Twin {}' }
		]);
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
