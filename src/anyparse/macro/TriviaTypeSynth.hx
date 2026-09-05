package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.macro.MacroNames.*;

using Lambda;

/**
 * ω₄c — Atomic synthesis of paired `*T` typedefs / enums for
 * trivia-bearing grammar rules.
 *
 * Every rule that `TriviaAnalysis` marked with `trivia.bearing = true`
 * gets a sibling type suffixed `T`, placed in a dedicated synth module
 * at `<rootPack>.trivia.Pairs`. The synthesised types mirror the
 * originating rules structurally with three mechanical rewrites:
 *
 *  1. `Ref` fields/args whose target is itself bearing switch to the
 *     target's `*T` variant — non-bearing refs (e.g. `HxExpr`,
 *     `HxIdentLit`) stay unchanged.
 *  2. `Array<T>` containers whose Star carries `trivia.starCollects`
 *     wrap the element type in `anyparse.runtime.Trivial<…>` so the
 *     element's source-fidelity trivia (leading comments, blank-line
 *     marker, trailing comment) sits alongside the wrapped node.
 *  3. `Null<T>` wrapping + `@:optional` meta are preserved so downstream
 *     struct-literal construction in Trivia-mode Lowering compiles
 *     against the same surface the Plain-mode code compiles against.
 *
 * **Why atomic `defineModule`, not per-type `defineType`?** The grammar
 * reference graph is cyclic — `HxStatementT` references `HxIfStmtT`
 * which references `HxStatementT`. `defineType` eagerly type-checks
 * each TypeDefinition's field types on insertion, so the first call
 * fails the moment it encounters a sibling reference that hasn't been
 * registered yet. `Context.onTypeNotFound` was investigated as the
 * cycle-safe alternative but empirically does **not** fire for
 * references discovered during typing of a callback-returned
 * TypeDefinition — Haxe only consults the hook for the initial
 * top-level lookup. `defineModule` takes the whole batch at once and
 * types them as a single compilation unit, so within-batch cycles
 * resolve naturally.
 *
 * **Access path.** Each synthesised type's canonical name becomes
 * `<rootPack>.trivia.Pairs.<Leaf>T` — sub-module reference through
 * the synth module. Consumers import via
 * `import anyparse.grammar.haxe.trivia.Pairs.HxModuleT;` (direct
 * short-name alias) or `import anyparse.grammar.haxe.trivia.Pairs;`
 * followed by `Pairs.HxModuleT`. The separate subpackage keeps the
 * original grammar package free of generated artefacts.
 *
 * `arm(shape)` is called from `Build.buildParser` after
 * `TriviaAnalysis.run` when `ctx.trivia` is true. Repeated calls with
 * the same `ShapeResult` are idempotent — the per-name `defined` map
 * short-circuits already-synthesised types. A future second trivia
 * grammar would get its own synth module under its own root pack.
 *
 * Three sibling `#if macro` modules carry one question each out of this
 * pass. `TriviaPairAltCtor` — what one synthesized Alt constructor looks
 * like, and which extra positional argument each branch shape earns (15
 * members). `TriviaPairSlots` — which synthesized trivia slot a struct
 * field earns, and what its declaration is (23). `TriviaPairConverters`
 * — how a paired `*T` value converts to and from its raw sibling (13).
 * What stayed is the slot-name vocabulary all three and the writer side
 * share, the atomic `defineModule` arm, and `buildTypeDefinition`, which
 * calls the first two.
 *
 * The seam is NOT a state boundary: this class declares no instance
 * field and every one of its 95 members was static, so a purity census
 * returns 100 % and decides nothing. What binds is the qualified call
 * site — `TriviaTypeSynth.<member>` is spelled 133 times outside this
 * file, 59 of those the ALL-CAPS slot-name constants. Those constants
 * stay: they are the vocabulary every consumer already knows the address
 * of, and moving them would buy no cap and cost 59 receiver rewrites.
 */
class TriviaTypeSynth {

	/**
	 * ω-issue-316 — suffixes for kw-trivia sibling slots synthesised on
	 * paired Seq types alongside `@:optional @:kw(...)` Ref fields.
	 * Exposed so `Lowering` and `WriterLowering` can reference the same
	 * names without risk of silent divergence.
	 */
	public static inline final AFTER_KW_SUFFIX: String = 'AfterKw';

	public static inline final KW_LEADING_SUFFIX: String = 'KwLeading';

	/**
	 * ω-keep-policy — two additional source-shape slots captured
	 * alongside `AfterKw` / `KwLeading` for the same `@:optional @:kw(...)`
	 * Ref fields. `BeforeKwNewline` records whether the source had a
	 * newline between the preceding token and the keyword (consumed by
	 * `sameLineSeparator`'s `Keep` branch). `BodyOnSameLine` records
	 * whether the body's first token followed the keyword on the same
	 * line (consumed by `bodyPolicyWrap`'s `Keep` branch). Both default
	 * to `false` on the commit-miss path.
	 */
	public static inline final BEFORE_KW_NEWLINE_SUFFIX: String = 'BeforeKwNewline';

