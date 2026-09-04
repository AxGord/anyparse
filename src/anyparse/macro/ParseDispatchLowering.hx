package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.macro.MacroNames.*;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.ExprTools;
import anyparse.macro.Lowering.*;

using Lambda;
using StringTools;
using anyparse.macro.MetaInspect;

/**
 * Pass 3 — the LL(1) dispatch analysis.
 *
 * One question, asked recursively over the shape tree: what is the
 * FIRST token a rule, an Alt branch, a Seq or a body can commit to? The
 * answer (`BranchFirstToken`) is what lets `Lowering.lowerEnum` wrap a
 * branch trial in a guard that skips it without running it, and the
 * soundness invariant on that enum — a guard may only skip a branch
 * whose trial would fail WITHOUT consuming input — is the contract every
 * member here upholds. `Unknown` is always the safe answer.
 *
 * The module carries the whole chain: `branchShape` (the single
 * classification both the emit side and the guard side switch on),
 * the `*FirstToken` family, the byte-set algebra the guards compile to
 * (`byteSetOf`, `byteRuns`, `byteSetTerms`, `orChain`), the Star gate
 * (`starGateExpr`, `starNestExitArm`), the word-shape predicates
 * (`isWordShaped`, `endsWithWordChar`, `wordOrByteFirst`) and the
 * `-D anyparse-dump-dispatch` reporting (`dumpDispatch`,
 * `describeFirstToken`).
 *
 * Split out of `Lowering` because it is the pass\'s ANALYSIS half:
 * nothing here emits a parse step, nothing reads a build\'s
 * `LoweringCtx`, and every member is static. `Lowering` reaches them
 * unqualified through `import anyparse.macro.ParseDispatchLowering.*;`
 * plus a class-level `@:access`, so the move rewrote no call site.
 */
@:access(anyparse.macro.Lowering)
final class ParseDispatchLowering {

	private static function isBareLeft(e: Expr): Bool {
		return switch e.expr {
			case EConst(CIdent('left')): true;
			case _: false;
		};
	}

	/**
	 * Recursively replace every `skipWs(ctx)` call in an expression tree
	 * with an empty block `{}`. Used by `@:raw` rules to suppress
	 * whitespace skipping without modifying any of the 50+ emission
	 * sites. Referenced sub-rules (via Ref) are separate generated
	 * functions — their own skipWs calls are in their own bodies, not
	 * in this tree, so they are unaffected.
	 */
	private static function stripSkipWs(e: Expr): Expr {
		return isSkipWsStep(e) ? { expr: EBlock([]), pos: e.pos } : ExprTools.map(e, stripSkipWs);
	}

	/**
	 * Whether `e` is the non-consuming `skipWs(ctx)` step a generated rule
	 * body opens with — INCLUDING the empty block `stripSkipWs` leaves
	 * behind in an `@:raw` / binary rule, which is the same step already
	 * reduced to nothing. Shared by the eraser and by `bodyFirstToken`,
	 * which must step over both spellings to reach the rule's first
	 * committed token.
	 */
	private static function isSkipWsStep(e: Expr): Bool {
		return switch e.expr {
			case EBlock([]), ECall({ expr: EConst(CIdent('skipWs')) }, _): true;
			case _: false;
		};
	}

	// -------- helpers --------

	/**
	 * Returns true if the literal's last character is a word character
	 * (`[A-Za-z0-9_]`). Used by `lowerEnumBranch` Cases 1 and 2 to decide
	 * between `expectLit` / `matchLit` and their word-boundary-enforcing
	 * `expectKw` / `matchKw` counterparts for `@:lit`-annotated branches.
	 * An empty literal returns false — the branch would be nonsense, and
	 * the surrounding shape checks reject it before this helper runs.
	 */
	private static function endsWithWordChar(lit: String): Bool {
		if (lit.length == 0) return false;
		final c: Int = lit.charCodeAt(lit.length - 1);
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code;
	}

