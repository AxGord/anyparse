package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.macro.WriterLoweringSupport.*;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;

using anyparse.macro.MetaInspect;

/**
 * Pass 3W - what the grammar says about a referenced rule's CONSTRUCTORS.
 *
 * Every member here asks one question of `shape.rules`: given a rule path,
 * which of its Alt branches answer some shape predicate, and what does each
 * project as a `case` pattern. `branchCtorPattern` is the projection itself
 * (ctor path plus the synth-slot arity `branchSynthExtraArity` computes),
 * `findCtorPattern` the by-name lookup, the five `collect*Patterns` the
 * by-predicate ones, and `leftCurlyTargetCtors` / `spacePrefixCtors` /
 * `ctorHasBodyPolicy` / `findElementBodyField` the name-level answers that
 * need no pattern at all. `buildCurlyBlockCuddleTest` and
 * `buildBracketBodyGlueTest` are the two runtime tests built directly on top
 * of a pattern set, and they live here because nothing else consumes those
 * two collectors.
 *
 * This is a LAYER, not a family, and the measurement that says so is the
 * inbound side: sixteen callers spread over EVERY writer shape family --
 * the Star emitters, both Ref-field halves, the separator builders, the Seq
 * walker and `WriterLowering`'s own constructor. Five sibling modules were
 * already reaching these members through bound closures in their ctx
 * bundles (`_bodyPolicy`, `_ctorBlank`, `_arrowValueIf`, `_braceSym`), which
 * is a layer's signature written down before anyone named it.
 *
 * The dependency surface is three fields wide -- `shape` for the rule table
 * and the two naming helpers that stayed in `WriterLowering` because most of
 * their callers did. Nothing here reads `LoweringCtx` or the format info,
 * and nothing here builds a layout: a member that needed either would belong
 * to a family instead.
 */
@:access(anyparse.macro.WriterLowering, anyparse.macro.WriterLoweringSupport)
final class WriterCtorPatternLowering {

	/**
	 * Find the branch of an Alt-rule whose first source-character is `{`.
	 * Used by the Ref-field leftCurly emission path to gate the runtime
	 * BracePlacement separator on the brace-bearing variant — sibling
	 * branches like `HxFnBody.NoBody` (`@:lit(';')`) leave the separator
	 * suppressed so `function f():Void;` round-trips without an inserted
	 * space.
	 *
	 * Two shapes are recognised:
	 *  - Direct: branch carries `@:lead('{')` itself (Case 4 Star ctor).
	 *  - Indirect via Seq typedef: branch is Case 3 single-Ref wrapping a
	 *    Seq whose first field's `@:lead` opens with `{` (e.g.
	 *    `BlockBody(block:HxFnBlock)` where `HxFnBlock.stmts` carries the
	 *    `@:lead('{')`).
	 *
	 * Returns the ctor's simple name (`'BlockBody'`) or `null` when the
	 * rule is not an Alt or no branch surfaces a `{` lead.
	 */
	private static function leftCurlyTargetCtors(ctx: CtorPatternCtx, refName: String): Array<String> {
		final result: Array<String> = [];
		final node: Null<ShapeNode> = ctx.shape.rules[refName];
		if (node == null || node.kind != Alt) return result;
		for (branch in node.children) {
			final ctor: Null<String> = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (ctor == null) continue;
			final lead: Null<String> = branch.annotations.get(AnnotationKeys.LIT_LEAD_TEXT);
			if (lead != null && lead == '{') {
				result.push(ctor);
				continue;
			}
			if (branch.children.length != 1 || branch.children[0].kind != Ref) continue;
			final innerName: Null<String> = branch.children[0].annotations.get(AnnotationKeys.BASE_REF);
			final innerNode: Null<ShapeNode> = innerName == null ? null : ctx.shape.rules[innerName];
			if (innerNode == null || innerNode.kind != Seq || innerNode.children.length <= 0) continue;
			final firstField: ShapeNode = innerNode.children[0];
			final firstLead: Null<String> = firstField.annotations[AnnotationKeys.LIT_LEAD_TEXT] ?? firstField.readMetaString(':lead');
			if (firstLead != null && firstLead.charAt(0) == '{') result.push(ctor);
		}
		return result;
	}

