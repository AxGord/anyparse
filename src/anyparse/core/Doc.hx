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
}
