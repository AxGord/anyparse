package anyparse.format.comment;

/**
 * A grammar's COMMENT lexer, handed to the comment-preservation machinery of this
 * package so that machinery stays grammar-agnostic.
 *
 * `scan(source, onComment)` reports every comment of `source` as a `[start, end)`
 * byte span, in source order, with the grammar's string and regex literals skipped
 * so a comment opener inside one never counts. Nothing else about the shape of a
 * comment is assumed here: `CommentInventory` normalises whatever text the spans
 * cover, and `FormatterOff` matches its markers against it.
 *
 * WHY A SEAM AND NOT A SHARED SCAN: this package used to carry a Haxe state machine
 * (`'…'` interpolation frames, `$$`, `~/…/`) because the Haxe writer was its only
 * consumer — one grammar's syntax deciding what a comment is for every language,
 * which is invariant 4 in reverse. The lexer now lives beside the grammar's other
 * one, `anyparse.grammar.haxe.HaxeLexicalRegions.scanComments`, and reaches here as
 * this function.
 *
 * NOT interchangeable with `GrammarPlugin.lexicalRegions` filtered to its comment
 * regions: the two answers differ DELIBERATELY inside a string-interpolation hole —
 * see `HaxeLexicalRegions.scanComments`, and `unit.LexicalRegionAgreementTest`,
 * which pins both.
 */
typedef CommentScan = (source:String, onComment:(start:Int, end:Int) -> Void) -> Void;
