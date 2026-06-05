package anyparse.core;

/**
 * Pretty-printer document IR.
 *
 * A `Doc` represents a structured document that the `Renderer` lays out
 * within a target line width. The renderer decides for each `Group` whether
 * to emit it flat (all `Line` nodes become their flat replacement) or broken
 * (all `Line` nodes become real newlines with indentation).
 *
 * Based on Wadler's "A prettier printer" with adjustments for strict
 * evaluation and Haxe ergonomics.
 *
 * Primitives:
 *
 * - `Empty`          — nothing.
 * - `Text(s)`        — literal string without line breaks.
 * - `Line(flat)`     — a potential line break. In flat mode it becomes `flat`
 *                      (usually `" "` or `""`); in break mode it becomes a
 *                      newline followed by the current indent.
 * - `Nest(n, inner)` — increases the current indent by `n` for breaks inside
 *                      `inner`.
 * - `Group(inner)`   — a unit of fit decision. The renderer measures the flat
 *                      width of `inner` and commits to flat if it fits within
 *                      the remaining width, otherwise to break.
 * - `BodyGroup(inner)` — body-level fit decision. Renderer treats
 *                      `BodyGroup` identically to `Group` for its own
 *                      flat/break choice. `fitsFlat` differs: when
 *                      measuring an outer Group that contains a
 *                      `BodyGroup`, the BG is DEFERRED — its content does
 *                      not contribute to the parent's measurement. The
 *                      parent therefore stays inline even when the inner
 *                      BG would break, which is what lets a multi-line
 *                      block body sit inside a call argument without
 *                      forcing the call's `(...)` onto separate lines,
 *                      and what lets chained FitLines keep the outer body
 *                      inline while the inner body breaks. The trivia
 *                      writer's trailing-comment folder looks specifically
 *                      for `BodyGroup` when splicing a trailing line
 *                      comment.
 * - `Concat(items)`  — sequential concatenation.
 * - `IfBreak(br, fl)`— emit `br` if the enclosing Group is in break mode,
 *                      `fl` if in flat mode. Used for trailing separators
 *                      that should appear only when the list breaks.
 * - `IfWidthExceeds(n, br, fl)` — column-aware sibling of `IfBreak`. At
 *                      render time, the renderer probes whether the
 *                      current column plus `flatWidth(fl)` reaches `n`.
 *                      If yes → emit `br`; else → `fl`. Independent of
 *                      the surrounding Group's flat/break mode. Used by
 *                      `WrapList.emit` to honour `LineLengthLargerThan`
 *                      cascade conditions whose threshold differs from
 *                      `WriteOptions.lineWidth` (the standard `IfBreak`
 *                      pivot) — e.g. opBool's `lineLength >= 140` when
 *                      `maxLineLength = 160`. For threshold equal to
 *                      `lineWidth`, prefer `IfBreak` (cheaper, no per-
 *                      primitive column probe). `fitsFlat` (used by
 *                      enclosing `Group` measurement) forwards to `fl`
 *                      so flat-mode width estimation stays stable
 *                      regardless of the column-aware decision.
 * - `IfFirstLineExceeds(n, br, fl)` — first-line-aware sibling of
 *                      `IfWidthExceeds`. Probes `col + firstLineWidth(fl)`
 *                      against `n` instead of total flat width: forced
 *                      hardlines inside `fl` cap the measurement at the
 *                      first line rather than collapsing to zero. Used
 *                      when the layout decision depends on whether the
 *                      first rendered line of a multi-line subtree
 *                      overflows — e.g. `return <multi-line if-expr>`
 *                      wants the if-expr's HEAD inline with `return`
 *                      when the head fits, even though subsequent
 *                      branches break. The full-width sibling
 *                      `IfWidthExceeds` answers "would the whole flat
 *                      subtree fit", which over-fires for multi-line
 *                      bodies; this sibling answers "would the first
 *                      rendered line fit", matching haxe-formatter's
 *                      `sameLine.returnBody: same` semantics. Group's
 *                      `fitsFlat` forwards to `fl` (same as
 *                      `IfWidthExceeds`) so chain consumers' cascade
 *                      semantic stays unchanged.
 * - `IfLineExceeds(n, br, fl)` — line-length-aware sibling of
 *                      `IfWidthExceeds`. Probes `col +
 *                      flatTokenWidth(fl) + flatTokenWidthOfRestStack`
 *                      against `n` — extends the column-aware probe with
 *                      a lookahead over the rest of the rendering stack
 *                      up to the next forced hardline. Answers "would
 *                      the rendered current line, including everything
 *                      after this primitive on the same source line,
 *                      reach `n` columns?". Closes the architectural
 *                      blindspot where a chain `Group(IfBreak)` sees only
 *                      its own subtree and picks flat even though the
 *                      enclosing assign/binop expression would push the
 *                      line past `lineWidth`. Independent of the
 *                      enclosing Group's flat/break mode (mirrors
 *                      `IfWidthExceeds`); `fitsFlat` forwards to `fl`.
 *                      `BodyGroup` is DEFERRED in both walks
 *                      (Departure 2) — body content does not contribute.
 *                      Slice ω-iflineexceeds-infra introduces this
 *                      primitive; consumers wire in via subsequent
 *                      slices that need line-aware probes outside the
 *                      wrap-engine cascade machinery.
 * - `IfFullLineExceeds(n, br, fl)` — sibling of `IfLineExceeds` with
 *                      an asymmetric `BodyGroup` semantic:
 *                      `flatTokenWidth(fl)` (the primitive's own subtree
 *                      width) DEFERS `BodyGroup` so a lambda body BG
 *                      INSIDE one of `fl`'s segments stays measured by
 *                      its header only — chain probes don't over-fire
 *                      when a chain segment contains a multi-line
 *                      lambda body; while the rest-of-stack lookahead
 *                      `flatTokenWidthOfRestStackFull(stack)` DESCENDS
 *                      `BodyGroup` so a sibling body that follows
 *                      AFTER this primitive on the same source line
 *                      (e.g. the `for (cond) BODY` body wrapped in BG
 *                      by `sameLine.forBody=fitLine`) IS visible to
 *                      the probe. Closes the chain-emit blindspot
 *                      where `Group(IfBreak)` at the chain level sees
 *                      only the chain's own subtree, missing trailing
 *                      tokens past close-paren including inline body
 *                      content in a sibling `BodyGroup`. Used by
 *                      `MethodChainEmit`. Independent of the enclosing
 *                      Group's flat/break mode (mirrors
 *                      `IfLineExceeds`); `fitsFlat` and cascade-rule
 *                      static walks forward to `fl`. Slice
 *                      ω-iffulllineexceeds-primitive.
 * - `IfNaturalFirstLineExceeds(n, br, fl)` — natural-shape sibling of
 *                      `IfFirstLineExceeds`. Where `IfFirstLineExceeds`
 *                      probes `col + flatTokenWidthFirstLine(fl)` — a
 *                      purely FLAT first-line walk that descends every
 *                      inner `Group`/`IfBreak`/`If*Exceeds` taking the
 *                      FLAT branch — this primitive probes
 *                      `naturalFirstLineWidth(fl, col, indent, width)`:
 *                      it renders `fl` SPECULATIVELY at the current pen,
 *                      resolving each inner Group by its OWN `fitsFlat`
 *                      decision (the real flat/break choice the renderer
 *                      would make at the running column), and measures
 *                      the width of the first PHYSICAL line — up to the
 *                      first naturally-produced hardline (a forced
 *                      `Line('\n')`, an `OptHardline*`, or a soft `Line`
 *                      reached inside a Group that `fitsFlat` chose to
 *                      break). Crosses `n` iff that natural first line
 *                      reaches `n`. This distinguishes a RHS pinned
 *                      NoWrap (keeps its full flat width → crosses →
 *                      break) from a RHS that wraps its own call-args
 *                      (short natural first line, e.g. `foo(` then a
 *                      hardline → does NOT cross → stay inline) — a
 *                      distinction the flat `IfFirstLineExceeds` cannot
 *                      make (it over-measures both). `BodyGroup` is
 *                      DEFERRED (Departure 2, same as the flat siblings).
 *                      Canonical consumer: assignment break-after-`=` on
 *                      a type-param-carrying LHS. `fitsFlat` and the
 *                      static flat walks forward to `fl`;
 *                      `startsWithHardline`/`isOPLShape` recurse `br`
 *                      (break-side leading-edge walkers, mirror the
 *                      `If*Exceeds` siblings). Slice
 *                      ω-ifnaturalfirstlineexceeds-infra.
 * - `Fill(items, sep, ?tailReserve)` — Wadler `fillSep`. In flat mode,
 *                      emits items joined by `sep` flat. In break mode,
 *                      packs items left-to-right: before each `items[i]`
 *                      (i > 0), measures `sep + items[i]` flat from the
 *                      current column; if it fits, emits `sep` flat then
 *                      the item; if it doesn't fit, emits `sep` in break
 *                      mode (so its inner `Line` becomes a hardline at
 *                      the Fill's indent) and starts the item on the
 *                      new line. Items[0] is always emitted at the
 *                      entry column. `BodyGroup` deferral applies inside
 *                      per-item flat measurements, so an item containing
 *                      a multi-line block body still measures by its
 *                      "header" width and packs cleanly with siblings.
 *                      `tailReserve` (default 0) — cols of post-Fill
 *                      same-line content (typically trailing punct +
 *                      close delim emitted OUTSIDE the Fill but on the
 *                      same line as its last packed item). Subtracted
 *                      from per-item-fit budget so the LAST packed item
 *                      leaves room for that tail; mirrors fork's
 *                      `wrapFillLine2AfterLast` accounting where each
 *                      item carries its trailing comma in `firstLineLength`.
 *                      Slice ω-fill-tail-reserve.
 * - `OptSpace(s)`    — optional inline whitespace, dropped when
 *                      immediately followed by a break-mode `Line`
 *                      (hardline). Used by lead emission to keep the
 *                      "lead literal + trailing space" pair byte-
 *                      identical when the value lays out flat, but
 *                      suppress the trailing space when the value
 *                      emits a leading hardline (e.g. `leftCurly=Next`
 *                      on an object literal). Treated as `Text(s)` for
 *                      flat-mode `fitsFlat` measurement so wrapping
 *                      decisions don't shift. Renderer holds OptSpace
 *                      in a small pending buffer; it's flushed before
 *                      any `Text` (or in-flat `Line`) and discarded
 *                      right before a break-mode `Line` writes the
 *                      newline. At end of render any unflushed
 *                      OptSpace is silently dropped (no trailing
 *                      whitespace at EOF).
 * - `OptHardline`    — optional break-mode newline, dropped when the
 *                      last emit was already a hardline (`Line('\n')`
 *                      or another `OptHardline`). Used to coordinate
 *                      between two independent emitters that each want
 *                      a leading newline at the same insertion point —
 *                      e.g. wrap-engine sep `\n` between call args
 *                      followed by the next arg's `leftCurly=Next`
 *                      leading `\n`. Without `OptHardline` the two
 *                      hardlines collide and produce `\n\n` (a
 *                      spurious blank line). Like `Line('\n')`, it
 *                      forces `fitsFlat` to refuse flatten — never
 *                      fits in flat mode. The dropped variant still
 *                      updates `pendingIndent` to the OptHardline's
 *                      own indent, so the next `Text` lands at the
 *                      more-specific (inner) position. Intentional
 *                      blank lines must use plain `Line('\n')` pairs;
 *                      OptHardline is opt-in at the producer site.
 * - `OptHardlineSkipAtOpenDelim` — break-mode newline that drops when
 *                      the last emitted byte is an open delimiter
 *                      (`(`, `[`, `{`), or a prior hardline (mirrors
 *                      `OptHardline`'s collision drop). Used by chain
 *                      shapes (`BinaryChainEmit.shapeOnePerLine`) for
 *                      the leading hardline before items[0]: keeps
 *                      the chain's first operand glued to the
 *                      enclosing open delim (`(items[0]...`) while
 *                      still emitting `\n+indent` in outer-context
 *                      cases (`dirty = chain`, `return chain`) where
 *                      the previous byte is `=` / `n` / etc. Like
 *                      `Line('\n')` and `OptHardline`, forces
 *                      `fitsFlat` to refuse flatten so the enclosing
 *                      Group commits MBreak. The dropped variant
 *                      updates `pendingIndent` to the node's own
 *                      indent so following `Text` lands at the
 *                      correct column.
 * - `OptHardlineSkipBeforeHardline` — break-mode newline that drops
 *                      when the NEXT non-OptSpace emit is itself a
 *                      hardline. Forward-looking mirror of
 *                      `OptHardline`'s drop-on-previous: the renderer
 *                      holds the emit in a `pendingHardline` slot
 *                      (sister to `pendingOptSpace`) and flushes it on
 *                      the first content-bearing emit; a hardline-like
 *                      emit arriving while pending clears it without
 *                      write. Used at `trailFollowExpr`
 *                      (close-trailing-of-Alt-branch-BlockStmt) where
 *                      the parent stmt-list Star's per-element
 *                      separator will itself emit `\n`, so the
 *                      comment-terminator hardline must drop to avoid
 *                      a spurious blank line between consecutive
 *                      `} // comment` / `<next stmt>` siblings. Forces
 *                      `fitsFlat` to refuse flatten.
 *
 * See `D` for builder helpers and `Renderer` for the layout algorithm.
 */
