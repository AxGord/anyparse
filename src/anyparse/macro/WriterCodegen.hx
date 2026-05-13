package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * Pass 4W of the macro pipeline — writer codegen.
 *
 * Takes the list of `WriterRule`s produced by `WriterLowering`, the root
 * rule name and format info, and returns a full `Array<Field>` ready to
 * be plugged into a marker class via `@:build`.
 *
 * What WriterCodegen owns:
 *  - Writing the `write(value, ?options)` public entry point that
 *    resolves options against the format's defaults, calls the root
 *    write function, and hands the Doc to Renderer.
 *  - Emitting the per-rule `writeXxx(value, opt)` functions. Internal
 *    helpers operate on a fully resolved `WriteOptions` struct — no
 *    nullable fields, no per-call defaulting.
 *  - Emitting Doc wrapper helpers (`_dt`, `_dc`, etc.) that avoid
 *    direct enum constructor calls in macro expressions.
 *  - Emitting layout helpers (`blockBody`, `sepList`) and encoding
 *    helpers (`formatFloat`, `escapeString`).
 */
class WriterCodegen {

	public static function emit(
		rules:Array<WriterLowering.WriterRule>,
		rootTypePath:String,
		rootReturnCT:ComplexType,
		formatInfo:FormatReader.FormatInfo,
		optionsTypePath:Null<String>,
		?rootFnName:Null<String>
	):Array<Field> {
		final fields:Array<Field> = [];
		if (formatInfo.isBinary) {
			fields.push(binaryEntry(rootTypePath, rootReturnCT));
			for (rule in rules) fields.push(binaryRuleField(rule));
		} else {
			if (optionsTypePath == null)
				Context.fatalError('WriterCodegen.emit: text writer requires optionsTypePath', Context.currentPos());
			final optionsCT:ComplexType = optionsComplexType(optionsTypePath);
			final resolvedRootFn:String = rootFnName ?? ('write' + simpleName(rootTypePath));
			fields.push(publicEntry(resolvedRootFn, rootReturnCT, formatInfo, optionsCT));
			fields.push(publicDocEntry(resolvedRootFn, rootReturnCT, formatInfo, optionsCT));
			for (rule in rules) fields.push(ruleField(rule, optionsCT));
			// Doc wrapper helpers
			for (f in docHelperFields()) fields.push(f);
			// ω-expression-case-flat-fanout: typed `Reflect.copy(opt)` shim,
			// emitted unconditionally so triviaTryparseStarExpr's flat-fanout
			// path can call it without per-grammar gating.
			fields.push(copyOptField(optionsCT));
			// ω-issue-423-mech-a: opt-fanout helper for `propagateExprPosition`.
			// Returns the input opt unchanged when `_inExprPosition` is already
			// true (no allocation on already-propagating descendants); otherwise
			// returns a `_copyOpt` with the flag flipped on. Emitted only when
			// the opt typedef carries the `_inExprPosition:Bool` field —
			// grammars whose options struct doesn't declare it (e.g. Json,
			// Bin) skip the helper to avoid a compile-time field-resolution
			// error. Per-grammar opt-in lives in the typedef itself.
			if (optionsHasInExprPosition(optionsTypePath))
				fields.push(setExprPositionField(optionsCT));
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
			// ω-chain-fillline-in-condwrap: opt-fanout helper for
			// `@:fmt(condWrap)` site. Forces `BinaryChainEmit.emit`'s
			// cascade to a single mode by swapping `opBoolChainWrap` /
			// `opAddSubChainWrap` to a degenerate `{rules: [],
			// defaultMode: mode}` cascade. Sister to `_setAnonFnBody` —
			// idempotent, null-mode short-circuit avoids allocation on
			// the default path. Emitted only when the opt typedef
			// declares `_chainModeOverride:Null<WrapMode>` AND carries
			// both `opBoolChainWrap` and `opAddSubChainWrap`.
			if (optionsHasField(optionsTypePath, '_chainModeOverride')
				&& optionsHasField(optionsTypePath, 'opBoolChainWrap')
				&& optionsHasField(optionsTypePath, 'opAddSubChainWrap')) {
				fields.push(setChainModeOverrideField(optionsCT));
				fields.push(resolveChainLocField());
			}
			// Layout helpers
			fields.push(blockBodyField());
			fields.push(sepListField());
			fields.push(fillListField());
			// Encoding helpers
			fields.push(formatFloatField());
			fields.push(escapeStringField(formatInfo));
			// Trivia helpers (ω₅). Always emitted — unused when
			// the marker class doesn't opt into `{trivia: true}`,
			// but cost is small private-static methods.
			fields.push(leadingCommentDocField());
			fields.push(trailingCommentDocField());
			fields.push(trailingCommentDocVerbatimField());
			// ω₆c: BodyGroup trailing-comment folder. Used by
			// `triviaBlockStarExpr` / `triviaEofStarExpr` to splice
			// a trailing comment into the body's FitLine measure.
			fields.push(foldTrailingIntoBodyGroupField());
			fields.push(foldTrailingRecursiveField());
			fields.push(appendInsideBodyGroupField());
			// ω-issue-316: renders the gap between a just-emitted `@:optional
			// @:kw` and its body (Same-policy / block-ctor path). Picks
			// `Text(' ')` when no trivia present — byte-identical to the
			// pre-slice separator; otherwise inlines a same-line trailing
			// and/or indents own-line leading comments at body interior
			// indent, closing with a hardline so the body's outer brace
			// lands at the parent's indent level.
			fields.push(kwGapDocField());
			// ω-trivia-after-kw-next-layout: renders the kw→body gap on
			// the Next-layout side of `bodyPolicyWrap`. Mirror of
			// `kwGapDoc` (Same-layout) but pre-puts the body inside a
			// `Nest(cols, …)` and threads any captured `kwLeading` comments
			// at the body's interior indent. Empty slots degrade to the
			// pre-slice `Nest(cols, [hardline, body])` shape — fixtures
			// without kw-trivia stay byte-identical.
			fields.push(nextLayoutKwGapDocField());
			// ω-trivia-before-kw: renders the gap between the preceding token
			// and a `@:optional @:kw` keyword. Returns the caller's plain
			// separator when no comments captured; otherwise emits each
			// captured leading comment on its own indented line, closing with
			// a hardline so the kw lands at the parent's indent level. Line-
			// comment style inherently breaks, so we always force own-line
			// layout even when `sameLine`/`Same` would otherwise put the kw
			// on the same line as `}`.
			fields.push(kwBeforeDocField());
			// ω-trivia-before-kw-trailing: prepends a same-line trailing
			// comment captured between the preceding sibling's last token and
			// the optional kw (`resize(); // first\nelse`). Returns the
			// caller's plain separator when no trailing captured.
			fields.push(kwBeforeTrailingDocField());
		}
		return fields;
	}