	public static inline final BODY_ON_SAME_LINE_SUFFIX: String = 'BodyOnSameLine';

	/**
	 * ω-trivia-before-kw — own-line comments captured BEFORE the optional
	 * keyword commit point (e.g. `if (x) { }\n// comment\nelse { }`). The pre-commit `skipWs` collects it and stashes it here on commit-success. Empty array on the
	 * commit-miss path (rewind discards the captured trivia).
	 */
	public static inline final BEFORE_KW_LEADING_SUFFIX: String = 'BeforeKwLeading';

	/**
	 * ω-trivia-before-kw-trailing — same-line trailing comment captured
	 * BEFORE the optional keyword commit point but ON THE SAME LINE as the
	 * preceding sibling's last token (e.g. `resize(); // first\nelse`).
	 * Differs from `BeforeKwLeading` (own-line comments separated by `\n`):
	 * `BeforeKwTrailing` is a single comment on the same line as the prior
	 * `;`, captured via `collectTrailing` (single comment, no internal
	 * newline). Stripped body, line-style only by construction. Writer
	 * emits as ` //<body>` cuddled to the previous token before the
	 * pre-kw hardline. `null` on the commit-miss path or when the source
	 * has no same-line comment between the prior sibling and the keyword.
	 */
	public static inline final BEFORE_KW_TRAILING_SUFFIX: String = 'BeforeKwTrailing';

	/**
	 * ω-trivia-after-trail — same-line trailing comment captured immediately
	 * AFTER a mandatory Ref field's `@:trail(LIT)` literal (e.g.
	 * `if (cond) // afterCond\n\tbody` — the `// afterCond` cuddles to the
	 * `)`). Synthesised on Ref fields carrying `@:trail` in trivia-bearing
	 * rules. The next sibling field (typically a bodyPolicy-wrapped Ref)
	 * reads `value.<priorField>AfterTrail` and threads it into the body's
	 * leading separator so the comment survives round-trip. `null` when the
	 * source had no same-line comment after the trail literal.
	 */
	public static inline final AFTER_TRAIL_SUFFIX: String = 'AfterTrail';

	/**
	 * ω-before-trail — a BLOCK comment captured in the gap between a mandatory Ref
	 * field's last token and its own `@:trail(LIT)` literal: the `/* c *\/` in
	 * `switch (subject /* c *\/)`, `if (cond /* c *\/)`, `(expr /* c *\/)`.
	 *
	 * That gap had no slot at all, so the comment was consumed as whitespace and
	 * the writer re-emitted the construct without it — `writeRoundTrip` then
	 * refused the whole file, which is what blocked `apq fmt` and every
	 * canonicalising op on it. The writer re-emits the slot immediately before the
	 * trail literal.
	 *
	 * LINE comments are deliberately NOT captured here (`collectTrailingBlock`
	 * only attempts the format's non-line-terminated patterns): a `//` runs to the
	 * newline, so emitting one before the close literal would comment the literal
	 * out. Such a comment stays exactly as it was — skipped, and reported by the
	 * comment-loss guard.
	 */
	public static inline final BEFORE_TRAIL_SUFFIX: String = 'BeforeTrail';

	/**
	 * ω-issue-48-v2 — source-shape slot synthesised on paired Seq types
	 * alongside bare non-first Ref fields (no `@:optional`, no `@:kw`, no
	 * `@:lead`). Records whether the source had a newline in the gap
	 * between the preceding content and the sub-rule's first token.
	 * Consumed by the writer's inter-field separator so that
	 * `@:allow(...)\n\tvar x` round-trips with the newline intact even
	 * when the member's `modifiers` Star is empty — the first element of
	 * that empty Star cannot carry the `newlineBefore` signal, so the
	 * parser drains the stashed trivia here instead.
	 */
	public static inline final BEFORE_NEWLINE_SUFFIX: String = 'BeforeNewline';

	/**
	 * ω-598-member-leading-comment — sibling source-shape slot synthesised on
	 * paired Seq types alongside the same bare non-first Ref fields that grow
	 * `BeforeNewline` (`isBareNonFirstRef`). Records the verbatim comments
	 * captured in the gap between the preceding content and the sub-rule's
	 * first token — the run that `BeforeNewline`'s `collectTrivia` scans; this slot keeps its `.leadingComments` (`BeforeNewline` itself keeps only the `.newlineBefore` bool). Load-bearing for
	 * `lineends/issue_598_multiline_comment_var`: a multiline block comment
	 * between a member modifier (`public`) and the `var` keyword is rejected
	 * by the modifier Star's `collectTrailingFull` (internal newline) and
	 * lands in this gap with no slot — dropped at parse. Empty array (the
	 * common case, including the empty-modifiers path where the comment is
	 * captured upstream) is byte-inert at write time. Consumed by the
	 * writer's bare-Ref non-first inter-field separator.
	 */
	public static inline final BEFORE_LEADING_SUFFIX: String = 'BeforeLeading';

