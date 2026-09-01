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
	 * `ForReifExpr` — the twin projected whenever the loop head goes beyond what `HxForExpr` models.
	 * That production DOES take an arrow head, but its value slot is a bare `HxKeyValueBinder`
	 * (one `HxIdentLit`), so `[for (k => v.f in m) …]` and `macro [for ($i{n} in xs) …]` both fall
	 * through to the reified ctor — is DELIBERATELY absent, and the measurement is the reason.
	 * Adding it is one token and it answers a real gap: the fork reads the token that FOLLOWS `[`
	 * and calls every `for`-headed list a comprehension, this list does not. But it turns
	 * `other/for_with_macro_reification.hxtest` PASS -> FAIL, and S16 measured where.
	 *
	 * NOT in `arrayBracketKind`: under that fixture config `comprehensionBrackets` and
	 * `arrayLiteralBrackets` are the same policy, and an arm giving only the predicate the new ctor
	 * leaves the fixture PASSING. The consumer that flips it is the first-element source-newline scan
	 * in `TriviaSepLowering.triviaSepPredicateScanExpr`, whose carve-out — a comprehension element
	 * genuinely starts on its own line after `[` — fires on a newline preceding the whole ENCLOSING
	 * statement, because the first element inherits the pending trivia captured before the `[`. That
	 * defect is already live for a plain `ForExpr`: the same source shape with
	 * `[for (key in o_ref) key => exprs[0].expr]` breaks its bracket open on the BASE engine while
	 * the fork keeps it flat. Deleting the carve-out makes the fixture pass and costs
	 * `wrapping/issue_238_keep_wrapping_nowrap.hxtest`, which needs it for a genuinely multi-line
	 * nested comprehension — so the fix is POSITIONAL (is the newline inside the bracket), not a
	 * classifier one.
	 *
	 * The note that stood here before said the fixture is a map comprehension the fork calls a map
	 * LITERAL, and that the append should land with a depth-0 `=>` scan. Both halves are measured
	 * wrong: `determinBkChildren` returns `Comprehension` from its first-child loop before it ever
	 * scans for `=>` — under a comprehension-padded config the fork pads that very fixture. What S16
	 * landed is only the reachable HALF of that scan, a wrapper recursion on the FIRST element; the
	 * whole-list half stays open by design (see `HxAstPredLowering.arrayBracketKindField`), and with
	 * the partial scan in place the append still flips the fixture.
	 */
	public static final GENERATOR_CTORS: Array<String> = ['ForExpr', 'WhileExpr'];

}
