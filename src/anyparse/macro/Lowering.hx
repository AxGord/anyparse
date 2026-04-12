package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;

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
		final fnName:String = 'parse$simple';
		final returnCT:ComplexType = TPath({pack: packOf(typePath), name: simple, params: []});
		// `eregByRule` is populated as a side-effect of `lowerTerminal`, so
		// every branch that builds the body must run before we read back
		// the registered eregs. The loop-vs-atom Pratt split hangs the
		// eregs off the loop rule (which is the public entry point for
		// the enum); the atom sub-rule has none of its own.
		return switch node.kind {
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
	}

	private function collectEregs(typePath:String):Array<GeneratedRule.EregSpec> {
		final eregs:Array<GeneratedRule.EregSpec> = [];
		if (eregByRule.exists(typePath)) eregs.push(eregByRule.get(typePath));
		return eregs;
	}

	private static function hasPrattBranch(node:ShapeNode):Bool {
		for (branch in node.children) if (branch.annotations.get('pratt.prec') != null) return true;
		return false;
	}

	private static function hasPostfixBranch(node:ShapeNode):Bool {
		for (branch in node.children) if (branch.annotations.get('postfix.op') != null) return true;
		return false;
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
					if (b.annotations.get('pratt.prec') == null && b.annotations.get('postfix.op') == null) b
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
		final returnCT:ComplexType = TPath({pack: packOf(typePath), name: simple, params: []});
		final loopFnName:String = 'parse$simple';
		final atomFnName:String = 'parse${simple}Atom';
		final atomCall:Expr = {
			expr: ECall(macro $i{atomFnName}, [macro ctx]),
			pos: Context.currentPos(),
		};
		final prattBranches:Array<ShapeNode> = [
			for (b in node.children) if (b.annotations.get('pratt.prec') != null) b
		];
		// Longest-match sort: longer operator literals come first in the
		// generated dispatch chain so `<=` is attempted before `<` (and
		// `>=` before `>`). Without this, `matchLit(ctx, "<")` succeeds on
		// input `<=`, consumes one char, and leaves `=` stranded for the
		// right operand parser to trip over. The sort is a Lowering-level
		// policy — `matchLit` stays a naive prefix match everywhere else
		// (enum-branch Case 1 `expectLit`, struct lead/trail, Case 4 array
		// loops) where ambiguity cannot arise because the literal is fixed
		// at macro time. Order among equal-length operators is semantically
		// irrelevant (no length-N operator is a prefix of another length-N
		// operator in a well-formed grammar), so `Array.sort` suffices.
		prattBranches.sort((a, b) -> {
			final la:Int = (a.annotations.get('pratt.op') : String).length;
			final lb:Int = (b.annotations.get('pratt.op') : String).length;
			return lb - la;
		});
		// Fold the operator chain into a nested if/else if tree. Each leaf
		// branch consumes the operator literal (already matched at the
		// peek), enforces `minPrec`, parses the right operand by recursing
		// into `parseXxx` at `prec + 1` for left-associative branches or
		// `prec` for right-associative branches, and rebuilds `left` as
		// the matched ctor call.
		var opChain:Expr = macro _matched = false;
		for (i in 0...prattBranches.length) {
			final branch:ShapeNode = prattBranches[prattBranches.length - 1 - i];
			final opText:String = branch.annotations.get('pratt.op');
			final precValue:Int = branch.annotations.get('pratt.prec');
			final assocValue:String = branch.annotations.get('pratt.assoc');
			final nextMinPrec:Int = assocValue == 'Right' ? precValue : precValue + 1;
			final ctor:String = branch.annotations.get('base.ctor');
			final ctorPath:Array<String> = packOf(typePath).concat([simple, ctor]);
			final ctorRef:Expr = MacroStringTools.toFieldExpr(ctorPath);
			final rightCall:Expr = {
				expr: ECall(macro $i{loopFnName}, [macro ctx, macro $v{nextMinPrec}]),
				pos: Context.currentPos(),
			};
			final ctorCall:Expr = {
				expr: ECall(ctorRef, [macro left, macro _right]),
				pos: Context.currentPos(),
			};
			final branchBody:Expr = macro {
				if ($v{precValue} < minPrec) {
					ctx.pos = _savedPos;
					_matched = false;
				} else {
					skipWs(ctx);
					final _right:$returnCT = $rightCall;
					left = $ctorCall;
				}
			};
			opChain = macro if (matchLit(ctx, $v{opText})) $branchBody else $opChain;
		}
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
		final returnCT:ComplexType = TPath({pack: packOf(typePath), name: simple, params: []});
		final enumSimple:String = simple;
		final selfFnName:String = 'parse$simple';
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
			final ctorPath:Array<String> = packOf(typePath).concat([enumSimple, ctor]);
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
					: 'parse${simpleName(elemRefName)}';
				final elemCall:Expr = {
					expr: ECall(macro $i{elemFn}, [macro ctx]),
					pos: Context.currentPos(),
				};
				final elemCT:ComplexType = TPath({pack: packOf(elemRefName), name: simpleName(elemRefName), params: []});
				final closeCharCode:Int = close.charCodeAt(0);
				final sepText:Null<String> = branch.annotations.get('lit.sepText');
				final ctorCall:Expr = {expr: ECall(ctorRef, [macro left, macro _args]), pos: Context.currentPos()};
				if (sepText != null) {
					final sepCharCode:Int = sepText.charCodeAt(0);
					macro {
						skipWs(ctx);
						final _args:Array<$elemCT> = [];
						if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}) {
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
						while (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}) {
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
					: 'parse${simpleName(suffixRef)}';
				final suffixCall:Expr = {
					expr: ECall(macro $i{suffixFn}, [macro ctx]),
					pos: Context.currentPos(),
				};
				final suffixCT:ComplexType = TPath({pack: packOf(suffixRef), name: simpleName(suffixRef), params: []});
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
			opChain = macro if (matchLit(ctx, $v{op})) $branchBody else $opChain;
		}
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
		final ctorPath:Array<String> = packOf(typePath).concat([simpleName(typePath), ctor]);
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
			final operandCT:ComplexType = TPath({pack: packOf(typePath), name: enumSimple, params: []});
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
		final kwLeadBranch:Null<String> = branch.annotations.get('kw.leadText');
		if (kwLeadBranch != null && branch.children.length == 0 && branch.annotations.get('lit.litList') == null) {
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
			final inner:ShapeNode = children[0].children[0];
			if (inner.kind != Ref) {
				Context.fatalError('Lowering: Star child must be a Ref in Phase 2', Context.currentPos());
			}
			final elemRefName:String = inner.annotations.get('base.ref');
			final elemFn:String = 'parse${simpleName(elemRefName)}';
			final elemCT:ComplexType = TPath({pack: packOf(elemRefName), name: simpleName(elemRefName), params: []});
			final elemCall:Expr = {
				expr: ECall(macro $i{elemFn}, [macro ctx]),
				pos: Context.currentPos(),
			};
			final closeCharCode:Int = trailText.charCodeAt(0);
			final ctorCall:Expr = {expr: ECall(ctorRef, [macro _items]), pos: Context.currentPos()};
			if (sepText != null) {
				final sepCharCode:Int = sepText.charCodeAt(0);
				return macro {
					skipWs(ctx);
					expectLit(ctx, $v{leadText});
					final _items:Array<$elemCT> = [];
					skipWs(ctx);
					if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}) {
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
				while (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}) {
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
				expr: ECall(macro $i{'parse${simpleName(refName)}'}, [macro ctx]),
				pos: Context.currentPos(),
			};
			final ctorCall:Expr = {expr: ECall(ctorRef, [macro _raw]), pos: Context.currentPos()};
			final kwLead:Null<String> = branch.annotations.get('kw.leadText');
			final steps:Array<Expr> = [macro skipWs(ctx)];
			if (kwLead != null) {
				steps.push(macro expectKw(ctx, $v{kwLead}));
				steps.push(macro skipWs(ctx));
			} else if (leadText != null) {
				steps.push(macro expectLit(ctx, $v{leadText}));
				steps.push(macro skipWs(ctx));
			}
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
				steps.push(macro expectLit(ctx, $v{trailText}));
			}
			steps.push(macro return $ctorCall);
			return macro $b{steps};
		}

		Context.fatalError('Lowering: unsupported enum branch shape for ${simpleName(typePath)}.${ctor}', Context.currentPos());
		throw 'unreachable';
	}

	// -------- struct rule --------

	private function lowerStruct(node:ShapeNode, typePath:String):Expr {
		final parseSteps:Array<Expr> = [];
		final structFields:Array<ObjectField> = [];
		for (child in node.children) {
			final fieldName:Null<String> = child.annotations.get('base.fieldName');
			if (fieldName == null) {
				Context.fatalError('Lowering: struct field missing base.fieldName', Context.currentPos());
			}
			// Per-field prefix: either @:kw (word-boundary checked) or @:lead.
			// Only one of the two is emitted; @:kw takes priority when both are
			// present on the same field (the compiler already catches duplicate
			// ownership at registration time so this is defensive only).
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
			final kwLead:Null<String> = readMetaString(child, ':kw');
			final leadText:Null<String> = readMetaString(child, ':lead');
			final trailText:Null<String> = readMetaString(child, ':trail');
			final isStar:Bool = child.kind == Star;
			final isOptional:Bool = child.annotations.get('base.optional') == true;
			if (isOptional && child.kind != Ref) {
				Context.fatalError(
					'Lowering: @:optional is only supported on Ref-shaped struct fields (field "$fieldName")',
					Context.currentPos()
				);
			}
			if (isOptional && trailText != null) {
				// A trail on an optional field would have to live inside
				// the peek branch — the current session only supports
				// lead-only optional fields. Reject explicitly rather than
				// silently drop the trail; defer until a real grammar
				// needs it.
				Context.fatalError(
					'Lowering: @:optional combined with @:trail is deferred (field "$fieldName")',
					Context.currentPos()
				);
			}
			if (!isStar && !isOptional) {
				if (kwLead != null) {
					parseSteps.push(macro skipWs(ctx));
					parseSteps.push(macro expectKw(ctx, $v{kwLead}));
				} else if (leadText != null) {
					parseSteps.push(macro skipWs(ctx));
					parseSteps.push(macro expectLit(ctx, $v{leadText}));
				}
			}
			// Field value — by kind.
			final localName:String = '_f_$fieldName';
			parseSteps.push(macro skipWs(ctx));
			switch child.kind {
				case Ref if (isOptional):
					if (kwLead != null) {
						Context.fatalError(
							'Lowering: @:optional combined with @:kw is deferred — field "$fieldName"',
							Context.currentPos()
						);
					}
					if (leadText == null) {
						Context.fatalError(
							'Lowering: @:optional struct field "$fieldName" requires @:lead',
							Context.currentPos()
						);
					}
					final refName:String = child.annotations.get('base.ref');
					final subCall:Expr = {
						expr: ECall(macro $i{'parse${simpleName(refName)}'}, [macro ctx]),
						pos: Context.currentPos(),
					};
					final fieldCT:ComplexType = child.annotations.get('base.fieldType');
					// skipWs was already pushed above; `matchLit` sees a
					// whitespace-trimmed cursor. On hit, consume the lead and
					// parse the sub-rule; on miss, leave the cursor alone and
					// store null. No backtracking over the sub-rule body —
					// the lead literal is the commit point (see D24).
					final valueExpr:Expr = macro if (matchLit(ctx, $v{leadText})) {
						skipWs(ctx);
						$subCall;
					} else null;
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
						expr: ECall(macro $i{'parse${simpleName(refName)}'}, [macro ctx]),
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
				case Star:
					final isLastField:Bool = child == node.children[node.children.length - 1];
					emitStarFieldSteps(child, localName, parseSteps, isLastField);
				case _:
					Context.fatalError('Lowering: struct field kind ${child.kind} not supported', Context.currentPos());
			}
			// Per-field trail. Skipped for Star fields — `emitStarFieldSteps`
			// already emitted the close literal as part of the loop wrappers.
			// Also skipped for optional fields — a trail on an optional
			// should live inside the peek branch, which is not supported in
			// this session (the grammar has no such case yet).
			if (!isStar && !isOptional && trailText != null) {
				parseSteps.push(macro skipWs(ctx));
				parseSteps.push(macro expectLit(ctx, $v{trailText}));
			}
			structFields.push({field: fieldName, expr: macro $i{localName}});
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
	 *  - No `@:trail`, **not last field** — try-parse mode. Loop
	 *    attempts to parse an element on each iteration; on `ParseError`
	 *    restores position and breaks. Used by modifier arrays where
	 *    the loop stops when the next token is not a recognised keyword.
	 *  - No `@:trail`, **last field** — EOF mode. Loop terminates when
	 *    `ctx.pos` reaches `ctx.input.length`. Used by module-root Star
	 *    fields where the top level has no close delimiter.
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
		final elemFn:String = 'parse${simpleName(elemRefName)}';
		final elemCT:ComplexType = TPath({pack: packOf(elemRefName), name: simpleName(elemRefName), params: []});
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
		if (closeText == null && !isLastField) {
			// Try-parse mode: loop until element parse fails. Used by
			// Star fields that are NOT the last field in a struct — the
			// loop terminates when the next token cannot be parsed as an
			// element (e.g. a modifier loop stopping at `var`/`function`).
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
		final closeCharCode:Int = closeText.charCodeAt(0);
		if (sepText != null) {
			final sepCharCode:Int = sepText.charCodeAt(0);
			parseSteps.push(macro {
				skipWs(ctx);
				if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}) {
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
				while (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}) {
					$accumRef.push($elemCall);
					skipWs(ctx);
				}
			});
		}
		parseSteps.push(macro skipWs(ctx));
		parseSteps.push(macro expectLit(ctx, $v{closeText}));
	}

	// -------- terminal rule --------

	private function lowerTerminal(node:ShapeNode, typePath:String, simple:String):Expr {
		final pattern:Null<String> = node.annotations.get('re.pattern');
		if (pattern == null) {
			Context.fatalError('Lowering: terminal $typePath missing @:re', Context.currentPos());
			throw 'unreachable';
		}
		final underlying:String = node.annotations.get('base.underlying');
		final eregVar:String = '_re_$simple';
		eregByRule.set(typePath, {varName: eregVar, pattern: pattern});

		// `@:rawString` on a String-underlying Terminal means "the regex
		// match is already the raw value" — skip the JSON-specific
		// unquote/unescape helper. Used for identifier-like terminals (Haxe
		// `HxIdentLit`) where the matched slice IS the identifier text. A
		// format-contributed decoder table will replace this closed switch
		// once a third Terminal type demands it (see D13 in session_state.md).
		// Named `@:rawString` (not bare `@:raw`) to avoid collision with
		// Haxe's built-in `@:raw` meta for verbatim code injection.
		final raw:Bool = hasMeta(node, ':rawString');
		final decodeExpr:Expr = switch underlying {
			case 'Float': macro Std.parseFloat(_matched);
			case 'Int':
				// `Std.parseInt` returns `Null<Int>` — in strict null
				// safety the implicit coercion to `Int` is disallowed.
				// The regex gate above already guarantees `_matched` is
				// all digits, so the null branch is truly unreachable,
				// but we still guard it explicitly rather than force an
				// unsafe cast. Abstracts with `from Int` (e.g.
				// `HxIntLit`) unify with the narrowed `Int` value.
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
			case 'String' if (raw): macro _matched;
			case 'String': macro decodeJsonString(_matched);
			case _:
				Context.fatalError('Lowering: no decoder for underlying type "$underlying"', Context.currentPos());
				throw 'unreachable';
		};

		return macro {
			final _rest:String = ctx.input.substring(ctx.pos, ctx.input.length);
			if (!$i{eregVar}.match(_rest)) {
				throw new anyparse.runtime.ParseError(
					new anyparse.runtime.Span(ctx.pos, ctx.pos),
					$v{'expected $simple'}
				);
			}
			final _matched:String = $i{eregVar}.matched(0);
			ctx.pos += _matched.length;
			return $decodeExpr;
		};
	}

	// -------- helpers --------

	private static function readMetaString(node:ShapeNode, tag:String):Null<String> {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return null;
		for (entry in meta) if (entry.name == tag) {
			if (entry.params.length != 1) return null;
			return switch entry.params[0].expr {
				case EConst(CString(s, _)): s;
				case _: null;
			};
		}
		return null;
	}

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

	private static function hasMeta(node:ShapeNode, tag:String):Bool {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return false;
		for (entry in meta) if (entry.name == tag) return true;
		return false;
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
