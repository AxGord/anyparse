package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;

using Lambda;

/**
 * A chain's walk from one link (`WriterMetaLineEndLowering.chainWalk`): the statements binding `_tail` and
 * `_chainSimple`, and the pattern of a next link.
 */
typedef ChainWalk = { final decls: Array<Expr>; final pattern: Expr; }
/**
 * Pass 3W — the one answer to "which line-end policy governs this metadata run".
 *
 * `@:fmt(metaLineEndPolicy('<optField>'))` names the knob of a metadata Star.
 * `@:fmt(metaLineEndIfCtor('<sibling>', '<optField>', '<Ctor>', …))` narrows it by the constructor
 * of the sibling the metadata annotates, because which knob applies — a `var`'s or a `function`'s —
 * is known only from what follows the run. `@:fmt(metaLineEndChain('<Ctor>', '<field>'))` makes a
 * bare Ref a metadata site: its annotated value is reached through the wrapper constructor nested
 * annotations are built from. `@:fmt(metaLineEndSimple('<predicate>'))` names the generated AST
 * predicate that tells a simple annotation, which the `Fit` policy may place by width; a chain names
 * the wrapper's annotation field after it. A site that names none has no simple annotation.
 * `@:fmt(metaLineEndInlineMax('<optField>'))` names the Int knob that caps the written width of a lone simple
 * annotation kept on its declaration's line; `0` is no cap, and so is a site that names none.
 */
@:access(anyparse.macro.WriterCtorPatternLowering, anyparse.macro.WriterLoweringSupport)
final class WriterMetaLineEndLowering {

	private static final SIMPLE_META: String = 'metaLineEndSimple';
	private static final CHAIN_META: String = 'metaLineEndChain';
	private static final INLINE_MAX_META: String = 'metaLineEndInlineMax';
	private static final TRIVIA_META: String = ':trivia';

	/**
	 * The runtime locals of a metadata run under its knob `raw`: `_metaFit` is `1` for one simple element, which
	 * keeps the declaration's line when that line fits, `2` for several, which share one row of their own when it
	 * fits, and `0` otherwise; `_metaPolicy` is the knob with `Fit` read as `After` (when `_metaFit` is `0`) or `AfterLast`. A run
	 * holding a comment (`broken`) is never fit: its row breaks as under `After`. `pred` is `simplePred`'s answer.
	 * `_metaFit` stays assignable for `fitInlineCapExpr`, which reads the element once it is written.
	 */
	public static function fitDecls(pred: Null<Expr>, raw: Expr, arr: Expr, elemNode: Expr -> Expr, broken: Expr): Expr {
		final pos: Position = Context.currentPos();
		final fit: Expr = if (pred == null) {
			macro 0;
		} else {
			final test: Expr = { expr: ECall(pred, [elemNode(macro _fe)]), pos: pos };
			macro _metaRaw == anyparse.format.MetadataLineEndPolicy.Fit && $arr.length > 0 && !$broken
				&& !Lambda.exists($arr, _fe -> !$test)
				? ($arr.length == 1 ? 1 : 2)
				: 0;
		};
		final policy: Expr = macro _metaRaw == anyparse.format.MetadataLineEndPolicy.Fit
			? (_metaFit == 0 ? anyparse.format.MetadataLineEndPolicy.After : anyparse.format.MetadataLineEndPolicy.AfterLast)
			: _metaRaw;
		return {
			expr: EVars([
				{
					name: '_metaRaw',
					type: macro : Int,
					expr: raw,
					isFinal: true
				},
				{
					name: '_metaFit',
					type: macro : Int,
					expr: fit,
					isFinal: false
				},
				{
					name: '_metaPolicy',
					type: macro : Int,
					expr: policy,
					isFinal: true
				}
			]),
			pos: pos
		};
	}

	/**
	 * The statement that takes a lone simple element off its declaration's line once its written `elemDoc` is wider
	 * than the cap `field` names: `_metaFit` falls to `0`, so the element breaks as under `After`. A lone element has
	 * no separator, so `_metaPolicy` needs no second reading. A no-op when the field names no cap.
	 */
	public static function fitInlineCapExpr(field: ShapeNode, elemDoc: Expr): Expr {
		final wide: Null<Expr> = overInlineMaxExpr(field, elemDoc);
		return wide == null ? macro {} : macro if (_metaFit == 1 && $wide) _metaFit = 0;
	}

