package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.macro.WriterLoweringSupport.*;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;

using anyparse.macro.MetaInspect;

/**
 * Pass 3W — the blank-line and width probes shared by the Star
 * families.
 *
 * These are the `Expr` fragments a Star emit body splices when it has
 * to ask a question about the SOURCE rather than about the grammar:
 * how many blank lines the input had around a multi-line member
 * (`blankAroundMultilineExprs`, `blankBefore2ExtrasExpr`), whether a
 * uniform-collapse run is still uniform
 * (`triviaUniformCollapseInitExpr`, `triviaBalcEmitExpr`), whether a
 * switch-case sibling still fits its line (`caseSiblingWidthProbeExpr`,
 * `caseSiblingUnitExpandExpr`), and the small seam builders an arrow
 * body or a bare separator needs.
 *
 * They live here rather than in any one Star family because each is
 * read by two or more of them — the tryparse, block, sep and eof
 * modules plus `WriterLowering` itself — which is exactly why they had
 * stayed behind in `WriterLowering` when those four families were
 * extracted. Callers reach them unqualified through
 * `import anyparse.macro.WriterBlankLowering.*;`.
 */
@:access(anyparse.macro.WriterLoweringSupport)
final class WriterBlankLowering {

	/**
	 * ω-uniform-statement-blanks / ω-uniform-element-blanks: pre-pass Expr
	 * declaring `_uniformCollapse` over the captured element array — shared by
	 * the block-Star (statement list) and sep-Star (array literal) emitters.
	 * `true` when the runtime knob is `Collapse` AND every interior gap between
	 * adjacent elements is blank AND no INTERIOR element carries a leading
	 * comment. Uniformity is measured over INTERIOR gaps only, so the edge blank
	 * right after the open delimiter never participates.
	 *
	 * A leading comment bails from an INTERIOR element only, because only there
	 * can a blank line detach it from the element above and make it a group
	 * header — and under uniformity that blank is always present. Element 0 has
	 * nothing above it but the open delimiter, so its comment annotates its own
	 * element and carries no grouping intent; the blank it may hold
	 * (`blankAfterLeadingComments`) is stripped by `triviaBalcEmitExpr`.
	 *
	 * Declared as a bare `EVars` so the var lands in the enclosing emit scope the
	 * per-element blank guard reads. `macro {}` (no declaration) for every
	 * non-opted Star, keeping the pre-slice emit byte-identical.
	 *
	 * The declare/read pair now spans three modules: this declaration is spliced
	 * by `TriviaSepLowering.triviaSepDispatchExpr` and
	 * `TriviaBlockLowering.triviaBlockElseBody`, and `_uniformCollapse` is read by
	 * the blank guards in both. Parity is held only by every one of those sites
	 * passing the same `uniformStmtBlanks` flag — gate one side and not the other
	 * and the generated writer either reads an undeclared local or declares a dead
	 * one, with nothing in any module's types to catch it.
	 */
	private static function triviaUniformCollapseInitExpr(uniformStmtBlanks: Bool): Expr {
		return !uniformStmtBlanks
			? macro {}
			: macro var _uniformCollapse: Bool = opt.uniformStatementBlanks == anyparse.format.UniformStatementBlanksPolicy.Collapse && {
				var _ok: Bool = true;
				var _uci: Int = 0;
				while (_uci < _arr.length) {
					if (_uci > 0 && (!_arr[_uci].blankBefore || _arr[_uci].leadingComments.length > 0)) {
						_ok = false;
						break;
					}
					_uci++;
				}
				_ok;
			};
	}

	/**
	 * ω-uniform-statement-blanks / ω-uniform-element-blanks: the
	 * `blankAfterLeadingComments` emit, shared by the block-Star and sep-Star
	 * force-multi loops. A collapsed element list must also drop the blank a
	 * leading comment holds before its own element — the pre-pass only lets a
	 * comment through at element 0, so this reaches exactly the "note glued to
	 * the open delimiter, then a stray blank" shape and never an interior group
	 * header. The pre-slice expression for every non-opted Star.
	 */
	private static function triviaBalcEmitExpr(uniformStmtBlanks: Bool): Expr {
		return uniformStmtBlanks ? macro if (_t.blankAfterLeadingComments && _t.leadingComments.length > 0 && !_uniformCollapse)
			_inner.push(_dhl()) : macro if (_t.blankAfterLeadingComments && _t.leadingComments.length > 0) _inner.push(_dhl());
	}

