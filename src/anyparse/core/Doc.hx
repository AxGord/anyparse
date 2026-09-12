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
 * evaluation and Haxe ergonomics. Every ctor carries its own contract below.
 *
 * Before ADDING a ctor read `docs/architecture.md` § "The Doc probe family":
 * it holds the probe family's per-member calibration table, the
 * fits-strictness convention a new member picks its boundary from, and the
 * compile-time net of exhaustive spine walkers that catches a new ctor —
 * together with the one walker whose nested arm the net does not cover.
 *
 * See `D` for builder helpers and `Renderer` for the layout algorithm.
 */
enum Doc {

	Empty;

	/**
	 * A literal string with no line break of its own.
	 *
	 * `verbatim` says whether the bytes are CONTENT the writer must
	 * reproduce exactly (a comment body) or SYNTAX the writer emitted
	 * (a keyword, an operator, a separator, a delimiter). The renderer
	 * reads it for one decision and nothing else: a non-verbatim leaf's
	 * TRAILING blank run is held back and dropped when a line break
	 * lands on it, so no emitted-syntax space can ever reach a line
	 * end. A verbatim leaf is written whole, always.
	 *
	 * Omitted means syntax, because syntax is what nearly every `Text` in the
	 * tree is. The whole mark set is the comment emitters — `D.verbatim` over
	 * what the Doc `BlockCommentNormalizer` hands back, and `WriterCodegen`'s
	 * comment helpers via `_dtv`; marking the syntax side instead would be an
	 * open-ended sweep over every `kwLead`, separator and delimiter, and
	 * splitting the producer sites was tried and refused.
	 *
	 * The `_dtv` half is INERT for the Haxe grammar and is not there for
	 * Haxe: `LineCommentNormalizer` rtrims every `//` body before a Doc
	 * exists, so no such leaf can end in a blank, and
	 * `WriterTrailingWhitespaceTest` pins that rtrim as the reason. It is
	 * there because a grammar that binds NO `lineCommentAdapter` gets the
	 * raw captured bytes instead, and `trailingCommentDocGuarded` appends
	 * an `OptHardlineSkipBeforeHardline` right after them — author bytes
	 * with a break behind them is exactly the case the flag exists for,
	 * and grammars are plugins.
	 *
	 * The flag is deliberately NOT a separate ctor. Every other `Doc`
	 * walker — the width walks, flattening, the exhaustive spine walkers —
	 * treats a verbatim leaf identically to a syntax one, so a ctor
	 * would buy one pass-through arm per walker and one chance each to get
	 * it subtly wrong. A trailing optional parameter is invisible to
	 * `case Text(s)` (Haxe matches a ctor's leading arguments) and to
	 * `Text(s)` construction, so nothing else in the tree changes.
	 *
	 * A `Doc → Doc` rewriter must not rebuild a matched leaf as `Text(s)` —
	 * that silently demotes content to syntax. Today none does.
	 */
	Text(s: String, ?verbatim: Bool);

	/**
	 * A line break: a real `lineEnd` + indent in break mode, the `flat`
	 * replacement in flat mode.
	 *
	 * `verbatim` is `Text`'s flag one ctor down, and it answers the same
	 * question about the break that `Text`'s answers about the bytes: was
	 * this line boundary WRITTEN BY THE AUTHOR inside content the writer
	 * only reproduces — the interior of a multi-line block comment — or
	 * CHOSEN BY THE WRITER as layout. Only the renderer reads it, and only
	 * to record the break's buffer offset in `RenderCtx.textLineEnds`, so
	 * `Renderer.capConsecutiveBlanks` neither counts it into a blank run
	 * nor drops it. Omitted means layout, because layout is what nearly
	 * every `Line` in the tree is.
	 *
	 * The whole mark set is again the comment path: `D.verbatim` over what the
	 * Doc `BlockCommentNormalizer` hands back. That covers every assembly shape
	 * at once, the macro-generated `BlockCommentWriter.writeDoc` included, whose
	 * `@:sep('\n')` join no hand edit can reach.
	 *
	 * A GUTTER-LESS block comment is why the flag exists. Its lines are
	 * re-indented, so the normalizer hands the renderer one `Text` PER LINE
	 * joined by these breaks, and a blank interior line is an EMPTY `Text` that
	 * emits nothing at all; without the flag the cap sees a bare run of layout
	 * line-ends and deletes a line the author wrote. A DOC comment is no
	 * exception — its blank lines are safe only where the author put the ` * `
	 * gutter on them, and a genuinely empty interior line reaches
	 * `javadocBytePreserveDoc`, which builds the same empty `Text`.
	 *
	 * Marking the LEAF rather than opening a region is what keeps the mark
	 * honest at a boundary. The breaks BETWEEN two adjacent comments, and
	 * the one between a comment and the code under it, belong to the
	 * enclosing writer's Doc and are never inside the subtree `D.verbatim`
	 * walks — so they stay layout and stay cappable. A positional rule
	 * ("the run sits between two verbatim `Text`s") cannot tell those two
	 * cases apart and would silently under-apply the cap.
	 *
	 * Same shape and same reasons as `Text`'s flag — a trailing optional
	 * parameter no `case Line(flat)` and no `Line(flat)` construction sees —
	 * and under the same standing obligation: a `Doc → Doc` rewriter must not
	 * rebuild a matched break as `Line(flat)`. Today nothing does; only
	 * `D.verbatim`, which IS the mark, and `D.flatten`, carved out below,
	 * rebuild the node at all (`hxq cases Line src` re-derives the readers).
	 *
	 * `D.flatten` is outside that obligation rather than an exception to it: a
	 * break whose flat text is a newline becomes `Empty`, so the force-flat
	 * transform DELETES the line rather than demoting it. Its other arm,
	 * `Line(flat) -> Text(flat)` for a non-newline flat text, WOULD drop the
	 * mark; nothing reaches it today, because every break the comment path
	 * builds is `Line('\n')`.
	 */
	Line(flat: String, ?verbatim: Bool);