	/**
	 * The doc a lone element of a `Fit` run is pushed as: flat whenever it fits its own line, as it then stands in
	 * either outcome, so a break inside it (an operator argument's) never weighs the declaration that may follow it.
	 */
	public static function fitLoneDocExpr(elemDoc: Expr): Expr {
		return macro _metaFit == 1
			? anyparse.core.Doc.IfWidthExceeds(opt.lineWidth + 1, $elemDoc, anyparse.core.Doc.HardFlatten($elemDoc))
			: $elemDoc;
	}

	/** The separator between two elements of a run that does not break after each: a soft line inside a `Fit` row. */
	public static function fitSepExpr(): Expr {
		return macro (_metaFit == 2 ? _dl() : _dt(' '));
	}

	/**
	 * Whether the separator before an element of a run is the source's own break: under `None` a break the source has
	 * between two elements stays, as `newlineBefore` reads it. Never for a run inside a declaration (`inDecl`, the
	 * run's `metaLineEndInline`), where a break would split it.
	 */
	public static function noneKeepsBreakExpr(inDecl: Bool, newlineBefore: Expr): Expr {
		return inDecl ? macro false : macro _metaPolicy == anyparse.format.MetadataLineEndPolicy.None && $newlineBefore;
	}

	/** The break after a run's last element: a lone simple one under `Fit` stays on the line it fits. */
	public static function fitAfterLastExpr(): Expr {
		return macro (_metaFit == 1 ? _dfle(opt.lineWidth + 1, _dhl(), _dt(' ')) : _dhl());
	}

	/** Wraps `_docs` from `from` on in one group when the run is a `Fit` row: it stays one line when it fits, else one per line. */
	public static function fitRowWrapExpr(from: Expr): Expr {
		return macro if (_metaFit == 2) {
			final _row: Array<anyparse.core.Doc> = _docs.splice($from, _docs.length - $from);
			_docs.push(_dg(_dc(_row)));
		};
	}

	/**
	 * The runtime policy of a metadata run, or `null` when the field names no knob. `@:fmt(metaLineEndInline)`
	 * answers `None` for a run that sits inside a declaration (between a `var` keyword and its name), where a
	 * break would split it. `subject` replaces the sibling's own value for a chain, whose annotated value is
	 * known only at the tail; `owner` replaces `value` as the struct holding the sibling. With no knob of its own, a
	 * value no arm names answers `-1`: no metadata site.
	 */
	public static function policyExpr(
		ctx: WriterCtorPatternLowering.CtorPatternCtx, field: ShapeNode, typePath: String, ?subject: Expr, ?owner: Expr
	): Null<Expr> {
		if (MetaInspect.fmtHasFlag(field, 'metaLineEndInline')) return macro anyparse.format.MetadataLineEndPolicy.None;
		final own: Null<String> = MetaInspect.fmtReadString(field, 'metaLineEndPolicy');
		final arms: Array<Array<String>> = MetaInspect.fmtReadStringArgsAll(field, 'metaLineEndIfCtor');
		if (own == null && arms.length == 0) return null;
		final fallback: Expr = own == null ? (macro -1) : WriterLoweringSupport.optFieldAccess(own);
		if (arms.length == 0) return fallback;
		final pos: Position = Context.currentPos();
		final sibling: String = arms[0][0];
		final refName: String = fieldRefName(ctx, typePath, sibling);
		final cases: Array<Case> = [{ values: [macro null], expr: fallback, guard: null }];
		for (arm in arms) {
			if (arm.length < 3 || arm[0] != sibling)
				Context.fatalError(
					'WriterLowering: @:fmt(metaLineEndIfCtor) expects (sibling, optField, Ctor, ...) over one sibling on $typePath', pos
				);
			final patterns: Array<Expr> = [ for (i in 2...arm.length) ctorPattern(ctx, refName, arm[i]) ];
			cases.push({ values: patterns, expr: WriterLoweringSupport.optFieldAccess(arm[1]), guard: null });
		}
		final access: Expr = subject ?? { expr: EField(owner ?? macro value, sibling), pos: pos };
		return { expr: ESwitch(access, cases, fallback), pos: pos };
	}

