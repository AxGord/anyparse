package anyparse.macro;

#if macro
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;
import anyparse.macro.WriterLoweringSupport.*;

using Lambda;
using anyparse.macro.MetaInspect;

/**
 * Pass 3W helpers - the arrow-value-`if` re-flow family.
 *
 * One `@:fmt` feature, whole: `@:fmt(arrowValueIfReflow)` lets a value-`if`
 * chain that is the body of an arrow lambda (and, under the optional fourth
 * knob, any value-`if` in expression position) collapse onto one line
 * instead of taking the body policy's layout. The decision is a runtime
 * gate the macro splices into the branch body, and everything here builds a
 * piece of it: the spine walk that proves the whole chain is comment-clean,
 * the branch-count cap, the per-child comment-slot probes, and the
 * `_aifBlocked` propagation that carries a refusal down into nested
 * members.
 *
 * Split out of `WriterLowering` for size. The family is a LEAF of that
 * module's call graph - three entries (`arrowValueIfReflowWrap` from the
 * struct lowering, `arrowValueIfBlockOpt` from the two Ref emit sites that
 * descend into a branch) and nothing else reaches in.
 *
 * Every member is static and the build state arrives as one
 * `ArrowValueIfCtx` bundle, built once in `WriterLowering`'s constructor.
 * The bundle IS the dependency surface: two data fields (`shape`, `ctx`)
 * and the three shape-name helpers whose other callers stayed behind.
 *
 * `WriterLowering.ARROW_VALUE_IF_SITE` stays there: it is the spelling of
 * the per-field opt-in flag, read at four sites of which only one is here.
 *
 * The GENERATED-code surface is the real contract. `arrowValueIfReflowWrap`
 * DECLARES `_aifReflow`, `_aifBlocked` and `_aifClean` in the branch body;
 * `arrowValueIfPolicy` (in `WriterBodyPolicyLowering`) and
 * `arrowValueIfBlockOpt` READ them. Move a gate on one side only and the
 * generated writer reads an undeclared local, with nothing in either
 * module's types to catch it.
 */
@:access(anyparse.macro.WriterLoweringSupport)
final class WriterArrowValueIfLowering {

	/** `@:fmt(arrowValueIfReflow)` arg count that carries the optional value-if FIT knob as its 4th arg. */
	private static inline final FIT_KNOB_ARG_COUNT: Int = 4;

