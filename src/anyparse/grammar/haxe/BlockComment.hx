package anyparse.grammar.haxe;

/**
 * A captured block-comment token. The AST is intentionally trivial —
 * a comment is opaque text between `/*` and `*\/`. Whatever bytes sit
 * between the wrap delimiters land in `content` verbatim, including
 * any `*` runs adjacent to the wrap (`/**` open or `**\/` close) and
 * any per-line ` * ` markers inside javadoc-style bodies.
 *
 * Output style is policy, not structure. By default
 * (`commentStyle: Verbatim`) the writer emits `/*` + content + `*\/`
 * byte-identical. With an explicit `commentStyle:
 * Plain|Javadoc|JavadocNoStars` the writer's
 * `HaxeCommentNormalizer.processCapturedBlockComment` adapter runs an
 * opt-in canonicalization pass on the content string before emit.
 *
 * `@:raw` suppresses `skipWs` between the wrap delimiters and the
 * captured content terminal.
 */
@:peg
@:raw
@:schema(anyparse.grammar.haxe.HaxeFormat)
typedef BlockComment = {
	@:lead('/*') @:trail('*/') var content:BlockCommentContent;
};