	/**
	 * The separator after one annotation of a chain joined to `doc`, the rest of the chain, or `null` when the field is
	 * no chain. Every annotation of a chain shares the policy of the value at its tail: `After` breaks after each, every
	 * other policy but `None` keeps the inner ones on one line and breaks after the last one; under `None` every separator
	 * is the source's own (`sourceSep`). Under `Fit` the outermost link decides for the whole chain (`chainOptExpr` hands its
	 * answer down): a lone simple annotation joins the declaration when the line fits, several simple ones are one group
	 * of soft lines whose closing break stays outside its measure, and a complex one breaks after each. A chain whose
	 * tail no arm names is no metadata site: `sourceSep` stands. `writeFnFor` names the writer of a rule: a lone simple
	 * annotation wider than the field's inline cap is written once more to be measured, and breaks.
	 */
	public static function chainJoinExpr(
		ctx: WriterCtorPatternLowering.CtorPatternCtx, field: ShapeNode, typePath: String, fieldAccess: Expr, sourceSep: Expr, trivia: Bool,
		doc: Expr, writeFnFor: String -> String
	): Null<Expr> {
		final walk: Null<ChainWalk> = chainWalk(ctx, field, typePath, fieldAccess, trivia);
		if (walk == null) return null;
		final pos: Position = Context.currentPos();
		final policy: Null<Expr> = policyExpr(ctx, field, typePath, macro _tail);
		if (policy == null) Context.fatalError('WriterLowering: @:fmt(metaLineEndChain) needs a metaLineEndIfCtor on $typePath', pos);
		final chainPat: Expr = walk.pattern;
		final simple: Null<Array<String>> = MetaInspect.fmtReadStringArgs(field, SIMPLE_META);
		final ownWide: Expr = simple == null || simple.length != 2 ? macro false : {
			final own: Expr = { expr: EField(macro value, simple[1]), pos: pos };
			final ownDoc: Expr = { expr: ECall(macro $i{writeFnFor(fieldRefName(ctx, typePath, simple[1]))}, [own, macro opt]), pos: pos };
			overInlineMaxExpr(field, ownDoc) ?? macro false;
		};
		final decide: Expr = macro {
			final _policy: anyparse.format.MetadataLineEndPolicy = $policy;
			final _link: Bool = $fieldAccess.match($chainPat);
			if ((_policy: Int) < 0 || _policy == anyparse.format.MetadataLineEndPolicy.None)
				_dc([$sourceSep, $doc]);
			else if (_policy == anyparse.format.MetadataLineEndPolicy.Fit)
				switch (opt._metaChain) {
					case 0 if (_chainSimple && _link):
						_dg(_dc([_dl(), $doc]));
					case 0 if (_chainSimple && !$ownWide):
						_dc([_dile(opt.lineWidth + 1, _dhl(), _dt(' ')), $doc]);
					case 1 if (_link):
						_dc([_dl(), $doc]);
					case 1:
						_dbg(_dc([_dhl(), $doc]));
					case _:
						_dc([_dhl(), $doc]);
				}
			else if (!_link || _policy == anyparse.format.MetadataLineEndPolicy.After)
				_dc([_dhl(), $doc]);
			else
				_dc([_dt(' '), $doc]);
		};
		return { expr: EBlock(walk.decls.concat([decide])), pos: pos };
	}

	/**
	 * `optExpr` with the chain context the next field is written under: on a link of a chain, the outermost link's
	 * answer (`1` when every annotation is simple, `2` when one is complex); cleared on the tail and on every other field
	 * of a link, which no chain reaches through. `optExpr` itself when no field of `typePath` is a chain.
	 */
	public static function chainOptExpr(
		ctx: WriterCtorPatternLowering.CtorPatternCtx, field: ShapeNode, typePath: String, fieldAccess: Expr, optExpr: Expr, trivia: Bool
	): Expr {
		final walk: Null<ChainWalk> = chainWalk(ctx, field, typePath, fieldAccess, trivia);
		if (walk == null) {
			final rule: Null<ShapeNode> = ctx.shape.rules[typePath];
			final inChain: Bool = rule != null && rule.children.exists(c -> MetaInspect.fmtReadStringArgs(c, CHAIN_META) != null);
			return inChain ? macro _setMetaChain($optExpr, 0, opt) : optExpr;
		}
		final chainPat: Expr = walk.pattern;
		final outermost: Expr = { expr: EBlock(walk.decls.concat([macro _chainSimple ? 1 : 2])), pos: Context.currentPos() };
		return macro _setMetaChain($optExpr, !$fieldAccess.match($chainPat) ? 0 : opt._metaChain != 0 ? opt._metaChain : $outermost, opt);
	}