	/**
	 * omega-arrow-value-if-reflow - struct-level wrap for a type carrying
	 * `@:fmt(arrowValueIfReflow('<knobField>', '<spineField>', '<spineCtor>'))`
	 * (sole consumer: `HxIfExpr`).
	 *
	 * Emits two things around the struct's assembled Doc:
	 *
	 *  - the gate locals, declared BEFORE the Doc is built so the field-level
	 *    sites inside it (`arrowValueIfPolicy` on both branches, the pre-`else`
	 *    gap in `beforeKwSeparator`, `arrowValueIfBlockOpt` on both branch
	 *    opt-fanouts) read one runtime answer. `_aifReflow` fires when the
	 *    config knob is on, the node sits in an arrow-lambda body
	 *    (`opt._inArrowLambdaBody`), no ANCESTOR member of the chain already
	 *    refused (`opt._arrowValueIfBlocked`), and no member from here DOWN the
	 *    `else`-spine carries a captured comment;
	 *  - a `Group` around the whole node, which turns the soft `Line` before
	 *    each `else` into the chain's single flat-vs-broken decision.
	 *
	 * The Group is gated on `!opt._inValueIfBranch`, which is what
	 * distinguishes the OUTERMOST chain member from the nested `else if (...)`
	 * ones: the arrow body's opt has the flag cleared (`_setExprPosition` runs
	 * on the way in), while every `else`-branch descent sets it via
	 * `propagateValueIfBranch`. So one group spans the whole chain and the
	 * nested members contribute only their soft `Line`s - nested groups would
	 * let an inner `else if ... else ...` tail re-join while the outer broke.
	 *
	 * The group is NOT additionally gated on the Doc being able to render flat.
	 * A body that cannot (a `{ ... }` branch) makes the group commit to its
	 * break branch, which is the same output the bare soft `Line`s would give -
	 * while skipping the group would ALSO skip nothing, since the forced-`Same`
	 * policies and the soft separators are already in the Doc by then. The
	 * earlier `flatLength != -1` conjunct was measured to cost `} else {`
	 * cuddling on block-bodied branches for no gain.
	 *
	 * Returns `dcExpr` untouched for every type without the meta.
	 */
	private static function arrowValueIfReflowWrap(ac: ArrowValueIfCtx, node: ShapeNode, dcExpr: Expr): Expr {
		final args: Null<Array<String>> = node.fmtReadStringArgs('arrowValueIfReflow');
		if (args == null) return dcExpr;
		if (args.length != 3 && args.length != FIT_KNOB_ARG_COUNT)
			Context.fatalError(
				'WriterLowering: @:fmt(arrowValueIfReflow) expects 3 or 4 string args (knobField, spineField, spineCtor'
				+ ', [fitKnobField]), got ${args.length}',
				Context.currentPos()
			);
		final knobAccess: Expr = optFieldAccess(args[0]);
		// omega-value-if-fit: the optional 4th arg names the sibling knob that re-flows EVERY
		// value-if rather than only an arrow body. Absent, the local folds to a constant `false` and
		// every expression below collapses to the arrow-only shape, so a 3-arg site stays byte-inert.
		final fitAccess: Expr = args.length == FIT_KNOB_ARG_COUNT ? optFieldAccess(args[3]) : macro false;
		final spineCleanExpr: Expr = arrowValueIfSpineCleanExpr(ac, node, args[1], args[2]);
		final branchCapExpr: Expr = arrowValueIfBranchCapExpr(ac, node, args[1], args[2]);
		return macro {
			final _aifGate: Bool = $knobAccess && opt._inArrowLambdaBody;
			// The arrow gate is checked FIRST and excludes the fit gate: a chain in an arrow body
			// under both knobs keeps the arrow shape (branch values glued to their conditions),
			// the more specific answer for that position.
			final _vifGate: Bool = !_aifGate && $fitAccess && opt._inExprPosition;
			final _anyGate: Bool = _aifGate || _vifGate;
			// ONE spine walk for both gates -- short-circuited by `_anyGate`, so a file compiled with
			// neither knob never runs it. `_aifReflow` keeps its exact old value when the fit knob is
			// off, since `_vifGate` is then false and `_anyGate` collapses to `_aifGate`.
			final _aifClean: Bool = _anyGate && !opt._arrowValueIfBlocked && !opt._arrowValueIfElemTrailComment && $spineCleanExpr;
			final _aifReflow: Bool = _aifGate && _aifClean;
			// The cap refuses the chain as a WHOLE: `_aifBlocked` below turns a refusal here into a
			// refusal for every nested member, so a capped 3-branch chain cannot render with its
			// 2-branch tail collapsed and its head in policy layout.
			final _vifFit: Bool = _vifGate && _aifClean && $branchCapExpr;
			// Two comment positions live outside the node: one on the branch
			// VALUE's own slot (a call's `closeTrailing`), which the spine walk
			// now asks for, and one on the enclosing list element, which arrives
			// as `_arrowValueIfElemTrailComment`. Both sit after the chain's LAST
			// value, where the node has no field of its own left to carry them.
			//
			// The refusal is chain-wide in BOTH directions: the spine walk above
			// covers a comment on this member or any member below it, and
			// `_aifBlocked` (read by `arrowValueIfBlockOpt` on the branch
			// descents) carries the verdict down to members the walk already
			// judged, so an ANCESTOR's comment reaches them too. Only ever true
			// with the knob ON, so the OFF path is byte-inert.
			final _aifBlocked: Bool = _anyGate && !_aifReflow && !_vifFit;
			final _aifDoc: anyparse.core.Doc = $dcExpr;
			(_aifReflow || _vifFit) && !opt._inValueIfBranch ? _dg(_aifDoc) : _aifDoc;
		};
	}