	/**
	 * List Alt branches of `refName` whose writer output begins with a
	 * sub-rule write (no `@:lit`, no `@:lead`, no `@:kw` lead, and not the
	 * brace-bearing branch already handled by `leftCurlyTargetCtor`).
	 *
	 * Such branches need an inserted ` ` separator at the parent Ref-field
	 * site so the kw of the surrounding rule doesn't butt up against the
	 * sub-rule's first token. The parser's Case 3 (single-Ref, optional
	 * `@:trail`) already inserts `skipWs` before the sub-call; the writer
	 * must produce the symmetric output.
	 *
	 * First consumer: `HxFnBody.ExprBody(expr:HxExpr) @:trail(';')` —
	 * `function foo() trace("hi");`. The space sits between `()` and the
	 * expression. `BlockBody`'s ` `/`\n\t` is owned by `leftCurlySeparator`;
	 * `NoBody`'s `;` wants no preceding space (suppressed via `_de()` in
	 * the runtime switch's default branch).
	 */
	private static function spacePrefixCtors(ctx: CtorPatternCtx, refName: String, lcCtorNames: Array<String>): Array<String> {
		final ctors: Array<String> = [];
		final node: Null<ShapeNode> = ctx.shape.rules[refName];
		if (node == null || node.kind != Alt) return ctors;
		for (branch in node.children) {
			final ctor: Null<String> = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (ctor == null || lcCtorNames.indexOf(ctor) != -1) continue;
			if (branch.annotations.get(AnnotationKeys.LIT_LIT_LIST) != null) continue;
			if (branch.annotations.get(AnnotationKeys.LIT_LEAD_TEXT) != null) continue;
			if (branch.annotations.get(AnnotationKeys.KW_LEAD_TEXT) != null) continue;
			if (branch.annotations.get(AnnotationKeys.PREFIX_OP) != null) continue;
			if (branch.annotations.get(AnnotationKeys.POSTFIX_OP) != null) continue;
			if (branch.annotations.get(AnnotationKeys.PRATT_PREC) != null) continue;
			if (branch.annotations.get(AnnotationKeys.TERNARY_OP) != null) continue;
			if (branch.children.length != 1 || branch.children[0].kind != Ref) continue;
			ctors.push(ctor);
		}
		return ctors;
	}

	/**
	 * Return `true` when the named ctor of `refName`'s Alt enum carries a
	 * ctor-level `@:fmt(bodyPolicy(<flag>))`. Consumed by the Case 5
	 * (Ref + `@:fmt(leftCurly)`) emission site to suppress the parent's
	 * fixed `_dt(' ')` separator for sibling ctors whose own writer
	 * (Case 3 path) wraps the body in `bodyPolicyWrap` and supplies the
	 * kw→body separator runtime-switchably.
	 *
	 * First consumer: `HxFnBody.ExprBody`'s `@:fmt(bodyPolicy('functionBody'))`
	 * (ω-functionBody-policy).
	 */
	private static function ctorHasBodyPolicy(ctx: CtorPatternCtx, refName: String, ctorName: String): Bool {
		final node: Null<ShapeNode> = ctx.shape.rules[refName];
		if (node == null || node.kind != Alt) return false;
		for (branch in node.children) if (branch.annotations.get(AnnotationKeys.BASE_CTOR) == ctorName)
			return branch.fmtReadStringArgs('bodyPolicy') != null;
		return false;
	}

