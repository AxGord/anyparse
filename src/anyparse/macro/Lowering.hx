package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.ExprTools;
import haxe.macro.MacroStringTools;
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;

using anyparse.macro.MetaInspect;

/**
 * Pass 3 of the macro pipeline — lowering.
 *
 * Walks the shape tree produced by `ShapeBuilder` (after the strategy
 * annotation pass has written the `lit.*`, `re.*`, `skip.*` slots on
 * each node) and emits one `GeneratedRule` per top-level type in the
 * grammar. Each rule's body uses unqualified helper names (`skipWs`,
 * `matchLit`, `expectLit`, `parseXxx`) that Codegen injects into the
 * same class, plus `$p{...}` expressions for cross-package type and
 * constructor references.
 *
 * Phase 2 ships three rule shapes: enum Alt rules (construct a named
 * enum constructor per branch), typedef Seq rules (build an anonymous
 * struct literal), and Terminal rules (run an `EReg` and decode the
 * matched slice). Structural CoreIR primitives (`Lit`, `Re`, `Seq`,
 * `Alt`, `Star`, `Opt`, `Ref`, `Empty`) are used to describe each rule
 * conceptually; the emitter produces the concrete Haxe expression
 * directly rather than round-tripping through a separate `CoreIR →
 * Expr` serializer, which would double the code with no observable
 * benefit until Phase 3 adds more primitive variants.
 */
class Lowering {

	private final shape:ShapeBuilder.ShapeResult;
	private final formatInfo:FormatReader.FormatInfo;
	private final ctx:LoweringCtx;
	private final eregByRule:Map<String, GeneratedRule.EregSpec> = new Map();

	public function new(shape:ShapeBuilder.ShapeResult, formatInfo:FormatReader.FormatInfo, ctx:LoweringCtx) {
		this.shape = shape;
		this.formatInfo = formatInfo;
		this.ctx = ctx;
	}

	public function generate():Array<GeneratedRule> {
		final rules:Array<GeneratedRule> = [];
		for (typePath => node in shape.rules) for (rule in lowerRule(typePath, node)) rules.push(rule);
		return rules;
	}

	private function lowerRule(typePath:String, node:ShapeNode):Array<GeneratedRule> {
		final simple:String = simpleName(typePath);
		final fnName:String = parseFnName(typePath);
		final returnCT:ComplexType = ruleReturnCT(typePath);
		// `eregByRule` is populated as a side-effect of `lowerTerminal`, so
		// every branch that builds the body must run before we read back
		// the registered eregs. The loop-vs-atom Pratt split hangs the
		// eregs off the loop rule (which is the public entry point for
		// the enum); the atom sub-rule has none of its own.
		final rules:Array<GeneratedRule> = switch node.kind {
			case Alt if (hasPrattBranch(node) && hasPostfixBranch(node)):
				// Pratt + postfix enum: emit three rules.
				//  * `parseXxx(ctx, ?minPrec = 0)` — the precedence-climbing loop
				//    (public entry, called via the `parse` wrapper).
				//  * `parseXxxAtom(ctx)` — the atom WRAPPER. Calls `parseXxxAtomCore`
				//    to get an underlying atom, then runs `lowerPostfixLoop` around
				//    the result, applying postfix operators left-recursively. Every
				//    caller that wants a "complete atom with any attached postfix"
				//    uses this function — the Pratt loop for left/right operands,
				//    and Case 5 prefix's operand recursion.
				//  * `parseXxxAtomCore(ctx)` — the actual tryBranch chain over
				//    non-operator branches (atoms + prefix). Never called directly
				//    except by `parseXxxAtom`.
				//
				// Prefix's `recurseFnName` targets `parseXxxAtom` (the wrapper),
				// so `-a.b` parses as `Neg(FieldAccess(a, b))`: prefix's operand
				// goes through the wrapper, which applies postfix to `a` before
				// the prefix ctor wraps the result.
				final wrapperFnName:String = '${fnName}Atom';
				final coreFnName:String = '${fnName}AtomCore';
				final loopBody:Expr = lowerPrattLoop(node, typePath, simple);
				final wrapperBody:Expr = lowerPostfixLoop(node, typePath, simple, coreFnName);
				final coreBody:Expr = lowerEnum(node, typePath, /* atomsOnly */ true, wrapperFnName);
				final eregs:Array<GeneratedRule.EregSpec> = collectEregs(typePath);
				final loopRule:GeneratedRule = new GeneratedRule(fnName, returnCT, loopBody, eregs, true);
				final wrapperRule:GeneratedRule = new GeneratedRule(wrapperFnName, returnCT, wrapperBody, [], false);
				final coreRule:GeneratedRule = new GeneratedRule(coreFnName, returnCT, coreBody, [], false);
				[loopRule, wrapperRule, coreRule];
			case Alt if (hasPrattBranch(node)):
				// Pratt-enabled enum (no postfix): emit two rules sharing the same return type.
				//  * `parseXxx(ctx, ?minPrec = 0)` — the precedence-climbing loop
				//    (primary public entry; the regular `parse` wrapper calls it).
				//  * `parseXxxAtom(ctx)` — the atoms-only dispatcher covering the
				//    non-infix enum branches through the existing Cases 1–4 of
				//    `lowerEnumBranch`. The Pratt loop calls this for the left
				//    operand, then repeatedly for every right operand as long as
				//    the next peeked operator's precedence meets `minPrec`.
				//
				// The two rules deliberately share a return type but differ in
				// signature: the loop rule takes `?minPrec` so recursion inside
				// the loop can climb levels, whereas external callers
				// (`parseHxVarDecl` → `parseHxExpr(ctx)`) drop the parameter via
				// its default value, keeping every other rule's call sites
				// untouched.
				final atomFnName:String = '${fnName}Atom';
				final loopBody:Expr = lowerPrattLoop(node, typePath, simple);
				final atomBody:Expr = lowerEnum(node, typePath, /* atomsOnly */ true, atomFnName);
				final eregs:Array<GeneratedRule.EregSpec> = collectEregs(typePath);
				final loopRule:GeneratedRule = new GeneratedRule(fnName, returnCT, loopBody, eregs, true);
				final atomRule:GeneratedRule = new GeneratedRule(atomFnName, returnCT, atomBody, [], false);
				[loopRule, atomRule];
			case Alt if (hasPostfixBranch(node)):
				// Postfix-only enum (no Pratt): emit two rules.
				//  * `parseXxx(ctx)` — the atom WRAPPER, also the public entry.
				//    Calls `parseXxxCore` then runs `lowerPostfixLoop` around the
				//    result.
				//  * `parseXxxCore(ctx)` — the atom core (tryBranch chain over
				//    non-postfix branches).
				//
				// Prefix's `recurseFnName` targets `parseXxx` — the wrapper — so
				// any prefix operator's operand flows through postfix application
				// before the prefix ctor wraps it. This branch is not exercised
				// by HxExpr (which has both Pratt and postfix), but keeps the
				// logic general for future postfix-only enums.
				final coreFnName:String = '${fnName}Core';
				final wrapperBody:Expr = lowerPostfixLoop(node, typePath, simple, coreFnName);
				final coreBody:Expr = lowerEnum(node, typePath, /* atomsOnly */ true, fnName);
				final eregs:Array<GeneratedRule.EregSpec> = collectEregs(typePath);
				final wrapperRule:GeneratedRule = new GeneratedRule(fnName, returnCT, wrapperBody, eregs, false);
				final coreRule:GeneratedRule = new GeneratedRule(coreFnName, returnCT, coreBody, [], false);
				[wrapperRule, coreRule];
			case Alt:
				final body:Expr = lowerEnum(node, typePath, false, fnName);
				[new GeneratedRule(fnName, returnCT, body, collectEregs(typePath))];
			case Seq:
				final body:Expr = lowerStruct(node, typePath);
				[new GeneratedRule(fnName, returnCT, body, collectEregs(typePath))];
			case Terminal:
				final body:Expr = lowerTerminal(node, typePath, simple);
				[new GeneratedRule(fnName, returnCT, body, collectEregs(typePath))];
			case _:
				Context.fatalError('Lowering: cannot lower top-level ${node.kind} for $typePath', Context.currentPos());
				throw 'unreachable';
		};
		// `@:raw` on a grammar type suppresses all `skipWs(ctx)` calls in
		// the generated parse function(s) for that rule. Used for string
		// content and other whitespace-sensitive zones where the parser must
		// NOT consume spaces between tokens. The caller's skipWs (in the
		// non-raw parent rule) handles whitespace before the raw rule's
		// entry point; inside the raw rule, every character is significant.
		if (node.hasMeta(':raw') || formatInfo.isBinary)
			for (rule in rules) rule.body = stripSkipWs(rule.body);
		return rules;
	}

	private function collectEregs(typePath:String):Array<GeneratedRule.EregSpec> {
		final eregs:Array<GeneratedRule.EregSpec> = [];
		if (eregByRule.exists(typePath)) eregs.push(eregByRule.get(typePath));
		return eregs;
	}

	private static function hasPrattBranch(node:ShapeNode):Bool {
		for (branch in node.children) {
			if (branch.annotations.get('pratt.prec') != null || branch.annotations.get('ternary.op') != null) return true;
		}
		return false;
	}

	private static function hasPostfixBranch(node:ShapeNode):Bool {
		for (branch in node.children) if (branch.annotations.get('postfix.op') != null) return true;
		return false;
	}

	/** Returns the operator literal for a branch in the Pratt dispatch chain.
	 *  Binary infix branches carry `pratt.op`; ternary branches carry `ternary.op`. */
	private static function getOperatorText(branch:ShapeNode):String {
		return (branch.annotations.get('pratt.op') : Null<String>) ?? branch.annotations.get('ternary.op');
	}

	// -------- enum rule --------

	/**
	 * Lower an enum `ShapeNode` into the body of its `parseXxx` function.
	 *
	 * `atomsOnly` controls whether operator-shaped branches are excluded.
	 * When true, both Pratt-annotated (`pratt.prec`) and postfix-annotated
	 * (`postfix.op`) branches are filtered out — those operators are
	 * handled by separate generated rules (`lowerPrattLoop` for Pratt,
	 * `lowerPostfixLoop` for postfix). Prefix branches (`prefix.op`) are
	 * left in, because prefix is an atom-producing form (consumes one
	 * operand and builds a value) that belongs alongside the leaf cases.
	 *
	 * `recurseFnName` is the name of the function whose body `tryBranch`
	 * should target as the recursion point for prefix operands. It is
	 * passed down through `tryBranch` → `lowerEnumBranch` to Case 5
	 * (unary prefix), where a `@:prefix` branch's operand recursion
	 * targets this function. The caller picks a name that yields the
	 * correct binding-tightness:
	 *
	 *  - For a plain enum: the function's own name (`parseXxx`).
	 *  - For a Pratt enum (no postfix): the atom function name
	 *    (`parseXxxAtom`) — NOT the Pratt loop, so `-x * 2` parses as
	 *    `Mul(Neg(x), 2)`.
	 *  - For a Pratt + postfix enum: the atom WRAPPER name
	 *    (`parseXxxAtom`, which is now the postfix-extended wrapper
	 *    around `parseXxxAtomCore`) — so prefix's operand gets postfix
	 *    applied before the prefix ctor wraps it, yielding
	 *    `Neg(FieldAccess(a, b))` for `-a.b`.
	 *  - For a postfix-only enum: the wrapper name (`parseXxx` itself,
	 *    which wraps `parseXxxCore`) — same semantics, prefix's operand
	 *    gets postfix before the prefix ctor wraps it.
	 */
	private function lowerEnum(node:ShapeNode, typePath:String, atomsOnly:Bool, recurseFnName:String):Expr {
		final branches:Array<ShapeNode> = atomsOnly
			? [
				for (b in node.children)
					if (b.annotations.get('pratt.prec') == null && b.annotations.get('postfix.op') == null && b.annotations.get('ternary.op') == null) b
			]
			: node.children;
		final branchExprs:Array<Expr> = [for (branch in branches) tryBranch(branch, typePath, recurseFnName)];
		final failExpr:Expr = macro throw new anyparse.runtime.ParseError(
			new anyparse.runtime.Span(ctx.pos, ctx.pos),
			$v{'expected ${simpleName(typePath)}'}
		);
		final statements:Array<Expr> = branchExprs.concat([failExpr]);
		return macro $b{statements};
	}

