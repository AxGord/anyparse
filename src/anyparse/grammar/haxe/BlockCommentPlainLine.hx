package anyparse.grammar.haxe;

/**
 * Body struct for the `PlainLine` variant of `BlockCommentLine`.
 *
 * A plain body line with no javadoc `*` marker: leading whitespace
 * (preserved verbatim for relative-offset preservation across
 * lines) + content (everything up to the next newline or the body
 * close delimiter).
 *
 * Separate typedef (rather than inline constructor args) because
 * the macro's enum-branch lowering handles only single-Ref
 * variants — wrapping the two fields in a struct gives the variant
 * a single-Ref shape while keeping grammar intent clean.
 */
@:peg
@:raw
@:schema(anyparse.grammar.haxe.HaxeFormat)
typedef BlockCommentPlainLine = {
	var ws:BlockCommentLineWs;
	var content:BlockCommentLineContent;
}
