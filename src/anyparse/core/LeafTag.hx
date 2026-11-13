package anyparse.core;

using StringTools;

/**
 * What a `Doc.Text` leaf IS, said by the writer that built it, so a reader of the Doc never re-reads the leaf's bytes
 * to find out: the one answer to "which kind of leaf is this `Text`". An untagged leaf is writer syntax nobody has
 * named yet; each value is set where the leaf is built and nowhere else.
 */
enum LeafTag {

	/** A line comment (`CommentRun.isLine`): it runs to its line end, so nothing may follow it on that line. */
	LineComment;

	/** Any other comment, or one line of it: a delimited comment that ends where its closer does. */
	BlockComment;

	/**
	 * Writer syntax whose first byte opens a delimited run (`opens`) and/or whose last byte closes one (`closes`):
	 * the leaf a grammar's open / close / lead / trail / empty literal builds.
	 */
	Delimiter(opens: OpenEdge, closes: Bool);

}

/** Which delimited run a `LeafTag.Delimiter` leaf opens at its first byte. */
enum OpenEdge {

	/** The leaf opens nothing (a pure closer such as `)` or `]`). */
	NoOpen;

	/** A parenthesised run: `(`. */
	Paren;

	/** A non-empty collection: `[` or `{`. */
	Collection;

	/** An empty pair `[]` / `{}` emitted as ONE leaf: it opens a collection with nothing in it. */
	EmptyCollection;

}

/** The one answer to "which delimiter edge does this writer-syntax literal carry", asked once where the leaf is built. */
class DelimiterLeaf {

	/** The tag of a leaf spelling `s`, or null when `s` neither opens nor closes a delimited run at its edges. */
	public static function tagOf(s: String): Null<LeafTag> {
		if (s.length == 0) return null;
		final first: Int = s.fastCodeAt(0);
		final last: Int = s.fastCodeAt(s.length - 1);
		final closes: Bool = last == ')'.code || last == ']'.code || last == '}'.code;
		final trimmed: String = s.trim();
		final opens: OpenEdge = if (first == '('.code)
			Paren
		else if (first != '['.code && first != '{'.code)
			NoOpen
		else if (trimmed == '[]' || trimmed == '{}')
			EmptyCollection
		else
			Collection;
		return opens == NoOpen && !closes ? null : Delimiter(opens, closes);
	}

	/** A `Text` of a delimiter string `s` (a list's open or close), tagged with the edge it carries. */
	public static function leaf(s: String): Doc {
		return Text(s, null, tagOf(s));
	}

}
