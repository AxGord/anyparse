package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * Which `WriteOptions` context flag a generated shim sets or clears.
 *
 * The text writer threads ONE options record down the whole emit. A
 * layout decision that depends on where a node sits — an expression
 * position, an arrow-lambda body, a typedef body, a chain inside a
 * paren — is carried as a field on that record, and the generated
 * writer reaches it through a `_setXxx` / `_clearXxx` shim this module
 * emits. Every member here answers one half of that: which shims a
 * grammar gets (`pushOptFanoutHelpers`, gated per field on the opt
 * typedef via `optionsHasField`), and what one shim's body looks like
 * (the `set*Field` / `clear*Field` pair per flag).
 *
 * `chainBaseArg` and `copyOptField` are the mechanism the whole family
 * shares: `_copyOpt` is the record clone, and `_b` is the chain-root
 * argument that lets a composed chain of shims mutate the clone the
 * previous step already made instead of minting one per step. Both are
 * called from nowhere else — `chainBaseArg`'s 39 callers are exactly
 * the shims below.
 *
 * Split out of `WriterCodegen`, which kept the entry points, the
 * per-rule fields and the Doc / layout / comment helpers. Nothing here
 * reads state: `WriterCodegen` declared no field at all, so the split
 * is by QUESTION, not by a state seam. `WriterCodegen` reaches these
 * members unqualified through `import anyparse.macro.WriterOptFanout.*;`
 * plus a class-level `@:access`, so the move rewrote no call site.
 */
final class WriterOptFanout {

	/**
	 * ω-issue-423-mech-a — true iff the writer's `WriteOptions` typedef
	 * carries the `_inExprPosition:Bool` field. Used to gate emission
	 * of the `_setExprPosition` helper: grammars whose options struct
	 * doesn't declare the field (Json, Bin, etc.) skip the helper to
	 * avoid a compile-time field-resolution error inside its body.
	 *
	 * Walks `TType`/`TAnon` so it sees the intersection-typedef form
	 * (`HxModuleWriteOptions = WriteOptions & {...}`) — `getType`
	 * resolves to the alias before unification. `TLazy` is followed
	 * eagerly to handle forward-referenced typedefs.
	 */
	private static inline function optionsHasInExprPosition(optionsTypePath: String): Bool {
		return optionsHasField(optionsTypePath, '_inExprPosition');
	}

	/**
	 * ω-optclone-chain-fusion — the trailing `_b` (chain-base) argument every
	 * opt-fanout shim carries.
	 *
	 * A composition site threads one opt through several shims in ONE emitted
	 * expression (`_setSuppressCallRestProbe(_setCallArgChainNest(_setExprPosition(opt)))`).
	 * Each shim used to clone, so a three-step chain minted three 210-field
	 * records where one would do: on a real tree 48 % of every `_copyOpt` call
	 * had a source object the PREVIOUS step had just created, and threading the
	 * base retired 34.7 % of the calls outright.
	 *
	 * `_b` is the chain's ROOT expression. It is spelled with the same
	 * identifier (`opt`) as the root and sits in the same scope, so the two
	 * always denote the same binding — including where generated code rebinds
	 * `opt` (`final opt = _setParenInCondition(… opt …, opt)`, whose `_b` still
	 * resolves to the outer one). An incoming `o` that is not `_b` can
	 * therefore only be a clone an EARLIER step of the same expression just
	 * made: it is reachable from nowhere else, so the shim mutates it in place
	 * instead of cloning again. The first step still clones, and a callee
	 * re-roots at its own `opt`, so ownership never crosses a call boundary —
	 * which is what keeps the output byte-identical.
	 *
	 * The `_b != null` conjunct is load-bearing, not defensive: `o` is never
	 * null, so a bare `o != _b` would read as `true` at every site that passes
	 * no base and would license in-place mutation there.
	 *
	 * One rule for a shim body: after the clone line, only WRITE `_c` — never
	 * read `o` for a field already written, since on the fusion path `_c` and
	 * `o` are the same record. Hoist such reads above the clone line the way
	 * `_setChainModeOverride` does.
	 *
	 * Defaults to `null` (own nothing, always clone), so an emission site that
	 * has not been audited for its chain root stays on the old behaviour.
	 */
	private static inline function chainBaseArg(optionsCT: ComplexType): FunctionArg {
		return { name: '_b', type: macro :Null<$optionsCT>, value: macro null };
	}

	/**
	 * ω-anonfunction-empty-curly — generic field-presence probe sister
	 * to `optionsHasInExprPosition`. Walks the same `TType`/`TAnon`
	 * intersection chain so it sees the merged `HxModuleWriteOptions =
	 * WriteOptions & {...}` shape. Used to gate the emission of
	 * per-flag opt-fanout helpers (`_setAnonFnBody` etc.) so that
	 * grammars whose options struct doesn't declare the matching
	 * internal flag skip the helper.
	 */
	private static function optionsHasField(optionsTypePath: String, fieldName: String): Bool {
		final t: Null<haxe.macro.Type> = try Context.getType(optionsTypePath) catch (e: haxe.Exception) null;
		return t != null && anonHasField(t, fieldName);
	}

	private static function anonHasField(t: haxe.macro.Type, name: String): Bool {
		switch (t) {
			case TLazy(f):
				return anonHasField(f(), name);
			case TType(_, _):
				return anonHasField(Context.follow(t), name);
			case TAnonymous(aRef):
				final fields: Array<haxe.macro.Type.ClassField> = aRef.get().fields;
				for (cf in fields) if (cf.name == name) return true;
				return false;
			case _:
				return false;
		}
	}

	/**
	 * Every field name of the writer options struct, base-first.
	 *
	 * The options typedef is an intersection (`HxModuleWriteOptions =
	 * WriteOptions & {...}`), and the compiler already merges both halves
	 * into the resolved anon's own `fields` — measured: 210 for
	 * `HxModuleWriteOptions`, 21 base + 189 own. The `AExtend` walk is
	 * therefore not what makes the list complete; it only groups the base's
	 * fields first, and it is insurance against a future compiler
	 * representation that leaves the halves unmerged.
	 *
	 * Order inside each group is whatever `AnonType.fields` yields, which is
	 * ALPHABETICAL, not declaration order — so the emitted clone does NOT
	 * share a hidden class with a format's hand-written `defaultWriteOptions`
	 * literal. Harmless at the measured ratio (a handful of root objects
	 * against ~246 000 clones), but the macro API exposes no declaration
	 * order, so matching it is not a cheap change.
	 *
	 * An empty result means the path did not resolve to an anon; the caller
	 * falls back to `Reflect.copy` rather than emitting a literal that would
	 * drop fields.
	 */
	private static function optionsFieldNames(optionsTypePath: String): Array<String> {
		final t: Null<haxe.macro.Type> = try Context.getType(optionsTypePath) catch (e: haxe.Exception) null;
		final names: Array<String> = [];
		if (t != null) collectAnonFieldNames(t, names);
		return names;
	}

	private static function collectAnonFieldNames(t: haxe.macro.Type, out: Array<String>): Void {
		switch (t) {
			case TLazy(f):
				collectAnonFieldNames(f(), out);
			case TType(_, _):
				collectAnonFieldNames(Context.follow(t, true), out);
			case TAnonymous(aRef):
				final anon: haxe.macro.Type.AnonType = aRef.get();
				switch (anon.status) {
					case AExtend(tl):
						for (base in tl.get()) collectAnonFieldNames(base, out);
					case _:
				}
				for (cf in anon.fields) if (!out.contains(cf.name))
					out.push(cf.name);
			case _:
		}
	}