	/**
	 * Whether the run in `field` annotates anything: `null` when a required field follows it in the
	 * struct `typePath`, else the runtime test that one of the optional fields after it is present.
	 * A run that annotates nothing (a region before `}` or the end of the file) owes no break.
	 */
	public static function annotatesExpr(
		ctx: WriterCtorPatternLowering.CtorPatternCtx, field: ShapeNode, typePath: String, fieldAccess: Expr
	): Null<Expr> {
		final rule: Null<ShapeNode> = ctx.shape.rules[typePath];
		final owner: Null<Expr> = switch fieldAccess.expr {
			case EField(o, _): o;
			case _: null;
		};
		if (rule == null || owner == null) return null;
		final at: Int = rule.children.indexOf(field);
		if (at < 0) return null;
		var test: Null<Expr> = null;
		for (i in at + 1...rule.children.length) {
			final next: ShapeNode = rule.children[i];
			final name: String = next.annotations[AnnotationKeys.BASE_FIELD_NAME];
			final access: Expr = { expr: EField(owner, name), pos: fieldAccess.pos };
			final present: Expr = if (next.kind == Star)
				macro $access.length > 0;
			else if (next.annotations[AnnotationKeys.BASE_OPTIONAL] == true)
				macro $access != null;
			else
				return null;
			test = test == null ? present : macro $test || $present;
		}
		return test ?? macro false;
	}

	/** The generated predicate `@:fmt(metaLineEndSimple('<predicate>'))` on the run's field names, or `null`. */
	public static function simplePred(field: ShapeNode, rootTypePath: String, trivia: Bool): Null<Expr> {
		final simple: Null<Array<String>> = MetaInspect.fmtReadStringArgs(field, SIMPLE_META);
		return simple == null || simple.length == 0 ? null : AstPredLowering.predFnExpr(rootTypePath, trivia, false, simple[0]);
	}

	/**
	 * Whether a comment stands between the run in `field` and what it annotates: the leading comments of the first
	 * element of the next non-empty trivia run, or those the parser keeps in the gap before the next bare field
	 * (`TriviaPairSlots.isBareNonFirstRef`). A run followed by such a comment is broken, as one holding a comment.
	 */
	public static function gapCommentExpr(
		ctx: WriterCtorPatternLowering.CtorPatternCtx, field: ShapeNode, typePath: String, fieldAccess: Expr
	): Expr {
		final rule: Null<ShapeNode> = ctx.shape.rules[typePath];
		final owner: Null<Expr> = switch fieldAccess.expr {
			case EField(o, _): o;
			case _: null;
		};
		if (rule == null || owner == null) return macro false;
		final at: Int = rule.children.indexOf(field);
		return at < 0
			? macro false
			: nextFieldGapExpr(
				rule, field, owner, fieldAccess.pos, e -> macro $e.leadingComments.length > 0, TriviaTypeSynth.BEFORE_LEADING_SUFFIX,
				g -> macro $g.length > 0
			);
	}

