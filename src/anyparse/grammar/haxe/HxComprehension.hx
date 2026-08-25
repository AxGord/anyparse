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
	 * `ForReifExpr` — the reified twin, projected only when the loop HEAD carries reification
	 * metavariables (`macro [for ($i{n} in $e{xs}) if (c) n]`; a `for` written with a literal head
	 * inside `macro { … }` is a plain `ForExpr`) — is DELIBERATELY absent, and the measurement is
	 * the reason. Adding it is one token and it does answer a real gap: a wide reified filter
	 * comprehension keeps its bracket shut and breaks inside the filter's `if (` where the fork
	 * opens the bracket. But it also turns `other/for_with_macro_reification.hxtest` PASS -> FAIL.
	 * That fixture is a MAP comprehension (`[for (key => $i{…} in $i{r}) key => ${…}]`), which the
	 * fork calls a map LITERAL — it scans for any `=>` at bracket depth 0, where `arrayBracketKind`
	 * only asks whether the FIRST ELEMENT is an `Arrow`. Today that first element is neither, so the
	 * predicate answers 0, array literal, which happens to render exactly what the fork's 1 does;
	 * a 2 would not. The divergence is recorded in `HxAstPredLowering.arrayBracketKindField` as
	 * costing nothing — the append is what makes it cost. And it buys nothing measurable: byte-inert
	 * across the Pony tree (868 files) and this one (1493). Land it with the depth-0 `=>` scan, not
	 * before.
	 */
	public static final GENERATOR_CTORS: Array<String> = ['ForExpr', 'WhileExpr'];

}
