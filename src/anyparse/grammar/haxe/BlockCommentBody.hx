package anyparse.grammar.haxe;

/**
 * Grammar root for a captured multi-line `/*…*\/` block-comment body.
 *
 * Parses the verbatim string Trivia-mode captures for a leading block
 * comment (delimiters included) into a typed list of interior lines.
 * Downstream `anyparse.runtime.CommentLayout` reads `lines` at write
 * time and re-indents each line to match the current writer's
 * `indentChar` / `indentSize` / `tabWidth`.
 *
 * `@:lead('/*') @:trail('*\/')` brackets the Star; `@:sep('\n')`
 * separates line elements. The Star's close-peek entry guard is
 * `peekLit`-based (full-string), not single-byte — a post-macro
 * upgrade that lets `BlockCommentLine` legitimately start with `*`
 * (javadoc `/**` style) without the Star short-circuiting.
 *
 * `@:raw` suppresses `skipWs` in the generated parse function:
 * comment interior is whitespace-sensitive and any `skipWs` would
 * drop leading indent from every line.
 *
 * Schema is `HaxeFormat` because `/*…*\/` is specifically the
 * C-family block-comment convention this project exercises. A
 * future non-C-family grammar (Haskell `{- -}`, OCaml `(* *)`)
 * would author its own analogue pointing at its own format's
 * `blockComment`.
 */
@:peg
@:raw
@:schema(anyparse.grammar.haxe.HaxeFormat)
typedef BlockCommentBody = {
	@:lead('/*') @:trail('*/') @:sep('\n')
	var lines:Array<BlockCommentLine>;
}