	/**
	 * Increases the current indent by `indent` for breaks inside `inner`.
	 */
	Nest(indent: Int, inner: Doc);

	/**
	 * A unit of fit decision. The renderer measures the flat width of `inner`
	 * and commits to flat when it fits within the remaining width, otherwise
	 * to break.
	 */
	Group(inner: Doc);

	/**
	 * Body-level fit decision. The renderer treats it identically to `Group`
	 * for its own flat/break choice; `fitsFlat` does not — measuring an outer
	 * `Group` that contains one DEFERS it, so its content never contributes to
	 * the parent's measurement.
	 *
	 * That deferral is what lets a multi-line block body sit inside a call
	 * argument without forcing the call's `(...)` onto separate lines, and what
	 * lets chained FitLines keep the outer body inline while the inner body
	 * breaks. The trivia writer's trailing-comment folder looks specifically for
	 * `BodyGroup` when splicing a trailing line comment.
	 */
	BodyGroup(inner: Doc);

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
	GroupWithRestProbe(inner: Doc);
	Concat(items: Array<Doc>);

	/**
	 * Emits `breakDoc` when the enclosing `Group` is in break mode and
	 * `flatDoc` when it is flat — for a trailing separator that should appear
	 * only when the list breaks.
	 */
	IfBreak(breakDoc: Doc, flatDoc: Doc);

	/**
	 * Column-aware sibling of `IfBreak`: at render time the renderer probes
	 * whether the current column plus `flatWidth(flatDoc)` reaches `n`, and
	 * takes `breakDoc` when it does. Independent of the enclosing `Group`'s
	 * flat/break mode.
	 *
	 * It exists for a cascade condition whose threshold differs from
	 * `WriteOptions.lineWidth`; for a threshold equal to `lineWidth` prefer
	 * `IfBreak`, which is cheaper and needs no per-primitive column probe.
	 * `fitsFlat` forwards to `flatDoc`, so an enclosing `Group`'s flat-mode
	 * width estimate stays stable whatever the column-aware decision is.
	 */
	IfWidthExceeds(n: Int, breakDoc: Doc, flatDoc: Doc);

	/**
	 * First-line-aware sibling of `IfWidthExceeds`: probes
	 * `col + firstLineWidth(flatDoc)` against `n`, so a forced hardline inside
	 * `flatDoc` caps the measurement at the first line instead of collapsing it
	 * to zero.
	 *
	 * `IfWidthExceeds` answers "would the whole flat subtree fit", which
	 * over-fires for a multi-line body; this one answers "would the first
	 * rendered line fit" — what `return <multi-line if-expr>` needs to keep the
	 * if-expr's HEAD inline while its later branches break. `fitsFlat` forwards
	 * to `flatDoc`, as in `IfWidthExceeds`.
	 */
	IfFirstLineExceeds(n: Int, breakDoc: Doc, flatDoc: Doc);

	/**
	 * Line-length-aware sibling of `IfWidthExceeds` (ω-iflineexceeds-infra):
	 * probes `col + flatTokenWidth(flatDoc) + flatTokenWidthOfRestStack`
	 * against `n`, extending the column-aware probe with a lookahead over the
	 * rest of the rendering stack up to the next forced hardline.
	 *
	 * It answers "would the rendered current line, including everything after
	 * this primitive on the same source line, reach `n` columns?" — closing the
	 * blind spot where a chain `Group(IfBreak)` sees only its own subtree and
	 * picks flat while the enclosing assign or binop expression pushes the line
	 * past `lineWidth`. Independent of the enclosing `Group`'s mode; `fitsFlat`
	 * forwards to `flatDoc`, and `BodyGroup` is DEFERRED in both walks
	 * (Departure 2).
	 */
	IfLineExceeds(n: Int, breakDoc: Doc, flatDoc: Doc);

