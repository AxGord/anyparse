package anyparse.grammar.haxe;

/**
 * The one grammar fact behind "is this bracketed list a comprehension?":
 * which `HxExpr` constructors can sit as an array comprehension's
 * GENERATOR element.
 *
 * It has to be readable from BOTH compilation contexts, and that is the
 * only reason it lives in a module of its own. At macro time
 * `HxAstPredLowering.arrayBracketKindField` compiles it into the generated
 * `arrayBracketKind` predicate's kind-2 arm; at runtime
 * `HaxeFormat.isComprehensionGenerator` tests a `Type.enumConstructor`
 * against it. Neither of those two can host it: the lowering lives behind
 * `#if macro`, so no runtime consumer could read it back, and reading the
 * list off `HaxeFormat` fails the macro build outright — measured, with
 * `You cannot use @:build inside a macro`, because `HaxeFormat` reaches
 * `anyparse.format.comment.BlockCommentNormalizer` (a fully qualified
 * reference in its `blockCommentAdapter` field, not an import) and that
 * reaches the `@:build`-generated `BlockCommentParser`.
 *
 * So the constraint on THIS module is its type closure, not its import
 * count: it must not reach a `@:build`-generated type. Naming `HxExpr` here
 * would be safe (a macro can use its values; `HxComplexItems` is macro-read
 * fine despite `using Lambda`); naming `AstPreds` / `AstPredsT` /
 * `AstPredsS`, `HaxeFormat`, or anything reaching
 * `anyparse.format.comment.*` is what breaks it.
 *
 * The two classifiers stay separate because they answer for different
 * input types — `arrayBracketKind` is a typed `Null<HxExpr>` predicate on
 * the generated `AstPreds` marker class, reachable only through
 * `AstPredLowering.predCallExpr`, while `isComprehensionGenerator` answers
 * for an untyped element that may be a trivia-synth wrapper or a
 * non-`HxExpr` Star payload. Only this list is shared, and a new generator
 * ctor is taught here once.
 */
final class HxComprehension {

	/**
	 * `HxExpr` constructors that make a bracketed list a comprehension rather than an array literal.
	 *
	 * `ForReifExpr` — the twin projected whenever the loop head goes beyond what `HxForExpr` models —
	 * belongs here for the same reason `ForExpr` does: the source says `for`. The arrow head is NOT the
	 * discriminator, `HxForExpr` takes one; what it cannot model is a non-identifier VALUE slot, since
	 * its `HxKeyValueBinder` holds a single `HxIdentLit`. So `[for (k => v in m) …]` is a plain
	 * `ForExpr`, while `[for (k => v.q in m) …]` and a reified `macro [for ($i{n} in xs) …]` head both
	 * fall through to this ctor.
	 *
	 * It was held OUT until this slice because adding it turned `other/for_with_macro_reification.hxtest`
	 * PASS -> FAIL, and S16 isolated where: the first-element source-newline scan in
	 * `TriviaSepLowering.triviaSepPredicateScanExpr` carves comprehensions out of the
	 * `reflowSourceMultiline` suppression, and element 0 was inheriting a newline captured BEFORE the
	 * `[` — so a bracket the source wrote flat broke open the moment this ctor started answering
	 * "comprehension". Deleting the carve-out instead made that fixture pass and cost
	 * `wrapping/issue_238_keep_wrapping_nowrap.hxtest`: net 0, refused with the number.
	 *
	 * What unblocked the append is positional and lives in the PARSER, not in either classifier —
	 * `Lowering.lowerTriviaStarBranch` and `Lowering.emitTriviaStarFieldSteps` clear the pending stash
	 * newline right after their open literal, because consuming `[` proves the elements are inside it.
	 * With that in place the append moves ZERO corpus fixtures (both named above stay PASS), and
	 * `HxComprehensionBracketPolicyTest.testReifiedForHeadIsComprehension` pins what it buys:
	 * `[for (k => v.q in m) k]` now takes the comprehension bracket policy.
	 *
	 * NOT the whole story for `arrayBracketKind`, which reads this list through
	 * `HxAstPredLowering.arrayBracketKindField`: what S16 landed there is only the reachable HALF of a
	 * whole-list `=>` scan — a wrapper recursion on the FIRST element; the whole-list half stays open by
	 * design.
	 *
	 * The note that stood here before the append said the reification fixture is a map comprehension the
	 * fork calls a map LITERAL, and that the append needed a depth-0 `=>` scan. Both halves are measured
	 * wrong: `determinBkChildren` returns `Comprehension` from its first-child loop before it ever scans
	 * for `=>`, and under a comprehension-padded config the fork pads that very fixture.
	 */
	public static final GENERATOR_CTORS: Array<String> = ['ForExpr', 'ForReifExpr', 'WhileExpr'];

}