	/**
	 * Whether the metadata run in the field `fieldName` of the struct `typePath`, read off `owner`, ends on a line of its own
	 * above what it annotates, as this module's policy writes it: the one answer to "does a member's metadata stand on its own
	 * line": one annotation of the run on a line above it is enough. `None`, and a site with no knob, keep the source's
	 * breaks, inside the run and after it; `Fit` keeps a lone simple annotation on the
	 * declaration's line, read as kept even where that line overflows at render; every other policy breaks after the run.
	 * `null` when the field is no metadata run. `writeFnFor` names the writer of a rule, which measures a lone annotation
	 * against its inline cap.
	 */
	public static function ownLineExpr(
		ctx: WriterCtorPatternLowering.CtorPatternCtx, writeFnFor: String -> String, typePath: String, fieldName: String, owner: Expr
	): Null<Expr> {
		final rule: Null<ShapeNode> = ctx.shape.rules[typePath];
		if (rule == null) return null;
		final field: Null<ShapeNode> = rule.children.find(c -> c.annotations[AnnotationKeys.BASE_FIELD_NAME] == fieldName);
		if (field == null || field.kind != Star || !MetaInspect.hasMeta(field, TRIVIA_META)) return null;
		final pos: Position = Context.currentPos();
		final access: Expr = { expr: EField(owner, fieldName), pos: pos };
		final trailLC: Expr = { expr: EField(owner, fieldName + TriviaTypeSynth.TRAILING_LEADING_SUFFIX), pos: pos };
		final decls: Expr = decisionDecls(ctx, field, typePath, access, macro _omArr, trailLC, owner);
		final elemRef: Null<String> = field.children.length == 1 ? field.children[0].annotations[AnnotationKeys.BASE_REF] : null;
		final cap: Expr = elemRef == null
			? macro {}
			: fitInlineCapExpr(field, { expr: ECall(macro $i{writeFnFor(elemRef)}, [macro _omArr[0].node, macro opt]), pos: pos });
		final nextBreak: Expr = nextFieldGapExpr(
			rule, field, owner, pos, e -> macro $e.newlineBefore, TriviaTypeSynth.BEFORE_NEWLINE_SUFFIX, g -> g
		);
		final runBreak: Expr = macro Lambda.exists(_omArr.slice(1), _fe -> _fe.newlineBefore);
		final sourceBreak: Expr = macro $runBreak || $nextBreak;
		return macro {
			final _omArr = $access;
			$decls;
			$cap;
			if (_metaRaw == -2)
				true;
			else if (_metaPolicy < 0 || _metaPolicy == anyparse.format.MetadataLineEndPolicy.None)
				$sourceBreak;
			else
				_metaFit != 1;
		};
	}

	/**
	 * The `fitDecls` locals of the run `arr` in `field` of the struct `typePath`, reached as `fieldAccess`, with `trailLC` its
	 * trailing comments: the one composition the run's writer and `ownLineExpr` both read, so the blank-line verdict decides
	 * from the decision the writer makes. A run that annotates nothing answers `-2`, keeping its source layout with no break
	 * owed after its last element; a run holding a comment, or followed by one before what it annotates, breaks as under
	 * `After`. `owner` is `policyExpr`'s.
	 */
	public static function decisionDecls(
		ctx: WriterCtorPatternLowering.CtorPatternCtx, field: ShapeNode, typePath: String, fieldAccess: Expr, arr: Expr, trailLC: Expr,
		?owner: Expr
	): Expr {
		final own: Null<Expr> = policyExpr(ctx, field, typePath, null, owner);
		final annotates: Null<Expr> = own == null ? null : annotatesExpr(ctx, field, typePath, fieldAccess);
		final raw: Expr = if (own == null)
			macro -1
		else if (annotates == null)
			own
		else
			macro ($annotates ? ($own: Int) : -2);
		final broken: Expr = macro ${gapCommentExpr(ctx, field, typePath, fieldAccess)}
			|| $trailLC.length > 0
			|| Lambda.exists($arr, _fe -> _fe.leadingComments.length > 0 || _fe.trailingComment != null);
		return fitDecls(simplePred(field, ctx.shape.root, true), raw, arr, e -> macro $e.node, broken);
	}

	/** Whether the written `doc` of one annotation is wider than the cap `field` names, or `null` when it names none. */
	private static function overInlineMaxExpr(field: ShapeNode, doc: Expr): Null<Expr> {
		final knob: Null<String> = MetaInspect.fmtReadString(field, INLINE_MAX_META);
		if (knob == null) return null;
		final max: Expr = WriterLoweringSupport.optFieldAccess(knob);
		return macro $max > 0 && anyparse.core.DocMeasure.flatTokenWidth($doc) > $max;
	}