	/**
	 * ω-blank-around-multiline-members — the three fragments that force a blank
	 * line into the gap between two adjacent members when either of them renders
	 * across more than one line.
	 *
	 * Why it cannot reuse the `multiline` predicate the module level already
	 * has: that one is resolved STRUCTURALLY at macro time from
	 * `@:fmt(multilineWhen…)` on the payload type, and a member has no such
	 * shape — `final a = ['x'];` and `final a = [… twenty …];` are the same
	 * node and differ only by width. So the question is asked of the built Doc
	 * instead, which forces the split into three splice points: the gap's
	 * position is known BEFORE the element is written, the answer only AFTER.
	 *
	 * `mark` records the insert index (ahead of the element's leading comments,
	 * so a doc-comment stays attached to its member); `seen` notes whether the
	 * source-driven rules already filled the gap, so the pass tops up to the
	 * knob rather than adding to it; `apply` measures both neighbours and
	 * splices the hardlines in at the recorded index.
	 *
	 * The width side compares against ONE indent level. That is exact for a
	 * top-level type and under-counts for a nested one, which can only cost a
	 * blank that a stricter measure would have added — never a spurious one.
	 */
	private static function blankAroundMultilineExprs(optField: Null<String>): {
		final markExpr: Expr;
		final seenExpr: Expr;
		final applyExpr: Expr;
	} {
		if (optField == null) return { markExpr: macro {}, seenExpr: macro {}, applyExpr: macro {} };
		final knob: Expr = { expr: EField(macro opt, optField), pos: Context.currentPos() };
		return {
			// ONE `EVars` node, not `macro { var …; var …; }` — a reified block
			// is an `EBlock`, i.e. its own scope, and the two sibling splices
			// below would not see the vars.
			markExpr: {
				expr: EVars([
					{ name: '_bamAt', type: macro :Int, expr: macro _inner.length },
					{ name: '_bamHad', type: macro :Bool, expr: macro false }
				]),
				pos: Context.currentPos()
			},
			seenExpr: macro _bamHad = _inner.length > _bamAt,
			applyExpr: macro {
				if (_si > 0 && !_bamHad && $knob > 0) {
					final _bamCols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
					inline function _bamMulti(_d: anyparse.core.Doc): Bool {
						return anyparse.core.DocMeasure.hasForcedBreak(_d)
							|| _bamCols + anyparse.core.DocMeasure.flatTokenWidth(_d) > opt.lineWidth;
					}
					if (_bamMulti(_elem) || (_priorElemDoc != null && _bamMulti(_priorElemDoc))) {
						var _bami: Int = 0;
						while (_bami < $knob) {
							_inner.insert(_bamAt, _dhl());
							_bami++;
						}
					}
				}
			}
		};
	}

	/**
	 * ω-blank2: emit `_t.blankBefore2` extra hardlines — the blank lines
	 * beyond the first (already emitted for `blankBefore`) — via `pushExpr`.
	 * `blankBefore2` is `@:optional` on the trivia struct, so a construction
	 * site that never set it reads `null`, treated as zero. The Renderer caps
	 * the run at `opt.maxConsecutiveBlanks`, so an over-emit collapses back;
	 * this only widens a >1 source blank gap up to the configured maximum.
	 * References the runtime `_t`; splice right after the `blankBefore` push.
	 */
	private static function blankBefore2ExtrasExpr(pushExpr: Expr): Expr {
		return macro {
			final _bb2: Int = _t.blankBefore2 ?? 0;
			var _bbi: Int = 0;
			while (_bbi < _bb2) {
				$pushExpr;
				_bbi++;
			}
		};
	}