	/**
	 * ω-region-prefix-blank — third source-shape slot of the pre-field gap,
	 * synthesised only for a bare non-first Ref that opts in with
	 * `@:fmt(keepBlankAfterStarCtor(starField, ctorName))`. `BeforeNewline` says
	 * the source broke; this says it left a BLANK line. Load-bearing for a
	 * declaration whose whole prefix is a `#if X #end` region: the fork treats
	 * such a region as its own entity and keeps the blank after it
	 * (`emptylines/after_vars_before_conditionals` even MOVES a blank to that
	 * side of `#end`), while the blank after an ordinary metadata prefix is
	 * deleted (`emptylines/issue_384_macro_classes_with_metadata`) — which is
	 * why the slot is opt-in and ctor-gated rather than a third unconditional
	 * companion.
	 */
	public static inline final BEFORE_BLANK_SUFFIX: String = 'BeforeBlank';

	/**
	 * ω-cond-comp-expr-multiline — source-shape slot synthesised on
	 * paired Seq types alongside bare-Ref fields that carry
	 * `@:fmt(captureSourceNewlineAfter)`. Records whether the source
	 * had a newline immediately AFTER this field's last token (and
	 * before the next outer sibling — typically the parent ctor's
	 * `@:trail` literal).
	 *
	 * Sister to `BeforeNewline` (which captures the gap BEFORE the
	 * field's first token); together they let a bare-Ref field
	 * source-shape its own pad-trailing boundary regardless of
	 * which downstream sibling owns the visible token. Consumed by
	 * `WriterLowering.padTrailingDoc`'s `collectFollowingNewlineSignals`
	 * walker as a terminal-fallback signal (no guard) — fires only
	 * when every preceding signal in the chain falls through (all
	 * downstream optional siblings are absent).
	 *
	 * Currently consumed by `HxConditionalExpr.expr`'s `expr → '#end'`
	 * boundary when both `elseifs` is empty AND `elseExpr` is absent.
	 */
	public static inline final NEWLINE_AFTER_SUFFIX: String = 'NewlineAfter';

	/**
	 * ω-condition-wrap-keep — source-shape slot synthesised on paired Seq
	 * types alongside the mandatory-Ref condition field of a `@:fmt(condWrap)`
	 * struct (`HxIfStmt.cond` / `HxWhileStmt.cond`) that opts in via
	 * `@:fmt(captureCondOpenNewline)`. Records whether the source placed a
	 * newline right AFTER the condition's open paren `@:lead('(')` and before
	 * the cond's first token (`if (\n\tcond` vs `if (cond`). Read by the
	 * single-Ref condWrap emit in `WriterLowering`, which threads it into
	 * `WrapList.emitCondition`'s `sourceOpenNewline` arg so a `WrapMode.Keep`
	 * condition reproduces the author's post-`(` break verbatim.
	 *
	 * Sister to `NewlineAfter` (which captures the gap AFTER a bare-Ref
	 * field's last token); this captures the gap AFTER the field's lead
	 * literal. Plain mode keeps the original struct shape (no slot); the
	 * writer falls back to the width-driven glue.
	 */
	public static inline final CONDITION_OPEN_NEWLINE_SUFFIX: String = 'CondOpenNewline';

	/**
	 * ω-orphan-trivia — suffixes for trailing-trivia sibling slots
	 * synthesised on paired Seq types alongside `@:trivia` Star fields.
	 * `TrailingLeading` carries the own-line comments captured AFTER
	 * the last element and BEFORE the close (or EOF); `TrailingBlankBefore`
	 * records whether the captured run crossed a blank line so the writer
	 * can reproduce the source's vertical separation between the final
	 * member and the orphan comments.
	 */
	public static inline final TRAILING_BLANK_BEFORE_SUFFIX: String = 'TrailingBlankBefore';

	public static inline final TRAILING_LEADING_SUFFIX: String = 'TrailingLeading';

	/**
	 * ω-keep-fnsig-newline — suffix for a `Bool` flag recording whether the
	 * source placed at least one newline between the last `@:trivia` Star
	 * element and the close literal (`param7:Int\n)` vs `param7:Int)`).
	 * Sibling of `TrailingBlankBefore` (which records a BLANK line — 2+
	 * newlines), captured from the same terminal `_lead.newlineBefore` at the
	 * Star's close-peek. Consumed ONLY by `triviaSepStarExpr`'s `_keepEmit`
	 * close-placement: under a kept function signature, the close `)` breaks
	 * onto its own line iff the author put a newline there, so a kept
	 * signature round-trips both `param7:Int)` (glued — e.g.
	 * `wrapping_of_function_signature_keep`) and `\n\t):FastMatrix3` (own line
	 * — e.g. `issue_238_keep_wrapping_function_signature`). Synthesised
	 * unconditionally alongside `TrailingBlankBefore` so the slot arity stays
	 * in lockstep (struct field, name-matched — no positional ctor risk).
	 * Default `false` (no newline before close) for every non-keep / non-
	 * bearing consumer — byte-inert.
	 */
	public static inline final TRAILING_NEWLINE_BEFORE_SUFFIX: String = 'TrailingNewlineBefore';

