package unit.core;

import anyparse.core.CollectionRun;
import anyparse.core.D;
import anyparse.core.Doc;
import anyparse.core.DocIdentityMap;
import anyparse.core.LeafTag;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

using Lambda;

/** A delimiter leaf says which edge it carries through its `LeafTag`, set where it is built, never re-read from its bytes. */
@:nullSafety(Strict)
class DelimiterLeafTest extends Test {

	/** A delimiter literal is classified by its edges; an empty pair is its own open edge, plain text carries none. */
	@:pin('control')
	@:killer('M-DELIMLEAF-EMPTY-PAIR')
	public function testTagOfClassifiesTheEdges(): Void {
		Assert.same(Delimiter(Paren, Opens), DelimiterLeaf.tagOf('('));
		Assert.same(Delimiter(NoOpen, Closes), DelimiterLeaf.tagOf(')'));
		Assert.same(Delimiter(Collection, Opens), DelimiterLeaf.tagOf('{'));
		Assert.same(Delimiter(NoOpen, ClosesBrace), DelimiterLeaf.tagOf('}'));
		Assert.same(Delimiter(EmptyCollection, Closes), DelimiterLeaf.tagOf('[]'));
		Assert.same(Delimiter(EmptyCollection, ClosesBrace), DelimiterLeaf.tagOf('{}'));
		Assert.same(Delimiter(Paren, Closes), DelimiterLeaf.tagOf('()'));
		Assert.isNull(DelimiterLeaf.tagOf('a'));
		Assert.isNull(DelimiterLeaf.tagOf(''));
	}

	/**
	 * Every paren leaf the generated writer builds — a grammar literal or a list delimiter — carries its edge tag.
	 */
	@:pin('control')
	@:killer('M-DELIMLEAF-MACRO-UNTAGGED')
	public function testWriterTagsEveryParenLeaf(): Void {
		final tags: Array<Null<LeafTag>> = [];
		collect(
			HaxeModuleTriviaWriter.writeDoc(
				HaxeModuleTriviaParser.parse(
					'class A {\n\tvar o: { a: Int } = { a: 1 };\n\tfunction f() {\n\t\tif (c) g(a);\n\t\tvar x = (a + b) * c;\n'
					+ '\t\tvar l = [1, 2];\n\t\tvar e = [];\n\t\tswitch (x) {\n\t\t\tcase _:\n\t\t}\n\t}\n}\n'
				),
				HaxeFormat.instance.defaultWriteOptions
			),
			['(', ')', '[', ']', '{', '}', '()', '[]', '{}'], new DocIdentityMap(), tags
		);
		Assert.isTrue(tags.exists(t -> Type.enumEq(t, Delimiter(Paren, Opens))));
		Assert.isTrue(tags.exists(t -> Type.enumEq(t, Delimiter(NoOpen, Closes))));
		Assert.isTrue(tags.exists(t -> Type.enumEq(t, Delimiter(NoOpen, ClosesBrace))));
		Assert.isFalse(tags.exists(t -> t == null));
	}

	/** A collection run starts at a tagged non-empty open; an empty pair, or the same bytes untagged, starts none. */
	@:pin('control')
	@:killer('M-DELIMLEAF-RUN-EMPTY-PAIR')
	public function testCollectionRunReadsTheTag(): Void {
		Assert.isTrue(CollectionRun.startsCollection(Concat([DelimiterLeaf.leaf('['), Text('a')])));
		Assert.isFalse(CollectionRun.startsCollection(DelimiterLeaf.leaf('[]')));
		Assert.isFalse(CollectionRun.startsCollection(Concat([Text('['), Text('a')])));
	}

	/** Every distinct `Text` leaf of `d` spelling one of `spellings`, by its tag. */
	private static function collect(d: Doc, spellings: Array<String>, seen: DocIdentityMap<Bool>, out: Array<Null<LeafTag>>): Void {
		if (seen.exists(d)) return;
		seen.set(d, true);
		switch d {
			case Text(s, _, t) if (spellings.contains(s)):
				out.push(t);
			case _:
		}
		D.mapChildren(d, c -> {
			collect(c, spellings, seen, out);
			return c;
		});
	}

}