	/**
	 * omega-arrow-value-if-reflow - the no-comment gate, decided over the whole
	 * `else`-SPINE rather than over this node alone.
	 *
	 * A comment sits on ONE member of an `else if` chain, but each member runs
	 * its own copy of this gate, so a per-node answer splits the chain: the
	 * member holding the comment keeps its policy shape while the rest re-flows,
	 * and the output carries both forms at once. The model already carries the
	 * spine - the optional `<spineField>` is the next member wrapped in the
	 * `<spineCtor>` constructor - so the walk asks every member from here down
	 * and folds one answer.
	 *
	 * Emitted as an iterative walk rather than a recursive helper because the
	 * generated writer has no place to hang a per-type static: the cursor starts
	 * at `value` and the spine constructor's payload has that same type, so the
	 * reassignment types itself with no annotation. `break` inside the `switch`
	 * leaves the LOOP (Haxe `switch` has no fallthrough), which is how a
	 * non-`<spineCtor>` tail ends the walk.
	 *
	 * Plain (non-trivia) mode captures no comments and synthesises no slots, so
	 * `arrowValueIfNoCommentExpr` degrades to `true` and the walk with it.
	 */
	private static function arrowValueIfSpineCleanExpr(ac: ArrowValueIfCtx, node: ShapeNode, spineField: String, spineCtor: String): Expr {
		final ownClean: Expr = arrowValueIfNoCommentExpr(ac, node, macro _aifCur);
		final spineNode: Null<ShapeNode> = findFieldByName(node, spineField);
		if (spineNode == null)
			Context.fatalError(
				'WriterLowering: @:fmt(arrowValueIfReflow) spineField "$spineField" not found on the struct', Context.currentPos()
			);
		final spineRef: Null<String> = spineNode.annotations.get(AnnotationKeys.BASE_REF);
		final capture: Null<Expr> = spineRef == null ? null : ctorCapturePattern(ac, spineRef, spineCtor, '_aifInner');
		if (capture == null) return macro {
			final _aifCur = value;
			$ownClean;
		};
		final spineAccess: Expr = { expr: EField(macro _aifCur, spineField), pos: Context.currentPos() };
		final stepCases: Array<Case> = [
			{ values: [capture], expr: macro _aifCur = _aifInner, guard: null },
			{ values: [macro _], expr: macro break, guard: null }
		];
		final stepSwitch: Expr = { expr: ESwitch(macro _aifNext, stepCases, null), pos: Context.currentPos() };
		return macro {
			var _aifCur = value;
			var _aifClean: Bool = true;
			while (true) {
				if (!$ownClean) {
					_aifClean = false;
					break;
				}
				final _aifNext = $spineAccess;
				if (_aifNext == null) break;
				$stepSwitch;
			}
			_aifClean;
		};
	}

	/**
	 * omega-value-if-fit branch cap - the runtime gate `_vifFit` folds in: true when no cap is
	 * configured, else the chain's branch count measured against it.
	 *
	 * A SECOND spine walk, deliberately not folded into `arrowValueIfSpineCleanExpr` -- that one runs
	 * under `_anyGate` (either knob), while the count must run only when the fit knob is on AND a cap
	 * is set, which the `||` short-circuit here gives it for free. Folding them would pay the count on
	 * every arrow-knob file for an answer nothing reads.
	 */
	private static function arrowValueIfBranchCapExpr(ac: ArrowValueIfCtx, node: ShapeNode, spineField: String, spineCtor: String): Expr {
		final countExpr: Expr = arrowValueIfBranchCountExpr(ac, node, spineField, spineCtor);
		return macro opt.expressionIfFitMaxBranches <= 0 || $countExpr <= opt.expressionIfFitMaxBranches;
	}

