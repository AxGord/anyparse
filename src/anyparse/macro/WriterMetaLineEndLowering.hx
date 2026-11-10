package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * Pass 3W — the one answer to "which line-end policy governs this metadata run".
 *
 * `@:fmt(metaLineEndPolicy('<optField>'))` names the knob of a metadata Star.
 * `@:fmt(metaLineEndIfCtor('<sibling>', '<optField>', '<Ctor>', …))` narrows it by the constructor
 * of the sibling the metadata annotates, because which knob applies — a `var`'s or a `function`'s —
 * is known only from what follows the run. `@:fmt(metaLineEndChain('<Ctor>', '<field>'))` makes a
 * bare Ref a metadata site: its annotated value is reached through the wrapper constructor nested
 * annotations are built from.
 */
@:access(anyparse.macro.WriterCtorPatternLowering, anyparse.macro.WriterLoweringSupport)
final class WriterMetaLineEndLowering {

	/**
	 * The runtime policy of a metadata run, or `null` when the field names no knob. `subject`
	 * replaces the sibling's own value for a chain, whose annotated value is known only at the tail.
	 * With no knob of its own, a value no arm names answers `-1`: no metadata site.
	 */
	public static function policyExpr(
		ctx: WriterCtorPatternLowering.CtorPatternCtx, field: ShapeNode, typePath: String, ?subject: Expr
	): Null<Expr> {
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
			final patterns: Array<Expr> = [for (i in 2...arm.length) ctorPattern(ctx, refName, arm[i])];
			cases.push({ values: patterns, expr: WriterLoweringSupport.optFieldAccess(arm[1]), guard: null });
		}
		final access: Expr = subject ?? { expr: EField(macro value, sibling), pos: pos };
		return { expr: ESwitch(access, cases, fallback), pos: pos };
	}

	/**
	 * The separator after one annotation of a chain, or `null` when the field is no chain. Every
	 * annotation of a chain shares the policy of the value at its tail: `After` breaks after each,
	 * every other policy keeps the inner ones on one line, and the last one breaks unless the policy
	 * is `None`; no separator of a chain follows the source. A chain whose tail no arm names is no
	 * metadata site: `sourceSep` stands.
	 */
	public static function chainSepExpr(
		ctx: WriterCtorPatternLowering.CtorPatternCtx, field: ShapeNode, typePath: String, fieldAccess: Expr, sourceSep: Expr
	): Null<Expr> {
		final chain: Null<Array<String>> = MetaInspect.fmtReadStringArgs(field, 'metaLineEndChain');
		if (chain == null) return null;
		final pos: Position = Context.currentPos();
		if (chain.length != 2)
			Context.fatalError('WriterLowering: @:fmt(metaLineEndChain) expects (ctorName, fieldName) on $typePath', pos);
		final refName: String = fieldRefName(ctx, typePath, field.annotations[AnnotationKeys.BASE_FIELD_NAME]);
		final chainPat: Expr = ctorPattern(ctx, refName, chain[0]);
		final innerAccess: Expr = { expr: EField(macro _mv, chain[1]), pos: pos };
		final peel: Expr = {
			expr: ESwitch(macro _tail, [
				{ values: [bindFirstArg(chainPat)], expr: macro _tail = $innerAccess, guard: null }
			], macro break),
			pos: pos
		};
		final policy: Null<Expr> = policyExpr(ctx, field, typePath, macro _tail);
		if (policy == null) Context.fatalError('WriterLowering: @:fmt(metaLineEndChain) needs a metaLineEndIfCtor on $typePath', pos);
		return macro {
			var _tail = $fieldAccess;
			while (true) $peel;
			final _policy: anyparse.format.MetadataLineEndPolicy = $policy;
			if ((_policy: Int) < 0)
				$sourceSep;
			else if (
				_policy != anyparse.format.MetadataLineEndPolicy.None
				&& (!$fieldAccess.match($chainPat) || _policy == anyparse.format.MetadataLineEndPolicy.After)
			)
				_dhl();
			else
				_dt(' ');
		};
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

}
#end