	/**
	 * Lower the Pratt-loop body for a `@:infix`-annotated enum. The body
	 * implements a standard precedence-climbing loop:
	 *
	 * ```
	 *   var left = parseXxxAtom(ctx);
	 *   while (true) {
	 *       skipWs(ctx);
	 *       final _savedPos = ctx.pos;
	 *       // Operators are dispatched longest-first — the branches
	 *       // are sorted by literal length descending before the
	 *       // chain is folded, so `<=` is tried before `<` and the
	 *       // naive `matchLit` cannot eat a short prefix of a longer
	 *       // operator. Declaration order is irrelevant to dispatch.
	 *       if (matchLit(ctx, "<op1>")) { ... }
	 *       else if (matchLit(ctx, "<op2>")) { ... }
	 *       else break;
	 *   }
	 *   return left;
	 * ```
	 *
	 * Each matched branch checks the operator's precedence against
	 * `minPrec`: if it falls below, the matched literal is rolled back and
	 * the loop breaks — the operator belongs to an outer caller. Otherwise
	 * the right operand is parsed by recursing into `parseXxx` itself at
	 * an elevated `minPrec`, and `left` is replaced with a freshly
	 * constructed ctor call built from the matched branch.
	 *
	 * Associativity is read from the `pratt.assoc` annotation on each
	 * branch (written by `Pratt.annotate`). Left-associative branches
	 * recurse at `prec + 1`, so a second same-prec operator fails the
	 * inner gate and is re-taken by the outer loop iteration, folding
	 * left. Right-associative branches recurse at `prec`, so a second
	 * same-prec operator is absorbed by the inner recursion, folding
	 * right. The per-branch choice is baked in at macro time — no
	 * runtime switch on associativity.
	 */
	private function lowerPrattLoop(node:ShapeNode, typePath:String, simple:String):Expr {
		final returnCT:ComplexType = ruleReturnCT(typePath);
		final loopFnName:String = parseFnName(typePath);
		final atomFnName:String = '${loopFnName}Atom';
		final atomCall:Expr = {
			expr: ECall(macro $i{atomFnName}, [macro ctx]),
			pos: Context.currentPos(),
		};
		final operatorBranches:Array<ShapeNode> = [
			for (b in node.children)
				if (b.annotations.get('pratt.prec') != null || b.annotations.get('ternary.op') != null) b
		];
		// Longest-match sort: longer operator literals come first in the
		// generated dispatch chain so `<=` is attempted before `<` (and
		// `??` before `?`). Without this, `matchLit(ctx, "<")` succeeds on
		// input `<=`, consumes one char, and leaves `=` stranded for the
		// right operand parser to trip over. The sort is a Lowering-level
		// policy — `matchLit` stays a naive prefix match everywhere else
		// (enum-branch Case 1 `expectLit`, struct lead/trail, Case 4 array
		// loops) where ambiguity cannot arise because the literal is fixed
		// at macro time. Order among equal-length operators is semantically
		// irrelevant (no length-N operator is a prefix of another length-N
		// operator in a well-formed grammar), so `Array.sort` suffices.
		// The sort key uses `pratt.op` for binary infix branches and
		// `ternary.op` for ternary branches — both are operator literals
		// that compete in the same `matchLit` dispatch chain.
		operatorBranches.sort((a, b) -> {
			final la:Int = getOperatorText(a).length;
			final lb:Int = getOperatorText(b).length;
			return lb - la;
		});
		// Fold the operator chain into a nested if/else if tree. Each leaf
		// branch consumes the operator literal (already matched at the
		// peek), enforces `minPrec`, parses the right operand by recursing
		// into `parseXxx` at `prec + 1` for left-associative branches or
		// `prec` for right-associative branches, and rebuilds `left` as
		// the matched ctor call. Ternary branches (detected by `ternary.op`)
		// parse both middle and right operands at `minPrec = 0` (full
		// expression) with an `expectLit` separator in between.
		var opChain:Expr = macro _matched = false;
		for (i in 0...operatorBranches.length) {
			final branch:ShapeNode = operatorBranches[operatorBranches.length - 1 - i];
			final ctor:String = branch.annotations.get('base.ctor');
			final ctorPath:Array<String> = ruleCtorPath(typePath, ctor);
			final ctorRef:Expr = MacroStringTools.toFieldExpr(ctorPath);
			final isTernary:Bool = branch.annotations.get('ternary.op') != null;
			final opText:String = getOperatorText(branch);
			final precValue:Int = isTernary
				? (branch.annotations.get('ternary.prec') : Int)
				: (branch.annotations.get('pratt.prec') : Int);
			final branchBody:Expr = if (isTernary) {
				// Ternary branch: three operands (cond, middle, right).
				// Both middle and right parse at minPrec=0 (full expression).
				final sepText:String = branch.annotations.get('ternary.sep');
				final fullExprCall:Expr = {
					expr: ECall(macro $i{loopFnName}, [macro ctx, macro $v{0}]),
					pos: Context.currentPos(),
				};
				final ctorCall:Expr = {
					expr: ECall(ctorRef, [macro left, macro _middle, macro _right]),
					pos: Context.currentPos(),
				};
				macro {
					if ($v{precValue} < minPrec) {
						ctx.pos = _savedPos;
						_matched = false;
					} else {
						skipWs(ctx);
						final _middle:$returnCT = $fullExprCall;
						skipWs(ctx);
						expectLit(ctx, $v{sepText});
						skipWs(ctx);
						final _right:$returnCT = $fullExprCall;
						left = $ctorCall;
					}
				};
			} else {
				// Binary infix branch: two operands (left, right). The right
				// operand normally recurses into the same Pratt loop at an
				// elevated minPrec to enforce associativity. When the right
				// child references a different enum than the loop's own
				// (asymmetric infix, e.g. `x is Type` where left:HxExpr but
				// right:HxType), recursing into the same loop is wrong — call
				// the other type's parse function once at its default starting
				// precedence and let outer Pratt iteration handle chaining.
				final assocValue:String = branch.annotations.get('pratt.assoc');
				final nextMinPrec:Int = assocValue == 'Right' ? precValue : precValue + 1;
				final rightChildren:Array<ShapeNode> = branch.children;
				final rightChild:ShapeNode = rightChildren[1];
				final rightRef:Null<String> = rightChild.kind == Ref ? rightChild.annotations.get('base.ref') : null;
				final isAsymmetric:Bool = rightRef != null && simpleName(rightRef) != simple;
				final rightCT:ComplexType = isAsymmetric ? ruleReturnCT(rightRef) : returnCT;
				final rightCall:Expr = if (isAsymmetric) {
					expr: ECall(macro $i{parseFnName(rightRef)}, [macro ctx]),
					pos: Context.currentPos(),
				} else {
					expr: ECall(macro $i{loopFnName}, [macro ctx, macro $v{nextMinPrec}]),
					pos: Context.currentPos(),
				};
				final ctorCall:Expr = {
					expr: ECall(ctorRef, [macro left, macro _right]),
					pos: Context.currentPos(),
				};
				macro {
					if ($v{precValue} < minPrec) {
						ctx.pos = _savedPos;
						_matched = false;
					} else {
						skipWs(ctx);
						final _right:$rightCT = $rightCall;
						left = $ctorCall;
					}
				};
			};
			final matchFnName:String = endsWithWordChar(opText) ? 'matchKw' : 'matchLit';
			final matchCall:Expr = {
				expr: ECall(macro $i{matchFnName}, [macro ctx, macro $v{opText}]),
				pos: Context.currentPos(),
			};
			opChain = macro if ($matchCall) $branchBody else $opChain;
		}
		// ω-trivia-sep: in Trivia mode, save pos BEFORE the per-iteration
		// `skipWs`. On no-match, scan the consumed range for comment
		// markers — if any are present, rewind to preserve the comment
		// for a sibling's `collectTrailing` capture (otherwise `field: ""
		// // some comment` loses its trailing comment). Plain whitespace
		// and `\n` stay consumed so `@:raw` siblings (e.g. `${expr}` in
		// string interp, where the trailing literal expects `}` directly
		// without skipWs) keep working: no comment → no rewind.
		if (ctx.trivia) return macro {
			var left:$returnCT = $atomCall;
			while (true) {
				final _preWsPos:Int = ctx.pos;
				skipWs(ctx);
				final _savedPos:Int = ctx.pos;
				var _matched:Bool = true;
				$opChain;
				if (!_matched) {
					var _scanI:Int = _preWsPos;
					var _hadComment:Bool = false;
					while (_scanI + 1 < ctx.pos) {
						if (ctx.input.charCodeAt(_scanI) == '/'.code) {
							final _c2:Int = ctx.input.charCodeAt(_scanI + 1);
							if (_c2 == '/'.code || _c2 == '*'.code) {
								_hadComment = true;
								break;
							}
						}
						_scanI++;
					}
					if (_hadComment) ctx.pos = _preWsPos;
					break;
				}
			}
			return left;
		};
		return macro {
			var left:$returnCT = $atomCall;
			while (true) {
				skipWs(ctx);
				final _savedPos:Int = ctx.pos;
				var _matched:Bool = true;
				$opChain;
				if (!_matched) break;
			}
			return left;
		};
	}

	private function tryBranch(branch:ShapeNode, typePath:String, recurseFnName:String):Expr {
		final body:Expr = lowerEnumBranch(branch, typePath, recurseFnName);
		return macro {
			final _savedPos:Int = ctx.pos;
			try $body catch (_e:anyparse.runtime.ParseError) ctx.pos = _savedPos;
		};
	}