	/**
	 * omega-value-if-fit branch cap - counts the VALUE BRANCHES of an `else`-spine: `if (c) a else b`
	 * is 2, `if (c) a else if (d) b else e` is 3, and a trailing-`else`-less `if (c) a else if (d) b`
	 * is 2 as well.
	 *
	 * Same iterative spine walk as `arrowValueIfSpineCleanExpr` (see there for why it is emitted
	 * inline rather than as a per-type static): one member per `if` keyword, plus one for the final
	 * `else` value when the innermost member has an `else` that is not itself a chain member. A
	 * grammar whose spine field cannot be captured answers from the direct sibling alone, which is
	 * the no-chain shape and therefore the layout-preserving direction.
	 */
	private static function arrowValueIfBranchCountExpr(ac: ArrowValueIfCtx, node: ShapeNode, spineField: String, spineCtor: String): Expr {
		final spineNode: Null<ShapeNode> = findFieldByName(node, spineField);
		if (spineNode == null) return macro 1;
		final spineAccess: Expr = { expr: EField(macro _vifCur, spineField), pos: Context.currentPos() };
		final spineRef: Null<String> = spineNode.annotations.get(AnnotationKeys.BASE_REF);
		final capture: Null<Expr> = spineRef == null ? null : ctorCapturePattern(ac, spineRef, spineCtor, '_vifInner');
		if (capture == null) {
			final directAccess: Expr = { expr: EField(macro value, spineField), pos: Context.currentPos() };
			return macro $directAccess != null ? 2 : 1;
		}
		final stepCases: Array<Case> = [
			{
				values: [capture],
				expr: macro {
					_vifCur = _vifInner;
					_vifN++;
				},
				guard: null
			},
			{ values: [macro _], expr: macro break, guard: null }
		];
		final stepSwitch: Expr = { expr: ESwitch(macro _vifNext, stepCases, null), pos: Context.currentPos() };
		return macro {
			var _vifCur = value;
			var _vifN: Int = 1;
			while (true) {
				final _vifNext = $spineAccess;
				if (_vifNext == null) break;
				$stepSwitch;
			}
			$spineAccess != null ? _vifN + 1 : _vifN;
		};
	}

	/**
	 * omega-arrow-value-if-reflow - `findCtorPattern` with a BINDING in the
	 * first constructor slot instead of a wildcard, so the spine walk can step
	 * onto the payload it just matched. Every remaining slot stays `_`.
	 */
	private static function ctorCapturePattern(
		ac: ArrowValueIfCtx, bodyTypePath: String, ctorName: String, captureName: String
	): Null<Expr> {
		final rule: Null<ShapeNode> = ac.shape.rules[bodyTypePath];
		if (rule == null || rule.kind != Alt) return null;
		for (branch in rule.children) {
			final branchCtor: String = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (branchCtor != ctorName) continue;
			final arity: Int = branch.children.length + ac.branchSynthExtraArity(bodyTypePath, branch);
			if (arity == 0) return null;
			final ctorRef: Expr = MacroStringTools.toFieldExpr(ac.ruleCtorPath(bodyTypePath, branchCtor));
			final ctorArgs: Array<Expr> = [macro $i{captureName}].concat([for (_ in 1...arity) macro _]);
			return { expr: ECall(ctorRef, ctorArgs), pos: Context.currentPos() };
		}
		return null;
	}

	/**
	 * omega-arrow-value-if-reflow - the no-comment half of the `_aifReflow`
	 * gate: an AND-fold over every trivia slot of `node` that can hold a
	 * captured comment, so a chain carrying one refuses the reflow.
	 *
	 * The slot set is derived from the same three predicates
	 * `TriviaTypeSynth` gates the slots themselves on, rather than from a
	 * hand-listed field name per grammar: an optional-kw field owns the four
	 * kw-gap slots (`AfterKw` / `KwLeading` / `BeforeKwLeading` /
	 * `BeforeKwTrailing`), a bare non-first Ref owns `BeforeLeading`, and a
	 * `@:trail`-bearing Ref owns `AfterTrail`. For `HxIfExpr` that is exactly
	 * the six places a `//` can sit inside `if (c) a else b`.
	 *
	 * Plain (non-trivia) mode captures no comments and synthesises no slots,
	 * so the fold degrades to `true`.
	 */
	private static function arrowValueIfNoCommentExpr(ac: ArrowValueIfCtx, node: ShapeNode, rootExpr: Expr): Expr {
		if (!ac.ctx.trivia) return macro true;
		final pos: Position = Context.currentPos();
		var pred: Expr = macro true;
		for (child in node.children) {
			final fieldName: Null<String> = child.annotations.get(AnnotationKeys.BASE_FIELD_NAME);
			if (fieldName == null) continue;
			for (slot in arrowValueIfCommentSlots(child, node)) {
				final access: Expr = { expr: EField(rootExpr, fieldName + slot.suffix), pos: pos };
				pred = slot.isList ? macro $pred && $access.length == 0 : macro $pred && $access == null;
			}
			final valueClean: Expr = arrowValueIfValueTrailCleanExpr(ac, child, rootExpr);
			pred = macro $pred && $valueClean;
		}
		return pred;
	}