	/**
	 * Residual-line-aware probe (ω-arrow-residual-linewrap). Renders exactly
	 * like `IfLineExceeds` at render time — fires `breakDoc` when `col +
	 * flatTokenWidth(flatDoc) + flatTokenWidthOfRestStack(stack) >= n` — but
	 * the natural-first-line WALK (`naturalWidthStructural`, consumed by an
	 * enclosing `IfNaturalFirstLineFitsOpenDelim` / `IfNaturalFirstLineExceeds`
	 * decision) resolves it WITHOUT the rest-of-stack lookahead: the arrow
	 * contributes only its own flat body width and DEFERS the rest-of-line to
	 * the enclosing measurer. So an enclosing construct (`&&`/`||` condition
	 * chain, ternary, assignment) sees the arrow's full flat width and breaks
	 * FIRST when the whole line overflows, instead of the arrow pre-empting it.
	 *
	 * Consumed ONLY by the arrow-body line-wrap marker
	 * (`WrapBoundary(IfResidualLineExceeds(...))`, emitted for
	 * `@:fmt(arrowBodyLineWrap)` `->`/`=>` bodies). A dedicated ctor keeps the
	 * cond-wrap `IfLineExceeds` rest-stack semantic untouched — the two probes
	 * consume the same `flatTokenWidthOfRestStack` walker at render time but
	 * diverge only in the natural-walk resolution.
	 */
	IfResidualLineExceeds(n: Int, breakDoc: Doc, flatDoc: Doc);

	/**
	 * Sibling of `IfLineExceeds` that DEFERS a `BodyGroup` on BOTH measures
	 * (ω-iffulllineexceeds-primitive).
	 *
	 * `flatTokenWidth(flatDoc)` defers one, so a lambda body inside a segment of
	 * `flatDoc` measures by its header alone and a chain probe does not
	 * over-fire; the rest-of-stack lookahead defers one too, so a sibling body
	 * following this primitive on the same source line — a `for (cond) BODY`
	 * body wrapped by `sameLine.forBody=fitLine`, a `case P if (c):` guard's
	 * body — contributes nothing. Such a body is MOVABLE: it drops to its own
	 * line whenever the shared line overflows, so counting it would decide a
	 * header's layout by the body's width, tearing a fitting case-guard label
	 * and breaking a method chain whose own header line fits
	 * (ω-header-wrap-ladder). Independent of the enclosing `Group`'s mode;
	 * `fitsFlat` and the cascade-rule static walks forward to `flatDoc`.
	 */
	IfFullLineExceeds(n: Int, breakDoc: Doc, flatDoc: Doc);

	/**
	 * Natural-shape sibling of `IfFirstLineExceeds`
	 * (ω-ifnaturalfirstlineexceeds-infra). Where `IfFirstLineExceeds` probes
	 * `col + flatTokenWidthFirstLine(flatDoc)` — a purely FLAT first-line walk
	 * that descends every inner `Group` / `IfBreak` / `If*Exceeds` on its flat
	 * branch — this one probes `naturalFirstLineWidth(flatDoc, col, indent,
	 * width)`: it renders `flatDoc` SPECULATIVELY at the current pen, resolving
	 * each inner `Group` by its OWN `fitsFlat` decision at the running column,
	 * and measures the first PHYSICAL line, up to the first naturally produced
	 * hardline.
	 *
	 * That distinguishes an RHS pinned `NoWrap`, which keeps its full flat width
	 * and so crosses, from an RHS that wraps its own call args and so does not —
	 * a distinction the flat `IfFirstLineExceeds` cannot make, because it
	 * over-measures both. `BodyGroup` is DEFERRED, as in the flat siblings.
	 * Canonical consumer: assignment break-after-`=` on a type-param-carrying
	 * LHS. `fitsFlat` and the static flat walks forward to `flatDoc`;
	 * `startsWithHardline` / `isOPLShape` recurse `breakDoc`.
	 */
	IfNaturalFirstLineExceeds(n: Int, breakDoc: Doc, flatDoc: Doc);