	/**
	 * Walk `bodyTypePath`'s rule (expected to be an `Alt`) and collect
	 * `case` patterns for branches that render via `blockBody` — i.e.
	 * enum ctors declared with `@:lead(open) @:trail(close)` on a single
	 * `Star` child. Returns an empty array when `bodyTypePath` is not an
	 * enum, has no such branches, or is absent from the shape map.
	 */
	private static function collectBlockCtorPatterns(ctx: CtorPatternCtx, bodyTypePath: String): Array<Expr> {
		final rule: Null<ShapeNode> = ctx.shape.rules[bodyTypePath];
		return rule == null || rule.kind != Alt ? [] : [
			for (branch in rule.children) if (isBlockCtorBranch(branch)) branchCtorPattern(ctx, bodyTypePath, branch)
		];
	}

	/**
	 * ω-same-on-block — the two halves `collectBlockCtorPatterns` returns as
	 * one set, split by the delimiter its branch opens with.
	 * `SameLinePolicy.SameOnBlock` promises a cuddle after a `}` and nothing
	 * else, so the shape-aware separator needs the two halves as separate
	 * switch arms; `collectBlockCtorPatterns` itself is unchanged and still
	 * serves every caller that only asks "does this branch render as a
	 * block".
	 */
	private static function collectCurlyBlockCtorPatterns(ctx: CtorPatternCtx, bodyTypePath: String): Array<Expr> {
		final rule: Null<ShapeNode> = ctx.shape.rules[bodyTypePath];
		return rule == null || rule.kind != Alt ? [] : [
			for (branch in rule.children) if (isCurlyBlockCtorBranch(branch)) branchCtorPattern(ctx, bodyTypePath, branch)
		];
	}

	private static function collectNonCurlyBlockCtorPatterns(ctx: CtorPatternCtx, bodyTypePath: String): Array<Expr> {
		final rule: Null<ShapeNode> = ctx.shape.rules[bodyTypePath];
		return rule == null || rule.kind != Alt ? [] : [
			for (branch in rule.children)
				if (isBlockCtorBranch(branch) && !isCurlyBlockCtorBranch(branch)) branchCtorPattern(ctx, bodyTypePath, branch)
		];
	}

	private static function collectBlockShapeEquivalentPatterns(ctx: CtorPatternCtx, bodyTypePath: String): Array<Expr> {
		final rule: Null<ShapeNode> = ctx.shape.rules[bodyTypePath];
		return rule == null || rule.kind != Alt ? [] : [
			for (branch in rule.children) if (isBlockShapeEquivalentBranch(branch)) branchCtorPattern(ctx, bodyTypePath, branch)
		];
	}

	/**
	 * ω-block-shape-aware — find the field name of the bare-Ref child on
	 * `elemTypePath`'s Seq rule whose Ref points at `bodyTypePath`. Used by
	 * the Star sameLine handler to wire shape-awareness on subsequent
	 * iterations: each catch element after the first checks the previous
	 * element's body shape (`_arr[_si - 1].<field>`) against the prev
	 * body's block ctors. Returns `null` when the element is not a Seq,
	 * has no matching Ref child, or the matching child is not a bare Ref
	 * (Star / optional fields are skipped — they don't carry the body
	 * directly).
	 */
	private static function findElementBodyField(ctx: CtorPatternCtx, elemTypePath: String, bodyTypePath: String): Null<String> {
		final rule: Null<ShapeNode> = ctx.shape.rules[elemTypePath];
		if (rule == null || rule.kind != Seq) return null;
		for (child in rule.children) if (child.kind == Ref && child.annotations.get(AnnotationKeys.BASE_OPTIONAL) != true) {
			final ref: Null<String> = child.annotations.get(AnnotationKeys.BASE_REF);
			if (ref == bodyTypePath) return child.annotations.get(AnnotationKeys.BASE_FIELD_NAME);
		}
		return null;
	}

