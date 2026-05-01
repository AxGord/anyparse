package anyparse.format.comment;

/**
 * One line of a block comment's interior: leading whitespace + body.
 * See `BlockComment` for the package-level rationale.
 */
@:peg
@:raw
@:schema(anyparse.format.comment.CFamilyCommentFormat)
typedef BlockCommentLine = {
	var ws:BlockCommentLineWs;
	var body:BlockCommentLineBody;
};