	/**
	 * ω-close-trailing — suffix for the same-line trailing comment
	 * captured immediately after a `@:trivia` Star's close literal.
	 * Synthesised only for close-peek Stars (those with `@:trail`);
	 * EOF-mode Stars have no close to trail, and `@:trivia + @:tryparse`
	 * already rejects `@:trail` at compile time. `Null<String>` — `null`
	 * when the source had no same-line comment after the close.
	 */
	public static inline final TRAILING_CLOSE_SUFFIX: String = 'TrailingClose';

	/**
	 * ω-open-trailing — suffix for the same-line trailing comment
	 * captured immediately after a `@:trivia` Star's open literal
	 * (e.g. `{ // foo` before the first element). Mirror of
	 * `TrailingClose`. Synthesised only for Stars that carry `@:lead`
	 * (the open delimiter); bare Stars have no open lit to trail.
	 * `Null<String>` — `null` when the source had no same-line comment
	 * after the open. Captured via `collectTrailing` so the body has its
	 * delimiters stripped (line-style only, by construction — internal
	 * newline disqualifies the match).
	 */
	public static inline final TRAILING_OPEN_SUFFIX: String = 'TrailingOpen';

	/**
	 * ω-trail-blank-after — suffix for a `Bool` flag recording whether
	 * the source had a blank line between an orphan trail comment and the
	 * next outer-Star sibling (e.g. `case A: // X\n\n case B:`). Set by
	 * the tryparse+nestBody catch path when the failed-element trivia
	 * carried `blankAfterLeadingComments`; consumed by
	 * `triviaTryparseStarExpr` to emit an extra hardline after the trail
	 * Doc so the blank survives round-trip. Synthesised only for Stars
	 * that combine `@:tryparse` with `@:fmt(nestBody)` — currently
	 * `HxCaseBranch.body` and `HxDefaultBranch.stmts`. Other tryparse
	 * shapes either rewind on failure (no trail capture path) or have no
	 * nestBody wrap (no body-vs-parent indent distinction).
	 */
	public static inline final TRAILING_BLANK_AFTER_SUFFIX: String = 'TrailingBlankAfter';

	/**
	 * ω-objectlit-source-trail-comma — suffix for a `Bool` slot recording
	 * whether the source had a separator (e.g. trailing `,`) after the
	 * last element of a `@:trivia` sep-Star with a close literal. Set by
	 * the parser's per-iteration `matchLit(sepText)` capture; consumed by
	 * the writer's `WrapList.emit` call as a `forceExceeds` flag so that
	 * source-trailing-comma + an opt-in `@:fmt(trailingComma(...))` knob
	 * forces the wrap cascade into break-mode (typically `OnePerLine`),
	 * round-tripping the source's "I want this list multi-line" intent.
	 * First consumer: `HxObjectLit.fields`.
	 *
	 * Dual consumer (`buildStructFieldTrailPresentSlot`): struct typedef Ref fields with `@:trailOpt(LIT)` reuse the same suffix on an `@:optional Null<Bool>` slot. Both consumers encode "trail literal was present in source"; disjoint host kinds (Star vs Ref) within one Seq cannot collide on field name. The writer does not yet read the struct-field slot — see `isStructFieldTrailOpt`.
	 */
	public static inline final TRAIL_PRESENT_SUFFIX: String = 'TrailPresent';

	/**
	 * ω-condcomp-body-leading-sep — suffix for a `Bool` slot recording
	 * whether the source had a leading separator INSIDE a `@:sep+@:tryparse`
	 * (no-trail) Star body, between the enclosing keyword and the first
	 * body element. Set by `Lowering.emitStarFieldSteps`'s pre-loop
	 * sep-peek; consumed by `WriterLowering.emitWriterStarField`'s
	 * padLeading branch as a runtime gate that swaps the leading-pad
	 * `_dt(' ')` for `_dt(', ')`. Synthesised only for Stars opting in via
	 * `@:fmt(sepBeforeOpt)` (which additionally REQUIRES `@:fmt(padLeading)`
	 * and a `@:sep + @:tryparse` no-trail shape); other Stars skip the
	 * slot. First consumer: `HxConditionalParam.body` (`whitespace/issue_582_type_hints_conditionals`).
	 *
	 * Limitation: an empty body (`#if X, #end`) drops the leading sep at
	 * write time because the padLeading branch's empty-array short-circuit
	 * returns `_de()` before any push runs. No corpus fixture exercises
	 * the empty-body-with-leading-sep shape; rejected by parser-side rewind
	 * as well (the body Star's first iter would have to fail on `#end`
	 * AFTER the leading sep was consumed — rare and harmless).
	 */
	public static inline final SEP_BEFORE_SUFFIX: String = 'SepBefore';

	/**
	 * ω-trailopt-source-track — positional arg name appended to paired
	 * Alt ctors that carry `@:trailOpt(...)`. The parser's `matchLit`
	 * result lands here so the writer can gate trail emission on source
	 * presence (`true` → emit literal; `false` → omit). Plain mode keeps
	 * the original ctor arity and falls back to AST-shape gates such as
	 * `@:fmt(trailOptShapeGate(...))`. First consumers: `HxDeclT.TypedefDecl`
	 * and `HxDeclT.VarDecl` (top-level) plus `HxStatementT.VarStmt` /
	 * `FinalStmt` (function-body locals).
	 */
	public static inline final TRAIL_PRESENT_ARG_NAME: String = 'trailPresent';