	/**
	 * omega-bracket-body-glue: the BRACKET counterpart of
	 * `collectBlockCtorPatternsByLeftCurly` — every `[ … ]` block ctor of
	 * `bodyTypePath`, as `case` patterns. Unsplit, because the `leftCurly`
	 * knob has no bracket sibling: a `[` body has exactly one placement, glued
	 * to the head, and the FLAG decides whether it is taken at all.
	 */
	private static function collectBracketBlockCtorPatterns(ctx: CtorPatternCtx, bodyTypePath: String): Array<Expr> {
		final rule: Null<ShapeNode> = ctx.shape.rules[bodyTypePath];
		return rule == null || rule.kind != Alt ? [] : [
			for (branch in rule.children) if (isBracketBlockCtorBranch(branch)) branchCtorPattern(ctx, bodyTypePath, branch)
		];
	}

	/**
	 * ω-same-on-block — the curly sibling of `buildBracketBodyGlueTest`: true at
	 * runtime when the gap policy named by `sameLineFlag` is `SameOnBlock` AND
	 * the body value is a CURLY block ctor, i.e. exactly when the shape-aware
	 * separator is about to join `}` to the following keyword. The one consumer
	 * is `semicolonBeforeSiblingWrap`, which drops the optional `;` in that
	 * state — `}; else` is not a join. `null` (inert) when the grammar passes no
	 * flag name, or when the body type has no curly block ctor, so every other
	 * field keeps its bytes.
	 */
	private static function buildCurlyBlockCuddleTest(
		ctx: CtorPatternCtx, sameLineFlag: Null<String>, bodyTypePath: Null<String>, bodyValueExpr: Expr
	): Null<Expr> {
		if (sameLineFlag == null || bodyTypePath == null) return null;
		final patterns: Array<Expr> = collectCurlyBlockCtorPatterns(ctx, bodyTypePath);
		if (patterns.length == 0) return null;
		final flagAccess: Expr = optFieldAccess(sameLineFlag);
		final sameOnBlock: Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'SameLinePolicy', 'SameOnBlock']);
		final ctorTest: Expr = {
			expr: ESwitch(bodyValueExpr, [{ values: patterns, expr: macro true, guard: null }], macro false),
			pos: Context.currentPos()
		};
		return macro $flagAccess == $sameOnBlock && $ctorTest;
	}

	/**
	 * omega-bracket-body-glue: the runtime test that substitutes `Same` for the
	 * resolved policy — `opt.<flagName>` AND the body's runtime ctor is one of
	 * the body type's `[ … ]` block ctors. Null when the field carries no
	 * `@:fmt(bracketBodyGlueIfFlag(...))`, or when the body type has no bracket
	 * block ctor at all, so every other grammar and every other field keep their
	 * bytes.
	 *
	 * One core for all THREE seams the knob owns — the body placement
	 * (`bodyPolicyWrap`), the branch terminator (`semicolonBeforeSiblingWrap`) and
	 * the pre-`else` gap (`beforeKwSeparator`) — so a grammar that opts one field
	 * in cannot get a different answer from another. The last two are the CLOSE
	 * side of the hug: a `[` glued to its branch head is only half a shape while
	 * the matching `]` is left alone on its line by a `;` the source wrote and a
	 * source-preserving `Keep` gap.
	 */
	private static function buildBracketBodyGlueTest(
		ctx: CtorPatternCtx, args: Null<Array<String>>, bodyTypePath: Null<String>, bodyValueExpr: Expr
	): Null<Expr> {
		if (args == null || bodyTypePath == null) return null;
		if (args.length != 1)
			Context.fatalError(
				'WriterLowering: @:fmt(${WriterLowering.BRACKET_BODY_GLUE}) requires 1 string arg (flagName), got ${args.length} args',
				Context.currentPos()
			);
		final patterns: Array<Expr> = collectBracketBlockCtorPatterns(ctx, bodyTypePath);
		if (patterns.length == 0) return null;
		final flagAccess: Expr = optFieldAccess(args[0]);
		final ctorTest: Expr = {
			expr: ESwitch(bodyValueExpr, [{ values: patterns, expr: macro true, guard: null }], macro false),
			pos: Context.currentPos()
		};
		return macro $flagAccess && $ctorTest;
	}

	private static function branchCtorPattern(ctx: CtorPatternCtx, bodyTypePath: String, branch: ShapeNode): Expr {
		final ctorName: String = branch.annotations[AnnotationKeys.BASE_CTOR];
		final arity: Int = branch.children.length + branchSynthExtraArity(ctx, bodyTypePath, branch);
		final ctorPath: Array<String> = ctx.ruleCtorPath(bodyTypePath, ctorName);
		final ctorRef: Expr = MacroStringTools.toFieldExpr(ctorPath);
		return if (arity == 0)
			ctorRef
		else {
			final args: Array<Expr> = [for (_ in 0...arity) macro _];
			{ expr: ECall(ctorRef, args), pos: Context.currentPos() };
		};
	}

	/**
	 * Synth-pair Alt branches grow positional args beyond `children.length`
	 * in trivia mode (closeTrailing, openTrailing, trailPresent, sourceText).
	 * Wildcard patterns must include matching `_` slots for each, otherwise
	 * arity mismatches the synth ctor at compile time. Returns 0 when the
	 * body is not trivia-bearing or the branch shape adds no extra args.
	 */
	private static function branchSynthExtraArity(ctx: CtorPatternCtx, bodyTypePath: String, branch: ShapeNode): Int {
		if (!ctx.isTriviaBearing(bodyTypePath)) return 0;
		var extras: Int = 0;
		if (TriviaPairAltCtor.isAltCloseTrailingBranch(branch)) {
			extras++;
			if (branch.readMetaString(':lead') != null && !branch.hasMeta(':tryparse')) extras++;
		}
		if (TriviaPairAltCtor.isAltTrailOptBranch(branch)) extras++;
		if (TriviaPairAltCtor.isCaptureSourceBranch(branch)) extras++;
		return extras;
	}

	/**
	 * Build a wildcard `case` pattern for the named ctor of a polymorphic
	 * enum type. Returns `null` when the type is not an enum in the shape
	 * map or has no branch with the requested name — the caller then
	 * skips the ctor-specific override.
	 *
	 * Used by the ψ₈ `@:fmt(elseIf)` path to target the `IfStmt(_)` ctor of
	 * `HxStatement` when rendering the `else` body of `HxIfStmt`.
	 */
	private static function findCtorPattern(ctx: CtorPatternCtx, bodyTypePath: String, ctorName: String): Null<Expr> {
		final rule: Null<ShapeNode> = ctx.shape.rules[bodyTypePath];
		if (rule == null || rule.kind != Alt) return null;
		for (branch in rule.children) {
			final branchCtor: String = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (branchCtor != ctorName) continue;
			final arity: Int = branch.children.length + branchSynthExtraArity(ctx, bodyTypePath, branch);
			final ctorPath: Array<String> = ctx.ruleCtorPath(bodyTypePath, branchCtor);
			final ctorRef: Expr = MacroStringTools.toFieldExpr(ctorPath);
			return if (arity == 0)
				ctorRef
			else {
				final args: Array<Expr> = [for (_ in 0...arity) macro _];
				{ expr: ECall(ctorRef, args), pos: Context.currentPos() };
			};
		}
		return null;
	}

}

/**
 * The build state the ctor-pattern queries read, bundled once per
 * `WriterLowering` instance.
 *
 * One data field -- `shape`, for the `rules` table every member opens with --
 * and two shape-name helpers that stayed behind. The bundle IS the dependency
 * surface: a member here that needs a layout decision, a `LoweringCtx` or the
 * format info has to widen this literal, which is one visible edit in that
 * constructor and the signal that it stopped being a lookup.
 */
typedef CtorPatternCtx = {
	final shape: ShapeBuilder.ShapeResult;
	final isTriviaBearing: (refName:String) -> Bool;
	final ruleCtorPath: (typePath:String, ctor:String) -> Array<String>;
}
#end