enum Doc {
	Empty;
	Text(s:String);
	Line(flat:String);
	Nest(indent:Int, inner:Doc);
	Group(inner:Doc);
	BodyGroup(inner:Doc);

	/**
	 * Rest-of-stack-aware `Group` variant (ω-group-rest-probe). At
	 * render time the fit decision subtracts `flatTokenWidthOfRestStack(stack)`
	 * from the budget — content trailing on the same rendered line after
	 * this Group is considered before committing to MFlat. Mirrors fork's
	 * `wrapFillLine2AfterLast` `lengthAfter` bias toward earlier wrap
	 * construct when significant content trails on the same line (e.g.
	 * typedef LHS typeParams that should wrap because RHS won't fit on
	 * the continuation).
	 *
	 * Sister to `IfLineExceeds` rest-of-stack lookahead — same walker
	 * (`flatTokenWidthOfRestStack`), different consumer: `IfLineExceeds`
	 * picks between two explicit docs based on column threshold; this
	 * primitive picks between MFlat / MBreak by fit decision.
	 *
	 * All Doc walkers (`flatTokenWidth`, `flatTokenWidthFirstLine`,
	 * `flatLength`, `hasLeadingHardline`, …) treat this primitive
	 * identically to `Group(inner)` — semantic difference is rendering-time
	 * only.
	 */
	GroupWithRestProbe(inner:Doc);
	Concat(items:Array<Doc>);
	IfBreak(breakDoc:Doc, flatDoc:Doc);
	IfWidthExceeds(n:Int, breakDoc:Doc, flatDoc:Doc);
	IfFirstLineExceeds(n:Int, breakDoc:Doc, flatDoc:Doc);
	IfLineExceeds(n:Int, breakDoc:Doc, flatDoc:Doc);
	IfFullLineExceeds(n:Int, breakDoc:Doc, flatDoc:Doc);
	IfNaturalFirstLineExceeds(n:Int, breakDoc:Doc, flatDoc:Doc);

