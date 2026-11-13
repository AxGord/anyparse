package unit.core;

import anyparse.core.D;
import anyparse.core.Doc;
import anyparse.core.DocIdentityMap;
import anyparse.core.LeafTag;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

using Lambda;
using StringTools;

/** A leaf with its verbatim mark and tag, as the writer built it. */
private typedef Leaf = { final s: String; final verbatim: Bool; final tag: Null<LeafTag>; }

/**
 * A comment leaf says what it is through its `LeafTag`, set where the writer builds it, so no reader of the Doc
 * re-reads the bytes for `//`; and the walkers that keep a leaf keep its tag.
 */
@:nullSafety(Strict)
class LeafTagTest extends Test {

	/** An own-line `//` comment is a line-comment leaf. */
	@:pin('control')
	@:killer('M-LEAFTAG-LEADING-LINE')
	public function testOwnLineLineCommentLeafIsALineComment(): Void {
		assertTags('class A {\n\t// note\n\tvar x: Int;\n}\n', 'note', LeafTag.LineComment);
	}

	/** A captured trailing `//` comment is a line-comment leaf. */
	@:pin('control')
	@:killer('M-LEAFTAG-CAPTURED-LINE')
	public function testTrailingLineCommentLeafIsALineComment(): Void {
		assertTags('class A {\n\tvar x: Int; // note\n}\n', 'note', LeafTag.LineComment);
	}

	/** A one-line block comment is a block-comment leaf. */
	@:pin('guard')
	public function testOneLineBlockCommentLeafIsABlockComment(): Void {
		assertTags('class A {\n\t/* note */\n\tvar x: Int;\n}\n', 'note', LeafTag.BlockComment);
	}

	/** Every line of a normalized multi-line block comment is a block-comment leaf. */
	@:pin('control')
	@:killer('M-LEAFTAG-BLOCK-NORMALIZED')
	public function testMultiLineBlockCommentLeavesAreBlockComments(): Void {
		assertTags('class A {\n\t/*\n\t\tnote one\n\t\tnote two\n\t*/\n\tvar x: Int;\n}\n', 'note', LeafTag.BlockComment, 2);
	}

	/** A string literal whose bytes open with `//` is no line comment, which a test of its text would have said it was. */
	@:pin('guard')
	public function testStringLiteralOpeningWithSlashesIsNoLineComment(): Void {
		final found: Array<Leaf> = leaves("class A {\n\tvar x: String = '// lit $y';\n}\n", '// lit');
		Assert.isTrue(found.length > 0 && found.exists(l -> l.s.ltrim().startsWith('//')));
		for (l in found) Assert.notEquals(LeafTag.LineComment, l.tag);
	}

	/** `D.verbatim` with no tag marks the leaf verbatim and keeps the tag it had. */
	@:pin('control')
	@:killer('M-LEAFTAG-VERBATIM-KEEPS-OWN')
	public function testVerbatimWithNoTagKeepsTheLeafTag(): Void {
		assertLeaf(D.verbatim(Text('// a', false, LeafTag.LineComment)), true, LeafTag.LineComment);
	}

	/** `D.verbatim` with a tag sets it on every leaf of the content. */
	@:pin('control')
	@:killer('M-LEAFTAG-VERBATIM-SETS')
	public function testVerbatimWithATagTagsEveryLeaf(): Void {
		switch D.verbatim(Concat([Text('a'), Text('b')]), LeafTag.BlockComment) {
			case Concat([a, b]):
				assertLeaf(a, true, LeafTag.BlockComment);
				assertLeaf(b, true, LeafTag.BlockComment);
			case other:
				Assert.fail('not a two-leaf Concat: $other');
		}
	}

	/** `D.flatten` keeps a tagged leaf as it is. */
	@:pin('control')
	@:killer('M-LEAFTAG-FLATTEN-KEEPS')
	public function testFlattenKeepsTheLeafTag(): Void {
		switch D.flatten(Concat([Text('// a', true, LeafTag.LineComment)])) {
			case Concat([leaf]):
				assertLeaf(leaf, true, LeafTag.LineComment);
			case other:
				Assert.fail('not a one-leaf Concat: $other');
		}
	}

	/** `D.mapChildren` hands a leaf back as it is. */
	@:pin('guard')
	public function testMapChildrenKeepsTheLeafTag(): Void {
		assertLeaf(D.mapChildren(Text('// a', true, LeafTag.LineComment), c -> Empty), true, LeafTag.LineComment);
	}

	private static function assertTags(source: String, marker: String, tag: LeafTag, count: Int = 1): Void {
		final found: Array<Leaf> = leaves(source, marker);
		Assert.equals(count, found.length);
		for (l in found) {
			Assert.isTrue(l.verbatim);
			Assert.equals(tag, l.tag);
		}
	}

	private static function assertLeaf(d: Doc, verbatim: Bool, tag: LeafTag): Void {
		switch d {
			case Text(_, v, t):
				Assert.equals(verbatim, v == true);
				Assert.equals(tag, t);
			case other:
				Assert.fail('not a Text leaf: $other');
		}
	}

	/** Every distinct `Text` leaf of `source`'s written Doc whose bytes hold `marker`. */
	private static function leaves(source: String, marker: String): Array<Leaf> {
		final out: Array<Leaf> = [];
		collect(
			HaxeModuleTriviaWriter.writeDoc(HaxeModuleTriviaParser.parse(source), HaxeFormat.instance.defaultWriteOptions), marker,
			new DocIdentityMap(), out
		);
		return out;
	}

	/** Visits each shared node of the DAG once, so a leaf two branches share is counted once. */
	private static function collect(d: Doc, marker: String, seen: DocIdentityMap<Bool>, out: Array<Leaf>): Void {
		if (seen.exists(d)) return;
		seen.set(d, true);
		switch d {
			case Text(s, v, t) if (s.contains(marker)):
				out.push({ s: s, verbatim: v == true, tag: t });
			case _:
		}
		D.mapChildren(d, c -> {
			collect(c, marker, seen, out);
			return c;
		});
	}

}
