package anyparse.format.text;

/**
 * One line of a block comment's interior: leading whitespace + body.
 * See `BlockComment` for the package-level rationale.
 */
@:peg
@:raw
@:schema(anyparse.format.text.CFamilyCommentFormat)
typedef BlockCommentLine = {
	var ws:BlockCommentLineWs;
	var body:BlockCommentLineBody;
};