	/**
	 * `IfNaturalFirstLineExceeds` that also counts what rides the SAME rendered
	 * line AFTER `flatDoc` — content living in the enclosing render stack, which
	 * the probe's own walk cannot reach. Rest-aware sibling of the plain ctor in
	 * exactly the sense `GroupWithRestProbe` is of `Group`, and every static Doc
	 * walker treats the two identically; the difference is rendering-time only.
	 *
	 * The consumer is the `return`-body probe. Its statement terminator comes
	 * from the ctor's `@:trailOpt(';')`, so it is not part of the value's Doc: a
	 * value whose flat width equals the remaining budget EXACTLY resolved flat,
	 * the natural first line came out as the whole value, and the probe broke
	 * after the keyword — a bare `return` above a value that then fitted the
	 * continuation. Counting the terminator makes the value break inside itself.
	 *
	 * The assignment probe deliberately stays on the plain ctor: there the extra
	 * column buys an opened delimiter (`= try f(\n\t…\n) catch …`) in place of a
	 * two-line break after `=`, which is the worse shape.
	 */
	IfNaturalFirstLineExceedsWithRest(n: Int, breakDoc: Doc, flatDoc: Doc);

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
	 * SECOND CONSUMER, same two questions on a different subject:
	 * `BodyFit.strictFitLineLayout`, where `flatDoc` is a GLUED body rather than a
	 * glued `(cond)`. There (b) says the body breaks only inside a delimiter its own
	 * head line opened, so no part of it renders at the container indent — the
	 * condition a `@:fmt(strictFitLineBody)` field refuses the glue for.
	 *
	 * The natural-first-line semantic (each inner `Group` resolved by its own
	 * `fitsFlat` at the running column, first physical line measured) is
	 * shared with `IfNaturalFirstLineExceeds`; the added (b) end-on-open-delim
	 * test is what separates leading-break from packed inner constructs. Pure
	 * render-time decision — all static Doc walkers forward to `flatDoc`.
	 */
	IfNaturalFirstLineFitsOpenDelim(n: Int, breakDoc: Doc, flatDoc: Doc);

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
	 *
	 * SLOT INVERSION at the NON-arrow consumers. `WrapList.shapeSingleArgGlue`
	 * reuses this ctor twice — for a sole `{`-object-literal argument
	 * (ω-callparam-single-objectlit) and for the sole-argument outer-first probe
	 * (ω-outer-first-wrap), and `BinaryChainEmit.emitNoThreshold` a third time for
	 * the trailing-paren operator break (ω-opadd-trailing-paren-break), and
	 * `WrapList.shapeMultiArgCollection` a fourth for the FIT-pivot collection arg
	 * (ω-fit-pivot-collection-arg). All four pass `breakDoc` = the GLUED /
	 * fall-through shape and `flatDoc` = the OPENED shape, the reverse of the arrow
	 * consumer's pairing. The arm itself is unchanged (fits → `flatDoc`); what
	 * swaps is which layout each slot holds, because at those sites "fits at the
	 * continuation" is the reason to break the OUTER boundary rather than to keep
	 * it inline.
	 *
	 * `BinaryChainEmit.cuddleShape` (ω-ternary-cuddled-braces) adds three more, and
	 * they do NOT all agree with each other: its outer probe gate and its
	 * else-fits probe invert like the four above, while the innermost GLUE probe
	 * keeps the arrow pairing (`breakDoc` = the pre-knob separated shape,
	 * `flatDoc` = the glued one) — it asks "does the GLUED line fit", so fitting
	 * is the reason to glue. A walker resolving that one to `flatDoc` therefore
	 * reads the CUDDLED layout, not the pre-knob one.
	 *
	 * That inversion is visible to every walker that resolves this ctor to ONE
	 * slot. `WrapList.flatLength` takes `flatDoc`, so for such a call it walks a
	 * shape carrying hardlines and answers `-1` — "cannot be laid out on one
	 * line" — even though the call's glued form is perfectly flat. Two behaviours
	 * currently rest on that answer, so do not "correct" it without reading both:
	 *  - `WriterBlankLowering.caseSiblingWidthProbeExpr` (ω-case-sibling-symmetry)
	 *    consumes its bodies only through `flatLength`, so a case body holding
	 *    such a call never raises the widest-sibling maximum and the group falls
	 *    back to `BodyFit.SIBLING_NONE` — sibling coordination cannot be
	 *    triggered by one;
	 *  - the enclosing natural-first-line walk sees the OPEN shape and therefore
	 *    keeps an outer prefix glued, pinned by
	 *    `HxCallParamOuterFirstWrapSliceTest.testNestedCallSoleArgHugsWhenTheInnerCallLeadingBreaks`.
	 */
	IfArrowContinuationFits(extraIndent: Int, flatWidth: Int, n: Int, breakDoc: Doc, flatDoc: Doc);