	/**
	 * ω-string-interp-noformat — positional arg name appended to paired
	 * Alt ctors that carry `@:fmt(captureSource)`. The parser captures the
	 * input slice between the ctor's `@:lead` and `@:trail` literals here
	 * so the writer can emit it verbatim under
	 * `opt.formatStringInterpolation == false`. First (and currently only)
	 * consumer: `HxStringSegmentT.Block` for `${expr}` interpolation.
	 */
	public static inline final SOURCE_TEXT_ARG_NAME: String = 'sourceText';

	/**
	 * ω-issue-257-firstline — positional arg name appended to paired Alt
	 * ctors carrying `@:fmt(bodyPolicy(...))` on a single-Ref kw-led
	 * branch (e.g. `HxStatementT.ReturnStmt`). The parser captures
	 * whether the body's first token followed the keyword on the same
	 * source line so `bodyPolicyWrap`'s `Keep` branch can pick between
	 * `sameLayoutExpr` and `nextLayoutExpr` at writer time — the ctor-
	 * level mirror of the struct-field `<field>BodyOnSameLine` slot.
	 * Plain mode keeps the original ctor arity (no slot, default Same
	 * layout via `widthAware`). First consumer: `HxStatementT.ReturnStmt`.
	 */
	public static inline final BODY_ON_SAME_LINE_ARG_NAME: String = 'bodyOnSameLine';

	/**
	 * ω-paren-wrap-source-newline — positional arg name appended to paired
	 * Alt ctors carrying `@:fmt(captureWrapOpenNewline)` on a `@:wrap(...)`
	 * (no kw, has lead+trail) single-Ref branch. The parser captures
	 * whether the source had a newline in the gap between the open
	 * delimiter (`@:lead`) and the inner sub-rule's first token — i.e.
	 * source author wrote `(\n\tinner)` (newline) vs `(inner)` (tight).
	 * The writer threads the flag into the wrap shape so a chain inner
	 * rendered as OnePerLine round-trips the source-author distinction
	 * between `((items[0]\n\titems[1]\n))` (no leading newline → glued)
	 * and `(\n\titems[0]\n\titems[1]\n)` (open broken → first item on
	 * its own line). Without the slot the writer can only emit one of
	 * the two shapes uniformly. Plain mode keeps the original ctor arity
	 * and the writer falls back to the always-glue shape from
	 * `OptHardlineSkipAtOpenDelim`. First consumer: `HxExpr.ParenExpr`.
	 */
	public static inline final WRAP_OPEN_NEWLINE_ARG_NAME: String = 'wrapOpenNewline';

	/**
	 * ω-keep-kw-newline (increment 1b) — positional arg name appended to
	 * paired Alt ctors carrying `@:fmt(captureKwNewline)` on the mandatory-
	 * `@:kw` VarStmt-family enum ctors (`VarStmt` / `FinalStmt` /
	 * `StaticVarStmt` / `StaticFinalStmt`). The parser captures whether the
	 * source had a newline between the LAST keyword / lead literal
	 * (`var` / `final`) and the inner `decl` Ref's first token — i.e. the
	 * author wrote `var\n\trawRead` (newline) vs `var rawRead` (same line).
	 * The writer threads the flag into the `HxVarDecl` multiVar fold's
	 * `WrapMode.Keep` head break (`_breaks[0]`) so a kept multi-var decl
	 * round-trips the source-author `var`→head newline. Plain mode keeps
	 * the original ctor arity (no slot; head always glued to `var `).
	 * Sister to `bodyOnSameLine` / `wrapOpenNewline` — same parser-capture-
	 * onto-synth-arg channel, but on the mandatory-kw enum-ctor path rather
	 * than the optional-kw Ref path.
	 */
	public static inline final KW_NEWLINE_ARG_NAME: String = 'kwNewline';

	/**
	 * ω-keep-chain (increment 2) — positional arg name appended to paired
	 * infix enum ctors carrying `@:fmt(captureChainNewline)` (the Pratt
	 * binary-chain ctors `HxExpr.Add` / `Sub` / `And` / `Or`). The parser
	 * captures, at the `lowerPrattLoop` operator-match site, whether the
	 * source had a newline anywhere in the gap before this ctor's RIGHT
	 * operand (covering both `a\n&& b` and `a +\n b` shapes). The writer's
	 * chain `_gather` reads it into a `_breaks` array parallel to `_ops`
	 * and threads it to `BinaryChainEmit.emit(..., sourceBreakBefore)` so a
	 * `WrapMode.Keep` chain round-trips the source per-operator line breaks.
	 * Plain mode keeps the original 2-operand ctor arity (no slot; chain
	 * always glues via `shapeNoWrap`). Sister to `kwNewline` — same parser-
	 * capture-onto-synth-arg channel, but on the Pratt/infix enum-ctor path.
	 */
	public static inline final CHAIN_NEWLINE_ARG_NAME: String = 'chainNewline';