	/**
	 * Condition-paren-glue decision (ω-cond-paren-glued, increment-4).
	 * Renders `flatDoc` (the GLUED `(cond)` shape) iff the cond's NATURAL
	 * first line both (a) fits within `n` AND (b) ENDS at an open delimiter
	 * (`(` / `[` / `{` or an arrow `->`) — meaning the inner construct (call /
	 * array / arrow lambda) leading-broke right after it, so the cond prefix
	 * stays on the open line
	 * (`if (!list.exists(\n\t…\n))`). Otherwise renders `breakDoc` (the open
	 * `(\n cond \n)` shape).
	 *
	 * Distinguishes the fork's two condition layouts at one render decision:
	 *  - inner call leading-breaks (first line ends at `(`) → keep cond glued
	 *    (`condition_wrapping_nested`, `arrow_wrapping_collapse_after_condition`);
	 *  - inner call fillLine-PACKS its first arg onto the open line, or the
	 *    cond is a bare chain whose own operator breaks (first line ends mid-
	 *    args / at an operand) → open the cond paren
	 *    (`condition_wrapping_for`, `condition_wrapping_if`).
	 *
	 * The natural-first-line semantic (each inner `Group` resolved by its own
	 * `fitsFlat` at the running column, first physical line measured) is
	 * shared with `IfNaturalFirstLineExceeds`; the added (b) end-on-open-delim
	 * test is what separates leading-break from packed inner constructs. Pure
	 * render-time decision — all static Doc walkers forward to `flatDoc`.
	 */
	IfNaturalFirstLineFitsOpenDelim(n:Int, breakDoc:Doc, flatDoc:Doc);