	/**
	 * Rest-of-stack-aware `IfArrowContinuationFits` (ω-ternary-cuddle-tail).
	 * Identical to its plain sibling everywhere except the render arm, which also
	 * counts `Renderer.flatTokenWidthOfRestStack(stack)` — the content the pending
	 * work stack still emits on the SAME rendered line after this probe's subtree.
	 * Rest-aware sibling of the plain ctor in exactly the sense
	 * `IfNaturalFirstLineExceedsWithRest` is of `IfNaturalFirstLineExceeds`, and
	 * every static Doc walker treats the two identically; the difference is
	 * rendering-time only, so both share the plain ctor's probe-family row in
	 * `docs/architecture.md`.
	 *
	 * The consumer is `BinaryChainEmit.cuddleShape`'s two ELSE probes. What they
	 * measure is the ternary's LAST rendered line, and a ternary never owns the end
	 * of the line it sits on: a statement host trails `;`, a call argument trails
	 * `);`, one nested a call deeper trails `));`, and one whose host opened its own
	 * paren trails nothing at all. The plain ctor compares a column-independent
	 * token width that cannot see any of that, so the knob RESERVED one column and
	 * was exact for the statement host alone. Against any other host the two probes
	 * straddle a band `|tail - 1|` columns wide in which the cuddle explodes an
	 * else that had been a single line — a host whose own paren opened charges a
	 * tail the reserve over-counts, a doubly nested one a tail it under-counts.
	 *
	 * No constant closes that band, because the two probes want OPPOSITE
	 * conservatism — a loose glue probe cuddles a line that overflows, and a strict
	 * else probe reads a fitting else as "breaks anyway, so the cuddle is free" and
	 * cuddles it too. The real tail width is the only answer and it lives in the
	 * render stack, which is why this is a ctor and not a wider reserve.
	 *
	 * Both consumers pass `n = opt.lineWidth + 1`: the reserve is gone and the tail
	 * is charged for real, so the arm's strict `<` still reads "the whole rendered
	 * line, terminator included, fits inside `maxLineLength`". For the statement
	 * host that is arithmetically the older behaviour (tail 1 against a threshold
	 * one wider), which is why the calibrated fixtures do not move.
	 */
	IfArrowContinuationFitsWithRest(extraIndent: Int, flatWidth: Int, n: Int, breakDoc: Doc, flatDoc: Doc);

	/**
	 * Sibling-coordinated placement decision (ω-case-sibling-symmetry).
	 * Renders `breakDoc` when `f.indent + flatWidth` EXCEEDS `n`, else
	 * `flatDoc` — the `<= n` fits convention the `Group` family uses.
	 *
	 * The point is `flatWidth`: it is a build-time constant the EMITTER
	 * supplies, not a measurement of `flatDoc`. That is what lets a set of
	 * siblings reach ONE verdict. Every sibling of a group (e.g. every
	 * `case` clause of a switch) renders at the SAME indent, so handing all
	 * of them the same `flatWidth` — the widest sibling's flat width —
	 * makes every one of them answer identically, without the renderer
	 * needing to see the set. A sibling narrower than the widest still
	 * breaks, which is the "if one spreads, all spread" semantic.
	 *
	 * Column-independent by construction: the probe reads `f.indent`, not
	 * the live pen column, and `flatWidth` comes from a static walk
	 * (`WrapList.flatLength`, which DESCENDS `BodyGroup`), so the verdict
	 * cannot depend on the source's line shape and a single format pass
	 * reaches the `writeRoundTrip(s) == s` fixed point.
	 *
	 * Pure render-time decision: no static walker evaluates the width, and
	 * the two branches wrap the SAME body, differing only in the separator
	 * before it. That last property is load-bearing — a walker asking about
	 * subtree CONTENT gets the same answer from either branch, so the
	 * both-branch walkers (`CollapsePass.walk`, `Renderer.findCollapseProbe`,
	 * `MatrixWrap.isMultiline`) descend the FLAT branch ONLY. Descending both
	 * doubles the visited node count per nested probe, which is 2^depth for
	 * nested switches; one branch is the whole content for one traversal.
	 *
	 * See `docs/architecture.md` § "The Doc probe family" for how this ctor's
	 * fits-strictness and per-walker branch choice compare to its siblings —
	 * every member of the family diverges somewhere, and each divergence is
	 * justified only at its own call sites.
	 */
	IfIndentWidthExceeds(flatWidth: Int, n: Int, breakDoc: Doc, flatDoc: Doc);