	/**
	 * ω-postfix-op-space — positional arg name appended to a word-op
	 * postfix ctor carrying `@:fmt(capturePostfixOpSpace)`
	 * (`HxExpr.CondSpliceTail`). Holds whether the source had whitespace
	 * between the operand and the operator (`f() #if …` vs `f()#if …`)
	 * so the writer re-emits the gap source-faithfully instead of always
	 * space-padding the word operator's left side.
	 */
	public static inline final POSTFIX_OP_SPACE_ARG_NAME: String = 'opSpaceBefore';

	/**
	 * ω-keep-chain-receiver-comment — positional arg name appended to the
	 * `@:postfix('.')` method-chain ctor `HxExpr.FieldAccess` (alongside its
	 * `chainNewline:Bool` slot). Holds the verbatim same-line trailing comment
	 * captured by the parser in the gap BEFORE the `.` dispatch — i.e. the
	 * trailing comment of the FieldAccess's operand. For a chain whose receiver
	 * is a bare value (`owner // test\n\t.addEntity()…`) the inner-most
	 * FieldAccess's operand IS that receiver, so this slot carries the
	 * receiver's trailing comment; the chain dispatch threads it onto the
	 * receiver Doc under `WrapMode.Keep` so the comment survives the per-segment
	 * break. Null for operands whose trailing comment is already captured
	 * elsewhere — a Call operand's `)`-trailing comment is held by the Call's
	 * `closeTrailing` slot, so `collectTrailingFull` finds nothing left at the
	 * dot gap and this slot stays null (byte-inert). Postfix-only (the infix
	 * chain ctors capture operand trivia through the Pratt stash, not here).
	 * Plain mode keeps the original 2-arg FieldAccess ctor (no slot).
	 */
	public static inline final CHAIN_LEAD_COMMENT_ARG_NAME: String = 'chainLeadComment';

	public static inline final OP_AFTER_COMMENT_ARG_NAME: String = 'opAfterComment';
	public static inline final OP_RHS_TRAIL_COMMENT_ARG_NAME: String = 'opRhsTrailComment';

	/**
	 * ω-keep-ternary-operand-comment — positional arg names appended to a
	 * `@:ternary` ctor carrying `@:fmt(captureTernaryTrail)`
	 * (`HxExpr.Ternary`). `condTrailComment` holds the verbatim same-line
	 * comment trailing the CONDITION (`a // c` before `?`), `thenTrailComment`
	 * the one trailing the THEN branch (`? b // c` before `:`). Both null when
	 * the source had no such comment.
	 */
	public static inline final TERNARY_COND_TRAIL_ARG_NAME: String = 'condTrailComment';

	public static inline final TERNARY_THEN_TRAIL_ARG_NAME: String = 'thenTrailComment';

	private static inline final PAIRED_SUFFIX: String = 'T';
	private static inline final SYNTH_SUBPACK: String = 'trivia';
	private static inline final SYNTH_MODULE_LEAF: String = 'Pairs';
	private static final shapes: Array<ShapeBuilder.ShapeResult> = [];
	private static final defined: Map<String, Bool> = [];

	private static var convertersAdded: Bool = false;

	public static function arm(shape: ShapeBuilder.ShapeResult): Void {
		if (shapes.indexOf(shape) == -1) shapes.push(shape);
		final rootPack: Array<String> = packOf(shape.root);
		final synthPack: Array<String> = rootPack.concat([SYNTH_SUBPACK]);
		final modulePath: String = synthPack.concat([SYNTH_MODULE_LEAF]).join('.');
		final paired: Array<TypeDefinition> = [];
		final convertedNames: Array<String> = [];
		for (origName => node in shape.rules) if (node.annotations.get(AnnotationKeys.TRIVIA_BEARING) == true) {
			final pairedFqn: String = origName + PAIRED_SUFFIX;
			if (defined.exists(pairedFqn)) continue;
			defined[pairedFqn] = true;
			paired.push(buildTypeDefinition(origName, node, synthPack));
			convertedNames.push(origName);
		}
		if (paired.length == 0) return;
		// ω-paired-converters (Phase A1): emit a single `Converters` class
		// in the same synth module carrying static `pairedToRaw_<T>` /
		// `rawToPaired_<T>` helpers for every paired type. The engine
		// (`WriterLowering.wrapWithPreWrite`) routes preWrite plugins
		// through these helpers in trivia mode, so plugin sigs stay raw
		// (`(<T>, WriteOptions) -> Null<<T>>`) regardless of trivia
		// propagation. One Converters class per `Context.defineModule`
		// batch — additional `arm()` calls for the same module batch
		// must not re-emit (Haxe rejects duplicate type defs); the
		// `convertersAdded` flag guards repeat invocations.
		if (!convertersAdded) {
			convertersAdded = true;
			paired.push(TriviaPairConverters.buildConvertersClass(convertedNames, synthPack));
		}
		Context.defineModule(modulePath, paired);
		#if anyparse_trivia_dump
		for (td in paired) Sys.println('// trivia.synth: defined ${td.pack.join('.')}.${td.name} in module $modulePath');
		#end
	}