	/**
	 * ω-case-sibling-symmetry — build the per-SWITCH placement pre-pass for a
	 * case-list Star, or `macro -1` when the Star does not opt in.
	 *
	 * THE PROBLEM: each case body's `FitLine` placement is decided
	 * independently, so one body that lands below its label leaves its short
	 * siblings inline. The user-visible ask is per-SWITCH symmetry — if ANY
	 * body renders below its label, all of them do.
	 *
	 * THE RULE, in one sentence: a switch is TRIGGERED when some unit is
	 * below-label STRUCTURALLY, and otherwise when the widest unit's flat
	 * width does not fit or some unit is both unmeasurable and refused the
	 * glue. Every channel reaches the same output slot
	 * (`_caseSiblingFlatWidth`, consumed by `BodyFit.fitLineLayout` as an
	 * `IfIndentWidthExceeds` probe width), so nothing downstream has to know
	 * which one fired.
	 *
	 * STRUCTURAL CHANNEL. The generated
	 * `caseUnitStructuralBreak_<ElemRule>` predicate answers, per expanded
	 * unit, whether its body sits below its label at ANY budget: a body of two
	 * or more statements, a single statement `caseBodyRefusesFlat` refuses, or
	 * a `CondSpliceCase` label-splice region, whose shared body is mandatory
	 * and always renders below the labels it was split from. Two shapes
	 * deliberately do not trigger: an EMPTY body (nothing to place, and
	 * nothing a forced break could move) and a GLUED body (a lambda / block /
	 * object literal — its FIRST line shares the label line, so it is not a
	 * below-label placement). A glued body still MOVES under someone else's
	 * trigger; it just never leads.
	 *
	 * WHAT THE CHANNEL COSTS. The first `true` sets
	 * `BodyFit.SIBLING_FORCE_BREAK` and the measuring loop is SKIPPED — so a
	 * TRIGGERED switch now costs ONE write per element instead of the
	 * pre-pass's two. A switch that does NOT trigger pays the other side of
	 * that trade: the predicate walk visits every unit before the measuring
	 * loop begins, an O(N) pass the width-only pre-pass did not make. It reads
	 * AST fields and allocates nothing, so it is cheap against the writes it
	 * exists to avoid — but it is not free.
	 *
	 * WIDTH CHANNEL (the original slice, now the fallback). With no structural
	 * unit, the pre-pass writes each element once with the coordination
	 * suppressed and takes the maximum `WrapList.flatLength`. Elements that
	 * answer `-1` (glued bodies, and the shapes below) contribute nothing to
	 * that maximum. All negative ⇒ `SIBLING_NONE` and the emit stays
	 * uncoordinated, which is what keeps an all-glued switch (a comparator
	 * table of `case X: (a, b) -> { … }`) exactly as it renders without this
	 * slice.
	 *
	 * THE CONTROL-FLOW VERDICT rides that loop rather than the structural pass
	 * (omega-case-body-controlflow-glue). `BodyFit.fitLineLayout` refuses the
	 * glue for a body whose single statement is keyword-led control flow, so
	 * such a body renders below its label and must lead like a structural
	 * one — but only when it CANNOT render flat, and `case X: if (c) x();` and
	 * `case X: if (c) { x(); }` have the same statement kind. Kind alone
	 * therefore cannot decide it; the loop asks
	 * `caseUnitControlFlowBody_<ElemRule>` exactly on the units that measured
	 * `-1`, and the first `true` substitutes `SIBLING_FORCE_BREAK`. The arm is
	 * emitted ONLY for an element rule whose body Star carries
	 * `@:fmt(refuseGlueOnControlFlowRoot)` (resolved at macro time by
	 * `elemBodyStarHasFlag`), so the spread and the placement it accompanies
	 * can never be enabled apart.
	 *
	 * That verdict also reaches PAST the shape it was written for, and
	 * correctly so: it reads the statement KIND and never the trivia, so a
	 * COMMENT-refused body - one a leading comment on its element, or a
	 * trailing comment captured on its label, already pushed below its label -
	 * leads the spread too when its single statement is control-flow. It
	 * measures `-1` for the comment's sake and answers true for the
	 * statement's, and both point the same way.
	 *
	 * THE RESIDUALS — shapes that DO render below their label and still cannot
	 * LEAD. One is render-time: a glue that `BodyFit.glueLayout` turns into a
	 * break. That verdict is reached at the LIVE PEN COLUMN — the header is
	 * already emitted and only the renderer knows how wide it came out — so no
	 * emitter-side walk can predict it, and the switch it belongs to is not
	 * triggered by it. Pinned by
	 * `HxGlueWidthSliceTest.testGlueTurnedBreakIsNotASiblingSymmetryTrigger`.
	 * The other is a COMMENT-refused body whose single statement is NOT
	 * control-flow - the paragraph above closes the control-flow half of that
	 * class, not the class. Its tree is perfectly readable; the obstacle is
	 * that one predicate NAME emits one predicate BODY, shared by the plain /
	 * trivia / spans AST families, and the slots holding those comments are
	 * trivia-family-specific - see
	 * `HxCasePredLowering.caseUnitStructuralBreakField` for the full argument.
	 *
	 * A body Star with ORPHAN trailing comments used to be a third such shape;
	 * since omega-case-trail-comment-inline it flattens instead, so it is no
	 * longer below its label. It still contributes no WIDTH — its element Doc
	 * carries the comment run's hardline, so the pre-pass measures it `-1`,
	 * exactly as it measures a glued body — which means it never leads a
	 * spread by WIDTH and always follows one. That is deliberate: the rule the
	 * owner asked for is about whether the BODY can share its label line, and
	 * the comment sits outside the `BodyGroup` the fit path wraps the body in,
	 * so an over-wide such body still breaks on its own at render time.
	 *
	 * WHAT A DIRECTIVE REGION CONTRIBUTES (ω-if-leader-case-symmetry): not one
	 * element, but its inner case UNITS. A `#if`-guarded region projects as ONE
	 * Star element whose Doc carries directive hardlines, so measured whole it
	 * is always `-1` — it could FOLLOW a plain sibling's break and never LEAD
	 * one. The Star's `caseSiblingUnits_<ElemRule>` flattener expands the
	 * region into the inner case elements of EVERY branch (`#if` / `#elseif` /
	 * `#else` are alternatives — only one is ever compiled — so the maximum
	 * over all of them is the conservative trigger), and every channel then runs
	 * per inner unit: an over-wide guarded body leads by width, a
	 * multi-statement one leads structurally. The one-element short-circuit
	 * moved with it: what must exceed 1 is the UNIT count, so a switch whose
	 * only element is a region holding several cases still coordinates. A
	 * `CondSpliceCase` region is the exception that does NOT expand — its
	 * labels are byte-verbatim, so there is no inner case list — but it stays
	 * one unit that LEADS, because the structural channel answers true for it
	 * outright.
	 *
	 * The flattener and the structural verdict are MANDATORY for an opted-in
	 * Star: a format carrying the meta without generated AST predicates is a
	 * macro-time error here, not a silent fallback - carrying a second,
	 * never-exercised copy of this pre-pass is exactly the drift the trivia
	 * web's predicate-only `@:fmt` features refuse. The control-flow verdict is
	 * the one OPTIONAL member, because it belongs to a second, independently
	 * declared meta.
	 *
	 * `WrapList.flatLength` is the width measure specifically because it
	 * DESCENDS `BodyGroup` where `Renderer.fitsFlat` defers it — the T16b
	 * lesson: anything that reads render-time group state makes the verdict
	 * depend on the source's line shape, and `fmt` then needs a second pass to
	 * settle.
	 *
	 * WHY THE PRE-PASS DOES NOT NEST (ω-case-sym-linear): writing an element
	 * twice — once to measure, once to emit — costs 2x per switch LEVEL, so a
	 * switch nested d deep cost 2^d. The recursion is pure waste, because
	 * `flatLength` forwards `IfIndentWidthExceeds` to its FLAT branch: a nested
	 * switch's own coordination is INVISIBLE to the measurement that contains
	 * it. The `SIBLING_PROBING` marker therefore rides down the whole subtree —
	 * every Star already inside a pre-pass returns it unchanged instead of
	 * running its own — so each level is measured once and emitted once.
	 * Depth-15 nesting went from ~6s to flat.
	 *
	 * The knob gate keeps the double write off every config that cannot use it:
	 * the pre-pass runs only when the policy the case bodies will actually
	 * consult (`opt._inExprPosition` selects which of the two) is `FitLine`.
	 * Under `Same` / `Keep` / `Next` the elements are written exactly once, as
	 * before.
	 */
	private static function caseSiblingWidthProbeExpr(
		elemFn: String, knobs: Null<Array<String>>, ?unitsFn: Expr, ?structuralFn: Expr, ?controlFlowFn: Expr
	): Expr {
		if (knobs == null) return macro -1;
		final fitPat: Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BodyPolicy', 'FitLine']);
		final stmtAccess: Expr = optFieldAccess(knobs[0]);
		final exprAccess: Expr = optFieldAccess(knobs[1]);
		final policyGate: Expr = macro (opt._inExprPosition ? $exprAccess : $stmtAccess) == $fitPat;
		// `caseSiblingSymmetry` is a predicate-only feature with no legacy
		// runtime channel, so it follows the trivia web's rule for such metas:
		// fail LOUDLY rather than carry a second, untestable copy of the
		// pre-pass for a grammar that opts in without generating predicates.
		// Both predicates are mandatory: without the flattener a `#if` region
		// could not lead, and without the structural verdict the rule would
		// silently degrade to the width-only one it replaced. The message names
		// the one that is missing, so it points at the gap it found.
		if (unitsFn == null || structuralFn == null) {
			final missing: String = unitsFn == null ? 'caseSiblingUnits_* flattener' : 'caseUnitStructuralBreak_* verdict';
			Context.fatalError('WriterLowering: caseSiblingSymmetry needs the generated $missing', Context.currentPos());
			throw 'unreachable';
		}
		final expandExpr: Expr = caseSiblingUnitExpandExpr(unitsFn);
		final structuralCall: Expr = { expr: ECall(structuralFn, [macro _csUnits[_csS]]), pos: Context.currentPos() };
		final unitProbeCall: Expr = {
			expr: ECall(macro $i{elemFn}, [macro _csUnits[_csK], macro _csOpt]),
			pos: Context.currentPos()
		};
		// omega-case-body-controlflow-glue: emitted ONLY when the element rule's
		// body Star carries `@:fmt(refuseGlueOnControlFlowRoot)` - the same meta
		// that turns the glue into a break. Null (flag absent) drops the arm, so
		// the pre-pass is byte-identical to the width-only one.
		final controlFlowForce: Expr = controlFlowFn == null ? macro {} : {
			final call: Expr = { expr: ECall(controlFlowFn, [macro _csUnits[_csK]]), pos: Context.currentPos() };
			macro if (_csFlat == -1 && $call) {
				_csMax = anyparse.format.BodyFit.SIBLING_FORCE_BREAK;
				break;
			};
		};
		return macro {
			var _csMax: Int = anyparse.format.BodyFit.SIBLING_PROBING;
			if (opt._caseSiblingFlatWidth != anyparse.format.BodyFit.SIBLING_PROBING) {
				_csMax = anyparse.format.BodyFit.SIBLING_NONE;
				if (_arr.length > 0 && $policyGate) {
					final _csUnits = $expandExpr;
					// A one-UNIT list cannot be asymmetric. The pre-slice gate
					// read `_arr.length > 1`; the count is now over EXPANDED
					// units, so a switch whose only element is a `#if` region
					// holding several cases still coordinates.
					if (_csUnits.length > 1) {
						// Structural pass FIRST, and it writes nothing: one unit
						// already below its own label settles the whole switch,
						// so the measuring loop (two writes per element) is
						// skipped entirely for a triggered switch.
						var _csForce: Bool = false;
						var _csS: Int = 0;
						while (_csS < _csUnits.length) {
							if ($structuralCall) {
								_csForce = true;
								break;
							}
							_csS++;
						}
						if (_csForce)
							_csMax = anyparse.format.BodyFit.SIBLING_FORCE_BREAK;
						else {
							final _csOpt = _setCaseSiblingWidth(opt, anyparse.format.BodyFit.SIBLING_PROBING);
							var _csK: Int = 0;
							while (_csK < _csUnits.length) {
								final _csFlat: Int = anyparse.format.wrap.WrapList.flatLength($unitProbeCall);
								// omega-case-body-controlflow-glue: a unit that
								// cannot render flat AND holds a single
								// control-flow statement is refused the glue by
								// `BodyFit.fitLineLayout`, so it renders below its
								// own label — the same verdict the structural pass
								// reaches, but only measurable here.
								$controlFlowForce;
								if (_csFlat > _csMax) _csMax = _csFlat;
								_csK++;
							}
						}
					}
				}
			}
			_csMax;
		};
	}