	/**
	 * Lower the postfix-loop body for a `@:postfix`-annotated enum. The
	 * body runs inside the atom wrapper function and looks like:
	 *
	 * ```
	 *   var left = parseXxxAtomCore(ctx);
	 *   while (true) {
	 *       skipWs(ctx);
	 *       var _matched:Bool = true;
	 *       if (matchLit(ctx, "(")) { skipWs; expectLit(")"); left = Ctor(left); }
	 *       else if (matchLit(ctx, "[")) { skipWs; _i = parseXxx(ctx); skipWs; expectLit("]"); left = Ctor(left, _i); }
	 *       else if (matchLit(ctx, ".")) { skipWs; _f = parseHxIdentLit(ctx); left = Ctor(left, _f); }
	 *       else _matched = false;
	 *       if (!_matched) break;
	 *   }
	 *   return left;
	 * ```
	 *
	 * There is no precedence gate and no `_savedPos` rollback. Once a
	 * postfix operator matches, the body commits: a failing inner parse
	 * (e.g. unclosed `[`) throws `ParseError` upward as a hard error.
	 * The loop only terminates by exhausting the dispatch chain — none
	 * of the peeked operators matched, so the postfix-extended atom is
	 * complete and control returns to the caller (usually the Pratt
	 * loop, which then tries its own operators around `left`).
	 *
	 * Longest-first sort on `postfix.op` (same pattern as `lowerPrattLoop`
	 * D33) keeps declaration order irrelevant to dispatch. For slice δ1
	 * the three shipping ops (`.`, `[`, `(`) have unique first characters
	 * so the sort is a no-op, but the guarantee holds for future
	 * shared-prefix cases (e.g. hypothetical `?.` vs `?`).
	 *
	 * Each branch picks one of three body shapes based on a combination
	 * of `postfix.close` presence and the branch's children:
	 *
	 *  1. **pair-lit (call-no-args)** — 1 child (operand only),
	 *     `postfix.close` set. Body: expect close literal, build
	 *     `Ctor(left)`.
	 *  2. **single-Ref-suffix (field access)** — 2 children (operand +
	 *     suffix Ref), `postfix.close` absent. Body: parse the suffix
	 *     Ref, build `Ctor(left, suffix)`. The suffix Ref typically
	 *     points at a Terminal like `HxIdentLit`.
	 *  3. **wrap-with-recurse (index access)** — 2 children (operand +
	 *     inner Ref), `postfix.close` set. Body: parse the inner Ref
	 *     (typically `SelfType`, a full recursive expression), expect
	 *     close, build `Ctor(left, inner)`.
	 *
	 * Validation of the operand child (must be `Ref` to same enum) and
	 * symbolic-op check (no word-like postfix ops yet) run at macro
	 * time — word-like ops would need a word-boundary-aware match helper
	 * which is not wired for postfix in this slice.
	 */
	private function lowerPostfixLoop(node:ShapeNode, typePath:String, simple:String, coreFnName:String):Expr {
		final returnCT:ComplexType = ruleReturnCT(typePath);
		final enumSimple:String = simple;
		final selfFnName:String = parseFnName(typePath);
		final coreCall:Expr = {
			expr: ECall(macro $i{coreFnName}, [macro ctx]),
			pos: Context.currentPos(),
		};
		final postfixBranches:Array<ShapeNode> = [
			for (b in node.children) if (b.annotations.get('postfix.op') != null) b
		];
		if (postfixBranches.length == 0) {
			Context.fatalError('Lowering: lowerPostfixLoop called with no postfix branches', Context.currentPos());
		}
		// Longest-first sort — same macro-time policy as lowerPrattLoop (D33).
		postfixBranches.sort((a, b) -> {
			final la:Int = (a.annotations.get('postfix.op') : String).length;
			final lb:Int = (b.annotations.get('postfix.op') : String).length;
			return lb - la;
		});
		// Cross-category longer-prefix resolution: a postfix op that is a
		// strict prefix of another op in the same enum (postfix, infix, or
		// ternary) must lose to that longer op. Without this, postfix `.`
		// commits on the first `.` of `...` — then fails to parse a
		// following HxIdentLit and throws upward, rewinding past the entire
		// HxVarDecl/HxClassMember/… chain. Collecting ALL op literals on
		// the enum lets us emit a `!peekLit(longer)` guard per conflict so
		// the postfix dispatch declines and Pratt picks up the longer op.
		final allOps:Array<String> = [];
		for (b in node.children) {
			final po:Null<String> = b.annotations.get('postfix.op');
			if (po != null) allOps.push(po);
			final pr:Null<String> = b.annotations.get('pratt.op');
			if (pr != null) allOps.push(pr);
			final tr:Null<String> = b.annotations.get('ternary.op');
			if (tr != null) allOps.push(tr);
		}
		// Fold the dispatch chain right-to-left, mirroring lowerPrattLoop.
		var opChain:Expr = macro _matched = false;
		for (i in 0...postfixBranches.length) {
			final branch:ShapeNode = postfixBranches[postfixBranches.length - 1 - i];
			final op:String = branch.annotations.get('postfix.op');
			final close:Null<String> = branch.annotations.get('postfix.close');
			final ctor:String = branch.annotations.get('base.ctor');
			if (endsWithWordChar(op)) {
				Context.fatalError(
					'Lowering: @:postfix operator must be symbolic (word-like postfix ops not supported yet): "$op"',
					Context.currentPos()
				);
			}
			final children:Array<ShapeNode> = branch.children;
			if (children.length == 0 || children[0].kind != Ref) {
				Context.fatalError(
					'Lowering: @:postfix branch "$ctor" must have operand:$enumSimple as its first argument',
					Context.currentPos()
				);
			}
			final operandRef:String = children[0].annotations.get('base.ref');
			if (simpleName(operandRef) != enumSimple) {
				Context.fatalError(
					'Lowering: @:postfix operand must reference the same enum ($enumSimple)',
					Context.currentPos()
				);
			}
			final ctorPath:Array<String> = ruleCtorPath(typePath, ctor);
			final ctorRef:Expr = MacroStringTools.toFieldExpr(ctorPath);
			final branchBody:Expr = if (children.length == 1) {
				if (close == null) {
					Context.fatalError(
						'Lowering: @:postfix single-child branch "$ctor" requires @:postfix(open, close) pair form',
						Context.currentPos()
					);
					throw 'unreachable';
				}
				final ctorCall:Expr = {expr: ECall(ctorRef, [macro left]), pos: Context.currentPos()};
				macro {
					skipWs(ctx);
					expectLit(ctx, $v{close});
					left = $ctorCall;
				};
			} else if (children.length == 2 && children[1].kind == Star) {
				// Star-suffix form: `Call(operand:T, args:Array<T>)` with
				// @:postfix('(', ')') @:sep(','). The Star child wraps
				// a Ref to the element type. After the open literal is
				// consumed by the outer matchLit, this branch emits a
				// sep-peek array loop (same pattern as Case 4 in
				// lowerEnumBranch) and then expects the close literal.
				if (close == null) {
					Context.fatalError(
						'Lowering: @:postfix Star-suffix branch "$ctor" requires @:postfix(open, close) pair form',
						Context.currentPos()
					);
					throw 'unreachable';
				}
				final starNode:ShapeNode = children[1];
				final inner:ShapeNode = starNode.children[0];
				if (inner.kind != Ref) {
					Context.fatalError(
						'Lowering: @:postfix Star child must be a Ref',
						Context.currentPos()
					);
					throw 'unreachable';
				}
				final elemRefName:String = inner.annotations.get('base.ref');
				final elemFn:String = simpleName(elemRefName) == enumSimple
					? selfFnName
					: parseFnName(elemRefName);
				final elemCall:Expr = {
					expr: ECall(macro $i{elemFn}, [macro ctx]),
					pos: Context.currentPos(),
				};
				final elemCT:ComplexType = ruleReturnCT(elemRefName);
				// See struct-field close-peek (emitStarFieldSteps) for why
				// we flip to full-string `peekLit` when close is multi-byte.
				final closeCharCode:Int = close.charCodeAt(0);
				final closeNotNextExpr:Expr = close.length == 1
					? macro ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}
					: macro ctx.pos < ctx.input.length && !peekLit(ctx, $v{close});
				final sepText:Null<String> = branch.annotations.get('lit.sepText');
				final ctorCall:Expr = {expr: ECall(ctorRef, [macro left, macro _args]), pos: Context.currentPos()};
				if (sepText != null) {
					final sepCharCode:Int = sepText.charCodeAt(0);
					macro {
						skipWs(ctx);
						final _args:Array<$elemCT> = [];
						if ($closeNotNextExpr) {
							_args.push($elemCall);
							skipWs(ctx);
							while (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
								ctx.pos++;
								skipWs(ctx);
								_args.push($elemCall);
								skipWs(ctx);
							}
						}
						skipWs(ctx);
						expectLit(ctx, $v{close});
						left = $ctorCall;
					};
				} else {
					// No separator — peek-close loop (same as Case 4 no-sep).
					macro {
						skipWs(ctx);
						final _args:Array<$elemCT> = [];
						while ($closeNotNextExpr) {
							_args.push($elemCall);
							skipWs(ctx);
						}
						skipWs(ctx);
						expectLit(ctx, $v{close});
						left = $ctorCall;
					};
				}
			} else if (children.length == 2) {
				final suffix:ShapeNode = children[1];
				if (suffix.kind != Ref) {
					Context.fatalError(
						'Lowering: @:postfix branch "$ctor" second argument must be a Ref',
						Context.currentPos()
					);
					throw 'unreachable';
				}
				final suffixRef:String = suffix.annotations.get('base.ref');
				// For the wrap-with-recurse form, the inner Ref typically points
				// at SelfType — to force a full expression parse reset we call
				// `parseXxx` directly (via its public entry) rather than the
				// atom wrapper. This lets a `[a + b]` index expression contain
				// arbitrary infix operators. For the single-Ref-suffix form,
				// the suffix is usually a Terminal like HxIdentLit and the
				// `parseXxxSuffix` call is just a terminal call.
				final suffixFn:String = simpleName(suffixRef) == enumSimple
					? selfFnName
					: parseFnName(suffixRef);
				final suffixCall:Expr = {
					expr: ECall(macro $i{suffixFn}, [macro ctx]),
					pos: Context.currentPos(),
				};
				final suffixCT:ComplexType = ruleReturnCT(suffixRef);
				final ctorCall:Expr = {expr: ECall(ctorRef, [macro left, macro _suffix]), pos: Context.currentPos()};
				if (close == null) {
					macro {
						skipWs(ctx);
						final _suffix:$suffixCT = $suffixCall;
						left = $ctorCall;
					};
				} else {
					macro {
						skipWs(ctx);
						final _suffix:$suffixCT = $suffixCall;
						skipWs(ctx);
						expectLit(ctx, $v{close});
						left = $ctorCall;
					};
				}
			} else {
				Context.fatalError(
					'Lowering: @:postfix branch "$ctor" has ${children.length} arguments; expected 1 (pair-lit), 2 (suffix/Star form)',
					Context.currentPos()
				);
				throw 'unreachable';
			};
			// Prepend `!peekLit(longerOp)` guards for every op literal that
			// strictly starts with `op`. Short-circuits so matchLit is not
			// called when a longer op is about to match.
			var matchExpr:Expr = macro matchLit(ctx, $v{op});
			for (other in allOps) {
				if (other.length > op.length && StringTools.startsWith(other, op)) {
					matchExpr = macro !peekLit(ctx, $v{other}) && $matchExpr;
				}
			}
			opChain = macro if ($matchExpr) $branchBody else $opChain;
		}
		// ω-trivia-sep: same pre-skipWs save + comment-only rewind as
		// `lowerPrattLoop`. See that function for the rationale.
		if (ctx.trivia) return macro {
			var left:$returnCT = $coreCall;
			while (true) {
				final _preWsPos:Int = ctx.pos;
				skipWs(ctx);
				var _matched:Bool = true;
				$opChain;
				if (!_matched) {
					var _scanI:Int = _preWsPos;
					var _hadComment:Bool = false;
					while (_scanI + 1 < ctx.pos) {
						if (ctx.input.charCodeAt(_scanI) == '/'.code) {
							final _c2:Int = ctx.input.charCodeAt(_scanI + 1);
							if (_c2 == '/'.code || _c2 == '*'.code) {
								_hadComment = true;
								break;
							}
						}
						_scanI++;
					}
					if (_hadComment) ctx.pos = _preWsPos;
					break;
				}
			}
			return left;
		};
		return macro {
			var left:$returnCT = $coreCall;
			while (true) {
				skipWs(ctx);
				var _matched:Bool = true;
				$opChain;
				if (!_matched) break;
			}
			return left;
		};
	}

	private function lowerEnumBranch(branch:ShapeNode, typePath:String, recurseFnName:String):Expr {
		final ctor:String = branch.annotations.get('base.ctor');
		final ctorPath:Array<String> = ruleCtorPath(typePath, ctor);
		final ctorRef:Expr = MacroStringTools.toFieldExpr(ctorPath);

		// Case 5: unary-prefix branch. A `@:prefix("-")` annotated ctor
		// with a single `Ref` child that references the same enum. The
		// body consumes the prefix literal, recurses into `recurseFnName`
		// (the function currently being generated — atom function for
		// Pratt enums, whole enum for plain enums), and builds the ctor
		// around the returned operand. This case must run BEFORE the
		// existing Cases 1/2/4/3, because a prefix branch structurally
		// matches Case 3 ("single `Ref` child, no `@:lit`") and Case 3
		// would emit a body with no `expectLit` — an unguarded recursive
		// call into the main expression rule that never consumes input
		// and infinite-loops.
		//
		// The recursive call deliberately targets `recurseFnName` (the
		// atom function for Pratt enums), not the Pratt loop: the operand
		// of a prefix is a single atom (possibly another prefix), not a
		// whole expression. `-x * 2` parses as `Mul(Neg(x), 2)` because
		// the atom returned to the outer Pratt loop is already `Neg(x)`,
		// and the loop then picks up `* 2` around it.
		//
		// Word-like prefix operators are rejected at compile time: the
		// body uses `expectLit` with no word-boundary check, which would
		// wrongly accept `notx` for `not`. When a grammar needs word-like
		// prefix ops, extend Case 5 to route through `expectKw` the same
		// way Cases 1 and 2 dispatch by `endsWithWordChar`.
		final prefixOp:Null<String> = branch.annotations.get('prefix.op');
		if (prefixOp != null) {
			final children:Array<ShapeNode> = branch.children;
			if (children.length != 1 || children[0].kind != Ref) {
				Context.fatalError(
					'Lowering: @:prefix branch must have exactly one Ref child (the operand)',
					Context.currentPos()
				);
			}
			final refName:String = children[0].annotations.get('base.ref');
			final enumSimple:String = simpleName(typePath);
			if (simpleName(refName) != enumSimple) {
				Context.fatalError(
					'Lowering: @:prefix operand must reference the same enum ($enumSimple)',
					Context.currentPos()
				);
			}
			if (endsWithWordChar(prefixOp)) {
				Context.fatalError(
					'Lowering: @:prefix operator must be symbolic (word-like prefix ops not supported yet): "$prefixOp"',
					Context.currentPos()
				);
			}
			final operandCT:ComplexType = ruleReturnCT(typePath);
			final recurseCall:Expr = {
				expr: ECall(macro $i{recurseFnName}, [macro ctx]),
				pos: Context.currentPos(),
			};
			final ctorCall:Expr = {expr: ECall(ctorRef, [macro _operand]), pos: Context.currentPos()};
			return macro {
				skipWs(ctx);
				expectLit(ctx, $v{prefixOp});
				skipWs(ctx);
				final _operand:$operandCT = $recurseCall;
				return $ctorCall;
			};
		}

		// Case 0: zero-arg ctor with @:kw (no @:lit). Parallel to Case 1
		// but driven by the Kw strategy annotation instead of the Lit
		// strategy. Emits `expectKw` with word-boundary enforcement.
		// Used by modifier enums where each ctor is a bare keyword.
		// When @:trail is present (e.g. `@:kw('return') @:trail(';')
		// VoidReturnStmt`), the trail literal is emitted unconditionally
		// after the keyword (D48).
		final kwLeadBranch:Null<String> = branch.annotations.get('kw.leadText');
		if (kwLeadBranch != null && branch.children.length == 0 && branch.annotations.get('lit.litList') == null) {
			final trailBranch:Null<String> = branch.annotations.get('lit.trailText');
			if (trailBranch != null) {
				return macro {
					skipWs(ctx);
					expectKw(ctx, $v{kwLeadBranch});
					skipWs(ctx);
					expectLit(ctx, $v{trailBranch});
					return $ctorRef;
				};
			}
			return macro {
				skipWs(ctx);
				expectKw(ctx, $v{kwLeadBranch});
				return $ctorRef;
			};
		}

		// Classify branch shape.
		final litList:Null<Array<String>> = branch.annotations.get('lit.litList');
		final children:Array<ShapeNode> = branch.children;
		final leadText:Null<String> = branch.annotations.get('lit.leadText');
		final trailText:Null<String> = branch.annotations.get('lit.trailText');
		final sepText:Null<String> = branch.annotations.get('lit.sepText');

		// Case 1: zero-arg ctor with @:lit(single). When the literal ends
		// with a word character (`null`, `true`, `default`, …), emit the
		// word-boundary-checking `expectKw` instead of `expectLit`, so a
		// partial match on the prefix of a longer identifier (`nullable`,
		// `trueish`) is rejected and the try/catch wrapper in `tryBranch`
		// rolls back to the next branch. Symbolic literals (`;`, `=`, `{`)
		// route through plain `expectLit` — a word boundary after them
		// would falsely reject sequences like `;foo`.
		if (litList != null && litList.length == 1 && children.length == 0) {
			final lit:String = litList[0];
			final expectCall:Expr = endsWithWordChar(lit)
				? macro expectKw(ctx, $v{lit})
				: macro expectLit(ctx, $v{lit});
			return macro {
				skipWs(ctx);
				$expectCall;
				return $ctorRef;
			};
		}

		// Case 2: single-arg ctor with @:lit(multi) — literals map to
		// ident values of the field type. When the first literal ends
		// with a word character, emit `matchKw` (peek + word-boundary)
		// for every dispatch; mixed symbolic / word-like literal sets
		// inside the same `@:lit(...)` are rejected at macro time since
		// their dispatch semantics would be inconsistent.
		if (litList != null && litList.length > 1 && children.length == 1) {
			final wordLike:Bool = endsWithWordChar(litList[0]);
			for (lit in litList) {
				if (endsWithWordChar(lit) != wordLike) {
					Context.fatalError(
						'Lowering: multi-@:lit set mixes word-like and symbolic literals: ${litList.join(", ")}',
						Context.currentPos()
					);
				}
			}
			final matchFnName:String = wordLike ? 'matchKw' : 'matchLit';
			final attempts:Array<Expr> = [];
			for (lit in litList) {
				final valueExpr:Expr = {expr: EConst(CIdent(lit)), pos: Context.currentPos()};
				final call:Expr = {expr: ECall(ctorRef, [valueExpr]), pos: Context.currentPos()};
				final matchCall:Expr = {
					expr: ECall(macro $i{matchFnName}, [macro ctx, macro $v{lit}]),
					pos: Context.currentPos(),
				};
				attempts.push(macro if ($matchCall) return $call);
			}
			final failExpr:Expr = macro throw new anyparse.runtime.ParseError(
				new anyparse.runtime.Span(ctx.pos, ctx.pos),
				$v{'expected one of ${litList.join(", ")}'}
			);
			final body:Array<Expr> = [macro skipWs(ctx)].concat(attempts).concat([failExpr]);
			return macro $b{body};
		}

		// Case 4: single-arg ctor wrapping Array<Ref> with @:lead/@:trail and
		// optional @:sep. No-sep variant terminates the loop by peeking at
		// the close character instead of consuming a separator between items.
		if (leadText != null && trailText != null && children.length == 1 && children[0].kind == Star) {
			final starNode:ShapeNode = children[0];
			final inner:ShapeNode = starNode.children[0];
			if (inner.kind != Ref) {
				Context.fatalError('Lowering: Star child must be a Ref in Phase 2', Context.currentPos());
			}
			final elemRefName:String = inner.annotations.get('base.ref');
			final elemFn:String = parseFnName(elemRefName);
			final elemCT:ComplexType = ruleReturnCT(elemRefName);
			final elemCall:Expr = {
				expr: ECall(macro $i{elemFn}, [macro ctx]),
				pos: Context.currentPos(),
			};
			// See struct-field close-peek (emitStarFieldSteps) for why
			// we flip to full-string `peekLit` when close is multi-byte.
			final closeCharCode:Int = trailText.charCodeAt(0);
			final closeNotNextExpr:Expr = trailText.length == 1
				? macro ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}
				: macro ctx.pos < ctx.input.length && !peekLit(ctx, $v{trailText});
			final closeNextOrEofExpr:Expr = trailText.length == 1
				? macro ctx.pos >= ctx.input.length || ctx.input.charCodeAt(ctx.pos) == $v{closeCharCode}
				: macro ctx.pos >= ctx.input.length || peekLit(ctx, $v{trailText});
			final ctorCall:Expr = {expr: ECall(ctorRef, [macro _items]), pos: Context.currentPos()};
			// Trivia-mode @:trivia Star in an enum branch (e.g. HxStatement.BlockStmt
			// marks its stmts Star via the branch-level @:trivia meta propagated to
			// the Star by TriviaAnalysis). Replace the plain element-push loop with
			// a collectTrivia → parseElement → collectTrailing pipeline that feeds
			// Trivial<T> structs into the accumulator.
			//
			// ω-trivia-sep: `@:sep` is supported alongside `@:trivia` for
			// close-peek Alt branches (e.g. `HxExpr.ArrayExpr` with
			// `@:lead('[') @:trail(']') @:sep(',')`). The sep is matched
			// after each element via `matchLit`, before `collectTrailing`,
			// so a same-line `// comment` after `,` attaches to the
			// just-pushed element.
			if (ctx.trivia && starNode.annotations.get('trivia.starCollects') == true) {
				final wrappedCT:ComplexType = TPath({
					pack: ['anyparse', 'runtime'], name: 'Trivial', params: [TPType(elemCT)]
				});
				// ω-close-trailing-alt: synth ctor of close-peek `@:trivia`
				// Alt branches (e.g. `HxStatementT.BlockStmt`) carries an
				// extra positional `closeTrailing:Null<String>` arg captured
				// here by `collectTrailingFull(ctx)` right after the close
				// literal. The Full variant keeps comment delimiters so the
				// writer can round-trip block-vs-line style (ω-trailing-
				// block-style). Plain mode keeps the 1-arg ctor.
				final ctorCallTrivia:Expr = {
					expr: ECall(ctorRef, [macro _items, macro _closeTrail]),
					pos: Context.currentPos(),
				};
				final sepMatchExpr:Expr = if (sepText != null) {
					// Same horizontal-whitespace-only skip as the struct-field
					// trivia+sep path — avoids `skipWs` consuming the trailing
					// `// comment` before `collectTrailing` runs.
					macro {
						while (ctx.pos < ctx.input.length) {
							final _hwc:Int = ctx.input.charCodeAt(ctx.pos);
							if (_hwc == ' '.code || _hwc == '\t'.code || _hwc == '\r'.code) ctx.pos++;
							else break;
						}
						matchLit(ctx, $v{sepText});
					}
				} else {
					macro {};
				};
				return macro {
					skipWs(ctx);
					expectLit(ctx, $v{leadText});
					final _items:Array<$wrappedCT> = [];
					while (true) {
						final _lead = collectTrivia(ctx);
						if ($closeNextOrEofExpr) break;
						final _node:$elemCT = $elemCall;
						$sepMatchExpr;
						final _trailing:Null<String> = collectTrailing(ctx);
						_items.push({
							blankBefore: _lead.blankBefore,
							blankAfterLeadingComments: _lead.blankAfterLeadingComments,
							newlineBefore: _lead.newlineBefore,
							leadingComments: _lead.leadingComments,
							trailingComment: _trailing,
							node: _node,
						});
					}
					skipWs(ctx);
					expectLit(ctx, $v{trailText});
					final _closeTrail:Null<String> = collectTrailingFull(ctx);
					return $ctorCallTrivia;
				};
			}
			if (sepText != null) {
				final sepCharCode:Int = sepText.charCodeAt(0);
				return macro {
					skipWs(ctx);
					expectLit(ctx, $v{leadText});
					final _items:Array<$elemCT> = [];
					skipWs(ctx);
					if ($closeNotNextExpr) {
						_items.push($elemCall);
						skipWs(ctx);
						while (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
							ctx.pos++;
							skipWs(ctx);
							_items.push($elemCall);
							skipWs(ctx);
						}
					}
					skipWs(ctx);
					expectLit(ctx, $v{trailText});
					return $ctorCall;
				};
			}
			return macro {
				skipWs(ctx);
				expectLit(ctx, $v{leadText});
				final _items:Array<$elemCT> = [];
				skipWs(ctx);
				while ($closeNotNextExpr) {
					_items.push($elemCall);
					skipWs(ctx);
				}
				skipWs(ctx);
				expectLit(ctx, $v{trailText});
				return $ctorCall;
			};
		}

		// Case 3 (extended): single-arg ctor wrapping a Ref, with optional
		// kw/lit lead and optional lit trail. No separator loop — that's
		// Case 4's domain. The lead can be either a `@:kw("...")` keyword
		// (word-boundary checked) or a plain `@:lead("...")` literal; only
		// one of the two is emitted per branch.
		if (litList == null && children.length == 1 && children[0].kind == Ref) {
			final refName:String = children[0].annotations.get('base.ref');
			final callSub:Expr = {
				expr: ECall(macro $i{parseFnName(refName)}, [macro ctx]),
				pos: Context.currentPos(),
			};
			final trailOptional:Bool = branch.annotations.get('lit.trailOptional') == true;
			// ω-trailopt-source-track: in trivia mode, paired Alt ctors
			// of `@:trailOpt(...)` branches carry an extra positional
			// `trailPresent:Bool` arg synthesised by `TriviaTypeSynth`.
			// Pass the captured `matchLit` result through so the writer
			// can preserve source presence of the trail literal.
			final triviaTrailOpt:Bool = trailOptional && ctx.trivia && isTriviaBearing(typePath);
			// ω-string-interp-noformat: ctors with `@:fmt(captureSource)` +
			// `@:lead`/`@:trail` carry a positional `sourceText:String` arg
			// in trivia mode. The parser captures the byte slice between
			// lead and trail (inclusive of any interior whitespace) so the
			// writer can emit verbatim under
			// `opt.formatStringInterpolation == false`. Trivia-only because
			// the synth-pair ctor is the carrier; plain pipelines keep the
			// pre-slice ctor arity.
			final triviaCaptureSource:Bool = ctx.trivia
				&& isTriviaBearing(typePath)
				&& TriviaTypeSynth.isCaptureSourceBranch(branch);
			final ctorArgs:Array<Expr> = [macro _raw];
			if (triviaTrailOpt) ctorArgs.push(macro _trailPresent);
			if (triviaCaptureSource) ctorArgs.push(macro _sourceText);
			final ctorCall:Expr = {expr: ECall(ctorRef, ctorArgs), pos: Context.currentPos()};
			final kwLead:Null<String> = branch.annotations.get('kw.leadText');
			final steps:Array<Expr> = [macro skipWs(ctx)];
			// `@:kw` and `@:wrap`/`@:lead` compose on the same single-Ref
			// branch: emit kw (word-boundary checked) first, then the lead
			// literal. First consumer is `HxMetadata.OverloadMeta` which
			// pairs `@:kw('@:overload')` with `@:wrap('(', ')')` so the
			// keyword commits the branch and the parens delimit the
			// structurally-parsed `HxOverloadArgs` payload. Either or both
			// may be absent — the `@:kw('return')`-only ctors keep their
			// pre-slice shape, and a bare `@:wrap`-only ctor (`ParenExpr`)
			// stays a single-literal commit.
			if (kwLead != null) {
				steps.push(macro expectKw(ctx, $v{kwLead}));
				steps.push(macro skipWs(ctx));
			}
			if (leadText != null) {
				steps.push(macro expectLit(ctx, $v{leadText}));
				steps.push(macro skipWs(ctx));
			}
			// Capture _start_pos AFTER any lead literal AND its skipWs, so
			// the substring spans only what lives between lead and trail.
			// In `@:raw` rules the `skipWs` call gets stripped by the rule-
			// level post-process, but the capture still works — `ctx.pos`
			// at this point is the position of the first byte after the
			// lead literal.
			if (triviaCaptureSource) steps.push(macro final _start_pos:Int = ctx.pos);
			steps.push({
				expr: EVars([{
					name: '_raw',
					type: null,
					expr: callSub,
					isFinal: true,
				}]),
				pos: Context.currentPos(),
			});
			if (trailText != null) {
				steps.push(macro skipWs(ctx));
				// Capture _end_pos AFTER the post-Ref skipWs but BEFORE the
				// trail-literal match, so trailing whitespace inside the
				// braces (e.g. `${ i + 1 }`) is included in the verbatim
				// slice. In `@:raw` rules the skipWs is stripped at post-
				// process time and the capture lands at the position of
				// the trail literal directly.
				if (triviaCaptureSource) {
					steps.push(macro final _end_pos:Int = ctx.pos);
					steps.push(macro final _sourceText:String = ctx.input.substring(_start_pos, _end_pos));
				}
				// `@:trailOpt` annotates `lit.trailOptional:true` alongside
				// `lit.trailText`. The trail literal becomes optional on
				// parse — `matchLit` peeks + consumes if present, but does
				// NOT throw if absent. In trivia mode the captured presence
				// flag flows into the synth ctor's extra `trailPresent:Bool`
				// arg (slice ω-trailopt-source-track 2026-05-02). Plain
				// mode keeps the original ctor arity and falls back to
				// AST-shape gates such as `@:fmt(trailOptShapeGate(...))`
				// in the writer.
				// Consumers: `HxDecl.TypedefDecl` for `typedef Foo = T`
				// without trailing `;` (slice ω-typedef-trailOpt);
				// `HxStatement.VarStmt` / `FinalStmt` for `var foo =
				// switch (x) { case _: 1 }` without trailing `;` (slice
				// ω-vardecl-trailOpt — the `}`-terminated rhs idiom).
				if (triviaTrailOpt) steps.push(macro final _trailPresent:Bool = matchLit(ctx, $v{trailText}));
				else if (trailOptional) steps.push(macro matchLit(ctx, $v{trailText}));
				else steps.push(macro expectLit(ctx, $v{trailText}));
			}
			steps.push(macro return $ctorCall);
			return macro $b{steps};
		}

		Context.fatalError('Lowering: unsupported enum branch shape for ${simpleName(typePath)}.${ctor}', Context.currentPos());
		throw 'unreachable';
	}

	// -------- struct rule --------

	private function lowerStruct(node:ShapeNode, typePath:String):Expr {
		if (shouldLowerByName(node)) return lowerStructByName(node, typePath);
		final parseSteps:Array<Expr> = [];
		final structFields:Array<ObjectField> = [];
		// Binary: @:magic prefix — validate fixed magic bytes before fields.
		final magic:Null<String> = node.annotations.get('bin.magic');
		if (magic != null)
			parseSteps.push(macro expectLit(ctx, $v{magic}));
		for (child in node.children) {
			final fieldName:Null<String> = child.annotations.get('base.fieldName');
			if (fieldName == null) {
				Context.fatalError('Lowering: struct field missing base.fieldName', Context.currentPos());
			}
			// Per-field prefix: @:kw (word-boundary checked) and/or @:lead.
			// When both are present, both are emitted sequentially — @:kw
			// first, then @:lead (D50). First consumers:
			// HxDoWhileStmt.cond and HxCatchClause.name.
			//
			// For a Star field, the @:lead/@:trail pair semantically describes
			// the surrounding wrappers of the collection and is read directly
			// from the Star node's own `lit.*` annotations by
			// `emitStarFieldSteps`. Emitting them here too would produce
			// duplicate `expectLit` calls, so we skip struct-level lead/trail
			// emission whenever the field is a Star.
			//
			// For an @:optional field, the lead literal is parsed via
			// `matchLit` as part of the peek-conditional block, not as a
			// preceding unconditional `expectLit` — the peek IS the commit
			// point. So the lead emission is also skipped for optional
			// fields, and the peek + conditional sub-rule call are emitted
			// together inside the field-value switch below.
			final kwLead:Null<String> = child.readMetaString(':kw');
			final leadText:Null<String> = child.readMetaString(':lead');
			final trailText:Null<String> = child.readMetaString(':trail');
			final isStar:Bool = child.kind == Star;
			final isOptional:Bool = child.annotations.get('base.optional') == true;
			if (isOptional && child.kind != Ref && child.kind != Star) {
				Context.fatalError(
					'Lowering: @:optional is only supported on Ref- or Star-shaped struct fields (field "$fieldName")',
					Context.currentPos()
				);
			}
			if (isOptional && !isStar && trailText != null) {
				// A trail on an optional Ref field would have to live inside
				// the peek branch — the current session only supports
				// lead-only optional Ref fields. Reject explicitly rather
				// than silently drop the trail; defer until a real grammar
				// needs it. Optional Star fields are exempt — `@:trail` on
				// a Star describes the close delimiter of the angle-/paren-
				// bracketed list, not a free-floating post-field literal,
				// and the close-peek emission already lives inside the
				// matchLit-gated branch.
				Context.fatalError(
					'Lowering: @:optional combined with @:trail is deferred (field "$fieldName")',
					Context.currentPos()
				);
			}
			if (isStar && isOptional) {
				// Optional Star is the angle-bracketed type-parameter
				// pattern (`@:optional @:lead('<') @:trail('>') @:sep(',')`,
				// first consumer: `HxTypeRef.params`). The combination
				// requires a close delimiter — the matchLit peek on the
				// open commits to consuming up to and including the close,
				// so EOF / try-parse termination modes are inapplicable.
				if (leadText == null || trailText == null) {
					Context.fatalError(
						'Lowering: @:optional Star field "$fieldName" requires both @:lead and @:trail',
						Context.currentPos()
					);
				}
				if (kwLead != null) {
					Context.fatalError(
						'Lowering: @:optional Star field "$fieldName" does not support @:kw',
						Context.currentPos()
					);
				}
			}
			// Binary @:length prefix — read an N-byte ASCII-encoded length
			// BEFORE any field-level lead literal. The parsed integer is
			// stored in `_lenPrefix_<field>` and consumed by the
			// `bin.lengthPrefix` branch in the Terminal case below, which
			// uses it as the byte count for a variable-length Bytes payload.
			final lenPrefix:Null<{width:Int, encoding:String}> = child.annotations.get('bin.lengthPrefix');
			if (lenPrefix != null)
				emitBinLengthPrefix(fieldName, lenPrefix.width, lenPrefix.encoding, parseSteps);
			if (!isStar && !isOptional) {
				if (kwLead != null) {
					parseSteps.push(macro skipWs(ctx));
					parseSteps.push(macro expectKw(ctx, $v{kwLead}));
				}
				if (leadText != null) {
					parseSteps.push(macro skipWs(ctx));
					parseSteps.push(macro expectLit(ctx, $v{leadText}));
				}
			}
			// Field value — by kind.
			final localName:String = '_f_$fieldName';
			// Suppress the pre-field `skipWs` only for a trivia-collecting
			// Star with no lead literal (HxModule.decls). There the outer
			// skipWs would discard the file's first leading comments
			// before the Star loop's `collectTrivia` sees them. When a
			// lead IS present (HxClassDecl.members `{`, HxFnDecl.body `{`)
			// the outer skipWs belongs before the lead — comments between
			// the lead `{` and the first member are captured by
			// `collectTrivia` inside the loop regardless.
			final triviaEofStar:Bool = isStar
				&& child.annotations.get('trivia.starCollects') == true
				&& child.readMetaString(':lead') == null
				&& child.readMetaString(':kw') == null
				&& ctx.trivia;
			// Slice ω₆a: an @:optional Ref field takes ownership of its own
			// pre-field ws handling so the commit-check can rewind over the
			// just-consumed whitespace (and any comments inside it, in trivia
			// mode) when the kw/lead miss — that trivia belongs to the next
			// outer @:trivia Star loop, not to this discarded optional slot.
			final isOptionalRef:Bool = child.kind == Ref && isOptional;
			// ω-issue-48-v2: a bare non-first Ref field (no `@:optional`, no
			// `@:kw`, no `@:lead`) in a trivia-bearing Seq captures the
			// `newlineBefore` signal in the gap between preceding content
			// and the sub-rule's first token. Needed when the preceding
			// bare-tryparse Star is empty (e.g. `HxMemberDecl.modifiers`
			// empty → `member` follows an `@:allow(...)\n` meta element):
			// the Star's rewind stashes trivia back to `ctx.pendingTrivia`,
			// and the pre-Ref `collectTrivia` here drains it, preserving
			// the newline on the synth `<field>BeforeNewline:Bool` slot.
			final hasBeforeNewlineSlot:Bool = child.kind == Ref
				&& !isOptional
				&& child != node.children[0]
				&& kwLead == null
				&& leadText == null
				&& ctx.trivia
				&& isTriviaBearing(typePath);
			final beforeNlLocal:String = '_beforeNl_$fieldName';
			if (!triviaEofStar && !isOptionalRef) {
				if (hasBeforeNewlineSlot) {
					// Route through `collectTrivia` — drains any
					// `pendingTrivia` stash from a preceding empty
					// bare-tryparse Star and captures `newlineBefore` into
					// the local that the struct literal writes onto the
					// synth slot. `skipWs` would silently discard both.
					parseSteps.push({
						expr: EVars([{
							name: beforeNlLocal,
							type: (macro : Bool),
							expr: macro collectTrivia(ctx).newlineBefore,
							isFinal: true,
						}]),
						pos: Context.currentPos(),
					});
				} else parseSteps.push(macro skipWs(ctx));
			}
			// ω-issue-316: for `@:optional @:kw(...)` Ref fields in Trivia
			// mode, declare per-field locals that capture (a) a same-line
			// trailing comment after the kw and (b) own-line leading comments
			// between the kw and the body's first token. These land on synth
			// sibling slots `<field>AfterKw:Null<String>` and
			// `<field>KwLeading:Array<String>` of the paired type. Writer
			// consumes them to preserve source layout.
			//
			// ω-keep-policy: two additional source-shape booleans captured
			// on the same path — `_beforeKwNl_<field>` records whether the
			// whitespace between the preceding token and the kw crossed a
			// newline; `_bodyOnSameLine_<field>` records whether the body
			// follows the kw on the same line. Both default to `false` on
			// the commit-miss path. Landed on synth slots
			// `<field>BeforeKwNewline:Bool` / `<field>BodyOnSameLine:Bool`
			// for the writer's `Keep` dispatch.
			// Sidecar slots (<field>AfterKw, <field>KwLeading, <field>BeforeKwNewline,
			// <field>BodyOnSameLine) only exist on the synth paired `*T` type of
			// trivia-bearing rules. Non-bearing rules have no paired type and the
			// plain typedef has no sidecar fields, so emitting the locals +
			// struct-literal writes for them would reference fields that do not
			// exist on the target type. First non-bearing consumer of the
			// `@:optional @:kw(...)` pattern is `HxIfExpr` — the expression-
			// position `if`. Gating on bearing mirrors every other trivia-
			// conditional branch in the codegen (`parseFnName`, `ruleReturnCT`,
			// `ruleCtorPath` all return the plain form for non-bearing refs in
			// trivia mode).
			final hasKwTriviaSlots:Bool = isOptionalRef && kwLead != null && ctx.trivia && isTriviaBearing(typePath);
			final afterKwLocal:String = '_afterKw_$fieldName';
			final kwLeadingLocal:String = '_kwLeading_$fieldName';
			final beforeKwNlLocal:String = '_beforeKwNl_$fieldName';
			final bodyOnSameLineLocal:String = '_bodyOnSameLine_$fieldName';
			final beforeKwLeadingLocal:String = '_beforeKwLeading_$fieldName';
			final beforeKwTrailingLocal:String = '_beforeKwTrailing_$fieldName';
			if (hasKwTriviaSlots) {
				parseSteps.push({
					expr: EVars([{name: afterKwLocal, type: (macro : Null<String>), expr: macro null, isFinal: false}]),
					pos: Context.currentPos(),
				});
				parseSteps.push({
					expr: EVars([{name: kwLeadingLocal, type: (macro : Array<String>), expr: macro [], isFinal: false}]),
					pos: Context.currentPos(),
				});
				parseSteps.push({
					expr: EVars([{name: beforeKwNlLocal, type: (macro : Bool), expr: macro false, isFinal: false}]),
					pos: Context.currentPos(),
				});
				parseSteps.push({
					expr: EVars([{name: bodyOnSameLineLocal, type: (macro : Bool), expr: macro false, isFinal: false}]),
					pos: Context.currentPos(),
				});
				parseSteps.push({
					expr: EVars([{name: beforeKwLeadingLocal, type: (macro : Array<String>), expr: macro [], isFinal: false}]),
					pos: Context.currentPos(),
				});
				parseSteps.push({
					expr: EVars([{name: beforeKwTrailingLocal, type: (macro : Null<String>), expr: macro null, isFinal: false}]),
					pos: Context.currentPos(),
				});
			}
			switch child.kind {
				case Ref if (isOptional):
					if (kwLead == null && leadText == null) {
						Context.fatalError(
							'Lowering: @:optional struct field "$fieldName" requires @:lead or @:kw',
							Context.currentPos()
						);
					}
					final refName:String = child.annotations.get('base.ref');
					final subCall:Expr = {
						expr: ECall(macro $i{parseFnName(refName)}, [macro ctx]),
						pos: Context.currentPos(),
					};
					// In trivia mode a bearing ref needs the Null<XxxT> wrap
					// around the synth `*T` — `base.fieldType` captured the
					// plain-mode `Null<Xxx>` form at shape-analysis time so we
					// rebuild it here when the target is bearing; otherwise the
					// cached annotation is re-used unchanged.
					final fieldCT:ComplexType = isTriviaBearing(refName)
						? TPath({pack: [], name: 'Null', params: [TPType(ruleReturnCT(refName))]})
						: child.annotations.get('base.fieldType');
					// The commit point peeks the lead literal or keyword —
					// on hit, consume and parse the sub-rule; on miss,
					// rewind pos to before the pre-commit ws scan so any
					// trivia we just skipped becomes visible again to the
					// enclosing @:trivia Star's next `collectTrivia`. No
					// backtracking over the sub-rule body (D24). Keywords
					// use matchKw for word-boundary enforcement (D47).
					final commitCheck:Expr = if (kwLead != null)
						macro matchKw(ctx, $v{kwLead})
					else
						macro matchLit(ctx, $v{leadText});
					// Post-commit trivia handling branches three ways:
					//  - Trivia mode + kw: capture same-line trailing into
					//    `_afterKw_<field>`, route own-line leadings into
					//    `_kwLeading_<field>` (ω-issue-316). Additionally
					//    capture source-shape booleans into
					//    `_beforeKwNl_<field>` (pre-kw ws crossed a newline)
					//    and `_bodyOnSameLine_<field>` (post-kw gap stayed
					//    on the same line) for the writer's `Keep` branches
					//    (ω-keep-policy).
					//  - Trivia mode + lead: ω₆b stash — any captured leading
					//    run flows into `pendingTrivia` for the sub-rule's
					//    first @:trivia Star to drain.
					//  - Plain mode: plain ws skip.
					final innerCommitAction:Expr = if (hasKwTriviaSlots) macro {
						final _kwEndPos:Int = ctx.pos;
						$i{afterKwLocal} = collectTrailing(ctx);
						final _t = collectTrivia(ctx);
						for (_c in _t.leadingComments) $i{kwLeadingLocal}.push(_c);
						$i{bodyOnSameLineLocal} = !hasNewlineIn(ctx.input, _kwEndPos, ctx.pos);
					} else if (ctx.trivia) macro {
						final _t = collectTrivia(ctx);
						// Stash whenever the captured run carries any signal the
						// downstream `collectTrivia` would otherwise lose:
						// comments, blank lines, OR a single newline boundary
						// (the `newlineBefore` channel — sub-rule's first
						// `@:trivia` Star element consumes it via `_t.newlineBefore`).
						if (_t.leadingComments.length > 0 || _t.blankBefore || _t.blankAfterLeadingComments || _t.newlineBefore) ctx.pendingTrivia = _t;
					} else macro skipWs(ctx);
					final preCommitCapture:Expr = if (hasKwTriviaSlots)
						macro $i{beforeKwNlLocal} = hasNewlineIn(ctx.input, _wsPos, _kwStartPos);
					else
						macro {};
					// ω-trivia-before-kw: in trivia mode + kw-bearing optional Ref,
					// the pre-commit ws scan must `collectTrivia` instead of
					// `skipWs` — otherwise own-line comments captured between the
					// preceding token and the kw (e.g. `} // comment\nelse`) are
					// silently discarded. On commit-success the captured leading
					// comments flow into `_beforeKwLeading_<field>` for the
					// writer to emit on its own line before the kw. On commit-
					// miss the rewind (`ctx.pos = _wsPos`) drops the captured
					// trivia so the enclosing Star's next `collectTrivia` re-
					// observes it.
					final valueExpr:Expr = if (hasKwTriviaSlots) macro {
						final _wsPos:Int = ctx.pos;
						// ω-trivia-before-kw-trailing: probe for a single same-line
						// `// comment` after the preceding sibling's last token
						// (e.g. `resize(); // first\nelse`). `collectTrailing`
						// consumes pos to end of comment on hit, rewinds otherwise.
						// On commit-success the captured body lands in
						// `_beforeKwTrailing_<field>` for the writer to cuddle to
						// the prior token. On commit-miss the outer `ctx.pos =
						// _wsPos` rewind drops the capture so the enclosing Star's
						// next `collectTrivia` re-observes it.
						final _trailComment:Null<String> = collectTrailing(ctx);
						final _preTrivia = collectTrivia(ctx);
						final _kwStartPos:Int = ctx.pos;
						if ($commitCheck) {
							$i{beforeKwTrailingLocal} = _trailComment;
							for (_c in _preTrivia.leadingComments) $i{beforeKwLeadingLocal}.push(_c);
							$preCommitCapture;
							$innerCommitAction;
							$subCall;
						} else {
							ctx.pos = _wsPos;
							null;
						}
					} else macro {
						final _wsPos:Int = ctx.pos;
						skipWs(ctx);
						final _kwStartPos:Int = ctx.pos;
						if ($commitCheck) {
							$preCommitCapture;
							$innerCommitAction;
							$subCall;
						} else {
							ctx.pos = _wsPos;
							null;
						}
					};
					parseSteps.push({
						expr: EVars([{
							name: localName,
							type: fieldCT,
							expr: valueExpr,
							isFinal: true,
						}]),
						pos: Context.currentPos(),
					});
				case Ref:
					final refName:String = child.annotations.get('base.ref');
					final callExpr:Expr = {
						expr: ECall(macro $i{parseFnName(refName)}, [macro ctx]),
						pos: Context.currentPos(),
					};
					parseSteps.push({
						expr: EVars([{
							name: localName,
							type: null,
							expr: callExpr,
							isFinal: true,
						}]),
						pos: Context.currentPos(),
					});
				case Star if (isOptional):
					emitOptionalStarFieldSteps(child, localName, parseSteps);
				case Star:
					final isLastField:Bool = child == node.children[node.children.length - 1];
					emitStarFieldSteps(child, localName, parseSteps, isLastField);
				case Terminal:
					final binFixedLen:Null<Int> = child.annotations.get('bin.fixedLen');
					final binEncoding:Null<String> = child.annotations.get('bin.encoding');
					final binDataRef:Null<String> = child.annotations.get('bin.dataRef');
					if (lenPrefix != null)
						emitBinLengthBytesField(localName, fieldName, parseSteps);
					else if (binFixedLen != null && binEncoding != null)
						emitBinFixedIntField(localName, binFixedLen, binEncoding, fieldName, parseSteps);
					else if (binFixedLen != null)
						emitBinFixedStringField(localName, binFixedLen, parseSteps);
					else if (binDataRef != null)
						emitBinDataField(localName, binDataRef, parseSteps);
					else
						Context.fatalError(
							'Lowering: Terminal struct field "$fieldName" requires @:bin or @:length in binary format',
							Context.currentPos()
						);
				case _:
					Context.fatalError('Lowering: struct field kind ${child.kind} not supported', Context.currentPos());
			}
			// Per-field trail. Skipped for Star fields — `emitStarFieldSteps`
			// already emitted the close literal as part of the loop wrappers.
			// Also skipped for optional fields — a trail on an optional
			// should live inside the peek branch, which is not supported in
			// this session (the grammar has no such case yet).
			final hasAfterTrailSlot:Bool = child.kind == Ref && !isStar && !isOptional && trailText != null
				&& ctx.trivia && isTriviaBearing(typePath);
			final afterTrailLocal:String = '_afterTrail_$fieldName';
			if (!isStar && !isOptional && trailText != null) {
				parseSteps.push(macro skipWs(ctx));
				parseSteps.push(macro expectLit(ctx, $v{trailText}));
				// ω-trivia-after-trail: in trivia-bearing rules, capture a
				// same-line `// comment` after the trail literal into a
				// sidecar local — pushed to the synth pair as
				// `<field>AfterTrail:Null<String>` for the next sibling's
				// `bodyPolicyWrap` to thread before its body emission.
				// `collectTrailing` returns null when no same-line comment
				// is present and does not consume any whitespace beyond
				// the optional space + `//<body>` match.
				if (hasAfterTrailSlot) {
					parseSteps.push({
						expr: EVars([{
							name: afterTrailLocal,
							type: (macro : Null<String>),
							expr: macro collectTrailing(ctx),
							isFinal: true,
						}]),
						pos: Context.currentPos(),
					});
				}
			}
			structFields.push({field: fieldName, expr: macro $i{localName}});
			if (hasAfterTrailSlot)
				structFields.push({field: fieldName + TriviaTypeSynth.AFTER_TRAIL_SUFFIX, expr: macro $i{afterTrailLocal}});
			if (hasBeforeNewlineSlot)
				structFields.push({field: fieldName + TriviaTypeSynth.BEFORE_NEWLINE_SUFFIX, expr: macro $i{beforeNlLocal}});
			if (hasKwTriviaSlots) {
				structFields.push({field: fieldName + TriviaTypeSynth.AFTER_KW_SUFFIX, expr: macro $i{afterKwLocal}});
				structFields.push({field: fieldName + TriviaTypeSynth.KW_LEADING_SUFFIX, expr: macro $i{kwLeadingLocal}});
				structFields.push({field: fieldName + TriviaTypeSynth.BEFORE_KW_NEWLINE_SUFFIX, expr: macro $i{beforeKwNlLocal}});
				structFields.push({field: fieldName + TriviaTypeSynth.BODY_ON_SAME_LINE_SUFFIX, expr: macro $i{bodyOnSameLineLocal}});
				structFields.push({field: fieldName + TriviaTypeSynth.BEFORE_KW_LEADING_SUFFIX, expr: macro $i{beforeKwLeadingLocal}});
				structFields.push({field: fieldName + TriviaTypeSynth.BEFORE_KW_TRAILING_SUFFIX, expr: macro $i{beforeKwTrailingLocal}});
			}
			if (ctx.trivia && isStar && child.annotations.get('trivia.starCollects') == true) {
				final trailBBLocal:String = trailingBlankBeforeLocalName(localName);
				final trailLCLocal:String = trailingLeadingLocalName(localName);
				structFields.push({field: fieldName + TriviaTypeSynth.TRAILING_BLANK_BEFORE_SUFFIX, expr: macro $i{trailBBLocal}});
				structFields.push({field: fieldName + TriviaTypeSynth.TRAILING_LEADING_SUFFIX, expr: macro $i{trailLCLocal}});
				// ω-close-trailing: the synth slot exists only for close-peek
				// Stars (see `TriviaTypeSynth.buildStarTrailingSlots`). Gate
				// the push on the Star's own `lit.trailText` annotation so
				// EOF-mode Stars (e.g. `HxModule.decls`) skip the field.
				if (child.annotations.get('lit.trailText') != null) {
					final trailCloseLocal:String = trailingCloseLocalName(localName);
					structFields.push({field: fieldName + TriviaTypeSynth.TRAILING_CLOSE_SUFFIX, expr: macro $i{trailCloseLocal}});
				}
				// ω-open-trailing: synth slot exists only for Stars with
				// `@:lead` AND not `@:tryparse` (the tryparse writer helper
				// does not consume the slot — see TriviaTypeSynth gate +
				// `emitTriviaStarFieldSteps`'s open-text capture gate).
				if (child.annotations.get('lit.leadText') != null && !child.hasMeta(':tryparse')) {
					final trailOpenLocal:String = trailingOpenLocalName(localName);
					structFields.push({field: fieldName + TriviaTypeSynth.TRAILING_OPEN_SUFFIX, expr: macro $i{trailOpenLocal}});
				}
				// ω-trail-blank-after: synth slot exists only for `@:tryparse +
				// @:fmt(nestBody)` Stars (see TriviaTypeSynth gate). Gate the
				// push the same way; emitTriviaStarFieldSteps's tryparse+nestBody
				// branch is the sole producer of `trailBALocal`.
				if (child.hasMeta(':tryparse') && child.fmtHasFlag('nestBody')) {
					final trailBALocal:String = trailingBlankAfterLocalName(localName);
					structFields.push({field: fieldName + TriviaTypeSynth.TRAILING_BLANK_AFTER_SUFFIX, expr: macro $i{trailBALocal}});
				}
				// ω-objectlit-source-trail-comma: synth slot exists only for
				// sep-Stars with a close literal (see TriviaTypeSynth gate).
				// Both `lit.sepText` and `lit.trailText` are populated by the
				// Lit strategy before Lowering runs, so reading from
				// annotations here mirrors the close-trailing / open-trailing
				// gates above.
				if (child.annotations.get('lit.sepText') != null && child.annotations.get('lit.trailText') != null) {
					final trailPresentLocal:String = trailPresentLocalName(localName);
					structFields.push({field: fieldName + TriviaTypeSynth.TRAIL_PRESENT_SUFFIX, expr: macro $i{trailPresentLocal}});
				}
			}
		}
		// Binary: @:align — skip to next alignment boundary after all fields.
		final align:Null<Int> = node.annotations.get('bin.align');
		if (align != null) {
			parseSteps.push(macro {
				final _rem:Int = ctx.pos % $v{align};
				if (_rem != 0 && ctx.pos < ctx.input.length) ctx.pos += $v{align} - _rem;
			});
		}
		final structLiteral:Expr = {expr: EObjectDecl(structFields), pos: Context.currentPos()};
		parseSteps.push(macro return $structLiteral);
		return macro $b{parseSteps};
	}

	/**
	 * Emit the parse steps for a struct field of shape `Star<Ref>`. The
	 * Star node's own `lit.*` annotations carry the surrounding wrappers
	 * (`@:lead` open, `@:trail` close, optional `@:sep`). The accumulator
	 * is declared with the given `localName` so the enclosing `lowerStruct`
	 * can reference it in the final struct literal.
	 *
	 * Four termination modes are selected by the metadata on the Star
	 * node and by the `isLastField` flag:
	 *
	 *  - `@:trail("X")` **without** `@:sep` — loop terminates when the
	 *    next non-whitespace char is the close literal's first char.
	 *  - `@:trail("X")` **with** `@:sep(",")` — loop terminates when the
	 *    next char is not a separator. The first element is parsed only
	 *    when the next char is not already the close char (empty-list
	 *    case).
	 *  - No `@:trail`, **not last field** (or `@:tryparse`) — try-parse
	 *    mode. Loop attempts to parse an element on each iteration; on
	 *    `ParseError` restores position and breaks. Used by modifier
	 *    arrays where the loop stops when the next token is not a
	 *    recognised keyword, and by switch-case bodies where the loop
	 *    stops at the next `case` / `default` / `}` (D49).
	 *  - No `@:trail`, **last field**, no `@:tryparse` — EOF mode. Loop
	 *    terminates when `ctx.pos` reaches `ctx.input.length`. Used by
	 *    module-root Star fields where the top level has no close
	 *    delimiter.
	 *
	 * `@:sep` combined with no `@:trail` is rejected at compile time
	 * because there is no unambiguous way to stop a sep-peek loop at
	 * EOF or via try-parse.
	 */
	private function emitStarFieldSteps(starNode:ShapeNode, localName:String, parseSteps:Array<Expr>, isLastField:Bool):Void {
		final inner:ShapeNode = starNode.children[0];
		if (inner.kind != Ref) {
			Context.fatalError('Lowering: Star struct field must contain a Ref', Context.currentPos());
		}
		final elemRefName:String = inner.annotations.get('base.ref');
		final elemFn:String = parseFnName(elemRefName);
		final elemCT:ComplexType = ruleReturnCT(elemRefName);
		final elemCall:Expr = {
			expr: ECall(macro $i{elemFn}, [macro ctx]),
			pos: Context.currentPos(),
		};
		final openText:Null<String> = starNode.annotations.get('lit.leadText');
		final closeText:Null<String> = starNode.annotations.get('lit.trailText');
		final sepText:Null<String> = starNode.annotations.get('lit.sepText');
		if (closeText == null && sepText != null) {
			Context.fatalError('Lowering: Star struct field with @:sep requires an explicit @:trail close literal', Context.currentPos());
		}
		// Trivia-mode branch — @:trivia-annotated Star accumulates
		// `Trivial<T>` wrappers instead of plain element values. Supports
		// close-peek mode (HxClassDecl.members / HxFnDecl.body) and EOF
		// mode (HxModule.decls). `@:sep` and `@:tryparse` combined with
		// @:trivia are rejected — no current grammar combines them and the
		// semantics of "trivia around a sep-separated list" are undecided.
		if (ctx.trivia && starNode.annotations.get('trivia.starCollects') == true) {
			emitTriviaStarFieldSteps(starNode, localName, parseSteps, isLastField, elemCT, elemCall, openText, closeText);
			return;
		}
		if (openText != null) {
			parseSteps.push(macro expectLit(ctx, $v{openText}));
			parseSteps.push(macro skipWs(ctx));
		}
		final accumCT:ComplexType = TPath({pack: [], name: 'Array', params: [TPType(elemCT)]});
		parseSteps.push({
			expr: EVars([{
				name: localName,
				type: accumCT,
				expr: macro [],
				isFinal: true,
			}]),
			pos: Context.currentPos(),
		});
		final accumRef:Expr = macro $i{localName};
		if (closeText == null && (!isLastField || starNode.hasMeta(':tryparse'))) {
			// Try-parse mode: loop until element parse fails. Used by
			// Star fields that are NOT the last field in a struct, OR
			// by fields annotated with `@:tryparse` (D49) — the loop
			// terminates when the next token cannot be parsed as an
			// element (e.g. a modifier loop stopping at `var`/`function`,
			// or a switch-case body stopping at the next `case`/`default`).
			parseSteps.push(macro {
				while (true) {
					final _savedPos:Int = ctx.pos;
					try {
						skipWs(ctx);
						$accumRef.push($elemCall);
					} catch (_e:anyparse.runtime.ParseError) {
						ctx.pos = _savedPos;
						break;
					}
				}
			});
			return;
		}
		if (closeText == null) {
			// EOF mode: last field, no trail — loop until end of input.
			parseSteps.push(macro {
				skipWs(ctx);
				while (ctx.pos < ctx.input.length) {
					$accumRef.push($elemCall);
					skipWs(ctx);
				}
			});
			return;
		}
		// Close-peek entry guard for the Star loop.
		//
		// When `closeText` is a single byte, a `charCodeAt` peek is the
		// fastest way to decide "are we at the close or at an element?".
		// When `closeText` is longer, the single-byte peek false-positives
		// on elements whose first byte happens to equal `closeText[0]` —
		// concretely, `@:trail('*\/')` on a block-comment body lets `*`
		// appear inside line content, and a `charCodeAt != '*'` guard
		// skips the Star entirely the moment body begins with `*` (e.g.
		// `/**` javadoc). The full-string `peekLit` call eats a substring
		// comparison instead of a byte compare, which is negligible
		// outside of very hot inner loops.
		final closeCharCode:Int = closeText.charCodeAt(0);
		final closeNotNextExpr:Expr = closeText.length == 1
			? macro ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}
			: macro ctx.pos < ctx.input.length && !peekLit(ctx, $v{closeText});
		if (sepText != null) {
			final sepCharCode:Int = sepText.charCodeAt(0);
			parseSteps.push(macro {
				skipWs(ctx);
				if ($closeNotNextExpr) {
					$accumRef.push($elemCall);
					skipWs(ctx);
					while (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
						ctx.pos++;
						skipWs(ctx);
						$accumRef.push($elemCall);
						skipWs(ctx);
					}
				}
			});
		} else {
			parseSteps.push(macro {
				skipWs(ctx);
				while ($closeNotNextExpr) {
					$accumRef.push($elemCall);
					skipWs(ctx);
				}
			});
		}
		parseSteps.push(macro skipWs(ctx));
		parseSteps.push(macro expectLit(ctx, $v{closeText}));
	}

	/**
	 * Emit the parse steps for an `@:optional` Star struct field with
	 * `@:lead` / `@:trail` (and optionally `@:sep`). The local is typed
	 * `Null<Array<elemCT>>`; absent input leaves it `null`, present input
	 * parses the bracketed list and assigns the array.
	 *
	 * First consumer: `HxTypeRef.params` (`@:optional @:lead('<')
	 * @:trail('>') @:sep(',')`). The element rule may recurse into the
	 * containing rule — composition is handled by the parser dispatcher,
	 * not by this emitter.
	 *
	 * Termination is close-peek with an optional sep loop, mirroring
	 * `emitStarFieldSteps`'s sep+close branch. Trivia-mode trailing slots
	 * and tryparse / EOF modes are not supported — the bracketed list
	 * shape commits to a close delimiter on `matchLit` hit.
	 */
	private function emitOptionalStarFieldSteps(starNode:ShapeNode, localName:String, parseSteps:Array<Expr>):Void {
		final inner:ShapeNode = starNode.children[0];
		if (inner.kind != Ref) {
			Context.fatalError('Lowering: @:optional Star struct field must contain a Ref', Context.currentPos());
		}
		final elemRefName:String = inner.annotations.get('base.ref');
		final elemFn:String = parseFnName(elemRefName);
		final elemCT:ComplexType = ruleReturnCT(elemRefName);
		final elemCall:Expr = {
			expr: ECall(macro $i{elemFn}, [macro ctx]),
			pos: Context.currentPos(),
		};
		// `@:lead` and `@:trail` are guaranteed non-null at this point —
		// the validation block in `lowerStruct` rejects optional Star
		// without both before the field-value switch fires.
		final openText:String = starNode.annotations.get('lit.leadText');
		final closeText:String = starNode.annotations.get('lit.trailText');
		final sepText:Null<String> = starNode.annotations.get('lit.sepText');
		final accumCT:ComplexType = TPath({pack: [], name: 'Array', params: [TPType(elemCT)]});
		final optAccumCT:ComplexType = TPath({pack: [], name: 'Null', params: [TPType(accumCT)]});
		final closeCharCode:Int = closeText.charCodeAt(0);
		final closeNotNextExpr:Expr = closeText.length == 1
			? macro ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}
			: macro ctx.pos < ctx.input.length && !peekLit(ctx, $v{closeText});
		final loopBody:Expr = if (sepText != null) {
			final sepCharCode:Int = sepText.charCodeAt(0);
			macro {
				skipWs(ctx);
				if ($closeNotNextExpr) {
					_items.push($elemCall);
					skipWs(ctx);
					while (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
						ctx.pos++;
						skipWs(ctx);
						_items.push($elemCall);
						skipWs(ctx);
					}
				}
			};
		} else {
			macro {
				skipWs(ctx);
				while ($closeNotNextExpr) {
					_items.push($elemCall);
					skipWs(ctx);
				}
			};
		}
		parseSteps.push({
			expr: EVars([{
				name: localName,
				type: optAccumCT,
				expr: macro if (matchLit(ctx, $v{openText})) {
					final _items:$accumCT = [];
					$loopBody;
					skipWs(ctx);
					expectLit(ctx, $v{closeText});
					_items;
				} else null,
				isFinal: true,
			}]),
			pos: Context.currentPos(),
		});
	}

	/**
	 * Emit the Trivia-mode variant of a Star struct field — each element
	 * goes through `collectTrivia` (leading comments + blank-before
	 * detection) before being parsed, then `collectTrailing` probes for
	 * a same-line comment after the element. The result is pushed into
	 * `_items:Array<Trivial<elemCT>>` as a struct literal that mirrors
	 * `Trivial<T>`'s four fields.
	 *
	 * Supported termination modes:
	 *  - Close-peek (`closeText != null`, no `@:sep`) — reuses the
	 *    `charCodeAt == closeChar` peek from the plain-mode path.
	 *  - EOF (`closeText == null`, `isLastField`, no `@:tryparse`) —
	 *    terminates at `ctx.pos >= ctx.input.length`.
	 *  - Try-parse (`@:tryparse`, no close) — attempts element parse in
	 *    a try/catch; on failure rewinds `ctx.pos` to the start of the
	 *    iteration (before `collectTrivia`) so the enclosing Star
	 *    re-scans the bytes and attaches trivia to the correct site.
	 *    Trailing slots stay at defaults — orphan trivia propagates
	 *    outward, not into `TrailingLeading`.
	 *
	 * `@:sep` combined with `@:trivia` is rejected upstream in
	 * `emitStarFieldSteps` — no current grammar combines them and its
	 * semantics for trivia placement (before or after the separator)
	 * is undecided.
	 */
	private function emitTriviaStarFieldSteps(
		starNode:ShapeNode, localName:String, parseSteps:Array<Expr>, isLastField:Bool,
		elemCT:ComplexType, elemCall:Expr, openText:Null<String>, closeText:Null<String>
	):Void {
		final sepText:Null<String> = starNode.annotations.get('lit.sepText');
		if (sepText != null && (closeText == null || starNode.hasMeta(':tryparse'))) {
			Context.fatalError(
				'Lowering: @:trivia + @:sep requires close-peek (@:trail), not EOF/@:tryparse',
				Context.currentPos()
			);
		}
		if (closeText == null && !isLastField && !starNode.hasMeta(':tryparse')) {
			// Defensive — the Star shape would reject on the plain path too.
			Context.fatalError(
				'Lowering: @:trivia Star without @:trail requires the field to be terminal',
				Context.currentPos()
			);
		}
		final tryparse:Bool = starNode.hasMeta(':tryparse');
		final nestBody:Bool = starNode.fmtHasFlag('nestBody');
		if (openText != null) {
			parseSteps.push(macro expectLit(ctx, $v{openText}));
			// ω-open-trailing: capture a same-line `// comment` (or
			// `/* … */`) sitting right after the open literal (e.g.
			// `{ // foo` before the first element). Stored in a synth
			// `<field>TrailingOpen` slot on the paired Seq type; the
			// writer emits it inline after the open lit so it stays on
			// the same line as `{` rather than being mis-bucketed as
			// own-line leading of the first element. Captured via
			// `collectTrailingFull` (content WITH delimiters) so block-
			// style trailings round-trip as `/* foo */`, mirroring the
			// `<field>TrailingClose` slot's verbatim contract.
			//
			// Skipped for `@:tryparse` Stars: their writer helper
			// (`triviaTryparseStarExpr`) does not consume the slot —
			// capturing here would silently drop the comment at write
			// time. The synth gate in `TriviaTypeSynth.buildStarTrailingSlots`
			// matches; without it the struct-literal push below would
			// also reference a non-existent field.
			if (!tryparse) {
				final trailOpenLocal:String = trailingOpenLocalName(localName);
				final nullStrCT:ComplexType = TPath({
					pack: [], name: 'Null', params: [TPType(TPath({pack: [], name: 'String', params: []}))]
				});
				parseSteps.push({
					expr: EVars([{
						name: trailOpenLocal,
						type: nullStrCT,
						expr: macro collectTrailingFull(ctx),
						isFinal: true,
					}]),
					pos: Context.currentPos(),
				});
			}
		}
		final wrappedCT:ComplexType = TPath({
			pack: ['anyparse', 'runtime'], name: 'Trivial', params: [TPType(elemCT)]
		});
		final accumCT:ComplexType = TPath({pack: [], name: 'Array', params: [TPType(wrappedCT)]});
		parseSteps.push({
			expr: EVars([{
				name: localName,
				type: accumCT,
				expr: macro [],
				isFinal: true,
			}]),
			pos: Context.currentPos(),
		});
		// ω-orphan-trivia: two mutable locals capture the trivia scanned
		// on the final iteration (the one that hits the termination
		// check). Without these, orphan comments between the last
		// element and the close literal (or EOF) would be silently
		// dropped. Paired with the two synth slots on the parent Seq
		// type (see `TriviaTypeSynth.buildStarTrailingSlots`).
		//
		// In `@:tryparse` mode the rewind-on-fail path uncaptures any
		// trivia the failed iteration had already scanned, so the
		// trailing slots stay at their zero-initialised defaults — orphan
		// trivia propagates outward through the enclosing Star's own
		// `collectTrivia` scan rather than being stashed here.
		final trailBBLocal:String = trailingBlankBeforeLocalName(localName);
		final trailLCLocal:String = trailingLeadingLocalName(localName);
		final trailBALocal:String = trailingBlankAfterLocalName(localName);
		final boolCT:ComplexType = TPath({pack: [], name: 'Bool', params: []});
		final arrayStrCT:ComplexType = TPath({
			pack: [], name: 'Array', params: [TPType(TPath({pack: [], name: 'String', params: []}))]
		});
		parseSteps.push({
			expr: EVars([{
				name: trailBBLocal,
				type: boolCT,
				expr: macro false,
				isFinal: false,
			}]),
			pos: Context.currentPos(),
		});
		parseSteps.push({
			expr: EVars([{
				name: trailLCLocal,
				type: arrayStrCT,
				expr: macro [],
				isFinal: false,
			}]),
			pos: Context.currentPos(),
		});
		// ω-trail-blank-after: tryparse + nestBody Stars carry an extra Bool
		// slot that records whether the source had a blank line BETWEEN the
		// stashed orphan trail comment and the next outer-Star sibling. Set
		// from `_lead.blankAfterLeadingComments` on the failed iteration
		// (the parse attempt that triggered trail capture); other tryparse
		// shapes either rewind on failure or have no nestBody wrap so the
		// signal is meaningless. Default `false` matches the no-blank case.
		if (tryparse && nestBody) {
			parseSteps.push({
				expr: EVars([{
					name: trailBALocal,
					type: boolCT,
					expr: macro false,
					isFinal: false,
				}]),
				pos: Context.currentPos(),
			});
		}
		// ω-objectlit-source-trail-comma: sep-Stars with a close literal
		// declare an extra mutable Bool that records whether the LAST
		// `matchLit(sepText)` call inside the loop succeeded. After the
		// loop terminates via the close-peek check, the local holds
		// `true` iff the final parsed element was followed by a separator
		// (i.e. source had a trailing comma). Default `false` covers the
		// empty-list case and the no-trailing-sep case identically.
		final trailPresentLocal:String = trailPresentLocalName(localName);
		if (sepText != null) {
			parseSteps.push({
				expr: EVars([{
					name: trailPresentLocal,
					type: boolCT,
					expr: macro false,
					isFinal: false,
				}]),
				pos: Context.currentPos(),
			});
		}
		final accumRef:Expr = macro $i{localName};
		if (tryparse) {
			// Try-parse termination: each iteration saves `ctx.pos` before
			// `collectTrivia`, attempts the element parse, and rewinds to
			// the saved pos on failure so the captured trivia is fully
			// uncaptured. The enclosing `@:trivia` Star's next
			// `collectTrivia` re-scans the same bytes and attaches them
			// correctly (e.g. as leading of the next sibling element).
			//
			// `@:fmt(nestBody)` Stars (case/default bodies) add a trailing-
			// orphan capture: when parse fails AFTER scanning own-line
			// comments without a blank-line separator, those comments
			// belong to THIS body (rendered at body-indent), not to the
			// next sibling. We stash them in the trailing slots and
			// advance cursor past the trivia so the enclosing Star does
			// not re-capture. Comments separated by a blank line still
			// flow outward via rewind — preserving "blank line = belongs
			// to next entity" convention.
			if (nestBody) {
				parseSteps.push(macro {
					while (true) {
						final _savedPos:Int = ctx.pos;
						final _lead = collectTrivia(ctx);
						final _afterTriviaPos:Int = ctx.pos;
						try {
							final _node:$elemCT = $elemCall;
							final _trailing:Null<String> = collectTrailing(ctx);
							$accumRef.push({
								blankBefore: _lead.blankBefore,
								blankAfterLeadingComments: _lead.blankAfterLeadingComments,
								newlineBefore: _lead.newlineBefore,
								leadingComments: _lead.leadingComments,
								trailingComment: _trailing,
								node: _node,
							});
						} catch (_e:anyparse.runtime.ParseError) {
							if (!_lead.blankBefore && _lead.leadingComments.length > 0) {
								$i{trailBBLocal} = _lead.blankBefore;
								$i{trailLCLocal} = _lead.leadingComments;
								$i{trailBALocal} = _lead.blankAfterLeadingComments;
								ctx.pos = _afterTriviaPos;
							} else {
								ctx.pos = _savedPos;
							}
							break;
						}
					}
				});
				return;
			}
			parseSteps.push(macro {
				while (true) {
					final _savedPos:Int = ctx.pos;
					final _lead = collectTrivia(ctx);
					try {
						final _node:$elemCT = $elemCall;
						final _trailing:Null<String> = collectTrailing(ctx);
						$accumRef.push({
							blankBefore: _lead.blankBefore,
							blankAfterLeadingComments: _lead.blankAfterLeadingComments,
							newlineBefore: _lead.newlineBefore,
							leadingComments: _lead.leadingComments,
							trailingComment: _trailing,
							node: _node,
						});
					} catch (_e:anyparse.runtime.ParseError) {
						ctx.pos = _savedPos;
						break;
					}
				}
			});
			return;
		}
		final terminationCheck:Expr = if (closeText != null) {
			// See emitStarFieldSteps for why we flip to full-string `peekLit` when
			// close is multi-byte (single-byte peek false-positives when close's
			// first byte can legitimately appear inside element content).
			final closeCharCode:Int = closeText.charCodeAt(0);
			closeText.length == 1
				? macro ctx.pos >= ctx.input.length || ctx.input.charCodeAt(ctx.pos) == $v{closeCharCode}
				: macro ctx.pos >= ctx.input.length || peekLit(ctx, $v{closeText});
		} else {
			macro ctx.pos >= ctx.input.length;
		};
		// ω-trivia-sep: when the trivia Star carries `@:sep`, an
		// optional separator (e.g. `,`) is matched after each element
		// before the trailing-comment capture. Trailing same-line
		// comments after the sep (e.g. `field: 1, // comment`) attach
		// to the just-pushed element. Without sep, the close-peek loop
		// falls through unchanged.
		//
		// The pre-sep horizontal-whitespace skip avoids consuming
		// newlines / comments (`skipWs` would swallow the trailing
		// `// comment` before `collectTrailing` could see it). Inlines
		// the same `' ' | '\t' | '\r'` walk that `collectTrailing`
		// uses internally.
		// ω-objectlit-source-trail-comma: capture the per-iteration
		// `matchLit` result into the slice's source-trail-presence local.
		// After the loop's close-peek terminates, the local holds the
		// LAST iteration's sep result — `true` iff the source committed
		// to a trailing separator before the close.
		final sepMatchExpr:Expr = if (sepText != null) {
			macro {
				while (ctx.pos < ctx.input.length) {
					final _hwc:Int = ctx.input.charCodeAt(ctx.pos);
					if (_hwc == ' '.code || _hwc == '\t'.code || _hwc == '\r'.code) ctx.pos++;
					else break;
				}
				$i{trailPresentLocal} = matchLit(ctx, $v{sepText});
			}
		} else {
			macro {};
		};
		parseSteps.push(macro {
			while (true) {
				final _lead = collectTrivia(ctx);
				if ($terminationCheck) {
					$i{trailBBLocal} = _lead.blankBefore;
					$i{trailLCLocal} = _lead.leadingComments;
					break;
				}
				final _node:$elemCT = $elemCall;
				$sepMatchExpr;
				final _trailing:Null<String> = collectTrailing(ctx);
				$accumRef.push({
					blankBefore: _lead.blankBefore,
					blankAfterLeadingComments: _lead.blankAfterLeadingComments,
					newlineBefore: _lead.newlineBefore,
					leadingComments: _lead.leadingComments,
					trailingComment: _trailing,
					node: _node,
				});
			}
		});
		if (closeText != null) {
			parseSteps.push(macro skipWs(ctx));
			parseSteps.push(macro expectLit(ctx, $v{closeText}));
			// ω-close-trailing: capture a same-line trailing comment sitting
			// right after the close literal (e.g. `} // catch` before the
			// next `catch` clause). Stored in a synth `<field>TrailingClose`
			// slot on the paired Seq type; the writer emits
			// `trailingCommentDocVerbatim(...)` after the close when non-
			// null. ω-trailing-block-style: captured via `collectTrailingFull`
			// (content WITH delimiters) so block-style trailing comments
			// round-trip as `/* foo */`, not as `// foo`. EOF mode and
			// try-parse mode have no close literal and skip this capture
			// entirely.
			final trailCloseLocal:String = trailingCloseLocalName(localName);
			final nullStrCT:ComplexType = TPath({
				pack: [], name: 'Null', params: [TPType(TPath({pack: [], name: 'String', params: []}))]
			});
			parseSteps.push({
				expr: EVars([{
					name: trailCloseLocal,
					type: nullStrCT,
					expr: macro collectTrailingFull(ctx),
					isFinal: true,
				}]),
				pos: Context.currentPos(),
			});
		}
	}

	/**
	 * Name of the `Bool` local that records whether the trailing
	 * trivia run captured on a `@:trivia` Star's final iteration
	 * crossed a blank line. Shared between `emitTriviaStarFieldSteps`
	 * (the producer) and `lowerStruct`'s Seq-child loop (the consumer
	 * that pushes it into the struct literal).
	 */
	public static inline function trailingBlankBeforeLocalName(localName:String):String return '${localName}_trailBB';

	/**
	 * Name of the `Array<String>` local that records the own-line
	 * comments captured on a `@:trivia` Star's final iteration (after
	 * the last element, before the close / EOF).
	 */
	public static inline function trailingLeadingLocalName(localName:String):String return '${localName}_trailLC';

	/**
	 * Name of the `Null<String>` local that records a same-line
	 * trailing comment captured right after a close-peek `@:trivia`
	 * Star's close literal (ω-close-trailing). Only declared in the
	 * close-peek branch of `emitTriviaStarFieldSteps`; the EOF and
	 * try-parse branches skip it.
	 */
	public static inline function trailingCloseLocalName(localName:String):String return '${localName}_trailClose';

	/**
	 * Name of the `Null<String>` local that records a same-line trailing
	 * comment captured right after a `@:trivia` Star's open literal
	 * (ω-open-trailing). Mirror of `trailingCloseLocalName`. Only declared
	 * in branches of `emitTriviaStarFieldSteps` that emit the open lit
	 * (i.e. `openText != null`).
	 */
	public static inline function trailingOpenLocalName(localName:String):String return '${localName}_trailOpen';

	/**
	 * Name of the `Bool` local that records whether a tryparse+nestBody
	 * Star's stashed orphan trail run was followed by a blank line
	 * (ω-trail-blank-after). Mirrors `trailingBlankBeforeLocalName` —
	 * the "after" cousin records gap between trail and the next outer
	 * sibling, while "before" records gap between the last body element
	 * and the trail itself.
	 */
	public static inline function trailingBlankAfterLocalName(localName:String):String return '${localName}_trailBA';

	/**
	 * Name of the `Bool` local that records whether the source had a
	 * trailing separator after the last element of a `@:trivia` sep-Star
	 * with a close literal (ω-objectlit-source-trail-comma). Set by the
	 * per-iteration `matchLit(sepText)` capture inside
	 * `emitTriviaStarFieldSteps`'s sep+close branch; pushed into the
	 * synth pair's `<field>TrailPresent` slot by `lowerStruct`. Consumed
	 * by the writer's `WrapList.emit` call as the `forceExceeds` flag.
	 */
	public static inline function trailPresentLocalName(localName:String):String return '${localName}_trailPresent';

	// -------- terminal rule --------

	private function lowerTerminal(node:ShapeNode, typePath:String, simple:String):Expr {
		final stringEnumValues:Null<Array<{name:String, value:String}>> = node.annotations.get('base.stringEnumValues');
		if (stringEnumValues != null) return lowerStringEnumTerminal(node, typePath, simple, stringEnumValues);
		final pattern:Null<String> = node.annotations.get('re.pattern');
		if (pattern == null) {
			Context.fatalError('Lowering: terminal $typePath missing @:re', Context.currentPos());
			throw 'unreachable';
		}
		final underlying:String = node.annotations.get('base.underlying');
		final eregVar:String = '_re_$simple';
		eregByRule.set(typePath, {varName: eregVar, pattern: pattern});

		// `@:unescape` on a Terminal abstract generates an inline
		// walk-and-unescape loop using the `@:schema` format's
		// `unescapeChar`. Bare `@:unescape` strips surrounding quotes
		// first; `@:unescape("raw")` uses the matched string as-is.
		final unescape:Bool = node.hasMeta(':unescape');
		final unescapeMode:Null<String> = node.readMetaString(':unescape');

		// `@:decode("pkg.Class.method")` on a Terminal abstract names a
		// static function that decodes the matched string into the
		// terminal's underlying type. The path is split on `.` and
		// emitted as `pkg.Class.method(_matched)`.
		final decodePath:Null<String> = node.readMetaString(':decode');

		// `@:rawString` on a String-underlying Terminal means "the regex
		// match is already the raw value" — skip decoding entirely. Used
		// for identifier-like terminals (Haxe `HxIdentLit`) where the
		// matched slice IS the identifier text.
		final raw:Bool = node.hasMeta(':rawString');

		if (unescape && decodePath != null)
			Context.fatalError('Lowering: terminal $typePath has both @:unescape and @:decode', Context.currentPos());
		if (unescape && raw)
			Context.fatalError('Lowering: terminal $typePath has both @:unescape and @:rawString', Context.currentPos());

		final decodeExpr:Expr = if (unescape) {
			final fmtParts:Array<String> = formatInfo.schemaTypePath.split('.');
			final bodyExpr:Expr = if (unescapeMode == 'raw') macro _matched
				else macro _matched.substring(1, _matched.length - 1);
			macro {
				final _body:String = $e{bodyExpr};
				final _buf:StringBuf = new StringBuf();
				var _i:Int = 0;
				while (_i < _body.length) {
					final _c:Int = StringTools.fastCodeAt(_body, _i);
					if (_c == '\\'.code) {
						final _res:anyparse.format.text.TextFormat.UnescapeResult = $p{fmtParts}.instance.unescapeChar(_body, _i + 1);
						_buf.addChar(_res.char);
						_i += 1 + _res.consumed;
					} else {
						_buf.addChar(_c);
						_i++;
					}
				}
				_buf.toString();
			};
		} else if (decodePath != null) {
			final parts:Array<String> = decodePath.split('.');
			{expr: ECall(macro $p{parts}, [macro _matched]), pos: Context.currentPos()};
		} else switch underlying {
			case 'Float': macro Std.parseFloat(_matched);
			case 'Int':
				macro {
					final _v:Null<Int> = Std.parseInt(_matched);
					if (_v == null) {
						throw new anyparse.runtime.ParseError(
							new anyparse.runtime.Span(ctx.pos, ctx.pos),
							'invalid int literal'
						);
					}
					_v;
				};
			case 'Bool': macro _matched == 'true';
			case 'String' if (raw): macro _matched;
			case 'String':
				Context.fatalError('Lowering: String terminal $typePath requires @:unescape, @:decode, or @:rawString', Context.currentPos());
				throw 'unreachable';
			case _:
				Context.fatalError('Lowering: no decoder for underlying type "$underlying"', Context.currentPos());
				throw 'unreachable';
		};

		// `@:captureGroup(N)` (N >= 1) picks the Nth capture group as the
		// stored value — position still advances by the full `matched(0)`
		// length, so any prefix matched but not stored (leading ws, style
		// markers like `* ` in a `/*...*/` body) is consumed. Default (no
		// meta) keeps the whole match as both stored value and advance
		// amount, preserving the existing behaviour for every other
		// terminal.
		final captureGroup:Null<Int> = node.annotations.get('re.captureGroup');
		final matchedValueExpr:Expr = captureGroup == null
			? macro $i{eregVar}.matched(0)
			: macro $i{eregVar}.matched($v{captureGroup});
		final advanceLenExpr:Expr = captureGroup == null
			? macro _matched.length
			: macro $i{eregVar}.matched(0).length;
		return macro {
			final _rest:String = ctx.input.substring(ctx.pos, ctx.input.length);
			if (!$i{eregVar}.match(_rest)) {
				throw new anyparse.runtime.ParseError(
					new anyparse.runtime.Span(ctx.pos, ctx.pos),
					$v{'expected $simple'}
				);
			}
			final _matched:String = $matchedValueExpr;
			ctx.pos += $advanceLenExpr;
			return $decodeExpr;
		};
	}

	/**
	 * Lower an `enum abstract(String)` terminal — parses the format's
	 * string literal, then dispatches to the matching enum value via a
	 * macro-time switch over the declared `name → value` pairs. Unknown
	 * strings raise a `ParseError`. No regex is registered — the value
	 * set is closed at compile time, so a literal switch is both faster
	 * and cleaner than an `EReg` alternation.
	 */
	private function lowerStringEnumTerminal(
		node:ShapeNode, typePath:String, simple:String, values:Array<{name:String, value:String}>
	):Expr {
		final stringType:Null<String> = formatInfo.stringType;
		if (stringType == null) {
			Context.fatalError(
				'Lowering: enum-abstract(String) terminal $typePath requires the format ${formatInfo.schemaTypePath} to declare stringType',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		final pack:Array<String> = packOf(typePath);
		final errMsg:String = 'invalid $simple value';
		final cases:Array<Case> = [for (v in values) {
			values: [{expr: EConst(CString(v.value)), pos: Context.currentPos()}],
			expr: MacroStringTools.toFieldExpr(pack.concat([simple, v.name])),
		}];
		final defaultExpr:Expr = macro throw new anyparse.runtime.ParseError(
			new anyparse.runtime.Span(_errPos, ctx.pos),
			$v{errMsg} + ': "' + _matched + '"'
		);
		final switchExpr:Expr = {expr: ESwitch(macro _matched, cases, defaultExpr), pos: Context.currentPos()};
		final stringFn:String = 'parse${simpleName(stringType)}';
		final stringCall:Expr = {expr: ECall(macro $i{stringFn}, [macro ctx]), pos: Context.currentPos()};
		return macro {
			skipWs(ctx);
			final _errPos:Int = ctx.pos;
			final _matched:String = $stringCall;
			return $switchExpr;
		};
	}

	/**
	 * True when the struct node should be lowered as a key-dispatched
	 * (ByName) object. Two conditions must hold: the resolved format
	 * has `fieldLookup == ByName` and no field on the struct carries
	 * positional metadata (`@:kw`, `@:lead`, `@:trail`, `@:sep`) or
	 * binary metadata. The positional Haxe grammar uses anchors to
	 * describe fixed syntax — those structs stay on the original
	 * positional codepath even though `HaxeFormat` also declares
	 * `ByName`. Binary schemas never reach this branch (`isBinary`
	 * short-circuits `fieldLookup` to a non-ByName default inside
	 * `FormatReader`).
	 */
	private function shouldLowerByName(node:ShapeNode):Bool {
		if (formatInfo.isBinary) return false;
		if (formatInfo.fieldLookup != ByName) return false;
		if (formatInfo.keySyntax != Quoted) return false;
		if (node.annotations.get('bin.magic') != null) return false;
		if (node.annotations.get('bin.align') != null) return false;
		for (child in node.children) {
			if (child.readMetaString(':kw') != null) return false;
			if (child.readMetaString(':lead') != null) return false;
			if (child.readMetaString(':trail') != null) return false;
			if (child.readMetaString(':sep') != null) return false;
		}
		return true;
	}

	/**
	 * Lower a typedef struct as a JSON-style key-dispatched object. The
	 * generated body emits one `Null<T>` local per field, then runs a
	 * loop that reads `"key"`, dispatches to the matching field's
	 * parser, and finally materialises the struct literal. Unknown keys
	 * are routed by the format's `onUnknown` policy — `Skip` silently
	 * consumes the value via `_skipJsonValue`, `Error` raises a
	 * `ParseError` naming the offending key. Non-optional fields are
	 * checked for null after the loop and raise `ParseError` listing
	 * the missing name; optional fields retain their `null` default.
	 */
	private function lowerStructByName(node:ShapeNode, typePath:String):Expr {
		final structFields:Array<ObjectField> = [];
		final declareLocals:Array<Expr> = [];
		final switchCases:Array<Case> = [];
		final missingChecks:Array<Expr> = [];
		for (child in node.children) {
			final fieldName:Null<String> = child.annotations.get('base.fieldName');
			if (fieldName == null)
				Context.fatalError('Lowering: ByName struct field missing base.fieldName', Context.currentPos());
			final isOptional:Bool = child.annotations.get('base.optional') == true;
			final fieldCT:Null<ComplexType> = child.annotations.get('base.fieldType');
			if (fieldCT == null)
				Context.fatalError('Lowering: ByName struct field "$fieldName" missing base.fieldType', Context.currentPos());
			final localName:String = '_f_$fieldName';
			final localCT:ComplexType = isOptional
				? fieldCT
				: TPath({pack: [], name: 'Null', params: [TPType(fieldCT)]});
			declareLocals.push({
				expr: EVars([{name: localName, type: localCT, expr: macro null, isFinal: false}]),
				pos: Context.currentPos(),
			});
			final parseCall:Expr = byNameFieldParseExpr(child, fieldName);
			switchCases.push({
				values: [{expr: EConst(CString(fieldName)), pos: Context.currentPos()}],
				expr: macro $i{localName} = $parseCall,
			});
			if (!isOptional) {
				final errMsg:String = 'missing required field "$fieldName"';
				final checkedName:String = '_r_$fieldName';
				// Two-step unwrap: the `if (... == null) throw` narrows the
				// local in the subsequent statement, and the `final` re-bind
				// produces a non-null local that the struct literal can
				// consume without tripping the object-literal inference
				// collapsing back to Null<T>.
				missingChecks.push(macro {
					if ($i{localName} == null)
						throw new anyparse.runtime.ParseError(
							new anyparse.runtime.Span(ctx.pos, ctx.pos),
							$v{errMsg}
						);
				});
				missingChecks.push({
					expr: EVars([{
						name: checkedName,
						type: fieldCT,
						expr: macro $i{localName},
						isFinal: true,
					}]),
					pos: Context.currentPos(),
				});
				structFields.push({field: fieldName, expr: macro $i{checkedName}});
			} else {
				structFields.push({field: fieldName, expr: macro $i{localName}});
			}
		}
		final defaultExpr:Expr = switch formatInfo.onUnknown {
			case Skip:
				final anyType:Null<String> = formatInfo.anyType;
				if (anyType == null) {
					Context.fatalError(
						'Lowering: UnknownPolicy.Skip requires the format ${formatInfo.schemaTypePath} to declare anyType (the universal-value grammar type used to consume unknown keys)',
						Context.currentPos()
					);
					throw 'unreachable';
				}
				final anyFn:String = 'parse${simpleName(anyType)}';
				macro {
					$i{anyFn}(ctx);
				};
			case Error: macro throw new anyparse.runtime.ParseError(
				new anyparse.runtime.Span(ctx.pos, ctx.pos),
				'unknown field: "' + _key + '"'
			);
			case _:
				Context.fatalError(
					'Lowering: UnknownPolicy.Store is not supported in ByName mode (schema ${formatInfo.schemaTypePath})',
					Context.currentPos()
				);
				throw 'unreachable';
		};
		final switchExpr:Expr = {expr: ESwitch(macro _key, switchCases, defaultExpr), pos: Context.currentPos()};
		final stringType:Null<String> = formatInfo.stringType;
		if (stringType == null) {
			Context.fatalError(
				'Lowering: ByName struct parsing requires the format ${formatInfo.schemaTypePath} to declare stringType (the grammar type used to parse mapping keys)',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		final keyFn:String = 'parse${simpleName(stringType)}';
		final keyCall:Expr = {expr: ECall(macro $i{keyFn}, [macro ctx]), pos: Context.currentPos()};
		final closeCharCode:Int = formatInfo.mappingClose.charCodeAt(0);
		final mappingOpen:String = formatInfo.mappingOpen;
		final mappingClose:String = formatInfo.mappingClose;
		final keyValueSep:String = formatInfo.keyValueSep;
		final entrySep:String = formatInfo.entrySep;
		final structLiteral:Expr = {expr: EObjectDecl(structFields), pos: Context.currentPos()};
		final parseSteps:Array<Expr> = [macro skipWs(ctx), macro expectLit(ctx, $v{mappingOpen})];
		for (d in declareLocals) parseSteps.push(d);
		parseSteps.push(macro {
			skipWs(ctx);
			if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}) {
				while (true) {
					skipWs(ctx);
					final _key:String = $keyCall;
					skipWs(ctx);
					expectLit(ctx, $v{keyValueSep});
					skipWs(ctx);
					$switchExpr;
					skipWs(ctx);
					if (!matchLit(ctx, $v{entrySep})) break;
				}
			}
			skipWs(ctx);
			expectLit(ctx, $v{mappingClose});
		});
		for (c in missingChecks) parseSteps.push(c);
		parseSteps.push(macro return $structLiteral);
		return macro $b{parseSteps};
	}

	private function byNameFieldParseExpr(child:ShapeNode, fieldName:String):Expr {
		return switch child.kind {
			case Ref:
				final refName:String = child.annotations.get('base.ref');
				final fnName:String = 'parse${simpleName(refName)}';
				{expr: ECall(macro $i{fnName}, [macro ctx]), pos: Context.currentPos()};
			case Star:
				byNameStarParseExpr(child, fieldName);
			case _:
				Context.fatalError(
					'Lowering: ByName struct field "$fieldName" has unsupported kind ${child.kind}'
						+ ' — format ${formatInfo.schemaTypePath} may be missing a primitive type mapping',
					Context.currentPos()
				);
				throw 'unreachable';
		};
	}

	/**
	 * Emit the parse expression for a `ByName` struct field whose type is
	 * `Array<T>`. Walks `formatInfo.sequenceOpen` / `entrySep` /
	 * `sequenceClose` to drive the loop. Inner element parsing routes
	 * through the Ref case's helpers (`parseFnName` + `ruleReturnCT`),
	 * picking up trivia-bearing paths and JSON primitive rewrites
	 * (`Array<HxFormatWrapRule>` reads via `parseHxFormatWrapRule`,
	 * etc.).
	 *
	 * The accumulator local is typed against the field's declared
	 * element type (extracted from `base.fieldType`) rather than the
	 * inner Ref's rewrite target, so primitive-rewrite cases — where
	 * the schema declares `Array<Int>` but the inner Ref points at
	 * `anyparse.grammar.json.JIntLit` — keep the schema's invariant
	 * `Array<Int>` shape and rely on the abstract's `from Int to Int`
	 * conversion at each `push`.
	 *
	 * The element shape must be a single `Ref` child; nested `Star` is
	 * deferred until a real schema needs `Array<Array<T>>`.
	 */
	private function byNameStarParseExpr(child:ShapeNode, fieldName:String):Expr {
		final seqOpen:Null<String> = formatInfo.sequenceOpen;
		final seqClose:Null<String> = formatInfo.sequenceClose;
		if (seqOpen == null || seqClose == null) {
			Context.fatalError(
				'Lowering: ByName Array<T> field "$fieldName" requires the format ${formatInfo.schemaTypePath} '
					+ 'to declare sequenceOpen / sequenceClose',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		if (child.children.length != 1) {
			Context.fatalError(
				'Lowering: ByName Array<T> field "$fieldName" expected exactly one element child, got ${child.children.length}',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		final inner:ShapeNode = child.children[0];
		if (inner.kind != Ref) {
			Context.fatalError(
				'Lowering: ByName Array<T> field "$fieldName" element kind ${inner.kind} is not supported '
					+ '— only Array<RefType> (a single named element type) is implemented',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		final refName:String = inner.annotations.get('base.ref');
		final fnName:String = parseFnName(refName);
		final fieldCT:Null<ComplexType> = child.annotations.get('base.fieldType');
		final innerCT:ComplexType = extractArrayElementCT(fieldCT) ?? ruleReturnCT(refName);
		final closeCharCode:Int = seqClose.charCodeAt(0);
		final entrySep:String = formatInfo.entrySep;
		return macro {
			final _arr:Array<$innerCT> = [];
			skipWs(ctx);
			expectLit(ctx, $v{seqOpen});
			skipWs(ctx);
			if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}) {
				while (true) {
					skipWs(ctx);
					_arr.push($i{fnName}(ctx));
					skipWs(ctx);
					if (!matchLit(ctx, $v{entrySep})) break;
				}
			}
			skipWs(ctx);
			expectLit(ctx, $v{seqClose});
			_arr;
		};
	}

	/**
	 * Unwrap `Array<T>` (or `Null<Array<T>>`) and return the element
	 * `ComplexType`. Used by `byNameStarParseExpr` to type the
	 * accumulator local against the schema-declared element type
	 * instead of the parse-fn return type, so primitive-rewrite paths
	 * (`Array<Int>` field whose Ref child resolves to `JIntLit`) keep
	 * `Array<Int>` shape and rely on the abstract's `from`/`to`
	 * conversion at each `push`. Returns `null` on any other shape;
	 * caller falls back to `ruleReturnCT(refName)`.
	 */
	private static function extractArrayElementCT(ct:Null<ComplexType>):Null<ComplexType> {
		if (ct == null) return null;
		return switch ct {
			case TPath({pack: [], name: 'Array', params: [TPType(inner)]}): inner;
			case TPath({pack: [], name: 'Null', params: [TPType(inner)]}): extractArrayElementCT(inner);
			case _: null;
		};
	}

	// -------- binary field helpers --------

	/**
	 * Emit parse steps for a `@:bin(N)` String field — read N bytes as
	 * an ASCII string and strip trailing spaces. The right-padding is a
	 * format convention (e.g. ar), never a meaningful part of the value.
	 */
	private static function emitBinFixedStringField(localName:String, len:Int, parseSteps:Array<Expr>):Void {
		parseSteps.push({
			expr: EVars([{
				name: localName,
				type: macro : String,
				expr: macro {
					final _s:String = StringTools.rtrim(ctx.input.substring(ctx.pos, ctx.pos + $v{len}));
					ctx.pos += $v{len};
					_s;
				},
				isFinal: true,
			}]),
			pos: Context.currentPos(),
		});
	}

	/**
	 * Emit parse steps for a `@:bin(N, Dec|Oct)` Int field — read N bytes
	 * as an ASCII slice, strip trailing spaces, and decode as an integer
	 * in the given base.
	 */
	private static inline function emitBinFixedIntField(
		localName:String, len:Int, encoding:String, fieldName:String, parseSteps:Array<Expr>
	):Void {
		emitIntSliceLocal(localName, len, encoding, 'field "$fieldName"', parseSteps);
	}

	/**
	 * Emit parse steps for a `@:bin("fieldName")` Bytes field — read a
	 * variable number of bytes determined by `parseInt(trim(fieldRef))`.
	 */
	private static function emitBinDataField(localName:String, refField:String, parseSteps:Array<Expr>):Void {
		final localRef:Expr = {expr: EConst(CIdent('_f_$refField')), pos: Context.currentPos()};
		final errMsg:String = 'invalid size in field "$refField"';
		parseSteps.push({
			expr: EVars([{
				name: localName,
				type: macro : haxe.io.Bytes,
				expr: macro {
					final _len:Int = {
						final _s:String = StringTools.rtrim($localRef);
						final _v:Null<Int> = Std.parseInt(_s);
						if (_v == null)
							throw new anyparse.runtime.ParseError(
								new anyparse.runtime.Span(ctx.pos, ctx.pos),
								$v{errMsg}
							);
						(_v : Int);
					};
					final _b:haxe.io.Bytes = ctx.input.bytes(ctx.pos, ctx.pos + _len);
					ctx.pos += _len;
					_b;
				},
				isFinal: true,
			}]),
			pos: Context.currentPos(),
		});
	}

	/**
	 * Emit parse steps for a `@:length(N, Dec|Oct)` length prefix. Reads
	 * N bytes, right-trims, decodes as an integer in the given base, and
	 * stores the result in `_lenPrefix_<field>:Int`.
	 */
	private static inline function emitBinLengthPrefix(
		fieldName:String, width:Int, encoding:String, parseSteps:Array<Expr>
	):Void {
		emitIntSliceLocal('_lenPrefix_$fieldName', width, encoding, 'length prefix for "$fieldName"', parseSteps);
	}

	/**
	 * Emit `final <localName>:Int = decode(rtrim(slice of <width> bytes))`.
	 * Shared by fixed-width Int fields and length prefixes — they differ
	 * only in the local name they bind to and the error context string.
	 */
	private static function emitIntSliceLocal(
		localName:String, width:Int, encoding:String, errContext:String, parseSteps:Array<Expr>
	):Void {
		final decodeExpr:Expr = makeIntDecodeExpr(encoding, errContext);
		parseSteps.push({
			expr: EVars([{
				name: localName,
				type: macro : Int,
				expr: macro {
					final _s:String = StringTools.rtrim(ctx.input.substring(ctx.pos, ctx.pos + $v{width}));
					ctx.pos += $v{width};
					$decodeExpr;
				},
				isFinal: true,
			}]),
			pos: Context.currentPos(),
		});
	}

	/**
	 * Emit parse steps for a `@:length`-paired Bytes field — read the
	 * count stored in `_lenPrefix_<field>` bytes into the AST value.
	 */
	private static function emitBinLengthBytesField(localName:String, fieldName:String, parseSteps:Array<Expr>):Void {
		final lenRef:Expr = {expr: EConst(CIdent('_lenPrefix_$fieldName')), pos: Context.currentPos()};
		parseSteps.push({
			expr: EVars([{
				name: localName,
				type: macro : haxe.io.Bytes,
				expr: macro {
					final _b:haxe.io.Bytes = ctx.input.bytes(ctx.pos, ctx.pos + $lenRef);
					ctx.pos += $lenRef;
					_b;
				},
				isFinal: true,
			}]),
			pos: Context.currentPos(),
		});
	}

	/**
	 * Build the Int-decode expression for a right-trimmed `_s:String`
	 * local. `Dec` uses `Std.parseInt`; `Oct` runs an inline digit loop
	 * (Haxe's `Std.parseInt` interprets unprefixed ASCII as decimal, not
	 * octal, so the octal path cannot delegate to it).
	 */
	private static function makeIntDecodeExpr(encoding:String, errContext:String):Expr {
		return switch encoding {
			case 'Dec':
				final errMsg:String = 'invalid decimal in $errContext';
				macro {
					final _v:Null<Int> = Std.parseInt(_s);
					if (_v == null)
						throw new anyparse.runtime.ParseError(
							new anyparse.runtime.Span(ctx.pos, ctx.pos),
							$v{errMsg}
						);
					(_v : Int);
				};
			case 'Oct':
				final emptyMsg:String = 'empty octal in $errContext';
				final digitMsg:String = 'invalid octal digit in $errContext';
				macro {
					if (_s.length == 0)
						throw new anyparse.runtime.ParseError(
							new anyparse.runtime.Span(ctx.pos, ctx.pos),
							$v{emptyMsg}
						);
					var _acc:Int = 0;
					var _oi:Int = 0;
					while (_oi < _s.length) {
						final _oc:Int = StringTools.fastCodeAt(_s, _oi);
						if (_oc < '0'.code || _oc > '7'.code)
							throw new anyparse.runtime.ParseError(
								new anyparse.runtime.Span(ctx.pos, ctx.pos),
								$v{digitMsg}
							);
						_acc = (_acc << 3) | (_oc - '0'.code);
						_oi++;
					}
					_acc;
				};
			case _:
				Context.fatalError('Lowering: unsupported bin encoding "$encoding"', Context.currentPos());
				throw 'unreachable';
		};
	}

	// -------- @:raw post-processing --------

	/**
	 * Recursively replace every `skipWs(ctx)` call in an expression tree
	 * with an empty block `{}`. Used by `@:raw` rules to suppress
	 * whitespace skipping without modifying any of the 50+ emission
	 * sites. Referenced sub-rules (via Ref) are separate generated
	 * functions — their own skipWs calls are in their own bodies, not
	 * in this tree, so they are unaffected.
	 */
	private static function stripSkipWs(e:Expr):Expr {
		return switch e.expr {
			case ECall({expr: EConst(CIdent('skipWs'))}, _):
				{expr: EBlock([]), pos: e.pos};
			case _:
				ExprTools.map(e, stripSkipWs);
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
	private static function endsWithWordChar(lit:String):Bool {
		if (lit.length == 0) return false;
		final c:Int = lit.charCodeAt(lit.length - 1);
		return (c >= 'a'.code && c <= 'z'.code)
			|| (c >= 'A'.code && c <= 'Z'.code)
			|| (c >= '0'.code && c <= '9'.code)
			|| c == '_'.code;
	}

	// -------- trivia-mode helpers --------

	/**
	 * True when `ctx.trivia` is active AND the rule at `refName` carries
	 * `trivia.bearing=true`. The rule-lookup guard returns false for
	 * non-grammar refs (format primitives the Lowering still expects to
	 * call through their plain `parse*` functions, e.g. `JIntLit` under
	 * `HxFormatConfig`).
	 */
	private function isTriviaBearing(refName:String):Bool {
		if (!ctx.trivia) return false;
		final node:Null<ShapeNode> = shape.rules.get(refName);
		if (node == null) return false;
		return node.annotations.get('trivia.bearing') == true;
	}

	/** `parse<name>T` when trivia-bearing, else `parse<name>` — every ref fn-name site goes through this. */
	private function parseFnName(refName:String):String {
		final simple:String = simpleName(refName);
		return isTriviaBearing(refName) ? 'parse${simple}T' : 'parse$simple';
	}

	/** Paired `*T` ComplexType in the synth module for bearing rules; plain TPath otherwise. */
	private function ruleReturnCT(refName:String):ComplexType {
		final simple:String = simpleName(refName);
		if (isTriviaBearing(refName))
			return TPath({pack: packOf(refName).concat(['trivia']), name: 'Pairs', sub: simple + 'T', params: []});
		return TPath({pack: packOf(refName), name: simple, params: []});
	}

	/** Enum-constructor field-path segments for `toFieldExpr` — routes through the synth module for bearing enums. */
	private function ruleCtorPath(typePath:String, ctor:String):Array<String> {
		final simple:String = simpleName(typePath);
		if (isTriviaBearing(typePath))
			return packOf(typePath).concat(['trivia', 'Pairs', simple + 'T', ctor]);
		return packOf(typePath).concat([simple, ctor]);
	}

	private static function simpleName(typePath:String):String {
		final idx:Int = typePath.lastIndexOf('.');
		return idx == -1 ? typePath : typePath.substring(idx + 1);
	}

	private static function packOf(typePath:String):Array<String> {
		final idx:Int = typePath.lastIndexOf('.');
		return idx == -1 ? [] : typePath.substring(0, idx).split('.');
	}
}
#end
