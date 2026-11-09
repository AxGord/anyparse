package anyparse.runtime;

using StringTools;

/**
 * The one answer to "which element does a block comment between a list's open delimiter and its first element,
 * all on one line, belong to when the writer lays the list out by its wrap rules".
 *
 * The parser takes any comment right after the open delimiter into the list's open-trailing slot, so the
 * `{/* c *\/ a, b}` a flat write of a first element's inline leading comment produces reads back as an open
 * trail, which forces the list broken. `first` hands the writer the tree that write came from instead: the
 * comment as the first element's glued leading comment and no open trail, so the list's layout is decided the
 * same way on every rewrite. A line comment, a block comment that spans lines, or one that ends its line in
 * the source stays where the parser put it.
 */
@:nullSafety(Strict)
final class OpenGluedComment {

	/** Whether `trailOpen` is a one-line block comment the source wrote on the first element's own line. */
	public static function leads<T>(arr: Array<Trivial<T>>, trailOpen: Null<String>): Bool {
		return trailOpen != null && arr.length != 0 && !arr[0].newlineBefore && trailOpen.startsWith('/*') && trailOpen.indexOf('\n') < 0;
	}

	/** `arr` with `trailOpen` prepended to its first element's leading comments, glued to that element. */
	public static function first<T>(arr: Array<Trivial<T>>, trailOpen: String): Array<Trivial<T>> {
		final t: Trivial<T> = arr[0];
		final out: Array<Trivial<T>> = arr.copy();
		out[0] = {
			blankBefore: t.blankBefore,
			blankBefore2: t.blankBefore2,
			blankAfterLeadingComments: t.blankAfterLeadingComments,
			newlineBefore: false,
			leadingComments: [trailOpen].concat(t.leadingComments),
			trailingComment: t.trailingComment,
			trailingBeforeSep: t.trailingBeforeSep,
			afterSepComment: t.afterSepComment,
			sepAfter: t.sepAfter,
			leadingCommentsGlued: t.leadingComments.length == 0 || t.leadingCommentsGlued,
			node: t.node
		};
		return out;
	}

}
