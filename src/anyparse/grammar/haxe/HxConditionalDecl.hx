package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <decls> [#elseif <cond> <decls>]* [#else <decls>] #end` preprocessor-guarded
 * module-level region: the enclosing `HxDecl.Conditional` ctor consumes the `#if` keyword and the trailing
 * `#end`; this typedef covers the content between.
 *
 * Element type is `HxTopLevelDecl` (not bare `HxDecl`) so leading metadata + modifiers inside the region parse
 * through the same meta + modifier Stars used at module top level. The body's `@:tryparse` Star terminates
 * when the next token is not a recognised `HxTopLevelDecl` start — `#elseif`, `#else` and `#end` fail every
 * modifier and decl-keyword dispatch path. Nested `#if` is supported transitively through
 * `HxDecl.Conditional`. `elseifs:Array<HxElseifDecl>` sits between `body` and `elseBody`, each clause carrying
 * the `#elseif` keyword on its first field's metadata (`HxCatchClause` precedent); the position before
 * `elseBody` is mandatory so the clause loop terminates before the optional `#else`. `@:optional @:kw('#else')
 * @:tryparse var elseBody` uses the kw-led optional Star path (`emitOptionalKwStarFieldSteps`): `#else` is the
 * commit point, a miss leaves `null`.
 *
 * Writer-side output mirrors `HxConditionalMod`: `@:fmt(padLeading, padTrailing, conditionalBodyIndent)` on
 * `body` and `elseBody` adds a leading + trailing pad around each Star when non-empty, closing the
 * `#if`/`#else`/`#end` boundary gaps; the pads switch from a space to a hardline when the first body element's
 * `newlineBefore` slot is set. Both Stars also opt into the inter-element blank-line cascade of
 * `HxModule.decls` (the six-meta cluster documented on `HxModule`, same arg strings, so a nested `#if … #end`
 * still routes through the leaf classifier), so `betweenImports` fires inside a `#if php` body too.
 *
 * `trailingMeta` captures metadata left DANGLING at the end of the region — tags that belong to the
 * declaration AFTER `#end`, written inside the guard so they apply only under the condition (`#if lime_cffi
 * import …; @:access(NativeCFFI) #end @:access(Bytes) abstract D(…)`). Without the slot the `body` Star's last
 * iteration parses the `@:access` into a `HxTopLevelDecl.meta` prefix, fails on the mandatory `decl` field at
 * `#end`, rewinds, and leaves the metadata unconsumed in front of the outer `@:trail('#end')`. A trailing Star
 * is strictly additive — empty for every shape that parsed before; widening `HxCondDeclPrefix` with an
 * `import` arm instead would let the metadata Star (tried BEFORE the decl dispatch) claim every import-ONLY
 * region and strip it of these cascades. It carries `@:fmt(padTrailing)` and NOT `padLeading`: the leading pad
 * fires on an EMPTY Star and would insert a blank line before `#end` in every module-level region. `#else` /
 * `#elseif` carry the same slot (`elseTrailingMeta`, `HxElseifDecl.trailingMeta`): `#if macro <imports> #else
 * @:autoBuild(...) #end interface X {}` is valid Haxe. The gap between the last body decl and the dangling
 * metadata is left to `body`'s own `padTrailing`, which costs the blank line the source had there — a
 * byte-fidelity gap only, the emitted form re-parses unchanged. LAYOUT WART: an alternative branch holding
 * ONLY metadata renders `@:keep #end` on one line — `padTrailing` on the meta Star takes its newline signal
 * from a non-empty preceding body and there is none; valid, re-parses, a fixed point.
 */
@:peg
typedef HxConditionalDecl = {
	var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent)
	@:fmt(blankLinesOnTransitionAcross(
		'decl', 'ImportDecl', 'ImportAliasDecl', 'ImportAliasInDecl', 'ImportWildDecl', '|', 'UsingDecl', 'UsingWildDecl', 'beforeUsing'
	))
	@:fmt(blankLinesOnTransitionAcross(
		'decl', 'ImportDecl', 'ImportAliasDecl', 'ImportAliasInDecl', 'ImportWildDecl', 'UsingDecl', 'UsingWildDecl', '|', 'ClassDecl',
		'InterfaceDecl', 'AbstractDecl', 'EnumDecl', 'FinalDecl', 'AbstractClassDecl', 'EnumAbstractDecl', 'TypedefDecl', 'FnDecl',
		'beforeType'
	))
	@:fmt(blankLinesBetweenSameCtorByLevel(
		'decl', 'ImportDecl', 'ImportAliasDecl', 'ImportAliasInDecl', 'ImportWildDecl', 'betweenImportsLevel', 'betweenImports',
		'betweenImportsPathDiffers'
	))
	@:fmt(blankLinesBetweenSameCtorByLevel(
		'decl', 'UsingDecl', 'UsingWildDecl', 'betweenImportsLevel', 'betweenImports', 'betweenImportsPathDiffers'
	))
	@:fmt(blankLinesBetweenSameCtorTailTransparent('decl', 'Conditional', 'betweenImportsTailLeafClassify'))
	@:fmt(blankLinesBetweenSameCtorHeadTransparent('decl', 'Conditional', 'betweenImportsHeadLeafClassify'))
	var body: Array<HxTopLevelDecl>;
	@:trivia @:tryparse @:fmt(padTrailing) var trailingMeta: Array<HxMetadata>;
	@:trivia @:tryparse var elseifs: Array<HxElseifDecl>;
	@:optional @:kw('#else') @:trivia @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent)
	@:fmt(blankLinesOnTransitionAcross(
		'decl', 'ImportDecl', 'ImportAliasDecl', 'ImportAliasInDecl', 'ImportWildDecl', '|', 'UsingDecl', 'UsingWildDecl', 'beforeUsing'
	))
	@:fmt(blankLinesOnTransitionAcross(
		'decl', 'ImportDecl', 'ImportAliasDecl', 'ImportAliasInDecl', 'ImportWildDecl', 'UsingDecl', 'UsingWildDecl', '|', 'ClassDecl',
		'InterfaceDecl', 'AbstractDecl', 'EnumDecl', 'FinalDecl', 'AbstractClassDecl', 'EnumAbstractDecl', 'TypedefDecl', 'FnDecl',
		'beforeType'
	))
	@:fmt(blankLinesBetweenSameCtorByLevel(
		'decl', 'ImportDecl', 'ImportAliasDecl', 'ImportAliasInDecl', 'ImportWildDecl', 'betweenImportsLevel', 'betweenImports',
		'betweenImportsPathDiffers'
	))
	@:fmt(blankLinesBetweenSameCtorByLevel(
		'decl', 'UsingDecl', 'UsingWildDecl', 'betweenImportsLevel', 'betweenImports', 'betweenImportsPathDiffers'
	))
	@:fmt(blankLinesBetweenSameCtorTailTransparent('decl', 'Conditional', 'betweenImportsTailLeafClassify'))
	@:fmt(blankLinesBetweenSameCtorHeadTransparent('decl', 'Conditional', 'betweenImportsHeadLeafClassify'))
	var elseBody: Null<Array<HxTopLevelDecl>>;
	@:trivia @:tryparse @:fmt(padTrailing) var elseTrailingMeta: Array<HxMetadata>;
};