	/**
	 * ω-expression-case-flat-fanout helper — typed shallow copy of `opt`.
	 *
	 * Emits a monomorphic structural clone: an object literal naming every
	 * field of the options struct (`{f1: o.f1, …}`), which the macro knows
	 * at compile time. `Reflect.copy` on js is a `for…in` walk with a
	 * dynamic read per field and measured 50.7 % of writer self-CPU
	 * (245 912 copies × 210 fields on the anyparse tree); the literal is one
	 * hidden class and one store per field. `Object.assign({}, o)` is NOT an
	 * alternative — it measured 1.8× worse than `Reflect.copy`.
	 *
	 * The helper is deliberately NOT `AInline`: a 210-field literal expanded
	 * into the ~1000 call sites would add megabytes to the js bundle and
	 * blow the JVM 64 KB method-body limit. One out-of-line function keeps a
	 * single literal site, so every clone shares one hidden class.
	 *
	 * Falls back to `Reflect.copy` when the options type does not resolve
	 * to an anon (no field list to enumerate), and warns at compile time so
	 * a grammar silently losing the fast path is visible. Only that branch
	 * returns `Null<T>` — which strict null safety refuses to narrow at the
	 * call site — so `@:nullSafety(Off)` is attached to it alone; the
	 * literal path stays strict-checked.
	 *
	 * Used by `triviaTryparseStarExpr` when a Star carries
	 * `@:fmt(flatChildOpt(...))` and by every opt-fanout helper below — the
	 * runtime needs a per-call mutable copy to override knob fields without
	 * touching the shared `opt` singleton.
	 */
	private static function copyOptField(optionsTypePath: String, optionsCT: ComplexType): Field {
		final names: Array<String> = optionsFieldNames(optionsTypePath);
		final pos: Position = Context.currentPos();
		final fallback: Bool = names.length == 0;
		if (fallback)
			Context.warning(
				'WriterCodegen: options type $optionsTypePath did not resolve to an anon — _copyOpt falls back to Reflect.copy', pos
			);
		final body: Expr = if (fallback)
			macro {
				final _c: $optionsCT = cast Reflect.copy(o);
				if (_c == null) throw 'WriterCodegen._copyOpt: Reflect.copy returned null';
				return _c;
			}
		else {
			final objFields: Array<ObjectField> = [
				for (n in names) { field: n, expr: { expr: EField(macro o, n), pos: pos } }
			];
			final literal: Expr = { expr: EObjectDecl(objFields), pos: pos };
			macro return $literal;
		};
		return {
			name: '_copyOpt',
			access: [APrivate, AStatic],
			meta: fallback ? [{ name: ':nullSafety', params: [macro Off], pos: pos }] : [],
			kind: FFun({ args: [{ name: 'o', type: optionsCT }], ret: optionsCT, expr: body }),
			pos: pos
		};
	}

