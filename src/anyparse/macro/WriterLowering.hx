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
			? wrapWithPreWrite(preWriteFn, rawBody, fnName, hasPratt, typePath)
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
			// ω-issue-257-firstline: single-Ref kw-led ctors carrying
			// `@:fmt(bodyPolicy(...))` grow a positional `bodyOnSameLine:Bool`
			// arg captured by the parser. Read inside Case 3 via the index
			// computed below to forward as `bodyPolicyWrap`'s
			// `bodyOnSameLineExpr` parameter so `Keep` policy dispatches
			// source-shape-aware. Disjoint from the four predicates above
			// (single-Ref + `:kw` + `bodyPolicy` is structurally distinct)
			// so the predicate composes additively in `extraArgs`.
			final hasBodyPolicyKw:Bool = ctx.trivia && TriviaTypeSynth.isAltBodyPolicyKwBranch(branch);
			// omega-paren-wrap-source-newline: single-Ref @:wrap branches with
			// `@:fmt(captureWrapOpenNewline)` grow a positional `wrapOpenNewline:Bool`
			// arg captured by the parser (post-lead skipWs gap newline). Read
			// inside the wrap-shape block below via `wrapOpenNewlineExpr` to
			// route between the open-broken and glue break shapes. Disjoint
			// from the kw-bearing predicates (no kw on @:wrap ctors); composes
			// additively in `extraArgs`.
			final hasWrapOpenNewline:Bool = ctx.trivia && TriviaTypeSynth.isAltWrapOpenNewlineBranch(branch);
			// ω-keep-kw-newline (increment 1b): mandatory-`@:kw` VarStmt-family
			// ctors with `@:fmt(captureKwNewline)` grow a positional
			// `kwNewline:Bool` arg captured by the parser (gap newline between
			// the last keyword / lead literal and the inner `decl` Ref). Read
			// via `altSlotAccess(..., KwNewline)` to thread `_setVarKwNewline`
			// into the inner writeCall. Disjoint from the wrap/bodyPolicy kw
			// predicates; composes additively in `extraArgs`.
			final hasKwNewline:Bool = ctx.trivia && TriviaTypeSynth.isAltKwNewlineBranch(branch);
			// ω-keep-chain (increment 2): Pratt/infix ctors with
			// `@:fmt(captureChainNewline)` (the chain ctors Add/Sub/And/Or)
			// grow a positional `chainNewline:Bool` arg captured by the parser
			// (gap newline before the ctor's right operand). Read via
			// `altSlotAccess(..., ChainNewline)` to feed the chain `_gather`'s
			// `_breaks` array. Disjoint from every Alt/postfix predicate (chain
			// ctors are bare infix); composes additively in `extraArgs`.
			final hasChainNewline:Bool = ctx.trivia && TriviaTypeSynth.isAltChainNewlineBranch(branch);
			// ω-keep-chain-receiver-comment: the `@:postfix('.')` FieldAccess ctor
			// grows a `chainLeadComment:Null<String>` slot after its `chainNewline`
			// slot (operand's dot-gap trailing comment). Reserve it in `extraArgs`
			// so the general FieldAccess pattern destructures the right arity; the
			// keep-mode chain dispatch reads it directly off its hand-written
			// `FieldAccess(_prev, _fld, _nl, _opTrail)` pattern. Postfix-only.
			final hasChainLeadComment:Bool = ctx.trivia && TriviaTypeSynth.isPostfixChainCommentBranch(branch);
			// ω-open-trailing-alt: same-line trailing comment after the
			// open lit grows a parallel positional arg next to closeTrailing.
			// Synth gate is `isAltCloseTrailingBranch && @:lead present`,
			// mirrored here so `argNames[2]` names the openTrailing slot.
			final hasOpenTrailing:Bool = hasCloseTrailing
				&& branch.readMetaString(':lead') != null
				&& !branch.hasMeta(':tryparse');
			// ω-postfix-call-trailing: postfix Star-suffix ctors with
			// auto-marked `trivia.starCollects=true` Stars (currently
			// `HxExpr.Call`) grow a positional `closeTrailing:Null<String>`
			// slot for the trailing comment between the close `)` and the
			// next postfix iteration. Disjoint from the four Alt-side
			// predicates (different ctor shapes), so the predicates compose
			// additively in `extraArgs` without collision.
			// ω-keep-callclose-newline: the synth now grows THREE positionals on
			// these branches — closeTrailing (argNames[2]), argsOpenNewline
			// (argNames[3]), argsCloseNewline (argNames[4]); `extraArgs` below
			// reserves all three so the writer-side arg names stay aligned with
			// the parser-pushed ctor arity.
			final hasPostfixCloseTrailing:Bool = ctx.trivia && TriviaTypeSynth.isPostfixCloseTrailingBranch(branch);
			// ω-orphan-trivia-alt: when the branch grows openTrailing it
			// also grows trailingBlankBefore (`argNames[3]`) and
			// trailingLeading (`argNames[4]`). Same `isAltCloseTrailingBranch
			// && @:lead && !@:tryparse` gate as `hasOpenTrailing` — the
			// synth and parser sides both emit conditionally on it.
			// ω-arraylit-source-trail-comma: enum-Alt sep+trail+lead+@:trivia
			// branches (HxExpr.ArrayExpr, HxType.Anon) grow a positional
			// `trailPresent:Bool` arg holding whether the source had a trailing
			// separator before the close literal. Same gate as the synth side
			// (`branch.readMetaString(':sep') != null` inside the
			// `isAltCloseTrailingBranch + @:lead + !@:tryparse` block in
			// `TriviaTypeSynth.buildEnumCtor`) so positions stay deterministic.
			// Writer reads via `argNames[5]` in `lowerEnumStar`. Sister to
			// struct-Star `<field>TrailPresent` synth slot.
			// ω-blockended-trivia-meta-arity (Session 3): hasMeta over
			// readMetaString — multi-arg `@:sep('text', tailRelax, blockEnded)`
			// gates the same as 1-arg `@:sep(',')`. Sister to TriviaTypeSynth
			// L1076 fix; positions stay deterministic between synth + writer.
			final hasArrayLitTrailPresent:Bool = hasOpenTrailing
				&& branch.hasMeta(':sep');
			final extraArgs:Int = ((hasCloseTrailing || hasTrailOptFlag || hasCaptureSource) ? 1 : 0)
				+ (hasOpenTrailing ? 3 : 0)
				+ (hasArrayLitTrailPresent ? 1 : 0)
				+ (hasBodyPolicyKw ? 1 : 0)
				+ (hasWrapOpenNewline ? 1 : 0)
				+ (hasKwNewline ? 1 : 0)
				+ (hasChainNewline ? 1 : 0)
				+ (hasChainLeadComment ? 1 : 0)
				+ (hasPostfixCloseTrailing ? 3 : 0);
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
	private function wrapWithPreWrite(fnExpr:Expr, defaultBody:Expr, writeFnName:String, hasPratt:Bool, typePath:String):Expr {
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
		//
		// ω-paired-converters (Phase A3): in trivia mode, the writer's
		// `value` is paired-T but the plugin signature accepts raw type.
		// Route through the synth-generated `Converters.pairedToRaw_<T>`
		// / `rawToPaired_<T>` helpers so plugins remain raw-only. The
		// rewrite path loses the source trivia by design — when the
		// plugin substitutes a different ctor shape, the original trivia
		// no longer fits and defaults to empty.
		final pos:Position = Context.currentPos();
		if (isTriviaBearing(typePath)) {
			final simple:String = simpleName(typePath);
			final convPath:Array<String> = packOf(typePath).concat(['trivia', 'Pairs', 'Converters']);
			final pairedToRawFn:Expr = MacroStringTools.toFieldExpr(convPath.concat(['pairedToRaw_' + simple]));
			final rawToPairedFn:Expr = MacroStringTools.toFieldExpr(convPath.concat(['rawToPaired_' + simple]));
			final userCall:Expr = {expr: ECall(fnExpr, [macro _raw, macro opt]), pos: pos};
			final wrapBack:Expr = {expr: ECall(rawToPairedFn, [macro _rw]), pos: pos};
			final unwrap:Expr = {expr: ECall(pairedToRawFn, [macro value]), pos: pos};
			return macro {
				final _raw = $unwrap;
				final _rw = $userCall;
				if (_rw != null) value = $wrapBack;
				$defaultBody;
			};
		}
		final preCall:Expr = {expr: ECall(fnExpr, [macro value, macro opt]), pos: pos};
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
		final callRulesExpr:Expr = optFieldAccess(cwf);
		final argsListExpr:Expr = macro anyparse.format.wrap.WrapList.emit(
			$v{callOpen}, $v{callClose}, $v{callSep}, _argDocs, opt,
			_de(), _de(), false, $callRulesExpr, $callTcExpr
		);
		final chainRulesExpr:Expr = optFieldAccess(chainField);
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
		//
		// ω-postfix-call-trailing: trivia-mode Call ctor grew a
		// positional `closeTrailing:Null<String>` slot (see
		// `TriviaTypeSynth.isPostfixCloseTrailingBranch`); the trivia
		// branch's pattern matches three args and embeds `_trailClose`
		// into the segment's Doc when non-null. Plain-mode pattern stays
		// 2-arg. Both branches share the rest of the chain walk.
		// ω-methodchain-prev-pclose-gate: mirror fork's
		// `MarkWrapping.markMethodChaining` chain-start rule — a Dot
		// counts as a chain start only when it is preceded by `)` in
		// source. In AST terms: at least one segment in the chain must
		// have a `_prev` that is a Call ctor (which renders ending with
		// `)`). Pure-prefix paths like `haxe.Json.parse(s)` have NO dot
		// after `)` → fork does not mark a chain → no
		// OnePerLineAfterFirst wrap. Without this gate we activate
		// `MethodChainEmit` on every 2+-segment Call/FieldAccess
		// sequence, which over-wraps short type-path chains inside a
		// long enclosing line (the `IfFullLineExceeds` probe sees the
		// rest-of-stack and forces BREAK mode). The gate is
		// conservative — it matches PClose only; `(a + b).foo()` and
		// `a[i].foo()` still fall through to default emission, matching
		// fork's `isDotAfterPClose` PClose-only test (`MarkWrapping.hx:2299`).
		return isCallTriviaStar
			? macro {
				final _segs:Array<anyparse.core.Doc> = [];
				// ω-keep-chain (increment 9): `_breaks` is parallel to `_segs`
				// — entry `i` is whether the source had a newline in the gap
				// before segment `i`'s `.field` lead (the FieldAccess ctor's
				// captured `chainNewline` synth slot). Built in lockstep with
				// `_segs.unshift` so a `WrapMode.Keep` method-chain round-trips
				// the source per-segment dot-boundary line breaks via
				// `MethodChainEmit.shapeKeep`. Trivia-mode only; Plain keeps the
				// 2-arg ctor patterns below and threads no `_breaks` (null →
				// shapeNoWrap, byte-inert).
				final _breaks:Array<Bool> = [];
				var _cursor = value;
				var _receiver = value;
				var _hasCallPrev:Bool = false;
				// ω-keep-chain-receiver-comment: the inner-most FieldAccess carries
				// its operand's dot-gap trailing comment in the synth
				// `chainLeadComment` slot. When that operand IS the chain receiver
				// (a bare value, the `case _:` of the `switch _prev` below), stash
				// the comment so it can be reattached to the receiver Doc after the
				// walk — a `Keep` chain would otherwise drop it when the per-segment
				// break replaces the source `owner // test` layout.
				var _recTrail:Null<String> = null;
				while (true) {
					switch _cursor {
						// ω-keep-callclose-newline: trivia Call ctor grew a 5th
						// positional `argsCloseNewline`; the chain walk ignores it
						// here (close placement is decided by the outer call's
						// `lowerPostfixStar`, not the per-segment chain emit).
						case Call(_op, _args, _trailClose, _, _):
							switch _op {
								case FieldAccess(_prev, _fld, _nl, _opTrail):
									final _argDocs:Array<anyparse.core.Doc> = $argDocsExpr;
									final _argsDoc:anyparse.core.Doc = $argsListExpr;
									final _segDoc:anyparse.core.Doc = _trailClose != null
										? _dc([_dt('.' + _fld), _argsDoc, trailingCommentDocVerbatim(_trailClose, opt)])
										: _dc([_dt('.' + _fld), _argsDoc]);
									_segs.unshift(_segDoc);
									_breaks.unshift(_nl);
									switch _prev {
										case Call(_, _, _, _, _): _hasCallPrev = true;
										case _: if (_opTrail != null) _recTrail = _opTrail;
									}
									_cursor = _prev;
								case _:
									_receiver = _cursor;
									break;
							}
						case FieldAccess(_prev, _fld, _nl, _opTrail):
							// ω-methodchain-glue-bare-field: a bare `.field`
							// access that precedes an already-collected segment
							// (a Call to its right) is NOT its own chain
							// break-item — it glues onto that segment's lead,
							// mirroring fork `MarkWrapping.isDotAfterPClose` (a
							// `.` counts as a chain item only when its previous
							// token is `)`). So `holder.firstField.inner
							// .filter(args)` stays ONE item, not three. When
							// `_segs` is empty the bare field is a trailing
							// access (its own item per fork's PClose-after rule
							// for `a().b`); keep current shape. Without this glue
							// every leading bare FieldAccess over-segments the
							// chain and inflates the cascade item count.
							//
							// ω-keep-chain: when the bare field glues onto
							// `_segs[0]` it becomes that segment's NEW leading
							// dot, so its source-newline (`_nl`) REPLACES the
							// existing `_breaks[0]` (the break-before now refers
							// to the glued lead). When `_segs` is empty the bare
							// field is its own segment → push its `_nl` parallel.
							if (_segs.length > 0) {
								_segs[0] = _dc([_dt('.' + _fld), _segs[0]]);
								_breaks[0] = _nl;
							} else {
								_segs.unshift(_dt('.' + _fld));
								_breaks.unshift(_nl);
							}
							switch _prev {
								case Call(_, _, _, _, _): _hasCallPrev = true;
								case _: if (_opTrail != null) _recTrail = _opTrail;
							}
							_cursor = _prev;
						case _:
							_receiver = _cursor;
							break;
					}
				}
				if (_segs.length >= 2 && _hasCallPrev) {
					final _recBaseDoc:anyparse.core.Doc = $writeIdent(_receiver, opt, $precExpr);
					// ω-keep-chain-receiver-comment: glue the receiver's captured
					// trailing comment (`owner // test`) to its Doc before the first
					// forced segment break. `trailingCommentDocVerbatim` prepends the
					// leading space, so `_dc([recv, ' // test'])` reproduces the source.
					final _recDoc:anyparse.core.Doc = _recTrail != null
						? _dc([_recBaseDoc, trailingCommentDocVerbatim(_recTrail, opt)])
						: _recBaseDoc;
					return anyparse.format.wrap.MethodChainEmit.emit(_recDoc, _segs, opt, $chainRulesExpr, _breaks);
				}
				$body;
			}
			: macro {
				final _segs:Array<anyparse.core.Doc> = [];
				var _cursor = value;
				var _receiver = value;
				var _hasCallPrev:Bool = false;
				while (true) {
					switch _cursor {
						case Call(_op, _args):
							switch _op {
								case FieldAccess(_prev, _fld):
									final _argDocs:Array<anyparse.core.Doc> = $argDocsExpr;
									final _argsDoc:anyparse.core.Doc = $argsListExpr;
									_segs.unshift(_dc([_dt('.' + _fld), _argsDoc]));
									switch _prev {
										case Call(_, _): _hasCallPrev = true;
										case _:
									}
									_cursor = _prev;
								case _:
									_receiver = _cursor;
									break;
							}
						case FieldAccess(_prev, _fld):
							// ω-methodchain-glue-bare-field (plain-mode twin of
							// the trivia branch above): glue a bare leading
							// `.field` onto the already-collected segment to its
							// right rather than over-segmenting the chain.
							if (_segs.length > 0)
								_segs[0] = _dc([_dt('.' + _fld), _segs[0]]);
							else
								_segs.unshift(_dt('.' + _fld));
							switch _prev {
								case Call(_, _): _hasCallPrev = true;
								case _:
							}
							_cursor = _prev;
						case _:
							_receiver = _cursor;
							break;
					}
				}
				if (_segs.length >= 2 && _hasCallPrev) {
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
			// ω-ternary-wrap: dispatch to the chain-emit engine with a
			// degenerate 3-item / 2-op chain (items = [cond, then, else],
			// ops = [ternaryOp, sep]). `BinaryChainEmit.shapeNoWrap`
			// produces `cond ? then : else` with `' op '` spacing —
			// byte-equivalent to the prior flat emit when the cascade
			// resolves to NoWrap (default). `OnePerLineAfterFirst` +
			// BeforeLast (haxe-formatter `ternaryExpression` canonical
			// break shape) yields `cond\n\t? then\n\t: else`. The chain
			// extractor is intentionally NOT applied here: nested ternary
			// `Ternary(a, b, Ternary(c, d, e))` renders the inner ternary
			// as a self-contained leaf Doc through the standard writer
			// path — each `?:` node runs the cascade independently.
			// Collapsing nested ternaries into a single chain is a future
			// slice (no current fixture demands it).
			final rulesExpr:Expr = optFieldAccess('ternaryWrap');
			return macro {
				final _items:Array<anyparse.core.Doc> = [$condCall, $middleCall, $rightCall];
				final _ops:Array<String> = [$v{ternaryOp}, $v{sep}];
				final _inner:anyparse.core.Doc = anyparse.format.wrap.BinaryChainEmit.emit(
					_items, _ops, opt, $rulesExpr, false
				);
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
			// ω-arrow-fn-type-haxe3: a per-ctor whitespace-policy flag
			// (e.g. `@:fmt(functionTypeHaxe3)` on `HxType.Arrow`) puts the
			// op literal under a runtime switch on `opt.<flag>` so the
			// spacing follows the user's `hxformat.json` config. Default
			// `WhitespacePolicy.None` preserves the historic tight shape
			// without `@:fmt(tight)` needed in tandem.
			final infixPolicyFlag:Null<String> = firstFmtFlag(branch, ['functionTypeHaxe3']);
			final isTight:Bool = branch.fmtHasFlag('tight') || infixPolicyFlag != null;
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
				final opEmitExpr:Expr = infixPolicyFlag != null
					? whitespacePolicyInfix(opText, infixPolicyFlag)
					: macro _dt($v{opWithSpaces});
				final innerExpr:Expr = isAssign && !isTight
					? macro _dc([
						$leftCall, _dt(' '), _dt($v{opText}), _dop(' '), $rightCall,
					])
					: macro _dc([
						$leftCall, $opEmitExpr, $rightCall,
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
				final chainRulesExpr:Expr = optFieldAccess(chainRulesField);
				final argTypeCT:ComplexType = ruleValueCT(typePath);
				// Leaf operands render at the chain's own precedence. A
				// sub-expression with strictly lower prec (ternary inside
				// `||`, assign inside `+`) gets the parens it needs;
				// same-class operators are consumed by the extractor.
				final leafCall:Expr = makeWriteCall(writeFnName, macro _e, hasPratt, prec);
				// ω-keep-chain (increment 2): in Trivia mode the chain ctors
				// Add/Sub/And/Or carry a 3rd `chainNewline:Bool` synth arg (the
				// per-operand source-newline). Bind it (`_nl`) and push into the
				// `_breaks` array parallel to `_ops` so `BinaryChainEmit.emit`'s
				// `WrapMode.Keep` shaper can reproduce the source line breaks. In
				// Plain mode the ctors keep 2-operand arity and no `_breaks` is
				// threaded (chain stays glued via shapeNoWrap) → byte-inert.
				// Outer-ctor chainNewline (read via altSlotAccess; null in Plain)
				// — the gap before THIS branch's right operand (`argNames[1]`),
				// pushed between the two top-level gathers to stay parallel to
				// the outer `_ops.push(opText)`.
				final outerChainNl:Null<Expr> = ctx.trivia
					? altSlotAccess(branch, children.length, argNames, ChainNewline)
					: null;
				// All four chain ctors (Or/And/Add/Sub) carry `captureChainNewline`,
				// so `outerChainNl` is non-null in Trivia mode; the `!= null` guard
				// keeps `_breaks` declaration and the gatherSwitch's `_breaks.push`
				// strictly in lockstep (no half-wired state).
				final threadBreaks:Bool = ctx.trivia && outerChainNl != null;
				final gatherSwitch:Expr = if (threadBreaks) {
					isChainBool
						? macro switch _e {
							case Or(_l, _r, _nl): _gather(_l); _ops.push('||'); _breaks.push(_nl); _gather(_r);
							case And(_l, _r, _nl): _gather(_l); _ops.push('&&'); _breaks.push(_nl); _gather(_r);
							case _: _items.push($leafCall);
						}
						: macro switch _e {
							case Add(_l, _r, _nl): _gather(_l); _ops.push('+'); _breaks.push(_nl); _gather(_r);
							case Sub(_l, _r, _nl): _gather(_l); _ops.push('-'); _breaks.push(_nl); _gather(_r);
							case _: _items.push($leafCall);
						};
				} else {
					isChainBool
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
				}
				// `_breaks` (parallel to `_ops`) only exists in Trivia mode.
				// ω-keep-chain head break (increment 2): a `return`→head source
				// newline is delivered via the shared `opt._varKwNewline` channel
				// (set by the `ReturnStmt` Case-3 `_setVarKwNewline` threading;
				// the same field VarStmt uses). Read it as the chain head break
				// (single `EVars` → declared at the outer block scope) and CLEAR
				// it on `opt` (folded into the `_clearCallArgChainNest` re-bind
				// below) so it does not leak to a nested chain / the multiVar
				// fold. Trivia-keep only; in Plain / non-keep the field is false
				// and untouched → byte-inert.
				// ω-keep-chain (increment: opadd_chain_keep): drop the chain
				// `_headBreak` when this Keep chain is wrapped by a return-context
				// `ParenExpr` (`_keepChainInParen`, declared just above) — the
				// `return`→value source newline is reproduced at the value level
				// (`returnBody` FitLine), NOT inside the paren. A bare-value chain
				// (opbool case-2) has `_keepChainInParen == false` → keeps headBreak.
				final headDecl:Expr = threadBreaks
					? macro final _headBreak:Bool = opt._varKwNewline && !_keepChainInParen
					: macro {};
				// Fold `_clearVarKwNewline` into the `_clearCallArgChainNest`
				// re-bind so the head-break flag is consumed once at the
				// outermost chain (leaf/nested chains see it cleared).
				// ω-keep-chain (increment: opadd_chain_keep): additionally mark
				// `_keepFlatInner` on the leaf-operand opt when THIS chain's config
				// resolves to `WrapMode.Keep` (`$chainRulesExpr.defaultMode == Keep`).
				// A kept chain preserves source line structure verbatim (operand
				// lines may exceed `lineWidth`), so its operands' inner `ParenExpr`
				// must stay GLUED — the flag flips the `expressionParenHardFlatten`
				// emit to the unconditional-glue branch. Runtime-gated so a non-keep
				// chain (NoWrap / FillLine / OnePerLine) passes the flag through false
				// → byte-inert. The `_setKeepFlatInner` re-bind wraps the existing
				// clear chain so the flag rides the SAME opt the leaf `makeWriteCall`s
				// thread. Trivia+chain-only (`threadBreaks`); Plain keeps the legacy form.
				final clearOptExpr:Expr = threadBreaks
					? macro _setKeepFlatInner(
						_clearKeepChainInParen(_clearVarKwNewline(_clearCallArgChainNest(opt))),
						$chainRulesExpr.defaultMode == anyparse.format.wrap.WrapMode.Keep
					)
					: macro _clearCallArgChainNest(opt);
				final breaksDecl:Expr = threadBreaks
					? macro final _breaks:Array<Bool> = []
					: macro {};
				// Top-level gather: head operand, the outer operator, the outer
				// ctor's source-newline (parallel to that operator), tail operand.
				final outerBreakPush:Expr = threadBreaks
					? macro _breaks.push(${outerChainNl})
					: macro {};
				final gatherInvoke:Expr = macro {
					_gather($i{argNames[0]});
					_ops.push($v{opText});
					$outerBreakPush;
					_gather($i{argNames[1]});
				};
				// Thread `_breaks` (sourceBreakBefore) + `_headBreak` only in
				// Trivia mode; Plain keeps the legacy 6-arg call (chain glues).
				final emitCall:Expr = threadBreaks
					? macro anyparse.format.wrap.BinaryChainEmit.emit(
						_items, _ops, opt, $chainRulesExpr, _chainNestSuppress, _condWrapForced, _breaks, _headBreak
					)
					: macro anyparse.format.wrap.BinaryChainEmit.emit(
						_items, _ops, opt, $chainRulesExpr, _chainNestSuppress, _condWrapForced
					);
				return macro {
					final _items:Array<anyparse.core.Doc> = [];
					final _ops:Array<String> = [];
					$breaksDecl;
					// ω-condwrap-call-arg-nest + ω-callarg-chain-nest: suppress
					// the chain's OWN continuation `Nest(cols, …)` when an outer
					// context already supplied the `+cols` indent — either a
					// condWrap `FillLineWithLeadingBreak` brkShape
					// (`_chainModeOverride`, set at the `@:fmt(condWrap)` site via
					// `_setChainModeOverride`; only that mode expands
					// `WrapList.emitCondition` to `Nest(cols, [Line('\n'),
					// condDoc])`), or a leading-break call argument
					// (`_callArgChainNest`, set at the call's per-arg writer call
					// when `callParameterWrap.defaultMode == FLWLB`, whose
					// `shapeFillLineWithLeadingBreak` Nests the arg at +cols).
					// Read the flag from the inbound opt, then CLEAR
					// `_callArgChainNest` so only the OUTERMOST chain consumes it
					// — leaf operands / nested chains (written via `makeWriteCall`,
					// which threads this same `opt`) keep their own Nest.
					// `_chainModeOverride` is deliberately NOT cleared: condWrap
					// collapses every chain in the condition. Safe to read both
					// fields directly: only Haxe declares `||`/`&&`/`+`/`-` chain
					// infix (HxModuleWriteOptions carries the fields).
					// `_condWrapForced` distinguishes the cond-wrap collapse
					// (`_chainModeOverride == FLWLB`, set at the `@:fmt(condWrap)`
					// site) from a leading-break CALL-ARG (`_callArgChainNest`):
					// both suppress the chain's own Nest, but only the cond-wrap
					// case is a chain-UNWRAP candidate (ω-chain-keep-flat). A
					// call-arg chain must keep its configured break shape (fork
					// `unwrapBoolOps` fires inside `applyArrowWrapping`, never for
					// a chain that is itself a call argument — `opbool_in_call_
					// leading_break_preserved`, `opsub_chain_in_single_param_call`).
					final _condWrapForced:Bool =
						opt._chainModeOverride == anyparse.format.wrap.WrapMode.FillLineWithLeadingBreak;
					// ω-keep-chain (increment: opadd_chain_keep): a `WrapMode.Keep`
					// chain wrapped by an enclosing `ParenExpr` in a return-head-break
					// context (`opt._keepChainInParen`, set at the paren's inner opt)
					// suppresses its OWN continuation `Nest` — the value-level break
					// already supplied the +cols, so the chain operators co-indent
					// with the head (no +2cols compounding). The `$headDecl` below
					// likewise drops the chain `_headBreak`. Gated on the chain config
					// being Keep so non-keep chains in a paren are byte-inert.
					final _keepChainInParen:Bool = opt._keepChainInParen
						&& $chainRulesExpr.defaultMode == anyparse.format.wrap.WrapMode.Keep;
					final _chainNestSuppress:Bool = _condWrapForced || opt._callArgChainNest || _keepChainInParen;
					$headDecl;
					final opt = $clearOptExpr;
					function _gather(_e:$argTypeCT):Void $gatherSwitch;
					$gatherInvoke;
					final _inner:anyparse.core.Doc = $emitCall;
					if ($v{prec} < ctxPrec) _dc([_dt('('), _inner, _dt(')')]) else _inner;
				};
			}
			// Group/Line/Nest wrap for non-tight non-assign non-chain
			// infix (compare, shift, bitwise, `is`, `??`, `*`/`/`/`%`): lets
			// the renderer pick flat (Line(' ') → space) when the chain's
			// full flat width fits in the remaining columns, else break.
			// Per-binary Group cascading from G.1 (ω-binop-group-wrap).
			//
			// ω-binop-open-delim-glue (opadd_chain* B1-remainder): these
			// operators are NOT wrap-points in the fork — `MarkWrapping`
			// wrap-marks ONLY `Binop(OpAdd)` / `Binop(OpLt)` (type param) /
			// `Binop(OpArrow)`; `*`/`/`/`%`/`>`/`<<`/`&`/`is`/`??`/compare
			// never break at the operator, only their bracketed operands
			// break. The legacy `Group(Concat([left, Nest(cols, [Line, op,
			// right])]))` breaks the soft `Line` whenever the content carries
			// a committed hardline — which happens when the RIGHT operand is
			// a paren-wrapped chain that wraps one-per-line (e.g.
			// `return 1 * (a + b + c + …)`). The enclosing `Mul` Group then
			// over-breaks `1\n\t* (…` where the fork keeps `1 * (` glued and
			// lets ONLY the inner paren's chain wrap. When the right operand
			// STARTS WITH an open delimiter (`(`/`[`/`{` — a paren-expr /
			// call / array / object whose bracket absorbs the break),
			// emit the operator GLUED (flat `left op right`, no Group/Line):
			// the bracketed operand carries the wrap inside its own delims.
			// `startsWithOpenDelim` is an O(left-spine) structural check
			// (NO render-time re-measure) so it is exponential-safe even on
			// deeply nested same-class binary trees (`(a * (b * (c …)))`) —
			// each level just glues, no probe nesting. Non-delim right
			// operands (leaf idents, prefix-op exprs) keep the legacy Group
			// break unchanged. Byte-inert when the bracketed operand does
			// not wrap (no hardline → the legacy Group never broke → glued
			// shape is byte-identical to the flat Group resolution).
			final opAfterText:String = opText + ' ';
			return macro {
				final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space
					? opt.indentSize : opt.tabWidth;
				final _left:anyparse.core.Doc = $leftCall;
				final _right:anyparse.core.Doc = $rightCall;
				// ω-binop-close-delim-glue (cond-paren-OPEN sibling): when the
				// LEFT operand ENDS with a close delim (`[…].indexOf(x)`,
				// `(chain)`), the bracketed operand wraps inside its own brackets
				// and the never-wrap-marked operator (`<`/`>`/`*`/`/`/compare)
				// must RIDE the close-delim line (`].indexOf(x) < 0`), not break
				// onto its own line. The right-spine mirror of the existing
				// `startsWithOpenDelim(_right)` head-glue; both keep the operator
				// glued so only the bracketed operand carries the break. Byte-
				// inert when the left operand does not wrap (no committed hardline
				// → the legacy Group never broke → glued shape is byte-identical).
				final _inner:anyparse.core.Doc = anyparse.format.wrap.WrapList.startsWithOpenDelim(_right)
						|| anyparse.format.wrap.WrapList.endsWithCloseDelim(_left)
					? _dc([_left, _dt($v{opWithSpaces}), _right])
					: _dg(_dc([
						_left,
						_dn(_cols, _dc([_dl(), _dt($v{opAfterText}), _right])),
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
				if (close.length > 0) {
					// ω-bracket-config: `HxExpr.IndexAccess` (`@:postfix('[',
					// ']') @:fmt(accessBrackets)`) is the sole close-bearing
					// two-child postfix ctor. With the flag, pad the inside of
					// the subscript brackets per `accessBracketsOpen` /
					// `accessBracketsClose` (`arr[ i ]`); without it, the slots
					// collapse to `_de()` so the default `arr[i]` stays byte-
					// identical. The `index` is a mandatory Ref (never empty),
					// so no empty-bracket guard is needed here.
					if (branch.fmtHasFlag('accessBrackets')) {
						final openInside:Expr = policyInsideSpace('accessBracketsOpen', false);
						final closeInside:Expr = policyInsideSpace('accessBracketsClose', true);
						return macro _dc([$operandCall, _dt($v{postfixOp}), $openInside, $suffixCall, $closeInside, _dt($v{close})]);
					}
					return macro _dc([$operandCall, _dt($v{postfixOp}), $suffixCall, _dt($v{close})]);
				}
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
			// ω-issue-423-mech-a: when the kw-Ref ctor itself carries
			// `@:fmt(propagateExprPosition)` (e.g. `HxStatement.ReturnStmt`,
			// `HxExpr.ReturnExpr`), wrap the sub-call's opt arg in
			// `_setExprPosition` so the `value:HxExpr` descendant sees the
			// expression-position frame. Idempotent — already-true opt
			// passes through.
			final propagateExpr:Bool = branch.fmtHasFlag('propagateExprPosition');
			// ω-string-interp-noformat-flat: the interpolation `${expr}` body
			// (`@:fmt(captureSource(...))` ctor — `HxStringSegment.Block`)
			// threads `_setChainModeOverride(opt, NoWrap)` into the sub-call
			// so the descendant chain emit collapses its cascade to `NoWrap`
			// — an inner `+`/`-`/`&&` chain stays flat regardless of the
			// `opAddSubChain`/`opBoolChain` config (the fork never wraps
			// expressions inside interpolations). Reuses the existing
			// chain-override channel (no new opt field): `_setChainModeOverride`
			// swaps `opBoolChainWrap`/`opAddSubChainWrap` to a degenerate
			// `{rules: [], defaultMode: NoWrap}` cascade. `NoWrap` is distinct
			// from the `FillLineWithLeadingBreak` cond-wrap mode, so the
			// chain dispatch's `_condWrapForced` gate (== FLWLB) stays false —
			// no interaction with the inc6 chain-unwrap path. The HardFlatten
			// wrap at `bodyExpr` (below) covers width-conditional breaks +
			// non-chain Groups; this NoWrap channel covers the unconditional
			// `onePerLine` chain shape whose `Line('\n')` flat form would
			// survive HardFlatten. Composes with `propagateExpr`. Gated on the
			// `captureSource` flag alone (Haxe-only today, and `HxModuleWriteOptions`
			// carries the chain-override channel) — mirrors the `@:fmt(condWrap)`
			// site (L3592), which calls `_setChainModeOverride` ungated for the
			// same reason: the flag's presence implies the grammar's channel.
			final interpFlat:Bool = branch.fmtHasFlag('captureSource');
			// ω-expr-paren-in-condition (cond F2): the `ParenExpr`
			// (`@:fmt(expressionParenHardFlatten)`) inner chain is HardFlatten-
			// collapsed by default. When this paren sits inside a condition
			// (`opt._parenInCondition`, set at the `@:fmt(condWrap)` site) AND the
			// user configured `expressionWrapping` to fillLine, thread the fillLine
			// mode as a `_chainModeOverride` into the paren's OWN inner writeCall so
			// its chain wraps fillLine — and CLEAR `_parenInCondition` so a nested
			// expr paren inside this one does not re-trigger. Runtime-gated so a
			// standalone expr paren (flag false, e.g. `expression_paren_wrapping`)
			// is byte-identical (`opt` passed through unchanged).
			final parenHardFlatten:Bool = branch.fmtHasFlag('expressionParenHardFlatten');
			// ω-keep-kw-newline (increment 1b): when this VarStmt-family ctor
			// captured a `var`→head newline (the synth `kwNewline:Bool` slot),
			// thread `_setVarKwNewline(opt, true)` into the inner `decl`
			// writeCall so the `HxVarDecl` multiVar fold reproduces the head
			// break under `WrapMode.Keep`. The helper is idempotent and
			// allocation-free when the flag matches, so a same-line `var x = …`
			// (kwNewline false) leaves `opt` unchanged — byte-inert. Trivia-
			// only (the slot exists only on bearing trivia ctors); plain mode
			// leaves `kwNewlineExpr` null and the head stays glued to `var `.
			final kwNewlineExpr:Null<Expr> = (ctx.trivia && isTriviaBearing(typePath))
				? altSlotAccess(branch, children.length, argNames, KwNewline)
				: null;
			final ctorOptArg:Expr = {
				var _o:Expr = macro opt;
				if (propagateExpr) _o = macro _setExprPosition($_o);
				if (interpFlat) _o = macro _setChainModeOverride($_o, anyparse.format.wrap.WrapMode.NoWrap);
				if (parenHardFlatten) _o = macro(opt._parenInCondition
					? _setChainModeOverride(_clearParenInCondition($_o),
						anyparse.format.wrap.WrapList.effectiveExpressionWrapMode(opt.expressionWrappingWrap))
					: $_o);
				// ω-keep-chain (increment: opadd_chain_keep): a `ParenExpr`
				// (`@:fmt(expressionParenHardFlatten)`) wrapping a chain marks the
				// inner opt `_keepChainInParen`. A `WrapMode.Keep` chain reads it to
				// (a) SUPPRESS its own `_headBreak` — the `return`→value source
				// newline is reproduced at the VALUE level (`returnBody` FitLine
				// breaks `return\n\tvalue`), not inside the paren (`(\n head`); and
				// (b) SUPPRESS its continuation `Nest` — the value-level break Nest
				// already supplies the +cols, so the chain operators continue at that
				// SAME indent (no compounding to +2cols). Mirrors fork keep2 keeping
				// the `return`→`1` newline at the value and the chain ops co-indented
				// with the head. Non-keep chains ignore the flag (gated on `isKeep`)
				// → byte-inert. A BARE chain return value (opbool case-2) has NO
				// enclosing `ParenExpr`, so the flag stays false and its chain keeps
				// its own headBreak + Nest. Trivia-only.
				if (parenHardFlatten && ctx.trivia) _o = macro _setKeepChainInParen($_o, true);
				if (kwNewlineExpr != null) _o = macro _setVarKwNewline($_o, $kwNewlineExpr);
				_o;
			};
			final subCall:Expr = if (isSelfRef && hasPratt)
				{expr: ECall(macro $i{subFn}, [macro $i{argNames[0]}, ctorOptArg, macro -1]), pos: Context.currentPos()}
			else
				{expr: ECall(macro $i{subFn}, [macro $i{argNames[0]}, ctorOptArg]), pos: Context.currentPos()};

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
			// ω-issue-257-else-in-return-switch: `bodyPolicy(...)` accepts
			// 1 or 2 flag names. Two-arg form dispatches between the
			// stmt-position knob (arg 0) and expr-position knob (arg 1)
			// at runtime via `opt._inExprPosition`. Mirrors the dual-flag
			// dispatch in `triviaTryparseStarExpr` for case-body Stars.
			final ctorBodyPolicy:{stmt:Null<String>, expr:Null<String>} = readBodyPolicyDual(branch);
			final ctorBodyPolicyFlag:Null<String> = ctorBodyPolicy.stmt;
			final ctorBodyPolicyExprFlag:Null<String> = ctorBodyPolicy.expr;
			// ω-returnbody-widthaware: read the parameterless `@:fmt(widthAware)`
			// flag at the same call site so the runtime IfFirstLineExceeds
			// wrap is opt-in per ctor (currently `HxStatement.ReturnStmt`).
			final ctorWidthAware:Bool = branch.fmtHasFlag('widthAware');
			// ω-return-body-single-line: read the
			// `@:fmt(bodyPolicySingleLine('<flag>', '<multiCtor>'...))` knob
			// (currently `HxStatement.ReturnStmt`) so `bodyPolicyWrap` can split
			// the policy between single-line and multi-line value shapes. Arg 0
			// is the single-line flag name; the remaining args name the value
			// ctors treated as multi-line (control-flow / block), which keep the
			// base `returnBody` policy.
			final ctorSingleLineArgs:Null<Array<String>> = branch.fmtReadStringArgs('bodyPolicySingleLine');
			final ctorSingleLineFlag:Null<String> = ctorSingleLineArgs == null ? null : ctorSingleLineArgs[0];
			final ctorSingleLineMultiCtors:Null<Array<String>> = ctorSingleLineArgs == null ? null : ctorSingleLineArgs.slice(1);
			// ω-issue-257-firstline: when the ctor is the bodyPolicy-kw-Ref
			// shape (predicate matches `HxStatement.ReturnStmt`) and trivia
			// mode + bearing typePath, the synth ctor carries a positional
			// `bodyOnSameLine:Bool` arg captured by the parser. Forward its
			// access expression so `bodyPolicyWrap`'s `Keep` branch can
			// dispatch source-shape-aware. The arg index follows the same
			// ordering as `TriviaTypeSynth.buildEnumCtor`: closeTrailing
			// (+ openTrailing/trailingBlankBefore/trailingLeading) →
			// trailPresent → sourceText → bodyOnSameLine → postfix
			// closeTrailing. Plain mode keeps `null` and the wrap degrades
			// to `sameLayoutExpr` (no Keep slot — falls through the same
			// width-aware path as `Same`).
			final bodyOnSameLineExpr:Null<Expr> = (ctx.trivia && isTriviaBearing(typePath))
				? altSlotAccess(branch, children.length, argNames, BodyPolicyKw)
				: null;
			// omega-paren-wrap-source-newline: ctors carrying
			// @:fmt(captureWrapOpenNewline) on a single-Ref @:wrap branch grow
			// a positional `wrapOpenNewline:Bool` arg in the synth pair (see
			// TriviaTypeSynth.buildEnumCtor push order). Compute its access
			// expression here so the @:wrap shape below can switch break-mode
			// shape based on source-shape capture. Plain mode (or trivia-mode
			// without the opt-in flag) leaves `wrapOpenNewlineExpr` null and
			// the shape falls back to the existing unconditional glue.
			final wrapOpenNewlineExpr:Null<Expr> = (ctx.trivia && isTriviaBearing(typePath))
				? altSlotAccess(branch, children.length, argNames, WrapOpenNewline)
				: null;
			// ω-issue-257-firstline regression-fix: forward `indentArgs` to
			// `bodyPolicyWrap` so its `indentObjGuardedNext` rule fires for
			// the ctor-level `Next`/`Keep`-bodyOnSameLine-false fallback path
			// when the body is an ObjectLit and `indentObjectLiteral=false`.
			// Without forwarding, the `Keep`-route nextLayoutExpr always
			// emits `_dn(_cols, [_dhl, body])` and over-indents `{` by one
			// step (`return\n\t\t\t{` instead of `return\n\t\t{` for
			// `indentObjectLiteral=false` configs). The post-process wrap
			// below at `indentWrapped` keeps overriding the SAME-policy case
			// when `indentObjectLiteral=true`; the two layers are orthogonal
			// — post-process handles `Same+true`, bodyPolicyWrap handles
			// `Next+false` and `Keep+false`. Reads the meta once and reuses
			// the result for both layers.
			//
			// ω-issue-257-return-same-indent-value-expr: split the
			// `indentValueIfCtor` entries on this ctor by arity:
			//   - 3-arg form `(ctorName, optField, leftCurlyField)` →
			//     `indentArgs`, fed to `bodyPolicyWrap.indentObjGuardedNext`
			//     (Next/Keep+false ObjectLit path) AND post-hoc
			//     `indentWrapped` (Same+true ObjectLit path). At most one
			//     entry per ctor.
			//   - 2-arg form `(ctorName, optField)` → `ifExprIndentArgs`,
			//     fed to `bodyPolicyWrap` as the new `ifExprIndentArgs`
			//     param which conditionally wraps the writeCall in
			//     `Nest(_cols, …)` ONLY in the Same flat-path (so multi-
			//     line IfExpr-as-value picks up `+cols` on its internal
			//     else-branch hardlines, mirroring the struct-field
			//     `HxVarDecl.init` semantic). At most one entry per ctor.
			// Mirrors the multi-entry pattern in `maybeIndentValueIfCtor`
			// for struct-field path.
			var indentArgs:Null<Array<String>> = null;
			var ifExprIndentArgs:Null<Array<String>> = null;
			final indentEntries:Array<Array<String>> = branch.fmtReadStringArgsAll('indentValueIfCtor');
			for (entry in indentEntries) switch entry.length {
				case 3:
					if (indentArgs != null) Context.fatalError('WriterLowering: at most one 3-arg @:fmt(indentValueIfCtor(ctorName, optField, leftCurlyField)) per ctor', Context.currentPos());
					indentArgs = entry;
				case 2:
					if (ifExprIndentArgs != null) Context.fatalError('WriterLowering: at most one 2-arg @:fmt(indentValueIfCtor(ctorName, optField)) per ctor', Context.currentPos());
					ifExprIndentArgs = entry;
				case _:
					Context.fatalError('WriterLowering: @:fmt(indentValueIfCtor(...)) on ctor requires 2 or 3 args, got ${entry.length}', Context.currentPos());
			}
			final policyWrapped:Expr = ctorBodyPolicyFlag != null
				? bodyPolicyWrap({
					flagName: ctorBodyPolicyFlag,
					exprFlagName: ctorBodyPolicyExprFlag,
					writeCall: subCall,
					bodyValueExpr: macro $i{argNames[0]},
					bodyTypePath: refName,
					hasElseIf: false,
					elseFieldName: null,
					bodyOnSameLineExpr: bodyOnSameLineExpr,
					indentObjArgs: indentArgs,
					widthAware: ctorWidthAware,
					ifExprIndentArgs: ifExprIndentArgs,
					singleLineFlagName: ctorSingleLineFlag,
					singleLineMultiCtors: ctorSingleLineMultiCtors,
					kwNewlineExpr: kwNewlineExpr,
				})
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
			// through to `policyWrapped` unchanged. `indentArgs` is the
			// 3-arg entry (guaranteed by the arity split above; null when
			// only the 2-arg IfExpr form is present).
			final indentWrapped:Expr = if (indentArgs == null) policyWrapped
			else {
				final ctorName:String = indentArgs[0];
				final optField:String = indentArgs[1];
				final leftCurlyField:String = indentArgs[2];
				final optAccess:Expr = optFieldAccess(optField);
				final leftCurlyAccess:Expr = optFieldAccess(leftCurlyField);
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
			var bodyExpr:Expr = if (captureSourceOpt != null) {
				final sourceAccess:Expr = macro $i{argNames[1]};
				final optAccess:Expr = optFieldAccess(captureSourceOpt);
				// Mirror haxe-formatter `MarkTokenText.printStringToken`
				// (`MarkTokenText.hx:39-63`). Fork uses naive `text.indexOf('}',
				// index + 2)` to find the close of `${…}`. Two failure modes
				// both land at verbatim emission upstream:
				//  - a literal `{` inside the body (nested string / anon
				//    struct) trips the explicit `fragment.indexOf("{")` skip
				//    (line 54);
				//  - a literal `}` inside the body makes `indexOf("}")` match
				//    too early; the truncated fragment fails `formatFragment`
				//    tokenisation (line 110-113 catch) and the slot stays
				//    verbatim.
				// Our recursive-descent parser handles brace balance correctly,
				// but to match fork's byte output we replicate both bail-outs
				// at write time: any `{` OR `}` in the captured slice → emit
				// verbatim. Closes `whitespace/issue_72_whitespace_in_string_interpolation`.
				macro $optAccess && $sourceAccess.indexOf('{') < 0 && $sourceAccess.indexOf('}') < 0 ? $indentWrapped : _dt($sourceAccess);
			} else indentWrapped;

			// ω-string-interp-noformat-flat: an interpolation `${expr}` body
			// (the `@:fmt(captureSource(...))` ctor — `HxStringSegment.Block`)
			// re-renders the inner expression when `formatStringInterpolation`
			// is true, but the fork NEVER wraps expressions inside string
			// interpolations — they stay on one line regardless of the chain
			// wrap config (`opAddSubChain`/`opBoolChain` onePerLine/fillLine).
			// Pin the re-rendered body force-flat through `HardFlatten` so an
			// inner `+`/`-`/`&&` chain (or any nested Group) collapses to one
			// line: `${topRightPointX - 7.5}` instead of breaking the chain
			// one-per-line at the operator. Mirror of fork — `printStringToken`
			// formats the fragment in isolation with no surrounding wrap
			// context. HardFlatten survives the chain's inner `WrapBoundary`
			// (Renderer.hx ω-hardflatten) where plain `Flatten` would re-float.
			// The verbatim branch (`_dt(sourceAccess)`) is a single Text —
			// HardFlatten is a no-op there. Closes `opadd_chain_string_concat`
			// inner-interp breaks / `opadd_chain_trailing_indent`.
			if (branch.fmtHasFlag('captureSource')) bodyExpr = macro _dhf($bodyExpr);

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
			// ω-kw-word-lead-spacing (Slice 37): a ctor-level `@:lead` whose
			// first char is a word character is a second keyword, NOT a
			// tight symbol delimiter. Word-word adjacency between kw and
			// lead (e.g. `@:kw('static') @:lead('var')` → `static var`,
			// `@:kw('inline') @:lead('function')` → `inline function`)
			// requires a separating space on BOTH sides of the lead: kw
			// keeps its trailing space, AND the lead emit appends a
			// trailing space so the body's first token doesn't collide.
			// Symbol leads (`(`, `{`, `<`, `:`, `?`, `->`, `${`, …) stay
			// tight under the strip — `while (` vs `while(` is owned by
			// the field-level path, and ctor-level symbol leads were the
			// only consumers of the pre-slice `leadText != null` clause.
			final leadIsWord:Bool = leadText != null && isWordStart(leadText);
			final stripKwTrailingSpace:Bool = ctorBodyPolicyFlag != null
				|| subStructStartsWithBodyPolicy(refName)
				|| subStructStartsWithBodyBreak(refName)
				|| subStructStartsWithBareBodyBreaks(refName)
				|| subStructStartsWithTightLead(refName)
				// Combined kw + symbol `@:lead` on the same single-Ref
				// branch composes as a tight visual unit: kw and lead
				// literal render adjacent without a separating space.
				// Strip the kw's trailing space so the lead literal abuts
				// the kw. Symmetric with the parser-side composition in
				// Lowering Case 3. Word-lead branches (above) bypass.
				// Writer Slice 5: opt-in `@:fmt(spaceBeforeLead)` keeps
				// the kw's trailing space so `kw symLead` emits with a
				// separating space — used by `HxExpr.MacroTypeExpr`
				// (`@:kw('macro') @:lead(':')`) to emit `macro :Type`
				// matching haxe-formatter's type-reification convention.
				|| (leadText != null && !leadIsWord && !branch.fmtHasFlag('spaceBeforeLead'));
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
				: kwTrailingSpacePolicy(branch, ['ifPolicy', 'forPolicy', 'whilePolicy', 'switchPolicy', 'tryPolicy', 'sharpCondParensGap']);
			final parenSidePolicySpace:Null<Expr> = stripKwTrailingSpace
				? null
				: kwTrailingSpacePolicyParenSide(branch, ['anonFuncParens']);
			// ω-cast-tight-on-paren (Slice 46): `@:fmt(tightOnParenOperand('A',
			// 'B', …))` on a kw-led single-Ref branch suppresses the kw's
			// trailing space at runtime when the operand's enum ctor matches
			// any name in the list. Consumed by `HxExpr.CastExpr`
			// (alongside `@:fmt(atomOperand)`) so `cast (x)` / `cast (x:Int)`
			// (operand = `ParenExpr` / `ECheckTypeExpr` at atom level) emit
			// tight `cast(x)` / `cast(x : Int)` per haxe-formatter's
			// cast-as-function-call convention, while bare `cast x` (operand
			// = `IdentExpr`, anything not listed) keeps the existing
			// `cast x` shape. Sub-call's `parseXxxAtom` routing ensures
			// operand truly is the leading-`(` ctor, not a Pratt wrapper
			// (`Is(ParenExpr, ...)`) that would slip past the ctor match.
			final ctorTightSpace:Null<Expr> = stripKwTrailingSpace
				? null
				: kwTrailingSpaceOnOperandCtor(branch, argNames);
			final kwTrailSpace:Null<Expr> = kwSidePolicySpace ?? parenSidePolicySpace ?? ctorTightSpace;
			final parts:Array<Expr> = [];
			if (kwLead != null) {
				if (kwTrailSpace != null) {
					parts.push(macro _dt($v{kwLead}));
					parts.push(kwTrailSpace);
				} else if (branch.fmtHasFlag('deferKwSpace') && !stripKwTrailingSpace) {
					// ω-multivar-wrap one_line: opt-in `@:fmt(deferKwSpace)` on a
					// kw-led single-Ref ctor emits the kw's trailing space as a
					// deferred `_dop(' ')` (OptSpace) instead of a hard `_dt(kw ')`.
					// The renderer flushes it as a real space before the next Text
					// (flat / head-inline cases — byte-identical), but DROPS it when
					// the sub-call leads with a break-mode hardline. Used by
					// `HxStatement.VarStmt` / `FinalStmt`: when the `HxVarDecl`
					// body routes its `more` list through `multiVarWrap` with
					// `defaultWrap: onePerLine`, the head binding breaks too
					// (`var\n\trawRead,…`), so the `var `
					// trailing space must collapse into the break — mirror of the
					// assign-op `=`→`_dop(' ')` split (ω-binop-wraprules).
					parts.push(macro _dt($v{kwLead}));
					parts.push(macro _dop(' '));
				} else {
					final kwText:String = stripKwTrailingSpace ? kwLead : kwLead + ' ';
					parts.push(macro _dt($v{kwText}));
				}
			}
			if (leadText != null) {
				// ω-kw-word-lead-spacing (Slice 37): word-keyword lead
				// also gets a trailing space so it doesn't fuse with the
				// body's first token (e.g. `static final @Test` —
				// HxVarDecl's first field is a meta Star). Symbol leads
				// stay tight as before — the open delim glues to whatever
				// follows.
				// Writer Slice 4: opt-in `@:fmt(spaceAfterLead)` on a
				// symbol-lead enum ctor adds a trailing space — used by
				// `HxAnonField.ExtendsField` (`@:lead('>')`) to emit
				// `> Foo` matching haxe-formatter's structure-extension
				// convention (`typedef Bar = { > Foo, ... }`).
				final spaceAfterLead:Bool = branch.fmtHasFlag('spaceAfterLead');
				final leadEmit:String = (leadIsWord || spaceAfterLead) ? leadText + ' ' : leadText;
				parts.push(macro _dt($v{leadEmit}));
			}
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
				// Writer Slice 9: opt-in `@:fmt(spaceBeforeTrail)` on the
				// enum ctor inserts a leading space into the trail literal
				// so a word-start trail (e.g. `#end`) does not fuse with
				// the body's last word character. Mirror of Slice 4's
				// `spaceAfterLead` for the trail emit. Used by
				// `HxType.ConditionalType` (`@:kw('#if') @:trail('#end')`)
				// so `#if cond WebGLContext #end` re-emits the leading
				// space rather than `WebGLContext#end`.
				final trailEmit:String = branch.fmtHasFlag('spaceBeforeTrail')
					? ' ' + trailText
					: trailText;
				final trailExpr:Expr = if (isTriviaTrailOpt) {
					final flagAccess:Expr = macro $i{argNames[1]};
					macro $flagAccess ? _dt($v{trailEmit}) : _de();
				} else {
					trailOptShapeGateWrap(branch, trailEmit, argNames[0])
						?? macro _dt($v{trailEmit});
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
				// ω-hardflatten (increment-2): expression-paren collapse
				// consumer (C2a/B). Ctor opted into
				// `@:fmt(expressionParenHardFlatten)` (HxExpr.ParenExpr).
				// Emit `IfFullLineExceeds(opt.lineWidth, OPEN, GLUED)`:
				//  - GLUED  `(<inner>)` — flat-side, byte-identical to the
				//    pre-slice concat. Taken when the full rendered line
				//    (paren + everything trailing it on the same source line)
				//    fits within `lineWidth`.
				//  - OPEN   `(\n\t<HardFlatten(inner)>\n)` — break-side. The
				//    paren opens; the inner subtree is pinned force-flat via
				//    `HardFlatten` so an inner opAddSub chain collapses to ONE
				//    line UNCONDITIONALLY (fork `collapseInnerChainBreaks`).
				// The enclosing op-chain's outer-collapse (`) / 2 - D` riding
				// the close-paren line, fork `collapseChainBreaksAfter`) is
				// resolved by `CollapsePass` — the Doc→Doc pre-render pass that
				// reads which parens WOULD open (the `IfFullLineExceeds`
				// decision) and commits the chain to its glued shape, breaking
				// the branch-blind circular coupling.
				if (branch.fmtHasFlag('expressionParenHardFlatten')) {
					// Leading-hardline (opBool/ternary already one-per-line)
					// defer-open shape. Honors `captureWrapOpenNewline`: when the
					// source had a `\n` after the open delim, the break shape
					// opens `(\n<inner>\n)` (first operand on its own line —
					// fork issue_187_oneline `!(\n a.y…)`); otherwise the glued-
					// open `(<inner>\n)`. Computed at macro time so the null-
					// `wrapOpenNewlineExpr` case (plain mode / no opt-in) is not
					// spliced.
					final hardlineOpenShape:Expr = wrapOpenNewlineExpr != null
						? macro($wrapOpenNewlineExpr
							? _dc([$leadDoc, _dhl(), _wrapInner, _dhl(), _wrapTrail])
							: _dc([$leadDoc, _wrapInner, _dhl(), _wrapTrail]))
						: macro _dc([$leadDoc, _wrapInner, _dhl(), _wrapTrail]);
					// ω-keep-chain (increment: opbool-expr-paren-keep): an
					// expression paren whose inner is a kept chain that DID NOT
					// open with a leading hardline (head glued to the open delim,
					// only INTERNAL operator gaps broke — the `return !(chain)`
					// shape) is invisible to the `startsWithHardline` gate below,
					// so it falls through to the width-driven `_dfle` collapse
					// (glued head, no `(`-indent, glued `)`). When the source
					// placed a newline right after the open delim
					// (`wrapOpenNewlineExpr`) AND the inner already broke
					// (`flatLength < 0`, the kept chain reproduced its source
					// `||`/`+` gaps), open the paren condition-style:
					// `( + Nest(cols, [hardline, inner]) + hardline + )`. The
					// inner chain own continuation `Nest` is already suppressed
					// (cols=0) and its `_headBreak` dropped via `_keepChainInParen`
					// (set at the `ctorOptArg` site), so the PAREN `Nest(cols)`
					// supplies the +cols indent (head + every `||` continuation at
					// outer+cols) and the leading `Line` supplies the head break —
					// mirroring `WrapList.emitCondition` `brkShape` for the
					// `if (\n cond \n)` keep case. Computed at macro time so the
					// null-`wrapOpenNewlineExpr` case (plain / no opt-in) is not
					// spliced; the runtime `flatLength` gate keeps it byte-inert for a
					// flat (non-broken) paren content and for non-keep configs (where
					// the inner does not source-break). `_keepFlatInner` (operand of a
					// kept chain) is excluded by the outer ternary below.
					final keepOpenGate:Expr = wrapOpenNewlineExpr != null
						? macro($wrapOpenNewlineExpr
							&& anyparse.format.wrap.WrapList.flatLength(_wrapInner) < 0)
						: macro false;
					return macro {
						final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space
							? opt.indentSize : opt.tabWidth;
						final _wrapInner:anyparse.core.Doc = $innerDoc;
						final _wrapTrail:anyparse.core.Doc = $trailDoc;
						// ω-keep-chain (increment: opadd_chain_keep): when this expr
						// paren is an operand of a `WrapMode.Keep` chain
						// (`opt._keepFlatInner`, set on the leaf-operand opt at the
						// chain emit), the kept chain preserves source line structure
						// verbatim — its operand lines may exceed `lineWidth`. The
						// inner paren must therefore stay GLUED `(<inner>)`
						// UNCONDITIONALLY, NOT re-open via the width-driven
						// `IfFullLineExceeds` probe below (which would force
						// `(\n\tHardFlatten(inner)\n)`). Mirrors fork `keep2`'s
						// `noLineEndBefore` lock on operand-interior boundaries.
						// Byte-identical to the existing GLUED flat side, so a
						// standalone expr paren (flag false) is byte-inert.
						opt._keepFlatInner
							? _dc([$leadDoc, _wrapInner, _wrapTrail])
						// Operator-class gate (design-inc2 Step B, refined): the
						// HardFlatten inner-collapse mirrors fork's (`:`-branch below).
						// `collapseInnerChainBreaks` which matches ONLY
						// opAdd/opSub. Route by the inner's TOP-LEVEL operator
						// class:
						//  - leading-hardline inner (opBool/ternary already
						//    committed one-per-line at the chain level) → defer
						//    ENTIRELY to the pre-existing `@:wrap`
						//    close-on-own-line behavior, byte-identical to
						//    baseline. Covers issue_187_oneline.
						//  - pure opAddSub chain (the anchor) →
						//    `IfFullLineExceeds(open + HardFlatten(inner),
						//    glued)`; the inner opAddSub chain is pinned flat
						//    unconditionally once the paren opens
						//    (`collapseInnerChainBreaks`), and `CollapsePass`
						//    reads the open decision to glue the enclosing
						//    chain's tail onto the close-paren line
						//    (`collapseChainBreaksAfter`).
						//  - opBool / ternary inner (NOT pure opAddSub, NOT
						//    leading-hardline) → `IfFullLineExceeds(open +
						//    PLAIN inner, glued)`: the paren opens when the full
						//    line exceeds, but the inner is NOT hard-flattened —
						//    its own wrap cascade decides flatten-vs-break at the
						//    deeper paren indent. This matches the fork: opBool
						//    that fits at the deeper indent stays flat
						//    (opbool_inner_chain_additional_indent /
						//    opboolchain_paren_fillline), opBool/ternary that
						//    overflows keeps its per-operator break. `CollapsePass`
						//    ignores this branch (no HardFlatten marker), so the
						//    renderer's own `IfFullLineExceeds` resolves the open.
						: anyparse.format.wrap.WrapList.startsWithHardline(_wrapInner)
							? _dg(_dib(
								$hardlineOpenShape,
								_dc([$leadDoc, _wrapInner, _wrapTrail])
							))
						// ω-keep-chain (increment: opbool-expr-paren-keep): the kept
						// chain head glued to `(` (no leading hardline) + only internal
						// `||`/`+` gaps broke. `startsWithHardline` is false here, so
						// without this branch the paren falls into the width `_dfle`
						// collapse. Open condition-style (mirror `emitCondition.brkShape`):
						// the inner chain already nestSuppressed (cols=0) + headBreak-
						// dropped, so the PAREN supplies `Nest(cols, [hardline, inner])`
						// (head + every continuation at outer+cols) and the trailing
						// hardline puts `)` on its own line. Gated runtime on
						// `keepOpenGate` (source open-newline + inner broke) → byte-inert
						// otherwise. Ordered AFTER the `startsWithHardline` branch
						// (disjoint: that branch owns the inner-LEADS-with-hardline
						// shape — onePerLine chains, whose own Nest must not be
						// double-bumped by this branch's `Nest(cols)`); this branch
						// fires only for a glued-head kept chain where
						// `startsWithHardline` is false.
						: $keepOpenGate
							? _dc([$leadDoc, _dn(_cols, _dc([_dhl(), _wrapInner])), _dhl(), _wrapTrail])
							: anyparse.format.wrap.WrapList.isPureOpAddSubChain(_wrapInner)
								? (
									// ω-expr-paren-in-condition (cond F2): when this expr
									// paren sits inside a condition (`opt._parenInCondition`)
									// AND `expressionWrapping` is configured fillLine, its
									// inner opAddSub chain was emitted under a fillLine
									// `_chainModeOverride` (threaded at `ctorOptArg`) and
									// carries its OWN fillLine break shape. Open the paren on
									// the RAW full-line-exceeds verdict (NO `_dcp`
									// CollapseProbe — the inner is fillLine-wrapped, not a
									// collapse candidate) and render the chain's plain break
									// shape at the deeper paren indent. The fork fillLine-
									// wraps expr-paren content inside a condition. Without the
									// flag (every standalone expr paren, e.g.
									// `expression_paren_wrapping`) keep the unconditional
									// HardFlatten collapse via the `_dcp(_dhf(...))`
									// CollapseProbe — byte-inert.
									opt._parenInCondition
										&& anyparse.format.wrap.WrapList.effectiveExpressionWrapMode(opt.expressionWrappingWrap) != null
										? _dfle(
											opt.lineWidth,
											_dc([
												$leadDoc,
												_dn(_cols, _dc([_dhl(), _wrapInner])),
												_dhl(),
												_wrapTrail
											]),
											_dc([$leadDoc, _wrapInner, _wrapTrail])
										)
										: _dfle(
											opt.lineWidth,
											_dc([
												$leadDoc,
												_dn(_cols, _dc([_dhl(), _dcp(_dhf(_wrapInner))])),
												_dhl(),
												_wrapTrail
											]),
											_dc([$leadDoc, _wrapInner, _wrapTrail])
										)
								)
								: _dfle(
									opt.lineWidth,
									_dc([
										$leadDoc,
										_dn(_cols, _dc([_dhl(), _dcp(_wrapInner)])),
										_dhl(),
										_wrapTrail
									]),
									_dc([$leadDoc, _wrapInner, _wrapTrail])
								);
					};
				}
				// omega-paren-wrap-source-newline: when the ctor opted into
				// `@:fmt(captureWrapOpenNewline)` and the parser captured a
				// source `\n` between open delim and inner sub-rule's first
				// token, route the break shape to `(\n<inner>\n)` (open
				// followed by hardline + close on its own line). The inner's
				// own leading `OptHardlineSkipAtOpenDelim` collides with the
				// freshly-emitted hardline and drops via the renderer's
				// hardline-collision branch -- net output is `(\n<item0>\n…\n)`.
				// When the source had no leading newline (or the ctor didn't
				// opt in / plain mode), fall back to the pre-slice shape
				// `(<inner>\n)` from the chain emit's open-delim glue.
				if (wrapOpenNewlineExpr != null) {
					return macro {
						final _wrapInner:anyparse.core.Doc = $innerDoc;
						final _wrapTrail:anyparse.core.Doc = $trailDoc;
						anyparse.format.wrap.WrapList.startsWithHardline(_wrapInner)
							? _dg(_dib(
								$wrapOpenNewlineExpr
									? _dc([$leadDoc, _dhl(), _wrapInner, _dhl(), _wrapTrail])
									: _dc([$leadDoc, _wrapInner, _dhl(), _wrapTrail]),
								_dc([$leadDoc, _wrapInner, _wrapTrail])
							))
							: _dc([$leadDoc, _wrapInner, _wrapTrail]);
					};
				}
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

			final case3Doc:Expr = if (parts.length == 1) parts[0]
			else dcCall(parts);
			// ω-cond-indent-policy FixedZero/AlignedDecrease: a cond-comp ctor
			// opting into `@:fmt(conditionalMarkerDedent)` (the `#if … #end`
			// `HxStatement`/`HxClassMember`/`HxDecl` `Conditional` ctors) wraps
			// its whole construct Doc in a render-time marker scope:
			//  - `FixedZero` → `_dcmz` (ConditionalMarkerZero): every `#`-leading
			//    fresh line (`#if`/`#elseif`/`#else`/`#end`, incl. nested ones)
			//    flushes at column 0 while body content keeps its frame indent.
			//  - `AlignedDecrease` → `_dcmd` (ConditionalMarkerDecrease): EVERY
			//    fresh line (markers AND body) shifts one indent level shallower,
			//    moving the increase-style body accumulation (already applied via
			//    `condIncreaseGateExpr`, which also fires for `AlignedDecrease`)
			//    `-1` uniformly.
			// Every other policy (`Aligned` default, `AlignedIncrease`, …) leaves
			// the ctor unwrapped → byte-identical.
			return branch.fmtHasFlag('conditionalMarkerDedent')
				? macro (opt.conditionalPolicy == anyparse.format.ConditionalIndentationPolicy.FixedZero
					? _dcmz($case3Doc)
					: (opt.conditionalPolicy == anyparse.format.ConditionalIndentationPolicy.AlignedDecrease
						? _dcmd($case3Doc)
						: $case3Doc))
				: case3Doc;
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
		// ω-issue-423-mech-a: ctor-level `@:fmt(propagateExprPosition)` on a
		// postfix-Star ctor (e.g. `HxExpr.Call`, `HxNewExpr`) wraps each
		// element's opt arg in `_setExprPosition` so call/ctor args land in
		// expression-position and any case body deeper than them picks
		// `expressionCase` via the dispatched flat-gate.
		final propagateExpr:Bool = branch.fmtHasFlag('propagateExprPosition');
		// ω-callarg-chain-nest: ctor-level `@:fmt(callArgChainNest)` opt-in on a
		// call-arg postfix Star (`HxExpr.Call`). When the call uses leading-break
		// wrapping (`callParameterWrap.defaultMode == FillLineWithLeadingBreak`),
		// the per-element opt is wrapped in `_setCallArgChainNest` so a chain
		// argument suppresses its own continuation Nest — the leading-break
		// call-arg Nest already supplies the +cols indent. Runtime-gated on the
		// cascade default (mirror of the condWrap `_chainModeOverride` path);
		// consumed exactly once at the chain dispatch via `_clearCallArgChainNest`.
		// `wrapRulesField` is read here (and reused by the sepList dispatch below)
		// so the per-element opt and the args-list cascade share one lookup.
		final wrapRulesField:Null<String> = branch.fmtReadString('wrapRules');
		final wantChainNest:Bool = branch.fmtHasFlag('callArgChainNest');
		// ω-keep-callclose-newline: the postfix-Star ctor that drives method
		// chains (`HxExpr.Call`) carries `@:fmt(methodChain('<field>'))`. When the
		// chain config is `Keep`, a chain sole-arg renders source-faithfully via
		// `MethodChainEmit.shapeKeep` — a length-2-Nest shape that
		// `shapeFillLine`'s `isChainOPLBreak` cannot tell apart from a genuine
		// OnePerLine chain, so it would force the OUTER call's close `)` onto its
		// own line. Under Keep we instead follow the source: keep `)` glued unless
		// the parser recorded a newline before it (`argsCloseNewline`). The signal
		// is computed only when the ctor carries both `methodChain` and is a
		// trivia Star (the parser-captured slot exists); every other postfix Star
		// passes the engine default `keepCloseGlued = false` and stays byte-inert.
		final methodChainField:Null<String> = branch.fmtReadString('methodChain');
		var elemOptArg:Expr = propagateExpr ? macro _setExprPosition(opt) : macro opt;
		if (wantChainNest && wrapRulesField != null) {
			final wrapRulesAccess:Expr = optFieldAccess(wrapRulesField);
			elemOptArg = macro $wrapRulesAccess.defaultMode == anyparse.format.wrap.WrapMode.FillLineWithLeadingBreak
				? _setCallArgChainNest($elemOptArg)
				: $elemOptArg;
		}
		final elemCallArgs:Array<Expr> = [elemRead, elemOptArg];
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
		// ω-call-parens-inside (Stage B): `@:fmt(callParensInside)` opts the
		// call-arg `(`/`)` into runtime inner padding driven by
		// `opt.callParensInsideOpen` / `opt.callParensInsideClose` (the
		// `after`/`before` sub-policies of fork's `parenConfig.callParens`).
		// Threaded into the WrapList.emit / fillList / sepList `openInside` /
		// `closeInside` slots (the same slots `triviaSepStarExpr` uses for
		// anon-type braces). Default `None` on both → `_de()`, byte-identical
		// to the tight `bar1(x)`. Empty `()` short-circuits before padding in
		// every emit path (`items.length == 0` guard).
		final callInsideFlag:Bool = branch.fmtHasFlag('callParensInside');
		var callInsideOpen:Expr = callInsideFlag
			? policyInsideSpace('callParensInsideOpen', false)
			: macro _de();
		final callInsideClose:Expr = callInsideFlag
			? policyInsideSpace('callParensInsideClose', true)
			: macro _de();
		// ω-compress-successive-paren: mirror fork's
		// `whitespace.compressSuccessiveParenthesis` for a paren-call open
		// `(` immediately followed by an object-literal `{` argument. The
		// fork's `successiveParenthesis` keeps the brace's `Before` policy
		// space (`( {`) when the knob is `false`, and removes it (`({`) when
		// `true`. In anyparse the inter-bracket pad lives in the WrapList /
		// fillList / sepList `openInside` slot — so when the open delim is a
		// `(` (compile-time `postfixOp == '('`) we make `openInside` a
		// runtime-conditional space: emit `_dt(' ')` iff
		// `!opt.compressSuccessiveParenthesis` AND the first call argument
		// renders as an object literal (its enum ctor is `ObjectLit`). Only
		// the first arg can sit directly after `(` (later args are preceded
		// by `, `), so the check is on `_args[0]`. Default `true` keeps the
		// glued `TPath({…})` layout byte-identical. `_args` is in scope where
		// this Expr is spliced (the emit call sits inside the
		// `final _args = $argsAccess; …` body). Trivia mode wraps each elem in
		// `Trivial<T>` (`.node` holds the paired enum); plain mode is the raw
		// enum — mirror `elemRead`'s `isTriviaStar` branch.
		if (postfixOp == '(') {
			final firstArgNode:Expr = isTriviaStar ? macro _args[0].node : macro _args[0];
			final firstArgObjLit:Expr = macro _args.length > 0
				&& Type.enumConstructor(cast $firstArgNode) == 'ObjectLit';
			callInsideOpen = macro !opt.compressSuccessiveParenthesis && $firstArgObjLit
				? _dt(' ')
				: $callInsideOpen;
		}
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
		final useFill:Bool = branch.fmtHasFlag('fill');
		final fillDouble:Bool = branch.fmtHasFlag('fillDoubleIndent');
		final sepListCall:Expr = if (wrapRulesField != null) {
			final rulesExpr:Expr = optFieldAccess(wrapRulesField);
			// ω-keep-callclose-newline: keep the outer call's close `)` glued iff
			// the chain config is Keep AND the parser saw no newline before the
			// close (`argsCloseNewline == false`). Only a trivia Star carrying
			// `methodChain` has the parser slot; otherwise the signal is constant
			// `false` (byte-inert legacy close placement).
			final keepCloseGluedExpr:Expr = (isTriviaStar && methodChainField != null)
				? {
					final chainRulesExpr:Expr = optFieldAccess(methodChainField);
					final closeNlExpr:Expr = {expr: EConst(CIdent(argNames[4])), pos: Context.currentPos()};
					macro $chainRulesExpr.defaultMode == anyparse.format.wrap.WrapMode.Keep && !$closeNlExpr;
				}
				: macro false;
			final wrapListExpr:Expr = macro anyparse.format.wrap.WrapList.emit(
				$v{postfixOp}, $v{postfixClose}, $v{elemSep}, _docs, opt,
				$callInsideOpen, $callInsideClose, false, $rulesExpr, $tcExpr,
				_de(), _de(), false, null, null, false, false,
				null, false, null, $keepCloseGluedExpr
			);
			if (isTriviaStar) {
				// ω-D9A-keep-callargs: when the wrap-rules' runtime config
				// sets `defaultMode == WrapMode.Keep`, bypass the cascade
				// and build the args list Doc by hand — `_dhl()` between
				// args when source had `\n` before the next arg
				// (`Trivial<T>.newlineBefore`), `_dt(' ')` otherwise.
				//
				// ω-D9A-keep-callargs-v2: args[0]'s leading source-vertical
				// signal is captured by a dedicated parser slot
				// `argsOpenNewline` (positional `argNames[3]`, sibling of
				// `closeTrailing` at `argNames[2]`). `Trivial<T>.newlineBefore`
				// for args[0] is unreliable because upstream kw-Ref rules
				// (e.g. `catch (e:E)\n\t\ttrace(e);`) drain `ctx.pendingTrivia`
				// into the first `collectTrivia`. The slot is captured BEFORE
				// the per-iter `skipWs(ctx)` so the post-open `\n` is
				// preserved verbatim. Inter-arg signals (i ≥ 1) stay on
				// `Trivial.newlineBefore` — captured by the loop's
				// `collectTrivia(ctx)` AFTER the previous sep, where
				// pendingTrivia is already drained.
				//
				// When `argsOpenNewline=true` the emit also adds a trailing
				// `_dhl()` between the last arg and the close lit so the
				// source-vertical fixture's `\n)` shape round-trips. Sister
				// to `triviaSepStarExpr`'s `ω-keep-objectlit` per-element
				// source-aware leading.
				//
				// JSON-driven: the loader maps `"defaultWrap": "keep"` on
				// the named wrap-rules section → `Keep`. Default
				// `NoWrap` cascades route to `wrapListExpr` (legacy
				// byte-identical).
				final argsOpenNewlineExpr:Expr = {expr: EConst(CIdent(argNames[3])), pos: Context.currentPos()};
				final keepDoc:Expr = macro {
					final _kArgsOpenNewline:Bool = $argsOpenNewlineExpr;
					final _kInner:Array<anyparse.core.Doc> = [];
					var _kj:Int = 0;
					while (_kj < _docs.length) {
						if (_kj > 0)
							_kInner.push(_args[_kj].newlineBefore ? _dhl() : _dt(' '));
						else if (_kArgsOpenNewline)
							_kInner.push(_dhl());
						_kInner.push(_docs[_kj]);
						final _kIsLast:Bool = _kj == _docs.length - 1;
						if (!_kIsLast)
							_kInner.push(_dt($v{elemSep}));
						else if ($tcExpr)
							_kInner.push(_dt($v{elemSep}));
						_kj++;
					}
					final _kCols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
					final _kOuter:Array<anyparse.core.Doc> = [
						_dt($v{postfixOp}),
						_dn(_kCols, _dc(_kInner)),
					];
					if (_kArgsOpenNewline) _kOuter.push(_dhl());
					_kOuter.push(_dt($v{postfixClose}));
					_dwb(_dc(_kOuter));
				};
				macro $rulesExpr.defaultMode == anyparse.format.wrap.WrapMode.Keep ? $keepDoc : $wrapListExpr;
			} else {
				wrapListExpr;
			}
		} else if (useFill) {
			macro fillList($v{postfixOp}, $v{postfixClose}, $v{elemSep}, _docs, opt, $tcExpr, $callInsideOpen, $callInsideClose, false, $v{fillDouble});
		} else {
			macro sepList($v{postfixOp}, $v{postfixClose}, $v{elemSep}, _docs, opt, $tcExpr, $callInsideOpen, $callInsideClose, false, false);
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
		// ω-postfix-call-trailing: when the synth pair grew a
		// `closeTrailing:Null<String>` slot (gated by `isTriviaStar`,
		// which is the same predicate as `isPostfixCloseTrailingBranch`
		// at this site), append `trailingCommentDocVerbatim(_trailClose,
		// opt)` after the call's emitted Doc when non-null. The slot
		// holds a same-line trailing `// c` / `/* c */` between `)` and
		// the next expression boundary — captured by Lowering's
		// `lowerPostfixLoop` Star-suffix trivia branch. For chain Calls
		// the chain extractor (`wrapWithChainDispatch`) handles the same
		// slot per segment via its own dispatch; this default-path
		// emission covers non-chain single Calls.
		final tailExpr:Expr = isTriviaStar
			? {
				final closeTrailRef:Expr = {
					expr: EConst(CIdent(argNames[2])),
					pos: Context.currentPos(),
				};
				macro {
					final _dcResult:anyparse.core.Doc = $dcExpr;
					final _trailClose:Null<String> = $closeTrailRef;
					_trailClose != null
						? _dc([_dcResult, trailingCommentDocVerbatim(_trailClose, opt)])
						: _dcResult;
				};
			}
			: dcExpr;
		return macro {
			final _args = $argsAccess;
			final _docs:Array<anyparse.core.Doc> = [];
			var _i:Int = 0;
			while (_i < _args.length) {
				$pushElemExpr;
				_i++;
			}
			$tailExpr;
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

		// ω-arrow-lambda-body-context: enum-Case Star branches opting into
		// `@:fmt(leftCurlyAnonFnOverride('<knob>'))` (currently
		// `HxExpr.BlockExpr`) prepend a runtime-gated hardline before the
		// open delimiter — when the writer was descended through
		// `@:fmt(propagateAnonFnContext)` (parent flips `_inAnonFnBody=true`
		// via `_setAnonFnBody`) AND the named knob is `Next`, the hardline
		// fires and the renderer drops the parent's preceding `_dop(' ')`
		// OptSpace (e.g. `arrowFunctions=Both` after `->`), placing `{` on
		// its own line at the parent indent. When the override knob is
		// `Same` OR `_inAnonFnBody=false` (non-lambda context like
		// `HxIfExpr.thenBranch` reaching `BlockExpr`), the prefix is `_de()`
		// and the pre-slice cuddled `{` layout is preserved. The flag is
		// then cleared on per-element opt by `triviaBlockStarExpr` so
		// nested BlockExpr inside body statements falls back to default
		// `blockLeftCurly`.
		final anonFnOverrideKnob:Null<String> = branch.fmtReadString('leftCurlyAnonFnOverride');
		if (anonFnOverrideKnob != null) {
			final knobAccess:Expr = optFieldAccess(anonFnOverrideKnob);
			final nextPat:Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BracePlacement', 'Next']);
			parts.push(macro opt._inAnonFnBody && $knobAccess == $nextPat ? _dhl() : _de());
		}

		final isTriviaStar:Bool = ctx.trivia && starNode.annotations.get('trivia.starCollects') == true;
		if (isTriviaStar) {
			// ω-close-trailing-alt: same-line trailing comment captured
			// after the close literal (`} // catch`). The synth ctor
			// grew a positional arg (`closeTrailing`) and `argNames[1]`
			// is its writer-side binding. Plain mode keeps the pre-slice
			// null path (no extra arg, no extra binding).
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
			final hasOrphan:Bool = TriviaTypeSynth.isAltCloseTrailingBranch(branch)
				&& branch.readMetaString(':lead') != null
				&& !branch.hasMeta(':tryparse');
			final trailCloseAccess:Null<Expr> = TriviaTypeSynth.isAltCloseTrailingBranch(branch)
				? macro $i{argNames[1]}
				: null;
			final trailOpenAccess:Null<Expr> = hasOrphan
				? macro $i{argNames[2]}
				: null;
			// ω-orphan-trivia-alt: orphan trivia between the last Star
			// element and the close literal (e.g. trailing line comment
			// inside `try { p(); /* dropped */ }`). Synth grew two
			// positional args (`trailingBlankBefore` at `argNames[3]`,
			// `trailingLeading` at `argNames[4]`) for `isAltCloseTrailingBranch`
			// branches with `@:lead`. The Lowering Case 4 trivia loop
			// captures `_lead.blankBefore` / `_lead.leadingComments` on
			// close-peek break and forwards them. Without this, an inner
			// `// foo` between the last stmt and `}` is dropped at parse —
			// `collectTrivia` runs on the final iteration but its result is
			// discarded on the break.
			final trailBBAccess:Null<Expr> = hasOrphan
				? macro $i{argNames[3]}
				: null;
			final trailLCAccess:Null<Expr> = hasOrphan
				? macro $i{argNames[4]}
				: null;
			// ω-arraylit-source-trail-comma: enum-Alt sep+trail+lead+@:trivia
			// branches grow a 6th positional `trailPresent:Bool` (synth pushes
			// it inside the `isAltCloseTrailingBranch + @:lead + !@:tryparse`
			// block when `branch.readMetaString(':sep') != null`). Bind here so
			// the trivia branch of `triviaSepStarExpr` can preserve a source
			// trailing comma via `appendTrailingCommaExpr = trailPresent ||
			// knob`. Sister to struct-Star `<field>TrailPresent` binding in
			// `lowerStruct`.
			final hasSepTrailPresent:Bool = hasOrphan && sepText != null;
			final sepTrailPresentAccess:Null<Expr> = hasSepTrailPresent
				? macro $i{argNames[5]}
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
			// ω-blockended-trivia (Session 3): enum-Alt mirror — when the
			// trivia-mode `@:sep+@:lead+@:trail` branch carries the
			// `blockEnded` flag (HxStatement.BlockStmt / HxExpr.BlockExpr
			// after Session 3 migration), skip the `triviaSepStarExpr`
			// flat-or-multi dispatch and fall through to the block-mode
			// dispatch with sepText/blockEnded threaded into
			// `triviaBlockStarExpr`.
			final altBlockEndedFlag:Bool = branch.annotations.get('lit.sepBlockEnded') == true;
			if (sepText != null && !altBlockEndedFlag) {
				final wrapRulesField:Null<String> = branch.fmtReadString('wrapRules');
				// ω-arraylit-trailing-comma-dispatch: enum-Alt branches
				// (e.g. `HxExpr.ArrayExpr`) carry `@:fmt(trailingComma(
				// '<knob>'))` but the trivia-mode emit at this site
				// previously hardcoded `null, null` for `triviaSepStarExpr`'s
				// 13th/14th params, ignoring the knob entirely. Sister
				// dispatch-dual-path gap to [[feedback-wraprules-dispatch-
				// dual-path]] — the struct-Star path at `lowerStruct`
				// already threads `trailingCommaField`. Companion sibling
				// `ω-arraylit-source-trail-comma` adds the 13th param's
				// counterpart via a synth-side positional `trailPresent:
				// Bool` slot (no `<field>TrailPresent` named struct field —
				// Alt ctors are positional, so synth pushes the slot under
				// the `isAltCloseTrailingBranch + @:lead + !@:tryparse +
				// @:sep` gate; writer binds it via `argNames[5]` as
				// `sepTrailPresentAccess` below). With both, the trivia-
				// sep helper's `appendTrailingCommaExpr` engages identically
				// to the struct-Star path: `trailPresent || knob`.
				final trailingCommaField:Null<String> = branch.fmtReadString('trailingComma');
				// ω-trivia-sep-anontype-braces (Phase B1): forward the
				// `anonTypeBracesOpen/Close` policy via
				// `delimInsidePolicySpace` so the trivia-mode emit honours
				// inside-brace whitespace exactly like the non-trivia
				// branch (line ~1257). Branches without the flag get null
				// → helper falls back to `_de()` (no spaces inside).
				final openInsideExpr:Null<Expr> = delimInsidePolicySpace(branch, ['anonTypeBracesOpen'], false);
				final closeInsideExpr:Null<Expr> = delimInsidePolicySpace(branch, ['anonTypeBracesClose'], true);
				// ω-trivia-sep-doc-comment-cascade (Phase B2): forward the
				// `beforeDocCommentEmptyLines` flag so sep-Stars opt into
				// the cascade (currently only `HxType.Anon.fields`).
				final beforeDocComments:Bool = branch.fmtHasFlag('beforeDocCommentEmptyLines');
				// ω-anontype-left-curly: forward `@:fmt(leftCurly('<knob>'))`
				// from the enum-Alt branch so `HxType.Anon` honours per-
				// construct `anonTypeLeftCurly`. When `Next`, the helper's
				// trivia branch prepends `_doh()` (OptHardline) before the
				// `{`, and the no-trivia branch feeds the same Doc into
				// `WrapList.emit`'s `(leadFlat=_de(), leadBreak=_doh())`
				// pair so the wrap engine's flat/break decision picks
				// cuddled vs Allman per the anon-type's measured shape.
				// Mirrors the struct-Star `lowerStruct` path at
				// `HxObjectLit.fields`.
				final knobLeftCurly:Null<String> = branch.fmtReadString('leftCurly');
				// ω-anontype-right-curly: call-form `@:fmt(rightCurly('<knob>'))`
				// names a per-construct `RightCurlyPlacement` opt field that
				// the trivia branch of `triviaSepStarExpr` reads. Currently
				// consumed by `HxType.Anon` for `anonTypeRightCurly`. Null
				// (no opt-in or bare flag) falls back to unconditional
				// `_dhl()` before close.
				final knobRightCurly:Null<String> = branch.fmtReadString('rightCurly');
				// ω-typedef-anon-force-multi: enum-Alt branch reader for
				// `@:fmt(forceMultiInTypedef)` on `HxType.Anon`. Threads the
				// flag into `triviaSepStarExpr` so the no-trivia branch
				// emits a runtime `opt._inTypedefBody ? WrapMode.OnePerLine
				// : null` as `WrapList.emit`'s 15th `forceMode` arg. Closes
				// the `issue_301` typedef-anon source-flat → fork-multi
				// shape gap by forcing OnePerLine when the parent
				// `HxTypedefDecl.type` Ref has flipped `_inTypedefBody=true`
				// via `propagateTypedefContext`. Non-typedef anon callers
				// (var-type-hint, fn-return-type) stay cascade-driven.
				final forceMultiTypedef:Bool = branch.fmtHasFlag('forceMultiInTypedef');
				final bodyAware:Bool = branch.fmtHasFlag('bodyAwareCompactIndent');
				// ω-group-rest-probe slice 2: enum-Alt branch reader for
				// `@:fmt(groupRestProbe)`. Trivia-path mirror of the plain-
				// path read at lowerStruct's Star dispatch. Dual-dispatch
				// per [[feedback-wraprules-dispatch-dual-path]].
				final groupRestProbe:Bool = branch.fmtHasFlag('groupRestProbe');
				// ω-cascade-emits-comments: enum-Alt branch reader for
				// `@:fmt(ignoreSourceNewlinesForWrap)` — intrinsic
				// per-construct opt-in to fork's `Ignore` policy
				// (drop source newline signal, inline cascade-emittable
				// trivia). Currently no enum-Alt consumer opts in;
				// reader present for symmetry with the struct-path
				// dual-dispatch.
				final ignoreSourceNewlines:Bool = branch.fmtHasFlag('ignoreSourceNewlinesForWrap');
				// ω-bropen-keep-sep: forward `@:fmt(keepCurlyBlanks)` from
				// the enum-Alt branch into `triviaSepStarExpr`'s opt-in.
				// Sister to the trivia-block path's read at the else arm
				// (line ~1542); enables `HxType.Anon` to honour
				// `opt.afterLeftCurly` / `opt.beforeRightCurly` Keep.
				final keepCurlyBlanksAlt:Bool = branch.fmtHasFlag('keepCurlyBlanks');
					// ω-array-reflow: enum-Alt branch reader for
					// `@:fmt(reflowSourceMultiline)` — opt-in for source-
					// multiline lists (currently `HxExpr.ArrayExpr`) re-flowed
					// by the wrap cascade instead of forced one-per-line.
					// Threads into `triviaSepStarExpr`'s `_smlKeep` gate.
					final reflowSourceMultilineAlt:Bool = branch.fmtHasFlag('reflowSourceMultiline');
					// ω-bracket-config: enum-Alt branch reader for
					// `@:fmt(bracketKindPad)` (`HxExpr.ArrayExpr`). When set,
					// `triviaSepStarExpr` overrides the static open/close
					// inside-space Docs with a runtime dispatch on the first
					// element's bracket kind (array-literal / map / comprehension
					// → the matching `*BracketsOpen`/`*BracketsClose` policy).
					final bracketKindPadAlt:Bool = branch.fmtHasFlag('bracketKindPad');
					// ω-arraymatrix-wrap: enum-Alt branch reader for
					// `@:fmt(arrayMatrixWrap)` (`HxExpr.ArrayExpr`). Marks the
					// Star as matrix-eligible so `triviaSepStarExpr` attempts a
					// source-grid layout before the wrap cascade.
					final matrixWrapAlt:Bool = branch.fmtHasFlag('arrayMatrixWrap');
				parts.push(triviaSepStarExpr(
					argsAccess, trailBBAccess, trailLCAccess, trailCloseAccess, trailOpenAccess, elemFn, leadText, trailText, sepText,
					wrapRulesField, knobLeftCurly, knobRightCurly, sepTrailPresentAccess, trailingCommaField, openInsideExpr, closeInsideExpr, beforeDocComments,
					forceMultiTypedef, bodyAware, groupRestProbe, ignoreSourceNewlines, keepCurlyBlanksAlt, reflowSourceMultilineAlt, bracketKindPadAlt, matrixWrapAlt
				));
			} else {
				// ω-bropen-keep: forward `@:fmt(keepCurlyBlanks)` from the
				// enum-Case branch so non-type block bodies (BlockStmt,
				// BlockExpr) honour `opt.afterLeftCurly` /
				// `opt.beforeRightCurly` Keep policy. Sister to the
				// struct-Star path's read at the `lowerStruct` call site.
				final keepCurlyBlanks:Bool = branch.fmtHasFlag('keepCurlyBlanks');
				// ω-arrow-lambda-body-context: forward the override-meta
				// presence so the helper clears `_inAnonFnBody` for the
				// per-element write — see helper docstring for rationale.
				final anonFnClear:Bool = branch.fmtHasFlag('leftCurlyAnonFnOverride');
				// ω-blockempty: enum-Case branch may opt into empty-curly
				// break dispatch via `@:fmt(emptyCurlyBreak)` (bare or with
				// knob-name arg). Used by `HxStatement.BlockStmt` and
				// `HxExpr.BlockExpr` to route empty bodies through
				// `opt.blockEmptyCurly`.
				final emptyCurlyBreak:Bool = branch.fmtHasFlag('emptyCurlyBreak');
				final emptyCurlyKnobArgs:Null<Array<String>> = branch.fmtReadStringArgs('emptyCurlyBreak');
				final emptyCurlyKnob:Null<String> = (emptyCurlyKnobArgs != null && emptyCurlyKnobArgs.length >= 1)
					? emptyCurlyKnobArgs[0]
					: null;
				// ω-blockright-curly: call-form `@:fmt(rightCurly('<knob>'))`
				// names a per-construct RightCurlyPlacement opt field. The
				// bare form returns null and falls back to unconditional
				// `_dhl()` before close inside `triviaBlockStarExpr`.
				final rightCurlyKnobArgs:Null<Array<String>> = branch.fmtReadStringArgs('rightCurly');
				final rightCurlyKnob:Null<String> = (rightCurlyKnobArgs != null && rightCurlyKnobArgs.length >= 1)
					? rightCurlyKnobArgs[0]
					: null;
				// ω-anonfunction-right-curly: call-form
				// `@:fmt(rightCurlyAnonFnOverride('<knob>'))` names a
				// RightCurlyPlacement opt field that the dispatch reads
				// only when `_inAnonFnBody=true`. Sister to
				// `leftCurlyAnonFnOverride`. Pre-slice (no opt-in) falls
				// through to `_dhl()` for non-anon-fn contexts.
				final rightCurlyAnonFnArgs:Null<Array<String>> = branch.fmtReadStringArgs('rightCurlyAnonFnOverride');
				final rightCurlyAnonFnKnob:Null<String> = (rightCurlyAnonFnArgs != null && rightCurlyAnonFnArgs.length >= 1)
					? rightCurlyAnonFnArgs[0]
					: null;
				parts.push(triviaBlockStarExpr(
					argsAccess, trailBBAccess, trailLCAccess, trailCloseAccess, trailOpenAccess, elemFn,
					leadText, trailText, true, false, false, false, null, false, emptyCurlyBreak, false, keepCurlyBlanks,
					false, false, null, false, null, anonFnClear, emptyCurlyKnob, rightCurlyKnob, rightCurlyAnonFnKnob,
					// ω-blockended-trivia (Session 3): enum-Alt sep+blockEnded
					// routes here when `altBlockEndedFlag` fires; pass sepText
					// only in that case so unrelated callers stay byte-identical.
					// ω-condcomp-stray-semi (Stage A): thread the predicate name
					// + schema path so the inter-element sep consults the AST
					// shape (suppresses stray `;` after a `#if … #end` element).
					altBlockEndedFlag ? sepText : null, altBlockEndedFlag,
					altBlockEndedFlag ? (branch.annotations.get('lit.sepBlockEndedPredicate') : Null<String>) : null,
					altBlockEndedFlag ? formatInfo.schemaTypePath : null
				));
			}
		} else if (sepText != null && branch.annotations.get('lit.sepBlockEnded') == true) {
			// Block-ended exemption (Session 2 pilot — mirror of
			// `emitWriterStarField`). Suppress between-element sep
			// emission when EITHER:
			//   (a) the prior element's rendered Doc ends with `}` or `;`
			//       (`DocMeasure.endsWithStmtTerminator` — Session 8 widened
			//       from `endsWithCloseBrace` to include `;` so per-stmt
			//       `@:trail/@:trailOpt(';')` baked terminators suppress
			//       sep too), OR
			//   (b) the schema-instance predicate returns true on the prior
			//       element's AST (Session 7 option b2 — AST-shape adapter
			//       e.g. `Atom('end')` in the MiniBlockStrict pilot, or
			//       `HxStatement.Conditional(#if…#end)` whose byte-end
			//       `d` misses (a) but predicate matches the AST shape).
			// Mirrors the struct-field plain-mode site at L3845-3880 and
			// the parser-side blockEnded branch in `Lowering.emitStarFieldSteps`
			// (`b == '}'.code || b == ';'.code || $predicateCall`).
			// Strictly opt-in via `@:sep('text', tailRelax, blockEnded[('pred'[, sepStartsElement])])`.
			final predicateName:Null<String> = branch.annotations.get('lit.sepBlockEndedPredicate');
			final predicateCheckPrior:Expr = if (predicateName != null) {
				final fmtParts:Array<String> = formatInfo.schemaTypePath.split('.');
				{
					expr: ECall(
						{expr: EField(macro $p{fmtParts}.instance, predicateName), pos: Context.currentPos()},
						[macro _args[_i - 1]]
					),
					pos: Context.currentPos(),
				};
			} else macro false;
			parts.push(macro {
				final _args = $argsAccess;
				final _docs:Array<anyparse.core.Doc> = [_dt($v{leadText})];
				var _i:Int = 0;
				while (_i < _args.length) {
					final _elemDoc:anyparse.core.Doc = $elemCall;
					if (_i > 0) {
						final _priorDoc:anyparse.core.Doc = _docs[_docs.length - 1];
						final _priorEnds:Bool = anyparse.core.DocMeasure.endsWithSemi(_priorDoc) || $predicateCheckPrior;
						if (!_priorEnds) {
							_docs.push(_dt($v{sepText}));
							_docs.push(_dt(' '));
						}
					}
					_docs.push(_elemDoc);
					_i++;
				}
				_docs.push(_dt($v{trailText}));
				_dc(_docs);
			});
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
				// ω-bracket-config: `@:fmt(bracketKindPad)` (`HxExpr.ArrayExpr`,
				// plain-mode `sepList` path) overrides the static anonTypeBraces
				// inside-space with a runtime dispatch on the first element's
				// bracket kind. Reads `_args[0]` (the plain `HxExpr` element,
				// bound just below at the `final _args = $argsAccess` site).
				// `opt.arrayBracketKind` null-guards an empty list, so `_args[0]`
				// on `[]` resolves to the default `ArrayLiteral` → `_de()`,
				// keeping empty brackets tight.
				final bracketKindPad:Bool = branch.fmtHasFlag('bracketKindPad');
				final openInsideExpr:Expr = bracketKindPad
					? arrayBracketInsidePolicySpace(macro _args[0], false)
					: (delimInsidePolicySpace(branch, ['anonTypeBracesOpen'], false) ?? macro _de());
				final closeInsideExpr:Expr = bracketKindPad
					? arrayBracketInsidePolicySpace(macro _args[0], true)
					: (delimInsidePolicySpace(branch, ['anonTypeBracesClose'], true) ?? macro _de());
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
					final rulesExpr:Expr = optFieldAccess(wrapRulesField);
					macro anyparse.format.wrap.WrapList.emit($v{leadText}, $v{trailText}, $v{sepText}, _docs, opt, $openInsideExpr, $closeInsideExpr, false, $rulesExpr, $tcExpr);
				} else {
					macro sepList($v{leadText}, $v{trailText}, $v{sepText}, _docs, opt, $tcExpr, $openInsideExpr, $closeInsideExpr, false, $v{branch.fmtHasFlag('cuddle')});
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

	/**
	 * Mirror of `Lowering.shouldLowerByName` for the writer side. When
	 * the resolved format has `fieldLookup == ByName + keySyntax ==
	 * Quoted` and no struct field carries positional metadata
	 * (`@:kw / @:lead / @:trail / @:sep`) or binary metadata, the
	 * writer emits the struct as a JSON-style key-dispatched object —
	 * `"<key>": <value>` entries joined by the format's `entrySep` and
	 * wrapped in `mappingOpen` / `mappingClose`. Symmetric to the
	 * parser's ByName codepath so `@:peg @:schema(JsonFormat) typedef
	 * T = { … }` round-trips through `Build.buildParser` /
	 * `Build.buildWriter` without any positional metadata.
	 */
	private function shouldWriteByName(node:ShapeNode):Bool {
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
	 * Emit the writer body for a struct lowered as a key-dispatched
	 * object. For each child field, build a `Doc` for
	 * `"<key>"<keyValueSep> <value>` and push it into a runtime
	 * accumulator. Optional fields whose value is `null` are skipped
	 * entirely — neither their key nor their separator is emitted.
	 * The accumulator is then handed to `sepList` so the entries get
	 * width-aware line breaks for free, just like the positional-
	 * struct writer paths.
	 *
	 * Field value dispatch:
	 *  - `Ref` → call the sub-rule's `write<Ref>(value, opt)`. For
	 *    primitive fields the ShapeBuilder has already rewritten
	 *    `base.ref` to the format-declared terminal (e.g. `String` →
	 *    `JStringLit`), so the same call handles string escaping.
	 *  - `Star` → emit `sequenceOpen + items joined by entrySep +
	 *    sequenceClose` via `sepList`. The element shape must be a
	 *    single `Ref`; nested `Star` is deferred until a real schema
	 *    needs `Array<Array<T>>`.
	 *
	 * Failure modes match the parser's `byNameStarParseExpr`: missing
	 * `sequenceOpen` / `sequenceClose` on the format is a macro-time
	 * fatal error.
	 */
	private function lowerStructByName(node:ShapeNode, typePath:String):Expr {
		final mappingOpen:String = formatInfo.mappingOpen;
		final mappingClose:String = formatInfo.mappingClose;
		final keyValueSep:String = formatInfo.keyValueSep;
		final entrySep:String = formatInfo.entrySep;

		final stmts:Array<Expr> = [macro final _entries:Array<anyparse.core.Doc> = []];

		for (child in node.children) {
			final fieldName:Null<String> = child.annotations.get('base.fieldName');
			if (fieldName == null)
				Context.fatalError('WriterLowering: ByName struct field missing base.fieldName for $typePath', Context.currentPos());
			final isOptional:Bool = child.annotations.get('base.optional') == true;
			final fieldAccess:Expr = {expr: EField(macro value, fieldName), pos: Context.currentPos()};
			final keyPrefix:String = '"' + fieldName + '"' + keyValueSep;
			if (isOptional) {
				// Strict null safety does not narrow field reads — capture into
				// a non-null local before handing off to the per-kind writer.
				final fieldCT:Null<ComplexType> = child.annotations.get('base.fieldType');
				if (fieldCT == null)
					Context.fatalError('WriterLowering: ByName optional field "$fieldName" missing base.fieldType for $typePath', Context.currentPos());
				final localName:String = '_v_' + fieldName;
				final valueDocExpr:Expr = byNameFieldWriteExpr(child, fieldName, macro $i{localName});
				stmts.push(macro if ($fieldAccess != null) {
					final $localName:$fieldCT = $fieldAccess;
					_entries.push(_dc([_dt($v{keyPrefix}), $valueDocExpr]));
				});
			} else {
				final valueDocExpr:Expr = byNameFieldWriteExpr(child, fieldName, fieldAccess);
				stmts.push(macro _entries.push(_dc([_dt($v{keyPrefix}), $valueDocExpr])));
			}
		}

		stmts.push(macro return sepList(
			$v{mappingOpen}, $v{mappingClose}, $v{entrySep},
			_entries, opt, false, _de(), _de(), false, false
		));
		return macro $b{stmts};
	}

	private function byNameFieldWriteExpr(child:ShapeNode, fieldName:String, valueAccess:Expr):Expr {
		return switch child.kind {
			case Ref:
				final refName:String = child.annotations.get('base.ref');
				makeWriteCall(writeFnFor(refName), valueAccess, false, -1);
			case Star:
				byNameStarWriteExpr(child, fieldName, valueAccess);
			case _:
				Context.fatalError(
					'WriterLowering: ByName struct field "$fieldName" has unsupported kind ${child.kind}'
					+ ' — format ${formatInfo.schemaTypePath} may be missing a primitive type mapping',
					Context.currentPos()
				);
				throw 'unreachable';
		};
	}

	private function byNameStarWriteExpr(child:ShapeNode, fieldName:String, valueAccess:Expr):Expr {
		final seqOpen:Null<String> = formatInfo.sequenceOpen;
		final seqClose:Null<String> = formatInfo.sequenceClose;
		if (seqOpen == null || seqClose == null) {
			Context.fatalError(
				'WriterLowering: ByName Array<T> field "$fieldName" requires the format ${formatInfo.schemaTypePath} '
				+ 'to declare sequenceOpen / sequenceClose',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		if (child.children.length != 1) {
			Context.fatalError(
				'WriterLowering: ByName Array<T> field "$fieldName" expected exactly one element child, got ${child.children.length}',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		final inner:ShapeNode = child.children[0];
		if (inner.kind != Ref) {
			Context.fatalError(
				'WriterLowering: ByName Array<T> field "$fieldName" element kind ${inner.kind} is not supported '
				+ '— only Array<RefType> (a single named element type) is implemented',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		final refName:String = inner.annotations.get('base.ref');
		final elemFn:String = writeFnFor(refName);
		final entrySep:String = formatInfo.entrySep;
		return macro {
			final _items:Array<anyparse.core.Doc> = [for (_e in $valueAccess) $i{elemFn}(_e, opt)];
			sepList($v{seqOpen}, $v{seqClose}, $v{entrySep}, _items, opt, false, _de(), _de(), false, false);
		};
	}

	private function lowerStruct(node:ShapeNode, typePath:String):Expr {
		if (shouldWriteByName(node)) return lowerStructByName(node, typePath);
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
		// ω-pad-trailing-ref: tracks the runtime-Bool expr representing
		// the immediately preceding field's `@:fmt(padTrailing)` emission
		// (or `null` when the previous field neither carried the flag
		// nor — for optional/Star kinds — had its presence guard pass).
		// Read by `sameLineSeparator` to drop the next field's leading
		// space to `_de()` when this expr is truthy at runtime — closes
		// the double-space window when prev field's padTrailing meets
		// next field's sameLineSep at the same gate (canonical example:
		// `HxConditionalExpr` `expr` (bare-Ref padTrailing) immediately
		// followed by `elseExpr` (optional-kw-Ref sameLineSep)).
		//
		// Set at the end of each iteration's field branch from the per-
		// iteration scratch `thisPadTrailing`. Cleared (set to null) when
		// the iteration's field doesn't fire padTrailing — natural
		// boundary reset, no separate clear needed.
		var prevPadTrailing:Null<Expr> = null;
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
		for (c in node.children) if (c.annotations.get('base.optional') == true && c.fmtReadStringArgs('bodyPolicy') != null) {
			optionalBodyFieldName = c.annotations.get('base.fieldName');
			break;
		}

		// ω-condwrap-forstmt: detect a span-mode condWrap pair —
		// `@:fmt(condWrap('<knob>'))` on a starting field plus a later
		// sibling carrying the `@:fmt(condWrapEnd)` sentinel flag. The
		// open paren literal comes from the start field's `@:lead`, the
		// close paren from the end field's `@:trail`; the inter-field
		// pushes (separators, `@:kw` text, second writeCall) accumulate
		// normally into `parts` and are spliced into a single
		// `WrapList.emitCondition` wrap at the end of the end-field's
		// iteration. Single-Ref consumers (`HxIfStmt.cond`,
		// `HxWhileStmt.cond`) have no `condWrapEnd` sibling, so
		// `spanInfo` stays null and the existing single-Ref path runs.
		//
		// First consumer: `HxForStmt` — span covers
		// `varName + 'in' + iterable` with `(` from varName.@:lead and
		// `)` from iterable.@:trail. Fork's `markPWrapping` dispatches
		// `ForLoop` to the same `wrapCondition` path as `WhileCondition`
		// / `IfCondition`.
		var spanInfo:Null<{startIdx:Int, endIdx:Int, leadText:String, trailText:String, knob:String}> = null;
		{
			var startIdx:Int = -1;
			var startKnob:Null<String> = null;
			var startLead:Null<String> = null;
			for (i in 0...node.children.length) {
				final c:ShapeNode = node.children[i];
				final cw:Null<Array<String>> = c.fmtReadStringArgs('condWrap');
				if (cw != null && startIdx == -1) {
					startIdx = i;
					startKnob = cw[0];
					startLead = c.readMetaString(':lead');
				} else if (c.fmtHasFlag('condWrapEnd') && startIdx != -1) {
					final endTrail:Null<String> = c.readMetaString(':trail');
					if (startLead == null || endTrail == null)
						Context.fatalError('WriterLowering: @:fmt(condWrap)/@:fmt(condWrapEnd) span requires @:lead on the start field and @:trail on the end field', Context.currentPos());
					if (startKnob == null)
						Context.fatalError('WriterLowering: @:fmt(condWrap) requires a knob arg', Context.currentPos());
					if (c.kind != Ref || c.annotations.get('base.optional') == true)
						Context.fatalError('WriterLowering: @:fmt(condWrapEnd) is supported only on bare mandatory Ref fields', Context.currentPos());
					spanInfo = {
						startIdx: startIdx, endIdx: i,
						leadText: startLead, trailText: endTrail,
						knob: startKnob,
					};
					break;
				}
			}
		}
		var fieldIdx:Int = -1;
		var spanStartPartsIdx:Int = -1;

		// ω-multivar-wrap: detect the struct-level
		// `@:fmt(multiVarWrap('<knob>', '<moreField>'))` opt-in (sole
		// consumer: `HxVarDecl`). When present, the named right-recursive
		// list field is routed through the `<knob>` `WrapRules` cascade at
		// the return-folding step below: the head binding plus each chain
		// link become head-only item Docs and are spliced into one
		// `WrapList.emit('', '', ',', …)`. The per-field emit of the
		// `<moreField>` Star is gated on the runtime `_suppressMore` entry
		// flag so a recursive head-only self-call drops it to `_de()`. Off
		// every other struct (args == null) → byte-identical to pre-slice.
		final multiVarArgs:Null<Array<String>> = node.fmtReadStringArgs('multiVarWrap');
		final multiVarKnob:Null<String> = multiVarArgs != null ? multiVarArgs[0] : null;
		final multiVarMoreField:Null<String> = multiVarArgs != null ? multiVarArgs[1] : null;
		if (multiVarArgs != null && multiVarArgs.length != 2)
			Context.fatalError(
				'WriterLowering: @:fmt(multiVarWrap) expects 2 string args (knobFieldName, moreFieldName), got ${multiVarArgs.length}',
				Context.currentPos()
			);

		for (child in node.children) {
			fieldIdx++;
			final fieldName:Null<String> = child.annotations.get('base.fieldName');
			if (fieldName == null)
				Context.fatalError('WriterLowering: struct field missing base.fieldName', Context.currentPos());
			// Tracker is "prev" — clear at the start so a non-bearing-Ref
			// field doesn't leak the value set two iterations back.
			final stalePrevBareRefBody:Null<PrevBodyInfo> = prevBareRefBody;
			prevBareRefBody = null;
			// ω-pad-trailing-ref: per-iteration scratch holding THIS
			// field's padTrailing-emission runtime expr (or null if this
			// field doesn't fire padTrailing). Each field-kind branch
			// sets it locally before its `continue` (Star branches) or
			// fall-through (Ref/OptRef branches) to the shared end-of-
			// loop block, where `composePadTrailing` folds it into
			// `prevPadTrailing`.
			var thisPadTrailing:Null<Expr> = null;
			// ω-pad-trailing-ref: per-iteration scratch holding THIS
			// field's "transparent at runtime" runtime expr — i.e. the
			// guard under which the field emits NO visible content (and
			// therefore can be skipped over when propagating an earlier
			// field's pad signal across an intervening empty/absent
			// middle field). `null` means "always emits content" (e.g.
			// mandatory bare Ref). Set per branch:
			//   bare Ref:        null (never transparent)
			//   optional Ref:    `$fieldAccess == null`
			//   non-opt Star:    `$fieldAccess.length == 0`
			//   optional Star:   `$fieldAccess == null || $fieldAccess.length == 0`
			// Folded into `prevPadTrailing` via `composePadTrailing` —
			// closes the empty-middle-Star window where a static reset
			// would lose the signal across `expr → empty Star → elseExpr`.
			var thisTransparent:Null<Expr> = null;
			final kwLead:Null<String> = child.readMetaString(':kw');
			final leadText:Null<String> = child.readMetaString(':lead');
			final trailText:Null<String> = child.readMetaString(':trail');
			// `@:trailOpt(LIT)` sets `lit.trailText`+`lit.trailOptional=true`
			// in `strategy/Lit.hx` (uniform with `@:trail`). The writer reads
			// it as a separate `trailOptText` to keep the existing `trailText`
			// (raw `@:trail` only) consumers untouched — `condWrap` requires
			// `@:trail` semantics, `prevTrailFieldName` synthesises an
			// `AfterTrail` slot only for `@:trail` (`TriviaTypeSynth.isTrailRef`),
			// and span-mode condWrap pulls from `:trail` directly. The trail-
			// emit branches below treat `trailText` (always-emit) and
			// `trailOptText` (source-tracked via Phase 4 gate) as parallel
			// sources for the trail literal Doc push.
			final trailOptText:Null<String> = child.annotations.get('lit.trailOptional') == true
				? (child.annotations.get('lit.trailText') : Null<String>)
				: null;
			final isStar:Bool = child.kind == Star;
			final isOptional:Bool = child.annotations.get('base.optional') == true;
			final hasElseIf:Bool = child.fmtHasFlag('elseIf');
			// ω-condition-wrap-wiring: `@:fmt(condWrap('<knob>'))` on a
			// bare mandatory Ref carrying `@:lead('(') @:trail(')')` (or
			// any open/close literal pair) routes lead+value+trail through
			// the runtime `WrapList.emitCondition` cascade instead of
			// pushing the three pieces independently. The cascade fits
			// flat `(cond)` when the column has room and breaks to
			// `(\n\tcond\n)` otherwise — driven by `opt.<knob>:WrapRules`.
			// First consumers: `HxIfStmt.cond`, `HxWhileStmt.cond`. The
			// lead push at line ~1756 and the trail push at line ~2463
			// are skipped when this meta fires, and the bare-Ref Case's
			// `parts.push(writeCall)` default path emits the wrapped Doc
			// via the runtime helper instead.
			final condWrapArgs:Null<Array<String>> = child.fmtReadStringArgs('condWrap');
			final isSpanStart:Bool = spanInfo != null && fieldIdx == spanInfo.startIdx;
			final hasCondWrapEnd:Bool = spanInfo != null && fieldIdx == spanInfo.endIdx;
			if (condWrapArgs != null) {
				if (condWrapArgs.length != 1)
					Context.fatalError('WriterLowering: @:fmt(condWrap(\'<knob>\')) requires 1 string arg, got ${condWrapArgs.length}', Context.currentPos());
				if (leadText == null)
					Context.fatalError('WriterLowering: @:fmt(condWrap) requires @:lead on the field', Context.currentPos());
				// Span mode: trail literal lives on the matched `@:fmt(condWrapEnd)`
				// sibling; single-Ref mode: trail required on the same field.
				if (spanInfo == null && trailText == null)
					Context.fatalError('WriterLowering: @:fmt(condWrap) requires @:trail on the field (or a sibling @:fmt(condWrapEnd) for span mode)', Context.currentPos());
				if (isOptional || isStar || child.kind != Ref)
					Context.fatalError('WriterLowering: @:fmt(condWrap) is supported only on bare mandatory Ref fields', Context.currentPos());
				if (spanInfo == null && kwLead != null)
					Context.fatalError('WriterLowering: @:fmt(condWrap) (single-Ref mode) does not support @:kw on the same field', Context.currentPos());
			}
			final hasCondWrap:Bool = condWrapArgs != null;
			if (isSpanStart) spanStartPartsIdx = parts.length;

			final fieldAccess:Expr = {
				expr: EField(macro value, fieldName),
				pos: Context.currentPos(),
			};

			// ω-struct-trailopt-source-track (Session 14 Phase 4): trivia-
			// bearing struct-typedef Ref field carrying `@:trailOpt(LIT)`
			// reads `value.<field>TrailPresent:Null<Bool>` (slot synthesised
			// by `TriviaTypeSynth.buildStructFieldTrailPresentSlot` Phase 2,
			// populated by `Lowering.lowerStruct`'s `_trailPresent_<field>`
			// capture Phase 3). The writer gates trail re-emission on the
			// captured value: `true` -> emit, `false` -> suppress, `null` ->
			// fall through to canonical emit (covers raw->paired upcasts
			// from `Converters.rawToPaired_*` where preWrite plugins don't
			// preserve source presence). Gate fires on BOTH the mandatory-
			// Ref trail-push (~L3085) and the optional-Ref + lead + trail
			// push (~L2458), mirroring the two Lowering capture paths.
			final hasStructFieldTrailOptSlot:Bool = !isStar
				&& child.kind == Ref
				&& child.annotations.get('lit.trailOptional') == true
				&& ctx.trivia && isTriviaBearing(typePath);
			final structTrailOptAccess:Null<Expr> = hasStructFieldTrailOptSlot
				? {expr: EField(macro value, fieldName + TriviaTypeSynth.TRAIL_PRESENT_SUFFIX), pos: Context.currentPos()}
				: null;

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
						typePath, isFirstField, isRaw, stalePrevBareRefBody, prevTrailFieldName
					);
					// ω-typeparam-spacing: when the typeParamOpen=Before/Both
					// path injects a leading-space Doc into innerParts, the
					// list grows to two elements. EBlock would evaluate to
					// the last Doc only and silently drop the space — use
					// `_dc([...])` so the writer concatenates both pieces.
					final innerExpr:Expr = if (innerParts.length == 1) innerParts[0]
					else dcCall(innerParts);
					if (kwLead != null) {
						// ω-cond-comp-engine: kw-led optional Star writer
						// mirror. Splices the kw-Ref optional path's
						// inter-field sep + kw-trivia layers (sameLineSeparator
						// + kwBeforeDoc + kwBeforeTrailingDoc) with the Star
						// body emitted by `emitWriterStarField`. The Star
						// helper already honours `@:fmt(padLeading, padTrailing)`
						// against the narrowed `_optVal:Array<T>`, so the gap
						// between the kw and the first body element comes
						// from the pad logic — no need for a literal trailing
						// space on the kw token. Empty body degrades to `_de()`
						// inside the helper, mirroring `HxConditionalMod.body`'s
						// non-optional precedent. First consumer:
						// `HxConditionalDecl.elseBody`.
						final useTriviaGap:Bool = ctx.trivia;
						final beforeKwLeadingExpr:Null<Expr> = useTriviaGap
							? {expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_KW_LEADING_SUFFIX), pos: Context.currentPos()}
							: null;
						final beforeKwTrailingExpr:Null<Expr> = useTriviaGap
							? {expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_KW_TRAILING_SUFFIX), pos: Context.currentPos()}
							: null;
						final sepBaseExpr:Expr = sameLineSeparator(child, prevBodyField, typePath, prevPadTrailing);
						final sepWithBeforeKwExpr:Expr = beforeKwLeadingExpr != null
							? macro kwBeforeDoc($beforeKwLeadingExpr, $sepBaseExpr, opt)
							: sepBaseExpr;
						final sepWithBeforeKwTrailingExpr:Expr = beforeKwTrailingExpr != null
							? macro kwBeforeTrailingDoc($beforeKwTrailingExpr, $sepWithBeforeKwExpr, opt)
							: sepWithBeforeKwExpr;
						final kwOptParts:Array<Expr> = [
							sepWithBeforeKwTrailingExpr,
							macro _dt($v{kwLead}),
							innerExpr,
						];
						final kwOptBody:Expr = dcCall(kwOptParts);
						parts.push(macro {
							final _optVal = $fieldAccess;
							if (_optVal != null) $kwOptBody else _de();
						});
					} else {
						parts.push(macro {
							final _optVal = $fieldAccess;
							if (_optVal != null) $innerExpr else _de();
						});
					}
					// ω-pad-trailing-ref: optional Star with @:fmt(padTrailing)
					// fires its trailing-pad ONLY when both `_optVal != null`
					// AND `_optVal.length > 0` (the Star helper's empty branch
					// returns `_de()` regardless of pad flags). Optional Star
					// is transparent (no visible output) when absent OR empty,
					// so propagate prev across that combined guard.
					if (child.fmtHasFlag('padTrailing'))
						thisPadTrailing = macro $fieldAccess != null && $fieldAccess.length > 0;
					thisTransparent = macro $fieldAccess == null || $fieldAccess.length == 0;
					prevAnyStarNonEmpty = null;
					prevBodyField = null;
					prevTrailFieldName = null;
					prevPadTrailing = composePadTrailing(prevPadTrailing, thisPadTrailing, thisTransparent);
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
				//
				// ω-pad-trailing-ref / ω-cond-comp-stmt-blank-fix: when the
				// immediately preceding field fired `@:fmt(padTrailing)`,
				// drop THIS sep at runtime so the pad's emission owns the
				// boundary alone. Without the gate, body→elseifs boundary
				// in `HxConditionalStmt` / `HxConditionalDecl` doubled the
				// hardline (body's padTrailing emits `_dhl()` because
				// `body[0].newlineBefore=true`, then this sep emits
				// `_dhl()` again because `elseifs[0].newlineBefore=true`)
				// and produced a spurious blank line between the last body
				// stmt and `#elseif`. Mirrors the `withPadTrailingDrop`
				// wrapper in `sameLineSeparator` (kw-Ref / opt-Ref sep
				// path); both consume the same macro-time `prevPadTrailing`
				// signal at struct-field boundaries.
				if (isBareTryparseStar(child) && !isFirstField && prevAnyStarNonEmpty != null) {
					final prev:Expr = prevAnyStarNonEmpty;
					final baseExpr:Expr = ctx.trivia
						? macro {
							final _next = $fieldAccess;
							if ($prev && _next.length > 0)
								_next[0].newlineBefore ? _dhl() : _dt(' ');
							else _de();
						}
						: macro ($prev && $fieldAccess.length > 0) ? _dt(' ') : _de();
					parts.push(withPadTrailingDrop(prevPadTrailing, baseExpr));
				}
				// ω-multivar-wrap: gate the `<moreField>` Star emit on the
				// runtime `_suppressMore` entry flag. A recursive head-only
				// self-call (`writeHxVarDeclT(value, _setSuppressMore(opt))`,
				// emitted in the return-fold below) sets the flag so this
				// field drops to `_de()`, yielding the head binding alone.
				// `_suppressMoreEntry` is the entry-captured local declared by
				// the return-fold wrapper; it is in scope because that wrapper
				// brackets the entire emitted body.
				final isMultiVarMoreField:Bool = multiVarMoreField != null && fieldName == multiVarMoreField;
				final multiVarPartsStart:Int = parts.length;
				emitWriterStarField(child, fieldAccess, parts, child == node.children[node.children.length - 1], typePath, isFirstField, isRaw, stalePrevBareRefBody, prevTrailFieldName);
				if (isMultiVarMoreField) for (i in multiVarPartsStart...parts.length) {
					final entry:Expr = parts[i];
					parts[i] = macro _suppressMoreEntry ? _de() : $entry;
				}
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
				// ω-pad-trailing-ref: non-optional Star with @:fmt(padTrailing)
				// fires its trailing-pad when `_arr.length > 0` (the helper's
				// empty branch returns `_de()`). Non-opt Star is transparent
				// when empty, so propagate prev across `length == 0`.
				//
				// ω-metadata-line-end-function: a Star carrying
				// `@:fmt(metaLineEndPolicy('<optField>'))` ALSO fires a
				// trailing-pad equivalent when the runtime knob is non-None
				// AND the Star is non-empty. Reuse the `prevPadTrailing`
				// channel so the next field's inter-Star sep
				// (`withPadTrailingDrop`) drops its own emit, avoiding a
				// double-hardline at the meta→modifiers boundary.
				if (child.fmtHasFlag('padTrailing'))
					thisPadTrailing = macro $fieldAccess.length > 0;
				else {
					final metaLineEndField:Null<String> = child.fmtReadString('metaLineEndPolicy');
					if (metaLineEndField != null) {
						final optAccess:Expr = optFieldAccess(metaLineEndField);
						thisPadTrailing = macro $fieldAccess.length > 0 && $optAccess != 0;
					}
				}
				thisTransparent = macro $fieldAccess.length == 0;
				prevBodyField = null;
				prevTrailFieldName = null;
				prevPadTrailing = composePadTrailing(prevPadTrailing, thisPadTrailing, thisTransparent);
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
				if (!isFirstField && !isRaw) parts.push(sameLineSeparator(child, prevBodyField, typePath, prevPadTrailing));
				if (child.fmtHasFlag('leftCurly')) {
					// `leftCurlySeparator` (default `optSpaceUpstream=false`)
					// handles both forms identically at this site: bare-flag
					// reads `opt.leftCurly`, knob-form reads
					// `opt.<knobName>` — `Same` emits `_dt(' ')`
					// (byte-identical to the unsplit `kwLead + ' '` form) and
					// `Next` emits `_dhl()`. First knob-form consumer here:
					// `HxUntypedFnBody.block` with
					// `leftCurly('blockLeftCurly')` (slice
					// ω-blockcurly-broader) so the kw→`{` gap honors the
					// per-construct `Block` knob alongside the global
					// cascade.
					parts.push(macro _dt($v{kwLead}));
					parts.push(leftCurlySeparator(child));
				} else if (child.fmtHasFlag('anonFuncParens')) {
					// `@:fmt(anonFuncParens)` on a kw-led mandatory Ref
					// routes the kw-trailing space slot through the
					// runtime `WhitespacePolicy` knob (paren-side
					// semantics — `Before` / `Both` emit a space, `None`
					// / `After` collapse it). First consumer is
					// `HxExpr.FnExpr` (`@:kw('function')` Ref to
					// `HxFnExpr`) — default `None` keeps
					// `function<T>(...)` / `function(...)` tight, and
					// `whitespace.parenConfig.anonFuncParamParens.openingPolicy:
					// "before"` flips both to `function <T>(...)` /
					// `function (...)`. Mirrors the haxe-formatter
					// convention where `function`-led parens (also when
					// reached inside an `@:overload(...)` metadata arg)
					// track `anonFuncParamParens` (see
					// `MarkWhitespace.determinePOpenPolicy` default
					// fall-through).
					parts.push(macro _dt($v{kwLead}));
					final policySpace:Null<Expr> = kwTrailingSpacePolicyParenSide(child, ['anonFuncParens']);
					if (policySpace != null) parts.push(policySpace);
				} else if (firstFmtFlag(child, ['catchParensGap', 'whilePolicy']) != null) {
					// ω-condition-parens (Stage C): kw-led struct-field cond
					// whose `kw`→`(` gap tracks a kw-after `WhitespacePolicy`
					// knob. `catchParensGap` (`HxCatchClause.param`,
					// `@:kw('catch')`) and `whilePolicy` (`HxDoWhileStmt.cond`,
					// `@:kw('while')` — the trailing `while` of a `do … while`)
					// both use kw-after semantics (`After`/`Both` → space,
					// `None` → tight). Defaults keep `catch (` / `} while (`
					// byte-identical; fed from
					// `parenConfig.{catch|while}ConditionParens.openingPolicy`
					// (flipped to the kw-after axis) in `applyConditionParens`.
					parts.push(macro _dt($v{kwLead}));
					final policySpace:Null<Expr> = kwTrailingSpacePolicy(child, ['catchParensGap', 'whilePolicy']);
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
			// ω-condwrap-forstmt: symmetric with the trail gate below — the
			// end-field of a condWrap span cannot push its own `@:lead`
			// literal (the open paren is owned by the start field and emitted
			// via the splice's `emitCondition` wrap). No current consumer
			// puts `@:lead` on the end field, but mirror the trail gate so a
			// future end-field with `@:lead` does not silently leak the lead
			// literal into the spanned cond Doc.
			if (leadText != null && !isOptional && !hasCondWrap && !hasCondWrapEnd)
				parts.push(whitespacePolicyLead(child, leadText, ['objectFieldColon', 'typeHintColon', 'typeCheckColon', 'typedefAssign', 'typedefIntersection', 'functionTypeHaxe4', 'arrowFunctions', 'catchParensInsideOpen', 'switchCondParensInsideOpen', 'whileCondParensInsideOpen']));

			// Field value
			// ω-issue-257-else-in-return-switch: same dual-flag form as
			// the ctor-level read above — `bodyPolicy('<stmtFlag>',
			// '<exprFlag>')` dispatches at runtime on
			// `opt._inExprPosition`.
			final bodyPolicy:{stmt:Null<String>, expr:Null<String>} = readBodyPolicyDual(child);
			final bodyPolicyFlag:Null<String> = bodyPolicy.stmt;
			final bodyPolicyExprFlag:Null<String> = bodyPolicy.expr;
			// ω-expression-if-next-with-fitline-body: `@:fmt(noSiblingFallback(
			// 'fallbackFlag'))` on a bare-Ref body field tells `bodyPolicyWrap`
			// to swap `opt.<bodyPolicy>` for `opt.<fallbackFlag>` at runtime
			// when the next optional sibling field's value is null. Used by
			// `HxIfExpr.thenBranch` to fall back to `opt.ifBody` (FitLine) when
			// `elseBranch` is null — mirrors fork's arrow-body / comprehension-
			// filter-if short-circuits onto `ifBody`. When this flag is set
			// the field also opts into the `optionalBodyFieldName` channel so
			// `elseFieldName` is populated regardless of `fitLineIfWithElse`.
			final fallbackFlag:Null<String> = child.fmtReadString('noSiblingFallback');
			final elseFieldName:Null<String> = (child.fmtHasFlag('fitLineIfWithElse') || fallbackFlag != null) ? optionalBodyFieldName : null;
			var justWrappedBody:Null<PrevBodyInfo> = null;
			switch child.kind {
				case Ref if (isOptional):
					final refName:String = child.annotations.get('base.ref');
					final writeFn:String = writeFnFor(refName);
					// ω-issue-423-mech-a: same opt-fanout as mandatory Ref —
					// when the optional Ref carries `@:fmt(propagateExprPosition)`,
					// wrap opt in `_setExprPosition` so the descendant writer
					// sees `_inExprPosition=true`. Used by `HxVarDecl.init`
					// to flag var-rhs as expression-position.
					final propagateExpr:Bool = child.fmtHasFlag('propagateExprPosition');
					// ω-anonfunction-empty-curly: sister opt-fanout — when the
					// optional Ref carries `@:fmt(propagateAnonFnContext)`,
					// wrap opt in `_setAnonFnBody` so the descendant writer
					// sees `_inAnonFnBody=true`. Used by `HxFnExpr.body` to
					// flag the anon-fn body so the inner `HxFnBlock.stmts`
					// emptyCurlyBreak emit dispatches on
					// `opt.anonFunctionEmptyCurly` instead of the global
					// `opt.emptyCurly`. Idempotent — composes safely with
					// `propagateExprPosition` should a future field combine
					// both metas.
					final propagateAnonFn:Bool = child.fmtHasFlag('propagateAnonFnContext');
					final optArgExpr:Expr = if (propagateExpr && propagateAnonFn)
						macro _setAnonFnBody(_setExprPosition(opt));
					else if (propagateExpr)
						macro _setExprPosition(opt);
					else if (propagateAnonFn)
						macro _setAnonFnBody(opt);
					else
						macro opt;
					final rawWriteCall:Expr = {
						expr: ECall(macro $i{writeFn}, [macro _optVal, optArgExpr]),
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
					// ω-N-break-after-eq: when the meta-gated helper bundles the
					// lead + RHS together (via the natural-first-line probe), the
					// post-branch unconditional `optParts.push(writeCall)` must be
					// skipped — the RHS is already inside the bundled Doc.
					var breakAfterEqEmitted:Bool = false;
					if (kwLead != null) {
						final sepBaseExpr:Expr = sameLineSeparator(child, prevBodyField, typePath, prevPadTrailing);
						final sepWithBeforeKwExpr:Expr = beforeKwLeadingExpr != null
							? macro kwBeforeDoc($beforeKwLeadingExpr, $sepBaseExpr, opt)
							: sepBaseExpr;
						final sepWithBeforeKwTrailingExpr:Expr = beforeKwTrailingExpr != null
							? macro kwBeforeTrailingDoc($beforeKwTrailingExpr, $sepWithBeforeKwExpr, opt)
							: sepWithBeforeKwExpr;
						optParts.push(sepWithBeforeKwTrailingExpr);
						if (bodyPolicyFlag != null) {
							optParts.push(macro _dt($v{kwLead}));
							// ω-expression-if-with-blocks: sister read of
							// `@:fmt(inlineBlockBodyIfFlag(...))` on optional-kw
							// body field path (e.g. `HxIfExpr.elseBranch`'s
							// `@:optional @:kw('else')` form). Threaded into the
							// same `bodyPolicyWrap` plumbing as the bare-Ref path
							// below; the runtime override fires at writeCall-swap
							// time before policy dispatch.
							final inlineBlockBodyArgs:Null<Array<String>> = child.fmtReadStringArgs('inlineBlockBodyIfFlag');
							optParts.push(bodyPolicyWrap({
								flagName: bodyPolicyFlag,
								exprFlagName: bodyPolicyExprFlag,
								writeCall: writeCall,
								bodyValueExpr: macro _optVal,
								bodyTypePath: refName,
								hasElseIf: hasElseIf,
								elseFieldName: elseFieldName,
								afterKwExpr: afterKwExpr,
								kwLeadingExpr: kwLeadingExpr,
								bodyOnSameLineExpr: bodyOnSameLineExpr,
								indentObjArgs: indentObjArgs,
								inlineBlockBodyArgs: inlineBlockBodyArgs,
							}));
						} else if (child.fmtHasFlag('nestBodyOnSourceNewline') && bodyOnSameLineExpr != null) {
							// ω-cond-comp-expr-body-nest: optional-kw-Ref body
							// break+nest based on the captured `<f>BodyOnSameLine`
							// slot. When the slot is false (source had a newline
							// between the kw and the body) the wrapper emits
							// `Nest(_cols, [hardline, body])` so the body sits
							// one indent step deeper than the kw line. When true
							// the wrapper emits `' ' + body` for inline single-
							// line shape. Plain mode and non-trivia-bearing rules
							// see a null `bodyOnSameLineExpr` and fall through to
							// the default `_dt(kwLead + ' ') + writeCall` below.
							// Currently consumed by `HxConditionalExpr.elseExpr`.
							optParts.push(macro _dt($v{kwLead}));
							final invertedSignal:Expr = macro !$bodyOnSameLineExpr;
							optParts.push(nestBodyOnSourceNewlineWrap(writeCall, invertedSignal));
						} else {
							optParts.push(macro _dt($v{kwLead + ' '}));
							optParts.push(writeCall);
						}
					} else if (leadText != null) {
						final isFieldTight:Bool = child.fmtHasFlag('tightLead');
						if (isTightLead(leadText)) {
							// ω-E-whitespace: `@:fmt(typeHintColon)` on
							// optional-Ref tight leads routes through the same
							// WhitespacePolicy helper as mandatory leads.
							// Without the flag the `None` default keeps the
							// tight `_dt(leadText)` byte-identical to the pre-
							// flag path (`f():Void`).
							optParts.push(whitespacePolicyLead(child, leadText, ['typeHintColon']));
						} else if (isFieldTight) {
							// Slice 26 — per-field `@:fmt(tightLead)`: opts an
							// optional Ref's `@:lead` into tight emission
							// without joining the format-level `tightLeads`
							// list. No leading separator, no trailing
							// `_dop(' ')` — bare `_dt(leadText)` only.
							// Consumer: `HxVarDecl.access` (`@:lead('(')` for
							// property accessor clause). Format-level
							// `tightLeads` can't carry `(` because other
							// `@:lead('(')` sites (`HxFnDecl.params`,
							// `HxIfStmt.cond`, etc.) have distinct handlers.
							optParts.push(macro _dt($v{leadText}));
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
							optParts.push(sameLineSeparator(child, prevBodyField, typePath, prevPadTrailing));
							// ω-N-break-after-eq: `@:fmt(breakAfterLeadIfLhsTypeParam('type'))`
							// (today: `HxVarDecl.init`) bundles the lead + RHS through
							// the natural-first-line probe so the `=`-break only fires
							// when the RHS's NATURAL first line still overflows (a
							// NoWrap-pinned RHS), NOT when the RHS wraps its own
							// call-args. The bundled Doc already contains the RHS, so
							// the post-branch unconditional `writeCall` push is skipped.
							final breakAfterEqArg:Null<String> = child.fmtReadString('breakAfterLeadIfLhsTypeParam');
							if (breakAfterEqArg != null && !isTightLead(leadText)) {
								optParts.push(breakAfterLeadIfLhsTypeParamWrap(leadText, writeCall, breakAfterEqArg));
								breakAfterEqEmitted = true;
							} else {
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
						}
						if (!breakAfterEqEmitted)
							optParts.push(writeCall);
						// ω-optional-ref-trail: bracket-pair close for an
						// `@:optional @:lead(<open>) @:trail(<close>)` Ref.
						// Pushed INSIDE optParts so the trail rides the
						// `_optVal != null` runtime gate (absent value
						// suppresses both lead and trail). Bracket-tight by
						// design — no separator before the close, mirroring
						// the mandatory-Ref trail emit (`!isOptional` arm
						// below). First consumer: `HxAbstractDecl.
						// underlyingType` (`(T)` group) for the bare-abstract
						// shape (Slice 40).
						if (trailText != null)
							optParts.push(macro _dt($v{trailText}));
						// ω-struct-trailopt-source-track (Session 14 Phase 4):
						// optional Ref + kw/lead + `@:trailOpt(LIT)` lands here
						// as a parallel push (`trailText` covers `@:trail`,
						// `trailOptText` covers `@:trailOpt`; the two are
						// mutually exclusive in the same field). Gate on
						// `hasStructFieldTrailOptSlot` (trivia mode + bearing)
						// so plain mode and non-bearing rules preserve pre-
						// Phase-4 silent-drop behaviour for now (no slot to
						// consult, no canonical answer either — earlier code
						// simply never reached this trail at all). The
						// `<field>TrailPresent` slot is `null` only on raw->
						// paired upcasts from `Converters.rawToPaired_*`; the
						// `==false` test degrades safely there — null falls
						// through to canonical emit.
						else if (hasStructFieldTrailOptSlot && trailOptText != null)
							optParts.push(macro $structTrailOptAccess == false ? _de() : _dt($v{trailOptText}));
					} else if (bodyPolicyFlag != null) {
						// ω-absent-on-bodypolicy: optional Ref with no kw /
						// lead but `@:fmt(bodyPolicy(...))`. The leftCurly
						// branch below mirrors the mandatory-Ref `{`-ctor
						// switch; this branch mirrors the mandatory-Ref
						// `bodyPolicyWrap` path (the bare-Ref site below /
						// the optional-kw site above) so the `)`→body
						// separator survives. `bodyPolicyWrap` owns the
						// separator AND the body emission; for the absent
						// case the outer `_optVal != null` guard drops the
						// whole thing to `_de()`. Present-body output is
						// byte-identical to the pre-optional mandatory-Ref
						// path (same wrap, same flag, no kw-trivia gap).
						// First consumer: `HxCatchClause.body` (bodyless
						// `catch (e:T)`).
						final inlineBlockBodyArgs:Null<Array<String>> = child.fmtReadStringArgs('inlineBlockBodyIfFlag');
						optParts.push(bodyPolicyWrap({
							flagName: bodyPolicyFlag,
							exprFlagName: bodyPolicyExprFlag,
							writeCall: writeCall,
							bodyValueExpr: macro _optVal,
							bodyTypePath: refName,
							hasElseIf: hasElseIf,
							elseFieldName: elseFieldName,
							indentObjArgs: indentObjArgs,
							inlineBlockBodyArgs: inlineBlockBodyArgs,
						}));
					} else {
						// ω-absent-on: optional Ref with no kw / lead — emit
						// only the writeCall, but if `@:fmt(leftCurly)` is
						// present mirror the mandatory-Ref path's runtime
						// ctor switch so the kw→`{` transition (Allman
						// `\n{` for BlockBody, ` ` for ExprBody) survives.
						// Without this the absent-on body emits its
						// payload glued to the previous token. First and
						// only consumer so far: `HxFnExpr.body`.
						final lcSep:Null<Expr> = child.fmtHasFlag('leftCurly')
							? leftCurlySeparator(child)
							: null;
						final lcCtors:Array<String> = lcSep == null ? [] : leftCurlyTargetCtors(refName);
						// ω-anonfnbody-keep: optional-Ref mirror of the
						// mandatory-Ref `bodyPolicyForCtor` chain (see the
						// `HxFnDecl.body` site below, slice ω-fnbody-keep). When
						// `@:fmt(bodyPolicyForCtor('<ctor>', '<flagName>'))` pairs
						// are present, route each matched runtime ctor through
						// `bodyPolicyWrap` (which owns the signature→body
						// separator AND the body emission) and fall through to the
						// per-ctor `sep + writeCall` default for every other ctor.
						// Consumer: `HxFnExpr.body` for `('ExprBody',
						// 'anonFunctionBody')` — the bare-expr anon-fn body. The
						// gap-at-parent rationale matches the mandatory-Ref path:
						// the signature→body source-newline gap is consumed by the
						// parent struct's pre-field `skipWs` before this branch's
						// sub-rule probes, so the `Keep`-policy slot must be read
						// at the parent (`<field>BeforeNewline`), NOT inside the
						// kw-less `ExprBody` branch (which grows no slot). Default
						// `anonFunctionBody=Same` reproduces the prior ExprBody
						// `_dt(' ')` cuddle byte-for-byte, so this is inert until
						// the knob is set to `Next` / `Keep`.
						final bodyPolicyForCtorPairs:Array<Array<String>> = child.fmtReadStringArgsAll('bodyPolicyForCtor');
						if (lcSep != null && lcCtors.length > 0) {
							final spaceCtors:Array<String> = spacePrefixCtors(refName, lcCtors);
							final ctorExpr:Expr = macro Type.enumConstructor(_optVal);
							var sepExpr:Expr = macro _de();
							for (sc in spaceCtors) {
								final scSep:Expr = ctorHasBodyPolicy(refName, sc) ? macro _de() : macro _dt(' ');
								sepExpr = macro $ctorExpr == $v{sc} ? $scSep : $sepExpr;
							}
							for (lc in lcCtors)
								sepExpr = macro $ctorExpr == $v{lc} ? $lcSep : $sepExpr;
							if (bodyPolicyForCtorPairs.length > 0) {
								// The `<field>BeforeNewline` Keep-dispatch slot is
								// synthesised only for NON-optional bare Refs
								// (`TriviaTypeSynth.isBareNonFirstRef` excludes
								// `@:optional`). This optional-Ref path therefore has
								// no slot — pass `null`, so `Same` / `Next` work and
								// `Keep` degrades to the no-slot default. Supporting
								// `Keep` here would require extending slot synthesis
								// to optional Refs (a separate, larger change — the
								// `sourceMultilineKeep` wall noted in slice ω-fnbody-keep).
								final wrapBodyOnSameLineExpr:Null<Expr> = null;
								final defaultPair:Expr = macro _dc([$sepExpr, $writeCall]);
								// Fold the pairs into a ternary chain. Iterate in
								// reverse so the first-declared pair sits at the
								// chain head (tested first at runtime).
								var chain:Expr = defaultPair;
								var i:Int = bodyPolicyForCtorPairs.length - 1;
								while (i >= 0) {
									final pair:Array<String> = bodyPolicyForCtorPairs[i];
									if (pair.length != 2)
										Context.fatalError('WriterLowering: @:fmt(bodyPolicyForCtor(...)) requires (ctorName, flagName), got ${pair.length} args', Context.currentPos());
									final wrapCtorName:String = pair[0];
									final wrapFlagName:String = pair[1];
									final wrapOutput:Expr = bodyPolicyWrap({
										flagName: wrapFlagName,
										writeCall: writeCall,
										bodyValueExpr: macro _optVal,
										bodyTypePath: refName,
										hasElseIf: false,
										elseFieldName: null,
										bodyOnSameLineExpr: wrapBodyOnSameLineExpr,
									});
									chain = macro $ctorExpr == $v{wrapCtorName} ? $wrapOutput : $chain;
									i--;
								}
								optParts.push(chain);
							} else {
								optParts.push(sepExpr);
								optParts.push(writeCall);
							}
						} else
							optParts.push(writeCall);
					}
					// ω-pad-trailing-ref: optional-Ref `@:fmt(padTrailing)`
					// pushes a trailing space INSIDE optParts so the pad is
					// emitted only when `_optVal != null` (the surrounding
					// wrap drops the entire optBody to `_de()` for the
					// absent case). Tracker expr is `$fieldAccess != null`,
					// matching the runtime presence guard one-to-one.
					// First consumer: `HxConditionalExpr.elseExpr` so the
					// `... e2 #end` boundary lands as ` #end` instead of
					// `e2#end`.
					if (child.fmtHasFlag('padTrailing')) {
						optParts.push(padTrailingDoc(node, child, typePath));
						thisPadTrailing = macro $fieldAccess != null;
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
					// ω-issue-423-mech-a: when the Ref carries
					// `@:fmt(propagateExprPosition)`, wrap the opt arg in
					// `_setExprPosition` so the descendant writer (and ANY
					// further recursive descent through it) sees
					// `_inExprPosition=true`. Idempotent — already-true opt
					// passes through without re-allocating. Consumers:
					// `HxVarDecl.init`, `HxObjectField.value`,
					// `HxParenLambda.body`, `HxThinParenLambda.body` — every
					// expression-position-yielding Ref parent that ANY case-
					// body descendant might see.
					final propagateExpr:Bool = child.fmtHasFlag('propagateExprPosition');
					// ω-arrow-lambda-body-context: sister opt-fanout to
					// `propagateExprPosition` — when the mandatory Ref carries
					// `@:fmt(propagateAnonFnContext)`, wrap opt in
					// `_setAnonFnBody` so the descendant writer sees
					// `_inAnonFnBody=true`. Used by `HxParenLambda.body` and
					// `HxThinParenLambda.body` so the inner `HxExpr.BlockExpr`
					// reads `opt.anonFunctionLeftCurly` for its `{` placement
					// instead of the global `opt.blockLeftCurly`. Mirrors the
					// optional-Ref site above (consumer: `HxFnExpr.body`).
					final propagateAnonFn:Bool = child.fmtHasFlag('propagateAnonFnContext');
					// ω-typedef-anon-force-multi: sister opt-fanout — when the
					// mandatory Ref carries `@:fmt(propagateTypedefContext)`,
					// wrap opt in `_setTypedefBody` so the descendant writer
					// sees `_inTypedefBody=true`. Used by `HxTypedefDecl.type`
					// so the inner `HxType.Anon.fields` Star reads
					// `opt._inTypedefBody=true` and forces multi-line via
					// `WrapList.emit(..., forceMode = WrapMode.OnePerLine)`.
					// Composes with sister flags by stacked wrapping.
					final propagateTypedef:Bool = child.fmtHasFlag('propagateTypedefContext');
					// ω-extern-class-no-blanks:
					// `@:fmt(setBoolFlagFromStarCtor(optField, starField,
					// ctorName))` allocates a fresh opt copy
					// (`_wo = _copyOpt(opt)`) and sets `_wo.<optField> = true`
					// iff the parent struct's sibling `<starField>` Star
					// contains an element matching `<ctorName>`. Used by
					// `HxTopLevelDecl.decl` to propagate `_classExtern` from
					// the presence of `Extern` in `modifiers`, so descendants
					// (`HxClassDecl.members`) can suppress
					// `interMemberBlankLines`-driven blanks. Trivia-bearing
					// path probes `_m.node.match(<ctorName>)` because Star
					// elements wrap the underlying enum in `Trivial<...>`;
					// plain mode probes `_m.match(<ctorName>)` directly.
					// Composes with `propagateExprPosition` — when both metas
					// fire on the same field, `_wo._inExprPosition = true` is
					// set inline alongside the bool-flag assignment so a
					// single opt copy carries both modifications.
					final boolFlagArgs:Null<Array<String>> = child.fmtReadStringArgs('setBoolFlagFromStarCtor');
					if (boolFlagArgs != null && boolFlagArgs.length != 3)
						Context.fatalError(
							'WriterLowering: @:fmt(setBoolFlagFromStarCtor) expects 3 string args (optField, starField, ctorName), got ${boolFlagArgs.length}',
							Context.currentPos()
						);
					// ω-switch-subject-nowrap (condition_wrapping_switch): the
					// fork NEVER wraps a switch subject — `markPWrapping`'s
					// `case SwitchCondition:` falls through with an empty body
					// (no `wrapCondition` / `wrapExpressionParen`), unlike
					// `IfCondition` / `WhileCondition` / `ForLoop`. Thread
					// `_setChainModeOverride(opt, NoWrap)` into the subject
					// `expr` sub-call so a top-level `+`/`-`/`&&`/`||` chain in
					// the subject stays flat regardless of the
					// `opAddSubChain` / `opBoolChain` config. Mirror of the
					// string-interp `captureSource`→NoWrap site (above): the
					// override swaps ONLY `opBoolChainWrap` / `opAddSubChainWrap`
					// to a degenerate `{rules: [], defaultMode: NoWrap}` cascade,
					// so nested `Call` / `ArrayLiteral` parens inside the subject
					// keep their own wrap config (matching the fork's per-`Call`
					// `markPWrapping` recursion). `NoWrap` is distinct from the
					// `FillLineWithLeadingBreak` cond-wrap mode, so the chain
					// dispatch's `_condWrapForced` gate (== FLWLB) stays false —
					// no interaction with the inc6 chain-unwrap path. Carried by
					// `HxSwitchStmt.expr` / `HxSwitchStmtBare.expr`.
					final switchSubjectNoWrap:Bool = child.fmtHasFlag('switchSubjectNoWrap');
					final optArgExpr:Expr = if (boolFlagArgs != null) {
						macro _wo;
					} else {
						var e:Expr = macro opt;
						if (propagateExpr) e = macro _setExprPosition($e);
						if (propagateAnonFn) e = macro _setAnonFnBody($e);
						if (propagateTypedef) e = macro _setTypedefBody($e);
						if (switchSubjectNoWrap)
							e = macro _setChainModeOverride($e, anyparse.format.wrap.WrapMode.NoWrap);
						e;
					};
					final baseRawWriteCall:Expr = {
						expr: ECall(macro $i{writeFn}, [fieldAccess, optArgExpr]),
						pos: Context.currentPos(),
					};
					final rawWriteCall:Expr = if (boolFlagArgs == null) baseRawWriteCall;
					else {
						final pos:Position = Context.currentPos();
						final optField:String = boolFlagArgs[0];
						final starField:String = boolFlagArgs[1];
						final ctorName:String = boolFlagArgs[2];
						final starAccess:Expr = {expr: EField(macro value, starField), pos: pos};
						final flagAccess:Expr = {expr: EField(macro _wo, optField), pos: pos};
						final ctorIdent:Expr = {expr: EConst(CIdent(ctorName)), pos: pos};
						final useNodeAccess:Bool = ctx.trivia && isTriviaBearing(typePath);
						final probeBody:Expr = useNodeAccess
							? macro for (_m in $starAccess) if (_m.node.match($ctorIdent)) { _f = true; break; }
							: macro for (_m in $starAccess) if (_m.match($ctorIdent)) { _f = true; break; };
						final propagateExprStmt:Expr = propagateExpr ? (macro _wo._inExprPosition = true) : (macro {});
						// Each `macro …` reification in an array literal must be
						// parenthesised — bare `macro` after `[…,` mis-parses as
						// "Keyword macro cannot be used as variable name". Plain
						// identifiers (`propagateExprStmt`, `baseRawWriteCall`)
						// are fine as-is.
						final block:Array<Expr> = [
							(macro final _wo = _copyOpt(opt)),
							propagateExprStmt,
							(macro {
								var _f:Bool = false;
								$probeBody;
								$flagAccess = _f;
							}),
							baseRawWriteCall,
						];
						{expr: EBlock(block), pos: pos};
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
					// ω-condition-parens (Stage C): `@:fmt(sharpCondParensInside(
					// '<insideOpenKnob>', '<insideCloseKnob>'))` on the verbatim
					// `#if (cond)` condition (`HxConditionalStmt.cond`, a
					// `@:rawString HxPpCondLit` whose capture INCLUDES the outer
					// parens). The cond writer emits the captured string verbatim,
					// so the inner pad cannot ride the lead/trail path — it
					// rewrites the opaque string at write time. When the string is
					// wrapped in matching outer parens (`(…)`), inject inner spaces
					// per `opt.<knob>` (`After`/`Both` → open pad, `Before`/`Both`
					// → close pad); non-parenthesised conds (`#if php`) pass
					// through unchanged. Null policies → no pad → byte-identical
					// to the verbatim capture.
					final sharpInsideArgs:Null<Array<String>> = child.fmtReadStringArgs('sharpCondParensInside');
					final effRawWriteCall:Expr = if (sharpInsideArgs != null && sharpInsideArgs.length == 2) {
						final openKnob:Expr = optFieldAccess(sharpInsideArgs[0]);
						final closeKnob:Expr = optFieldAccess(sharpInsideArgs[1]);
						final wpAfter:Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'WhitespacePolicy', 'After']);
						final wpBoth:Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'WhitespacePolicy', 'Both']);
						final wpBefore:Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'WhitespacePolicy', 'Before']);
						macro {
							final _condStr:String = ($fieldAccess : String);
							if (_condStr.length >= 2 && StringTools.fastCodeAt(_condStr, 0) == '('.code
									&& StringTools.fastCodeAt(_condStr, _condStr.length - 1) == ')'.code) {
								final _inner:String = _condStr.substr(1, _condStr.length - 2);
								final _op:anyparse.format.WhitespacePolicy = $openKnob;
								final _cp:anyparse.format.WhitespacePolicy = $closeKnob;
								final _openPad:String = (_op == $wpAfter || _op == $wpBoth) ? ' ' : '';
								final _closePad:String = (_cp == $wpBefore || _cp == $wpBoth) ? ' ' : '';
								_dt('(' + _openPad + _inner + _closePad + ')');
							} else _dt(_condStr);
						}
					} else rawWriteCall;
					final writeCall:Expr = bodyPolicyFlag != null && indentObjArgs != null
						? effRawWriteCall
						: maybeIndentValueIfCtor(effRawWriteCall, fieldAccess, child);
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
						//
						// ω-untyped-keep-trybody: `@:fmt(beforeNewlineSlotFirst)`
						// opt-in extends slot reading to first-field bodyPolicy
						// paths. Pairs with parent Alt-branch
						// `@:fmt(forwardNewlineForBody)` (Case 3 omits post-kw
						// `skipWs`) and `TriviaTypeSynth.isBareNonFirstRef` /
						// `Lowering.hasBeforeNewlineSlot` first-field allowances.
						// Currently consumed by `HxTryCatchStmt.body` for
						// `untypedBody=Keep` source-shape preservation.
						final firstFieldNlOptIn:Bool = isFirstField && child.fmtHasFlag('beforeNewlineSlotFirst');
						final bodyOnSameLineExpr:Null<Expr> = ctx.trivia && (!isFirstField || firstFieldNlOptIn)
							? beforeNewlineNotAccess(fieldName)
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
						// ω-issue-168: `@:fmt(bodyAllmanIndentForCtor('<ctor>',
						// '<optField>', '<lcField>'))` runtime-overrides the
						// policy-decided layout when the body's runtime ctor
						// matches `<ctor>` AND `opt.<optField>` is true AND
						// `opt.<lcField>` is `Next` AND the body's writeCall
						// emits internal hardlines (multi-line). The override
						// places the body in Allman position with extra
						// `+cols` indent on contents, regardless of Keep/Same/
						// Next/FitLine policy. Currently consumed by
						// `HxForExpr.body` for the `[for (x in xs) {<multi>}]`
						// shape; HxIfExpr.thenBranch deliberately does NOT
						// carry this meta because fork keeps `if (cond) {`
						// cuddled.
						final bodyAllmanIndentArgs:Null<Array<String>> = child.fmtReadStringArgs('bodyAllmanIndentForCtor');
						// ω-expression-if-with-blocks: `@:fmt(inlineBlockBodyIfFlag(
						// '<flagName>'))` reads `opt.<flagName>:Bool` at runtime;
						// when true AND body's runtime ctor is `BlockExpr`, wrap
						// the body's writeCall result in `D.flatten(…)` to collapse
						// `{<hardline>stmt;<hardline>}` to `{stmt;}` regardless of
						// width. Mirrors fork's `expressionIfWithBlocks` knob
						// (`MarkSameLine.markBody` with `includeBrOpen=true` →
						// `markBlockBody` Same-policy collapse). Currently consumed
						// by `HxIfExpr.thenBranch` / `elseBranch`. Non-BlockExpr
						// bodies and flag-false fall through to the regular policy
						// cascade.
						final inlineBlockBodyArgs:Null<Array<String>> = child.fmtReadStringArgs('inlineBlockBodyIfFlag');
						parts.push(bodyPolicyWrap({
							flagName: bodyPolicyFlag,
							exprFlagName: bodyPolicyExprFlag,
							writeCall: writeCall,
							bodyValueExpr: fieldAccess,
							bodyTypePath: refName,
							hasElseIf: hasElseIf,
							elseFieldName: elseFieldName,
							bodyOnSameLineExpr: bodyOnSameLineExpr,
							kwPolicyFlagName: kwPolicyFlag,
							afterTrailExpr: afterTrailExpr,
							indentObjArgs: indentObjArgs,
							policyOverrides: policyOverrides,
							bodyAllmanIndentArgs: bodyAllmanIndentArgs,
							fallbackFlagName: fallbackFlag,
							inlineBlockBodyArgs: inlineBlockBodyArgs,
						}));
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
							// ω-untyped-keep: `@:fmt(bodyPolicyForCtor('<ctor>',
							// '<flagName>'))` on a struct field with leftCurly path
							// runtime-replaces the per-ctor `sep + writeCall` pair with
							// a `bodyPolicyWrap` invocation when the body's runtime
							// ctor matches. The wrap reads `opt.<flagName>` for policy
							// and (when the field's `<field>BeforeNewline:Bool` slot
							// is synthesised — bare non-first Ref / trivia-bearing
							// path, see `hasBeforeNewlineSlot` in `Lowering.lowerStruct`)
							// reads `!value.<field>BeforeNewline` as `bodyOnSameLine`
							// for the `Keep` dispatch. Other ctors keep the existing
							// per-ctor switch unchanged.
							//
							// Architectural rationale: pre-kw gap before an inner kw
							// (e.g. `untyped` inside `HxUntypedFnBody.block`) is
							// consumed by parent-struct's pre-field skipWs BEFORE the
							// inner sub-rule probes. Capturing the slot at the inner
							// kw site always reads `true`. Moving the wrap from inner
							// ctor (`HxFnBody.UntypedBlockBody`) to outer struct field
							// (`HxFnDecl.body`) places it where the `bodyBeforeNewline`
							// slot is captured by the existing `hasBeforeNewlineSlot`
							// path — which fires during the parent struct's parse,
							// when the gap is still in play.
							//
							// ω-fnbody-keep: `bodyPolicyForCtor` accepts MULTIPLE
							// `('<ctor>', '<flagName>')` pairs (repeatable), each
							// routing its own runtime ctor to a `bodyPolicyWrap`
							// with the named policy flag. Built as a ternary chain
							// — `Type.enumConstructor(body) == ctorᵢ ? wrapᵢ : …` —
							// falling through to the per-ctor `sep + writeCall`
							// `defaultPair` for every ctor with no pair. Consumers:
							// `HxFnDecl.body` for `('UntypedBlockBody', 'untypedBody')`
							// (the `untyped {…}` body) AND `('ExprBody', 'functionBody')`
							// (the `return …` / bare-expr body). Both share ONE root
							// cause — the signature→body source-newline gap is consumed
							// by the parent struct's pre-field `skipWs` before the branch
							// sub-rule probes, so the slot must be read at the parent
							// (where `bodyBeforeNewline` IS captured), NOT inside the
							// branch (a kw-less branch grows no `bodyOnSameLine` slot and
							// the gap is already gone). `ExprBody` therefore drops its
							// prior branch-local `@:fmt(bodyPolicy('functionBody'))`; the
							// separator + Keep dispatch now live entirely on this parent
							// wrap. `bodyValueExpr` is the `HxFnBody` value: only
							// `bodyPolicyWrap`'s ctor-override / single-line / block-split
							// paths consult it, none of which `functionBody` / `untypedBody`
							// (plain policies, no override args) reach — so Same/Next
							// output stays byte-identical to the pre-slice inner-branch
							// emission.
							final bodyPolicyForCtorPairs:Array<Array<String>> = child.fmtReadStringArgsAll('bodyPolicyForCtor');
							if (bodyPolicyForCtorPairs.length > 0) {
								final hasBeforeNlSlot:Bool = ctx.trivia && isTriviaBearing(typePath)
									&& !isFirstField && kwLead == null && leadText == null;
								final wrapBodyOnSameLineExpr:Null<Expr> = hasBeforeNlSlot
									? beforeNewlineNotAccess(fieldName)
									: null;
								final defaultPair:Expr = macro _dc([$sepExpr, $writeCall]);
								// Fold the pairs into a ternary chain. Iterate in reverse
								// so the first-declared pair sits at the chain head
								// (tested first at runtime).
								var chain:Expr = defaultPair;
								var i:Int = bodyPolicyForCtorPairs.length - 1;
								while (i >= 0) {
									final pair:Array<String> = bodyPolicyForCtorPairs[i];
									if (pair.length != 2)
										Context.fatalError('WriterLowering: @:fmt(bodyPolicyForCtor(...)) requires (ctorName, flagName), got ${pair.length} args', Context.currentPos());
									final wrapCtorName:String = pair[0];
									final wrapFlagName:String = pair[1];
									final wrapOutput:Expr = bodyPolicyWrap({
										flagName: wrapFlagName,
										writeCall: writeCall,
										bodyValueExpr: fieldAccess,
										bodyTypePath: refName,
										hasElseIf: false,
										elseFieldName: null,
										bodyOnSameLineExpr: wrapBodyOnSameLineExpr,
									});
									chain = macro $ctorExpr == $v{wrapCtorName} ? $wrapOutput : $chain;
									i--;
								}
								parts.push(chain);
							} else {
								parts.push(sepExpr);
								parts.push(writeCall);
							}
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
								// Non-matching ctor falls through to the same
								// BeforeNewline-aware separator the plain
								// bare-Ref non-first branch uses below
								// (ω-issue-48-v2 mechanism). In trivia mode the
								// synth slot `<f>BeforeNewline` records whether
								// source had a newline before this field's
								// first token; preserve it so `@:m if (…)` etc.
								// honour source-side line breaks the same way
								// the rest of the writer does. Plain mode (no
								// trivia signal) keeps the unconditional space.
								final sepExpr:Expr = ctx.trivia && isTriviaBearing(typePath)
									? macro ${beforeNewlineAccess(fieldName)} ? _dhl() : _dt(' ')
									: macro _dt(' ');
								parts.push(macro {
									final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
									final _doc:anyparse.core.Doc = $writeCall;
									$ctorMatchExpr ? _dn(_cols, _dc([_dhl(), _doc])) : _dc([$sepExpr, _doc]);
								});
							} else if (child.fmtHasFlag('nestBodyOnSourceNewline') && ctx.trivia && isTriviaBearing(typePath)) {
								// ω-cond-comp-expr-body-nest: source-shape-driven
								// body break+nest. The bare-Ref non-first slot
								// `<f>BeforeNewline:Bool` (synth via
								// `TriviaTypeSynth.isBareNonFirstRef`) records
								// whether the source had a newline before this
								// field's first token. When true the wrapper
								// emits `Nest(_cols, [hardline, body])` so the
								// body sits one indent step deeper than the
								// preceding `#if`/`#elseif` keyword line; when
								// false the wrapper emits `' ' + body` for
								// inline single-line cond-comp expressions.
								// Currently consumed by `HxConditionalExpr.expr`
								// and `HxElseifExpr.expr`.
								final nlSignal:Expr = beforeNewlineAccess(fieldName);
								parts.push(nestBodyOnSourceNewlineWrap(writeCall, nlSignal));
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
									final nlAccess:Expr = beforeNewlineAccess(fieldName);
									final triviaSepExpr:Expr = if (prevAnyStarNonEmpty != null) {
										final prev:Expr = prevAnyStarNonEmpty;
										macro $prev ? ($nlAccess ? _dhl() : _dt(' ')) : _de();
									} else macro $nlAccess ? _dhl() : _dt(' ');
									parts.push(withPadTrailingDrop(prevPadTrailing, triviaSepExpr));
								} else if (prevAnyStarNonEmpty != null) {
									final prev:Expr = prevAnyStarNonEmpty;
									parts.push(withPadTrailingDrop(prevPadTrailing, macro $prev ? _dt(' ') : _de()));
								} else parts.push(withPadTrailingDrop(prevPadTrailing, macro _dt(' ')));
								parts.push(writeCall);
							}
						} else if (hasCondWrap && spanInfo != null) {
							// ω-condwrap-forstmt: span mode — defer the
							// `emitCondition` wrap to the end-field
							// iteration. Push writeCall directly so
							// inter-field separators / kw text /
							// trailing-field writeCall accumulate in
							// `parts` for splicing at the end. The
							// `_setChainModeOverride` shadow is also
							// applied lazily (inside the end-field's
							// splice block) so the inner writeCalls see
							// the overridden cascade.
							parts.push(writeCall);
						} else if (hasCondWrap) {
							// ω-condition-wrap-wiring: replace bare lead+
							// value+trail emission with a runtime
							// `WrapList.emitCondition` call. The lead and
							// trail pushes above are gated off by
							// `hasCondWrap`; here the writer emits the
							// `Group(IfBreak(brk, flat))` shape driven by
							// `opt.<knob>:WrapRules` so the renderer
							// commits to `(cond)` or `(\n\tcond\n)` based
							// on column fit at layout time.
							//
							// ω-chain-fillline-in-condwrap: before the
							// inner cond Ref writeCall evaluates, shadow
							// `opt` with `_setChainModeOverride(opt, ovr)`
							// where `ovr` is derived from the cond
							// cascade's `defaultMode` (NoWrap → null, no
							// allocation). The helper swaps
							// `opBoolChainWrap` / `opAddSubChainWrap` to
							// `{rules: [], defaultMode: mode}` so the
							// chain dispatch inside the cond emits the
							// override mode directly — mirrors fork's
							// `collapseChainWraps` post-pass output shape
							// without a Doc-IR post-collapse phase. The
							// outer `WrapList.emitCondition` receives the
							// same shadowed opt; harmless because the
							// cond knob itself is preserved by `_copyOpt`.
							final condKnobAccess:Expr = optFieldAccess(condWrapArgs[0]);
							// ω-condition-parens (Stage C): `@:fmt(condParensInside(
							// '<insideOpenKnob>', '<insideCloseKnob>'))` on the
							// condWrap cond field pads the FLAT `( cond )` shape via
							// `opt.<knob>:WhitespacePolicy`. Null when absent →
							// `_de()` inner Docs → tight `(cond)` byte-identical.
							final condInsideArgs:Null<Array<String>> = child.fmtReadStringArgs('condParensInside');
							final condInsideOpen:Expr = (condInsideArgs != null && condInsideArgs.length == 2)
								? policyInsideSpace(condInsideArgs[0], false)
								: macro _de();
							final condInsideClose:Expr = (condInsideArgs != null && condInsideArgs.length == 2)
								? policyInsideSpace(condInsideArgs[1], true)
								: macro _de();
							// ω-condition-wrap-keep: read the `<field>CondOpenNewline:Bool`
							// synth slot (populated by `Lowering` when the source broke
							// right after the open paren) and thread it into
							// `emitCondition`'s `sourceOpenNewline` arg. Under
							// `WrapMode.Keep` the engine forces `brkShape` so the
							// author's post-`(` break round-trips. Gated on trivia +
							// bearing + the field opting in via
							// `@:fmt(captureCondOpenNewline)`; otherwise the slot does
							// not exist, so we pass a literal `false` → byte-inert
							// (plain mode, non-keep modes, non-opted condWrap fields).
							final hasCondOpenNewlineSlot:Bool = ctx.trivia
								&& isTriviaBearing(typePath)
								&& child.fmtHasFlag('captureCondOpenNewline');
							final condOpenNewlineExpr:Expr = hasCondOpenNewlineSlot
								? {expr: EField(macro value, fieldName + TriviaTypeSynth.CONDITION_OPEN_NEWLINE_SUFFIX), pos: Context.currentPos()}
								: macro false;
							// ω-condition-wrap-keep: only the trivia-bearing Haxe cond
							// path (slot present) sets `_keepChainInParen` — the
							// `_setKeepChainInParen` helper exists only on opt types that
							// declare `_keepChainInParen` (Haxe `HxModuleWriteOptions`). A
							// generic `@:fmt(condWrap)` grammar without the slot emits the
							// plain opt shadow → no reference to the Haxe-only helper. The
							// runtime `sourceOpenNewline` + Keep gate further narrows the
							// flag to force-broken keep conds.
							final condKeepChainInParen:Expr = hasCondOpenNewlineSlot
								? macro {
									final _condKeepBrk:Bool = $condOpenNewlineExpr
										&& _condMode == anyparse.format.wrap.WrapMode.Keep;
									final opt = _condKeepBrk ? _setKeepChainInParen(opt, true) : opt;
									opt;
								}
								: macro opt;
							parts.push(macro {
								final _condRules:anyparse.format.wrap.WrapRules = $condKnobAccess;
								final _condMode:anyparse.format.wrap.WrapMode = _condRules.defaultMode;
								final _chainOvr:Null<anyparse.format.wrap.WrapMode> =
									_condMode == anyparse.format.wrap.WrapMode.NoWrap ? null : _condMode;
								// ω-expr-paren-in-condition (cond F2): mark the condition
								// content so an expression paren INSIDE it routes its inner
								// chain through `expressionWrapping` (fillLine) instead of
								// the unconditional HardFlatten collapse — the fork applies
								// `expressionWrapping` to expr parens regardless of context.
								// The flag is consumed ONLY at the `ParenExpr` lowering (it
								// threads the fillLine `_chainModeOverride` into the paren's
								// OWN inner chain and clears the flag), so the condition's
								// top-level chain (`a && b`) is untouched. Byte-inert for
								// the universal default `expressionWrappingWrap`
								// (`{rules: [], defaultMode: NoWrap}` → false).
								final _parenCond:Bool =
									anyparse.format.wrap.WrapList.effectiveExpressionWrapMode(opt.expressionWrappingWrap) != null;
								final opt = _setParenInCondition(_setChainModeOverride(opt, _chainOvr), _parenCond);
								// ω-condition-wrap-keep: when the cond paren is force-broken
								// (source newline after `(` + Keep mode → `emitCondition`
								// returns `brkShape`), the `brkShape`'s `Nest(cols, condDoc)`
								// already supplies the +cols paren indent. Mark the cond
								// chain's opt `_keepChainInParen` so its OWN continuation
								// `Nest` is suppressed (chain operators co-indent with the
								// head at outer+cols, not compounding to outer+2cols) AND its
								// own `_headBreak` is dropped (`brkShape`'s leading `Line`
								// already put the head operand on its own line). Reuses the
								// f9d6a53 `_keepChainInParen` channel (gated there on the
								// chain config being Keep). `condKeepChainInParen` is a
								// macro-time no-op (`opt`) for non-Haxe / non-bearing grammars
								// so the Haxe-only `_setKeepChainInParen` helper is never
								// referenced there.
								final opt = $condKeepChainInParen;
								anyparse.format.wrap.WrapList.emitCondition(
									$v{leadText}, $v{trailText}, $writeCall, opt, $condKnobAccess,
									$condInsideOpen, $condInsideClose, $condOpenNewlineExpr
								);
							});
						} else if (child.fmtHasFlag('arrowBodyLineWrap')) {
							// ω-arrow-body-line-wrap: when the line containing
							// the lambda body — `(params) -> body` plus rest of
							// stack — would exceed `opt.lineWidth`, break after
							// `->` (or `=>`) and indent the body one level. The
							// preceding lead emission via `whitespacePolicyLead`
							// terminates with `_dop(' ')` (OptSpace); the brk
							// side's leading hardline triggers the renderer's
							// `pendingOptSpace` clear so the post-arrow space
							// drops cleanly without leaving a trailing token.
							// Flat side is the bare writeCall — byte-identical
							// to the pre-slice default branch below.
							//
							// Mirrors fork's `MarkWrapping.applyArrowWrapping`
							// (`MarkWrapping.hx:985-1041`): collect arrows whose
							// flat line exceeds `maxLineLength`, apply break
							// after `->`, try collapse, restore on still-exceed.
							// Our `_dile` IS the collapse — flat side fires
							// when the line fits, brk side fires when it does
							// not, both decided at render time.
							//
							// Wrapped in `_dwb` (WrapBoundary) so a sister probe
							// in `WrapList.shapeFillLine` 1-item path can detect
							// the arrow-body-line-wrap signature structurally
							// and route the outer Call's close paren to its own
							// line (mirrors fork's parent-walk close-paren mark
							// in `applyArrowWrapping`'s `lineEndBefore(pClose)`).
							// Slice-2 follow-up extends `isChainOPLBreak`.
							//
							// Currently consumed by `HxThinParenLambda.body`
							// (`->` form) and `HxParenLambda.body` (`=>` form)
							// for symmetric coverage of the canonical and
							// legacy lambda-body syntaxes.
							parts.push(macro {
								final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
								final _doc:anyparse.core.Doc = $writeCall;
								_dwb(_dile(opt.lineWidth, _dn(_cols, _dc([_dhl(), _doc])), _doc));
							});
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
			// ω-condition-parens (Stage C): `@:fmt(catchParensInsideClose)` on
			// a mandatory-Ref `@:trail(')')` field routes the close literal
			// through `opt.catchParensInsideClose` (`Before`/`Both` → inner
			// ` )` pad). No flag → tight `_dt(trailText)` byte-identical.
			if (!isOptional && trailText != null && !hasCondWrap && !hasCondWrapEnd)
				parts.push(whitespacePolicyTrail(child, trailText, ['catchParensInsideClose', 'switchCondParensInsideClose', 'whileCondParensInsideClose']));
			// ω-struct-trailopt-source-track (Session 14 Phase 4): mandatory-
			// Ref `@:trailOpt(LIT)` field gates the trail emission on the
			// synth slot `<field>TrailPresent:Null<Bool>` so the writer
			// preserves source presence (true -> `;`, false -> ``) rather
			// than always re-emitting the canonical trail. Gate on
			// `hasStructFieldTrailOptSlot` (trivia mode + bearing) so plain
			// mode and non-bearing rules preserve pre-Phase-4 silent-drop
			// behaviour for now — pre-Phase-4 the writer never reached the
			// trail emit for mandatory-Ref `@:trailOpt` (it read trail from
			// `:trail` only, not `:trailOpt`), so no fixture in the corpus
			// exercised source-preservation for these fields. `null` on
			// `<field>TrailPresent` is reserved for raw->paired upcasts
			// from `Converters.rawToPaired_*` and falls through to
			// canonical emit via the `==false` test.
			if (hasStructFieldTrailOptSlot && !isOptional && !hasCondWrap && !hasCondWrapEnd && trailOptText != null)
				parts.push(macro $structTrailOptAccess == false ? _de() : _dt($v{trailOptText}));

			// ω-pad-trailing-ref: bare-Ref `@:fmt(padTrailing)` — mandatory
			// Ref always fires, so push a trailing space unconditionally and
			// set tracker to a constant `true`. Optional-Ref padTrailing was
			// pushed inside `optParts` above (gated on `_optVal != null`),
			// so this branch covers ONLY the mandatory-Ref kind. Star-kind
			// fields were already handled by the early-continue paths above.
			// Position: AFTER `@:trail` push so the pad lands BETWEEN the
			// field's writeCall (+ any trail literal) and the next sibling's
			// leading sep — that's the boundary where `sameLineSeparator`
			// reads `prevPadTrailing` and drops to `_de()`.
			//
			// First consumer: `HxConditionalExpr.expr` (mandatory bare Ref)
			// so `expr` → either `#elseif` / `#else` / outer `#end` lands
			// with one inter-token space instead of either glued (no engine)
			// or doubled (naive padTrailing without engine drop).
			//
			// `thisTransparent` is `null` for mandatory bare Ref (always
			// emits visible content), `$fieldAccess == null` for optional
			// Ref (transparent when absent). The latter lets a prev pad
			// signal propagate across an absent optional Ref middle field.
			if (!isStar && !isOptional && child.fmtHasFlag('padTrailing')) {
				parts.push(padTrailingDoc(node, child, typePath));
				thisPadTrailing = macro true;
			}
			if (isStar) {
				// Star kinds already updated `prevPadTrailing` via their
				// early-continue path; Star branches never reach this
				// shared end-of-loop block, so `thisTransparent` is moot.
			} else if (isOptional) {
				thisTransparent = macro $fieldAccess == null;
			}

			prevAnyStarNonEmpty = null;
			prevBodyField = justWrappedBody;
			prevPadTrailing = composePadTrailing(prevPadTrailing, thisPadTrailing, thisTransparent);
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
			// Slice 40: optional Refs with `@:lead + @:trail` ALSO publish
			// the slot (mirror of the parser-side `hasAfterTrailSlot`
			// extension). The lead-led commit branch captures the
			// post-trail `// comment` and the absent branch leaves the
			// slot null — both feed the downstream tryparse Star's
			// `tryparsePriorAfterTrailExpr` read uniformly.
			prevTrailFieldName = (!isStar && trailText != null
				&& ctx.trivia && isTriviaBearing(typePath))
					? fieldName
					: null;
			isFirstField = false;

			// ω-condwrap-forstmt: end of span-mode iteration — splice the
			// accumulated cond-span Doc parts and wrap them in a single
			// `WrapList.emitCondition` call, mirroring the single-Ref
			// engine's emit at line ~2480 but with a runtime-built
			// composite condDoc (`_dc([...])`) instead of one writeCall.
			if (hasCondWrapEnd && spanInfo != null) {
				final spanLen:Int = parts.length - spanStartPartsIdx;
				final spanBuf:Array<Expr> = parts.slice(spanStartPartsIdx, parts.length);
				parts.splice(spanStartPartsIdx, spanLen);
				final innerDoc:Expr = if (spanBuf.length == 1) spanBuf[0] else dcCall(spanBuf);
				final condKnobAccess:Expr = optFieldAccess(spanInfo.knob);
				final leadStr:String = spanInfo.leadText;
				final trailStr:String = spanInfo.trailText;
				parts.push(macro {
					final _condRules:anyparse.format.wrap.WrapRules = $condKnobAccess;
					final _condMode:anyparse.format.wrap.WrapMode = _condRules.defaultMode;
					final _chainOvr:Null<anyparse.format.wrap.WrapMode> =
						_condMode == anyparse.format.wrap.WrapMode.NoWrap ? null : _condMode;
					final opt = _setChainModeOverride(opt, _chainOvr);
					anyparse.format.wrap.WrapList.emitCondition(
						$v{leadStr}, $v{trailStr}, $innerDoc, opt, $condKnobAccess
					);
				});
			}
		}

		// ω-multivar-wrap: when the struct opted into
		// `@:fmt(multiVarWrap('<knob>', '<moreField>'))`, bracket the whole
		// emitted body so the `<moreField>` Star gate (`_suppressMoreEntry ?
		// _de() : …`) and the head-only recursive self-calls resolve. The
		// generated body:
		//   final _suppressMoreEntry = opt._suppressMore;  // entry snapshot
		//   final opt = _clearSuppressMore(opt);           // head fields never
		//                                                  // see the flag, so a
		//                                                  // var decl nested in
		//                                                  // an initializer keeps
		//                                                  // its own `more`
		//   final _headPlusMore = _dc([parts]);            // head + (gated) more
		//   if (!_suppressMoreEntry && value.<more>.length > 0) {
		//     final _items = [ writeHxVarDeclT(value, _setSuppressMore(opt)) ];
		//     var _ml = value.<more>;        // Array<Trivial<HxVarMoreT>>
		//     while (_ml.length > 0) {
		//       final _link = _ml[0].node;   // HxVarMoreT
		//       _items.push(writeHxVarDeclT(_link.decl, _setSuppressMore(opt)));
		//       _ml = _link.decl.<more>;     // walk the right-recursion
		//     }
		//     return WrapList.emit('', '', ',', _items, opt, Empty, Empty,
		//       false, opt.<knob>);
		//   }
		//   return _headPlusMore;
		// `WrapList.shapeOnePerLineAfterFirst('', '', ',', …)` byte-reproduces
		// `head,\n\ttail,\n\ttail` (head inline, tail at +cols); the cascade's
		// column-aware `LineLengthLargerThan(80)` fires on the wide ~108-col
		// decl while `AllItemLengthsLessThan(15)` packs short lists FillLine.
		// Each item is head-only, so the continuation Nest is single-level —
		// the right-recursion never stacks Nests.
		final dcExpr:Expr = if (multiVarKnob == null || multiVarMoreField == null) dcCall(parts);
		else {
			final knobName:String = multiVarKnob;
			final moreFieldName:String = multiVarMoreField;
			final headPlusMore:Expr = dcCall(parts);
			final knobAccess:Expr = optFieldAccess(knobName);
			final selfFn:String = writeFnFor(typePath);
			final selfIdent:Expr = {expr: EConst(CIdent(selfFn)), pos: Context.currentPos()};
			final moreAccess:Expr = {expr: EField(macro value, moreFieldName), pos: Context.currentPos()};
			final linkMoreAccess:Expr = {expr: EField(macro _link.decl, moreFieldName), pos: Context.currentPos()};
			// In trivia mode the Star collects `Trivial<HxVarMoreT>` so the
			// element is reached via `.node`; in plain mode the Star holds the
			// raw `HxVarMore` directly. Both yield a value whose `.decl` is the
			// next `HxVarDecl(T)` link, so the rest of the walk is identical.
			final linkBind:Expr = ctx.trivia ? (macro final _link = _ml[0].node) : (macro final _link = _ml[0]);
			// ω-keep-newline-after-sep (increment 1): when this fold's
			// `WrapList.emit` resolves to `WrapMode.Keep`, the engine
			// reproduces each comma-link's source break iff the source
			// placed a newline AFTER the comma (`,\n  next`). That signal
			// lives on the trivia Star element's `Trivial.newlineAfterSep`
			// slot, so it is only available in trivia mode.
			// ω-keep-kw-newline (increment 1b): the HEAD break (`_breaks[0]`)
			// reproduces the source `var`→head newline (`var\n\trawRead`). The
			// `HxStatement.VarStmt` writer threads it onto `opt._varKwNewline`
			// (set only when the parser captured a newline after the `var` /
			// `final` keyword); this fold reads it for `_breaks[0]` and clears
			// the flag so the recursive head/link self-calls do not re-trigger.
			// Each loop step appends the link's `newlineAfterSep` flag, keeping
			// `_breaks` index-aligned with `_items`. In plain mode the Star
			// holds raw `HxVarMore` (no trivia) — `_breaks` stays empty and
			// `sourceBreakBefore` is passed `null`, so Keep falls back to
			// the legacy `shapeNoWrap` glue (byte-inert vs pre-slice).
			final breakDecl:Expr = ctx.trivia
				? (macro final _breaks:Array<Bool> = [_varKwNewlineHead])
				: (macro final _breaks:Null<Array<Bool>> = null);
			final breakStepPush:Expr = ctx.trivia
				? (macro _breaks.push(_ml[0].newlineAfterSep == true))
				: (macro {});
			macro {
				final _suppressMoreEntry:Bool = opt._suppressMore;
				final _varKwNewlineHead:Bool = opt._varKwNewline;
				final opt = _clearSuppressMore(_clearVarKwNewline(opt));
				final _headPlusMore:anyparse.core.Doc = $headPlusMore;
				if (!_suppressMoreEntry && $moreAccess.length > 0) {
					final _items:Array<anyparse.core.Doc> = [$selfIdent(value, _setSuppressMore(opt))];
					$breakDecl;
					var _ml = $moreAccess;
					while (_ml.length > 0) {
						$linkBind;
						$breakStepPush;
						_items.push($selfIdent(_link.decl, _setSuppressMore(opt)));
						_ml = $linkMoreAccess;
					}
					anyparse.format.wrap.WrapList.emit(
						'', '', ',', _items, opt,
						anyparse.core.Doc.Empty, anyparse.core.Doc.Empty,
						false, $knobAccess,
						// appendTrailingComma / leadFlat / leadBreak / forceExceeds
						false, anyparse.core.Doc.Empty, anyparse.core.Doc.Empty, false,
						// trailBreak: the statement's `;` (or block-end) follows the
						// last binding directly — no close delimiter here, so the
						// default `Line('\n')` would push the `;` onto its own line
						// under OnePerLine. `Empty` glues the `;` to the last binding.
						anyparse.core.Doc.Empty,
						// forceMode / compactContinuation / groupRestProbe /
						// sepBeforeFlags / sourceMultilineKeep — defaults; then
						// sourceBreakBefore: the per-link source-break flags that
						// drive `WrapList.shapeKeep` under `WrapMode.Keep` (null in
						// plain mode → legacy glue).
						null, false, false, null, false, _breaks
					);
				} else _headPlusMore;
			};
		}

		// ω-functionsignature-body-aware-indent: struct-level
		// `@:fmt(propagateFnBodyEmpty('<bodyField>'))` flags `opt._fnSigBodyEmpty`
		// based on emptiness of the named body field (typed `HxFnBody` / paired
		// `HxFnBodyT`). The flag is consumed by `WrapList.emit`'s cols formula
		// to drop the FillLine `+1` paren-bump continuation when the wrapped
		// signature is followed by an empty / absent body (`{}` / `;` /
		// `untyped {}`). Mirrors fork's token-tree `calcIndent` reduction.
		//
		// Save-mutate-eval-restore pattern guards nested HxFnDecl: each level
		// stashes the inherited flag and writes its own; restore reverts on
		// exit. The pattern matches `value.<bodyField>` against `HxFnBody`'s
		// four ctors with bare names so plain-mode (`HxFnBody`) and trivia-mode
		// (`HxFnBodyT`) both resolve cleanly — TriviaTypeSynth preserves ctor
		// names verbatim across paired types.
		final fnBodyEmptyArgs:Null<Array<String>> = node.fmtReadStringArgs('propagateFnBodyEmpty');
		if (fnBodyEmptyArgs == null) return macro return $dcExpr;
		if (fnBodyEmptyArgs.length != 1)
			Context.fatalError(
				'WriterLowering: @:fmt(propagateFnBodyEmpty) expects 1 string arg (bodyFieldName), got ${fnBodyEmptyArgs.length}',
				Context.currentPos()
			);
		final bodyField:String = fnBodyEmptyArgs[0];
		final bodyAccess:Expr = {expr: EField(macro value, bodyField), pos: Context.currentPos()};
		// ω-anonfnsignature-body-aware-indent: dispatch the empty-body
		// switch on the body field's actual enum type. `HxFnBody` and
		// `HxFnExprBody` share two bare ctor names (`BlockBody`,
		// `ExprBody`) but differ in the other ctors — a single
		// hardcoded form fails compilation on whichever enum lacks
		// `NoBody` / `UntypedBlockBody`. Resolve the type via the
		// body field's ShapeNode `base.ref` annotation (FQN, stripped
		// by `simpleName`) and emit the matching ctor set. The `T`-
		// suffixed variants (`HxFnBodyT` / `HxFnExprBodyT`) carry the
		// same ctor names per `TriviaTypeSynth` — share an arm. Optional
		// body (`Null<HxFnExprBody>` on `HxFnExpr.body`) gets a leading
		// `_body == null` guard so absent body (`@:overload(function(...))`)
		// flags as empty.
		var bodyRef:Null<String> = null;
		var bodyIsOptional:Bool = false;
		for (c in node.children) if (c.annotations.get('base.fieldName') == bodyField) {
			bodyRef = c.annotations.get('base.ref');
			bodyIsOptional = c.annotations.get('base.optional') == true;
			break;
		}
		if (bodyRef == null)
			Context.fatalError(
				'WriterLowering: @:fmt(propagateFnBodyEmpty) bodyField "$bodyField" not found in struct',
				Context.currentPos()
			);
		final bodyTypeName:String = simpleName(bodyRef);
		// ω-fnbody-empty-honours-orphan-trivia: in trivia mode, a `{ // comment }`
		// or `{\n // orphan \n}` body is NOT empty for fork's
		// `paren_indent_function_signature` rule — the comment is content, even
		// though `stmts.length == 0`. Mirror fork's behaviour by additionally
		// checking the synth slots `<field>TrailingOpen` (`// after open lit`)
		// and `<field>TrailingLeading` (orphan comments before close lit). Skip
		// `TrailingClose` (trailing AFTER `}` doesn't affect body content) and
		// `TrailingBlankBefore` (blank-line only is still empty). In plain mode
		// the slots don't exist on the body type, so the original
		// `_b.stmts.length == 0` form is preserved.
		final blockEmptyExpr:Expr = ctx.trivia
			? macro _b.stmts.length == 0 && _b.stmtsTrailingOpen == null && _b.stmtsTrailingLeading.length == 0
			: macro _b.stmts.length == 0;
		final untypedBlockEmptyExpr:Expr = ctx.trivia
			? macro _u.block.stmts.length == 0 && _u.block.stmtsTrailingOpen == null && _u.block.stmtsTrailingLeading.length == 0
			: macro _u.block.stmts.length == 0;
		final bodySwitchExpr:Expr = switch bodyTypeName {
			case 'HxFnBody' | 'HxFnBodyT':
				macro switch _body {
					case NoBody: true;
					case BlockBody(_b): $blockEmptyExpr;
					case UntypedBlockBody(_u): $untypedBlockEmptyExpr;
					case ExprBody(_): false;
				};
			case 'HxFnExprBody' | 'HxFnExprBodyT':
				macro switch _body {
					case BlockBody(_b): $blockEmptyExpr;
					case ExprBody(_): false;
				};
			case _:
				Context.fatalError(
					'WriterLowering: @:fmt(propagateFnBodyEmpty) unsupported body type "$bodyTypeName" (expected HxFnBody / HxFnExprBody)',
					Context.currentPos()
				);
				throw 'unreachable';
		};
		final isEmptyExpr:Expr = bodyIsOptional
			? macro {
				final _body = $bodyAccess;
				if (_body == null) true; else $bodySwitchExpr;
			}
			: macro {
				final _body = $bodyAccess;
				$bodySwitchExpr;
			};
		return macro {
			final _savedFnSigBodyEmpty:Bool = opt._fnSigBodyEmpty;
			opt._fnSigBodyEmpty = $isEmptyExpr;
			final _resultDoc:anyparse.core.Doc = $dcExpr;
			opt._fnSigBodyEmpty = _savedFnSigBodyEmpty;
			return _resultDoc;
		};
	}

	/** Emit writer steps for a Star struct field. */
	private function emitWriterStarField(
		starNode:ShapeNode, fieldAccess:Expr, parts:Array<Expr>,
		isLastField:Bool, typePath:String, isFirstField:Bool, isRaw:Bool,
		prevBareRefBody:Null<PrevBodyInfo> = null,
		prevTrailFieldName:Null<String> = null
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
			// ω-blockended-trivia-tryparse (Session 3): @:trivia + @:sep +
			// @:tryparse is now allowed when the `blockEnded` flag is
			// present (sole consumer: HxCaseBranch.body / HxDefaultBranch.stmts).
			// EOF mode (closeText == null, no @:tryparse) still rejects.
			final writerBlockEnded:Bool = starNode.annotations.get('lit.sepBlockEnded') == true;
			if (sepText != null && closeText == null && !starNode.hasMeta(':tryparse'))
				Context.fatalError('WriterLowering: @:trivia + @:sep requires close-peek (@:trail) or @:tryparse', Context.currentPos());
			if (sepText != null && starNode.hasMeta(':tryparse') && !writerBlockEnded)
				Context.fatalError(
					'WriterLowering: @:trivia + @:sep + @:tryparse requires blockEnded flag '
					+ '(@:sep(text, tailRelax, blockEnded))',
					Context.currentPos()
				);
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
			// ω-keep-fnsig-newline: accessor for the close-newline slot, threaded
			// into `triviaSepStarExpr` for the `_keepEmit` close placement.
			final trailNLAccess:Null<Expr> = fieldName == null
				? null
				: {expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_NEWLINE_BEFORE_SUFFIX), pos: Context.currentPos()};
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
					final optFlag:Expr = optFieldAccess(sameLineName);
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
				// iteration) and bare bodies force `_dhl()`. Both
				// `HxTryCatchStmt.catches` (block-form ctor with non-block
				// body via `ExprStmt(...)`) and `HxTryCatchStmtBare.catches`
				// (bare-form, body=HxExpr) opt in — non-block prev-body
				// pairs with `tryBody=Next` to keep the multi-line layout
				// coherent: `try\n\tBARE;\ncatch (...)`. Block bodies stay
				// under policy control (`sameLineCatch=Next` still breaks
				// `} catch` to `}\ncatch`). The block-ctor predicate is
				// `isBlockShapeEquivalentBranch` (sister of
				// `isBlockCtorBranch` that also accepts `@:fmt(blockShape)`
				// opt-in ctors like `UntypedBlockStmt(body:HxUntypedFnBody)`,
				// which emits `untyped { … }` — visually a block).
				final blockShapeAware:Bool = starNode.fmtHasFlag('blockBodyKeepsInline');
				final bareShapeAware:Bool = starNode.fmtHasFlag('bareBodyBreaks');
				final shapeAware:Bool = blockShapeAware || bareShapeAware;
				// `bareBodyBreaks` includes blockShape opt-in ctors (e.g.
				// `UntypedBlockStmt`) — they end with `}` and should be
				// treated as block for the catch-separator decision while
				// staying non-block in `bodyPolicyWrap`'s strict block-ctor
				// override path.
				final blockPatterns:Array<Expr> = sameLineName != null && prevBareRefBody != null && shapeAware
					? (bareShapeAware
						? collectBlockShapeEquivalentPatterns(prevBareRefBody.typePath)
						: collectBlockCtorPatterns(prevBareRefBody.typePath))
					: [];
				final elemBodyField:Null<String> = sameLineName != null && blockPatterns.length > 0
					? findElementBodyField(elemRefName, prevBareRefBody.typePath)
					: null;
				final blockKeepsInlineBranch:Expr = blockBodyKeepsInlineBranch(starNode);
				final firstSepOverride:Null<Expr> = if (blockPatterns.length == 0) closeTrailingFirstOverride;
				else {
					final fallback:Expr = closeTrailingFirstOverride ?? sepExpr;
					final blockBranch:Expr = blockShapeAware ? blockKeepsInlineBranch : fallback;
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
					final blockBranch:Expr = blockShapeAware ? blockKeepsInlineBranch : sepExpr;
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
				// ω-cond-mod-pad: `@:fmt(padLeading)`/`@:fmt(padTrailing)` on
				// a `@:trivia @:tryparse` Star emit a leading/trailing space
				// when non-empty (matches the non-trivia padLeading/padTrailing
				// branch), with the leading slot SWITCHING to `_dhl()` when
				// the source had a newline before the first element. Used by
				// `HxConditionalMod.body` so V1–V3 (single-line `#if X mods #end`)
				// stay on one line and V4 (newline-separated cond/mods/`#end`)
				// breaks all three pad slots together — the trail-side pad
				// follows the leading-side decision because the parser does
				// not capture a body→`#end` newline slot, but in legal source
				// shapes the two newlines are correlated.
				final tryparsePadLeading:Bool = starNode.fmtHasFlag('padLeading');
				final tryparsePadTrailing:Bool = starNode.fmtHasFlag('padTrailing');
				// ω-cond-indent-policy: `@:fmt(conditionalBodyIndent)` on a
				// `@:trivia @:tryparse` cond-comp body / elseBody / elseif-body
				// Star opts the body content into the runtime
				// `opt.conditionalPolicy` indent rule. When the policy is
				// `AlignedIncrease`, the body content (leading pad hardline +
				// each body element) is wrapped in `_dn(_cols, …)` so it sits
				// one level deeper than the `#if`/`#else`/`#end` markers, while
				// the trailing pad hardline (the `\n` before `#else`/`#end`)
				// is emitted OUTSIDE the nest so the close marker stays at the
				// surrounding statement indent. Nesting accumulates per
				// conditional depth (a nested `#if` body re-enters the same
				// `_dn`). DEFAULT `Aligned` → the runtime gate is false → the
				// pre-policy `else` branch fires → byte-identical. Only the
				// cond-comp body Stars carry this flag, so every other tryparse
				// Star consumer is untouched.
				final tryparseCondBodyIndent:Bool = starNode.fmtHasFlag('conditionalBodyIndent');
				// ω-issue-423-mech-a: `@:fmt(propagateExprPosition)` on a
				// `@:trivia @:tryparse` Star marks the body as an expression-
				// position frame for descendants. The runtime block emits an
				// always-copy of `opt` with `_inExprPosition = true` set, so
				// the dual-flag `bodyPolicy('A','B')` flat-gate in nested
				// case-body sites picks the expression-position policy
				// (`expressionCase`) instead of the statement-position one
				// (`caseBody`). Mirrors fork's `isReturnExpression` walk-up
				// heuristic — currently wired only by `HxCaseBranch.body` /
				// `HxDefaultBranch.stmts` so a case nested in another case's
				// body inherits expression context.
				final propagateExprPosition:Bool = starNode.fmtHasFlag('propagateExprPosition');
				// ω-issue-423-mech-b: `@:fmt(refuseFlatOnComplexExpr)` AND-s the
				// runtime `_flatCase` gate with `!opt.caseBodyRefusesFlat(_arr[0].node)`,
				// dispatching through the plugin-supplied adapter on
				// `WriteOptions` (Haxe wires it to `HxExprUtil.refusesCaseFlat`).
				// Engine never references the grammar plugin by name —
				// mirrors the `endsWithCloseBrace` adapter pattern. Null
				// adapter falls through (no refusal). Wired on
				// `HxCaseBranch.body` / `HxDefaultBranch.stmts` to mirror
				// fork's `MarkSameLine.markExpressionCase` body-shape check.
				final refuseFlatOnComplex:Bool = starNode.fmtHasFlag('refuseFlatOnComplexExpr');
				// ω-metadata-line-end-function: `@:fmt(metaLineEndPolicy('<optField>'))`
				// on a `@:trivia @:tryparse` Star wires inter-element + post-Star
				// separator dispatch through `opt.<optField>:MetadataLineEndPolicy`.
				// Default `None` (and absent flag) is byte-identical to pre-slice.
				final metaLineEndOptField:Null<String> = starNode.fmtReadString('metaLineEndPolicy');
				// ω-bug-2c-inner-star — read the same cascade `@:fmt(blankLines*)`
				// metas that the EOF-Star branch reads, so an inner Star (e.g.
				// `HxConditionalDecl.body`) opted in via the metas drives the
				// blank-line cascade between its sibling elements.
				final cascadeInfos:CascadeInfos = readCascadeInfosFromStar(starNode, elemRefName);
				// ω-trivia-tryparse-linelength: when the Star carries
				// `@:fmt(lineLengthAwareSeps)`, swap inter-element + padLeading
				// hard spaces for `_dile` probes + wrap in `_dn(_cols, ...)`.
				// Sister to the non-trivia bare-Star `padLeading||padTrailing`
				// branch's lineLengthAware path.
				final tryparseLineLengthAware:Bool = starNode.fmtHasFlag('lineLengthAwareSeps');
				// B4 ω-implements-extends-wrap: `@:fmt(heritageWrap)` on a
				// `@:trivia @:tryparse` Star (HxClassDecl.heritage /
				// HxInterfaceDecl.heritage) routes a MULTI-clause heritage list
				// (`extends A implements B …`) through the fork's
				// `wrapping.implementsExtends` FillLine layout: when the full
				// glued decl line is long, pack clauses from the front and break
				// the overflow clause(s) at additionalIndent 2 (8 spaces). The
				// single-clause path stays on the existing `lineLengthAwareSeps`
				// 1-tab break-before-keyword (matches fork single-clause +
				// `extends_break_before_keyword_not_type_params`). Abstract
				// `clauses` (from/to) never carries this flag — its
				// `lineLengthAwareSeps` behaviour is untouched.
				final tryparseHeritageWrap:Bool = starNode.fmtHasFlag('heritageWrap');
				// ω-slice-45 / issue_626: `@:fmt(forceInlineSep)` on a `@:trivia
				// @:tryparse` Star collapses every source linebreak between
				// consecutive elements to a single space. First consumers are
				// the modifier Stars on `HxMemberDecl.modifiers` and
				// `HxTopLevelDecl.modifiers` so multi-line `static\n\toverload`
				// round-trips as `static overload`. Comment trivia between
				// elements is out of scope — flag's contract is "treat
				// inter-element whitespace trivia as one space".
				final tryparseForceInlineSep:Bool = starNode.fmtHasFlag('forceInlineSep');
				// ω-trivia-tryparse-prior-after-trail: when the PREV sibling
				// field has a synthesised `<priorField>AfterTrail:Null<String>`
				// slot (mandatory Ref with `@:trail` in trivia-bearing mode),
				// thread its access so the Star can inline-emit the captured
				// trail-of-prev-field comment cuddled to the prev token.
				final tryparsePriorAfterTrailExpr:Null<Expr> = prevTrailFieldName == null
					? null
					: {expr: EField(macro value, prevTrailFieldName + TriviaTypeSynth.AFTER_TRAIL_SUFFIX), pos: Context.currentPos()};
				// ω-blockended-trivia-tryparse (Session 3): thread the Star's
				// `@:sep('text', tailRelax, blockEnded)` annotation into
				// `triviaTryparseStarExpr` so the helper can inject `;`
				// between two non-`}`-ending elements. Non-blockEnded
				// tryparse Stars (every existing consumer) pass null sepText
				// and the helper splices a no-op.
				final tryparseSepText:Null<String> = starNode.annotations.get('lit.sepText');
				final tryparseBlockEnded:Bool = starNode.annotations.get('lit.sepBlockEnded') == true;
				parts.push(triviaTryparseStarExpr(
					fieldAccess, elemFn, sepExpr, sameLineName != null, nestBody,
					tryparseTrailBB, tryparseTrailLC, tryparseTrailBA, firstSepOverride, subsequentSepOverride,
					caseBodyFlagNames, flatChildOptPairs, tryparsePadLeading, tryparsePadTrailing,
					propagateExprPosition, refuseFlatOnComplex,
					cascadeInfos.afterCtorInfos, cascadeInfos.beforeCtorInfos,
					cascadeInfos.betweenCtorInfos, cascadeInfos.transitionAcrossInfos,
					cascadeInfos.headCtorInfos,
					metaLineEndOptField,
					cascadeInfos.betweenSameCtorIfNotInfos,
					tryparseLineLengthAware,
					tryparsePriorAfterTrailExpr,
					tryparseForceInlineSep,
					tryparseBlockEnded ? tryparseSepText : null, tryparseBlockEnded,
					tryparseHeritageWrap,
					tryparseCondBodyIndent
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
					parts.push(leftCurlySeparator(starNode, isFirstField && hasKnobLeftCurly));
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
				// ω-blockended-trivia (Session 3): `@:sep('text', tailRelax,
				// blockEnded)` on a block-mode trivia Star (HxFnBlock.stmts
				// / HxBlockExpr.stmts / HxBlockStmt.stmts) keeps the
				// per-element hardlined block layout — sep emit moves
				// INSIDE `triviaBlockStarExpr` (extended), NOT through the
				// flat-or-multi `triviaSepStarExpr`. Detect the flag here
				// and skip the sep dispatch so the fall-through reaches
				// the block dispatch with sepText/blockEnded threaded.
				final blockEndedFlag:Bool = starNode.annotations.get('lit.sepBlockEnded') == true;
				if (sepText != null && !blockEndedFlag) {
					// ω-cascade-emits-comments: emit the funcParamParens /
					// typeParamOpen space inside the @:trivia + sep
					// dispatch — the @:trivia path returns BEFORE the
					// no-trivia branch at `:3504-3510` that owns the
					// equivalent emit, so without this mirror the
					// `function foo ()` space (and sister knobs) is
					// silently dropped when the Star becomes @:trivia.
					// First-field Stars skip (matches the no-trivia path's
					// `!isFirstField` gate).
					if (!isFirstField) {
						final triviaParamSpace:Null<Expr> = openDelimPolicySpace(starNode, ['funcParamParens', 'typeParamOpen']);
						if (triviaParamSpace != null) parts.push(triviaParamSpace);
					}
					// ω-objectlit-source-trail-comma: when the Star also
					// carries `@:fmt(trailingComma('<knob>'))`, thread the
					// knob's field name into `triviaSepStarExpr` so its
					// no-trivia branch can `forceExceeds` on the wrap engine
					// when the source had a trailing separator AND the knob
					// is on. Null knob → behaves identically to pre-slice
					// (cascade evaluates exceeds=false / =true symmetrically).
					final trailingCommaField:Null<String> = starNode.fmtReadString('trailingComma');
					// ω-objectlit-right-curly: struct-Star path now threads
					// `@:fmt(rightCurly('<knob>'))` (e.g.
					// `rightCurly('objectLiteralRightCurly')` on
					// `HxObjectLit.fields`) into `triviaSepStarExpr`'s 12th
					// param. Null (no opt-in) preserves pre-slice
					// unconditional `_dhl()` before close.
					final knobRightCurly:Null<String> = starNode.fmtReadString('rightCurly');
					// ω-typedef-anon-force-multi: when the sep-Star carries
					// `@:fmt(forceMultiInTypedef)` (currently only
					// `HxType.Anon.fields`), thread the flag into
					// `triviaSepStarExpr` so its no-trivia branch emits a
					// runtime `opt._inTypedefBody ? WrapMode.OnePerLine :
					// null` as `WrapList.emit`'s 15th `forceMode` arg.
					// Bypasses the cascade only when the typedef-RHS
					// context is active — non-typedef anon consumers
					// (var-type-hint, fn-return-type) stay cascade-driven.
					final forceMultiTypedef:Bool = starNode.fmtHasFlag('forceMultiInTypedef');
					final bodyAware:Bool = starNode.fmtHasFlag('bodyAwareCompactIndent');
					// ω-group-rest-probe slice 2: struct-Star path reader for
					// `@:fmt(groupRestProbe)`. Mirrors the lowerStruct plain-
					// path read (added at the lowerStruct dispatch site).
					// Trivia-path dual-dispatch closure per
					// [[feedback-wraprules-dispatch-dual-path]].
					final groupRestProbe:Bool = starNode.fmtHasFlag('groupRestProbe');
					// ω-cascade-emits-comments: struct-Star path reader for
					// `@:fmt(ignoreSourceNewlinesForWrap)`. Intrinsic
					// per-construct opt-in to fork's `Ignore` semantic —
					// drops `Trivial<T>.newlineBefore` signal, routes
					// per-element block-trailing + leading comments
					// through the cascade no-trivia branch. Currently
					// `HxFnDecl.params` (Slice 4c).
					final ignoreSourceNewlines:Bool = starNode.fmtHasFlag('ignoreSourceNewlinesForWrap');
					// ω-bropen-keep-sep: read `@:fmt(keepCurlyBlanks)` on the
					// struct-Star path. Sister to the enum-Alt path's read.
					final keepCurlyBlanksStar:Bool = starNode.fmtHasFlag('keepCurlyBlanks');
						// ω-array-reflow: struct-Star path reader for
						// `@:fmt(reflowSourceMultiline)`. Sister to the enum-Alt
						// read; threads into `triviaSepStarExpr`'s `_smlKeep`
						// gate. No struct-Star consumer opts in yet (first
						// consumer `HxExpr.ArrayExpr` is enum-Alt) — present for
						// dual-dispatch symmetry.
						final reflowSourceMultilineStar:Bool = starNode.fmtHasFlag('reflowSourceMultiline');
						// ω-arraymatrix-wrap: struct-Star path reader for
						// `@:fmt(arrayMatrixWrap)`. Sister to the enum-Alt read;
						// no struct-Star consumer opts in yet (first consumer
						// `HxExpr.ArrayExpr` is enum-Alt) — present for dual-
						// dispatch symmetry. `bracketKindPad` is not read on this
						// path (passed false) so matrix slots in after it.
						final matrixWrapStar:Bool = starNode.fmtHasFlag('arrayMatrixWrap');
					parts.push(triviaSepStarExpr(
						fieldAccess, trailBBAccess, trailLCAccess, trailCloseAccess, trailOpenAccess, elemFn,
						openText ?? '', closeText, sepText, wrapRulesField,
						leftCurlyOwnedBySep ? knobLeftCurly : null,
						knobRightCurly,
						trailPresentAccess, trailingCommaField,
						null, null, false, forceMultiTypedef, bodyAware, groupRestProbe, ignoreSourceNewlines,
						keepCurlyBlanksStar, reflowSourceMultilineStar, false, matrixWrapStar,
						// ω-keep-fnsig-newline: close-newline accessor for the
						// struct-Star keep close placement (HxFnDecl.params).
						trailNLAccess
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
				final emptyCurlyBreak:Bool = starNode.fmtHasFlag('emptyCurlyBreak');
				// ω-blockempty: call-form `@:fmt(emptyCurlyBreak('<knob>'))`
				// names a per-construct EmptyCurly opt field. The bare form
				// returns null and falls back to `_inAnonFnBody` dispatch
				// inside `triviaBlockStarExpr`.
				final emptyCurlyKnobArgs:Null<Array<String>> = starNode.fmtReadStringArgs('emptyCurlyBreak');
				final emptyCurlyKnob:Null<String> = (emptyCurlyKnobArgs != null && emptyCurlyKnobArgs.length >= 1)
					? emptyCurlyKnobArgs[0]
					: null;
				final beginEndType:Bool = starNode.fmtHasFlag('beginEndType');
				final keepCurlyBlanks:Bool = starNode.fmtHasFlag('keepCurlyBlanks');
				final lineCommentTrailBlank:Bool = starNode.fmtHasFlag('blankBeforeOrphanLineCommentTrail');
				final blankBeforeFinalDocInLeading:Bool = starNode.fmtHasFlag('blankBeforeFinalDocCommentInLeading');
				final interMemberArgs:Null<Array<String>> = starNode.fmtReadStringArgs('interMemberBlankLines');
				final interMemberInfo:Null<InterMemberClassifyInfo> = interMemberArgs == null
					? null
					: buildInterMemberClassifyInfo(elemRefName, interMemberArgs);
				// `fmtHasFlag` accepts both bare-identifier (`staticVarSubdivision`)
				// and call form (`staticVarSubdivision('modifiers', 'Static',
				// 'afterStaticVars')`) — `fmtReadStringArgs` is null in the
				// bare form and only carries args when the call form is used.
				final staticVarSubdiv:Bool = starNode.fmtHasFlag('staticVarSubdivision');
				final staticVarSubdivArgs:Null<Array<String>> = staticVarSubdiv
					? starNode.fmtReadStringArgs('staticVarSubdivision')
					: null;
				final staticVarSubdivInfo:Null<StaticVarSubdivisionInfo> = (staticVarSubdiv && interMemberInfo != null)
					? buildStaticVarSubdivisionInfo(elemRefName, staticVarSubdivArgs ?? [])
					: null;
				final betweenMultilineCommentsBlanks:Bool = starNode.fmtHasFlag('betweenMultilineCommentsBlanks');
				final uniformBetweenArgs:Null<Array<String>> = starNode.fmtReadStringArgs('uniformBetween');
				if (uniformBetweenArgs != null && uniformBetweenArgs.length != 1)
					Context.fatalError(
						'WriterLowering: @:fmt(uniformBetween) expects exactly 1 string arg (optField), got ${uniformBetweenArgs.length}',
						Context.currentPos()
					);
				final uniformBetweenOptField:Null<String> = uniformBetweenArgs != null
					? uniformBetweenArgs[0]
					: null;
				final anonFnClear:Bool = starNode.fmtHasFlag('leftCurlyAnonFnOverride');
				// ω-blockright-curly: call-form `@:fmt(rightCurly('<knob>'))`
				// on a Seq-struct Star names a per-construct
				// RightCurlyPlacement opt field. Sister to `emptyCurlyKnob`
				// — when null, dispatch falls back to unconditional
				// `_dhl()` before close inside `triviaBlockStarExpr`.
				final rightCurlyKnobArgs:Null<Array<String>> = starNode.fmtReadStringArgs('rightCurly');
				final rightCurlyKnob:Null<String> = (rightCurlyKnobArgs != null && rightCurlyKnobArgs.length >= 1)
					? rightCurlyKnobArgs[0]
					: null;
				// ω-anonfunction-right-curly: call-form
				// `@:fmt(rightCurlyAnonFnOverride('<knob>'))` on a Seq-struct
				// Star names a RightCurlyPlacement opt field read only when
				// `_inAnonFnBody=true`. Used by `HxFnBlock.stmts` to route
				// anon-fn body closes through `opt.anonFunctionRightCurly`
				// while keeping `HxFnDecl.body` / `HxUntypedFnBody.block`
				// (same `HxFnBlock` Star, `_inAnonFnBody=false`) on the
				// pre-slice `_dhl()` path.
				final rightCurlyAnonFnArgs:Null<Array<String>> = starNode.fmtReadStringArgs('rightCurlyAnonFnOverride');
				final rightCurlyAnonFnKnob:Null<String> = (rightCurlyAnonFnArgs != null && rightCurlyAnonFnArgs.length >= 1)
					? rightCurlyAnonFnArgs[0]
					: null;
				parts.push(triviaBlockStarExpr(
					fieldAccess, trailBBAccess, trailLCAccess, trailCloseAccess, trailOpenAccess, elemFn,
					openText ?? '', closeText, false, afterDocComments, keepBetweenFields, beforeDocComments,
					interMemberInfo, indentCaseLabelsGate, emptyCurlyBreak, beginEndType, keepCurlyBlanks,
					lineCommentTrailBlank, blankBeforeFinalDocInLeading, staticVarSubdivInfo,
					betweenMultilineCommentsBlanks, uniformBetweenOptField, anonFnClear, emptyCurlyKnob,
					rightCurlyKnob, rightCurlyAnonFnKnob,
					// ω-blockended-trivia (Session 3): thread sepText +
					// blockEnded flag when the Star opted into
					// `@:sep('text', tailRelax, blockEnded)`. Null sepText
					// preserves pre-slice byte-identical output for every
					// existing block-mode caller.
					// ω-condcomp-stray-semi (Stage A): also thread the
					// blockEnded predicate name + schema path so the
					// between-element / trailing sep consults `stmtNoSemi`
					// on the prior element's AST (suppresses the stray `;`
					// after a `#if … #end` stmt).
					blockEndedFlag ? sepText : null, blockEndedFlag,
					blockEndedFlag ? (starNode.annotations.get('lit.sepBlockEndedPredicate') : Null<String>) : null,
					blockEndedFlag ? formatInfo.schemaTypePath : null
				));
			} else if (isLastField) {
				if (openText != null) parts.push(macro _dt($v{openText}));
				final cascadeInfos:CascadeInfos = readCascadeInfosFromStar(starNode, elemRefName);
				final lineCommentTrailBlank:Bool = starNode.fmtHasFlag('blankBeforeOrphanLineCommentTrail');
				final lineCommentLedAddBlank:Bool = starNode.fmtHasFlag('blankBeforeLineCommentLed');
				final afterFileHeaderCommentBlanks:Bool = starNode.fmtHasFlag('afterFileHeaderCommentBlanks');
				final betweenMultilineCommentsBlanks:Bool = starNode.fmtHasFlag('betweenMultilineCommentsBlanks');
				parts.push(triviaEofStarExpr(
					fieldAccess, trailBBAccess, trailLCAccess, elemFn,
					cascadeInfos.afterCtorInfos, cascadeInfos.beforeCtorInfos,
					cascadeInfos.betweenCtorInfos, cascadeInfos.transitionAcrossInfos,
					cascadeInfos.headCtorInfos, lineCommentTrailBlank, lineCommentLedAddBlank,
					afterFileHeaderCommentBlanks, betweenMultilineCommentsBlanks,
					cascadeInfos.betweenSameCtorIfNotInfos
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

		// Block-ended exemption (Session 2 pilot → Session 8 layout fix +
		// writer-side predicate consultation). When the Star carries
		// `@:sep(<text>, tailRelax, blockEnded[('<predicate>')])`,
		// between-element sep is suppressed when EITHER:
		//   (a) the prior element's rendered Doc ends with `}` OR `;`
		//       (per-stmt `@:trail/@:trailOpt(';')` baked terminator —
		//       `DocMeasure.endsWithStmtTerminator` one-walk check), OR
		//   (b) the format-instance predicate returns true on the prior
		//       element's AST (Session 7 option b2 — AST-shape adapter,
		//       e.g. `HxStatement.Conditional(#if…#end)` ends `#end`
		//       byte-wise so (a) misses, but the predicate accepts the
		//       AST shape).
		// Mirrors the parser-side blockEnded branch in
		// `Lowering.emitStarFieldSteps`: byte-check `}`∪`;` (or-extended
		// `b == '}'.code || b == ';'.code || $predicateCall`). Predicate
		// is omitted iff `lit.sepBlockEndedPredicate` is absent — the
		// `false` fallback keeps the byte-check fast path untouched.
		//
		// Layout mirrors `blockBody` (WriterCodegen.hx:730-758): empty →
		// flat `open+close`; non-empty → `_dc([_dt(open), _dn(cols,
		// _dc([_dhl, item, [sep?]]*)), _dhl, _dt(close)])`. This replaces
		// the prior flat `_dc([open, item, _dt(' '), item, …, close])`
		// that had no multiline primitive — Session 7's HxFnBlock.stmts
		// smoke test regressed 35 unit tests because function bodies
		// collapsed to one line; the blockBody-shape layout restores
		// parity with the non-`@:sep` path at L3981.
		final blockEnded:Bool = starNode.annotations.get('lit.sepBlockEnded') == true;
		if (closeText != null && sepText != null && blockEnded) {
			final predicateName:Null<String> = starNode.annotations.get('lit.sepBlockEndedPredicate');
			final predicateCheck:Expr = if (predicateName != null) {
				final fmtParts:Array<String> = formatInfo.schemaTypePath.split('.');
				{
					expr: ECall(
						{expr: EField(macro $p{fmtParts}.instance, predicateName), pos: Context.currentPos()},
						[macro _arr[_si]]
					),
					pos: Context.currentPos(),
				};
			} else macro false;
			// Phase G2 (Session 10) — trail-emit-on-last for plain mode.
			// Mirror of between-element gate below, queried on the last
			// element. Required when per-stmt `@:trailOpt(';')` is removed
			// from a ctor (Session 10 migration) — the element's Doc no
			// longer bakes `;`, so the Star owns trailing emit. Mirrors
			// trivia mode's `blockTrailSepEmitExpr` (L7002-7009) minus the
			// source-fidelity `sepAfter` gate (plain mode has no per-pair
			// state — always emit when non-block-ended).
			final lastPredicateCheck:Expr = if (predicateName != null) {
				final fmtParts:Array<String> = formatInfo.schemaTypePath.split('.');
				{
					expr: ECall(
						{expr: EField(macro $p{fmtParts}.instance, predicateName), pos: Context.currentPos()},
						[macro _arr[_arr.length - 1]]
					),
					pos: Context.currentPos(),
				};
			} else macro false;
			parts.push(macro {
				final _arr = $fieldAccess;
				if (_arr.length == 0) {
					_dc([_dt($v{openText ?? ''}), _dt($v{closeText})]);
				} else {
					final _items:Array<anyparse.core.Doc> = [];
					var _si:Int = 0;
					var _lastElemDoc:Null<anyparse.core.Doc> = null;
					while (_si < _arr.length) {
						final _elemDoc:anyparse.core.Doc = $elemCall;
						_items.push(_dhl());
						_items.push(_elemDoc);
						if (_si < _arr.length - 1
								&& !anyparse.core.DocMeasure.endsWithSemi(_elemDoc)
								&& !($predicateCheck)) {
							_items.push(_dt($v{sepText}));
						}
						_lastElemDoc = _elemDoc;
						_si++;
					}
					if (_lastElemDoc != null
							&& !anyparse.core.DocMeasure.endsWithSemi(_lastElemDoc)
							&& !($lastPredicateCheck)) {
						_items.push(_dt($v{sepText}));
					}
					final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
					_dc([_dt($v{openText ?? ''}), _dn(_cols, _dc(_items)), _dhl(), _dt($v{closeText})]);
				}
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
			// ω-functionsignature-body-aware-indent: `@:fmt(bodyAwareCompactIndent)`
			// on the Star tells the wrapRules dispatch to thread
			// `opt._fnSigBodyEmpty` into `WrapList.emit`'s `compactContinuation`
			// param. The flag is set by the sibling struct-level meta
			// `@:fmt(propagateFnBodyEmpty(<bodyField>))` and consumed only by
			// the cascade engine. Fields without this meta pass `false` so
			// only the opt-in site reacts; reads `opt._fnSigBodyEmpty` at
			// runtime so non-HxFnDecl wraps inside descendant code (default
			// values, body call args, …) see `false` (no propagation past
			// the opt-fanout span — see `lowerStruct`'s save/restore).
			final bodyAware:Bool = starNode.fmtHasFlag('bodyAwareCompactIndent');
			// ω-group-rest-probe slice 2: `@:fmt(groupRestProbe)` opt-in for
			// Star fields whose outer Group should bias toward MBreak when
			// significant same-line content trails (typedef LHS typeParams,
			// followed by ` = Rhs<…>;`). Mirrors fork's `lengthAfter` rule
			// at Group layer. Plain-path 17th param to `WrapList.emit`;
			// trivia path mirror lives in `triviaSepStarExpr` (dual-dispatch
			// per [[feedback-wraprules-dispatch-dual-path]]).
			final groupRestProbe:Bool = starNode.fmtHasFlag('groupRestProbe');
			final listCall:Expr = if (wrapRulesField != null) {
				final rulesExpr:Expr = optFieldAccess(wrapRulesField);
				final compactContExpr:Expr = bodyAware ? (macro opt._fnSigBodyEmpty) : (macro false);
				macro anyparse.format.wrap.WrapList.emit(
					$v{openText ?? ''}, $v{closeText}, $v{sepText}, _docs, opt,
					$openInsideExpr, $closeInsideExpr, $keepInnerExpr, $rulesExpr, $tcExpr,
					_de(), _de(), false, null, null, $compactContExpr, $v{groupRestProbe}
				);
			} else if (useFill) {
				macro fillList($v{openText ?? ''}, $v{closeText}, $v{sepText}, _docs, opt, $tcExpr, $openInsideExpr, $closeInsideExpr, $keepInnerExpr, $v{fillDouble});
			} else {
				macro sepList($v{openText ?? ''}, $v{closeText}, $v{sepText}, _docs, opt, $tcExpr, $openInsideExpr, $closeInsideExpr, $keepInnerExpr, false);
			};
			// ω-casepattern-keep: a FIRST-field bare Star that opts into
			// `@:fmt(beforeNewlineSlotFirst)` (only `HxCaseBranch.patterns`)
			// reads the synth `<field>BeforeNewline:Bool` slot. When the
			// source broke right after the parent `case` keyword AND
			// `opt.leftCurly == Next` (the `lineEnds.leftCurly: before`/`both`
			// configs where fork puts a line-end before the pattern's `{`),
			// wrap the pattern list Doc in `_dn(_cols, _dc([_dhl, …]))` so
			// `case\n\t{pattern}` round-trips verbatim. The body field follows
			// on the `:`-glued line, governed by its own `caseBody`/
			// `expressionCase` keep. Gated on trivia + bearing + the opt-in
			// flag so every non-bearing / plain-mode emit (no slot) keeps the
			// unconditional glued list; gated on `leftCurly == Next` at
			// runtime so `Same` configs and the absent-newline source shape
			// (`case {pattern}`) stay byte-identical. The parent
			// `HxSwitchCase.CaseBranch` ctor carries `@:fmt(deferKwSpace)`, so
			// the `case ` trailing space drops cleanly before the hardline.
			// Mirrors the bare-Ref first-field channel (`HxTryCatchStmt.body`
			// / `bodyPolicyWrap` Next branch `_dn(_cols, [_dhl, body])`).
			final firstStarNlKeep:Bool = isFirstField
				&& ctx.trivia
				&& isTriviaBearing(typePath)
				&& starNode.fmtHasFlag('beforeNewlineSlotFirst');
			final patternListExpr:Expr = if (firstStarNlKeep) {
				final nlFieldName:String = starNode.annotations.get('base.fieldName');
				final beforeNlAccess:Expr = {
					expr: EField(macro value, nlFieldName + TriviaTypeSynth.BEFORE_NEWLINE_SUFFIX),
					pos: Context.currentPos(),
				};
				macro {
					final _patListDoc:anyparse.core.Doc = $listCall;
					final _patBeforeNl:Bool = $beforeNlAccess
						&& opt.leftCurly == anyparse.format.BracePlacement.Next;
					final _patCols:Int = opt.indentChar == anyparse.format.IndentChar.Space
						? opt.indentSize
						: opt.tabWidth;
					_patBeforeNl ? _dn(_patCols, _dc([_dhl(), _patListDoc])) : _patListDoc;
				};
			} else macro $listCall;
			parts.push(macro {
				final _arr = $fieldAccess;
				final _docs:Array<anyparse.core.Doc> = [];
				var _si:Int = 0;
				while (_si < _arr.length) {
					_docs.push($elemCall);
					_si++;
				}
				$patternListExpr;
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
				final optFlag:Expr = optFieldAccess(sameLineName);
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
					? (bareShapeAware
						? collectBlockShapeEquivalentPatterns(prevBareRefBody.typePath)
						: collectBlockCtorPatterns(prevBareRefBody.typePath))
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
					final blockKeepsInlineBranch:Expr = blockBodyKeepsInlineBranch(starNode);
					final firstBlockBranch:Expr = blockShapeAware ? blockKeepsInlineBranch : sepExpr;
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
						final subBlockBranch:Expr = blockShapeAware ? blockKeepsInlineBranch : sepExpr;
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
				// ω-abstract-clauses-linewrap: when a bare-Star with padLeading
				// (and/or padTrailing) opts in via `@:fmt(lineLengthAwareSeps)`,
				// replace each hard padding/inter-element space with an
				// `IfLineExceeds(opt.lineWidth, _dhl(), _dt(' '))` probe and
				// wrap the body in `Nest(_cols, ...)` so break-mode hardlines
				// indent +1 from the enclosing decl. Mirrors fork's
				// `wrapAfter` + `CodeLine.applyWrapping` mechanism for
				// `abstract <T>(...) [from X]*` clauses (MarkWhitespace.hx:79
				// + codedata/CodeLine.hx:47). Single-clause and short-multi-
				// clause cases decide correctly without a multi-pass marker
				// because `IfLineExceeds`'s rest-of-stack walker sees the
				// trailing same-line content (members `{}` + close-trailing
				// comment). First consumer is `HxAbstractDecl.clauses`.
				final lineLengthAwareSeps:Bool = starNode.fmtHasFlag('lineLengthAwareSeps');
				// ω-condcomp-body-leading-sep (Slice 18f): read the runtime
				// `<field>SepBefore:Bool` slot synthesised by
				// `TriviaTypeSynth.isSepBeforeOptStarField`. When true at
				// write time, prepend the sep literal to the leading pad
				// (`_dt(', ')` in place of `_dt(' ')`). Requires `padLeading`
				// — the leading pad is the only Doc slot in this branch that
				// fires adjacent to the enclosing kw (`#if cond`). Combining
				// with `lineLengthAwareSeps` is rejected at macro time (no
				// current consumer; the line-wrap probe would have to
				// swallow the comma into the breakable probe, which the
				// fork semantics for `#if cond, body` does NOT do).
				//
				// The slot lives on the trivia-paired typedef only (sister
				// gate in `Lowering.lowerStruct` skips the plain-mode
				// struct literal). Plain writer keeps the pre-slice
				// `_dt(' ')` pad — no slot to read, byte-roundtrip parity
				// with the no-slot pre-Slice-18f shape preserved.
				final sepBeforeOpt:Bool = starNode.fmtHasFlag('sepBeforeOpt');
				if (sepBeforeOpt && !padLeading)
					Context.fatalError('WriterLowering: @:fmt(sepBeforeOpt) requires @:fmt(padLeading)', Context.currentPos());
				if (sepBeforeOpt && lineLengthAwareSeps)
					Context.fatalError('WriterLowering: @:fmt(sepBeforeOpt) is not compatible with @:fmt(lineLengthAwareSeps)', Context.currentPos());
				final sepBeforeOptActive:Bool = sepBeforeOpt && ctx.trivia;
				// ω-condcomp-body-softfill (Slice 18h): plain-mode
				// `@:sep + @:tryparse` Star with `@:fmt(padLeading[, padTrailing])`
				// can opt into Wadler `Fill(items, sep)` inter-element layout via
				// `@:fmt(softFill)`. Items pack inline up to the current line
				// budget and break the sep before any overflow item at the
				// surrounding Nest's indent. Closes `whitespace/issue_582…`:
				// `#if air, p1, p2, …, pN #end` inside an outer function-
				// signature Star whose source wraps the body across multiple
				// lines. The flat sep is `Concat([Text(sepText), Line(' ')])` —
				// flat=`,` + ` `, break=`,` + newline+indent. The current
				// outer-Group Nest from `wrapRules('functionSignatureWrap')`
				// supplies the break-mode indent (matches `#if`'s column in
				// every fork-corpus shape observed for cond-comp params).
				// Mutually exclusive with `lineLengthAwareSeps` — the latter
				// owns its own break primitive and the two would double-decide
				// the wrap.
				final softFill:Bool = starNode.fmtHasFlag('softFill');
				if (softFill && lineLengthAwareSeps)
					Context.fatalError('WriterLowering: @:fmt(softFill) is not compatible with @:fmt(lineLengthAwareSeps)', Context.currentPos());
				if (softFill && !(padLeading || padTrailing))
					Context.fatalError('WriterLowering: @:fmt(softFill) requires @:fmt(padLeading) or @:fmt(padTrailing)', Context.currentPos());
				if (padLeading || padTrailing) {
					if (lineLengthAwareSeps) {
						final leadingPush:Expr = padLeading
							? macro _docs.push(_dile(opt.lineWidth, _dhl(), _dt(' ')))
							: macro {};
						final trailingPush:Expr = padTrailing
							? macro _docs.push(_dile(opt.lineWidth, _dhl(), _dt(' ')))
							: macro {};
						parts.push(macro {
							final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
							final _arr = $fieldAccess;
							if (_arr.length == 0) _de()
							else {
								final _docs:Array<anyparse.core.Doc> = [];
								$leadingPush;
								var _si:Int = 0;
								while (_si < _arr.length) {
									_docs.push($elemCall);
									if (_si < _arr.length - 1)
										_docs.push(_dile(opt.lineWidth, _dhl(), _dt(' ')));
									_si++;
								}
								$trailingPush;
								_dn(_cols, _dc(_docs));
							}
						});
					} else {
						final leadingPush:Expr = if (sepBeforeOptActive) {
							final fieldName:String = starNode.annotations.get('base.fieldName');
							final sepBeforeAccess:Expr = {
								expr: EField(macro value, fieldName + TriviaTypeSynth.SEP_BEFORE_SUFFIX),
								pos: Context.currentPos(),
							};
							final sepText:Null<String> = starNode.annotations.get('lit.sepText');
							final sepLeadText:String = (sepText ?? ',') + ' ';
							macro _docs.push($sepBeforeAccess ? _dt($v{sepLeadText}) : _dt(' '));
						} else if (padLeading) macro _docs.push(_dt(' '));
						else macro {};
						final trailingPush:Expr = padTrailing ? macro _docs.push(_dt(' ')) : macro {};
						// ω-condcomp-body-inter-sep (Slice 18f): the inter-element
						// separator for this branch was historically `_dt(' ')` —
						// designed for sep-less Stars where elements pack with one
						// space (e.g. modifier runs). Sep-bearing Stars (e.g.
						// `HxConditionalParam.body` / `HxConditionalObjectField.body`
						// with `@:sep(',')`) emit their actual sep + space so multi-
						// element bodies round-trip the source comma. Falls back to
						// `' '` when sepText is absent — sep-less Stars stay byte-
						// identical to pre-slice behaviour.
						final sepTextForInter:Null<String> = starNode.annotations.get('lit.sepText');
						final interSepText:String = sepTextForInter != null ? sepTextForInter + ' ' : ' ';
						if (softFill) {
							// ω-condcomp-body-softfill: route inter-element sep
							// through `Fill(items, Concat([Text(sep), Line(' ')]))`.
							// Flat mode renders the sep identically to the
							// pre-softFill `Text(interSepText)` path (`, ` for
							// sep-bearing Stars, ` ` for sep-less). Break mode
							// emits `sep` + newline+indent before each overflow
							// item — Fill picks per-item flat/break against the
							// current Renderer budget.
							final interSepLit:String = sepTextForInter ?? '';
							parts.push(macro {
								final _arr = $fieldAccess;
								if (_arr.length == 0) _de()
								else {
									final _docs:Array<anyparse.core.Doc> = [];
									$leadingPush;
									final _items:Array<anyparse.core.Doc> = [];
									var _si:Int = 0;
									while (_si < _arr.length) {
										_items.push($elemCall);
										_si++;
									}
									_docs.push(_dfill(_items, _dc([_dt($v{interSepLit}), _dl()])));
									$trailingPush;
									_dc(_docs);
								}
							});
						} else parts.push(macro {
							final _arr = $fieldAccess;
							if (_arr.length == 0) _de()
							else {
								final _docs:Array<anyparse.core.Doc> = [];
								$leadingPush;
								var _si:Int = 0;
								while (_si < _arr.length) {
									_docs.push($elemCall);
									if (_si < _arr.length - 1) _docs.push(_dt($v{interSepText}));
									_si++;
								}
								$trailingPush;
								_dc(_docs);
							}
						});
					}
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
			if (unescapeMode == 'raw' || unescapeMode == 'singleQuoteRaw') {
				// @:unescape("raw"):           escape without quote wrap,
				//                              using the format's `escapeChar`
				//                              (double-quote-aware table).
				// @:unescape("singleQuoteRaw"): same, but uses
				//                              `escapeSingleQuoteChar` —
				//                              the format's single-quote-
				//                              aware escape table (escapes
				//                              `'`, `$`, `\\` but leaves
				//                              `"` bare). Used by
				//                              `HxStringLitSegment` so that
				//                              literal `"` inside Haxe
				//                              `'...'` strings round-trips
				//                              bare instead of being
				//                              over-escaped to `\\"`.
				final fmtParts:Array<String> = formatInfo.schemaTypePath.split('.');
				final escapeCall:Expr = unescapeMode == 'singleQuoteRaw'
					? macro $p{fmtParts}.instance.escapeSingleQuoteChar(_c)
					: macro $p{fmtParts}.instance.escapeChar(_c);
				return macro {
					final _s:String = (cast value : String);
					final _buf:StringBuf = new StringBuf();
					var _ci:Int = 0;
					while (_ci < _s.length) {
						final _c:Null<Int> = _s.charCodeAt(_ci);
						if (_c != null) _buf.add($e{escapeCall});
						_ci++;
					}
					return _dt(_buf.toString());
				};
			}
			// @:unescape (bare): wrap in "..." and escape
			return macro return _dt(escapeString(value));
		}

		if (raw) {
			// ω-numeric-normalize-suffix (Slice 47): `@:writeNormalize('<id>')`
			// on a `@:rawString` terminal wraps the emit through a built-in
			// normalisation transform before `_dt`. Currently one variant —
			// `'stripSuffixUnderscore'` — drops the optional underscore that
			// precedes a Haxe 5 typed numeric suffix (`_i32` → `i32`,
			// `_f64` → `f64`), matching haxe-formatter's canonicalisation
			// convention: source-form `12_0_i32` round-trips as `12_0i32`,
			// `1_2.3_4_f64` as `1_2.3_4f64`. Source-fidelity loss is the
			// trade — haxe-formatter normalises here and no fixture preserves
			// the underscore-before-suffix form on output. Generic enough
			// for future numeric-shape canonicalisations; the registry is
			// the switch below, keep it small.
			final normalize:Null<String> = node.readMetaString(':writeNormalize');
			if (normalize == 'stripSuffixUnderscore') {
				return macro {
					var _s:String = (cast value : String);
					final _re = ~/_([iuf](?:8|16|32|64))$/;
					if (_re.match(_s)) _s = _s.substr(0, _re.matchedPos().pos) + _re.matched(1);
					return _dt(_s);
				};
			}
			return macro return _dt(value);
		}

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
	private function sameLineSeparator(
		child:ShapeNode, prevBody:Null<PrevBodyInfo>, typePath:String, prevPadTrailing:Null<Expr> = null
	):Expr {
		// ω-pad-trailing-ref: every return path wraps via the static
		// `withPadTrailingDrop` helper — drops the sep at runtime when
		// the immediately preceding field's `@:fmt(padTrailing)` fired.
		// No-op when `prevPadTrailing == null`, so existing callers (no
		// upstream padTrailing) stay byte-identical.
		final flagName:Null<String> = child.fmtReadString('sameLine');
		// ω-cond-comp-expr-multiline (sub-slice 6): default sep is
		// `_dossh()` (Doc.OptSpaceSkipAfterHardline) — emits `' '` to
		// keep tokens separated when the previous emit ended on the same
		// line, drops to nothing when the previous emit ended with a
		// hardline. Closes the spurious-space-after-hardline window
		// without conflating with `prevPadTrailing` (the latter is a
		// macro-time signal about the prior FIELD's pad-emission, while
		// this drop reads the renderer's runtime `lastEmit` state — they
		// fire under different conditions and stack cleanly:
		// `withPadTrailingDrop` collapses to `_de()` when prev's pad
		// fired, otherwise `_dossh()` handles the residual hardline-
		// trailing case from a non-pad-bearing prev field's body, e.g.
		// `HxConditionalStmt.body → '#elseif'-clause → '#else'` where
		// elseifs is non-empty so body's pad is masked but elseifs's
		// last body element still ends with a hardline).
		if (flagName == null) return withPadTrailingDrop(prevPadTrailing, macro _dossh());
		final optFlag:Expr = optFieldAccess(flagName);
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
		if (prevBody == null || !child.fmtHasFlag('shapeAware')) return withPadTrailingDrop(prevPadTrailing, flagBased);
		final blockPatterns:Array<Expr> = collectBlockCtorPatterns(prevBody.typePath);
		if (blockPatterns.length == 0) return withPadTrailingDrop(prevPadTrailing, flagBased);
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
		// ω-issue-257-else-in-return-switch: dual-flag bodyPolicy on the
		// child propagates here too — the inline-shape probe must
		// dispatch on `opt._inExprPosition` so an expr-position parent
		// (e.g. inner `if/else` in the case body of a return-switch
		// when `expressionIf=Same`) reads the expr-side knob and
		// suppresses the shape-aware else-break consistently with the
		// dispatched body layout in `bodyPolicyWrap`. Single-flag
		// callers (no second arg) keep the byte-identical pre-slice
		// access.
		final childBodyPolicy:{stmt:Null<String>, expr:Null<String>} = readBodyPolicyDual(child);
		final childBodyPolicyFlag:Null<String> = childBodyPolicy.stmt;
		if (childBodyPolicyFlag == null) return withPadTrailingDrop(prevPadTrailing, shapeAwareSwitch);
		final stmtBpAccess:Expr = optFieldAccess(childBodyPolicyFlag);
		final bpAccess:Expr = if (childBodyPolicy.expr == null) stmtBpAccess
		else {
			final exprBpAccess:Expr = optFieldAccess(childBodyPolicy.expr);
			macro (opt._inExprPosition ? $exprBpAccess : $stmtBpAccess);
		};
		final samePat:Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BodyPolicy', 'Same']);
		final keepPat:Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BodyPolicy', 'Keep']);
		final isInlineExpr:Expr = if (hasKeepSlot) {
			final slotAccess:Expr = {
				expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_KW_NEWLINE_SUFFIX),
				pos: Context.currentPos(),
			};
			macro ($bpAccess == $samePat || ($bpAccess == $keepPat && !$slotAccess));
		} else macro $bpAccess == $samePat;
		// ω-ifelse-semicolon-next-line: when the body is forced inline
		// (`isInlineExpr` — e.g. `sameLine.ifBody:same`) the pre-slice
		// shape obeyed `flagBased` (`sameLineElse`), gluing `else` after a
		// `;`-terminated non-block then-body. Mirror fork's
		// `MarkSameLine.markElse` Semicolon branch: when the rendered
		// then-body ends with a `;` (the token immediately before `else`)
		// AND `opt.ifElseSemicolonNextLine` is set, break `else` onto its
		// own line instead. The discriminator is the then-body's RENDERED
		// Doc, re-derived by re-rendering the then-body value through its
		// own write fn and inspecting the right-spine tail via
		// `DocMeasure.endsWithSemi` (a bounded right-spine walk — NOT a
		// layout probe). `endsWithSemi` treats ONLY `;` as a terminator,
		// not `}`, so block then-bodies (`if (c) {…} else …`) keep gluing
		// and `;`-omitting non-blocks (`if (c) foo else …`) keep gluing —
		// matching the fixtures' rows. Re-rendering is pure (no state
		// mutation, INVARIANT #1) and produces the same Doc as the actual
		// emit, so the tail byte is authoritative.
		//
		// Gated on the opt-in `@:fmt(semicolonNextLineElse)` flag, present
		// ONLY on `HxIfStmt.elseBody`. The fork's `ifElseSemicolonNextLine`
		// is a statement-`if` rule, so two more gates pin it tightly:
		//   - macro-time `ctx.trivia`: source-`;`-presence is only knowable
		//     in the trivia pipeline (the corpus harness). The plain writer
		//     canonicalises `;`, so "did the source have `;`" is meaningless
		//     there — plain mode stays byte-identical (falls to `flagBased`).
		//   - runtime `!opt._inExprPosition`: value-position `if`
		//     (`return switch … case A: if (c) a(); else b()`, or
		//     `final x = if (a) b; else c`) is governed by
		//     `sameLineExpressionElse`, not the statement rule — keep `else`
		//     glued there. Mirrors fork's `MarkSameLine.markElse` (statement
		//     `if` only).
		final inlineSep:Expr = if (ctx.trivia && child.fmtHasFlag('semicolonNextLineElse')) {
			final prevWriteFn:String = writeFnFor(prevBody.typePath);
			final prevAccess:Expr = prevBody.access;
			final prevDoc:Expr = {expr: ECall(macro $i{prevWriteFn}, [prevAccess, macro opt]), pos: Context.currentPos()};
			macro (!opt._inExprPosition && opt.ifElseSemicolonNextLine && anyparse.core.DocMeasure.endsWithSemi($prevDoc) ? _dhl() : $flagBased);
		} else flagBased;
		return withPadTrailingDrop(prevPadTrailing, macro $isInlineExpr ? $inlineSep : $shapeAwareSwitch);
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
	 * ω-block-body-alt-samelinepolicy: block-body branch of the catches-
	 * Star sep override. Bare `@:fmt(blockBodyKeepsInline)` returns
	 * `_dt(' ')` — block bodies stay inline regardless of policy
	 * (existing behavior). The knob form
	 * `@:fmt(blockBodyKeepsInline('<sameLineFlag>'))` redirects the
	 * block-body branch through `sameLinePolicySwitch` on the named
	 * runtime option, so the catch separator after a block body follows
	 * a different SameLine policy than the bare-body branch's
	 * `sameLine('<expressionFlag>')`. Consumed by
	 * `HxTryCatchExpr.catches` to match haxe-formatter, where a
	 * block-bodied expression-position `try` honours `sameLine.tryCatch`
	 * (`} catch` vs `}\ncatch`) while a bare-body expression-position
	 * `try` keeps reading `sameLine.expressionTry`.
	 */
	private static function blockBodyKeepsInlineBranch(starNode:ShapeNode):Expr {
		final altPolicy:Null<String> = starNode.fmtReadString('blockBodyKeepsInline');
		return altPolicy == null
			? macro _dt(' ')
			: sameLinePolicySwitch(optFieldAccess(altPolicy), macro _dt(' '));
	}

	/**
	 * ω-pad-trailing-ref — fold a field's runtime pad-fire condition
	 * (`fires`) and runtime transparency condition (`transparent`)
	 * into the running `prevPadTrailing` tracker.
	 *
	 * Truth table per (fires, transparent, prev) presence:
	 *
	 *   fires=null, transparent=null      → return null
	 *     (visible non-pad emission resets the chain)
	 *   fires=null, transparent=expr      → return `transparent && prev`
	 *     (this field is sometimes-empty; when empty, propagate prev)
	 *   fires=expr, transparent=null      → return `fires`
	 *     (mandatory-Ref pad — always fires when present)
	 *   fires=expr, transparent=expr      → return `fires || (transparent && prev)`
	 *     (optional/Star with pad — fires when present, propagates when transparent)
	 *
	 * The `transparent` runtime expr must be the negation of "this
	 * field emitted any visible content" — i.e. true iff the field's
	 * presence guard fails (Star empty / optional-Ref absent / etc.).
	 * For optional-Star/Ref WITH pad, `transparent` and `fires` are
	 * mutex by construction (`length > 0` vs `length == 0`); the
	 * disjunction in the third arm therefore collapses cleanly without
	 * runtime overlap.
	 *
	 * Returns `null` to mean "no live pad signal" — every caller stores
	 * the result back into `prevPadTrailing`, and `sameLineSeparator`
	 * treats a `null` tracker as "wrap is a no-op" (byte-identical to
	 * the pre-engine path).
	 */
	private static function composePadTrailing(prev:Null<Expr>, fires:Null<Expr>, transparent:Null<Expr>):Null<Expr> {
		if (fires == null && transparent == null) return null;
		if (fires == null) return prev != null ? macro $transparent && $prev : null;
		if (transparent == null) return fires;
		return prev != null ? macro $fires || ($transparent && $prev) : fires;
	}

	/**
	 * ω-pad-trailing-ref — wrap a sep-emission `Expr` with the
	 * `prevPadTrailing` runtime drop. When the immediately preceding
	 * field fired `@:fmt(padTrailing)`, drop THIS sep at runtime so
	 * the pad's emission owns the boundary alone.
	 *
	 * No-op (returns `result` unchanged) when `prevPadTrailing` is
	 * null — preserves byte-identical behaviour for callers without
	 * an upstream pad signal.
	 *
	 * Two consumer sites: `sameLineSeparator` (kw-Ref / opt-Ref /
	 * opt-lead struct-field sep) and the inter-Star sep at the
	 * struct-field bare-tryparse-Star branch (sub-slice 7). Both
	 * read the same macro-time `prevPadTrailing` set by
	 * `composePadTrailing` at the end of each iteration.
	 */
	private static inline function withPadTrailingDrop(prevPadTrailing:Null<Expr>, result:Expr):Expr {
		return prevPadTrailing != null
			? macro ($prevPadTrailing ? _de() : $result)
			: result;
	}

	/**
	 * ω-cond-comp-expr-multiline — emit the Doc that a Ref-side
	 * `@:fmt(padTrailing)` site pushes between `child` and the next
	 * sibling (or the parent ctor's trail literal). In plain mode
	 * or when the parent's struct rule is non-trivia-bearing, falls
	 * back to a literal `_dt(' ')` (byte-identical to the inline
	 * push the helper replaced in sub-slice 1).
	 *
	 * In trivia mode, walks the children that follow `child`
	 * via `collectFollowingNewlineSignals` and builds a runtime
	 * ternary chain that picks `_dhl()` over `_dt(' ')` when ANY
	 * downstream field's leading-newline signal is true at write
	 * time:
	 *
	 *   `(g₀ ? s₀ : (g₁ ? s₁ : … (g_n ? s_n : false))) ? _dhl() : _dt(' ')`
	 *
	 * Each `(guard, signal)` pair represents one downstream
	 * boundary candidate — guard is "this field is present at
	 * runtime", signal is "this field's leading-newline slot is
	 * true". The first guarded-and-present field's signal wins;
	 * absent fields pass through to the next entry.
	 *
	 * Sub-slice 2 wires the two existing slot kinds — `@:trivia`
	 * Star first-element `newlineBefore` and optional-kw-Ref/Star
	 * `BeforeKwNewline`. Sub-slice 5 will add a terminal entry on
	 * `child` itself (`<field>NewlineAfter`) for the
	 * parent-trail-literal boundary case where no downstream
	 * sibling carries a slot.
	 *
	 * Centralised so all three Ref-kind pad emit sites (mandatory
	 * Ref at the end-of-loop block, optional Ref inside `optParts`,
	 * and any future Ref-kind opt-in) share one decision surface.
	 * Star-kind fields keep their existing in-helper pad emission
	 * (`triviaTryparseStarExpr` reads `_arr[0].newlineBefore` for
	 * its own first-element signal — Star→Star path was
	 * pre-existing and unrelated to this slice's Ref-kind lift).
	 */
	private function padTrailingDoc(parent:ShapeNode, child:ShapeNode, typePath:String):Expr {
		if (!ctx.trivia || !isTriviaBearing(typePath)) return macro _dt(' ');
		final signals:Array<{guard:Expr, signal:Expr}> = collectFollowingNewlineSignals(parent, child);
		if (signals.length == 0) return macro _dt(' ');
		var picked:Expr = macro false;
		var i:Int = signals.length;
		while (i-- > 0) {
			final sig:{guard:Expr, signal:Expr} = signals[i];
			final guard:Expr = sig.guard;
			final signal:Expr = sig.signal;
			picked = macro $guard ? $signal : $picked;
		}
		return macro $picked ? _dhl() : _dt(' ');
	}

	/**
	 * ω-cond-comp-expr-multiline — walk the children of `parent`
	 * that follow `child`, collecting one `(guard, signal)` pair
	 * per downstream field whose presence is runtime-guarded AND
	 * whose leading-newline source-shape was captured by the
	 * trivia parser. Stops at the first mandatory non-transparent
	 * field — that field always emits visible content, so any
	 * further signal is irrelevant to `child`'s pad-emit site.
	 *
	 * Slot precedence (matches `TriviaTypeSynth`): a field that
	 * is BOTH `@:trivia` Star AND optional-kw routes through the
	 * opt-kw branch — `BeforeKwNewline` describes the kw-position
	 * newline (the boundary `child`'s pad is closing), while the
	 * Star's first-element `newlineBefore` describes a post-kw
	 * boundary one layer deeper.
	 *
	 * Optional fields (Ref or Star) without `@:kw` and without
	 * `@:trivia` carry no captured-newline slot — they're walked
	 * past as "transparent if absent" but contribute no entry; a
	 * downstream signal-bearing field still gets to win when the
	 * intervening transparent field is empty/absent at runtime.
	 */
	private function collectFollowingNewlineSignals(parent:ShapeNode, child:ShapeNode):Array<{guard:Expr, signal:Expr}> {
		final out:Array<{guard:Expr, signal:Expr}> = [];
		final startIdx:Int = parent.children.indexOf(child);
		if (startIdx < 0) return out;
		for (i in (startIdx + 1)...parent.children.length) {
			final next:ShapeNode = parent.children[i];
			final nextFieldName:Null<String> = next.annotations.get('base.fieldName');
			if (nextFieldName == null) continue;
			final nextAccess:Expr = {expr: EField(macro value, nextFieldName), pos: Context.currentPos()};
			final isOptional:Bool = next.annotations.get('base.optional') == true;
			final isOptKw:Bool = (next.kind == Ref || next.kind == Star)
				&& isOptional
				&& next.readMetaString(':kw') != null;
			if (isOptKw) {
				final slotAccess:Expr = {
					expr: EField(macro value, nextFieldName + TriviaTypeSynth.BEFORE_KW_NEWLINE_SUFFIX),
					pos: Context.currentPos(),
				};
				out.push({guard: macro $nextAccess != null, signal: slotAccess});
				continue;
			}
			final isTriviaStar:Bool = next.kind == Star && next.annotations.get('trivia.starCollects') == true;
			if (isTriviaStar) {
				final firstNl:Expr = macro $nextAccess[0].newlineBefore;
				final guard:Expr = isOptional
					? macro $nextAccess != null && $nextAccess.length > 0
					: macro $nextAccess.length > 0;
				out.push({guard: guard, signal: firstNl});
				continue;
			}
			// Non-signal field. Optional/transparent kinds without a
			// captured-newline slot fall through to the next iteration —
			// when absent at runtime they contribute no signal, when
			// present they emit visible content and the boundary is
			// theirs (a downstream signal would describe a different
			// boundary). Mandatory non-transparent fields stop the walk
			// outright.
			if (!isOptional && next.kind != Star) break;
		}
		// ω-cond-comp-expr-multiline (sub-slice 5): terminal-fallback
		// signal on `child` itself when opted in via
		// `@:fmt(captureSourceNewlineAfter)`. The signal describes the
		// newline AFTER `child`'s last token — used when every preceding
		// downstream signal is absent at runtime (Star empty + optional
		// Refs all null), i.e. when the boundary is `child → parent
		// trail-literal`. Always-on guard (`macro true`) — a runtime
		// ternary `g₀ ? s₀ : (g₁ ? s₁ : … (true ? s_n : false))`
		// folds to `(present ? signal : … : s_n)`, so this entry is
		// the chain's tail and only fires when no earlier guard
		// matched a present downstream field.
		final childFieldName:Null<String> = child.annotations.get('base.fieldName');
		if (childFieldName != null && child.kind == Ref && child.fmtHasFlag('captureSourceNewlineAfter')) {
			final terminalSlot:Expr = {
				expr: EField(macro value, childFieldName + TriviaTypeSynth.NEWLINE_AFTER_SUFFIX),
				pos: Context.currentPos(),
			};
			// Always-on guard. For an optional `child` the slot stores
			// whatever `collectTrivia` saw at the post-rewind position
			// when absent, which still describes the gap that `child`'s
			// pad-trailing emit site is closing.
			out.push({guard: macro true, signal: terminalSlot});
		}
		return out;
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
		final optFlag:Expr = optFieldAccess(flagName);
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
	 * ω-cond-comp-expr-body-nest — wrap a body Ref's writer call so the
	 * leading separator + body emit either as inline `' ' + body`
	 * (source on same line) or as `Nest(_cols, [hardline, body])`
	 * (source had a newline at the boundary). Pure source-shape decision —
	 * no user-config policy involvement, distinct from the heavier
	 * `bodyPolicyWrap` (Same/Next/Keep + bodyOnSameLine slot) and the
	 * shape-aware `bareBodyBreakWrap` (block-ctor switch). Sister to the
	 * issue_48-v2 inline `nlAccess ? _dhl() : _dt(' ')` sep but with the
	 * `_dn(_cols, ...)` wrap so the body picks up `+1` indent step on
	 * break — required for expression-scope cond-comp where the fork
	 * convention places the body one level deeper than `#if`/`#elseif`/
	 * `#else` (issue_429), unlike stmt/decl scope where body sits at
	 * the same indent as the keyword.
	 *
	 * `sourceNewlineExpr` is a runtime `Bool` Expr the caller assembles
	 * from the appropriate per-kind slot:
	 *   - Bare-Ref non-first → `value.<f>BeforeNewline` directly (true
	 *     means the source had a newline before this field's first
	 *     token, so break + nest).
	 *   - Optional-kw-Ref → `!value.<f>BodyOnSameLine` (the captured
	 *     slot stores `true` when body sat on the same line as the kw,
	 *     so we negate to get the break decision).
	 *
	 * The wrapper itself is signal-agnostic — kind dispatch lives at
	 * the call site so each path can read its own slot and gate on
	 * `ctx.trivia` / `isTriviaBearing(typePath)` before opting in.
	 *
	 * Plain mode and non-trivia-bearing types must NOT call this helper
	 * — there's no captured slot to read; the call site falls back to
	 * the existing `_dt(' ') + writeCall` default sep instead.
	 *
	 * Used by `@:fmt(nestBodyOnSourceNewline)` on body Ref fields of
	 * `HxConditionalExpr.expr`, `HxConditionalExpr.elseExpr`, and
	 * `HxElseifExpr.expr`. All current consumers have a non-Star
	 * prior sibling (`cond:HxPpCondLit` for the bare-Ref expr fields;
	 * the prior sibling is irrelevant for the optional-kw-Ref path
	 * which owns its own kw separator). Future consumers placing
	 * the flag on a bare-Ref whose prior sibling is an optional Star
	 * would need to compose with `prevAnyStarNonEmpty` at the call
	 * site — the wrapper itself is intentionally signal-only, mirroring
	 * the simplicity of `bareBodyBreakWrap`.
	 */
	private static inline function nestBodyOnSourceNewlineWrap(writeCall:Expr, sourceNewlineExpr:Expr):Expr {
		final sameLayoutExpr:Expr = macro _dc([_dt(' '), $writeCall]);
		final nextLayoutExpr:Expr = macro _dn(_cols, _dc([_dhl(), $writeCall]));
		return macro {
			final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			$sourceNewlineExpr ? $nextLayoutExpr : $sameLayoutExpr;
		};
	}

	/**
	 * ω-indent-objectliteral — wrap a Ref field's writer call in a runtime
	 * gate that, when the conditions hold, replaces the inline emission
	 * with `Nest(_cols, value)`:
	 *
	 *  1. The bound value's enum ctor matches `ctorName`.
	 *  2. The named knob `opt.<optField>:Bool` is true.
	 *  3. (3-arg form only) The named knob
	 *     `opt.<leftCurlyField>:BracePlacement` is `Next`.
	 *
	 * The 3-arg form mirrors haxe-formatter's
	 * `indentation.indentObjectLiteral=true` rule, which only fires when
	 * `{` lands on its own line — i.e. when the per-construct leftCurly
	 * placement is Allman (`Next` / `both`). In that layout the value's
	 * hardlines pick up one extra indent step: `var x =\n\t{...}` instead
	 * of `var x =\n{...}`. With `Same` (cuddled) leftCurly the wrap is
	 * inert — `{` already sits on the parent line, so the inner content's
	 * existing nest is enough (`var x = {\n\t...}` byte-identical to the
	 * pre-slice layout).
	 *
	 * The 2-arg form (ω-indent-complex-value-expr) drops the leftCurly
	 * check — the wrap fires whenever the ctor + opt knob match,
	 * unconditionally. Used for ctors where the leading `{` placement is
	 * fixed by the grammar (e.g. `IfExpr` always has `if (cond) {…}` on
	 * the same line as `if`) so a leftCurly gate would be inert. Mirrors
	 * haxe-formatter's `indentation.indentComplexValueExpressions=true`
	 * rule which adds an indent step to `if`/`switch`/`try` value
	 * expressions on RHS regardless of brace placement.
	 *
	 * Used by `@:fmt(indentValueIfCtor('<ctorName>', '<optField>'))` or
	 * `@:fmt(indentValueIfCtor('<ctorName>', '<optField>',
	 * '<leftCurlyField>'))` on RHS-style Ref fields. Multiple entries
	 * stack on the same field — `HxVarDecl.init` carries one entry for
	 * `('ObjectLit', 'indentObjectLiteral', 'objectLiteralLeftCurly')`
	 * plus a second for `('IfExpr', 'indentComplexValueExpressions')`.
	 * All args are grammar-driven so the macro core stays format-neutral:
	 * the ctor name is local to the field's enum type, and runtime knobs
	 * live on the per-grammar `WriteOptions` struct (no base-options
	 * bloat for non-Haxe formats). New RHS sites opt in by tagging their
	 * field, no core edit required.
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
	private function indentValueIfCtorWrap(writeCall:Expr, fieldAccess:Expr, ctorName:String, optField:String, ?leftCurlyField:String):Expr {
		final optAccess:Expr = optFieldAccess(optField);
		final ctorMatch:Expr = macro Type.enumConstructor($fieldAccess) == $v{ctorName};
		final condExpr:Expr = if (leftCurlyField == null) macro $optAccess && $ctorMatch
		else {
			final leftCurlyAccess:Expr = optFieldAccess(leftCurlyField);
			macro $optAccess && $leftCurlyAccess == anyparse.format.BracePlacement.Next && $ctorMatch;
		};
		return macro {
			final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			final _doc:anyparse.core.Doc = $writeCall;
			if ($condExpr) _dn(_cols, _doc) else _doc;
		};
	}

	/**
	 * ω-N-break-after-eq: bundle a non-tight optional `@:lead` + its RHS
	 * through the natural-first-line probe so the lead breaks (LF + Nest
	 * +1) ONLY when the LHS declared type carries type-params AND the
	 * RHS's NATURAL first line (its own wrap decisions active) still
	 * overflows `opt.lineWidth`. A NoWrap-pinned RHS keeps its full flat
	 * first line -> probe crosses -> break after `=`; a RHS that wraps
	 * its own call-args has a short natural first line -> probe stays
	 * flat -> keep ` = RHS` inline (the fork wraps the RHS bracket, not
	 * the `=`). The LHS-type-param gate (gate 1) reads the sibling field
	 * named by `typeFieldName` (today `HxVarDecl.type`): fires only for a
	 * `Named` type ctor with a non-empty `params` list. Mode-agnostic —
	 * a single optional Ref's paired value is the paired enum directly
	 * (NOT Trivial<…>-wrapped, unlike Star elements).
	 *
	 * Differs from the `bodyPolicyWrap` `_difle` precedent (same file,
	 * width path) by calling `_dinfle` (natural-first-line probe) instead
	 * of `_difle` (flat first-line probe): the flat probe cannot tell a
	 * wrappable RHS bracket from a NoWrap-pinned one and over-breaks.
	 */
	private function breakAfterLeadIfLhsTypeParamWrap(leadText:String, writeCall:Expr, typeFieldName:String):Expr {
		final typeAccess:Expr = {expr: EField(macro value, typeFieldName), pos: Context.currentPos()};
		return macro {
			final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			final _rhs:anyparse.core.Doc = $writeCall;
			final _lhsType = $typeAccess;
			final _lhsHasTypeParam:Bool = _lhsType != null
				&& Type.enumConstructor(_lhsType) == 'Named'
				&& {
					final _p = Reflect.field(Type.enumParameters(_lhsType)[0], 'params');
					_p != null && (_p : Array<Dynamic>).length > 0;
				};
			if (_lhsHasTypeParam)
				_dc([
					_dt($v{leadText}),
					_dinfle(opt.lineWidth,
						_dn(_cols, _dc([_dhl(), _rhs])),
						_dc([_dop(' '), _rhs]))
				]);
			else
				_dc([_dt($v{leadText}), _dop(' '), _rhs]);
		};
	}

	/**
	 * Read every `@:fmt(indentValueIfCtor(...))` entry off `child` and
	 * chain a wrap per entry. Returns the (possibly multi-wrapped) writer
	 * call when any entry is present, the raw call when none. Both Ref-
	 * field branches (optional + mandatory) in `lowerStruct` route through
	 * this single helper to avoid duplicating the meta-validation block.
	 *
	 * Each entry accepts 2 args (`ctorName, optField`) or 3 args
	 * (`ctorName, optField, leftCurlyField`); the 2-arg form drops the
	 * leftCurly gate. Entries' ctor names are mutually exclusive in
	 * practice (an `HxExpr` value's runtime ctor is one of its variants)
	 * so at most one wrap fires per render — chaining is safe.
	 */
	private function maybeIndentValueIfCtor(rawWriteCall:Expr, fieldAccess:Expr, child:ShapeNode):Expr {
		final all:Array<Array<String>> = child.fmtReadStringArgsAll('indentValueIfCtor');
		if (all.length == 0) return rawWriteCall;
		var current:Expr = rawWriteCall;
		for (entry in all) {
			if (entry.length != 2 && entry.length != 3) Context.fatalError(
				'WriterLowering: @:fmt(indentValueIfCtor(...)) requires (ctorName, optField) or (ctorName, optField, leftCurlyField), got ${entry.length} args',
				Context.currentPos()
			);
			final lc:Null<String> = entry.length == 3 ? entry[2] : null;
			current = indentValueIfCtorWrap(current, fieldAccess, entry[0], entry[1], lc);
		}
		return current;
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
	private static function leftCurlySeparator(starNode:ShapeNode, optSpaceUpstream:Bool = false):Expr {
		if (!starNode.fmtHasFlag('leftCurly')) return macro _dt(' ');
		final knobName:Null<String> = starNode.fmtReadString('leftCurly');
		final baseKnobExpr:Expr = optFieldAccess(knobName ?? 'leftCurly');
		// ω-arrow-lambda-body-context: sister meta
		// `@:fmt(leftCurlyAnonFnOverride('<knob>'))` co-located with
		// `@:fmt(leftCurly('<knob>'))` enables flag-aware dispatch — when
		// the writer descends through `@:fmt(propagateAnonFnContext)` (e.g.
		// from `HxThinParenLambda.body`), `opt._inAnonFnBody` is true and
		// the separator reads `opt.<overrideKnob>` (anonFunctionLeftCurly)
		// instead of the default knob (blockLeftCurly). Consumer:
		// `HxExpr.BlockExpr.stmts`. Star-element write site clears the flag
		// before per-element descent so nested BlockExpr in inner statements
		// fall back to the default knob.
		final anonFnOverrideKnob:Null<String> = starNode.fmtReadString('leftCurlyAnonFnOverride');
		final knobExpr:Expr = if (anonFnOverrideKnob != null) {
			final overrideExpr:Expr = optFieldAccess(anonFnOverrideKnob);
			macro opt._inAnonFnBody ? $overrideExpr : $baseKnobExpr;
		} else baseKnobExpr;
		final nextPat:Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BracePlacement', 'Next']);
		// `optSpaceUpstream=true` (currently only first-field Star with
		// knob-form `@:fmt(leftCurly('<knob>'))`, e.g. `HxObjectLit.fields` /
		// `HxType.Anon.fields`) means the outer caller already emits the
		// inter-token space via the lead's `_dop(' ')` (OptSpace). The
		// `Same` branch returns `_de()` — the OptSpace flushes as ' ' on
		// its own. The `Next` branch emits a hardline; the renderer drops
		// the pending OptSpace and writes `\n` cleanly.
		//
		// `optSpaceUpstream=false` (the default — kw-led mandatory Ref,
		// optional Ref / bare Ref `@:fmt(leftCurly)`, non-first-field
		// Star bare-flag) means no upstream space producer; the separator
		// must own the space directly: `Same` → `_dt(' ')`, `Next` →
		// `_dhl()`. Knob-form on these paths (slice
		// ω-anonfunction-left-curly first consumer: `HxFnExpr.body` with
		// `leftCurly('anonFunctionLeftCurly')`) keeps the `_dt(' ')` Same
		// default — the pre-slice heuristic that switched to `_de()` on
		// any knob-form was tuned for the first-field-Star site only.
		// ω-trivia-tryparse-linelength: switch the `Same` (and `Keep` / non-
		// `Next`) default from hard `_dt(' ')` to `_dossh()`
		// (OptSpaceSkipAfterHardline) so a preceding hardline (e.g. our
		// lineLengthAware-emitted trail-terminator after a trailing line
		// comment) drops the space, leaving the next `{` at base indent
		// without a leading space (`\n{` instead of `\n {`). Flat-mode
		// width is identical (1) so layout decisions stay byte-identical
		// outside the after-hardline state; `Next` branch unaffected.
		final defaultExpr:Expr = optSpaceUpstream ? macro _de() : macro _dossh();
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
			return branch.fmtReadStringArgs('bodyPolicy') != null;
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
		final optAccess:Expr = optFieldAccess(flagName);
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
		final optAccess:Expr = optFieldAccess(flagName);
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
		final optAccess:Expr = optFieldAccess(flagName);
		return {expr: ESwitch(optAccess, cases, macro _de()), pos: Context.currentPos()};
	}

	/**
	 * Operand-ctor-dispatched counterpart of `kwTrailingSpacePolicy` —
	 * same kw-after slot, but the choice between ` ` and `_de()` is
	 * driven at runtime by the operand's enum constructor name rather
	 * than a `WhitespacePolicy` option. Reads
	 * `@:fmt(tightOnParenOperand('A', 'B', …))` from the branch; when
	 * the operand's runtime `Type.enumConstructor(...)` matches any of
	 * the listed names, emits `_de()` (kw fuses tight to the operand's
	 * leading `(`); otherwise emits `_dt(' ')`.
	 *
	 * Returns `null` when the flag is absent so the call site falls
	 * through to the pre-slice fixed `kwLead + ' '` emission. Requires
	 * the branch to be a single-Ref ctor — `argNames[0]` carries the
	 * operand binding (mirror of `bodyPolicy`'s value-arg dispatch in
	 * the indent-wrap path).
	 *
	 * Consumed by `@:fmt(tightOnParenOperand('ParenExpr',
	 * 'ECheckTypeExpr'))` on `HxExpr.CastExpr` (paired with
	 * `@:fmt(atomOperand)` in Lowering so the operand binds at atom
	 * level and the listed ctors actually appear as the operand's
	 * runtime ctor — without atom-binding, `cast (x) is Bool` would
	 * carry operand=`Is(...)` and the ctor match would never fire).
	 * Emits tight `cast(x)` / `cast(x : Int)` per haxe-formatter's
	 * cast-as-function-call convention, while bare `cast x` (operand =
	 * `IdentExpr`) keeps the spaced shape.
	 */
	private static function kwTrailingSpaceOnOperandCtor(branch:ShapeNode, argNames:Array<String>):Null<Expr> {
		final names:Null<Array<String>> = branch.fmtReadStringArgs('tightOnParenOperand');
		if (names == null || names.length == 0) return null;
		if (argNames.length == 0) return null;
		final operandAccess:Expr = macro $i{argNames[0]};
		final ctorEquals:Array<Expr> = [for (n in names) macro _ctor == $v{n}];
		var matchExpr:Expr = ctorEquals[0];
		for (i in 1...ctorEquals.length) {
			final next:Expr = ctorEquals[i];
			matchExpr = macro $matchExpr || $next;
		}
		return macro {
			final _ctor:String = Type.enumConstructor($operandAccess);
			$matchExpr ? _de() : _dt(' ');
		};
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
		return policyInsideSpace(flagName, isClose);
	}

	/**
	 * Build the inside-delimiter space Doc Expr for a named
	 * `WhitespacePolicy` opt field: a runtime switch emitting `_dt(' ')`
	 * for `After`/`Both` (open side) or `Before`/`Both` (close side), else
	 * `_de()`. Shared core of `delimInsidePolicySpace` (where the flag name
	 * IS the opt field name, e.g. `anonTypeBracesOpen`) and the
	 * `HxExpr.IndexAccess` `accessBracketsOpen`/`Close` path (where the
	 * `@:fmt(accessBrackets)` flag name differs from the two opt fields).
	 */
	private static function policyInsideSpace(optFieldName:String, isClose:Bool):Expr {
		final wpPath:Array<String> = ['anyparse', 'format', 'WhitespacePolicy'];
		final beforePat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Before']));
		final afterPat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['After']));
		final bothPat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Both']));
		final matchValues:Array<Expr> = isClose ? [beforePat, bothPat] : [afterPat, bothPat];
		final cases:Array<Case> = [
			{values: matchValues, expr: macro _dt(' '), guard: null},
		];
		final optAccess:Expr = optFieldAccess(optFieldName);
		return {expr: ESwitch(optAccess, cases, macro _de()), pos: Context.currentPos()};
	}

	/**
	 * ω-bracket-config: runtime-dispatched sibling of
	 * `delimInsidePolicySpace` for the `HxExpr.ArrayExpr` `[…]` Star,
	 * whose ONE ctor covers three fork bracket kinds (array-literal /
	 * map-literal / comprehension). The kind is decided at write time by
	 * `opt.arrayBracketKind(<first element>)` (the plugin classifier on
	 * the first element's enum ctor: `Arrow`→map, `ForExpr`/`WhileExpr`→
	 * comprehension, else array-literal). The resolved kind selects one of
	 * the three `{arrayLiteral|mapLiteral|comprehension}Brackets<Open|
	 * Close>` policy fields, then the same open→After/Both / close→Before/
	 * Both → `_dt(' ')` collapse as `delimInsidePolicySpace` produces the
	 * inside-space Doc.
	 *
	 * `firstAccess` is the runtime Expr reading the first Star element
	 * (`_arr[0].node` in trivia mode, `_args[0]` in plain mode — both
	 * normalised by the plugin's `unwrap`). Emitted as a block so the
	 * classifier runs once per side. Default `None` on every kind keeps
	 * the tight `[1]` / `[1 => "a"]` / `[for …]` byte-identical to the
	 * pre-slice layout. Empty `[]` never reaches this helper — both emit
	 * paths short-circuit `items.length == 0` before padding.
	 */
	private static function arrayBracketInsidePolicySpace(firstAccess:Expr, isClose:Bool):Expr {
		final wpPath:Array<String> = ['anyparse', 'format', 'WhitespacePolicy'];
		final beforePat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Before']));
		final afterPat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['After']));
		final bothPat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Both']));
		final matchValues:Array<Expr> = isClose ? [beforePat, bothPat] : [afterPat, bothPat];
		final spaceCases:Array<Case> = [
			{values: matchValues, expr: macro _dt(' '), guard: null},
		];
		final suffix:String = isClose ? 'Close' : 'Open';
		final mapField:Expr = optFieldAccess('mapLiteralBrackets' + suffix);
		final comprField:Expr = optFieldAccess('comprehensionBrackets' + suffix);
		final arrayField:Expr = optFieldAccess('arrayLiteralBrackets' + suffix);
		final kindCases:Array<Case> = [
			{values: [macro 1], expr: mapField, guard: null},
			{values: [macro 2], expr: comprField, guard: null},
		];
		final policyExpr:Expr = {expr: ESwitch(macro _abk, kindCases, arrayField), pos: Context.currentPos()};
		final spaceSwitch:Expr = {expr: ESwitch(macro _abp, spaceCases, macro _de()), pos: Context.currentPos()};
		// `arrayBracketKind` is `Null<Dynamic -> Int>` (an opt-in adapter);
		// capture into a local + null-check before calling, mirroring the
		// `caseBodyRefusesFlat` pattern. Null (format didn't wire it) → kind
		// 0 (ArrayLiteral) so the default `arrayLiteralBrackets` policy
		// applies — its `None` default keeps the tight `[1]` form.
		return macro {
			final _abkFn:Null<Dynamic -> Int> = opt.arrayBracketKind;
			final _abk:Int = _abkFn == null ? 0 : _abkFn($firstAccess);
			final _abp:anyparse.format.WhitespacePolicy = $policyExpr;
			$spaceSwitch;
		};
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
		if (flagName == null) {
			// Writer Slice 10: opt-in `@:fmt(spaceAfterLead)` on a struct-
			// field mandatory `@:lead(LIT)` appends an OptSpace after the
			// lead literal — mirror of Slice 4's enum-ctor `spaceAfterLead`
			// path (line ~1075) for the struct-field side. Used by
			// `HxVarMore.decl` (`@:lead(',')`) and `HxTypedCast.type`
			// (`@:lead(',')`) to emit `, b` and `cast(x, T)` respectively
			// instead of tight `,b` / `cast(x,T)`. The space is `_dop` so
			// the renderer can drop it when the value emits a leading
			// hardline.
			if (child.fmtHasFlag('spaceAfterLead'))
				return macro _dc([_dt($v{leadText}), _dop(' ')]);
			return macro _dt($v{leadText});
		}
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
		final optAccess:Expr = optFieldAccess(flagName);
		return {expr: ESwitch(optAccess, cases, macro _dt($v{leadText})), pos: Context.currentPos()};
	}

	/**
	 * Infix-op sister of `whitespacePolicyLead`: emit the operator literal
	 * (e.g. `->` on `HxType.Arrow`) under a runtime switch on
	 * `opt.<flagName>:WhitespacePolicy`. Default `None` falls through to
	 * the tight `_dt(opText)`, preserving the pre-flag layout for the
	 * historic `@:fmt(tight)` shape; `Around` / `Before` / `After` add
	 * the matching adjacent spaces. Both adjacent spaces emit as plain
	 * `_dt` (not `_dop`) — an infix op sits between two value Docs that
	 * never emit leading or trailing hardlines on their own at the op
	 * boundary, so OptSpace would not pay off the way it does on a
	 * `@:lead` site whose value may break.
	 */
	private static function whitespacePolicyInfix(opText:String, flagName:String):Expr {
		final wpPath:Array<String> = ['anyparse', 'format', 'WhitespacePolicy'];
		final beforePat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Before']));
		final afterPat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['After']));
		final bothPat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Both']));
		final cases:Array<Case> = [
			{values: [beforePat], expr: macro _dt($v{' ' + opText}), guard: null},
			{values: [afterPat], expr: macro _dt($v{opText + ' '}), guard: null},
			{values: [bothPat], expr: macro _dt($v{' ' + opText + ' '}), guard: null},
		];
		final optAccess:Expr = optFieldAccess(flagName);
		return {expr: ESwitch(optAccess, cases, macro _dt($v{opText})), pos: Context.currentPos()};
	}

	/**
	 * ω-condition-parens (Stage C): trail-side sister of
	 * `whitespacePolicyLead`. Emit a `@:trail(text)` close literal under a
	 * runtime switch on `opt.<flagName>:WhitespacePolicy`, prepending an
	 * INNER space (` )`) when the policy carries the `before` side
	 * (`Before` / `Both`). The close literal sits right after a value Doc,
	 * so the inner space is a plain `_dt(' ')` (the value never emits a
	 * trailing hardline at the paren boundary). Picks the first flag from
	 * `flagNames` present on `child`; no flag → tight `_dt(trailText)`,
	 * byte-identical to the pre-slice mandatory-trail path. Used by
	 * `catchParensInsideClose` (`HxCatchClause.param` `@:trail(')')`).
	 */
	private static function whitespacePolicyTrail(child:ShapeNode, trailText:String, flagNames:Array<String>):Expr {
		final flagName:Null<String> = firstFmtFlag(child, flagNames);
		if (flagName == null) return macro _dt($v{trailText});
		final wpPath:Array<String> = ['anyparse', 'format', 'WhitespacePolicy'];
		final beforePat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Before']));
		final bothPat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Both']));
		final cases:Array<Case> = [
			{values: [beforePat, bothPat], expr: macro _dt($v{' ' + trailText}), guard: null},
		];
		final optAccess:Expr = optFieldAccess(flagName);
		return {expr: ESwitch(optAccess, cases, macro _dt($v{trailText})), pos: Context.currentPos()};
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
	private function bodyPolicyWrap(opts:WrapBodyOpts):Expr {
		// ω-bodyPolicyWrap-struct-arg: 17-positional-arg signature collapsed
		// into a single struct (`WrapBodyOpts`) so call sites no longer thread
		// `null, null, null` runs for forwarding-only fields. Aliasing back to
		// the original local names keeps the body diff-free; the typedef
		// definition lives at the bottom of this file alongside `PrevBodyInfo`.
		final flagName:String = opts.flagName;
		final bodyValueExpr:Expr = opts.bodyValueExpr;
		final bodyTypePath:String = opts.bodyTypePath;
		final hasElseIf:Bool = opts.hasElseIf;
		final elseFieldName:Null<String> = opts.elseFieldName;
		final afterKwExpr:Null<Expr> = opts.afterKwExpr;
		final kwLeadingExpr:Null<Expr> = opts.kwLeadingExpr;
		final bodyOnSameLineExpr:Null<Expr> = opts.bodyOnSameLineExpr;
		final kwPolicyFlagName:Null<String> = opts.kwPolicyFlagName;
		final afterTrailExpr:Null<Expr> = opts.afterTrailExpr;
		final indentObjArgs:Null<Array<String>> = opts.indentObjArgs;
		final policyOverrides:Null<Array<Array<String>>> = opts.policyOverrides;
		final bodyAllmanIndentArgs:Null<Array<String>> = opts.bodyAllmanIndentArgs;
		final widthAware:Null<Bool> = opts.widthAware;
		final ifExprIndentArgs:Null<Array<String>> = opts.ifExprIndentArgs;
		final fallbackFlagName:Null<String> = opts.fallbackFlagName;
		final inlineBlockBodyArgs:Null<Array<String>> = opts.inlineBlockBodyArgs;
		// ω-expression-if-with-blocks: when the field carries
		// `@:fmt(inlineBlockBodyIfFlag('<flagName>'))`, swap the body's
		// writeCall for a runtime-conditional Doc that flattens block
		// bodies inline when `opt.<flagName>` is true AND the body's
		// runtime ctor is `BlockExpr`. Done at the entry of bodyPolicyWrap
		// so the flattened body propagates through every downstream
		// policy / override layout (Same / Next / Keep / FitLine / etc.).
		// Non-BlockExpr bodies and flag-false invocations get the original
		// writeCall result unchanged.
		//
		// Note: ctor literal `'BlockExpr'` is hardcoded by-definition —
		// the meta's semantic IS "block-shaped body collapse" (mirrors
		// fork's `markBlockBody`). If a future grammar wants the same
		// override on a different block-shaped ctor, extend the meta to
		// `inlineBlockBodyIfFlag('<flag>', '<ctorName>')` and read both
		// args here.
		final writeCall:Expr = if (inlineBlockBodyArgs == null) opts.writeCall
		else {
			if (inlineBlockBodyArgs.length != 1)
				Context.fatalError('WriterLowering: bodyPolicyWrap inlineBlockBodyArgs requires (flagName), got ${inlineBlockBodyArgs.length} args', Context.currentPos());
			final inlineFlag:Expr = optFieldAccess(inlineBlockBodyArgs[0]);
			final origWriteCall:Expr = opts.writeCall;
			macro {
				final _bodyDoc:anyparse.core.Doc = $origWriteCall;
				($inlineFlag && Type.enumConstructor($bodyValueExpr) == 'BlockExpr')
					? anyparse.core.D.flatten(_bodyDoc)
					: _bodyDoc;
			};
		};
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
		// ω-issue-257-else-in-return-switch: when the field carries a
		// dual-flag `bodyPolicy('<stmtFlag>', '<exprFlag>')`, the
		// resolved policy depends on `opt._inExprPosition` — stmt
		// position reads the first flag, expr position reads the
		// second. Mirrors the dual-flag dispatch in
		// `triviaTryparseStarExpr` for case-body Star fields. Single-
		// flag form (`exprFlagName == null`) keeps the byte-identical
		// pre-slice access. First consumers: `HxIfStmt.thenBody`
		// (`bodyPolicy('ifBody', 'expressionIfBody')`) and
		// `HxIfStmt.elseBody` (`bodyPolicy('elseBody',
		// 'expressionElseBody')`) — flatten in/else inside
		// `case POpen: if(c) a; else b;` of a return-switch when
		// `expressionIf=Same`.
		final exprFlagName:Null<String> = opts.exprFlagName;
		final baseOptFlag:Expr = if (exprFlagName == null) optFieldAccess(flagName) else {
			final stmtAccess:Expr = optFieldAccess(flagName);
			final exprAccess:Expr = optFieldAccess(exprFlagName);
			macro (opt._inExprPosition ? $exprAccess : $stmtAccess);
		};
		// ω-return-body-single-line: when the field carries
		// `@:fmt(bodyPolicySingleLine('<flagName>', '<multiCtor>'...))` (e.g.
		// `HxStatement.ReturnStmt`), the resolved policy splits on the value's
		// AST shape — mirroring haxe-formatter's `shouldReturnBeSameLine` /
		// `shouldReturnChildsBeSameLine` (MarkSameLine.hx): a value whose ctor
		// is a control-flow / block construct (`if` / `switch` / `for` /
		// `while` / `try` / `{ … }`, listed verbatim as the trailing meta args)
		// keeps the base `returnBody` policy; every other value (literal,
		// ident, ternary, array/object/comprehension, call …) reads the
		// `opt.<singleLineFlag>` (`returnBodySingleLine`) knob. The control-flow
		// ctor names are passed declaratively from the grammar so the writer
		// macro stays format-neutral. Orthogonal to the expr-position dual-flag
		// above: expr-position picks stmt-vs-expr knob, this picks
		// singleLine-vs-multiLine. With no multi-ctor args the value always
		// resolves to the single-line knob.
		final singleLineFlagName:Null<String> = opts.singleLineFlagName;
		final singleLineMultiCtors:Null<Array<String>> = opts.singleLineMultiCtors;
		// ω-keep-chain (increment: opadd_chain_keep): the ctor's captured
		// `return`→value source newline; drives the FitLine head-break when the
		// body is an already-multiline keep-chain. Null → no head-break (legacy).
		final kwNewlineExpr:Null<Expr> = opts.kwNewlineExpr;
		final defaultOptFlag:Expr = if (singleLineFlagName == null) baseOptFlag else {
			final singleLineAccess:Expr = optFieldAccess(singleLineFlagName);
			final ctors:Array<String> = singleLineMultiCtors ?? [];
			final ctorExpr:Expr = macro Type.enumConstructor($bodyValueExpr);
			var isMultiLine:Expr = macro false;
			for (ctorName in ctors)
				isMultiLine = macro $isMultiLine || $ctorExpr == $v{ctorName};
			macro ($isMultiLine ? $baseOptFlag : $singleLineAccess);
		};
		final ctorOverriddenOptFlag:Expr = if (policyOverrides == null || policyOverrides.length == 0) defaultOptFlag
		else {
			final ctorExpr:Expr = macro Type.enumConstructor($bodyValueExpr);
			var chain:Expr = defaultOptFlag;
			var i:Int = policyOverrides.length - 1;
			while (i >= 0) {
				final pair:Array<String> = policyOverrides[i];
				if (pair.length != 2) Context.fatalError('WriterLowering: bodyPolicyWrap policyOverrides entry requires (ctorName, flagName), got ${pair.length} args', Context.currentPos());
				final ctorName:String = pair[0];
				final overrideFlag:String = pair[1];
				final overrideField:Expr = optFieldAccess(overrideFlag);
				chain = macro $ctorExpr == $v{ctorName} ? $overrideField : $chain;
				i--;
			}
			chain;
		};
		// ω-expression-if-next-with-fitline-body: outermost runtime swap on
		// `optFlag`. When the field carries `@:fmt(noSiblingFallback(
		// '<fallbackFlagName>'))` AND the next optional sibling field is null
		// at runtime AND the resolved policy is `Next` / `FitLine`, the body
		// policy is read from `opt.<fallbackFlagName>` instead of
		// `opt.<flagName>`. Wraps OUTSIDE the ctor-override chain because no-
		// sibling implies "fall back to the simpler shape" — the body's ctor
		// is irrelevant when the fallback policy applies.
		//
		// `Same` / `Keep` are NOT swapped: the original semantic is "flatten /
		// preserve source" which is independent of sibling presence, and the
		// fallback flag (e.g. `opt.ifBody=Next` default) would force-break
		// short bodies that the user's config explicitly asked to keep flat.
		// The fallback exists to undo the force-break of `Next/FitLine`, not
		// to override every policy.
		//
		// Consumed by `HxIfExpr.thenBranch` (`fallbackFlagName='ifBody'`,
		// elseFieldName='elseBranch'): when `else` is absent AND
		// `opt.expressionIfBody` is `Next` / `FitLine`, the body uses
		// `opt.ifBody` instead, preserving inline shape for arrow-body and
		// comprehension-filter `if (cond) body` cases under `expressionIf=
		// next`. With `expressionIf=same/keep` the original policy applies.
		final optFlag:Expr = if (fallbackFlagName == null || elseFieldName == null) ctorOverriddenOptFlag
		else {
			final elseAccess:Expr = {expr: EField(macro value, elseFieldName), pos: Context.currentPos()};
			final fallbackAccess:Expr = optFieldAccess(fallbackFlagName);
			final bpPath:Array<String> = ['anyparse', 'format', 'BodyPolicy'];
			final samePat:Expr = MacroStringTools.toFieldExpr(bpPath.concat(['Same']));
			final keepPat:Expr = MacroStringTools.toFieldExpr(bpPath.concat(['Keep']));
			macro {
				final _resolvedBP:anyparse.format.BodyPolicy = $ctorOverriddenOptFlag;
				($elseAccess == null && _resolvedBP != $samePat && _resolvedBP != $keepPat)
					? $fallbackAccess : _resolvedBP;
			};
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
			final kwOpt:Expr = optFieldAccess(kwPolicyFlagName);
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
		// ω-returnbody-widthaware + ω-issue-257-firstline: when the field
		// carries `@:fmt(widthAware)`, wrap the Same-mode emission with a
		// `Doc.IfFirstLineExceeds(opt.lineWidth, brk, flat)` probe. The
		// renderer chooses `brk` (next-line + indent) when `col +
		// flatTokenWidthFirstLine(flat) >= opt.lineWidth`, else `flat`
		// (inline). The first-line cap matters for multi-line bodies whose
		// first rendered line fits but whose total flat width would
		// overflow — e.g. `return <multi-line if-expr>` where the if-expr's
		// head fits inline with `return` while subsequent `else` branches
		// keep their own hardlines (haxe-formatter's
		// `sameLine.returnBody: same` semantic). The earlier
		// `IfWidthExceeds` variant over-fired on such shapes and forced
		// the body onto its own line.
		//
		// `_bodyW` is bound once so the writer call emits a single Doc
		// subtree shared between both sides of the IfFirstLineExceeds; the
		// renderer materialises only the chosen branch. The flat-shape
		// sibling (`flatTokenWidth` in chain consumers) is unchanged —
		// only the renderer-side probe descends with the first-line cap.
		//
		// Affects `Same` policy unconditionally and the `Keep`-fallback
		// path when no `bodyOnSameLineExpr` slot is forwarded. With the
		// slot threaded (ctor-level capture in `Lowering.lowerEnumBranch`
		// Case 3 — see `triviaBodyPolicyKw` gate — and forwarded by the
		// Case 3 writer call site below), `Keep` dispatches source-shape-
		// aware: `true` → `sameLayoutExpr` (still width-probed via the
		// first-line cap), `false` → `nextLayoutExpr` (unconditional
		// break).
		//
		// Trade-off: when both `widthAware` AND `indentValueIfCtor` fire on
		// the same field AND the width-aware brk path triggers, the brk path
		// uses the plain `_dn(_cols, [_dhl(), _bodyW])` shape — the
		// `indentObjGuardedNext` outer-Nest-drop is reachable only via
		// explicit `Next` policy. ReturnStmt's only consumer today.
		//
		// ω-issue-257-return-same-indent-value-expr: when `ifExprIndentArgs`
		// names a 2-arg `indentValueIfCtor(ctorName, optField)` entry, build
		// a conditional `Nest(_cols, body)` wrapper and apply it ONLY in the
		// Same flat-path (widthAware flat branch + non-widthAware Same).
		// Mirrors the struct-field `HxVarDecl.init` semantic
		// (`@:fmt(indentValueIfCtor('IfExpr', 'indentComplexValueExpressions'))`)
		// for ctor-level kw-led single-Ref branches like
		// `HxStatement.ReturnStmt`. Without the gate, multi-branch IfExpr
		// values inside `return <if-expr>` (Same policy, body inline with
		// `return`) emit their internal `else` hardlines at the ambient
		// indent — expected is `+cols` (one extra step beyond the kw
		// column). The `nextLayoutExpr`, `blockLayoutExpr`, `fitExpr`, and
		// widthAware-brk paths already apply their own outer Nest, so
		// double-Nest = over-indent — the wrap fires only in flat-path.
		// Same-policy `Keep` fallback (no `bodyOnSameLineExpr` slot) routes
		// through `sameLayoutExpr`, so it inherits the wrap; `Keep`-with-
		// `bodyOnSameLineExpr=true` also routes through `sameLayoutExpr`.
		// `Keep`-with-`bodyOnSameLineExpr=false` routes through
		// `nextLayoutExpr` (no wrap, body already on its own indent step).
		if (ifExprIndentArgs != null && ifExprIndentArgs.length != 2)
			Context.fatalError('WriterLowering: bodyPolicyWrap ifExprIndentArgs requires (ctorName, optField), got ${ifExprIndentArgs.length} args', Context.currentPos());
		inline function wrapIfExprNest(bodyExpr:Expr):Expr {
			if (ifExprIndentArgs == null) return bodyExpr;
			final ifCtorName:String = ifExprIndentArgs[0];
			final ifOptAccess:Expr = optFieldAccess(ifExprIndentArgs[1]);
			return macro {
				final _bIfn:anyparse.core.Doc = $bodyExpr;
				($ifOptAccess && Type.enumConstructor($bodyValueExpr) == $v{ifCtorName}) ? _dn(_cols, _bIfn) : _bIfn;
			};
		}
		final sameLayoutExpr:Expr = if (widthAware == true) {
			final flatBody:Expr = wrapIfExprNest(macro _bodyW);
			macro {
				final _bodyW:anyparse.core.Doc = $writeCall;
				_difle(opt.lineWidth,
					_dn(_cols, _dc([_dhl(), _bodyW])),
					_dc([$sameSepNb, $flatBody]));
			};
		} else {
			final flatBody:Expr = wrapIfExprNest(writeCall);
			macro _dc([$sameSepNb, $flatBody]);
		};
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
			final optAccess:Expr = optFieldAccess(indentObjArgs[1]);
			final lcAccess:Expr = optFieldAccess(indentObjArgs[2]);
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
		// `Concat[OptSpace(' '), body]` (kw inline + body wraps
		// internally with its own indent). Width-driven break path is
		// preserved for single-line bodies that don't fit `lineWidth`.
		// ω-optspace-leading-break: `_dop(' ')` instead of `_dt(' ')` —
		// when the body's leading shape is itself a hardline (e.g. a
		// long op-add chain whose `shapeOnePerLine` opens with
		// `OptHardlineSkipAtOpenDelim`), the OptSpace drops cleanly via
		// renderer's `pendingOptSpace = null` on the inner hardline emit,
		// yielding `return\n\t<chain>` instead of `return \n\t<chain>`.
		// For bodies whose leading shape is plain Text (e.g. `return
		// foo(\narg)` — multi-line call with leading `foo(`), the
		// OptSpace flushes normally as a space — byte-identical to the
		// pre-slice `_dt(' ')` emission. Sister fix to the kw-led
		// optional-Ref lead-value split at line 2129 which uses the same
		// idiom for `var x =\n{...}` object-literal-leftCurly-Next.
		// ω-return-fitline-natural-glue (inc8): for return-style FitLine bodies
		// (`singleLineFlagName != null` = `ReturnStmt`), keep `return <head>`
		// GLUED iff the body's NATURAL first line fits at the `return ` column,
		// letting a binary chain / call SELF-break its operators / args at
		// +1cols — mirroring fork's `shouldWrapReturnExpr`. A body that
		// CANNOT self-break (atomic long literal / ident) has a natural first
		// line == its whole flat width → overflows → wholesale next-line break
		// (`return\n\t<body>`), matching `HxReturnBodySliceTest.
		// testFitLineBreaksLongValue`. The `_dinfle` (`IfNaturalFirstLineExceeds`,
		// inc1 downward probe) resolves the body's inner Groups by their own
		// `fitsFlat`, so a chain whose operand-Group breaks reports its short
		// natural first line (`return prefix`) and glues; the chain's own
		// `Nest(cols)` then supplies the single +1 continuation indent (no
		// double-Nest, because the glue branch adds no Nest of its own). The
		// `flatLength == -1` already-multiline case glues unconditionally
		// (the body owns its layout). if/for/while/etc. FitLine bodies
		// (`singleLineFlagName == null`) keep the legacy `BodyGroup` wholesale
		// break — fork treats their body as one atomic unit
		// (`sameline/fitline_{if,for}`, `if_for_chain_*`).
		// ω-keep-chain (increment: opadd_chain_keep): for an already-multiline
		// body (`flatLength == -1`) the inc8 return path glues `return <body>`
		// ("body owns its layout"). But when the source placed a newline after
		// `return` (`kwNewlineExpr` true — a `WrapMode.Keep` chain nested in
		// `1 * (…)` whose own `_headBreak` was suppressed by the enclosing
		// ParenExpr) the head newline must be reproduced at the VALUE level:
		// break `return\n\t<body>` so `1 * (…)` lands at +1cols and the chain's
		// operators continue at that same indent. Mirrors fork keep2 preserving
		// the `return`→`1` source newline. `kwNewlineExpr` null (plain / non-
		// bearing) keeps the legacy unconditional glue → byte-inert.
		// The head-break fires ONLY when (a) the source placed a newline after
		// `return` (`kwNewlineExpr`), (b) a chain KEEP config is active
		// (`opAddSubChain`/`opBoolChain` defaultWrap=keep) — so the whole gate is
		// byte-inert under every non-keep config, and (c) the body does NOT already
		// start with a hardline. A BARE chain return value (opbool case-2)
		// self-breaks its head (`shapeKeep` headBreak → leading `\n`), so
		// `startsWithHardline(_body)` is true and we keep the legacy glue (the chain
		// owns the head break — no double `\n`). A chain nested in `1 * (…)` (opadd)
		// had its headBreak suppressed (`_keepChainInParen`) and starts with
		// `1 * (` (Text), so the value-level head-break fires. The chain keep-config
		// fields are referenced only inside the `kwNewlineExpr != null` branch,
		// which is spliced solely for the Haxe trivia `ReturnStmt` ctor (the only
		// opt carrying those fields) — format-neutral for every other grammar.
		//
		// ω-return-value-expr-if-indent: in the return-style FitLine glue
		// path (`singleLineFlagName != null` = `ReturnStmt`) the body is
		// emitted INLINE with `return` (no FitLine break) when it is already
		// multi-line (`flatLength == -1`) or when its natural first line fits
		// (`_dinfle` flat branch). For a value-expression `if`/`else` written
		// across source lines under `expressionIf=keep`, that glue path
		// previously emitted the body at the ambient indent — dropping the
		// value-expression indent step that `wrapIfExprNest`
		// (`@:fmt(indentValueIfCtor('IfExpr', 'indentComplexValueExpressions'))`)
		// already applies on the Same flat-path. Route the glued body through
		// `wrapIfExprNest` so the internal then/else hardlines pick up `+cols`,
		// matching the struct-field `HxVarDecl.init` semantic (which wraps the
		// whole if-expr write via `maybeIndentValueIfCtor`). The wrap is
		// ctor-gated (`Type.enumConstructor(value) == 'IfExpr'`) AND opt-gated
		// (`indentComplexValueExpressions`, default `false`), so it is byte-
		// inert for every non-IfExpr value and every config that does not opt
		// in. On a single-line if-expr (`_dinfle` flat) the Nest has no
		// hardlines to indent and is inert. The chain-keep branch
		// (`kwNewlineExpr` true) keeps the bare `_body` — chains are not
		// `IfExpr` so the wrap would be inert there anyway.
		final gluedBody:Expr = wrapIfExprNest(macro _body);
		final multilineGlue:Expr = kwNewlineExpr != null
			? macro($kwNewlineExpr
					&& (opt.opAddSubChainWrap.defaultMode == anyparse.format.wrap.WrapMode.Keep
						|| opt.opBoolChainWrap.defaultMode == anyparse.format.wrap.WrapMode.Keep)
					&& !anyparse.format.wrap.WrapList.startsWithHardline(_body)
				? _dn(_cols, _dc([_dhl(), _body]))
				: _dc([_dop(' '), $gluedBody]))
			: macro _dc([_dop(' '), $gluedBody]);
		final fitInnerExpr:Expr = if (singleLineFlagName != null)
			macro anyparse.format.wrap.WrapList.flatLength(_body) == -1
				? $multilineGlue
				: _dinfle(opt.lineWidth,
					_dn(_cols, _dc([_dhl(), _body])),
					_dc([_dop(' '), $gluedBody]));
		else
			macro anyparse.format.wrap.WrapList.flatLength(_body) == -1
				? _dc([_dop(' '), _body])
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
		// ω-D8-keep-block-trivia: hoisted out of the bodySwitch construction
		// below so the Keep next-layout arm (see `keepNextLayoutExpr` below)
		// can route block ctors through `blockLayoutExpr`. The previous
		// declaration site at the head of `bodySwitch` worked for the non-
		// Keep dispatch but was too late for the Keep arm. No behavioural
		// change — same value computed once, consumed by both `bodySwitch`
		// and `keepNextLayoutExpr`.
		final blockSplit:{tagged:Array<Expr>, untagged:Array<Expr>} = collectBlockCtorPatternsByLeftCurly(bodyTypePath);
		// ω-D8-keep-elseif-override: hoisted so the Keep arm can apply the
		// `opt.elseIf == Next` override for `else if (…)` bodies (mirrors
		// the non-Keep `bodySwitch` arm at the existing `outerCases` push
		// below). Without the hoist + Keep dispatch, Keep would short-
		// circuit the elseIf override — user-set `elseIf=Next` would lose
		// to `elseBody=Keep`'s source-preservation. Same value also
		// consumed by the existing non-Keep dispatch (one read site each).
		final ifStmtPattern:Null<Expr> = hasElseIf
			? (findCtorPattern(bodyTypePath, 'IfStmt') ?? findCtorPattern(bodyTypePath, 'IfExpr'))
			: null;
		// ω-keep-policy: `Keep` dispatches at runtime between same and
		// next layouts based on the trivia-mode parser's captured
		// `<field>BodyOnSameLine:Bool` slot. When the caller did not
		// forward a slot access (non-kw paths, plain mode), degrade to
		// `sameLayoutExpr` (matches the pre-slice behaviour when the
		// loader lossy-mapped `keep` to `Same`). Handled by the outer
		// `keepPat` case below; a `_` catch-all in `policyCases` would
		// be unreachable because the outer switch short-circuits Keep.
		// ω-D8-keep-block-trivia: when Keep dispatches into the
		// next-layout arm (body NOT on same line as kw) AND the body is
		// a block ctor, route through `blockLayoutExpr` instead of
		// `nextLayoutExpr`. `nextLayoutExpr` wraps body in
		// `Nest(_cols, [hardline, body])` which is correct for non-block
		// stmt bodies (`else // c\n\tb();` — body wants +cols indent)
		// but adds an extra +cols step to a block-ctor `{`, putting it
		// one indent below parent col instead of Allman-aligned with the
		// kw. The `outerKeepCases` arm short-circuits the block-aware
		// `bodySwitch` below, so Keep never sees the existing block
		// split — replicate the split here. `blockLayoutExpr` uses
		// `sameSepBlock` (= `kwGapDoc(_, _, _cols, isNextExpr, opt)` when
		// hasKwSlots) which emits captured trivia + trailing hardline at
		// parent col, then body emits its `{` at parent col — Allman
		// shape, byte-identical to the non-Keep block path. When
		// `blockSplit.tagged` is empty, `keepNextLayoutExpr` collapses to
		// `nextLayoutExpr` (no behavioural change for body types without
		// block ctors).
		final keepNextLayoutExpr:Expr = if (blockSplit.tagged.length > 0) {
			final cases:Array<Case> = [
				{values: blockSplit.tagged, expr: blockLayoutExpr, guard: null},
			];
			cases.push({values: [macro _], expr: nextLayoutExpr, guard: null});
			{expr: ESwitch(bodyValueExpr, cases, null), pos: Context.currentPos()};
		}
		else nextLayoutExpr;
		final keepBaseExpr:Expr = bodyOnSameLineExpr != null
			? macro ($bodyOnSameLineExpr ? $sameLayoutExpr : $keepNextLayoutExpr)
			: sameLayoutExpr;
		// ω-D8-keep-elseif-override: when body is an `IfStmt` / `IfExpr`
		// (else-if shape) AND `opt.elseIf == Next`, force the nested
		// `if` onto the next line by routing through `nextLayoutExpr` —
		// matches the non-Keep `elseIfSwitch` semantics below. User-set
		// `elseIf=Next` is an explicit override and must beat Keep's
		// source-shape preservation, same way `elseIf=Same` is already
		// observable over `elseBody=Next` via the non-Keep `bodySwitch`
		// arm. Default (`elseIf=Same`) falls through to `keepBaseExpr`
		// so inline source `else if` shapes are preserved verbatim.
		final keepLayoutExpr:Expr = if (ifStmtPattern != null) {
			final kpPath:Array<String> = ['anyparse', 'format', 'KeywordPlacement'];
			final kpNextPat:Expr = MacroStringTools.toFieldExpr(kpPath.concat(['Next']));
			final elseIfCases:Array<Case> = [
				{values: [kpNextPat], expr: nextLayoutExpr, guard: null},
			];
			final elseIfSwitchForKeep:Expr = {
				expr: ESwitch(macro opt.elseIf, elseIfCases, keepBaseExpr),
				pos: Context.currentPos(),
			};
			final outerKeepBodyCases:Array<Case> = [
				{values: [ifStmtPattern], expr: elseIfSwitchForKeep, guard: null},
			];
			outerKeepBodyCases.push({values: [macro _], expr: keepBaseExpr, guard: null});
			{expr: ESwitch(bodyValueExpr, outerKeepBodyCases, null), pos: Context.currentPos()};
		}
		else keepBaseExpr;
		final policyCases:Array<Case> = [
			{values: [samePat], expr: sameLayoutExpr, guard: null},
			{values: [nextPat], expr: nextLayoutExpr, guard: null},
			{values: [fitPat], expr: fitExpr, guard: null},
		];
		final policySwitch:Expr = {expr: ESwitch(optFlag, policyCases, sameLayoutExpr), pos: Context.currentPos()};

		// ω-expression-if-next-with-fitline-body: `hasElseIf` with body type
		// HxStatement matches `IfStmt`; with body type HxExpr matches `IfExpr`
		// (HxIfExpr.elseBranch). The override fires when the else-body is
		// itself an if-construct so `else if` cuddles via opt.elseIf semantics.
		// `ifStmtPattern` declared above near `blockSplit` so it's also
		// available to `keepLayoutExpr`.
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
		// ω-issue-168: outermost runtime override — when the field carries
		// `@:fmt(bodyAllmanIndentForCtor('<ctor>', '<optField>',
		// '<lcField>'))` AND the runtime conditions match (named bool opt
		// TRUE, named leftCurly opt `Next`, value's ctor matches, body's
		// `flatLength` is `-1` i.e. anyHardline), bypass the policy-decided
		// layout entirely and emit `_dn(_cols, [_dhl(), _dn(_cols, body)])`
		// — `{` on its own line at +cols, body's contents at +2cols, `}` at
		// +cols. The wrap-with-extra-Nest matches haxe-formatter's per-
		// construct rule for `[for (x in xs) {<multi-line obj-lit>}]`
		// comprehensions where the body is broken from the `for` head and
		// indented one extra step. Single-line obj-lit bodies, non-
		// ObjectLit values, or `objectLiteralLeftCurly == Same` configs
		// fall through to the policy-decided `wrapExpr`. The override
		// stays outside `coreWrapExpr` so it stacks above Keep's source-
		// shape preservation as well as the explicit policy axes.
		final finalWrapExpr:Expr = if (bodyAllmanIndentArgs == null) wrapExpr
		else {
			if (bodyAllmanIndentArgs.length != 2)
				Context.fatalError('WriterLowering: bodyPolicyWrap bodyAllmanIndentArgs requires (ctorName, optField), got ${bodyAllmanIndentArgs.length} args', Context.currentPos());
			final ctorName:String = bodyAllmanIndentArgs[0];
			final optAccess:Expr = optFieldAccess(bodyAllmanIndentArgs[1]);
			macro {
				final _bodyForAllman:anyparse.core.Doc = $writeCall;
				if ($optAccess
					&& Type.enumConstructor($bodyValueExpr) == $v{ctorName}
					&& anyparse.format.wrap.WrapList.flatLength(_bodyForAllman) == -1)
					_dn(_cols, _dc([_dhl(), _bodyForAllman]))
				else
					$wrapExpr;
			};
		};

		return macro {
			final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			$finalWrapExpr;
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

	private function collectBlockShapeEquivalentPatterns(bodyTypePath:String):Array<Expr> {
		final rule:Null<ShapeNode> = shape.rules.get(bodyTypePath);
		if (rule == null || rule.kind != Alt) return [];
		final patterns:Array<Expr> = [];
		for (branch in rule.children) if (isBlockShapeEquivalentBranch(branch))
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
	 *
	 * ω-issue-303-array-comprehension — only genuine curly-brace block
	 * bodies (`{ … }`, lead `{`) are partitioned here. Bracket-delimited
	 * list ctors (`[ … ]`, lead `[` — `HxExpr.ArrayExpr`, incl. array
	 * comprehensions `[for (x in xs) …]`) match `isBlockCtorBranch`'s
	 * shape (lead + trail + single `Star`) but are VALUE expressions, not
	 * block bodies: they must obey the resolved body policy
	 * (`returnBody` / `returnBodySingleLine`), not the unconditional
	 * keyword-glue the block-split override forces. Excluding them here
	 * lets `bodyPolicyWrap`'s `bodySwitch` fall through to the policy
	 * switch — mirroring fork `MarkSameLine.shouldReturnBeSameLine`, which
	 * routes a single-line `return [for …];` value to
	 * `sameLine.returnBodySingleLine` instead of force-gluing it. The
	 * single-vs-multi-line distinction is handled downstream by the
	 * policy's own layout (`Same` width-probe / `Next` break / `Keep`
	 * source-shape), so no source-line probe is needed at this point.
	 */
	private function collectBlockCtorPatternsByLeftCurly(bodyTypePath:String):{tagged:Array<Expr>, untagged:Array<Expr>} {
		final rule:Null<ShapeNode> = shape.rules.get(bodyTypePath);
		if (rule == null || rule.kind != Alt) return {tagged: [], untagged: []};
		final tagged:Array<Expr> = [];
		final untagged:Array<Expr> = [];
		for (branch in rule.children) if (isCurlyBlockCtorBranch(branch)) {
			final pattern:Expr = branchCtorPattern(bodyTypePath, branch);
			if (branch.fmtHasFlag('leftCurly')) tagged.push(pattern);
			else untagged.push(pattern);
		}
		return {tagged: tagged, untagged: untagged};
	}

	/**
	 * `isBlockCtorBranch` narrowed to genuine curly-brace block bodies:
	 * the branch must be a block-ctor shape (lead + trail + single `Star`)
	 * AND its `@:lead` literal must open a curly brace (`{`). Bracket
	 * list ctors (`[ … ]`) and any other delimiter are excluded. Used by
	 * the body-placement block-split so `[for …]`-style value lists follow
	 * the resolved body policy instead of the keyword-glue override.
	 */
	private static function isCurlyBlockCtorBranch(branch:ShapeNode):Bool {
		if (!isBlockCtorBranch(branch)) return false;
		final leadText:Null<String> = branch.annotations.get('lit.leadText');
		return leadText != null && StringTools.startsWith(leadText, '{');
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
	private static function isBlockShapeEquivalentBranch(branch:ShapeNode):Bool {
		return isBlockCtorBranch(branch) || branch.fmtHasFlag('blockShape');
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
		return optFieldAccess(flagName);
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
		return optFieldAccess(flagName);
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
		return first.fmtReadStringArgs('bodyPolicy') != null;
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
		indentCaseLabelsGate:Bool = false,
		emptyCurlyBreak:Bool = false,
		beginEndType:Bool = false,
		keepCurlyBlanks:Bool = false,
		lineCommentTrailBlank:Bool = false,
		blankBeforeFinalDocInLeading:Bool = false,
		staticVarSubdivInfo:Null<StaticVarSubdivisionInfo> = null,
		betweenMultilineCommentsBlanks:Bool = false,
		uniformBetweenOptField:Null<String> = null,
		clearAnonFnBodyOnElems:Bool = false,
		emptyCurlyKnob:Null<String> = null,
		rightCurlyKnob:Null<String> = null,
		rightCurlyAnonFnKnob:Null<String> = null,
		// ω-blockended-trivia (Session 3): when the Star carries
		// `@:sep('text', tailRelax, blockEnded)`, the block-mode emit
		// gains between-element sep emission, gated on
		// `!DocMeasure.endsWithCloseBrace(priorElemDoc)`. Null sepText →
		// pre-slice byte-identical (no inter-stmt sep emit — per-stmt
		// `;` lives inside each element's own Doc via @:trailOpt).
		sepText:Null<String> = null,
		blockEnded:Bool = false,
		// ω-condcomp-stray-semi (Stage A): the schema-instance predicate name
		// (`lit.sepBlockEndedPredicate`, e.g. `stmtNoSemi`) consulted on the
		// PRIOR / LAST element's AST when deciding between-element / trailing
		// sep elision. Mirror of the plain-mode block-Star path (L4400): a
		// `#if … #end` stmt ends with `d` so the `endsWithStmtTerminator` byte
		// check misses, but `stmtNoSemi` accepts the `Conditional` AST shape.
		// `blockEndedSchemaPath` is the dotted format-instance path (e.g.
		// `anyparse.grammar.haxe.HaxeFormat`) used to build the
		// `<schema>.instance.<predicate>(elem)` call. Both null → byte-
		// identical to the pre-fix path (no predicate consult).
		blockEndedPredicate:Null<String> = null,
		blockEndedSchemaPath:Null<String> = null
	):Expr {
		// ω-condcomp-stray-semi (Stage A): build the schema-instance
		// predicate-call Expr for a given element-access Expr. Mirrors the
		// plain-mode block-Star path (L4400-4428). Returns `macro false` when
		// no predicate is wired so the OR-extended byte/sepAfter checks below
		// stay byte-identical for callers without `blockEnded('<pred>')`.
		final blockEndedPredCall:Expr->Expr = function(elemAccess:Expr):Expr {
			if (blockEndedPredicate == null || blockEndedSchemaPath == null) return macro false;
			final fmtParts:Array<String> = blockEndedSchemaPath.split('.');
			return {
				expr: ECall(
					{expr: EField(macro $p{fmtParts}.instance, blockEndedPredicate), pos: Context.currentPos()},
					[elemAccess]
				),
				pos: Context.currentPos(),
			};
		};
		// ω-arrow-lambda-body-context: when the call site opts in via
		// `@:fmt(leftCurlyAnonFnOverride(...))` on the parent Star, the per-
		// element write call passes `_clearAnonFnBody(opt)` so the flag is
		// consumed at this Star's `{` placement and descendants (nested
		// statements / nested BlockExpr inside the body) fall back to the
		// default `blockLeftCurly` knob rather than re-triggering the
		// anon-fn override.
		final elemOptExpr:Expr = clearAnonFnBodyOnElems
			? macro _clearAnonFnBody(opt)
			: macro opt;
		final triviaElemCall:Expr = {
			expr: ECall(macro $i{elemFn}, [macro _t.node, elemOptExpr]),
			pos: Context.currentPos(),
		};
		final emptyText:String = openText + closeText;
		// ω-empty-curly-break: when the call site opts in via
		// `@:fmt(emptyCurlyBreak)`, the empty-body branch dispatches at
		// runtime on `opt.emptyCurly`. `Break` emits the open lit, a
		// hardline at the parent's indent, and the close lit on its own
		// line (`{\n}`); `Same` keeps the pre-slice flat `{}`. Mirrors
		// haxe-formatter's `lineEnds.emptyCurly: same|break`. The flag
		// is opt-in per Star — formats / grammars that don't expose the
		// knob skip the branch entirely.
		// ω-anonfunction-empty-curly: when the call site descends through
		// an anonymous-function-expression body (`HxFnExpr.body` flagged
		// via `@:fmt(propagateAnonFnContext)` + `_setAnonFnBody`
		// opt-fanout), read `opt.anonFunctionEmptyCurly` instead of the
		// global `opt.emptyCurly`. Lets `lineEnds.anonFunctionCurly.emptyCurly`
		// flip empty `function() {}` bodies to two-line Allman
		// (`function()\n{\n}`) without affecting class/iface/abstract/enum
		// bodies (which keep reading `opt.emptyCurly`). Pre-slice behaviour
		// for HxFnDecl body (NOT in anon-fn context) is preserved:
		// `_inAnonFnBody` defaults false so dispatch falls through to
		// `opt.emptyCurly`. Emitted unconditionally — every grammar that
		// opts into `@:fmt(emptyCurlyBreak)` on a body Star also needs
		// `_inAnonFnBody` and `anonFunctionEmptyCurly` on its options
		// typedef. Currently only Haxe grammar uses `emptyCurlyBreak`.
		// ω-blockempty: when the call site opts into the call-form
		// `@:fmt(emptyCurlyBreak('<knob>'))` instead of the bare
		// `@:fmt(emptyCurlyBreak)`, the dispatch reads `opt.<knob>` directly
		// — bypassing the `_inAnonFnBody` ternary. Used by `BlockStmt` /
		// `BlockExpr` / `HxSwitchStmt.cases` / `HxSwitchStmtBare.cases` to
		// route to `opt.blockEmptyCurly` (driven by `lineEnds.blockCurly.emptyCurly`
		// sub-key). Bare-flag callers (`HxFnBlock.stmts`, class/iface/abstract
		// member-Star bodies, `HxEnumDecl.ctors`) keep the pre-slice
		// `_inAnonFnBody`-based dispatch.
		final emptyCurlyAccess:Expr = emptyCurlyKnob != null
			? {expr: EField(macro opt, emptyCurlyKnob), pos: Context.currentPos()}
			: macro (opt._inAnonFnBody ? opt.anonFunctionEmptyCurly : opt.emptyCurly);
		final emptyDocExpr:Expr = emptyCurlyBreak
			? macro ($emptyCurlyAccess == anyparse.format.EmptyCurly.Break
				? _dc([_dt($v{openText}), _dhl(), _dt($v{closeText})])
				: _dt($v{emptyText}))
			: macro _dt($v{emptyText});
		// ω-blockright-curly: when the call site opts into the call-form
		// `@:fmt(rightCurly('<knob>'))`, the non-empty-body branch reads
		// `opt.<knob>:RightCurlyPlacement` and drops the hardline before
		// `}` when the knob is `Inline`. `Same` (default) keeps the
		// pre-slice `_dhl()` so `}` lands on its own line at the parent
		// indent. The empty-body branch is unaffected — empty-body
		// dispatch is owned by `emptyCurlyBreak` + `emptyCurlyKnob`.
		// Bare-flag callers without `rightCurlyKnob` keep pre-slice
		// behaviour (knob is null → `_dhl()` emitted unconditionally).
		// Mirrors haxe-formatter's `lineEnds.rightCurly: before|both`
		// (-> `Same`) vs `after|none` (-> `Inline`) -- the trailing
		// newline after `}` is contributed by the outer sibling sep, so
		// fork's 4-value surface collapses to 2 here.
		// ω-anonfunction-right-curly: when the call site opts into the
		// call-form `@:fmt(rightCurlyAnonFnOverride('<knob>'))`, the
		// dispatch fires only when `opt._inAnonFnBody=true` (set by a
		// parent's `@:fmt(propagateAnonFnContext)` via `_setAnonFnBody`)
		// — `Inline` drops the hardline before `}`, `Same` falls through
		// to `_dhl()`. When `_inAnonFnBody=false`, the dispatch falls
		// through to `_dhl()` regardless of the knob value. Used by
		// `HxFnBlock.stmts` to apply `anonFunctionRightCurly` to anon-fn
		// bodies (`HxFnExpr.body`) while preserving pre-slice `_dhl()`
		// for function declarations (`HxFnDecl.body`) and untyped blocks
		// (`HxUntypedFnBody.block`) that share the same `HxFnBlock`
		// typedef. `rightCurlyKnob` (direct dispatch) takes precedence
		// over `rightCurlyAnonFnKnob` when both are set — but in
		// practice no Star opts into both. Sister to
		// `leftCurlyAnonFnOverride` precedent.
		final rightCurlyAccess:Null<Expr> = rightCurlyKnob != null
			? {expr: EField(macro opt, rightCurlyKnob), pos: Context.currentPos()}
			: null;
		final rightCurlyAnonFnAccess:Null<Expr> = (rightCurlyKnob == null && rightCurlyAnonFnKnob != null)
			? {expr: EField(macro opt, rightCurlyAnonFnKnob), pos: Context.currentPos()}
			: null;
		final beforeCloseHardlineExpr:Expr = if (rightCurlyAccess != null)
			macro ($rightCurlyAccess == anyparse.format.RightCurlyPlacement.Inline ? _de() : _dhl());
		else if (rightCurlyAnonFnAccess != null)
			macro (opt._inAnonFnBody && $rightCurlyAnonFnAccess == anyparse.format.RightCurlyPlacement.Inline ? _de() : _dhl());
		else
			macro _dhl();
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
		// line comment is followed by a hardline — line comments terminate
		// at \n semantically, and the Alt's parent struct may emit a space
		// sep next (e.g. HxTryCatchStmt.body→catches with sameLineCatch),
		// which would glue the next sibling onto the same line as the
		// comment. Seq-struct sites pass false: their close-trailing slot
		// always lives on the LAST field of its containing struct, where
		// the parent Star's element separator already supplies a hardline.
		//
		// ω-opthardlineskipbeforehardline (slice B opt-in): emit
		// `_dohsbh()` instead of `_dhl()`. Forward-looking opt-hardline
		// drops when the next non-OptSpace emit is itself a hardline —
		// closes the spurious-blank-line bug between two consecutive
		// `} // comment` / `<next stmt>` BlockStmt-Alt siblings where
		// the parent stmt-list Star's per-element sep emits a hardline.
		// In the sameLineCatch case the parent emits a content/space
		// follower, so `_dohsbh()` still fires (lands `\n+indent` for
		// the next-line catch placement). See target fixtures
		// `lineends/issue_445_curly_with_comment{,_both}`.
		final trailFollowExpr:Expr = appendHardlineAfterTrail ? macro _parts.push(_dohsbh()) : macro {};
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
		final uniformBetween:Bool = uniformBetweenOptField != null;
		final anyEmptyLinesFlag:Bool = afterFieldsWithDocComments || existingBetweenFields || beforeDocCommentEmptyLines || interMember || uniformBetween;
		final stripByDocExpr:Expr = afterFieldsWithDocComments
			? macro (_prevHadDocComment && opt.afterFieldsWithDocComments == anyparse.format.CommentEmptyLinesPolicy.None)
			: macro false;
		final addByDocExpr:Expr = afterFieldsWithDocComments
			? macro (_prevHadDocComment && opt.afterFieldsWithDocComments == anyparse.format.CommentEmptyLinesPolicy.One)
			: macro false;
		final stripByExistingExpr:Expr = existingBetweenFields
			? macro (opt.existingBetweenFields == anyparse.format.KeepEmptyLinesPolicy.Remove)
			: macro false;
		// ω-extern-existing-between-split-leading: when the current
		// member's `leadingComments` carries the "split" shape — a
		// trailing `/**` doc-comment preceded by `//` line-comments —
		// fork's `existingBetweenFields=Remove` policy strips the
		// inter-member source blank, regardless of `_prevHadDocComment`.
		// The strip is consulted under the extern-scoped policy
		// (`externExistingBetweenFields`) when `_classExtern` is set,
		// otherwise the regular policy. This lets fixtures that mix
		// `afterFieldsWithDocComments=Ignore` with `Remove` behave
		// like fork: blanks between members with a regular leading
		// cluster survive, while the split-leading boundary collapses
		// (the source blank is "moved" inside the leading cluster by
		// the sibling `blankBeforeFinalDocCommentInLeading` mech).
		final stripBySplitLeadingExpr:Expr = existingBetweenFields
			? macro (
				opt._classExtern
				&& _currHasSplitLeading
				&& opt.externExistingBetweenFields == anyparse.format.KeepEmptyLinesPolicy.Remove
			)
			: macro false;
		// Companion suppress: in extern context, fork never re-adds a
		// blank at the inter-member slot when the next member's leading
		// carries the split shape — beforeDocCommentEmptyLines=One only
		// fires intra-leading on the final `/**`. Independent of
		// `externExistingBetweenFields` policy (verified via fork CLI:
		// extern + split + default config + no source blank → no add;
		// extern + split + source blank present → blank preserved
		// because source survives, but no extra add stacks on top).
		final addSuppressOnSplitLeadingExpr:Expr = existingBetweenFields
			? macro (opt._classExtern && _currHasSplitLeading)
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
		// ω-extern-existing-between-split-leading: per-element scan that
		// flips `_currHasSplitLeading` true when the element's leading
		// cluster ends in a `/**` doc comment whose immediate predecessor
		// is a `//` line comment. Mirrors the gate used by
		// `blankBeforeFinalDocCommentInLeading` (single front-to-back
		// pass tracking the index of the last `/**`; the split fires when
		// that index is > 0 AND the previous entry is `//`-prefixed).
		// Drives `stripBySplitLeadingExpr` above; gated on the same
		// `existingBetweenFields` star flag so JSON / AS3 writers stay
		// untouched.
		final currHasSplitLeadingComputeExpr:Expr = existingBetweenFields ? macro {
			_currHasSplitLeading = false;
			var _slLast:Int = -1;
			var _sli:Int = 0;
			while (_sli < _t.leadingComments.length) {
				if (StringTools.startsWith(_t.leadingComments[_sli], '/**')) _slLast = _sli;
				_sli++;
			}
			if (_slLast > 0 && StringTools.startsWith(_t.leadingComments[_slLast - 1], '//'))
				_currHasSplitLeading = true;
		} : macro {};
		// ω-class-static-var-cascade: when the Star opts in via
		// `@:fmt(staticVarSubdivision)`, augment the per-iteration kind
		// switch with a sibling-Star scan that promotes kind `1` (instance
		// var) to kind `3` (static var) on encountering a `Static`-ctor
		// modifier. Kind `2` (function) is left alone — fork's
		// classifier-cascade DOES split static functions, but no current
		// fixture exercises that arm; defer until one does.
		final staticVarSubdiv:Bool = staticVarSubdivInfo != null;
		final staticPromoteExpr:Expr = staticVarSubdiv ? {
			final pos:Position = Context.currentPos();
			final modAccess:Expr = {
				expr: EField(macro _t.node, staticVarSubdivInfo.modifierFieldName),
				pos: pos,
			};
			final staticIdent:Expr = {expr: EConst(CIdent(staticVarSubdivInfo.staticCtorName)), pos: pos};
			macro {
				if (_currKind == 1) for (_m in $modAccess) if (_m.node.match($staticIdent)) {
					_currKind = 3;
					break;
				}
			};
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
			macro {
				_currKind = $switchExpr;
				$staticPromoteExpr;
			};
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
			// ω-extern-class-no-blanks: `_classExtern` is propagated from
			// `HxTopLevelDecl.decl` via `@:fmt(setBoolFlagFromStarCtor(...))`
			// when the sibling `modifiers` Star contains `Extern`. AND-out
			// the entire interMember add-rule when the flag is set so an
			// `extern class { var; var; function; function; }` round-trips
			// with zero blanks regardless of `betweenVars` /
			// `betweenFunctions` / `afterVars` defaults — mirrors fork's
			// `externClassEmptyLines` config-section override at the
			// minimal interMember subset.
			//
			// ω-class-static-var-cascade: when subdivision is active, kind
			// `3` represents static-var. Same-kind cascade arms treat
			// kinds `1` and `3` as both "var" for the var↔function `afterVars`
			// arm (so static-var → fn fires `afterVars` like instance-var → fn).
			// Within the var family, instance↔static transitions fire the
			// new `afterStaticVars` knob; same-static and same-instance use
			// `betweenVars` (fork's `betweenStaticVars` defaults to `0` —
			// equivalent — and is not modeled separately until a fixture
			// requires it). When subdivision is off, kind `3` is unreachable
			// and the cascade collapses to the pre-slice three arms.
			if (staticVarSubdiv) {
				final afterStaticVarsAccess:Expr = {
					expr: EField(macro opt, staticVarSubdivInfo.afterStaticVarsField),
					pos: pos,
				};
				macro (!opt._classExtern && (
					(_prevKind == 1 && _currKind == 1 && $betweenVarsAccess > 0)
					|| (_prevKind == 3 && _currKind == 3 && $betweenVarsAccess > 0)
					|| (((_prevKind == 1 && _currKind == 3) || (_prevKind == 3 && _currKind == 1))
						&& $afterStaticVarsAccess > 0)
					|| (_prevKind == 2 && _currKind == 2 && $betweenFnAccess > 0)
					|| ((((_prevKind == 1 || _prevKind == 3) && _currKind == 2)
						|| (_prevKind == 2 && (_currKind == 1 || _currKind == 3)))
						&& $afterVarsAccess > 0)
				));
			} else {
				macro (!opt._classExtern && (
					(_prevKind == 1 && _currKind == 1 && $betweenVarsAccess > 0)
					|| (_prevKind == 2 && _currKind == 2 && $betweenFnAccess > 0)
					|| (_prevKind != 0 && _currKind != 0 && _prevKind != _currKind && $afterVarsAccess > 0)
				));
			}
		} : macro false;
		// ω-enum-empty-lines: opt-in via `@:fmt(uniformBetween('<optField>'))`.
		// When present, the named non-negative-Int knob on the runtime
		// `opt` is consulted at the inter-element slot — `> 0` contributes
		// to `_addBlank` (single-blank semantics, same shape as the other
		// add arms). Generic mech: any Star whose elements are an Alt
		// without a var/fn split (e.g. `HxEnumDecl.ctors` →
		// `opt.betweenEnumCtors`) can opt in by pointing at its own knob.
		final addByUniformBetweenExpr:Expr = uniformBetween ? {
			final pos:Position = Context.currentPos();
			final optAccess:Expr = {
				expr: EField(macro opt, uniformBetweenOptField),
				pos: pos,
			};
			macro $optAccess > 0;
		} : macro false;
		final blankBeforeExpr:Expr = anyEmptyLinesFlag ? macro {
			$currHasDocComputeExpr;
			$currKindComputeExpr;
			$currHasSplitLeadingComputeExpr;
			final _stripBlank:Bool = $stripByDocExpr || $stripByExistingExpr || $stripByCurrDocExpr || $stripBySplitLeadingExpr;
			final _addBlank:Bool = !$addSuppressOnSplitLeadingExpr && ($addByDocExpr || $addByCurrDocExpr || $addByInterMemberExpr || $addByUniformBetweenExpr);
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
		final initCurrSplitLeadingExpr:Expr = existingBetweenFields
			? macro var _currHasSplitLeading:Bool = false
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
		// ω-class-begin-end-type: opt-in head/tail blank-line injection
		// for class/interface/abstract bodies. Drives `opt.beginType` /
		// `opt.endType` (exact counts) and `opt.afterLeftCurly` /
		// `opt.beforeRightCurly` (Keep/Remove on source blanks). The
		// explicit count wins when > 0; otherwise Keep honours the
		// captured source-blank signal (`_arr[0].blankBefore` for the
		// open side, `_trailBB` for the close side). Remove (default)
		// strips. The flag is opt-in per Star — formats that don't
		// expose the knobs leave the inserts disabled.
		//
		// ω-bropen-keep: sister opt-in `keepCurlyBlanks` for non-type
		// bodies (function body, if/while/etc. block-stmt, block-expr).
		// Honours the universal `opt.afterLeftCurly` / `opt.beforeRightCurly`
		// Keep policy without applying type-scoped `opt.beginType` /
		// `opt.endType` Int counts (those live under haxe-formatter's
		// `emptyLines.classEmptyLines` and only fire on type bodies).
		final emitBeginExtras:Bool = beginEndType || keepCurlyBlanks;
		final beginNExpr:Expr = beginEndType
			? macro (opt.beginType > 0
				? opt.beginType
				: (opt.afterLeftCurly == anyparse.format.KeepEmptyLinesPolicy.Keep && _firstSourceBlank ? 1 : 0))
			: macro (opt.afterLeftCurly == anyparse.format.KeepEmptyLinesPolicy.Keep && _firstSourceBlank ? 1 : 0);
		final endNExpr:Expr = beginEndType
			? macro (opt.endType > 0
				? opt.endType
				: (opt.beforeRightCurly == anyparse.format.KeepEmptyLinesPolicy.Keep && _trailBB && _arr.length > 0 ? 1 : 0))
			: macro (opt.beforeRightCurly == anyparse.format.KeepEmptyLinesPolicy.Keep && _trailBB && _arr.length > 0 ? 1 : 0);
		final beginTypeExpr:Expr = emitBeginExtras ? macro {
			final _firstSourceBlank:Bool = _arr.length > 0 && _arr[0].blankBefore;
			final _beginN:Int = $beginNExpr;
			var _bi:Int = 0;
			while (_bi < _beginN) {
				_inner.push(_dhl());
				_bi++;
			}
		} : macro {};
		final endTypeExpr:Expr = emitBeginExtras ? macro {
			final _endN:Int = $endNExpr;
			var _ei:Int = 0;
			while (_ei < _endN) {
				_inner.push(_dhl());
				_ei++;
			}
		} : macro {};
		// ω-block-final-doc-leading-blank: opt-in via
		// `@:fmt(blankBeforeFinalDocCommentInLeading)`. When the current
		// element's `leadingComments` mixes line-style `//` runs with a
		// trailing `/**` doc-comment, fork inserts a single blank between
		// the last `//` and that final `/**` (treats the last `/**` as
		// "the doc comment", separated from the line-comment cluster).
		// Only fires for the LAST `/**` index — earlier `/**` entries
		// inside leading do NOT get a leading blank (verified via fork
		// CLI probes on `// /** // /** static main()` shapes). The
		// "is last `/**`" lookahead is recomputed inline per iteration
		// — the leadingComments arrays are short (≤ ~5 entries in
		// practice) so the cost is negligible, and it lets the gate
		// stay self-contained without leaking a helper var into the
		// outer EBlock scope.
		final leadingSplitGateExpr:Expr = blankBeforeFinalDocInLeading
			? macro {
				if (_ci > 0 && StringTools.startsWith(_t.leadingComments[_ci], '/**')
						&& StringTools.startsWith(_t.leadingComments[_ci - 1], '//')) {
					var _isLastDoc:Bool = true;
					var _ldi:Int = _ci + 1;
					while (_ldi < _t.leadingComments.length) {
						if (StringTools.startsWith(_t.leadingComments[_ldi], '/**')) {
							_isLastDoc = false;
							break;
						}
						_ldi++;
					}
					if (_isLastDoc) _inner.push(_dhl());
				}
			}
			: macro {};
		// ω-block-orphan-trail-blank: opt-in via
		// `@:fmt(blankBeforeOrphanLineCommentTrail)` (sister to the EOF
		// flavor in `triviaEofStarExpr`). When the orphan trail is led by
		// a line-comment `//`, force the extra `_dhl()` blank between the
		// last block member and the trail chain regardless of source-blank
		// capture. Without the flag the gate stays `_trailBB`-driven.
		final extraInnerTrailBlankExpr:Expr = lineCommentTrailBlank
			? macro (_arr.length > 0 && (_trailBB || (_trailLC.length > 0 && StringTools.startsWith(_trailLC[0], '//'))))
			: macro (_trailBB && _arr.length > 0);
		// ω-fileheader-multiline-comments: betweenMultilineComments override
		// for body-internal block-block boundaries — both inside per-element
		// `leadingComments` and inside the body's trailing orphan chain.
		// Mirrors fork's `markMultilineComments` which fires at every
		// block-comment-to-block-comment pair regardless of scope.
		final blockLeadingBetweenExpr:Expr = betweenMultilineCommentsBlanks
			? macro {
				if (_ci + 1 < _t.leadingComments.length
						&& StringTools.startsWith(_t.leadingComments[_ci], '/*')
						&& StringTools.startsWith(_t.leadingComments[_ci + 1], '/*')) {
					var _bbi:Int = 0;
					while (_bbi < opt.betweenMultilineComments) {
						_inner.push(_dhl());
						_bbi++;
					}
				}
			}
			: macro {};
		final blockTrailBetweenExpr:Expr = betweenMultilineCommentsBlanks
			? macro {
				if (_ti + 1 < _trailLC.length
						&& StringTools.startsWith(_trailLC[_ti], '/*')
						&& StringTools.startsWith(_trailLC[_ti + 1], '/*')) {
					var _bbi:Int = 0;
					while (_bbi < opt.betweenMultilineComments) {
						_inner.push(_dhl());
						_bbi++;
					}
				}
			}
			: macro {};
		// ω-blockended-trivia (Session 3): between-element sep emission in
		// block-mode trivia Star. Sep emitted BEFORE the per-iter hardline
		// so the output is `<priorElem>;<\n><indent><currElem>` when the
		// prior element wasn't already statement-terminated. Null sepText /
		// non-blockEnded → no-op (byte-identical to pre-slice).
		//
		// ω-phase-g (Session 4): source-fidelity OR `_arr[_si - 1].sepAfter`.
		// Trust the parser: if it consumed a sep after the prior element,
		// preserve it on output even when the prior already ends with `}`
		// (covers source like `if (c) {body}; foo();` where author wrote
		// the redundant `;` after the brace). The `endsWithStmtTerminator`
		// arm stays as a safety net for raw/programmatic AST inputs whose
		// `Trivial<T>` defaults leave `sepAfter=false` even when the source
		// shape demands a sep. NOTE: `endsWithStmtTerminator` (NOT
		// `endsWithSemi`) here. Migrated stmts (Session 10) reach the
		// between-element path via `sepAfter=true` instead (Star consumed
		// the source `;`), which short-circuits the OR before the doc-check.
		//
		// ω-condcomp-stray-semi (Stage A): AND a `!predicate(prior)` guard
		// onto the byte-fallback arm — a `#if … #end` stmt ends with `d`
		// (byte check misses), but `stmtNoSemi` accepts the `Conditional`
		// shape so the spurious `;` between `#end` and the next stmt is
		// suppressed. The `sepAfter` source-fidelity OR stays in front; the
		// predicate only gates the byte-fallback. `macro false` when no
		// predicate wired → byte-identical to the pre-fix path.
		final priorPredCall:Expr = blockEndedPredCall(macro _arr[_si - 1].node);
		final lastPredCall:Expr = blockEndedPredCall(macro _arr[_arr.length - 1].node);
		final blockSepBeforeHardlineExpr:Expr = (sepText != null && blockEnded)
			? macro {
				if (_si > 0 && _priorElemDoc != null
						&& (_arr[_si - 1].sepAfter
							|| (!anyparse.core.DocMeasure.endsWithStmtTerminator(_priorElemDoc) && !($priorPredCall)))) {
					_inner.push(_dt($v{sepText}));
				}
			}
			: macro {};
		// ω-blockended-trivia-trail-sep (Session 3): after the last element
		// the loop has run, source-trail sep emission. Source had `;`
		// before close iff the LAST element's `sepAfter` is true. Emit
		// `;` to preserve byte-fidelity; suppress only when the last element
		// already ends with `;` (inner `@:trail(';')` baked it in) — `}`
		// alone no longer suppresses (see `blockSepBeforeHardlineExpr`).
		final blockTrailSepEmitExpr:Expr = (sepText != null && blockEnded)
			? macro {
				if (_arr.length > 0 && _priorElemDoc != null && _arr[_arr.length - 1].sepAfter
						&& !anyparse.core.DocMeasure.endsWithSemi(_priorElemDoc)
						&& !($lastPredCall)) {
					_inner.push(_dt($v{sepText}));
				}
			}
			: macro {};
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
				else $emptyDocExpr;
			} else {
				final _inner:Array<anyparse.core.Doc> = [];
				$initDocCommentExpr;
				$initCurrDocCommentExpr;
				$initCurrSplitLeadingExpr;
				$initPrevKindExpr;
				// ω-blockended-trivia (Session 3): tracks the prior iteration's
				// rendered element Doc so the between-element sep emission can
				// query `DocMeasure.endsWithStmtTerminator`. Null on the first
				// iteration (no `_si > 0`-gated emit yet). Always declared so
				// the inserted expr is a no-op when sepText is null.
				var _priorElemDoc:Null<anyparse.core.Doc> = null;
				var _si:Int = 0;
				while (_si < _arr.length) {
					final _t = _arr[_si];
					$initCurrKindExpr;
					$blockSepBeforeHardlineExpr;
					_inner.push(_dhl());
					if (_si == 0) $beginTypeExpr;
					$blankBeforeExpr;
					var _ci:Int = 0;
					while (_ci < _t.leadingComments.length) {
						$leadingSplitGateExpr;
						_inner.push(leadingCommentDoc(_t.leadingComments[_ci], opt));
						_inner.push(_dhl());
						$blockLeadingBetweenExpr;
						_ci++;
					}
					if (_t.blankAfterLeadingComments && _t.leadingComments.length > 0) _inner.push(_dhl());
					$trackDocCommentExpr;
					final _elem:anyparse.core.Doc = $triviaElemCall;
					final _tc:Null<String> = _t.trailingComment;
					_inner.push(_tc != null ? foldTrailingIntoBodyGroup(_elem, trailingCommentDocVerbatim(_tc, opt)) : _elem);
					_priorElemDoc = _elem;
					$trackPrevKindExpr;
					_si++;
				}
				// ω-blockended-trivia-trail-sep (Session 3): after the last
				// element, if source had `;` AND prior doesn't already
				// terminate (covers `}` block-close and `;` from inner
				// `@:trail(';')`), emit `;` so source-fidelity is preserved.
				// Without this, `{ stmt1; stmt2; }` round-trips as
				// `{ stmt1; stmt2 }` (valid Haxe but byte-diff).
				$blockTrailSepEmitExpr;
				if (_trailLC.length > 0) {
					_inner.push(_dhl());
					if ($extraInnerTrailBlankExpr) _inner.push(_dhl());
					var _ti:Int = 0;
					while (_ti < _trailLC.length) {
						_inner.push(leadingCommentDoc(_trailLC[_ti], opt));
						if (_ti < _trailLC.length - 1) _inner.push(_dhl());
						$blockTrailBetweenExpr;
						_ti++;
					}
				} else $endTypeExpr;
				final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
				final _innerWrap:anyparse.core.Doc = $innerWrapExpr;
				final _parts:Array<anyparse.core.Doc> = [_dt($v{openText})];
				if (_trailOpen != null) _parts.push(trailingCommentDocVerbatim(_trailOpen, opt));
				_parts.push(_innerWrap);
				_parts.push($beforeCloseHardlineExpr);
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
				//
				// ω-force-flat-engine sister-coverage: block-style trivia
				// hand-rolls `_dbg(_dc(_parts))` and sits under wrap-cascade
				// parents (e.g. function bodies inside NoWrap call args).
				// `_dwb` matches the trivia-sep sister fix at 6491 — no-op
				// outside Flatten frame, opt-out boundary inside one so a
				// nested wrap-engine reads its own independent layout.
				_dwb(_dbg(_dc(_parts)));
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
		rightCurlyKnob:Null<String> = null,
		trailPresentAccess:Null<Expr> = null, trailingCommaField:Null<String> = null,
		openInsideExpr:Null<Expr> = null, closeInsideExpr:Null<Expr> = null,
		beforeDocCommentEmptyLines:Bool = false,
		forceMultiInTypedef:Bool = false,
		bodyAwareCompactIndent:Bool = false,
		groupRestProbe:Bool = false,
		ignoreSourceNewlinesForWrap:Bool = false,
		keepCurlyBlanks:Bool = false,
		reflowSourceMultiline:Bool = false,
		bracketKindPad:Bool = false,
		matrixWrap:Bool = false,
		// ω-keep-fnsig-newline: accessor for the close-newline slot
		// (`value.<field>TrailingNewlineBefore`). Threaded only by callers that
		// pass it; null for every other call site → the keep close placement
		// degrades to the legacy own-line close (byte-inert).
		trailNLAccess:Null<Expr> = null
	):Expr {
		// ω-trivia-sep-anontype-braces (Phase B1): when the call site
		// reads `@:fmt(anonTypeBracesOpen)` / `objectLiteralBracesOpen`
		// via `delimInsidePolicySpace` and threads the resulting Doc
		// expression here, the wrap-rules branch wires it into
		// `WrapList.emit` (parity with the non-trivia path's
		// `delimInsidePolicySpace` plumbing). Null fall-through keeps
		// `_de()` — backward-compatible for callers that don't have the
		// knobs (e.g. `HxExpr.ArrayExpr.elems`).
		//
		// ω-bracket-config: `@:fmt(bracketKindPad)` (`HxExpr.ArrayExpr`)
		// supersedes the static path — the inside-space depends on the
		// first element's bracket kind, decided at runtime. Both override
		// Docs reference `_arr[0].node`, which is safe everywhere they are
		// spliced: the empty-`[]` form short-circuits before any emit that
		// uses them (`_arr.length == 0` guard near the function tail and
		// `WrapList.emit`'s own `items.length == 0` guard).
		final openInsideDoc:Expr = bracketKindPad
			? arrayBracketInsidePolicySpace(macro _arr[0].node, false)
			: (openInsideExpr ?? macro _de());
		final closeInsideDoc:Expr = bracketKindPad
			? arrayBracketInsidePolicySpace(macro _arr[0].node, true)
			: (closeInsideExpr ?? macro _de());
		// ω-bropen-keep-sep: opt-in via `@:fmt(keepCurlyBlanks)` on a
		// sep-Star (currently `HxType.Anon.fields`). Sister to the block-
		// Star path's ω-bropen-keep at `triviaBlockStarExpr` (which
		// channels through `emitBeginExtras = beginEndType || keepCurly-
		// Blanks` and the shared `beginTypeExpr` / `endTypeExpr` blocks).
		// The sep-Star's existing `_inner` per-iter leading `_dhl()` (or
		// `blankBeforeExpr` for `_si > 0`) doesn't fire for the open-side
		// blank because `blankBeforeExpr` is gated on `_si > 0`. Push one
		// extra `_dhl()` at the head of `_inner` when source had a blank
		// between `{` and the first element AND the runtime opted into
		// Keep. Symmetric end-side push before `_trailLC` handling. Other
		// sep-Star consumers default `keepCurlyBlanks=false` → both pushes
		// are `macro {}` and the helper stays byte-identical for them.
		final keepCurlyBeginExpr:Expr = keepCurlyBlanks
			? macro {
				if (opt.afterLeftCurly == anyparse.format.KeepEmptyLinesPolicy.Keep
						&& _arr.length > 0 && _arr[0].blankBefore)
					_inner.push(_dhl());
			}
			: macro {};
		final keepCurlyEndExpr:Expr = keepCurlyBlanks
			? macro {
				if (opt.beforeRightCurly == anyparse.format.KeepEmptyLinesPolicy.Keep
						&& _trailBB && _arr.length > 0)
					_inner.push(_dhl());
			}
			: macro {};
		// ω-trivia-sep-doc-comment-cascade (Phase B2): mirror the
		// `_currHasDocComment` / `addByCurrDocExpr` machinery from
		// `triviaBlockStarExpr` so sep-Stars (e.g. `HxType.Anon.fields`
		// in trivia mode) honour the `beforeDocCommentEmptyLines` policy
		// at inter-element slots. Compile-time gate keeps callers without
		// the flag (`HxExpr.ArrayExpr.elems`, `HxObjectLit.fields`)
		// byte-identical to pre-slice behaviour.
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
		final initCurrDocCommentExpr:Expr = beforeDocCommentEmptyLines
			? macro var _currHasDocComment:Bool = false
			: macro {};
		final blankBeforeExpr:Expr = beforeDocCommentEmptyLines ? macro {
			$currHasDocComputeExpr;
			final _stripBlank:Bool = $stripByCurrDocExpr;
			final _addBlank:Bool = $addByCurrDocExpr;
			final _sourceBlank:Bool = _t.blankBefore && !_stripBlank;
			if (_si > 0 && (_sourceBlank || _addBlank)) _inner.push(_dhl());
		} : macro {
			if (_t.blankBefore && _si > 0) _inner.push(_dhl());
		};
		// ω-typedef-anon-force-multi: when the Star carries
		// `@:fmt(forceMultiInTypedef)`, the outermost typedef-RHS anon
		// has flipped `opt._inTypedefBody=true` via the parent Ref's
		// `propagateTypedefContext`. Per-element writer calls must
		// CLEAR the flag before recursing so a nested anon
		// (`typedef T = {a:{b:Int}}` — inner `{b:Int}`) reverts to
		// default fit-driven wrap. Sister to `_clearAnonFnBody` on the
		// block-Star path.
		final elemOptArg:Expr = forceMultiInTypedef
			? macro _clearTypedefBody(opt)
			: macro opt;
		final triviaElemCall:Expr = {
			expr: ECall(macro $i{elemFn}, [macro _t.node, elemOptArg]),
			pos: Context.currentPos(),
		};
		final emptyText:String = openText + closeText;
		final trailBB:Expr = trailBBAccess ?? macro false;
		// ω-keep-fnsig-newline: close-newline splice (`value.<field>Trailing
		// NewlineBefore`), null for non-bearing callers → defaults to `false`.
		final trailNL:Expr = trailNLAccess ?? macro false;
		final trailLC:Expr = trailLCAccess ?? macro ([] : Array<String>);
		final trailClose:Expr = trailCloseAccess ?? macro (null : Null<String>);
		final trailOpen:Expr = trailOpenAccess ?? macro (null : Null<String>);
		final emptyTrailExpr:Expr = macro _dc([_dt($v{emptyText}), trailingCommentDocVerbatim(_trailClose, opt)]);
		// ω-keep-objectlit: when the Star carries
		// `@:fmt(wrapRules('<rulesField>'))` AND the runtime config sets
		// `opt.<rulesField>.defaultMode == WrapMode.Keep`, the trivia
		// branch's per-element loop swaps the unconditional leading
		// `_dhl()` for a per-element source-aware decision (hardline if
		// `Trivial<T>.newlineBefore`, space if glued). Mirrors fork's
		// `MarkWrappingBase.keep2` per-token `isOriginalNewlineBefore`
		// dispatch. `_keepEmit=false` (default — null `wrapRulesField`
		// OR rules' defaultMode != Keep OR any comment forces hardline)
		// preserves the legacy force-multi shape byte-identically.
		//
		// JSON-driven: the loader maps `"defaultWrap": "keep"` → `Keep`;
		// `BinaryChainEmit` and `MethodChainEmit` route `Keep` to their
		// `shapeNoWrap` arms to preserve baseline for chain-config Keep
		// cases (e.g. `issue_187_multi_line_wrapped_assignment_oneline`)
		// where the JSON-config Keep slipped past loader's silent-drop
		// previously. Real chain-Keep semantics is a follow-up slice.
		// ω-keep-fnsig-newline: detect Keep from the FULL cascade, not just
		// `defaultMode`. A function-signature keep config can select Keep via
		// either `defaultWrap: keep` (→ `defaultMode == Keep`, e.g.
		// `issue_238_keep_wrapping_function_signature`) OR a width-independent
		// cascade rule (`itemCount >= 0 -> keep`, e.g.
		// `wrapping_of_function_signature_keep`). `cascadeIsKeep` resolves the
		// cascade for the runtime element count across both fit/exceed states
		// and returns true only when EVERY state yields Keep — equivalent to
		// the bare `defaultMode == Keep` read for the `rules: []` case, and
		// additively true for the always-firing structural rule. Width-gated
		// keep rules (`lineLength >= n`) disagree across states → false, so the
		// trivia path stays on the legacy cascade for them.
		final keepCheckExpr:Expr = wrapRulesField != null
			? {
				final rulesAccess:Expr = optFieldAccess(wrapRulesField);
				macro anyparse.format.wrap.WrapList.cascadeIsKeep($rulesAccess, _arr.length);
			}
			: macro false;
		// ω-cascade-emits-comments: Ignore-mode runtime check, sister to
		// `keepCheckExpr`. Fires when the wrap-rules JSON config sets
		// `"defaultWrap": "ignore"` (case-2, user-driven) OR the grammar
		// annotation `@:fmt(ignoreSourceNewlinesForWrap)` is set (case-1,
		// intrinsic per-construct semantic — currently `HxFnDecl.params`).
		// Architecture per [[feedback-grammar-annotation-keep-too-aggressive]]:
		// intrinsic flags + JSON checks are disjoined here, no separate
		// override channel.
		final ignoreCheckExpr:Expr = ignoreSourceNewlinesForWrap
			? macro true
			: (wrapRulesField != null
				? {
					final rulesAccess:Expr = optFieldAccess(wrapRulesField);
					macro $rulesAccess.defaultMode == anyparse.format.wrap.WrapMode.Ignore;
				}
				: macro false);
		// ω-nowrap-flat: pure-`noWrap` runtime check, sister to
		// `keepCheckExpr` / `ignoreCheckExpr`. Fires only when the
		// wrap-rules JSON config selects `"defaultWrap": "noWrap"` with an
		// EMPTY rule cascade (`{rules: [], defaultMode: NoWrap}` — the shape
		// the loader builds for a user `arrayWrap.defaultWrap: noWrap` block,
		// see `Loader.wrapRulesFromConfig`). This is the fork's `noWrap()`
		// policy (`MarkWrappingBase.noWrap` → `noWrappingBetween`): every
		// element cuddles flat, and the ONLY break is the unsuppressible
		// `lineEndAfter` a `//` line-comment forces. Distinct from the
		// built-in `defaultArrayLiteralWrap` cascade (non-empty `rules`), so
		// the gate stays false for the default config → byte-inert there.
		// Used to (a) defeat the `reflowSourceMultiline` floor so a
		// source-multiline list collapses fully flat under explicit noWrap,
		// and (b) swap the force-multi per-element hardline for a space
		// (break only after a line-comment) when a mid-list `//` forced the
		// list into the trivia branch.
		final noWrapFlatCheckExpr:Expr = wrapRulesField != null
			? {
				final rulesAccess:Expr = optFieldAccess(wrapRulesField);
				macro $rulesAccess.defaultMode == anyparse.format.wrap.WrapMode.NoWrap
					&& $rulesAccess.rules.length == 0;
			}
			: macro false;
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
			: optFieldAccess(leftCurlyKnob);
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
		// ω-anontype-right-curly: when the call site reads
		// `@:fmt(rightCurly('<knob>'))`, build a Doc that picks `_de()`
		// for `RightCurlyPlacement.Inline` (close glued to last body
		// token) and `_dhl()` otherwise. Null knob → unconditional
		// `_dhl()` (legacy). Substituted for the unconditional `_dhl()`
		// emitted immediately before `_dt(closeText)` in the trivia
		// branch. The wrap-engine branch reads the same expression
		// through `WrapList.emit`'s `trailBreak` param (slice
		// ω-wraplist-trailbreakdoc) — both branches honour the same
		// `RightCurlyPlacement.{Inline,Same}` semantic.
		final rightCurlyKnobExpr:Null<Expr> = rightCurlyKnob == null
			? null
			: optFieldAccess(rightCurlyKnob);
		final inlinePat:Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'RightCurlyPlacement', 'Inline']);
		final triviaTrailDoc:Expr = rightCurlyKnobExpr == null
			? macro _dhl()
			: {
				expr: ESwitch(rightCurlyKnobExpr, [{values: [inlinePat], expr: macro _de(), guard: null}], macro _dhl()),
				pos: Context.currentPos(),
			};
		// ω-wraplist-trailbreakdoc: wrap-engine close placement reads
		// the same knob as the trivia branch's `triviaTrailDoc`.
		// `WrapList.shapeOnePerLine` substitutes the result for the
		// hardcoded `Line('\n')` before `Text(close)` — `_de()` glues
		// the close to the last body token (Inline), `_dhl()` keeps
		// it on its own line (Same).
		final wrapTrailBreakDoc:Expr = triviaTrailDoc;
		// ω-keep-fnsig-newline: close-delimiter placement for the trivia
		// force-multi KEEP path. Function signatures (the only Star carrying
		// `@:fmt(ignoreSourceNewlinesForWrap)`) preserve the SOURCE close
		// placement under keep: the close `)` stays glued to the last
		// parameter (`param7:Int)` — `wrapping_of_function_signature_keep`) when
		// the source had no newline before it, but drops to its own indented
		// line (`\n\t):FastMatrix3` — `issue_238_keep_wrapping_function_signature`)
		// when the author put one there. `_trailNL` carries that source signal
		// (captured at the Star's close-peek into the `TrailingNewlineBefore`
		// slot). When `_keepEmit` is live: `_dhl()` if the source broke before
		// close, `_de()` (glued) otherwise. Object-literals / arrays (no
		// intrinsic flag) keep their own-line close unchanged, and non-keep
		// params (`_keepEmit == false`) stay on the legacy break — both byte-
		// inert. Only consumed at the trivia branch's `_parts` assembly; the
		// no-trivia cascade reads `wrapTrailBreakDoc`.
		final triviaTrailDocKeepAware:Expr = ignoreSourceNewlinesForWrap
			? macro(_keepEmit ? (_trailNL ? _dhl() : _de()) : $triviaTrailDoc)
			: triviaTrailDoc;
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
			: optFieldAccess(trailingCommaField);
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
		// ω-arraymatrix-keep: matrix-align takes precedence over the Keep
		// cascade. The non-Keep matrix attempt (`matrixComputeExpr`, in the
		// no-trivia/cascade branch) is gated `!_keepEmit` and so never fires
		// under a `"defaultWrap": "keep"` array — a kept matrix lands in the
		// force-multi path, which preserves the source rows but emits no
		// column padding. The fork runs `tryMatrixWrap` BEFORE
		// `applyWrappingPlace` inside `arrayLiteralWrapping`, so matrix grid
		// layout wins over the array's keep/noWrap rules; this expr mirrors
		// that for the Keep case. Computed at the outer Star scope (the
		// no-trivia branch's `_matrixDoc` is unreachable under Keep) and
		// gated on `_keepEmit` + the same source-multiline-without-hardline
		// condition the non-Keep path uses (`!_requiresHardline`,
		// `_hasSourceNewlines`). The matrix detector reads per-element
		// `newlineBefore` (row boundaries) and the bare rendered cell Docs;
		// on a uniform grid it returns the aligned/unaligned Doc, else null
		// → fall through to force-multi. Cells under `!_requiresHardline`
		// carry no comments (any leading/trailing comment forces a hardline
		// under Keep, see the predicate split below), so the bare
		// `$triviaElemCall` render matches the no-trivia branch's `_docs`
		// exactly. Only meaningful when the Star opted into
		// `@:fmt(arrayMatrixWrap)` (`matrixWrap` compile-time flag); every
		// other sep-Star consumer leaves it `macro null` and stays byte-
		// identical.
		final keepMatrixComputeExpr:Expr = matrixWrap ? macro {
			if (_keepEmit && !_requiresHardline && _hasSourceNewlines
					&& opt.arrayMatrixWrap != anyparse.format.ArrayMatrixWrap.NoMatrixWrap) {
				final _kdocs:Array<anyparse.core.Doc> = [];
				final _krow:Array<Bool> = [];
				var _kmi:Int = 0;
				while (_kmi < _arr.length) {
					final _t = _arr[_kmi];
					_kdocs.push($triviaElemCall);
					_krow.push(_kmi == 0 || _t.newlineBefore);
					_kmi++;
				}
				final _kmcols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
				anyparse.format.wrap.MatrixWrap.tryLayout(
					_kdocs, _krow, opt.arrayMatrixWrap,
					$v{openText}, $v{closeText}, $v{sepText}, $appendTrailingCommaExpr, _kmcols
				);
			} else {
				(null : Null<anyparse.core.Doc>);
			}
		} : macro (null : Null<anyparse.core.Doc>);
		// ω-typedef-anon-force-multi: 15th positional arg to
		// `WrapList.emit` — a runtime `Null<WrapMode>` predicate. When
		// the Star opted into `@:fmt(forceMultiInTypedef)` AND the
		// parent typedef-RHS Ref flipped `opt._inTypedefBody=true` via
		// `propagateTypedefContext` AND `opt.anonTypeLeftCurly == Next`,
		// the engine bypasses the cascade and lays out the body
		// `OnePerLine` unconditionally — closes the issue_301 typedef-
		// anon source-flat → fork-multi-line shape gap deferred in
		// ω-anontype-left-curly. The leftCurly==Next gate mirrors fork's
		// `MarkLineEnds.detectCurlyPolicy(TypedefDecl)` rule: the
		// curly-break-driven multi-line layout fires only when the
		// global `lineEnds.leftCurly` ↔ our `anonTypeLeftCurly` cascade
		// hits `before`/`both` (= Next). For the default `after` (= Same)
		// flat typedef-RHS anons stay cuddled, matching issue_586 /
		// issue_206 / issue_588 (which leave `typedef T = {a:Int}` /
		// `typedef T = {…}->Void` / `typedef T = Array<{k:Int}>` flat).
		// Null fall-through preserves pre-slice cascade-driven layout
		// for non-typedef anon consumers (var-type-hint, fn-return-type).
		// ω-typedef-anon-force-multi: 15th positional arg to
		// `WrapList.emit` — a runtime `Null<WrapMode>` predicate. When
		// the Star opted into `@:fmt(forceMultiInTypedef)` AND the
		// parent typedef-RHS Ref flipped `opt._inTypedefBody=true` via
		// `propagateTypedefContext` AND `opt.anonTypeLeftCurly == Next`,
		// the engine bypasses the cascade and lays out the body
		// `OnePerLine` unconditionally — closes the issue_301 typedef-
		// anon source-flat → fork-multi-line shape gap deferred in
		// ω-anontype-left-curly. The leftCurly==Next gate mirrors fork's
		// `MarkLineEnds.detectCurlyPolicy(TypedefDecl)` rule.
		final forceModeExpr:Expr = forceMultiInTypedef
			? macro (opt._inTypedefBody && opt.anonTypeLeftCurly == anyparse.format.BracePlacement.Next
				? anyparse.format.wrap.WrapMode.OnePerLine
				: (null : Null<anyparse.format.wrap.WrapMode>))
			: macro (null : Null<anyparse.format.wrap.WrapMode>);
		final noTriviaBranch:Expr = if (wrapRulesField != null) {
			final rulesExpr:Expr = optFieldAccess(wrapRulesField);
			// ω-functionsignature-body-aware-indent: thread the field-level
			// `@:fmt(bodyAwareCompactIndent)` opt-in into `WrapList.emit`'s
			// 16th `compactContinuation` param. Reads `opt._fnSigBodyEmpty`
			// at runtime — true only inside HxFnDecl's struct-emit span
			// where `@:fmt(propagateFnBodyEmpty('body'))` flips the flag.
			// Other sep-Star consumers (HxType.Anon.fields,
			// HxObjectLit.fields, etc.) leave the flag clear and pass
			// `macro false`, keeping the engine byte-identical to pre-slice
			// for non-opt-in sites.
			final compactContExpr:Expr = bodyAwareCompactIndent ? (macro opt._fnSigBodyEmpty) : (macro false);
			// ω-arraymatrix-wrap: when the Star opted into
			// `@:fmt(arrayMatrixWrap)` (currently `HxExpr.ArrayExpr`) and the
			// runtime policy preserves the source grid, attempt a one-pass
			// grid layout BEFORE the wrap cascade. The matrix detector reads
			// per-element `newlineBefore` (row boundaries) and the rendered
			// cell widths; on a uniform matrix (>=2 columns, equal rows, no
			// multi-line cell) it returns the aligned/unaligned grid Doc,
			// which is wrapped in BodyGroup (sister to the `_smlKeep` path)
			// so an enclosing Group's `fitsFlat` defers the grid's hardlines
			// and the call/assign context stays inline. `tryLayout` returns
			// null for non-matrix shapes → fall through to the cascade.
			// Gated on the same source-multiline-without-blocking-trivia
			// condition as `_smlKeep`; only fires when `matrixWrap` is set,
			// so every other sep-Star consumer is byte-identical (`macro {}`).
			final matrixComputeExpr:Expr = matrixWrap ? macro {
				if (opt.arrayMatrixWrap != anyparse.format.ArrayMatrixWrap.NoMatrixWrap
						&& _hasSourceNewlines && !_requiresHardline && !_keepEmit && !_ignoreEmit) {
					final _rowStart:Array<Bool> = [for (_mi in 0..._arr.length) _mi == 0 || _arr[_mi].newlineBefore];
					final _mcols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
					_matrixDoc = anyparse.format.wrap.MatrixWrap.tryLayout(
						_docs, _rowStart, opt.arrayMatrixWrap,
						$v{openText}, $v{closeText}, $v{sepText}, $appendTrailingCommaExpr, _mcols
					);
				}
			} : macro {};
			// ω-cascade-emits-comments: wrap each per-element Doc with its
			// leading comments (each followed by a hardline) and an inline
			// block-style trailing comment (line-style trailings are not
			// cascade-emittable — the engine inserts the separator AFTER
			// the item, which would land INSIDE a `// ...` line comment;
			// those route to the force-multi branch via `_requiresHardline`
			// in the predicate split below). When the element has no
			// trivia (the only case reached pre-slice), `_parts.length==1`
			// collapses to the bare `_elemBase` Doc — byte-identical to
			// the previous `_docs.push($triviaElemCall)` shape.
			macro {
				final _docs:Array<anyparse.core.Doc> = [];
				// Slice 18g: per-pair `sepBefore` flags so `WrapList.emit`
				// can suppress the engine's inter-element comma when the
				// source elided it (canonical: `HxParam.Conditional` body
				// leading-sep elides the outer `,` ahead of the `#if`).
				// `_sepBeforeFlags[i] = !_arr[i-1].sepAfter` for i >= 1;
				// slot 0 is unused. Trailing-comma stays on the existing
				// `appendTrailingComma` axis. Closes whitespace/issue_582.
				final _sepBeforeFlags:Array<Bool> = [];
				var _si2:Int = 0;
				while (_si2 < _arr.length) {
					final _t = _arr[_si2];
					_sepBeforeFlags.push(_si2 == 0 ? false : !_arr[_si2 - 1].sepAfter);
					final _elemBase:anyparse.core.Doc = $triviaElemCall;
					final _parts:Array<anyparse.core.Doc> = [];
					var _ci2:Int = 0;
					while (_ci2 < _t.leadingComments.length) {
						_parts.push(leadingCommentDoc(_t.leadingComments[_ci2], opt));
						_parts.push(_dhl());
						_ci2++;
					}
					_parts.push(_elemBase);
					final _tc2:Null<String> = _t.trailingComment;
					if (_tc2 != null && StringTools.startsWith(_tc2, '/*'))
						_parts.push(trailingCommentDocVerbatim(_tc2, opt));
					_docs.push(_parts.length == 1 ? _parts[0] : _dc(_parts));
					_si2++;
				}
				// ω-arraymatrix-wrap: grid layout attempt before the cascade.
				// `_matrixDoc` stays null for non-matrix shapes (or when the
				// flag is off — `matrixComputeExpr` is then `macro {}`), so the
				// trailing expression falls through to the wrap cascade.
				var _matrixDoc:Null<anyparse.core.Doc> = null;
				$matrixComputeExpr;
				final _wlResult:anyparse.core.Doc = anyparse.format.wrap.WrapList.emit(
					$v{openText}, $v{closeText}, $v{sepText},
					_docs, opt, $openInsideDoc, $closeInsideDoc, false, $rulesExpr, $appendTrailingCommaExpr,
					$wrapLeadFlatDoc, $wrapLeadBreakDoc, $forceExceedsExpr, $wrapTrailBreakDoc, $forceModeExpr, $compactContExpr, $v{groupRestProbe}, _sepBeforeFlags, _smlKeep
				);
				// ω-array-reflow: a source-multiline list re-flowed through the
				// cascade carries internal hardlines but lacks the BodyGroup
				// wrapper the force-multi path (`_dwb(_dbg(...))`) applies.
				// Without BodyGroup, an enclosing call-arg `Group.fitsFlat`
				// SEES the list's hardline (BodyGroup is deferred from fitsFlat,
				// a bare Concat/Nest is not) and commits the call to MBreak —
				// stacking the call's continuation `Nest` on top of the list's
				// own `Nest` (+1 indent) and, for a trailing-arg list, breaking
				// the arg onto its own line. Wrapping the re-flowed list in
				// BodyGroup defers its hardline exactly like force-multi: the
				// call stays MFlat (no continuation-Nest bump) and the list's
				// internal break decides independently at the call's flat
				// indent. Only fires under `_smlKeep`; every other consumer
				// keeps the bare cascade Doc.
				_matrixDoc != null ? _dbg(_matrixDoc) : (_smlKeep ? _dbg(_wlResult) : _wlResult);
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
			// ω-keep-fnsig-newline: source newline-before-close signal,
			// consumed by `triviaTrailDocKeepAware` under `_keepEmit`.
			final _trailNL:Bool = $trailNL;
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
				// ω-keep-predicate-split + ω-cascade-emits-comments: decompose
				// `_hasTrivia` into three orthogonal predicates so the
				// Ignore-mode cascade can ingest per-element block comments
				// and the Keep emit path can stay gated on physical hardline
				// requirements alone.
				//
				//  - `_requiresHardline` — physical hardline requirement:
				//    `_trailLC`/`_trailOpen` on the open/close boundary, any
				//    blank line before an element, leading comments (when
				//    NOT in ignore mode), and trailing LINE comments (any
				//    mode — engine inserts the sep AFTER the item, which
				//    would land inside `// ...`). Anything in this bucket
				//    MUST route through the force-multi branch.
				//  - `_hasSourceNewlines` — bare `newlineBefore=true` on at
				//    least one element. Independent axis. Under
				//    `_ignoreEmit` this signal is DROPPED (fork's `Ignore`
				//    policy ignores source newlines and lets width drive
				//    layout); legacy default still flips `_hasTrivia=true`.
				//  - `_hasInlineableTrivia` — at least one element carries a
				//    leading comment OR a block-style trailing comment, AND
				//    `_ignoreEmit` is live. These are cascade-emittable: the
				//    no-trivia branch wraps each item Doc with its leading
				//    comments + inline block trailing before passing to
				//    `WrapList.emit`. Routes the item to cascade (not
				//    force-multi) when no `_requiresHardline` blocker fires.
				//
				// Byte-identity for `_ignoreEmit=false`: comments still set
				// `_requiresHardline=true` (legacy bucket); cascade rewrite
				// at the no-trivia branch collapses to `_docs.push(_elem)`
				// because `_parts.length==1` on no-comment elements.
				// ω-keep-fnsig-newline: `_keepEmit` is read FIRST so the
				// `_ignoreEmit` gate below can yield to it. The only Star
				// carrying the intrinsic `@:fmt(ignoreSourceNewlinesForWrap)`
				// flag (so `ignoreCheckExpr == macro true`) is `HxFnDecl.params`;
				// it ALSO reads `wrapRules('functionSignatureWrap')`. When the
				// JSON config sets that rule to `keep`, the author opted into
				// source-newline preservation explicitly, so Keep must win over
				// the per-construct Ignore default. For every JSON-config consumer
				// `defaultMode` is a single value — Keep and Ignore are mutually
				// exclusive — so `!_keepEmit` only ever flips the params-in-Keep
				// case; all other Stars (Ignore-mode object-literals / arrays,
				// default-mode params) keep the prior `_ignoreEmit` value byte-
				// for-byte. The force-multi per-element swap further below reads
				// this same `_keepEmit` for the source-`newlineBefore` dispatch.
				final _keepEmit:Bool = $keepCheckExpr;
				final _ignoreEmit:Bool = $ignoreCheckExpr && !_keepEmit;
				// ω-nowrap-flat: pure-`noWrap` config (empty cascade) — yields
				// to Keep/Ignore (mutually exclusive `defaultMode`s, so this
				// only ever flips for an actual NoWrap config). Scoped to the
				// ARRAY-LITERAL Star via the `reflowSourceMultiline` compile
				// flag (the only Star carrying it). The fork flattens noWrap
				// arrays (`arrayLiteralWrapping` → `applyWrappingPlace`) but
				// does NOT flatten a source-multiline OBJECT literal under
				// noWrap — `objectLiteralWrapping` force-one-per-lines any
				// `!isOriginalSameLine` body BEFORE consulting the rule. Object
				// literals (no `reflowSourceMultiline`) therefore keep their
				// legacy source-multiline force-multi shape. Drives the fork's
				// `noWrap()` flat-with-comment-break layout below.
				final _noWrapFlat:Bool = $v{reflowSourceMultiline}
					&& $noWrapFlatCheckExpr && !_keepEmit && !_ignoreEmit;
				// ω-arraymatrix-wrap: `NoMatrixWrap` ignores the source grid
				// entirely — like the `Ignore` policy it DROPS source newlines
				// so the cascade (not the force-multi path) drives layout: a
				// short matrix-shaped array collapses flat, a wide one width-
				// packs. Only meaningful on a matrix-eligible Star (`matrixWrap`
				// compile-time flag); every other consumer leaves it false.
				final _matrixOff:Bool = $v{matrixWrap}
					&& opt.arrayMatrixWrap == anyparse.format.ArrayMatrixWrap.NoMatrixWrap;
				var _requiresHardline:Bool = _trailLC.length > 0 || _trailOpen != null;
				var _hasSourceNewlines:Bool = false;
				var _hasInlineableTrivia:Bool = false;
				// ω-nowrap-flat: the noWrap-flatten path applies only to a plain
				// element list. Two kinds of item make a list NON-flattenable,
				// mirroring the fork (`MarkWrapping.arrayLiteralWrapping`):
				//  - a `for`/`while` ARRAY-COMPREHENSION item: the fork returns
				//    early from `arrayLiteralWrapping` when the first item is
				//    `Kwd(KwdFor)`/`Kwd(KwdWhile)` under `comprehensionFor: keep`,
				//    leaving the comprehension's layout to the sameLine/forBody
				//    policy — so the noWrap arrayWrap rule never touches it.
				//  - an item that renders with its own forced hardline (block
				//    body, etc.): cannot be cuddled flat (the inner construct
				//    keeps its mandatory breaks). Probed via
				//    `WrapList.flatLength(item) < 0`, the same "has forced
				//    hardline" signal the cascade's `HasMultilineItems` uses.
				// Both flow into `_anyMultilineItem`, which gates the flatten
				// off → such lists keep the legacy `_smlKeep`/force-multi shape.
				// Only computed under `_noWrapFlat` (every other path leaves it
				// false → no extra per-element render / reflection).
				var _anyMultilineItem:Bool = false;
				var _ti:Int = 0;
				while (_ti < _arr.length) {
					final _t = _arr[_ti];
					if (_t.blankBefore) _requiresHardline = true;
					if (_t.leadingComments.length > 0) {
						if (_ignoreEmit) _hasInlineableTrivia = true;
						else _requiresHardline = true;
					}
					final _tcSig:Null<String> = _t.trailingComment;
					if (_tcSig != null) {
						if (_ignoreEmit && StringTools.startsWith(_tcSig, '/*'))
							_hasInlineableTrivia = true;
						else
							_requiresHardline = true;
					}
					if (_t.newlineBefore && !_ignoreEmit && !_matrixOff)
						_hasSourceNewlines = true;
					if (_noWrapFlat) {
						// `Type.enumConstructor` returns null for a non-enum
						// payload (e.g. an object-literal field struct) — the
						// `==` comparisons then simply miss. Typed `Null<String>`
						// so the null path is explicit.
						final _itemCtor:Null<String> = Type.enumConstructor(cast _t.node);
						if (_itemCtor == 'ForExpr' || _itemCtor == 'WhileExpr'
								|| anyparse.format.wrap.WrapList.flatLength($triviaElemCall) < 0)
							_anyMultilineItem = true;
					}
					_ti++;
				}
				final _hasTrivia:Bool = _requiresHardline || _hasSourceNewlines;
				// ω-nowrap-flat: matrix grid wins over noWrap-flatten, mirroring
				// the fork (`arrayLiteralWrapping` calls `tryMatrixWrap` BEFORE
				// `applyWrappingPlace`). Probe whether the source rows form a
				// uniform grid; if so, leave `_noWrapFlatten` off so the array
				// flows to the existing `_smlKeep` / no-trivia matrix path
				// (column-aligned grid). Only computed for a matrix-eligible
				// Star (`matrixWrap`) under noWrap with no comment/blank
				// hardline; every other path leaves it false.
				final _matrixSucceeds:Bool = if ($v{matrixWrap} && _noWrapFlat && !_anyMultilineItem
						&& !_requiresHardline
						&& opt.arrayMatrixWrap != anyparse.format.ArrayMatrixWrap.NoMatrixWrap) {
					final _pdocs:Array<anyparse.core.Doc> = [];
					final _prow:Array<Bool> = [];
					var _pi:Int = 0;
					while (_pi < _arr.length) {
						final _t = _arr[_pi];
						_pdocs.push($triviaElemCall);
						_prow.push(_pi == 0 || _t.newlineBefore);
						_pi++;
					}
					final _pcols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
					anyparse.format.wrap.MatrixWrap.tryLayout(
						_pdocs, _prow, opt.arrayMatrixWrap,
						$v{openText}, $v{closeText}, $v{sepText}, $appendTrailingCommaExpr, _pcols
					) != null;
				} else false;
				// ω-keep-relax-gate: Keep emit gate. Fires whenever the
				// wrap-rules runtime mode is Keep — comments and blanks no
				// longer block Keep semantics. The force-multi loop below
				// emits leadingComments/trailingComment + blanks per
				// element, and the per-element swap honours source
				// `newlineBefore` for inter-element breaks. Syntactic
				// invariant: a line-trailing `// ...` comment ends the
				// source line, so the next element always carries
				// `newlineBefore=true` and gets `_dhl()` from the swap —
				// no risk of `_dt(' ')` cuddling content after a `//`.
				// The cascade-emits-comments path remains reserved for
				// Ignore mode (`_hasInlineableTrivia` bucket).
				// `_keepEmit` itself is declared above (hoisted so the
				// `_ignoreEmit` gate can yield to it — ω-keep-fnsig-newline).
				// ω-array-reflow: when the Star opted into
				// `@:fmt(reflowSourceMultiline)` AND its only "multi-line"
				// signal is bare source newlines (no hardline-requiring
				// trivia, no Keep / Ignore policy), divert away from the
				// force-multi (one-`_dhl()`-per-element) path and let the
				// wrap cascade re-flow the list. `_smlKeep` gates that
				// diversion; `WrapList.emit`'s `sourceMultilineKeep` floor
				// then guarantees the cascade never collapses such a list
				// fully flat (NoWrap → OnePerLine), so the source's
				// "stay multi-line" intent is honoured while width-driven
				// packing (FillLine / FillLineWithLeadingBreak) applies.
				// Under `NoMatrixWrap` (`_matrixOff`) `_hasSourceNewlines` was
				// already forced false above, so `_smlKeep` collapses here and
				// the cascade drives layout — no extra gate needed.
				// ω-nowrap-flat: under an explicit pure-`noWrap` array config a
				// source-multiline list whose items carry NO intrinsic hardline
				// (`_anyMultilineItem`: a `for`/`while` comprehension or a
				// hardline-bearing item) AND that is not a uniform matrix grid
				// (`_matrixSucceeds`) must collapse to the fork's `noWrap()` flat
				// shape — every element cuddled, the close glued, and the only
				// break the one a `//` line-comment forces. Both the comment
				// case (`_requiresHardline` via a line-comment) and the plain
				// case route through the FORCE-MULTI per-element loop below: its
				// `_noWrapFlatten` branch
				// lays the list out flat AND preserves the source trailing comma
				// (`appendTrailingCommaExpr`) — which the no-trivia cascade's
				// `shapeNoWrap` would have dropped. A comprehension / multi-line
				// item or a matrix-grid array keeps the legacy `_smlKeep` reflow
				// (its layout is owned by another path).
				final _noWrapFlatten:Bool = _noWrapFlat && !_anyMultilineItem && !_matrixSucceeds;
				// ω-nowrap-flat: `_smlKeep` reflow stays ON for a comprehension /
				// multi-line-item / matrix noWrap array — those keep their HEAD
				// source-multiline shape. It is disabled ONLY when the array
				// actually flattens (`_noWrapFlatten`), so the flatten routes
				// through the force-multi flat loop below instead of reflow.
				final _smlKeep:Bool = $v{reflowSourceMultiline}
					&& _hasSourceNewlines && !_requiresHardline
					&& !_keepEmit && !_ignoreEmit && !_noWrapFlatten;
				final _forceMulti:Bool = (_hasTrivia && !_smlKeep) || _noWrapFlatten;
				// ω-arraymatrix-keep: attempt the matrix grid BEFORE the keep
				// force-multi emit. `_keepMatrixDoc` is non-null only for a
				// matrix-eligible Star (`matrixWrap`) under Keep with a
				// uniform source grid; otherwise null → fall through to the
				// existing force-multi / cascade dispatch byte-identically.
				// Wrapped in `_dwb(_dbg(...))` like the force-multi path so a
				// matrix nested inside a force-flat region keeps its indent
				// and an enclosing Group defers the grid's hardlines.
				final _keepMatrixDoc:Null<anyparse.core.Doc> = $keepMatrixComputeExpr;
				if (_keepMatrixDoc != null) {
					_dwb(_dbg(_keepMatrixDoc));
				} else if (_forceMulti) {
					final _inner:Array<anyparse.core.Doc> = [];
					$initCurrDocCommentExpr;
					$keepCurlyBeginExpr;
					var _si:Int = 0;
					while (_si < _arr.length) {
						final _t = _arr[_si];
						// ω-keep-objectlit: per-element source-aware leading break.
						// Keep mode: first element gets hardline only if source
						// had `\n` before it (`newlineBefore=true`) — otherwise
						// glue to open lit. Subsequent elements: hardline on
						// source-newline, space otherwise. Legacy non-Keep path
						// always pushes hardline (force-multi byte-identical).
						if (_keepEmit) {
							if (_si > 0) {
								if (_t.newlineBefore)
									_inner.push(_dhl());
								else
									_inner.push(_dt(' '));
							} else if (_t.newlineBefore) {
								_inner.push(_dhl());
							}
						} else if (_noWrapFlatten) {
							// ω-nowrap-flat: cuddle every element flat (space sep),
							// mirroring the fork's `noWrap()` line-end suppression.
							// The ONLY break is the unsuppressible newline a `//`
							// line-comment forces — emit it on the element that
							// FOLLOWS a line-comment-bearing element (the comment
							// ends its own source line). First element glues to the
							// open delimiter (no leading break). A list with a
							// multi-line item falls through to the legacy `_dhl()`
							// one-per-line shape (its items cannot be cuddled).
							if (_si > 0) {
								final _prevTc:Null<String> = _arr[_si - 1].trailingComment;
								if (_prevTc != null && !StringTools.startsWith(_prevTc, '/*'))
									_inner.push(_dhl());
								else
									_inner.push(_dt(' '));
							}
						} else {
							_inner.push(_dhl());
						}
						$blankBeforeExpr;
						var _ci:Int = 0;
						while (_ci < _t.leadingComments.length) {
							_inner.push(leadingCommentDoc(_t.leadingComments[_ci], opt));
							_inner.push(_dhl());
							_ci++;
						}
						if (_t.blankAfterLeadingComments && _t.leadingComments.length > 0) _inner.push(_dhl());
						final _elem:anyparse.core.Doc = $triviaElemCall;
						var _line:anyparse.core.Doc = _elem;
						// ω-objectlit-source-inter-sep: inter-element comma
						// honours source presence via `_t.sepAfter` (default
						// `true` for non-tracking sites — see Trivial.hx).
						// Trailing-position comma keeps the existing
						// `appendTrailingComma` decision (source-present OR
						// knob, computed by `appendTrailingCommaExpr`).
						// Closes lineends/issue_111 where source had two
						// `field:` slots with no separator between them; we
						// previously emitted the comma unconditionally.
						final _isLast:Bool = _si == _arr.length - 1;
						final _emitSep:Bool = _isLast ? $appendTrailingCommaExpr : _t.sepAfter;
						final _tc:Null<String> = _t.trailingComment;
						// ω-trivia-trailing-before-sep: emit `elem /*c*/, next`
						// instead of `elem, /*c*/ next` when the source captured
						// the trailing comment between the element and the sep.
						// Falls through to the legacy after-sep position for
						// every existing capture site (`trailingBeforeSep:false`
						// default in producer pushes, see Lowering.hx).
						if (_tc != null && _t.trailingBeforeSep)
							_line = _dc([_line, trailingCommentDocVerbatim(_tc, opt)]);
						if (_emitSep)
							_line = _dc([_line, _dt($v{sepText})]);
						if (_tc != null && !_t.trailingBeforeSep)
							_line = _dc([_line, trailingCommentDocVerbatim(_tc, opt)]);
						_inner.push(_line);
						_si++;
					}
					$keepCurlyEndExpr;
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
					// ω-nowrap-flat: glue the close delimiter to the last
					// element (`0]`) — the fork's `noWrap()` calls
					// `noLineEndBefore(close)`. Only when the list actually
					// cuddled flat (`_noWrapFlatten`); otherwise keep the legacy
					// own-line close (`triviaTrailDocKeepAware`).
					_parts.push(_noWrapFlatten ? _de() : $triviaTrailDocKeepAware);
					_parts.push(_dt($v{closeText}));
					if (_trailClose != null)
						_parts.push(trailingCommentDocVerbatim(_trailClose, opt));
					// ω-force-flat-engine slice D follow-up: trivia branch builds
					// hardlined Doc by hand instead of going through one of the 4
					// cascade-emit functions Slice C wraps. Without `_dwb` here a
					// trivia-bearing inner construct nested inside a NoWrap-cascade
					// `Flatten` region loses its source-preserved indent (the
					// hardlines fire but `Nest`'s columns are dropped by force-flat).
					// WrapBoundary is no-op when the parent frame is not in force-flat
					// mode, so this wrap is safe on the non-nested common path.
					_dwb(_dbg(_dc(_parts)));
				} else {
					$noTriviaBranch;
				}
			}
		};
	}

	/**
	 * ω-bug-2c-inner-star — extract the cascade emit machinery shared by
	 * `triviaEofStarExpr` (top-level EOF-terminated Star) and
	 * `triviaTryparseStarExpr` (inner tryparse-terminated Star, e.g.
	 * `HxConditionalDecl.body`). Returns five Exprs ready to splice into
	 * the consumer's runtime block:
	 *
	 *  - `initPrev`   — single EVars statement declaring all `_prev*`
	 *                   trackers (placed once, in the outer scope, before
	 *                   the while loop).
	 *  - `initCurr`   — single EVars statement declaring all `_curr*`
	 *                   trackers (placed inside the while body, before
	 *                   `currCompute`).
	 *  - `currCompute`— single EBlock of assignments computing `_curr*`
	 *                   from `_t.node` classifier values.
	 *  - `trackPrev`  — single EBlock of `_prev* = _curr*` assignments
	 *                   (end of iteration).
	 *  - `blanksCount`— Int-typed cascade ternary, fallback
	 *                   `(_t.blankBefore ? 1 : 0)`. Empty info arrays leave
	 *                   only the fallback, so consumers without cascade
	 *                   metas behave byte-identically (the `(0|1)` count
	 *                   matches the existing `if (blankBefore) push(\\n)`
	 *                   path).
	 *
	 * The emitted Exprs reference runtime locals defined in the consumer's
	 * scope: `_t` (per-iteration `_arr[_si]` binding), `opt` (writer
	 * options parameter), and `_v0` (bound by ctor pattern inside switch
	 * cases — local to each pattern body via `BetweenCtorPattern` /
	 * `TransitionAcrossPattern`).
	 *
	 * Sister to `readCascadeInfosFromStar`, which reads the
	 * `@:fmt(blankLines*)` metas off the Star ShapeNode and produces the
	 * info arrays consumed here. The two helpers together let any Star
	 * emit kind opt in to the cascade machinery without duplicating its
	 * implementation.
	 */
	private static function buildCascadeEmit(
		afterInfos:Array<AfterCtorBlankInfo>,
		beforeInfos:Array<BeforeCtorBlankInfo>,
		betweenInfos:Array<BetweenCtorBlankInfo>,
		transitionInfos:Array<TransitionAcrossInfo>,
		headInfos:Array<HeadCtorBlankInfo>,
		betweenSameIfNotInfos:Array<BetweenSameCtorIfNotInfo> = null
	):CascadeEmit {
		final betweenIfNotInfos:Array<BetweenSameCtorIfNotInfo> = betweenSameIfNotInfos ?? [];
		final pos:Position = Context.currentPos();

		final prevVars:Array<Var> = [];
		final currVars:Array<Var> = [];
		final currCompute:Array<Expr> = [];
		final trackPrev:Array<Expr> = [];

		// After-ctor cascade — single-axis kind tracker per info.
		for (i in 0...afterInfos.length) {
			final info:AfterCtorBlankInfo = afterInfos[i];
			prevVars.push({name: '_prevKindAfter' + i, type: macro:Int, expr: macro 0});
			currVars.push({name: '_currKindAfter' + i, type: macro:Int, expr: macro 0});
			final classifierAccess:Expr = {expr: EField(macro _t.node, info.classifierFieldName), pos: pos};
			final switchExpr:Expr = {expr: ESwitch(classifierAccess, info.classifyCases, null), pos: pos};
			final lhs:Expr = {expr: EConst(CIdent('_currKindAfter' + i)), pos: pos};
			currCompute.push(macro $lhs = $switchExpr);
			final tlhs:Expr = {expr: EConst(CIdent('_prevKindAfter' + i)), pos: pos};
			final trhs:Expr = {expr: EConst(CIdent('_currKindAfter' + i)), pos: pos};
			trackPrev.push(macro $tlhs = $trhs);
		}

		// Before-ctor cascade — same shape as after-ctor, separate idents.
		for (i in 0...beforeInfos.length) {
			final info:BeforeCtorBlankInfo = beforeInfos[i];
			prevVars.push({name: '_prevKindBefore' + i, type: macro:Int, expr: macro 0});
			currVars.push({name: '_currKindBefore' + i, type: macro:Int, expr: macro 0});
			final classifierAccess:Expr = {expr: EField(macro _t.node, info.classifierFieldName), pos: pos};
			final switchExpr:Expr = {expr: ESwitch(classifierAccess, info.classifyCases, null), pos: pos};
			final lhs:Expr = {expr: EConst(CIdent('_currKindBefore' + i)), pos: pos};
			currCompute.push(macro $lhs = $switchExpr);
			final tlhs:Expr = {expr: EConst(CIdent('_prevKindBefore' + i)), pos: pos};
			final trhs:Expr = {expr: EConst(CIdent('_currKindBefore' + i)), pos: pos};
			trackPrev.push(macro $tlhs = $trhs);
			// ω-before-multiline-prev-not — second binary classify-switch on
			// the same classifier field, tracking whether the element matched
			// an excluded-prev ctor (e.g. `Conditional`). Only built when the
			// info carries `prevExcludeCases`; the ternary below adds a
			// `_prevKindPrevExcl != 1` guard so the override is suppressed when
			// the previous sibling was excluded (falls through to source).
			final prevExcludeCases:Null<Array<Case>> = info.prevExcludeCases;
			if (prevExcludeCases != null) {
				prevVars.push({name: '_prevKindPrevExcl' + i, type: macro:Int, expr: macro 0});
				currVars.push({name: '_currKindPrevExcl' + i, type: macro:Int, expr: macro 0});
				final exclSwitch:Expr = {expr: ESwitch(classifierAccess, prevExcludeCases, null), pos: pos};
				final exclLhs:Expr = {expr: EConst(CIdent('_currKindPrevExcl' + i)), pos: pos};
				currCompute.push(macro $exclLhs = $exclSwitch);
				final exclTlhs:Expr = {expr: EConst(CIdent('_prevKindPrevExcl' + i)), pos: pos};
				final exclTrhs:Expr = {expr: EConst(CIdent('_currKindPrevExcl' + i)), pos: pos};
				trackPrev.push(macro $exclTlhs = $exclTrhs);
			}
		}

		// Between-ctor cascade — kind+path trackers, head AND tail axes,
		// transparent-wrapper support via the shared head/tail adapter pair.
		for (i in 0...betweenInfos.length) {
			final info:BetweenCtorBlankInfo = betweenInfos[i];
			prevVars.push({name: '_prevTailKindBetween' + i, type: macro:Int, expr: macro 0});
			prevVars.push({name: '_prevTailPathBetween' + i, type: macro:String, expr: macro ''});
			currVars.push({name: '_currTailKindBetween' + i, type: macro:Int, expr: macro 0});
			currVars.push({name: '_currTailPathBetween' + i, type: macro:String, expr: macro ''});
			currVars.push({name: '_currHeadKindBetween' + i, type: macro:Int, expr: macro 0});
			currVars.push({name: '_currHeadPathBetween' + i, type: macro:String, expr: macro ''});

			final classifierAccess:Expr = {expr: EField(macro _t.node, info.classifierFieldName), pos: pos};
			final tailKindIdent:Expr = {expr: EConst(CIdent('_currTailKindBetween' + i)), pos: pos};
			final tailPathIdent:Expr = {expr: EConst(CIdent('_currTailPathBetween' + i)), pos: pos};
			final headKindIdent:Expr = {expr: EConst(CIdent('_currHeadKindBetween' + i)), pos: pos};
			final headPathIdent:Expr = {expr: EConst(CIdent('_currHeadPathBetween' + i)), pos: pos};

			final ctorNameMatch:Expr = {
				var acc:Expr = macro false;
				for (cn in info.matchedCtorNames) {
					final lit:Expr = {expr: EConst(CString(cn)), pos: pos};
					acc = macro $acc || _r.ctorName == $lit;
				}
				acc;
			};
			final tailBody:Expr = if (info.tailAdapterOptField == null)
				macro { $tailKindIdent = 0; $tailPathIdent = ''; }
			else {
				final adapterAccess:Expr = {expr: EField(macro opt, info.tailAdapterOptField), pos: pos};
				macro {
					final _r = $adapterAccess != null ? $adapterAccess(_v0) : null;
					if (_r != null && $ctorNameMatch) {
						$tailKindIdent = 1;
						$tailPathIdent = _r.path;
					} else {
						$tailKindIdent = 0;
						$tailPathIdent = '';
					}
				};
			}
			final headBody:Expr = if (info.headAdapterOptField == null)
				macro { $headKindIdent = 0; $headPathIdent = ''; }
			else {
				final adapterAccess:Expr = {expr: EField(macro opt, info.headAdapterOptField), pos: pos};
				macro {
					final _r = $adapterAccess != null ? $adapterAccess(_v0) : null;
					if (_r != null && $ctorNameMatch) {
						$headKindIdent = 1;
						$headPathIdent = _r.path;
					} else {
						$headKindIdent = 0;
						$headPathIdent = '';
					}
				};
			}
			final transparentBody:Expr = macro {
				$tailBody;
				$headBody;
			};
			final cases:Array<Case> = [
				for (cp in info.ctorPatterns) {
					values: [cp.pattern],
					guard: null,
					expr: cp.isMatch
						? macro {
							// `_v0` is the matched ctor's first positional
							// arg. For ctors whose first arg is a leaf path
							// terminal (`HxTypeName` / `HxWildPath` abstracts
							// over `String`), `_v0` IS the path string and
							// `Reflect.hasField` returns false. For ctors
							// whose first arg is a struct sub-rule carrying
							// a `.path` field (`HxImportAlias`), the lookup
							// extracts the dotted-ident path. Multi-arg
							// enum branches are unsupported by the PEG
							// lowering so this is the only struct-payload
							// shape the cascade has to recognise.
							final _v0Path:String = Reflect.hasField(_v0, 'path')
								? Std.string(Reflect.field(_v0, 'path'))
								: Std.string(_v0);
							$tailKindIdent = 1;
							$tailPathIdent = _v0Path;
							$headKindIdent = 1;
							$headPathIdent = _v0Path;
						}
						: cp.isTransparent
							? transparentBody
							: macro {
								$tailKindIdent = 0;
								$tailPathIdent = '';
								$headKindIdent = 0;
								$headPathIdent = '';
							},
				}
			];
			currCompute.push({expr: ESwitch(classifierAccess, cases, null), pos: pos});

			final pkLhs:Expr = {expr: EConst(CIdent('_prevTailKindBetween' + i)), pos: pos};
			final pkRhs:Expr = {expr: EConst(CIdent('_currTailKindBetween' + i)), pos: pos};
			final ppLhs:Expr = {expr: EConst(CIdent('_prevTailPathBetween' + i)), pos: pos};
			final ppRhs:Expr = {expr: EConst(CIdent('_currTailPathBetween' + i)), pos: pos};
			trackPrev.push(macro $pkLhs = $pkRhs);
			trackPrev.push(macro $ppLhs = $ppRhs);
		}

		// ω-between-single-line-types — single-axis kind tracker per info,
		// kind=1 when the current element matches one of the named ctors
		// AND the grammar-derived `multiline` predicate returns FALSE on
		// its payload (inverted polarity via `resolveCtorBlankArgs(...,
		// predicateInvert=true)`). Cascade fire consults BOTH prev and
		// curr trackers — see the priority-wrap loop below.
		for (i in 0...betweenIfNotInfos.length) {
			final info:BetweenSameCtorIfNotInfo = betweenIfNotInfos[i];
			prevVars.push({name: '_prevKindBetweenIfNot' + i, type: macro:Int, expr: macro 0});
			currVars.push({name: '_currKindBetweenIfNot' + i, type: macro:Int, expr: macro 0});
			final classifierAccess:Expr = {expr: EField(macro _t.node, info.classifierFieldName), pos: pos};
			final switchExpr:Expr = {expr: ESwitch(classifierAccess, info.classifyCases, null), pos: pos};
			final lhs:Expr = {expr: EConst(CIdent('_currKindBetweenIfNot' + i)), pos: pos};
			currCompute.push(macro $lhs = $switchExpr);
			final tlhs:Expr = {expr: EConst(CIdent('_prevKindBetweenIfNot' + i)), pos: pos};
			final trhs:Expr = {expr: EConst(CIdent('_currKindBetweenIfNot' + i)), pos: pos};
			trackPrev.push(macro $tlhs = $trhs);
		}

		// Cross-subset transition cascade — A/B subset trackers, head AND
		// tail, transparent-wrapper support via head/tail adapter pair.
		for (i in 0...transitionInfos.length) {
			final info:TransitionAcrossInfo = transitionInfos[i];
			prevVars.push({name: '_prevTailKindAcrossA' + i, type: macro:Int, expr: macro 0});
			prevVars.push({name: '_prevTailKindAcrossB' + i, type: macro:Int, expr: macro 0});
			currVars.push({name: '_currTailKindAcrossA' + i, type: macro:Int, expr: macro 0});
			currVars.push({name: '_currTailKindAcrossB' + i, type: macro:Int, expr: macro 0});
			currVars.push({name: '_currHeadKindAcrossA' + i, type: macro:Int, expr: macro 0});
			currVars.push({name: '_currHeadKindAcrossB' + i, type: macro:Int, expr: macro 0});

			final classifierAccess:Expr = {expr: EField(macro _t.node, info.classifierFieldName), pos: pos};
			final tkaIdent:Expr = {expr: EConst(CIdent('_currTailKindAcrossA' + i)), pos: pos};
			final tkbIdent:Expr = {expr: EConst(CIdent('_currTailKindAcrossB' + i)), pos: pos};
			final hkaIdent:Expr = {expr: EConst(CIdent('_currHeadKindAcrossA' + i)), pos: pos};
			final hkbIdent:Expr = {expr: EConst(CIdent('_currHeadKindAcrossB' + i)), pos: pos};
			inline function buildAdapterMatchExpr(adapterField:Null<String>, names:Array<String>):Expr {
				if (adapterField == null) return macro 0;
				var acc:Expr = macro false;
				for (cn in names) {
					final lit:Expr = {expr: EConst(CString(cn)), pos: pos};
					acc = macro $acc || _r.ctorName == $lit;
				}
				return macro (_r != null && $acc) ? 1 : 0;
			}
			final tailAdapterAccess:Null<Expr> = info.tailAdapterOptField == null
				? null
				: {expr: EField(macro opt, info.tailAdapterOptField), pos: pos};
			final headAdapterAccess:Null<Expr> = info.headAdapterOptField == null
				? null
				: {expr: EField(macro opt, info.headAdapterOptField), pos: pos};
			final tailMatchA:Expr = buildAdapterMatchExpr(info.tailAdapterOptField, info.matchedCtorNamesA);
			final tailMatchB:Expr = buildAdapterMatchExpr(info.tailAdapterOptField, info.matchedCtorNamesB);
			final headMatchA:Expr = buildAdapterMatchExpr(info.headAdapterOptField, info.matchedCtorNamesA);
			final headMatchB:Expr = buildAdapterMatchExpr(info.headAdapterOptField, info.matchedCtorNamesB);
			final transparentBody:Expr = if (tailAdapterAccess == null && headAdapterAccess == null)
				macro {
					$tkaIdent = 0; $tkbIdent = 0;
					$hkaIdent = 0; $hkbIdent = 0;
				}
			else if (headAdapterAccess == null)
				macro {
					final _r = $tailAdapterAccess != null ? $tailAdapterAccess(_v0) : null;
					$tkaIdent = $tailMatchA;
					$tkbIdent = $tailMatchB;
					$hkaIdent = 0;
					$hkbIdent = 0;
				}
			else if (tailAdapterAccess == null)
				macro {
					final _r = $headAdapterAccess != null ? $headAdapterAccess(_v0) : null;
					$hkaIdent = $headMatchA;
					$hkbIdent = $headMatchB;
					$tkaIdent = 0;
					$tkbIdent = 0;
				}
			else
				macro {
					final _r = $tailAdapterAccess != null ? $tailAdapterAccess(_v0) : null;
					$tkaIdent = $tailMatchA;
					$tkbIdent = $tailMatchB;
					{
						final _r = $headAdapterAccess != null ? $headAdapterAccess(_v0) : null;
						$hkaIdent = $headMatchA;
						$hkbIdent = $headMatchB;
					}
				};
			final cases:Array<Case> = [
				for (cp in info.ctorPatterns) {
					values: [cp.pattern],
					guard: null,
					expr: switch cp.subset {
						case 1: macro {
							$tkaIdent = 1; $tkbIdent = 0;
							$hkaIdent = 1; $hkbIdent = 0;
						};
						case 2: macro {
							$tkaIdent = 0; $tkbIdent = 1;
							$hkaIdent = 0; $hkbIdent = 1;
						};
						case 3: transparentBody;
						case _: macro {
							$tkaIdent = 0; $tkbIdent = 0;
							$hkaIdent = 0; $hkbIdent = 0;
						};
					},
				}
			];
			currCompute.push({expr: ESwitch(classifierAccess, cases, null), pos: pos});

			final pkaLhs:Expr = {expr: EConst(CIdent('_prevTailKindAcrossA' + i)), pos: pos};
			final pkaRhs:Expr = {expr: EConst(CIdent('_currTailKindAcrossA' + i)), pos: pos};
			final pkbLhs:Expr = {expr: EConst(CIdent('_prevTailKindAcrossB' + i)), pos: pos};
			final pkbRhs:Expr = {expr: EConst(CIdent('_currTailKindAcrossB' + i)), pos: pos};
			trackPrev.push(macro $pkaLhs = $pkaRhs);
			trackPrev.push(macro $pkbLhs = $pkbRhs);
		}

		// Build cascade ternary from innermost (source-driven) outward —
		// before in reverse, then between in reverse, then transition in
		// reverse, then after in reverse. Final priority (outermost wins
		// first): after[0..N] > between[0..N] > transition[0..N] >
		// before[0..N] > source-driven `(_t.blankBefore ? 1 : 0)`.
		var blanksCountExpr:Expr = macro (_t.blankBefore ? 1 : 0);
		for (i in 0...beforeInfos.length) {
			final idx:Int = beforeInfos.length - 1 - i;
			final info:BeforeCtorBlankInfo = beforeInfos[idx];
			final beforeAccess:Expr = {expr: EField(macro opt, info.optField), pos: pos};
			final currIdent:Expr = {expr: EConst(CIdent('_currKindBefore' + idx)), pos: pos};
			final prevIdent:Expr = {expr: EConst(CIdent('_prevKindBefore' + idx)), pos: pos};
			final fallback:Expr = blanksCountExpr;
			// ω-before-multiline-prev-not — gate construction: when the info
			// carries `prevExcludeCases`, the fire condition gains a
			// `_prevKindPrevExcl != 1` guard so the override falls through to
			// the source-driven fallback when the previous sibling matched an
			// excluded ctor (e.g. a cond-comp `#if … #end`). Without
			// `prevExcludeCases` the gate is the original two-term form —
			// byte-identical for every existing `blankLinesBeforeCtor{,If}`.
			final gate:Expr = if (info.prevExcludeCases == null)
				macro $currIdent == 1 && $prevIdent != 1;
			else {
				final prevExclIdent:Expr = {expr: EConst(CIdent('_prevKindPrevExcl' + idx)), pos: pos};
				macro $currIdent == 1 && $prevIdent != 1 && $prevExclIdent != 1;
			}
			blanksCountExpr = macro ($gate ? $beforeAccess : $fallback);
		}
		// ω-between-single-line-types — splice in priority between `before`
		// (just wrapped) and `between` (about to wrap). Fires `opt.<f>`
		// blanks when both prev and curr kind trackers report 1 (matched
		// ctor AND !multiline on both sides of the pair) AND `opt > 0`.
		// The `opt > 0` gate keeps default `0` as "source-driven" (the
		// fallback cascade runs unchanged), matching fork's
		// `betweenSingleLineTypes` insertion-only semantic — `0` does NOT
		// strip source blanks between single-line type pairs. `>0` forces
		// exactly that many blanks regardless of source-captured count.
		for (i in 0...betweenIfNotInfos.length) {
			final idx:Int = betweenIfNotInfos.length - 1 - i;
			final info:BetweenSameCtorIfNotInfo = betweenIfNotInfos[idx];
			final optAccess:Expr = {expr: EField(macro opt, info.optField), pos: pos};
			final currIdent:Expr = {expr: EConst(CIdent('_currKindBetweenIfNot' + idx)), pos: pos};
			final prevIdent:Expr = {expr: EConst(CIdent('_prevKindBetweenIfNot' + idx)), pos: pos};
			final fallback:Expr = blanksCountExpr;
			blanksCountExpr = macro ($currIdent == 1 && $prevIdent == 1 && $optAccess > 0 ? $optAccess : $fallback);
		}
		for (i in 0...betweenInfos.length) {
			final idx:Int = betweenInfos.length - 1 - i;
			final info:BetweenCtorBlankInfo = betweenInfos[idx];
			final countAccess:Expr = {expr: EField(macro opt, info.countOptField), pos: pos};
			final levelAccess:Expr = {expr: EField(macro opt, info.levelOptField), pos: pos};
			final adapterAccess:Expr = {expr: EField(macro opt, info.adapterOptField), pos: pos};
			final currKindIdent:Expr = {expr: EConst(CIdent('_currHeadKindBetween' + idx)), pos: pos};
			final prevKindIdent:Expr = {expr: EConst(CIdent('_prevTailKindBetween' + idx)), pos: pos};
			final currPathIdent:Expr = {expr: EConst(CIdent('_currHeadPathBetween' + idx)), pos: pos};
			final prevPathIdent:Expr = {expr: EConst(CIdent('_prevTailPathBetween' + idx)), pos: pos};
			final differCall:Expr = {expr: ECall(adapterAccess, [prevPathIdent, currPathIdent, levelAccess]), pos: pos};
			final fallback:Expr = blanksCountExpr;
			// Null-guard the adapter call — `WriteOptions.<adapterOptField>` is
			// declared `Null<(String,String,Int)->Bool>`, and the consuming
			// writer files (HxModuleWriter / HaxeModuleTriviaWriter, both
			// `@:nullSafety(Strict)`) reject a bare `opt.f(...)` call. The `&&`
			// short-circuit on `$adapterAccess != null` keeps the path inert
			// when no adapter is wired (cascade falls through to the fallback /
			// source-driven blank count).
			//
			// ω-D12-keep-source-blank-across-conditional — when
			// `opt.keepSourceBlankAcrossConditional` is opt-in `true` AND the
			// current item has a captured source blank (`_t.blankBefore`), the
			// emitted count is widened to `max(countAccess, 1)` so a real
			// source blank around `(prevImport, #if … importB; #end)` survives
			// the head/tail-transparency override path with `betweenImports=0`.
			// Default `false` preserves fork byte-identical behaviour — the
			// override emits `$countAccess` unchanged.
			final betweenChosen:Expr = macro (
				opt.keepSourceBlankAcrossConditional && _t.blankBefore && $countAccess < 1 ? 1 : $countAccess
			);
			blanksCountExpr = macro ($currKindIdent == 1 && $prevKindIdent == 1 && $adapterAccess != null && $differCall ? $betweenChosen : $fallback);
		}
		for (i in 0...transitionInfos.length) {
			final idx:Int = transitionInfos.length - 1 - i;
			final info:TransitionAcrossInfo = transitionInfos[idx];
			final countAccess:Expr = {expr: EField(macro opt, info.countOptField), pos: pos};
			final currHKAIdent:Expr = {expr: EConst(CIdent('_currHeadKindAcrossA' + idx)), pos: pos};
			final currHKBIdent:Expr = {expr: EConst(CIdent('_currHeadKindAcrossB' + idx)), pos: pos};
			final prevTKAIdent:Expr = {expr: EConst(CIdent('_prevTailKindAcrossA' + idx)), pos: pos};
			final prevTKBIdent:Expr = {expr: EConst(CIdent('_prevTailKindAcrossB' + idx)), pos: pos};
			final fallback:Expr = blanksCountExpr;
			blanksCountExpr = macro (
				($currHKAIdent == 1 && $prevTKBIdent == 1)
				|| ($currHKBIdent == 1 && $prevTKAIdent == 1)
				? $countAccess : $fallback
			);
		}
		for (i in 0...afterInfos.length) {
			final idx:Int = afterInfos.length - 1 - i;
			final info:AfterCtorBlankInfo = afterInfos[idx];
			final afterAccess:Expr = {expr: EField(macro opt, info.optField), pos: pos};
			final prevIdent:Expr = {expr: EConst(CIdent('_prevKindAfter' + idx)), pos: pos};
			final fallback:Expr = blanksCountExpr;
			blanksCountExpr = macro ($prevIdent == 1 ? $afterAccess : $fallback);
		}

		// ω-before-package — head-of-Star cascade. Each info contributes a
		// single `_arr[0].node.<classifier>` switch returning kind 1 / 0;
		// the cascade ternary picks the first matching opt.<optField>
		// (source order = priority), fallback `0`. Built bottom-up so info[0]
		// is the outermost test. Reads `_arr[0]` directly — head emit fires
		// once at the start of the Star body, before any `_t = _arr[_si]`
		// binding exists. With empty `headInfos`, the emitted `headEmit`
		// block is `macro {}` — non-opt-in callers stay byte-identical.
		var headBlanksExpr:Expr = macro 0;
		for (i in 0...headInfos.length) {
			final idx:Int = headInfos.length - 1 - i;
			final info:HeadCtorBlankInfo = headInfos[idx];
			final classifierAccess:Expr = {expr: EField(macro _arr[0].node, info.classifierFieldName), pos: pos};
			final switchExpr:Expr = {expr: ESwitch(classifierAccess, info.classifyCases, null), pos: pos};
			final optAccess:Expr = {expr: EField(macro opt, info.optField), pos: pos};
			final fallback:Expr = headBlanksExpr;
			headBlanksExpr = macro ($switchExpr == 1 ? $optAccess : $fallback);
		}
		final headEmit:Expr = headInfos.length == 0 ? (macro {}) : (macro if (_arr.length > 0) {
			final _hb:Int = $headBlanksExpr;
			var _hbi:Int = 0;
			while (_hbi < _hb) {
				_docs.push(_dhl());
				_hbi++;
			}
		});
		final initPrev:Expr = prevVars.length > 0 ? {expr: EVars(prevVars), pos: pos} : (macro {});
		final initCurr:Expr = currVars.length > 0 ? {expr: EVars(currVars), pos: pos} : (macro {});
		final currComputeExpr:Expr = currCompute.length > 0 ? {expr: EBlock(currCompute), pos: pos} : (macro {});
		final trackPrevExpr:Expr = trackPrev.length > 0 ? {expr: EBlock(trackPrev), pos: pos} : (macro {});
		return {
			initPrev: initPrev,
			initCurr: initCurr,
			currCompute: currComputeExpr,
			trackPrev: trackPrevExpr,
			blanksCount: blanksCountExpr,
			headEmit: headEmit,
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
		beforeCtorInfos:Array<BeforeCtorBlankInfo> = null,
		betweenCtorInfos:Array<BetweenCtorBlankInfo> = null,
		transitionAcrossInfos:Array<TransitionAcrossInfo> = null,
		headCtorInfos:Array<HeadCtorBlankInfo> = null,
		lineCommentTrailBlank:Bool = false,
		lineCommentLedAddBlank:Bool = false,
		afterFileHeaderCommentBlanks:Bool = false,
		betweenMultilineCommentsBlanks:Bool = false,
		betweenSameCtorIfNotInfos:Array<BetweenSameCtorIfNotInfo> = null
	):Expr {
		final triviaElemCall:Expr = {
			expr: ECall(macro $i{elemFn}, [macro _t.node, macro opt]),
			pos: Context.currentPos(),
		};
		final trailBB:Expr = trailBBAccess ?? macro false;
		final trailLC:Expr = trailLCAccess ?? macro ([] : Array<String>);
		final afterInfos:Array<AfterCtorBlankInfo> = afterCtorInfos ?? [];
		final beforeInfos:Array<BeforeCtorBlankInfo> = beforeCtorInfos ?? [];
		final betweenInfos:Array<BetweenCtorBlankInfo> = betweenCtorInfos ?? [];
		final transitionInfos:Array<TransitionAcrossInfo> = transitionAcrossInfos ?? [];
		final headInfos:Array<HeadCtorBlankInfo> = headCtorInfos ?? [];
		final betweenIfNotInfos:Array<BetweenSameCtorIfNotInfo> = betweenSameCtorIfNotInfos ?? [];
		final pos:Position = Context.currentPos();
		// ω-bug-2c-inner-star — cascade emit machinery (per-info trackers
		// + cascade ternary) extracted into `buildCascadeEmit` so the
		// inner-Star path (`triviaTryparseStarExpr`, e.g.
		// `HxConditionalDecl.body`) can opt in too. See `buildCascadeEmit`
		// for cascade priority semantics, transparent-wrapper handling,
		// and the runtime locals (`_t`, `_v0`, `opt`) the emitted Exprs
		// reference.
		final emit:CascadeEmit = buildCascadeEmit(afterInfos, beforeInfos, betweenInfos, transitionInfos, headInfos, betweenIfNotInfos);
		final blanksCountExpr:Expr = emit.blanksCount;
		// ω-before-package — head-of-Star override (e.g. `beforePackage`).
		// Spliced once at the start of `_docs` building, after `initPrev`,
		// before any element emit. With no `blankLinesAtHeadIfCtor` meta on
		// the Star, `headEmit` is `macro {}` — byte-identical to pre-slice.
		final headEmitExpr:Expr = emit.headEmit;
		// `emit.initPrev` / `emit.initCurr` are EVars statements with all
		// per-info trackers folded into one — declared once at the
		// surrounding-scope's top-level so subsequent siblings (compute,
		// cascade fire, track) resolve their idents against the same
		// lexical block. `emit.currCompute` / `emit.trackPrev` are EBlocks
		// of pure assignments, fine to nest. `$blanksCountExpr` references
		// the `_curr*` / `_prev*` idents at the cascade fire point.
		final whileBodyParts:Array<Expr> = [];
		whileBodyParts.push(macro final _t = _arr[_si]);
		if (afterFileHeaderCommentBlanks || betweenMultilineCommentsBlanks)
			whileBodyParts.push(macro var _suppressBalc:Bool = false);
		whileBodyParts.push(emit.initCurr);
		whileBodyParts.push(emit.currCompute);
		// ω-line-comment-led-blank: opt-in via `@:fmt(blankBeforeLineCommentLed)`
		// on the EOF Star — when the next sibling's `leadingComments[0]` starts
		// with `//`, force at least 1 blank line between previous element and
		// the line-comment chain regardless of source-blank capture or cascade
		// rules. Mirrors fork's `markLineCommentsAfter(typeToken, 1)` always-1
		// rule (MarkEmptyLines.hx:823) for top-level type→line-comment-led-type
		// boundaries. Only fires when the cascade-determined `_blanks` count
		// is 0 — cascade priorities (afterCtor / betweenCtor / transition /
		// beforeCtor / source-blank) are otherwise preserved.
		final lineCommentLedExpr:Expr = lineCommentLedAddBlank
			? macro (_t.leadingComments.length > 0 && StringTools.startsWith(_t.leadingComments[0], '//'))
			: macro false;
		whileBodyParts.push(macro if (_si > 0) {
			_docs.push(_dhl());
			final _blanks:Int = $blanksCountExpr;
			final _bln:Int = ($lineCommentLedExpr && _blanks == 0) ? 1 : _blanks;
			var _bli:Int = 0;
			while (_bli < _bln) {
				_docs.push(_dhl());
				_bli++;
			}
		});
		// ω-fileheader-multiline-comments: opt-in via
		// `@:fmt(afterFileHeaderCommentBlanks)` and / or
		// `@:fmt(betweenMultilineCommentsBlanks)` on the EOF Star.
		// `_suppressBalc` (only declared when at least one of the two
		// flags fires) replaces the source-driven `blankAfterLeadingComments`
		// trail-blank with the policy override at the c[last]→decl slot
		// when fileheader semantics applied during this iteration.
		final fileheaderCommentBlanksExpr:Expr = (afterFileHeaderCommentBlanks || betweenMultilineCommentsBlanks)
			? macro {
				final _lc:String = _t.leadingComments[_ci];
				final _isBlock:Bool = StringTools.startsWith(_lc, '/*');
				final _isLast:Bool = _ci + 1 == _t.leadingComments.length;
				var _override:Int = 0;
				final _firstSlot:Bool = $v{afterFileHeaderCommentBlanks}
					&& _si == 0 && _ci == 0 && _isBlock
					&& (_hasPiu || _t.leadingComments.length >= 2);
				if (_firstSlot) {
					_override = opt.afterFileHeaderComment;
					_suppressBalc = true;
				} else if ($v{betweenMultilineCommentsBlanks}
						&& !_isLast && _isBlock
						&& StringTools.startsWith(_t.leadingComments[_ci + 1], '/*')) {
					_override = opt.betweenMultilineComments;
				}
				var _bi:Int = 0;
				while (_bi < _override) {
					_docs.push(_dhl());
					_bi++;
				}
			}
			: macro {};
		final balcExpr:Expr = (afterFileHeaderCommentBlanks || betweenMultilineCommentsBlanks)
			? macro if (_t.blankAfterLeadingComments && _t.leadingComments.length > 0 && !_suppressBalc) _docs.push(_dhl())
			: macro if (_t.blankAfterLeadingComments && _t.leadingComments.length > 0) _docs.push(_dhl());
		whileBodyParts.push(macro {
			var _ci:Int = 0;
			while (_ci < _t.leadingComments.length) {
				_docs.push(leadingCommentDoc(_t.leadingComments[_ci], opt));
				_docs.push(_dhl());
				$fileheaderCommentBlanksExpr;
				_ci++;
			}
		});
		whileBodyParts.push(balcExpr);
		whileBodyParts.push(macro final _elem:anyparse.core.Doc = $triviaElemCall);
		whileBodyParts.push(macro final _tc:Null<String> = _t.trailingComment);
		whileBodyParts.push(macro _docs.push(_tc != null ? foldTrailingIntoBodyGroup(_elem, trailingCommentDocVerbatim(_tc, opt)) : _elem));
		whileBodyParts.push(emit.trackPrev);
		whileBodyParts.push(macro _si++);
		final whileBodyBlock:Expr = {expr: EBlock(whileBodyParts), pos: pos};
		final whileExpr:Expr = {
			expr: EWhile(macro _si < _arr.length, whileBodyBlock, true),
			pos: pos,
		};
		final elseBodyParts:Array<Expr> = [];
		elseBodyParts.push(macro final _docs:Array<anyparse.core.Doc> = []);
		elseBodyParts.push(emit.initPrev);
		// ω-fileheader-multiline-comments: `_hasPiu` flags whether the
		// module contains any `package` / `import` / `using` decl (mirrors
		// fork's `markFileHeader` packagesAndImports filter). When it is
		// true OR when the first decl carries 2+ leading comments, the
		// fileheader rule fires at `_si == 0 && _ci == 0` and replaces the
		// source-driven blank slot with `opt.afterFileHeaderComment`.
		// Top-level scan only — HxDecl's `Conditional` ctor wraps inner
		// decls but fileheader fixtures never test that combination, so
		// the simpler shallow scan stays in place until a fixture needs it.
		if (afterFileHeaderCommentBlanks || betweenMultilineCommentsBlanks) elseBodyParts.push(macro var _hasPiu:Bool = false);
		if (afterFileHeaderCommentBlanks) elseBodyParts.push(macro {
			var _piuI:Int = 0;
			while (_piuI < _arr.length) {
				if (!_hasPiu) switch _arr[_piuI].node.decl {
					case PackageDecl(_) | PackageEmpty | ImportDecl(_) | ImportAliasDecl(_) | ImportWildDecl(_) | UsingDecl(_) | UsingWildDecl(_):
						_hasPiu = true;
					case _:
				}
				_piuI++;
			}
		});
		elseBodyParts.push(headEmitExpr);
		elseBodyParts.push(macro var _si:Int = 0);
		elseBodyParts.push(whileExpr);
		// ω-orphan-trail-blank: opt-in via `@:fmt(blankBeforeOrphanLineCommentTrail)`
		// on the EOF Star — when the orphan trail is led by a line-comment
		// (`// …`), force the extra `_dhl()` blank between last decl and
		// trail chain regardless of source-blank capture. Mirrors fork's
		// `markLineCommentsAfter(typeToken, 1)` always-1 rule for top-level
		// type→trailing-line-comment-chain boundaries. Without the flag the
		// gate stays `_trailBB`-driven (source-blank-preserve).
		final extraTrailBlankExpr:Expr = lineCommentTrailBlank
			? macro (_arr.length > 0 && (_trailBB || (_trailLC.length > 0 && StringTools.startsWith(_trailLC[0], '//'))))
			: macro (_trailBB && _arr.length > 0);
		// ω-fileheader-multiline-comments: when the trail contains two or
		// more block-style comments, fork's `markMultilineComments` fires
		// `betweenMultilineComments` extra blanks between each block-block
		// pair. Mirrors the leading-comments emit gate above.
		final eofTrailBetweenExpr:Expr = betweenMultilineCommentsBlanks
			? macro {
				if (_ti < _trailLC.length - 1
						&& StringTools.startsWith(_trailLC[_ti], '/*')
						&& StringTools.startsWith(_trailLC[_ti + 1], '/*')) {
					var _bbi:Int = 0;
					while (_bbi < opt.betweenMultilineComments) {
						_docs.push(_dhl());
						_bbi++;
					}
				}
			}
			: macro {};
		elseBodyParts.push(macro if (_trailLC.length > 0) {
			if (_arr.length > 0) _docs.push(_dhl());
			if ($extraTrailBlankExpr) _docs.push(_dhl());
			var _ti:Int = 0;
			while (_ti < _trailLC.length) {
				_docs.push(leadingCommentDoc(_trailLC[_ti], opt));
				if (_ti < _trailLC.length - 1) _docs.push(_dhl());
				$eofTrailBetweenExpr;
				_ti++;
			}
		});
		// ω-force-flat-engine sister-coverage: EOF Star is top-level
		// (`HxModule.decls`) so its parent frame is the document root,
		// not a wrap-cascade Flatten. `_dwb` is a defensive no-op here —
		// kept for invariant symmetry with the other trivia dispatchers
		// so a future caller that places EOF-style emit under a Flatten
		// parent doesn't silently lose its hand-rolled hardlines.
		elseBodyParts.push(macro _dwb(_dc(_docs)));
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

	/**
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
	 */
	/**
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
	private static function readBodyPolicyDual(node:ShapeNode):{stmt:Null<String>, expr:Null<String>} {
		final args:Null<Array<String>> = node.fmtReadStringArgs('bodyPolicy');
		if (args == null) return {stmt: null, expr: null};
		if (args.length < 1 || args.length > 2)
			Context.fatalError('WriterLowering: @:fmt(bodyPolicy(...)) takes 1 or 2 args, got ${args.length}', Context.currentPos());
		return {stmt: args[0], expr: args.length == 2 ? args[1] : null};
	}

	private static function buildCaseBodyFlagPredicate(flagName:String):Expr {
		final samePat:Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BodyPolicy', 'Same']);
		final keepPat:Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BodyPolicy', 'Keep']);
		final optFlag:Expr = optFieldAccess(flagName);
		return macro ($optFlag == $samePat || ($optFlag == $keepPat && !_arr[0].newlineBefore));
	}

	private static function triviaTryparseStarExpr(
		fieldAccess:Expr, elemFn:String, sepExpr:Expr,
		sepBeforeFirst:Bool, nestBody:Bool,
		trailBBAccess:Null<Expr>, trailLCAccess:Null<Expr>, trailBAAccess:Null<Expr>,
		firstSepOverride:Null<Expr> = null,
		subsequentSepOverride:Null<Expr> = null,
		caseBodyFlagNames:Null<Array<String>> = null,
		flatChildOptPairs:Null<Array<Array<String>>> = null,
		padLeading:Bool = false,
		padTrailing:Bool = false,
		propagateExprPosition:Bool = false,
		refuseFlatOnComplex:Bool = false,
		afterCtorInfos:Array<AfterCtorBlankInfo> = null,
		beforeCtorInfos:Array<BeforeCtorBlankInfo> = null,
		betweenCtorInfos:Array<BetweenCtorBlankInfo> = null,
		transitionAcrossInfos:Array<TransitionAcrossInfo> = null,
		headCtorInfos:Array<HeadCtorBlankInfo> = null,
		metaLineEndOptField:Null<String> = null,
		betweenSameCtorIfNotInfos:Array<BetweenSameCtorIfNotInfo> = null,
		lineLengthAwareSeps:Bool = false,
		priorAfterTrailExpr:Null<Expr> = null,
		forceInlineSep:Bool = false,
		// ω-blockended-trivia-tryparse (Session 3): when the tryparse
		// Star carries `@:sep('text', tailRelax, blockEnded)`, the
		// per-iteration emit inserts `;` (or other sepText) between two
		// non-`}`-ending elements before the existing hardline / space
		// dispatch. Null sepText → byte-identical to pre-slice.
		sepText:Null<String> = null,
		blockEnded:Bool = false,
		// B4 ω-implements-extends-wrap: HxClassDecl/HxInterfaceDecl heritage
		// Star. When true, MULTI-clause heritage uses fork FillLine layout
		// (pack-from-front, break overflow clause at additionalIndent 2);
		// single-clause stays on the lineLengthAwareSeps 1-tab break path.
		heritageWrap:Bool = false,
		// ω-cond-indent-policy: cond-comp body Star opts into the runtime
		// `opt.conditionalPolicy` indent rule. Default false → byte-inert.
		condBodyIndent:Bool = false
	):Expr {
		// ω-bug-2c-inner-star — cascade emit for the tryparse-Star path.
		// Cascade trackers + cascade-fire blank count come from
		// `buildCascadeEmit`; consumer splices `$cascadeInitPrev` once
		// before the while loop (in `_docs` outer scope), `$cascadeInitCurr`
		// + `$cascadeCurrCompute` at the top of each iteration, replaces
		// the source-driven `if (blankBefore) push(\\n)` between iterations
		// with a `_blanks` cascade loop, and `$cascadeTrackPrev` at the end
		// of each iteration. With all info arrays empty, the cascade
		// fallback is `(_t.blankBefore ? 1 : 0)` — byte-identical to the
		// pre-slice behavior on `_si > 0 && _t.newlineBefore`.
		final afterInfos:Array<AfterCtorBlankInfo> = afterCtorInfos ?? [];
		final beforeInfos:Array<BeforeCtorBlankInfo> = beforeCtorInfos ?? [];
		final betweenInfos:Array<BetweenCtorBlankInfo> = betweenCtorInfos ?? [];
		final transitionInfos:Array<TransitionAcrossInfo> = transitionAcrossInfos ?? [];
		final headInfos:Array<HeadCtorBlankInfo> = headCtorInfos ?? [];
		final betweenIfNotInfos:Array<BetweenSameCtorIfNotInfo> = betweenSameCtorIfNotInfos ?? [];
		final cascadeEmit:CascadeEmit = buildCascadeEmit(afterInfos, beforeInfos, betweenInfos, transitionInfos, headInfos, betweenIfNotInfos);
		final cascadeInitPrev:Expr = cascadeEmit.initPrev;
		final cascadeInitCurr:Expr = cascadeEmit.initCurr;
		final cascadeCurrCompute:Expr = cascadeEmit.currCompute;
		final cascadeTrackPrev:Expr = cascadeEmit.trackPrev;
		// ω-meta-strip-blanks: meta Stars (marked via `@:fmt(metaLineEndPolicy(...))`)
		// cap inter-element separator at a single hardline regardless of source
		// blank-line count. Mirrors fork's `MarkLineEnds.determineMetadataPolicy`:
		// all four AtLineEndPolicy values (None/After/AfterLast/ForceAfterLast)
		// emit at most one newline between consecutive `@:meta` tokens, and
		// `MarkEmptyLines` has no rule that adds blanks between At tokens.
		// Non-meta Stars keep the cascade-driven source-blank pass through.
		//
		// ω-slice-45: `forceInlineSep` Stars short-circuit cascade blanks too
		// — the dedicated inter-element branch (below) always emits a single
		// space, so source blank-line trivia must NOT leak through via the
		// `_t.newlineBefore` fallback.
		final cascadeBlanksCount:Expr = metaLineEndOptField != null || forceInlineSep
			? macro 0
			: cascadeEmit.blanksCount;
		// ω-before-package — head-of-Star override (e.g. `beforePackage`).
		// Spliced once at the start of the inner Star body (after `_docs`
		// init / `_padLeading`, before the while loop). With no
		// `blankLinesAtHeadIfCtor` meta on this inner Star — the typical
		// case for body-Stars — `headEmit` is `macro {}`, byte-identical.
		final cascadeHeadEmit:Expr = cascadeEmit.headEmit;
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
		// `@:fmt(bodyPolicy('<flag>'))` (single-flag) or
		// `@:fmt(bodyPolicy('<stmtFlag>', '<exprFlag>'))` (dual form
		// for case bodies), build a runtime gate over `opt.<flag>`:
		//  - `Same` → flatten unconditionally (override).
		//  - `Keep` → flatten IFF the body's first element has no
		//    preceding source newline (`!_arr[0].newlineBefore`).
		//  - `Next` / `FitLine` → gate stays `false`, wrap stays
		//    multiline.
		// `_arr[0]` access is safe — the outer `_flatCase` short-
		// circuits via `_arr.length == 1` BEFORE this gate runs.
		//
		// ω-issue-423-mech-a: dual-flag case-body form dispatches at
		// runtime on `opt._inExprPosition`. Convention: `flag[0]` is
		// the statement-position policy (used when descending through
		// non-expression-position parents — top-level switch in a
		// function body picks `caseBody=Next` → break), `flag[1]` is
		// the expression-position policy (used when an
		// expression-position parent set `_inExprPosition=true` via
		// `@:fmt(propagateExprPosition)` — case-in-case body picks
		// `expressionCase=Keep` → flatten on same-line source).
		// Mirrors fork's `isReturnExpression` walk-up heuristic in
		// `MarkSameLine.markCase`. Single-flag callers stay byte-
		// identical (no dispatch).
		if (caseBodyFlagNames != null && caseBodyFlagNames.length > 2)
			Context.fatalError('WriterLowering: @:fmt(bodyPolicy(...)) takes at most 2 args (stmtFlag, exprFlag), got ${caseBodyFlagNames.length}', Context.currentPos());
		final flatGateExpr:Expr = if (caseBodyFlagNames == null || caseBodyFlagNames.length == 0)
			macro false;
		else if (caseBodyFlagNames.length == 1)
			buildCaseBodyFlagPredicate(caseBodyFlagNames[0]);
		else {
			final stmtPred:Expr = buildCaseBodyFlagPredicate(caseBodyFlagNames[0]);
			final exprPred:Expr = buildCaseBodyFlagPredicate(caseBodyFlagNames[1]);
			macro (opt._inExprPosition ? $exprPred : $stmtPred);
		};
		// ω-expression-case-flat-fanout: when `flatChildOptPairs` is non-empty,
		// the `_writerOpt` emitted into the runtime block is a `Reflect.copy(opt)`
		// + per-pair field override on the flat path, falling back to `opt`
		// itself everywhere else. The triviaElemCall reads `_writerOpt` so the
		// child writer sees the swapped knobs (statement-position
		// `ifBody`/`elseBody`/`forBody` → expression-position counterparts) and
		// propagates them through subsequent recursive calls. Default is plain
		// `opt` (no copy) — non-flat-fanout consumers stay byte-identical.
		//
		// ω-issue-423-mech-a: when `propagateExprPosition` is true, the copy
		// fires on BOTH paths (flat AND break) and unconditionally sets
		// `_wo._inExprPosition = true` so descendants see the expression-
		// position frame regardless of whether the case body itself flattens.
		// `flatChildOpt` per-pair overrides remain gated on `_flatCase`. When
		// the propagation flag is off, the existing flat-only path is preserved
		// byte-identically (copy only on flat, plain `opt` otherwise).
		final hasFlatChildOpt:Bool = flatChildOptPairs != null && flatChildOptPairs.length > 0;
		final writerOptExpr:Expr = if (!hasFlatChildOpt && !propagateExprPosition)
			macro opt;
		else if (!propagateExprPosition) {
			final block:Array<Expr> = [macro final _wo = _copyOpt(opt)];
			for (pair in flatChildOptPairs) {
				final fromAccess:Expr = {expr: EField(macro _wo, pair[0]), pos: Context.currentPos()};
				final toAccess:Expr = optFieldAccess(pair[1]);
				block.push(macro $fromAccess = $toAccess);
			}
			block.push(macro _wo);
			final overrideBlock:Expr = {expr: EBlock(block), pos: Context.currentPos()};
			macro (_flatCase ? $overrideBlock : opt);
		} else {
			// Wrap each `macro` expression in parens — array-literal `,` after
			// a `macro final ... = ...` reification fragment otherwise mis-parses
			// (the parser treats `macro` as a variable name in the next element).
			final block:Array<Expr> = [
				(macro final _wo = _copyOpt(opt)),
				(macro _wo._inExprPosition = true),
			];
			if (hasFlatChildOpt) {
				final flatOnlyParts:Array<Expr> = [
					for (pair in flatChildOptPairs) {
						final fromAccess:Expr = {expr: EField(macro _wo, pair[0]), pos: Context.currentPos()};
						final toAccess:Expr = optFieldAccess(pair[1]);
						macro $fromAccess = $toAccess;
					}
				];
				final flatOnlyExpr:Expr = {expr: EBlock(flatOnlyParts), pos: Context.currentPos()};
				block.push(macro if (_flatCase) $flatOnlyExpr);
			}
			block.push(macro _wo);
			final overrideBlock:Expr = {expr: EBlock(block), pos: Context.currentPos()};
			overrideBlock;
		};
		final padLeadingExpr:Expr = macro $v{padLeading};
		final padTrailingExpr:Expr = macro $v{padTrailing};
		// ω-trivia-tryparse-linelength: when the Star carries
		// `@:fmt(lineLengthAwareSeps)`, swap hard `_dt(' ')` separators
		// (padLeading + inter-element default sep) for `_dile(opt.lineWidth,
		// _dhl(), _dt(' '))` probes that decide flat-vs-break per the
		// enclosing Group's line-length verdict, and wrap the final `_docs`
		// in `_dn(_cols, _dc(_docs))` so break-mode hardlines indent +1.
		// Mirrors the non-trivia bare-Star `padLeading||padTrailing` branch
		// (WriterLowering.hx:3684-3708). First consumer: HxAbstractDecl.clauses
		// after the @:trivia @:tryparse flip — closes wrap regressions
		// (issue_364) under the trivia path that the non-trivia branch
		// already handled via lineLengthAwareSeps.
		final padLeadingSpaceDoc:Expr = lineLengthAwareSeps
			? macro _dile(opt.lineWidth, _dhl(), _dt(' '))
			: macro _dt(' ');
		final subsequentSepDoc:Expr = lineLengthAwareSeps
			? macro _dile(opt.lineWidth, _dhl(), _dt(' '))
			: subsequentSepExpr;
		// ω-trivia-tryparse-prior-after-trail: when the Star's PREVIOUS
		// sibling field was a mandatory Ref carrying `@:trail` in trivia-
		// bearing mode, its synth `<priorField>AfterTrail:Null<String>`
		// slot holds the same-line `// comment` (stripped delimiters)
		// that landed right after the trail literal. The non-trivia bare-
		// Star path discards this — only `bodyPolicyWrap`-tagged Refs
		// previously consumed it (WriterLowering.hx:2379). Inline-emit
		// before padLeading so the trail-of-prev-field comment cuddles to
		// the prev token visually. Null when caller did not thread the
		// slot (default no-op).
		final priorAfterTrailEmit:Expr = priorAfterTrailExpr == null
			? macro {}
			: macro {
				final _pat:Null<String> = $priorAfterTrailExpr;
				if (_pat != null) _docs.push(trailingCommentDoc(_pat, opt));
			};
		// ω-trivia-tryparse-linelength: when the LAST element carries a
		// same-line `// trail`, the line comment runs until next physical
		// `\n` — without a terminator the next field's lead literal would
		// inline INSIDE the comment. Emit `_dhl()` OUTSIDE the Nest wrap
		// (else next field's `{` lands at +1 indent). The terminator sits
		// at base indent so the next field's leftCurlySeparator decides
		// placement independently. Gated by `lineLengthAwareSeps` — non-
		// opt-in callers stay byte-identical (`_de()` no-op).
		final finalWrapDocs:Expr = lineLengthAwareSeps
			? macro _dc([
				_dn(_cols, _dc(_docs)),
				(_arr.length > 0 && _arr[_arr.length - 1].trailingComment != null) ? _dhl() : _de()
			])
			: macro _dc(_docs);
		// ω-cond-indent-policy: runtime gate — the Star carries
		// `@:fmt(conditionalBodyIndent)` (compile-time `condBodyIndent`)
		// AND the active `opt.conditionalPolicy` is `AlignedIncrease` OR
		// `AlignedDecrease`. Both layouts accumulate the body `+1` per nesting
		// depth identically (`_dn(_cols, …)`); `AlignedDecrease` then shifts the
		// whole construct `-1` uniformly at render time via the
		// `ConditionalMarkerDecrease` wrap (see `case3Doc` gate below). When
		// false (default `Aligned`, `FixedZero`, every non-cond Star) the body
		// assembly stays byte-identical. The enum is `Int`-backed so the
		// comparison is a plain integer test in the hot path.
		final condIncreaseGateExpr:Expr = condBodyIndent
			? macro (opt.conditionalPolicy == anyparse.format.ConditionalIndentationPolicy.AlignedIncrease
				|| opt.conditionalPolicy == anyparse.format.ConditionalIndentationPolicy.AlignedDecrease)
			: macro false;
		final lastTrailTerminatorEmit:Expr = macro {};
		// ω-metadata-line-end-function: runtime `_metaPolicy:Int` read from
		// `opt.<metaLineEndOptField>` (default 0 = None when the flag is
		// absent, byte-identical to pre-slice). Drives inter-element sep
		// override AND post-Star hardline. Values mirror
		// `anyparse.format.MetadataLineEndPolicy`:
		//   0 = None (source-driven, default)
		//   1 = After (every inter-meta sep → hardline)
		//   2 = AfterLast (source-driven inter-meta, force trailing hardline)
		//   3 = ForceAfterLast (collapse inter-meta to space, force trailing hardline)
		final metaPolicyExpr:Expr = metaLineEndOptField != null
			? optFieldAccess(metaLineEndOptField)
			: macro 0;
		// ω-issue-423-mech-b: `@:fmt(refuseFlatOnComplexExpr)` adds an extra
		// AND-clause to `_flatCase` that defers to the plugin-supplied
		// `WriteOptions.caseBodyRefusesFlat` adapter (mirrors the
		// `endsWithCloseBrace` pattern — engine never references the
		// grammar plugin by name; the plugin's `defaultWriteOptions`
		// wires its own predicate). Null adapter → no refusal (the gate
		// short-circuits to `true`, preserving the dual flat-gate's
		// verdict). Default `refuseFlatOnComplex=false` → predicate
		// omitted entirely (other Star consumers stay byte-identical).
		final shapeRefusalExpr:Expr = refuseFlatOnComplex
			? (macro {
				final _refuseFn:Null<Dynamic -> Bool> = opt.caseBodyRefusesFlat;
				_refuseFn == null || !_refuseFn(_arr[0].node);
			})
			: (macro true);
		// ω-blockended-trivia-tryparse (Session 3): inject `;` between two
		// not-yet-statement-terminated elements. Null sepText /
		// non-blockEnded → no-op.
		//
		// ω-phase-g (Session 4): source-fidelity OR `_arr[_si - 1].sepAfter`.
		// Trust the parser: if it consumed a sep after the prior element,
		// preserve it on output even when the prior already ends with `}`
		// or `;` (covers source like `case x: if(c){body}; foo();` where
		// the author wrote the redundant `;` after the brace). The
		// `endsWithStmtTerminator` arm stays as a safety net for raw /
		// programmatic AST inputs whose `Trivial<T>` defaults leave
		// `sepAfter=false` even when the source shape demands a sep.
		final tryparseBlockEndedSepEmit:Expr = (sepText != null && blockEnded)
			? macro {
				if (_si > 0 && _priorElemDoc != null
						&& (_arr[_si - 1].sepAfter
							|| !anyparse.core.DocMeasure.endsWithStmtTerminator(_priorElemDoc))) {
					_docs.push(_dt($v{sepText}));
				}
			}
			: macro {};
		// ω-blockended-trivia-tryparse-trail (Session 3): post-loop tail
		// sep emit so the last element of a case-body keeps its source
		// `;` (e.g. `case X: foo();` survives round-trip). `endsWithSemi`
		// (not `endsWithStmtTerminator`) — see `blockTrailSepEmitExpr`
		// rationale: under BlockBody Star sep-ownership a trailing `}`
		// is the inner value's, not the stmt's terminator.
		final tryparseBlockEndedTrailEmit:Expr = (sepText != null && blockEnded)
			? macro {
				if (_arr.length > 0 && _priorElemDoc != null && _arr[_arr.length - 1].sepAfter
						&& !anyparse.core.DocMeasure.endsWithSemi(_priorElemDoc)) {
					_docs.push(_dt($v{sepText}));
				}
			}
			: macro {};
		// B4 ω-implements-extends-wrap: dedicated heritage emit bypassing
		// the shared incremental loop. MULTI-clause heritage packs clauses
		// from the front via `Fill` and breaks the overflow clause(s) at
		// additionalIndent 2 (8 spaces) — the fork `wrapping.implementsExtends`
		// default FillLine layout. SINGLE-clause heritage stays byte-identical
		// to the `lineLengthAwareSeps` path (`_dile` leading break at 1 tab,
		// type params intact) so `extends_break_before_keyword_not_type_params`
		// and the meta-priority single-clause cases hold. Falls back to a plain
		// space-join when any clause carries leading/trailing comments (no
		// fork-corpus heritage fixture exercises that path).
		if (heritageWrap) {
			return macro {
				final _arr = $fieldAccess;
				if (_arr.length == 0) _de()
				else {
					final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
					final _writerOpt = $writerOptExpr;
					var _hasComments:Bool = false;
					var _hci:Int = 0;
					while (_hci < _arr.length) {
						if (_arr[_hci].leadingComments.length > 0 || _arr[_hci].trailingComment != null)
							_hasComments = true;
						_hci++;
					}
					final _items:Array<anyparse.core.Doc> = [];
					var _hi:Int = 0;
					while (_hi < _arr.length) {
						final _t = _arr[_hi];
						_items.push($triviaElemCall);
						_hi++;
					}
					if (_hasComments) {
						final _docs:Array<anyparse.core.Doc> = [_dt(' ')];
						var _hj:Int = 0;
						while (_hj < _items.length) {
							if (_hj > 0) _docs.push(_dt(' '));
							_docs.push(_items[_hj]);
							_hj++;
						}
						_dc(_docs);
					} else if (_items.length <= 1) {
						_dn(_cols, _dc([_dile(opt.lineWidth, _dhl(), _dt(' ')), _items[0]]));
					} else {
						// B4 ω-implements-extends-wrap: config-driven multi-clause
						// layout. Resolve the fork-style WrapRules cascade at write
						// time from opt.implementsExtendsWrap. lineLength rules gate
						// via IfLineExceeds (prefix-aware); itemCount / defaultMode
						// resolve as plain Haxe. additionalIndent comes from the
						// cascade (defaultAdditionalIndent; anyparse WrapRule has no
						// per-rule indent — see HaxeFormat.defaultImplementsExtendsWrap).
						final _rules = opt.implementsExtendsWrap;
						final _ai:Int = _cols * (_rules.defaultAdditionalIndent ?? 0);
						// Resolve mode + lineLength threshold from the first matching
						// rule (itemCount evaluated now; lineLength deferred to the
						// render gate via _thr). _thr<0 means "apply mode always".
						var _mode:anyparse.format.wrap.WrapMode = _rules.defaultMode;
						var _thr:Int = -1;
						var _ri:Int = 0;
						var _matched:Bool = false;
						while (_ri < _rules.rules.length && !_matched) {
							final _rule = _rules.rules[_ri];
							_ri++;
							var _llThr:Int = -1;
							var _ok:Bool = true;
							var _ci2:Int = 0;
							while (_ci2 < _rule.conditions.length) {
								final _cond = _rule.conditions[_ci2];
								_ci2++;
								switch (_cond.cond) {
									case anyparse.format.wrap.WrapConditionType.ItemCountLargerThan:
										if (_arr.length < _cond.value) _ok = false;
									case anyparse.format.wrap.WrapConditionType.ItemCountLessThan:
										if (_arr.length > _cond.value) _ok = false;
									case anyparse.format.wrap.WrapConditionType.LineLengthLargerThan:
										_llThr = _cond.value;
									case anyparse.format.wrap.WrapConditionType.ExceedsMaxLineLength:
										_llThr = opt.lineWidth;
									case _:
										_ok = false;
								}
							}
							if (_ok) { _mode = _rule.mode; _thr = _llThr; _matched = true; }
						}
						// Build the broken layout for the resolved mode, plus the
						// all-glued (space-joined) fallback used when the lineLength
						// gate does not fire.
						final _glued:Array<anyparse.core.Doc> = [_dt(' ')];
						var _gj:Int = 0;
						while (_gj < _items.length) { if (_gj > 0) _glued.push(_dt(' ')); _glued.push(_items[_gj]); _gj++; }
						final _gluedDoc:anyparse.core.Doc = _dc(_glued);
						final _broken:anyparse.core.Doc = switch (_mode) {
							case anyparse.format.wrap.WrapMode.OnePerLine:
								final _ds:Array<anyparse.core.Doc> = [];
								var _k:Int = 0;
								while (_k < _items.length) { _ds.push(_dhl()); _ds.push(_items[_k]); _k++; }
								_dn(_ai, _dc(_ds));
							case anyparse.format.wrap.WrapMode.OnePerLineAfterFirst:
								final _ds:Array<anyparse.core.Doc> = [_dt(' '), _items[0]];
								var _k:Int = 1;
								while (_k < _items.length) { _ds.push(_dhl()); _ds.push(_items[_k]); _k++; }
								_dn(_ai, _dc(_ds));
							case anyparse.format.wrap.WrapMode.FillLine | anyparse.format.wrap.WrapMode.FillLineWithLeadingBreak:
								_dn(_ai, _dc([_dt(' '), _dfill(_items, _dl())]));
							case _:
								_gluedDoc;
						};
						if (_mode == anyparse.format.wrap.WrapMode.NoWrap) _gluedDoc;
						else if (_thr < 0) _broken;
						else _dile(_thr, _broken, _gluedDoc);
					}
				}
			};
		}
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
				&& $shapeRefusalExpr
				&& $flatGateExpr;
			final _writerOpt = $writerOptExpr;
			// ω-cond-mod-pad: padLeading/padTrailing emit a space (single-line
			// shape) or hardline (multi-line, when first element carries a
			// source newline) around the Star body. Trail-side decision
			// mirrors leading-side because the parser does not capture a
			// body[last]→outer-trail newline slot — in legal source shapes
			// the two are correlated. Empty arrays skip both pads.
			final _padLeading:Bool = $padLeadingExpr;
			final _padTrailing:Bool = $padTrailingExpr;
			final _padHardline:Bool = (_padLeading || _padTrailing) && _arr.length > 0 && _arr[0].newlineBefore;
			final _metaPolicy:Int = $metaPolicyExpr;
			// ω-condcomp-empty-body-newline (Stage A): an EMPTY cond-comp body
			// / elseBody Star (`HxConditionalStmt`/`Decl`/… `body` carries BOTH
			// `@:fmt(padLeading, padTrailing)`) must still emit a single
			// hardline so `#if(cond)\n#end` keeps its interior newline rather
			// than collapsing to `#if(cond)#end`. The `padLeading && padTrailing`
			// gate is cond-comp-EXCLUSIVE (the expr-position `elseifs` Star has
			// padTrailing ONLY) — every other tryparse-Star consumer leaves
			// both false, so the empty body stays `_de()` byte-identical.
			if (_arr.length == 0 && _trailLC.length == 0)
				(_padLeading && _padTrailing) ? _dhl() : _de();
			else {
				final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
				final _docs:Array<anyparse.core.Doc> = [];
				// ω-cond-indent-policy: when active, the trailing pad hardline
				// (the `\n` before `#else`/`#end`) is held OUT of `_docs` so it
				// lands at the surrounding statement indent; the body content
				// inside `_docs` is wrapped in `_dn(_cols, …)` at assembly.
				final _condIncrease:Bool = $condIncreaseGateExpr;
				var _condTrailPad:Null<anyparse.core.Doc> = null;
				$cascadeInitPrev;
				$cascadeHeadEmit;
				$priorAfterTrailEmit;
				if (_padLeading && _arr.length > 0) _docs.push(_padHardline ? _dhl() : $padLeadingSpaceDoc);
				// ω-blockended-trivia-tryparse (Session 3): see comment near
				// tryparseBlockEndedSepEmit construction. Always declared so
				// the splice site reads it safely; when sepText is null /
				// blockEnded false, the splice expands to `{}` (no read).
				var _priorElemDoc:Null<anyparse.core.Doc> = null;
				var _si:Int = 0;
				while (_si < _arr.length) {
					final _t = _arr[_si];
					$cascadeInitCurr;
					$cascadeCurrCompute;
					$tryparseBlockEndedSepEmit;
					if (_t.leadingComments.length > 0) {
						// ω-D16-padleading-first-comment-no-dup: padLeading
						// already emitted `_dhl()` for the first element when
						// `_padHardline` is true (driven by `_arr[0].newlineBefore`).
						// Both reflect the SAME source newline between the
						// prior token and the stmt's trivia — a second `_dhl()`
						// here produces a spurious blank line (visible as
						// `#if sys\n\n\t\t// comment` for HxConditionalStmt.body
						// with `@:fmt(padLeading)` and a leading line comment
						// on the first body stmt). Skip the dup only on the
						// first iteration when padLeading fired as a hardline;
						// inter-stmt path (`_si > 0`) and non-padLeading
						// consumers stay byte-identical.
						if (!(_si == 0 && _padLeading && _padHardline)) _docs.push(_dhl());
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
					} else if (_si > 0 && _metaPolicy == 1) {
						// ω-metadata-line-end-function: After policy collapses
						// source-driven inter-meta sep to a forced hardline,
						// emitting one metadata per line regardless of source
						// layout. Skips the cascade-blanks path — blank-line
						// separators between metas aren't a fork-supported shape
						// for the After policy.
						_docs.push(_dhl());
					} else if (_si > 0 && _metaPolicy == 3) {
						// ω-metadata-line-end-function: ForceAfterLast collapses
						// any source newline between consecutive metas to a
						// single space, producing the canonical `@A @B @C`
						// inline shape ahead of the trailing hardline.
						_docs.push(_dt(' '));
					} else if (_si > 0 && $v{forceInlineSep}
						&& Type.enumParameters(cast _arr[_si - 1].node).length == 0
						&& Type.enumParameters(cast _t.node).length == 0) {
						// ω-slice-45: `@:fmt(forceInlineSep)` collapses every
						// source linebreak between consecutive SimpleCtor
						// elements to a single space. Modifier Stars
						// (`HxMemberDecl.modifiers`, `HxTopLevelDecl.modifiers`)
						// opt in so multi-line `static\n\toverload` round-trips
						// as `static overload`. ParamCtor elements (current
						// consumers: `Conditional(inner:HxConditionalMod)` —
						// the `#if … #end` modifier region) are gated OUT so
						// the existing CondMod layout (issue_332 V1/V4: source
						// newline between `#end` and the next keyword
						// preserved) stays byte-identical. Plugin-agnostic
						// ctor classification via `Type.enumParameters` — no
						// reflection by ctor name. The `cast` suppresses
						// macro-time type-checking on `.node` (struct-shaped
						// Star elements like `HxMemberDeclT`/`HxTopLevelDeclT`
						// would otherwise fail `EnumValue` unification — dead-
						// code elimination runs AFTER type-check); compile-
						// time `$v{forceInlineSep}` short-circuit keeps the
						// runtime reflection cost on opted-in modifier Stars
						// only, where `.node` IS an enum (`HxMemberModifier` /
						// `HxModifier`).
						_docs.push(_dt(' '));
					} else if (_si > 0 && _t.newlineBefore) {
						// ω-cond-mod-newline: preserve a single source newline
						// between try-parse Star elements. Without this, the
						// default `sepExpr` (space) would collapse
						// `#if COND <mods> #end\n\tpublic` (issue_332 V1) down
						// to `#if COND <mods> #end public` on round-trip,
						// losing the author's modifier-list line break.
						//
						// ω-bug-2c-inner-star: cascade-blanks loop replaces the
						// pre-slice `if (_t.blankBefore) push(\\n)` source-driven
						// path. With no cascade infos active, `$cascadeBlanksCount`
						// reduces to `(_t.blankBefore ? 1 : 0)` — byte-identical
						// to the prior single-blank emit.
						_docs.push(_dhl());
						final _blanks:Int = $cascadeBlanksCount;
						var _bli:Int = 0;
						while (_bli < _blanks) {
							_docs.push(_dhl());
							_bli++;
						}
					} else if (_si > 0) {
						_docs.push($subsequentSepDoc);
					} else if (_sepFirst) {
						_docs.push($firstSepExpr);
					}
					final _elem:anyparse.core.Doc = $triviaElemCall;
					final _tc:Null<String> = _t.trailingComment;
					_docs.push(_tc != null ? foldTrailingIntoBodyGroup(_elem, trailingCommentDocVerbatim(_tc, opt)) : _elem);
					_priorElemDoc = _elem;
					$cascadeTrackPrev;
					_si++;
				}
				$tryparseBlockEndedTrailEmit;
				// ω-cond-indent-policy: under AlignedIncrease hold the trailing
				// pad out of `_docs` so the close marker (`#else`/`#end`)
				// renders at the surrounding indent rather than at body+1. The
				// pad doc is identical to the pre-policy push; only its
				// placement (outside the `_dn`) changes. Other policies /
				// non-cond Stars keep the inline push (`_condIncrease` false →
				// byte-identical).
				if (_condIncrease && _padTrailing && _arr.length > 0) _condTrailPad = _padHardline ? _dhl() : _dt(' ');
				else if (_padTrailing && _arr.length > 0) _docs.push(_padHardline ? _dhl() : _dt(' '));
				else if (_metaPolicy != 0 && _arr.length > 0) _docs.push(_dhl());
				// ω-trivia-tryparse-linelength: when the LAST element carries
				// a same-line `// trail`, a `//` line comment runs until the
				// next physical newline, so an inline ` ` separator before
				// the next sibling's lead literal (`{`/`}`/...) would inline
				// that sibling INSIDE the comment. Emit a terminating
				// hardline so the next field's lead lands on its own line.
				// Gated by `lineLengthAwareSeps` so non-opt-in callers stay
				// byte-identical. First consumer: HxAbstractDecl.clauses
				// terminating the last-clause trail before members `{` lead.
				$lastTrailTerminatorEmit;
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
				// ω-force-flat-engine sister-coverage: tryparse Star is used
				// for inner-Star bodies (case bodies, `HxConditionalDecl.body`)
				// which can sit under wrap-cascade Flatten parents in expression
				// position. Each leaf branch hand-rolls its terminal Doc — wrap
				// uniformly in `_dwb` so a nested wrap-engine reads its own
				// independent layout. `_dwb` is no-op outside Flatten frame.
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
					_dwb(_dn(_cols, _dc(_docs)));
				} else if (_nestBody) {
					if (_arr.length > 0 && _trailDocs.length > 0) {
						_dwb(_dc([_dn(_cols, _dc(_docs)), _dc(_trailDocs)]));
					} else {
						for (_d in _trailDocs) _docs.push(_d);
						_dwb(_dn(_cols, _dc(_docs)));
					}
				} else if (_condIncrease) {
					// ω-cond-indent-policy: AlignedIncrease — body content
					// (leading pad + each body element, all inside `_docs`)
					// nests one level deeper; the trailing close-marker pad
					// (`_condTrailPad`, held out above) renders at the
					// surrounding indent. `_trailDocs` (orphan trail comments)
					// is empty for cond-comp bodies but appended defensively
					// inside the nest to preserve the pre-policy ordering.
					for (_d in _trailDocs) _docs.push(_d);
					final _nested:anyparse.core.Doc = _dn(_cols, _dc(_docs));
					_dwb(_condTrailPad != null ? _dc([_nested, _condTrailPad]) : _nested);
				} else {
					for (_d in _trailDocs) _docs.push(_d);
					_dwb($finalWrapDocs);
				}
			}
		};
	}

	/** Build `_dc([elem1, elem2, ...])` from a macro-time array of Exprs. */
	private static function dcCall(parts:Array<Expr>):Expr {
		final arr:Expr = {expr: EArrayDecl(parts), pos: Context.currentPos()};
		return macro _dc($arr);
	}

	/**
	 * Build the field-access Expr `opt.<fieldName>` — used everywhere the
	 * generated writer reads a `WriteOptions` knob (cascade rules, body
	 * policy flags, leftCurly placement, etc.). Replaces 4-line inline
	 * `optFieldAccess(name)`
	 * boilerplate at ~46 sites.
	 *
	 * Two sites that build the access with a non-`Context.currentPos()`
	 * position (`triviaSepStarExpr` per-info loops in `interMemberInfo`)
	 * stay inline — the helper assumes `Context.currentPos()`.
	 */
	private static inline function optFieldAccess(fieldName:String):Expr {
		return {expr: EField(macro opt, fieldName), pos: Context.currentPos()};
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
	private static inline function beforeNewlineAccess(fieldName:String):Expr {
		return {
			expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_NEWLINE_SUFFIX),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Build `!value.<fieldName><BEFORE_NEWLINE_SUFFIX>` — the `bodyOnSameLine`
	 * inverse of the trivia BeforeNewline slot, used by `bodyPolicyWrap`'s
	 * `Keep`-policy dispatch and the `bodyPolicyForCtor` runtime wrap.
	 */
	private static inline function beforeNewlineNotAccess(fieldName:String):Expr {
		return {
			expr: EUnop(OpNot, false, beforeNewlineAccess(fieldName)),
			pos: Context.currentPos(),
		};
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
		final adapterExpr:Expr = optFieldAccess(adapterName);
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

	/**
	 * `true` when `s` is a non-empty string whose first character is a
	 * Haxe identifier-start (`a-zA-Z_`). Used by Case 3 single-Ref
	 * emission to detect word-keyword `@:lead` (e.g. `var`, `final`,
	 * `function`) — these are second keywords that need spacing on both
	 * sides, unlike symbol leads (`(`, `{`, `<`, `:`, `?`, `->`, `${`).
	 */
	private static function isWordStart(s:String):Bool {
		if (s == null || s.length == 0) return false;
		final c:Int = StringTools.fastCodeAt(s, 0);
		return (c >= 'a'.code && c <= 'z'.code)
			|| (c >= 'A'.code && c <= 'Z'.code)
			|| c == '_'.code;
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
		// The var-ctor arg accepts a `|`-separated set so grammars whose
		// element enum splits the "var" family across multiple ctors (Haxe:
		// `VarMember` for `var x`, `FinalMember` for `final x` / `static
		// final x`) classify every member of that family as kind 1. Mirrors
		// the fork's `FieldUtils.getFieldType`, which folds `Kwd(KwdFinal)`
		// into the same `Var(...)` field kind as `Kwd(KwdVar)`.
		final varCtors:Array<String> = args[1].split('|');
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
			final kindExpr:Expr = if (varCtors.contains(ctorName)) macro 1;
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
	 * ω-class-static-var-cascade — resolve `@:fmt(staticVarSubdivision)` /
	 * `@:fmt(staticVarSubdivision('<modifierField>', '<staticCtor>',
	 * '<afterStaticVarsField>'))` into the data the per-iteration kind
	 * switch reads to promote kind `1` (instance var) to kind `3` (static
	 * var). The zero-arg form defaults to the `('modifiers', 'Static',
	 * 'afterStaticVars')` triple — matches the canonical
	 * `HxMemberDecl.modifiers` Star + `HxMemberModifier.Static` ctor +
	 * `HxModuleWriteOptions.afterStaticVars` knob.
	 *
	 * The companion meta is read alongside `@:fmt(interMemberBlankLines)`;
	 * `@:fmt(staticVarSubdivision)` without `interMemberBlankLines` is
	 * inert (the cascade arms are written by `triviaBlockStarExpr` and
	 * gated on the interMember presence). Validates that the named
	 * modifier field exists on the element Seq rule and that it's a Star.
	 */
	private function buildStaticVarSubdivisionInfo(elemRefName:String, args:Array<String>):StaticVarSubdivisionInfo {
		if (args.length != 0 && args.length != 3)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) expects 0 or 3 string args (modifierField, staticCtor, afterStaticVarsField), got ${args.length}',
				Context.currentPos()
			);
		final modifierField:String = args.length == 3 ? args[0] : 'modifiers';
		final staticCtor:String = args.length == 3 ? args[1] : 'Static';
		final afterStaticVarsField:String = args.length == 3 ? args[2] : 'afterStaticVars';
		final elemRule:Null<ShapeNode> = shape.rules.get(elemRefName);
		if (elemRule == null || elemRule.kind != Seq)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) requires element rule $elemRefName to be a Seq struct',
				Context.currentPos()
			);
		var modifierNode:Null<ShapeNode> = null;
		for (child in elemRule.children) if (child.annotations.get('base.fieldName') == modifierField) {
			modifierNode = child;
			break;
		}
		if (modifierNode == null)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) modifier field "$modifierField" not found on element rule $elemRefName',
				Context.currentPos()
			);
		if (modifierNode.kind != Star)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) modifier field "$modifierField" must be a Star',
				Context.currentPos()
			);
		// `base.ref` lives on the Star's element child (the Ref node), not the
		// Star itself — `ShapeBuilder.shapeFieldType` builds `Array<T>` as a
		// Star with `children = [shapeFieldType(T)]` and only the inner Ref
		// carries `base.ref`.
		if (modifierNode.children.length != 1)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) modifier field "$modifierField" must have exactly one Star child',
				Context.currentPos()
			);
		final modifierEnumName:Null<String> = modifierNode.children[0].annotations.get('base.ref');
		if (modifierEnumName == null)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) modifier field "$modifierField" has no base.ref annotation',
				Context.currentPos()
			);
		final modifierEnum:Null<ShapeNode> = shape.rules.get(modifierEnumName);
		if (modifierEnum == null || modifierEnum.kind != Alt)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) modifier target $modifierEnumName must be an Alt (enum)',
				Context.currentPos()
			);
		var staticBranchFound:Bool = false;
		for (branch in modifierEnum.children) if (branch.annotations.get('base.ctor') == staticCtor) {
			staticBranchFound = true;
			break;
		}
		if (!staticBranchFound)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) static ctor "$staticCtor" not found on enum $modifierEnumName',
				Context.currentPos()
			);
		return {
			modifierFieldName: modifierField,
			staticCtorName: staticCtor,
			afterStaticVarsField: afterStaticVarsField,
		};
	}

	/**
	 * ω-bug-2c-inner-star — read every cascade `@:fmt(blankLines*)` meta
	 * off a `@:trivia` Star ShapeNode and resolve them into the four
	 * info arrays consumed by `buildCascadeEmit`. Centralises the
	 * meta-read + transparent-merge + cross-validation block previously
	 * inlined in the EOF-Star branch of `lowerStruct`, so the inner-Star
	 * branch (`triviaTryparseStarExpr` consumers) can reuse the same
	 * cascade infrastructure without duplication.
	 *
	 * Recognised metas:
	 *  - `blankLinesAfterCtor` / `blankLinesAfterCtorIf`
	 *  - `blankLinesBeforeCtor` / `blankLinesBeforeCtorIf`
	 *  - `blankLinesBetweenSameCtorByLevel`
	 *  - `blankLinesBetweenSameCtorTailTransparent`
	 *  - `blankLinesBetweenSameCtorHeadTransparent`
	 *  - `blankLinesBetweenSameCtorIfNot`
	 *  - `blankLinesOnTransitionAcross`
	 *
	 * Tail/head transparent metas are merged per-classifier-field into a
	 * shared adapter pair, fed to BOTH the between-ctor and transition
	 * cascades (single shared head/tail walker per Star+classifier). Any
	 * transparent meta whose classifier has no matching between/transition
	 * meta is rejected at compile time as dead code.
	 */
	private function readCascadeInfosFromStar(starNode:ShapeNode, elemRefName:String):CascadeInfos {
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
		final beforeCtorIfPrevNotAllArgs:Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBeforeCtorIfPrevNot');
		for (args in beforeCtorIfPrevNotAllArgs)
			beforeCtorInfos.push(buildBeforeCtorBlankInfoIfPrevNot(elemRefName, args));
		final betweenCtorAllArgs:Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBetweenSameCtorByLevel');
		final tailTransparentAllArgs:Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBetweenSameCtorTailTransparent');
		final headTransparentAllArgs:Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBetweenSameCtorHeadTransparent');
		final transparentByClassifier:Map<String, {ctors:Array<String>, tailAdapter:Null<String>, headAdapter:Null<String>}> = [];
		inline function ingestTransparent(args:Array<String>, isTail:Bool, metaName:String):Void {
			if (args.length != 3)
				Context.fatalError(
					'WriterLowering: @:fmt($metaName) expects exactly 3 string args (classifierField, ctorName, adapterOptField), got ${args.length}',
					Context.currentPos()
				);
			final cf:String = args[0];
			final ctor:String = args[1];
			final adapter:String = args[2];
			var entry:Null<{ctors:Array<String>, tailAdapter:Null<String>, headAdapter:Null<String>}> = transparentByClassifier[cf];
			if (entry == null) {
				entry = {ctors: [], tailAdapter: null, headAdapter: null};
				transparentByClassifier[cf] = entry;
			}
			if (entry.ctors.indexOf(ctor) < 0) entry.ctors.push(ctor);
			if (isTail) {
				if (entry.tailAdapter != null && entry.tailAdapter != adapter)
					Context.fatalError(
						'WriterLowering: @:fmt($metaName) adapter mismatch for classifier "$cf" — got "${entry.tailAdapter}" and "$adapter"; one shared tail adapter per Star+classifier',
						Context.currentPos()
					);
				entry.tailAdapter = adapter;
			} else {
				if (entry.headAdapter != null && entry.headAdapter != adapter)
					Context.fatalError(
						'WriterLowering: @:fmt($metaName) adapter mismatch for classifier "$cf" — got "${entry.headAdapter}" and "$adapter"; one shared head adapter per Star+classifier',
						Context.currentPos()
					);
				entry.headAdapter = adapter;
			}
		}
		for (args in tailTransparentAllArgs)
			ingestTransparent(args, true, 'blankLinesBetweenSameCtorTailTransparent');
		for (args in headTransparentAllArgs)
			ingestTransparent(args, false, 'blankLinesBetweenSameCtorHeadTransparent');
		final betweenCtorInfos:Array<BetweenCtorBlankInfo> = [
			for (args in betweenCtorAllArgs) {
				final classifier:String = args[0];
				final tt:Null<{ctors:Array<String>, tailAdapter:Null<String>, headAdapter:Null<String>}> = transparentByClassifier[classifier];
				buildBetweenCtorBlankInfo(
					elemRefName, args,
					tt != null ? tt.ctors : [],
					tt != null ? tt.tailAdapter : null,
					tt != null ? tt.headAdapter : null
				);
			}
		];
		final transitionAcrossAllArgs:Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesOnTransitionAcross');
		final transitionAcrossInfos:Array<TransitionAcrossInfo> = [
			for (args in transitionAcrossAllArgs) {
				final classifier:String = args[0];
				final tt:Null<{ctors:Array<String>, tailAdapter:Null<String>, headAdapter:Null<String>}> = transparentByClassifier[classifier];
				buildTransitionAcrossInfo(
					elemRefName, args,
					tt != null ? tt.ctors : [],
					tt != null ? tt.tailAdapter : null,
					tt != null ? tt.headAdapter : null
				);
			}
		];
		final headCtorAllArgs:Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesAtHeadIfCtor');
		final headCtorInfos:Array<HeadCtorBlankInfo> = [
			for (args in headCtorAllArgs) buildHeadCtorBlankInfo(elemRefName, args)
		];
		for (cf in transparentByClassifier.keys()) {
			final hasBetween:Bool = Lambda.exists(betweenCtorInfos, info -> info.classifierFieldName == cf);
			final hasTransition:Bool = Lambda.exists(transitionAcrossInfos, info -> info.classifierFieldName == cf);
			if (!hasBetween && !hasTransition)
				Context.fatalError(
					'WriterLowering: @:fmt(blankLinesBetweenSameCtor{Tail,Head}Transparent) classifier "$cf" has no matching @:fmt(blankLinesBetweenSameCtorByLevel) or @:fmt(blankLinesOnTransitionAcross) on the same Star',
					Context.currentPos()
				);
		}
		final betweenSameCtorIfNotAllArgs:Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBetweenSameCtorIfNot');
		final betweenSameCtorIfNotInfos:Array<BetweenSameCtorIfNotInfo> = [
			for (args in betweenSameCtorIfNotAllArgs) buildBetweenSameCtorBlankInfoIfNot(elemRefName, args)
		];
		return {
			afterCtorInfos: afterCtorInfos,
			beforeCtorInfos: beforeCtorInfos,
			betweenCtorInfos: betweenCtorInfos,
			transitionAcrossInfos: transitionAcrossInfos,
			headCtorInfos: headCtorInfos,
			betweenSameCtorIfNotInfos: betweenSameCtorIfNotInfos,
		};
	}

	/**
	 * ω-before-package — resolve
	 * `@:fmt(blankLinesAtHeadIfCtor(classifierField, CtorName1,
	 * [CtorName2, …], optField))` into a `HeadCtorBlankInfo`. Same
	 * single-axis classify-switch shape as `buildAfterCtorBlankInfo`
	 * (1 if matched, 0 otherwise) — semantic divergence is at the cascade
	 * splice point: head-of-Star override fires once on `_arr[0].node`,
	 * not per-iteration. Reuses `resolveCtorBlankArgs` for arity
	 * validation, classifier-enum resolution, and synth-arity-aware case
	 * pattern emission.
	 */
	private function buildHeadCtorBlankInfo(elemRefName:String, args:Array<String>):HeadCtorBlankInfo {
		final r:CtorBlankResolution = resolveCtorBlankArgs(elemRefName, args, 'blankLinesAtHeadIfCtor', null);
		return {
			classifierFieldName: r.fieldName,
			classifyCases: r.cases,
			optField: r.optField,
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
			prevExcludeCases: null,
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
			prevExcludeCases: null,
		};
	}

	/**
	 * ω-before-multiline-prev-not — predicate-gated `blankLinesBeforeCtor`
	 * variant that ALSO suppresses the override when the previous sibling
	 * matched an excluded ctor. Args shape:
	 * `(classifierField, predicateName, TargetCtor1, …, '|', ExcludeCtor1,
	 * …, optField)`. The `'|'` separator splits the target set (left) from
	 * the excluded-prev set (right). The target side resolves exactly like
	 * `buildBeforeCtorBlankInfoIf` (predicate-gated kind tracker); the
	 * excluded side builds a second binary classify-switch on the SAME
	 * classifier field (kind=1 for any excluded ctor) stored in
	 * `prevExcludeCases`. The cascade consumer (`buildCascadeEmit`) adds a
	 * `&& _prevKindPrevExcl != 1` guard so the override falls through to the
	 * source-driven blank count when the prev sibling was excluded.
	 *
	 * Drives the "do not force a blank before a multiline type decl when
	 * the preceding sibling is a cond-comp `#if … #end` with no source
	 * blank" rule (issue_298): `Conditional`-prev → respect source.
	 */
	private function buildBeforeCtorBlankInfoIfPrevNot(elemRefName:String, args:Array<String>):BeforeCtorBlankInfo {
		final sepIdx:Int = args.indexOf('|');
		if (args.length < 5 || sepIdx < 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBeforeCtorIfPrevNot) expects ≥ 5 string args (classifierField, predicateName, TargetCtor1, …, "|", ExcludeCtor1, …, optField) with a "|" separator, got ${args.length}',
				Context.currentPos()
			);
		final classifier:String = args[0];
		final predicateName:String = args[1];
		final optField:String = args[args.length - 1];
		final targetCtors:Array<String> = args.slice(2, sepIdx);
		final excludeCtors:Array<String> = args.slice(sepIdx + 1, args.length - 1);
		if (targetCtors.length == 0 || excludeCtors.length == 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBeforeCtorIfPrevNot) requires ≥ 1 target ctor before "|" and ≥ 1 excluded ctor after it',
				Context.currentPos()
			);
		// Target side: predicate-gated kind tracker, same resolution as
		// `buildBeforeCtorBlankInfoIf` (classifier + ctors + optField, with
		// the predicate name threaded in).
		final targetArgs:Array<String> = [classifier].concat(targetCtors).concat([optField]);
		final target:CtorBlankResolution = resolveCtorBlankArgs(elemRefName, targetArgs, 'blankLinesBeforeCtorIfPrevNot', predicateName);
		// Excluded side: bare binary classify-switch on the same classifier
		// field — no predicate, kind=1 for any excluded ctor. `optField` is
		// reused only to satisfy the resolver arity; its result is discarded.
		final excludeArgs:Array<String> = [classifier].concat(excludeCtors).concat([optField]);
		final exclude:CtorBlankResolution = resolveCtorBlankArgs(elemRefName, excludeArgs, 'blankLinesBeforeCtorIfPrevNot', null);
		return {
			classifierFieldName: target.fieldName,
			classifyCases: target.cases,
			optField: target.optField,
			prevExcludeCases: exclude.cases,
		};
	}

	/**
	 * ω-between-single-line-types — resolve
	 * `@:fmt(blankLinesBetweenSameCtorIfNot(classifierField,
	 * predicateName, CtorName1, [CtorName2, …], optField))` into a
	 * `BetweenSameCtorIfNotInfo`. Same arg shape as
	 * `blankLinesAfterCtorIf` (≥ 4 string args, predicate name at args[1])
	 * but the resolver runs with `predicateInvert=true`, so the kind
	 * tracker fires `1` when the ctor matches AND the predicate is FALSE
	 * (i.e. the ctor's payload is single-line per the grammar-derived
	 * `multiline` predicate). The cascade-emit phase consults BOTH prev
	 * and curr trackers — fires `opt.<optField>` blank lines only when
	 * both sides of the consecutive pair land in kind=1.
	 *
	 * Currently only `'multiline'` is registered as a predicate name (via
	 * `buildPredicateGatedKind`). Untagged / empty-body / no-payload
	 * ctors bucket into kind=1 (single-line by default), so adding new
	 * ctors to the named set without tagging their payload type with
	 * `@:fmt(multilineWhen…)` is safe — they fire the rule whenever they
	 * appear next to another matched ctor.
	 */
	private function buildBetweenSameCtorBlankInfoIfNot(elemRefName:String, args:Array<String>):BetweenSameCtorIfNotInfo {
		if (args.length < 4)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBetweenSameCtorIfNot) expects ≥ 4 string args (classifierField, predicateName, CtorName1, [CtorName2, …], optField), got ${args.length}',
				Context.currentPos()
			);
		final reduced:Array<String> = [args[0]].concat(args.slice(2));
		final r:CtorBlankResolution = resolveCtorBlankArgs(elemRefName, reduced, 'blankLinesBetweenSameCtorIfNot', args[1], true);
		return {
			classifierFieldName: r.fieldName,
			classifyCases: r.cases,
			optField: r.optField,
		};
	}

	/**
	 * ω-imports-using-between — resolve
	 * `@:fmt(blankLinesBetweenSameCtorByLevel(classifierField,
	 * CtorName1, [CtorName2, …], levelOptField, countOptField,
	 * pathDifferFQN))` into a `BetweenCtorBlankInfo`. Validates the
	 * classifier resolves to an enum and that every named ctor exists
	 * with arity ≥ 1 (the first positional arg is the path payload
	 * read at runtime). Patterns for matched ctors bind `_v0` to the
	 * first arg; unmatched ctors use bare wildcards.
	 *
	 * Reuses the classifier resolution path from `resolveCtorBlankArgs`
	 * (probe Seq element rule → find Ref field → walk to enum target →
	 * enumerate Alt branches) but builds its own case-pattern set
	 * because (a) the runtime case body assigns BOTH a kind flag AND a
	 * path String at index-dependent ident names, generated at cascade-
	 * emit time, and (b) the matched arity-≥1 requirement is stricter
	 * than the existing builder's optional `_v0` binding.
	 */
	private function buildBetweenCtorBlankInfo(
		elemRefName:String, args:Array<String>,
		transparentCtorNames:Array<String>,
		tailAdapterOptField:Null<String>, headAdapterOptField:Null<String>
	):BetweenCtorBlankInfo {
		if (args.length < 5)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBetweenSameCtorByLevel) expects ≥ 5 string args (classifierField, CtorName1, [CtorName2, …], levelOptField, countOptField, adapterOptField), got ${args.length}',
				Context.currentPos()
			);
		final fieldName:String = args[0];
		final adapterOptField:String = args[args.length - 1];
		final countOptField:String = args[args.length - 2];
		final levelOptField:String = args[args.length - 3];
		final ctorNames:Array<String> = args.slice(1, args.length - 3);
		if (ctorNames.length == 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBetweenSameCtorByLevel) requires at least one ctor name between the classifier field and the level/count/adapter tail',
				Context.currentPos()
			);
		// ω-cond-comp-tail-transparency — sanity-check no overlap between
		// matched and transparent sets. A ctor in both lists would be
		// ambiguous (kind=1/path=_v0 wins or transparent adapter call?).
		// Reject at compile time so the grammar author resolves it.
		for (name in ctorNames) if (transparentCtorNames.indexOf(name) >= 0)
			Context.fatalError(
				'WriterLowering: ctor "$name" appears both in @:fmt(blankLinesBetweenSameCtorByLevel) matched set and in @:fmt(blankLinesBetweenSameCtorTailTransparent) transparent set on the same Star — must be one or the other',
				Context.currentPos()
			);
		final r:{enumRule:ShapeNode, enumRuleName:String} = resolveClassifierEnum(elemRefName, fieldName, 'blankLinesBetweenSameCtorByLevel');
		final enumRule:ShapeNode = r.enumRule;
		final enumRuleName:String = r.enumRuleName;
		final pos:Position = Context.currentPos();
		final patterns:Array<BetweenCtorPattern> = [];
		final matched:Array<String> = [];
		final transparentMatched:Array<String> = [];
		for (branch in enumRule.children) {
			final ctorName:Null<String> = branch.annotations.get('base.ctor');
			if (ctorName == null) continue;
			final arity:Int = branch.children.length;
			final ctorIdent:Expr = {expr: EConst(CIdent(ctorName)), pos: pos};
			final isMatch:Bool = ctorNames.indexOf(ctorName) >= 0;
			final isTransparent:Bool = !isMatch && transparentCtorNames.indexOf(ctorName) >= 0;
			if (isMatch) {
				if (arity < 1)
					Context.fatalError(
						'WriterLowering: @:fmt(blankLinesBetweenSameCtorByLevel) ctor "$ctorName" must have arity ≥ 1 (first arg is the path payload bound to _v0); got arity $arity',
						Context.currentPos()
					);
				matched.push(ctorName);
				final binders:Array<Expr> = [for (i in 0...arity) i == 0 ? macro _v0 : macro _];
				patterns.push({
					pattern: {expr: ECall(ctorIdent, binders), pos: pos},
					isMatch: true,
					isTransparent: false,
				});
			} else if (isTransparent) {
				if (arity < 1)
					Context.fatalError(
						'WriterLowering: @:fmt(blankLinesBetweenSameCtorTailTransparent) ctor "$ctorName" must have arity ≥ 1 (first arg is the wrapper payload bound to _v0 and passed to the tail-leaf classifier adapter); got arity $arity',
						Context.currentPos()
					);
				transparentMatched.push(ctorName);
				final binders:Array<Expr> = [for (i in 0...arity) i == 0 ? macro _v0 : macro _];
				patterns.push({
					pattern: {expr: ECall(ctorIdent, binders), pos: pos},
					isMatch: false,
					isTransparent: true,
				});
			} else {
				final pattern:Expr = arity == 0
					? ctorIdent
					: {expr: ECall(ctorIdent, [for (_ in 0...arity) macro _]), pos: pos};
				patterns.push({pattern: pattern, isMatch: false, isTransparent: false});
			}
		}
		for (name in ctorNames) if (matched.indexOf(name) < 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBetweenSameCtorByLevel) ctor "$name" not found in enum $enumRuleName',
				Context.currentPos()
			);
		for (name in transparentCtorNames) if (transparentMatched.indexOf(name) < 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBetweenSameCtorTailTransparent) ctor "$name" not found in enum $enumRuleName',
				Context.currentPos()
			);
		return {
			classifierFieldName: fieldName,
			ctorPatterns: patterns,
			matchedCtorNames: ctorNames.copy(),
			levelOptField: levelOptField,
			countOptField: countOptField,
			adapterOptField: adapterOptField,
			tailAdapterOptField: tailAdapterOptField,
			headAdapterOptField: headAdapterOptField,
			transparentCtorNames: transparentCtorNames.copy(),
		};
	}

	/**
	 * ω-imports-using-transition — lower one
	 * `@:fmt(blankLinesOnTransitionAcross(classifierField, CtorA1,
	 * [CtorA2, …], '|', CtorB1, [CtorB2, …], countOptField))` into a
	 * `TransitionAcrossInfo`. The `'|'` literal in the args list separates
	 * subset A (left) from subset B (right). Each subset must be non-
	 * empty; ctors must exist in the classifier's target enum.
	 *
	 * Transparent-ctor support is inherited from sibling
	 * `blankLinesBetweenSameCtor{Tail,Head}Transparent` metas via the
	 * pre-merged `transparentByClassifier` map (caller).
	 */
	private function buildTransitionAcrossInfo(
		elemRefName:String, args:Array<String>,
		transparentCtorNames:Array<String>,
		tailAdapterOptField:Null<String>, headAdapterOptField:Null<String>
	):TransitionAcrossInfo {
		if (args.length < 5)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) expects ≥ 5 string args (classifierField, CtorA1, [CtorA2, …], "|", CtorB1, [CtorB2, …], countOptField), got ${args.length}',
				Context.currentPos()
			);
		final fieldName:String = args[0];
		final countOptField:String = args[args.length - 1];
		final pipeIdx:Int = args.indexOf('|');
		if (pipeIdx < 2 || pipeIdx > args.length - 3)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) requires a "|" separator between subset A and subset B (with at least one ctor on each side); got args ${args}',
				Context.currentPos()
			);
		final ctorNamesA:Array<String> = args.slice(1, pipeIdx);
		final ctorNamesB:Array<String> = args.slice(pipeIdx + 1, args.length - 1);
		if (ctorNamesA.length == 0 || ctorNamesB.length == 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) requires at least one ctor on each side of "|"',
				Context.currentPos()
			);
		for (name in ctorNamesA) if (ctorNamesB.indexOf(name) >= 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) ctor "$name" appears in both subset A and subset B — must be in exactly one',
				Context.currentPos()
			);
		for (name in ctorNamesA) if (transparentCtorNames.indexOf(name) >= 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) ctor "$name" appears both as a matched (subset A) and transparent ctor on the same Star — must be one or the other',
				Context.currentPos()
			);
		for (name in ctorNamesB) if (transparentCtorNames.indexOf(name) >= 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) ctor "$name" appears both as a matched (subset B) and transparent ctor on the same Star — must be one or the other',
				Context.currentPos()
			);
		final r:{enumRule:ShapeNode, enumRuleName:String} = resolveClassifierEnum(elemRefName, fieldName, 'blankLinesOnTransitionAcross');
		final enumRule:ShapeNode = r.enumRule;
		final enumRuleName:String = r.enumRuleName;
		final pos:Position = Context.currentPos();
		final patterns:Array<TransitionAcrossPattern> = [];
		final matchedA:Array<String> = [];
		final matchedB:Array<String> = [];
		final transparentMatched:Array<String> = [];
		for (branch in enumRule.children) {
			final ctorName:Null<String> = branch.annotations.get('base.ctor');
			if (ctorName == null) continue;
			final shapeArity:Int = branch.children.length;
			// In trivia mode, ctors with `@:trailOpt` / `@:lead` close-trailing /
			// `@:fmt(captureSource)` carry a synthesized positional arg appended
			// to the synth ctor (`HxDeclT.TypedefDecl(decl, trailPresent)`). The
			// pattern arity must match the synth ctor's full arity, otherwise
			// the generated switch fails with "Not enough arguments". Helper
			// returns 0 outside trivia mode or for non-bearing enums.
			final arity:Int = shapeArity + branchSynthExtraArity(enumRuleName, branch);
			final ctorIdent:Expr = {expr: EConst(CIdent(ctorName)), pos: pos};
			final inA:Bool = ctorNamesA.indexOf(ctorName) >= 0;
			final inB:Bool = !inA && ctorNamesB.indexOf(ctorName) >= 0;
			final isTransparent:Bool = !inA && !inB && transparentCtorNames.indexOf(ctorName) >= 0;
			if (inA) {
				matchedA.push(ctorName);
				final binders:Array<Expr> = arity == 0
					? []
					: [for (i in 0...arity) i == 0 ? macro _v0 : macro _];
				patterns.push({
					pattern: arity == 0 ? ctorIdent : {expr: ECall(ctorIdent, binders), pos: pos},
					subset: 1,
				});
			} else if (inB) {
				matchedB.push(ctorName);
				final binders:Array<Expr> = arity == 0
					? []
					: [for (i in 0...arity) i == 0 ? macro _v0 : macro _];
				patterns.push({
					pattern: arity == 0 ? ctorIdent : {expr: ECall(ctorIdent, binders), pos: pos},
					subset: 2,
				});
			} else if (isTransparent) {
				if (shapeArity < 1)
					Context.fatalError(
						'WriterLowering: @:fmt(blankLinesOnTransitionAcross) transparent ctor "$ctorName" must have arity ≥ 1 (first arg is the wrapper payload bound to _v0 and passed to the head/tail-leaf classifier adapters); got arity $shapeArity',
						Context.currentPos()
					);
				transparentMatched.push(ctorName);
				final binders:Array<Expr> = [for (i in 0...arity) i == 0 ? macro _v0 : macro _];
				patterns.push({
					pattern: {expr: ECall(ctorIdent, binders), pos: pos},
					subset: 3,
				});
			} else {
				final pattern:Expr = arity == 0
					? ctorIdent
					: {expr: ECall(ctorIdent, [for (_ in 0...arity) macro _]), pos: pos};
				patterns.push({pattern: pattern, subset: 0});
			}
		}
		for (name in ctorNamesA) if (matchedA.indexOf(name) < 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) subset A ctor "$name" not found in enum $enumRuleName',
				Context.currentPos()
			);
		for (name in ctorNamesB) if (matchedB.indexOf(name) < 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) subset B ctor "$name" not found in enum $enumRuleName',
				Context.currentPos()
			);
		for (name in transparentCtorNames) if (transparentMatched.indexOf(name) < 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBetweenSameCtor{Tail,Head}Transparent) ctor "$name" not found in enum $enumRuleName',
				Context.currentPos()
			);
		return {
			classifierFieldName: fieldName,
			ctorPatterns: patterns,
			matchedCtorNamesA: ctorNamesA.copy(),
			matchedCtorNamesB: ctorNamesB.copy(),
			countOptField: countOptField,
			tailAdapterOptField: tailAdapterOptField,
			headAdapterOptField: headAdapterOptField,
			transparentCtorNames: transparentCtorNames.copy(),
		};
	}

	/**
	 * Shared classifier-lookup path for the `blankLines{After,Before,
	 * BetweenSameCtorByLevel}Ctor[*]` meta family. Validates that the
	 * Seq element rule has a Ref field matching `fieldName`, that the
	 * Ref points at an Alt rule, and returns `(enumRule, enumRuleName)`
	 * for downstream branch enumeration. Centralising this stops the
	 * five fatalError messages from drifting out of sync across builders.
	 */
	private function resolveClassifierEnum(elemRefName:String, fieldName:String, metaName:String):{enumRule:ShapeNode, enumRuleName:String} {
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
		return {enumRule: enumRule, enumRuleName: enumRuleName};
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
	private function resolveCtorBlankArgs(elemRefName:String, args:Array<String>, metaName:String, predicateName:Null<String>, predicateInvert:Bool = false):CtorBlankResolution {
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
		final r:{enumRule:ShapeNode, enumRuleName:String} = resolveClassifierEnum(elemRefName, fieldName, metaName);
		final enumRule:ShapeNode = r.enumRule;
		final enumRuleName:String = r.enumRuleName;
		final pos:Position = Context.currentPos();
		final cases:Array<Case> = [];
		final matched:Array<String> = [];
		for (branch in enumRule.children) {
			final ctorName:Null<String> = branch.annotations.get('base.ctor');
			if (ctorName == null) continue;
			// Synth-aware arity: in trivia mode, ctors carrying `@:trailOpt` /
			// `@:lead` close-trailing / `@:fmt(captureSource)` etc. grow
			// positional args on the paired synth ctor. The wildcard / `_v0`
			// pattern must size to the full synth arity or Haxe rejects with
			// "Not enough arguments" at the generated switch.
			final arity:Int = branch.children.length + branchSynthExtraArity(enumRuleName, branch);
			final ctorIdent:Expr = {expr: EConst(CIdent(ctorName)), pos: pos};
			final pattern:Expr = arity == 0
				? ctorIdent
				: {expr: ECall(ctorIdent, [for (_ in 0...arity) macro _]), pos: pos};
			final isMatch:Bool = ctorNames.indexOf(ctorName) >= 0;
			if (isMatch) matched.push(ctorName);
			final kindExpr:Expr = if (!isMatch) macro 0;
				else if (predicateName == null) macro 1;
				else buildPredicateGatedKind(branch, ctorName, predicateName, metaName, enumRuleName, predicateInvert);
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
	private function buildPredicateGatedKind(branch:ShapeNode, ctorName:String, predicateName:String, metaName:String, enumRuleName:String, invert:Bool = false):Expr {
		if (predicateName != 'multiline')
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) predicate "$predicateName" is not registered (currently only "multiline" is supported)',
				Context.currentPos()
			);
		// ω-between-single-line-types — `invert=true` flips the kind polarity:
		// kind=1 when predicate is FALSE (i.e. the ctor matches AND is NOT
		// multi-line). Used by `blankLinesBetweenSameCtorIfNot` to track
		// "single-line side of the pair". Untagged ctors (no relevant
		// `multilineWhen…` meta on payload type) return `null` predicate
		// → kind=1 unconditionally under invert (single-line by default).
		if (branch.children.length == 0) return invert ? macro 1 : macro 0;
		final argNode:ShapeNode = branch.children[0];
		final argTypeName:Null<String> = argNode.annotations.get('base.ref');
		if (argTypeName == null) return invert ? macro 1 : macro 0;
		final pred:Null<Expr> = buildMultilinePredicate(argTypeName, macro _v0);
		if (pred == null) return invert ? macro 1 : macro 0;
		return invert ? macro ($pred ? 0 : 1) : macro ($pred ? 1 : 0);
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
	 *  - typedef-level `multilineWhenFieldCtorAndOpt('<field>', '<ctorName>',
	 *    '<optField>', '<optEnumExpr>')` (4-arg form) →
	 *    `Type.enumConstructor(accessExpr.<field>) == ctorName
	 *    && opt.<optField> == <optEnumExpr>`. The 4th arg is parsed as
	 *    a Haxe expression (via `Context.parse`) so the compared value
	 *    can be a fully-qualified `enum abstract` constructor like
	 *    `anyparse.format.BracePlacement.Next` — `Type.enumConstructor`
	 *    on the opt side would not compile for `enum abstract` knobs.
	 *    Use when the structural ctor match alone isn't enough — the
	 *    bound type may render flat or multi-line depending on a runtime
	 *    layout knob. Currently used by `HxTypedefDecl` to mark itself
	 *    multi-line only when `type` is `Anon` AND `anonTypeLeftCurly`
	 *    is `Next` (Allman): under `Same` the same source emits single-
	 *    line so the predicate stays false. The full path on the 4th
	 *    arg keeps the macro free of grammar-specific imports.
	 *  - typedef-level `multilineWhenStarFieldWrapsCascade('<starField>',
	 *    '<cascadeKnob>', '<itemNameField>')` (3-arg form) — predicate
	 *    fires when the named Star field's wrap cascade would resolve
	 *    to a non-`NoWrap` mode. The macro emits a runtime mirror of
	 *    `WrapList.emit`'s width arithmetic (sum/max with `(n-1)*2`
	 *    inter-item sep correction for `, `), reads `opt.<cascadeKnob>`
	 *    as a `WrapRules`, and calls `WrapList.decideWithLineLengthState`
	 *    with layout-blind inputs (`exceeds=false`, no `LineLengthLargerThan`
	 *    firing). Per-item width approximated as `item.<itemNameField>.length`
	 *    — sufficient when items are dominated by a single bare-name field
	 *    (e.g. `HxTypeParamDecl.name`, no constraint). Used by
	 *    `HxTypedefDecl` to detect typedefs whose declare-site typeParams
	 *    overflow `totalItemLength`/`anyItemLength` thresholds.
	 *
	 * Multiple struct-level meta entries OR-fold into one predicate:
	 * each matching meta contributes a clause, and the predicate fires
	 * when any clause fires. Enables composing structural conditions
	 * (Anon-Allman binding) with rendering-aware conditions (wrap-cascade
	 * fires on a Star field) on the same typedef. Previously first-match-
	 * wins-returns precluded this composition.
	 */
	private function buildMultilinePredicate(typeName:String, accessExpr:Expr):Null<Expr> {
		final node:Null<ShapeNode> = shape.rules.get(typeName);
		if (node == null) return null;
		final pos:Position = Context.currentPos();
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta != null) {
			// Collect every matching struct-level multiline flag and OR-fold
			// them into one predicate. Single first-match-wins precluded
			// composing structural conditions (Anon-Allman binding) with
			// rendering-aware conditions (wrap-cascade fires on a Star field),
			// so a typedef whose body type stays simple but whose declare-site
			// typeParams overflow into a wrap could not be detected as
			// multi-line. Closes the `wrapping/issue_494_type_parameter`
			// boundary between a flat typedef and a typeParam-wrapping typedef.
			final preds:Array<Expr> = [];
			for (entry in meta) if (entry.name == ':fmt') {
				for (param in entry.params) switch param.expr {
					case ECall({expr: EConst(CIdent('multilineWhenFieldNonEmpty'))}, [{expr: EConst(CString(field, _))}]):
						final fieldExpr:Expr = {expr: EField(accessExpr, field), pos: pos};
						preds.push(macro $fieldExpr.length > 0);
					case ECall({expr: EConst(CIdent('multilineWhenFieldShape'))}, [{expr: EConst(CString(field, _))}]):
						final fieldNode:Null<ShapeNode> = findFieldByName(node, field);
						if (fieldNode == null)
							Context.fatalError(
								'WriterLowering: @:fmt(multilineWhenFieldShape) field "$field" not found on $typeName',
								Context.currentPos()
							);
						final targetType:Null<String> = fieldNode.annotations.get('base.ref');
						if (targetType == null) continue;
						final fieldExpr:Expr = {expr: EField(accessExpr, field), pos: pos};
						final inner:Null<Expr> = buildMultilinePredicate(targetType, fieldExpr);
						if (inner != null) preds.push(inner);
					// ω-typedef-between-blank: 4-arg runtime ctor match on a
					// named field PLUS an opt-side runtime equality with a
					// fully-qualified enum literal. Emits
					// `Type.enumConstructor(<accessExpr>.<field>) == <ctorName>
					// && opt.<optField> == <optEnumExpr>`.
					// The opt-gate distinguishes layout modes that drive
					// whether a structurally-bound type renders multi-line
					// — e.g. `HxTypedefDecl` is "multi-line in output" only
					// when the bound type is `Anon` AND `anonTypeLeftCurly`
					// is `BracePlacement.Next` (issue_301 boundary). Avoids
					// spurious blanks under Same / other placements where the
					// same source emits single-line. The 4th arg is parsed
					// as a Haxe expression so `enum abstract` knobs (which
					// fail `Type.enumConstructor`) can be compared directly
					// against their declared constructor.
					case ECall({expr: EConst(CIdent('multilineWhenFieldCtorAndOpt'))}, [
						{expr: EConst(CString(field, _))},
						{expr: EConst(CString(ctorName, _))},
						{expr: EConst(CString(optField, _))},
						{expr: EConst(CString(optEnumExprStr, _))}
					]):
						final fieldExpr:Expr = {expr: EField(accessExpr, field), pos: pos};
						final optAccess:Expr = optFieldAccess(optField);
						final optEnumExpr:Expr = Context.parse(optEnumExprStr, pos);
						preds.push(macro Type.enumConstructor($fieldExpr) == $v{ctorName}
							&& $optAccess == $optEnumExpr);
					// ω-typedef-typeparam-multiline: 3-arg cascade probe on a
					// Star field. Mirror of `WrapList.decideWithLineLengthState`
					// at predicate-eval time, approximating per-item width via
					// `<itemNameField>.length` and the same `(n-1)*(sep+space)`
					// inter-item correction `WrapList.emit` applies. Predicate
					// fires when the cascade would resolve to any non-NoWrap
					// mode, i.e. the typedef's declare-site type parameters
					// would render multi-line. Hardcodes sep width to fork-
					// standard `, ` (2 chars) — every Haxe wrap cascade uses
					// comma separators, so this matches the runtime that
					// `shapeNoWrap` / `shapeFillLine` produce.
					case ECall({expr: EConst(CIdent('multilineWhenStarFieldWrapsCascade'))}, [
						{expr: EConst(CString(field, _))},
						{expr: EConst(CString(cascadeKnob, _))},
						{expr: EConst(CString(itemNameField, _))}
					]):
						final fieldExpr:Expr = {expr: EField(accessExpr, field), pos: pos};
						final cascadeAccess:Expr = optFieldAccess(cascadeKnob);
						final itemFieldExpr:Expr = {expr: EField(macro _p, itemNameField), pos: pos};
						// Width arithmetic mirrors `WrapList.emit`: each non-last item
						// contributes `name + sep + space` (= +2 for fork-standard `, `),
						// the last item contributes just `name`. Applied symmetrically
						// to BOTH `_sum` (→ `totalItemLength` cascade cond) AND `_maxLen`
						// (→ `anyItemLength` cascade cond) so the predicate's threshold
						// answers match `WrapList.emit`'s at runtime. Without sep in
						// maxLen the predicate could undershoot on item-length boundary
						// cases (e.g. item of exactly 49 chars vs threshold 50: predicate
						// false, emit true).
						preds.push(macro {
							final _arr = $fieldExpr;
							if (_arr == null || _arr.length == 0)
								false;
							else {
								var _sum:Int = 0;
								var _maxLen:Int = 0;
								final _lastIdx:Int = _arr.length - 1;
								for (_i in 0..._arr.length) {
									final _p = _arr[_i];
									final _raw:Int = ($itemFieldExpr : String).length;
									final _w:Int = _i < _lastIdx ? _raw + 2 : _raw;
									_sum += _w;
									if (_w > _maxLen) _maxLen = _w;
								}
								anyparse.format.wrap.WrapList.decideWithLineLengthState(
									$cascadeAccess, _arr.length, _maxLen, _sum,
									false, false, _ -> false
								) != anyparse.format.wrap.WrapMode.NoWrap;
							}
						});
					case _:
				}
			}
			if (preds.length > 0) {
				var folded:Expr = preds[0];
				for (i in 1...preds.length) {
					final next:Expr = preds[i];
					folded = macro $folded || $next;
				}
				return folded;
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
	private static function altSlotAccess(branch:ShapeNode, baseIdx:Int, argNames:Array<String>, slot:AltSlot):Null<Expr> {
		final hasSlot:Bool = switch slot {
			case CloseTrailing:   TriviaTypeSynth.isAltCloseTrailingBranch(branch);
			case TrailOpt:        TriviaTypeSynth.isAltTrailOptBranch(branch);
			case CaptureSource:   TriviaTypeSynth.isCaptureSourceBranch(branch);
			case BodyPolicyKw:    TriviaTypeSynth.isAltBodyPolicyKwBranch(branch);
			case WrapOpenNewline: TriviaTypeSynth.isAltWrapOpenNewlineBranch(branch);
			case KwNewline:       TriviaTypeSynth.isAltKwNewlineBranch(branch);
			case ChainNewline:    TriviaTypeSynth.isAltChainNewlineBranch(branch);
			case ChainLeadComment: TriviaTypeSynth.isPostfixChainCommentBranch(branch);
		};
		if (!hasSlot) return null;
		var idx:Int = baseIdx;
		if (slot == CloseTrailing) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isAltCloseTrailingBranch(branch)) {
			idx++;
			if (branch.readMetaString(':lead') != null && !branch.hasMeta(':tryparse')) idx += 3;
		}
		if (slot == TrailOpt) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isAltTrailOptBranch(branch)) idx++;
		if (slot == CaptureSource) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isCaptureSourceBranch(branch)) idx++;
		if (slot == BodyPolicyKw) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isAltBodyPolicyKwBranch(branch)) idx++;
		if (slot == WrapOpenNewline) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isAltWrapOpenNewlineBranch(branch)) idx++;
		if (slot == KwNewline) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isAltKwNewlineBranch(branch)) idx++;
		if (slot == ChainNewline) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isAltChainNewlineBranch(branch)) idx++;
		return macro $i{argNames[idx]};
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
 * ω-bodyPolicyWrap-struct-arg — option struct for `WriterLowering.bodyPolicyWrap`.
 *
 * Refactored from a 17-positional-arg signature (5 mandatory + 12 optional) into
 * a single struct-arg form so call sites are readable and forwarding-only fields
 * don't need long `null, null, null` runs. The 6 fields without `?` are required
 * (every call site passes them explicitly today); the rest are forwarding flags
 * for one of the runtime overrides documented in `bodyPolicyWrap`'s body.
 *
 * Field semantics — see `bodyPolicyWrap` body comments for full detail:
 *   - `flagName`            — name of the `BodyPolicy` field on `opt` driving the layout switch.
 *   - `exprFlagName`        — optional 2nd `BodyPolicy` field name (expr-position dispatch when `opt._inExprPosition`).
 *   - `writeCall`           — pre-built `Doc` expression that emits the body's bytes.
 *   - `bodyValueExpr`       — runtime access to the body value (used for `Type.enumConstructor` checks).
 *   - `bodyTypePath`        — fully qualified Haxe type path of the body's enum (for ctor-pattern lookup).
 *   - `hasElseIf`           — `true` for `HxIfExpr.thenBranch`-style sites that elide `{}` when followed by `if`.
 *   - `elseFieldName`       — name of the sibling `else`-side field on `value`; `null` when no peer.
 *   - `afterKwExpr`         — runtime access to captured after-kw trivia (`kwGapDoc` source).
 *   - `kwLeadingExpr`       — runtime access to captured kw-leading trivia.
 *   - `bodyOnSameLineExpr`  — runtime `Bool` driving the `Keep` branch's flat-vs-break choice.
 *   - `kwPolicyFlagName`    — name of a sibling `WhitespacePolicy` knob driving the `Same` separator (kw-policy mode).
 *   - `afterTrailExpr`      — runtime access to captured after-kw trailing comment (forces `Next` shape).
 *   - `indentObjArgs`       — `(ctorName, optField, lcField)` triple for the `indentObjGuardedNext` rule.
 *   - `policyOverrides`     — list of `(ctorName, flagName)` pairs cascading the runtime body-policy override.
 *   - `bodyAllmanIndentArgs`— `(ctorName, optField)` pair for the multi-line Allman+indent override.
 *   - `widthAware`          — when `true`, the `Same` branch routes through `IfWidthExceeds` for line-fit-aware break.
 *   - `ifExprIndentArgs`    — `(ctorName, optField)` pair for the IfExpr-as-value RHS-style indent in flat path.
 *   - `fallbackFlagName`    — name of a fallback `BodyPolicy` flag activated when the sibling `else` is absent.
 *   - `inlineBlockBodyArgs` — `(flagName)` 1-tuple for the inline-collapse override on `BlockExpr` bodies (slice ω-expression-if-with-blocks).
 *   - `singleLineFlagName`  — name of the `BodyPolicy` knob used when the value is NOT a control-flow / block ctor (slice ω-return-body-single-line).
 *   - `singleLineMultiCtors`— value ctor names treated as multi-line (keep the base policy); all other ctors read `singleLineFlagName`.
 */
typedef WrapBodyOpts = {
	flagName:String,
	?exprFlagName:Null<String>,
	writeCall:Expr,
	bodyValueExpr:Expr,
	bodyTypePath:String,
	hasElseIf:Bool,
	elseFieldName:Null<String>,
	?afterKwExpr:Null<Expr>,
	?kwLeadingExpr:Null<Expr>,
	?bodyOnSameLineExpr:Null<Expr>,
	?kwPolicyFlagName:Null<String>,
	?afterTrailExpr:Null<Expr>,
	?indentObjArgs:Array<String>,
	?policyOverrides:Array<Array<String>>,
	?bodyAllmanIndentArgs:Array<String>,
	?widthAware:Bool,
	?ifExprIndentArgs:Array<String>,
	?fallbackFlagName:String,
	?inlineBlockBodyArgs:Array<String>,
	?singleLineFlagName:Null<String>,
	?singleLineMultiCtors:Null<Array<String>>,
	// ω-keep-chain (increment: opadd_chain_keep) — runtime `Bool` access to the
	// ctor's captured `return`→value source newline (the `captureKwNewline` synth
	// slot, ReturnStmt only). When true AND the body is already-multiline
	// (`flatLength == -1`, e.g. a `WrapMode.Keep` chain nested in `1 * (…)`), the
	// FitLine return path breaks `return\n\t<body>` instead of gluing — preserving
	// the source's head newline at the VALUE level (the inner chain has had its
	// own `_headBreak` suppressed by the enclosing ParenExpr's `_setKeepChainInParen`).
	// Null in plain mode / non-bearing ctors → byte-inert (legacy glue).
	?kwNewlineExpr:Null<Expr>,
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
 * ω-class-static-var-cascade — resolved data for
 * `@:fmt(staticVarSubdivision)` /
 * `@:fmt(staticVarSubdivision('<modifierField>', '<staticCtor>',
 * '<afterStaticVarsField>'))`. Produced by
 * `WriterLowering.buildStaticVarSubdivisionInfo`. When present alongside
 * `interMemberInfo`, `triviaBlockStarExpr` augments the per-iteration
 * `_currKind` switch with a sibling-Star scan: when the base switch
 * yields kind `1` (instance var) AND the `<modifierField>` Star contains
 * a `<staticCtor>`-ctor element, `_currKind` is promoted to `3` (static
 * var). The cascade then routes (1,3)/(3,1) transitions to the
 * `<afterStaticVarsField>` opt knob, leaving (1,1)/(3,3)/(2,2)/var↔fn
 * arms on the existing `betweenVars` / `betweenFunctions` / `afterVars`.
 *
 * Class and abstract members opt in; interface members do NOT — fork's
 * `InterfaceFieldsEmptyLinesConfig` lacks `afterStaticVars` and treats
 * static-var transitions as plain `betweenVars`. Skipping the meta on
 * `HxInterfaceDecl.members` keeps that behaviour without a separate
 * interface-side knob.
 */
typedef StaticVarSubdivisionInfo = {
	modifierFieldName:String,
	staticCtorName:String,
	afterStaticVarsField:String,
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
 * ω-before-package — resolved data for
 * `@:fmt(blankLinesAtHeadIfCtor(classifierField, CtorName1, [CtorName2, …],
 * optField))`. Produced by `WriterLowering.buildHeadCtorBlankInfo` and
 * spliced into the start of `triviaEofStarExpr` / `triviaTryparseStarExpr`
 * elseBody (after `_docs` init, before any element emit). Fires
 * `opt.<optField>` blank lines at the START of the Star body when the
 * FIRST element matches one of the named ctors. Source-driven blank
 * suppression / extension does not apply — this is a pure override
 * tied to the structural shape of the head element.
 *
 * Mirrors `AfterCtorBlankInfo` shape exactly (single-axis classify-
 * switch + opt field), with two semantic differences: (a) classifier is
 * read off `_arr[0].node.<field>`, not the per-element `_t.node`;
 * (b) consumed once at the head, not per-iteration. Multiple infos on
 * the same Star are walked in source order, first matching wins —
 * remaining infos are inert. Reusable for any future "blank lines at
 * head before ctor X" slice (e.g. file-leading-comment normalisation
 * before a typedef header) by pointing at a different opt field.
 *
 * No `Before` mirror is needed at the cascade level: head and "before
 * first" are the same boundary at a Star's head, and the source-driven
 * binary blank-line slot does not apply at index 0 either way.
 */
typedef HeadCtorBlankInfo = {
	classifierFieldName:String,
	classifyCases:Array<Case>,
	optField:String,
};

/**
 * ω-between-single-line-types — resolved data for
 * `@:fmt(blankLinesBetweenSameCtorIfNot(classifierField, predicateName,
 * CtorName1, [CtorName2, …], optField))`. Produced by
 * `WriterLowering.buildBetweenSameCtorBlankInfoIfNot` and spliced into
 * `triviaEofStarExpr` / `triviaTryparseStarExpr`'s per-element loop
 * alongside the after/before/between/transition families.
 *
 * Shape mirrors `AfterCtorBlankInfo` / `BeforeCtorBlankInfo` exactly
 * (single-axis classify-switch returning `1` for any matching ctor
 * whose `predicateName` evaluates to FALSE on its payload, `0`
 * otherwise) plus an opt-field name. The two diverge from after / before
 * at the cascade gate: this family fires when BOTH prev and curr have
 * kind=1 — i.e. consecutive pair where both ends fall in the matching
 * ctor set AND neither side matches the predicate.
 *
 * Used to drive haxe-formatter's `emptyLines.betweenSingleLineTypes`
 * semantic (1 blank between any pair of single-line typedef / class /
 * interface / abstract / enum decls). The predicate is grammar-derived
 * via `buildMultilinePredicate` (same one driving `afterMultilineDecl` /
 * `beforeMultilineDecl`) but with inverted polarity at kind-emission
 * time, so untagged / empty-body decls bucket into "single-line" and
 * non-empty type-body decls bucket into "multi-line" automatically.
 *
 * Cascade priority: after-ctor > between-ctor (path-aware) > transition
 * > between-same-ctor-if-not > before-ctor > source-driven. Sits below
 * the path-aware between family (Imports/Usings) because that family
 * also gates on both sides and would conflict otherwise; sits above
 * before-ctor so a single-line typedef → single-line typedef pair
 * still fires `betweenSingleLineTypes` even when an unrelated
 * before-ctor rule would otherwise apply.
 */
typedef BetweenSameCtorIfNotInfo = {
	classifierFieldName:String,
	classifyCases:Array<Case>,
	optField:String,
};

/**
 * Aggregated cascade info arrays read off a `@:trivia` Star ShapeNode
 * by `WriterLowering.readCascadeInfosFromStar`. Each array is the
 * resolved form of one `@:fmt(blankLines*)` meta family on the same
 * Star — see the per-Info typedefs for shape semantics. Both the EOF
 * Star branch (`triviaEofStarExpr`) and the tryparse Star branch
 * (`triviaTryparseStarExpr`) consume this struct unchanged.
 *
 * `headCtorInfos` is the head-of-Star override family
 * (`blankLinesAtHeadIfCtor`); spliced once at the start of the Star
 * body. Empty array → no head emit, byte-identical to non-opt-in
 * consumers.
 */
typedef CascadeInfos = {
	afterCtorInfos:Array<AfterCtorBlankInfo>,
	beforeCtorInfos:Array<BeforeCtorBlankInfo>,
	betweenCtorInfos:Array<BetweenCtorBlankInfo>,
	transitionAcrossInfos:Array<TransitionAcrossInfo>,
	headCtorInfos:Array<HeadCtorBlankInfo>,
	betweenSameCtorIfNotInfos:Array<BetweenSameCtorIfNotInfo>,
};

/**
 * Output of `WriterLowering.buildCascadeEmit` — six Exprs ready to
 * splice into the consumer's runtime block. `initPrev` / `initCurr`
 * are single combined `EVars` statements (folded across all infos);
 * `currCompute` / `trackPrev` are `EBlock`s of pure assignments;
 * `blanksCount` is the cascade ternary with fallback
 * `(_t.blankBefore ? 1 : 0)`. `headEmit` is the head-of-Star block
 * (head cascade ternary + push loop, guarded on `_arr.length > 0`)
 * spliced once at the start of the Star body, after `_docs` init.
 * Empty info arrays produce `macro {}` placeholders so non-cascade-
 * bearing consumers stay byte-identical.
 */
typedef CascadeEmit = {
	initPrev:Expr,
	initCurr:Expr,
	currCompute:Expr,
	trackPrev:Expr,
	blanksCount:Expr,
	headEmit:Expr,
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
	// ω-before-multiline-prev-not — when non-null, a second binary
	// classify-switch (kind=1 if the element's classifier ctor is in the
	// excluded-prev set, e.g. `Conditional`). The before-ctor cascade
	// ternary gains an extra `&& _prevKindPrevExcl != 1` guard so the
	// override is suppressed when the previous sibling matched an excluded
	// ctor — the cascade then falls through to the source-driven
	// `_t.blankBefore` count. Closes the spurious-blank-after-`#end` bug
	// (issue_298): a cond-comp `#if … #end` immediately before a multiline
	// class no longer forces `beforeMultilineDecl` regardless of source.
	// Null for the plain `blankLinesBeforeCtor{,If}` builders → no extra
	// tracker, byte-identical cascade.
	?prevExcludeCases:Null<Array<Case>>,
};

/**
 * ω-imports-using-between — resolved data for
 * `@:fmt(blankLinesBetweenSameCtorByLevel(classifierField, CtorName1,
 * [CtorName2, …], levelOptField, countOptField, adapterOptField))`.
 * Produced by `WriterLowering.buildBetweenCtorBlankInfo` and spliced
 * into `triviaEofStarExpr`'s per-element loop alongside the
 * after/before-ctor families. Shape diverges from those two: the
 * runtime tracks both a kind flag (1 for any matching ctor, 0 otherwise)
 * AND a path String (first ctor arg of the matched ctor, e.g. the
 * `HxTypeName`/`HxWildPath` payload of `ImportDecl(path)`). The cascade
 * ternary fires `opt.<countOptField>` blank lines when both prev and
 * curr match the same set AND
 * `opt.<adapterOptField>(prevPath, currPath, opt.<levelOptField>)`
 * returns `true`.
 *
 * `ctorPatterns` carries one entry per enum variant in the classifier
 * target — `pattern` is a ready-to-use ESwitch case pattern (matched
 * ctors bind their first positional arg as `_v0`; unmatched ctors use
 * a wildcard for every arg). The case body is generated at cascade-
 * emit time inside `triviaEofStarExpr` because it needs to reference
 * the per-info `_currTailKindBetween<i>` / `_currTailPathBetween<i>` ident
 * names, which depend on the info's index in the cascade.
 *
 * `adapterOptField` names a function-typed field on `WriteOptions`
 * (e.g. `betweenImportsPathDiffers:Null<(String, String, Int) -> Bool>`)
 * default-wired by the grammar plugin. Engine emits a pure
 * `opt.<adapterOptField>(...)` EField call — no FQN parsing, no
 * grammar-package coupling baked into the macro core. Cascade
 * priority: after-ctor entries (outermost) > between entries >
 * before-ctor entries > source-driven `blankBefore`.
 *
 * `tailAdapterOptField` (slice ω-cond-comp-tail-transparency) and
 * `headAdapterOptField` (slice ω-imports-using-transition) name
 * optional function-typed fields on `WriteOptions`
 * (e.g. `betweenImportsTailLeafClassify` /
 * `betweenImportsHeadLeafClassify`, each
 * `Null<Dynamic -> Null<{ctorName, path}>>`). When non-null, ctors
 * named in `transparentCtorNames` are routed through the matching
 * direction's adapter at runtime: tail walks the wrapper payload (e.g.
 * `HxConditionalDecl`) to its LAST-branch / LAST-element leaf decl,
 * head walks to FIRST-branch / FIRST-element. Each adapter returns
 * `{ctorName, path}`; the engine runs a runtime
 * `_r.ctorName == 'CtorA' || _r.ctorName == 'CtorB'` filter against
 * the per-info `matchedCtorNames` list — so a single shared adapter
 * pair can feed multiple between infos on the same Star (one walker
 * pair drives both Imports and Usings infos on `HxModule.decls`).
 * Tail feeds the next iteration's prev-side via the track-step;
 * head feeds THIS iteration's curr-side at cascade fire. Either or
 * both adapter fields may be null: the absent direction zeros out
 * its kind/path for transparent ctors (same as the unmatched bucket)
 * while the wired direction's classification still drives the
 * cascade. With both null, transparent ctors fall fully into the
 * unmatched bucket.
 *
 * `transparentCtorNames` lists the wrapper ctor names (e.g.
 * `Conditional`) collected from
 * `@:fmt(blankLinesBetweenSameCtorTailTransparent(classifierField,
 * ctorName, adapterOptField))` and
 * `@:fmt(blankLinesBetweenSameCtorHeadTransparent(...))` metas with
 * matching classifier field — merged across both directions, so any
 * ctor that appears in EITHER meta becomes transparent. Validated
 * arity ≥ 1 (first positional arg is the wrapper payload passed to
 * the adapter pair).
 */
typedef BetweenCtorBlankInfo = {
	classifierFieldName:String,
	ctorPatterns:Array<BetweenCtorPattern>,
	matchedCtorNames:Array<String>,
	levelOptField:String,
	countOptField:String,
	adapterOptField:String,
	tailAdapterOptField:Null<String>,
	headAdapterOptField:Null<String>,
	transparentCtorNames:Array<String>,
};

/**
 * One ESwitch case pattern with its matched/unmatched/transparent flag,
 * used by `BetweenCtorBlankInfo`. Matched-ctor patterns bind `_v0` to
 * the ctor's first positional arg so the cascade-emit phase can read
 * the import / using path String at runtime. Transparent-ctor patterns
 * also bind `_v0` (the wrapper payload, e.g. `HxConditionalDecl`) so
 * the emit phase can pass it to the tail-leaf classifier adapter.
 * Unmatched-ctor patterns use a wildcard for every arg.
 *
 * `isMatch` and `isTransparent` are mutually exclusive — at most one
 * is `true`. `isMatch=true` → kind=1/path=_v0 case body. `isTransparent
 * =true` → adapter-call case body filtered by per-info ctorNames.
 * Both `false` → kind=0/path='' (unmatched fallback).
 */
typedef BetweenCtorPattern = {
	pattern:Expr,
	isMatch:Bool,
	isTransparent:Bool,
};

/**
 * ω-imports-using-transition — resolved data for
 * `@:fmt(blankLinesOnTransitionAcross(classifierField, CtorA1,
 * [CtorA2, …], '|', CtorB1, [CtorB2, …], countOptField))`. Produced by
 * `WriterLowering.buildTransitionAcrossInfo` and spliced into
 * `triviaEofStarExpr`'s per-element loop alongside the
 * `BetweenCtorBlankInfo` family.
 *
 * Fires `opt.<countOptField>` blank lines when prev's tail-classified
 * kind and curr's head-classified kind fall into DIFFERENT subsets
 * (subset A vs subset B): `(prevTailA==1 && currHeadB==1) || (prevTailB
 * ==1 && currHeadA==1) → fire`. Mirrors fork's `MarkEmptyLines.markImports`
 * cross-kind emit (`prevInfo.isImport != newInfo.isImport →
 * emit beforeUsing`).
 *
 * Transparent-ctor support is inherited from the same Star's
 * `blankLinesBetweenSameCtor{Tail,Head}Transparent` metas — the merged
 * `transparentByClassifier` map's adapter pair feeds both the betweenCtor
 * and transitionAcross runtime classifiers, so a single pair of
 * head/tail walkers covers all classifiers on the same Star.
 *
 * `ctorPatterns` carries one entry per enum variant in the classifier
 * target. `subset` selects the case-body shape: 1 for subset A match,
 * 2 for subset B match, 3 for transparent (calls head + tail adapters
 * and sets each direction's A/B flags by ctorName lookup), 0 for
 * unmatched (zero out all flags). Matched-ctor patterns bind `_v0` to
 * the ctor's first positional arg (currently unused at this cascade,
 * reserved for parity with `BetweenCtorBlankInfo` and possible future
 * path-aware transition rules); transparent-ctor patterns also bind
 * `_v0` (the wrapper payload passed to the adapter pair); unmatched
 * patterns wildcard every arg.
 */
typedef TransitionAcrossInfo = {
	classifierFieldName:String,
	ctorPatterns:Array<TransitionAcrossPattern>,
	matchedCtorNamesA:Array<String>,
	matchedCtorNamesB:Array<String>,
	countOptField:String,
	tailAdapterOptField:Null<String>,
	headAdapterOptField:Null<String>,
	transparentCtorNames:Array<String>,
};

/**
 * One ESwitch case pattern with its subset tag for `TransitionAcrossInfo`.
 * `subset`: 1 = matched in subset A, 2 = matched in subset B, 3 =
 * transparent wrapper, 0 = unmatched.
 */
typedef TransitionAcrossPattern = {
	pattern:Expr,
	subset:Int,
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

/**
 * Synth-ctor positional-arg slot kind for `altSlotAccess`. Order MUST
 * mirror `TriviaTypeSynth.buildEnumCtor`'s push order — the walker
 * relies on declaration order to skip slots preceding the requested one.
 */
enum abstract AltSlot(Int) {
	final CloseTrailing = 0;
	final TrailOpt = 1;
	final CaptureSource = 2;
	final BodyPolicyKw = 3;
	final WrapOpenNewline = 4;
	final KwNewline = 5;
	final ChainNewline = 6;
	final ChainLeadComment = 7;
}
#end
