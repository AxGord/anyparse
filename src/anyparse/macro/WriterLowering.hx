package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;

using anyparse.macro.MetaInspect;

/**
 * Pass 3W of the macro pipeline — writer lowering.
 *
 * Walks the shape tree and emits one `WriterRule` per type in the grammar.
 * Each rule's body builds a `Doc` value from the typed AST node.
 * This is the structural inverse of `Lowering`, which emits parse bodies
 * that consume input and build AST nodes.
 *
 * Generated code references `_dt`, `_dc`, `_dhl`, `_de` etc. — thin
 * wrappers over `Doc` constructors emitted by `WriterCodegen` on the
 * same class. This avoids direct enum constructor calls in `macro {}`
 * blocks, which trigger macro-time type checking.
 */
class WriterLowering {

	private final shape:ShapeBuilder.ShapeResult;
	private final formatInfo:FormatReader.FormatInfo;
	private final ctx:LoweringCtx;

	public function new(shape:ShapeBuilder.ShapeResult, formatInfo:FormatReader.FormatInfo, ctx:LoweringCtx) {
		this.shape = shape;
		this.formatInfo = formatInfo;
		this.ctx = ctx;
	}

	public function generate():Array<WriterRule> {
		final rules:Array<WriterRule> = [];
		for (typePath => node in shape.rules) for (rule in lowerRule(typePath, node)) rules.push(rule);
		return rules;
	}

	private function lowerRule(typePath:String, node:ShapeNode):Array<WriterRule> {
		final simple:String = simpleName(typePath);
		final fnName:String = writeFnFor(typePath);
		final valueCT:ComplexType = ruleValueCT(typePath);

		final hasPratt:Bool = node.kind == Alt && (hasPrattBranch(node) || hasPostfixBranch(node));

		final rawBody:Expr = switch node.kind {
			case Alt: lowerEnum(node, typePath, hasPratt);
			case Seq: lowerStruct(node, typePath);
			case Terminal: lowerTerminal(node, typePath, simple);
			case _:
				Context.fatalError('WriterLowering: cannot lower ${node.kind} for $typePath', Context.currentPos());
				throw 'unreachable';
		};
		// ω-fmt-prewrite-hook: `@:fmt(preWrite(Pkg.Cls.fnName))` on the
		// rule's TYPE (enum, typedef, terminal) lets a plugin rewrite
		// the value before the default emission. Function signature:
		// `(<RuleType>, WriteOptions) -> Null<<RuleType>>` — non-null
		// re-dispatches through `fnName` so the rewritten value lands
		// on its own ctor branch / struct path. Used for shape-
		// conditional canonicalisation that fits no declarative
		// `@:fmt(...)` knob: e.g. `HxType.ArrowFn([Pos(Arrow)], R)` →
		// `Arrow(Parens, R)` for old-style curried chain rendering, or
		// `BlockComment.lines` per-line variant pick + indent
		// canonicalisation. The arg is a real Haxe expression (typically
		// `EField` field-access) — type-checked at compile time, IDE
		// go-to-def works, no string typo can survive compile.
		final preWriteFn:Null<Expr> = fmtReadCall(node, 'preWrite');
		final body:Expr = preWriteFn != null
			? wrapWithPreWrite(preWriteFn, rawBody, fnName, hasPratt)
			: rawBody;
		return [{fnName: fnName, valueCT: valueCT, body: body, hasCtxPrec: hasPratt, isBinary: false}];
	}

	// -------- enum rule --------

	private function lowerEnum(node:ShapeNode, typePath:String, hasPratt:Bool):Expr {
		final writeFnName:String = writeFnFor(typePath);

		// Compute PREC_POSTFIX for Pratt enums: max(all prec values) + 1
		var precPostfix:Int = 0;
		if (hasPratt) {
			for (b in node.children) {
				final p:Null<Int> = b.annotations.get('pratt.prec');
				if (p != null && p > precPostfix) precPostfix = p;
				final tp:Null<Int> = b.annotations.get('ternary.prec');
				if (tp != null && tp > precPostfix) precPostfix = tp;
			}
			precPostfix++;
		}

		final cases:Array<Case> = [];
		for (branch in node.children) {
			final ctor:String = branch.annotations.get('base.ctor');
			final children:Array<ShapeNode> = branch.children;
			// ω-close-trailing-alt: in trivia mode, close-peek `@:trivia`
			// Alt branches grow a positional `closeTrailing:Null<String>`
			// arg in the synth ctor (`HxStatementT.BlockStmt(stmts, closeTrailing)`).
			// The ShapeNode tree is unchanged — gate by reading the same
			// raw `@:trail` meta `TriviaTypeSynth` consults — so the
			// pattern grows by one binding consumed by `lowerEnumStar`.
			//
			// ω-trailopt-source-track: in trivia mode, single-Ref Alt
			// branches carrying `@:trailOpt(...)` likewise grow a positional
			// `trailPresent:Bool` arg captured by the parser's `matchLit`.
			// Disjoint from `isAltCloseTrailingBranch` (Star vs Ref child),
			// so at most one extra arg per branch — the writer reads the
			// flag via `argNames[1]` in `lowerEnumBranch`'s Case 3.
			// ω-string-interp-noformat: in trivia mode, ctors with
			// `@:fmt(captureSource)` grow a positional `sourceText:String`
			// arg holding the parser-captured byte slice between the
			// ctor's `@:lead` and `@:trail`. Disjoint from the above two
			// (different shape predicates) — at most one extra arg per
			// branch. Read inside Case 3 via `argNames[1]` to gate verbatim
			// emission on `opt.formatStringInterpolation`.
			final hasCloseTrailing:Bool = ctx.trivia && TriviaTypeSynth.isAltCloseTrailingBranch(branch);
			final hasTrailOptFlag:Bool = ctx.trivia && TriviaTypeSynth.isAltTrailOptBranch(branch);
			final hasCaptureSource:Bool = ctx.trivia && TriviaTypeSynth.isCaptureSourceBranch(branch);
			// ω-open-trailing-alt: same-line trailing comment after the
			// open lit grows a parallel positional arg next to closeTrailing.
			// Synth gate is `isAltCloseTrailingBranch && @:lead present`,
			// mirrored here so `argNames[2]` names the openTrailing slot.
			final hasOpenTrailing:Bool = hasCloseTrailing
				&& branch.readMetaString(':lead') != null
				&& !branch.hasMeta(':tryparse');
			final extraArgs:Int = ((hasCloseTrailing || hasTrailOptFlag || hasCaptureSource) ? 1 : 0)
				+ (hasOpenTrailing ? 1 : 0);
			final argNames:Array<String> = [for (i in 0...children.length + extraArgs) '_v$i'];

			// Build pattern
			final ctorPath:Array<String> = ruleCtorPath(typePath, ctor);
			final ctorRef:Expr = MacroStringTools.toFieldExpr(ctorPath);
			final pattern:Expr = if (children.length == 0) ctorRef
			else {
				final argExprs:Array<Expr> = [for (name in argNames) macro $i{name}];
				{expr: ECall(ctorRef, argExprs), pos: Context.currentPos()};
			};

			// Build body. The `@:fmt(preWrite(...))` hook lives at the
			// rule level (see `lowerRule`), so per-ctor branches need no
			// additional wrapping here.
			final body:Expr = lowerEnumBranch(branch, typePath, writeFnName, hasPratt, argNames, precPostfix);
			// ω-methodchain-emit: ctors carrying `@:fmt(methodChain('<wrapField>'))`
			// (currently `HxExpr.Call` and `HxExpr.FieldAccess`) wrap their
			// case body with a runtime walk that detects two-or-more-segment
			// chains and emits via `MethodChainEmit` against the named
			// `WrapRules` cascade on `opt`. Non-chain values (single calls,
			// plain field access) fall through to the default emission.
			final chainField:Null<String> = branch.fmtReadString('methodChain');
			final wrappedBody:Expr = chainField != null
				? wrapWithChainDispatch(body, chainField, writeFnName, node, precPostfix)
				: body;
			cases.push({values: [pattern], expr: wrappedBody, guard: null});
		}
		return macro return ${{expr: ESwitch(macro value, cases, null), pos: Context.currentPos()}};
	}

	/**
	 * ω-fmt-prewrite-hook — wrap a per-ctor case body so the writer
	 * first calls a plugin rewrite function, and on a non-null result
	 * re-dispatches through the rule's main writer. The recurse path
	 * routes the rewritten value back through the same `switch value`
	 * so any ctor produced by the rewrite lands on its proper branch
	 * (and on its own `@:fmt(...)` knobs). When the rewrite returns
	 * null the case falls back to the default emission.
	 *
	 * The hook lives at the case-branch level (not at function entry)
	 * so it fires only for the ctors that opt in via `@:fmt(preWrite)`
	 * — non-opt-in ctors carry zero overhead, no extra dispatch.
	 */
	private function wrapWithPreWrite(fnExpr:Expr, defaultBody:Expr, writeFnName:String, hasPratt:Bool):Expr {
		// preWrite signature: `(value:T, opt:WriteOptions) -> Null<T>`.
		// `opt` is passed through unconditionally so future rewrites can
		// branch on config (line width, comment style, etc.) without a
		// signature break — current consumers that don't need it accept
		// and ignore the param. Replace-value semantics: when the rewrite
		// returns non-null, the function's `value` parameter is reassigned
		// in place and the default emission body runs against the new
		// value. For enum rules the body's `switch value { ... }`
		// dispatches against the rewritten value naturally — no recursive
		// call to `$writeFnName`, so no risk of infinite loops on
		// rewrites that produce values still matching the same hook (e.g.
		// `anyparse.format.comment.BlockCommentNormalizer.normalize` always returns a canonical
		// `BlockComment`). For struct rules the body reads `value.<field>`
		// which now sees the rewritten value's fields. The single rule-
		// level wrap covers both kinds uniformly.
		final preCall:Expr = {expr: ECall(fnExpr, [macro value, macro opt]), pos: Context.currentPos()};
		return macro {
			final _rw = $preCall;
			if (_rw != null) value = _rw;
			$defaultBody;
		};
	}

