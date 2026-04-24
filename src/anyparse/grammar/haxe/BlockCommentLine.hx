package anyparse.grammar.haxe;

/**
 * One line of a captured block-comment body.
 *
 * Two structural variants, distinguished by presence of a javadoc
 * `*` marker — parser selects by source match:
 *
 *  - `StarredLine(body:BlockCommentStarredLine)` — `<ws>*<sp?><content>`.
 *    Marker captured verbatim so round-trip preserves author spacing
 *    (` * foo`, `*foo`, `\t * foo`, …).
 *  - `PlainLine(body:BlockCommentPlainLine)` — `<ws><content>`, no star
 *    marker. Leading ws preserved for relative-offset calculations.
 *
 * Parser tries StarredLine first (more specific — requires a `*`
 * that isn't part of the body close) and falls back to PlainLine.
 * Writer round-trips via the stored fields.
 *
 * Each variant wraps its fields in a struct typedef
 * (`BlockCommentStarredLine` / `BlockCommentPlainLine`) because
 * the macro's enum-branch lowering handles only single-Ref
 * variants.
 *
 * `@:raw` suppresses `skipWs` in the generated parse function for
 * this enum: the fields inside each wrapped struct are adjacent
 * bytes in source, not whitespace-separated tokens.
 */
@:peg
@:raw
@:schema(anyparse.grammar.haxe.HaxeFormat)
enum BlockCommentLine {

	StarredLine(body:BlockCommentStarredLine);

	PlainLine(body:BlockCommentPlainLine);
}
