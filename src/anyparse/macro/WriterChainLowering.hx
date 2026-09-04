package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.macro.WriterLowering.ChainDispatchCtx;
import anyparse.macro.WriterLowering.PostfixStarCtx;
import haxe.macro.Context;
import haxe.macro.Expr;

using StringTools;
using Lambda;
using anyparse.macro.MetaInspect;

/**
 * Pass 3W — the `@:fmt(methodChain)` postfix-chain bodies.
 *
 * A method chain (`a.b().c().d()`) is a postfix Star whose layout is
 * decided over the WHOLE chain rather than per element: how many links
 * before it breaks, where the break lands relative to the dot, and
 * whether the source already broke it. `wrapChainTriviaBody` builds
 * that decision for the trivia mode and `wrapChainPlainBody` for the
 * plain one; `locateChainCallBranch` finds the call link the wrap
 * measures from, and the `lowerPostfix*` quartet emits the per-element
 * Doc the wrap composes.
 *
 * Split out of `WriterLowering` as one family: it is entered from
 * `wrapWithChainDispatch` and `lowerPostfixStar` and reaches nothing in
 * the rest of the writer, which is why the two `WriterLowering`
 * sub-module bundles it types its parameters with (`ChainDispatchCtx`,
 * `PostfixStarCtx`) are the entire macro-time contract.
 */
final class WriterChainLowering {

	/**
	 * Locate the Call-shaped sibling branch (a postfix Star carrying
	 * `@:fmt(methodChain(...))`) within an enum node, erroring if absent.
	 *
	 */
	private static function locateChainCallBranch(node: ShapeNode): ShapeNode {
		final callBranch: Null<ShapeNode> = node.children.find(b ->
			b.fmtReadString('methodChain') != null && b.children.length == 2 && b.children[1].kind == Star
		);
		if (callBranch == null)
			Context.error(
				'WriterLowering.methodChain: expected a sibling postfix-Star ctor with @:fmt(methodChain(...))', Context.currentPos()
			);
		return callBranch;
	}

