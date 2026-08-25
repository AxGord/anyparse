package anyparse.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.BracePlacement;
import anyparse.format.CommentEmptyLinesPolicy;
import anyparse.format.EmptyCurly;
import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.format.KeywordPlacement;
import anyparse.format.MetadataLineEndPolicy;
import anyparse.format.OptionalSemicolon;
import anyparse.format.RightCurlyPlacement;
import anyparse.format.SameLinePolicy;
import anyparse.format.UniformStatementBlanksPolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.format.WriteOptions;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrapRules;
import anyparse.grammar.haxe.format.HxBetweenImportsLevel;

/**
 * Write options specific to the Haxe module grammar (`HxModule`).
 *
 * Haxe-specific knobs are mixed into the base `WriteOptions` shape via
 * struct intersection so the macro-generated writer sees a fully
 * populated struct at runtime. Defaults live in
 * `HaxeFormat.defaultWriteOptions`; `hxformat.json` ingest lives in
 * `HaxeFormatConfigLoader`. Note: `addLineCommentSpace` lives on the
 * base `WriteOptions` typedef (it drives format-neutral comment helpers
 * shared by every text writer), not here; default `true`, matches
 * haxe-formatter's `whitespace.addLineCommentSpace`.
 *
 * Underscore-prefixed fields are internal write-time channels, not
 * user-facing knobs: no JSON loader entry, no `hxformat.json` ingest.
 * They propagate through the standard opt-fanout copy.
 *
 * SAME-LINE POLICIES (`SameLinePolicy`; `Keep` reads a trivia-mode
 * source-shape slot and degrades to `Same` in plain mode):
 *  - `sameLineElse` — placement of `else` relative to the preceding `}`.
 *    `Same` (default) emits `} else {`; `Next` moves `else` to the next
 *    line at the current indent; `Keep` dispatches on the captured
 *    `elseBodyBeforeKwNewline` slot.
 *  - `sameLineCatch` — same shape for `} catch (...)`.
 *  - `sameLineDoWhile` — same shape for the closing `while (...)` of a
 *    `do … while (…)` loop.
 *  - `sameLineExpressionElse` — placement of `else` when it is the
 *    optional kw of an expression-position `if` (`HxIfExpr.elseBranch`).
 *    Distinct from `sameLineElse` (statement-level). Default `Same`
 *    (space). JSON `sameLine.expressionIf` fans the same value into both
 *    the BodyPolicy channel (gated to Keep/Same) AND this knob (ungated;
 *    `Next` maps to `Keep`, see loader doc). `Keep` consults the synth
 *    `elseBranchBeforeKwNewline` slot, computed against the previous
 *    field's last non-whitespace position (`Lowering.hx`
 *    ω-prev-content-end) so trailing whitespace consumed by Pratt's tail
 *    loop does not falsify the slot.
 *
 * TRAILING COMMAS (`Bool`, all default `false`; the trailing `,` is
 * emitted only when the enclosing Group lays out in break mode — the
 * flags have no effect on one-line lists):
 *  - `trailingCommaArrays` — array literals that break across lines.
 *  - `trailingCommaArgs` — call argument lists (incl. `new T(...)`).
 *  - `trailingCommaParams` — function / enum-ctor / parenthesised-lambda
 *    parameter lists.
 *  - `trailingCommaObjectLits` — object-literal field lists. JSON
 *    `trailingCommas.objectLiteralDefault` (anyparse-specific — upstream
 *    haxe-formatter has no such knob and preserves source).
 *
 * BODY-PLACEMENT POLICIES (`BodyPolicy`). Value meanings: `Same` keeps
 * the body inline after a space; `Next` pushes it to the next line one
 * indent level deeper; `FitLine` keeps it flat when it fits within
 * `lineWidth`, else breaks; `Keep` preserves the source layout (plain
 * mode degrades to `Same`). The policies apply only to non-block bodies:
 * a block body (`{ … }`) carries its own hardlines, so the separator
 * before `{` stays a single space regardless of the policy.
 *  - `ifBody` / `elseBody` / `forBody` / `whileBody` / `doBody` —
 *    statement-form `if` / `else` / `for` / `while` / `do … while`
 *    bodies. Default `Keep` for all five.
 *  - `returnBody` — separator between `return` and its value
 *    (`HxStatement.ReturnStmt` only; the void form has no value to
 *    wrap). Default `FitLine` — corresponds to haxe-formatter's
 *    effective `sameLine.returnBody: Same`, where long values wrap via a
 *    separate `wrapping.maxLineLength` pass.
 *  - `returnBodySingleLine` — sibling knob refining the return-value
 *    policy for value ctors in the single-line-shaped set (see the
 *    `bodyPolicySingleLine('returnBodySingleLine', …)` entry on
 *    `HxStatement`). JSON `sameLine.returnBodySingleLine`. Default
 *    `FitLine`.
 *  - `throwBody` — separator between `throw` and its value
 *    (`HxStatement.ThrowStmt`). Default `Same` — haxe-formatter has no
 *    throwBody knob and leaves `throw <expr>` inline regardless of
 *    length; long values wrap via their own internal fill rules instead
 *    of breaking at the kw boundary. No `sameLine.throwBody` JSON key is
 *    parsed; the knob exists for programmatic use.
 *  - `catchBody` — separator between the `)` of the catch header
 *    (`catch (name:Type)`) and its body at `HxCatchClause.body`. Default
 *    `Next`.
 *  - `tryBody` — body placement at `HxTryCatchStmt.body`. Default `Next`
 *    (matches upstream `sameLine.tryBody`). Orthogonal to `tryPolicy`:
 *    `tryPolicy` controls the inline whitespace right after the `try`
 *    keyword (`try{` vs `try {`); `tryBody` controls whether the body
 *    sits on the same line at all. They compose via the
 *    `kwOwnsInlineSpace` mode in `WriterLowering.bodyPolicyWrap` — the
 *    `Same` inline gap routes through `opt.tryPolicy` (after/both →
 *    space, none/before → empty). Block bodies are shape-aware and
 *    `leftCurly=Next` still wins for the brace position.
 *  - `caseBody` — body placement at `HxCaseBranch.body` /
 *    `HxDefaultBranch.stmts` for statement-position switches. `Same`
 *    collapses a single-stmt body onto the case header line
 *    (`case X: foo();`); `Next` keeps `case X:` and the body on separate
 *    lines; `Keep` (default) flattens only when the source had the stmt
 *    on the same line as `:` (reads `Trivial<T>.newlineBefore` of the
 *    body's first element); `FitLine` (ω-case-body-fitline) asks
 *    `anyparse.format.BodyFit.fitLineLayout` — the SAME emitter the
 *    bare-Ref `FitLine` bodies use — which splits on whether the body
 *    CAN render on one line at all:
 *      - it can (`WrapList.flatLength >= 0`, no hardline anywhere) —
 *        the flat `case <patterns>: <body>` line is measured against
 *        `lineWidth`, counting the live column after the header plus the
 *        body's flat width incl. its `;` and any folded trailing
 *        comment; inline at `<= lineWidth`, WHOLE body one indent deeper
 *        past it.
 *      - it cannot (a block, a wrap cascade that refuses one line, a
 *        source-multi-line literal the emitter keeps broken) — no budget
 *        makes it fit, so it GLUES to the label exactly as `Same` does,
 *        and the case line may exceed `lineWidth`.
 *    Neither outcome consults the source line shape (that axis is
 *    `Keep`'s), so an author-broken body that fits re-joins the label and
 *    one format pass reaches the `writeRoundTrip(s) == s` fixed point.
 *    Multi-stmt bodies always stay multiline.
 *  - `expressionCase` — same shape, selected instead of `caseBody` when
 *    `_inExprPosition` is set (expression-context switches such as
 *    `var x = switch … { case Y: 1; }`). Sibling JSON key in
 *    `hxformat.json`. Default `Keep`.
 *  - `functionBody` — body placement at `HxFnBody.ExprBody`
 *    (`function f() expr;`; the brace-bearing `BlockBody` and the
 *    `;`-only `NoBody` are excluded). Default `Next` (upstream
 *    `sameLine.functionBody`); `Same` keeps `function f() expr;` inline;
 *    `FitLine` and `Keep` degrade to `Next`. The parent `HxFnDecl.body`
 *    leftCurly path suppresses its fixed space separator for ctors
 *    carrying `@:fmt(bodyPolicy(...))`, so the wrap inside the sub-rule
 *    writer fully owns the kw-to-body separator. JSON
 *    `sameLine.functionBody`.
 *  - `untypedBody` — parent→`untyped` separator at
 *    `HxFnBody.UntypedBlockBody` (`function f():T untyped { … }`).
 *    Default `Same` (cuddles the kw inline). Caller trap: the stmt-level
 *    form `HxStatement.UntypedBlockStmt` (incl. `try untyped { … }`)
 *    deliberately does NOT consume this knob — a stmt-level wrap would
 *    stack with parent body-policy / block-stmt separators.
 *  - `expressionIfBody` / `expressionElseBody` / `expressionForBody` —
 *    body placement for the expression-position counterparts of
 *    `if` / `for` (`HxIfExpr` / `HxForExpr`, incl. comprehensions).
 *    Defaults `Same` / `Same` / `Keep`. `Keep` reads the
 *    `<field>BeforeNewline:Bool` synth slot (created on bare-non-first
 *    Refs by `TriviaTypeSynth`); plain mode degrades to `Same`. JSON: a
 *    single `sameLine.expressionIf` key fans out into all three;
 *    programmatic users can set them independently.
 *  - `expressionIfWithBlocks` — `Bool` (default `false`) gating inline
 *    collapse of `BlockExpr` bodies on `HxIfExpr.thenBranch` /
 *    `elseBranch`. When `true` AND the runtime body ctor is `BlockExpr`,
 *    the writer wraps the body's Doc in `D.flatten(…)` — collapsing
 *    `{<hardline>stmt;<hardline>}` to `{stmt;}` regardless of width.
 *    Wired via `@:fmt(inlineBlockBodyIfFlag('expressionIfWithBlocks'))`
 *    on both branch fields; flag-false falls through to the
 *    `expressionIfBody` / `expressionElseBody` cascade. JSON
 *    `sameLine.expressionIfWithBlocks`.
 *
 * BRACE PLACEMENT AND EMPTY BODIES:
 *  - `leftCurly` — global `BracePlacement` for block-opening `{` at
 *    every `@:fmt(leftCurly)` site. `Same` (default) keeps `{` on the
 *    same line after a single space; `Next` emits it on the next line at
 *    the current indent (Allman). Only two values are exposed —
 *    haxe-formatter's `Before` / `Both` collapse to `Next`, and the
 *    inline `None` shape is not supported.
 *  - `emptyCurly` — global `EmptyCurly` for empty bodies at
 *    `@:fmt(emptyCurlyBreak)` sites. `Same` (default) keeps empty bodies
 *    flat (`class C {}`); `Break` emits them across two lines with `}`
 *    on its own line at the parent's indent. JSON `lineEnds.emptyCurly`.
 *    Override semantics, not floor: the decision is purely opt-driven
 *    for empty Stars — source blanks between the braces are irrelevant.
 *  - `objectLiteralLeftCurly` — per-construct `BracePlacement` for
 *    `HxObjectLit.fields`. Default `Same`. The loader cascades global
 *    `lineEnds.leftCurly` into this knob; per-construct sub-key
 *    `lineEnds.objectLiteralCurly.leftCurly` overrides the cascade.
 *    leftCurly emission threads through `WrapList.emit`'s
 *    `(leadFlat, leadBreak)` pair, so the wrap engine's flat/break
 *    decision picks cuddled vs Allman per literal.
 *  - `anonTypeLeftCurly` — per-construct `BracePlacement` for
 *    `HxType.Anon.fields`. Default `Same`. Same global cascade. With
 *    `Next`, typedef RHS anon-types emit `typedef Foo =\n{ ... }` and
 *    inner var-type anons emit `var a:\n\t{ ... }`.
 *  - `anonFunctionLeftCurly` — per-construct `BracePlacement` for
 *    `HxFnExpr.body`. Default `Same` (`function() {…}`); `Next` flips to
 *    Allman. Same global cascade; sub-key
 *    `lineEnds.anonFunctionCurly.leftCurly` overrides. Arrow-lambda
 *    block bodies (`() -> {…}`) are reached separately via the
 *    `_inAnonFnBody` channel and
 *    `@:fmt(leftCurlyAnonFnOverride('anonFunctionLeftCurly'))` on
 *    `HxExpr.BlockExpr` (see `_inAnonFnBody` below).
 *  - `anonFunctionEmptyCurly` — per-construct `EmptyCurly` for the empty
 *    body of an anonymous function expression (`function() {}` vs
 *    `function()\n{\n}`). Default `Same`. The loader cascades global
 *    `lineEnds.emptyCurly` into it; sub-key
 *    `lineEnds.anonFunctionCurly.emptyCurly` overrides. Routed at the
 *    `HxFnBlock.stmts` emit site via `_inAnonFnBody` — when true, the
 *    writer reads this knob instead of `emptyCurly`; `HxFnDecl` bodies
 *    keep reading `emptyCurly`.
 *  - `blockLeftCurly` — per-construct `BracePlacement` for plain block
 *    bodies: `HxFnDecl.body`, `HxStatement.BlockStmt`,
 *    `HxExpr.BlockExpr`, `HxSwitchStmt.cases`, `HxSwitchStmtBare.cases`,
 *    `HxUntypedFnBody.block` — every site upstream classifies as
 *    `BrOpenType.Block`. Default `Same`; `Next` flips every block brace
 *    to Allman. Global cascade; sub-key `lineEnds.blockCurly.leftCurly`
 *    overrides. The per-construct categories (`anonFunctionCurly`,
 *    `anonTypeCurly`, `objectLiteralCurly`, `typedefCurly`) take
 *    precedence over `blockCurly` for their own brace contexts.
 *  - `blockEmptyCurly` — per-construct `EmptyCurly` for empty plain
 *    blocks (`if (x) {}`, `{ }`, `switch (e) {}`). Default `Same`.
 *    Global cascade; sub-key `lineEnds.blockCurly.emptyCurly` overrides.
 *    Consumed via the call-form `@:fmt(emptyCurlyBreak('blockEmptyCurly'))`
 *    at `HxStatement.BlockStmt`, `HxExpr.BlockExpr` and the switch-case
 *    Stars; the bare `@:fmt(emptyCurlyBreak)` form keeps the
 *    `_inAnonFnBody` dispatch (`anonFunctionEmptyCurly` vs global
 *    `emptyCurly`) and is used by `HxFnBlock.stmts` and type member
 *    bodies.
 *  - `blockRightCurly` — per-construct `RightCurlyPlacement` gating the
 *    hardline emitted immediately before `}` for plain blocks. `Same`
 *    (default) keeps the close on its own line; `Inline` drops the
 *    before-close hardline so the brace glues to the last body token
 *    (`{ body }`). The loader cascades global `lineEnds.rightCurly` into
 *    it; sub-key `lineEnds.blockCurly.rightCurly` overrides. Consumed
 *    via `@:fmt(rightCurly('blockRightCurly'))` at the same block sites.
 *    Upstream mapping: `before` / `both` → `Same` (the after-`}` newline
 *    comes from the outer sibling separator, not from `blockBody`);
 *    `after` / `none` → `Inline`.
 *  - `anonFunctionRightCurly` — same axis for anonymous function bodies.
 *    Default `Same`. Global cascade; sub-key
 *    `lineEnds.anonFunctionCurly.rightCurly` overrides. Consumed by
 *    `HxFnBlock.stmts` via
 *    `@:fmt(rightCurlyAnonFnOverride('anonFunctionRightCurly'))` — the
 *    dispatch fires only when `_inAnonFnBody` is true, so function
 *    declarations and `HxUntypedFnBody.block` (which share `HxFnBlock`)
 *    keep the plain hardline.
 *  - `anonTypeRightCurly` — same axis for anonymous type braces
 *    (`HxType.Anon.fields`). Default `Same`. Global cascade; sub-key
 *    `lineEnds.anonTypeCurly.rightCurly` overrides. Caller trap: it
 *    dispatches only in `triviaSepStarExpr`'s trivia branch; the
 *    wrap-engine branch (no per-element trivia) keeps `WrapList.emit`'s
 *    shapes.
 *  - `objectLiteralRightCurly` — same axis for object literals
 *    (`HxObjectLit.fields`); trivia branch only, like
 *    `anonTypeRightCurly`. Default `Same`. Global cascade; sub-key
 *    `lineEnds.objectLiteralCurly.rightCurly` overrides.
 *
 * WHITESPACE POLICIES (`WhitespacePolicy`):
 *  - `objectFieldColon` — around the `:` inside an object literal
 *    (`HxObjectField.value`'s lead). Default `After` (`{a: 0}`, upstream
 *    `whitespace.objectFieldColonPolicy`); `None` → `{a:0}`; `Before` /
 *    `Both` exposed for completeness but uncommon. Scoped to the
 *    object-literal `:` only — type annotations use `typeHintColon`.
 *  - `typeHintColon` — around the type-annotation `:` on
 *    `HxVarDecl.type`, `HxParam.type` and `HxFnDecl.returnType`. Default
 *    `None` (`x:Int`, upstream `whitespace.typeHintColonPolicy`); `Both`
 *    emits `x : Int` (upstream `"around"`). Applies only at
 *    `@:fmt(typeHintColon)` sites.
 *  - `typeCheckColon` — around the `:` in a type-check expression
 *    `(expr : Type)` (`HxECheckType.type`'s lead). Default `Both`
 *    (upstream `Around`); `None` → `("":String)`. Separate from
 *    `typeHintColon` — the two `:` sites follow opposite upstream
 *    conventions.
 *  - `funcParamParens` — space before the opening `(` of a function
 *    declaration's parameter list (`HxFnDecl.params`). Default `None`;
 *    `Before` / `Both` → `function main ()`. `After` is exposed for
 *    parity but has no effect (no post-open padding point). Only
 *    `HxFnDecl.params` carries the flag.
 *  - `callParens` — space before the opening `(` of a call's argument
 *    list (`HxExpr.Call.args`). Default `None`; `Before` / `Both` →
 *    `trace (x)`. `After` has no effect on this knob — the inside-open
 *    pad is the separate `callParensInsideOpen`. Only `HxExpr.Call`
 *    carries the flag.
 *  - `anonFuncParens` — space AFTER the `function` keyword (= before the
 *    `(`) of an anonymous-function expression. Default `None` → tight
 *    `function(args)…` (upstream
 *    `whitespace.parenConfig.anonFuncParamParens.openingPolicy`, whose
 *    `auto` collapses to `None`; the upstream `auto` heuristic is not
 *    modelled); `Before` / `Both` keep `function (args)…`. `After` is
 *    accepted for parity but produces no space — the kw-trailing slot is
 *    the only switchable axis. Independent of `funcParamParens`.
 *  - `anonFuncParamParensKeepInnerWhenEmpty` — `Bool` (default `false`):
 *    when `true`, an empty anonymous-function parameter list emits a
 *    single inside space (`function ( ) body`). Loader inverts upstream
 *    `…anonFuncParamParens.removeInnerWhenEmpty`. Read by
 *    `HxFnExpr.params` and routed through `sepList`'s
 *    `keepInnerWhenEmpty` arg — orthogonal to `anonFuncParens`.
 *  - `ifPolicy` — gap between the `if` keyword and its condition `(`.
 *    Consumed by `HxStatement.IfStmt` and `HxExpr.IfExpr`. Default
 *    `After` (`if (cond)`); `Before` / `None` (from upstream
 *    `"onlyBefore"` / `"none"`) collapse to `if(cond)`; `Both` behaves
 *    like `After` — the before-kw slot is owned by the preceding token's
 *    separator.
 *  - `forPolicy` / `whilePolicy` / `switchPolicy` — same shape for the
 *    trailing space after `for` / `while` / `switch` (all four switch
 *    ctors: parens / bare × stmt / expr). Default `After`. Caller trap:
 *    for the bare switch form (`switch cond { … }`), `Before` / `None`
 *    produce `switchcond` — a syntax error; keep the default there.
 *    `Both` is equivalent to `After`.
 *  - `tryPolicy` — trailing space after the `try` keyword. Consumed by
 *    `HxStatement.TryCatchStmt` (block-body form) only; the bare-body
 *    sibling strips the kw-trailing slot regardless of policy (its first
 *    field's `@:fmt(bareBodyBreaks)` triggers `stripKwTrailingSpace`).
 *    Default `After` (`try {`); `Before` / `None` → `try{`; `Both` =
 *    `After`.
 *  - `elseIf` — `KeywordPlacement` for the nested `if` inside an `else`
 *    clause. `Same` (default, upstream `sameLine.elseIf`) keeps the
 *    `else if (...)` idiom inline, overriding `elseBody` for the
 *    `IfStmt` ctor; `Next` moves the nested `if` to the next line one
 *    indent deeper (`} else\n\tif (...) {`). Non-if else branches route
 *    through `elseBody` as usual.
 *  - `fitLineIfWithElse` — `Bool` (default `false`) runtime gate on the
 *    `FitLine` body policy for if-statement bodies when the enclosing
 *    `if` carries an `else`. When `false`, `ifBody=FitLine` /
 *    `elseBody=FitLine` degrade to `Next` for such ifs (fitting one half
 *    and breaking the other reads as inconsistent); when `true`,
 *    `FitLine` applies unconditionally. Wired via
 *    `@:fmt(fitLineIfWithElse)` with macro-lower-time sibling-field
 *    introspection, so future then/else pairs can opt in without macro
 *    changes.
 *
 * CLASS-MEMBER BLANK-LINE POLICIES:
 *  - `afterFieldsWithDocComments` — `CommentEmptyLinesPolicy` for the
 *    slot after a member whose leading trivia carries at least one doc
 *    comment (leading entry with a `/**` prefix). `One` (default) forces
 *    exactly one blank line after it regardless of source; `Ignore`
 *    honours the captured source count; `None` strips any blank.
 *    Applies at `@:fmt(afterFieldsWithDocComments)` sites —
 *    `HxClassDecl.members` is the current consumer.
 *  - `existingBetweenFields` — `Keep` / `Remove` for source blank lines
 *    between class members. `Keep` (default) honours the captured
 *    count; `Remove` strips every inter-sibling blank. Composes with
 *    `afterFieldsWithDocComments` on the same slot: `Remove` drops
 *    source blanks while `One` can still re-insert one after a
 *    doc-commented field. Site: `HxClassDecl.members`.
 *  - `externExistingBetweenFields` — `Keep` / `Remove` that takes over
 *    from `existingBetweenFields` when `_classExtern` is true. Default
 *    `Keep`. JSON `emptyLines.externClassEmptyLines.existingBetweenFields`.
 *    Combined with the engine's split-leading detector: `Remove` strips
 *    the inter-member source blank only when the next member's leading
 *    cluster carries a trailing `/**` doc comment preceded by `//` line
 *    comments; members with a regular leading cluster (single `/**` or
 *    none) keep their blanks.
 *  - `beforeDocCommentEmptyLines` — same axis as
 *    `afterFieldsWithDocComments` but for the slot immediately BEFORE a
 *    member whose leading trivia starts with a doc comment (triggers on
 *    the next sibling's `_t.leadingComments[0]`). Default `One`. Site:
 *    `HxClassDecl.members`.
 *
 * INTER-MEMBER BLANK COUNTS (`Int`; consumed only where the Star carries
 * `@:fmt(interMemberBlankLines('classifierField', 'VarCtorName',
 * 'FnCtorName'))`. Kind classification happens at write time via a
 * switch on the member-variant field; the variant names are supplied per
 * grammar so the macro stays shape-agnostic. The 6-arg meta form selects
 * alternative opt fields (used by the interface knobs); the 3-arg form
 * reads the shared class/abstract set. Caller trap: any positive value
 * currently collapses to a single blank line — the emission path accepts
 * a boolean add-blank contributor per site, not a count loop):
 *  - `betweenVars` (default `0`) — between two consecutive var members.
 *  - `betweenFunctions` (default `1`) — between two consecutive function
 *    members.
 *  - `afterVars` (default `1`) — at a var↔function boundary.
 *  - `afterStaticVars` (default `1`) — between an instance var and a
 *    static var (either order). Fires only when the Star ALSO carries
 *    `@:fmt(staticVarSubdivision)` — class and abstract members opt in,
 *    interface members do not. Gated on `!opt._classExtern`.
 *  - `betweenStaticFunctions` (default `1`) — between two consecutive
 *    static functions; same `staticVarSubdivision` + non-extern gates.
 *  - `interfaceBetweenVars` / `interfaceBetweenFunctions` /
 *    `interfaceAfterVars` — interface-scope counterparts, routed through
 *    the 6-arg meta form on `HxInterfaceDecl.members`. Defaults
 *    `0 / 0 / 0` — interface bodies stay tight unless overridden.
 *  - `betweenEnumCtors` (default `0`) — uniform blank count between
 *    every pair of adjacent enum constructors, via
 *    `@:fmt(uniformBetween('betweenEnumCtors'))` on `HxEnumDecl.ctors`.
 *    The meta is a generic uniform-between handler reusable by any
 *    future Alt-element Star with its own opt knob.
 *
 * TYPE-BODY HEAD/TAIL BLANKS (fire at `@:fmt(beginEndType)` sites —
 * `HxClassDecl.members`, `HxInterfaceDecl.members`,
 * `HxAbstractDecl.members`, `HxEnumDecl.ctors`):
 *  - `beginType` (default `0`) — exact blank count between the opening
 *    `{` of a type body and its first member; positive values insert
 *    regardless of source.
 *  - `endType` (default `0`) — exact blank count between the last member
 *    and the closing `}`.
 *  - `afterLeftCurly` — `Keep` / `Remove` gating source-blank
 *    preservation after the opening `{` when `beginType` is `0`. Default
 *    `Keep`. `beginType > 0` overrides — the explicit count wins.
 *  - `beforeRightCurly` — `Keep` / `Remove` gating source-blank
 *    preservation before the closing `}` when `endType` is `0`. Default
 *    `Keep`. `endType > 0` overrides.
 *
 * STATEMENT-BLOCK INTERIOR BLANKS (fires at `@:fmt(uniformStmtBlanks)`
 * sites — `HxExpr.BlockExpr.stmts`, `HxFnBlock.stmts`):
 *  - `uniformStatementBlanks` — `Keep` / `Collapse` over the blank-line
 *    gaps BETWEEN adjacent statements of one block (function / if / for /
 *    while / plain-block bodies, never a type member list). `Keep`
 *    (default) round-trips source blanks byte-identically. `Collapse`
 *    applies "separators that separate everything separate nothing":
 *    when every interior gap is blank the blanks are uniform noise and
 *    all get stripped; a selective blank/adjacent mix (or any comment
 *    between statements) is left byte-exact. Uniformity is measured over
 *    interior gaps only — the head/tail `{` / `}` blanks are already
 *    resolved by `afterLeftCurly` / `beforeRightCurly`. See
 *    `UniformStatementBlanksPolicy`.
 *
 * TYPEDEF-RHS AND TYPE-SYNTAX WHITESPACE:
 *  - `typedefAssign` — around the `=` joining a typedef name to its RHS
 *    type (`HxTypedefDecl.type`'s lead). Default `Both`
 *    (`typedef Foo = Bar;`); `None` → `typedef Foo=Bar;`. Applies only
 *    at `@:fmt(typedefAssign)` sites — the optional-Ref `=` leads on
 *    `HxVarDecl.init` and `HxParam.defaultValue` use the bare-optional
 *    fallback path, which already emits ` = `.
 *  - `typedefIntersection` — space AFTER the `&` joining intersection
 *    operands (`HxIntersectionClause.type`'s `@:lead('&')`). Default
 *    `After` (`& B`); combined with the structural pre-`&` space from
 *    the consuming Star's `@:fmt(padLeading)` + separator, the result is
 *    the around-spaced `typedef X = A & B & C;`. `None` → `&B`. Caller
 *    trap: `Both` / `Before` add a clause-internal leading space on top
 *    of the structural one — use `After` / `None` for predictable
 *    output. Sibling of `typedefAssign`.
 *  - `typeParamDefaultEquals` — around the `=` joining a type-parameter
 *    name (or constraint) to its default type
 *    (`HxTypeParamDecl.defaultValue`'s lead). Default `Both`
 *    (`<T = Int>`); `None` → `<T=Int>`.
 *  - `typeParamOpen` / `typeParamClose` — interior spacing of a
 *    type-parameter list's `<` / `>` at
 *    `@:fmt(typeParamOpen, typeParamClose)` sites (`HxTypeRef.params`
 *    plus the declare-site `typeParams` fields on the six decl types).
 *    Defaults `None` (`Array<Int>`). Open: `Before` → space outside
 *    before `<`; `After` → space inside after `<` (threads through
 *    `sepList`'s `openInside`). Close: `Before` → space inside before
 *    `>`; `After` has no effect (no outside-after-close padding point).
 *  - `anonTypeBracesOpen` / `anonTypeBracesClose` — interior spacing of
 *    an anonymous structure type's `{}` (`HxType.Anon`). Defaults
 *    `None`. Open: `After` → `{ x:Int`; `Before` has no effect (no
 *    outside-before-open padding point — the gap before `{` is governed
 *    by `typeHintColon` etc.). Close: `Before` → `x:Int }`; `After` has
 *    no effect.
 *  - `objectLiteralBracesOpen` / `objectLiteralBracesClose` — same pair
 *    for object-literal `{}` (`HxObjectLit.fields`'s sep-Star path).
 *    Defaults `None`. Same no-effect parity notes as the anon-type pair.
 *
 * WRAP-RULES CASCADES (`WrapRules`, evaluated by `WrapList.emit` /
 * `BinaryChainEmit.emit`: the helper measures item count and max/total
 * flat width, runs the cascade twice (`exceeds=false` and
 * `exceeds=true`) and emits one of `NoWrap` / `OnePerLine` /
 * `OnePerLineAfterFirst` / `FillLine` shapes — wrapping the result in
 * `Group(IfBreak(brkDoc, flatDoc))` when the two runs disagree, so the
 * renderer's flat/break decision selects the right mode at layout time.
 * User `hxformat.json` `wrapping.*` sections override the defaults
 * through the loader. For default configs the `exceedsMaxLineLength`
 * cond fires identically to upstream's final fallback rule; upstream
 * conds not modelled by `WrapConditionType` are skipped):
 *  - `objectLiteralWrap` — object-literal fields
 *    (`@:fmt(wrapRules('objectLiteralWrap'))` on `HxObjectLit.fields`).
 *    Defaults port upstream `wrapping.objectLiteral`: `noWrap` if
 *    `count <= 3 ∧ ¬exceeds`, else `onePerLine` if any item ≥ 30 cols,
 *    total ≥ 60 cols, count ≥ 4, or exceeds; default mode `noWrap`.
 *    Orthogonal to the braces-spacing knobs — braces decide `{a:1}` vs
 *    `{ a:1 }`; the cascade decides single- vs multi-line shape.
 *  - `callParameterWrap` — call argument lists (`HxExpr.Call.args`
 *    postfix-Star site). Defaults port upstream `wrapping.callParameter`:
 *    `fillLine` if any of `count ≥ 7`, `total ≥ 140`, `anyItem ≥ 80`,
 *    `line ≥ 160`, or exceeds; default mode `noWrap`. Orthogonal to
 *    `callParens`.
 *  - `arrayLiteralWrap` — array-literal element lists
 *    (`HxExpr.ArrayExpr.elems`). Defaults port upstream
 *    `wrapping.arrayWrap`, including the leading
 *    `hasMultilineItems → OnePerLine` rule (item-multiline detection is
 *    decoupled from width measurement). The `equalItemLengths` cond and
 *    its gated `fillLineWithLeadingBreak` rule are not modelled.
 *    Orthogonal to `trailingCommaArrays`.
 *  - `anonTypeWrap` — anonymous-type field lists (`HxType.Anon.fields`).
 *    Defaults port upstream `wrapping.anonType` in full: `count <= 3` +
 *    no-exceed stays flat; `anyItem >= 30` / `total >= 60` /
 *    `count >= 4` cascade to `OnePerLine`; exceeds falls through to
 *    `FillLine`. Orthogonal to the anon-type braces knobs.
 *  - `methodChainWrap` — `.method(args).method(args)…` postfix chains.
 *    Chain segments are not a flat Star field — they form a nested
 *    left-assoc `Call(FieldAccess(Call(…)))` tree over `HxExpr` — so the
 *    writer uses a chain extractor + dedicated emit (ω-methodchain-emit;
 *    `@:fmt(methodChain('methodChainWrap'))` on `HxExpr.Call` and the
 *    postfix `.`). Defaults port upstream `wrapping.methodChain` minus
 *    its leading `lineLength >= 160` rule (unmodelled): `count <= 3` +
 *    no-exceed OR `total <= 80` + no-exceed keeps short chains flat;
 *    `anyItem >= 30` + `count >= 4`, `count >= 7`, or exceeds cascade to
 *    `OnePerLineAfterFirst`.
 *  - `opBoolChainWrap` — `||` / `&&` chains (upstream `opBoolChain`).
 *    `BinaryChainEmit.emit` fires on the outermost `Or` / `And` ctor;
 *    the extractor gathers all same-class operands into a flat
 *    `(items, ops)` pair — one cascade evaluation per top-level chain.
 *    Default: single rule `ExceedsMaxLineLength → OnePerLineAfterFirst`
 *    over `defaultMode: NoWrap` (BeforeLast op placement —
 *    `\n+indent || operand`).
 *  - `opAddSubChainWrap` — `+` / `-` chains (upstream `opAddSubChain`).
 *    Same dispatch flow. Default: `ExceedsMaxLineLength → FillLine` over
 *    `NoWrap` — add/sub chains pack multiple operands per line (long
 *    string concat, arithmetic) while bool chains canonically place each
 *    operator on its own line, matching the upstream per-class defaults.
 *  - `conditionWrap` — statement-condition parens (`if (cond)`,
 *    `while (cond)`, `for (item in coll)`, `switch (expr)` — upstream
 *    `conditionWrapping` class). Consumed via
 *    `@:fmt(condWrap('conditionWrap'))` on the condition fields. Default
 *    `{rules: [], defaultMode: NoWrap}`.
 *  - `ternaryWrap` — the `? :` ternary (upstream `ternaryExpression`).
 *    Routed from the `@:ternary` branch to `BinaryChainEmit.emit` with
 *    items = [cond, then, else] and ops = ['?', ':']. Default
 *    `{rules: [], defaultMode: NoWrap}` keeps `cond ? then : else` flat.
 *  - `functionSignatureWrap` — named function parameter lists
 *    (`HxFnDecl.params` via `@:fmt(wrapRules('functionSignatureWrap'))`
 *    — upstream `functionSignature` class). Default
 *    `{rules: [], defaultMode: FillLine, defaultAdditionalIndent: 1}` —
 *    the `+1 tab` continuation indent keeps wrapped parameters one
 *    indent level deeper than the body.
 *  - `anonFunctionSignatureWrap` — anonymous-function / lambda parameter
 *    lists (`HxFnExpr.params`, `HxParenLambda.params`,
 *    `HxThinParenLambda.params` — upstream `anonFunctionSignature`
 *    class). Default `{rules: [itemCount>=7 → FillLine,
 *    totalItemLength>=80 → FillLine, exceedsMaxLineLength → FillLine],
 *    defaultMode: NoWrap, defaultAdditionalIndent: 1}` — short anon-fn
 *    signatures stay flat and only break on a cascade trigger.
 *  - `metadataCallParameterWrap` — metadata-call argument lists
 *    (`HxMetaCallArgs.args`: `@:overload(args)`, … — upstream
 *    `metadataCallParameter` class). Default
 *    `{rules: [totalItemLength>=140 → FillLine, lineLength>=160 →
 *    FillLine, exceedsMaxLineLength → FillLine], defaultMode: NoWrap}` —
 *    single-arg `@:overload` keeps the parens glued
 *    (`@:overload(function(...))`) and the inner FnExpr handles its own
 *    param wrap; long multi-arg metas fall through to FillLine packing.
 *  - `typeParameterWrap` — type-parameter lists at declare-site (the
 *    `typeParams` fields of the seven decl/expr types) and use-site
 *    (`HxTypeRef.params` — `Map<K, V>`). Default
 *    `{rules: [anyItemLength>=50 → FillLine, totalItemLength>=70 →
 *    FillLine], defaultMode: NoWrap}`.
 *  - `expressionWrappingWrap` — parenthesised expressions (`(expr)` —
 *    upstream `expressionWrapping` class). Consumed through
 *    `WrapList.effectiveExpressionWrapMode` at the paren emit sites.
 *    Default `{rules: [], defaultMode: NoWrap}` — opt-out by default.
 *
 * OTHER LAYOUT KNOBS:
 *  - `expressionTry` — three-way same-line policy for the separator
 *    between the body of an expression-position `try` and each of its
 *    `catch` clauses (`var x = try foo() catch (_:Any) null;`).
 *    Independent of `sameLineCatch` (statement form). `Same` (default,
 *    upstream `sameLine.expressionTry`) keeps the expression form on one
 *    line; `Next` pushes the body and each `catch` keyword onto their
 *    own lines; `Keep` defers to captured source shape (plain mode
 *    degrades to `Same`). Site: `@:fmt(sameLine('expressionTry'))` on
 *    `HxTryCatchExpr.catches`.
 *  - `indentCaseLabels` — when `true` (default) the `case` / `default`
 *    labels and their bodies nest one indent level inside the switch
 *    braces; when `false` the labels stay flush with `switch` and only
 *    the case body receives the per-case `nestBody` indent. Upstream
 *    `indentation.indentCaseLabels`. Sites: `HxSwitchStmt.cases`,
 *    `HxSwitchStmtBare.cases`.
 *  - `indentObjectLiteral` — when `true` (default) AND
 *    `objectLiteralLeftCurly` is `Next`, an `ObjectLit` value on the RHS
 *    of `=` / `:` / `(` / `[` / keyword is wrapped in `Nest(_cols, val)`
 *    so its hardlines take one extra indent step (`var x =\n\t{...}`).
 *    Inert under `Same` (cuddled) leftCurly, and unconditionally inert
 *    when `false`. Upstream `indentation.indentObjectLiteral`. Sites:
 *    `@:fmt(indentValueIfCtor('ObjectLit', 'indentObjectLiteral',
 *    'objectLiteralLeftCurly'))` — currently `HxVarDecl.init` and
 *    `HxObjectField.value`; other RHS positions do not opt in.
 *  - `indentComplexValueExpressions` — when `true`, an `IfExpr` value on
 *    the RHS of `=` / `:` / `(` / `[` / keyword is wrapped in
 *    `Nest(_cols, val)` so its `{ … } else { … }` block bodies take one
 *    extra indent step. Default `false` (wrap inert). No leftCurly gate
 *    — the `{` after `if (cond)` is grammatically tied to the same line.
 *    Upstream `indentation.indentComplexValueExpressions`. Site:
 *    `HxVarDecl.init`. Forced on (knob bypassed) for class-member
 *    `var` / `final` initializers via `_inFieldLevelVar`.
 *  - `indentVarTypeHintAnon` — when `true` (default) AND
 *    `anonTypeLeftCurly` is `Next`, a multi-line `Anon` value on the RHS
 *    of a var's type-hint `:` is wrapped in `Nest(_cols, val)` for one
 *    extra indent step (`\tvar a:\n\t\t{\n\t\t\tx:Int\n\t\t};`). Inert
 *    under cuddled leftCurly or when `false`. Site: `HxVarDecl.type`
 *    (covers class-member `var` + local `VarStmt`); other type-hint
 *    sites do not opt in.
 *  - `functionTypeHaxe4` — around the `->` of a new-form (Haxe 4) arrow
 *    function type `(args) -> ret` (`HxArrowFnType.ret`'s lead). Default
 *    `Both` (`(Int) -> Bool`, upstream
 *    `whitespace.functionTypeHaxe4Policy`); `None` → `(Int)->Bool`.
 *  - `functionTypeHaxe3` — around the `->` of an old-form (Haxe 3)
 *    curried function type (`HxType.Arrow`'s `@:infix('->')`). Default
 *    `None` (`Int->Bool`, upstream `whitespace.functionTypeHaxe3Policy`);
 *    `Both` → `Int -> Bool`. Independent of `functionTypeHaxe4` so a
 *    config can space one arrow form while keeping the other tight.
 *  - `arrowFunctions` — around the `->` of a parenthesised arrow lambda
 *    expression `(params) -> body` (`HxThinParenLambda.body`'s lead).
 *    Default `Both` (upstream `whitespace.arrowFunctionsPolicy`); `None`
 *    → `(arg)->body`. The single-ident infix form `arg -> body` rides
 *    the Pratt infix path, which already adds surrounding spaces.
 *
 * MODULE-LEVEL BLANK-LINE KNOBS (all `Int` counts have override
 * semantics — the source-captured blank count is replaced, not floored —
 * unless noted):
 *  - `afterPackage` (default `1`) — exact blanks between a top-level
 *    `PackageDecl` / `PackageEmpty` and the following decl. Via
 *    `@:fmt(blankLinesAfterCtor('decl', 'PackageDecl', 'PackageEmpty',
 *    'afterPackage'))` on `HxModule.decls`; the mechanism is reusable
 *    for other "blank after ctor X" knobs by pointing at a different opt
 *    field.
 *  - `beforePackage` (default `0`) — exact blanks at the very START of a
 *    module whose first decl is a package directive; applies once per
 *    module, before any element is emitted. Via
 *    `@:fmt(blankLinesAtHeadIfCtor(…))` on `HxModule.decls`; reusable
 *    for any "blanks at head before ctor X" knob.
 *  - `beforeUsing` (default `1`) — exact blanks when the current decl is
 *    a `using` (`UsingDecl` / `UsingWildDecl`) and the previous is NOT a
 *    `using`. Consecutive `using` decls fall through to the trivia
 *    channel's binary `blankBefore` flag. Via
 *    `@:fmt(blankLinesBeforeCtor(…))`. Multi-info support lets one Star
 *    carry multiple after/before-ctor entries with independent ctor sets
 *    and opt fields, cascaded in source order.
 *  - `betweenImports` (default `0`) — exact blanks between two
 *    consecutive same-kind imports or usings whose dotted paths fall
 *    into different groups at the configured level; fires only on a
 *    level-mismatch boundary, same-level pairs fall through to source.
 *  - `betweenImportsLevel` — granularity of that level test: `All`
 *    (default; every same-kind boundary is a mismatch),
 *    `FirstLevelPackage` … `FifthLevelPackage` (compare the first N dot
 *    segments), `FullPackage` (whole path). Via
 *    `@:fmt(blankLinesBetweenSameCtorByLevel(…))` on `HxModule.decls`
 *    (one entry per kind set: imports + usings); the 6th meta arg names
 *    the format-neutral `WriteOptions.betweenImportsPathDiffers` adapter
 *    slot, default-wired by the grammar plugin to its level-aware
 *    path-comparison helper.
 *  - `beforeType` (default `1`) — exact blanks at the import/using →
 *    type-decl transition (previous decl is an import/using, current is
 *    a `ClassDecl` / `InterfaceDecl` / `AbstractDecl` / `EnumDecl` /
 *    `TypedefDecl` / `FnDecl`). Pairs not spanning that boundary fall
 *    through to the next cascade layer. Via
 *    `@:fmt(blankLinesOnTransitionAcross(…))` — consumers are
 *    `HxModule.decls`, `HxConditionalDecl.body` / `elseBody`, and
 *    `HxElseifDecl.body`. Conditional transparency comes from the shared
 *    `betweenImportsTailLeafClassify` / `betweenImportsHeadLeafClassify`
 *    adapters (same `'decl'` classifier), so `#if … import …` blocks
 *    count as imports for the boundary test.
 *  - `afterMultilineDecl` (default `1`) — exact blanks after a top-level
 *    decl whose ctor is in the predicate-gated set (`ClassDecl` /
 *    `InterfaceDecl` / `AbstractDecl` / `EnumDecl` / `FnDecl`) AND whose
 *    grammar-derived multi-line predicate fires (non-empty `members` /
 *    `ctors` / `BlockBody.stmts`). Empty-body single-line decls
 *    (`class C {}`) fall through to the source-driven cascade fallback.
 *  - `beforeMultilineDecl` (default `1`) — symmetric "before"
 *    counterpart; fires when the current decl is multi-line AND the
 *    previous isn't (on multi → multi transitions `afterMultilineDecl`
 *    wins). The `multiline` predicate is resolved at compile time by
 *    `WriterLowering.buildMultilinePredicate` from the grammar's
 *    `@:fmt(multilineWhenFieldNonEmpty(…))` /
 *    `@:fmt(multilineWhenFieldShape(…))` / `@:fmt(multilineCtor)` metas
 *    — zero runtime reflection.
 *  - `afterFileHeaderComment` (default `1`) — exact blanks AFTER the
 *    first top-level block-style comment of a module when fileheader
 *    semantics apply: the module either contains at least one
 *    `package` / `import` / `using` decl, OR the first decl carries 2+
 *    leading comments at module head. Site:
 *    `@:fmt(afterFileHeaderCommentBlanks)` on `HxModule.decls` (the
 *    concept is module-scope by definition).
 *  - `betweenMultilineComments` (default `0`) — exact blanks BETWEEN two
 *    consecutive block-style comments wherever block-block boundaries
 *    occur in `leadingComments` arrays or trailing-orphan arrays
 *    (`_trailLC`), except the slot already claimed by
 *    `afterFileHeaderComment`. Sites:
 *    `@:fmt(betweenMultilineCommentsBlanks)` — `HxModule.decls` and the
 *    class / interface / abstract member Stars.
 *  - `betweenSingleLineTypes` (default `0`) — blanks between any
 *    consecutive pair of single-line top-level type decls (neither
 *    matches the `multiline` predicate; empty-body decls and any
 *    `typedef T = …;` count as single-line). Insertion-only semantics:
 *    the override fires ONLY when the value is `> 0`, forcing exactly
 *    that count; at `0` the slot stays source-driven (the engine-level
 *    `>0` gate short-circuits the cascade ternary — this axis never
 *    strips blanks, only fills). The cascade gate consults BOTH prev and
 *    curr classifier kinds — it fires only when both ends are in the
 *    ctor set AND neither is multi-line; `afterMultilineDecl` /
 *    `beforeMultilineDecl` win when either side is multi-line. Via
 *    `@:fmt(blankLinesBetweenSameCtorIfNot(…))` on `HxModule.decls`.
 *
 * STRING INTERPOLATION AND METADATA:
 *  - `formatStringInterpolation` — when `true` (default, upstream
 *    `whitespace.formatStringInterpolation`) the writer re-emits each
 *    `${expr}` segment by recursing into the parsed `HxExpr`, producing
 *    canonical `${a + b}` spacing. When `false` it emits the
 *    parser-captured byte slice between `${` and `}` verbatim (`${a+b}`
 *    stays `${a+b}`). The captured slice rides the trivia-pair synth
 *    ctor `HxStringSegmentT.Block`'s positional `sourceText:String` arg
 *    (populated when the ctor carries `@:fmt(captureSource)`); plain
 *    mode does not capture, so the knob has no effect there.
 *  - `metadataFunctionLineEnd` — line-end policy for the metadata
 *    `@:tryparse` Star on `HxMemberDecl.meta` (upstream
 *    `lineEnds.metadataFunction`, ω-metadata-line-end-function):
 *      `None` (default) — source-driven inter-element separator from
 *        per-element `newlineBefore` trivia; no forced gap after the
 *        last metadata.
 *      `After` — every inter-element separator becomes a hardline AND a
 *        hardline fires after the last element (one metadata per line).
 *      `AfterLast` — separators stay source-driven, but a hardline
 *        ALWAYS fires after the last metadata.
 *      `ForceAfterLast` — separators forced to a single space (collapses
 *        source newlines between metas) AND a hardline fires after the
 *        last metadata.
 *    Consumed by `@:fmt(metaLineEndPolicy('metadataFunctionLineEnd'))`.
 *    Per-construct sisters (`metadataType` / `metadataVar` /
 *    `metadataOther`) do not exist yet.
 *
 * INTERNAL WRITE-TIME CHANNELS (documented inline on the fields below or
 * here; all default `false` / `null`):
 *  - `_inExprPosition` — set when descending through an
 *    expression-position parent (`HxCaseBranch.body` /
 *    `HxDefaultBranch.stmts` via `@:fmt(propagateExprPosition)`). Read
 *    by the dual-flag `bodyPolicy('caseBody', 'expressionCase')`
 *    flat-gate to dispatch between the statement-position `caseBody`
 *    policy and the expression-position `expressionCase` policy
 *    (ω-issue-423-mech-a): an outer `case X:` in a statement-position
 *    switch breaks per `caseBody`, while a case nested inside another
 *    case's body inherits the flag via opt-fanout and flattens per
 *    `expressionCase`.
 *  - `_classExtern` — set by `HxTopLevelDecl.decl` via
 *    `@:fmt(setBoolFlagFromStarCtor('_classExtern', 'modifiers',
 *    'Extern'))` when the sibling `modifiers` Star contains an `Extern`
 *    ctor. Read by `triviaBlockStarExpr`'s `addByInterMemberExpr` to
 *    suppress interMember-driven blank emission inside extern decls
 *    (ω-extern-class-no-blanks — extern class bodies round-trip with
 *    zero blanks regardless of `betweenVars` / `betweenFunctions` /
 *    `afterVars`); also selects `externExistingBetweenFields`.
 *  - `_inAnonFnBody` — set on descent into an anonymous function body:
 *    `HxFnExpr.body` (function-kw anon-fn), `HxParenLambda.body`
 *    (`(params) => body`), `HxThinParenLambda.body` (`(params) -> body`)
 *    via `@:fmt(propagateAnonFnContext)` + `_setAnonFnBody` opt-fanout
 *    (ω-arrow-lambda-body-context). Consumers: the `emptyCurlyBreak`
 *    branch in `triviaBlockStarExpr` dispatches `anonFunctionEmptyCurly`
 *    vs global `emptyCurly`; `HxExpr.BlockExpr.stmts` (via
 *    `@:fmt(leftCurlyAnonFnOverride('anonFunctionLeftCurly'))`) prepends
 *    a runtime-gated hardline before `{` when the flag is true AND the
 *    knob is `Next` (arrow-lambda body brace in Allman position), then
 *    clears the flag via `_clearAnonFnBody` so nested statements /
 *    blocks fall back to `blockLeftCurly`.
 *  - `_inTypedefBody` — set on descent into a typedef RHS type via
 *    `@:fmt(propagateTypedefContext)` + `_setTypedefBody` on
 *    `HxTypedefDecl.type` (ω-typedef-anon-force-multi). Consumed by
 *    `@:fmt(forceMultiInTypedef)` on `HxType.Anon.fields`: when the flag
 *    is true AND `anonTypeLeftCurly == Next`, the writer threads a
 *    runtime `forceMode` predicate into `WrapList.emit`, bypassing the
 *    cascade and laying the anon body out `OnePerLine` (forcing
 *    `=\n{\n\t...\n}` even when the fields fit flat) — with the default
 *    `Same` cascade, flat typedef-RHS anons stay cuddled. Cleared
 *    per-element so nested anons (`typedef T = {f:{g:Int}}`) revert to
 *    the layout-driven wrap.
 *  - `_inFieldLevelVar` — set on descent into a class-member `var` /
 *    `final` initializer (NOT a local-var statement) via
 *    `@:fmt(propagateFieldLevelVar)` + `_setFieldLevelVar` on
 *    `HxClassMember.VarMember` / `FinalMember`. Consumed by the
 *    `indentValueIfCtor('IfExpr', 'indentComplexValueExpressions')`
 *    entry on `HxVarDecl.init` — when set, the knob gate is bypassed
 *    (forced on), so a member `var x = if (…) … else …` indents its
 *    branches one step deeper regardless of the config knob. Local-var
 *    initializers (via `HxStatement.VarStmt` / `HxExpr.VarExpr`) keep
 *    the flag false and stay knob-gated.
 *  - `_fnSigBodyEmpty` — set while emitting an `HxFnDecl` whose body is
 *    empty or absent (`NoBody` / empty-`stmts` `BlockBody` /
 *    empty-`stmts` `UntypedBlockBody`), via the struct-level
 *    `@:fmt(propagateFnBodyEmpty('body'))` meta (evaluated at struct
 *    emit prelude, restored after). Consumed by `WrapList.emit`'s cols
 *    formula: when `true` AND `defaultAdditionalIndent` is positive, the
 *    FillLine / NoWrap path drops the `+1` paren-bump continuation,
 *    landing at `member+additional` (1 tab) instead of
 *    `member+1+additional` (2 tabs).
 *  - `_chainModeOverride` — `Null<WrapMode>` forcing
 *    `BinaryChainEmit.emit`'s cascade to a single mode
 *    (ω-chain-fillline-in-condwrap). Set by the runtime
 *    `_setChainModeOverride(opt, mode)` helper at
 *    `@:fmt(condWrap('<knob>'))` sites before the inner cond Ref
 *    writeCall evaluates: it swaps `opBoolChainWrap` and
 *    `opAddSubChainWrap` for a fresh `{rules: [], defaultMode: mode}`
 *    cascade so the chain dispatch (which reads those fields by name)
 *    sees the override transparently. The mode derives from
 *    `opt.<condKnob>.defaultMode`; `NoWrap` / unmappable modes leave the
 *    override `null`, suppressing allocation on the default path.
 */
