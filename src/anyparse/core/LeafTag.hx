package anyparse.core;

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

}
