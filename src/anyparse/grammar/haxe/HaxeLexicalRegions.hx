package anyparse.grammar.haxe;

/**
 * The HAXE lexers this grammar publishes, GENERATED from its own declarations. No AST, no
 * `QueryNode`, no parse — just bytes.
 *
 * TWO scans, because two consumers ask different questions and one answer cannot serve
 * both: `scan` (behind `GrammarPlugin.lexicalRegions`) maps a source to its NON-CODE
 * regions — comment, string literal, regex literal — for the occurrence scans that mask
 * them; `scanComments` (behind `anyparse.format.comment.CommentScan`) reports only
 * COMMENTS, and follows a `${ … }` interpolation hole into the code inside it, for the
 * writer's comment-loss guard. Here they are two FILTERS over ONE generated walk rather
 * than two lexers, and their one disagreement is a declared policy — stated on `scanComments`.
 *
 * ## Why it lives HERE
 *
 * Everything it answers is Haxe syntax: single-quote interpolation, `${ … }` holes,
 * `~/ … /` literals, `//` and block comments. `scan` sat in `anyparse.query.LexicalRegions`,
 * which made a grammar-agnostic package the home of one grammar's lexer — invariant 4 ("a new
 * language is a new package, not a core change"): a second grammar could not answer the same
 * question without editing core code. It now reaches every consumer that holds a plugin
 * through `GrammarPlugin.lexicalRegions(source)`, beside `controlFlowSupport()`.
 *
 * `scanComments` came from `anyparse.format.comment.CommentInventory`, where the same debt
 * sat one package over: the comment-preservation audit carried its own Haxe state machine
 * because the Haxe writer was its only consumer. It reaches that package as a
 * `CommentScan` the caller supplies.
 *
 * `anyparse.query.LexicalRegions` keeps the region TYPES and the two pure helpers over a
 * region array, which are grammar-agnostic. The deprecated forwarder it also carried,
 * for callers that held no plugin, is gone since S60 — every consumer now arrives
 * through the seam.
 *
 * ## Why the scan is correct where a naive one is not
 *
 * Every consumer of `RefactorSupport.collectCommentTokens` — most of the tool — depends on
 * this being right, and for a long time a defect in it only made an occurrence COUNT wrong,
 * which nothing acted on. Then it began gating a DELETE: the hand scanner's string walk
 * mis-paired the quotes of `'${cond ? '// note' : X}'`, the region ended mid-expression, the
 * `//` inside opened a comment region over live source, and `unused-import --fix` removed an
 * import the commented-over line was using (`Type not found : Dep`, compile-proved).
 *
 * ## Why there is no hand state machine here any more
 *
 * S55 measured both ways of deriving this scan and refused both. The FIRST refusal stands and
 * is not re-opened; the second was overruled by the user and built as S66.
 *
 *  - From a full PARSE: REFUSED, permanently. 116 of 6784 real sources do not parse at all
 *    (115 of the corpus 1890, 6.1 %), and this scan is handed RAW source everywhere, with no
 *    promise that it parses: `RefactorSupport.nameBoundInRange` says so in code, falling back
 *    to the pure text scan the moment `classifyOccurrences` reports the file did not parse.
 *    Even where the parse succeeds the tree carries no node for a string literal in three
 *    positions — a conditional-compilation CONDITION, a `#error` message, and a quoted
 *    object-literal KEY, whose text the projection folds into the field node name slot. That
 *    is 34 of 1775 parsed corpus sources and 83 of 3340 parsed real-world files. The direction
 *    is uniformly tree-BLIND, never scanner-blind, which is the safe one: an unmasked region
 *    costs a refusal, a missed one costs a delete.
 *  - From a generated LEXICAL-ONLY pass: BUILT, and this class has no body of its own any
 *    more. Every ingredient was already declarative and half of it already read at macro time
 *    (`HaxeFormat.lineComment` / `blockComment` through `FormatReader.commentPatterns`, the
 *    literal terminals' own `@:re`, the interpolating string's `@:lead` / `@:trail` over its
 *    segment enum). S66 added the two that were missing: `@:lexical(<Kind>)`, which says a
 *    rule IS a non-code region and which kind it carries, and `@:balanced('{', '}')` on the
 *    hole segment — where a `${ … }` hole ENDS is the brace-and-quote balancing no declaration
 *    expressed, and the deleted `skipInterpolationHole` was the only thing that knew it.
 *    `Build.buildLexicalScan` runs `LexicalLowering` then `LexicalCodegen`; nothing about Haxe
 *    survives as a literal in either, which is what lets a second grammar declare its own.
 *
 * The equivalence was measured BEFORE the hand scanner was deleted — generated against hand,
 * region-for-region and comment-for-comment over 6804 sources (150 834 regions, 61 458
 * comments): this project, the haxe-formatter `.hxtest` corpus input and expected, Pony's
 * `src`, the haxe-formatter sources and the Haxe 4.3.7 standard library. 0 divergences in
 * either direction, the 116 unparseable sources included.
 *
 * `unit.LexicalRegionAgreementTest` is the standing pin: every outermost literal NODE must be
 * an exactly-equal region here, this pass must agree with `CommentInventory.scan` on every
 * comment of every file in the tree, and the delimiters are checked against what `HaxeFormat`
 * DECLARES. Both historical corruptions above are caught by it — verified by mutation, arms
 * named in that class.
 */
@:nullSafety(Strict)
@:build(anyparse.macro.Build.buildLexicalScan(anyparse.grammar.haxe.HxModule))
final class HaxeLexicalRegions {}
