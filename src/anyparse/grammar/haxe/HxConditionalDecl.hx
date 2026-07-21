package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <decls> [#else <decls>] #end` preprocessor-
 * guarded module-level region. Mirror of `HxConditionalMod` at the
 * top-level declaration scope: the enclosing `HxDecl.Conditional` ctor
 * consumes the `#if` keyword and the trailing `#end`; this typedef
 * covers the content between them — the condition atom, the then-body
 * Star of further declarations, and an optional `#else` clause with
 * its own decl Star.
 *
 * Element type is `HxTopLevelDecl` (not bare `HxDecl`) so leading
 * metadata + modifiers inside the conditional region parse uniformly:
 * `#if cond @:meta private class Foo {} #end` works through the same
 * meta + modifier Stars used at module top level. The body's
 * `@:tryparse` Star terminates when the next token isn't a recognised
 * `HxTopLevelDecl` start — `#else` and `#end` fail every modifier and
 * decl-keyword dispatch path, so the loop naturally stops there.
 *
 * Nested `#if` is supported transitively through the body re-entering
 * `HxDecl.Conditional` via the dispatch enum's `@:kw('#if')` ctor.
 *
 * `#elseif` chained-clause support landed in slice ω-cond-comp-elseif:
 * `elseifs:Array<HxElseifDecl>` Star sits between `body` and `elseBody`.
 * Each clause is a `HxElseifDecl` typedef carrying the `#elseif`
 * keyword on its first field's metadata (HxCatchClause precedent), so
 * the Star's `@:tryparse` loop dispatches per-iteration and naturally
 * terminates when the next token isn't `#elseif`. Empty Star degrades
 * to `_de()` (no output). Position before `elseBody` is mandatory so
 * the clause loop fully terminates before the optional `#else`.
 *
 * Writer-side output mirrors `HxConditionalMod`: the
 * `@:fmt(padLeading, padTrailing, conditionalBodyIndent)` flag pair on `body` and `elseBody`
 * adds a leading + trailing pad around each Star when non-empty,
 * closing the `#if`/`#else`/`#end` boundary gaps that the default
 * internal-only sep leaves glued. The pads switch from a literal space
 * to a hardline when the first body element's `newlineBefore` slot is
 * set (captured via `@:trivia`), reproducing the multi-line shape the
 * fork's import fixtures exercise (`#if php\nimport php.Lib;\n#end`).
 *
 * Slice ω-bug-2c-inner-star opted `body` and `elseBody` into the
 * inter-element blank-line cascade (mirror of `HxModule.decls`):
 * `blankLinesBetweenSameCtorByLevel` for adjacent imports / usings,
 * `blankLinesOnTransitionAcross` for the import↔using boundary, plus
 * the head/tail transparent-wrapper meta pair so a nested `#if … #end`
 * inside the body still routes through the leaf classifier. Drives
 * fork's `imports_and_using_all` fixture — between two `import …;`
 * decls inside a `#if php` body, fork's `betweenImports=1 +
 * betweenImportsLevel=all` config now fires the same blank-line
 * override anyparse's top-level Star already honored.
 *
 * `trailingMeta` captures metadata left DANGLING at the end of the region
 * - tags that belong to the declaration AFTER `#end`, written inside
 * the guard so they apply only under the condition. Two lime modules
 * need it:
 *
 * ```haxe
 * #if (lime_cffi && !macro)
 * import lime._internal.backend.native.NativeCFFI;
 *
 * @:access(lime._internal.backend.native.NativeCFFI)
 * #end
 * @:access(haxe.io.Bytes)
 * abstract DataPointer(DataPointerType) to DataPointerType
 * ```
 *
 * (`lime/utils/DataPointer.hx`, `lime/tools/HXProject.hx`.)
 *
 * Without the slot the `body` Star's last iteration parses the `@:access`
 * into a `HxTopLevelDecl.meta` prefix, then fails on the mandatory
 * `decl` field when it reaches `#end`, rewinds, and leaves the metadata
 * unconsumed in front of the outer `@:trail('#end')`.
 *
 * The obvious alternative was to widen `HxCondDeclPrefix` with an
 * `import` arm so the WHOLE region rides `HxTopLevelDecl.meta` as a
 * `HxMetadata.Conditional` - the routing trick that arm's doc already
 * describes for `#if (haxe_ver >= 4.0) enum #else @:enum #end`. It was
 * implemented, measured, and rejected: the metadata Star is tried
 * BEFORE the decl dispatch, so an `import` arm makes the meta path win
 * for import-ONLY regions too, re-routing the 25 fork fixtures that
 * put an `import` inside a `#if` (`emptylines/imports_and_using_*`,
 * `emptylines/issue_49_imports_with_conditional`,
 * `sameline/issue_504_conditional_import`, ...) away from this typedef
 * and its blank-line cascades. A trailing Star here is strictly
 * additive: it is empty for every shape that parsed before, so no
 * existing routing moves.
 *
 * It carries `@:fmt(padTrailing)` and NOT `padLeading`. The pad pair is
 * documented as firing only when the Star is non-empty; measured, the
 * leading pad fires on an EMPTY Star as well and inserted a blank line
 * before `#end` in every module-level `#if` region in a real project
 * tree (50 files of `hxq fmt --list` drift, none of them related to
 * dangling metadata). `padTrailing` alone closes the gap before `#end`
 * without that side effect. The gap between the last body decl and the
 * metadata is left to `body`'s own `padTrailing`, which costs the blank
 * line the source had there - a byte-fidelity gap, not a parse or
 * re-parse one: the emitted form round-trips through the parser
 * unchanged.
 *
 * `#else` / `#elseif` branches have no equivalent slot. No observed
 * source dangles metadata off an alternative branch, and each one would
 * need its own Star.
 *
 * `@:optional @:kw('#else') @:tryparse var elseBody:Null<Array<…>>`
 * uses the kw-led optional Star path (Lowering's
 * `emitOptionalKwStarFieldSteps`, slice ω-cond-comp-engine). The path
 * splices the kw-Ref commit machinery with the tryparse Star loop —
 * `#else` is the commit point, miss leaves the field `null` so the
 * writer skips the entire clause. Direct path eliminates the
 * pre-engine-slice Ref-wrapper companion typedef (one extra fn frame
 * + wrapper struct alloc per `#else` hit + extra paired `*T` synth).
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
};