	/**
	 * Glued-body placement decision (ω-glue-width). Renders `breakDoc` when the
	 * NATURAL first line of `flatDoc`, measured from the live pen column,
	 * EXCEEDS `n` — AND the same body's first line WOULD fit once moved to
	 * `indent + bodyIndent`, AND it carries more there than its own opening
	 * delimiter. Else `flatDoc`, the `<= n` fits convention of the `Group`
	 * family. Sole consumer: `BodyFit.glueLayout`; `bodyIndent` is the `Nest`
	 * amount inside `breakDoc`, carried here so the render arm can re-measure at
	 * the column the break would land on rather than guess it.
	 *
	 * The two extra conditions are not optimisations. Together they state the
	 * honest contract — a body moves down when moving it down FIXES the
	 * overflow, never merely because the glued line was long — and each refuses
	 * a shape the width test alone got wrong: the fit test covers the residual
	 * slop of the measurer (below), and the opening-delimiter test keeps a
	 * statement block from stranding its `{` on a line of its own for a two-
	 * column gain. The render arm names the corpus site behind each.
	 *
	 * Reads as `IfNaturalFirstLineExceeds` with two deliberate departures, and
	 * each one is why it is a separate ctor rather than a second call site:
	 *
	 *  - Both branches wrap the SAME body, differing only in the separator
	 *    before it (glued vs. next-line-one-deeper). A walker asking about
	 *    subtree CONTENT therefore gets one answer from either side, so the
	 *    both-branch walkers (`CollapsePass.walk`, `Renderer.findCollapseProbe`,
	 *    `MatrixWrap.isMultiline`) descend the FLAT branch ONLY — as they do for
	 *    `IfIndentWidthExceeds`, and unlike `IfNaturalFirstLineExceeds`, whose
	 *    branches are genuinely different shapes. Routing this population
	 *    through the both-branch ctor moves unrelated collapse-paren decisions
	 *    instead, because a probe in the body-glue slot doubles what those
	 *    walkers see.
	 *  - `WrapList.startsWithHardline` reads the FLAT side too, again unlike
	 *    the rest of the family. The break side opens with a hardline BY
	 *    CONSTRUCTION here, so a break-side read would answer "this body leads
	 *    with a newline" for every glued body in the tree and flip cond-wrap
	 *    shapes that have nothing to do with this decision. The flat side is
	 *    the status-quo shape, which is what keeps a glue that survives the
	 *    probe byte-identical.
	 *
	 * WHY the natural measurer and not a static one: the question is "will the
	 * header line, with this body glued after it, actually overflow?", and only
	 * a speculative render answers it. A flat first-line walk counts a
	 * condition that the renderer WILL wrap, so it breaks bodies whose glued
	 * shape was never over-wide, most of them regressions;
	 * `DocMeasure.breakableHead` stops at the first break
	 * OPPORTUNITY, which for a construct-group body is its opening `(` — it can
	 * never fire. The natural walk resolves each inner `Group` (and `BodyGroup`
	 * — `naturalWidthStructural` treats it as a real group, the Doc stanza
	 * above notwithstanding) by its own `fitsFlat` at the running column, which
	 * is the renderer's own decision procedure.
	 *
	 * Residual: the natural walk resolves `IfFirstLineExceeds` /
	 * `IfNaturalFirstLineFitsOpenDelim` / `IfArrowContinuationFits` /
	 * `IfIndentWidthExceeds` — and this ctor itself, so a NESTED glue measures
	 * as glued during an outer probe's walk — on their FLAT side
	 * (`naturalWidthStructural`), so a body whose own bracket opens through one
	 * of those probes measures as if it had stayed packed. That over-measures,
	 * i.e. it can break a glue whose rendered first line would have fitted; the
	 * second gate absorbs most of it, and `BodyFit.glueLayout` documents the one
	 * corpus site it does not.
	 */
	IfGluedFirstLineExceeds(n: Int, bodyIndent: Int, breakDoc: Doc, flatDoc: Doc);

	/**
	 * Wadler `fillSep`. Flat mode emits the items joined by `sep` flat; break
	 * mode packs them left to right — before each item after the first it
	 * measures `sep + item` flat from the current column, emitting `sep` flat
	 * and then the item when that fits, and otherwise emitting `sep` in break
	 * mode, so its inner `Line` becomes a hardline at the Fill's indent and the
	 * item starts on the new line. The first item is always emitted at the entry
	 * column.
	 *
	 * `BodyGroup` deferral applies inside the per-item flat measurements, so an
	 * item carrying a multi-line block body still measures by its header width
	 * and packs cleanly with its siblings. `tailReserve` is the width of the
	 * post-Fill same-line content — trailing punctuation plus a close delimiter
	 * emitted OUTSIDE the Fill but on the same line as its last packed item —
	 * subtracted from the per-item fit budget so that last item leaves room for
	 * the tail (ω-fill-tail-reserve).
	 */
	Fill(items: Array<Doc>, sep: Doc, ?tailReserve: Int);

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
	FillWithRestProbe(items: Array<Doc>, sep: Doc, ?tailReserve: Int);

	/**
	 * Break-after-wrapped-item `Fill` variant (ω-fill-break-after-wrap). At
	 * render time, the per-item-fit probe additionally forces the separator
	 * before `items[i]` to BREAK whenever the preceding item `items[i-1]`
	 * self-wrapped — i.e. it emitted a physical newline while rendering,
	 * overflowing its own continuation line. Plain `Fill` packs the follower
	 * onto the wrapped item's short last-line column (render-order dependent);
	 * this variant instead matches haxe-formatter's
	 * `wrapFillLineWithLeading2AfterLast` flat-width `lineLength` accounting,
	 * where an item whose flat width overflows `maxLineLength` pushes the next
	 * item onto its own continuation line regardless of where the wrapped item
	 * visually ends.
	 *
	 * Used by `WrapList.shapeFillLineWithLeadingBreak` for the OUTER call-
	 * argument list of a `fillLineWithLeadingBreak` call whose first arg is a
	 * self-wrapping opAddSub chain: the chain wraps across continuation lines,
	 * then the trailing scalar args (`, 10212` / `, getStyle(), 430, 20`) start
	 * on a fresh continuation line and fill-pack among themselves — exactly
	 * `opadd_multiparam_{before,after}_last` and `opadd_multiparam_continuation_
	 * indent`.
	 *
	 * All static Doc walkers (`flatTokenWidth`, `flatTokenWidthFirstLine`,
	 * `flatLength`, `hasLeadingHardline`, …) treat this primitive identically
	 * to `Fill(items, sep, tailReserve)` — the break-after-wrap semantic is a
	 * render-time decision only.
	 */
	FillBreakAfterWrap(items: Array<Doc>, sep: Doc, ?tailReserve: Int);