	/**
	 * omega-arrow-value-if-reflow - the comment position the slot fold above
	 * cannot reach: one captured on the branch VALUE itself
	 * (`else tokenError() // handlers`).
	 *
	 * A trailing comment lands on the LAST node that can hold it, so which
	 * slot owns it depends on what the branch value is. A literal owns none,
	 * and the comment travels up to the enclosing list element - that half is
	 * `_arrowValueIfElemTrailComment`'s. A call owns one: the `closeTrailing`
	 * synth param every trivia-collecting postfix Star gets, which its own
	 * writer re-emits through `trailingCommentDocGuarded`. The `if` node holds
	 * only the branch's Ref, so this half asks the VALUE.
	 *
	 * Emitted as a switch over the branch type's Alt, one case per ctor that
	 * owns the slot (`Call` alone, for `HxExpr`) - the ctor arity comes from
	 * the shape, so a synth-param change is a compile error here rather than a
	 * silent wrong-slot read. Degrades to `true` for a non-Alt / non-trivia
	 * branch and for plain mode, which synthesises no slots at all.
	 */
	@:access(anyparse.macro.TriviaTypeSynth)
	private static function arrowValueIfValueTrailCleanExpr(ac: ArrowValueIfCtx, child: ShapeNode, rootExpr: Expr): Expr {
		final fieldName: Null<String> = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		final refPath: Null<String> = child.kind == Ref ? child.annotations[AnnotationKeys.BASE_REF] : null;
		if (fieldName == null || refPath == null || !ac.isTriviaBearing(refPath)) return macro true;
		final rule: Null<ShapeNode> = ac.shape.rules[refPath];
		if (rule == null || rule.kind != Alt) return macro true;
		final pos: Position = Context.currentPos();
		final cases: Array<Case> = [];
		for (branch in rule.children) {
			final trailIndex: Int = altCloseTrailingParamIndex(branch);
			if (trailIndex < 0) continue;
			final ctorRef: Expr = MacroStringTools.toFieldExpr(ac.ruleCtorPath(refPath, branch.annotations.get(AnnotationKeys.BASE_CTOR)));
			final arity: Int = branch.children.length + TriviaTypeSynth.countAltExtras(branch);
			final args: Array<Expr> = [for (i in 0...arity) i == trailIndex ? macro _aifValueTrail : macro _];
			cases.push({
				values: [{ expr: ECall(ctorRef, args), pos: pos }],
				expr: macro _aifValueTrail == null,
				guard: null
			});
		}
		if (cases.length == 0) return macro true;
		final access: Expr = { expr: EField(rootExpr, fieldName), pos: pos };
		final switchExpr: Expr = { expr: ESwitch(access, cases, macro true), pos: pos };
		// An optional branch is `Null<T>`, and a `case _` default does NOT catch
		// null - the guard is what keeps the switch off a null subject.
		return macro $access == null ? true : $switchExpr;
	}