	/**
	 * ω-methodchain-emit — wrap a per-ctor case body with a writer-time
	 * chain extractor + cascade-driven emit.
	 *
	 * The pattern: at each entry to a ctor tagged
	 * `@:fmt(methodChain('<wrapField>'))` we walk down the AST collecting
	 * chain segments. Two segment shapes are recognised, both keyed off
	 * sibling enum ctors carrying the same `methodChain` flag:
	 *  - **Call segment** — `Call(FieldAccess(prev, fld), args)` — emits
	 *    `.<fld>(<args>)` with the inner args list routed through
	 *    `WrapList.emit` against the Call ctor's `wrapRules` /
	 *    `trailingComma` / postfix delimiters (preserving per-call
	 *    callParameter wrapping inside each segment);
	 *  - **Field segment** — `FieldAccess(prev, fld)` — emits `.<fld>`
	 *    (no args list).
	 *
	 * The walk also pulls out the chain `receiver` — the deepest
	 * non-chain operand (anything that doesn't match `Call(FieldAccess
	 * (Call,_), _)` / `FieldAccess(Call,_)` rest of the way down).
	 *
	 * When the walk finds two or more segments the body short-circuits
	 * via a `return` to `MethodChainEmit.emit(receiverDoc, segs, opt,
	 * opt.<wrapField>)`. One-segment cases — `a.b()` plain call or
	 * `a.b` plain field — fall through to the default emission, so
	 * non-chain expressions pay only the cost of one `switch` per
	 * Call/FieldAccess ctor entry (no recursion, no allocation).
	 *
	 * Args list config (open/close/sep/wrapRules/trailingComma) is read
	 * from the sibling Call ctor's annotations — keeping the chain
	 * emit's arg formatting byte-identical to the regular call emit.
	 * `opt` and `ctxPrec` are in scope from the surrounding writer-fn
	 * signature; recursive renderings (receiver, args) call the same
	 * `$writeFnName` — for HxExpr trivia mode that's `writeHxExprT`,
	 * for plain mode `writeHxExpr`.
	 */
	private function wrapWithChainDispatch(
		body:Expr, chainField:String, writeFnName:String, node:ShapeNode, precPostfix:Int
	):Expr {
		// Locate the Call-shaped sibling (postfix Star with `methodChain`).
		var callBranch:Null<ShapeNode> = null;
		for (b in node.children) if (b.fmtReadString('methodChain') != null) {
			if (b.children.length == 2 && b.children[1].kind == Star) {
				callBranch = b;
				break;
			}
		}
		if (callBranch == null)
			Context.error('WriterLowering.methodChain: expected a sibling postfix-Star ctor with @:fmt(methodChain(...))', Context.currentPos());
		final cb:ShapeNode = callBranch;
		final callOpen:String = cb.annotations.get('postfix.op');
		final callClose:String = cb.annotations.get('postfix.close') ?? '';
		final callSep:String = cb.annotations.get('lit.sepText') ?? ',';
		final callWrapField:Null<String> = cb.fmtReadString('wrapRules');
		final callTcExpr:Expr = trailingCommaExpr(cb);
		// Args list shape: the Call ctor MUST carry `@:fmt(wrapRules(
		// '<field>'))` for the chain-emit's per-segment rendering to use
		// the same arg layout as a regular Call. Surfacing this as a
		// macro-time error rather than carrying a dead fallback per
		// architecture skill ("no complexity before pain"); a future
		// grammar that drops wrapRules can extend this path then.
		if (callWrapField == null)
			Context.error('WriterLowering.methodChain: Call sibling ctor must carry @:fmt(wrapRules(\'<field>\')) for the chain-emit per-segment args layout to share the regular call shape', Context.currentPos());
		final cwf:String = callWrapField;
		final callRulesExpr:Expr = {
			expr: EField(macro opt, cwf),
			pos: Context.currentPos(),
		};
		final argsListExpr:Expr = macro anyparse.format.wrap.WrapList.emit(
			$v{callOpen}, $v{callClose}, $v{callSep}, _argDocs, opt,
			_de(), _de(), false, $callRulesExpr, $callTcExpr
		);
		final chainRulesExpr:Expr = {
			expr: EField(macro opt, chainField),
			pos: Context.currentPos(),
		};
		final writeIdent:Expr = {
			expr: EConst(CIdent(writeFnName)),
			pos: Context.currentPos(),
		};
		// ω-postfix-starsuffix-trivia: per-arg Doc comprehension below
		// must mirror `lowerPostfixStar`'s trivia branch: when args are
		// `Array<Trivial<HxExprT>>` (auto-wrapped by TriviaTypeSynth),
		// read `.node` for the recursive write and append
		// `.trailingComment` verbatim. Plain-mode and grammars that
		// don't auto-collect on the postfix Star-suffix keep the
		// pre-slice direct `_a` access.
		final cbStar:ShapeNode = cb.children[1];
		final isCallTriviaStar:Bool = ctx.trivia
			&& cbStar.annotations.get('trivia.starCollects') == true;
		final argDocsExpr:Expr = isCallTriviaStar
			? macro {
				final _argDocs:Array<anyparse.core.Doc> = [];
				for (_a in _args) {
					final _aDoc:anyparse.core.Doc = $writeIdent(_a.node, opt, -1);
					final _aTc:Null<String> = _a.trailingComment;
					// `trailingCommentDocVerbatim` already prepends ' '.
					_argDocs.push(_aTc != null
						? _dc([_aDoc, trailingCommentDocVerbatim(_aTc, opt)])
						: _aDoc);
				}
				_argDocs;
			}
			: macro [for (_a in _args) $writeIdent(_a, opt, -1)];
		// Receiver renders at the postfix precedence so a binop /
		// ternary receiver gets parenthesised — `(a + b).foo().bar()`
		// must keep its parens or the chain misreads as
		// `a + b.foo().bar()`. Mirrors the `lowerEnumBranch` postfix
		// path which passes `precPostfix` for the same reason.
		final precExpr:Expr = macro $v{precPostfix};
		// The pattern names `Call` and `FieldAccess` resolve against the
		// switch value's enum (`HxExprT` in trivia mode, `HxExpr` in
		// plain mode). The macro emits the same unqualified ctor names
		// for both modes — Haxe's typer resolves to whichever sibling
		// ctor lives on the `value` parameter's enum.
		return macro {
			final _segs:Array<anyparse.core.Doc> = [];
			var _cursor = value;
			var _receiver = value;
			while (true) {
				switch _cursor {
					case Call(_op, _args):
						switch _op {
							case FieldAccess(_prev, _fld):
								final _argDocs:Array<anyparse.core.Doc> = $argDocsExpr;
								final _argsDoc:anyparse.core.Doc = $argsListExpr;
								_segs.unshift(_dc([_dt('.' + _fld), _argsDoc]));
								_cursor = _prev;
							case _:
								_receiver = _cursor;
								break;
						}
					case FieldAccess(_prev, _fld):
						_segs.unshift(_dt('.' + _fld));
						_cursor = _prev;
					case _:
						_receiver = _cursor;
						break;
				}
			}
			if (_segs.length >= 2) {
				final _recDoc:anyparse.core.Doc = $writeIdent(_receiver, opt, $precExpr);
				return anyparse.format.wrap.MethodChainEmit.emit(_recDoc, _segs, opt, $chainRulesExpr);
			}
			$body;
		};
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
	private static function fmtReadCall(node:ShapeNode, name:String):Null<Expr> {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return null;
		for (entry in meta) if (entry.name == ':fmt') {
			for (param in entry.params) switch param.expr {
				case ECall({expr: EConst(CIdent(id))}, [arg]) if (id == name): return arg;
				case _:
			}
		}
		return null;
	}

	private function lowerEnumBranch(
		branch:ShapeNode, typePath:String, writeFnName:String,
		hasPratt:Bool, argNames:Array<String>, precPostfix:Int
	):Expr {
		final children:Array<ShapeNode> = branch.children;
		final litList:Null<Array<String>> = branch.annotations.get('lit.litList');
		final leadText:Null<String> = branch.annotations.get('lit.leadText');
		final trailText:Null<String> = branch.annotations.get('lit.trailText');
		final kwLead:Null<String> = branch.annotations.get('kw.leadText');

		final prefixOp:Null<String> = branch.annotations.get('prefix.op');
		final postfixOp:Null<String> = branch.annotations.get('postfix.op');
		final postfixClose:Null<String> = branch.annotations.get('postfix.close');
		final prattPrec:Null<Int> = branch.annotations.get('pratt.prec');
		final prattAssoc:Null<String> = branch.annotations.get('pratt.assoc');
		final ternaryOp:Null<String> = branch.annotations.get('ternary.op');
		final ternaryPrec:Null<Int> = branch.annotations.get('ternary.prec');
		final ternarySep:Null<String> = branch.annotations.get('ternary.sep');

		// ---- Ternary ----
		if (ternaryOp != null) {
			final tPrec:Int = (ternaryPrec : Int);
			final sep:String = (ternarySep : String);
			final condCall:Expr = makeWriteCall(writeFnName, macro $i{argNames[0]}, hasPratt, tPrec + 1);
			final middleCall:Expr = makeWriteCall(writeFnName, macro $i{argNames[1]}, hasPratt, -1);
			final rightCall:Expr = makeWriteCall(writeFnName, macro $i{argNames[2]}, hasPratt, -1);
			final opWithSpaces:String = ' ' + ternaryOp + ' ';
			final sepWithSpaces:String = ' ' + sep + ' ';
			return macro {
				final _inner:anyparse.core.Doc = _dc([
					$condCall, _dt($v{opWithSpaces}),
					$middleCall, _dt($v{sepWithSpaces}),
					$rightCall,
				]);
				if ($v{tPrec} < ctxPrec) _dc([_dt('('), _inner, _dt(')')]) else _inner;
			};
		}

		// ---- Infix ----
		if (prattPrec != null) {
			final prec:Int = (prattPrec : Int);
			final assoc:String = prattAssoc ?? 'Left';
			final opText:String = getOperatorText(branch);
			final leftCtx:Int = assoc == 'Right' ? prec + 1 : prec;
			final rightCtx:Int = assoc == 'Right' ? prec : prec + 1;
			// `@:fmt(tight)` on the ctor suppresses the default surrounding
			// spaces. Used by Haxe's interval `...` where `0...n` is the
			// idiomatic shape — the policy is grammar-level (per-operator),
			// not format-level, because tightness is a property of the
			// specific operator literal, not the language as a whole.
			final isTight:Bool = branch.fmtHasFlag('tight');
			// Assignment-class operators (prec=0: `=`, `+=`, `<<=`, `??=`, …)
			// keep flat emission. The break point for a long assignment lives
			// inside its RHS chain (which has its own Group), not at the `=`
			// itself — haxe-formatter expects `dirty = dirty\n\t|| ...`, i.e.
			// `lhs = first-of-rhs` on the lead line and breaks ONLY at the
			// inner binary chain. Wrapping `=` in a Group would force a break
			// before `=` once the full flat width exceeds the line, producing
			// `dirty\n\t= ...` — wrong indent and wrong shape.
			final isAssign:Bool = prec == 0;
			final opWithSpaces:String = isTight ? opText : ' ' + opText + ' ';
			// Asymmetric infix mirror of Lowering.lowerPrattLoop: when the
			// right child references a different enum (e.g. `Is(left:HxExpr,
			// right:HxType)`), the right operand uses that type's own writer
			// at its default ctxPrec (no precedence parenthesisation cross-
			// type). Self-symmetric branches keep the existing same-fn path.
			final rightChild:ShapeNode = children[1];
			final rightRef:Null<String> = rightChild.kind == Ref ? rightChild.annotations.get('base.ref') : null;
			final isAsymmetric:Bool = rightRef != null && simpleName(rightRef) != simpleName(typePath);
			final leftCall:Expr = makeWriteCall(writeFnName, macro $i{argNames[0]}, hasPratt, leftCtx);
			final rightCall:Expr = isAsymmetric
				? makeWriteCall(writeFnFor(rightRef), macro $i{argNames[1]}, false, -1)
				: makeWriteCall(writeFnName, macro $i{argNames[1]}, hasPratt, rightCtx);
			if (isTight || isAssign) {
				// Assign / arrow ops (prec 0, non-tight): split the trailing
				// space into `_dop(' ')` (OptSpace) so the renderer drops it
				// when the RHS emits a leading break-mode hardline (e.g.
				// `dirty =\n\t\t\tdirty || ...` from a OnePerLine wrapping
				// chain on the RHS), avoiding a spurious `dirty = \n…`
				// trailing-space-before-newline. Flat emission is unchanged
				// — the next Text from `$rightCall` flushes the OptSpace.
				// Tight ops keep the original single-Text shape (no spaces).
				final innerExpr:Expr = isAssign && !isTight
					? macro _dc([
						$leftCall, _dt(' '), _dt($v{opText}), _dop(' '), $rightCall,
					])
					: macro _dc([
						$leftCall, _dt($v{opWithSpaces}), $rightCall,
					]);
				return macro {
					final _inner:anyparse.core.Doc = $innerExpr;
					if ($v{prec} < ctxPrec) _dc([_dt('('), _inner, _dt(')')]) else _inner;
				};
			}
			// Slice ω-binop-wraprules: `||` / `&&` (opBoolChain) and
			// `+` / `-` (opAddSubChain) dispatch to a chain-level emit
			// that gathers the full same-class subtree into a flat
			// `(items, ops)` pair, runs the cascade once, and emits one
			// `BinaryChainEmit` shape (NoWrap / OnePerLineAfterFirst /
			// OnePerLine / FillLine). Inner same-class `BinOp` nodes are
			// consumed by the AST walk — they never re-enter the writer
			// through their own ctor branch, so the cascade evaluates
			// exactly once per chain regardless of depth. Mirror of
			// `wrapWithChainDispatch` for postfix method chains.
			//
			// Extraction is inline (vs an external helper) so the
			// `case Or(...)` / `case And(...)` patterns resolve against
			// the current writer's value type — `HxExpr` in plain mode,
			// `HxExprT` in trivia mode (paired type carries the same
			// ctor names). A typed external helper would force a
			// `(_e:HxExpr)` parameter that fails compile in trivia
			// writers.
			final isChainBool:Bool = opText == '||' || opText == '&&';
			final isChainAddSub:Bool = opText == '+' || opText == '-';
			if (isChainBool || isChainAddSub) {
				final chainRulesField:String = isChainBool ? 'opBoolChainWrap' : 'opAddSubChainWrap';
				final chainRulesExpr:Expr = {
					expr: EField(macro opt, chainRulesField),
					pos: Context.currentPos(),
				};
				final argTypeCT:ComplexType = ruleValueCT(typePath);
				// Leaf operands render at the chain's own precedence. A
				// sub-expression with strictly lower prec (ternary inside
				// `||`, assign inside `+`) gets the parens it needs;
				// same-class operators are consumed by the extractor.
				final leafCall:Expr = makeWriteCall(writeFnName, macro _e, hasPratt, prec);
				final gatherSwitch:Expr = isChainBool
					? macro switch _e {
						case Or(_l, _r): _gather(_l); _ops.push('||'); _gather(_r);
						case And(_l, _r): _gather(_l); _ops.push('&&'); _gather(_r);
						case _: _items.push($leafCall);
					}
					: macro switch _e {
						case Add(_l, _r): _gather(_l); _ops.push('+'); _gather(_r);
						case Sub(_l, _r): _gather(_l); _ops.push('-'); _gather(_r);
						case _: _items.push($leafCall);
					};
				return macro {
					final _items:Array<anyparse.core.Doc> = [];
					final _ops:Array<String> = [];
					function _gather(_e:$argTypeCT):Void $gatherSwitch;
					_gather($i{argNames[0]});
					_ops.push($v{opText});
					_gather($i{argNames[1]});
					final _inner:anyparse.core.Doc = anyparse.format.wrap.BinaryChainEmit.emit(
						_items, _ops, opt, $chainRulesExpr
					);
					if ($v{prec} < ctxPrec) _dc([_dt('('), _inner, _dt(')')]) else _inner;
				};
			}
			// Group/Line/Nest wrap for non-tight non-assign non-chain
			// infix (compare, shift, bitwise, `is`, `??`): lets the
			// renderer pick flat (Line(' ') → space) when the chain's
			// full flat width fits in the remaining columns, else break.
			// Per-binary Group cascading from G.1 (ω-binop-group-wrap).
			final opAfterText:String = opText + ' ';
			return macro {
				final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space
					? opt.indentSize : opt.tabWidth;
				final _inner:anyparse.core.Doc = _dg(_dc([
					$leftCall,
					_dn(_cols, _dc([_dl(), _dt($v{opAfterText}), $rightCall])),
				]));
				if ($v{prec} < ctxPrec) _dc([_dt('('), _inner, _dt(')')]) else _inner;
			};
		}

		// ---- Prefix ----
		if (prefixOp != null) {
			final operandCall:Expr = makeWriteCall(writeFnName, macro $i{argNames[0]}, hasPratt, precPostfix);
			return macro _dc([_dt($v{prefixOp}), $operandCall]);
		}

		// ---- Postfix ----
		if (postfixOp != null) {
			final operandCall:Expr = makeWriteCall(writeFnName, macro $i{argNames[0]}, hasPratt, precPostfix);
			if (children.length == 1) {
				final text:String = postfixOp + (postfixClose ?? '');
				return macro _dc([$operandCall, _dt($v{text})]);
			}
			if (children.length == 2 && children[1].kind == Star)
				return lowerPostfixStar(branch, typePath, writeFnName, hasPratt, argNames, operandCall);
			if (children.length == 2) {
				final suffixRef:String = children[1].annotations.get('base.ref');
				final suffixFn:String = writeFnFor(suffixRef);
				final suffixCall:Expr = {
					expr: ECall(macro $i{suffixFn}, [macro $i{argNames[1]}, macro opt]),
					pos: Context.currentPos(),
				};
				final close:String = postfixClose ?? '';
				if (close.length > 0)
					return macro _dc([$operandCall, _dt($v{postfixOp}), $suffixCall, _dt($v{close})]);
				return macro _dc([$operandCall, _dt($v{postfixOp}), $suffixCall]);
			}
			Context.fatalError('WriterLowering: unsupported postfix shape', Context.currentPos());
			throw 'unreachable';
		}

		// ---- Case 0: zero-arg kw ----
		if (kwLead != null && children.length == 0 && litList == null) {
			final trail:Null<String> = branch.annotations.get('lit.trailText');
			final text:String = kwLead + (trail ?? '');
			return macro _dt($v{text});
		}

		// ---- Case 1: zero-arg lit ----
		if (litList != null && litList.length == 1 && children.length == 0)
			return macro _dt($v{litList[0]});

		// ---- Case 2: multi-lit Bool ----
		if (litList != null && litList.length > 1 && children.length == 1) {
			final trueLit:String = litList[0];
			final falseLit:String = litList[1];
			return macro if (_v0) _dt($v{trueLit}) else _dt($v{falseLit});
		}

		// ---- Case 4: single-arg Star with lead/trail ----
		if (leadText != null && trailText != null && children.length == 1 && children[0].kind == Star)
			return lowerEnumStar(branch, typePath, writeFnName, hasPratt, argNames);

		// ---- Case 3: single-arg Ref ----
		if (litList == null && children.length == 1 && children[0].kind == Ref) {
			final refName:String = children[0].annotations.get('base.ref');
			final subFn:String = writeFnFor(refName);
			final isSelfRef:Bool = simpleName(refName) == simpleName(typePath);
			final subCall:Expr = if (isSelfRef && hasPratt)
				{expr: ECall(macro $i{subFn}, [macro $i{argNames[0]}, macro opt, macro -1]), pos: Context.currentPos()}
			else
				{expr: ECall(macro $i{subFn}, [macro $i{argNames[0]}, macro opt]), pos: Context.currentPos()};

			// ω-return-body: ctor-level `@:fmt(bodyPolicy(...))` on a kw-led
			// single-Ref branch (e.g. `HxStatement.ReturnStmt(value:HxExpr)`)
			// wraps the sub-call through `bodyPolicyWrap` so the kw→body
			// separator is runtime-switchable. The wrap supplies the
			// separator (`_dt(' ')` for `Same`, `_dn(_cols, _dhl + body)`
			// for `Next`, etc.), so the kw must drop its trailing space —
			// the existing `subStructStartsWithBodyPolicy` path covers the
			// sub-struct case (`HxStatement.IfStmt(stmt:HxIfStmt)` where the
			// `bodyPolicy` flag lives on a field of `HxIfStmt`); this new
			// path covers the direct-Ref case where no wrapper struct hosts
			// the field.
			final ctorBodyPolicyFlag:Null<String> = branch.fmtReadString('bodyPolicy');
			final policyWrapped:Expr = ctorBodyPolicyFlag != null
				? bodyPolicyWrap(ctorBodyPolicyFlag, subCall, macro $i{argNames[0]}, refName, false, null)
				: subCall;

			// ω-return-indent-objectliteral: ctor-level
			// `@:fmt(indentValueIfCtor('<ctor>', '<optField>', '<leftCurlyField>'))`
			// on a kw-led single-Ref branch (e.g. `HxStatement.ReturnStmt`)
			// extends the RHS-style indent rule of `HxVarDecl.init` /
			// `HxObjectField.value` to the ctor-arg form. When the runtime
			// conditions match (named bool opt true AND named leftCurly opt
			// `Next` AND `Type.enumConstructor(value) == ctorName`), bypass
			// `bodyPolicyWrap`'s sameLayoutExpr fallback (which emits a
			// trailing-space-before-hardline `_dt(' ') + writeCall`) and
			// instead emit `Nest(_cols, subCall)` directly. The body's
			// own leading `_dhl` (e.g. ObjectLit's `leftCurly=Next`) picks
			// up `+cols` indent through the Nest so the `{` lands one step
			// past the kw column. When the conditions don't match, falls
			// through to `policyWrapped` unchanged. Reads three string args
			// off the branch (mirrors the `child`-level helper of the same
			// name).
			final indentArgs:Null<Array<String>> = branch.fmtReadStringArgs('indentValueIfCtor');
			final indentWrapped:Expr = if (indentArgs == null) policyWrapped
			else {
				if (indentArgs.length != 3) Context.fatalError('WriterLowering: @:fmt(indentValueIfCtor(...)) on ctor requires (ctorName, optField, leftCurlyField), got ${indentArgs.length} args', Context.currentPos());
				final ctorName:String = indentArgs[0];
				final optField:String = indentArgs[1];
				final leftCurlyField:String = indentArgs[2];
				final optAccess:Expr = {expr: EField(macro opt, optField), pos: Context.currentPos()};
				final leftCurlyAccess:Expr = {expr: EField(macro opt, leftCurlyField), pos: Context.currentPos()};
				final valueAccess:Expr = macro $i{argNames[0]};
				macro {
					final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
					if ($optAccess
						&& $leftCurlyAccess == anyparse.format.BracePlacement.Next
						&& Type.enumConstructor($valueAccess) == $v{ctorName}) _dc([_dop(' '), _dn(_cols, $subCall)]) else $policyWrapped;
				};
			}

			// ω-string-interp-noformat: when the ctor opted into source-
			// byte capture (`@:fmt(captureSource('<optName>'))` + trivia
			// mode), the synth ctor's `argNames[1]` holds the verbatim
			// slice between `@:lead` and `@:trail`. Gate emission on the
			// named `Bool` runtime option: when `false`, emit the captured
			// bytes via `_dt(sourceText)` instead of recursing into the
			// parsed `expr`. The two modes are runtime-selectable per write
			// — the same parsed AST can flip between formatted and verbatim
			// by toggling the knob. The flag arg names the runtime field
			// so format-neutrality is preserved (mirror of `bodyPolicy` /
			// `wrapRules` parametric flags).
			final captureSourceOpt:Null<String> = ctx.trivia
				? branch.fmtReadString('captureSource')
				: null;
			final bodyExpr:Expr = if (captureSourceOpt != null) {
				final sourceAccess:Expr = macro $i{argNames[1]};
				final optAccess:Expr = {
					expr: EField(macro opt, captureSourceOpt),
					pos: Context.currentPos(),
				};
				macro $optAccess ? $indentWrapped : _dt($sourceAccess);
			} else indentWrapped;

			// When the sub-struct opens with a bare-Ref @:fmt(bodyPolicy(...)) field,
			// the sub-struct's writer emits the header→body separator via
			// bodyPolicyWrap (Same/Next/FitLine). Stripping the trailing
			// space from kwLead here avoids a double space (Same) or
			// trailing-space-before-hardline (Next/FitLine). Non-policy
			// sub-structs keep the pre-ψ₅ `kw ` shape.
			//
			// Also strip when the sub-struct's first field has a tight
			// `@:lead` (format-declared in `FormatInfo.tightLeads`, e.g.
			// `:` for Haxe). HxDefaultBranch opens with `@:lead(':')` —
			// without the strip we emit `default :` instead of `default:`.
			// Non-tight leads (`(`, `{`) keep the space — `if (`, `else {`.
			//
			// ω-expression-try-body-break: also strip when the sub-struct's
			// first field carries `@:fmt(bodyBreak(...))` — the field's own
			// `bodyBreakWrap` provides the conditional space/hardline-Nest
			// between the kw and the body, so leaving the trailing space in
			// would yield `try  body` (`Same`) or `try \n…body` (`Next`).
			//
			// ω-statement-bare-break: same reasoning for `@:fmt(bareBodyBreaks)`
			// — `bareBodyBreakWrap` provides the conditional inline-space /
			// hardline-Nest based on body ctor shape. Statement-form
			// `HxTryCatchStmt.body` opts into this; the parent kw `try` must
			// drop its trailing space so the wrap is the sole separator.
			final stripKwTrailingSpace:Bool = ctorBodyPolicyFlag != null
				|| subStructStartsWithBodyPolicy(refName)
				|| subStructStartsWithBodyBreak(refName)
				|| subStructStartsWithBareBodyBreaks(refName)
				|| subStructStartsWithTightLead(refName)
				// Combined kw + `@:wrap`/`@:lead` on the same single-Ref
				// branch composes as a tight visual unit: `@:overload(...)`
				// (kw `@:overload` + wrap lead `(`) renders without a
				// space between them. Strip the kw's trailing space so
				// the lead literal abuts the kw — first consumer is
				// `HxMetadata.OverloadMeta`. Symmetric with the parser-
				// side composition extension in Lowering Case 3.
				|| leadText != null;
			// ω-if-policy / ω-control-flow-policies / ω-try-policy /
			// ω-anon-fn-paren-policy: an enum branch with `@:fmt(<flag>)`
			// whose runtime value is `WhitespacePolicy` opts into a
			// runtime-switched trailing space after the kw. Two semantic
			// flavours feed the SAME slot:
			//  - kw-side (`After`/`Both` → space) for control-flow knobs
			//    `ifPolicy` / `forPolicy` / `whilePolicy` / `switchPolicy`
			//    / `tryPolicy` — JSON name like `"onlyAfter"` reads as
			//    "after the kw".
			//  - paren-side (`Before`/`Both` → space) for `anonFuncParens`,
			//    matching haxe-formatter's
			//    `whitespace.parenConfig.anonFuncParamParens.openingPolicy`
			//    naming (sibling of `funcParamParens` / `callParens`).
			// `firstFmtFlag` partitions the lookup so a branch carries at
			// most one of the two flag families. Both helpers return null
			// when no flag matches, letting non-policy branches keep the
			// pre-slice `kwLead + ' '` (or stripped) emission.
			final kwSidePolicySpace:Null<Expr> = stripKwTrailingSpace
				? null
				: kwTrailingSpacePolicy(branch, ['ifPolicy', 'forPolicy', 'whilePolicy', 'switchPolicy', 'tryPolicy']);
			final parenSidePolicySpace:Null<Expr> = stripKwTrailingSpace
				? null
				: kwTrailingSpacePolicyParenSide(branch, ['anonFuncParens']);
			final kwTrailSpace:Null<Expr> = kwSidePolicySpace ?? parenSidePolicySpace;
			final parts:Array<Expr> = [];
			if (kwLead != null) {
				if (kwTrailSpace != null) {
					parts.push(macro _dt($v{kwLead}));
					parts.push(kwTrailSpace);
				} else {
					final kwText:String = stripKwTrailingSpace ? kwLead : kwLead + ' ';
					parts.push(macro _dt($v{kwText}));
				}
			}
			if (leadText != null) parts.push(macro _dt($v{leadText}));
			parts.push(bodyExpr);
			if (trailText != null) {
				// ω-trailopt-source-track: in trivia mode, the parser
				// captures `matchLit`'s presence flag into the synth ctor's
				// positional `trailPresent:Bool` arg (`argNames[1]`). The
				// writer gates trail emission on it directly — `true` →
				// emit literal; `false` → empty Doc. This bypasses the
				// AST-shape gate `trailOptShapeGateWrap`, which is a Plain-
				// mode workaround for missing source-presence info. Trivia
				// mode preserves authored source verbatim.
				final isTriviaTrailOpt:Bool = ctx.trivia
					&& TriviaTypeSynth.isAltTrailOptBranch(branch);
				final trailExpr:Expr = if (isTriviaTrailOpt) {
					final flagAccess:Expr = macro $i{argNames[1]};
					macro $flagAccess ? _dt($v{trailText}) : _de();
				} else {
					trailOptShapeGateWrap(branch, trailText, argNames[0])
						?? macro _dt($v{trailText});
				};
				parts.push(trailExpr);
			}
			// ω-paren-wrap-break: `@:wrap(open, close)` enum ctor (no kw,
			// both lead and trail set) renders as a Group whose break
			// shape adds a hardline before the close delimiter, so a
			// multi-line inner Doc lands the close on its own line at
			// the outer indent — matches haxe-formatter's
			// `return !(\n\t\t\t...\n\t\t)` shape on issue_187_oneline.
			// Gated at runtime on `WrapList.startsWithHardline(_inner)`
			// so the close-on-own-line behavior is symmetric with the
			// open-with-hardline behavior of the inner Doc:
			//  - inner with leading hardline (e.g. `BinaryChainEmit`
			//    `OnePerLine` shape — every operand on its own line):
			//    close goes on its own line.
			//  - inner without leading hardline (e.g.
			//    `OnePerLineAfterFirst` keeps items[0] inline): close
			//    stays glued to the last item — matches the
			//    default-cascade `((items[0]\n\t…\n\titems[n-1]))`
			//    shape on issue_187_multi_line_wrapped_assignment.
			// The flat shape stays byte-identical to the pre-slice
			// `lead + inner + trail` concat.
			final isWrapShape:Bool = kwLead == null && leadText != null && trailText != null && parts.length == 3;
			if (isWrapShape) {
				final leadDoc:Expr = parts[0];
				final innerDoc:Expr = parts[1];
				final trailDoc:Expr = parts[2];
				return macro {
					final _wrapInner:anyparse.core.Doc = $innerDoc;
					final _wrapTrail:anyparse.core.Doc = $trailDoc;
					anyparse.format.wrap.WrapList.startsWithHardline(_wrapInner)
						? _dg(_dib(
							_dc([$leadDoc, _wrapInner, _dhl(), _wrapTrail]),
							_dc([$leadDoc, _wrapInner, _wrapTrail])
						))
						: _dc([$leadDoc, _wrapInner, _wrapTrail]);
				};
			}

			return if (parts.length == 1) parts[0]
			else dcCall(parts);
		}

		Context.fatalError('WriterLowering: unsupported enum branch shape for ${simpleName(typePath)}', Context.currentPos());
		throw 'unreachable';
	}

	/** Postfix Star-suffix form: `Call(operand, args:Array<T>)`. */
	private function lowerPostfixStar(
		branch:ShapeNode, typePath:String, writeFnName:String,
		hasPratt:Bool, argNames:Array<String>, operandCall:Expr
	):Expr {
		final postfixOp:String = branch.annotations.get('postfix.op');
		final postfixClose:String = branch.annotations.get('postfix.close') ?? '';
		final starNode:ShapeNode = branch.children[1];
		final inner:ShapeNode = starNode.children[0];
		final elemRefName:String = inner.annotations.get('base.ref');
		final isSelfRef:Bool = simpleName(elemRefName) == simpleName(typePath);
		final elemFn:String = isSelfRef ? writeFnName : writeFnFor(elemRefName);
		final elemSep:String = branch.annotations.get('lit.sepText') ?? ',';

		// ω-postfix-starsuffix-trivia: when TriviaAnalysis auto-marks
		// the postfix Star-suffix Star with `trivia.starCollects=true`
		// (Call.args, IndexAccess analogues, etc.), TriviaTypeSynth wraps
		// each elem in `Trivial<elemT>`. Read `.node` for the element
		// write call and append `.trailingComment` (verbatim, with
		// delimiters intact) as `_dt(' ') + trailingCommentDoc` after
		// the element when non-null. Plain mode and non-trivia-collecting
		// Stars keep the pre-slice direct `_args[_i]` access.
		final isTriviaStar:Bool = ctx.trivia
			&& starNode.annotations.get('trivia.starCollects') == true;
		final elemRead:Expr = isTriviaStar ? macro _args[_i].node : macro _args[_i];
		final elemCallArgs:Array<Expr> = [elemRead, macro opt];
		if (isSelfRef && hasPratt) elemCallArgs.push(macro -1);
		final elemCall:Expr = {
			expr: ECall(macro $i{elemFn}, elemCallArgs),
			pos: Context.currentPos(),
		};

		final argsAccess:Expr = macro $i{argNames[1]};
		final tcExpr:Expr = trailingCommaExpr(branch);
		// ω-call-parens: a `@:postfix('(', ')')` ctor with
		// `@:fmt(callParens)` opts into a runtime-switched space before
		// the open delim, mirroring `funcParamParens` on a struct Star.
		// `openDelimPolicySpace` returns null when the flag is absent so
		// the pre-slice tight emission stays byte-identical.
		final openSpace:Null<Expr> = openDelimPolicySpace(branch, ['callParens']);
		// ω-fill-primitive: `@:fmt(fill)` routes the args list through the
		// Fill helper so items pack inline as long as each fits in the
		// remaining budget; on overflow the separator before the offending
		// item breaks at the args' indent. Default `sepList` stays for any
		// postfix-Star ctor that doesn't opt in.
		//
		// ω-wraprules-callparam: `@:fmt(wrapRules('<optionFieldName>'))`
		// supersedes both above paths — routes the args list through the
		// runtime `WrapList.emit` engine driven by the named `WrapRules`
		// cascade on `opt`. Mirrors the struct-Star branch in `lowerStruct`
		// (slice ω-wraprules-objlit). First postfix-Star consumer is
		// `HxExpr.Call.args` (`callParameterWrap`); future slices wire
		// other postfix-Star ctors (array-access, etc.) through the same
		// engine. `@:fmt(fill)` / `@:fmt(fillDoubleIndent)` remain orthogonal
		// for postfix-Star sites that opt into Wadler fillSep without a
		// per-construct cascade.
		final wrapRulesField:Null<String> = branch.fmtReadString('wrapRules');
		final useFill:Bool = branch.fmtHasFlag('fill');
		final fillDouble:Bool = branch.fmtHasFlag('fillDoubleIndent');
		final sepListCall:Expr = if (wrapRulesField != null) {
			final rulesExpr:Expr = {
				expr: EField(macro opt, wrapRulesField),
				pos: Context.currentPos(),
			};
			macro anyparse.format.wrap.WrapList.emit($v{postfixOp}, $v{postfixClose}, $v{elemSep}, _docs, opt, _de(), _de(), false, $rulesExpr, $tcExpr);
		} else if (useFill) {
			macro fillList($v{postfixOp}, $v{postfixClose}, $v{elemSep}, _docs, opt, $tcExpr, _de(), _de(), false, $v{fillDouble});
		} else {
			macro sepList($v{postfixOp}, $v{postfixClose}, $v{elemSep}, _docs, opt, $tcExpr, _de(), _de(), false);
		};
		final dcArgs:Array<Expr> = [operandCall];
		if (openSpace != null) dcArgs.push(openSpace);
		dcArgs.push(sepListCall);
		final dcExpr:Expr = dcCall(dcArgs);
		final pushElemExpr:Expr = isTriviaStar
			? macro {
				final _elem:anyparse.core.Doc = $elemCall;
				final _tc:Null<String> = _args[_i].trailingComment;
				// `trailingCommentDocVerbatim` already prepends ' ' to
				// the captured content, so the per-arg Doc is just
				// `_elem ++ trailingDoc` — no extra `_dt(' ')`.
				_docs.push(_tc != null
					? _dc([_elem, trailingCommentDocVerbatim(_tc, opt)])
					: _elem);
			}
			: macro _docs.push($elemCall);
		return macro {
			final _args = $argsAccess;
			final _docs:Array<anyparse.core.Doc> = [];
			var _i:Int = 0;
			while (_i < _args.length) {
				$pushElemExpr;
				_i++;
			}
			$dcExpr;
		};
	}

	/** Enum Case 4 Star: `@:lead @:trail` with optional `@:sep`. */
	private function lowerEnumStar(
		branch:ShapeNode, typePath:String, writeFnName:String,
		hasPratt:Bool, argNames:Array<String>
	):Expr {
		final leadText:String = branch.annotations.get('lit.leadText');
		final trailText:String = branch.annotations.get('lit.trailText');
		final sepText:Null<String> = branch.annotations.get('lit.sepText');
		final kwLead:Null<String> = branch.annotations.get('kw.leadText');
		final starNode:ShapeNode = branch.children[0];
		final inner:ShapeNode = starNode.children[0];
		final elemRefName:String = inner.annotations.get('base.ref');
		final isSelfRef:Bool = simpleName(elemRefName) == simpleName(typePath);
		final elemFn:String = isSelfRef ? writeFnName : writeFnFor(elemRefName);

		final elemCallArgs:Array<Expr> = [macro _args[_i], macro opt];
		if (isSelfRef && hasPratt) elemCallArgs.push(macro -1);
		final elemCall:Expr = {
			expr: ECall(macro $i{elemFn}, elemCallArgs),
			pos: Context.currentPos(),
		};

		final argsAccess:Expr = macro $i{argNames[0]};
		final parts:Array<Expr> = [];
		if (kwLead != null) parts.push(macro _dt($v{kwLead + ' '}));

		final isTriviaStar:Bool = ctx.trivia && starNode.annotations.get('trivia.starCollects') == true;
		if (isTriviaStar) {
			// ω-orphan-trivia: Alt-branch Star still has no synth trailing
			// orphan slots — `TrailingBlankBefore`/`TrailingLeading` are
			// Seq-only. Pass null so leftover orphan trivia inside e.g.
			// `BlockStmt({ /*c*/ })` continues to drop until that synth
			// is widened.
			//
			// ω-close-trailing-alt: same-line trailing comment captured
			// after the close literal (`} // catch`) IS available — the
			// synth ctor grew a positional arg (`closeTrailing`) and
			// `argNames[1]` is its writer-side binding. Plain mode keeps
			// the pre-slice null path (no extra arg, no extra binding).
			//
			// ω-open-trailing-alt: parallel slot for the same-line trailing
			// comment captured AFTER the open literal (`[ /* foo */]` for
			// empty arrays, `{ // foo` before first stmt). Synth appends
			// `openTrailing:Null<String>` as `argNames[2]` when the branch
			// also carries `@:lead`. Without this, an inline comment in an
			// otherwise-empty close-peek Star is dropped at parse — the
			// loop's terminal `_lead` is discarded on close-peek break, and
			// `collectTrivia`'s newline-anchored scan skips same-line
			// comments after the open lit anyway.
			final trailCloseAccess:Null<Expr> = TriviaTypeSynth.isAltCloseTrailingBranch(branch)
				? macro $i{argNames[1]}
				: null;
			final trailOpenAccess:Null<Expr> = TriviaTypeSynth.isAltCloseTrailingBranch(branch)
					&& branch.readMetaString(':lead') != null
				? macro $i{argNames[2]}
				: null;
			// ω-trivia-sep: sep-Star Alt branches (e.g. `HxExpr.ArrayExpr`)
			// route to the dedicated sep helper. Block-style (no sep)
			// stays on the always-multi-line path.
			//
			// ω-arraylit-wraprules: forward `@:fmt(wrapRules('<field>'))`
			// from the enum-Case branch to the helper so the no-trivia
			// branch can defer layout to `WrapList.emit` (mirrors the
			// struct-Star path in `lowerStruct`). First Alt-branch
			// consumer is `HxExpr.ArrayExpr.elems` (`arrayLiteralWrap`).
			if (sepText != null) {
				final wrapRulesField:Null<String> = branch.fmtReadString('wrapRules');
				parts.push(triviaSepStarExpr(
					argsAccess, null, null, trailCloseAccess, trailOpenAccess, elemFn, leadText, trailText, sepText,
					wrapRulesField
				));
			} else {
				parts.push(triviaBlockStarExpr(argsAccess, null, null, trailCloseAccess, trailOpenAccess, elemFn, leadText, trailText, true));
			}
		} else if (sepText != null) {
			// See `emitWriterStarField` — `@:sep('\n')` routes to a flat
			// hardline-join emission (format-neutral).
			if (sepText == '\n') {
				parts.push(macro {
					final _args = $argsAccess;
					final _docs:Array<anyparse.core.Doc> = [_dt($v{leadText})];
					var _i:Int = 0;
					while (_i < _args.length) {
						if (_i > 0) _docs.push(_dhl());
						_docs.push($elemCall);
						_i++;
					}
					_docs.push(_dt($v{trailText}));
					_dc(_docs);
				});
			} else {
				final tcExpr:Expr = trailingCommaExpr(branch);
				final openInsideExpr:Expr = delimInsidePolicySpace(branch, ['anonTypeBracesOpen'], false) ?? macro _de();
				final closeInsideExpr:Expr = delimInsidePolicySpace(branch, ['anonTypeBracesClose'], true) ?? macro _de();
				// ω-anontype-wraprules: forward `@:fmt(wrapRules('<field>'))`
				// to `WrapList.emit` for non-trivia-collecting Alt-Star
				// nodes only. `@:trivia`-annotated branches (e.g.
				// `HxExpr.ArrayExpr`) keep the renderer-driven `sepList`
				// path here — their wrapRules dispatch already runs
				// through `triviaSepStarExpr` in trivia mode, and
				// switching the plain-mode path to `WrapList.emit` would
				// lose renderer-driven flat/break for callers that rely
				// on `lineWidth`-based natural breaking (verified by
				// `HxTrailingCommaOptionsTest.testArrayTrailingCommaOnBreak`,
				// which uses plain-mode `HxModuleWriter`). Type-position
				// nodes (`HxType.Anon.fields`) don't carry trivia, so the
				// plain-path dispatch is their only wrapRules surface —
				// a `@:trivia` flip would synthesize unused machinery (see
				// `feedback_trivia_not_freebie.md`).
				final isTriviaCollecting:Bool = starNode.annotations.get('trivia.starCollects') == true;
				final wrapRulesField:Null<String> = isTriviaCollecting
					? null
					: branch.fmtReadString('wrapRules');
				final listCall:Expr = if (wrapRulesField != null) {
					final rulesExpr:Expr = {
						expr: EField(macro opt, wrapRulesField),
						pos: Context.currentPos(),
					};
					macro anyparse.format.wrap.WrapList.emit($v{leadText}, $v{trailText}, $v{sepText}, _docs, opt, $openInsideExpr, $closeInsideExpr, false, $rulesExpr, $tcExpr);
				} else {
					macro sepList($v{leadText}, $v{trailText}, $v{sepText}, _docs, opt, $tcExpr, $openInsideExpr, $closeInsideExpr, false);
				};
				parts.push(macro {
					final _args = $argsAccess;
					final _docs:Array<anyparse.core.Doc> = [];
					var _i:Int = 0;
					while (_i < _args.length) {
						_docs.push($elemCall);
						_i++;
					}
					$listCall;
				});
			}
		} else {
			parts.push(macro {
				final _args = $argsAccess;
				final _docs:Array<anyparse.core.Doc> = [];
				var _i:Int = 0;
				while (_i < _args.length) {
					_docs.push($elemCall);
					_i++;
				}
				blockBody($v{leadText}, $v{trailText}, _docs, opt);
			});
		}
		return if (parts.length == 1) parts[0]
		else dcCall(parts);
	}

	// -------- struct rule --------

	private function lowerStruct(node:ShapeNode, typePath:String):Expr {
		final isRaw:Bool = node.hasMeta(':raw');
		final parts:Array<Expr> = [];
		var isFirstField:Bool = true;
		// Tracks a cumulative bool expr: `true` when ANY preceding
		// bare-tryparse Star in this struct contributed non-zero output.
		// A following bare-Ref field gates its leading separator on this
		// expr — otherwise a stray space leaks when every preceding Star
		// was empty (e.g. `\t function` instead of `\tfunction` when
		// `HxMemberDecl.modifiers` is empty). An intervening bare-
		// tryparse Star ORs its own `length > 0` check into the expr so
		// the signal propagates across a chain of Stars — required by
		// ω-member-meta where `meta` (non-empty) is followed by
		// `modifiers` (empty) is followed by `member`: the member still
		// needs its leading space because `meta` was non-empty two
		// fields back. Reset to `null` on any non-Star field, since the
		// emitted content at that point forms its own boundary.
		var prevAnyStarNonEmpty:Null<Expr> = null;
		// ψ₉: tracks the immediately preceding bare-Ref field that was
		// wrapped via `bodyPolicyWrap` — the next field's `@:fmt(sameLine(...))`
		// separator must then be shape-aware on the preceding body's
		// runtime ctor: a block ctor (e.g. `BlockStmt`) respects the
		// flag (space / hardline), any other ctor forces a hardline
		// because a lone keyword on the same line as a semicolon-
		// terminated body has no meaning.
		var prevBodyField:Null<PrevBodyInfo> = null;
		// ω-close-trailing-alt: tracks the immediately preceding bare-Ref
		// body field (any Ref kind, not just bodyPolicy-wrapped) so a
		// following Star with `@:fmt(sameLine(...))` can emit a runtime
		// override on its FIRST element's separator: when the prev body's
		// runtime ctor was a BlockStmt-style branch with a non-null
		// `closeTrailing` slot, the body's writer already terminated its
		// output with `\n`, and emitting the normal space separator would
		// leak a stray ` ` between the indent and the next sibling. The
		// override emits `_de()` instead. Reset on Star to avoid carrying
		// across non-Ref siblings.
		var prevBareRefBody:Null<PrevBodyInfo> = null;
		// ω-trivia-after-trail: tracks the field name of the immediately
		// preceding mandatory Ref that carried `@:trail` in trivia-bearing
		// mode. The next sibling's `bodyPolicyWrap` reads
		// `value.<prevTrailFieldName>AfterTrail:Null<String>` and threads
		// the captured same-line comment before the body's leading
		// separator. Reset to null on any non-Ref-with-trail sibling so
		// the slot is not carried across an intervening field that would
		// itself terminate the visual gap. Plain mode and non-bearing
		// rules leave this null — the synth slot does not exist there.
		var prevTrailFieldName:Null<String> = null;
		// ψ₁₂: captures the name of the first `@:optional` sibling that
		// carries `@:fmt(bodyPolicy(...))` — consumed by children tagged
		// `@:fmt(fitLineIfWithElse)` to wire a runtime sibling-presence
		// check into the `FitLine` branch of `bodyPolicyWrap`. In the
		// current grammar this is `HxIfStmt.elseBody`; the same shape
		// (pair of bodyPolicy fields, one required, one optional) can
		// opt in without further macro changes. First-match semantics:
		// a struct with two optional bodyPolicy siblings would quietly
		// pick one — no such grammar exists today, and a future case
		// can disambiguate via an explicit arg on `@:fmt(fitLineIfWithElse)`.
		var optionalBodyFieldName:Null<String> = null;
		for (c in node.children) if (c.annotations.get('base.optional') == true && c.fmtReadString('bodyPolicy') != null) {
			optionalBodyFieldName = c.annotations.get('base.fieldName');
			break;
		}

		for (child in node.children) {
			final fieldName:Null<String> = child.annotations.get('base.fieldName');
			if (fieldName == null)
				Context.fatalError('WriterLowering: struct field missing base.fieldName', Context.currentPos());
			// Tracker is "prev" — clear at the start so a non-bearing-Ref
			// field doesn't leak the value set two iterations back.
			final stalePrevBareRefBody:Null<PrevBodyInfo> = prevBareRefBody;
			prevBareRefBody = null;
			final kwLead:Null<String> = child.readMetaString(':kw');
			final leadText:Null<String> = child.readMetaString(':lead');
			final trailText:Null<String> = child.readMetaString(':trail');
			final isStar:Bool = child.kind == Star;
			final isOptional:Bool = child.annotations.get('base.optional') == true;
			final hasElseIf:Bool = child.fmtHasFlag('elseIf');

			final fieldAccess:Expr = {
				expr: EField(macro value, fieldName),
				pos: Context.currentPos(),
			};

			if (isStar) {
				if (isOptional) {
					// Optional close-peek Star (first consumer:
					// `HxTypeRef.params`). Build the inner emission against
					// a narrowed local `_optVal` so the strict-null
					// `final _arr = _optVal` inside `emitWriterStarField`
					// types as `Array<T>`, then wrap the whole thing in a
					// `null` check at the field-access boundary. Empty Doc
					// (`_de()`) is the absent shape — the surrounding Seq
					// emits nothing for the missing list.
					final innerParts:Array<Expr> = [];
					emitWriterStarField(
						child, macro _optVal, innerParts,
						child == node.children[node.children.length - 1],
						typePath, isFirstField, isRaw, stalePrevBareRefBody
					);
					// ω-typeparam-spacing: when the typeParamOpen=Before/Both
					// path injects a leading-space Doc into innerParts, the
					// list grows to two elements. EBlock would evaluate to
					// the last Doc only and silently drop the space — use
					// `_dc([...])` so the writer concatenates both pieces.
					final innerExpr:Expr = if (innerParts.length == 1) innerParts[0]
					else dcCall(innerParts);
					parts.push(macro {
						final _optVal = $fieldAccess;
						if (_optVal != null) $innerExpr else _de();
					});
					prevAnyStarNonEmpty = null;
					prevBodyField = null;
					prevTrailFieldName = null;
					isFirstField = false;
					continue;
				}
				// ω-member-meta: inter-Star separator. When a non-first
				// bare-tryparse Star follows another bare-tryparse Star
				// that may have emitted content, emit a leading separator
				// gated on BOTH previous non-empty AND this Star non-empty.
				// Double-gating prevents `@:allow(...)  var x` (double
				// space) when this Star is empty — the member field's own
				// leading-separator check still runs afterwards against
				// the propagated `prevAnyStarNonEmpty`.
				//
				// In trivia mode the separator picks `_dhl()` vs `_dt(' ')`
				// at runtime from the first element's `newlineBefore`
				// trivia, preserving source-shape across the cross-Star
				// boundary (e.g. `@:final\n\tstatic` round-trips with the
				// newline intact instead of collapsing to a space). Plain
				// mode has no Trivial wrapper, so the double-gated branch
				// emits a plain space (no newline recovery).
				if (isBareTryparseStar(child) && !isFirstField && prevAnyStarNonEmpty != null) {
					final prev:Expr = prevAnyStarNonEmpty;
					if (ctx.trivia) {
						parts.push(macro {
							final _next = $fieldAccess;
							if ($prev && _next.length > 0)
								_next[0].newlineBefore ? _dhl() : _dt(' ');
							else _de();
						});
					} else {
						parts.push(macro ($prev && $fieldAccess.length > 0) ? _dt(' ') : _de());
					}
				}
				emitWriterStarField(child, fieldAccess, parts, child == node.children[node.children.length - 1], typePath, isFirstField, isRaw, stalePrevBareRefBody);
				if (isBareTryparseStar(child)) {
					final thisNonEmpty:Expr = macro $fieldAccess.length > 0;
					prevAnyStarNonEmpty = prevAnyStarNonEmpty == null
						? thisNonEmpty
						: {
							final prev:Expr = prevAnyStarNonEmpty;
							macro $prev || $thisNonEmpty;
						};
				} else {
					prevAnyStarNonEmpty = null;
				}
				prevBodyField = null;
				prevTrailFieldName = null;
				isFirstField = false;
				continue;
			}

			// D61: kw prefix — space before kw (unless first), kw text with trailing space.
			// @:fmt(sameLine(flagName)) on the child switches the leading space to a
			// hardline when `opt.<flagName>` is false (τ₁).
			//
			// ω-untyped-leftCurly: `@:fmt(leftCurly)` on a kw-led mandatory Ref
			// (currently `HxUntypedFnBody.block`) splits the kw emission so the
			// trailing space is replaced by a runtime `BracePlacement` switch —
			// `Same` (default) emits `_dt(' ')` (byte-identical to the unsplit
			// `kwLead + ' '` form), `Next` emits `_dhl()` so the inner `{` lands
			// on its own line at the current indent. The Ref-case body emits no
			// further separator before its writeCall, so pushing leftCurlySeparator
			// here owns the kw→`{` transition fully.
			if (kwLead != null && !isOptional) {
				if (!isFirstField && !isRaw) parts.push(sameLineSeparator(child, prevBodyField, typePath));
				if (child.fmtHasFlag('leftCurly')) {
					// Bare-flag only at this site. Knob-form `@:fmt(leftCurly('<knob>'))`
					// is designed for first-field Star paths where the outer caller
					// produces an `_dop(' ')` (OptSpace) the `Same` branch can ride
					// on; here there is no OptSpace producer, so a knob-form `Same`
					// would silently strip the kw→`{` space.
					if (child.fmtReadString('leftCurly') != null)
						Context.fatalError('WriterLowering: knob-form @:fmt(leftCurly(\'<knob>\')) on kw-led mandatory Ref not supported (no OptSpace producer at this site)', Context.currentPos());
					parts.push(macro _dt($v{kwLead}));
					parts.push(leftCurlySeparator(child));
				} else if (child.fmtHasFlag('anonFuncParens')) {
					// `@:fmt(anonFuncParens)` on a kw-led mandatory Ref
					// routes the kw-trailing space slot through the
					// runtime `WhitespacePolicy` knob (paren-side
					// semantics — `Before` / `Both` emit a space, `None`
					// / `After` collapse it). First consumer is
					// `HxOverloadArgs.fn` (`@:kw('function')` Ref to
					// `HxOverloadFn`) — default `None` keeps
					// `function<T>(...)` / `function(...)` tight, and
					// `whitespace.parenConfig.anonFuncParamParens.openingPolicy:
					// "before"` flips both to `function <T>(...)` /
					// `function (...)`. Mirrors the haxe-formatter
					// convention where `function`-led parens inside a
					// metadata arg track `anonFuncParamParens` (see
					// `MarkWhitespace.determinePOpenPolicy` default
					// fall-through).
					parts.push(macro _dt($v{kwLead}));
					final policySpace:Null<Expr> = kwTrailingSpacePolicyParenSide(child, ['anonFuncParens']);
					if (policySpace != null) parts.push(policySpace);
				} else {
					parts.push(macro _dt($v{kwLead + ' '}));
				}
			}

			// D61: non-optional lead — no space before lead.
			// ψ₇ / ω-E-whitespace: `@:fmt(objectFieldColon)` /
			// `@:fmt(typeHintColon)` on the field switches the emission to
			// a runtime-configurable spacing around the lead text; all
			// other mandatory leads stay tight.
			if (leadText != null && !isOptional)
				parts.push(whitespacePolicyLead(child, leadText, ['objectFieldColon', 'typeHintColon', 'typeCheckColon', 'typedefAssign', 'functionTypeHaxe4', 'arrowFunctions']));

			// Field value
			final bodyPolicyFlag:Null<String> = child.fmtReadString('bodyPolicy');
			final elseFieldName:Null<String> = child.fmtHasFlag('fitLineIfWithElse') ? optionalBodyFieldName : null;
			var justWrappedBody:Null<PrevBodyInfo> = null;
			switch child.kind {
				case Ref if (isOptional):
					final refName:String = child.annotations.get('base.ref');
					final writeFn:String = writeFnFor(refName);
					final rawWriteCall:Expr = {
						expr: ECall(macro $i{writeFn}, [macro _optVal, macro opt]),
						pos: Context.currentPos(),
					};
					// ω-indent-objectliteral: `@:fmt(indentValueIfCtor('<ctor>', '<optField>'))`
					// wraps the writer call in a runtime gate (see
					// `maybeIndentValueIfCtor` / `indentValueIfCtorWrap`).
					// Currently used by `HxVarDecl.init` to indent a multi-
					// line `ObjectLit` value one extra step.
					//
					// ω-expr-body-indent-objectliteral: same-field combination
					// with `@:fmt(bodyPolicy(...))` (e.g. `HxIfExpr.elseBranch`)
					// switches the meta into the SUBTRACTIVE channel through
					// `bodyPolicyWrap`'s `indentObjArgs` argument; see the
					// mandatory-Ref path below for the rationale.
					final indentObjArgs:Null<Array<String>> = child.fmtReadStringArgs('indentValueIfCtor');
					final writeCall:Expr = bodyPolicyFlag != null && indentObjArgs != null
						? rawWriteCall
						: maybeIndentValueIfCtor(rawWriteCall, macro _optVal, child);
					// Leading separator is runtime-conditional when @:fmt(sameLine(...))
					// is present — see sameLineSeparator. Split into (sep, kw+' ')
					// so the sep part can become a hardline (τ₁).
					// @:fmt(bodyPolicy(...)) replaces the final ' ' before the body with
					// a runtime-switched separator (Same/Next/FitLine, ψ₄).
					// ω-issue-316: in Trivia mode, `@:optional @:kw(...)` Ref
					// children grow per-parent sibling slots `<field>AfterKw`
					// / `<field>KwLeading` holding captured trivia from the
					// gap between the kw and the body. Read them off `value`
					// (the parent struct) and forward to `bodyPolicyWrap`
					// which injects them into the kw→body separator. The
					// non-bodyPolicy kwLead path below (`_dt(kwLead + ' ')`)
					// currently drops these slots — no grammar field exercises
					// that combination yet, but a future `@:optional @:kw`
					// without bodyPolicy would lose captured trivia silently.
					final useTriviaGap:Bool = ctx.trivia && kwLead != null;
					final afterKwExpr:Null<Expr> = useTriviaGap
						? {expr: EField(macro value, fieldName + TriviaTypeSynth.AFTER_KW_SUFFIX), pos: Context.currentPos()}
						: null;
					final kwLeadingExpr:Null<Expr> = useTriviaGap
						? {expr: EField(macro value, fieldName + TriviaTypeSynth.KW_LEADING_SUFFIX), pos: Context.currentPos()}
						: null;
					// ω-keep-policy: `<field>BodyOnSameLine:Bool` drives the
					// `Keep` branch of `bodyPolicyWrap` / policySwitch. Only
					// synthesised on optional-kw Ref paths in trivia mode.
					final bodyOnSameLineExpr:Null<Expr> = useTriviaGap
						? {expr: EField(macro value, fieldName + TriviaTypeSynth.BODY_ON_SAME_LINE_SUFFIX), pos: Context.currentPos()}
						: null;
					// ω-trivia-before-kw: own-line comments captured between
					// the preceding token and the kw (e.g. `} // c\nelse`)
					// land in `<field>BeforeKwLeading`. When non-empty, the
					// `kwBeforeDoc` runtime helper replaces the plain
					// `sameLineSeparator` output with hardline-separated
					// comments at the parent's indent level. When empty,
					// the helper degrades to the unmodified separator.
					final beforeKwLeadingExpr:Null<Expr> = useTriviaGap
						? {expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_KW_LEADING_SUFFIX), pos: Context.currentPos()}
						: null;
					// ω-trivia-before-kw-trailing: same-line trailing comment
					// captured between the preceding sibling's last token and
					// the kw (e.g. `resize(); // first\nelse`) lands in
					// `<field>BeforeKwTrailing`. When non-null, prepended
					// before the (possibly leading-augmented) separator so
					// the comment cuddles to the prior token; the hardline
					// inside the sep breaks back to the parent indent before
					// the kw. Composes with `kwBeforeDoc` cleanly: trailing
					// first, then own-line leadings, then sep+kw.
					final beforeKwTrailingExpr:Null<Expr> = useTriviaGap
						? {expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_KW_TRAILING_SUFFIX), pos: Context.currentPos()}
						: null;
					final optParts:Array<Expr> = [];
					if (kwLead != null) {
						final sepBaseExpr:Expr = sameLineSeparator(child, prevBodyField, typePath);
						final sepWithBeforeKwExpr:Expr = beforeKwLeadingExpr != null
							? macro kwBeforeDoc($beforeKwLeadingExpr, $sepBaseExpr, opt)
							: sepBaseExpr;
						final sepWithBeforeKwTrailingExpr:Expr = beforeKwTrailingExpr != null
							? macro kwBeforeTrailingDoc($beforeKwTrailingExpr, $sepWithBeforeKwExpr, opt)
							: sepWithBeforeKwExpr;
						optParts.push(sepWithBeforeKwTrailingExpr);
						if (bodyPolicyFlag != null) {
							optParts.push(macro _dt($v{kwLead}));
							optParts.push(bodyPolicyWrap(bodyPolicyFlag, writeCall, macro _optVal, refName, hasElseIf, elseFieldName, afterKwExpr, kwLeadingExpr, bodyOnSameLineExpr, null, null, indentObjArgs));
						} else {
							optParts.push(macro _dt($v{kwLead + ' '}));
							optParts.push(writeCall);
						}
					} else if (leadText != null) {
						if (isTightLead(leadText)) {
							// ω-E-whitespace: `@:fmt(typeHintColon)` on
							// optional-Ref tight leads routes through the same
							// WhitespacePolicy helper as mandatory leads.
							// Without the flag the `None` default keeps the
							// tight `_dt(leadText)` byte-identical to the pre-
							// flag path (`f():Void`).
							optParts.push(whitespacePolicyLead(child, leadText, ['typeHintColon']));
						} else if (firstFmtFlag(child, ['typeParamDefaultEquals']) != null) {
							// ω-typeparam-default-equals: optional non-tight lead with
							// `@:fmt(typeParamDefaultEquals)` collapses the
							// pre-slice `sameLineSeparator + leadText + ' '` pair
							// into a single `whitespacePolicyLead` switch so
							// `WhitespacePolicy.None` can produce a tight
							// `<T=Int>` (matching `whitespace.binopPolicy: "none"`).
							// The default `Both` branch emits ` = ` — byte-
							// identical to the previous pair when the field has
							// no `@:fmt(sameLine(...))` companion.
							optParts.push(whitespacePolicyLead(child, leadText, ['typeParamDefaultEquals']));
						} else {
							optParts.push(sameLineSeparator(child, prevBodyField, typePath));
							// Trailing space after a non-tight optional lead
							// is split into a literal `_dt(leadText)` plus an
							// `_dop(' ')`. The optional space is dropped by
							// the renderer when the value emits a leading
							// hardline (e.g. `var x = {…}` with
							// `leftCurly=Next` on the object literal),
							// producing `var x =\n{…}` cleanly. For all
							// other values the rendering is byte-identical
							// to the pre-slice `_dt(leadText + ' ')` path.
							optParts.push(macro _dt($v{leadText}));
							optParts.push(macro _dop(' '));
						}
						optParts.push(writeCall);
					} else {
						optParts.push(writeCall);
					}
					final optBody:Expr = if (optParts.length == 1) optParts[0]
					else dcCall(optParts);
					parts.push(macro {
						final _optVal = $fieldAccess;
						if (_optVal != null) $optBody else _de();
					});

				case Ref:
					final refName:String = child.annotations.get('base.ref');
					final writeFn:String = writeFnFor(refName);
					final rawWriteCall:Expr = {
						expr: ECall(macro $i{writeFn}, [fieldAccess, macro opt]),
						pos: Context.currentPos(),
					};
					// ω-indent-objectliteral: `@:fmt(indentValueIfCtor('<ctor>', '<optField>'))`
					// wrap on mandatory Ref — currently used by
					// `HxObjectField.value` so a nested ObjectLit on a `:` RHS
					// gets the same extra-indent as the outer `=` site
					// (`HxVarDecl.init`).
					//
					// ω-expr-body-indent-objectliteral: when the same field
					// also carries `@:fmt(bodyPolicy(...))` (e.g.
					// `HxIfExpr.thenBranch`), the additive Nest of
					// `maybeIndentValueIfCtor` would compound with
					// `bodyPolicyWrap`'s default `Nest(_cols, [_dhl, body])` and
					// produce double-indent on `indentObjectLiteral=true`. The
					// bare-Ref bodyPolicy path therefore SKIPS the additive
					// wrap here and instead routes the same meta through
					// `bodyPolicyWrap`'s `indentObjArgs` channel as a
					// SUBTRACTIVE rule — the rule fires the inverse direction
					// (`indentObjectLiteral=false` drops the default Nest
					// when the body is a multi-line ObjectLit, leaving `{`
					// at parent indent).
					final indentObjArgs:Null<Array<String>> = child.fmtReadStringArgs('indentValueIfCtor');
					final writeCall:Expr = bodyPolicyFlag != null && indentObjArgs != null
						? rawWriteCall
						: maybeIndentValueIfCtor(rawWriteCall, fieldAccess, child);
					// bodyPolicy on a first field: the parent enum-branch
					// Case 3 strips its kwLead trailing space so the
					// separator here is the sole transition token. Non-
					// first-field case (HxIfStmt.thenBody after cond's
					// `)` trail): the trail emits the token literally and
					// bodyPolicyWrap replaces the default ` ` separator.
					if (bodyPolicyFlag != null && kwLead == null && leadText == null && !isRaw) {
						// ω-tryBody: optional `@:fmt(kwPolicy('<flag>'))` companion
						// names a sibling `WhitespacePolicy` knob on the parent
						// ctor (e.g. `tryPolicy` on `HxStatement.TryCatchStmt`).
						// The `Same` inline separator inside `bodyPolicyWrap`
						// then routes through `opt.<flag>` so the parent kw-
						// policy controls the inline gap (empty under `None`,
						// space under `After`/`Both`). Without the companion
						// the wrap defaults to `_dt(' ')` and the parent ctor
						// is responsible for stripping its kw-trail-space (as
						// before).
						final kwPolicyFlag:Null<String> = child.fmtReadString('kwPolicy');
						// ω-trivia-after-trail: when the IMMEDIATELY preceding
						// sibling is a mandatory Ref carrying `@:trail` in
						// trivia-bearing mode, read its synth slot
						// `value.<priorField>AfterTrail:Null<String>` and
						// thread it into `bodyPolicyWrap`. The wrap prepends
						// ` //<comment>` (cuddled to the prior trail token) +
						// forces the body onto its own line at +cols indent
						// regardless of the runtime bodyPolicy. Currently
						// fired by `HxIfStmt.thenBody` after `cond`'s `)`
						// trail. Plain mode and non-bearing rules see a null
						// `prevTrailFieldName` and skip the threading.
						final afterTrailExpr:Null<Expr> = prevTrailFieldName == null
							? null
							: {expr: EField(macro value, prevTrailFieldName + TriviaTypeSynth.AFTER_TRAIL_SUFFIX), pos: Context.currentPos()};
						// Slice ω-expr-body-keep: `BodyPolicy.Keep` on bare-Ref
						// body fields reads the source-shape signal from the
						// existing `<field>BeforeNewline:Bool` synth slot
						// (created by `isBareNonFirstRef` in TriviaTypeSynth) —
						// `BodyOnSameLine` is its inverse, no separate slot
						// needed. First-field bodyPolicy paths (Case 3) have no
						// BeforeNewline slot, so the !isFirstField gate keeps
						// the pre-slice null fallback there. Without ctx.trivia
						// the slot doesn't exist either; null falls back to the
						// `Same` layout inside `bodyPolicyWrap` (matches the
						// pre-slice plain-mode behaviour for Keep).
						final bodyOnSameLineExpr:Null<Expr> = ctx.trivia && !isFirstField
							? macro !${ {expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_NEWLINE_SUFFIX), pos: Context.currentPos()} }
							: null;
						// ω-untyped-body-stmt-override: forward all
						// `@:fmt(bodyPolicyOverride('<ctor>', '<flag>'))`
						// entries on this field to bodyPolicyWrap. Each entry
						// flips the parent's own bodyPolicy flag to the named
						// replacement when the body's runtime ctor matches —
						// e.g. `HxTryCatchStmt.body` reads `untypedBody`
						// instead of `tryBody` when the value is
						// `HxStatement.UntypedBlockStmt`. Multiple entries
						// cascade through a runtime ternary chain.
						final policyOverrides:Array<Array<String>> = child.fmtReadStringArgsAll('bodyPolicyOverride');
						parts.push(bodyPolicyWrap(bodyPolicyFlag, writeCall, fieldAccess, refName, hasElseIf, elseFieldName, null, null, bodyOnSameLineExpr, kwPolicyFlag, afterTrailExpr, indentObjArgs, policyOverrides));
						justWrappedBody = {access: fieldAccess, typePath: refName};
					} else {
						// `@:fmt(leftCurly)` on a bare Ref field (e.g.
						// `HxFnDecl.body:HxFnBody`) routes the inter-field
						// space through the runtime BracePlacement switch —
						// same separator the Star path uses when the `{`
						// open lives on the field. The Ref points at an
						// enum (BlockBody / NoBody); the separator must be
						// suppressed when the runtime branch is the
						// `;`-terminated NoBody — emitting `_dt(' ')` ahead
						// of `;` would round-trip as `function f():Void ;`.
						// Detect the brace-bearing branch by `@:lead('{')`
						// at macro time; gate emission on enum-ctor identity
						// at runtime via `Type.enumConstructor`.
						final lcSep:Null<Expr> = child.fmtHasFlag('leftCurly')
							? leftCurlySeparator(child)
							: null;
						final lcCtors:Array<String> = lcSep == null ? [] : leftCurlyTargetCtors(refName);
						final lcCtor:Null<String> = lcCtors.length == 0 ? null : lcCtors[0];
						final bodyBreakFlag:Null<String> = child.fmtReadString('bodyBreak');
						final bareBodyBreaksFlag:Bool = child.fmtHasFlag('bareBodyBreaks');
						if (lcSep != null && lcCtor != null) {
							// Sibling no-lead branches (e.g. `HxFnBody.ExprBody`) need a
							// ` ` separator between the parent kw and the sub-rule's
							// first token — Case 3 generic single-Ref branches whose
							// writer emits `subCall` first. `;`-led siblings (NoBody)
							// stay on the `_de()` default so `function f():Void;`
							// round-trips with no inserted space ahead of `;`.
							//
							// ω-functionBody-policy: a sibling ctor carrying ctor-level
							// `@:fmt(bodyPolicy(...))` has its own bodyPolicyWrap inside
							// the sub-rule writer (Case 3 path) which provides the
							// kw→body separator (`_dt(' ')` for Same, hardline+Nest for
							// Next). The parent must therefore emit `_de()` for that
							// ctor, otherwise we get a doubled space (Same) or a
							// trailing space ahead of the hardline (Next). The
							// per-sibling separator decision lives at the parent here
							// because only the parent knows the runtime ctor.
							final spaceCtors:Array<String> = spacePrefixCtors(refName, lcCtors);
							final ctorExpr:Expr = macro Type.enumConstructor($fieldAccess);
							var sepExpr:Expr = macro _de();
							for (sc in spaceCtors) {
								final scSep:Expr = ctorHasBodyPolicy(refName, sc) ? macro _de() : macro _dt(' ');
								sepExpr = macro $ctorExpr == $v{sc} ? $scSep : $sepExpr;
							}
							for (lc in lcCtors)
								sepExpr = macro $ctorExpr == $v{lc} ? $lcSep : $sepExpr;
							parts.push(sepExpr);
							parts.push(writeCall);
						} else if (bodyBreakFlag != null && kwLead == null && leadText == null && !isRaw) {
							// ω-expression-try-body-break: wrap the body field in a
							// SameLinePolicy switch — `Same` emits ` ` + body, `Next`
							// emits hardline + Nest + body so the body sits one indent
							// deeper than the surrounding kw line. Used by
							// `HxTryCatchExpr.body` (first field; Case 3 strips the
							// `try` kw's trailing space so the wrap's `Same` ` ` is the
							// sole separator) and by `HxCatchClauseExpr.body` (last
							// field; replaces the fixed `_dt(' ')` between `)` and the
							// catch body).
							parts.push(bodyBreakWrap(bodyBreakFlag, writeCall, fieldAccess, refName, child.fmtHasFlag('blockBodyKeepsInline')));
						} else if (bareBodyBreaksFlag && kwLead == null && leadText == null && !isRaw) {
							// ω-statement-bare-break: shape-only wrap — block body
							// emits inline ` ` + body, bare body emits hardline +
							// Nest + body. No policy involvement, so the layout is
							// independent of `sameLineCatch` (block bodies still get
							// their `} catch` placement controlled by the catches
							// Star sameLine knob; bare bodies always break). Used by
							// `HxTryCatchStmt.body` (first field; Case 3 strips the
							// `try` kw's trailing space) and `HxCatchClause.body`
							// (last field; replaces the default `_dt(' ')` separator
							// between `)` and the catch body).
							parts.push(bareBodyBreakWrap(writeCall, fieldAccess, refName));
						} else if (kwLead == null && leadText == null && !isFirstField && !isRaw) {
							// ω-meta-allman-objectlit: `@:fmt(allmanIndentForCtor('<ctor>'))`
							// on a bare-Ref non-first field forces an Allman-style
							// brace placement plus one indent step when the field's
							// runtime value matches the named ctor. The default
							// `_dt(' ')` separator is suppressed and the writer call
							// is wrapped in `Nest(_cols, [hardline, writeCall])` —
							// the hardline lands at indent base + _cols (Nest bumps
							// the current indent), so the value's own opening
							// literal sits one indent step deeper than the parent
							// and the value's body picks up another step from its
							// own internal Nest. Non-matching ctors fall through to
							// the default `_dt(' ') + writeCall` layout.
							//
							// First (and currently only) consumer: `HxMetaExpr.expr`
							// with `('ObjectLit')` so `@meta { ... }` round-trips
							// the haxe-formatter convention of placing `{` on its
							// own line at indent +1 regardless of the global
							// `objectLiteralLeftCurly` knob — the meta-prefixed
							// brace placement is structural, not configurable.
							//
							// Trivia-mode `BeforeNewline` signal is bypassed when
							// the flag fires — the runtime ctor check is
							// structurally definitive for the brace-form layout
							// and source-newline preservation would only matter
							// for non-brace alternatives that already fall through
							// to the default sep path.
							final allmanCtor:Null<String> = child.fmtReadString('allmanIndentForCtor');
							if (allmanCtor != null) {
								final ctorMatchExpr:Expr = macro Type.enumConstructor($fieldAccess) == $v{allmanCtor};
								parts.push(macro {
									final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
									final _doc:anyparse.core.Doc = $writeCall;
									$ctorMatchExpr ? _dn(_cols, _dc([_dhl(), _doc])) : _dc([_dt(' '), _doc]);
								});
							} else {
								// ω-issue-48-v2: in trivia mode the bare Ref field
								// grew a `<field>BeforeNewline:Bool` slot (see
								// `TriviaTypeSynth.isBareNonFirstRef`). Consult it
								// to emit a hardline when the parser captured a
								// source newline in the gap — this is the only
								// signal available when a preceding bare-tryparse
								// Star (e.g. `HxMemberDecl.modifiers`) is empty,
								// since that Star has no first element whose
								// `newlineBefore` could be read.
								if (ctx.trivia && isTriviaBearing(typePath)) {
									final nlAccess:Expr = {
										expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_NEWLINE_SUFFIX),
										pos: Context.currentPos(),
									};
									if (prevAnyStarNonEmpty != null) {
										final prev:Expr = prevAnyStarNonEmpty;
										parts.push(macro $prev ? ($nlAccess ? _dhl() : _dt(' ')) : _de());
									} else parts.push(macro $nlAccess ? _dhl() : _dt(' '));
								} else if (prevAnyStarNonEmpty != null) {
									final prev:Expr = prevAnyStarNonEmpty;
									parts.push(macro $prev ? _dt(' ') : _de());
								} else parts.push(macro _dt(' '));
								parts.push(writeCall);
							}
						} else {
							parts.push(writeCall);
						}
					}
					// ω-close-trailing-alt: track ANY bare-Ref body (with or
					// without bodyPolicy wrap) so the next field can react to
					// its runtime closeTrailing slot. Only matters when the
					// target type is trivia-bearing — non-bearing types have
					// no closeTrailing slot and the override degrades to a
					// no-op switch returning the default sep.
					//
					// ω-block-shape-aware: track in plain mode too, gated only
					// on bare-Ref-ness. Block-shape consumers
					// (`bodyBreakWrap`, the Star sameLine handler) check
					// `collectBlockCtorPatterns(refName)` themselves and
					// degrade to a no-op when the target type has no block
					// ctors, so the wider tracker is safe in both modes.
					prevBareRefBody = {access: fieldAccess, typePath: refName};