	/**
	 * The walk of a chain from the link holding `field`: `_tail` ends at the annotated value and `_chainSimple` tells
	 * whether every annotation on the way is simple; `pattern` matches a next link. `null` when the field is no chain.
	 */
	private static function chainWalk(
		ctx: WriterCtorPatternLowering.CtorPatternCtx, field: ShapeNode, typePath: String, fieldAccess: Expr, trivia: Bool
	): Null<ChainWalk> {
		final chain: Null<Array<String>> = MetaInspect.fmtReadStringArgs(field, CHAIN_META);
		if (chain == null) return null;
		final pos: Position = Context.currentPos();
		if (chain.length != 2)
			Context.fatalError('WriterLowering: @:fmt(metaLineEndChain) expects (ctorName, fieldName) on $typePath', pos);
		final refName: String = fieldRefName(ctx, typePath, field.annotations[AnnotationKeys.BASE_FIELD_NAME]);
		final chainPat: Expr = ctorPattern(ctx, refName, chain[0]);
		final innerAccess: Expr = { expr: EField(macro _mv, chain[1]), pos: pos };
		final simple: Null<Array<String>> = MetaInspect.fmtReadStringArgs(field, SIMPLE_META);
		final pred: Null<Expr> = simple == null || simple.length != 2 ? null : simplePred(field, ctx.shape.root, trivia);
		final ownSimple: Expr = pred == null
			? macro false
			: { expr: ECall(pred, [{ expr: EField(macro value, simple[1]), pos: pos }]), pos: pos };
		final innerSimple: Expr = pred == null
			? macro false
			: { expr: ECall(pred, [{ expr: EField(macro _mv, simple[1]), pos: pos }]), pos: pos };
		final peel: Expr = {
			expr: ESwitch(macro _tail, [{
				values: [bindFirstArg(chainPat)],
				expr: macro {
					_chainSimple = _chainSimple && $innerSimple;
					_tail = $innerAccess;
				},
				guard: null
			}], macro break),
			pos: pos
		};
		return {
			decls: [
				(macro var _tail = $fieldAccess),
				(macro var _chainSimple: Bool = $ownSimple),
				macro while (true) $peel
			],
			pattern: chainPat
		};
	}

	/** The referenced rule of a named field of the struct `typePath`. */
	private static function fieldRefName(ctx: WriterCtorPatternLowering.CtorPatternCtx, typePath: String, fieldName: String): String {
		final rule: Null<ShapeNode> = ctx.shape.rules[typePath];
		if (rule != null) for (c in rule.children) if (c.annotations[AnnotationKeys.BASE_FIELD_NAME] == fieldName) {
			final refName: Null<String> = c.annotations[AnnotationKeys.BASE_REF];
			if (refName != null) return refName;
		}
		return Context.fatalError(
			'WriterLowering: metadata line-end sibling "$fieldName" is no Ref field of $typePath', Context.currentPos()
		);
	}

	private static function ctorPattern(ctx: WriterCtorPatternLowering.CtorPatternCtx, refName: String, ctor: String): Expr {
		final pattern: Null<Expr> = WriterCtorPatternLowering.findCtorPattern(ctx, refName, ctor);
		if (pattern == null)
			Context.fatalError('WriterLowering: metadata line-end ctor "$ctor" not found in enum $refName', Context.currentPos());
		return pattern;
	}

	/** The pattern with its first argument bound to `_mv`, the wrapper's annotated value. */
	private static function bindFirstArg(pattern: Expr): Expr {
		return switch pattern.expr {
			case ECall(target, args) if (args.length > 0): { expr: ECall(target, [macro _mv].concat(args.slice(1))), pos: pattern.pos };
			case _: Context.fatalError('WriterLowering: @:fmt(metaLineEndChain) ctor takes no argument', pattern.pos);
		};
	}

	/**
	 * What the source holds right after the run in `field` of `rule`, read off `owner`: `first` of the first element of the
	 * next non-empty trivia run, or `bare` of the slot `<name><bareSuffix>` the parser keeps in the gap before the next bare
	 * field (`TriviaPairSlots.isBareNonFirstRef`). Any other next field answers `false`.
	 */
	private static function nextFieldGapExpr(
		rule: ShapeNode, field: ShapeNode, owner: Expr, pos: Position, first: Expr -> Expr, bareSuffix: String, bare: Expr -> Expr
	): Expr {
		final at: Int = rule.children.indexOf(field);
		var test: Expr = macro false;
		var i: Int = rule.children.length;
		while (--i > at) {
			final next: ShapeNode = rule.children[i];
			final name: String = next.annotations[AnnotationKeys.BASE_FIELD_NAME];
			final access: Expr = { expr: EField(owner, name), pos: pos };
			test = if (next.kind == Star) {
				final head: Expr = MetaInspect.hasMeta(next, TRIVIA_META) ? first(macro $access[0]) : macro false;
				macro $access.length == 0 ? $test : $head;
			} else if (TriviaPairSlots.isBareNonFirstRef(next, rule)) {
				bare({ expr: EField(owner, name + bareSuffix), pos: pos });
			} else {
				macro false;
			};
		}
		return test;
	}

}
#end
