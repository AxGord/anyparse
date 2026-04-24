package anyparse.grammar.haxe;

/**
 * One line of a captured block-comment body.
 *
 * Four variants — two permissive source-verbatim forms for parser
 * capture and two canonical grammar-literal forms for normalizer
 * output:
 *
 *  - `StarredLine(body:BlockCommentStarredLine)` — `<ws>*<sp?><content>`.
 *    Permissive; marker captured verbatim so round-trip preserves
 *    author spacing (` * foo`, `*foo`, `\t * foo`, …).
 *  - `PlainLine(body:BlockCommentPlainLine)` — `<ws><content>`, no star
 *    marker. Permissive leading-ws capture for relative-offset
 *    calculations.
 *  - `JavadocLine(content:BlockCommentLineContent)` — `@:lead(' * ')`
 *    declares the canonical javadoc content-line prefix at the
 *    grammar level. Emitted by `HaxeCommentNormalizer` when writing
 *    `commentStyle == Javadoc`; parser never produces this variant
 *    because the permissive `StarredLine`/`PlainLine` pair always
 *    catches the input first.
 *  - `JavadocBlankLine` — `@:lit(' *')` declares the canonical
 *    javadoc blank-line shape at the grammar level. Same
 *    parser-unreachable / normalizer-emitted role as `JavadocLine`.
 *
 * The canonical variants are the single source of truth for the
 * literal strings the normalizer would otherwise have had to
 * hardcode. Parser matches against `StarredLine`/`PlainLine` first
 * (declaration order); tryBranch rollback semantics mean the
 * canonical variants are dead dispatch at parse time but live
 * dispatch at write time — the writer matches every variant the
 * normalizer can produce and emits the declared literals verbatim.
 *
 * Each permissive variant wraps its fields in a struct typedef
 * (`BlockCommentStarredLine` / `BlockCommentPlainLine`) because
 * the macro's enum-branch lowering handles only single-Ref
 * variants.
 *
 * `@:raw` suppresses `skipWs` in the generated parse/write function
 * for this enum: the fields inside each wrapped struct are adjacent
 * bytes in source, not whitespace-separated tokens, and the
 * canonical variants' lead/lit literals include their own leading
 * space verbatim.
 */
@:peg
@:raw
@:schema(anyparse.grammar.haxe.HaxeFormat)
enum BlockCommentLine {

	StarredLine(body:BlockCommentStarredLine);

	PlainLine(body:BlockCommentPlainLine);

	@:lead(' * ')
	JavadocLine(content:BlockCommentLineContent);

	@:lit(' *')
	JavadocBlankLine;
}