				case _:
					Context.fatalError('WriterLowering: struct field kind ${child.kind} not supported', Context.currentPos());
			}

			// Trail
			if (!isOptional && trailText != null)
				parts.push(macro _dt($v{trailText}));

			prevAnyStarNonEmpty = null;
			prevBodyField = justWrappedBody;
			// `prevBareRefBody` was either set above for trivia-bearing
			// bare-Ref fields (the only case the next sibling can usefully
			// inspect) or untouched here when the field was a non-Ref kind.
			// A subsequent Star resets it through the early-continue path,
			// so non-Star non-bearing fields just fall through with the
			// stale value cleared in the next loop iteration's bare-Ref
			// branch (which always assigns) or via the Star reset.
			// ω-trivia-after-trail: a mandatory Ref with `@:trail` in
			// trivia-bearing mode publishes its name so the NEXT field's
			// `bodyPolicyWrap` can read `value.<name>AfterTrail`. Other
			// field shapes (Star, optional, no-trail, plain mode, non-
			// bearing rule) clear the signal so downstream emission does
			// not reference a synth slot that was never populated.
			prevTrailFieldName = (!isOptional && !isStar && trailText != null
				&& ctx.trivia && isTriviaBearing(typePath))
					? fieldName
					: null;
			isFirstField = false;
		}

		final dcExpr:Expr = dcCall(parts);
		return macro return $dcExpr;
	}

	/** Emit writer steps for a Star struct field. */
	private function emitWriterStarField(
		starNode:ShapeNode, fieldAccess:Expr, parts:Array<Expr>,
		isLastField:Bool, typePath:String, isFirstField:Bool, isRaw:Bool,
		prevBareRefBody:Null<PrevBodyInfo> = null
	):Void {
		final inner:ShapeNode = starNode.children[0];
		if (inner.kind != Ref)
			Context.fatalError('WriterLowering: Star struct field must contain a Ref', Context.currentPos());

		final elemRefName:String = inner.annotations.get('base.ref');
		final elemFn:String = writeFnFor(elemRefName);
		final openText:Null<String> = starNode.annotations.get('lit.leadText');
		final closeText:Null<String> = starNode.annotations.get('lit.trailText');
		final sepText:Null<String> = starNode.annotations.get('lit.sepText');
		final isTriviaStar:Bool = ctx.trivia && starNode.annotations.get('trivia.starCollects') == true;

		// Trivia Star: the Array element type is Trivial<elemT>, and the
		// write call targets `_t.node` instead of the raw array element.
		// Leading/trailing comments and blank-line markers attach around
		// each element via the generated layout below. Sep / @:raw
		// combinations with @:trivia are rejected by the parser side
		// upstream — valid modes are block (close + no sep), EOF (no
		// close, last field), and try-parse (no close, last field,
		// `@:tryparse`).
		if (isTriviaStar) {
			if (isRaw)
				Context.fatalError('WriterLowering: @:trivia Star does not support @:raw', Context.currentPos());
			if (sepText != null && (closeText == null || starNode.hasMeta(':tryparse')))
				Context.fatalError('WriterLowering: @:trivia + @:sep requires close-peek (@:trail), not EOF/@:tryparse', Context.currentPos());
			// ω-orphan-trivia / ω-close-trailing: Seq-struct call sites
			// drive the trailing slots synthesised on the paired type.
			// Alt-branch Star call sites (`HxStatement.BlockStmt`) have
			// no synth slots and pass null — writer falls back to pre-
			// slice behaviour. `TrailingClose` is only synthesised for
			// close-peek Stars (those with `lit.trailText`); EOF-mode
			// Stars forward null to preserve the post-loop emission
			// shape without a dangling slot access.
			final fieldName:Null<String> = starNode.annotations.get('base.fieldName');
			final trailBBAccess:Null<Expr> = fieldName == null
				? null
				: {expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_BLANK_BEFORE_SUFFIX), pos: Context.currentPos()};
			final trailLCAccess:Null<Expr> = fieldName == null
				? null
				: {expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_LEADING_SUFFIX), pos: Context.currentPos()};
			final trailCloseAccess:Null<Expr> = fieldName == null || closeText == null
				? null
				: {expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_CLOSE_SUFFIX), pos: Context.currentPos()};
			// ω-open-trailing: same-line `// comment` captured right after
			// the open literal. Synthesised only when the Star carries
			// `@:lead` AND not `@:tryparse` (parallel to TrailingClose's
			// `@:trail` gate; tryparse writer helper does not consume the
			// slot, and the synth gate omits it for tryparse Stars — see
			// `TriviaTypeSynth.buildStarTrailingSlots`).
			final trailOpenAccess:Null<Expr> = fieldName == null || openText == null || starNode.hasMeta(':tryparse')
				? null
				: {expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_OPEN_SUFFIX), pos: Context.currentPos()};
			// ω-trail-blank-after: synth slot is only present on tryparse +
			// nestBody Stars. Forward null elsewhere so the slot access
			// doesn't reference a non-existent field.
			final trailBAAccess:Null<Expr> = fieldName == null
					|| !starNode.hasMeta(':tryparse')
					|| !starNode.fmtHasFlag('nestBody')
				? null
				: {expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_BLANK_AFTER_SUFFIX), pos: Context.currentPos()};
			// ω-objectlit-source-trail-comma: synth slot is only present on
			// sep-Stars with a close literal. Forward null elsewhere so the
			// slot access doesn't reference a non-existent field. Mirrors
			// the `@:trail` / `@:sep` parser-side gate in TriviaTypeSynth.
			final trailPresentAccess:Null<Expr> = fieldName == null || sepText == null || closeText == null
				? null
				: {expr: EField(macro value, fieldName + TriviaTypeSynth.TRAIL_PRESENT_SUFFIX), pos: Context.currentPos()};
			if (starNode.hasMeta(':tryparse')) {
				if (closeText != null)
					Context.fatalError('WriterLowering: @:trivia + @:tryparse must not have @:trail', Context.currentPos());
				// Non-last-field @:trivia @:tryparse is supported only when
				// the Star is bare (no `@:lead`). The emitted Doc then
				// stands alone (empty array → `_de()`), and the next
				// sibling's leading separator in `lowerStruct` already gates
				// on `prevAnyStarNonEmpty` via the bare-tryparse-Star
				// tracker, so the space between Star output and next
				// field never leaks when the Star was empty. Required by
				// `HxMemberDecl.modifiers` (not last — `member` follows).
				//
				// `@:lead` on a non-last bare-tryparse Star would emit the
				// lead text unconditionally even on empty input, leaking
				// the literal across an otherwise-empty member position.
				// Reject loudly until a grammar needs it AND the empty-
				// input case is gated.
				if (!isLastField && openText != null)
					Context.fatalError(
						'WriterLowering: non-last @:trivia @:tryparse Star must be bare (no @:lead)',
						Context.currentPos()
					);
				if (openText != null) parts.push(macro _dt($v{openText}));
				// sameLine-annotated Stars (catches against try body) emit
				// the separator before EVERY element — it's the boundary
				// with the preceding struct field. Non-sameLine Stars
				// (case / default bodies) emit it only between elements,
				// matching the plain-mode tryparse writer.
				final sameLineName:Null<String> = starNode.fmtReadString('sameLine');
				final sepExpr:Expr = if (sameLineName != null) {
					final optFlag:Expr = {expr: EField(macro opt, sameLineName), pos: Context.currentPos()};
					sameLinePolicySwitch(optFlag, macro _dt(' '));
				} else {
					macro _dt(' ');
				};
				final nestBody:Bool = starNode.fmtHasFlag('nestBody');
				// Trailing slots only carry orphan trivia when nestBody is
				// on (parser gates capture on the same flag). For catches
				// the slots remain zero — forward null to keep the writer
				// path byte-identical to the pre-nestBody shape.
				final tryparseTrailBB:Null<Expr> = nestBody ? trailBBAccess : null;
				final tryparseTrailLC:Null<Expr> = nestBody ? trailLCAccess : null;
				final tryparseTrailBA:Null<Expr> = nestBody ? trailBAAccess : null;
				// ω-close-trailing-alt: when prev field was a bare-Ref to a
				// trivia-bearing type whose Alt has close-trailing branches
				// (currently `HxStatement.BlockStmt`), build a runtime
				// override on the FIRST element's separator. `BlockStmt(_, ct)`
				// with `ct != null` means the body's writer already
				// terminated its output with `\n` after the trailing line
				// comment — the normal space sep would leak ` ` between the
				// indent and the next sibling (e.g. `catch`). The override
				// emits `_de()` instead; non-matching ctors fall through.
				final closeTrailingFirstOverride:Null<Expr> = sameLineName != null
					? buildCloseTrailingFirstSepOverride(prevBareRefBody, sepExpr)
					: null;
				// ω-block-shape-aware: when the Star carries
				// `@:fmt(blockBodyKeepsInline)` AND the prev body's enum has
				// block ctors, force the leading sep before each catch
				// element to `_dt(' ')` whenever the previous body (struct
				// field for the first iteration, prev element's body for
				// subsequent iterations) was a block ctor. Composes with the
				// close-trailing override above by using it as the non-block
				// fallback on the first iteration.
				//
				// ω-statement-bare-break: dual flag `@:fmt(bareBodyBreaks)`
				// flips the cases — block bodies fall through to the policy-
				// driven `sepExpr` (or close-trailing override on the first
				// iteration) and bare bodies force `_dhl()`. Statement-form
				// `HxTryCatchStmt.catches` opts into this so default config
				// (`sameLineCatch=Same`) still breaks `try BARE\ncatch` even
				// though the policy by itself would emit ` `. Block bodies
				// stay under policy control (`sameLineCatch=Next` still
				// breaks `} catch` to `}\ncatch`).
				final blockShapeAware:Bool = starNode.fmtHasFlag('blockBodyKeepsInline');
				final bareShapeAware:Bool = starNode.fmtHasFlag('bareBodyBreaks');
				final shapeAware:Bool = blockShapeAware || bareShapeAware;
				final blockPatterns:Array<Expr> = sameLineName != null && prevBareRefBody != null && shapeAware
					? collectBlockCtorPatterns(prevBareRefBody.typePath)
					: [];
				final elemBodyField:Null<String> = sameLineName != null && blockPatterns.length > 0
					? findElementBodyField(elemRefName, prevBareRefBody.typePath)
					: null;
				final firstSepOverride:Null<Expr> = if (blockPatterns.length == 0) closeTrailingFirstOverride;
				else {
					final fallback:Expr = closeTrailingFirstOverride ?? sepExpr;
					final blockBranch:Expr = blockShapeAware ? (macro _dt(' ')) : fallback;
					final bareBranch:Expr = blockShapeAware ? fallback : (macro _dhl());
					final cases:Array<Case> = [
						{values: blockPatterns, expr: blockBranch, guard: null},
						{values: [macro _], expr: bareBranch, guard: null},
					];
					{expr: ESwitch(prevBareRefBody.access, cases, null), pos: Context.currentPos()};
				};
				final subsequentSepOverride:Null<Expr> = if (elemBodyField == null) null;
				else {
					final prevElemBodyAccess:Expr = {
						expr: EField(macro _arr[_si - 1].node, elemBodyField),
						pos: Context.currentPos(),
					};
					final blockBranch:Expr = blockShapeAware ? (macro _dt(' ')) : sepExpr;
					final bareBranch:Expr = blockShapeAware ? sepExpr : (macro _dhl());
					final cases:Array<Case> = [
						{values: blockPatterns, expr: blockBranch, guard: null},
						{values: [macro _], expr: bareBranch, guard: null},
					];
					{expr: ESwitch(prevElemBodyAccess, cases, null), pos: Context.currentPos()};
				};
				// ω-case-body-policy / ω-case-body-keep:
				// `@:fmt(bodyPolicy('flag1', 'flag2', ...))` on a
				// `nestBody` Star opts the body field into runtime
				// single-stmt-flat emission. The runtime ORs all named
				// `BodyPolicy` flags across two predicates:
				//  - ANY flag == `Same` → flatten unconditionally (override).
				//  - ANY flag == `Keep` → flatten IFF the source had the
				//    body's first element on the same line as the lead
				//    (read off `Trivial<T>.newlineBefore`).
				// Either path gates on the body holding exactly one element
				// with no leading / orphan-trailing trivia; multi-stmt and
				// trivia-bearing bodies stay multiline. Consumed by
				// `HxCaseBranch.body` and `HxDefaultBranch.stmts` to
				// switch between `case X:\n\tstmt;` (Next) and
				// `case X: stmt;` (Same / Keep+sameLine).
				final caseBodyFlagNames:Array<String> = starNode.fmtReadStringArgs('bodyPolicy') ?? [];
				// ω-expression-case-flat-fanout: when `@:fmt(flatChildOpt('A=B', …))`
				// is present, parse each `'from=to'` arg into a [from, to] pair so
				// `triviaTryparseStarExpr` can emit a `Reflect.copy(opt)` + per-pair
				// override block in the runtime flat-case branch.
				final flatChildOptRaw:Null<Array<String>> = starNode.fmtReadStringArgs('flatChildOpt');
				final flatChildOptPairs:Array<Array<String>> = if (flatChildOptRaw == null) []
				else {
					final out:Array<Array<String>> = [];
					for (raw in flatChildOptRaw) {
						final eq:Int = raw.indexOf('=');
						if (eq <= 0 || eq >= raw.length - 1) Context.fatalError('WriterLowering: @:fmt(flatChildOpt(...)) arg must be "from=to", got "${raw}"', Context.currentPos());
						out.push([raw.substr(0, eq), raw.substr(eq + 1)]);
					}
					out;
				};
				parts.push(triviaTryparseStarExpr(
					fieldAccess, elemFn, sepExpr, sameLineName != null, nestBody,
					tryparseTrailBB, tryparseTrailLC, tryparseTrailBA, firstSepOverride, subsequentSepOverride,
					caseBodyFlagNames, flatChildOptPairs
				));
				return;
			}
			if (closeText != null) {
				// First-field Star with knob-form `@:fmt(leftCurly('<knob>'))`
				// (e.g. `HxObjectLit.fields`) fires the leftCurly switch
				// even at first-field position — its outer caller already
				// emits the inter-token space via `_dop(' ')`, so the
				// `Same` branch is `_de()` and `Next` is `_dhl()` (drops
				// the pending OptSpace and writes a hardline).
				final knobLeftCurly:Null<String> = starNode.fmtReadString('leftCurly');
				final hasKnobLeftCurly:Bool = knobLeftCurly != null;
				// ω-objectlit-leftCurly-cascade: when the Star carries BOTH
				// `@:fmt(wrapRules(...))` AND `@:fmt(leftCurly('<knob>'))`,
				// leftCurly emission moves INSIDE `triviaSepStarExpr` so the
				// no-trivia branch can wire `IfBreak(_dhl(), _de())` into the
				// wrap engine's Group — short literals stay cuddled even when
				// the knob is `Next`. Trivia-bearing branch keeps the
				// pre-slice unconditional `_dhl()`/`_de()`. Outer site keeps
				// emitting `leftCurlySeparator` for the no-wrap-rules case
				// (legacy bare-flag callers and future knob-form callers
				// without wrap-rules).
				final wrapRulesField:Null<String> = starNode.fmtReadString('wrapRules');
				final leftCurlyOwnedBySep:Bool = hasKnobLeftCurly && wrapRulesField != null;
				if (!leftCurlyOwnedBySep && (!isFirstField || hasKnobLeftCurly) && isSpacedLead(openText))
					parts.push(leftCurlySeparator(starNode));
				// ω-trivia-sep: sep-Star with @:trivia routes to a
				// dedicated helper that drives multi-line vs flat layout
				// from per-element `newlineBefore` / comment trivia.
				//
				// ω-wraprules-objlit: when the Star carries
				// `@:fmt(wrapRules('<field>'))`, the no-trivia branch of
				// `triviaSepStarExpr` defers to the runtime
				// `WrapList.emit` engine so the cascade picks the layout
				// shape (NoWrap / OnePerLine / FillLine / …). The
				// trivia-bearing branch still forces multi-line — when
				// inline / leading / trailing comments are present, the
				// list cannot collapse to a single line regardless of
				// what the cascade would say.
				if (sepText != null) {
					// ω-objectlit-source-trail-comma: when the Star also
					// carries `@:fmt(trailingComma('<knob>'))`, thread the
					// knob's field name into `triviaSepStarExpr` so its
					// no-trivia branch can `forceExceeds` on the wrap engine
					// when the source had a trailing separator AND the knob
					// is on. Null knob → behaves identically to pre-slice
					// (cascade evaluates exceeds=false / =true symmetrically).
					final trailingCommaField:Null<String> = starNode.fmtReadString('trailingComma');
					parts.push(triviaSepStarExpr(
						fieldAccess, trailBBAccess, trailLCAccess, trailCloseAccess, trailOpenAccess, elemFn,
						openText ?? '', closeText, sepText, wrapRulesField,
						leftCurlyOwnedBySep ? knobLeftCurly : null,
						trailPresentAccess, trailingCommaField
					));
					return;
				}
				// `openText ?? ''` (was `?? '{'` through ω₅) — when a
				// close-peek Star has no `@:lead`, the surrounding Seq
				// emits the open delimiter before this field, so the Star
				// itself contributes nothing at the open position. Empty
				// string → `_dt('')` is a no-op, and `emptyText = '' +
				// closeText` stays format-neutral (invariant #5).
				final afterDocComments:Bool = starNode.fmtHasFlag('afterFieldsWithDocComments');
				final keepBetweenFields:Bool = starNode.fmtHasFlag('existingBetweenFields');
				final beforeDocComments:Bool = starNode.fmtHasFlag('beforeDocCommentEmptyLines');
				final indentCaseLabelsGate:Bool = starNode.fmtHasFlag('indentCaseLabels');
				final interMemberArgs:Null<Array<String>> = starNode.fmtReadStringArgs('interMemberBlankLines');
				final interMemberInfo:Null<InterMemberClassifyInfo> = interMemberArgs == null
					? null
					: buildInterMemberClassifyInfo(elemRefName, interMemberArgs);
				parts.push(triviaBlockStarExpr(
					fieldAccess, trailBBAccess, trailLCAccess, trailCloseAccess, trailOpenAccess, elemFn,
					openText ?? '', closeText, false, afterDocComments, keepBetweenFields, beforeDocComments,
					interMemberInfo, indentCaseLabelsGate
				));
			} else if (isLastField) {
				if (openText != null) parts.push(macro _dt($v{openText}));
				final afterCtorAllArgs:Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesAfterCtor');
				final afterCtorInfos:Array<AfterCtorBlankInfo> = [
					for (args in afterCtorAllArgs) buildAfterCtorBlankInfo(elemRefName, args, null)
				];
				final afterCtorIfAllArgs:Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesAfterCtorIf');
				for (args in afterCtorIfAllArgs)
					afterCtorInfos.push(buildAfterCtorBlankInfoIf(elemRefName, args));
				final beforeCtorAllArgs:Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBeforeCtor');
				final beforeCtorInfos:Array<BeforeCtorBlankInfo> = [
					for (args in beforeCtorAllArgs) buildBeforeCtorBlankInfo(elemRefName, args, null)
				];
				final beforeCtorIfAllArgs:Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBeforeCtorIf');
				for (args in beforeCtorIfAllArgs)
					beforeCtorInfos.push(buildBeforeCtorBlankInfoIf(elemRefName, args));
				parts.push(triviaEofStarExpr(
					fieldAccess, trailBBAccess, trailLCAccess, elemFn,
					afterCtorInfos, beforeCtorInfos
				));
			} else {
				Context.fatalError('WriterLowering: @:trivia Star without @:trail must be the last field', Context.currentPos());
			}
			return;
		}

		final elemCall:Expr = {
			expr: ECall(macro $i{elemFn}, [macro _arr[_si], macro opt]),
			pos: Context.currentPos(),
		};

		// @:raw types (string content): concatenate items with no whitespace,
		// wrapping in lead/trail if present. No block/sep layout.
		if (isRaw && closeText != null && sepText == null) {
			parts.push(macro {
				final _arr = $fieldAccess;
				final _docs:Array<anyparse.core.Doc> = [_dt($v{openText ?? ''})];
				var _si:Int = 0;
				while (_si < _arr.length) {
					_docs.push($elemCall);
					_si++;
				}
				_docs.push(_dt($v{closeText}));
				_dc(_docs);
			});
			return;
		}

		if (closeText != null && sepText != null) {
			// Newline as separator — semantically a hardline between
			// elements, not a soft-fit-or-break token. `sepList` uses a
			// soft-line (space-in-flat / newline-in-break) which doesn't
			// match "newlines are structure." Route `@:sep('\n')` to a
			// flat hardline-join emission: `open + \n + item + \n + … + \n + close`.
			// No Nest — enclosing scope's indent reaches interior lines
			// unchanged. Format-neutral — any grammar using `@:sep('\n')`
			// gets this layout.
			if (sepText == '\n') {
				parts.push(macro {
					final _arr = $fieldAccess;
					final _docs:Array<anyparse.core.Doc> = [_dt($v{openText ?? ''})];
					var _si:Int = 0;
					while (_si < _arr.length) {
						if (_si > 0) _docs.push(_dhl());
						_docs.push($elemCall);
						_si++;
					}
					_docs.push(_dt($v{closeText}));
					_dc(_docs);
				});
				return;
			}
			// ω-E-whitespace: spaced leads (`{`) get a plain leading space;
			// a Star with `@:fmt(funcParamParens)` opts into a runtime-
			// switched space before its open delim. The two branches are
			// structurally exclusive so a grammar site that ever combined
			// them (spaced-lead `{` with a funcParamParens-style flag)
			// cannot produce a double space.
			//
			// ω-typeparam-spacing: `@:fmt(typeParamOpen)` extends the same
			// outside-before-open path — `Before`/`Both` on `<` emit a
			// space before the delim (`Foo <Int>`). `After`/`Both` on
			// `<` and `Before`/`Both` on `>` route through `delimInsidePolicySpace`
			// below to splice padding INSIDE the delimiters via `sepList`'s
			// `openInside` / `closeInside` Doc args.
			if (!isFirstField && !isRaw) {
				if (isSpacedLead(openText)) {
					parts.push(macro _dt(' '));
				} else {
					final paramSpace:Null<Expr> = openDelimPolicySpace(starNode, ['funcParamParens', 'typeParamOpen']);
					if (paramSpace != null) parts.push(paramSpace);
				}
			}
			final tcExpr:Expr = trailingCommaExpr(starNode);
			final openInsideExpr:Expr = delimInsidePolicySpace(starNode, ['typeParamOpen', 'objectLiteralBracesOpen'], false) ?? macro _de();
			final closeInsideExpr:Expr = delimInsidePolicySpace(starNode, ['typeParamClose', 'objectLiteralBracesClose'], true) ?? macro _de();
			final keepInnerExpr:Expr = keepInnerWhenEmptyExpr(starNode);
			// ω-fill-primitive: `@:fmt(fill)` on the Star routes the list
			// through `fillList` (Wadler fillSep) instead of `sepList`,
			// packing items inline up to the line budget and breaking the
			// separator before each overflow item at the list's indent.
			//
			// ω-wraprules-objlit: `@:fmt(wrapRules('<optionFieldName>'))`
			// supersedes both above paths — routes the list through the
			// runtime `WrapList.emit` engine driven by the named
			// `WrapRules` cascade on `opt`. The cascade picks one of
			// `NoWrap` / `OnePerLine` / `OnePerLineAfterFirst` /
			// `FillLine` per call from item count, max/total flat width
			// and an `exceedsMaxLineLength` flag — the engine evaluates
			// the cascade twice (`exceeds=false` + `exceeds=true`) and
			// emits `Group(IfBreak(brkDoc, flatDoc))` when the two runs
			// disagree, so the renderer's flat/break decision picks the
			// right mode at layout time. First consumer is `HxObjectLit`
			// (`objectLiteralWrap`); future slices wire `arrayWrap`,
			// `anonTypeWrap`, `callParameterWrap`, … through the same
			// engine. `@:fmt(fill)` / `@:fmt(fillDoubleIndent)` are
			// orthogonal — they continue to drive `fillList` for sites
			// that opt into Wadler fillSep without per-construct rules.
			final wrapRulesField:Null<String> = starNode.fmtReadString('wrapRules');
			final useFill:Bool = starNode.fmtHasFlag('fill');
			final fillDouble:Bool = starNode.fmtHasFlag('fillDoubleIndent');
			final listCall:Expr = if (wrapRulesField != null) {
				final rulesExpr:Expr = {
					expr: EField(macro opt, wrapRulesField),
					pos: Context.currentPos(),
				};
				macro anyparse.format.wrap.WrapList.emit($v{openText ?? ''}, $v{closeText}, $v{sepText}, _docs, opt, $openInsideExpr, $closeInsideExpr, $keepInnerExpr, $rulesExpr, $tcExpr);
			} else if (useFill) {
				macro fillList($v{openText ?? ''}, $v{closeText}, $v{sepText}, _docs, opt, $tcExpr, $openInsideExpr, $closeInsideExpr, $keepInnerExpr, $v{fillDouble});
			} else {
				macro sepList($v{openText ?? ''}, $v{closeText}, $v{sepText}, _docs, opt, $tcExpr, $openInsideExpr, $closeInsideExpr, $keepInnerExpr);
			};
			parts.push(macro {
				final _arr = $fieldAccess;
				final _docs:Array<anyparse.core.Doc> = [];
				var _si:Int = 0;
				while (_si < _arr.length) {
					_docs.push($elemCall);
					_si++;
				}
				$listCall;
			});
		} else if (closeText != null) {
			// Mirror of the trivia-path gate: knob-form leftCurly fires
			// even on a first-field Star (outer-side OptSpace owns the
			// inter-token space; see leftCurlySeparator's `_de()` branch).
			final hasKnobLeftCurly2:Bool = starNode.fmtReadString('leftCurly') != null;
			if ((!isFirstField || hasKnobLeftCurly2) && !isRaw && isSpacedLead(openText)) parts.push(leftCurlySeparator(starNode));
			parts.push(macro {
				final _arr = $fieldAccess;
				final _docs:Array<anyparse.core.Doc> = [];
				var _si:Int = 0;
				while (_si < _arr.length) {
					_docs.push($elemCall);
					_si++;
				}
				blockBody($v{openText ?? '{'}, $v{closeText}, _docs, opt);
			});
		} else if (!isLastField || starNode.hasMeta(':tryparse')) {
			// Try-parse mode. Emit lead if present (e.g. ':' in default:).
			if (openText != null)
				parts.push(macro _dt($v{openText}));
			final sameLineName:Null<String> = starNode.fmtReadString('sameLine');
			if (sameLineName != null) {
				// @:fmt(sameLine(...)) on a try-parse Star: each element is preceded by
				// a runtime-conditional separator (space or hardline), so the
				// first element's leading separator acts as the boundary with
				// the preceding struct field (τ₁ — catches against try body).
				// Per-element shape is not captured today, so `Keep` degrades
				// to `Same` at this site (ω-keep-policy).
				final optFlag:Expr = {
					expr: EField(macro opt, sameLineName),
					pos: Context.currentPos(),
				};
				final sepExpr:Expr = sameLinePolicySwitch(optFlag, macro _dt(' '));
				// ω-block-shape-aware: when the Star carries
				// `@:fmt(blockBodyKeepsInline)` AND the prev struct field's
				// body has block ctors AND the element type carries a same-
				// typed body field, force `_dt(' ')` for any iteration whose
				// preceding body was a block ctor. Mirrors the trivia path;
				// the plain path's element access drops the `.node`
				// indirection.
				//
				// ω-statement-bare-break: dual flag `@:fmt(bareBodyBreaks)`
				// inverts the cases — block bodies fall through to `sepExpr`
				// (policy-driven), bare bodies force `_dhl()`. See trivia-
				// path comment for rationale.
				final blockShapeAware:Bool = starNode.fmtHasFlag('blockBodyKeepsInline');
				final bareShapeAware:Bool = starNode.fmtHasFlag('bareBodyBreaks');
				final shapeAware:Bool = blockShapeAware || bareShapeAware;
				final blockPatterns:Array<Expr> = prevBareRefBody != null && shapeAware
					? collectBlockCtorPatterns(prevBareRefBody.typePath)
					: [];
				final elemBodyField:Null<String> = blockPatterns.length > 0
					? findElementBodyField(elemRefName, prevBareRefBody.typePath)
					: null;
				if (blockPatterns.length == 0) {
					parts.push(macro {
						final _arr = $fieldAccess;
						final _docs:Array<anyparse.core.Doc> = [];
						var _si:Int = 0;
						while (_si < _arr.length) {
							_docs.push($sepExpr);
							_docs.push($elemCall);
							_si++;
						}
						_dc(_docs);
					});
				} else {
					final firstBlockBranch:Expr = blockShapeAware ? (macro _dt(' ')) : sepExpr;
					final firstBareBranch:Expr = blockShapeAware ? sepExpr : (macro _dhl());
					final firstShapeCases:Array<Case> = [
						{values: blockPatterns, expr: firstBlockBranch, guard: null},
						{values: [macro _], expr: firstBareBranch, guard: null},
					];
					final firstSepShape:Expr = {
						expr: ESwitch(prevBareRefBody.access, firstShapeCases, null),
						pos: Context.currentPos(),
					};
					final subsequentSepExpr:Expr = if (elemBodyField == null) sepExpr;
					else {
						final prevElemBodyAccess:Expr = {
							expr: EField(macro _arr[_si - 1], elemBodyField),
							pos: Context.currentPos(),
						};
						final subBlockBranch:Expr = blockShapeAware ? (macro _dt(' ')) : sepExpr;
						final subBareBranch:Expr = blockShapeAware ? sepExpr : (macro _dhl());
						final cases:Array<Case> = [
							{values: blockPatterns, expr: subBlockBranch, guard: null},
							{values: [macro _], expr: subBareBranch, guard: null},
						];
						{expr: ESwitch(prevElemBodyAccess, cases, null), pos: Context.currentPos()};
					};
					parts.push(macro {
						final _arr = $fieldAccess;
						final _docs:Array<anyparse.core.Doc> = [];
						var _si:Int = 0;
						while (_si < _arr.length) {
							_docs.push(_si == 0 ? $firstSepShape : $subsequentSepExpr);
							_docs.push($elemCall);
							_si++;
						}
						_dc(_docs);
					});
				}
			} else {
				// `@:fmt(padLeading)` / `@:fmt(padTrailing)` — when the Star
				// is bracketed by surrounding tokens emitted OUTSIDE this
				// struct (an outer enum ctor's kwLead / trailText, or a
				// sibling Ref before it) AND has no own `@:lead`/`@:trail`
				// to carry the space, the internal-only sep leaves
				// `prevTok<elem1 elem2>nextTok` glued together. Opting into
				// `padLeading` emits a leading space when the array is non-
				// empty (`prevTok elem1 elem2>nextTok`); `padTrailing` does
				// the same on the trailing side; combine for the symmetric
				// `prevTok elem1 elem2 nextTok` shape (used by
				// `HxConditionalMod.body` to fence between `#if cond`/`#end`).
				// Empty arrays still degrade to `_de()` (no padding, no
				// stray space). Format-neutral — any grammar nesting a
				// padded Star inside a surrounding-token sandwich can adopt
				// either flag without touching the macro.
				final padLeading:Bool = starNode.fmtHasFlag('padLeading');
				final padTrailing:Bool = starNode.fmtHasFlag('padTrailing');
				if (padLeading || padTrailing) {
					final leadingPush:Expr = padLeading ? macro _docs.push(_dt(' ')) : macro {};
					final trailingPush:Expr = padTrailing ? macro _docs.push(_dt(' ')) : macro {};
					parts.push(macro {
						final _arr = $fieldAccess;
						if (_arr.length == 0) _de()
						else {
							final _docs:Array<anyparse.core.Doc> = [];
							$leadingPush;
							var _si:Int = 0;
							while (_si < _arr.length) {
								_docs.push($elemCall);
								if (_si < _arr.length - 1) _docs.push(_dt(' '));
								_si++;
							}
							$trailingPush;
							_dc(_docs);
						}
					});
				} else {
					parts.push(macro {
						final _arr = $fieldAccess;
						final _docs:Array<anyparse.core.Doc> = [];
						var _si:Int = 0;
						while (_si < _arr.length) {
							_docs.push($elemCall);
							if (_si < _arr.length - 1) _docs.push(_dt(' '));
							_si++;
						}
						_dc(_docs);
					});
				}
			}
		} else {
			// EOF mode. Emit lead if present.
			if (openText != null)
				parts.push(macro _dt($v{openText}));
			parts.push(macro {
				final _arr = $fieldAccess;
				if (_arr.length == 0) _de()
				else {
					final _docs:Array<anyparse.core.Doc> = [];
					var _si:Int = 0;
					while (_si < _arr.length) {
						if (_si > 0) {
							_docs.push(_dhl());
							_docs.push(_dhl());
						}
						_docs.push($elemCall);
						_si++;
					}
					_dc(_docs);
				}
			});
		}
	}

	// -------- terminal rule --------

	private function lowerTerminal(node:ShapeNode, typePath:String, simple:String):Expr {
		final underlying:String = node.annotations.get('base.underlying');
		final unescape:Bool = node.hasMeta(':unescape');
		final unescapeMode:Null<String> = node.readMetaString(':unescape');
		final raw:Bool = node.hasMeta(':rawString');

		if (unescape) {
			if (unescapeMode == 'raw') {
				// @:unescape("raw"): escape without wrapping in quotes.
				// Cast abstract to String for field access.
				final fmtParts:Array<String> = formatInfo.schemaTypePath.split('.');
				return macro {
					final _s:String = (cast value : String);
					final _buf:StringBuf = new StringBuf();
					var _ci:Int = 0;
					while (_ci < _s.length) {
						final _c:Null<Int> = _s.charCodeAt(_ci);
						if (_c != null) _buf.add($p{fmtParts}.instance.escapeChar(_c));
						_ci++;
					}
					return _dt(_buf.toString());
				};
			}
			// @:unescape (bare): wrap in "..." and escape
			return macro return _dt(escapeString(value));
		}

		if (raw) return macro return _dt(value);

		return switch underlying {
			case 'Float': macro return _dt(formatFloat(value));
			case 'Int': macro return _dt(Std.string(value));
			case 'Bool': macro return _dt(value ? 'true' : 'false');
			case 'String': macro return _dt(value);
			case _:
				Context.fatalError('WriterLowering: no encoder for underlying type "$underlying"', Context.currentPos());
				throw 'unreachable';
		};
	}

	// -------- helpers --------

	/**
	 * Return a Doc-separator expression for the whitespace that precedes
	 * a struct-field's kw/lead token.
	 *
	 * Without `@:fmt(sameLine(...))` metadata, emits a plain space (`_dt(' ')`) —
	 * the existing D61 behaviour. With `@:fmt(sameLine("flagName"))`, emits a
	 * switch on `opt.<flagName>:SameLinePolicy` picking between space
	 * (`Same`), hardline (`Next`), and a runtime slot lookup (`Keep`).
	 *
	 * ω-keep-policy: when the field is an `@:optional @:kw(...)` Ref AND
	 * the writer runs in trivia mode, the field's synth
	 * `<fieldName>BeforeKwNewline:Bool` slot drives the `Keep` branch —
	 * `true` emits a hardline (source had the kw on its own line),
	 * `false` emits a space (source had the kw inline with the preceding
	 * token). Plain mode / non-kw fields don't carry the slot, so `Keep`
	 * degrades to `Same`.
	 *
	 * ψ₉ opt-in shape-awareness via `@:fmt(shapeAware)`: when the field also
	 * carries the `@:fmt(shapeAware)` meta AND `prevBody` is non-null (the
	 * immediately preceding struct field was a bare-Ref wrapped via
	 * `bodyPolicyWrap`) AND the body's enum type has at least one block
	 * ctor, the emitted separator adds a runtime ctor switch on the
	 * preceding body's value: block ctors keep the flag-based layout,
	 * every other ctor forces a hardline. Used by `HxIfStmt.elseBody`
	 * where a lone `else` on the same line as a semicolon-terminated
	 * thenBody would collide visually with the body's terminator. NOT
	 * used by `HxDoWhileStmt.cond`'s `while` or `HxTryCatchStmt.catches`
	 * — those keywords are part of the loop/try structure and stay
	 * inline regardless of body shape, matching haxe-formatter's
	 * `sameLine.doWhile`/`tryCatch` defaults.
	 *
	 * Consumed by the two struct-field sites (non-optional kw, optional
	 * Ref/lead) that previously hard-coded `' '` as the boundary
	 * between a field and the preceding token. The try-parse Star
	 * `@:fmt(sameLine(...))` site in `emitWriterStarField` has its own inline
	 * handler (per-element separator, different semantic) and routes
	 * `Keep` to `Same` since there is no per-element source-shape slot.
	 */
	private function sameLineSeparator(child:ShapeNode, prevBody:Null<PrevBodyInfo>, typePath:String):Expr {
		final flagName:Null<String> = child.fmtReadString('sameLine');
		if (flagName == null) return macro _dt(' ');
		final optFlag:Expr = {
			expr: EField(macro opt, flagName),
			pos: Context.currentPos(),
		};
		final fieldName:Null<String> = child.annotations.get('base.fieldName');
		// Mirror of Lowering's `hasKwTriviaSlots` gate — `<field>BeforeKwNewline`
		// only exists on the synth paired `*T` type of trivia-bearing enclosing
		// rules. Non-bearing rules with `@:optional @:kw @:fmt(sameLine(...))`
		// would otherwise hit an EField on a nonexistent slot. No current
		// grammar triggers this combo (first non-bearing `@:optional @:kw` is
		// `HxIfExpr.elseBranch`, which has no `@:fmt(sameLine)`), but closing
		// the gap preemptively avoids recurrence of the Lowering fix pattern.
		final hasKeepSlot:Bool = ctx.trivia
			&& isTriviaBearing(typePath)
			&& fieldName != null
			&& child.kind == Ref
			&& child.annotations.get('base.optional') == true
			&& child.readMetaString(':kw') != null;
		final keepExpr:Expr = if (hasKeepSlot) {
			final slotAccess:Expr = {
				expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_KW_NEWLINE_SUFFIX),
				pos: Context.currentPos(),
			};
			macro ($slotAccess ? _dhl() : _dt(' '));
		} else macro _dt(' ');
		final flagBased:Expr = sameLinePolicySwitch(optFlag, keepExpr);
		if (prevBody == null || !child.fmtHasFlag('shapeAware')) return flagBased;
		final blockPatterns:Array<Expr> = collectBlockCtorPatterns(prevBody.typePath);
		if (blockPatterns.length == 0) return flagBased;
		final cases:Array<Case> = [
			{values: blockPatterns, expr: flagBased, guard: null},
			{values: [macro _], expr: macro _dhl(), guard: null},
		];
		final shapeAwareSwitch:Expr = {expr: ESwitch(prevBody.access, cases, null), pos: Context.currentPos()};
		// ω-expression-case-flat-fanout: shape-aware-break for `else` is
		// correct only when the child body actually lays out on its own
		// line. The child's runtime layout is driven by `opt.<bodyPolicy>`:
		//  - `Same` — body is forced inline → else-break is wrong, fall to
		//    flagBased (sameLineElse drives the gap).
		//  - `Keep` + slot says source had body inline (`!BeforeKwNewline`)
		//    → body is inline → suppress, fall to flagBased.
		//  - `Next` / `FitLine` / `Keep`+slot=broken — body sits on its own
		//    line → keep the pre-slice shape-break.
		// Default `elseBody=Next` keeps existing behaviour. Without this
		// gate, fanning `elseBody` to `expressionCase` inside a flat case
		// body would still produce `if (cond) body;\n\telse elseBody;`
		// because shape-aware would force `else` to its own line
		// regardless of the runtime body decision. Children without a
		// `bodyPolicy` meta (no current consumers, but defensive) keep the
		// pre-slice unconditional shape-aware switch.
		final childBodyPolicyFlag:Null<String> = child.fmtReadString('bodyPolicy');
		if (childBodyPolicyFlag == null) return shapeAwareSwitch;
		final bpAccess:Expr = {expr: EField(macro opt, childBodyPolicyFlag), pos: Context.currentPos()};
		final samePat:Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BodyPolicy', 'Same']);
		final keepPat:Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BodyPolicy', 'Keep']);
		final isInlineExpr:Expr = if (hasKeepSlot) {
			final slotAccess:Expr = {
				expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_KW_NEWLINE_SUFFIX),
				pos: Context.currentPos(),
			};
			macro ($bpAccess == $samePat || ($bpAccess == $keepPat && !$slotAccess));
		} else macro $bpAccess == $samePat;
		return macro $isInlineExpr ? $flagBased : $shapeAwareSwitch;
	}

	/**
	 * ω-keep-policy — build a runtime switch over `opt.<sameLineFlag>`
	 * (a `SameLinePolicy` enum abstract). `Next` maps to hardline at
	 * the current indent, `Keep` routes to the caller-supplied
	 * `keepExpr` (a slot-based dispatch in the kw-Ref site, a `Same`
	 * fallback everywhere else), the default case (`Same` and unknown
	 * values) emits a plain space.
	 *
	 * The case patterns are built as raw `EField` expressions to avoid
	 * macro-time enum resolution against the `SameLinePolicy` abstract
	 * (same precedent as `bodyPolicyWrap` / `leftCurlySeparator`).
	 */
	private static function sameLinePolicySwitch(optFlag:Expr, keepExpr:Expr):Expr {
		final slpPath:Array<String> = ['anyparse', 'format', 'SameLinePolicy'];
		final nextPat:Expr = MacroStringTools.toFieldExpr(slpPath.concat(['Next']));
		final keepPat:Expr = MacroStringTools.toFieldExpr(slpPath.concat(['Keep']));
		final cases:Array<Case> = [
			{values: [nextPat], expr: macro _dhl(), guard: null},
			{values: [keepPat], expr: keepExpr, guard: null},
		];
		return {expr: ESwitch(optFlag, cases, macro _dt(' ')), pos: Context.currentPos()};
	}

	/**
	 * ω-expression-try-body-break — build a runtime switch over
	 * `opt.<sameLineFlag>:SameLinePolicy` that wraps the body
	 * `writeCall` with an extra Nest level on the `Next` branch so the
	 * body content sits one indent deeper than the surrounding `try` /
	 * `catch (...)` keyword line. `Same` (and the default) emits the
	 * existing `' ' + body` shape; `Next` emits `_dn(_cols, _dc([_dhl(),
	 * body]))` — hardline + nested-indent + body, mirroring
	 * `bodyPolicyWrap`'s `Next` layout. `Keep` falls back to `Same`
	 * because no per-field source-shape slot exists at this site.
	 *
	 * Used by `@:fmt(bodyBreak('flagName'))` on a bare-Ref body field —
	 * `HxTryCatchExpr.body` (first field; Case 3 strips the `try` kw's
	 * trailing space so the wrap's `Same` ` ` is the sole separator) and
	 * `HxCatchClauseExpr.body` (last field; replaces the fixed
	 * `_dt(' ')` between `)` and the catch body).
	 *
	 * ω-block-shape-aware (block-body shape-awareness): when the field
	 * also carries `@:fmt(blockBodyKeepsInline)` AND the body's type has
	 * block ctors (collected via `collectBlockCtorPatterns`), an outer
	 * ctor switch forces the inline `' ' + body` layout for those ctors
	 * regardless of the `opt.<flag>` policy — block bodies have their
	 * own visual structure (`{ ... }` already opens its own line), so a
	 * body-break would emit `try \n\t{ ... }` instead of the canonical
	 * `try { ... }`. Non-block ctors still honour the policy switch.
	 * Opt-in via the flag because statement-form siblings
	 * (`HxTryCatchStmt.body` etc.) want the OPPOSITE — `} catch` breaks
	 * to `}\ncatch` on `Next` regardless of body shape (see
	 * `testSameLineCatchAppliesToEveryCatch` for the upstream
	 * haxe-formatter contract).
	 */
	private function bodyBreakWrap(flagName:String, writeCall:Expr, bodyAccess:Expr, bodyTypePath:String, shapeAware:Bool):Expr {
		final optFlag:Expr = {
			expr: EField(macro opt, flagName),
			pos: Context.currentPos(),
		};
		final sameLayoutExpr:Expr = macro _dc([_dt(' '), $writeCall]);
		final nextLayoutExpr:Expr = macro _dn(_cols, _dc([_dhl(), $writeCall]));
		final slpPath:Array<String> = ['anyparse', 'format', 'SameLinePolicy'];
		final nextPat:Expr = MacroStringTools.toFieldExpr(slpPath.concat(['Next']));
		final keepPat:Expr = MacroStringTools.toFieldExpr(slpPath.concat(['Keep']));
		final flagCases:Array<Case> = [
			{values: [nextPat], expr: nextLayoutExpr, guard: null},
			{values: [keepPat], expr: sameLayoutExpr, guard: null},
		];
		final flagSwitch:Expr = {expr: ESwitch(optFlag, flagCases, sameLayoutExpr), pos: Context.currentPos()};
		final blockPatterns:Array<Expr> = shapeAware ? collectBlockCtorPatterns(bodyTypePath) : [];
		final wrapExpr:Expr = if (blockPatterns.length == 0) flagSwitch
		else {
			final shapeCases:Array<Case> = [
				{values: blockPatterns, expr: sameLayoutExpr, guard: null},
				{values: [macro _], expr: flagSwitch, guard: null},
			];
			{expr: ESwitch(bodyAccess, shapeCases, null), pos: Context.currentPos()};
		};
		// `_dn(_cols, …)` in the Next branch needs a per-call `_cols` binding —
		// mirrors `bodyPolicyWrap`'s tail block (line 1721) and the Star
		// `_dn(_cols, _dc(_docs))` site at line 2337.
		return macro {
			final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			$wrapExpr;
		};
	}

	/**
	 * ω-statement-bare-break — wrap a bare-Ref body field with a runtime
	 * ctor switch that forces a multi-line break for non-block bodies and
	 * keeps the inline single-space layout for block bodies. No policy
	 * involvement: the layout is decided purely by the body's enum ctor.
	 *
	 * Block ctors (`collectBlockCtorPatterns(bodyTypePath)`) → `_dc([_dt(' '),
	 * body])` (inline space + body). Catch-all → `_dn(_cols, _dc([_dhl(),
	 * body]))` (hardline + nested-indent + body, mirroring `bodyBreakWrap`'s
	 * Next layout).
	 *
	 * Used by `@:fmt(bareBodyBreaks)` on a bare-Ref body field —
	 * `HxTryCatchStmt.body` (first field; Case 3 strips the `try` kw's
	 * trailing space so the wrap's inline `' '` is the sole separator) and
	 * `HxCatchClause.body` (last field; replaces the fixed `_dt(' ')`
	 * between `)` and the catch body). The semantic is the inverse of
	 * `blockBodyKeepsInline` on `bodyBreakWrap` — that flag forces inline
	 * for blocks regardless of an existing `Next` policy; this flag forces
	 * break for bare bodies with no policy at all. The two flags address
	 * the opposite haxe-formatter conventions for expression-position
	 * (`expressionTry=Next` rare; bare bodies stay inline) versus
	 * statement-position try-catch (default `sameLineCatch=Same`; bare
	 * bodies always break).
	 *
	 * If `bodyTypePath` has no block ctors the helper degrades to an
	 * unconditional `nextLayoutExpr` — a fallback that should never fire
	 * in practice (statement-form bodies are `HxStatement` which carries
	 * `BlockStmt`); kept defensive so the macro doesn't fatal-error on a
	 * future grammar that adds the flag without a block alternative.
	 */
	private function bareBodyBreakWrap(writeCall:Expr, bodyAccess:Expr, bodyTypePath:String):Expr {
		final sameLayoutExpr:Expr = macro _dc([_dt(' '), $writeCall]);
		final nextLayoutExpr:Expr = macro _dn(_cols, _dc([_dhl(), $writeCall]));
		final blockPatterns:Array<Expr> = collectBlockCtorPatterns(bodyTypePath);
		final wrapExpr:Expr = if (blockPatterns.length == 0) nextLayoutExpr
		else {
			final shapeCases:Array<Case> = [
				{values: blockPatterns, expr: sameLayoutExpr, guard: null},
				{values: [macro _], expr: nextLayoutExpr, guard: null},
			];
			{expr: ESwitch(bodyAccess, shapeCases, null), pos: Context.currentPos()};
		};
		return macro {
			final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			$wrapExpr;
		};
	}

	/**
	 * ω-indent-objectliteral — wrap a Ref field's writer call in a runtime
	 * gate that, when ALL THREE conditions hold, replaces the inline
	 * emission with `Nest(_cols, value)`:
	 *
	 *  1. The bound value's enum ctor matches `ctorName`.
	 *  2. The named knob `opt.<optField>:Bool` is true.
	 *  3. The named knob `opt.<leftCurlyField>:BracePlacement` is `Next`.
	 *
	 * Mirrors haxe-formatter's `indentation.indentObjectLiteral=true`
	 * rule, which only fires when `{` lands on its own line — i.e. when
	 * the per-construct leftCurly placement is Allman (`Next` / `both`).
	 * In that layout the value's hardlines pick up one extra indent
	 * step: `var x =\n\t{...}` instead of `var x =\n{...}`. With
	 * `Same` (cuddled) leftCurly the wrap is inert — `{` already sits on
	 * the parent line, so the inner content's existing nest is enough
	 * (`var x = {\n\t...}` byte-identical to the pre-slice layout).
	 *
	 * Used by `@:fmt(indentValueIfCtor('<ctorName>', '<optField>',
	 * '<leftCurlyField>'))` on RHS-style Ref fields — currently
	 * `HxVarDecl.init` and `HxObjectField.value` with `('ObjectLit',
	 * 'indentObjectLiteral', 'objectLiteralLeftCurly')`. All three args
	 * are grammar-driven so the macro core stays format-neutral: the
	 * ctor name is local to the field's enum type, and both runtime
	 * knobs live on the per-grammar `WriteOptions` struct (no base-
	 * options bloat for non-Haxe formats). New RHS sites opt in by
	 * tagging their field, no core edit required.
	 *
	 * The wrap is `Nest`, not `Group(IfBreak)`. An earlier draft tried
	 * to gate the indent on the value's own break decision via
	 * `Group(IfBreak(brk, flat))`, but `HxObjectLit.fields` emits a
	 * `BodyGroup` that the renderer's `fitsFlat` defers — the outer
	 * Group sees the IfBreak's flat branch as ~2 chars (just `{` + `}`
	 * with the BodyGroup deferred) and always picks flat, so the wrap
	 * never fired. Plain `Nest` sidesteps the measurement: when the
	 * value emits inline (no internal hardlines) `Nest` is inert — short
	 * literals stay cuddled (`var x = {a:1}`); when the value emits
	 * multi-line the hardlines pick up the extra indent step.
	 *
	 * The `_cols:Int` binding mirrors `bodyPolicyWrap` / `bareBodyBreakWrap`
	 * — `_dn(_cols, …)` reads the indent-step from `opt.indentChar` /
	 * `opt.indentSize` / `opt.tabWidth` per call so generated code does
	 * not assume any particular caller-side scope.
	 */
	private function indentValueIfCtorWrap(writeCall:Expr, fieldAccess:Expr, ctorName:String, optField:String, leftCurlyField:String):Expr {
		final optAccess:Expr = {expr: EField(macro opt, optField), pos: Context.currentPos()};
		final leftCurlyAccess:Expr = {expr: EField(macro opt, leftCurlyField), pos: Context.currentPos()};
		return macro {
			final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			final _doc:anyparse.core.Doc = $writeCall;
			if ($optAccess
				&& $leftCurlyAccess == anyparse.format.BracePlacement.Next
				&& Type.enumConstructor($fieldAccess) == $v{ctorName}) _dn(_cols, _doc) else _doc;
		};
	}

	/**
	 * Read `@:fmt(indentValueIfCtor('<ctor>', '<optField>',
	 * '<leftCurlyField>'))` off `child` and return the wrapped writer
	 * call when present, the raw call when absent. Both Ref-field
	 * branches (optional + mandatory) in `lowerStruct` route through
	 * this single helper to avoid duplicating the meta-validation block.
	 */
	private function maybeIndentValueIfCtor(rawWriteCall:Expr, fieldAccess:Expr, child:ShapeNode):Expr {
		final indentArgs:Null<Array<String>> = child.fmtReadStringArgs('indentValueIfCtor');
		if (indentArgs == null) return rawWriteCall;
		if (indentArgs.length != 3) Context.fatalError('WriterLowering: @:fmt(indentValueIfCtor(...)) requires (ctorName, optField, leftCurlyField), got ${indentArgs.length} args', Context.currentPos());
		return indentValueIfCtorWrap(rawWriteCall, fieldAccess, indentArgs[0], indentArgs[1], indentArgs[2]);
	}

	/**
	 * Return a Doc-separator expression for the whitespace that precedes
	 * a Star struct field's opening `{`.
	 *
	 * Without `@:fmt(leftCurly)` metadata, emits a plain space (`_dt(' ')`) —
	 * the existing pre-ψ₆ behaviour. With `@:fmt(leftCurly)` present (no
	 * argument), emits a switch that picks between `_dhl()` (hardline
	 * at the current indent, placing `{` on its own line) and
	 * `_dt(' ')` based on `opt.leftCurly:BracePlacement`.
	 *
	 * The bare flag `@:fmt(leftCurly)` reads the global `opt.leftCurly`
	 * knob — every grammar site without an arg maps to the same runtime
	 * option. The knob form `@:fmt(leftCurly('<knobName>'))` (slice
	 * ω-objectlit-leftCurly) reads `opt.<knobName>` instead, enabling
	 * per-construct overrides like `objectLiteralLeftCurly` for
	 * `HxObjectLit.fields`. Loader-side cascade decides whether the
	 * per-construct knob follows the global or stands on its own.
	 *
	 * The `Next` pattern is built as a raw `EField` expression to avoid
	 * macro-time enum resolution against the `BracePlacement` abstract
	 * (same precedent as `bodyPolicyWrap`). Everything other than
	 * `Next` (currently only `Same`) falls through to the default case
	 * and keeps the space — additional placements can be routed here
	 * by adding more cases.
	 */
	private static function leftCurlySeparator(starNode:ShapeNode):Expr {
		if (!starNode.fmtHasFlag('leftCurly')) return macro _dt(' ');
		final knobName:Null<String> = starNode.fmtReadString('leftCurly');
		final knobExpr:Expr = {expr: EField(macro opt, knobName ?? 'leftCurly'), pos: Context.currentPos()};
		final nextPat:Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BracePlacement', 'Next']);
		// Knob-form `@:fmt(leftCurly('<knob>'))` (e.g. on `HxObjectLit.fields`)
		// fires from a first-field Star whose outer caller already emits
		// the inter-token space via the lead's `_dop(' ')` (OptSpace). The
		// `Same` branch therefore returns `_de()` — the OptSpace flushes
		// as ' ' on its own. The `Next` branch emits a hardline; the
		// renderer drops the pending OptSpace and writes `\n` cleanly.
		//
		// Bare flag `@:fmt(leftCurly)` (e.g. on `HxClassDecl.members`)
		// fires from a non-first-field Star where the previous field has
		// no trailing whitespace, so the separator must own the space
		// directly: `Same` → `_dt(' ')`, `Next` → `_dhl()`. This is the
		// pre-slice behaviour.
		final defaultExpr:Expr = knobName != null ? macro _de() : macro _dt(' ');
		final cases:Array<Case> = [
			{values: [nextPat], expr: macro _dhl(), guard: null},
		];
		return {expr: ESwitch(knobExpr, cases, defaultExpr), pos: Context.currentPos()};
	}

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
	private function leftCurlyTargetCtors(refName:String):Array<String> {
		final result:Array<String> = [];
		final node:Null<ShapeNode> = shape.rules.get(refName);
		if (node == null || node.kind != Alt) return result;
		for (branch in node.children) {
			final ctor:Null<String> = branch.annotations.get('base.ctor');
			if (ctor == null) continue;
			final lead:Null<String> = branch.annotations.get('lit.leadText');
			if (lead != null && lead == '{') {
				result.push(ctor);
				continue;
			}
			if (branch.children.length == 1 && branch.children[0].kind == Ref) {
				final innerName:Null<String> = branch.children[0].annotations.get('base.ref');
				final innerNode:Null<ShapeNode> = innerName == null ? null : shape.rules.get(innerName);
				if (innerNode != null && innerNode.kind == Seq && innerNode.children.length > 0) {
					final firstField:ShapeNode = innerNode.children[0];
					final firstLead:Null<String> = firstField.annotations.get('lit.leadText')
						?? firstField.readMetaString(':lead');
					if (firstLead != null && firstLead.charAt(0) == '{')
						result.push(ctor);
				}
			}
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
	private function spacePrefixCtors(refName:String, lcCtorNames:Array<String>):Array<String> {
		final ctors:Array<String> = [];
		final node:Null<ShapeNode> = shape.rules.get(refName);
		if (node == null || node.kind != Alt) return ctors;
		for (branch in node.children) {
			final ctor:Null<String> = branch.annotations.get('base.ctor');
			if (ctor == null || lcCtorNames.indexOf(ctor) != -1) continue;
			if (branch.annotations.get('lit.litList') != null) continue;
			if (branch.annotations.get('lit.leadText') != null) continue;
			if (branch.annotations.get('kw.leadText') != null) continue;
			if (branch.annotations.get('prefix.op') != null) continue;
			if (branch.annotations.get('postfix.op') != null) continue;
			if (branch.annotations.get('pratt.prec') != null) continue;
			if (branch.annotations.get('ternary.op') != null) continue;
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
	 * (slice ω-functionBody-policy).
	 */
	private function ctorHasBodyPolicy(refName:String, ctorName:String):Bool {
		final node:Null<ShapeNode> = shape.rules.get(refName);
		if (node == null || node.kind != Alt) return false;
		for (branch in node.children) if (branch.annotations.get('base.ctor') == ctorName)
			return branch.fmtReadString('bodyPolicy') != null;
		return false;
	}

	/**
	 * Return a Doc expression that optionally prefixes a Star struct
	 * field's opening delimiter with a space driven by a
	 * `WhitespacePolicy` option — the paren counterpart of
	 * `whitespacePolicyLead`.
	 *
	 * Consumed today by `@:fmt(funcParamParens)` on `HxFnDecl.params` so
	 * users can opt into `function main ()` via
	 * `whitespace.parenConfig.funcParamParens.openingPolicy: "before"`
	 * without affecting call sites, `new T(...)` args, or `(expr)`.
	 *
	 * Returns `null` when the node carries no flag from `flagNames`,
	 * letting the call site fall through to its pre-slice emission
	 * (`_dt(' ')` for spaced leads, nothing for tight leads). When a
	 * flag matches, emits a runtime switch on `opt.<flagName>`:
	 *  - `Before` / `Both` → `_dt(' ')`.
	 *  - `None` / `After`  → `_de()` (no-op).
	 *
	 * `After` is accepted for surface parity with
	 * `WhitespacePolicy` but produces no space here — emitting a space
	 * after the opening delimiter would require injecting padding
	 * inside `sepList`, which currently concatenates the open token
	 * tight against the first element.
	 */
	private static function openDelimPolicySpace(starNode:ShapeNode, flagNames:Array<String>):Null<Expr> {
		final flagName:Null<String> = firstFmtFlag(starNode, flagNames);
		if (flagName == null) return null;
		final wpPath:Array<String> = ['anyparse', 'format', 'WhitespacePolicy'];
		final beforePat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Before']));
		final bothPat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Both']));
		final cases:Array<Case> = [
			{values: [beforePat, bothPat], expr: macro _dt(' '), guard: null},
		];
		final optAccess:Expr = {expr: EField(macro opt, flagName), pos: Context.currentPos()};
		return {expr: ESwitch(optAccess, cases, macro _de()), pos: Context.currentPos()};
	}

	/**
	 * Return a Doc expression for the trailing space AFTER an enum
	 * branch's `@:kw` keyword, gated by a `WhitespacePolicy` option.
	 * The kw counterpart of `openDelimPolicySpace` — flipped semantics
	 * because here the `WhitespacePolicy` value describes the gap on
	 * the AFTER side of the kw (= BEFORE side of the following lead /
	 * sub-struct).
	 *
	 * Returns `null` when the branch carries no flag from `flagNames`,
	 * letting the call site fall through to the pre-slice fixed
	 * trailing space (`kwLead + ' '`). When a flag matches, emits a
	 * runtime switch on `opt.<flagName>`:
	 *  - `After` / `Both` → `_dt(' ')` (space follows the kw).
	 *  - `Before` / `None` → `_de()` (no space).
	 *
	 * Consumed today by `@:fmt(ifPolicy)` on `HxStatement.IfStmt` and
	 * `HxExpr.IfExpr` (slice ω-if-policy), by `@:fmt(forPolicy)` /
	 * `@:fmt(whilePolicy)` / `@:fmt(switchPolicy)` on the matching
	 * stmt / expr ctors (slice ω-control-flow-policies) so a single
	 * config knob controls both statement- and expression-form
	 * `for(...)` / `for (...)`, `while(...)` / `while (...)`,
	 * `switch(cond)` / `switch (cond)` (and bare `switch cond`) spacing,
	 * by `@:fmt(tryPolicy)` on `HxStatement.TryCatchStmt` (slice
	 * ω-try-policy) gating `try {` / `try{`, and by
	 * `@:fmt(anonFuncParens)` on `HxExpr.FnExpr(fn:HxFnExpr)` (slice
	 * ω-anon-fn-paren-policy) gating `function (args)…` /
	 * `function(args)…` independently of `funcParamParens` (which
	 * targets `HxFnDecl.params`). The bare-body try sibling
	 * `TryCatchStmtBare` does NOT carry the flag — its first field's
	 * `@:fmt(bareBodyBreaks)` strips the kw-trailing-space slot.
	 */
	private static function kwTrailingSpacePolicy(branch:ShapeNode, flagNames:Array<String>):Null<Expr> {
		final flagName:Null<String> = firstFmtFlag(branch, flagNames);
		if (flagName == null) return null;
		final wpPath:Array<String> = ['anyparse', 'format', 'WhitespacePolicy'];
		final afterPat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['After']));
		final bothPat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Both']));
		final cases:Array<Case> = [
			{values: [afterPat, bothPat], expr: macro _dt(' '), guard: null},
		];
		final optAccess:Expr = {expr: EField(macro opt, flagName), pos: Context.currentPos()};
		return {expr: ESwitch(optAccess, cases, macro _de()), pos: Context.currentPos()};
	}

	/**
	 * Paren-side counterpart of `kwTrailingSpacePolicy` — same kw-after
	 * slot, but the `WhitespacePolicy` value names the gap from the
	 * FOLLOWING open-delimiter's perspective. `Before` / `Both` mean
	 * "space immediately before the `(`" (= space after the kw); `After`
	 * / `None` mean no space in this slot.
	 *
	 * Consumed by `@:fmt(anonFuncParens)` on `HxExpr.FnExpr(fn:HxFnExpr)`
	 * (slice ω-anon-fn-paren-policy) so the JSON config name
	 * `whitespace.parenConfig.anonFuncParamParens.openingPolicy: "before"`
	 * round-trips intuitively to `opt.anonFuncParens =
	 * WhitespacePolicy.Before` and emits the expected `function (args)…`
	 * spacing — matching the haxe-formatter convention where
	 * `anonFuncParamParens` policies name the gap from the paren side
	 * (siblings `funcParamParens`, `callParens`).
	 *
	 * Returned Expr shape mirrors `kwTrailingSpacePolicy`; only the
	 * Before/After mapping flips.
	 */
	private static function kwTrailingSpacePolicyParenSide(branch:ShapeNode, flagNames:Array<String>):Null<Expr> {
		final flagName:Null<String> = firstFmtFlag(branch, flagNames);
		if (flagName == null) return null;
		final wpPath:Array<String> = ['anyparse', 'format', 'WhitespacePolicy'];
		final beforePat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Before']));
		final bothPat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Both']));
		final cases:Array<Case> = [
			{values: [beforePat, bothPat], expr: macro _dt(' '), guard: null},
		];
		final optAccess:Expr = {expr: EField(macro opt, flagName), pos: Context.currentPos()};
		return {expr: ESwitch(optAccess, cases, macro _de()), pos: Context.currentPos()};
	}

	/**
	 * Return a Doc expression that pads the INSIDE of a Star struct
	 * field's open or close delimiter — the symmetric counterpart of
	 * `openDelimPolicySpace`, which only spaces the OUTSIDE-before-open
	 * slot.
	 *
	 * For `isClose=false` (open delim, e.g. `<` of `Array<T>`):
	 *  - `After` / `Both`  → `_dt(' ')` — emits ` ` after the open delim.
	 *  - `Before` / `None` → `_de()` (no-op; outside slot is wired via
	 *    `openDelimPolicySpace`).
	 *
	 * For `isClose=true` (close delim, e.g. `>` of `Array<T>`):
	 *  - `Before` / `Both` → `_dt(' ')` — emits ` ` before the close delim.
	 *  - `After` / `None`  → `_de()` (no-op; outside-after-close is not
	 *    yet supported by the writer's `sepList` shape).
	 *
	 * Threaded into `sepList` via the `openInside` / `closeInside` Doc
	 * args; returns `null` when the node carries no matching flag, so
	 * the call site falls through to `_de()` and keeps the pre-slice
	 * tight layout byte-identical.
	 *
	 * Consumed by `@:fmt(typeParamOpen, typeParamClose)` on the seven
	 * `typeParams` Star sites (`HxTypeRef.params` plus the five declare-
	 * site `typeParams` fields on class / interface / abstract / enum /
	 * typedef / function decls), by `@:fmt(anonTypeBracesOpen,
	 * anonTypeBracesClose)` on the `HxType.Anon` Alt-branch's
	 * `@:lead('{') @:trail('}') @:sep(',')` Star (routed through
	 * `lowerEnumStar`), and by `@:fmt(objectLiteralBracesOpen,
	 * objectLiteralBracesClose)` on `HxObjectLit.fields`'s `@:lead('{')
	 * @:trail('}') @:sep(',')` Star (routed through the regular
	 * `emitWriterStarField` sep-Star path). Defaults `None` keep
	 * `Array<Int>` / `{x:Int}` / `{a: 1}` tight; the haxe-formatter
	 * `whitespace.bracesConfig.{anonTypeBraces|objectLiteralBraces}.
	 * {openingPolicy: "around", closingPolicy: "around"}` flip produces
	 * `{ x:Int }` / `{ a: 1 }`.
	 */
	private static function delimInsidePolicySpace(starNode:ShapeNode, flagNames:Array<String>, isClose:Bool):Null<Expr> {
		final flagName:Null<String> = firstFmtFlag(starNode, flagNames);
		if (flagName == null) return null;
		final wpPath:Array<String> = ['anyparse', 'format', 'WhitespacePolicy'];
		final beforePat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Before']));
		final afterPat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['After']));
		final bothPat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Both']));
		final matchValues:Array<Expr> = isClose ? [beforePat, bothPat] : [afterPat, bothPat];
		final cases:Array<Case> = [
			{values: matchValues, expr: macro _dt(' '), guard: null},
		];
		final optAccess:Expr = {expr: EField(macro opt, flagName), pos: Context.currentPos()};
		return {expr: ESwitch(optAccess, cases, macro _de()), pos: Context.currentPos()};
	}

	/**
	 * Return the first flag name from `flagNames` that is present on
	 * `node` as an `@:fmt(...)` argument, or `null` if none match.
	 * Shared lookup for ω-E-whitespace's writer helpers.
	 */
	private static function firstFmtFlag(node:ShapeNode, flagNames:Array<String>):Null<String> {
		for (name in flagNames) if (node.fmtHasFlag(name)) return name;
		return null;
	}

	/**
	 * Return a Doc expression for a `@:lead(text)` whose field carries a
	 * writer-only whitespace-policy flag. The helper picks the first flag
	 * from `flagNames` that is present on `child` and emits a runtime
	 * switch on `opt.<flagName>:WhitespacePolicy`; when no flag matches
	 * the output is plain `_dt(leadText)`, matching the tight default of
	 * the mandatory-lead path.
	 *
	 * Defined flags today:
	 *  - `objectFieldColon` (ψ₇) — `HxObjectField.value`'s `@:lead(':')`.
	 *    Default `After` on `HaxeFormat.instance.defaultWriteOptions`:
	 *    `{a: 0}`.
	 *  - `typeHintColon` (ω-E-whitespace) — the three type-annotation
	 *    colons: `HxVarDecl.type`, `HxParam.type`, `HxFnDecl.returnType`.
	 *    Default `None` — `x:Int`, `f():Void` stay compact.
	 *  - `typedefAssign` (ω-typedef-assign) — `HxTypedefDecl.type`'s
	 *    `@:lead('=')`. Default `Both` — `typedef Foo = Bar;`. The
	 *    `None` policy reverts to the pre-slice tight `=` via the
	 *    same switch's fall-through path.
	 *  - `typeParamDefaultEquals` (ω-typeparam-default-equals) —
	 *    `HxTypeParamDecl.defaultValue`'s `@:optional @:lead('=')`.
	 *    Default `Both` — `<T = Int>` / `<T:Foo = Bar>`. `None`
	 *    collapses the optional non-tight lead's `sameLineSeparator +
	 *    leadText + ' '` pair into a tight `<T=Int>` (matches
	 *    `whitespace.binopPolicy: "none"`). Routed from the optional
	 *    non-tight branch in `lowerStruct` Case 5, NOT from the
	 *    mandatory-lead path that handles the other knobs above.
	 *
	 * Runtime dispatch for each switch (cases built as raw `EField`
	 * patterns to avoid macro-time enum resolution against
	 * `WhitespacePolicy`):
	 *  - `Before` → `_dt(' ' + leadText)`.
	 *  - `After`  → `_dt(leadText + ' ')`.
	 *  - `Both`   → `_dt(' ' + leadText + ' ')`.
	 *  - `None`   → default, `_dt(leadText)` (tight).
	 *
	 * Pre-concatenating each case into a single `_dt` (instead of three
	 * Doc atoms) keeps the output byte-identical to the pre-flag layout
	 * for the `None` case and avoids introducing Doc boundaries the
	 * Renderer might break across.
	 *
	 * Per-field flags stay scoped to their own grammar sites — sibling
	 * leads on the same struct are unaffected. Adding a new tag follows
	 * the ψ₆ principle (one meta = one options field); multiple tags on
	 * one field are resolved by `flagNames` order.
	 */
	private static function whitespacePolicyLead(child:ShapeNode, leadText:String, flagNames:Array<String>):Expr {
		final flagName:Null<String> = firstFmtFlag(child, flagNames);
		if (flagName == null) return macro _dt($v{leadText});
		final wpPath:Array<String> = ['anyparse', 'format', 'WhitespacePolicy'];
		final beforePat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Before']));
		final afterPat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['After']));
		final bothPat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Both']));
		// Trailing whitespace after the lead is emitted as `_dop(' ')`
		// (OptSpace) so the renderer can drop it when the value emits a
		// leading hardline — e.g. `Address: {…}` with `leftCurly=Next`
		// on the nested object literal renders as `Address:\n{…}`. The
		// leading space (Before / Both case) stays a plain `_dt(' ')`
		// because nothing emits a hardline before the lead.
		final cases:Array<Case> = [
			{values: [beforePat], expr: macro _dc([_dt(' '), _dt($v{leadText})]), guard: null},
			{values: [afterPat], expr: macro _dc([_dt($v{leadText}), _dop(' ')]), guard: null},
			{values: [bothPat], expr: macro _dc([_dt(' '), _dt($v{leadText}), _dop(' ')]), guard: null},
		];
		final optAccess:Expr = {expr: EField(macro opt, flagName), pos: Context.currentPos()};
		return {expr: ESwitch(optAccess, cases, macro _dt($v{leadText})), pos: Context.currentPos()};
	}

	/**
	 * Build a Doc expression that wraps a bare-Ref body field with a
	 * runtime-switched separator driven by `@:fmt(bodyPolicy("flagName"))`.
	 *
	 * Reads `opt.<flagName>:BodyPolicy` and dispatches:
	 *  - `Same`    → `_dc([_dt(' '), body])` — body on the same line,
	 *                separated by a single space (current behaviour).
	 *  - `Next`    → `_dn(cols, _dc([_dhl(), body]))` — body on the
	 *                next line at one indent level deeper.
	 *  - `FitLine` → `_dbg(_dn(cols, _dc([_dl(), body])))` — `BodyGroup`
	 *                lets the renderer pick flat (space + body) or break
	 *                (hardline + indent + body) based on `lineWidth`.
	 *                `BodyGroup` is layout-identical to `Group` but
	 *                acts as a semantic marker so the trivia writer's
	 *                `foldTrailingIntoBodyGroup` can splice a trailing
	 *                line comment into the body's measured content
	 *                without catching unrelated `Group`s in the tree
	 *                (e.g. `trailingCommaArgs` inside a call expression).
	 *
	 * `cols` is derived from the same `indentChar`/`indentSize`/
	 * `tabWidth` triple as `blockBody`, so one-level body indent matches
	 * a `{}` block's nesting depth.
	 *
	 * Block-bodied values bypass the policy: when `bodyTypePath` is an
	 * enum whose branches carry `@:lead(openText) @:trail(closeText)` on
	 * a single Star child (the characteristic of a `blockBody`-rendered
	 * constructor, e.g. `BlockStmt(@:lead('{') @:trail('}'))`), an outer
	 * runtime `switch` routes those ctors to a single-space layout —
	 * matching haxe-formatter's convention that `{ … }` stays on the
	 * same line as `do` / `if` / `while` / `for` regardless of the
	 * placement knob. This keeps policy targeted at the non-block
	 * expression-body case where the knob actually shifts layout.
	 *
	 * ω-issue-316-curly-both: block-ctor branches tagged with
	 * `@:fmt(leftCurly)` (e.g. `HxStatement.BlockStmt`) participate in
	 * the outer switch with a leftCurly-aware separator — the space
	 * between the preceding token and the body's `{` flips to a hardline
	 * at the outer indent when `opt.leftCurly:BracePlacement` is `Next`.
	 * Threaded through `kwGapDoc`'s `nextCurly` parameter on the
	 * kw-slot path so captured trivia still renders correctly (kwGapDoc
	 * already emits a trailing hardline when trivia is present — only
	 * the no-trivia path is affected by `nextCurly`). Untagged block
	 * ctors keep the pre-slice single-space layout.
	 *
	 * ψ₈: when `hasElseIf` is true, an additional outer-switch case is
	 * added for the `IfStmt` ctor of `bodyTypePath` that routes to
	 * `opt.elseIf:KeywordPlacement` — `Same` keeps `else if (...)`
	 * inline (single space + body) while `Next` moves the nested `if`
	 * to the next line (hardline + indent + body). This override runs
	 * regardless of the field's own `@:fmt(bodyPolicy(...))` flag value, so
	 * `elseBody=Next` with `elseIf=Same` still emits `} else if (...)`
	 * on one line for nested ifs and only pushes non-if else branches
	 * to the next line.
	 *
	 * ψ₁₂: when `elseFieldName` is non-null (derived from a sibling
	 * `@:optional` bodyPolicy field captured by `lowerStruct` and gated
	 * by the field's own `@:fmt(fitLineIfWithElse)` flag), the `FitLine`
	 * branch is replaced with a runtime ternary that degrades to the
	 * `Next` layout when `opt.fitLineIfWithElse` is `false` AND the
	 * sibling is non-null. On the sibling site itself (`elseBody`) the
	 * runtime check trivially resolves to `opt.fitLineIfWithElse`
	 * because the emission is already inside the `if (_optVal != null)`
	 * guard; on the peer site (`thenBody`) the check becomes a real
	 * lookup on `value.<elseFieldName>`. When `elseFieldName` is null,
	 * the `FitLine` branch stays byte-identical to pre-ψ₁₂.
	 *
	 * The case patterns are built as raw `EField` expressions to avoid
	 * macro-time enum resolution against the `BodyPolicy` abstract.
	 */
	private function bodyPolicyWrap(
		flagName:String, writeCall:Expr, bodyValueExpr:Expr, bodyTypePath:String, hasElseIf:Bool,
		elseFieldName:Null<String>, ?afterKwExpr:Null<Expr>, ?kwLeadingExpr:Null<Expr>,
		?bodyOnSameLineExpr:Null<Expr>, ?kwPolicyFlagName:Null<String>, ?afterTrailExpr:Null<Expr>,
		?indentObjArgs:Array<String>, ?policyOverrides:Array<Array<String>>
	):Expr {
		// ω-untyped-body-stmt-override: parent-side body-policy override.
		// When the field carries `@:fmt(bodyPolicyOverride('<ctor>',
		// '<flag>'))` (one entry per call, repeatable), the parent's own
		// `flagName` knob is overridden at runtime by the named replacement
		// flag whenever the body's runtime ctor matches. Mirrors haxe-
		// formatter's "applies sameLine.untypedBody to the gap before
		// `untyped` whenever the parent token is not a Block-typed BrOpen"
		// rule: in non-block parents (e.g. `try` body), the inner-shape
		// knob (`untypedBody`) wins over the parent-shape knob (`tryBody`).
		// Block-stmt Star context has no such override and uses its own
		// `\n<indent>` separator unchanged. Reads via `Type.enumConstructor`
		// so multiple overrides cascade through a ternary chain. Used by
		// `HxTryCatchStmt.body` to flip `tryBody` → `untypedBody` when the
		// body is `UntypedBlockStmt`.
		final defaultOptFlag:Expr = {
			expr: EField(macro opt, flagName),
			pos: Context.currentPos(),
		};
		final optFlag:Expr = if (policyOverrides == null || policyOverrides.length == 0) defaultOptFlag
		else {
			final ctorExpr:Expr = macro Type.enumConstructor($bodyValueExpr);
			var chain:Expr = defaultOptFlag;
			var i:Int = policyOverrides.length - 1;
			while (i >= 0) {
				final pair:Array<String> = policyOverrides[i];
				if (pair.length != 2) Context.fatalError('WriterLowering: bodyPolicyWrap policyOverrides entry requires (ctorName, flagName), got ${pair.length} args', Context.currentPos());
				final ctorName:String = pair[0];
				final overrideFlag:String = pair[1];
				final overrideField:Expr = {expr: EField(macro opt, overrideFlag), pos: Context.currentPos()};
				chain = macro $ctorExpr == $v{ctorName} ? $overrideField : $chain;
				i--;
			}
			chain;
		};
		// ω-issue-316: when the caller forwarded kw-trivia slot accesses,
		// the "Same" separator (`_dt(' ')`) becomes a runtime `kwGapDoc`
		// call that renders any captured after-kw trailing / own-line
		// leading comments and closes with a hardline. When slots are
		// absent, fall back to the byte-identical pre-slice `_dt(' ')`.
		//
		// ω-tryBody (kwOwnsInlineSpace mode): when the field carries a
		// `@:fmt(kwPolicy('<name>'))` companion meta, `kwPolicyFlagName`
		// names a sibling `WhitespacePolicy:After`/`Both` knob on the
		// parent ctor. The `Same` inline separator is then NOT a fixed
		// `_dt(' ')` — it routes through a runtime switch on
		// `opt.<kwPolicyFlagName>` so the parent kw-policy controls
		// whether the inline gap is a space or empty (mirrors the
		// architecturally orthogonal split between "is body inline?" and
		// "is there a space after the kw?"). The strip predicate at the
		// parent Case 3 still fires (kw-trail-space slot is null), so the
		// kw-policy logic lives entirely inside this wrap. Parent ctors
		// with no kw-policy knob skip the meta and get the legacy
		// `_dt(' ')`. Mutually exclusive with `hasKwSlots` —
		// `HxTryCatchStmt.body` is the only consumer today and the `try`
		// kw-trivia is captured at the parent ctor level, not threaded.
		final hasKwSlots:Bool = afterKwExpr != null && kwLeadingExpr != null;
		final wpPath:Array<String> = ['anyparse', 'format', 'WhitespacePolicy'];
		final wpAfter:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['After']));
		final wpBoth:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Both']));
		final kwPolicyInlineSep:Null<Expr> = kwPolicyFlagName == null ? null : {
			final kwOpt:Expr = {expr: EField(macro opt, kwPolicyFlagName), pos: Context.currentPos()};
			{
				expr: ESwitch(kwOpt, [
					{values: [wpAfter, wpBoth], expr: macro _dt(' '), guard: null},
				], macro _de()),
				pos: Context.currentPos(),
			};
		};
		// ω-keep-degraded-optspace: default kw→body separator is `_dop(' ')`
		// (OptSpace, drops before break-mode hardline) instead of `_dt(' ')`
		// (Text). When `Keep` policy degrades to `sameLayoutExpr` (no
		// `bodyOnSameLineExpr` slot — Case 3 enum-branch path) and the body's
		// own emission opens with a hardline (e.g. ObjectLit + leftCurly=Next),
		// the OptSpace drops, yielding `return\n{...}` instead of the spurious
		// `return \n{...}`. For Same policy with non-hardline-opening body
		// (Ident, Call, block ctor `{...}`), OptSpace renders as `' '`,
		// preserving pre-slice byte output.
		final sameSepNb:Expr = hasKwSlots
			? macro kwGapDoc($afterKwExpr, $kwLeadingExpr, _cols, false, opt)
			: kwPolicyInlineSep ?? macro _dop(' ');
		final sameLayoutExpr:Expr = macro _dc([$sameSepNb, $writeCall]);
		// ω-trivia-after-kw-next-layout (bug #3 of issue_45): when the
		// caller forwarded kw-trivia slot accesses, the Next-layout body
		// also threads `afterKw` (cuddled to the kw, before the hardline)
		// and `kwLeading` (own-line comments at body indent inside the
		// Nest). Without this, default-Next non-block bodies like
		// `else // c\n\tbody` silently drop the `// c` because the
		// kw-trivia slots only fed the Same-layout's `kwGapDoc`. The
		// runtime helper `nextLayoutKwGapDoc` builds the threaded shape;
		// when both slots are empty it degrades to the pre-slice
		// `_dn(_cols, [_dhl(), body])` shape so existing fixtures stay
		// byte-identical.
		// ω-expr-body-indent-objectliteral: when the bare-Ref body field
		// carries `@:fmt(indentValueIfCtor('<ctor>', '<optField>',
		// '<leftCurlyField>'))` AND the runtime conditions match
		// (named bool opt FALSE — the inverse of the additive RHS rule
		// — AND named leftCurly opt `Next` AND value's enum ctor matches
		// `ctorName` AND the body's `flatLength` is `-1` i.e. anyHardline),
		// drop the outer Nest from the Next-layout. The body's own
		// leftCurly hardline then lands at the parent's indent
		// (`{` cuddled to the surrounding kw column) and only the body's
		// internal Nest contributes the `+cols` step for the contents.
		// Mirrors haxe-formatter's `indentation.indentObjectLiteral=false`
		// rule for `if (cond)\n{...}` / `for (...) <obj-lit>` style sites
		// where the obj-lit acts as the body anchor itself. Single-line
		// obj-lit values fall through to the default `_dn(_cols, …)` so
		// short cases keep the per-stmt nesting (`if (cond)\n\t{a:1}`).
		//
		// TODO: the `!hasKwSlots` gate silently disables the rule on
		// trivia-mode kw-slot paths (`@:optional @:kw` Ref + bodyPolicy +
		// indentValueIfCtor — would target a future `HxIfExpr.elseBranch`
		// extension). Threading `indentObjArgs` into `nextLayoutKwGapDoc`
		// would lift the limit but is deferred until a consumer needs it.
		if (indentObjArgs != null && indentObjArgs.length != 3)
			Context.fatalError('WriterLowering: bodyPolicyWrap indentObjArgs requires (ctorName, optField, leftCurlyField), got ${indentObjArgs.length} args', Context.currentPos());
		final indentObjGuardedNext:Null<Expr> = if (indentObjArgs != null && !hasKwSlots) {
			final ctorName:String = indentObjArgs[0];
			final optAccess:Expr = {expr: EField(macro opt, indentObjArgs[1]), pos: Context.currentPos()};
			final lcAccess:Expr = {expr: EField(macro opt, indentObjArgs[2]), pos: Context.currentPos()};
			macro {
				final _body:anyparse.core.Doc = $writeCall;
				if (!$optAccess
					&& $lcAccess == anyparse.format.BracePlacement.Next
					&& Type.enumConstructor($bodyValueExpr) == $v{ctorName}
					&& anyparse.format.wrap.WrapList.flatLength(_body) == -1)
					_dc([_dhl(), _body])
				else
					_dn(_cols, _dc([_dhl(), _body]));
			};
		}
		else null;
		final nextLayoutExpr:Expr = if (indentObjGuardedNext != null) indentObjGuardedNext
		else if (hasKwSlots) macro nextLayoutKwGapDoc($afterKwExpr, $kwLeadingExpr, _cols, $writeCall, opt)
		else macro _dn(_cols, _dc([_dhl(), $writeCall]));
		// ω-issue-316-curly-both: block-ctor variant — when the body's
		// writeCall opens with `{`, the separator before it must honour
		// `opt.leftCurly`. For kw-slot sites, threaded through
		// `kwGapDoc`'s `nextCurly` parameter (only affects the no-trivia
		// path; trivia already emits a trailing hardline). For non-slot
		// sites, a runtime switch picks between `_dhl()` and `_dt(' ')`.
		// Under `kwOwnsInlineSpace` mode the leftCurly=Same branch routes
		// through the same kw-policy switch as `sameSepNb` so kw-policy
		// drives whether the inline gap before a same-line `{` is empty
		// or one space (`try{` vs `try {`).
		final bpPathLC:Array<String> = ['anyparse', 'format', 'BracePlacement'];
		final nextPatLC:Expr = MacroStringTools.toFieldExpr(bpPathLC.concat(['Next']));
		final isNextExpr:Expr = {
			expr: ESwitch(macro opt.leftCurly, [
				{values: [nextPatLC], expr: macro true, guard: null},
			], macro false),
			pos: Context.currentPos(),
		};
		final sameSepBlockSameLayout:Expr = kwPolicyInlineSep ?? macro _dt(' ');
		final sameSepBlock:Expr = hasKwSlots
			? macro kwGapDoc($afterKwExpr, $kwLeadingExpr, _cols, $isNextExpr, opt)
			: {
				expr: ESwitch(macro opt.leftCurly, [
					{values: [nextPatLC], expr: macro _dhl(), guard: null},
				], sameSepBlockSameLayout),
				pos: Context.currentPos(),
			};
		final blockLayoutExpr:Expr = macro _dc([$sameSepBlock, $writeCall]);
		final bpPath:Array<String> = ['anyparse', 'format', 'BodyPolicy'];
		final samePat:Expr = MacroStringTools.toFieldExpr(bpPath.concat(['Same']));
		final nextPat:Expr = MacroStringTools.toFieldExpr(bpPath.concat(['Next']));
		final fitPat:Expr = MacroStringTools.toFieldExpr(bpPath.concat(['FitLine']));
		final keepPat:Expr = MacroStringTools.toFieldExpr(bpPath.concat(['Keep']));
		// ω-fitline-multiline-anti-wrap: when the body's writeCall
		// produces a Doc with internal hardlines (multi-line single-expr
		// like `return foo(\n\t...)`), the canonical
		// `BodyGroup(Nest(_cols, [Line(' '), body]))` shape over-wraps:
		// (a) the outer BodyGroup sees fitsFlat=false because of the
		// inner hardline → soft `_dl()` breaks to `\n`, forcing a
		// kw-side wrap that haxe-formatter does NOT emit; (b) the Nest
		// adds `_cols` to every internal hardline on top of the body's
		// own Nest, double-indenting the multi-line operand. The fix
		// runtime-peeks `flatLength(body)`: when -1 (anyHardline), emit
		// `Concat[Text(' '), body]` (kw inline + body wraps internally
		// with its own indent). Width-driven break path is preserved
		// for single-line bodies that don't fit `lineWidth`.
		final fitInnerExpr:Expr = macro anyparse.format.wrap.WrapList.flatLength(_body) == -1
			? _dc([_dt(' '), _body])
			: _dbg(_dn(_cols, _dc([_dl(), _body])));
		final fitExpr:Expr = if (elseFieldName == null) macro {
			final _body:anyparse.core.Doc = $writeCall;
			$fitInnerExpr;
		};
		else {
			final elseAccess:Expr = {
				expr: EField(macro value, elseFieldName),
				pos: Context.currentPos(),
			};
			macro {
				final _body:anyparse.core.Doc = $writeCall;
				(opt.fitLineIfWithElse || $elseAccess == null)
					? $fitInnerExpr
					: _dn(_cols, _dc([_dhl(), _body]));
			}
		}
		// ω-keep-policy: `Keep` dispatches at runtime between same and
		// next layouts based on the trivia-mode parser's captured
		// `<field>BodyOnSameLine:Bool` slot. When the caller did not
		// forward a slot access (non-kw paths, plain mode), degrade to
		// `sameLayoutExpr` (matches the pre-slice behaviour when the
		// loader lossy-mapped `keep` to `Same`). Handled by the outer
		// `keepPat` case below; a `_` catch-all in `policyCases` would
		// be unreachable because the outer switch short-circuits Keep.
		final keepLayoutExpr:Expr = bodyOnSameLineExpr != null
			? macro ($bodyOnSameLineExpr ? $sameLayoutExpr : $nextLayoutExpr)
			: sameLayoutExpr;
		final policyCases:Array<Case> = [
			{values: [samePat], expr: sameLayoutExpr, guard: null},
			{values: [nextPat], expr: nextLayoutExpr, guard: null},
			{values: [fitPat], expr: fitExpr, guard: null},
		];
		final policySwitch:Expr = {expr: ESwitch(optFlag, policyCases, sameLayoutExpr), pos: Context.currentPos()};

		final blockSplit:{tagged:Array<Expr>, untagged:Array<Expr>} = collectBlockCtorPatternsByLeftCurly(bodyTypePath);
		final ifStmtPattern:Null<Expr> = hasElseIf ? findCtorPattern(bodyTypePath, 'IfStmt') : null;
		final outerCases:Array<Case> = [];
		if (ifStmtPattern != null) {
			final kpPath:Array<String> = ['anyparse', 'format', 'KeywordPlacement'];
			final kpNextPat:Expr = MacroStringTools.toFieldExpr(kpPath.concat(['Next']));
			final elseIfCases:Array<Case> = [
				{values: [kpNextPat], expr: nextLayoutExpr, guard: null},
			];
			final elseIfSwitch:Expr = {
				expr: ESwitch(macro opt.elseIf, elseIfCases, sameLayoutExpr),
				pos: Context.currentPos(),
			};
			outerCases.push({values: [ifStmtPattern], expr: elseIfSwitch, guard: null});
		}
		if (blockSplit.untagged.length > 0)
			outerCases.push({values: blockSplit.untagged, expr: sameLayoutExpr, guard: null});
		if (blockSplit.tagged.length > 0)
			outerCases.push({values: blockSplit.tagged, expr: blockLayoutExpr, guard: null});
		final bodySwitch:Expr = if (outerCases.length == 0) policySwitch
		else {
			outerCases.push({values: [macro _], expr: policySwitch, guard: null});
			{expr: ESwitch(bodyValueExpr, outerCases, null), pos: Context.currentPos()};
		};
		// ω-keep-policy: `Keep` takes precedence over block-ctor and
		// elseIf overrides — "keep" means preserve source, so the
		// policy-driven layout shortcuts do not apply. Route the whole
		// wrap through `keepLayoutExpr` when `opt.<flag> == Keep`.
		final outerKeepCases:Array<Case> = [
			{values: [keepPat], expr: keepLayoutExpr, guard: null},
		];
		final coreWrapExpr:Expr = {expr: ESwitch(optFlag, outerKeepCases, bodySwitch), pos: Context.currentPos()};
		// ω-trivia-after-trail: when a synth slot access was forwarded
		// from `lowerStruct` (i.e. the IMMEDIATELY preceding sibling was
		// a mandatory Ref with `@:trail` in trivia-bearing mode), runtime-
		// gate the whole wrap on the slot's value. Non-null slot →
		// override every layout (Same / Next / FitLine / block / elseIf)
		// with a forced Next-layout that prepends ` //<comment>` cuddled
		// to the prior trail token. The line comment forces a hardline
		// regardless of the policy axis, so the body lands at +cols
		// indent on the next line — matching haxe-formatter's
		// `if (cond) // comment\n\tbody` shape. Null slot → run the
		// pre-slice wrap unchanged. The ternary evaluates `$writeCall`
		// only on its taken branch, mirroring how the policy switch
		// already evaluates a single layout per call.
		final wrapExpr:Expr = if (afterTrailExpr == null) coreWrapExpr
		else {
			final forcedLayout:Expr = macro _dc([
				trailingCommentDoc($afterTrailExpr, opt),
				_dn(_cols, _dc([_dhl(), $writeCall])),
			]);
			macro $afterTrailExpr != null ? $forcedLayout : $coreWrapExpr;
		};

		return macro {
			final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			$wrapExpr;
		};
	}

	/**
	 * Walk `bodyTypePath`'s rule (expected to be an `Alt`) and collect
	 * `case` patterns for branches that render via `blockBody` — i.e.
	 * enum ctors declared with `@:lead(open) @:trail(close)` on a single
	 * `Star` child. Returns an empty array when `bodyTypePath` is not an
	 * enum, has no such branches, or is absent from the shape map.
	 */
	private function collectBlockCtorPatterns(bodyTypePath:String):Array<Expr> {
		final rule:Null<ShapeNode> = shape.rules.get(bodyTypePath);
		if (rule == null || rule.kind != Alt) return [];
		final patterns:Array<Expr> = [];
		for (branch in rule.children) if (isBlockCtorBranch(branch))
			patterns.push(branchCtorPattern(bodyTypePath, branch));
		return patterns;
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
	private function findElementBodyField(elemTypePath:String, bodyTypePath:String):Null<String> {
		final rule:Null<ShapeNode> = shape.rules.get(elemTypePath);
		if (rule == null || rule.kind != Seq) return null;
		for (child in rule.children) if (child.kind == Ref) {
			if (child.annotations.get('base.optional') == true) continue;
			final ref:Null<String> = child.annotations.get('base.ref');
			if (ref == bodyTypePath) return child.annotations.get('base.fieldName');
		}
		return null;
	}

	/**
	 * ω-close-trailing-alt — runtime override for a Star's first-element
	 * separator when the immediately preceding struct field was a bare
	 * Ref to a trivia-bearing type. Iterates the prev body's Alt branches
	 * looking for close-trailing branches (Star + `@:trail` + `@:trivia`)
	 * — currently only `HxStatement.BlockStmt`. For each, emits a case
	 * `BlockStmt(_, _ct)` with guard `_ct != null` mapping to `_de()`
	 * (the body's writer already terminated with `\n`, so any sep would
	 * leak ` ` between the indent and the next sibling). The default
	 * case falls through to `sepExpr`. Returns `null` when no override
	 * is needed (no prev body, non-bearing target, or no close-trailing
	 * branches in the Alt) so the caller skips the override path.
	 */
	private function buildCloseTrailingFirstSepOverride(prevBareRefBody:Null<PrevBodyInfo>, sepExpr:Expr):Null<Expr> {
		if (prevBareRefBody == null) return null;
		final rule:Null<ShapeNode> = shape.rules.get(prevBareRefBody.typePath);
		if (rule == null || rule.kind != Alt) return null;
		final cases:Array<Case> = [];
		for (branch in rule.children) if (TriviaTypeSynth.isAltCloseTrailingBranch(branch)) {
			final ctorName:String = branch.annotations.get('base.ctor');
			final ctorPath:Array<String> = ruleCtorPath(prevBareRefBody.typePath, ctorName);
			final ctorRef:Expr = MacroStringTools.toFieldExpr(ctorPath);
			// Pattern arity: child shape (1 Star) + the closeTrailing slot
			// (which we BIND as `_ct`) + any further synth extras
			// (currently only openTrailing for `:lead` branches; trailOpt /
			// captureSource predicates are disjoint from the close-trailing
			// shape, but the helper covers them for forward compatibility).
			final extras:Int = branchSynthExtraArity(prevBareRefBody.typePath, branch);
			final patternArgs:Array<Expr> = [macro _, macro _ct];
			for (_ in 0...extras - 1) patternArgs.push(macro _);
			final pattern:Expr = {
				expr: ECall(ctorRef, patternArgs),
				pos: Context.currentPos(),
			};
			cases.push({values: [pattern], guard: macro _ct != null, expr: macro _de()});
		}
		if (cases.length == 0) return null;
		cases.push({values: [macro _], guard: null, expr: sepExpr});
		return {expr: ESwitch(prevBareRefBody.access, cases, null), pos: Context.currentPos()};
	}

	/**
	 * ω-issue-316-curly-both — parallel to `collectBlockCtorPatterns`, but
	 * partitions the block-ctor branches by whether the branch carries a
	 * `@:fmt(leftCurly)` flag. Consumed by `bodyPolicyWrap` so block-ctor
	 * bodies (`BlockStmt(_)`) can honour `opt.leftCurly:BracePlacement`
	 * at the body-placement override — tagged patterns emit a
	 * leftCurly-aware separator, untagged patterns fall back to the
	 * pre-slice single-space layout.
	 */
	private function collectBlockCtorPatternsByLeftCurly(bodyTypePath:String):{tagged:Array<Expr>, untagged:Array<Expr>} {
		final rule:Null<ShapeNode> = shape.rules.get(bodyTypePath);
		if (rule == null || rule.kind != Alt) return {tagged: [], untagged: []};
		final tagged:Array<Expr> = [];
		final untagged:Array<Expr> = [];
		for (branch in rule.children) if (isBlockCtorBranch(branch)) {
			final pattern:Expr = branchCtorPattern(bodyTypePath, branch);
			if (branch.fmtHasFlag('leftCurly')) tagged.push(pattern);
			else untagged.push(pattern);
		}
		return {tagged: tagged, untagged: untagged};
	}

	private function branchCtorPattern(bodyTypePath:String, branch:ShapeNode):Expr {
		final ctorName:String = branch.annotations.get('base.ctor');
		final arity:Int = branch.children.length + branchSynthExtraArity(bodyTypePath, branch);
		final ctorPath:Array<String> = ruleCtorPath(bodyTypePath, ctorName);
		final ctorRef:Expr = MacroStringTools.toFieldExpr(ctorPath);
		return if (arity == 0) ctorRef
		else {
			final args:Array<Expr> = [for (_ in 0...arity) macro _];
			{expr: ECall(ctorRef, args), pos: Context.currentPos()};
		};
	}

	/**
	 * Synth-pair Alt branches grow positional args beyond `children.length`
	 * in trivia mode (closeTrailing, openTrailing, trailPresent, sourceText).
	 * Wildcard patterns must include matching `_` slots for each, otherwise
	 * arity mismatches the synth ctor at compile time. Returns 0 when the
	 * body is not trivia-bearing or the branch shape adds no extra args.
	 */
	private function branchSynthExtraArity(bodyTypePath:String, branch:ShapeNode):Int {
		if (!isTriviaBearing(bodyTypePath)) return 0;
		var extras:Int = 0;
		if (TriviaTypeSynth.isAltCloseTrailingBranch(branch)) {
			extras++;
			if (branch.readMetaString(':lead') != null && !branch.hasMeta(':tryparse')) extras++;
		}
		if (TriviaTypeSynth.isAltTrailOptBranch(branch)) extras++;
		if (TriviaTypeSynth.isCaptureSourceBranch(branch)) extras++;
		return extras;
	}

	private static function isBlockCtorBranch(branch:ShapeNode):Bool {
		final leadText:Null<String> = branch.annotations.get('lit.leadText');
		final trailText:Null<String> = branch.annotations.get('lit.trailText');
		if (leadText == null || trailText == null) return false;
		if (branch.children.length != 1) return false;
		return branch.children[0].kind == Star;
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
	private function findCtorPattern(bodyTypePath:String, ctorName:String):Null<Expr> {
		final rule:Null<ShapeNode> = shape.rules.get(bodyTypePath);
		if (rule == null || rule.kind != Alt) return null;
		for (branch in rule.children) {
			final branchCtor:String = branch.annotations.get('base.ctor');
			if (branchCtor != ctorName) continue;
			final arity:Int = branch.children.length + branchSynthExtraArity(bodyTypePath, branch);
			final ctorPath:Array<String> = ruleCtorPath(bodyTypePath, branchCtor);
			final ctorRef:Expr = MacroStringTools.toFieldExpr(ctorPath);
			return if (arity == 0) ctorRef
			else {
				final args:Array<Expr> = [for (_ in 0...arity) macro _];
				{expr: ECall(ctorRef, args), pos: Context.currentPos()};
			};
		}
		return null;
	}

	/**
	 * Return a `Bool`-valued expression for the `trailingComma` argument
	 * of `sepList`. Returns `macro false` when the node carries no
	 * `@:fmt(trailingComma("flagName"))` knob, else `macro opt.<flagName>` so
	 * the knob is resolved at runtime against the caller's options.
	 *
	 * Read from the node that owns the separated list — an enum branch
	 * (Case 4 Star / postfix Star) or a struct Star field.
	 */
	private static function trailingCommaExpr(node:ShapeNode):Expr {
		final flagName:Null<String> = node.fmtReadString('trailingComma');
		if (flagName == null) return macro false;
		return {
			expr: EField(macro opt, flagName),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Return a `Bool`-valued expression for the `keepInnerWhenEmpty`
	 * argument of `sepList`. Returns `macro false` when the field
	 * carries no `@:fmt(keepInnerWhenEmpty("flagName"))` knob, else
	 * `macro opt.<flagName>` so the knob is resolved at runtime.
	 *
	 * Today only struct Star fields opt in (`HxFnExpr.params` →
	 * `anonFuncParamParensKeepInnerWhenEmpty`). The two other `sepList`
	 * call sites (postfix Star, enum Case 4 Star) pass `false`
	 * directly — they have no fixture demand for the inside-space-on-
	 * empty shape and the literal keeps the macro dependency narrow.
	 */
	private static function keepInnerWhenEmptyExpr(node:ShapeNode):Expr {
		final flagName:Null<String> = node.fmtReadString('keepInnerWhenEmpty');
		if (flagName == null) return macro false;
		return {
			expr: EField(macro opt, flagName),
			pos: Context.currentPos(),
		};
	}

	/**
	 * True when the given lead-open string is declared by the format as
	 * taking a preceding space (e.g. Haxe's `{` block-opens). All other
	 * open-delimiters (`(`, `[`, etc.) stay tight against the preceding
	 * token. Evaluated at macro time against `formatInfo.spacedLeads`.
	 */
	private function isSpacedLead(openText:Null<String>):Bool {
		return openText != null && formatInfo.spacedLeads.indexOf(openText) != -1;
	}

	/**
	 * True when the given Star struct field has no `@:lead` / `@:trail`
	 * / `@:sep`, so its emitted Doc is empty whenever the runtime array
	 * is empty. The next bare-Ref field's leading separator must then
	 * be gated on `field.length > 0`, otherwise the writer emits a
	 * dangling space (`\t function` instead of `\tfunction` when
	 * `HxMemberDecl.modifiers` is empty).
	 */
	private static function isBareTryparseStar(child:ShapeNode):Bool {
		if (child.kind != Star) return false;
		final leadText:Null<String> = child.annotations.get('lit.leadText');
		final trailText:Null<String> = child.annotations.get('lit.trailText');
		final sepText:Null<String> = child.annotations.get('lit.sepText');
		return leadText == null && trailText == null && sepText == null;
	}

	/**
	 * True when the given optional `@:lead(...)` text is declared by the
	 * format as tight — no leading separator before it, no trailing
	 * space after it. Used by the optional-Ref code path so Haxe's
	 * `:Type` annotation stays compact instead of being wrapped in
	 * spaces like keyword leads (`else`, `catch`).
	 */
	private function isTightLead(leadText:Null<String>):Bool {
		return leadText != null && formatInfo.tightLeads.indexOf(leadText) != -1;
	}

	/**
	 * True when `refName` names a Seq (struct) rule whose first field is
	 * a bare Ref annotated with `@:fmt(bodyPolicy(...))` and no `@:kw` / `@:lead`
	 * of its own. Used by Case 3 enum-branch lowering to decide whether
	 * to strip the trailing space from a `@:kw` lead — the sub-struct's
	 * writer will emit the header→body separator via `bodyPolicyWrap`,
	 * so leaving the space in would yield a double space in the `Same`
	 * case and a dangling space before a hardline in `Next` / `FitLine`.
	 */
	private function subStructStartsWithBodyPolicy(refName:String):Bool {
		final subNode:Null<ShapeNode> = shape.rules.get(refName);
		if (subNode == null || subNode.kind != Seq) return false;
		final children:Array<ShapeNode> = subNode.children;
		if (children.length == 0) return false;
		final first:ShapeNode = children[0];
		if (first.kind != Ref) return false;
		if (first.annotations.get('base.optional') == true) return false;
		if (first.readMetaString(':kw') != null) return false;
		if (first.readMetaString(':lead') != null) return false;
		return first.fmtReadString('bodyPolicy') != null;
	}

	/**
	 * True when `refName` names a Seq rule whose first field is a bare
	 * Ref annotated with `@:fmt(bodyBreak(...))` and no `@:kw` / `@:lead`
	 * of its own. Mirrors `subStructStartsWithBodyPolicy` for the 2-way
	 * `SameLinePolicy` body-break knob (ω-expression-try-body-break).
	 * The field's own `bodyBreakWrap` provides the conditional
	 * space/hardline-Nest between the parent kw and the body, so the
	 * parent Case 3 must strip the trailing space from `kwLead` to
	 * avoid a double space in `Same` and a dangling space before a
	 * hardline in `Next`.
	 */
	private function subStructStartsWithBodyBreak(refName:String):Bool {
		final subNode:Null<ShapeNode> = shape.rules.get(refName);
		if (subNode == null || subNode.kind != Seq) return false;
		final children:Array<ShapeNode> = subNode.children;
		if (children.length == 0) return false;
		final first:ShapeNode = children[0];
		if (first.kind != Ref) return false;
		if (first.annotations.get('base.optional') == true) return false;
		if (first.readMetaString(':kw') != null) return false;
		if (first.readMetaString(':lead') != null) return false;
		return first.fmtReadString('bodyBreak') != null;
	}

	/**
	 * True when `refName` names a Seq rule whose first field is a bare
	 * Ref annotated with `@:fmt(bareBodyBreaks)` and no `@:kw` / `@:lead`
	 * of its own. Mirror of `subStructStartsWithBodyBreak` for the
	 * shape-driven (no policy) bare-body break knob (ω-statement-
	 * bare-break). The field's own `bareBodyBreakWrap` provides the
	 * conditional space/hardline-Nest between the parent kw and the body,
	 * so the parent Case 3 must strip the trailing space from `kwLead` —
	 * otherwise `try` + ` ` + (block branch's inline ` `) yields `try  body`
	 * for blocks and `try \n\tbody` for bare bodies (dangling space before
	 * the hardline).
	 */
	private function subStructStartsWithBareBodyBreaks(refName:String):Bool {
		final subNode:Null<ShapeNode> = shape.rules.get(refName);
		if (subNode == null || subNode.kind != Seq) return false;
		final children:Array<ShapeNode> = subNode.children;
		if (children.length == 0) return false;
		final first:ShapeNode = children[0];
		if (first.kind != Ref) return false;
		if (first.annotations.get('base.optional') == true) return false;
		if (first.readMetaString(':kw') != null) return false;
		if (first.readMetaString(':lead') != null) return false;
		return first.fmtHasFlag('bareBodyBreaks');
	}

	/**
	 * True when `refName` names a Seq rule whose first field's `@:lead`
	 * is declared tight by the format (`FormatInfo.tightLeads`, e.g. `:`
	 * for Haxe). A `@:kw` that routes into such a sub-struct must not
	 * emit a trailing word-boundary space — the tight lead wants to
	 * abut the kw without a space (`default:`, not `default :`). Leads
	 * that are NOT tight (`(`, `{`) keep the space (`if (`, `else {`).
	 */
	private function subStructStartsWithTightLead(refName:String):Bool {
		final subNode:Null<ShapeNode> = shape.rules.get(refName);
		if (subNode == null || subNode.kind != Seq) return false;
		final children:Array<ShapeNode> = subNode.children;
		if (children.length == 0) return false;
		final first:ShapeNode = children[0];
		return isTightLead(first.readMetaString(':lead'));
	}

	/**
	 * Build the Doc expression for a block-mode trivia Star field
	 * (`@:lead(open) @:trail(close) @:trivia`). Per-element layout:
	 * hardline baseline, optional extra hardline for `blankBefore`
	 * (skipped on the first element — the leading `{` already gives the
	 * break), leading comments each followed by a hardline, the element
	 * write call, optional trailing line comment. Wrapped in
	 * `_dc([_dt(open), _dn(cols, _dc(inner)), _dhl(), _dt(close)])` to
	 * match the Doc shape of the plain-mode `blockBody` helper.
	 *
	 * `elemFn` is the `*T`-variant write function (e.g. `writeHxMemberDeclT`)
	 * — the helper does not itself consult `isTriviaBearing`.
	 */
	private static function triviaBlockStarExpr(
		fieldAccess:Expr, trailBBAccess:Null<Expr>, trailLCAccess:Null<Expr>, trailCloseAccess:Null<Expr>,
		trailOpenAccess:Null<Expr>, elemFn:String, openText:String, closeText:String,
		appendHardlineAfterTrail:Bool = false,
		afterFieldsWithDocComments:Bool = false, existingBetweenFields:Bool = false,
		beforeDocCommentEmptyLines:Bool = false,
		interMemberInfo:Null<InterMemberClassifyInfo> = null,
		indentCaseLabelsGate:Bool = false
	):Expr {
		final triviaElemCall:Expr = {
			expr: ECall(macro $i{elemFn}, [macro _t.node, macro opt]),
			pos: Context.currentPos(),
		};
		final emptyText:String = openText + closeText;
		// ω-orphan-trivia: Alt-branch Star call sites (BlockStmt) have no
		// synth trailing slots — the null branch drops trailing trivia,
		// matching pre-slice behaviour. Seq-struct call sites forward the
		// real accessors and round-trip orphan comments.
		final trailBB:Expr = trailBBAccess ?? macro false;
		final trailLC:Expr = trailLCAccess ?? macro ([] : Array<String>);
		// ω-close-trailing: same-line trailing comment captured right
		// after the close literal (e.g. `} // comment` before the next
		// sibling). Present only for close-peek Seq Stars (Seq-struct
		// + ω-close-trailing-alt's BlockStmt); EOF and try-parse sites
		// forward null and degrade to the pre-slice close emission.
		// ω-trailing-block-style: the captured string includes its
		// delimiters (producer uses `collectTrailingFull`), so the
		// emission routes through `trailingCommentDocVerbatim` to
		// preserve block-vs-line style on round-trip.
		final trailClose:Expr = trailCloseAccess ?? macro (null : Null<String>);
		// ω-open-trailing: same-line trailing comment captured right after
		// the open literal (e.g. `{ // foo` before the first member).
		// Synthesised only for Stars with `@:lead`; Alt-branch and EOF
		// sites forward null. Verbatim emission preserves block-vs-line
		// style.
		final trailOpen:Expr = trailOpenAccess ?? macro (null : Null<String>);
		// ω-close-trailing-alt: Alt-branch sites pass true so the trailing
		// line comment is followed by `_dhl()` — line comments terminate
		// at \n semantically, and the Alt's parent struct may emit a space
		// sep next (e.g. HxTryCatchStmt.body→catches with sameLineCatch),
		// which would glue the next sibling onto the same line as the
		// comment. Seq-struct sites pass false: their close-trailing slot
		// always lives on the LAST field of its containing struct, where
		// the parent Star's element separator already supplies a hardline.
		final trailFollowExpr:Expr = appendHardlineAfterTrail ? macro _parts.push(_dhl()) : macro {};
		final emptyTrailExpr:Expr = appendHardlineAfterTrail
			? macro _dc([_dt($v{emptyText}), trailingCommentDocVerbatim(_trailClose, opt), _dhl()])
			: macro _dc([_dt($v{emptyText}), trailingCommentDocVerbatim(_trailClose, opt)]);
		// ω-C-empty-lines-doc / ω-C-empty-lines-between-fields /
		// ω-C-empty-lines-before-doc: when the grammar field carries any
		// of the empty-line flags
		// (`@:fmt(afterFieldsWithDocComments)`,
		// `@:fmt(existingBetweenFields)`,
		// `@:fmt(beforeDocCommentEmptyLines)`), the per-element loop
		// gates its blank-line emission on the corresponding runtime
		// policies —
		// `afterFieldsWithDocComments.One` forces a blank line after any
		// element whose leading trivia carried a `/**`-prefixed entry,
		// `afterFieldsWithDocComments.None` strips source blanks adjacent
		// to such an element, `existingBetweenFields.Remove` strips every
		// source blank between siblings regardless of doc-comment status,
		// `beforeDocCommentEmptyLines.One` forces a blank line before any
		// element whose own leading trivia starts with a `/**`-prefixed
		// entry, `beforeDocCommentEmptyLines.None` strips source blanks
		// adjacent to such an element's leading side. The policies
		// compose: a blank line survives only when no active strip-policy
		// fires AND (the source had one OR any add-policy fires). The
		// compile-time gate keeps JSON / AS3 writers byte-identical —
		// their Star fields carry none of the flags and skip the policy
		// computation entirely.
		final interMember:Bool = interMemberInfo != null;
		final anyEmptyLinesFlag:Bool = afterFieldsWithDocComments || existingBetweenFields || beforeDocCommentEmptyLines || interMember;
		final stripByDocExpr:Expr = afterFieldsWithDocComments
			? macro (_prevHadDocComment && opt.afterFieldsWithDocComments == anyparse.format.CommentEmptyLinesPolicy.None)
			: macro false;
		final addByDocExpr:Expr = afterFieldsWithDocComments
			? macro (_prevHadDocComment && opt.afterFieldsWithDocComments == anyparse.format.CommentEmptyLinesPolicy.One)
			: macro false;
		final stripByExistingExpr:Expr = existingBetweenFields
			? macro (opt.existingBetweenFields == anyparse.format.KeepEmptyLinesPolicy.Remove)
			: macro false;
		final stripByCurrDocExpr:Expr = beforeDocCommentEmptyLines
			? macro (_currHasDocComment && opt.beforeDocCommentEmptyLines == anyparse.format.CommentEmptyLinesPolicy.None)
			: macro false;
		final addByCurrDocExpr:Expr = beforeDocCommentEmptyLines
			? macro (_currHasDocComment && opt.beforeDocCommentEmptyLines == anyparse.format.CommentEmptyLinesPolicy.One)
			: macro false;
		final currHasDocComputeExpr:Expr = beforeDocCommentEmptyLines ? macro {
			_currHasDocComment = false;
			var _cdci:Int = 0;
			while (_cdci < _t.leadingComments.length) {
				if (StringTools.startsWith(_t.leadingComments[_cdci], '/**')) {
					_currHasDocComment = true;
					break;
				}
				_cdci++;
			}
		} : macro {};
		final currKindComputeExpr:Expr = interMember ? {
			final classifierAccess:Expr = {
				expr: EField(macro _t.node, interMemberInfo.classifierFieldName),
				pos: Context.currentPos(),
			};
			final switchExpr:Expr = {
				expr: ESwitch(classifierAccess, interMemberInfo.classifyCases, null),
				pos: Context.currentPos(),
			};
			macro _currKind = $switchExpr;
		} : macro {};
		final addByInterMemberExpr:Expr = interMember ? {
			final pos:Position = Context.currentPos();
			final betweenVarsAccess:Expr = {
				expr: EField(macro opt, interMemberInfo.betweenVarsField),
				pos: pos,
			};
			final betweenFnAccess:Expr = {
				expr: EField(macro opt, interMemberInfo.betweenFunctionsField),
				pos: pos,
			};
			final afterVarsAccess:Expr = {
				expr: EField(macro opt, interMemberInfo.afterVarsField),
				pos: pos,
			};
			macro (
				(_prevKind == 1 && _currKind == 1 && $betweenVarsAccess > 0)
				|| (_prevKind == 2 && _currKind == 2 && $betweenFnAccess > 0)
				|| (_prevKind != 0 && _currKind != 0 && _prevKind != _currKind && $afterVarsAccess > 0)
			);
		} : macro false;
		final blankBeforeExpr:Expr = anyEmptyLinesFlag ? macro {
			$currHasDocComputeExpr;
			$currKindComputeExpr;
			final _stripBlank:Bool = $stripByDocExpr || $stripByExistingExpr || $stripByCurrDocExpr;
			final _addBlank:Bool = $addByDocExpr || $addByCurrDocExpr || $addByInterMemberExpr;
			final _sourceBlank:Bool = _t.blankBefore && !_stripBlank;
			if (_si > 0 && (_sourceBlank || _addBlank)) _inner.push(_dhl());
		} : macro {
			if (_t.blankBefore && _si > 0) _inner.push(_dhl());
		};
		final trackDocCommentExpr:Expr = afterFieldsWithDocComments ? macro {
			var _hasDoc:Bool = false;
			var _dci:Int = 0;
			while (_dci < _t.leadingComments.length) {
				if (StringTools.startsWith(_t.leadingComments[_dci], '/**')) {
					_hasDoc = true;
					break;
				}
				_dci++;
			}
			_prevHadDocComment = _hasDoc;
		} : macro {};
		final initDocCommentExpr:Expr = afterFieldsWithDocComments
			? macro var _prevHadDocComment:Bool = false
			: macro {};
		final initCurrDocCommentExpr:Expr = beforeDocCommentEmptyLines
			? macro var _currHasDocComment:Bool = false
			: macro {};
		final initPrevKindExpr:Expr = interMember ? macro var _prevKind:Int = 0 : macro {};
		final initCurrKindExpr:Expr = interMember ? macro var _currKind:Int = 0 : macro {};
		final trackPrevKindExpr:Expr = interMember ? macro _prevKind = _currKind : macro {};
		// ω-indent-case-labels: when the call site (HxSwitchStmt.cases /
		// HxSwitchStmtBare.cases) opts in via `@:fmt(indentCaseLabels)`,
		// the body wrap is gated on `opt.indentCaseLabels` at runtime —
		// `false` flushes case labels with the surrounding `switch`
		// keyword instead of nesting them one level inside `{ … }`.
		// Per-case body indentation comes from `nestBody` on
		// `HxCaseBranch.body` / `HxDefaultBranch.stmts` and stays in
		// effect either way, so the body still receives one indent
		// relative to its label.
		final innerWrapExpr:Expr = indentCaseLabelsGate
			? macro (opt.indentCaseLabels ? _dn(_cols, _dc(_inner)) : _dc(_inner))
			: macro _dn(_cols, _dc(_inner));
		return macro {
			final _arr = $fieldAccess;
			final _trailLC:Array<String> = $trailLC;
			final _trailBB:Bool = $trailBB;
			final _trailClose:Null<String> = $trailClose;
			final _trailOpen:Null<String> = $trailOpen;
			// ω-open-trailing-alt: empty Star with a same-line block-style
			// trail comment after the open lit (`{ /* nop */ }`) emits flat
			// tight. Mirror of the equivalent fast path in
			// `triviaSepStarExpr` — see that helper for the line-style
			// fall-through rationale (line `// …` comments always arrive
			// with a source `\n` before the close).
			if (_arr.length == 0 && _trailLC.length == 0
					&& _trailOpen != null && StringTools.startsWith(_trailOpen, '/*')) {
				final _openDoc:anyparse.core.Doc = _dt(_trailOpen);
				if (_trailClose != null)
					_dc([_dt($v{openText}), _openDoc, _dt($v{closeText}), trailingCommentDocVerbatim(_trailClose, opt)]);
				else
					_dc([_dt($v{openText}), _openDoc, _dt($v{closeText})]);
			} else if (_arr.length == 0 && _trailLC.length == 0 && _trailOpen == null) {
				if (_trailClose != null) $emptyTrailExpr
				else _dt($v{emptyText});
			} else {
				final _inner:Array<anyparse.core.Doc> = [];
				$initDocCommentExpr;
				$initCurrDocCommentExpr;
				$initPrevKindExpr;
				var _si:Int = 0;
				while (_si < _arr.length) {
					final _t = _arr[_si];
					$initCurrKindExpr;
					_inner.push(_dhl());
					$blankBeforeExpr;
					var _ci:Int = 0;
					while (_ci < _t.leadingComments.length) {
						_inner.push(leadingCommentDoc(_t.leadingComments[_ci], opt));
						_inner.push(_dhl());
						_ci++;
					}
					if (_t.blankAfterLeadingComments && _t.leadingComments.length > 0) _inner.push(_dhl());
					$trackDocCommentExpr;
					final _elem:anyparse.core.Doc = $triviaElemCall;
					final _tc:Null<String> = _t.trailingComment;
					_inner.push(_tc != null ? foldTrailingIntoBodyGroup(_elem, trailingCommentDoc(_tc, opt)) : _elem);
					$trackPrevKindExpr;
					_si++;
				}
				if (_trailLC.length > 0) {
					_inner.push(_dhl());
					if (_trailBB && _arr.length > 0) _inner.push(_dhl());
					var _ti:Int = 0;
					while (_ti < _trailLC.length) {
						_inner.push(leadingCommentDoc(_trailLC[_ti], opt));
						if (_ti < _trailLC.length - 1) _inner.push(_dhl());
						_ti++;
					}
				}
				final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
				final _innerWrap:anyparse.core.Doc = $innerWrapExpr;
				final _parts:Array<anyparse.core.Doc> = [_dt($v{openText})];
				if (_trailOpen != null) _parts.push(trailingCommentDocVerbatim(_trailOpen, opt));
				_parts.push(_innerWrap);
				_parts.push(_dhl());
				_parts.push(_dt($v{closeText}));
				if (_trailClose != null) {
					_parts.push(trailingCommentDocVerbatim(_trailClose, opt));
					$trailFollowExpr;
				}
				// ω-break-group: wrap the block body in BodyGroup so a
				// surrounding Group (e.g. a call's sepList) does NOT see
				// the body's hardlines through its fitsFlat measurement.
				// Without this, putting a switch / class block / `{}` body
				// inside a call arg forces the call's outer parens to break
				// (the body's hardlines fail the parent's fit). With BG,
				// the outer parens stay inline; the body still breaks via
				// its own hardline-force-not-fit decision.
				_dbg(_dc(_parts));
			}
		};
	}

	/**
	 * ω-trivia-sep: build the Doc expression for a close-peek `@:trivia`
	 * Star field with `@:sep` (e.g. `HxObjectLit.fields` and
	 * `HxExpr.ArrayExpr`). Mirrors `triviaBlockStarExpr` but adds the
	 * separator between elements AND drives multi-line vs flat layout
	 * from source-fidelity signals on the `Trivial<T>` wrapper.
	 *
	 * Layout decision is computed at runtime over the captured array:
	 * if ANY element carries a `newlineBefore`, blank line, leading
	 * comment, or trailing comment, OR the orphan trail slots are
	 * non-empty, the whole literal renders multi-line. Otherwise it
	 * collapses to flat `{a, b, c}` (or `[a, b, c]`) on a single line.
	 *
	 * The runtime check preserves source intent without reaching for
	 * a width-driven Group: the existing 8 corpus fixtures all break
	 * because the user wrote them multi-line, not because they
	 * exceeded line width. Width-driven wrap stays a future slice.
	 */
	private static function triviaSepStarExpr(
		fieldAccess:Expr, trailBBAccess:Null<Expr>, trailLCAccess:Null<Expr>, trailCloseAccess:Null<Expr>,
		trailOpenAccess:Null<Expr>, elemFn:String, openText:String, closeText:String, sepText:String,
		wrapRulesField:Null<String> = null, leftCurlyKnob:Null<String> = null,
		trailPresentAccess:Null<Expr> = null, trailingCommaField:Null<String> = null
	):Expr {
		final triviaElemCall:Expr = {
			expr: ECall(macro $i{elemFn}, [macro _t.node, macro opt]),
			pos: Context.currentPos(),
		};
		final emptyText:String = openText + closeText;
		final trailBB:Expr = trailBBAccess ?? macro false;
		final trailLC:Expr = trailLCAccess ?? macro ([] : Array<String>);
		final trailClose:Expr = trailCloseAccess ?? macro (null : Null<String>);
		final trailOpen:Expr = trailOpenAccess ?? macro (null : Null<String>);
		final emptyTrailExpr:Expr = macro _dc([_dt($v{emptyText}), trailingCommentDocVerbatim(_trailClose, opt)]);
		// ω-objectlit-leftCurly-cascade: when the call site delegates
		// leftCurly emission to this helper (knob-form leftCurly + wrap-
		// rules), build runtime accessors for the knob value that:
		//  - in the trivia branch: pick `_dhl()` (Next) or `_de()` (Same)
		//    as a single Doc prepended to the BodyGroup's parts.
		//  - in the no-trivia branch: feed `(leadFlat, leadBreak)` into
		//    `WrapList.emit` so the engine's Group(IfBreak) picks the
		//    right shape per the wrap-cascade's flat/break decision.
		final knobExpr:Null<Expr> = leftCurlyKnob == null
			? null
			: {expr: EField(macro opt, leftCurlyKnob), pos: Context.currentPos()};
		final nextPat:Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BracePlacement', 'Next']);
		// Doc that selects `_doh()` for `BracePlacement.Next`, `_de()`
		// otherwise. `_doh()` is `OptHardline` — drops when the previous
		// emit was already a hardline (e.g. wrap-engine sep `\n`
		// between call args). Avoids the `,\n\n{` newline-collision
		// bug when an outer wrap-engine sep and an inner leftCurly Next
		// independently push a leading newline at the same insertion
		// point (slice ω-opthardline).
		//
		// `wrapLeadFlatDoc` is always `_de()` — flat layout never wants
		// a hardline before the open brace, regardless of knob value.
		final knobNextOrEmpty:Expr = knobExpr == null
			? macro _de()
			: {
				expr: ESwitch(knobExpr, [{values: [nextPat], expr: macro _doh(), guard: null}], macro _de()),
				pos: Context.currentPos(),
			};
		final triviaLeadDoc:Expr = knobNextOrEmpty;
		final wrapLeadFlatDoc:Expr = macro _de();
		final wrapLeadBreakDoc:Expr = knobNextOrEmpty;
		// ω-wraprules-objlit: when the Star carries
		// `@:fmt(wrapRules('<field>'))`, defer the no-trivia branch's
		// layout decision to the runtime `WrapList.emit` engine. The
		// engine reads `opt.<field>:WrapRules`, measures item count +
		// flat widths, and emits one of `NoWrap` / `OnePerLine` /
		// `OnePerLineAfterFirst` / `FillLine` shapes — wrapping the
		// result in `Group(IfBreak(brkDoc, flatDoc))` when the cascade's
		// `exceeds=false` and `exceeds=true` runs disagree, so the
		// renderer's flat/break decision picks the right mode at layout
		// time. When `wrapRulesField` is null, the no-trivia branch
		// keeps its pre-slice flat-only emission.
		//
		// ω-objectlit-source-trail-comma: when both `trailPresentAccess`
		// and `trailingCommaField` are wired, the engine receives a
		// `forceExceeds` flag = `<value>.<field>TrailPresent &&
		// opt.<trailingCommaField>`. When true, the cascade collapses to
		// its `exceeds=true` branch — typically `OnePerLine` — so the
		// source's "I want this multi-line" intent (a trailing separator)
		// round-trips instead of being silently flattened. The same
		// `opt.<trailingCommaField>` value is forwarded as
		// `appendTrailingComma` so the multi-line shape's last element
		// gets its `,`. When the knob is off the conjunction stays false
		// and `appendTrailingComma` is false — behaviour is byte-
		// identical to the pre-slice path.
		final knobAccessOrFalse:Expr = trailingCommaField == null
			? macro false
			: {expr: EField(macro opt, trailingCommaField), pos: Context.currentPos()};
		final forceExceedsExpr:Expr = trailPresentAccess != null && trailingCommaField != null
			? macro $trailPresentAccess && $knobAccessOrFalse
			: macro false;
		// ω-meta-allman-objectlit: when source had a trailing `,`, preserve
		// it in any multi-line shape regardless of the knob. Flat `NoWrap`
		// never appends (`shapeNoWrap` ignores `appendTrailingComma`), so
		// the disjunction degrades to the pre-slice behaviour for the
		// knob-off + flat-cascade case (`testSourceTrailingCommaIgnored-
		// WhenKnobOff` still asserts `{i: 0}`). The change only matters
		// when the layout is forced multi-line by some other signal —
		// surrounding hardlines (e.g. the meta-Allman wrap from
		// `HxMetaExpr.expr`'s `@:fmt(allmanIndentForCtor)`), natural
		// cascade fit, or `forceExceeds` — at which point the source's
		// `,` round-trips like the rest of the multi-line shape.
		// Mirrors haxe-formatter's "Keep" trailing-comma policy for the
		// meta-prefixed object-literal pattern (`return @patch { ..., }`
		// → multi-line with closing `,`).
		final appendTrailingCommaExpr:Expr = trailPresentAccess != null && trailingCommaField != null
			? macro $trailPresentAccess || $knobAccessOrFalse
			: knobAccessOrFalse;
		final noTriviaBranch:Expr = if (wrapRulesField != null) {
			final rulesExpr:Expr = {
				expr: EField(macro opt, wrapRulesField),
				pos: Context.currentPos(),
			};
			macro {
				final _docs:Array<anyparse.core.Doc> = [];
				var _si2:Int = 0;
				while (_si2 < _arr.length) {
					final _t = _arr[_si2];
					_docs.push($triviaElemCall);
					_si2++;
				}
				anyparse.format.wrap.WrapList.emit(
					$v{openText}, $v{closeText}, $v{sepText},
					_docs, opt, _de(), _de(), false, $rulesExpr, $appendTrailingCommaExpr,
					$wrapLeadFlatDoc, $wrapLeadBreakDoc, $forceExceedsExpr
				);
			};
		} else {
			macro {
				final _flat:Array<anyparse.core.Doc> = [_dt($v{openText})];
				var _si2:Int = 0;
				while (_si2 < _arr.length) {
					if (_si2 > 0) {
						_flat.push(_dt($v{sepText}));
						_flat.push(_dt(' '));
					}
					final _t = _arr[_si2];
					_flat.push($triviaElemCall);
					_si2++;
				}
				_flat.push(_dt($v{closeText}));
				_dc(_flat);
			};
		};
		return macro {
			final _arr = $fieldAccess;
			final _trailLC:Array<String> = $trailLC;
			final _trailBB:Bool = $trailBB;
			final _trailClose:Null<String> = $trailClose;
			final _trailOpen:Null<String> = $trailOpen;
			// ω-open-trailing-alt: empty Star with only a same-line block-
			// style trail comment after the open lit (`[ /* foo */ ]`,
			// `{ /* nop */ }`) emits flat tight `[<comment>]`. Line-style
			// `_trailOpen` ALWAYS arrives with a source newline before the
			// close (`// …` would otherwise consume `]` as comment body),
			// so it falls through to the multi-line path. The block-style
			// gate also rules out the `[ /* foo */\n]` case — the source
			// newline lands in the loop's terminal `_lead`, but that path
			// has no element to attach to and currently degrades; if/when
			// we synth a "newlineBeforeClose" slot, this gate tightens.
			if (_arr.length == 0 && _trailLC.length == 0
					&& _trailOpen != null && StringTools.startsWith(_trailOpen, '/*')) {
				final _openDoc:anyparse.core.Doc = _dt(_trailOpen);
				if (_trailClose != null)
					_dc([_dt($v{openText}), _openDoc, _dt($v{closeText}), trailingCommentDocVerbatim(_trailClose, opt)]);
				else
					_dc([_dt($v{openText}), _openDoc, _dt($v{closeText})]);
			} else if (_arr.length == 0 && _trailLC.length == 0 && _trailOpen == null) {
				if (_trailClose != null) $emptyTrailExpr
				else _dt($v{emptyText});
			} else {
				var _hasTrivia:Bool = _trailLC.length > 0 || _trailOpen != null;
				var _ti:Int = 0;
				while (!_hasTrivia && _ti < _arr.length) {
					final _t = _arr[_ti];
					if (_t.newlineBefore || _t.blankBefore || _t.leadingComments.length > 0 || _t.trailingComment != null)
						_hasTrivia = true;
					_ti++;
				}
				if (_hasTrivia) {
					final _inner:Array<anyparse.core.Doc> = [];
					var _si:Int = 0;
					while (_si < _arr.length) {
						final _t = _arr[_si];
						_inner.push(_dhl());
						if (_t.blankBefore && _si > 0) _inner.push(_dhl());
						var _ci:Int = 0;
						while (_ci < _t.leadingComments.length) {
							_inner.push(leadingCommentDoc(_t.leadingComments[_ci], opt));
							_inner.push(_dhl());
							_ci++;
						}
						if (_t.blankAfterLeadingComments && _t.leadingComments.length > 0) _inner.push(_dhl());
						final _elem:anyparse.core.Doc = $triviaElemCall;
						var _line:anyparse.core.Doc = _elem;
						if (_si < _arr.length - 1 || $appendTrailingCommaExpr)
							_line = _dc([_line, _dt($v{sepText})]);
						final _tc:Null<String> = _t.trailingComment;
						if (_tc != null)
							_line = _dc([_line, trailingCommentDoc(_tc, opt)]);
						_inner.push(_line);
						_si++;
					}
					if (_trailLC.length > 0) {
						_inner.push(_dhl());
						if (_trailBB && _arr.length > 0) _inner.push(_dhl());
						var _tii:Int = 0;
						while (_tii < _trailLC.length) {
							_inner.push(leadingCommentDoc(_trailLC[_tii], opt));
							if (_tii < _trailLC.length - 1) _inner.push(_dhl());
							_tii++;
						}
					}
					final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
					final _innerWrap:anyparse.core.Doc = _dn(_cols, _dc(_inner));
					final _parts:Array<anyparse.core.Doc> = [];
					_parts.push($triviaLeadDoc);
					_parts.push(_dt($v{openText}));
					if (_trailOpen != null) _parts.push(trailingCommentDocVerbatim(_trailOpen, opt));
					_parts.push(_innerWrap);
					_parts.push(_dhl());
					_parts.push(_dt($v{closeText}));
					if (_trailClose != null)
						_parts.push(trailingCommentDocVerbatim(_trailClose, opt));
					_dbg(_dc(_parts));
				} else {
					$noTriviaBranch;
				}
			}
		};
	}

	/**
	 * Build the Doc expression for an EOF-mode trivia Star field
	 * (last field, no `@:trail`). Single hardline between elements
	 * instead of the plain mode's forced double hardline, with the extra
	 * hardline driven by each element's `blankBefore` flag. Leading
	 * comments emit above the element at the outer indent level;
	 * trailing comment attaches inline after.
	 */
	private static function triviaEofStarExpr(
		fieldAccess:Expr, trailBBAccess:Null<Expr>, trailLCAccess:Null<Expr>,
		elemFn:String, afterCtorInfos:Array<AfterCtorBlankInfo> = null,
		beforeCtorInfos:Array<BeforeCtorBlankInfo> = null
	):Expr {
		final triviaElemCall:Expr = {
			expr: ECall(macro $i{elemFn}, [macro _t.node, macro opt]),
			pos: Context.currentPos(),
		};
		final trailBB:Expr = trailBBAccess ?? macro false;
		final trailLC:Expr = trailLCAccess ?? macro ([] : Array<String>);
		final afterInfos:Array<AfterCtorBlankInfo> = afterCtorInfos ?? [];
		final beforeInfos:Array<BeforeCtorBlankInfo> = beforeCtorInfos ?? [];
		final pos:Position = Context.currentPos();
		// ω-after-package — when the previous element matches one of the
		// named ctors, the writer overrides the source-captured blank-
		// line count with `opt.<optField>` blank lines (matching haxe-
		// formatter's `emptyLines.afterPackage` count semantics — `1`
		// inserts one blank line even when the source had none, `0`
		// strips any blank line even when the source carried them).
		//
		// ω-imports-using-blank — symmetric "before-ctor" override: when
		// the current element matches one of the named ctors AND the
		// previous element does NOT match the same set, the writer
		// overrides the source-captured count with `opt.<optField>`
		// blank lines (drives the `import → using` transition). Cascade
		// order: afterCtor wins first, then beforeCtor, then source.
		// For all other element pairs the trivia channel's binary
		// `blankBefore` flag drives a single blank line as before.
		//
		// ω-after-typedecl — the after/before ctor knobs accept multiple
		// `@:fmt(blankLinesAfterCtor(...))` / `blankLinesBeforeCtor(...)`
		// entries on the same Star, each with its own ctor set and opt
		// field. Each entry produces an independent kind-tracker variable
		// (`_prevKindAfterN` / `_prevKindBeforeN`); the runtime cascade
		// runs them in source order — first afterInfos[0], then
		// afterInfos[1], …, then beforeInfos[0], …, then source-driven.
		// Knobs read from the source-order chain, so authors order the
		// entries from highest priority (afterPackage) downward.
		final initPrevKindExprs:Array<Expr> = [
			for (i in 0...afterInfos.length) {
				final name:String = '_prevKindAfter' + i;
				macro var $name:Int = 0;
			}
		];
		final initCurrKindExprs:Array<Expr> = [
			for (i in 0...afterInfos.length) {
				final name:String = '_currKindAfter' + i;
				macro var $name:Int = 0;
			}
		];
		final currKindComputeExprs:Array<Expr> = [
			for (i in 0...afterInfos.length) {
				final info:AfterCtorBlankInfo = afterInfos[i];
				final classifierAccess:Expr = {
					expr: EField(macro _t.node, info.classifierFieldName),
					pos: pos,
				};
				final switchExpr:Expr = {
					expr: ESwitch(classifierAccess, info.classifyCases, null),
					pos: pos,
				};
				final lhs:Expr = {expr: EConst(CIdent('_currKindAfter' + i)), pos: pos};
				macro $lhs = $switchExpr;
			}
		];
		final trackPrevKindExprs:Array<Expr> = [
			for (i in 0...afterInfos.length) {
				final lhs:Expr = {expr: EConst(CIdent('_prevKindAfter' + i)), pos: pos};
				final rhs:Expr = {expr: EConst(CIdent('_currKindAfter' + i)), pos: pos};
				macro $lhs = $rhs;
			}
		];
		final initPrevKindBeforeExprs:Array<Expr> = [
			for (i in 0...beforeInfos.length) {
				final name:String = '_prevKindBefore' + i;
				macro var $name:Int = 0;
			}
		];
		final initCurrKindBeforeExprs:Array<Expr> = [
			for (i in 0...beforeInfos.length) {
				final name:String = '_currKindBefore' + i;
				macro var $name:Int = 0;
			}
		];
		final currKindBeforeComputeExprs:Array<Expr> = [
			for (i in 0...beforeInfos.length) {
				final info:BeforeCtorBlankInfo = beforeInfos[i];
				final classifierAccess:Expr = {
					expr: EField(macro _t.node, info.classifierFieldName),
					pos: pos,
				};
				final switchExpr:Expr = {
					expr: ESwitch(classifierAccess, info.classifyCases, null),
					pos: pos,
				};
				final lhs:Expr = {expr: EConst(CIdent('_currKindBefore' + i)), pos: pos};
				macro $lhs = $switchExpr;
			}
		];
		final trackPrevKindBeforeExprs:Array<Expr> = [
			for (i in 0...beforeInfos.length) {
				final lhs:Expr = {expr: EConst(CIdent('_prevKindBefore' + i)), pos: pos};
				final rhs:Expr = {expr: EConst(CIdent('_currKindBefore' + i)), pos: pos};
				macro $lhs = $rhs;
			}
		];
		var blanksCountExpr:Expr = macro (_t.blankBefore ? 1 : 0);
		// Build cascade from innermost (source-driven) outward — beforeInfos
		// in reverse order first, then afterInfos in reverse order, so the
		// source-order priority lands as the outermost ternary check.
		for (i in 0...beforeInfos.length) {
			final idx:Int = beforeInfos.length - 1 - i;
			final info:BeforeCtorBlankInfo = beforeInfos[idx];
			final beforeAccess:Expr = {expr: EField(macro opt, info.optField), pos: pos};
			final currIdent:Expr = {expr: EConst(CIdent('_currKindBefore' + idx)), pos: pos};
			final prevIdent:Expr = {expr: EConst(CIdent('_prevKindBefore' + idx)), pos: pos};
			final fallback:Expr = blanksCountExpr;
			blanksCountExpr = macro ($currIdent == 1 && $prevIdent != 1 ? $beforeAccess : $fallback);
		}
		for (i in 0...afterInfos.length) {
			final idx:Int = afterInfos.length - 1 - i;
			final info:AfterCtorBlankInfo = afterInfos[idx];
			final afterAccess:Expr = {expr: EField(macro opt, info.optField), pos: pos};
			final prevIdent:Expr = {expr: EConst(CIdent('_prevKindAfter' + idx)), pos: pos};
			final fallback:Expr = blanksCountExpr;
			blanksCountExpr = macro ($prevIdent == 1 ? $afterAccess : $fallback);
		}
		// Flatten the per-info var/compute/track exprs into the outer
		// scope to avoid nested-EBlock isolation (skill: $b{} / EBlock
		// creates a new scope, vars don't leak to siblings). The while
		// body is built as a flat Array<Expr> too: `_currKindAfterN`
		// / `_prevKindAfterN` ident references inside `$blanksCountExpr`
		// must resolve against the same lexical block that declares them.
		final whileBodyParts:Array<Expr> = [];
		whileBodyParts.push(macro final _t = _arr[_si]);
		for (e in initCurrKindExprs) whileBodyParts.push(e);
		for (e in currKindComputeExprs) whileBodyParts.push(e);
		for (e in initCurrKindBeforeExprs) whileBodyParts.push(e);
		for (e in currKindBeforeComputeExprs) whileBodyParts.push(e);
		whileBodyParts.push(macro if (_si > 0) {
			_docs.push(_dhl());
			final _blanks:Int = $blanksCountExpr;
			var _bli:Int = 0;
			while (_bli < _blanks) {
				_docs.push(_dhl());
				_bli++;
			}
		});
		whileBodyParts.push(macro {
			var _ci:Int = 0;
			while (_ci < _t.leadingComments.length) {
				_docs.push(leadingCommentDoc(_t.leadingComments[_ci], opt));
				_docs.push(_dhl());
				_ci++;
			}
		});
		whileBodyParts.push(macro if (_t.blankAfterLeadingComments && _t.leadingComments.length > 0) _docs.push(_dhl()));
		whileBodyParts.push(macro final _elem:anyparse.core.Doc = $triviaElemCall);
		whileBodyParts.push(macro final _tc:Null<String> = _t.trailingComment);
		whileBodyParts.push(macro _docs.push(_tc != null ? foldTrailingIntoBodyGroup(_elem, trailingCommentDoc(_tc, opt)) : _elem));
		for (e in trackPrevKindExprs) whileBodyParts.push(e);
		for (e in trackPrevKindBeforeExprs) whileBodyParts.push(e);
		whileBodyParts.push(macro _si++);
		final whileBodyBlock:Expr = {expr: EBlock(whileBodyParts), pos: pos};
		final whileExpr:Expr = {
			expr: EWhile(macro _si < _arr.length, whileBodyBlock, true),
			pos: pos,
		};
		final elseBodyParts:Array<Expr> = [];
		elseBodyParts.push(macro final _docs:Array<anyparse.core.Doc> = []);
		for (e in initPrevKindExprs) elseBodyParts.push(e);
		for (e in initPrevKindBeforeExprs) elseBodyParts.push(e);
		elseBodyParts.push(macro var _si:Int = 0);
		elseBodyParts.push(whileExpr);
		elseBodyParts.push(macro if (_trailLC.length > 0) {
			if (_arr.length > 0) _docs.push(_dhl());
			if (_trailBB && _arr.length > 0) _docs.push(_dhl());
			var _ti:Int = 0;
			while (_ti < _trailLC.length) {
				_docs.push(leadingCommentDoc(_trailLC[_ti], opt));
				if (_ti < _trailLC.length - 1) _docs.push(_dhl());
				_ti++;
			}
		});
		elseBodyParts.push(macro _dc(_docs));
		final elseBody:Expr = {expr: EBlock(elseBodyParts), pos: pos};
		return macro {
			final _arr = $fieldAccess;
			final _trailLC:Array<String> = $trailLC;
			final _trailBB:Bool = $trailBB;
			if (_arr.length == 0 && _trailLC.length == 0) _de()
			else $elseBody;
		};
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
	 */
	private static function triviaTryparseStarExpr(
		fieldAccess:Expr, elemFn:String, sepExpr:Expr,
		sepBeforeFirst:Bool, nestBody:Bool,
		trailBBAccess:Null<Expr>, trailLCAccess:Null<Expr>, trailBAAccess:Null<Expr>,
		firstSepOverride:Null<Expr> = null,
		subsequentSepOverride:Null<Expr> = null,
		caseBodyFlagNames:Null<Array<String>> = null,
		flatChildOptPairs:Null<Array<Array<String>>> = null
	):Expr {
		// ω-expression-case-flat-fanout: when the body's element call should
		// receive a copy-on-flat opt with named fields swapped, build the
		// per-pair override block. The caller-side helper has already parsed
		// `'from=to'` args into [from, to] pairs.
		final triviaElemCall:Expr = {
			expr: ECall(macro $i{elemFn}, [macro _t.node, macro _writerOpt]),
			pos: Context.currentPos(),
		};
		final sepBeforeFirstExpr:Expr = macro $v{sepBeforeFirst};
		final nestBodyExpr:Expr = macro $v{nestBody};
		final trailBB:Expr = trailBBAccess ?? macro false;
		final trailLC:Expr = trailLCAccess ?? macro ([] : Array<String>);
		// ω-trail-blank-after: source had a blank line between the stashed
		// orphan trail comment and the next outer-Star sibling. Emit an
		// extra hardline at the end of `_trailDocs` so the gap survives
		// round-trip. Null when slot is absent (non-tryparse-or-non-nestBody
		// callers); falls back to `false` like trailBB.
		final trailBA:Expr = trailBAAccess ?? macro false;
		// ω-close-trailing-alt: the FIRST element's separator picks
		// `firstSepOverride` (a runtime switch on the prev body's ctor)
		// when supplied; otherwise it falls back to `sepExpr` like
		// every subsequent iteration. Subsequent elements use
		// `subsequentSepOverride` when supplied (ω-block-shape-aware:
		// switch on prev element's body ctor) — closeTrailing was a
		// property of the prev STRUCT FIELD only, but block-shape-
		// awareness applies symmetrically across the chain (each catch
		// follows another body whose shape decides `} catch` inline vs
		// `\ncatch`).
		final firstSepExpr:Expr = firstSepOverride ?? sepExpr;
		final subsequentSepExpr:Expr = subsequentSepOverride ?? sepExpr;
		// ω-case-body-policy / ω-case-body-keep: when the Star carries
		// `@:fmt(bodyPolicy('flag1', 'flag2', ...))`, build a runtime
		// gate over `opt.<flag>` for the named flags. Two predicates
		// are ORed across every flag:
		//  - `Same`: ANY flag set to `BodyPolicy.Same` flattens
		//    unconditionally — author's source shape is overridden.
		//  - `Keep`: ANY flag set to `BodyPolicy.Keep` flattens IFF the
		//    captured body's first element has no preceding source
		//    newline (`!_arr[0].newlineBefore`). This preserves the
		//    author's per-instance choice between `case X: foo();` and
		//    `case X:\n\tfoo();`.
		// `_arr[0]` access is safe here because the outer `_flatCase`
		// short-circuits via `_arr.length == 1` BEFORE this gate runs.
		// `Next` and `FitLine` (default for both flags) leave the gate
		// `false` — the wrap stays at its multiline shape.
		final flatGateExpr:Expr = if (caseBodyFlagNames == null || caseBodyFlagNames.length == 0)
			macro false;
		else {
			final samePat:Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BodyPolicy', 'Same']);
			final keepPat:Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BodyPolicy', 'Keep']);
			var sameAcc:Null<Expr> = null;
			var keepAcc:Null<Expr> = null;
			for (flag in caseBodyFlagNames) {
				final optFlag:Expr = {expr: EField(macro opt, flag), pos: Context.currentPos()};
				final sameCmp:Expr = macro $optFlag == $samePat;
				final keepCmp:Expr = macro $optFlag == $keepPat;
				sameAcc = sameAcc == null ? sameCmp : macro $sameAcc || $sameCmp;
				keepAcc = keepAcc == null ? keepCmp : macro $keepAcc || $keepCmp;
			}
			macro ($sameAcc || ($keepAcc && !_arr[0].newlineBefore));
		};
		// ω-expression-case-flat-fanout: when `flatChildOptPairs` is non-empty,
		// the `_writerOpt` emitted into the runtime block is a `Reflect.copy(opt)`
		// + per-pair field override on the flat path, falling back to `opt`
		// itself everywhere else. The triviaElemCall reads `_writerOpt` so the
		// child writer sees the swapped knobs (statement-position
		// `ifBody`/`elseBody`/`forBody` → expression-position counterparts) and
		// propagates them through subsequent recursive calls. Default is plain
		// `opt` (no copy) — non-flat-fanout consumers stay byte-identical.
		final writerOptExpr:Expr = if (flatChildOptPairs == null || flatChildOptPairs.length == 0)
			macro opt;
		else {
			final block:Array<Expr> = [macro final _wo = _copyOpt(opt)];
			for (pair in flatChildOptPairs) {
				final fromAccess:Expr = {expr: EField(macro _wo, pair[0]), pos: Context.currentPos()};
				final toAccess:Expr = {expr: EField(macro opt, pair[1]), pos: Context.currentPos()};
				block.push(macro $fromAccess = $toAccess);
			}
			block.push(macro _wo);
			final overrideBlock:Expr = {expr: EBlock(block), pos: Context.currentPos()};
			macro (_flatCase ? $overrideBlock : opt);
		};
		return macro {
			final _arr = $fieldAccess;
			final _trailLC:Array<String> = $trailLC;
			final _trailBB:Bool = $trailBB;
			final _trailBA:Bool = $trailBA;
			final _sepFirst:Bool = $sepBeforeFirstExpr;
			final _nestBody:Bool = $nestBodyExpr;
			final _flatCase:Bool = _nestBody
				&& _arr.length == 1
				&& _trailLC.length == 0
				&& _arr[0].leadingComments.length == 0
				&& $flatGateExpr;
			final _writerOpt = $writerOptExpr;
			if (_arr.length == 0 && _trailLC.length == 0) _de() else {
				final _docs:Array<anyparse.core.Doc> = [];
				var _si:Int = 0;
				while (_si < _arr.length) {
					final _t = _arr[_si];
					if (_t.leadingComments.length > 0) {
						_docs.push(_dhl());
						if (_t.blankBefore && _si > 0) _docs.push(_dhl());
						var _ci:Int = 0;
						while (_ci < _t.leadingComments.length) {
							_docs.push(leadingCommentDoc(_t.leadingComments[_ci], opt));
							_docs.push(_dhl());
							_ci++;
						}
						if (_t.blankAfterLeadingComments) _docs.push(_dhl());
					} else if (_flatCase) {
						_docs.push(_dt(' '));
					} else if (_nestBody) {
						_docs.push(_dhl());
					} else if (_si > 0 && _t.newlineBefore) {
						// ω-cond-mod-newline: preserve a single source newline
						// between try-parse Star elements. Without this, the
						// default `sepExpr` (space) would collapse
						// `#if COND <mods> #end\n\tpublic` (issue_332 V1) down
						// to `#if COND <mods> #end public` on round-trip,
						// losing the author's modifier-list line break.
						// `blankBefore` adds the second hardline for source
						// gaps of two or more newlines.
						_docs.push(_dhl());
						if (_t.blankBefore) _docs.push(_dhl());
					} else if (_si > 0) {
						_docs.push($subsequentSepExpr);
					} else if (_sepFirst) {
						_docs.push($firstSepExpr);
					}
					final _elem:anyparse.core.Doc = $triviaElemCall;
					final _tc:Null<String> = _t.trailingComment;
					_docs.push(_tc != null ? foldTrailingIntoBodyGroup(_elem, trailingCommentDoc(_tc, opt)) : _elem);
					_si++;
				}
				// Trail comments collected into a separate Doc array so the
				// nestBody branch can render them at parent indent when the
				// body has stmts (issue_392): a `// comment` on its own line
				// between case body's last stmt and the next `case` label
				// belongs at case-label level, not case-body level. Empty-
				// body cases (only-comment) keep body-level indent — the
				// trail concat fold below restores that path.
				final _trailDocs:Array<anyparse.core.Doc> = [];
				if (_trailLC.length > 0) {
					var _ti:Int = 0;
					while (_ti < _trailLC.length) {
						_trailDocs.push(_dhl());
						if (_trailBB && _ti == 0 && _arr.length > 0) _trailDocs.push(_dhl());
						_trailDocs.push(leadingCommentDoc(_trailLC[_ti], opt));
						_ti++;
					}
					// ω-trail-blank-after: source had a blank line between this
					// trail comment and the next outer-Star sibling (e.g. case
					// label). Append an extra hardline at trail's tail; the
					// outer Star will then add its own element-leading hardline
					// for a true blank-line separator. Trailing whitespace on
					// the empty line is trimmed by the renderer (default).
					if (_trailBA) _trailDocs.push(_dhl());
				}
				final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
				if (_flatCase) {
					// ω-flat-case-wrap-indent: when bodyPolicy flattens the
					// case body inline (`case X: foo({...});`) but the body
					// breaks at render time (e.g. call-args wrap-rules fire),
					// the broken lines need +1 continuation indent relative
					// to the case-label line — matching haxe-formatter's
					// expressionCase=same/keep behavior. Wrapping the body
					// Doc in `_dn(_cols, ...)` is a no-op in the flat path
					// (no \n inside the body) and applies +1 indent on every
					// inner newline when the body wraps. Issue_121 fixtures.
					_dn(_cols, _dc(_docs));
				} else if (_nestBody) {
					if (_arr.length > 0 && _trailDocs.length > 0) {
						_dc([_dn(_cols, _dc(_docs)), _dc(_trailDocs)]);
					} else {
						for (_d in _trailDocs) _docs.push(_d);
						_dn(_cols, _dc(_docs));
					}
				} else {
					for (_d in _trailDocs) _docs.push(_d);
					_dc(_docs);
				}
			}
		};
	}

	/** Build `_dc([elem1, elem2, ...])` from a macro-time array of Exprs. */
	private static function dcCall(parts:Array<Expr>):Expr {
		final arr:Expr = {expr: EArrayDecl(parts), pos: Context.currentPos()};
		return macro _dc($arr);
	}

	private static function makeWriteCall(writeFnName:String, valueExpr:Expr, hasPratt:Bool, ctxPrec:Int):Expr {
		final args:Array<Expr> = [valueExpr, macro opt];
		if (hasPratt) args.push(macro $v{ctxPrec});
		return {
			expr: ECall(macro $i{writeFnName}, args),
			pos: Context.currentPos(),
		};
	}

	private static function getOperatorText(branch:ShapeNode):String {
		return (branch.annotations.get('pratt.op') : Null<String>) ?? branch.annotations.get('ternary.op');
	}

	private static function hasPrattBranch(node:ShapeNode):Bool {
		for (branch in node.children)
			if (branch.annotations.get('pratt.prec') != null || branch.annotations.get('ternary.op') != null) return true;
		return false;
	}

	private static function hasPostfixBranch(node:ShapeNode):Bool {
		for (branch in node.children) if (branch.annotations.get('postfix.op') != null) return true;
		return false;
	}

	/**
	 * Wraps the trail-literal emission for a `@:trailOpt(...)` ctor in a
	 * runtime-conditional `_de() / _dt(trail)` switch driven by a plugin-
	 * supplied AST shape predicate. Activates only when the branch carries
	 * both `lit.trailOptional=true` and `@:fmt(trailOptShapeGate('<adapter>',
	 * '<argFieldPath>'))`. Returns `null` when either condition is absent
	 * so the caller falls back to the unconditional `_dt(trail)` emission.
	 *
	 * `argFieldPath` is a dot-separated chain rooted at `argNames[0]` (the
	 * single Ref-arg name in Case 3). For Haxe's `VarStmt(decl:HxVarDecl)`
	 * the path is `init` — the optional initializer field on `HxVarDecl`.
	 * Plain mode reads `_v0.init:Null<HxExpr>`; trivia mode reads
	 * `_v0.init:Null<Trivial<HxExpr>>` — same field name, the plugin
	 * adapter unwraps the wrapper internally.
	 */
	private static function trailOptShapeGateWrap(branch:ShapeNode, trailText:String, rootArg:String):Null<Expr> {
		final trailOptional:Bool = branch.annotations.get('lit.trailOptional') == true;
		if (!trailOptional) return null;
		final args:Null<Array<String>> = branch.fmtReadStringArgs('trailOptShapeGate');
		if (args == null || args.length != 2) return null;
		final adapterName:String = args[0];
		final argPath:String = args[1];
		var pathExpr:Expr = macro $i{rootArg};
		for (segment in argPath.split('.'))
			pathExpr = {expr: EField(pathExpr, segment), pos: Context.currentPos()};
		final adapterExpr:Expr = {expr: EField(macro opt, adapterName), pos: Context.currentPos()};
		return macro {
			final _gateRaw:Null<Dynamic> = $pathExpr;
			final _gateFn:Null<Dynamic -> Bool> = $adapterExpr;
			(_gateFn != null && _gateRaw != null && _gateFn(_gateRaw)) ? _de() : _dt($v{trailText});
		};
	}

	private static function simpleName(typePath:String):String {
		final idx:Int = typePath.lastIndexOf('.');
		return idx == -1 ? typePath : typePath.substring(idx + 1);
	}

	private static function packOf(typePath:String):Array<String> {
		final idx:Int = typePath.lastIndexOf('.');
		return idx == -1 ? [] : typePath.substring(0, idx).split('.');
	}

	// -------- trivia-mode helpers (ω₅) --------

	/**
	 * True when `ctx.trivia` is active AND the rule at `refName` carries
	 * `trivia.bearing=true`. The rule-lookup guard returns false for
	 * non-grammar refs (format primitives the Writer still expects to
	 * call through their plain `writeXxx` functions).
	 */
	private function isTriviaBearing(refName:String):Bool {
		if (!ctx.trivia) return false;
		final node:Null<ShapeNode> = shape.rules.get(refName);
		if (node == null) return false;
		return node.annotations.get('trivia.bearing') == true;
	}

	/** `write<name>T` when trivia-bearing, else `write<name>` — every ref fn-name site goes through this. */
	private function writeFnFor(refName:String):String {
		final simple:String = simpleName(refName);
		return isTriviaBearing(refName) ? 'write${simple}T' : 'write$simple';
	}

	/** Paired `*T` ComplexType in the synth module for bearing rules; plain TPath otherwise. */
	private function ruleValueCT(refName:String):ComplexType {
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

	/**
	 * ω-interblank — resolve the `@:fmt(interMemberBlankLines(fieldName,
	 * varCtor, fnCtor))` meta into the classify-switch shape that
	 * `triviaBlockStarExpr` splices into its per-element loop.
	 *
	 * Inspects the element Seq rule's named field to locate the
	 * classifier enum rule, then builds one `case <Ctor>(_):` pattern
	 * per variant in that enum, mapping the configured `varCtor` name to
	 * kind `1`, `fnCtor` to kind `2`, and every other variant to kind
	 * `0`. Iterating every variant (instead of emitting a wildcard
	 * default) keeps the switch exhaustive without relying on Haxe's
	 * unused-pattern warnings for the single-grammar two-variant case.
	 */
	private function buildInterMemberClassifyInfo(elemRefName:String, args:Array<String>):InterMemberClassifyInfo {
		if (args.length != 3 && args.length != 6)
			Context.fatalError(
				'WriterLowering: @:fmt(interMemberBlankLines) expects 3 or 6 string args (classifierField, varCtor, fnCtor [, betweenVarsField, betweenFunctionsField, afterVarsField]), got ${args.length}',
				Context.currentPos()
			);
		final fieldName:String = args[0];
		final varCtor:String = args[1];
		final fnCtor:String = args[2];
		final betweenVarsField:String = args.length == 6 ? args[3] : 'betweenVars';
		final betweenFunctionsField:String = args.length == 6 ? args[4] : 'betweenFunctions';
		final afterVarsField:String = args.length == 6 ? args[5] : 'afterVars';
		final elemRule:Null<ShapeNode> = shape.rules.get(elemRefName);
		if (elemRule == null || elemRule.kind != Seq)
			Context.fatalError(
				'WriterLowering: @:fmt(interMemberBlankLines) requires element rule $elemRefName to be a Seq struct',
				Context.currentPos()
			);
		var classifierNode:Null<ShapeNode> = null;
		for (child in elemRule.children) if (child.annotations.get('base.fieldName') == fieldName) {
			classifierNode = child;
			break;
		}
		if (classifierNode == null)
			Context.fatalError(
				'WriterLowering: @:fmt(interMemberBlankLines) classifier field "$fieldName" not found on element rule $elemRefName',
				Context.currentPos()
			);
		if (classifierNode.kind != Ref)
			Context.fatalError(
				'WriterLowering: @:fmt(interMemberBlankLines) classifier field "$fieldName" must be a plain Ref to an enum rule',
				Context.currentPos()
			);
		final enumRuleName:Null<String> = classifierNode.annotations.get('base.ref');
		if (enumRuleName == null)
			Context.fatalError(
				'WriterLowering: @:fmt(interMemberBlankLines) classifier field "$fieldName" has no base.ref annotation',
				Context.currentPos()
			);
		final enumRule:Null<ShapeNode> = shape.rules.get(enumRuleName);
		if (enumRule == null || enumRule.kind != Alt)
			Context.fatalError(
				'WriterLowering: @:fmt(interMemberBlankLines) classifier target $enumRuleName must be an Alt (enum)',
				Context.currentPos()
			);
		final pos:Position = Context.currentPos();
		final cases:Array<Case> = [];
		for (branch in enumRule.children) {
			final ctorName:Null<String> = branch.annotations.get('base.ctor');
			if (ctorName == null) continue;
			final arity:Int = branch.children.length;
			final ctorIdent:Expr = {expr: EConst(CIdent(ctorName)), pos: pos};
			final pattern:Expr = arity == 0
				? ctorIdent
				: {expr: ECall(ctorIdent, [for (_ in 0...arity) macro _]), pos: pos};
			final kindExpr:Expr = if (ctorName == varCtor) macro 1;
				else if (ctorName == fnCtor) macro 2;
				else macro 0;
			cases.push({values: [pattern], guard: null, expr: kindExpr});
		}
		return {
			classifierFieldName: fieldName,
			classifyCases: cases,
			betweenVarsField: betweenVarsField,
			betweenFunctionsField: betweenFunctionsField,
			afterVarsField: afterVarsField,
		};
	}

	/**
	 * ω-after-package — resolve `@:fmt(blankLinesAfterCtor(classifierField,
	 * CtorName1, [CtorName2, …], optField))` into a binary classify-switch
	 * (`1` for any matching ctor, `0` otherwise) plus the option-field
	 * name read at runtime to pick the forced-minimum blank-line count.
	 *
	 * Mirrors `buildInterMemberClassifyInfo` but with arity ≥ 3
	 * (classifierField, ≥ 1 ctor name, optField) and a single-axis
	 * yes/no classification instead of var/fn/other. Reusable for any
	 * "blank line after ctor X" slice — the args list defines which
	 * ctors trigger and which `HxModuleWriteOptions` Int field is
	 * consulted.
	 */
	private function buildAfterCtorBlankInfo(elemRefName:String, args:Array<String>, predicateAdapter:Null<String>):AfterCtorBlankInfo {
		final r:CtorBlankResolution = resolveCtorBlankArgs(elemRefName, args, 'blankLinesAfterCtor', predicateAdapter);
		return {
			classifierFieldName: r.fieldName,
			classifyCases: r.cases,
			optField: r.optField,
		};
	}

	/**
	 * ω-after-multiline — predicate-gated variant of
	 * `buildAfterCtorBlankInfo`. Args shape: `(classifierField,
	 * predicateAdapter, CtorName1, …, optField)`. The runtime kind-=1
	 * path runs `opt.<predicateAdapter>(_t.node)` after the ctor match
	 * succeeds; kind stays `0` when the adapter returns false (or when
	 * the adapter field on `opt` is null). Lets a single ctor set fire
	 * a blank-line override only on shape-relevant elements (e.g.
	 * "blank line around any multi-line type decl") instead of bare
	 * ctor name (which would force the blank around empty-body decls
	 * too — the previously regressed `class C<T> {}` case).
	 */
	private function buildAfterCtorBlankInfoIf(elemRefName:String, args:Array<String>):AfterCtorBlankInfo {
		if (args.length < 4)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesAfterCtorIf) expects ≥ 4 string args (classifierField, predicateAdapter, CtorName1, [CtorName2, …], optField), got ${args.length}',
				Context.currentPos()
			);
		final reduced:Array<String> = [args[0]].concat(args.slice(2));
		final r:CtorBlankResolution = resolveCtorBlankArgs(elemRefName, reduced, 'blankLinesAfterCtorIf', args[1]);
		return {
			classifierFieldName: r.fieldName,
			classifyCases: r.cases,
			optField: r.optField,
		};
	}

	/**
	 * ω-imports-using-blank — resolve `@:fmt(blankLinesBeforeCtor(classifierField,
	 * CtorName1, [CtorName2, …], optField))` — symmetric mirror of
	 * `buildAfterCtorBlankInfo`. Same arity (≥ 3 string args), same
	 * single-axis yes/no classification on the named ctors. The runtime
	 * gate (in `triviaEofStarExpr`) fires when the CURRENT element matches
	 * AND the previous element did NOT match the same set, driving
	 * "blank line before first X group" semantics (e.g. `import → using`
	 * transition) independently of the after-ctor knob.
	 */
	private function buildBeforeCtorBlankInfo(elemRefName:String, args:Array<String>, predicateAdapter:Null<String>):BeforeCtorBlankInfo {
		final r:CtorBlankResolution = resolveCtorBlankArgs(elemRefName, args, 'blankLinesBeforeCtor', predicateAdapter);
		return {
			classifierFieldName: r.fieldName,
			classifyCases: r.cases,
			optField: r.optField,
		};
	}

	/**
	 * Predicate-gated variant of `buildBeforeCtorBlankInfo`. Same arg
	 * shape and adapter semantics as `buildAfterCtorBlankInfoIf` — the
	 * runtime gate at consumption keeps the existing "curr matches AND
	 * prev did NOT match" semantics, so the predicate-gated kind feeds
	 * both sides of the comparison. A single decl pair is governed by
	 * at most one override, and the cascade still picks after-ctor
	 * entries before before-ctor entries.
	 */
	private function buildBeforeCtorBlankInfoIf(elemRefName:String, args:Array<String>):BeforeCtorBlankInfo {
		if (args.length < 4)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBeforeCtorIf) expects ≥ 4 string args (classifierField, predicateAdapter, CtorName1, [CtorName2, …], optField), got ${args.length}',
				Context.currentPos()
			);
		final reduced:Array<String> = [args[0]].concat(args.slice(2));
		final r:CtorBlankResolution = resolveCtorBlankArgs(elemRefName, reduced, 'blankLinesBeforeCtorIf', args[1]);
		return {
			classifierFieldName: r.fieldName,
			classifyCases: r.cases,
			optField: r.optField,
		};
	}

	/**
	 * Shared resolver for `@:fmt(blankLinesAfterCtor(...))` and
	 * `@:fmt(blankLinesBeforeCtor(...))` — both metas accept the same
	 * `(classifierField, CtorName1, …, optField)` arg shape and produce
	 * the same single-axis classify-switch (`1` for any matching ctor,
	 * `0` otherwise) plus an opt-field name. The two metas diverge only
	 * at runtime: after-ctor consults the previous element's kind,
	 * before-ctor consults the current element's kind paired with a
	 * `prev != curr` gate. Centralising the parse/validation here keeps
	 * both knobs in sync on shape-validation messages and the classifier
	 * lookup path.
	 */
	private function resolveCtorBlankArgs(elemRefName:String, args:Array<String>, metaName:String, predicateName:Null<String>):CtorBlankResolution {
		if (args.length < 3)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) expects ≥ 3 string args (classifierField, CtorName1, [CtorName2, …], optField), got ${args.length}',
				Context.currentPos()
			);
		final fieldName:String = args[0];
		final optField:String = args[args.length - 1];
		final ctorNames:Array<String> = args.slice(1, args.length - 1);
		if (ctorNames.length == 0)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) requires at least one ctor name between the classifier field and the opt field',
				Context.currentPos()
			);
		final elemRule:Null<ShapeNode> = shape.rules.get(elemRefName);
		if (elemRule == null || elemRule.kind != Seq)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) requires element rule $elemRefName to be a Seq struct',
				Context.currentPos()
			);
		final classifierNode:Null<ShapeNode> = Lambda.find(elemRule.children, c -> c.annotations.get('base.fieldName') == fieldName);
		if (classifierNode == null)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) classifier field "$fieldName" not found on element rule $elemRefName',
				Context.currentPos()
			);
		if (classifierNode.kind != Ref)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) classifier field "$fieldName" must be a plain Ref to an enum rule',
				Context.currentPos()
			);
		final enumRuleName:Null<String> = classifierNode.annotations.get('base.ref');
		if (enumRuleName == null)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) classifier field "$fieldName" has no base.ref annotation',
				Context.currentPos()
			);
		final enumRule:Null<ShapeNode> = shape.rules.get(enumRuleName);
		if (enumRule == null || enumRule.kind != Alt)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) classifier target $enumRuleName must be an Alt (enum)',
				Context.currentPos()
			);
		final pos:Position = Context.currentPos();
		final cases:Array<Case> = [];
		final matched:Array<String> = [];
		for (branch in enumRule.children) {
			final ctorName:Null<String> = branch.annotations.get('base.ctor');
			if (ctorName == null) continue;
			final arity:Int = branch.children.length;
			final ctorIdent:Expr = {expr: EConst(CIdent(ctorName)), pos: pos};
			final pattern:Expr = arity == 0
				? ctorIdent
				: {expr: ECall(ctorIdent, [for (_ in 0...arity) macro _]), pos: pos};
			final isMatch:Bool = ctorNames.indexOf(ctorName) >= 0;
			if (isMatch) matched.push(ctorName);
			final kindExpr:Expr = if (!isMatch) macro 0;
				else if (predicateName == null) macro 1;
				else buildPredicateGatedKind(branch, ctorName, predicateName, metaName, enumRuleName);
			// When a predicate gate is active, the case pattern must bind the
			// first arg as `_v0` so the predicate can reference it. Plain
			// (non-predicated) and zero-arg ctors keep the original wildcard
			// pattern.
			final patternFinal:Expr = if (isMatch && predicateName != null && arity >= 1) {
				final binders:Array<Expr> = [];
				for (i in 0...arity) binders.push(i == 0 ? macro _v0 : macro _);
				{expr: ECall(ctorIdent, binders), pos: pos};
			} else pattern;
			cases.push({values: [patternFinal], guard: null, expr: kindExpr});
		}
		for (name in ctorNames) if (matched.indexOf(name) < 0)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) ctor "$name" not found in enum $enumRuleName',
				Context.currentPos()
			);
		return {
			fieldName: fieldName,
			cases: cases,
			optField: optField,
		};
	}

	/**
	 * ω-after-multiline — build the kind-=1 case body for a
	 * predicate-gated `blankLines{After,Before}CtorIf` ctor match.
	 * `predicateName` is currently only `'multiline'`; resolves to a
	 * grammar-derived structural check via `buildMultilinePredicate`
	 * applied to the ctor's first arg (bound as `_v0` in the case
	 * pattern). Returns `macro 0` when the ctor's payload type carries
	 * no relevant `@:fmt(multilineWhen...)` meta, so adding new ctors to
	 * the gated set without tagging their target type silently keeps
	 * them at kind=0 (same as the bare ctor not being in the set).
	 *
	 * Recursive design: `multilineWhenFieldNonEmpty(<arrayField>)` on a
	 * struct typedef → `_v0.<field>.length > 0`.
	 * `multilineWhenFieldShape(<refField>)` → recurse into the field's
	 * target type's predicate. On enum types, switch over each ctor
	 * and apply `multilineCtor`-tagged ctor's arg-type predicate;
	 * untagged ctors emit `false`.
	 */
	private function buildPredicateGatedKind(branch:ShapeNode, ctorName:String, predicateName:String, metaName:String, enumRuleName:String):Expr {
		if (predicateName != 'multiline')
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) predicate "$predicateName" is not registered (currently only "multiline" is supported)',
				Context.currentPos()
			);
		if (branch.children.length == 0) return macro 0;
		final argNode:ShapeNode = branch.children[0];
		final argTypeName:Null<String> = argNode.annotations.get('base.ref');
		if (argTypeName == null) return macro 0;
		final pred:Null<Expr> = buildMultilinePredicate(argTypeName, macro _v0);
		return pred == null ? macro 0 : macro $pred ? 1 : 0;
	}

	/**
	 * ω-after-multiline — recursively build the multi-line predicate
	 * for `typeName` applied to `accessExpr`. Returns `null` when the
	 * type carries no multi-line meta — caller substitutes `macro 0`
	 * (or `macro false`).
	 *
	 * Reads three `@:fmt(...)` flag forms from the grammar shape:
	 *  - typedef-level `multilineWhenFieldNonEmpty('field')` →
	 *    `accessExpr.field.length > 0`. Used when the type's multi-line
	 *    nature is determined by a Star field's emptiness (Class /
	 *    Iface / Abstract members, EnumDecl ctors, FnBlock stmts).
	 *  - typedef-level `multilineWhenFieldShape('field')` → recurse
	 *    into the named field's target type, applied to
	 *    `accessExpr.field`. Used when the type defers its multi-line
	 *    decision to a sub-rule (HxFnDecl → body).
	 *  - ctor-level `multilineCtor` (on enum branches) → switch over
	 *    every ctor of the enum; the tagged ctor binds its first arg
	 *    and recurses into the arg's type predicate; untagged ctors
	 *    emit `false`. Used for enum types whose multi-line nature
	 *    depends on which variant is present (HxFnBody → BlockBody
	 *    multi-line iff its block is, NoBody / ExprBody never).
	 */
	private function buildMultilinePredicate(typeName:String, accessExpr:Expr):Null<Expr> {
		final node:Null<ShapeNode> = shape.rules.get(typeName);
		if (node == null) return null;
		final pos:Position = Context.currentPos();
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta != null) {
			for (entry in meta) if (entry.name == ':fmt') {
				for (param in entry.params) switch param.expr {
					case ECall({expr: EConst(CIdent('multilineWhenFieldNonEmpty'))}, [{expr: EConst(CString(field, _))}]):
						final fieldExpr:Expr = {expr: EField(accessExpr, field), pos: pos};
						return macro $fieldExpr.length > 0;
					case ECall({expr: EConst(CIdent('multilineWhenFieldShape'))}, [{expr: EConst(CString(field, _))}]):
						final fieldNode:Null<ShapeNode> = findFieldByName(node, field);
						if (fieldNode == null)
							Context.fatalError(
								'WriterLowering: @:fmt(multilineWhenFieldShape) field "$field" not found on $typeName',
								Context.currentPos()
							);
						final targetType:Null<String> = fieldNode.annotations.get('base.ref');
						if (targetType == null) return null;
						final fieldExpr:Expr = {expr: EField(accessExpr, field), pos: pos};
						return buildMultilinePredicate(targetType, fieldExpr);
					case _:
				}
			}
		}
		// Enum dispatch: switch over each ctor's `multilineCtor` flag.
		if (node.kind == Alt) {
			final cases:Array<Case> = [];
			var anyTagged:Bool = false;
			for (branch in node.children) {
				final ctorName:Null<String> = branch.annotations.get('base.ctor');
				if (ctorName == null) continue;
				final arity:Int = branch.children.length;
				final ctorIdent:Expr = {expr: EConst(CIdent(ctorName)), pos: pos};
				final tagged:Bool = ctorBranchHasFlag(branch, 'multilineCtor');
				final pattern:Expr = if (tagged && arity >= 1) {
					final binders:Array<Expr> = [];
					for (i in 0...arity) binders.push(i == 0 ? macro _v : macro _);
					{expr: ECall(ctorIdent, binders), pos: pos};
				} else if (arity == 0) {
					ctorIdent;
				} else {
					{expr: ECall(ctorIdent, [for (_ in 0...arity) macro _]), pos: pos};
				};
				final body:Expr = if (!tagged) macro false;
				else {
					anyTagged = true;
					final argNode:ShapeNode = branch.children[0];
					final argTypeName:Null<String> = argNode.annotations.get('base.ref');
					final inner:Null<Expr> = argTypeName == null ? null : buildMultilinePredicate(argTypeName, macro _v);
					inner ?? macro false;
				};
				cases.push({values: [pattern], guard: null, expr: body});
			}
			if (!anyTagged) return null;
			return {expr: ESwitch(accessExpr, cases, null), pos: pos};
		}
		return null;
	}

	private static function findFieldByName(node:ShapeNode, name:String):Null<ShapeNode> {
		for (child in node.children) if (child.annotations.get('base.fieldName') == name) return child;
		return null;
	}

	private static function ctorBranchHasFlag(branch:ShapeNode, flag:String):Bool {
		final meta:Null<Metadata> = branch.annotations.get('base.meta');
		if (meta == null) return false;
		for (entry in meta) if (entry.name == ':fmt') {
			for (param in entry.params) switch param.expr {
				case EConst(CIdent(id)) if (id == flag): return true;
				case _:
			}
		}
		return false;
	}
}