	/**
	 * Sole-arrow call-arg head-glue decision (ω-inc5-cont). Renders `flatDoc`
	 * (the OPEN-paren shape — `f(\n\t(params) -> body\n)`) iff the arrow's flat
	 * `(params) -> body` would FIT on one continuation line measured AT THE
	 * CONTINUATION INDENT `f.indent + extraIndent`, not the current pen column.
	 * Otherwise renders `breakDoc` (the GLUE shape — `f((params) ->\n\tbody\n)`,
	 * arrow head glued to the open paren, body broken).
	 *
	 * Distinct from every other `If*Exceeds`: the threshold is checked at the
	 * NEXT-LINE continuation column (`f.indent + extraIndent`), because the
	 * decision must be committed BEFORE the arrow head is emitted (at the open-
	 * paren column) yet the relevant width is the body's own continuation line.
	 * Mirrors fork `MarkWrapping.preferLambdaSignatureInlineOverWrap` — keep the
	 * lambda signature inline on its own continuation line when it fits, else
	 * pull the signature up onto the open-paren line and break the body. Pure
	 * render-time decision — all static Doc walkers forward to `flatDoc`.
	 *
	 * `flatWidth` is the arrow item's FLAT token width, precomputed at lowering
	 * (`DocMeasure.flatTokenWidth`) — column-independent, so no render-time
	 * measurer call is needed; the arm just checks
	 * `f.indent + extraIndent + flatWidth < n`.
	 */
	IfArrowContinuationFits(extraIndent:Int, flatWidth:Int, n:Int, breakDoc:Doc, flatDoc:Doc);
	Fill(items:Array<Doc>, sep:Doc, ?tailReserve:Int);

