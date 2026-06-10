package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <decls>` clause inside a `HxConditionalDecl`'s
 * `elseifs` Star. Carries the `#elseif` keyword on its first field's
 * metadata (HxCatchClause precedent), so the parent's `@:tryparse Star`
 * loop tries the kw at each iteration and naturally terminates when
 * the next token isn't `#elseif`.
 *
 * Body shape mirrors `HxConditionalDecl.body` exactly: trivia-wrapped,
 * tryparse-terminated `Array<HxTopLevelDecl>` Star with
 * `@:fmt(padLeading, padTrailing)` for the leading + trailing pads
 * around the body Star (closes the boundary gaps between `#elseif
 * <cond>` and the body Star, and between the body Star's last element
 * and the next clause's `#elseif` / the trailing `#else` / `#end`).
 *
 * Same blank-line cascade meta cluster as `HxConditionalDecl.body`
 * (slice ω-bug-2c-inner-star) — `betweenSameCtorByLevel` for
 * import / using same-set adjacency, `onTransitionAcross` for the
 * import↔using boundary, head/tail transparent for nested `#if`.
 *
 * Element type is `HxTopLevelDecl` (not bare `HxDecl`) for the same
 * reason `HxConditionalDecl.body` uses it: leading metadata + modifiers
 * inside the clause region parse uniformly through the same meta +
 * modifier Stars used at module top level.
 *
 * Position constraint at the call site (`HxConditionalDecl`): the
 * `elseifs` Star MUST appear before the `elseBody` field so the
 * `#elseif` clauses fully terminate before the optional `#else`
 * dispatch fires.
 */
@:peg
typedef HxElseifDecl = {
	@:kw('#elseif') var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent)
	@:fmt(blankLinesOnTransitionAcross(
		'decl', 'ImportDecl', 'ImportAliasDecl', 'ImportWildDecl', '|', 'UsingDecl', 'UsingWildDecl', 'beforeUsing'
	))
	@:fmt(blankLinesOnTransitionAcross(
		'decl', 'ImportDecl', 'ImportAliasDecl', 'ImportWildDecl', 'UsingDecl', 'UsingWildDecl', '|', 'ClassDecl', 'InterfaceDecl',
		'AbstractDecl', 'EnumDecl', 'TypedefDecl', 'FnDecl', 'beforeType'
	))
	@:fmt(blankLinesBetweenSameCtorByLevel(
		'decl', 'ImportDecl', 'ImportAliasDecl', 'ImportWildDecl', 'betweenImportsLevel', 'betweenImports', 'betweenImportsPathDiffers'
	))
	@:fmt(blankLinesBetweenSameCtorByLevel(
		'decl', 'UsingDecl', 'UsingWildDecl', 'betweenImportsLevel', 'betweenImports', 'betweenImportsPathDiffers'
	))
	@:fmt(blankLinesBetweenSameCtorTailTransparent('decl', 'Conditional', 'betweenImportsTailLeafClassify'))
	@:fmt(blankLinesBetweenSameCtorHeadTransparent('decl', 'Conditional', 'betweenImportsHeadLeafClassify'))
	var body: Array<HxTopLevelDecl>;
};