	/**
	 * ω-if-leader-case-symmetry: the case-UNIT expansion spliced into the
	 * widest-sibling pre-pass. Walks the Star's elements once and yields the
	 * flat unit list — an element the flattener does not recognise (`null`)
	 * stands for itself, a `#if`-guarded region contributes the inner case
	 * elements of every one of its branches.
	 *
	 * `unitsFn` is the generated `caseSiblingUnits_<ElemRule>` predicate. It
	 * answers `null` on the hot path (every plain case of every switch), so
	 * the walk allocates nothing per element and the expansion stays a
	 * single linear AST pass — it re-enters neither the writer nor the
	 * pre-pass, so ω-case-sym-linear is unaffected.
	 */
	private static function caseSiblingUnitExpandExpr(unitsFn: Expr): Expr {
		final unitsCall: Expr = { expr: ECall(unitsFn, [macro _csNode]), pos: Context.currentPos() };
		return macro {
			final _csU = [];
			var _csI: Int = 0;
			while (_csI < _arr.length) {
				final _csNode = _arr[_csI].node;
				final _csNested = $unitsCall;
				if (_csNested == null)
					_csU.push(_csNode);
				else {
					var _csJ: Int = 0;
					while (_csJ < _csNested.length) {
						_csU.push(_csNested[_csJ]);
						_csJ++;
					}
				}
				_csI++;
			}
			_csU;
		};
	}