	/**
	 * Rest-of-stack-aware `Fill` variant (ω-fill-rest-probe). At render
	 * time the per-item-fit probe in the FillCont resumption subtracts
	 * `flatTokenWidthOfRestStack(stack)` from the budget — content
	 * trailing on the same rendered line after the Fill subtree is
	 * considered when deciding break-before-item. Mirrors fork's
	 * `wrapFillLine2AfterLast` `lengthAfter` bias at the Fill primitive
	 * layer; sister to `GroupWithRestProbe` at the Group decision layer.
	 *
	 * Used by `WrapList.shapeFillLine`'s last-chunk Fill construction
	 * when the outer Star opts in via `@:fmt(groupRestProbe)` (semantic
	 * is shared: "this Star's wrap considers rest-of-stack" at both
	 * Group and Fill decision layers). Earlier chunks are followed by a
	 * forced `,\n` chunk boundary, so their last-item-fit decision can't
	 * push the tail off the line — rest-probe is irrelevant there.
	 *
	 * All Doc walkers (`flatTokenWidth`, `flatTokenWidthFirstLine`,
	 * `flatLength`, `hasLeadingHardline`, …) treat this primitive
	 * identically to `Fill(items, sep, tailReserve)` — semantic
	 * difference is rendering-time only.
	 */
	FillWithRestProbe(items:Array<Doc>, sep:Doc, ?tailReserve:Int);
	OptSpace(s:String);
	OptHardline;
	OptHardlineSkipAtOpenDelim;