	/**
	 * omega-arrow-value-if-reflow - index of the `closeTrailing:Null<String>`
	 * synth param on an Alt branch, or `-1` when the branch owns none. The slot
	 * exists exactly for a postfix Star that collects trivia (the gate
	 * `lowerPostfixTailExpr` reads it under), and the synth params follow the
	 * declared ones, so the first of them sits at the child count.
	 */
	private static function altCloseTrailingParamIndex(branch: ShapeNode): Int {
		final postfixOp: Null<String> = branch.annotations[AnnotationKeys.POSTFIX_OP];
		if (postfixOp == null || branch.children.length == 0) return -1;
		final star: ShapeNode = branch.children[branch.children.length - 1];
		return star.kind != Star || star.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] != true ? -1 : branch.children.length;
	}

	/**
	 * omega-arrow-value-if-reflow - the comment-bearing trivia slots `child`
	 * owns, as `(suffix, isList)` pairs. `isList` picks the emptiness test:
	 * an `Array<String>` slot is empty at `length == 0`, a `Null<String>` one
	 * at `null`. Mirrors `TriviaTypeSynth`'s own synth gates.
	 */
	@:access(anyparse.macro.TriviaTypeSynth)
	private static function arrowValueIfCommentSlots(child: ShapeNode, node: ShapeNode): Array<{ suffix: String, isList: Bool }> {
		final slots: Array<{ suffix: String, isList: Bool }> = [];
		if (TriviaTypeSynth.isOptionalKw(child)) {
			slots.push({ suffix: TriviaTypeSynth.AFTER_KW_SUFFIX, isList: false });
			slots.push({ suffix: TriviaTypeSynth.KW_LEADING_SUFFIX, isList: true });
			slots.push({ suffix: TriviaTypeSynth.BEFORE_KW_LEADING_SUFFIX, isList: true });
			slots.push({ suffix: TriviaTypeSynth.BEFORE_KW_TRAILING_SUFFIX, isList: false });
		}
		if (TriviaTypeSynth.isBareNonFirstRef(child, node)) slots.push({ suffix: TriviaTypeSynth.BEFORE_LEADING_SUFFIX, isList: true });
		if (TriviaTypeSynth.isTrailRef(child)) slots.push({ suffix: TriviaTypeSynth.AFTER_TRAIL_SUFFIX, isList: false });
		return slots;
	}

	/**
	 * omega-arrow-value-if-reflow - branch opt-fanout arm for a body field
	 * carrying `@:fmt(arrowValueIfReflowSite)`.
	 *
	 * The spine walk gives each member a verdict over ITSELF AND EVERYTHING
	 * BELOW it, which settles a comment on a DESCENDANT. A comment on an
	 * ANCESTOR is the other direction and the model has no upward link, so the
	 * refusing member stamps `_arrowValueIfBlocked` on its branch writes and
	 * every deeper member reads it. With both halves the chain has exactly one
	 * verdict wherever the comment sits.
	 *
	 * The signal is its own opt field: clearing the shared `_inArrowLambdaBody`
	 * instead would also switch off the object-literal arrow knobs inside the
	 * refused branch, which is a different feature answering a different
	 * question.
	 *
	 * Returns `optExpr` unchanged for every field without the flag, and
	 * `_aifBlocked` is only ever true with the knob on, so both the flagless
	 * sites and the default config are byte-inert.
	 *
	 * `optExpr` MUST be a chain rooted at the generated writer function's own
	 * `opt` — the shim is passed `opt` as its `chainBaseArg`, which lets it
	 * mutate an already-cloned link in place. A caller that hands in a chain
	 * rooted anywhere else would let it mutate an opt someone else still holds.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function arrowValueIfBlockOpt(child: ShapeNode, optExpr: Expr): Expr {
		return child.fmtHasFlag(WriterLowering.ARROW_VALUE_IF_SITE)
			? macro (_aifBlocked ? _setArrowValueIfBlocked($optExpr, opt) : $optExpr)
			: optExpr;
	}

}

/**
 * The build state the arrow-value-`if` family reads, bundled once per
 * `WriterLowering` instance.
 *
 * The three function fields are shape-name helpers that stayed in
 * `WriterLowering` because most of their callers did; handing them over as
 * fields is what keeps every member here static.
 */
typedef ArrowValueIfCtx = {
	final shape: ShapeBuilder.ShapeResult;
	final ctx: LoweringCtx;
	final isTriviaBearing: (refName:String) -> Bool;
	final ruleCtorPath: (typePath:String, ctor:String) -> Array<String>;
	final branchSynthExtraArity: (bodyTypePath:String, branch:ShapeNode) -> Int;
}
#end
