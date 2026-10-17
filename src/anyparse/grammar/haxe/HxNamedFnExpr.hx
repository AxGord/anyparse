package anyparse.grammar.haxe;

/**
 * The inside of a NAMED function expression — `function name<T>(params):Ret body` in expression
 * position (`HxExpr.NamedFnExpr`). The signature is `HxFnDecl`'s field for field, formatting knobs
 * included, so a named function expression lays out exactly as it did while it reused that typedef.
 *
 * The body is the EXPRESSION-position `HxFnExprBody`, not the member-level `HxFnBody`, and that is
 * the whole reason this typedef exists: `HxFnBody.ExprBody` carries `@:trailOpt(';')`, so in
 * `final g = function named() return 1; // c` + `next();` it swallowed the `;` that terminates the
 * enclosing STATEMENT — the compiler's reading, where an expression body ends at the expression.
 * The statement then had no `;` of its own: an assignment statement (`g = function n() return 1;
 * next();`) failed to parse, a comment after the `;` hid the block's statement boundary from the
 * plain parser, and the trivia parser re-attached that comment as the NEXT statement's leading one.
 * `HxFnExprBody` owns no terminator, so the `;` is the statement's, as it is after an anonymous
 * `function () return 1;`.
 *
 * The forms `HxFnBody` has and this body does not: `NoBody` (a bare `;` is no expression body),
 * `CondBody` (a `#if` region as the whole body), and `UntypedBlockBody`, which reads here as an
 * `ExprBody` holding an `untyped` block expression — the same reading an anonymous function's
 * `untyped { … }` body gets.
 */
@:peg
@:fmt(multilineWhenFieldShape('body'))
typedef HxNamedFnExpr = {
	var name: HxFnNameLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var typeParams: Null<Array<HxTypeParamDecl>>;
	@:trivia @:lead('(') @:trail(')') @:sep(',') @:fmt(trailingComma('trailingCommaParams'), funcParamParens,
		wrapRules('functionSignatureWrap'), bodyAwareCompactIndent, groupRestProbe, ignoreSourceNewlinesForWrap) var params: Array<HxParam>;
	@:optional @:fmt(typeHintColon) @:lead(':') var returnType: Null<HxType>;
	@:fmt(leftCurly('blockLeftCurly'), bodyPolicyForCtor('ExprBody', 'functionBody'), metaBlockGlue('ExprBody', 'MetaExpr', 'BlockExpr'))
	var body: HxFnExprBody;
}
