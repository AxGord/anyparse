package anyparse.grammar.haxe;

/**
 * Pattern-body Alt-enum for a `case` pattern element. Distinguishes the
 * Haxe pattern-only `case var <ident>:` capture from a regular pattern
 * expression (`case 1:`, `case Foo(a):`, `case "x":`).
 *
 * `@:kw('var') Capture(name:HxVarNameLit)` consumes only the `var`
 * keyword plus the binding name and stops — no `:Type` hint, no `=
 * init`, no accessor, no multi-`,`-binding tail. This matters because
 * the outer `HxCaseBranch.patterns` is a `@:sep(',') @:trail(':')` Star
 * and the trailing `:` is the case-element terminator; routing
 * `var bar:` through `HxExpr.VarExpr` (whose `HxVarDecl` has
 * `@:optional @:lead(':')` for a type hint) would commit the
 * type-hint peek on that terminator `:`, then fail trying to parse the
 * statement body as an `HxType`. The Capture branch sidesteps the
 * problem by never reaching the type-hint slot.
 *
 * `Plain(expr:HxExpr)` is the fallthrough — every existing pattern
 * shape (`IntLit`, `IdentExpr`, `Call`, ternary inside a guard, ...)
 * still parses through here unchanged. Source order matters: Capture
 * (`@:kw('var')` keyword peek) wins on `var <ident>`; everything else
 * (including the inner `Pattern(var foo, var bar)` form, where `var
 * foo` lives inside an `HxExpr` call-arg position and parses through
 * `HxExpr.VarExpr` because the next token is `,` not `:`) falls
 * through to Plain. Slice 34.
 *
 * Used by `HxCasePattern.expr` only — local to the case-pattern call
 * site, identical mechanism to the existing single-Ref Alt-enum
 * wrappers (`HxAnonVarBody`, `HxLambdaParamBody`).
 *
 * The Alt-enum-split shape (over a Boolean `isCapture` flag on
 * `HxCasePattern`) was chosen because the macro pipeline supports
 * `@:optional` only on `Ref` and `Star` fields, and pushing the
 * capture marker into the shared typedef would force `expr` to become
 * nullable and pollute every existing pattern-matching consumer.
 */
@:peg
enum HxCasePatternBody {
	@:kw('var') Capture(name:HxVarNameLit);
	Plain(expr:HxExpr);
}
