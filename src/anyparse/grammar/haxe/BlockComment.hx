package anyparse.grammar.haxe;

/**
 * Grammar root for a captured block-comment token (multi-line or not).
 *
 * Two structural variants, distinguished by the open/close delimiter
 * pair — parser selects by source-literal match:
 *
 *  - `DoubleStars` — `/** … **\/` (canonical Javadoc / Haxe doc-block shape).
 *  - `Plain` — `/* … *\/` (C-family plain block). Also captures mixed
 *    `/** … *\/` source via absorption of the extra leading `*` into
 *    the first interior line's content.
 *
 * Wrap literals live in `@:lead` / `@:trail` metas on each variant
 * constructor — the single source of truth. Downstream code (parser,
 * writer, normalizer) never hardcodes `/*`/`/**`/`*\/`/`**\/` strings.
 *
 * Body is `Array<BlockCommentLine>` — each line is a `{ws, content}`
 * struct (see `BlockCommentLine`). `@:sep('\n')` separates interior
 * lines at parse time; at write time the newline-sep case is rendered
 * via hardline joins (see `emitWriterStarField`'s `@:sep('\n')` path).
 *
 * `@:raw` suppresses `skipWs` inside the captured body: comment
 * interior whitespace is significant (preserved for common-prefix
 * reduce in the plugin normalizer).
 */
@:peg
@:raw
@:schema(anyparse.grammar.haxe.HaxeFormat)
enum BlockComment {

	@:lead('/**') @:trail('**/') @:sep('\n')
	DoubleStars(lines:Array<BlockCommentLine>);

	@:lead('/*') @:trail('*/') @:sep('\n')
	Plain(lines:Array<BlockCommentLine>);
}