	/**
	 * Break-mode newline that drops when the **next** non-OptSpace emit
	 * is itself a hardline (`Line('\n')`, `OptHardline`,
	 * `OptHardlineSkipAtOpenDelim`, or another `OptHardlineSkipBeforeHardline`).
	 * Forward-looking mirror of `OptHardline`'s drop-on-state: where
	 * `OptHardline` drops when the PREVIOUS emit was a hardline, this
	 * primitive drops when the FOLLOWING emit will be a hardline. The
	 * renderer holds the emit in a small `pendingHardline` slot (sister
	 * to `pendingOptSpace`) and flushes it on the first content-bearing
	 * emit (`Text`, in-flat `Line(flat)`, or a flushed `OptSpace*`); a
	 * hardline-like emit arriving while pending clears it without write.
	 *
	 * Used at the `trailFollowExpr` close-trailing-of-Alt-branch-BlockStmt
	 * site (`WriterLowering.hx:5727`): a line-comment trailing the
	 * BlockStmt's close brace (`} // comment`) needs an emitter-side `\n`
	 * to terminate the comment line, BUT when the enclosing Star's
	 * per-element separator already emits a hardline for the next
	 * sibling, the two hardlines collide and produce a spurious blank
	 * line. With `_dohsbh`, our hardline drops when followed by the
	 * sep's hardline (sibling stmt boundary), but still fires when
	 * followed by content (sameLineCatch's `OptSpaceSkipAfterHardline`
	 * arrives after pending → flush emits `\n+indent`, then the
	 * lastEmit=Hardline drop fires inside OSSAH → catch lands on the
	 * next line at the correct indent).
	 *
	 * Like `Line('\n')`, `OptHardline`, and `OptHardlineSkipAtOpenDelim`,
	 * forces `fitsFlat` to refuse flatten — any enclosing Group containing
	 * this primitive commits to `MBreak`. Inside `Flatten(...)` force-flat
	 * region, drops entirely (mirror of `OptHardline`'s force-flat arm).
	 * Doc walkers (`flatTokenWidth`, `flatTokenWidthFirstLine`,
	 * `flatTokenWidthOfRestStack`, `flatLength`, `hasLeadingHardline`,
	 * …) treat this primitive identically to `OptHardline` — semantic
	 * difference is rendering-time only.
	 */
	OptHardlineSkipBeforeHardline;

	/**
	 * Inline single space that drops when the last emitted output was
	 * a hardline. Mirror of `OptHardlineSkipAtOpenDelim`'s drop-on-state
	 * pattern but for the trailing-side: emit `' '` to keep tokens
	 * separated when the previous emit ended on the same line, drop
	 * silently when the previous emit ended with `\n+indent` (no
	 * spurious `<indent> #else` after a closing-brace's hardline).
	 *
	 * Used by `WriterLowering.sameLineSeparator` as the default
	 * inter-field gap on optional-kw fields whose preceding sibling
	 * (typically a `@:trivia @:tryparse` Star ending with a body
	 * statement's `;\n`) emits a hardline with no pad-trailing signal
	 * to drop the explicit space. Plain `Text(' ')` would be flushed
	 * AFTER the next line's indent, producing `<indent> #else` instead
	 * of `<indent>#else`.
	 *
	 * Like `OptSpace`, contributes its width (`1`) to flat-measurement
	 * walks (`fitsFlat`, `flatTokenWidth*`); like `OptHardlineSkipAtOpenDelim`,
	 * the drop decision happens at render time based on `lastEmit`.
	 */
	OptSpaceSkipAfterHardline;

	/**
	 * Force-flat propagation marker (ω-force-flat-engine). Inside the
	 * subtree, the renderer treats every `Group` / `BodyGroup` as if it
	 * had chosen `MFlat` regardless of column fit, picks the flat branch
	 * of every `IfBreak` / `If*Exceeds`, lowers `Fill` to a plain
	 * sep-joined emit, collapses `OptHardline*` to nothing, and renders
	 * `Line(flat)` with the `flat` substring as text. Used by
	 * `WrapList.shapeNoWrap` to materialise fork's "this construct stays
	 * flat no matter what" semantic without per-Star-field cascade
	 * workarounds.
	 *
	 * Force-flat is rendering-time state, not structural — Doc walkers
	 * (`flatLength`, `flatTokenWidth*`, `hasLeadingHardline`, …) treat
	 * `Flatten` as a transparent pass-through, identical to descending
	 * `inner` directly. Only `Renderer` interprets it.
	 *
	 * Pair with `WrapBoundary` to scope force-flat to a single
	 * construct's body. Inner wrap-cascade results wrap themselves in
	 * `WrapBoundary` to reset force-flat — each cascade evaluates
	 * independently inside a force-flat region.
	 */
	Flatten(inner:Doc);