	// -------- public entry point --------

	private static function publicEntry(
		rootFn:String, rootReturnCT:ComplexType,
		formatInfo:FormatReader.FormatInfo,
		optionsCT:ComplexType
	):Field {
		final fmtParts:Array<String> = formatInfo.schemaTypePath.split('.');
		final defaultOptsExpr:Expr = {
			expr: EField(macro $p{fmtParts}.instance, 'defaultWriteOptions'),
			pos: Context.currentPos(),
		};
		final writeCall:Expr = {
			expr: ECall(macro $i{rootFn}, [macro value, macro _opt]),
			pos: Context.currentPos(),
		};
		final body:Expr = macro {
			final _opt:$optionsCT = options ?? $defaultOptsExpr;
			return anyparse.core.Renderer.render(
				$writeCall,
				_opt.lineWidth,
				_opt.indentChar,
				_opt.tabWidth,
				_opt.lineEnd,
				_opt.finalNewline,
				_opt.trailingWhitespace,
				_opt.maxConsecutiveBlanks
			);
		};
		return {
			name: 'write',
			access: [APublic, AStatic],
			kind: FFun({
				args: [
					{name: 'value', type: rootReturnCT},
					{name: 'options', type: macro : Null<$optionsCT>, value: macro null},
				],
				ret: macro : String,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Doc-returning counterpart of `publicEntry` — resolves options the
	 * same way, calls the root rule function, but skips the final
	 * `Renderer.render` step and hands the raw Doc tree to the caller.
	 *
	 * Used when a generated writer needs to be composed into a larger
	 * Doc stream rather than rendered in isolation — e.g. block-comment
	 * rendering embedded inside a class-member writer's output.
	 */
	private static function publicDocEntry(
		rootFn:String, rootReturnCT:ComplexType,
		formatInfo:FormatReader.FormatInfo,
		optionsCT:ComplexType
	):Field {
		final fmtParts:Array<String> = formatInfo.schemaTypePath.split('.');
		final defaultOptsExpr:Expr = {
			expr: EField(macro $p{fmtParts}.instance, 'defaultWriteOptions'),
			pos: Context.currentPos(),
		};
		final writeCall:Expr = {
			expr: ECall(macro $i{rootFn}, [macro value, macro _opt]),
			pos: Context.currentPos(),
		};
		final body:Expr = macro {
			final _opt:$optionsCT = options ?? $defaultOptsExpr;
			return $writeCall;
		};
		return {
			name: 'writeDoc',
			access: [APublic, AStatic],
			kind: FFun({
				args: [
					{name: 'value', type: rootReturnCT},
					{name: 'options', type: macro : Null<$optionsCT>, value: macro null},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	private static function optionsComplexType(optionsTypePath:String):ComplexType {
		final simple:String = simpleName(optionsTypePath);
		final pack:Array<String> = packOf(optionsTypePath);
		return TPath({pack: pack, name: simple, params: []});
	}

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
	private static function optionsHasInExprPosition(optionsTypePath:String):Bool {
		return optionsHasField(optionsTypePath, '_inExprPosition');
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
	private static function optionsHasField(optionsTypePath:String, fieldName:String):Bool {
		final t:Null<haxe.macro.Type> = try Context.getType(optionsTypePath) catch (e:haxe.Exception) null;
		if (t == null) return false;
		return anonHasField(t, fieldName);
	}

	private static function anonHasField(t:haxe.macro.Type, name:String):Bool {
		switch (t) {
			case TLazy(f): return anonHasField(f(), name);
			case TType(_, _): return anonHasField(Context.follow(t), name);
			case TAnonymous(aRef):
				final fields:Array<haxe.macro.Type.ClassField> = aRef.get().fields;
				for (cf in fields) if (cf.name == name) return true;
				return false;
			case _: return false;
		}
	}

	private static function packOf(typePath:String):Array<String> {
		final idx:Int = typePath.lastIndexOf('.');
		return idx == -1 ? [] : typePath.substring(0, idx).split('.');
	}

	private static function binaryEntry(rootTypePath:String, rootReturnCT:ComplexType):Field {
		final rootFn:String = 'write${simpleName(rootTypePath)}';
		final writeCall:Expr = {
			expr: ECall(macro $i{rootFn}, [macro value, macro output]),
			pos: Context.currentPos(),
		};
		final body:Expr = macro {
			final output:haxe.io.BytesOutput = new haxe.io.BytesOutput();
			$writeCall;
			return output.getBytes();
		};
		return {
			name: 'write',
			access: [APublic, AStatic],
			kind: FFun({
				args: [{name: 'value', type: rootReturnCT}],
				ret: macro : haxe.io.Bytes,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	private static function binaryRuleField(rule:WriterLowering.WriterRule):Field {
		return {
			name: rule.fnName,
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'value', type: rule.valueCT},
					{name: 'output', type: macro : haxe.io.BytesOutput},
				],
				ret: macro : Void,
				expr: rule.body,
			}),
			pos: Context.currentPos(),
		};
	}

	// -------- per-rule fields --------

	private static function ruleField(rule:WriterLowering.WriterRule, optionsCT:ComplexType):Field {
		final args:Array<FunctionArg> = [
			{name: 'value', type: rule.valueCT},
			{name: 'opt', type: optionsCT},
		];
		if (rule.hasCtxPrec)
			args.push({name: 'ctxPrec', type: macro : Int, value: macro -1});
		return {
			name: rule.fnName,
			access: [APrivate, AStatic],
			kind: FFun({
				args: args,
				ret: macro : anyparse.core.Doc,
				expr: rule.body,
			}),
			pos: Context.currentPos(),
		};
	}

	// -------- Doc wrapper helpers --------
	// Avoids direct enum constructor calls (`anyparse.core.Doc.Text(...)`)
	// in macro expressions, which trigger macro-time type checking.
	// Generated code calls `_dt(s)` instead — resolved at compile time
	// of the generated class, not at macro expansion time.

	private static function docHelperFields():Array<Field> {
		return [
			docHelper('_dt', [{name: 's', type: macro : String}], macro anyparse.core.Doc.Text(s)),
			docHelper('_dop', [{name: 's', type: macro : String}], macro anyparse.core.Doc.OptSpace(s)),
			docHelper('_dc', [{name: 'items', type: macro : Array<anyparse.core.Doc>}], macro anyparse.core.Doc.Concat(items)),
			docHelper('_dn', [{name: 'n', type: macro : Int}, {name: 'inner', type: macro : anyparse.core.Doc}], macro anyparse.core.Doc.Nest(n, inner)),
			docHelper('_dg', [{name: 'inner', type: macro : anyparse.core.Doc}], macro anyparse.core.Doc.Group(inner)),
			docHelper('_dbg', [{name: 'inner', type: macro : anyparse.core.Doc}], macro anyparse.core.Doc.BodyGroup(inner)),
			// ω-group-rest-probe: opt-in Group variant whose render-time fit
			// decision subtracts rest-of-stack flat width from the budget.
			// Emit via `_dgrp(...)` instead of `_dg(...)` at sites where
			// trailing same-line content should bias toward MBreak.
			docHelper('_dgrp', [{name: 'inner', type: macro : anyparse.core.Doc}], macro anyparse.core.Doc.GroupWithRestProbe(inner)),
			docHelper('_dhl', [], macro anyparse.core.Doc.Line('\n')),
			docHelper('_doh', [], macro anyparse.core.Doc.OptHardline),
			docHelper('_dossh', [], macro anyparse.core.Doc.OptSpaceSkipAfterHardline),
			docHelper('_dsl', [], macro anyparse.core.Doc.Line('')),
			docHelper('_dl', [], macro anyparse.core.Doc.Line(' ')),
			docHelper('_de', [], macro anyparse.core.Doc.Empty),
			docHelper(
				'_dib',
				[{name: 'br', type: macro : anyparse.core.Doc}, {name: 'fl', type: macro : anyparse.core.Doc}],
				macro anyparse.core.Doc.IfBreak(br, fl)
			),
			docHelper(
				'_diwe',
				[
					{name: 'n', type: macro : Int},
					{name: 'br', type: macro : anyparse.core.Doc},
					{name: 'fl', type: macro : anyparse.core.Doc}
				],
				macro anyparse.core.Doc.IfWidthExceeds(n, br, fl)
			),
			docHelper(
				'_difle',
				[
					{name: 'n', type: macro : Int},
					{name: 'br', type: macro : anyparse.core.Doc},
					{name: 'fl', type: macro : anyparse.core.Doc}
				],
				macro anyparse.core.Doc.IfFirstLineExceeds(n, br, fl)
			),
			docHelper(
				'_dfill',
				[{name: 'items', type: macro : Array<anyparse.core.Doc>}, {name: 'sep', type: macro : anyparse.core.Doc}],
				macro anyparse.core.Doc.Fill(items, sep)
			),
			// ω-fill-rest-probe: opt-in Fill variant whose per-item-fit probe
			// in FillCont resumption subtracts rest-of-stack flat width from
			// the budget. Sister to `_dgrp` at the Fill primitive layer.
			docHelper(
				'_dfwrp',
				[{name: 'items', type: macro : Array<anyparse.core.Doc>}, {name: 'sep', type: macro : anyparse.core.Doc}],
				macro anyparse.core.Doc.FillWithRestProbe(items, sep)
			),
			// ω-force-flat-engine slice D follow-up: WrapBoundary helper so the
			// hand-rolled trivia-branch dispatchers (triviaSepStarExpr et al.)
			// can reset force-flat for their inner content the same way the
			// 4 cascade-emit functions do via Slice C's wraps.
			docHelper('_dwb', [{name: 'inner', type: macro : anyparse.core.Doc}], macro anyparse.core.Doc.WrapBoundary(inner)),
		];
	}

	private static function docHelper(name:String, args:Array<FunctionArg>, body:Expr):Field {
		return {
			name: name,
			access: [APrivate, AStatic, AInline],
			kind: FFun({args: args, ret: macro : anyparse.core.Doc, expr: macro return $body}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * ω-expression-case-flat-fanout helper — typed shallow copy of `opt`.
	 *
	 * `Reflect.copy(o)` returns `Null<T>` which strict null safety refuses
	 * to narrow at the call site. The helper carries `@:nullSafety(Off)`
	 * locally so the cast to non-nullable T resolves without leaking
	 * `untyped`/`Dynamic` into the callers. Used by `triviaTryparseStarExpr`
	 * when a Star carries `@:fmt(flatChildOpt(...))` — the runtime flat
	 * branch needs a per-call mutable copy to override knob fields without
	 * touching the shared `opt` singleton.
	 */
	private static function copyOptField(optionsCT:ComplexType):Field {
		return {
			name: '_copyOpt',
			access: [APrivate, AStatic, AInline],
			meta: [{name: ':nullSafety', params: [macro Off], pos: Context.currentPos()}],
			kind: FFun({
				args: [{name: 'o', type: optionsCT}],
				ret: optionsCT,
				expr: macro {
					final _c:$optionsCT = cast Reflect.copy(o);
					if (_c == null) throw 'WriterCodegen._copyOpt: Reflect.copy returned null';
					return _c;
				},
			}),
			pos: Context.currentPos(),
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
	 */
	private static function setExprPositionField(optionsCT:ComplexType):Field {
		return {
			name: '_setExprPosition',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{name: 'o', type: optionsCT}],
				ret: optionsCT,
				expr: macro {
					if (o._inExprPosition) return o;
					final _c:$optionsCT = _copyOpt(o);
					_c._inExprPosition = true;
					return _c;
				},
			}),
			pos: Context.currentPos(),
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
	private static function setAnonFnBodyField(optionsCT:ComplexType):Field {
		return {
			name: '_setAnonFnBody',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{name: 'o', type: optionsCT}],
				ret: optionsCT,
				expr: macro {
					if (o._inAnonFnBody) return o;
					final _c:$optionsCT = _copyOpt(o);
					_c._inAnonFnBody = true;
					return _c;
				},
			}),
			pos: Context.currentPos(),
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
	private static function clearAnonFnBodyField(optionsCT:ComplexType):Field {
		return {
			name: '_clearAnonFnBody',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{name: 'o', type: optionsCT}],
				ret: optionsCT,
				expr: macro {
					if (!o._inAnonFnBody) return o;
					final _c:$optionsCT = _copyOpt(o);
					_c._inAnonFnBody = false;
					return _c;
				},
			}),
			pos: Context.currentPos(),
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
	private static function setTypedefBodyField(optionsCT:ComplexType):Field {
		return {
			name: '_setTypedefBody',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{name: 'o', type: optionsCT}],
				ret: optionsCT,
				expr: macro {
					if (o._inTypedefBody) return o;
					final _c:$optionsCT = _copyOpt(o);
					_c._inTypedefBody = true;
					return _c;
				},
			}),
			pos: Context.currentPos(),
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
	private static function clearTypedefBodyField(optionsCT:ComplexType):Field {
		return {
			name: '_clearTypedefBody',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [{name: 'o', type: optionsCT}],
				ret: optionsCT,
				expr: macro {
					if (!o._inTypedefBody) return o;
					final _c:$optionsCT = _copyOpt(o);
					_c._inTypedefBody = false;
					return _c;
				},
			}),
			pos: Context.currentPos(),
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
	private static function setChainModeOverrideField(optionsCT:ComplexType):Field {
		return {
			name: '_setChainModeOverride',
			access: [APrivate, AStatic, AInline],
			kind: FFun({
				args: [
					{name: 'o', type: optionsCT},
					{name: 'mode', type: macro : Null<anyparse.format.wrap.WrapMode>},
				],
				ret: optionsCT,
				expr: macro {
					if (mode == null) return o;
					final _mode:anyparse.format.wrap.WrapMode = mode;
					if (o._chainModeOverride == _mode) return o;
					final _c:$optionsCT = _copyOpt(o);
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
					_c.opBoolChainWrap = {
						rules: [],
						defaultMode: _mode,
						defaultLocation: _resolveChainLoc(o.opBoolChainWrap),
					};
					_c.opAddSubChainWrap = {
						rules: [],
						defaultMode: _mode,
						defaultLocation: _resolveChainLoc(o.opAddSubChainWrap),
					};
					return _c;
				},
			}),
			pos: Context.currentPos(),
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
	private static function resolveChainLocField():Field {
		return {
			name: '_resolveChainLoc',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{name: 'r', type: macro : anyparse.format.wrap.WrapRules}],
				ret: macro : anyparse.format.wrap.WrappingLocation,
				expr: macro {
					final _dl:Null<anyparse.format.wrap.WrappingLocation> = r.defaultLocation;
					if (_dl != null) return _dl;
					var _i:Int = r.rules.length;
					while (--_i >= 0) {
						final _loc:Null<anyparse.format.wrap.WrappingLocation> = r.rules[_i].location;
						if (_loc != null) return _loc;
					}
					return anyparse.format.wrap.WrappingLocation.BeforeLast;
				},
			}),
			pos: Context.currentPos(),
		};
	}

	// -------- layout helpers --------

	/** Block layout: `open + nest(indent, [hardline+item]*) + hardline + close`. */
	private static function blockBodyField():Field {
		final body:Expr = macro {
			if (docs.length == 0) return _dt(open + close);
			final _items:Array<anyparse.core.Doc> = [];
			var _i:Int = 0;
			while (_i < docs.length) {
				_items.push(_dhl());
				_items.push(docs[_i]);
				_i++;
			}
			final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			return _dc([_dt(open), _dn(_cols, _dc(_items)), _dhl(), _dt(close)]);
		};
		return {
			name: 'blockBody',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'open', type: macro : String},
					{name: 'close', type: macro : String},
					{name: 'docs', type: macro : Array<anyparse.core.Doc>},
					{name: 'opt', type: macro : anyparse.format.WriteOptions},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Separated list in delimiters with fit-or-break layout.
	 *
	 * When `trailingComma` is `true`, a trailing `sep` is emitted after
	 * the last item only when the enclosing Group lays out in break
	 * mode — an `IfBreak` node carries the conditional. In flat mode
	 * the trailing position is `Empty`, so short lists render unchanged.
	 *
	 * `openInside` / `closeInside` are inside-of-delimiter padding Docs
	 * spliced between the open/close literals and the items, driven by
	 * `WhitespacePolicy.After`/`Both` on the open delim and
	 * `Before`/`Both` on the close delim (see `delimInsidePolicySpace`
	 * in `WriterLowering`). Default `Empty` keeps the pre-slice tight
	 * layout. Empty lists short-circuit to `_dt(open + close)` and skip
	 * inside padding regardless — `< >` for `Array<>` would be visually
	 * surprising and no fixture asks for it.
	 *
	 * `keepInnerWhenEmpty` (slice ω-anon-fn-empty-paren-inner-space) —
	 * when `true` AND the list is empty, splices a single space between
	 * the open and close literals (`( )` instead of `()`). Routed by
	 * `WriterLowering.keepInnerWhenEmptyExpr` from a per-field
	 * `@:fmt(keepInnerWhenEmpty('<flagName>'))` annotation; default
	 * `false` preserves the pre-slice tight emission for every other
	 * sepList caller that does not opt in.
	 */
	private static function sepListField():Field {
		final body:Expr = macro {
			if (items.length == 0) return _dt(open + (keepInnerWhenEmpty ? ' ' : '') + close);
			final _inner:Array<anyparse.core.Doc> = [];
			var _i:Int = 0;
			while (_i < items.length) {
				if (_i > 0) {
					_inner.push(_dt(sep));
					_inner.push(_dl());
				}
				_inner.push(items[_i]);
				_i++;
			}
			if (trailingComma) _inner.push(_dib(_dt(sep), _de()));
			final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			return _dg(_dc([
				_dt(open), openInside,
				_dn(_cols, _dc([_dsl(), _dc(_inner)])),
				_dsl(), closeInside, _dt(close),
			]));
		};
		return {
			name: 'sepList',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'open', type: macro : String},
					{name: 'close', type: macro : String},
					{name: 'sep', type: macro : String},
					{name: 'items', type: macro : Array<anyparse.core.Doc>},
					{name: 'opt', type: macro : anyparse.format.WriteOptions},
					{name: 'trailingComma', type: macro : Bool},
					{name: 'openInside', type: macro : anyparse.core.Doc},
					{name: 'closeInside', type: macro : anyparse.core.Doc},
					{name: 'keepInnerWhenEmpty', type: macro : Bool},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Fill-mode list in delimiters (Wadler `fillSep`). Items pack
	 * left-to-right inside the surrounding `Group`; on overflow the
	 * separator before the offending item breaks at the Fill's indent.
	 *
	 * Activated by `@:fmt(fill)` on a Star field; routed through
	 * `WriterLowering` instead of the canonical `sepList` for that field.
	 *
	 * Signature mirrors `sepList` for caller-site uniformity. Empty and
	 * single-item lists short-circuit through the standard delimited
	 * paths — Fill itself only kicks in for two-or-more items, where a
	 * fit decision matters. Trailing-comma / inside-pad / keep-inner-when-
	 * empty knobs are honoured the same way as in `sepList`.
	 */
	private static function fillListField():Field {
		final body:Expr = macro {
			if (items.length == 0) return _dt(open + (keepInnerWhenEmpty ? ' ' : '') + close);
			final _sepDoc:anyparse.core.Doc = _dc([_dt(sep), _dl()]);
			final _baseCols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			final _cols:Int = doubleIndent ? _baseCols * 2 : _baseCols;
			final _fill:anyparse.core.Doc = items.length == 1
				? items[0]
				: _dfill(items, _sepDoc);
			final _trail:anyparse.core.Doc = trailingComma
				? _dib(_dt(sep), _de())
				: _de();
			// No leading / trailing softline around items: in Fill mode the
			// first item follows `open` inline and the closing delim sits
			// directly after the last item. Hardlines between items get
			// their indent from the surrounding `Nest`. `doubleIndent` doubles
			// the continuation indent — matches haxe-formatter's convention
			// of indenting wrapped function parameters one level deeper than
			// the body so they remain visually distinct.
			return _dg(_dc([
				_dt(open), openInside,
				_dn(_cols, _dc([_fill, _trail])),
				closeInside, _dt(close),
			]));
		};
		return {
			name: 'fillList',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'open', type: macro : String},
					{name: 'close', type: macro : String},
					{name: 'sep', type: macro : String},
					{name: 'items', type: macro : Array<anyparse.core.Doc>},
					{name: 'opt', type: macro : anyparse.format.WriteOptions},
					{name: 'trailingComma', type: macro : Bool},
					{name: 'openInside', type: macro : anyparse.core.Doc},
					{name: 'closeInside', type: macro : anyparse.core.Doc},
					{name: 'keepInnerWhenEmpty', type: macro : Bool},
					{name: 'doubleIndent', type: macro : Bool},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	// -------- encoding helpers --------

	/** Format a float ensuring a decimal point is always present. */
	private static function formatFloatField():Field {
		final body:Expr = macro {
			final _s:String = Std.string(value);
			if (_s.indexOf('.') >= 0) return _s;
			return _s + '.0';
		};
		return {
			name: 'formatFloat',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{name: 'value', type: macro : Float}],
				ret: macro : String,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Render a captured leading-comment atom as a Doc.
	 * `content` is VERBATIM per `ω-leading-block-style` — it already
	 * carries its open/close delimiters (`//…` or `/*…*\/`), so line-
	 * vs-block choice survives round-trip without style guessing.
	 *
	 * Line-style comments and single-line block comments pass through
	 * as a single `Doc.Text` — there is no handle for re-indent when a
	 * comment fits on one line.
	 *
	 * Multi-line block comments and `//`-line bodies are delegated to
	 * the plugin-supplied trivia adapters carried on `WriteOptions`
	 * (`opt.blockCommentAdapter` / `opt.lineCommentAdapter`). The
	 * format singleton's `defaultWriteOptions` populates both — e.g.
	 * `HaxeFormat` wires them to `anyparse.format.comment.BlockCommentNormalizer` /
	 * `LineCommentNormalizer` entry
	 * points. Routing through `opt` keeps the macro core format-
	 * neutral: no module reference here names a specific grammar's
	 * normalizer, so a non-C-family format with its own comment
	 * adapter functions just sets these fields and reuses this
	 * helper unchanged.
	 */
	private static function leadingCommentDocField():Field {
		final body:Expr = macro {
			if (StringTools.startsWith(content, '//')) {
				final _line = opt.lineCommentAdapter;
				return _dt(_line == null ? content : _line(content, opt.addLineCommentSpace));
			}
			if (!StringTools.startsWith(content, '/*')) return _dt(content);
			if (content.indexOf('\n') < 0) return _dt(content);
			final _block = opt.blockCommentAdapter;
			return _block == null ? _dt(content) : _block(content, opt);
		};
		return {
			name: 'leadingCommentDoc',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'content', type: macro : String},
					{name: 'opt', type: macro : anyparse.format.WriteOptions},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Render a captured trailing-comment body as a Doc text atom
	 * prefixed with a space separator from the preceding element.
	 * Trailing capture rule guarantees single-line content (block
	 * comments with an internal newline attach as leading-of-next),
	 * so line style is always safe.
	 *
	 * `content` is the body AFTER `//`; we re-prepend the delimiter
	 * before passing through the line-comment normalizer so the
	 * `addLineCommentSpace` knob gates the same `//foo` → `// foo`
	 * rewrite the leading and verbatim variants apply.
	 */
	private static function trailingCommentDocField():Field {
		final body:Expr = macro {
			final _line = opt.lineCommentAdapter;
			return _dt(' ' + (_line == null ? '//' + content : _line('//' + content, opt.addLineCommentSpace)));
		};
		return {
			name: 'trailingCommentDoc',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'content', type: macro : String},
					{name: 'opt', type: macro : anyparse.format.WriteOptions},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Render a captured trailing-comment body as a Doc text atom
	 * prefixed with a space separator from the preceding element —
	 * VERBATIM variant that expects `content` to already include its
	 * delimiters (e.g. `// foo` or `/* foo *\/`). Used by close-trailing
	 * slots (ω-close-trailing / ω-close-trailing-alt) where the parser
	 * captures via `collectTrailingFull` so block-vs-line style is
	 * preserved across a round-trip. Per-element + AfterKw slots keep
	 * the stripped-body `trailingCommentDoc` helper above — that path
	 * normalises to line style by construction.
	 *
	 * ω-line-comment-space: routes through `opt.lineCommentAdapter`
	 * for the `addLineCommentSpace` rewrite (`//foo` → `// foo` when
	 * the knob is on, decoration runs survive tight). The plugin
	 * normalizer short-circuits non-`//` input, so a verbatim block-
	 * style trailing (`/* foo *\/`) passes through unchanged.
	 */
	private static function trailingCommentDocVerbatimField():Field {
		final body:Expr = macro {
			final _line = opt.lineCommentAdapter;
			return _dt(' ' + (_line == null ? content : _line(content, opt.addLineCommentSpace)));
		};
		return {
			name: 'trailingCommentDocVerbatim',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'content', type: macro : String},
					{name: 'opt', type: macro : anyparse.format.WriteOptions},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Splice a trailing Doc atom inside the outermost `BodyGroup`
	 * reachable by walking the Doc tree from the root. The match is
	 * "outermost" in the sense that once a `BodyGroup` is found, the
	 * folder stops descending — nested `BodyGroup`s inside the matched
	 * one are left alone. Walks `Concat` items right-to-left so the
	 * `BodyGroup` emitted by `bodyPolicyWrap` at the tail of a bearing
	 * writer's output is found first.
	 *
	 * Purpose: lets the trivia writer's `trailing`-comment attachment
	 * enter the body's fit/break measurement. Without this, the
	 * `BodyGroup` measures only its own inner content and picks `flat`
	 * on bodies that fit without the trailing, producing output that
	 * overflows once the comment is appended outside.
	 *
	 * Fallback: when no `BodyGroup` is found anywhere, returns a plain
	 * `Concat([doc, trailing])` — the trailing comment appends as a
	 * sibling, matching the behaviour writers without a FitLine body
	 * had before this helper was introduced (byte-identical for block
	 * bodies and simple statements like `VarStmt`/`ReturnStmt`).
	 */
	private static function foldTrailingIntoBodyGroupField():Field {
		final body:Expr = macro {
			final _folded:Null<anyparse.core.Doc> = _foldTrailingIntoBodyGroup(doc, trailing);
			return _folded != null ? _folded : _dc([doc, trailing]);
		};
		return {
			name: 'foldTrailingIntoBodyGroup',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'doc', type: macro : anyparse.core.Doc},
					{name: 'trailing', type: macro : anyparse.core.Doc},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	private static function foldTrailingRecursiveField():Field {
		final body:Expr = macro {
			switch (doc) {
				case anyparse.core.Doc.BodyGroup(inner):
					return _dbg(_appendInsideBodyGroup(inner, trailing));
				case anyparse.core.Doc.Concat(items):
					var _i:Int = items.length - 1;
					while (_i >= 0) {
						final _item:anyparse.core.Doc = items[_i];
						// ω-fold-trailing-stop-at-text: abort the backward walk at
						// a concrete `Text(s)` literal (non-empty `s`). Folding past
						// a trail keyword like `#end` or `}` would splice the
						// trailing comment INSIDE preceding structure (e.g. inner
						// BodyGroup), placing it BEFORE the literal in output.
						// Empty Text, Empty, Line, IfBreak etc. keep walking so
						// trailing whitespace/separator items don't block fold.
						switch (_item) {
							case anyparse.core.Doc.Text(s) if (s.length > 0):
								return null;
							case _:
						}
						final _folded:Null<anyparse.core.Doc> = _foldTrailingIntoBodyGroup(_item, trailing);
						if (_folded != null) {
							final _newItems:Array<anyparse.core.Doc> = items.copy();
							_newItems[_i] = _folded;
							return _dc(_newItems);
						}
						_i--;
					}
					return null;
				case anyparse.core.Doc.Nest(n, inner):
					final _folded:Null<anyparse.core.Doc> = _foldTrailingIntoBodyGroup(inner, trailing);
					return _folded != null ? _dn(n, _folded) : null;
				case _:
					return null;
			}
		};
		return {
			name: '_foldTrailingIntoBodyGroup',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'doc', type: macro : anyparse.core.Doc},
					{name: 'trailing', type: macro : anyparse.core.Doc},
				],
				ret: macro : Null<anyparse.core.Doc>,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	private static function appendInsideBodyGroupField():Field {
		final body:Expr = macro {
			switch (inner) {
				case anyparse.core.Doc.Nest(n, innerInner):
					return _dn(n, _appendInsideBodyGroup(innerInner, trailing));
				case anyparse.core.Doc.Concat(items):
					return _dc(items.concat([trailing]));
				case _:
					return _dc([inner, trailing]);
			}
		};
		return {
			name: '_appendInsideBodyGroup',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'inner', type: macro : anyparse.core.Doc},
					{name: 'trailing', type: macro : anyparse.core.Doc},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * ω-issue-316 — render the kw→body gap for `@:optional @:kw(...)` Ref
	 * fields in Trivia mode. Output shape depends on captured trivia:
	 *  - both slots empty → space when `nextCurly` is `false`, hardline
	 *    when `true` (byte-identical pre-slice when `false`).
	 *  - `afterKw != null` → ` //<body>` trailing after the kw, then
	 *    hardline back to outer indent.
	 *  - `kwLeading` non-empty → each comment on its own line at the
	 *    body's interior indent (`cols` deeper than outer), then hardline
	 *    back to outer indent before the body token.
	 *  - both populated → trailing first (same line as kw), then the
	 *    own-line leading block, then closing hardline.
	 *
	 * `nextCurly` (ω-issue-316-curly-both) only affects the no-trivia
	 * path. When trivia is captured, the function already emits a
	 * trailing hardline — adding another would produce a blank row. The
	 * caller passes `opt.leftCurly == Next` only when the body writeCall
	 * begins with `{` (block ctor); in every other context, pass `false`.
	 *
	 * Caller concatenates the result with the body's writeCall — the
	 * closing hardline hands control to the Renderer at the parent's
	 * indent level so the body's lead brace lands there.
	 */
	private static function kwBeforeDocField():Field {
		final body:Expr = macro {
			if (beforeKwLeading.length == 0) return sepDoc;
			// Emit at the parent's indent (no `_dn` wrap) — the comment block
			// occupies the same indent column as `}` and `else`. Hardline
			// before each comment, plus a final hardline so the kw lands on
			// its own line at the parent indent.
			final _parts:Array<anyparse.core.Doc> = [];
			for (_c in beforeKwLeading) {
				_parts.push(_dhl());
				_parts.push(leadingCommentDoc(_c, opt));
			}
			_parts.push(_dhl());
			return _dc(_parts);
		};
		return {
			name: 'kwBeforeDoc',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'beforeKwLeading', type: macro : Array<String>},
					{name: 'sepDoc', type: macro : anyparse.core.Doc},
					{name: 'opt', type: macro : anyparse.format.WriteOptions},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * ω-trivia-before-kw-trailing — render the same-line trailing comment
	 * captured between a preceding sibling's last token and an
	 * `@:optional @:kw` keyword (e.g. `resize(); // first\nelse`). Returns
	 * the caller's separator unchanged when `trailing` is `null`. Otherwise
	 * concatenates ` //<body>` (via `trailingCommentDoc`) BEFORE the
	 * separator so the comment cuddles to the prior token; the separator
	 * (hardline or `kwBeforeDoc` output) follows and breaks back to the
	 * parent indent before the kw.
	 */
	private static function kwBeforeTrailingDocField():Field {
		final body:Expr = macro {
			if (trailing == null) return sepDoc;
			return _dc([trailingCommentDoc(trailing, opt), sepDoc]);
		};
		return {
			name: 'kwBeforeTrailingDoc',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'trailing', type: macro : Null<String>},
					{name: 'sepDoc', type: macro : anyparse.core.Doc},
					{name: 'opt', type: macro : anyparse.format.WriteOptions},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	private static function kwGapDocField():Field {
		final body:Expr = macro {
			if (afterKw == null && kwLeading.length == 0) return nextCurly ? _dhl() : _dt(' ');
			final _parts:Array<anyparse.core.Doc> = [];
			if (afterKw != null) {
				_parts.push(_dt(' '));
				_parts.push(_dt('//' + afterKw));
			}
			if (kwLeading.length > 0) {
				final _nested:Array<anyparse.core.Doc> = [];
				for (_c in kwLeading) {
					_nested.push(_dhl());
					_nested.push(leadingCommentDoc(_c, opt));
				}
				_parts.push(_dn(cols, _dc(_nested)));
			}
			_parts.push(_dhl());
			return _dc(_parts);
		};
		return {
			name: 'kwGapDoc',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'afterKw', type: macro : Null<String>},
					{name: 'kwLeading', type: macro : Array<String>},
					{name: 'cols', type: macro : Int},
					{name: 'nextCurly', type: macro : Bool},
					{name: 'opt', type: macro : anyparse.format.WriteOptions},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * ω-trivia-after-kw-next-layout — render the kw→body gap on the
	 * `bodyPolicyWrap` Next-layout path for `@:optional @:kw(...)` Ref
	 * fields in Trivia mode. Mirror of `kwGapDoc` (which serves the
	 * Same-layout side); the difference is that here the body MUST land
	 * one indent deeper at the next line regardless of whether trivia
	 * was captured. The body always lands inside `Nest(cols, …)` so it
	 * sits at the parent's indent + cols.
	 *
	 *  - Both slots empty → `Nest(cols, [hardline, body])` (byte-
	 *    identical to the pre-slice nextLayoutExpr).
	 *  - `afterKw != null` → ` //<afterKw>` cuddled to the kw OUTSIDE
	 *    the Nest, then `Nest(cols, [hardline, body])`.
	 *  - `kwLeading` non-empty → each leading comment on its own line
	 *    at the body's interior indent (inside the Nest), separated by
	 *    hardlines, then the body at the same interior indent.
	 *  - Both populated → afterKw first (sameline cuddle), then the
	 *    nested leadings + body block.
	 */
	private static function nextLayoutKwGapDocField():Field {
		final body:Expr = macro {
			final _innerParts:Array<anyparse.core.Doc> = [_dhl()];
			for (_c in kwLeading) {
				_innerParts.push(leadingCommentDoc(_c, opt));
				_innerParts.push(_dhl());
			}
			_innerParts.push(bodyDoc);
			final _nested:anyparse.core.Doc = _dn(cols, _dc(_innerParts));
			return afterKw == null ? _nested : _dc([trailingCommentDoc(afterKw, opt), _nested]);
		};
		return {
			name: 'nextLayoutKwGapDoc',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'afterKw', type: macro : Null<String>},
					{name: 'kwLeading', type: macro : Array<String>},
					{name: 'cols', type: macro : Int},
					{name: 'bodyDoc', type: macro : anyparse.core.Doc},
					{name: 'opt', type: macro : anyparse.format.WriteOptions},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/** Escape a string for double-quoted output using the format's escapeChar. */
	private static function escapeStringField(formatInfo:FormatReader.FormatInfo):Field {
		final fmtParts:Array<String> = formatInfo.schemaTypePath.split('.');
		final body:Expr = macro {
			final _buf:StringBuf = new StringBuf();
			_buf.add('"');
			var _i:Int = 0;
			while (_i < value.length) {
				final _c:Null<Int> = value.charCodeAt(_i);
				if (_c != null) _buf.add($p{fmtParts}.instance.escapeChar(_c));
				_i++;
			}
			_buf.add('"');
			return _buf.toString();
		};
		return {
			name: 'escapeString',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{name: 'value', type: macro : String}],
				ret: macro : String,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	private static function simpleName(typePath:String):String {
		final idx:Int = typePath.lastIndexOf('.');
		return idx == -1 ? typePath : typePath.substring(idx + 1);
	}
}
#end