/** Output of WriterLowering for one rule. */
typedef WriterRule = {
	fnName:String,
	valueCT:ComplexType,
	body:Expr,
	hasCtxPrec:Bool,
	isBinary:Bool,
};

/**
 * Carries the runtime-access expression and enum type path of the
 * immediately preceding bare-Ref struct field whose body was wrapped
 * via `bodyPolicyWrap`. Consumed by `sameLineSeparator` (ψ₉) to emit
 * a shape-aware leading separator on the following `@:fmt(sameLine(...))`
 * keyword: block ctors respect the flag, non-block ctors force a
 * hardline.
 */
typedef PrevBodyInfo = {
	access:Expr,
	typePath:String,
};

/**
 * ω-interblank — resolved data for `@:fmt(interMemberBlankLines(...))`.
 * Produced by `WriterLowering.buildInterMemberClassifyInfo` and spliced
 * into the `triviaBlockStarExpr` per-element loop to classify each
 * element as a var (kind `1`), a function (kind `2`), or other
 * (kind `0`). `classifyCases` is a ready-to-use `ESwitch` case list —
 * one entry per enum variant, exhaustive, no wildcard.
 *
 * `betweenVarsField` / `betweenFunctionsField` / `afterVarsField` name
 * the `HxModuleWriteOptions` Int fields read at runtime to gate each
 * blank-line slot (ω-iface-interblank). The 3-arg meta form defaults
 * them to the shared `betweenVars` / `betweenFunctions` / `afterVars`
 * (used by class + abstract); the 6-arg form lets a grammar route to
 * its own dedicated fields (e.g. interface uses
 * `interfaceBetweenVars` / `interfaceBetweenFunctions` /
 * `interfaceAfterVars` so its defaults stay independent of the
 * class/abstract knobs).
 */