	/**
	 * Force-flat reset marker (ω-force-flat-engine). Inside the subtree,
	 * the renderer clears any inherited force-flat state — `Group` /
	 * `BodyGroup` resume their normal `fitsFlat` decision, `IfBreak` /
	 * `If*Exceeds` pick by enclosing `Group` mode, `Fill` does its
	 * per-item fit dispatch, hardlines render normally. When the
	 * enclosing context did NOT have force-flat active, this primitive
	 * is a no-op pass-through.
	 *
	 * Emitted by every wrap-cascade producer (`WrapList.emit`,
	 * `WrapList.emitCondition`, `BinaryChainEmit.emit`,
	 * `MethodChainEmit.emit`) around its final return value so that a
	 * nested cascade evaluates its own conditions inside a parent's
	 * force-flat region. The boundary is the "I have my own wrap-class —
	 * don't propagate force-flat into me" marker that mirrors fork's
	 * per-construct independent wrap-rules semantic.
	 *
	 * Like `Flatten`, this is rendering-time state — Doc walkers treat
	 * it as transparent pass-through.
	 */
	WrapBoundary(inner:Doc);

	/**
	 * Force-flat propagation marker whose region survives an inner
	 * `WrapBoundary` (ω-hardflatten / increment-2 chain-collapse). Behaves
	 * exactly like `Flatten(inner)` — every nested `Group`/`BodyGroup`
	 * forced `MFlat`, every `IfBreak`/`If*Exceeds` takes the flat branch,
	 * `Fill` collapses to a sep-join, `OptHardline*` drops, `Line(flat)`
	 * renders flat — EXCEPT that an inner `WrapBoundary` does NOT reset
	 * the force-flat state. The renderer propagates a `Frame.hardFlat`
	 * flag through every structural push; the `WrapBoundary` arm checks
	 * `if (f.hardFlat) keep-force-flat else reset`.
	 *
	 * This is the anyparse analogue of haxe-formatter's
	 * `collapseInnerChainBreaks` (MarkWrapping.hx:3288): once an expression
	 * paren opens, its inner opAddSub chain is flattened to one line
	 * UNCONDITIONALLY (regardless of width), because the chain's own
	 * `WrapBoundary(Group(IfBreak))` would otherwise re-float to its own
	 * fit decision and break. `HardFlatten` pins the whole subtree flat
	 * through that boundary — "the opened paren owns its content".
	 *
	 * `Flatten` inside a `HardFlatten` INHERITS the hard region (the
	 * `hardFlat` flag is already set); a top-level `Flatten` does NOT
	 * become hard.
	 *
	 * Like `Flatten`/`WrapBoundary`, this is rendering-time state — all
	 * Doc walkers treat it as a transparent pass-through (descend `inner`).
	 * Only `Renderer` interprets the hard-region semantic.
	 */
	HardFlatten(inner:Doc);

	/**
	 * Expression-paren collapse-candidate marker (ω-collapse-probe /
	 * increment-2). Wraps the OPEN (break) branch of an expression-paren's
	 * `IfFullLineExceeds(open, glued)`. Purely render-transparent — the
	 * renderer pushes `inner` with the enclosing frame's mode and force-flat
	 * flags UNCHANGED, so it adds no layout effect of its own (unlike
	 * `HardFlatten`, which force-flattens). Its sole purpose is to let
	 * `CollapsePass` recognise the paren as a collapse candidate REGARDLESS
	 * of the inner's operator class:
	 *  - opAddSub inner → `CollapseProbe(HardFlatten(inner))` (the inner is
	 *    pinned flat unconditionally, fork `collapseInnerChainBreaks`);
	 *  - opBool / ternary inner → `CollapseProbe(inner)` (the inner keeps its
	 *    own wrap cascade; only the enclosing chain is committed to glued).
	 * In both cases `CollapsePass` reads the measure-render's open decision at
	 * the `IfFullLineExceeds` node and commits the enclosing op-chain to its
	 * glued shape (fork `collapseChainBreaksAfter`), breaking the branch-blind
	 * circular coupling between paren-open and chain-break.
	 *
	 * Like `Flatten`/`WrapBoundary`/`HardFlatten`, all Doc walkers treat it
	 * as a transparent pass-through (descend `inner`).
	 */
	CollapseProbe(inner:Doc);

