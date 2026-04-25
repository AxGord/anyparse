package anyparse.grammar.haxe;

/**
 * Grammar root for a captured block-comment token (multi-line or not).
 *
 * Single-shape body: `Array<BlockCommentLine>` between alternative
 * wrap pairs declared on the `lines` field via `@:lead` / `@:trail`
 * (primary `/* … *\/` Plain pair) and `@:fmt(altWrap(...))` (alt
 * `/** … **\/` DoubleStars pair, dispatched by `opt.commentStyle`).
 *
 * Parser tries the primary `/*` open + `*\/` close first; on `**\/`
 * close failure (DoubleStars source) rolls back and tries the alt
 * `/**` open + `**\/` close. Mixed `/** … *\/` source rolls back
 * from the alt close failure to the primary, where the `/*` open
 * absorbs the leading `*` into the body's first line content.
 *
 * Writer emits the wrap pair selected at runtime by
 * `opt.commentStyle`: `Plain` → primary `/* … *\/`; `Javadoc` /
 * `JavadocNoStars` → alt `/** … **\/`. The AST itself does NOT
 * carry which wrap the source had — wrap is policy, not structure.
 *
 * `@:raw` suppresses `skipWs` inside the captured body: comment
 * interior whitespace is significant (preserved for common-prefix
 * reduce in the plugin normalizer).
 */
@:peg
@:raw
@:schema(anyparse.grammar.haxe.HaxeFormat)
typedef BlockComment = {
	@:lead('/*') @:trail('*/') @:sep('\n')
	@:fmt(altWrap('commentStyle', 'Javadoc|JavadocNoStars', '/**', '**/'))
	var lines:Array<BlockCommentLine>;
};