	/**
	 * Optional inline whitespace, dropped when a break-mode `Line` immediately
	 * follows it. Lead emission uses it to keep the lead literal and its
	 * trailing space byte-identical when the value lays out flat, while
	 * suppressing that space when the value emits a leading hardline (say
	 * `leftCurly=Next` on an object literal).
	 *
	 * Counts as `Text(s)` for flat-mode `fitsFlat`, so wrapping decisions do
	 * not shift. The renderer holds it in a small pending buffer, flushes it
	 * before any `Text` (or an in-flat `Line`) and discards it right before a
	 * break-mode `Line` writes its newline; one still unflushed at end of render
	 * is dropped, so no trailing whitespace reaches EOF.
	 */
	OptSpace(s: String);

	/**
	 * Optional break-mode newline, dropped when the last emit was already a
	 * hardline (`Line('\n')` or another `OptHardline`). It coordinates two
	 * independent emitters that each want a leading newline at the same
	 * insertion point — a wrap-engine separator between call args followed by
	 * the next arg's `leftCurly=Next` leading newline — which would otherwise
	 * collide into a spurious blank line.
	 *
	 * Like `Line('\n')` it forces `fitsFlat` to refuse to flatten. The dropped
	 * variant still updates `pendingIndent` to its own indent, so the next
	 * `Text` lands at the more specific inner position. An INTENTIONAL blank
	 * line must use plain `Line('\n')` pairs; this ctor is opt-in at the
	 * producer site.
	 */
	OptHardline;

	/**
	 * Break-mode newline that drops when the last emitted byte is an open
	 * delimiter (`(`, `[`, `{`), or when a hardline already precedes it — the
	 * same collision drop `OptHardline` makes.
	 *
	 * Chain shapes (`BinaryChainEmit.shapeOnePerLine`) use it for the leading
	 * hardline before the first item: the chain's first operand stays glued to
	 * an enclosing open delimiter, while an outer context whose previous byte is
	 * `=` or a name still gets its newline and indent. Like `Line('\n')` and
	 * `OptHardline` it forces `fitsFlat` to refuse to flatten, so the enclosing
	 * `Group` commits to break; the dropped variant updates `pendingIndent` to
	 * its own indent so a following `Text` lands at the right column.
	 */
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
	 * Like `OptSpace`, contributes one column to the flat-width walks
	 * (`fitsFlat`, `flatTokenWidth*`); like `OptHardlineSkipAtOpenDelim`,
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
	Flatten(inner: Doc);

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
	WrapBoundary(inner: Doc);

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
	HardFlatten(inner: Doc);

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
	CollapseProbe(inner: Doc);

	/**
	 * Inner-opAddSub-chain collapse-candidate marker (ω-unwrap-add-ops /
	 * inverse-direction CollapsePass increment). Wraps the BROKEN (`brk`)
	 * shape of an opAddSub chain's own `IfBreak(brk, flat)` pivot — the
	 * marker is therefore rendered ONLY when that inner chain commits to
	 * its broken form (its enclosing `IfBreak` picked `brk`).
	 *
	 * Sister of `CollapseProbe` but the INVERSE direction: where
	 * `CollapseProbe` lets an expression paren OPEN and glue the enclosing
	 * chain, `CollapseAddProbe` lets an INNER opAddSub chain COLLAPSE its
	 * `+`/`-` breaks (HardFlatten) when it sits inside an OUTER op-chain
	 * (opBool / opAddSub) that committed to its own broken shape. This is
	 * the anyparse analogue of haxe-formatter's `unwrapAddOps`
	 * (MarkWrapping.hx:4139): once a surrounding region wraps, the inner
	 * `Binop(OpAdd)` / `Binop(OpSub)` line-ends are stripped
	 * UNCONDITIONALLY so the add-chain rides one continuation line.
	 *
	 * Purely render-transparent — the renderer pushes `inner` with the
	 * enclosing frame's mode and force-flat flags UNCHANGED (like
	 * `CollapseProbe`), so it adds no layout effect of its own. In the
	 * measure-only pass (`decisions != null`) the render dispatch records
	 * whether the marker was reached in break mode (`crosses = f.mode ==
	 * MBreak`) keyed by node identity; `CollapsePass` reads that decision
	 * plus the enclosing-chain-broke fact and rewrites
	 * `CollapseAddProbe(brk)` → `HardFlatten(brk)` (collapsing the inner
	 * add-chain to one flat line) only inside a broken outer chain. Absent
	 * any enclosing broken chain the marker is rewritten back to its bare
	 * `inner` → byte-identical.
	 *
	 * Like `Flatten`/`WrapBoundary`/`HardFlatten`/`CollapseProbe`, all Doc
	 * walkers treat it as a transparent pass-through (descend `inner`).
	 */
	CollapseAddProbe(inner: Doc);