	/**
	 * The `arrowBodyLineWrap` emit for a lambda body: wrap `bodyCall` in the
	 * `_dwb(_dilr(...))` arrow-body marker, so at render time the body either stays
	 * glued to the arrow (when `BodyFit.arrowGlueThreshold` holds), or — under
	 * `opt.fitLineBodyGlue` on a hardline-free body — is rescued onto the
	 * continuation by `BodyFit.continuationRescuesArrowBody`, or else breaks after
	 * the arrow and nests one level.
	 *
	 * Shared verbatim by the Pratt infix `->` branch (`lowerInfixTightAssign`) and the
	 * bare-Ref field path (`emitBareRefNonBodyPolicy`).
	 */
	private static function arrowBodyLineWrapExpr(bodyCall: Expr): Expr {
		return macro {
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			final _doc: anyparse.core.Doc = $bodyCall;
			final _flat: Int = anyparse.format.wrap.WrapList.flatLength(_doc);
			_dwb(_dilr(
				anyparse.format.BodyFit.arrowGlueThreshold(_doc, opt.lineWidth),
				opt.fitLineBodyGlue && _flat >= 0
					? anyparse.format.BodyFit.continuationRescuesArrowBody(_cols, _doc, _flat, opt.lineWidth)
					: _dn(_cols, _dc([_dhl(), _doc])),
				_doc
			));
		};
	}