	/**
	 * `final <name>: <type> = <value>;` with a RUNTIME name. The reified
	 * `macro final x = ...` form can only take a literal identifier, and
	 * the dispatch prologue's locals are named from the `GUARD_*_LOCAL`
	 * constants so `branchGuardExpr` can read the same spellings back.
	 */
	private static function finalLocal(name: String, type: ComplexType, value: Expr): Expr {
		return {
			expr: EVars([
				{
					name: name,
					type: type,
					expr: value,
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		};
	}

	/**
	 * Classify one Alt branch into the shape its lowering handles — the
	 * SOLE producer of `BranchShape`, read by `lowerEnumBranch` to pick
	 * the emission and by `branchFirstToken` to pick the dispatch guard.
	 * Neither can drift from the other any more: a new constructor breaks
	 * both switches until both have an arm for it.
	 *
	 * THE TEST ORDER BELOW IS THE GRAMMAR CONTRACT, not a detail. It
	 * reproduces the original predicate chain verbatim: `Prefix` before
	 * `KwRef` (a prefix branch matches the single-`Ref` shape too, and the
	 * `KwRef` lowering would emit an unguarded left-recursive call that
	 * consumes nothing), and `StarList` before `KwRef` for the same
	 * single-child reason. Each shape's own rationale lives on its
	 * `BranchShape` constructor.
	 */
	private static function branchShape(branch: ShapeNode): BranchShape {
		final prefixOp: Null<String> = branch.annotations[AnnotationKeys.PREFIX_OP];
		if (prefixOp != null) return Prefix(prefixOp);
		final litList: Null<Array<String>> = branch.annotations[AnnotationKeys.LIT_LIT_LIST];
		final children: Array<ShapeNode> = branch.children;
		final kwLead: Null<String> = branch.annotations[AnnotationKeys.KW_LEAD_TEXT];
		if (kwLead != null && children.length == 0 && litList == null) return KwZeroArg(kwLead);
		if (litList != null && litList.length == 1 && children.length == 0) return SingleLit(litList[0]);
		if (litList != null && litList.length > 1 && children.length == 1) return MultiLit(litList);
		final leadText: Null<String> = branch.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		final trailText: Null<String> = branch.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		final sepText: Null<String> = branch.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final sepAltText: Null<String> = branch.annotations[AnnotationKeys.LIT_SEP_ALT_TEXT];
		// `prefer-ternary-return` fires on this trailing pair. Collapsing it
		// only moves the finding one guard up the chain — every `if (…)
		// return Shape;` above is the same shape — and the UNIFORM chain is
		// the point: it reproduces the original predicate sequence in order,
		// and that order is the grammar contract (see the doc above).
		return if (leadText != null && trailText != null && children.length == 1 && children[0].kind == Star)
			StarList(leadText, trailText, sepText, sepAltText)
		else if (litList == null && children.length == 1 && children[0].kind == Ref)
			KwRef(kwLead, leadText)
		else
			Unsupported;
	}

	/**
	 * The FIRST token an Alt branch commits to, or `Unknown` when it is
	 * not provably first-token dispatchable (which leaves the branch
	 * unguarded — exactly the pre-guard behaviour).
	 *
	 * Every arm reads the same `branchShape` value `lowerEnumBranch`
	 * dispatches its emission on, so "the guard matches what the branch
	 * actually consumes first" is now structural rather than a comment
	 * asking two predicate chains to stay in step.
	 */
	private static function branchFirstToken(rules: Map<String, ShapeNode>, seen: Array<String>, branch: ShapeNode): BranchFirstToken {
		return switch branchShape(branch) {
			case Prefix(op): litFirst([op]);
			case KwZeroArg(kw): wordOrByteFirst([kw]);
			case SingleLit(lit): wordOrByteFirst([lit]);
			case MultiLit(lits): wordOrByteFirst(lits);
			case StarList(lead, _, _, _):
				litFirst([lead]);
			// Split into guarded arms rather than an if-chain inside one
			// arm: the keyword decides the first token whenever it is
			// present, the lead literal otherwise, and a bare `Ref` commits
			// nothing of its OWN — its first token is the referenced
			// rule's, which `refBranchFirstToken` reads. A new
			// `BranchShape` constructor still breaks this switch — the
			// trailing `KwRef` arm only makes the three KwRef sub-cases
			// exhaustive among themselves.
			case KwRef(kw, _) if (kw != null): wordOrByteFirst([kw]);
			case KwRef(_, lead) if (lead != null): litFirst([lead]);
			case KwRef(_, _): refBranchFirstToken(rules, seen, branch);
			case Unsupported: Unknown;
		};
	}

	/**
	 * First token of a bare-`Ref` Alt branch, taken from the RULE it
	 * references — the branch itself commits nothing before recursing, so
	 * its first token is whatever the sub-rule's is.
	 *
	 * `@:fmt(atomOperand)` retargets the call to the `…Atom` variant of
	 * the sub-rule rather than its entry function; `ruleFirstToken`
	 * models the entry only, so such a branch answers `Unknown`.
	 *
	 * Kept separate from `branchFirstToken` so the dispatch dump can
	 * report, per branch, what the branch-local classifier sees AND what
	 * looking through the `Ref` would add.
	 */
	private static function refBranchFirstToken(rules: Map<String, ShapeNode>, seen: Array<String>, branch: ShapeNode): BranchFirstToken {
		return switch branchShape(branch) {
			case KwRef(kw, lead) if (kw == null && lead == null && !branch.fmtHasFlag(ATOM_OPERAND_FLAG)):
				ruleFirstToken(rules, branch.children[0].annotations[AnnotationKeys.BASE_REF], seen);
			case _: Unknown;
		};
	}

	/**
	 * The FIRST token the generated entry function of `refName` commits
	 * to, or `Unknown` when it cannot be established from the shape.
	 *
	 * This is the RULE-level twin of `branchFirstToken`. The branch
	 * classifier answers "what does this Alt branch consume first" from
	 * the branch's OWN annotations and stops at a bare `Ref`, because the
	 * branch commits nothing there. The answer for that case lives one
	 * level down, in the referenced rule — and that is where the Haxe
	 * grammar's costliest backtrack sites sit: `HxParenLambda`,
	 * `HxThinParenLambda` and `HxECheckType` on `(`, `HxObjectLit` on
	 * `{`, `HxInterpString` on `'`.
	 *
	 * THE SOUNDNESS INVARIANT is `BranchFirstToken`'s: a non-`Unknown`
	 * answer claims the rule fails WITHOUT CONSUMING at every position
	 * whose first byte / word is outside the returned set.
	 * `checkRuleFirstToken` turns a claim the emission does not honour
	 * into a COMPILE ERROR, so this classifier cannot silently drift from
	 * `lowerStruct` the way two hand-kept predicate chains would.
	 *
	 * `seen` breaks rule cycles (`A`'s first field refs `B`, `B`'s refs
	 * `A`): a revisited rule answers `Unknown`, the safe default.
	 */
	private static function ruleFirstToken(rules: Map<String, ShapeNode>, refName: String, seen: Array<String>): BranchFirstToken {
		if (seen.contains(refName)) return Unknown;
		final node: Null<ShapeNode> = rules[refName];
		if (node == null) return Unknown;
		// `seen` grows on EVERY descent, not just the Seq one: an Alt
		// branch that is a bare `Ref` re-enters here through
		// `refBranchFirstToken`, so a grammar cycle (A -> branch Ref B ->
		// ... -> A) is reachable the moment `Alt` answers at all.
		final next: Array<String> = seen.concat([refName]);
		return switch node.kind {
			case Seq: seqFirstToken(rules, node, next);
			case Alt: altFirstToken(rules, node, next);
			case Terminal: terminalFirstToken(node);
			case _: Unknown;
		};
	}

	/**
	 * First token of an `Alt` rule — the UNION over its branches.
	 *
	 * Refused (`Unknown`) in three cases, each because the claim would
	 * not describe what the ENTRY function of the rule emits:
	 *
	 *  - ANY branch carrying `pratt.prec` / `postfix.op` / `ternary.op`.
	 *    `lowerRule` splits such an enum into a precedence-climbing (or
	 *    postfix) LOOP rule plus an atom sub-rule, and the entry function
	 *    is the loop. Its first token is the ATOM set's, which
	 *    `lowerEnum(atomsOnly = true)` computes over a FILTERED branch
	 *    list — so the union taken here would include operator branches
	 *    the atom dispatcher never tries.
	 *  - Any branch whose own first token is `Unknown`. An unguardable
	 *    branch can start with anything, so the rule can too.
	 *  - Fewer branches than `DISPATCH_MIN_GUARDS`. Below that threshold
	 *    `lowerEnum` emits NO dispatch prologue, so there would be no
	 *    emission for `checkRuleFirstToken` to verify the claim against.
	 */
	private static function altFirstToken(rules: Map<String, ShapeNode>, node: ShapeNode, seen: Array<String>): BranchFirstToken {
		if (node.children.length < DISPATCH_MIN_GUARDS) return Unknown;
		final operatorKeys: Array<String> = [AnnotationKeys.PRATT_PREC, AnnotationKeys.POSTFIX_OP, AnnotationKeys.TERNARY_OP];
		for (branch in node.children) for (key in operatorKeys) if (branch.annotations.get(key) != null) return Unknown;
		return unionFirstToken(node.children.map(branchFirstToken.bind(rules, seen)));
	}

	/**
	 * First token of a `@:re` Terminal rule — the first-byte SET of its
	 * pattern, read by `RegexFirstBytes`.
	 *
	 * A terminal whose set is known is guardable at every call site: the
	 * Alt dispatch skips its branch on a wrong first byte instead of
	 * paying a trial whose only exit is a thrown backtrack. That is what
	 * the numeric literals cost before this read a character class —
	 * `HxIntLit` and `HxFloatLit` were tried, and threw, on EVERY atom.
	 *
	 * `Unknown` for a terminal whose values are a closed `enum abstract`
	 * string set (`base.stringEnumValues`): those take
	 * `lowerStringEnumTerminal`, which has no regex at all, so the pattern
	 * this reads does not describe them. `Unknown` too for every pattern
	 * `RegexFirstBytes` will not commit to — see its own doc for which,
	 * and why `null` there is the safe direction.
	 */
	private static function terminalFirstToken(node: ShapeNode): BranchFirstToken {
		if (node.annotations['base.stringEnumValues'] != null) return Unknown;
		final codes: Null<Array<Int>> = RegexFirstBytes.of(node.annotations['re.pattern']);
		return codes == null ? Unknown : FirstLit(codes);
	}

	/**
	 * Union of several first-token facts into one that is sound for all
	 * of them.
	 *
	 * All-`FirstKw` unions as `FirstKw` (deduped). Any mix with a
	 * `FirstLit` degrades EVERY keyword to its first byte: matching a
	 * word-shaped keyword is a strictly stronger condition than matching
	 * its first byte, so the byte test is a NECESSARY condition of the
	 * keyword test and the weaker guard can only over-accept — never skip
	 * something that would have matched.
	 *
	 * A single `Unknown` part poisons the union: the alternative it
	 * stands for can begin with anything.
	 */
	private static function unionFirstToken(parts: Array<BranchFirstToken>): BranchFirstToken {
		if (parts.length == 0) return Unknown;
		var allKw: Bool = true;
		for (part in parts) {
			if (part == Unknown) return Unknown;
			if (part.match(FirstLit(_))) allKw = false;
		}
		if (allKw) {
			final words: Array<String> = [];
			for (part in parts) switch part {
				case FirstKw(ws):
					for (word in ws) if (!words.contains(word))
						words.push(word);
				case _:
					throw 'unreachable';
			}
			return FirstKw(words);
		}
		final codes: Array<Int> = [];
		for (part in parts) switch part {
			case FirstKw(ws):
				for (word in ws) if (!codes.contains(word.charCodeAt(0)))
					codes.push(word.charCodeAt(0));
			case FirstLit(cs):
				for (code in cs) if (!codes.contains(code))
					codes.push(code);
			case Unknown:
				throw 'unreachable';
		}
		return codes.length == 0 ? Unknown : FirstLit(codes);
	}

	/**
	 * First token of a `Seq` rule = first token of its FIRST field, which
	 * `lowerStruct` emits before anything else.
	 *
	 * An OPTIONAL first field answers `Unknown`: its lead literal is
	 * emitted inside the optional's own trial, so a position not starting
	 * with it is not a failure of the rule at all — the field is absent
	 * and the SECOND field decides. Guarding on it would skip a branch
	 * that matches.
	 *
	 * A first field carrying no lead of its own but holding a bare `Ref`
	 * hands the question one level down, exactly as a bare-`Ref` Alt
	 * branch does.
	 */
	private static function seqFirstToken(rules: Map<String, ShapeNode>, node: ShapeNode, seen: Array<String>): BranchFirstToken {
		if (node.children.length == 0 || node.annotations[BY_NAME_KEY] == true) return Unknown;
		// A binary `@:magic` prefix is an `expectLit` `lowerStruct` emits
		// BEFORE any field, and a `@:length` prefix is a read emitted
		// before the field it belongs to — in both cases the positional
		// first field is not what the body opens with. No current grammar
		// pairs either with a first field that would claim anything (so
		// the divergence would surface as a spurious build break, not as a
		// wrong guard), which is exactly why it is cheaper to refuse here
		// than to leave the trap for the next binary grammar.
		if (node.annotations[AnnotationKeys.BIN_MAGIC] != null) return Unknown;
		final first: ShapeNode = node.children[0];
		if (first.kind == Opt || first.annotations[AnnotationKeys.BASE_OPTIONAL] == true) return Unknown;
		if (first.annotations['bin.lengthPrefix'] != null) return Unknown;
		final kw: Null<String> = first.annotations[AnnotationKeys.KW_LEAD_TEXT];
		if (kw != null) return wordOrByteFirst([kw]);
		final lead: Null<String> = first.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		return if (lead != null)
			litFirst([lead]);
		else if (first.kind == Ref)
			ruleFirstToken(rules, first.annotations[AnnotationKeys.BASE_REF], seen);
		else
			Unknown;
	}

	/**
	 * The first token a LOWERED rule body actually commits to, read off
	 * the emitted expression instead of off the shape — the oracle
	 * `checkRuleFirstToken` holds `ruleFirstToken` against.
	 *
	 * Leading `skipWs(ctx)` calls are stepped over: `skipWs` consumes
	 * only what the dispatch prologue's own `skipWs` consumed before
	 * peeking, so it cannot move the token being classified. The first
	 * statement that is anything else must be the `expectLit` /
	 * `expectKw` the claim names, or the claim is wrong.
	 */
	private static function bodyFirstToken(
		rules: Map<String, ShapeNode>, fnToRule: Map<String, String>, body: Expr, seen: Array<String>
	): BranchFirstToken {
		final steps: Array<Expr> = switch body.expr {
			case EBlock(exprs): exprs;
			case _: [body];
		};
		var i: Int = 0;
		// `isGuardSavedDecl` wins over `isInertStep`: the prologue's
		// `final _gSaved:Int = ctx.pos;` IS an inert slot declaration, and
		// skipping it would leave the scan pointing at `_gC0` with the
		// dispatch shape no longer recognisable.
		while (i < steps.length && !isGuardSavedDecl(steps[i]) && isInertStep(steps[i])) i++;
		if (i >= steps.length) return Unknown;
		final head: Expr = steps[i];
		// An Alt dispatch body: the prologue's `_gSaved` snapshot, then one
		// `if (<guard>) <trial>` per guardable branch. Reading the EMITTED
		// guards back — rather than re-deriving them from the shape tree —
		// is what keeps an `Alt` claim honest: the claim comes from
		// `altFirstToken` over the shape, the verification from the
		// generated AST, and `checkRuleFirstToken` fatals when they part.
		if (isGuardSavedDecl(head)) return dispatchFirstToken(steps, i + 1);
		// The terminal first-byte reject `lowerTerminal` emits from the same
		// `terminalFirstToken` fact the claim is built on.
		final reject: Null<Array<Int>> = firstByteRejectCodes(steps, i);
		if (reject != null) return FirstLit(reject);
		// A leading `parseXxx(ctx)` — the emitted call for a `Seq` rule whose
		// first field is a bare `Ref`. Resolving the function name back to
		// its rule and recursing is NOT vacuous: it proves the shape-level
		// `Ref` the claim was derived through is the call the body actually
		// makes, and the recursion still bottoms out at a leaf rule whose own
		// body is checked against an `expectLit` / `expectKw` / byte reject.
		final called: Null<String> = leadingRefCallName(head);
		if (called != null) {
			final target: Null<String> = fnToRule[called];
			if (target != null) return ruleFirstToken(rules, target, seen);
		}
		return switch head.expr {
			case ECall({ expr: EConst(CIdent('expectLit')) }, [_, { expr: EConst(CString(lit, _)) }]): litFirst([lit]);
			case ECall({ expr: EConst(CIdent('expectKw')) }, [_, { expr: EConst(CString(kw, _)) }]): wordOrByteFirst([kw]);
			case _: Unknown;
		};
	}

	/**
	 * Steps a rule body may open with that provably consume no TOKEN, so
	 * the first-token fact lives in whatever follows them.
	 *
	 * Beyond `isSkipWsStep`'s whitespace skip (and the empty block a
	 * `@:raw` rule's `stripSkipWs` leaves behind), two families qualify:
	 *
	 *  - The trivia-mode whitespace/comment scanners. `collectTrivia` and
	 *    `skipWsAndStash` consume exactly what `skipWs` does — inter-token
	 *    whitespace and comments — and stop at the first token byte.
	 *  - A slot declaration whose initializer touches no input: a cursor
	 *    snapshot (`ctx.pos`), an empty accumulator (`[]`), or a literal
	 *    default (`false` / `true` / `null` / a number / a string).
	 *
	 * Nothing goes on this list without that argument. A step whose
	 * non-consumption cannot be justified must be left OFF it — then the
	 * claim fails `checkRuleFirstToken` and `ruleFirstToken` gets narrowed,
	 * which is the safe direction.
	 */
	private static function isInertStep(e: Expr): Bool {
		if (isSkipWsStep(e)) return true;
		return switch e.expr {
			case EVars(vars):
				for (v in vars) if (!isInertInit(v.expr)) return false;
				true;
			case _: isInertInit(e);
		};
	}

	/** Initializer of an `isInertStep` slot declaration — see there. */
	private static function isInertInit(e: Null<Expr>): Bool {
		if (e == null) return true;
		return switch e.expr {
			case EConst(CIdent('null' | 'true' | 'false')), EConst(CInt(_, _)), EConst(CFloat(_, _)), EConst(CString(_, _)),
				EArrayDecl([]), EField({ expr: EConst(CIdent('ctx')) }, 'pos'),
				ECall({ expr: EConst(CIdent('collectTrivia' | 'skipWsAndStash')) }, _): true;
			case _: false;
		};
	}

	/** The `final _gSaved:Int = ctx.pos;` that opens an Alt dispatch body. */
	private static function isGuardSavedDecl(e: Expr): Bool {
		return switch e.expr {
			case EVars([v]): v.name == GUARD_SAVED_LOCAL;
			case _: false;
		};
	}

	/** The remaining prologue steps `lowerEnum` emits after `_gSaved`. */
	private static function isDispatchPrologueStep(e: Expr): Bool {
		return switch e.expr {
			case EVars([v]):
				v.name == GUARD_BYTE_LOCAL || v.name == GUARD_WORD_LOCAL;
			case EBinop(OpAssign, { expr: EField({ expr: EConst(CIdent('ctx')) }, 'pos') }, { expr: EConst(CIdent(name)) }):
				name == GUARD_SAVED_LOCAL;
			case _: false;
		};
	}

	/**
	 * First token of an emitted Alt dispatch body, read off the guards it
	 * actually carries. `from` points just past the `_gSaved` declaration.
	 *
	 * Every branch statement must be a guarded `if (<guard>) <trial>`; a
	 * bare trial means an unguarded branch, which can start with anything,
	 * so the whole body answers `Unknown`. The trailing
	 * `throw ParseError.backtrack` ends the scan.
	 */
	private static function dispatchFirstToken(steps: Array<Expr>, from: Int): BranchFirstToken {
		final parts: Array<BranchFirstToken> = [];
		for (i in from ... steps.length) {
			final step: Expr = steps[i];
			if (isSkipWsStep(step) || isDispatchPrologueStep(step)) continue;
			switch step.expr {
				case EThrow(_):
					break;
				case EIf(cond, _, null):
					final part: BranchFirstToken = guardFirstToken(cond);
					if (part == Unknown) return Unknown;
					parts.push(part);
				case _:
					return Unknown;
			}
		}
		return unionFirstToken(parts);
	}

	/** One emitted branch guard — the or-chain `branchGuardExpr` built. */
	private static function guardFirstToken(cond: Expr): BranchFirstToken {
		final codes: Null<Array<Int>> = byteSetOf(cond, GUARD_BYTE_LOCAL);
		if (codes != null) return FirstLit(codes);
		return switch cond.expr {
			case EBinop(OpBoolOr, left, right): unionFirstToken([guardFirstToken(left), guardFirstToken(right)]);
			case EBinop(OpEq, { expr: EConst(CIdent(local)) }, { expr: EConst(CString(word, _)) }) if (local == GUARD_WORD_LOCAL):
				FirstKw([word]);
			case _: Unknown;
		};
	}

	/**
	 * The exact first-byte reject `lowerTerminal` emits, in either of its
	 * two shapes — matched down to the `ctx.input.charCodeAt(ctx.pos)`
	 * receiver so no other `if` against an int can be mistaken for it.
	 *
	 * One code is a bare `!=` compare in a single step; a SET is the
	 * `_tC0` read followed by a negated `byteSetTerms` chain, which is why
	 * this reads a step LIST rather than one expression.
	 */
	private static function firstByteRejectCodes(steps: Array<Expr>, at: Int): Null<Array<Int>> {
		return switch steps[at].expr {
			case EIf({ expr: EBinop(OpNotEq, receiver, { expr: EConst(CInt(code, _)) }) }, _, null) if (isPosCharCode(receiver)):
				final v: Null<Int> = Std.parseInt(code);
				v == null ? null : [v];
			case EVars([v]) if (v.name == TERMINAL_BYTE_LOCAL && v.expr != null && isPosCharCode(v.expr) && at + 1 < steps.length):
				switch steps[at + 1].expr {
					case EIf({ expr: EUnop(OpNot, false, cond) }, _, null): byteSetOf(cond, TERMINAL_BYTE_LOCAL);
					case _: null;
				}
			case _: null;
		};
	}

	/** The `ctx.input.charCodeAt(ctx.pos)` read both reject shapes open with. */
	private static function isPosCharCode(e: Expr): Bool {
		return switch e.expr {
			case ECall(
				{ expr: EField({ expr: EField({ expr: EConst(CIdent('ctx')) }, 'input') }, 'charCodeAt') },
				[{ expr: EField({ expr: EConst(CIdent('ctx')) }, 'pos') }]
			): true;
			case _: false;
		};
	}

	/**
	 * Name of a leading `parseXxx(ctx)` call — bare, or as the initializer
	 * of the `EVars` step a `Seq` field emits.
	 */
	private static function leadingRefCallName(e: Expr): Null<String> {
		final call: Null<Expr> = switch e.expr {
			case EVars([v]): v.expr;
			case _: e;
		};
		return call == null
			? null
			: switch call.expr {
				case ECall({ expr: EConst(CIdent(name)) }, [{ expr: EConst(CIdent('ctx')) }]) if (name.startsWith('parse')): name;
				case _: null;
			};
	}

	/**
	 * Hold `ruleFirstToken`'s claim about `typePath` against what the
	 * rule's lowered body emits, and halt the build when they differ.
	 *
	 * An over-claiming first-token classification is the one defect no
	 * runtime oracle catches: the dispatch guard it feeds skips a branch
	 * whose trial WOULD have matched, and only on grammars or inputs the
	 * corpus never exercises — a byte-identical corpus dump, a green
	 * suite and an A/B over real files all stay quiet. The claim and the
	 * emission are two independent code paths (`seqFirstToken` reads
	 * annotations, `lowerStruct` picks between a dozen field-emission
	 * variants), so this check is what keeps them in step — the same
	 * contract `BranchShape` gives `lowerEnumBranch` and
	 * `branchFirstToken`.
	 */
	private static function checkRuleFirstToken(
		rules: Map<String, ShapeNode>, fnToRule: Map<String, String>, typePath: String, rule: GeneratedRule
	): Void {
		final claimed: BranchFirstToken = ruleFirstToken(rules, typePath, []);
		if (claimed == Unknown) return;
		final emitted: BranchFirstToken = bodyFirstToken(rules, fnToRule, rule.body, [typePath]);
		if (!sameFirstToken(claimed, emitted))
			Context.fatalError(
				'Lowering: the first-token claim for ${simpleName(typePath)} (${describeFirstToken(claimed)}) '
				+ 'disagrees with what ${rule.fnName} emits (${describeFirstToken(emitted)}) — '
				+ 'an Alt dispatch guard built on it would skip branches that match',
				Context.currentPos()
			);
	}

	/**
	 * Equality over first-token facts. The payloads are SETS (distinct
	 * first bytes, alternative keywords), so order must not decide the
	 * answer.
	 */
	private static function sameFirstToken(a: BranchFirstToken, b: BranchFirstToken): Bool {
		return switch [a, b] {
			case [FirstKw(x), FirstKw(y)]: sameSet(x, y);
			case [FirstLit(x), FirstLit(y)]: sameSet(x, y);
			case [Unknown, Unknown]: true;
			case _: false;
		};
	}

	/** Set equality for the first-token payloads — same length, same members. */
	private static function sameSet<T>(x: Array<T>, y: Array<T>): Bool {
		return x.length == y.length && x.foreach(v -> y.contains(v));
	}

	/**
	 * One-line rendering of a first-token fact, shared by the dispatch
	 * dump and the drift error so a report and a diagnostic can never
	 * describe the same fact differently. Byte codes are printed as
	 * character AND number, since the interesting ones (`(`, `{`, `'`)
	 * are punctuation a bare character would make ambiguous in a log.
	 */
	private static function describeFirstToken(first: BranchFirstToken): String {
		return switch first {
			case FirstKw(words): 'kw ${words.join('|')}';
			case FirstLit(codes): 'lit ${describeByteSet(codes)}';
			case Unknown: 'unknown';
		};
	}

	/**
	 * A byte-code set with consecutive runs written as ranges — the same
	 * collapse `byteSetTerms` emits, so the dump reads like the guard.
	 * Without it a class-shaped head prints as 53 comma-free members and
	 * the per-rule dump line stops being readable.
	 */
	private static function describeByteSet(codes: Array<Int>): String {
		return [
			for (run in byteRuns(codes))
				run.lo == run.hi ? describeByte(run.lo) : '${describeByte(run.lo)}-${describeByte(run.hi)}'
		].join('|');
	}

	/**
	 * One byte as character AND number — the interesting ones are punctuation, so
	 * a bare number would be unreadable.
	 *
	 * A CONTROL character is spelled, never spliced raw: both consumers are
	 * ONE-LINE-per-record channels (`// dispatch.<kind>: …` under
	 * `-D anyparse_dispatch_dump`, and `checkRuleFirstToken`'s drift error), and a
	 * tab or newline in the middle of a record breaks the record rather than the
	 * character. Reachable since terminal heads became SETS: `escapeBytes` expands
	 * `\t` / `\n` / `\r`, so any `[ \t]`-shaped class head puts one here.
	 */
	private static function describeByte(code: Int): String {
		final spelled: Null<String> = switch code {
			case '\t'.code: '\\t';
			case '\n'.code: '\\n';
			case '\r'.code: '\\r';
			case _: code < ' '.code || code == DELETE_BYTE ? '\\x$code' : null;
		};
		return '${spelled ?? String.fromCharCode(code)}($code)';
	}

	/**
	 * `-D anyparse_dispatch_dump` diagnostic — the per-grammar inventory
	 * of what first-token dispatch reaches, printed as `//` comments
	 * alongside the existing `anyparse_trivia_dump` / `anyparse_dump`
	 * channels.
	 *
	 * Three record kinds: `dispatch.first` (one per rule — the rule-level
	 * fact a caller could guard a `Ref` on), `dispatch.branch` (one per
	 * Alt branch — its shape, the fact that guards it, and the fact taken
	 * through a bare `Ref` when that is where it came from), and
	 * `dispatch.rule` (per Alt — guardable count and whether the prologue
	 * is emitted), closed by one `dispatch.total` summary line.
	 */
	private static function dumpDispatch(
		rules: Map<String, ShapeNode>, gates: Array<{
			rule: Null<String>,
			field: Null<String>,
			elem: String,
			first: BranchFirstToken
		}>
	): Void {
		var ruleCount: Int = 0;
		var altCount: Int = 0;
		var dispatchCount: Int = 0;
		var branchCount: Int = 0;
		var guardedCount: Int = 0;
		var refViaCount: Int = 0;
		for (typePath => node in rules) {
			ruleCount++;
			Sys.println('// dispatch.first: $typePath = ${describeFirstToken(ruleFirstToken(rules, typePath, []))}');
			if (node.kind != Alt) continue;
			altCount++;
			var guardable: Int = 0;
			for (branch in node.children) {
				branchCount++;
				final ctor: Null<String> = branch.annotations[AnnotationKeys.BASE_CTOR];
				final own: BranchFirstToken = branchFirstToken(rules, [], branch);
				final viaRef: BranchFirstToken = refBranchFirstToken(rules, [], branch);
				if (own != Unknown) {
					guardedCount++;
					guardable++;
				}
				if (viaRef != Unknown) refViaCount++;
				Sys.println(
					'// dispatch.branch: $typePath.$ctor shape=${branchShape(branch)} '
					+ 'first=${describeFirstToken(own)} viaRef=${describeFirstToken(viaRef)}'
				);
			}
			final dispatches: Bool = guardable >= DISPATCH_MIN_GUARDS;
			if (dispatches) dispatchCount++;
			Sys.println('// dispatch.rule: $typePath branches=${node.children.length} guardable=$guardable dispatch=$dispatches');
		}
		var gatedCount: Int = 0;
		for (gate in gates) {
			final gated: Bool = gate.first != Unknown;
			if (gated) gatedCount++;
			Sys.println(
				'// dispatch.call: ${gate.rule}.${gate.field} elem=${gate.elem} first=${describeFirstToken(gate.first)} gated=$gated'
			);
		}
		Sys.println(
			'// dispatch.total: rules=$ruleCount alts=$altCount dispatching=$dispatchCount branches=$branchCount '
			+ 'guarded=$guardedCount viaRef=$refViaCount calls=${gates.length} gatedCalls=$gatedCount'
		);
	}

	/**
	 * `FirstKw` when EVERY literal is word-shaped — only then does a
	 * `peekWord` compare reproduce the branch's `expectKw` / `matchKw`
	 * word-boundary test exactly. `FirstLit` otherwise, which stays sound
	 * either way: the first-byte compare is the first iteration of the
	 * literal compare that `expectKw` and `expectLit` both open with.
	 *
	 * THE LOAD-BEARING IMPLICATION: `isWordShaped(lit)` implies
	 * `endsWithWordChar(lit)` — a word-shaped literal's last character is
	 * either its ident-start head or one of the `[A-Za-z0-9_]` characters
	 * the tail loop checked, so it is a word character either way. And
	 * `endsWithWordChar` is exactly the predicate the Case 1 / Case 2
	 * lowerings use to choose `expectKw` / `matchKw` over the
	 * boundary-less `expectLit` / `matchLit`. Therefore a `FirstKw` guard
	 * can only ever sit in front of a WORD-BOUNDARY-CHECKING primitive —
	 * which is what makes `peekWord` equality an exact acceptance test
	 * rather than an over-strict one. Were a `peekWord` guard ever to
	 * front a bare `expectLit`, it would wrongly skip the branch on input
	 * like `dog` for `expectLit('do')`, since `peekWord` returns the
	 * MAXIMAL word `dog` and would not equal `do`.
	 *
	 * `isWordShaped` is strictly stronger than `endsWithWordChar` (`a-b`,
	 * `1abc` and `else if` all end in a word character without being
	 * word-shaped); those correctly degrade to the byte guard, still sound
	 * because `expectKw` opens with the very same literal compare.
	 */
	private static function wordOrByteFirst(lits: Array<String>): BranchFirstToken {
		for (lit in lits) if (!isWordShaped(lit)) return litFirst(lits);
		return FirstKw(lits);
	}

	/**
	 * `FirstLit` over the DISTINCT first bytes of `lits`. A literal with
	 * no first byte cannot be guarded, so an empty literal — or an empty
	 * SET, which would leave the guard with no terms at all — degrades the
	 * whole classification to `Unknown`. The surrounding shape checks
	 * reject such a grammar anyway; this only keeps the classifier total,
	 * so no downstream builder has to defend against a term-less guard.
	 */
	private static function litFirst(lits: Array<String>): BranchFirstToken {
		if (lits.length == 0) return Unknown;
		final codes: Array<Int> = [];
		for (lit in lits) {
			if (lit.length == 0) return Unknown;
			final code: Int = lit.charCodeAt(0);
			if (!codes.contains(code)) codes.push(code);
		}
		return FirstLit(codes);
	}

	/**
	 * Full-match test for `#?[A-Za-z_][A-Za-z0-9_]*` — the exact shape
	 * `peekWord` returns. A `#`-led conditional-compilation keyword
	 * (`#if`, `#elseif`, `#else`, `#end`) IS word-shaped: `peekWord` folds
	 * the `#` into the word whenever an ident-start follows it, so the
	 * word-guard compare holds for those too.
	 */
	private static function isWordShaped(lit: String): Bool {
		final start: Int = lit.length > 0 && lit.charCodeAt(0) == '#'.code ? 1 : 0;
		if (lit.length <= start) return false;
		final head: Int = lit.charCodeAt(start);
		if (!((head >= 'a'.code && head <= 'z'.code) || (head >= 'A'.code && head <= 'Z'.code) || head == '_'.code)) return false;
		for (i in start + 1...lit.length) {
			final c: Int = lit.charCodeAt(i);
			if (
				!((c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code)
			)
				return false;
		}
		return true;
	}

	/**
	 * Guard condition for one classified branch, reading the per-dispatch
	 * prologue locals `lowerEnum` emits once (`GUARD_WORD_LOCAL` /
	 * `GUARD_BYTE_LOCAL`). `null` for `Unknown` — that branch is emitted
	 * unwrapped.
	 */
	private static function branchGuardExpr(first: BranchFirstToken, byteLocal: String, wordLocal: String): Null<Expr> {
		return switch first {
			case FirstKw(words): orChain([for (word in words) macro $i{wordLocal} == $v{word}]);
			case FirstLit(codes): orChain(byteSetTerms(byteLocal, codes));
			case Unknown: null;
		};
	}

	/**
	 * Membership terms for a byte-code set over `local`, one per RUN of
	 * consecutive codes: an equality for a run of one, a `>= lo && <= hi`
	 * pair for a longer one.
	 *
	 * The collapse is what makes a class-shaped first-byte fact usable at
	 * all. `[A-Za-z_]` is 53 codes, and it is the head of the identifier
	 * terminals every Alt in the grammar leads with — as 53 equalities it
	 * would be emitted at every guard site and every terminal reject; as
	 * three range terms it is the same test the hand-written guards were.
	 *
	 * `byteSetOf` is the inverse, and `checkRuleFirstToken` holds the two
	 * against each other on every build.
	 */
	private static function byteSetTerms(local: String, codes: Array<Int>): Array<Expr> {
		return [
			for (run in byteRuns(codes))
				run.lo == run.hi ? macro $i{local} == $v{run.lo} : macro $i{local} >= $v{run.lo} && $i{local} <= $v{run.hi}
		];
	}

	/**
	 * A byte-code set as ascending runs of consecutive codes.
	 *
	 * The one place the collapse happens. `byteSetTerms` turns each run into a
	 * guard term and `describeByteSet` into a rendered range, and the two have to
	 * agree — `describeByteSet`'s whole job is to print what the guard tests, and a
	 * hand-copied second loop would drift silently on a diagnostic path nothing
	 * checks.
	 */
	private static function byteRuns(codes: Array<Int>): Array<{ lo: Int, hi: Int }> {
		final sorted: Array<Int> = codes.copy();
		sorted.sort((a, b) -> a - b);
		final runs: Array<{ lo: Int, hi: Int }> = [];
		var i: Int = 0;
		while (i < sorted.length) {
			var last: Int = i;
			while (last + 1 < sorted.length && sorted[last + 1] == sorted[last] + 1) last++;
			runs.push({ lo: sorted[i], hi: sorted[last] });
			i = last + 1;
		}
		return runs;
	}

	/**
	 * The byte-code set an emitted `byteSetTerms` or-chain over `local`
	 * tests for — `null` for any expression that is not one, so no other
	 * condition can be mistaken for a first-byte guard.
	 *
	 * Deliberately NOT one shape wider than `byteSetTerms` emits: this is the
	 * READING half of the claim/emission check `checkRuleFirstToken` runs, and a
	 * reader that accepts something the writer cannot produce is a hole in exactly
	 * that check. `orChain` folds bare `EBinop` nodes with no parentheses, and a
	 * run of one is always an equality, so there is no `EParenthesis` arm and no
	 * `lo == hi` range arm here.
	 */
	private static function byteSetOf(cond: Expr, local: String): Null<Array<Int>> {
		return switch cond.expr {
			case EBinop(OpBoolOr, left, right):
				final a: Null<Array<Int>> = byteSetOf(left, local);
				final b: Null<Array<Int>> = byteSetOf(right, local);
				if (a == null || b == null)
					null;
				else {
					for (code in b) if (!a.contains(code)) a.push(code);
					a;
				}
			case EBinop(OpEq, { expr: EConst(CIdent(name)) }, { expr: EConst(CInt(code, _)) }) if (name == local):
				final v: Null<Int> = Std.parseInt(code);
				v == null ? null : [v];
			case EBinop(
				OpBoolAnd, { expr: EBinop(OpGte, { expr: EConst(CIdent(loName)) }, { expr: EConst(CInt(lo, _)) }) },
				{ expr: EBinop(OpLte, { expr: EConst(CIdent(hiName)) }, { expr: EConst(CInt(hi, _)) }) }
			) if (loName == local && hiName == local):
				final from: Null<Int> = Std.parseInt(lo);
				final to: Null<Int> = Std.parseInt(hi);
				from == null || to == null || to < from ? null : [for (c in from ... to + 1) c];
			case _:
				null;
		};
	}

	/**
	 * `starGateExpr` in splice-ready form, for the loops that always have
	 * a slot for the gate: an empty block when the fact is `Unknown`, which
	 * the codegen erases, leaving the loop exactly what it was.
	 */
	private static function starGateStep(first: BranchFirstToken, exitArm: Expr): Expr {
		return starGateExpr(first, exitArm) ?? macro {};
	}

	/**
	 * The orphan-trail bookkeeping a `@:fmt(nestBody)` trivia Star runs
	 * when the terminating element parse ends its loop.
	 *
	 * Shared by the sep and no-sep loops, and spliced into BOTH the catch
	 * arm and the first-token gate of each, so no exit path can drift from
	 * the others.
	 */
	private static function starNestExitArm(trailBBLocal: String, trailLCLocal: String, trailBALocal: String): Expr {
		return macro {
			if (!_lead.blankBefore && _lead.leadingComments.length > 0) {
				$i{trailBBLocal} = _lead.blankBefore;
				$i{trailLCLocal} = _lead.leadingComments;
				$i{trailBALocal} = _lead.blankAfterLeadingComments;
				ctx.pos = _afterTriviaPos;
			} else {
				ctx.pos = _savedPos;
			}
			break;
		};
	}

	/**
	 * Call-site first-token gate for a `@:tryparse` Star loop: a declared
	 * local plus the same or-chain the Alt dispatch guards use, and the
	 * loop's own exit bookkeeping when the chain says the element rule
	 * cannot start here.
	 *
	 * Deliberately NOT a `throw` of the backtrack sentinel — avoiding the
	 * throw is the entire point. The loop's termination is a NORMAL exit,
	 * so the gate runs the exact `Expr` the catch arm runs (the caller
	 * splices one value into both places) and falls out of the loop.
	 *
	 * `null` when the fact is `Unknown`, which every caller turns back into
	 * its pre-gate loop shape, byte for byte.
	 */
	private static function starGateExpr(first: BranchFirstToken, exitArm: Expr): Null<Expr> {
		final guard: Null<Expr> = branchGuardExpr(first, STAR_GATE_BYTE_LOCAL, STAR_GATE_WORD_LOCAL);
		if (guard == null) return null;
		// A word-shaped fact needs `peekWord`'s word-boundary semantics; a
		// byte fact needs the raw code, where `Input.charCodeAt` answering
		// -1 past the end makes an explicit bounds test unnecessary.
		final peek: Expr = switch first {
			case FirstKw(_): finalLocal(STAR_GATE_WORD_LOCAL, macro :String, macro peekWord(ctx));
			case _: finalLocal(STAR_GATE_BYTE_LOCAL, macro :Int, macro ctx.input.charCodeAt(ctx.pos));
		};
		return macro {
			$peek;
			if (!$guard) $exitArm;
		};
	}

	/**
	 * Fold one branch's alternative first-token tests into a single `||`
	 * chain. `litFirst` / `wordOrByteFirst` never produce an empty term
	 * list — an empty set already degrades to `Unknown`, which
	 * `branchGuardExpr` answers with `null` instead of calling here — so
	 * the empty case is a broken classifier, not a possible grammar, and
	 * halts the build.
	 */
	private static function orChain(terms: Array<Expr>): Expr {
		if (terms.length == 0) {
			Context.fatalError('Lowering: orChain on an empty term list (a BranchFirstToken with no terms)', Context.currentPos());
			throw 'unreachable';
		}
		var chain: Expr = terms[0];
		for (i in 1...terms.length) {
			final term: Expr = terms[i];
			chain = macro $chain || $term;
		}
		return chain;
	}

}
#end
