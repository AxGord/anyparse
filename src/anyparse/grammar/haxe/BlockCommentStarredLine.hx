package anyparse.grammar.haxe;

/**
 * Body struct for the `StarredLine` variant of `BlockCommentLine`.
 *
 * A javadoc-style body line: optional leading whitespace + `*`
 * marker + optional separator space + content. Three fields:
 * `ws` captures leading ws verbatim (for common-prefix reduce);
 * `marker` captures the `*` + optional separator space;
 * `content` captures everything after, up to the next newline or
 * the body close delimiter.
 *
 * Separate typedef (rather than inline constructor args) because
 * the macro's enum-branch lowering handles only single-Ref
 * variants — wrapping the two fields in a struct gives the variant
 * a single-Ref shape while keeping grammar intent clean.
 */
@:peg
@:raw
@:schema(anyparse.grammar.haxe.HaxeFormat)
typedef BlockCommentStarredLine = {
	var ws:BlockCommentLineWs;
	var marker:BlockCommentLineStarMarker;
	var content:BlockCommentLineContent;
}
