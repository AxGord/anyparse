package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.macro.WriterLowering.AltSlot;
import haxe.macro.Context;
import haxe.macro.Expr;

using StringTools;
using Lambda;
using anyparse.macro.MetaInspect;

/**
 * Pass 3W — the shared writer-lowering vocabulary.
 *
 * Everything the writer half of the macro says about a grammar node
 * BEFORE it decides a layout: how to reach a field on the generated
 * `value` (`optFieldAccess` and the `before*Access` trivia-slot
 * readers, the `AltSlot` index arithmetic), how to spell a `Doc`
 * constructor call (`dcCall`, `makeWriteCall`), how to read a
 * `@:fmt(...)` argument (`firstFmtFlag`, `fmtReadCall`,
 * `fmtFirstStringArg`, `fmtSingleStringArg`, `ctorBranchHasFlag`,
 * `readBodyPolicyDual`), and the small shape predicates every family
 * asks (`hasPrattBranch`, `isBlockCtorBranch`, `isBareTryparseStar`).
 *
 * Extracted from `WriterLowering` because it is a LAYER, not a family:
 * `optFieldAccess` alone had a fan-in of 46 there, and four sibling
 * modules already reached in for it through `@:access`. Its callers
 * spell these names unqualified — `import
 * anyparse.macro.WriterLoweringSupport.*;` plus a class-level
 * `@:access` is what keeps every call site verbatim across the move,
 * and is why the members stayed private rather than being widened.
 *
 * Every member is static: nothing here reads a build's `_shape` /
 * `_formatInfo` / `LoweringCtx`, which is exactly what made this the
 * layer that could leave.
 */
final class WriterLoweringSupport {

	/**
	 * Build the field-access Expr `opt.<fieldName>` — used everywhere the
	 * generated writer reads a `WriteOptions` knob (cascade rules, body
	 * policy flags, leftCurly placement, etc.). Replaces 4-line inline
	 * `optFieldAccess(name)`
	 * boilerplate at ~46 sites.
	 *
	 * The sites that build the access with a non-`Context.currentPos()`
	 * position (the `interMemberInfo` / `staticVarSubdivInfo` per-info
	 * loops, now in `TriviaBlockLowering`) stay inline — the helper
	 * assumes `Context.currentPos()`.
	 */
	private static inline function optFieldAccess(fieldName: String): Expr {
		return { expr: EField(macro opt, fieldName), pos: Context.currentPos() };
	}