typedef InterMemberClassifyInfo = {
	classifierFieldName:String,
	classifyCases:Array<Case>,
	betweenVarsField:String,
	betweenFunctionsField:String,
	afterVarsField:String,
};

/**
 * ω-after-package — resolved data for
 * `@:fmt(blankLinesAfterCtor(classifierField, CtorName1, [CtorName2, …], optField))`.
 * Produced by `WriterLowering.buildAfterCtorBlankInfo` and spliced
 * into `triviaEofStarExpr`'s per-element loop to override the source-
 * captured blank-line count when the previous element's classifier
 * matches one of the named ctors.
 *
 * `classifyCases` is a ready-to-use exhaustive `ESwitch` case list:
 * each enum variant present in the classifier target enum maps to
 * either kind `1` (matches one of the configured ctor names) or
 * kind `0` (no match). The runtime gate then reads
 * `_prevKindAfter == 1 ? opt.<optField> : (_t.blankBefore ? 1 : 0)` —
 * a hard override on match (the source-captured count is discarded),
 * source-driven otherwise. `0` strips an existing blank line, higher
 * counts insert that many regardless of source.
 *
 * `optField` is the `HxModuleWriteOptions` Int field name read at
 * runtime (e.g. `afterPackage`). The Star may carry multiple
 * `@:fmt(blankLinesAfterCtor(...))` entries (ω-after-typedecl) — each
 * produces its own `AfterCtorBlankInfo` with a disjoint ctor set and
 * its own `optField`. The runtime cascade walks them in source order:
 * the first matching kind-tracker wins, falling through to `beforeCtor`
 * infos and finally the source-driven `blankBefore` flag. Authors
 * order entries by priority (e.g. `afterPackage` before `afterTypeDecl`).
 */