	/**
	 * omega-try-brace-symmetry: the leading separator a `catch` takes after a NON-block body. The
	 * unconditional `_dhl()` is haxe-formatter's statement-context convention and stays the default;
	 * naming a `BodyPolicy` knob adds the FitLine escape, so `} catch` cuddles while the line fits and
	 * breaks when it does not — the separator answering the same width question the body's own policy
	 * answers, so the two agree about whether the construct rendered flat.
	 */
	private static function bareSepBreak(policyField: Null<String>, sepExpr: Expr, softSeam: Bool): Expr {
		if (policyField == null) return macro _dhl();
		final policy: Expr = optFieldAccess(policyField);
		// Under `@:fmt(constructFitSep)` the seam is a SOFT line owned by the enclosing construct
		// group, so it breaks with the body's own seam rather than answering for itself. Asking here
		// is what put a flat ` catch` after a body that had already broken, which then squeezed the
		// body's call into a width it had to wrap inside.
		final flatSeam: Expr = softSeam ? macro _dl() : macro _dfle(opt.lineWidth, _dhl(), $sepExpr);
		return macro $policy == anyparse.format.BodyPolicy.FitLine ? $flatSeam : _dhl();
	}

	/**
	 * The `opt` expression threaded into the RIGHT operand's write call of a Pratt
	 * infix branch, or null when the branch flags no fanout.
	 *
	 * ω-arrow-body-objlit-pad: `@:fmt(propagateArrowLambdaBody)` on the infix `->`
	 * branch (HxExpr.ThinArrow) flags the RIGHT operand write. Composed outside
	 * `_setExprPosition` so its descent clear does not wipe the just-set flag. Left
	 * operand passes `opt` unchanged, so the flag survives leftmost descents —
	 * replicating the fork's token-adjacency (`{` directly after `->`) for free.
	 */
	private static function rightOperandOptExpr(branch: ShapeNode): Null<Expr> {
		final rightOptBase: Null<Expr> = branch.fmtHasFlag('propagateExprPosition') ? macro _setExprPosition(opt) : null;
		return branch.fmtHasFlag('propagateArrowLambdaBody') ? macro _setArrowLambdaBody(${rightOptBase ?? macro opt}, opt) : rightOptBase;
	}

}
#end
