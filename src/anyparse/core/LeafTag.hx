package anyparse.core;

using anyparse.util.Strings;
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
	 * Writer syntax whose first byte opens a delimited run (`opens`) and/or whose end closes one or leaves one open
	 * (`ends`): the leaf a grammar's open / close / lead / trail / empty literal builds, `foo(` and `) {` included.
	 */
	Delimiter(opens: OpenEdge, ends: EndEdge);

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

/**
 * What a `LeafTag.Delimiter` leaf's end leaves for the token after it. A close is read at the last byte; an open
 * and an arrow at the last non-blank byte, since the blank after them belongs to the line, not to what they open.
 */
enum EndEdge {

	/** The end neither closes a run nor leaves one open (`(a`). */
	Plain;

	/** The last byte closes a delimited run: `)`, `]` or `}`. */
	Closes;

	/** The last non-blank byte opens a delimited run: `(`, `[` or `{`, as in `foo(` or `) {`. */
	Opens;

	/** The last non-blank bytes are an arrow `->`, whose body starts after it the way a run's does after its opener. */
	Arrow;

}

/** The one answer to "which delimiter edge does this writer-syntax literal carry", asked once where the leaf is built. */
class DelimiterLeaf {

	/** The tag of a leaf spelling `s`, or null when `s` neither opens a delimited run at its first byte nor carries an end edge. */
	public static function tagOf(s: String): Null<LeafTag> {
		if (s.length == 0) return null;
		final first: Int = s.fastCodeAt(0);
		final trimmed: String = s.trim();
		final opens: OpenEdge = if (first == '('.code)
			Paren
		else if (first != '['.code && first != '{'.code)
			NoOpen
		else if (trimmed == '[]' || trimmed == '{}')
			EmptyCollection
		else
			Collection;
		final ends: EndEdge = endEdgeOf(s);
		return opens == NoOpen && ends == Plain ? null : Delimiter(opens, ends);
	}

	/** A `Text` of a delimiter string `s` (a list's open or close), tagged with the edge it carries. */
	public static function leaf(s: String): Doc {
		return Text(s, null, tagOf(s));
	}

	/** Whether a leaf tagged `tag` leaves a delimited run open at its end; `arrow` counts an arrow `->` as such an end. */
	public static function leavesOpen(tag: Null<LeafTag>, arrow: Bool): Bool {
		return switch tag {
			case Delimiter(_, Opens): true;
			case Delimiter(_, Arrow): arrow;
			case _: false;
		};
	}

	/** The end edge of a non-empty `s`, read once from its last byte and its last non-blank bytes. */
	private static function endEdgeOf(s: String): EndEdge {
		final last: Int = s.fastCodeAt(s.length - 1);
		if (last == ')'.code || last == ']'.code || last == '}'.code) return Closes;
		var i: Int = s.length - 1;
		while (i >= 0 && s.fastCodeAt(i).isSpaceOrTab()) i--;
		if (i < 0) return Plain;
		final c: Int = s.fastCodeAt(i);
		if (c == '('.code || c == '['.code || c == '{'.code) return Opens;
		return c == '>'.code && i > 0 && s.fastCodeAt(i - 1) == '-'.code ? Arrow : Plain;
	}

}