typedef AfterCtorBlankInfo = {
	classifierFieldName:String,
	classifyCases:Array<Case>,
	optField:String,
};

/**
 * ω-imports-using-blank — resolved data for
 * `@:fmt(blankLinesBeforeCtor(classifierField, CtorName1, [CtorName2, …], optField))`.
 * Produced by `WriterLowering.buildBeforeCtorBlankInfo` and spliced into
 * `triviaEofStarExpr`'s per-element loop. Shape mirrors
 * `AfterCtorBlankInfo` exactly — same single-axis classify-switch
 * (`1` for any matching ctor, `0` otherwise) plus an opt-field name —
 * the two diverge only at the runtime gate. After-ctor's gate fires on
 * `_prevKindAfter == 1`; before-ctor's gate fires on
 * `_currKindBefore == 1 && _prevKindBefore != 1`, which gives the
 * "first X after a non-X" transition semantics (e.g. force a blank
 * line at `import → using`, no force between consecutive `using` decls).
 *
 * Cascade priority in `triviaEofStarExpr`: after-ctor entries (in
 * source order) win first, then before-ctor entries (in source order,
 * each gated on `prev != curr` for that entry's set), then source-
 * driven `blankBefore`. A single decl pair is governed by at most one
 * override; no double-counting. Multiple before-ctor entries on the
 * same Star are supported (ω-after-typedecl) — same shape as
 * `AfterCtorBlankInfo`, evaluated independently per entry.
 */
typedef BeforeCtorBlankInfo = {
	classifierFieldName:String,
	classifyCases:Array<Case>,
	optField:String,
};

/**
 * Internal result type shared by `buildAfterCtorBlankInfo` and
 * `buildBeforeCtorBlankInfo` — both metas accept the same arg shape
 * and produce the same classify-switch + optField pair, then wrap it
 * into their respective Info typedef. Centralising the resolution in
 * one helper keeps shape-validation messages and the classifier-lookup
 * path in sync between the two knobs.
 */
typedef CtorBlankResolution = {
	fieldName:String,
	cases:Array<Case>,
	optField:String,
};
#end