	/**
	 * ω-issue-423-mech-a — opt-fanout shim for the `propagateExprPosition`
	 * meta. Idempotent: returns `o` unchanged when `_inExprPosition` is
	 * already `true` (avoids per-call allocation in already-propagating
	 * descendant chains); otherwise returns a `_copyOpt(o)` with the
	 * flag flipped on. Emitted unconditionally so consumer call sites
	 * (Ref-field writer call, sep-Star element call, kw-Ref ctor body
	 * sub-call) can invoke it without per-grammar gating.
	 *
	 * Signature requires `_inExprPosition:Bool` on the opt typedef —
	 * grammars whose `HxModuleWriteOptions`-equivalent struct lacks the
	 * field would fail field-resolution at codegen time. Currently
	 * declared on `HxModuleWriteOptions` only (Haxe grammar).
	 *
	 * ω-expressionif-collapse: when the opt typedef ALSO carries
	 * `_inValueIfBranch:Bool` (`clearsValueIfBranch == true`), entering a
	 * fresh expression-position frame CLEARS that narrow flag — a call
	 * argument / array element / operand / arrow body is a new value
	 * context, never the immediate value of a value-if branch. This is
	 * the consumed-once discipline: the flag set on a branch value
	 * survives only the transparent descent into the branch's own object
	 * literal (those ctors carry no `propagateExprPosition`, so they never
	 * call this helper), and is dropped the moment a propagating ctor
	 * re-establishes expression position one level deeper.
	 */
	private static function setExprPositionField(
		optionsCT: ComplexType, clearsValueIfBranch: Bool, clearsArrowLambdaBody: Bool, clearsArrowValueIfBlocked: Bool
	): Field {
		var guard: Expr = macro o._inExprPosition;
		if (clearsValueIfBranch) guard = macro $guard && !o._inValueIfBranch;
		if (clearsArrowLambdaBody) guard = macro $guard && !o._inArrowLambdaBody;
		if (clearsArrowValueIfBlocked) guard = macro $guard && !o._arrowValueIfBlocked;
		final clears: Array<Expr> = [];
		if (clearsValueIfBranch) clears.push(macro _c._inValueIfBranch = false);
		if (clearsArrowLambdaBody) clears.push(macro _c._inArrowLambdaBody = false);
		if (clearsArrowValueIfBlocked) clears.push(macro _c._arrowValueIfBlocked = false);
		final body: Expr = macro {
			if ($guard) return o;
			final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
			_c._inExprPosition = true;
			$b{clears};
			return _c;
		};
		return {
			name: '_setExprPosition',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-expressionif-collapse — opt-fanout shim for the
	 * `propagateValueIfBranch` meta on `HxIfExpr.thenBranch` / `elseBranch`.
	 * Sets the narrow `_inValueIfBranch` flag ONLY when the branch is
	 * value-yielded — gated on `o._inExprPosition` so a statement-position
	 * `if` (whose branches are statements, not values) never flips it.
	 * Idempotent: returns `o` unchanged when not in expression position or
	 * when the flag is already set. Read by `HxObjectLit.fields`
	 * (`@:fmt(reflowInExprPosition)`) to collapse a source-multiline object
	 * literal that is the direct branch value. Emitted only when the opt
	 * typedef carries `_inValueIfBranch:Bool`.
	 * ω-case-sibling-symmetry — opt-fanout shim for the
	 * `caseSiblingSymmetry` meta on a case-list Star. Stamps the switch's
	 * widest-sibling flat width onto the element opt so every sibling body
	 * reaches the same placement verdict.
	 *
	 * Unlike the boolean `_set*` shims this is a SETTER with a value and no
	 * idempotence short-circuit on "already set": the width is per-switch,
	 * so a nested switch must OVERWRITE the enclosing one's rather than
	 * inherit it. It does short-circuit when the value is already equal,
	 * which is the common no-coordination case (`-1` into `-1`) and keeps
	 * the allocation off every non-switch Star. Emitted only when the opt
	 * typedef carries `_caseSiblingFlatWidth:Int`.
	 */
	private static function setCaseSiblingWidthField(optionsCT: ComplexType): Field {
		return {
			name: '_setCaseSiblingWidth',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [
					{ name: 'o', type: optionsCT },
					{ name: 'w', type: macro :Int },
					chainBaseArg(optionsCT)
				],
				ret: optionsCT,
				expr: macro {
					if (o._caseSiblingFlatWidth == w) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._caseSiblingFlatWidth = w;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	private static function setValueIfBranchField(optionsCT: ComplexType): Field {
		return {
			name: '_setValueIfBranch',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (!o._inExprPosition || o._inValueIfBranch) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._inValueIfBranch = true;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-expressionif-collapse — sister reset to `_setValueIfBranch`.
	 * Returns `o` unchanged when `_inValueIfBranch` is already `false`;
	 * otherwise returns a `_copyOpt(o)` with the flag cleared. Consumed by
	 * `triviaBlockStarExpr`'s per-element call when the parent Star carries
	 * `@:fmt(clearExprPositionNonTail)` (BlockExpr): an object literal
	 * inside a BLOCK-shaped branch (`if (c) { …; {obj} }`) is the value of
	 * the block, not the immediate value of the value-if branch, so the
	 * narrow collapse frame must not reach it — the block is an opaque
	 * barrier for the value-if-branch semantic even though the block's tail
	 * keeps the broad `_inExprPosition` frame. Emitted alongside
	 * `_setValueIfBranch`.
	 */
	private static function clearValueIfBranchField(optionsCT: ComplexType): Field {
		return {
			name: '_clearValueIfBranch',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (!o._inValueIfBranch) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._inValueIfBranch = false;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * omega-arrow-value-if-reflow - opt-fanout setter for the chain-refusal
	 * descent signal. An `HxIfExpr` that refuses the arrow-body reflow (a
	 * comment anywhere on its `else`-spine) stamps this on both branch writes
	 * so every deeper member of the SAME chain reads the refusal too - without
	 * it the member holding the comment keeps its policy shape while the
	 * comment-free tail re-flows, and the output carries both forms at once.
	 *
	 * Deliberately its OWN field rather than a clear of `_inArrowLambdaBody`:
	 * that flag is a shared context signal the object-literal arrow knobs also
	 * read, so borrowing it as a private refusal channel silently disabled the
	 * objlit open-pad / reflow inside the refused branch.
	 *
	 * Idempotent, and cleared by `_setExprPosition` on any fresh
	 * expression-position frame, so it never leaves the chain that set it.
	 * omega-arrow-value-if-reflow - opt-fanout setter for the ELEMENT-trailing
	 * refusal signal, set by a list Star on the element whose captured trailing
	 * comment sits right after it (`@:fmt(arrowValueIfElemTrail)`).
	 *
	 * Unlike `_setArrowValueIfBlocked`, this one is NOT cleared by
	 * `_setExprPosition`: the comment's owner is the element, and the chain it
	 * has to reach lives two expression-position frames deeper (the call
	 * argument, then the arrow-lambda body). A clear on either frame would
	 * throw the signal away before it arrives. It stays confined anyway - it is
	 * stamped per element, so a sibling element never sees it.
	 */
	private static function setArrowValueIfElemTrailCommentField(optionsCT: ComplexType): Field {
		return {
			name: '_setArrowValueIfElemTrailComment',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (o._arrowValueIfElemTrailComment) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._arrowValueIfElemTrailComment = true;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	private static function setArrowValueIfBlockedField(optionsCT: ComplexType): Field {
		return {
			name: '_setArrowValueIfBlocked',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (o._arrowValueIfBlocked) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._arrowValueIfBlocked = true;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	private static function setArrowLambdaBodyField(optionsCT: ComplexType): Field {
		return {
			name: '_setArrowLambdaBody',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (o._inArrowLambdaBody) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._inArrowLambdaBody = true;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	private static function clearArrowLambdaBodyField(optionsCT: ComplexType): Field {
		return {
			name: '_clearArrowLambdaBody',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (!o._inArrowLambdaBody) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._inArrowLambdaBody = false;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-value-yielded-if-tail-barrier — sister reset helper to
	 * `_setExprPosition`. Returns the input opt unchanged when
	 * `_inExprPosition` is already `false` (no allocation on non-expr
	 * descents); otherwise returns a `_copyOpt(o)` with the flag cleared.
	 * Consumed by `triviaBlockStarExpr`'s per-element call when the parent
	 * Star carries `@:fmt(clearExprPositionNonTail)` (BlockExpr / BlockStmt)
	 * so the expression-position frame is cleared for every NON-tail block
	 * statement — a Haxe block yields the value of its LAST statement, so
	 * only the tail keeps `_inExprPosition`. Emitted only when the opt
	 * typedef carries `_inExprPosition:Bool` — paired with `_setExprPosition`
	 * emission.
	 */
	private static function clearExprPositionField(optionsCT: ComplexType): Field {
		return {
			name: '_clearExprPosition',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (!o._inExprPosition) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._inExprPosition = false;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-elseif-body-break — opt-fanout setter for `@:fmt(propagateElseIfBranch)`
	 * on `HxIfStmt.elseBody`. Flips `_inElseIfBranch` on so the inner `else if`'s
	 * then-body fit-gate breaks a fitting single-statement body (fork's
	 * `MarkSameLine.isPartOfIfElse` "if inside else" clause). Idempotent: returns
	 * `o` unchanged when the flag is already set. Emitted only when the opt
	 * typedef carries `_inElseIfBranch:Bool`.
	 */
	private static function setElseIfBranchField(optionsCT: ComplexType): Field {
		return {
			name: '_setElseIfBranch',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (o._inElseIfBranch) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._inElseIfBranch = true;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-elseif-body-break — sister clear to `_setElseIfBranch`. The signal is a
	 * one-level marker (mirrors the fork's local tree check), so the inner
	 * `if`'s then-body recursion (`@:fmt(clearElseIfBranch)`) drops it before
	 * rendering the body content — a statement nested inside the else-if body is
	 * not itself an else-branch. Idempotent: returns `o` unchanged when the flag
	 * is already false (no allocation on the common non-else-if descent).
	 */
	private static function clearElseIfBranchField(optionsCT: ComplexType): Field {
		return {
			name: '_clearElseIfBranch',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (!o._inElseIfBranch) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._inElseIfBranch = false;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-anonfunction-empty-curly — opt-fanout shim for the
	 * `propagateAnonFnContext` meta. Idempotent sister to
	 * `_setExprPosition` — returns `o` unchanged when `_inAnonFnBody`
	 * is already `true`; otherwise returns a `_copyOpt(o)` with the
	 * flag flipped on. Consumed at `HxFnExpr.body`'s optional-Ref
	 * writer call site to flag the descendant `HxFnBlock.stmts`
	 * emptyCurlyBreak emit so it reads `opt.anonFunctionEmptyCurly`
	 * instead of `opt.emptyCurly`. Emitted only when the opt typedef
	 * declares `_inAnonFnBody:Bool` (currently `HxModuleWriteOptions`).
	 */
	private static function setAnonFnBodyField(optionsCT: ComplexType): Field {
		return {
			name: '_setAnonFnBody',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (o._inAnonFnBody) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._inAnonFnBody = true;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-arrow-lambda-body-context — sister reset helper to
	 * `_setAnonFnBody`. Returns the input opt unchanged when
	 * `_inAnonFnBody` is already `false` (no allocation in non-lambda
	 * descents); otherwise returns a `_copyOpt(o)` with the flag
	 * cleared. Consumed by `triviaBlockStarExpr`'s per-element call
	 * when the parent Star carries `@:fmt(leftCurlyAnonFnOverride(...))`
	 * so the anon-fn brace placement decision is consumed exactly once
	 * at `HxExpr.BlockExpr` and nested statements / nested `BlockExpr`
	 * inside the body fall back to the default `blockLeftCurly` knob.
	 * Emitted only when the opt typedef carries `_inAnonFnBody:Bool` —
	 * paired with `_setAnonFnBody` emission.
	 */
	private static function clearAnonFnBodyField(optionsCT: ComplexType): Field {
		return {
			name: '_clearAnonFnBody',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (!o._inAnonFnBody) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._inAnonFnBody = false;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-typedef-anon-force-multi — opt-fanout shim for the
	 * `propagateTypedefContext` meta. Idempotent sister to
	 * `_setAnonFnBody` — returns `o` unchanged when `_inTypedefBody` is
	 * already `true`; otherwise returns a `_copyOpt(o)` with the flag
	 * flipped on. Consumed at `HxTypedefDecl.type`'s Ref writer call
	 * site to flag the descendant `HxType.Anon.fields` Star so the
	 * `forceMultiInTypedef` predicate threads `WrapMode.OnePerLine`
	 * into `WrapList.emit`, forcing typedef-RHS anons to multi-line
	 * layout even when fields fit flat. Emitted only when the opt
	 * typedef declares `_inTypedefBody:Bool`.
	 */
	private static function setTypedefBodyField(optionsCT: ComplexType): Field {
		return {
			name: '_setTypedefBody',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (o._inTypedefBody) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._inTypedefBody = true;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-typedef-anon-force-multi — sister reset helper to
	 * `_setTypedefBody`. Returns the input opt unchanged when
	 * `_inTypedefBody` is already `false`; otherwise returns a
	 * `_copyOpt(o)` with the flag cleared. Consumed by the
	 * `HxType.Anon.fields` per-element call when the parent Star
	 * carries `@:fmt(forceMultiInTypedef)` so the force-multi
	 * decision fires exactly once at the outermost typedef-RHS anon
	 * and nested anon types inside the body fall back to the default
	 * fit-driven `wrapRules` cascade. Emitted only when the opt
	 * typedef carries `_inTypedefBody:Bool` — paired with
	 * `_setTypedefBody` emission.
	 */
	private static function clearTypedefBodyField(optionsCT: ComplexType): Field {
		return {
			name: '_clearTypedefBody',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (!o._inTypedefBody) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._inTypedefBody = false;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-typedef-intersection-operand-break — opt-fanout shim for the per-
	 * element `& Type`-clause break in `HxTypedefDecl.intersections`.
	 * Idempotent sister to `_setTypedefBody` — returns `o` unchanged when
	 * `_intersectionOperandBreak` is already `true`; otherwise returns a
	 * `_copyOpt(o)` with the flag flipped on. Consumed by the trivia-Star
	 * loop when the prior `& Type` clause rendered multi-line and ended with
	 * a close brace, so the next clause's `@:fmt(typedefIntersectionBreak)`
	 * lead breaks `&\n\t` before the operand. Emitted only when the opt
	 * typedef declares `_intersectionOperandBreak:Bool`.
	 */
	private static function setIntersectionBreakField(optionsCT: ComplexType): Field {
		return {
			name: '_setIntersectionBreak',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (o._intersectionOperandBreak) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._intersectionOperandBreak = true;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-fieldlevel-var-value-expr-indent — opt-fanout shim for the
	 * `propagateFieldLevelVar` meta. Idempotent sister to `_setExprPosition`
	 * — returns `o` unchanged when `_inFieldLevelVar` is already `true`;
	 * otherwise returns a `_copyOpt(o)` with the flag flipped on. Consumed at
	 * `HxClassMember.VarMember` / `FinalMember`'s single-Ref ctor opt-arg so
	 * the descendant `HxVarDecl.init` write forces the
	 * `indentComplexValueExpressions` value-expr indent (fork's
	 * `Indenter.isFieldLevelVar`). Emitted only when the opt typedef declares
	 * `_inFieldLevelVar:Bool` (currently `HxModuleWriteOptions`).
	 */
	private static function setFieldLevelVarField(optionsCT: ComplexType): Field {
		return {
			name: '_setFieldLevelVar',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (o._inFieldLevelVar) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._inFieldLevelVar = true;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-fieldlevel-var-value-expr-indent — sister reset helper to
	 * `_setFieldLevelVar`. Returns the input opt unchanged when
	 * `_inFieldLevelVar` is already `false`; otherwise returns a `_copyOpt(o)`
	 * with the flag cleared. Threaded into a function-body writer call so a
	 * local `var x = if (…)` nested inside a member initializer reverts to the
	 * knob-gated value-expr indent — matching fork's candidate walk that
	 * returns false once a `KwdFunction` is crossed. Emitted only when the opt
	 * typedef carries `_inFieldLevelVar:Bool` — paired with `_setFieldLevelVar`
	 * emission.
	 */
	private static function clearFieldLevelVarField(optionsCT: ComplexType): Field {
		return {
			name: '_clearFieldLevelVar',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (!o._inFieldLevelVar) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._inFieldLevelVar = false;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-callarg-chain-nest — opt-fanout shim for the `@:fmt(callArgChainNest)`
	 * opt-in. Idempotent sister to `_setExprPosition` — returns `o` unchanged
	 * when `_callArgChainNest` is already `true`; otherwise returns a
	 * `_copyOpt(o)` with the flag flipped on. Threaded into a call's per-arg
	 * writer call (gated at runtime on `callParameterWrap.defaultMode ==
	 * FillLineWithLeadingBreak`) so a chain argument suppresses its own
	 * continuation Nest — the leading-break call-arg Nest already supplies the
	 * +cols indent, mirroring the condWrap `_chainModeOverride` path. Emitted
	 * only when the opt typedef declares `_callArgChainNest:Bool` (currently
	 * `HxModuleWriteOptions`).
	 */
	private static function setCallArgChainNestField(optionsCT: ComplexType): Field {
		return {
			name: '_setCallArgChainNest',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (o._callArgChainNest) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._callArgChainNest = true;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-callarg-chain-nest — sister reset helper to `_setCallArgChainNest`.
	 * Returns the input opt unchanged when `_callArgChainNest` is already
	 * `false` (no allocation off the call-arg path); otherwise returns a
	 * `_copyOpt(o)` with the flag cleared. Consumed at each chain dispatch —
	 * the outermost infix chain (`makeInfixWriteCall`, which also HONOURS the
	 * flag as `_chainNestSuppress`) and the ternary (`lowerTernaryBranch`,
	 * which only clears it: a ternary always adds its own `?` / `:` Nest, so
	 * the advertised +cols is not its operands' base indent) — so the flag
	 * fires exactly once and leaf operands / nested chains fall back to their
	 * own continuation Nest. Paired with `_setCallArgChainNest` emission.
	 */
	private static function clearCallArgChainNestField(optionsCT: ComplexType): Field {
		return {
			name: '_clearCallArgChainNest',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (!o._callArgChainNest) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._callArgChainNest = false;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-expr-paren-in-condition (cond F2) — opt-fanout shim for the
	 * `@:fmt(condWrap)` site. Sets `_parenInCondition` to the supplied
	 * value (idempotent: returns `o` unchanged when already equal — no
	 * allocation when the condition does not request the flag). Read ONLY
	 * by the `ParenExpr` lowering, which threads a fillLine
	 * `_chainModeOverride` into the paren's own inner chain when set. Sister
	 * to `_setCallArgChainNest`. Gated on `_parenInCondition:Bool`.
	 */
	private static function setParenInConditionField(optionsCT: ComplexType): Field {
		return {
			name: '_setParenInCondition',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [
					{ name: 'o', type: optionsCT },
					{ name: 'v', type: macro :Bool },
					chainBaseArg(optionsCT)
				],
				ret: optionsCT,
				expr: macro {
					if (o._parenInCondition == v) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._parenInCondition = v;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-compare-operand-linewrap — opt-fanout shim for the ternary condition
	 * (`lowerTernaryBranch`). Sets `_inTernaryCond` to the supplied value
	 * (idempotent: returns `o` unchanged when already equal). Read ONLY by the
	 * `lowerInfixBranch` compare arm to suppress the `==`/`!=` operand-overflow
	 * break for a compare that IS a ternary condition. Sister to
	 * `_setParenInCondition`. Gated on `_inTernaryCond:Bool`.
	 */
	private static function setInTernaryCondField(optionsCT: ComplexType): Field {
		return {
			name: '_setInTernaryCond',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [
					{ name: 'o', type: optionsCT },
					{ name: 'v', type: macro :Bool },
					chainBaseArg(optionsCT)
				],
				ret: optionsCT,
				expr: macro {
					if (o._inTernaryCond == v) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._inTernaryCond = v;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * omega-call-grouprestprobe-subposition — opt-fanout shim for a `Call`
	 * subtree that is NOT in statement/expression position (case-pattern body
	 * via `HxCasePattern.expr`'s `@:fmt(suppressCallRestProbe)`; `??` operands
	 * via `lowerInfixBranch`). Sets `_suppressCallRestProbe` to the supplied
	 * value (idempotent: returns `o` unchanged when already equal). Read ONLY by
	 * the `Call` ctor's `groupRestProbe` gate in `lowerPostfixSepListCall` to
	 * skip the rest-of-line fit bias. Sister to `_setInTernaryCond`. Gated on
	 * `_suppressCallRestProbe:Bool`.
	 */
	private static function setSuppressCallRestProbeField(optionsCT: ComplexType): Field {
		return {
			name: '_setSuppressCallRestProbe',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [
					{ name: 'o', type: optionsCT },
					{ name: 'v', type: macro :Bool },
					chainBaseArg(optionsCT)
				],
				ret: optionsCT,
				expr: macro {
					if (o._suppressCallRestProbe == v) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._suppressCallRestProbe = v;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-complex-item-count — opt-fanout shim marking a case-PATTERN body or a
	 * switch SUBJECT (`@:fmt(suppressComplexItems)`), so an array literal below
	 * it skips the per-element complexity classification that feeds
	 * `complexItemCount >= n`. Idempotent (returns `o` unchanged when already
	 * set). Sister to `_setSuppressCallRestProbe`. Gated on
	 * `_suppressComplexItems:Bool`.
	 */
	private static function setSuppressComplexItemsField(optionsCT: ComplexType): Field {
		return {
			name: '_setSuppressComplexItems',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (o._suppressComplexItems) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._suppressComplexItems = true;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-pattern-rest-probe — opt-fanout shim marking a case-PATTERN body
	 * (`@:fmt(suppressPatternRestProbe)`), so no construct below it rest-probes the
	 * line on the TRIVIA write path. Idempotent (returns `o` unchanged when already
	 * set). Sister to `_setSuppressComplexItems`, and deliberately NOT the same flag:
	 * that one a switch SUBJECT also sets, and a subject is a real expression whose
	 * call must keep wrapping. Gated on `_suppressPatternRestProbe:Bool`.
	 *
	 * The non-trivia struct-Star dispatch (`WriterLowering.emitSepStarList`) reads the
	 * flag too, since T169 — it is the plain writer's path for a `@:trivia` Star and
	 * the ONLY path, in both writers, for a Star that has none.
	 */
	private static function setSuppressPatternRestProbeField(optionsCT: ComplexType): Field {
		return {
			name: '_setSuppressPatternRestProbe',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (o._suppressPatternRestProbe) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._suppressPatternRestProbe = true;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-expr-paren-in-condition — sister reset helper to
	 * `_setParenInCondition`. Returns `o` unchanged when `_parenInCondition`
	 * is already `false`; otherwise returns a `_copyOpt(o)` with the flag
	 * cleared. Consumed at the `ParenExpr` inner writeCall so a nested expr
	 * paren inside the in-condition paren does not re-trigger the fillLine
	 * override. Paired with `_setParenInCondition`.
	 */
	private static function clearParenInConditionField(optionsCT: ComplexType): Field {
		return {
			name: '_clearParenInCondition',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (!o._parenInCondition) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._parenInCondition = false;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-keep-kw-newline (increment 1b) — opt-fanout shim for the VarStmt-family
	 * `@:fmt(captureKwNewline)` ctors. Sets `_varKwNewline` to the supplied
	 * value (idempotent: returns `o` unchanged when already equal — no
	 * allocation when the source kept `var x = …` on one line). Read ONLY by
	 * the `HxVarDecl` multiVar fold, which uses it for the head break
	 * (`_breaks[0]`) under `WrapMode.Keep`. Sister to `_setParenInCondition`.
	 * Gated on `_varKwNewline:Bool`.
	 */
	private static function setVarKwNewlineField(optionsCT: ComplexType): Field {
		return {
			name: '_setVarKwNewline',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [
					{ name: 'o', type: optionsCT },
					{ name: 'v', type: macro :Bool },
					chainBaseArg(optionsCT)
				],
				ret: optionsCT,
				expr: macro {
					if (o._varKwNewline == v) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._varKwNewline = v;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-keep-kw-newline (increment 1b) — sister reset helper to
	 * `_setVarKwNewline`. Returns `o` unchanged when `_varKwNewline` is already
	 * `false`; otherwise returns a `_copyOpt(o)` with the flag cleared.
	 * Consumed at the `HxVarDecl` multiVar fold so the recursive head/link
	 * self-calls do not re-trigger the head break. Paired with
	 * `_setVarKwNewline`.
	 */
	private static function clearVarKwNewlineField(optionsCT: ComplexType): Field {
		return {
			name: '_clearVarKwNewline',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (!o._varKwNewline) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._varKwNewline = false;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-keep-chain (increment: opadd_chain_keep) — opt-fanout shim for the
	 * opAddSub / opBool chain emit. Sets `_keepFlatInner` to the supplied value
	 * (idempotent: returns `o` unchanged when already equal — no allocation when
	 * the chain is not in keep mode). Read ONLY by the `ParenExpr`
	 * (`@:fmt(expressionParenHardFlatten)`) emit, which takes the GLUED branch
	 * unconditionally so a kept chain's inner parens stay flat regardless of
	 * line width. Sister to `_setVarKwNewline`. Gated on `_keepFlatInner:Bool`.
	 */
	private static function setKeepFlatInnerField(optionsCT: ComplexType): Field {
		return {
			name: '_setKeepFlatInner',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [
					{ name: 'o', type: optionsCT },
					{ name: 'v', type: macro :Bool },
					chainBaseArg(optionsCT)
				],
				ret: optionsCT,
				expr: macro {
					if (o._keepFlatInner == v) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._keepFlatInner = v;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-keep-chain (increment: opadd_chain_keep) — sister reset helper to
	 * `_setKeepFlatInner`. Returns `o` unchanged when `_keepFlatInner` is already
	 * `false`; otherwise returns a `_copyOpt(o)` with the flag cleared. Paired
	 * with `_setKeepFlatInner`.
	 */
	private static function clearKeepFlatInnerField(optionsCT: ComplexType): Field {
		return {
			name: '_clearKeepFlatInner',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (!o._keepFlatInner) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._keepFlatInner = false;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-keep-chain (increment: opadd_chain_keep) — opt-fanout shim set by an
	 * enclosing `ParenExpr` so a `WrapMode.Keep` chain suppresses its headBreak +
	 * Nest (the return-head newline + continuation indent are supplied at the
	 * value level). Idempotent. Gated on `_keepChainInParen:Bool`.
	 */
	private static function setKeepChainInParenField(optionsCT: ComplexType): Field {
		return {
			name: '_setKeepChainInParen',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [
					{ name: 'o', type: optionsCT },
					{ name: 'v', type: macro :Bool },
					chainBaseArg(optionsCT)
				],
				ret: optionsCT,
				expr: macro {
					if (o._keepChainInParen == v) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._keepChainInParen = v;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-keep-chain (increment: opadd_chain_keep) — sister reset helper to
	 * `_setKeepChainInParen`. Cleared at the chain emit so nested chains / leaf
	 * operands inside the kept chain do not re-trigger the suppression.
	 */
	private static function clearKeepChainInParenField(optionsCT: ComplexType): Field {
		return {
			name: '_clearKeepChainInParen',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (!o._keepChainInParen) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._keepChainInParen = false;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-multivar-wrap — opt-fanout shim for the multi-var head-only emit.
	 * Idempotent sister to `_setCallArgChainNest`: returns `o` unchanged
	 * when `_suppressMore` is already `true`; otherwise returns a
	 * `_copyOpt(o)` with the flag flipped on. A recursive `writeHxVarDeclT`
	 * self-call made with the flag set emits only the head binding — the
	 * `more` Star field degrades to `_de()`. Emitted only when the opt
	 * typedef declares `_suppressMore:Bool` (currently `HxModuleWriteOptions`).
	 */
	private static function setSuppressMoreField(optionsCT: ComplexType): Field {
		return {
			name: '_setSuppressMore',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (o._suppressMore) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._suppressMore = true;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-multivar-wrap — sister reset helper to `_setSuppressMore`. Returns
	 * the input opt unchanged when `_suppressMore` is already `false` (no
	 * allocation off the multi-var path); otherwise returns a `_copyOpt(o)`
	 * with the flag cleared. Consumed before the head binding's own nested
	 * writes so a var decl nested inside an initializer keeps its own
	 * `more`. Paired with `_setSuppressMore` emission.
	 */
	private static function clearSuppressMoreField(optionsCT: ComplexType): Field {
		return {
			name: '_clearSuppressMore',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (!o._suppressMore) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._suppressMore = false;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-chain-fillline-in-condwrap — opt-fanout shim for the
	 * `@:fmt(condWrap('<knob>'))` site. Forces `BinaryChainEmit.emit`'s
	 * cascade to a single mode by swapping `opBoolChainWrap` and
	 * `opAddSubChainWrap` to `{rules: [], defaultMode: mode}` — the
	 * chain dispatch reads those fields by name and sees the override
	 * transparently, no `BinaryChainEmit` signature change. Idempotent:
	 * returns `o` unchanged when `mode == null` (no allocation on the
	 * default path) or when the override already matches. Consumed at
	 * `HxIfStmt.cond` / `HxWhileStmt.cond` writer call sites to mirror
	 * haxe-formatter's `collapseChainWraps` post-pass output shape
	 * (chains inside an active cond-wrap collapse from `OnePerLine` to
	 * `FillLine`-like packing). Emitted only when the opt typedef
	 * declares `_chainModeOverride:Null<WrapMode>` AND carries both
	 * `opBoolChainWrap` and `opAddSubChainWrap` (currently
	 * `HxModuleWriteOptions` only).
	 */
	private static function setChainModeOverrideField(optionsCT: ComplexType): Field {
		return {
			name: '_setChainModeOverride',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [
					{ name: 'o', type: optionsCT },
					{ name: 'mode', type: macro :Null<anyparse.format.wrap.WrapMode> },
					chainBaseArg(optionsCT)
				],
				ret: optionsCT,
				expr: macro {
					if (mode == null) return o;
					final _mode: anyparse.format.wrap.WrapMode = mode;
					if (o._chainModeOverride == _mode) return o;
					// Read every `o` field BEFORE the clone line: on the fusion
					// path `_c` and `o` are the SAME record, so a read after a
					// write would see the new value.
					final _boolLoc: anyparse.format.wrap.WrappingLocation = _resolveChainLoc(o.opBoolChainWrap);
					final _addSubLoc: anyparse.format.wrap.WrappingLocation = _resolveChainLoc(o.opAddSubChainWrap);
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._chainModeOverride = _mode;
					// Mode override forces chain layout to the cond-wrap
					// mode (mirrors fork's `collapseChainWraps` post-pass),
					// but operator-placement preference must follow the
					// user-configured opBoolChain location — fork preserves
					// the original `location` even after collapse. Resolve
					// per source: `defaultLocation` → last rule's `location`
					// (cascade fallback rule) → `BeforeLast`. The default
					// `BeforeLast` mirrors haxe-formatter's idiomatic default
					// (`\n&& X`) for unconfigured opBoolChain; was hardcoded
					// before priority_over_opbool exposed the gap.
					_c.opBoolChainWrap = { rules: [], defaultMode: _mode, defaultLocation: _boolLoc };
					_c.opAddSubChainWrap = { rules: [], defaultMode: _mode, defaultLocation: _addSubLoc };
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * Picks the effective `defaultLocation` to install on the override
	 * cascade. Resolution: `r.defaultLocation` → last rule's `location`
	 * (catch-all fallback rule) → `WrappingLocation.BeforeLast`.
	 *
	 * Sister to `setChainModeOverrideField` — emitted whenever that helper
	 * is emitted so the override path can preserve user-configured
	 * operator placement instead of the prior hardcoded `BeforeLast`.
	 */
	private static function resolveChainLocField(): Field {
		return {
			name: '_resolveChainLoc',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{ name: 'r', type: macro :anyparse.format.wrap.WrapRules }],
				ret: macro :anyparse.format.wrap.WrappingLocation,
				expr: macro {
					final _dl: Null<anyparse.format.wrap.WrappingLocation> = r.defaultLocation;
					if (_dl != null) return _dl;
					var _i: Int = r.rules.length;
					while (--_i >= 0) {
						final _loc: Null<anyparse.format.wrap.WrappingLocation> = r.rules[_i].location;
						if (_loc != null) return _loc;
					}
					return anyparse.format.wrap.WrappingLocation.BeforeLast;
				}
			}),
			pos: Context.currentPos()
		};
	}

	private static function pushOptFanoutHelpers(fields: Array<Field>, optionsTypePath: String, optionsCT: ComplexType): Void {
		// noqa: complexity
		final hasValueIfBranch: Bool = optionsHasField(optionsTypePath, '_inValueIfBranch');
		final hasArrowLambdaBody: Bool = optionsHasField(optionsTypePath, '_inArrowLambdaBody');
		// omega-arrow-value-if-reflow: the chain-refusal descent signal shares
		// the consumed-once discipline of `_inValueIfBranch` - a fresh
		// expression-position frame (call arg, operand, a NESTED arrow body) is
		// a new chain, so `_setExprPosition` clears it. The chain's own
		// `else`-descent carries no `propagateExprPosition` and therefore keeps
		// it, which is exactly the reach the signal needs.
		final hasArrowValueIfBlocked: Bool = optionsHasField(optionsTypePath, '_arrowValueIfBlocked');
		if (optionsHasInExprPosition(optionsTypePath)) {
			fields.push(setExprPositionField(optionsCT, hasValueIfBranch, hasArrowLambdaBody, hasArrowValueIfBlocked));
			fields.push(clearExprPositionField(optionsCT));
		}
		if (hasArrowValueIfBlocked) fields.push(setArrowValueIfBlockedField(optionsCT));
		if (optionsHasField(optionsTypePath, '_arrowValueIfElemTrailComment')) fields.push(setArrowValueIfElemTrailCommentField(optionsCT));
		// ω-elseif-body-break: opt-fanout helper pair for `propagateElseIfBranch`
		// (HxIfStmt.elseBody set-site) and `clearElseIfBranch` (inner if's
		// then-body one-level clear). Gated on `_inElseIfBranch:Bool` presence.
		if (optionsHasField(optionsTypePath, '_inElseIfBranch')) {
			fields.push(setElseIfBranchField(optionsCT));
			fields.push(clearElseIfBranchField(optionsCT));
		}
		// ω-case-sibling-symmetry: per-switch widest-sibling width fanout.
		if (optionsHasField(optionsTypePath, '_caseSiblingFlatWidth')) fields.push(setCaseSiblingWidthField(optionsCT));
		if (hasValueIfBranch) {
			fields.push(setValueIfBranchField(optionsCT));
			fields.push(clearValueIfBranchField(optionsCT));
		}
		// ω-arrow-body-objlit-pad: opt-fanout helper pair for
		// `propagateArrowLambdaBody` (`HxExpr.ThinArrow` right operand /
		// `HxThinParenLambda.body` set-sites) and the `_setExprPosition`
		// descent clear. The setter has NO `_inExprPosition` gate — an
		// arrow-lambda body is always an expression. Sister to
		// `_setValueIfBranch`/`_clearValueIfBranch`. Gated on
		// `_inArrowLambdaBody:Bool` field presence on the opt typedef.
		if (hasArrowLambdaBody) {
			fields.push(setArrowLambdaBodyField(optionsCT));
			fields.push(clearArrowLambdaBodyField(optionsCT));
		}
		// ω-anonfunction-empty-curly: opt-fanout helper for
		// `propagateAnonFnContext`. Returns the input opt unchanged when
		// `_inAnonFnBody` is already true; otherwise returns a `_copyOpt`
		// with the flag flipped on. Sister to `_setExprPosition`. Emitted
		// only when the opt typedef carries `_inAnonFnBody:Bool` —
		// currently declared on `HxModuleWriteOptions` only.
		if (optionsHasField(optionsTypePath, '_inAnonFnBody')) {
			fields.push(setAnonFnBodyField(optionsCT));
			fields.push(clearAnonFnBodyField(optionsCT));
		}
		// ω-typedef-anon-force-multi: opt-fanout helper pair for
		// `propagateTypedefContext` (typedef-RHS Ref dispatch) and
		// `forceMultiInTypedef` (Anon-body Star per-element clear).
		// Sister to `_setAnonFnBody`/`_clearAnonFnBody`. Gated on
		// `_inTypedefBody:Bool` field presence on the opt typedef.
		if (optionsHasField(optionsTypePath, '_inTypedefBody')) {
			fields.push(setTypedefBodyField(optionsCT));
			fields.push(clearTypedefBodyField(optionsCT));
		}
		// ω-enumabstract-begin-end: opt-fanout helper for
		// `@:fmt(propagateEnumAbstractContext)` on `EnumAbstractDecl(decl)`.
		// Set-only (an `enum abstract` body nests no further type decl, so no
		// clear sister is needed). Gated on `_inEnumAbstract:Bool`.
		if (optionsHasField(optionsTypePath, '_inEnumAbstract')) fields.push(setEnumAbstractField(optionsCT));
		// ω-typedef-intersection-operand-break: opt-fanout helper for the
		// per-element `& Type`-clause break in `HxTypedefDecl.intersections`.
		// Idempotent sister to `_setTypedefBody`. Gated on
		// `_intersectionOperandBreak:Bool` field presence on the opt typedef.
		if (optionsHasField(optionsTypePath, '_intersectionOperandBreak')) fields.push(setIntersectionBreakField(optionsCT));
		// ω-fieldlevel-var-value-expr-indent: opt-fanout helper pair for
		// `@:fmt(propagateFieldLevelVar)` (class-member `var`/`final` ctor
		// init dispatch) and the function-body clear. `_setFieldLevelVar`
		// flags the descendant `HxVarDecl.init` write so the
		// `indentValueIfCtor('IfExpr', 'indentComplexValueExpressions')`
		// entry forces its indent (fork's `isFieldLevelVar`);
		// `_clearFieldLevelVar` resets the flag at a function-body boundary
		// so a nested local var inside a member initializer stays
		// knob-gated. Sister to `_setAnonFnBody`/`_clearAnonFnBody`. Gated
		// on `_inFieldLevelVar:Bool` field presence on the opt typedef.
		if (optionsHasField(optionsTypePath, '_inFieldLevelVar')) {
			fields.push(setFieldLevelVarField(optionsCT));
			fields.push(clearFieldLevelVarField(optionsCT));
		}
		// ω-single-stmt-braces: opt-fanout helper for the dangling-else
		// suppress frame consumed by `SingleStmtBraces.unwrapStmt`. Gated
		// on `_ssbSuppress:Bool` field presence on the opt typedef.
		if (optionsHasField(optionsTypePath, '_ssbSuppress')) fields.push(setSsbSuppressField(optionsCT));
		// ω-single-stmt-braces CHAIN symmetry: two-way setter for the else-if
		// chain-suppress flag consumed by `SingleStmtBraces.chainForcesBraces`
		// propagation. Gated on `_ssbChainSuppress:Bool` field presence.
		if (optionsHasField(optionsTypePath, '_ssbChainSuppress')) fields.push(setSsbChainSuppressField(optionsCT));
		// omega-macro-reification-braces: disarm-both-knobs shim for a reification
		// scope (`@:fmt(clearBracePolicy)` — `HxExpr.MacroExpr` / `MacroClassExpr`).
		// Gated on BOTH brace knobs being present on the opt typedef.
		if (optionsHasField(optionsTypePath, 'dropSingleStmtBraces') && optionsHasField(optionsTypePath, 'singleStmtBraceSymmetry'))
			fields.push(clearBracePolicyField(optionsCT));
		// ω-chain-fillline-in-condwrap: opt-fanout helper for
		// `@:fmt(condWrap)` site. Forces `BinaryChainEmit.emit`'s
		// cascade to a single mode by swapping `opBoolChainWrap` /
		// `opAddSubChainWrap` to a degenerate `{rules: [],
		// defaultMode: mode}` cascade. Sister to `_setAnonFnBody` —
		// idempotent, null-mode short-circuit avoids allocation on
		// the default path. Emitted only when the opt typedef
		// declares `_chainModeOverride:Null<WrapMode>` AND carries
		// both `opBoolChainWrap` and `opAddSubChainWrap`.
		if (
			optionsHasField(optionsTypePath, '_chainModeOverride') && optionsHasField(optionsTypePath, 'opBoolChainWrap')
			&& optionsHasField(optionsTypePath, 'opAddSubChainWrap')
		) {
			fields.push(setChainModeOverrideField(optionsCT));
			fields.push(resolveChainLocField());
		}
		// ω-callarg-chain-nest: opt-fanout helper pair for the
		// `@:fmt(callArgChainNest)` opt-in on a call-arg Star (currently
		// `HxExpr.Call`). `_setCallArgChainNest` flags a chain arg of a
		// leading-break call so its own continuation Nest collapses to the
		// inherited indent (the call-arg Nest already supplies +cols);
		// `_clearCallArgChainNest` consumes the flag at the outermost chain
		// so nested chains keep their own Nest. Sister to
		// `_setAnonFnBody`/`_clearAnonFnBody`. Gated on `_callArgChainNest:Bool`.
		if (optionsHasField(optionsTypePath, '_callArgChainNest')) {
			fields.push(setCallArgChainNestField(optionsCT));
			fields.push(clearCallArgChainNestField(optionsCT));
		}
		// ω-multivar-wrap: opt-fanout helper pair for the multi-var
		// declaration head-only emit (`HxVarDecl.more` wrapping).
		// `_setSuppressMore` flags a recursive `writeHxVarDeclT` self-call
		// so it emits only the head binding (the `more` Star degrades to
		// `_de()`); `_clearSuppressMore` resets the flag before the head's
		// own nested-init writes so a var decl inside an initializer keeps
		// its own `more`. Sister to `_setCallArgChainNest`/
		// `_clearCallArgChainNest`. Gated on `_suppressMore:Bool`.
		if (optionsHasField(optionsTypePath, '_suppressMore')) {
			fields.push(setSuppressMoreField(optionsCT));
			fields.push(clearSuppressMoreField(optionsCT));
		}
		// ω-expr-paren-in-condition (cond F2): opt-fanout helper pair for
		// the `@:fmt(condWrap)` site. `_setParenInCondition` marks the
		// condition content so an expression paren inside it routes its
		// inner chain through `expressionWrapping` (fillLine);
		// `_clearParenInCondition` consumes the flag at the paren's inner
		// writeCall so a nested expr paren does not re-trigger. Gated on
		// `_parenInCondition:Bool`.
		if (optionsHasField(optionsTypePath, '_parenInCondition')) {
			fields.push(setParenInConditionField(optionsCT));
			fields.push(clearParenInConditionField(optionsCT));
		}
		// ω-compare-operand-linewrap: gate `_setInTernaryCond` on the field it
		// touches (its own block, matching the one-field-per-block precedent) so
		// it is emitted iff the grammar declares `_inTernaryCond`.
		if (optionsHasField(optionsTypePath, '_inTernaryCond')) {
			fields.push(setInTernaryCondField(optionsCT));
		}
		// omega-call-grouprestprobe-subposition: gate `_setSuppressCallRestProbe`
		// on the field it touches (one-field-per-block precedent) so it is emitted
		// iff the grammar declares `_suppressCallRestProbe`.
		if (optionsHasField(optionsTypePath, '_suppressCallRestProbe')) {
			fields.push(setSuppressCallRestProbeField(optionsCT));
		}
		// ω-complex-item-count: same one-field-per-block gate for
		// `_setSuppressComplexItems`.
		if (optionsHasField(optionsTypePath, '_suppressComplexItems')) {
			fields.push(setSuppressComplexItemsField(optionsCT));
		}
		// ω-pattern-rest-probe: same one-field-per-block gate for
		// `_setSuppressPatternRestProbe`.
		if (optionsHasField(optionsTypePath, '_suppressPatternRestProbe')) {
			fields.push(setSuppressPatternRestProbeField(optionsCT));
		}
		// ω-keep-kw-newline (increment 1b): opt-fanout helper pair for the
		// VarStmt-family `@:fmt(captureKwNewline)` ctors. `_setVarKwNewline`
		// records the source `var`→head newline so the `HxVarDecl` multiVar
		// fold can break the head binding under `WrapMode.Keep`;
		// `_clearVarKwNewline` resets it at the fold so recursive head/link
		// self-calls do not re-trigger. Sister to `_setParenInCondition` /
		// `_clearParenInCondition`. Gated on `_varKwNewline:Bool`.
		if (optionsHasField(optionsTypePath, '_varKwNewline')) {
			fields.push(setVarKwNewlineField(optionsCT));
			fields.push(clearVarKwNewlineField(optionsCT));
		}
		// ω-keep-chain (increment: opadd_chain_keep): opt-fanout helper pair
		// for the opAddSub / opBool chain emit. `_setKeepFlatInner` marks the
		// leaf-operand opt so an inner `ParenExpr` stays GLUED (no width-driven
		// re-open) under `WrapMode.Keep`; `_clearKeepFlatInner` resets it.
		// Sister to `_setVarKwNewline` / `_setParenInCondition`. Gated on
		// `_keepFlatInner:Bool`.
		if (optionsHasField(optionsTypePath, '_keepFlatInner')) {
			fields.push(setKeepFlatInnerField(optionsCT));
			fields.push(clearKeepFlatInnerField(optionsCT));
		}
		// ω-keep-chain (increment: opadd_chain_keep): opt-fanout helper pair
		// for the enclosing-`ParenExpr` → keep-chain signal. `_setKeepChainInParen`
		// marks the inner opt so a `WrapMode.Keep` chain suppresses its headBreak
		// + Nest; `_clearKeepChainInParen` resets it at the chain emit so nested
		// chains / leaf operands don't re-trigger. Gated on `_keepChainInParen:Bool`.
		if (!optionsHasField(optionsTypePath, '_keepChainInParen')) return;
		fields.push(setKeepChainInParenField(optionsCT));
		fields.push(clearKeepChainInParenField(optionsCT));
	}

	/**
	 * ω-enumabstract-begin-end — opt-fanout helper for
	 * `@:fmt(propagateEnumAbstractContext)` on `EnumAbstractDecl(decl)`.
	 * Idempotent sister to `_setTypedefBody`: returns `o` unchanged when
	 * `_inEnumAbstract` is already `true`, else a `_copyOpt(o)` with the flag
	 * set — so the inner `HxAbstractDecl` body's `beginEndType` count reads the
	 * `enumAbstractBeginType` / `enumAbstractEndType` knobs instead of the
	 * class-scoped `beginType` / `endType`. Emitted only when the opt typedef
	 * declares `_inEnumAbstract:Bool`.
	 */
	private static function setEnumAbstractField(optionsCT: ComplexType): Field {
		return {
			name: '_setEnumAbstract',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (o._inEnumAbstract) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._inEnumAbstract = true;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-single-stmt-braces — opt-fanout shim for the dangling-else
	 * suppress frame. Set-only (never cleared on descent — over-
	 * suppression inside nested braced regions is safe, merely
	 * conservative). Idempotent: returns `o` unchanged when
	 * `_ssbSuppress` is already `true`. Applied by
	 * `WriterLowering.buildMandatoryRefWriteCall` to the then-body
	 * writeCall of an `if` statement whose `else` sibling is present AND
	 * whose then-body renders WITHOUT braces (a brace-bearing then-body
	 * seals its subtree with its own `}`), so every
	 * `dropSingleStmtBraces` unwrap nested inside that then-body is put
	 * through the trailing-spine dangling-else test rather than allowed
	 * unconditionally (`SingleStmtBraces.unwrapStmt` reads the flag).
	 * Gated on `_ssbSuppress:Bool` field presence on the opt typedef.
	 */
	private static function setSsbSuppressField(optionsCT: ComplexType): Field {
		return {
			name: '_setSsbSuppress',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (o._ssbSuppress) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._ssbSuppress = true;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * omega-macro-reification-braces — opt-fanout shim that DISARMS both halves of the
	 * single-statement brace policy for a whole subtree. Applied by
	 * `WriterLowering.kwRefCtorOptArg` to the operand of a `macro …` reification
	 * (`@:fmt(clearBracePolicy)`).
	 *
	 * Inside a reification the code is DATA: `{ … }` is an `EBlock` node of the value the
	 * macro returns, not layout. Adding a brace level there turns `EBlock(exprs)` into
	 * `EBlock([EBlock(exprs)])` — an extra scope in the code the macro emits — and removing
	 * one is the same change in reverse. Both directions of the policy read these two
	 * fields first (`SingleStmtBraces.unwrapStmt` / `symmetryNeedsValueWrap` /
	 * `tryBraceVerdict` all short-circuit on `!drop && !symmetry`), so clearing the pair is
	 * the whole carve-out — there is no per-gate argument to keep in sync.
	 *
	 * Idempotent and allocation-free on the default path: with neither knob set (the
	 * default, and every config that is not `"remove"` / `"symmetric"`) it returns `o`
	 * unchanged, so the whole mechanism is byte- AND allocation-inert. Gated on both
	 * `dropSingleStmtBraces:Bool` and `singleStmtBraceSymmetry:Bool` being present on the
	 * opt typedef.
	 */
	private static function clearBracePolicyField(optionsCT: ComplexType): Field {
		return {
			name: '_clearBracePolicy',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{ name: 'o', type: optionsCT }, chainBaseArg(optionsCT)],
				ret: optionsCT,
				expr: macro {
					if (!o.dropSingleStmtBraces && !o.singleStmtBraceSymmetry) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c.dropSingleStmtBraces = false;
					_c.singleStmtBraceSymmetry = false;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-single-stmt-braces CHAIN symmetry — two-way opt-fanout shim for the
	 * else-if chain-suppress flag. `WriterLowering` SETS it on an else-if
	 * continuation writeCall (propagating the chain root's
	 * `chainForcesBraces` verdict down the spine) and CLEARS it on a branch's
	 * own content writeCall (then-body / terminal-else), so an independent
	 * if-chain nested inside a branch still de-braces on its own merits.
	 * Idempotent: returns `o` unchanged when `_ssbChainSuppress` already
	 * equals `v`. Gated on `_ssbChainSuppress:Bool` field presence.
	 */
	private static function setSsbChainSuppressField(optionsCT: ComplexType): Field {
		return {
			name: '_setSsbChainSuppress',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [
					{ name: 'o', type: optionsCT },
					{ name: 'v', type: macro :Bool },
					chainBaseArg(optionsCT)
				],
				ret: optionsCT,
				expr: macro {
					if (o._ssbChainSuppress == v) return o;
					final _c: $optionsCT = _b != null && o != _b ? o : _copyOpt(o);
					_c._ssbChainSuppress = v;
					return _c;
				}
			}),
			pos: Context.currentPos()
		};
	}

}
#end
