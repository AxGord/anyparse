package anyparse.core;

using anyparse.util.Strings;
using StringTools;

/**
 * What a `Doc.Text` leaf IS, said by the writer that built it, so a reader of the Doc never re-reads the leaf's bytes
 * to find out: the one answer to "which kind of leaf is this `Text`". An untagged leaf is writer syntax nobody has
 * named yet; each value is set where the leaf is built and nowhere else, save a call's `(`, which the call writer
 * names at the boundary of the run a list emitter built for it (`DelimiterLeaf.callArgs`).
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

	/** A call's argument run: the `(` right after its callee (`DelimiterLeaf.callArgs`). */
	CallArgs;

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

	/** The last byte closes a delimited run other than a brace one: `)` or `]`. */
	Closes;

	/** The last byte closes a brace run: `}`. */
	ClosesBrace;

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

	/** Whether a leaf tagged `tag` ends on a closing brace. */
	public static function closesBrace(tag: Null<LeafTag>): Bool {
		return switch tag {
			case Delimiter(_, ClosesBrace): true;
			case _: false;
		};
	}

	/** Whether a leaf tagged `tag` opens a call's argument run. */
	public static function opensCallArgs(tag: Null<LeafTag>): Bool {
		return switch tag {
			case Delimiter(CallArgs, _): true;
			case _: false;
		};
	}

	/**
	 * `args`, a call's argument run, with its opening `(` leaf tagged `CallArgs` in every layout the run offers. The list
	 * emitter that builds the run knows only its delimiter strings; the call writer that hands it the `(` knows it opens a
	 * call, so it names the leaf here, at that boundary.
	 */
	public static function callArgs(args: Doc): Doc {
		return retagOpenParen(args) ?? args;
	}

	/** `d` with its first visible leaf tagged `CallArgs` when that leaf opens a paren run, or null when `d` shows no leaf. */
	private static function retagOpenParen(d: Doc): Null<Doc> {
		return switch d {
			case Text(s, verbatim, Delimiter(Paren, ends)): Text(s, verbatim, Delimiter(CallArgs, ends));
			case Text(s, _, _): s.length == 0 ? null : d;
			case Empty, Line(_), OptSpace(_), OptSpaceSkipAfterHardline, OptHardline, OptHardlineSkipAtOpenDelim,
				OptHardlineSkipBeforeHardline:
				null;
			case Concat(items):
				final out: Null<Array<Doc>> = retagFirstItem(items);
				out == null ? null : Concat(out);
			case Fill(items, sep, tailReserve):
				final out: Null<Array<Doc>> = retagFirstItem(items);
				out == null ? null : Fill(out, sep, tailReserve);
			case FillWithRestProbe(items, sep, tailReserve):
				final out: Null<Array<Doc>> = retagFirstItem(items);
				out == null ? null : FillWithRestProbe(out, sep, tailReserve);
			case FillBreakAfterWrap(items, sep, tailReserve):
				final out: Null<Array<Doc>> = retagFirstItem(items);
				out == null ? null : FillBreakAfterWrap(out, sep, tailReserve);
			case _:
				var shown: Bool = false;
				final out: Doc = D.mapChildren(d, c -> {
					final r: Null<Doc> = retagOpenParen(c);
					if (r != null) shown = true;
					r ?? c;
				});
				shown ? out : null;
		};
	}

	/** `items` with the first item that shows a leaf retagged by `retagOpenParen`, or null when no item shows one. */
	private static function retagFirstItem(items: Array<Doc>): Null<Array<Doc>> {
		for (i in 0...items.length) {
			final r: Null<Doc> = retagOpenParen(items[i]);
			if (r == null) continue;
			final out: Array<Doc> = items.copy();
			out[i] = r;
			return out;
		}
		return null;
	}

	/** The end edge of a non-empty `s`, read once from its last byte and its last non-blank bytes. */
	private static function endEdgeOf(s: String): EndEdge {
		final last: Int = s.fastCodeAt(s.length - 1);
		if (last == '}'.code) return ClosesBrace;
		if (last == ')'.code || last == ']'.code) return Closes;
		var i: Int = s.length - 1;
		while (i >= 0 && s.fastCodeAt(i).isSpaceOrTab()) i--;
		if (i < 0) return Plain;
		final c: Int = s.fastCodeAt(i);
		if (c == '('.code || c == '['.code || c == '{'.code) return Opens;
		return c == '>'.code && i > 0 && s.fastCodeAt(i - 1) == '-'.code ? Arrow : Plain;
	}

}
