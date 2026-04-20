package anyparse.grammar.haxe;

/**
 * Closed set of values the haxe-formatter `emptyLines.*` fields of
 * type `CommentEmptyLinesPolicy` accept
 * (`afterFieldsWithDocComments`, `beforeDocCommentEmptyLines`).
 * Mirrors `formatter.config.CommentEmptyLinesPolicy` in the fork's
 * schema 1:1 so a `hxformat.json` written for upstream haxe-formatter
 * parses without unknown-value errors.
 *
 * Mapped by `HaxeFormatConfigLoader` to
 * `anyparse.format.CommentEmptyLinesPolicy`:
 *
 * - `"ignore"` → `CommentEmptyLinesPolicy.Ignore`
 * - `"none"`   → `CommentEmptyLinesPolicy.None`
 * - `"one"`    → `CommentEmptyLinesPolicy.One`
 */
enum abstract HxFormatCommentEmptyLinesPolicy(String) to String {

	final Ignore = 'ignore';

	final None = 'none';

	final One = 'one';
}