	/**
	 * Conditional-compilation marker fixed-zero scope (ω-cond-indent-policy
	 * FixedZero). Render-time-only: wraps the WHOLE `#if … #end` construct
	 * Doc (kw + cond + body + `#else`/`#elseif` clauses + trail). While
	 * rendering `inner`, any physical line whose FIRST non-whitespace byte is
	 * `#` — i.e. a preprocessor marker (`#if`/`#elseif`/`#else`/`#end`) — is
	 * re-indented to absolute column `0`; every other line (the guarded body
	 * content) keeps its frame indent. This is the anyparse analogue of
	 * haxe-formatter's `ConditionalIndentationPolicy.FixedZero`, where the
	 * conditional markers sit flush-left and the body stays at the enclosing
	 * statement indent.
	 *
	 * The discrimination is purely "fresh line whose first emitted token
	 * starts with `#`" — read at the Text-flush point in `Renderer.render`
	 * where the byte string is already known. Nested conditionals are handled
	 * for free: a nested `#if`/`#end` is still a `#`-leading fresh line inside
	 * the same scope, so it too lands at `0`, while its body stays at its
	 * (un-accumulated) frame indent — matching the fork's non-incrementing
	 * FixedZero body layout.
	 *
	 * Emitted by the generated writer ONLY when `opt.conditionalPolicy ==
	 * FixedZero` and the cond-comp ctor carries `@:fmt(conditionalMarkerDedent)`;
	 * every other policy leaves the construct unwrapped (byte-identical).
	 *
	 * Pure render-time state via a per-render depth counter (a local in
	 * `render`, NOT a static — invariant #1), pushed on entry and popped via a
	 * sentinel on scope exit. Structurally transparent — every static Doc
	 * walker descends `inner` exactly like `WrapBoundary`; only
	 * `Renderer.render` interprets the marker re-indent.
	 */
	ConditionalMarkerZero(inner:Doc);

	/**
	 * Conditional-compilation marker decrease scope (ω-cond-indent-policy
	 * AlignedDecrease). Render-time-only: wraps the WHOLE `#if … #end`
	 * construct Doc (kw + cond + body + `#else`/`#elseif` clauses + trail),
	 * exactly like `ConditionalMarkerZero`. While rendering `inner`, EVERY
	 * fresh physical line — both the preprocessor markers
	 * (`#if`/`#elseif`/`#else`/`#end`, incl. nested ones) AND the guarded
	 * body content — is re-indented one indent level shallower (clamped at
	 * column `0`). This is the anyparse analogue of haxe-formatter's
	 * `ConditionalIndentationPolicy.AlignedDecrease`: the body still
	 * accumulates `+1` per nesting depth (driven by the same
	 * `@:fmt(conditionalBodyIndent)` body-nest as `AlignedIncrease`), but
	 * the whole construct is shifted `-1` uniformly relative to the
	 * `AlignedIncrease` layout, so markers sit one level left of the
	 * enclosing statement indent and body one level left of the increase
	 * body.
	 *
	 * The discrimination is purely "fresh line, anything emitted" — read at
	 * the Text-flush point in `Renderer.render`. Unlike
	 * `ConditionalMarkerZero` (which fixes only `#`-leading lines at column
	 * `0`), this shifts every line by the same `-1` level, so the relative
	 * accumulation between body and markers is preserved while the whole
	 * block moves left. Nested conditionals compose: each nested
	 * `#if`/`#end` line is still a fresh line inside the same scope, so it
	 * too gets the single uniform `-1` (applied once per physical line, not
	 * per nesting depth).
	 *
	 * Emitted by the generated writer ONLY when `opt.conditionalPolicy ==
	 * AlignedDecrease` and the cond-comp ctor carries
	 * `@:fmt(conditionalMarkerDedent)`; every other policy leaves the
	 * construct unwrapped (byte-identical).
	 *
	 * Pure render-time state via a per-render depth counter (a local in
	 * `render`, NOT a static — invariant #1), pushed on entry and popped via
	 * a sentinel on scope exit. Structurally transparent — every static Doc
	 * walker descends `inner` exactly like `ConditionalMarkerZero`; only
	 * `Renderer.render` interprets the marker re-indent.
	 */
	ConditionalMarkerDecrease(inner:Doc);
}
