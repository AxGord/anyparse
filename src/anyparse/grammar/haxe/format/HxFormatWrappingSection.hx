package anyparse.grammar.haxe.format;

/**
 * `wrapping` section of `hxformat.json`.
 *
 *  - `maxLineLength`: int → `lineWidth`.
 *  - `arrayWrap`: `WrapRules` cascade → `arrayLiteralWrap` (slice
 *    ω-arraylit-wraprules).
 *  - `anonType`: `WrapRules` cascade → `anonTypeWrap` (slice
 *    ω-anontype-wraprules).
 *  - `methodChain`: `WrapRules` cascade → `methodChainWrap` (slices
 *    ω-methodchain-wraprules-capability + ω-methodchain-emit — knob,
 *    loader, and writer-time chain extractor all wired).
 *  - `opBoolChain`: `WrapRules` cascade → `opBoolChainWrap` (slice
 *    ω-binop-wraprules — drives `||` / `&&` chain break shape;
 *    knob + loader + macro-time dispatch all wired).
 *  - `opAddSubChain`: `WrapRules` cascade → `opAddSubChainWrap` (same
 *    slice — drives `+` / `-` chain break shape).
 *  - `callParameter`: `WrapRules` cascade → `callParameterWrap` (slice
 *    ω-wrapping-callParameter-ingest — knob, loader, and writer
 *    dispatch via `@:fmt(wrapRules('callParameterWrap'))` on
 *    `HxExpr.Call.args` and `HxNewExpr.args` are now wired).
 *  - `objectLiteral`: `WrapRules` cascade → `objectLiteralWrap` (slice
 *    ω-wrapping-objectLiteral-ingest — knob, default, and writer
 *    dispatch via `@:fmt(wrapRules('objectLiteralWrap'))` on
 *    `HxObjectLit.fields` were already wired before this slice; only
 *    the loader-side mapping was missing).
 *  - `conditionWrapping`: `WrapRules` cascade → `conditionWrap` (slice
 *    ω-condition-wrap-ingest — foundational scaffold). Drives wrap
 *    shape for statement-condition parens (`if (cond)`, `for (item in
 *    coll)`, `while (cond)`, `switch (expr)`). The loader path is wired
 *    here; the engine + grammar `@:fmt(condWrap(…))` wiring lands in a
 *    follow-up slice. Defaults match anyparse's pre-slice behaviour
 *    (`NoWrap`, no rules) so this scaffold is Δpass=0.
 *  - `ternaryExpression`: `WrapRules` cascade → `ternaryWrap` (slice
 *    ω-ternary-wrap). Drives break shape for the `? :` ternary —
 *    `WriterLowering`'s `@:ternary` branch now dispatches to
 *    `BinaryChainEmit.emit` with items=[cond, then, else] and
 *    ops=['?', ':']. Default `{rules: [], NoWrap}` is byte-equivalent
 *    to the prior flat emit.
 *  - `functionSignature`: `WrapRules` cascade → `functionSignatureWrap`.
 *    Drives break shape for named function parameter lists
 *    (`HxFnDecl.params`). Slice ω-functionsignature-wrap-ingest landed
 *    the loader path; slice ω-wraplist-additional-indent added the
 *    `defaultAdditionalIndent` knob on `WrapRules`; the follow-up
 *    grammar slice opted `HxFnDecl.params` into
 *    `@:fmt(wrapRules('functionSignatureWrap'))`. Defaults match
 *    fork's `wrapping.functionSignature`:
 *    `{rules: [], defaultMode: FillLine, defaultAdditionalIndent: 1}`.
 *  - `anonFunctionSignature`: `WrapRules` cascade →
 *    `anonFunctionSignatureWrap`. Drives break shape for anonymous-
 *    function parameter lists — `HxFnExpr.params` (`function(...)`),
 *    `HxParenLambda.params` (`(...) => body`), and
 *    `HxThinParenLambda.params` (`(...) -> body`). Slice
 *    ω-anonFunctionSignature-wrap-ingest landed the foundational scaffold
 *    (loader + grammar opt-in) with fork-mirror defaults:
 *    `{rules: [itemCount>=7 → FillLine, totalItemLength>=80 → FillLine,
 *    exceedsMaxLineLength → FillLine], defaultMode: NoWrap,
 *    defaultAdditionalIndent: 1}`.
 *  - `metadataCallParameter`: `WrapRules` cascade →
 *    `metadataCallParameterWrap`. Drives break shape for metadata-call
 *    argument lists — `HxMetaCallArgs.args` (`@:overload(args)`,
 *    `@:keep(args)`, …). Slice ω-metadataCallParameter-wrap-ingest
 *    landed the cascade with fork-mirror defaults:
 *    `{rules: [totalItemLength>=140 → FillLine,
 *    lineLength>=160 → FillLine, exceedsMaxLineLength → FillLine],
 *    defaultMode: NoWrap}`. Replaces the legacy `sepList` Group-with-
 *    softlines layout that propagated inner FnExpr param breaks outward
 *    as `@:overload(\n\tfunction(...)\n)`; NoWrap keeps the meta-call
 *    parens tight even when the inner expression wraps internally.
 *  - `typeParameter`: `WrapRules` cascade → `typeParameterWrap`. Drives
 *    break shape for type-parameter lists — declare-site
 *    (`HxClassDecl.typeParams`, `HxTypedefDecl.typeParams`,
 *    `HxFnDecl.typeParams`, `HxFnExpr.typeParams`,
 *    `HxEnumDecl.typeParams`, `HxAbstractDecl.typeParams`,
 *    `HxInterfaceDecl.typeParams`) and use-site (`HxTypeRef.params`).
 *    Slice ω-typeparameter-wrap-ingest landed the cascade with
 *    fork-mirror defaults: `{rules: [anyItemLength>=50 → FillLine,
 *    totalItemLength>=70 → FillLine], defaultMode: NoWrap}`. Short
 *    `<T>` / `<K, V>` lists stay flat; long lists pack Wadler-style.
 *  - `multiVar`: `WrapRules` cascade → `multiVarWrap`. Drives break
 *    shape for multi-variable declaration binding lists
 *    (`var a = 1, b = 2, c = 3;` — `HxVarDecl.more`). Slice
 *    ω-multivar-wrap-ingest landed the cascade with fork-mirror
 *    defaults: `{rules: [allItemLengths < 15 → FillLine,
 *    lineLength >= 80 → OnePerLineAfterFirst,
 *    exceedsMaxLineLength → OnePerLineAfterFirst], defaultMode: NoWrap}`.
 *    Short bindings pack inline; wide bindings break one-per-line with
 *    the first binding kept inline with `var`. The fork's rule 1
 *    `anyItemLength <= n` (MIN ≤ n) is mapped to `AllItemLengthsLessThan`
 *    (MAX ≤ n) — anyparse has no min≤n condition; the two coincide on
 *    every corpus target.
 *  - `casePattern`: `WrapRules` cascade → `casePatternWrap`. Drives break
 *    shape for comma-separated `case` pattern lists (`case A, B, C:` —
 *    `HxCaseBranch.patterns`). Slice ω-casepattern-wrap-ingest landed the
 *    cascade with fork-mirror defaults (`config/WrapConfig.hx`
 *    `wrapping.casePattern`): `{rules: [itemCount > 2 → FillLine,
 *    exceedsMaxLineLength → FillLine], defaultMode: NoWrap}`. Single/double
 *    patterns stay flat; lists of three or more pack Wadler-style.
 *  - `expressionWrapping`: `WrapRules` cascade →
 *    `expressionWrappingWrap` (slice
 *    ω-expressionwrapping-cascade-ingest — foundational scaffold).
 *    Drives break shape for parenthesised expressions (`(expr)` —
 *    haxe-formatter `expressionWrapping` class). The loader path
 *    is wired here; the engine + grammar `@:fmt(parenWrapRules(…))`
 *    wiring lands in a follow-up slice (a prior writer-time prototype
 *    at `WriterLowering`'s `isWrapShape` branch surfaced an outer-
 *    chain wrap-priority issue — when `obj.y = (expr)` exceeds
 *    `maxLineLength`, the outer `opAddSubChain` cascade commits
 *    MBreak before the paren's cascade probe runs, so the resulting
 *    Doc stacks two `Nest`s and over-indents the paren content. Fork
 *    resolves this with a 2-pass marker phase that decides paren
 *    wrap FIRST, then re-evaluates chain wrap; the follow-up slice
 *    needs an equivalent Doc-level mechanism). Fork-mirror default
 *    matches `default-hxformat.json`:
 *    `{rules: [], defaultMode: NoWrap}` — opt-out by default, so
 *    every cascade-less config stays byte-identical and the loader
 *    scaffold is Δpass=0.
 *
 * Slice ω-peg-byname-array lifted the prior `@:peg` ByName Array<T>
 * limitation, so every cascade above now ingests `rules` from
 * `hxformat.json` verbatim (rules with the still-unmodelled
 * `lineLength >= n` predicate are silently dropped at load time so the
 * cascade falls through to the next rule).
 *
 *  - `arrayMatrixWrap`: string → `arrayMatrixWrap` (slice
 *    ω-arraymatrix-wrap). Not a `WrapRules` cascade — a three-way enum
 *    policy (`noMatrixWrap` / `matrixWrapNoAlign` / `matrixWrapWithAlign`)
 *    selecting whether the writer preserves a source-detected matrix
 *    grid and whether columns are right-aligned. Default (config absent)
 *    is `matrixWrapWithAlign`, matching haxe-formatter. Resolved via
 *    `ArrayMatrixWrap.resolve`; unknown strings fall back to the format
 *    default.
 */
@:peg typedef HxFormatWrappingSection = {

	@:optional var maxLineLength: Int;

	@:optional var arrayMatrixWrap: String;

	@:optional var arrayWrap: HxFormatWrapRules;

	@:optional var multiVar: HxFormatWrapRules;

	@:optional var casePattern: HxFormatWrapRules;

	@:optional var anonType: HxFormatWrapRules;

	@:optional var methodChain: HxFormatWrapRules;

	@:optional var opBoolChain: HxFormatWrapRules;

	@:optional var opAddSubChain: HxFormatWrapRules;

	@:optional var callParameter: HxFormatWrapRules;

	@:optional var objectLiteral: HxFormatWrapRules;

	@:optional var conditionWrapping: HxFormatWrapRules;

	@:optional var ternaryExpression: HxFormatWrapRules;

	@:optional var functionSignature: HxFormatWrapRules;

	@:optional var anonFunctionSignature: HxFormatWrapRules;

	@:optional var metadataCallParameter: HxFormatWrapRules;

	@:optional var typeParameter: HxFormatWrapRules;

	@:optional var expressionWrapping: HxFormatWrapRules;

	@:optional var implementsExtends: HxFormatWrapRules;
};