	/**
	 * Build the field-access Expr `value.<fieldName><BEFORE_NEWLINE_SUFFIX>`
	 * for a trivia-bearing struct field's `<field>BeforeNewline:Bool` synth slot
	 * (created by `TriviaTypeSynth.isBareNonFirstRef`). The slot reads `true`
	 * when the parser captured a source newline in the gap before the field.
	 *
	 * Used by `lowerStruct` for source-newline preservation paths
	 * (issue_48-v2 bare-ref hardline) — also see `beforeNewlineNotAccess` for
	 * the `bodyOnSameLine` inverse used by `bodyPolicyWrap` consumers.
	 */
	private static inline function beforeNewlineAccess(fieldName: String): Expr {
		return {
			expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_NEWLINE_SUFFIX),
			pos: Context.currentPos()
		};
	}

	/** ω-region-prefix-blank — `value.<field>BeforeBlank`, sibling of `beforeNewlineAccess`. */
	private static inline function beforeBlankAccess(fieldName: String): Expr {
		return {
			expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_BLANK_SUFFIX),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-598-member-leading-comment — build `value.<fieldName>BeforeLeading`,
	 * the `Array<String>` of verbatim comments the parser captured in the gap
	 * before a bare non-first Ref field (synth via
	 * `TriviaTypeSynth.isBareNonFirstRef`). Non-empty only when a comment was
	 * dropped between the preceding content (e.g. a member modifier) and the
	 * field's first token; emitted by the bare-Ref non-first separator.
	 */
	private static inline function beforeLeadingAccess(fieldName: String): Expr {
		return {
			expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_LEADING_SUFFIX),
			pos: Context.currentPos()
		};
	}

	/**
	 * Build `!value.<fieldName><BEFORE_NEWLINE_SUFFIX>` — the `bodyOnSameLine`
	 * inverse of the trivia BeforeNewline slot, used by `bodyPolicyWrap`'s
	 * `Keep`-policy dispatch and the `bodyPolicyForCtor` runtime wrap.
	 */
	private static inline function beforeNewlineNotAccess(fieldName: String): Expr {
		return {
			expr: EUnop(OpNot, false, beforeNewlineAccess(fieldName)),
			pos: Context.currentPos()
		};
	}

	/**
	 * Resolves the positional argument access expression for a synth-ctor
	 * Alt slot, given the slot kind. Returns `null` when the branch does
	 * not carry that slot (synth ctor wasn't extended with the matching
	 * positional arg). Callers must additionally gate on `ctx.trivia &&
	 * isTriviaBearing(typePath)` since these slots only exist on
	 * trivia-mode bearing ctors.
	 *
	 * The slot order mirrors `TriviaTypeSynth.buildEnumCtor` push order:
	 *   CloseTrailing (+ 3 conditional `:lead && !:tryparse` slots) →
	 *   TrailOpt → CaptureSource → BodyPolicyKw → WrapOpenNewline →
	 *   KwNewline → ChainNewline.
	 *
	 * Centralising this walker keeps idx accounting in lockstep with
	 * `buildEnumCtor`; future slot additions become a single chain extend
	 * here instead of touching every consumer.
	 */
	private static function altSlotAccess(branch: ShapeNode, baseIdx: Int, argNames: Array<String>, slot: AltSlot): Null<Expr> {
		// noqa: complexity
		if (!altSlotHasSlot(branch, slot)) return null;
		var idx: Int = baseIdx;
		if (slot == CloseTrailing) return macro $i{argNames[idx]};
		if (TriviaPairAltCtor.isAltCloseTrailingBranch(branch)) {
			idx++;
			if (branch.readMetaString(':lead') != null && !branch.hasMeta(':tryparse')) idx += 3; // noqa: magic-number
		}
		if (slot == TrailOpt) return macro $i{argNames[idx]};
		if (TriviaPairAltCtor.isAltTrailOptBranch(branch)) idx++;
		if (slot == CaptureSource) return macro $i{argNames[idx]};
		if (TriviaPairAltCtor.isCaptureSourceBranch(branch)) idx++;
		if (slot == BodyPolicyKw) return macro $i{argNames[idx]};
		if (TriviaPairAltCtor.isAltBodyPolicyKwBranch(branch)) idx++;
		if (slot == WrapOpenNewline) return macro $i{argNames[idx]};
		if (TriviaPairAltCtor.isAltWrapOpenNewlineBranch(branch)) idx++;
		if (slot == KwNewline) return macro $i{argNames[idx]};
		if (TriviaPairAltCtor.isAltKwNewlineBranch(branch)) idx++;
		if (slot == ChainNewline) return macro $i{argNames[idx]};
		if (TriviaPairAltCtor.isAltChainNewlineBranch(branch)) idx++;
		if (slot == ChainLeadComment) return macro $i{argNames[idx]};
		if (TriviaPairAltCtor.isAltChainNewlineBranch(branch)) idx++;
		if (slot == ChainAfterComment) return macro $i{argNames[idx]};
		if (TriviaPairAltCtor.isInfixChainBranch(branch)) idx++;
		if (slot == ChainRhsTrail) return macro $i{argNames[idx]};
		if (TriviaPairAltCtor.isRhsTrailBranch(branch)) idx++;
		if (slot == TernaryCondTrail) return macro $i{argNames[idx]};
		if (TriviaPairAltCtor.isTernaryTrailBranch(branch)) idx++;
		if (slot == TernaryThenTrail) return macro $i{argNames[idx]};
		if (TriviaPairAltCtor.isTernaryTrailBranch(branch)) idx++;
		return macro $i{argNames[idx]};
	}

	/**
	 * Whether `branch` carries the synth trivia slot for `slot`, per the
	 * matching `TriviaTypeSynth.isAlt*Branch` predicate.
	 */
	private static function altSlotHasSlot(branch: ShapeNode, slot: AltSlot): Bool {
		return switch slot {
			case CloseTrailing: TriviaPairAltCtor.isAltCloseTrailingBranch(branch);
			case TrailOpt: TriviaPairAltCtor.isAltTrailOptBranch(branch);
			case CaptureSource: TriviaPairAltCtor.isCaptureSourceBranch(branch);
			case BodyPolicyKw: TriviaPairAltCtor.isAltBodyPolicyKwBranch(branch);
			case WrapOpenNewline: TriviaPairAltCtor.isAltWrapOpenNewlineBranch(branch);
			case KwNewline: TriviaPairAltCtor.isAltKwNewlineBranch(branch);
			case ChainNewline, ChainLeadComment: TriviaPairAltCtor.isAltChainNewlineBranch(branch);
			case PostfixOpSpace: TriviaPairAltCtor.isPostfixOpSpaceBranch(branch);
			case ChainAfterComment: TriviaPairAltCtor.isInfixChainBranch(branch);
			case ChainRhsTrail: TriviaPairAltCtor.isRhsTrailBranch(branch);
			case TernaryCondTrail, TernaryThenTrail: TriviaPairAltCtor.isTernaryTrailBranch(branch);
		};
	}

	private static function findFieldByName(node: ShapeNode, name: String): Null<ShapeNode> {
		return node.children.find(child -> child.annotations.get(AnnotationKeys.BASE_FIELD_NAME) == name);
	}

	/**
	 * `true` when `s` is a non-empty string whose first character is a
	 * Haxe identifier-start (`a-zA-Z_`). Used by Case 3 single-Ref
	 * emission to detect word-keyword `@:lead` (e.g. `var`, `final`,
	 * `function`) — these are second keywords that need spacing on both
	 * sides, unlike symbol leads (`(`, `{`, `<`, `:`, `?`, `->`, `${`).
	 */
	private static function isWordStart(s: String): Bool {
		if (s == null || s.length == 0) return false;
		final c: Int = s.fastCodeAt(0);
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || c == '_'.code;
	}

	/** Build `_dc([elem1, elem2, ...])` from a macro-time array of Exprs. */
	private static function dcCall(parts: Array<Expr>): Expr {
		final arr: Expr = { expr: EArrayDecl(parts), pos: Context.currentPos() };
		return macro _dc($arr);
	}

	private static function makeWriteCall(writeFnName: String, valueExpr: Expr, hasPratt: Bool, ctxPrec: Int, ?optExpr: Expr): Expr {
		// ω-value-yielded-if-tail-barrier (SI-1): callers may override the opt
		// arg threaded into the sub-call (e.g. `_setExprPosition(opt)` for the
		// infix `->`/`=>` `.right` operand). Null → the historic `macro opt`,
		// keeping non-overriding callers byte-identical.
		final optArg: Expr = optExpr ?? macro opt;
		final args: Array<Expr> = [valueExpr, optArg];
		if (hasPratt) args.push(macro $v{ctxPrec});
		return {
			expr: ECall(macro $i{writeFnName}, args),
			pos: Context.currentPos()
		};
	}

	/**
	 * Return the first flag name from `flagNames` that is present on
	 * `node` as an `@:fmt(...)` argument, or `null` if none match.
	 * Shared lookup for ω-E-whitespace's writer helpers.
	 */
	private static function firstFmtFlag(node: ShapeNode, flagNames: Array<String>): Null<String> {
		return flagNames.find(name -> node.fmtHasFlag(name));
	}

	/**
	 * Read a `name(<expr>)` arg from any `@:fmt(...)` entry on the node
	 * and return the inner expression unchanged. Mirror of
	 * `fmtReadString` for cases where the arg should stay a real Haxe
	 * expression (function reference, identifier path) so the macro
	 * can splice it directly into generated code, type-checked by the
	 * compiler. Returns null when the meta is absent or the arg shape
	 * is not exactly `name(<single-expr>)`.
	 */
	private static function fmtReadCall(node: ShapeNode, name: String): Null<Expr> {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return null;
		for (entry in meta) if (entry.name == ':fmt') {
			for (param in entry.params) switch param.expr {
				case ECall({ expr: EConst(CIdent(id)) }, [arg]) if (id == name):
					return arg;
				case _:
			}
		}
		return null;
	}

	/**
	 * The first string argument of a call-form `@:fmt(<flag>(...))` on `starNode`, or
	 * null when the flag is absent or bare (no argument at all).
	 */
	private static function fmtFirstStringArg(starNode: ShapeNode, flag: String): Null<String> {
		final args: Null<Array<String>> = starNode.fmtReadStringArgs(flag);
		return args != null && args.length >= 1 ? args[0] : null;
	}

	/**
	 * The single string argument of a call-form `@:fmt(<flag>('<optField>'))` on
	 * `starNode`, or null when the flag is absent. A present flag carrying any
	 * other arity is a grammar-author error and aborts the build.
	 */
	private static function fmtSingleStringArg(starNode: ShapeNode, flag: String): Null<String> {
		final args: Null<Array<String>> = starNode.fmtReadStringArgs(flag);
		if (args != null && args.length != 1)
			Context.fatalError(
				'WriterLowering: @:fmt($flag) expects exactly 1 string arg (optField), got ${args.length}', Context.currentPos()
			);
		return args != null ? args[0] : null;
	}

	private static function ctorBranchHasFlag(branch: ShapeNode, flag: String): Bool {
		final meta: Null<Metadata> = branch.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return false;
		for (entry in meta) if (entry.name == ':fmt') {
			for (param in entry.params) switch param.expr {
				case EConst(CIdent(id)) if (id == flag):
					return true;
				case _:
			}
		}
		return false;
	}

	/**
	 * Build the Doc expression for a try-parse trivia Star field
	 * (last field, no `@:trail`, `@:tryparse`). Mirrors the plain-mode
	 * tryparse layout but threads `Trivial<T>` unwrapping through the
	 * loop: when an element carries leading comments, the normal
	 * separator (`sepExpr`) is suppressed in favour of a hardline
	 * followed by each comment on its own line — line-style comments
	 * cannot share a line with trailing content. Between elements
	 * without leading comments the separator runs unchanged.
	 *
	 * Without `@:fmt(nestBody)`, trailing slots are not consulted —
	 * `@:tryparse` rewinds on parse failure so orphan trivia flows
	 * outward to the enclosing Star (matches `HxTryCatchStmt.catches`
	 * behaviour where a comment after the last catch belongs to the
	 * next statement's leading, not to the catches list).
	 *
	 * When `nestBody` is true (`@:fmt(nestBody)`), the whole body Doc
	 * is wrapped in `_dn(_cols, ...)` — one extra indent level — and
	 * every element is preceded by a hardline so the body drops to a
	 * fresh line at inner indent after the preceding field's content
	 * (e.g. a `case X:` pattern). The parser co-captures trailing
	 * orphan comments (own-line comments after the last element, with
	 * no blank-line separator) into the synth trailing slots; the
	 * writer renders them at body-indent right after the last element.
	 * Empty bodies with no trailing orphans emit nothing (no stray
	 * hardline, no dangling nest).
	 * Build a per-flag flat-gate predicate for the case-body
	 * `bodyPolicy` mechanism: `opt.<flag> == Same || (opt.<flag> ==
	 * Keep && !_arr[0].newlineBefore)`. The emitted Expr references
	 * the runtime block's local `_arr` (bound by the outer
	 * `final _arr = $fieldAccess`).
	 *
	 * Used by `triviaTryparseStarExpr.flatGateExpr` for both single-
	 * flag callers (e.g. `bodyPolicy('returnBody')`) and the dual-flag
	 * case-body form (`bodyPolicy('caseBody', 'expressionCase')` on
	 * `HxCaseBranch.body` / `HxDefaultBranch.stmts`). The dual form
	 * dispatches at runtime on `opt._inExprPosition` to pick which
	 * predicate fires; this helper just builds the predicate body for
	 * one flag at a time.
	 * ω-issue-257-else-in-return-switch — read the dual-flag form of
	 * `@:fmt(bodyPolicy('<stmtFlag>')` or `@:fmt(bodyPolicy('<stmtFlag>',
	 * '<exprFlag>'))` from a grammar node. Single-flag form returns
	 * `{stmt, expr: null}`; dual-flag form returns both names. Arity
	 * outside [1, 2] is a fatal error mirroring the policy in
	 * `triviaTryparseStarExpr` for case-body Star fields. Centralised so
	 * the four reader sites (ctor-level branch, optional-Ref shared
	 * branch, mandatory-Ref shared branch, `sameLineSeparator`) stay in
	 * lockstep on validation rules.
	 */
	private static function readBodyPolicyDual(node: ShapeNode): { stmt: Null<String>, expr: Null<String> } {
		final args: Null<Array<String>> = node.fmtReadStringArgs('bodyPolicy');
		if (args == null) return { stmt: null, expr: null };
		if (args.length < 1 || args.length > 2)
			Context.fatalError('WriterLowering: @:fmt(bodyPolicy(...)) takes 1 or 2 args, got ${args.length}', Context.currentPos());
		return { stmt: args[0], expr: args.length == 2 ? args[1] : null };
	}

	/**
	 * `isBlockCtorBranch` narrowed to genuine curly-brace block bodies:
	 * the branch must be a block-ctor shape (lead + trail + single `Star`)
	 * AND its `@:lead` literal must open a curly brace (`{`). Bracket
	 * list ctors (`[ … ]`) and any other delimiter are excluded. Used by
	 * the body-placement block-split so `[for …]`-style value lists follow
	 * the resolved body policy instead of the keyword-glue override.
	 */
	private static function isCurlyBlockCtorBranch(branch: ShapeNode): Bool {
		if (!isBlockCtorBranch(branch)) return false;
		final leadText: Null<String> = branch.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		return leadText != null && leadText.startsWith('{');
	}

	private static function isBlockCtorBranch(branch: ShapeNode): Bool {
		final leadText: Null<String> = branch.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		final trailText: Null<String> = branch.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		return leadText != null && trailText != null && (branch.children.length == 1 && branch.children[0].kind == Star);
	}

	/**
	 * The `[` half of the split `isCurlyBlockCtorBranch` makes: a block-ctor
	 * shape whose `@:lead` literal opens a square bracket (`HxExpr.ArrayExpr`
	 * — an array literal AND an array comprehension, which share one ctor).
	 *
	 * The two predicates are deliberately separate rather than one
	 * parameterised on the delimiter. The curly one is UNCONDITIONAL — a `{`
	 * block body always overrides the body policy, because a block owns its
	 * own indent — while this one only ever fires behind a config flag
	 * (`@:fmt(bracketBodyGlueIfFlag(...))`), since a bracket body hugging its
	 * head is a house-style choice, not a structural fact.
	 */
	private static function isBracketBlockCtorBranch(branch: ShapeNode): Bool {
		if (!isBlockCtorBranch(branch)) return false;
		final leadText: Null<String> = branch.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		return leadText != null && leadText.startsWith('[');
	}

	/**
	 * Sister predicate to `isBlockCtorBranch`: includes `@:fmt(blockShape)`
	 * opt-in ctors that wrap a block via an inner Ref but emit visually as
	 * `kw … { … }` (e.g. `UntypedBlockStmt(body:HxUntypedFnBody)` →
	 * `untyped { … }`). Used ONLY by shape-aware writers that care about
	 * "ends with a `}`" — e.g. `bareBodyBreaks` on a Star where the prev
	 * sibling body decides whether to force a hardline before the next
	 * element. `bodyPolicyWrap`'s body-placement override uses the strict
	 * `isBlockCtorBranch` so per-ctor overrides like
	 * `bodyPolicyOverride('UntypedBlockStmt', 'untypedBody')` still fire.
	 */
	private static function isBlockShapeEquivalentBranch(branch: ShapeNode): Bool {
		return isBlockCtorBranch(branch) || branch.fmtHasFlag('blockShape');
	}

	/**
	 * True when the given Star struct field has no `@:lead` / `@:trail`
	 * / `@:sep`, so its emitted Doc is empty whenever the runtime array
	 * is empty. The next bare-Ref field's leading separator must then
	 * be gated on `field.length > 0`, otherwise the writer emits a
	 * dangling space (`\t function` instead of `\tfunction` when
	 * `HxMemberDecl.modifiers` is empty).
	 */
	private static function isBareTryparseStar(child: ShapeNode): Bool {
		if (child.kind != Star) return false;
		final leadText: Null<String> = child.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		final trailText: Null<String> = child.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		final sepText: Null<String> = child.annotations[AnnotationKeys.LIT_SEP_TEXT];
		return leadText == null && trailText == null && sepText == null;
	}

}
#end