	private static function buildTypeDefinition(origName: String, origNode: ShapeNode, synthPack: Array<String>): TypeDefinition {
		final pairedSimple: String = leafOf(origName) + PAIRED_SUFFIX;
		final pos: Position = Context.currentPos();
		return switch origNode.kind {
			case Seq:
				final fields: Array<Field> = [];
				for (child in origNode.children) {
					fields.push(TriviaPairSlots.buildStructField(child, pos, synthPack));
					// ω-issue-316: `@:optional @:kw(...)` Ref fields grow two
					// sibling trivia slots — a same-line trailing comment
					// captured right after the kw (`AfterKw`), and own-line
					// comments captured between kw and body (`KwLeading`).
					// Writer consumes these to preserve source layout; absent
					// consumers read `null` / `[]` with no harm.
					if (TriviaPairSlots.isOptionalKw(child)) for (extra in TriviaPairSlots.buildKwTriviaSlots(child, pos))
						fields.push(extra);
					// ω-orphan-trivia: `@:trivia` Star fields grow two
					// sibling slots capturing trailing trivia (own-line
					// comments between the last element and the close /
					// EOF). Without them a class body like `{ /* orphan */ }`
					// would lose its comment at parse time.
					if (TriviaPairSlots.isTriviaStarField(child)) for (extra in TriviaPairSlots.buildStarTrailingSlots(child, pos))
						fields.push(extra);
					// ω-condcomp-body-leading-sep: independent of @:trivia.
					// Add a `<field>SepBefore:Bool` slot for Stars opting into
					// `@:fmt(sepBeforeOpt)`. First consumer is
					// `HxConditionalParam.body`, which is a NON-trivia Star —
					// the slot synthesis must not be gated on `isTriviaStarField`.
					if (TriviaPairSlots.isSepBeforeOptStarField(child)) {
						final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
						final fieldName: String = child.annotations.get(AnnotationKeys.BASE_FIELD_NAME);
						fields.push({
							name: fieldName + SEP_BEFORE_SUFFIX,
							kind: FVar(boolCT),
							pos: pos,
							access: []
						});
					}
					// ω-issue-48-v2: bare non-first Ref fields grow a
					// `BeforeNewline:Bool` slot capturing whether the source
					// had a newline in the gap between the preceding content
					// and the sub-rule's first token. Consumed by the
					// writer's inter-field separator.
					if (TriviaPairSlots.isBareNonFirstRef(child, origNode) || TriviaPairSlots.isBareFirstStarNlOptIn(child, origNode))
						fields.push(TriviaPairSlots.buildBeforeNewlineSlot(child, pos));
					// ω-598-member-leading-comment: only the bare non-first Ref
					// host (e.g. `HxMemberDecl.member`) grows the leading-comment
					// companion — its `BeforeNewline` `collectTrivia` scan owns
					// the pre-field gap. The Star-opt-in host reads a different
					// parser local, so it keeps `BeforeNewline` only.
					if (TriviaPairSlots.isBareNonFirstRef(child, origNode)) fields.push(TriviaPairSlots.buildBeforeLeadingSlot(child, pos));
					// ω-region-prefix-blank: the third slot of the same gap — whether the
					// source put a BLANK line there, not merely a newline. Opt-in
					// (`@:fmt(keepBlankAfterStarCtor(...))`), because for the ordinary
					// metadata prefix the fork DELETES the blank
					// (`emptylines/issue_384_macro_classes_with_metadata`: `@Test\n\n\tfunction
					// foobar()` → `@Test\n\tfunction foobar()`), and only a `#if … #end`
					// region in that position keeps it.
					if (TriviaPairSlots.isBeforeBlankRef(child, origNode)) fields.push(TriviaPairSlots.buildBeforeBlankSlot(child, pos));
					// ω-trivia-after-trail: any mandatory Ref field with
					// `@:trail` grows a `<field>AfterTrail:Null<String>` slot
					// holding a same-line `// comment` captured right after
					// the trail literal. Currently consumed by the next
					// sibling's `bodyPolicyWrap` (HxIfStmt's `cond` →
					// `thenBody`); other Ref+trail fields without a
					// bodyPolicy sibling synthesise the slot harmlessly and
					// can opt in later.
					if (TriviaPairSlots.isTrailRef(child)) fields.push(TriviaPairSlots.buildAfterTrailSlot(child, pos));
					// ω-before-trail: the twin slot on the OTHER side of the same
					// literal — a block comment sitting between the field's last
					// token and its `@:trail` close. See BEFORE_TRAIL_SUFFIX.
					if (TriviaPairSlots.isBeforeTrailRef(child)) fields.push(TriviaPairSlots.buildBeforeTrailSlot(child, pos));
					// ω-cond-comp-expr-multiline: bare Ref fields opted in via
					// `@:fmt(captureSourceNewlineAfter)` grow a `NewlineAfter:Bool`
					// slot capturing whether the source had a newline AFTER
					// this field's last token. Read by the writer's
					// `padTrailingDoc` terminal-fallback signal when no
					// downstream sibling carries a slot (e.g.
					// `HxConditionalExpr.expr → '#end'` when both `elseifs`
					// and `elseExpr` are absent).
					if (TriviaPairSlots.isPadTrailingTerminalRef(child)) fields.push(TriviaPairSlots.buildNewlineAfterSlot(child, pos));
					// ω-condition-wrap-keep: the mandatory-Ref condition field
					// of a `@:fmt(condWrap)` struct opted in via
					// `@:fmt(captureCondOpenNewline)` grows a `CondOpenNewline:Bool`
					// slot capturing whether the source broke right after the
					// condition's open paren (`if (\n\tcond`). Read by the
					// single-Ref condWrap emit so a `WrapMode.Keep` condition
					// reproduces the author's post-`(` break.
					if (TriviaPairSlots.isCondOpenNewlineRef(child)) fields.push(TriviaPairSlots.buildCondOpenNewlineSlot(child, pos));
					// ω-struct-trailopt-source-track:
					// struct typedef fields carrying `@:trailOpt(LIT)` grow an
					// `@:optional` `<field>TrailPresent:Null<Bool>` slot. The
					// `@:optional` + `Null<>` shape keeps the slot additive —
					// paired-struct literals in `Lowering` that omit the slot
					// leave it `null` at runtime, semantically "no source
					// info". The parser captures the `matchLit` result; the
					// writer-side gate (trail re-emission on source presence)
					// is not wired yet, so the captured value is currently
					// unobserved (see `isStructFieldTrailOpt`).
					//
					// Sister to `buildStarTrailingSlots`'s `<field>TrailPresent`
					// for Star `@:sep+@:trail` (same suffix constant — both
					// encode "trail literal was present in source"; disjoint
					// host context, no name collision possible within one Seq).
					//
					// Beneficiary fixtures: `wrapping/
					// issue_366_nested_array_comprehension` (nested `;` preserved),
					// `whitespace/issue_195`/`221` (do-while bare-body
					// form).
					if (TriviaPairAltCtor.isStructFieldTrailOpt(child))
						fields.push(TriviaPairSlots.buildStructFieldTrailPresentSlot(child, pos));
				}
				final anon: ComplexType = TAnonymous(fields);
				{
					pos: pos,
					pack: synthPack,
					name: pairedSimple,
					kind: TDAlias(anon),
					fields: []
				};
			case Alt:
				final fields: Array<Field> = [
					for (branch in origNode.children) TriviaPairAltCtor.buildEnumCtor(branch, pos, synthPack)
				];
				{
					pos: pos,
					pack: synthPack,
					name: pairedSimple,
					kind: TDEnum,
					fields: fields
				};
			case _:
				Context.fatalError('TriviaTypeSynth: unsupported bearing kind ${origNode.kind} for $origName', pos);
				throw 'unreachable';
		};
	}

