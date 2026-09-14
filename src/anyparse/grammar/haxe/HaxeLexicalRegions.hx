package anyparse.grammar.haxe;

/**
 * The HAXE lexers this grammar publishes, GENERATED from its own declarations. No AST, no `QueryNode`, no parse
 * — just bytes.
 *
 * TWO scans, because two consumers ask different questions: `scan` (behind `GrammarPlugin.lexicalRegions`) maps
 * a source to its NON-CODE regions — comment, string literal, regex literal — for the occurrence scans that mask
 * them; `scanComments` (behind `anyparse.format.comment.CommentScan`) reports only COMMENTS, and follows a `${ …
 * }` interpolation hole into the code inside it, for the writer's comment-loss guard. They are two FILTERS over
 * ONE generated walk, and their one disagreement is a declared policy — stated on `scanComments`.
 *
 * ## Why it lives HERE
 *
 * Everything it answers is Haxe syntax: single-quote interpolation, `${ … }` holes, `~/ … /` literals, `//` and
 * block comments. A grammar-agnostic package must not be the home of one grammar's lexer (invariant 4: a new
 * language is a new package, not a core change). Every consumer that holds a plugin reaches it through
 * `GrammarPlugin.lexicalRegions(source)`; `anyparse.query.LexicalRegions` keeps only the region TYPES and the
 * pure helpers.
 *
 * ## Why it is generated and not derived from a parse
 *
 * Every consumer of `RefactorSupport.collectCommentTokens` — most of the tool — depends on this being right, and
 * a defect here gates a DELETE: a hand scanner that mis-paired the quotes of `'${cond ? '// note' : X}'` opened
 * a comment region over live source, and `unused-import --fix` removed an import the commented-over line was
 * using. Deriving the scan from a full PARSE is refused permanently: this scan is handed RAW source everywhere,
 * with no promise that it parses (`RefactorSupport.nameBoundInRange` falls back to the text scan the moment
 * `classifyOccurrences` reports a parse failure), and even a parsed tree carries no node for a string literal in
 * three positions — a conditional-compilation CONDITION, a `#error` message, and a quoted object-literal KEY. An
 * unmasked region costs a refusal, a missed one costs a delete, so the direction must be tree-BLIND. Instead
 * every ingredient is declarative: `HaxeFormat.lineComment` / `blockComment` through
 * `FormatReader.commentPatterns`, the literal terminals' own `@:re`, the interpolating string's `@:lead` /
 * `@:trail` over its segment enum, `@:lexical(<Kind>)` marking a rule as a non-code region of that kind, and
 * `@:balanced('{', '}')` on the hole segment — where a `${ … }` hole ENDS is the brace-and-quote balancing no
 * other declaration expressed. `Build.buildLexicalScan` runs `LexicalLowering` then `LexicalCodegen`; nothing
 * about Haxe survives as a literal in either, which is what lets a second grammar declare its own.
 * `unit.LexicalRegionAgreementTest` is the standing pin: every outermost literal NODE must be an exactly-equal
 * region here, this pass must agree with `CommentInventory.scan` on every comment of every file in the tree, and
 * the delimiters match what `HaxeFormat` DECLARES.
 */
@:nullSafety(Strict)
@:build(anyparse.macro.Build.buildLexicalScan(anyparse.grammar.haxe.HxModule))
final class HaxeLexicalRegions {}