typedef HxModuleWriteOptions = WriteOptions & {
	sameLineElse: SameLinePolicy,
	sameLineCatch: SameLinePolicy,
	sameLineDoWhile: SameLinePolicy,
	sameLineExpressionElse: SameLinePolicy,
	trailingCommaArrays: Bool,
	trailingCommaArgs: Bool,
	trailingCommaParams: Bool,
	trailingCommaObjectLits: Bool,
	trailingCommaAnonTypes: Bool,
	ifBody: BodyPolicy,
	elseBody: BodyPolicy,
	forBody: BodyPolicy,
	whileBody: BodyPolicy,
	doBody: BodyPolicy,
	returnBody: BodyPolicy,
	returnBodySingleLine: BodyPolicy,
	throwBody: BodyPolicy,
	catchBody: BodyPolicy,
	tryBody: BodyPolicy,
	caseBody: BodyPolicy,
	expressionCase: BodyPolicy,
	functionBody: BodyPolicy,
	anonFunctionBody: BodyPolicy,
	untypedBody: BodyPolicy,
	expressionIfBody: BodyPolicy,
	expressionElseBody: BodyPolicy,
	expressionForBody: BodyPolicy,
	expressionIfWithBlocks: Bool,
	leftCurly: BracePlacement,
	emptyCurly: EmptyCurly,
	objectLiteralLeftCurly: BracePlacement,
	anonTypeLeftCurly: BracePlacement,
	anonFunctionLeftCurly: BracePlacement,
	anonFunctionEmptyCurly: EmptyCurly,
	blockLeftCurly: BracePlacement,
	blockEmptyCurly: EmptyCurly,
	blockRightCurly: RightCurlyPlacement,
	anonFunctionRightCurly: RightCurlyPlacement,
	anonTypeRightCurly: RightCurlyPlacement,
	objectLiteralRightCurly: RightCurlyPlacement,
	objectFieldColon: WhitespacePolicy,
	typeHintColon: WhitespacePolicy,
	typeCheckColon: WhitespacePolicy,
	funcParamParens: WhitespacePolicy,
	callParens: WhitespacePolicy,
	anonFuncParens: WhitespacePolicy,
	anonFuncParamParensKeepInnerWhenEmpty: Bool,
	ifPolicy: WhitespacePolicy,
	forPolicy: WhitespacePolicy,
	whilePolicy: WhitespacePolicy,
	switchPolicy: WhitespacePolicy,

	/**
	 * Leading space before the `switch` keyword — the `before` / `around`
	 * side of the fork's `whitespace.switchPolicy`, kept separate from the
	 * (conflated) `switchPolicy` field so the `conditionParens` overwrite
	 * does not erase it. Visible only when the keyword follows a tight `(`
	 * (a call argument `f( switch …)` or an expression paren `( switch …)`).
	 */
	switchKwLeadingSpace: Bool,
	tryPolicy: WhitespacePolicy,
	elseIf: KeywordPlacement,
	fitLineIfWithElse: Bool,

	/**
	 * omega-arrow-value-if-reflow: when `true`, a value-`if`/`else` chain in
	 * an arrow-lambda body becomes one width-decided unit instead of a
	 * per-branch policy cascade - the whole chain renders flat when it fits
	 * at its column, otherwise one arm per line with each branch value glued
	 * to its own condition. Default `false` keeps the `expressionIfBody` /
	 * `expressionElseBody` policies in charge (fork parity), where a
	 * flat-fitting chain in an arrow body still explodes.
	 *
	 * Read at the `HxIfExpr` sites (`arrowValueIfReflow` on the typedef,
	 * `arrowValueIfReflowSite` on both branches) and gated at runtime on
	 * `_inArrowLambdaBody`, on `_arrowValueIfBlocked` (an ancestor member's
	 * refusal) and on an `else`-spine walk for captured comments - a chain
	 * carrying a comment ANYWHERE keeps the policy shape, in one piece.
	 *
	 * "In an arrow-lambda body" is the reach of `_inArrowLambdaBody`, which
	 * is slightly wider than the immediate body: it also survives a
	 * `cast(..., T)` operand, a `untyped` / `@:meta` prefix, and an
	 * enclosing value-`if`'s CONDITION. Those three positions re-flow too
	 * (measured non-corrupt and idempotent); `HxIfExpr`'s own doc lists
	 * them. Fed by `sameLine.expressionIfArrowBodyReflow`.
	 */
	expressionIfArrowBodyReflow: Bool,

	/**
	 * omega-value-if-fit: when `true`, a value-position `if` / `else if` chain is decided by FIT
	 * instead of always exploding — flat on one line when it fits at its column, and otherwise the
	 * EXACT shape the `expressionIfBody` / `expressionElseBody` policies produce today (each branch
	 * value on its own indented line, `else` back at the `if`'s indent).
	 *
	 * Mechanically it is the sibling of `expressionIfArrowBodyReflow` and shares its three seams: the
	 * `Group` wrapping the node, the soft pre-`else` gap, and the branch gap. The two differ in ONE
	 * place — the arrow knob forces each branch policy to `Same`, gluing the value to its condition,
	 * so a broken chain reads `if (c) v` / `else if (d) v` / `else v`; this knob instead softens the
	 * branch gap's own `Line('\n')` to `Line(' ')`, so a broken chain keeps the policy layout and only
	 * a FITTING one collapses. Both are the same idea: give the chain one break axis and let the group
	 * decide it for every arm at once.
	 *
	 * Gated on expression position rather than on `_inArrowLambdaBody`, so it covers every value-`if`
	 * — an initializer, a `return`, a call argument. An arrow body under BOTH knobs keeps the arrow
	 * shape: that gate is checked first. Default `false` keeps every value-`if` exploding (fork
	 * parity). Fed by `sameLine.expressionIfFit`.
	 */
	expressionIfFit: Bool,

	/**
	 * omega-value-if-fit branch cap: the largest number of VALUE BRANCHES an `expressionIfFit` chain
	 * may hold and still be allowed to collapse onto one line. `if (c) a else b` is 2, `if (c) a else
	 * if (d) b else e` is 3. `0` (default) means no cap -- every fitting chain collapses, the
	 * pre-cap behaviour.
	 *
	 * Width alone is the wrong gate for this: a three-branch chain of short atoms fits 140 columns
	 * easily and still reads as two decisions crammed into one line, while the same width buys a
	 * two-branch chain nothing but a saved line. The count is what the reader parses, so the count is
	 * what the knob measures. Refusing a chain leaves it on the exact `expressionIf` policy layout,
	 * the same answer the knob-off path gives. Fed by `sameLine.expressionIfFitMaxBranches`.
	 */
	expressionIfFitMaxBranches: Int,

	/**
	 * omega-elseif-comment-reflow: when `true`, an `else if` whose nested `if`
	 * carries EXACTLY one interposed `//` line comment glues as usual and
	 * re-emits that comment at the end of the nested `if`'s head line - after
	 * the then-body's `{` when it is braced, after the condition's `)` when the
	 * body policy already puts a bare body on the next line. Both are the same
	 * structural position: the first unconditional break after the condition.
	 *
	 * Default `false` keeps the pre-knob layout, which is what the old
	 * haxe-formatter produced and what the writer round-trips byte for byte:
	 * `else` alone on its line, the comment one indent deeper, the nested
	 * `if` back at the outer indent.
	 *
	 * Read at `HxIfStmt.elseBody` (`@:fmt(elseIfCommentReflow)`) on the
	 * `elseIf` glue path only, and refused - layout unchanged - for a block
	 * comment, for more than one comment, for a same-line comment cuddled to
	 * the `else` itself, for a nested `if` head that ALREADY carries a trailing
	 * `//`, for an EMPTY then-body (`{}` closes on the head line, so the next
	 * break already belongs to that `if`'s own `else`), and whenever the nested
	 * `if`'s own emission offers no provable head-line anchor (a body that
	 * renders flat, or any Doc shape the walk cannot name).
	 * `sameLine.elseBody: "keep"` also disables it: a `Keep`
	 * policy routes the else through `buildBodyKeepLayout`, which the knob does
	 * not reach.
	 *
	 * Width never causes a refusal - an over-long glued head line is accepted
	 * rather than re-wrapped - but the relocated comment does stay visible to a
	 * `conditionWrapping` probe that measures the whole rendered line, exactly
	 * as a hand-written trailing comment in that position would; hiding it
	 * there would cost idempotence. Statement position only - the value-position
	 * twin `HxIfExpr` is out of scope. Fed by `sameLine.elseIfCommentReflow`.
	 */
	elseIfCommentReflow: Bool,

	/**
		 * ω-fitline-body-glue: when a `FitLine` construct body (`if` / `for` /
		 * `while`) does not fit on the header line, may it stay GLUED to that line
		 * and break inside itself, instead of always moving one line down and one
		 * indent deeper?
		 *
		 * Only bodies the next line would NOT rescue are affected: the probe asks
		 * whether the body's flat width fits at the continuation indent, and when it
		 * does the body still takes its own line exactly as before. When it does not,
		 * moving it buys nothing — it breaks internally either way — so the glue saves
		 * a line and an indent level:
		 *
		 * ```
		 * if (c)                 →   if (c) ({
		 *     ({                          field: value, …
		 *         field: value, …    })
		 *     })
		 * ```
		 *
		 * The glue itself stays width-gated by `BodyFit.glueLayout`, so the header
		 * line can never run past `maxLineLength` because of it.
		 *
		   * The ARROW-LAMBDA body (`xs.map(m -> ({ … }))`) takes the same answer through
	 * `BodyFit.continuationRescuesArrowBody`: it is the other placement that puts
	 * a body after a header token instead of under it, and it asked the same
	 * question with only one of the two answers available. There the glue is
	 * additionally scoped to a body that IS an expression paren — every other
	 * arrow body measured WORSE glued (an `if` body explodes its own condition at
	 * the deeper column), so only the shape that provably pays is accepted.
	 *
	 * Default `false` is the haxe-formatter layout the corpus pins. Fed by
	 * `sameLine.fitLineBodyGlue`; consumed by `WriterLowering.buildBodyFitExpr`'s
	 * construct-group arm and by the two `@:fmt(arrowBodyLineWrap)` emit sites, so
	 * it reaches exactly the bodies whose placement those own — a `Keep` / `Same` /
	 * `Next` body policy never sees it.
	 */
	fitLineBodyGlue: Bool,

	/**
	 * ω-loop-body-if-else-next: break a `for` / `while` header away from a body
	 * that is an `if` carrying an `else`, placing the whole `if`/`else` one line
	 * down and one indent step in.
	 *
	 * Under `forBody` / `whileBody: fitLine` a one-line-able body glues to the
	 * loop header. For a bare guard `if` that is the point — `for (x in xs) if
	 * (c) f(x);` is a deliberate idiom and stays glued. For an `if` that owns an
	 * `else`, the same glue leaves the `else` at the LOOP's indent, where it
	 * reads as a branch of the loop rather than of the `if`.
	 *
	 * The gate is therefore the BODY's shape, asked at runtime through
	 * `anyparse.format.LoopBodyShape.isIfWithElse`. That is what config alone
	 * cannot express: `forBody: next` produces the same layout for the `if`/
	 * `else` pair but moves the guard idiom under the header too.
	 *
	 * Distinct from `fitLineIfWithElse` one storey down, which asks whether the
	 * `if` BEING placed has an `else` sibling of its own. That flag is shared
	 * with upstream semantics and is deliberately not widened to loops.
	 *
	 * Default `false` is fork parity. Fed by `sameLine.loopBodyIfElseNext`;
	 * consumed by `WriterLowering.buildBodyFitExpr` at the two fields carrying
	 * `@:fmt(loopBodyIfElseNext(...))`, so a `Keep` / `Same` / `Next` body policy
	 * never sees it.
	 */
	loopBodyIfElseNext: Bool,

	/**
	 * ω-cond-expr-fit: break an expression-scope `#if … #end` region at its
	 * directive seams — the way a regular `if / else if / else` chain breaks —
	 * when the GLUED form does not fit the line. One `GroupWithRestProbe` wraps
	 * the whole `ConditionalExpr` emission, so every seam answers TOGETHER: a
	 * fitting region keeps its spaces, an over-wide one drops each directive
	 * onto its own line at the statement indent with each branch value one
	 * indent step deeper. Off (the default), layout stays purely source-driven.
	 *
	 * Fed by `sameLine.conditionalExprFit`; consumed by the `ConditionalExpr`
	 * ctor's `@:fmt(condExprFitGroup)` wrap, `WriterLowering.padTrailingDoc`'s
	 * `@:fmt(condExprFitBreak)` arm, `nestBodyOnSourceNewlineWrap`'s flat arm,
	 * and the `elseifs` Star's inter-element / trailing-pad separators.
	 */
	conditionalExprFit: Bool,
	ifElseSemicolonNextLine: Bool,
	afterFieldsWithDocComments: CommentEmptyLinesPolicy,
	existingBetweenFields: KeepEmptyLinesPolicy,
	externExistingBetweenFields: KeepEmptyLinesPolicy,
	beforeDocCommentEmptyLines: CommentEmptyLinesPolicy,
	betweenVars: Int,
	betweenFunctions: Int,
	afterVars: Int,
	afterStaticVars: Int,
	betweenStaticFunctions: Int,
	interfaceBetweenVars: Int,
	interfaceBetweenFunctions: Int,
	interfaceAfterVars: Int,
	betweenEnumCtors: Int,
	beginType: Int,
	endType: Int,
	// ω-enum-begin-end: dedicated enum-body begin/end blank knobs (fork's
	// `enumEmptyLines: TypedefFieldsEmptyLinesConfig`, `@:default(0)`). Kept
	// distinct from the class-scoped `beginType` / `endType` so a config that
	// sets `classEmptyLines.beginType` (shared knob) no longer leaks a leading
	// blank into `enum` bodies. Read only by `HxEnumDecl.ctors`' parameterised
	// `@:fmt(beginEndType('enumBeginType', 'enumEndType'))`.
	enumBeginType: Int,
	enumEndType: Int,
	// ω-enumabstract-begin-end: dedicated `enum abstract` body begin/end blank
	// knobs (fork's `enumAbstractEmptyLines: EnumAbstractFieldsEmptyLinesConfig`,
	// `@:default(0)`). `enum abstract` shares the `HxAbstractDecl` grammar with a
	// plain `abstract`, so the writer distinguishes them by the transient
	// `_inEnumAbstract` flag (set by `EnumAbstractDecl(decl)`) rather than a
	// per-type knob-name; when set, the `beginEndType` count reads these instead
	// of the class-scoped `beginType` / `endType`.
	enumAbstractBeginType: Int,
	enumAbstractEndType: Int,
	// ω-typedef-between-fields: dedicated typedef-RHS anon-body blank-line
	// knobs (fork's `TypedefFieldsEmptyLinesConfig`), read only by the
	// `@:sep`-Star force-multi branch under `_inTypedefBody`. Kept distinct
	// from the class-scoped `beginType` / `endType` (which the typedef anon
	// path never reads) so typedef + class scopes never cross-contaminate.
	// `typedefExistingBetweenFields` governs source-blank pass-through when
	// `typedefBetweenFields == 0`; a positive `typedefBetweenFields` forces
	// that exact count regardless of the policy. Defaults `0` / `0` / `Keep`
	// / `0` are fork-parity values.
	typedefBeginType: Int,
	typedefBetweenFields: Int,
	typedefExistingBetweenFields: KeepEmptyLinesPolicy,
	typedefEndType: Int,
	afterLeftCurly: KeepEmptyLinesPolicy,
	beforeRightCurly: KeepEmptyLinesPolicy,
	uniformStatementBlanks: UniformStatementBlanksPolicy,
	typedefAssign: WhitespacePolicy,
	typedefIntersection: WhitespacePolicy,
	typeParamDefaultEquals: WhitespacePolicy,
	typeParamOpen: WhitespacePolicy,
	typeParamClose: WhitespacePolicy,
	anonTypeBracesOpen: WhitespacePolicy,
	anonTypeBracesClose: WhitespacePolicy,
	objectLiteralBracesOpen: WhitespacePolicy,
	objectLiteralBracesClose: WhitespacePolicy,
	// ω-arrow-body-objlit-pad-keep: when `true`, the open-side
	// `objectLiteralBracesOpen` inner pad is applied EVEN when the literal
	// is an arrow-lambda body (`u -> { email: v }`). Default `false`
	// mirrors the fork's `MarkWhitespace.successiveParenthesis`
	// compress-mode `case Arrow: return;` which drops the opening-brace
	// pad after a `->` token (`u -> {email: v }`). Fed by
	// `whitespace.bracesConfig.objectLiteralBraces.arrowBodyOpenPad`.
	objectLiteralArrowBodyOpenPad: Bool,
	// ω-arrow-body-objlit-reflow: when `true`, a source-multiline object
	// literal that is an arrow-lambda body drops its source newlines and
	// the wrap cascade re-flows it by width (`u -> { a: 1 }` when it
	// fits). Default `false` keeps the source-multiline force-multi
	// shape (fork parity). Fed by `whitespace.bracesConfig.
	// objectLiteralBraces.arrowBodyReflow`.
	objectLiteralArrowBodyReflow: Bool,
	// ω-single-stmt-braces: when `true`, the writer drops the curly braces
	// around an `if` / `else` / `for` / `while` body whose block holds
	// exactly one safe single statement (`if (c) { return x; }` →
	// `if (c) return x;`). Safety gates (dangling-else, comments,
	// terminator, declaration scoping) live in
	// `anyparse.format.SingleStmtBraces.unwrapStmt` — every gate fails
	// closed (keeps braces). Trivia-mode writer only; the plain writer
	// ignores the knob. Default `false` (keep braces — byte-inert). Fed by
	// `whitespace.bracesConfig.singleStatementBraces` (`"remove"` → true).
	dropSingleStmtBraces: Bool,
	// ω-switch-subject-parens: `true` drops the redundant parens around a
	// `switch (subject) { … }` subject (`switch v { … }`); the leading-brace
	// subject carve-out (object literal / block) still keeps them. Covers both
	// statement- and expression-position switch (shared `HxSwitchStmt`
	// grammar). Default `false` (keep parens — byte-inert). Fed by
	// `whitespace.parenConfig.switchSubjectParens` (`"remove"` → true).
	dropSwitchSubjectParens: Bool,
	// ω-optional-semicolon (E11): three-way policy for the `@:trailOpt(';')`
	// statement terminator Haxe lets a `}`-terminated statement omit.
	// `Preserve` (default) re-emits source presence — byte-inert, fork
	// parity. `Always` emits it on every slot carrying
	// `@:fmt(optionalSemicolon(...))`; `Never` drops it wherever that
	// flag's shape gate proves it optional. Trivia-mode writer only; the
	// plain writer keeps its `trailOptShapeGate` AST-shape gate. Fed by
	// `whitespace.optionalSemicolon`.
	optionalSemicolon: OptionalSemicolon,
	// omega-semi-before-else: the SEPARATE three-way policy for the optional
	// `;` Haxe accepts between a value-`if`'s then-branch and its `else`
	// (`final x = if (c) a; else b;`). A distinct key from `optionalSemicolon`
	// because the two answer different questions about the same character: a
	// statement's terminator is a legitimate style choice, while a `;` before
	// `else` is an editing leftover -- a config that wants `Always` for the
	// first wants `Never` for the second, which one shared key cannot express.
	// `Preserve` (default) re-emits source presence (byte-inert, fork parity);
	// `Never` drops it; `Always` emits it. Only ever consulted when the node
	// HAS an `else`: with none, that `;` can be the ENCLOSING statement's own
	// terminator, so source presence always wins there. Fed by
	// `whitespace.semicolonBeforeElse`.
	semicolonBeforeElse: OptionalSemicolon,
	accessBracketsOpen: WhitespacePolicy,
	accessBracketsClose: WhitespacePolicy,
	arrayLiteralBracketsOpen: WhitespacePolicy,
	arrayLiteralBracketsClose: WhitespacePolicy,
	mapLiteralBracketsOpen: WhitespacePolicy,
	mapLiteralBracketsClose: WhitespacePolicy,
	comprehensionBracketsOpen: WhitespacePolicy,
	comprehensionBracketsClose: WhitespacePolicy,
	callParensInsideOpen: WhitespacePolicy,
	callParensInsideClose: WhitespacePolicy,
	// ω-condition-parens: per-condition-paren INNER pad, fed by
	// `whitespace.parenConfig.{if|while|switch}ConditionParens` /
	// `catchParens` / `sharpConditionParens` / `conditionParens`
	// (catch-all). `InsideOpen` (from `openingPolicy.after`) is the inner
	// `( ` pad; `InsideClose` (from `closingPolicy.before`) is the inner
	// ` )` pad. The keyword→`(` gap reuses the existing `ifPolicy` /
	// `whilePolicy` / `switchPolicy` / `tryPolicy` knobs (fed from the
	// same `openingPolicy.before` via a paren→kw flip in the loader);
	// `catchParensGap` / `sharpCondParensGap` are dedicated because catch
	// (`@:kw('catch')`) and `#if` (`HxConditionalStmt`) have no pre-
	// existing gap knob. Default None → tight `if (a)` / `catch (e)`.
	ifCondParensInsideOpen: WhitespacePolicy,
	ifCondParensInsideClose: WhitespacePolicy,
	whileCondParensInsideOpen: WhitespacePolicy,
	whileCondParensInsideClose: WhitespacePolicy,
	switchCondParensInsideOpen: WhitespacePolicy,
	switchCondParensInsideClose: WhitespacePolicy,
	catchParensGap: WhitespacePolicy,
	catchParensInsideOpen: WhitespacePolicy,
	catchParensInsideClose: WhitespacePolicy,
	sharpCondParensGap: WhitespacePolicy,
	sharpCondParensInsideOpen: WhitespacePolicy,
	sharpCondParensInsideClose: WhitespacePolicy,
	objectLiteralWrap: WrapRules,
	callParameterWrap: WrapRules,
	arrayLiteralWrap: WrapRules,
	mapLiteralWrap: WrapRules,
	multiVarWrap: WrapRules,
	casePatternWrap: WrapRules,
	anonTypeWrap: WrapRules,
	methodChainWrap: WrapRules,
	opBoolChainWrap: WrapRules,
	opAddSubChainWrap: WrapRules,
	conditionWrap: WrapRules,
	ternaryWrap: WrapRules,
	functionSignatureWrap: WrapRules,
	anonFunctionSignatureWrap: WrapRules,
	metadataCallParameterWrap: WrapRules,
	typeParameterWrap: WrapRules,
	expressionWrappingWrap: WrapRules,
	implementsExtendsWrap: WrapRules,
	expressionTry: SameLinePolicy,
	indentCaseLabels: Bool,
	indentObjectLiteral: Bool,
	indentComplexValueExpressions: Bool,
	indentVarTypeHintAnon: Bool,
	functionTypeHaxe4: WhitespacePolicy,
	functionTypeHaxe3: WhitespacePolicy,
	intervalPolicy: WhitespacePolicy,
	arrowFunctions: WhitespacePolicy,
	afterPackage: Int,
	beforePackage: Int,
	beforeUsing: Int,
	betweenImports: Int,
	betweenImportsLevel: HxBetweenImportsLevel,
	keepSourceBlankAcrossConditional: Bool,
	beforeType: Int,
	afterMultilineDecl: Int,
	beforeMultilineDecl: Int,
	// ω-after-conditional-block — number of blank lines forced after a
	// module-level `#if … #end` (`HxDecl.Conditional`) whose tail leaf is
	// NEITHER an import / using NOR a type-level decl. Mirrors fork's
	// behaviour: at module top level there is no keep-existing-blanks pass
	// (that only runs inside function bodies), so a `#if … #error … #end`
	// followed by a type decl collapses to zero blanks unless a mark pass
	// re-adds one. Fork's `markImports` re-adds `importAndUsing.beforeType`
	// (=1) when the conditional's tail is an import / using, and
	// `betweenTypes` (=1) re-adds one when the tail is a type-level decl;
	// every other tail (error, package directive, opaque conditional) keeps
	// the module default of 0. Default `0` strips the source blank for those
	// other-tailed conditionals; the import- / type-tailed cases fall
	// through to the source-driven count (kept). See
	// the generated `tailLeafKeepsBlankAfterConditional` for the gate walker.
	afterConditionalBlock: Int,
	afterFileHeaderComment: Int,
	betweenMultilineComments: Int,
	betweenSingleLineTypes: Int,
	// ω-blank-around-multiline-members — blank lines forced into the gap
	// between two adjacent TYPE MEMBERS when either of them renders across
	// more than one line. `betweenSingleLineTypes` above is its module-level
	// sibling, but that one resolves multi-line-ness STRUCTURALLY at macro
	// time (a class is multi-line iff it declares members). A field cannot be
	// classified that way — `final a = ['x'];` fits and `final a = [… 20 …];`
	// does not, from the same shape — so this knob is answered by measuring
	// the built Doc instead. `0` (the default) leaves every gap to the
	// source-driven `existingBetweenFields` path.
	aroundMultilineFields: Int,
	formatStringInterpolation: Bool,
	metadataFunctionLineEnd: MetadataLineEndPolicy,
	_inExprPosition: Bool,
	// ω-case-sibling-symmetry — ONE placement number for a whole switch's
	// case bodies, written once per switch by the cases Star's
	// `@:fmt(caseSiblingSymmetry(...))` pre-pass and handed to every sibling
	// body. `BodyFit.fitLineLayout` turns it into an `IfIndentWidthExceeds`
	// probe, so all siblings of one switch reach ONE placement verdict: if
	// the number does not fit, every body drops to the next line, including
	// the ones that would fit and the glued ones. THREE values, not two:
	//  - a plain `>= 0` — the MEASURED channel: the widest sibling case
	//    clause's FLAT width (`case <patterns>: <body>`, separator
	//    included);
	//  - `BodyFit.SIBLING_FORCE_BREAK` — the STRUCTURAL channel. Not a
	//    measurement but a verdict, reached because some unit of the switch
	//    renders below its own label at every budget (a multi-statement
	//    body, a flat-refused one, a label-splice region); it is spelled as
	//    an ordinary large width precisely so nothing downstream needs an
	//    arm for it;
	//  - `BodyFit.SIBLING_NONE` (`-1`, the default, and what the pre-pass
	//    records when no sibling could render inline at all) — "no
	//    coordination": every body decides for itself, exactly as before
	//    the slice.
	// `BodyFit.SIBLING_PROBING` (`-2`) also lands here, but only in
	// transit: the pre-pass stamps it for the duration of its own
	// measurement so a nested Star returns its subtree unchanged instead of
	// running a second pre-pass (ω-case-sym-linear). Always written by the
	// pre-pass, never inherited, so a nested switch coordinates its own
	// cases rather than the enclosing switch's.
	_caseSiblingFlatWidth: Int,
	// ω-expressionif-collapse — narrow companion to `_inExprPosition`, set
	// ONLY on the immediate value of a value-yielded `if`/`else` branch
	// (`HxIfExpr.thenBranch` / `elseBranch` carrying
	// `@:fmt(propagateValueIfBranch)`). Read by `HxObjectLit.fields`
	// (`@:fmt(reflowInExprPosition)`) so a source-multiline object literal
	// that is the DIRECT branch value collapses to single-line — mirroring
	// fork's "collapse object literal only when it is a value-if branch
	// body" rule, while leaving source-multiline object literals everywhere
	// else (var-init, call-args, array-elements) untouched. Cleared by
	// `_setExprPosition` on any descent into a fresh expression-position
	// frame (call-arg / array-element / operand / arrow-body) so the flag
	// never leaks into an object literal nested deeper than the immediate
	// branch value. Default `false`.
	_inValueIfBranch: Bool,
	// ω-arrow-body-objlit-pad — sister to `_inValueIfBranch`, set ONLY on the
	// immediate body of an arrow lambda (`HxExpr.ThinArrow` right operand /
	// `HxThinParenLambda.body` carrying `@:fmt(propagateArrowLambdaBody)`).
	// Read by `HxObjectLit.fields` (`@:fmt(arrowBodyOpenPadSuppress)`) to drop
	// the `objectLiteralBracesOpen` inner pad — mirroring fork's
	// `MarkWhitespace.successiveParenthesis` compress-mode `case Arrow:
	// return;`, which never applies the opening-brace policy to a `{`/`(`/`[`
	// whose previous token is `->` (so `u -> {email: v }`, not `u -> { email:
	// v }`, under `objectLiteralBraces.openingPolicy: "after"`). Cleared by
	// `_setExprPosition` on any descent into a fresh expression-position frame
	// (call-arg / array-element / operand / paren inner), so only the
	// LEFTMOST-LEAF object literal of the body — the one whose `{` sits right
	// after the `->` token — sees the flag. Default `false`.
	_inArrowLambdaBody: Bool,
	// omega-arrow-value-if-reflow - set on the branch writes of an `HxIfExpr`
	// that REFUSED the arrow-body reflow (a comment anywhere on its
	// `else`-spine), so every deeper member of the same chain refuses too and
	// the chain renders in ONE shape. Its own field rather than a clear of
	// `_inArrowLambdaBody`: that flag is shared with the object-literal arrow
	// knobs, and borrowing it as a refusal channel silently disabled the
	// objlit open-pad / reflow inside the refused branch. Cleared by
	// `_setExprPosition` on any fresh expression-position frame (call arg,
	// operand, nested arrow body), so it never leaves its own chain. Default
	// `false`.
	_arrowValueIfBlocked: Bool,
	// omega-arrow-value-if-reflow - set on the write of a list ELEMENT that
	// carries a captured trailing comment (`@:fmt(arrowValueIfElemTrail)` on
	// the element's Star), so an arrow-body value-`if` chain inside that
	// element refuses the reflow. The comment sits after the chain's LAST
	// branch value, which is the one position no field of the `HxIfExpr` owns
	// - the slot belongs to the enclosing list element, out of reach of both
	// the `else`-spine walk and `_arrowValueIfBlocked`. Deliberately NOT
	// cleared by `_setExprPosition`: the signal has to cross the call-arg
	// frame AND the arrow-lambda body frame to reach the chain, and it is set
	// per element, so it never spans a sibling. Default `false`.
	_arrowValueIfElemTrailComment: Bool,
	_classExtern: Bool,
	_inAnonFnBody: Bool,
	_inTypedefBody: Bool,
	// ω-enumabstract-begin-end: set on the inner `HxAbstractDecl` opt when it is
	// written as the body of an `enum abstract` (via `EnumAbstractDecl(decl)`'s
	// `@:fmt(propagateEnumAbstractContext)`), so its `beginEndType` blank count
	// reads `enumAbstractBeginType` / `enumAbstractEndType`. Default `false`.
	_inEnumAbstract: Bool,
	_fnSigBodyEmpty: Bool,
	_chainModeOverride: Null<WrapMode>,
	_callArgChainNest: Bool,
	_suppressMore: Bool,
	_parenInCondition: Bool,
	// ω-compare-operand-linewrap: set on the ternary CONDITION's opt (via
	// `_setInTernaryCond`) so `lowerInfixBranch` suppresses the `==`/`!=`
	// operand-overflow break for a compare that IS a ternary condition -- the
	// fork breaks the ternary `?`/`:`, not the compare. Default false → every
	// non-ternary compare (assignment / chain operand / statement condition)
	// still breaks on a genuine line overflow.
	_inTernaryCond: Bool,
	// omega-call-grouprestprobe-subposition: set on a `Call` subtree that is NOT
	// in statement/expression position, so the `Call` ctor skips the
	// `groupRestProbe` rest-of-line fit bias. Set-sites, all via
	// `_setSuppressCallRestProbe`:
	//  1. Case-pattern body (`HxCasePattern.expr`'s `@:fmt(suppressCallRestProbe)`):
	//     a ctor pattern (`case Nest(_, _) | Concat(_):`) must NOT wrap its args
	//     -- the fork breaks the `|` (BitOr) chain, not the ctor args.
	//  2. `??` (Coalesce) operands (`lowerInfixBranch`): `??` is right-assoc and
	//     renders via the non-chain infix path, so its outer-left operand carries
	//     the whole rest-chain; the rest-probe would over-count and wrap operand
	//     args the fork keeps glued (the fork packs left-to-right, breaking only
	//     the overflowing operand's brackets). Reverts `??` operands to pristine
	//     plain-Group (wrap-on-own-overflow), matching the self-canonical shape.
	//  3. opAddSub / opBool chain leaf operands (`lowerInfixChain`): a `Call` leaf
	//     -- especially the head -- would rest-probe the whole chain tail and split
	//     its own args though the call fits its line; the chain absorbs the overflow
	//     via its operator break / paren-open instead.
	//  4. Nested call arguments (`lowerPostfixStar`, the two `callParameterWrap`
	//     Stars = `HxExpr.Call` / `HxNewExpr`): a `Call` in argument position would
	//     count the outer call's sibling args + trailing `;`; suppressing lets the
	//     OUTER call wrap (open its paren) first while the inner call stays flat.
	// Not cleared on descent, so nested `Call`s inherit it. Default false -> every
	// statement/expression-position call keeps the rest-probe (wraps at limit+1,
	// counting the trailing `;`).
	_suppressCallRestProbe: Bool,
	// ω-complex-item-count: the subtree is a case PATTERN or a switch SUBJECT,
	// so an array literal inside it must not classify its elements for the
	// `complexItemCount >= n` cascade condition. Both positions can hold a shape
	// the classifier cannot tell from a value: an enum-constructor pattern
	// (`case [Some(a), Some(b)]:`) parses as two `Call`s, and the fork never
	// wraps a switch subject at all. Set via `_setSuppressComplexItems` from
	// `@:fmt(suppressComplexItems)` on `HxCasePattern.expr` /
	// `HxSwitchStmt(Bare).expr`; not cleared on descent, so a nested pattern
	// inherits it. Default false → every value-position array classifies.
	_suppressComplexItems: Bool,
	_varKwNewline: Bool,
	_inFieldLevelVar: Bool,
	// ω-single-stmt-braces: dangling-else suppress frame. Set (via
	// `_setSsbSuppress`) on the opt of an `if`-statement's then-body write
	// when the `if` carries an `else`, so every `dropSingleStmtBraces`
	// unwrap nested anywhere inside that then-body no-ops:
	// `if (a) while (c) { if (b) x; } else y` must keep the loop-body
	// braces — unwrapping would rebind the outer `else` to `if (b)`.
	// Never cleared on descent (over-suppression inside nested braced
	// regions is safe, merely conservative). Default `false`.
	_ssbSuppress: Bool,
	// ω-single-stmt-braces CHAIN symmetry: set (via `_setSsbChainSuppress`)
	// on the opt of an else-if continuation write when the CHAIN ROOT found
	// that some branch keeps its braces (`SingleStmtBraces.chainForcesBraces`).
	// It forces every downstream else-if branch to keep braces too, so
	// `if (a) { one; two; } else if (b) { three; }` stays fully braced
	// instead of de-bracing the `else if` half. Unlike `_ssbSuppress` this is
	// CLEARED when descending into a branch's own content (then-body /
	// terminal-else writeCall), so an independent if-chain nested inside a
	// branch still de-braces on its own merits. Default `false`.
	_ssbChainSuppress: Bool,
	// ω-keep-chain — set on the leaf-operand opt
	// when an opAddSub / opBool chain resolves to `WrapMode.Keep`. Read by the
	// `ParenExpr` (`@:fmt(expressionParenHardFlatten)`) emit to take the GLUED
	// branch UNCONDITIONALLY: a kept chain preserves the source line structure
	// verbatim (operand lines may exceed `lineWidth`), so its inner parens must
	// NOT re-open via the width-driven `IfFullLineExceeds` probe — mirror fork's
	// `keep2` `noLineEndBefore` lock on operand boundaries with no source break.
	// Default false → non-keep / Plain are byte-inert.
	_keepFlatInner: Bool,
	// ω-keep-chain — set by an enclosing
	// `ParenExpr` (`@:fmt(expressionParenHardFlatten)`) on its inner opt. A
	// `WrapMode.Keep` opAddSub / opBool chain reads it to suppress BOTH its own
	// `_headBreak` (the source return-head newline is reproduced at the
	// return-VALUE level instead) AND its continuation `Nest` (the value-level
	// break already supplies the +cols, so chain operators co-indent with the
	// head rather than compounding to +2cols). Non-keep chains ignore it (gated
	// on `isKeep`). Default false → Plain / direct-value chains byte-inert.
	// Also read by `WriterLowering.lowerTernaryBranch` as the "inside an explicit
	// expression paren" signal: a rest-aware ternary is EXCLUDED when this is set
	// (the paren owns the wrap). Keep the setter firing for ANY expression paren,
	// not only Keep chains, or that ternary gate silently breaks.
	_keepChainInParen: Bool,
	// ω-typedef-intersection-operand-break — set per-element by
	// `HxTypedefDecl.intersections`'s trivia-Star loop on the opt passed to a
	// `& Type` clause whose PRECEDING clause rendered multi-line and ended with
	// a close brace (a broke anon-struct operand: `A & {\n…\n} & B`). The clause
	// reads it via `@:fmt(typedefIntersectionBreak)` on
	// `HxIntersectionClause.type` and emits the `&`→operand whitespace as a
	// hardline + one-tab nest (`} &\n\tB`) instead of the `typedefIntersection`
	// After space (`} & B`), mirroring fork's `MarkLineEnds` `lineEndAfter` on
	// the `&` that follows a `BrClose`. Default false → single-line
	// intersections (`A & B`, `A & {x:Int} & B`) stay glued byte-identically.
	_intersectionOperandBreak: Bool,
	// ω-elseif-body-break: write-time-only signal flagging that the current
	// statement is being rendered as the direct `else` branch of an enclosing
	// `if` (i.e. an `else if`). Set by `HxIfStmt.elseBody`'s
	// `@:fmt(propagateElseIfBranch)` ONLY when the else-branch runtime ctor is
	// `IfStmt`, and cleared on the inner `if`'s then-body recursion
	// (`@:fmt(clearElseIfBranch)`) so it reaches exactly that one inner `if`'s
	// body fit-gate and dies. Read by the `fitLineIfWithElse` body gate
	// (`buildBodyFitExpr`) as an extra break trigger: mirrors haxe-formatter's
	// `MarkSameLine.isPartOfIfElse` "if inside else" clause, so a fitting
	// single-statement `else if (c) stmt;` degrades to `Next` under
	// `sameLine.ifBody:fitLine` + `fitLineIfWithElse:false`. Default false.
	_inElseIfBranch: Bool
};
