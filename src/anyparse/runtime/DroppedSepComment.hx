package anyparse.runtime;

/**
 * The list a sep-Star writer lays out when it drops the trailing separator a comment followed.
 *
 * `[a, {b: 1}, // c]` keeps `// c` on the last element: the parser read the `,` first. Written without the `,` the
 * next parse meets `{b: 1} // c`, and whatever construct ends the element may take the comment into a slot of its own
 * (`TailComments.rehome_<T>` answers which, mirroring the parser). Laying the list out from the source tree would then
 * put the comment outside an element the next write reads it inside of, so the two writes disagree. `last` hands the
 * writer the tree the next parse builds instead: the last element with the comment moved into its tail, no separator
 * after it. Every other list — a kept separator, no comment, a comment the source wrote before the separator, a block
 * comment, a tail that captures nothing — comes back as the same array.
 */
@:nullSafety(Strict)
final class DroppedSepComment {

	/**
	 * `arr` with its last element read as the next parse reads it once the writer drops its separator; `arr` itself
	 * unless `sepEmitted` is false, the element carries a line comment and `rehome` places it inside the element.
	 *
	 * Whether the source wrote the comment before or after its separator does not matter: with no separator written,
	 * the next parse meets the element and the comment either way. A parsed tree never even holds a before-separator
	 * comment on a tail that captures — that tail took it when the source was parsed. A block comment stays where it
	 * is: one after a dropped separator already reads back the way the first write lays it out.
	 */
	public static function last<T>(arr: Array<Trivial<T>>, sepEmitted: Bool, rehome: (T, String) -> Null<T>): Array<Trivial<T>> {
		if (sepEmitted || arr.length == 0) return arr;
		final t: Trivial<T> = arr[arr.length - 1];
		final comment: Null<String> = t.trailingComment;
		if (comment == null || !StringTools.startsWith(comment, '//')) return arr;
		final rehomed: Null<T> = rehome(t.node, comment);
		if (rehomed == null) return arr;
		final node: T = rehomed;
		final out: Array<Trivial<T>> = arr.copy();
		out[out.length - 1] = {
			blankBefore: t.blankBefore,
			blankBefore2: t.blankBefore2,
			blankAfterLeadingComments: t.blankAfterLeadingComments,
			newlineBefore: t.newlineBefore,
			leadingComments: t.leadingComments,
			trailingComment: null,
			trailingBeforeSep: false,
			sepAfter: false,
			newlineAfterSep: t.newlineAfterSep,
			leadingCommentsGlued: t.leadingCommentsGlued,
			node: node
		};
		return out;
	}

}