	private static function shapeToComplexType(node: ShapeNode, synthPack: Array<String>): ComplexType {
		return switch node.kind {
			case Ref:
				final refName: String = node.annotations[AnnotationKeys.BASE_REF];
				final base: ComplexType = refIsBearing(refName)
					? TPath({ pack: synthPack, name: leafOf(refName) + PAIRED_SUFFIX, params: [] })
					: TPath({ pack: packOf(refName), name: leafOf(refName), params: [] });
				return TriviaPairSlots.wrapOptional(node, base);
			case Star:
				final elementCT: ComplexType = shapeToComplexType(node.children[0], synthPack);
				final wrapped: ComplexType = node.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true
					? TPath({ pack: ['anyparse', 'runtime'], name: 'Trivial', params: [TPType(elementCT)] })
					: elementCT;
				return TriviaPairSlots.wrapOptional(node, TPath({ pack: [], name: 'Array', params: [TPType(wrapped)] }));
			case Terminal:
				final tp: Null<String> = node.annotations[AnnotationKeys.BASE_TYPE_PATH];
				if (tp != null) return TriviaPairSlots.wrapOptional(node, TPath({ pack: packOf(tp), name: leafOf(tp), params: [] }));
				final under: String = node.annotations['base.underlying'];
				return TriviaPairSlots.wrapOptional(node, TPath({ pack: [], name: under, params: [] }));
			case _:
				Context.fatalError('TriviaTypeSynth: unexpected node kind ${node.kind} in field-shape', Context.currentPos());
				throw 'unreachable';
		};
	}

	private static function refIsBearing(refName: String): Bool {
		for (shape in shapes) {
			final node: Null<ShapeNode> = shape.rules.get(refName);
			if (node != null) return node.annotations.get(AnnotationKeys.TRIVIA_BEARING) == true;
		}
		return false;
	}

	private static function leafOf(qualifiedName: String): String {
		final idx: Int = qualifiedName.lastIndexOf('.');
		return idx == -1 ? qualifiedName : qualifiedName.substring(idx + 1);
	}

}
#end