	/**
	 * Build the trivia-mode method-chain walk body for `wrapWithChainDispatch`.
	 * Walks the Call/FieldAccess spine right-to-left collecting per-segment
	 * Docs (and parallel source-newline `_breaks` for `Keep` round-trip),
	 * glues bare leading `.field` accesses, captures the receiver's dot-gap
	 * trailing comment, and dispatches to `MethodChainEmit.emit` for a
	 * 2+-segment chain whose receiver ends in a Call (`)`).
	 */
	private static function wrapChainTriviaBody(c: ChainDispatchCtx): Expr {
		final argsListExpr: Expr = c.argsListExpr;
		final argDocsExpr: Expr = c.argDocsExpr;
		final chainRulesExpr: Expr = c.chainRulesExpr;
		final writeIdent: Expr = c.writeIdent;
		final precExpr: Expr = c.precExpr;
		final segCallLeadingBreakExpr: Expr = c.segCallLeadingBreakExpr;
		final body: Expr = c.body;
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
		return macro {
			final _segs: Array<anyparse.core.Doc> = [];
			// ω-keep-chain (increment 9): `_breaks` is parallel to `_segs`
			// — entry `i` is whether the source had a newline in the gap
			// before segment `i`'s `.field` lead (the FieldAccess ctor's
			// captured `chainNewline` synth slot). Built in lockstep with
			// `_segs.unshift` so a `WrapMode.Keep` method-chain round-trips
			// the source per-segment dot-boundary line breaks via
			// `MethodChainEmit.shapeKeep`. Trivia-mode only; Plain keeps the
			// 2-arg ctor patterns below and threads no `_breaks` (null →
			// shapeNoWrap, byte-inert).
			final _breaks: Array<Bool> = [];
			var _cursor = value;
			var _receiver = value;
			var _hasCallPrev: Bool = false;
			// ω-methodchain-all-or-nothing / isDotAfterPClose: did the dot that
			// leads the INNERMOST collected segment follow a `)`? The walk runs
			// right-to-left, so the last write is that segment's answer. `false`
			// means the segment is not a chain item at all (fork
			// `MarkWrapping.isDotAfterPClose`) and belongs to the head, which
			// `MethodChainEmit.emit` renders by keeping it glued.
			var _seg0AfterCall: Bool = false;
			// ω-keep-chain-receiver-comment: the inner-most FieldAccess carries
			// its operand's dot-gap trailing comment in the synth
			// `chainLeadComment` slot. When that operand IS the chain receiver
			// (a bare value, the `case _:` of the `switch _prev` below), stash
			// the comment so it can be reattached to the receiver Doc after the
			// walk — a `Keep` chain would otherwise drop it when the per-segment
			// break replaces the source `owner // test` layout.
			var _recTrail: Null<String> = null;
			while (true) {
				switch _cursor {
					// ω-keep-callclose-newline: trivia Call ctor grew a 5th
					// positional `argsCloseNewline`; the chain walk ignores it
					// here (close placement is decided by the outer call's
					// `lowerPostfixStar`, not the per-segment chain emit).
					case Call(_op, _args, _trailClose, _, _, _):
						switch _op {
							case FieldAccess(_prev, _fld, _nl, _opTrail):
								final _argDocs: Array<anyparse.core.Doc> = $argDocsExpr;
								final _argsDoc: anyparse.core.Doc = $argsListExpr;
								final _segDoc: anyparse.core.Doc = _trailClose != null
									? _dc([_dt('.' + _fld), _argsDoc, trailingCommentDocVerbatim(_trailClose, opt)])
									: _dc([_dt('.' + _fld), _argsDoc]);
								_segs.unshift(_segDoc);
								_breaks.unshift(_nl);
								switch _prev {
									case Call(_, _, _, _, _, _):
										_hasCallPrev = true;
										_seg0AfterCall = true;
									case _:
										_seg0AfterCall = false;
										if (_opTrail != null) _recTrail = _opTrail;
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
							case Call(_, _, _, _, _, _):
								_hasCallPrev = true;
								_seg0AfterCall = true;
							case _:
								_seg0AfterCall = false;
								if (_opTrail != null) _recTrail = _opTrail;
						}
						_cursor = _prev;
					case _:
						_receiver = _cursor;
						break;
				}
			}
			if (_segs.length >= 1 && _hasCallPrev) {
				final _recBaseDoc: anyparse.core.Doc = $writeIdent(_receiver, opt, $precExpr);
				// ω-keep-chain-receiver-comment: glue the receiver's captured
				// trailing comment (`owner // test`) to its Doc before the first
				// forced segment break. `trailingCommentDocVerbatim` prepends the
				// leading space, so `_dc([recv, ' // test'])` reproduces the source.
				final _recDoc: anyparse.core.Doc = _recTrail != null
					? _dc([_recBaseDoc, trailingCommentDocVerbatim(_recTrail, opt)])
					: _recBaseDoc;
				// ω-methodchain-reeval-after-callparam nest-suppress prereq:
				// a chain that is itself a CALL ARGUMENT (`_callArgChainNest`)
				// keeps its own dot-break — fork
				// `reEvaluateMethodChainAfterCallParam` never strips chain
				// breaks for a chain inside a breaking outer call
				// (`method_chain_single_arg_break_parens`). Mirror the
				// `BinaryChainEmit` `_chainNestSuppress` gate.
				return anyparse.format.wrap.MethodChainEmit.emit(
					_recDoc, _segs, opt, $chainRulesExpr, _breaks, opt._callArgChainNest, $segCallLeadingBreakExpr, _seg0AfterCall
				);
			}
			$body;
		};
	}

	/**
	 * Build the plain-mode method-chain walk body for `wrapWithChainDispatch`
	 * — the no-trivia twin of `wrapChainTriviaBody` (2-arg Call/FieldAccess
	 * ctor patterns, no `_breaks` / receiver-comment slots).
	 */
	private static function wrapChainPlainBody(c: ChainDispatchCtx): Expr {
		final argsListExpr: Expr = c.argsListExpr;
		final argDocsExpr: Expr = c.argDocsExpr;
		final chainRulesExpr: Expr = c.chainRulesExpr;
		final writeIdent: Expr = c.writeIdent;
		final precExpr: Expr = c.precExpr;
		final segCallLeadingBreakExpr: Expr = c.segCallLeadingBreakExpr;
		final body: Expr = c.body;
		return macro {
			final _segs: Array<anyparse.core.Doc> = [];
			var _cursor = value;
			var _receiver = value;
			var _hasCallPrev: Bool = false;
			// ω-methodchain-all-or-nothing / isDotAfterPClose (plain-mode twin of
			// the trivia walk's tracker): did the innermost collected segment's
			// dot follow a `)`?
			var _seg0AfterCall: Bool = false;
			while (true) {
				switch _cursor {
					case Call(_op, _args):
						switch _op {
							case FieldAccess(_prev, _fld):
								final _argDocs: Array<anyparse.core.Doc> = $argDocsExpr;
								final _argsDoc: anyparse.core.Doc = $argsListExpr;
								_segs.unshift(_dc([_dt('.' + _fld), _argsDoc]));
								switch _prev {
									case Call(_, _):
										_hasCallPrev = true;
										_seg0AfterCall = true;
									case _:
										_seg0AfterCall = false;
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
							case Call(_, _):
								_hasCallPrev = true;
								_seg0AfterCall = true;
							case _:
								_seg0AfterCall = false;
						}
						_cursor = _prev;
					case _:
						_receiver = _cursor;
						break;
				}
			}
			if (_segs.length >= 1 && _hasCallPrev) {
				final _recDoc: anyparse.core.Doc = $writeIdent(_receiver, opt, $precExpr);
				// ω-methodchain-reeval-after-callparam nest-suppress prereq
				// (plain-mode twin): pass `sourceBreakBefore = null` then the
				// `_callArgChainNest` gate.
				return anyparse.format.wrap.MethodChainEmit.emit(
					_recDoc, _segs, opt, $chainRulesExpr, null, opt._callArgChainNest, $segCallLeadingBreakExpr, _seg0AfterCall
				);
			}
			$body;
		};
	}

	/**
	 * ω-callarg-own-line-comment: the postfix Star's force-multi shape — one
	 * argument per indented line, each followed by its separator, with an
	 * after-separator trailing comment cuddled onto that separator
	 * (`arg, // note`) and the next hardline terminating it.
	 *
	 * The wrap cascade cannot produce this. Its shapes own the separator, and
	 * `FillLineWithLeadingBreak` builds ONE shared separator Doc reused at every
	 * gap — there is no seam to move a single comma across, and no per-gap flag
	 * (`sepBeforeFlags`) reaches that shape. So a list holding a LINE comment
	 * bypasses the cascade the same way a sep-Star's force-multi branch does: a
	 * `//` runs to the newline, which leaves exactly one legal layout anyway.
	 *
	 * Structurally `lowerPostfixKeepDoc` with an unconditional hardline per
	 * element instead of the source-newline probe. Reads the trailing slots
	 * directly (not `_docs`) because the element loop deliberately leaves an
	 * after-separator comment out of the element's own Doc — its position is a
	 * property of the gap, not of the element.
	 *
	 * The separator is SOURCE-faithful, not positional: `Trivial.sepAfter` says
	 * whether the source actually wrote one. A conditional group that absorbed
	 * the comma (`g(true #if F, false #end, x)`) elides it at that gap, and
	 * emitting one anyway produces `g(true, , x)` once the branch is off — code
	 * that no longer parses, and that the comment-loss guard cannot see because
	 * every comment survived. Same signal the cascade path threads to
	 * `WrapList.emit` as `sepBeforeFlags`.
	 */
	private static function lowerPostfixForceMultiDoc(c: PostfixStarCtx): Expr {
		final tcExpr: Expr = c.tcExpr;
		return macro {
			final _mInner: Array<anyparse.core.Doc> = [];
			var _mj: Int = 0;
			while (_mj < _docs.length) {
				_mInner.push(_dhl());
				_mInner.push(_docs[_mj]);
				final _mTc: Null<String> = _args[_mj].trailingComment;
				final _mAfterSep: Null<String> = _args[_mj].trailingBeforeSep ? null : _mTc;
				// Between elements only when the source wrote a separator there; on the
				// last element when the config asks for a trailing one OR the source
				// itself put one (which is what an after-separator comment proves).
				final _mLast: Bool = _mj == _docs.length - 1;
				if ((!_mLast && _args[_mj].sepAfter) || (_mLast && $tcExpr) || _mAfterSep != null) _mInner.push(_dt($v{c.elemSep}));
				if (_mAfterSep != null) _mInner.push(trailingCommentDocVerbatim(_mAfterSep, opt));
				_mj++;
			}
			final _mCols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			_dwb(_dc([_dt($v{c.postfixOp}), _dn(_mCols, _dc(_mInner)), _dhl(), _dt($v{c.postfixClose})]));
		};
	}

	/**
	 * Build the source-faithful `Keep`-mode args-list Doc for a trivia
	 * postfix Star. The `ω-D9A-keep-callargs` per-arg hand-built layout (`_dhl()` where source
	 * had a newline before the next arg, `_dt(' ')` otherwise) plus the
	 * `argsOpenNewline` leading/trailing hardlines.
	 */
	private static function lowerPostfixKeepDoc(c: PostfixStarCtx): Expr {
		final postfixOp: String = c.postfixOp;
		final postfixClose: String = c.postfixClose;
		final elemSep: String = c.elemSep;
		final tcExpr: Expr = c.tcExpr;
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
		final argsOpenNewlineExpr: Expr = { expr: EConst(CIdent(c.argNames[3])), pos: Context.currentPos() };
		return macro {
			final _kArgsOpenNewline: Bool = $argsOpenNewlineExpr;
			final _kInner: Array<anyparse.core.Doc> = [];
			var _kj: Int = 0;
			while (_kj < _docs.length) {
				if (_kj > 0)
					_kInner.push(_args[_kj].newlineBefore ? _dhl() : _dt(' '));
				else if (_kArgsOpenNewline)
					_kInner.push(_dhl());
				_kInner.push(_docs[_kj]);
				final _kIsLast: Bool = _kj == _docs.length - 1;
				if (!_kIsLast)
					_kInner.push(_dt($v{elemSep}));
				else if ($tcExpr)
					_kInner.push(_dt($v{elemSep}));
				_kj++;
			}
			final _kCols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			final _kOuter: Array<anyparse.core.Doc> = [
				_dt($v{postfixOp}),
				_dn(_kCols, _dc(_kInner)),
			];
			if (_kArgsOpenNewline) _kOuter.push(_dhl());
			_kOuter.push(_dt($v{postfixClose}));
			_dwb(_dc(_kOuter));
		};
	}

	/**
	 * Build the per-iteration `_docs.push(...)` statement for a postfix Star.
	 * In trivia mode it appends the element's verbatim `trailingComment` after
	 * the element Doc; plain mode pushes the bare element.
	 */
	private static function lowerPostfixPushElem(c: PostfixStarCtx): Expr {
		final elemCall: Expr = c.elemCall;
		return c.isTriviaStar
			? macro {
				final _elem: anyparse.core.Doc = $elemCall;
				final _tc: Null<String> = _args[_i].trailingComment;
				// ω-callarg-after-sep-comment: the parser routes a same-line LINE
				// comment that followed the separator into THIS element's trailing
				// slot with `trailingBeforeSep == false`. The separator itself belongs
				// to the layout engine — and one of its shapes
				// (`FillLineWithLeadingBreak`) builds ONE shared separator Doc for
				// every gap, so it cannot be told to move or skip a single one. Such a
				// comment therefore does not go into this element's Doc at all: it is
				// read straight from the slot by `lowerPostfixForceMultiDoc`, which
				// owns both the separator and the line break around it.
				//
				// Scope: this Doc feeds the plain-call path. A call that is a
				// METHOD-CHAIN segment is re-assembled by `wrapWithChainDispatch`'s
				// own per-argument builder, which appends the trailing slot
				// unconditionally and never consults `_forceArgMulti` — so a chained
				// call keeps the pre-separator placement (`m(1 // c\n, 2).n()`).
				// Parseable, idempotent, and strictly better than the refusal it
				// replaces, but not the same shape; moving the chain emitter onto this
				// rule is its own slice.
				final _tcAfterSep: Bool = _tc != null && !_args[_i].trailingBeforeSep;
				if (_tcAfterSep) _forceArgMulti = true;
				// `trailingCommentDocGuarded` already prepends ' ' to
				// the captured content, so the per-arg Doc is just
				// `_elem ++ trailingDoc` — no extra `_dt(' ')`.
				// Group-closer seam: this Star owns the whole `(args)` postfix,
				// so its close paren is emitted on the SAME Doc line as the last
				// argument. A LINE comment cuddled there terminates at `\n` and
				// swallows the `)` (and every token after it up to the source
				// newline), which is why `g(\n\ta // c\n);` used to re-emit as
				// `g(a // c);` - a file that no longer parses. The guarded
				// emitter appends an `OptHardlineSkipBeforeHardline`, which both
				// refuses the flat fit (so the `)` lands on its own line) and
				// drops when the next emit is already a hardline. Inside a
				// force-flat region the renderer DROPS it instead, so
				// `WrapList.shapeNoWrap` skips its `Flatten` marker for a
				// guard-bearing body - the two halves together keep the `)` off
				// the comment's line under ANY wrap cascade. Every sound seam
				// stays byte-identical, and a block comment keeps its legal glue.
				// A BEFORE-separator trailing comment is NOT a force-multi trigger:
				// `trailingCommentDocGuarded`'s render-time break already keeps the
				// following token off its line, whatever shape the cascade picked.
				// Widening the trigger to it would re-wrap every `arg // noqa` call
				// in the tree for no correctness gain.
				var _elemDoc: anyparse.core.Doc = _tc != null && !_tcAfterSep ? _dc([_elem, trailingCommentDocGuarded(_tc, opt)]) : _elem;
				// ω-callarg-leading-comment: glue a captured inline block leading
				// comment before the argument (`/* c */ arg`).
				// ω-callarg-own-line-comment: a LINE comment (or a multi-line block)
				// cannot share the argument's line — it is emitted above the argument
				// with a hardline between, and the list goes force-multi so the open
				// delimiter can never end up glued in front of it. Before this it had
				// nowhere to go and was DROPPED.
				final _lc: Array<String> = _args[_i].leadingComments;
				if (_lc.length > 0) {
					final _leadParts: Array<anyparse.core.Doc> = [];
					// Index-based: `leadingCommentDocRun` is run-aware (it needs the
					// entry's neighbours to compute a run-wide common indent).
					for (_ci in 0..._lc.length) {
						final _c: String = _lc[_ci];
						final _inlineBlock: Bool = StringTools.startsWith(_c, '/*') && _c.indexOf('\n') < 0;
						if (!_inlineBlock) _forceArgMulti = true;
						_leadParts.push(leadingCommentDocRun(_lc, _ci, opt));
						_leadParts.push(_inlineBlock ? _dt(' ') : _dhl());
					}
					_leadParts.push(_elemDoc);
					_elemDoc = _dc(_leadParts);
				}
				_docs.push(_elemDoc);
			}
			: macro _docs.push($elemCall);
	}

	/**
	 * Build the postfix Star's tail expression — the final Doc value of the
	 * generated body. In trivia mode it appends the synth `closeTrailing`
	 * slot's verbatim same-line comment after the assembled call Doc; plain
	 * mode returns the call Doc directly.
	 */
	private static function lowerPostfixTailExpr(c: PostfixStarCtx, dcExpr: Expr): Expr {
		// ω-postfix-call-trailing: when the synth pair grew a
		// `closeTrailing:Null<String>` slot (gated by `isTriviaStar`,
		// which is the same predicate as `isPostfixCloseTrailingBranch`
		// at this site), append `trailingCommentDocGuarded(_trailClose,
		// opt)` after the call's emitted Doc when non-null. The slot
		// holds a same-line trailing `// c` / `/* c */` between `)` and
		// the next expression boundary — captured by Lowering's
		// `lowerPostfixLoop` Star-suffix trivia branch. For chain Calls
		// the chain extractor (`wrapWithChainDispatch`) handles the same
		// slot per segment via its own dispatch; this default-path
		// emission covers non-chain single Calls.
		//
		// Group-closer seam: whatever follows the call on the same Doc line
		// - the statement `;`, an infix tail (`+ 2`), an enclosing call's
		// `)` - is swallowed by a LINE comment emitted here. `return g(1) //
		// c` + newline + `+ 2;` re-emitted as `return g(1) // c + 2;`, which
		// still PARSES and silently drops the `+ 2`. The guarded emitter
		// forces the break; it drops before an already-hardline next emit
		// (the chain-segment `.n()` case), so sound seams stay byte-identical.
		if (!c.isTriviaStar) return dcExpr;
		final closeTrailRef: Expr = {
			expr: EConst(CIdent(c.argNames[2])),
			pos: Context.currentPos()
		};
		return macro {
			final _dcResult: anyparse.core.Doc = $dcExpr;
			final _trailClose: Null<String> = $closeTrailRef;
			_trailClose != null ? _dc([_dcResult, trailingCommentDocGuarded(_trailClose, opt)]) : _dcResult;
		};
	}

}
#end