	/**
	 * opBool-chain break-DIRECTION re-evaluation marker
	 * (ω-opbool-reeval-after-callparam / CollapsePass increment 2). Wraps the
	 * operator-TRAILING (`location: AfterLast`) FillLine shape of an opBool
	 * chain (`&&` / `||`) emitted inside an active cond-wrap context
	 * (`condWrapForced`) whose operands include a function call.
	 *
	 * Sister of `CollapseAddProbe` but for the break-DIRECTION axis rather
	 * than the collapse axis. The anyparse analogue of haxe-formatter's
	 * `reEvaluateOpBoolAfterCallParam` (MarkWrapping.hx:673): when a contained
	 * `callParameter` would wrap in the all-flat layout — i.e. the call
	 * operand's flat right edge overflows `maxLineLength` at its flat column —
	 * the fork re-applies the opBool chain wrap with the call breaks stripped,
	 * flipping the operator from trailing to LEADING (`&&` starts the
	 * continuation line) and gluing the now-fitting call flat onto its own
	 * line.
	 *
	 * Purely render-transparent — the renderer pushes `inner` (the trailing
	 * shape) with the enclosing frame's mode and force-flat flags UNCHANGED
	 * (like `CollapseAddProbe`), so absent a flip the output is byte-identical
	 * to the trailing shape. In the measure-only pass (`decisions != null`)
	 * the render dispatch records whether the marker was reached in break mode
	 * (`crosses = f.mode == MBreak`) AND the actual visual column the chain
	 * starts at (`indent = col`) keyed by node identity. `CollapsePass` reads
	 * that decision, walks the trailing FillLine's operands to test whether a
	 * call operand overflows at its flat position, and — only then — rewrites
	 * the marker to the operator-LEADING FillLine shape (fork
	 * `useTrailing: false`). When no call operand overflows, the marker
	 * unwraps to its bare `inner` (byte-identical).
	 *
	 * Like `Flatten`/`WrapBoundary`/`HardFlatten`/`CollapseProbe`/
	 * `CollapseAddProbe`, all Doc walkers treat it as a transparent
	 * pass-through (descend `inner`).
	 */
	CollapseBoolProbe(inner: Doc);

	/**
	 * method-chain re-glue (dot-break re-evaluation) marker
	 * (ω-methodchain-reeval-after-callparam / CollapsePass increment 3 —
	 * subroot-E). `MethodChainEmit.emit` wraps a chain's width-driven
	 * `IfFullLineExceeds(w, dotBreakShape, gluedShape)` in this marker when the
	 * BREAK shape is a dot-break over a glued `NoWrap` flat shape, the chain is
	 * not itself a call argument, and its glued last segment is a breakable call
	 * whose args wrap with a LEADING BREAK (`callParameterWrap.defaultMode ==
	 * FillLineWithLeadingBreak`).
	 *
	 * Sister of `CollapseBoolProbe`, but for the method-chain DOT-break axis
	 * rather than the opBool operator-direction axis. The anyparse analogue of
	 * haxe-formatter's `reEvaluateMethodChainAfterCallParam` (`MarkWrapping.hx`):
	 * when a contained `callParameter` actually wrapped (`isNewLineAfter(POpen)`
	 * — the segment's call args broke at layout time), the fork STRIPS the chain
	 * dot-break (re-glues the chain — `manager.getInstance().add(` on one line,
	 * args wrapping inside the glued call) instead of the over-eager
	 * dot-then-call-broke layout anyparse's width probe produces (it sees the
	 * full glued flat width including the now-breakable args).
	 *
	 * Like `CollapseBoolProbe`, the marker is purely render-transparent — the
	 * renderer pushes `inner` with the enclosing frame's mode and force-flat
	 * flags UNCHANGED, so absent a flip the output is byte-identical to the
	 * `IfFullLineExceeds` it wraps. In the measure-only pass (`decisions != null`)
	 * the render dispatch records the actual visual column the chain receiver
	 * starts at (`indent = col`) keyed by node identity. `CollapsePass.
	 * rewriteChainProbe` reads that column and — only when the full glued flat
	 * overflows BUT the glued first line (with the last call's args broken) fits
	 * at `col` (an O(1) flat-token-width re-measure, NO recursive spine probe) —
	 * rewrites the marker to the glued shape. Otherwise it keeps the
	 * `IfFullLineExceeds` (byte-identical).
	 *
	 * Like `Flatten`/`WrapBoundary`/`HardFlatten`/`CollapseProbe`/
	 * `CollapseAddProbe`/`CollapseBoolProbe`, all Doc walkers treat it as a
	 * transparent pass-through (descend `inner`).
	 */
	CollapseChainProbe(inner: Doc);

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
	ConditionalMarkerZero(inner: Doc);

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
	ConditionalMarkerDecrease(inner: Doc);

}
