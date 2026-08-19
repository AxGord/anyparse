package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * Pass 4S of the macro pipeline - span-info codegen.
 *
 * Turns the `SpanInfoResult` produced by `SpanInfoLowering` into fields on the
 * same marker class `QueryWalkerCodegen` writes to; the two share the generated
 * `_nameOf` helpers, so they must land together.
 */
class SpanInfoCodegen {

	private static final BUNDLE_CT: ComplexType = TPath({
		pack: ['anyparse', 'query'],
		name: 'SpanTypeInfoProvider',
		sub: 'SpanTypeInfo',
		params: []
	});
	private static final NULL_SPAN_CT: ComplexType = TPath({
		pack: [],
		name: 'Null',
		params: [TPType(TPath({ pack: ['anyparse', 'runtime'], name: 'Span', params: [] }))]
	});
	private static final NULL_STRING_CT: ComplexType = TPath({
		pack: [],
		name: 'Null',
		params: [TPType(TPath({ pack: [], name: 'String', params: [] }))]
	});
	private static final STRING_CT: ComplexType = TPath({ pack: [], name: 'String', params: [] });
	private static final INT_CT: ComplexType = TPath({ pack: [], name: 'Int', params: [] });
	private static final BOOL_CT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
	private static final VOID_CT: ComplexType = TPath({ pack: [], name: 'Void', params: [] });

	public static function emit(result: SpanInfoLowering.SpanInfoResult): Array<Field> {
		final fields: Array<Field> = [for (fn in result.walks) walkField(fn)];
		for (fn in result.nominals)
			fields.push(unaryField(fn, NULL_STRING_CT, 'Simple nominal type name carried by a `${fn.typePath}` value.'));
		for (fn in result.spanOfs) fields.push(unaryField(fn, NULL_SPAN_CT, 'Own span of a `${fn.typePath}` value.'));
		final idCT: Null<ComplexType> = result.accessorIdCT;
		if (idCT != null) fields.push(accessorField(idCT));
		fields.push(publicSpanInfoRootField(result));
		fields.push(publicSpanInfoField(result));
		fields.push(publicTypeParamsRootField(result));
		fields.push(publicTypeParamsField(result));
		return fields;
	}

	/** One `private static function _spanInfo<T>(v, cur, b, source): Void`. */
	private static function walkField(fn: SpanInfoLowering.SpanInfoFn): Field {
		return {
			name: fn.fnName,
			access: [APrivate, AStatic],
			doc: 'Record the span-indexed type/accessor info a `${fn.typePath}` value and its children carry. '
				+ '`cur` is the nearest enclosing binding span.',
			kind: FFun({
				args: [
					{ name: 'v', type: fn.paramCT },
					{ name: 'cur', type: NULL_SPAN_CT },
					{ name: 'b', type: BUNDLE_CT },
					{ name: 'source', type: STRING_CT },
					{ name: 'tp', type: TPath({ pack: [], name: 'Array', params: [TPType(STRING_CT)] }) }
				],
				ret: VOID_CT,
				expr: fn.body
			}),
			pos: Context.currentPos()
		};
	}

	/** One single-argument helper (`_nominalName<T>` / `_spanOf<T>`). */
	private static function unaryField(fn: SpanInfoLowering.SpanInfoFn, ret: ComplexType, doc: String): Field {
		return {
			name: fn.fnName,
			access: [APrivate, AStatic],
			doc: doc,
			kind: FFun({ args: [{ name: 'v', type: fn.paramCT }], ret: ret, expr: fn.body }),
			pos: Context.currentPos()
		};
	}

	/**
	 * The accessor test: whether the accessor at `slot` runs code. Only the three
	 * stored-slot ids are side-effect-free; a missing slot defaults to true, so a
	 * member is never wrongly classed as a plain stored field.
	 */
	private static function accessorField(idCT: ComplexType): Field {
		final stored: Expr = SpanInfoLowering.storedAccessorsExpr();
		final body: Expr = macro {
			if (ids.length <= slot) return true;
			final s: String = cast ids[slot];
			return !$stored.contains(s);
		};
		return {
			name: '_accessorRunsCode',
			access: [APrivate, AStatic],
			doc: 'Whether the property accessor at `slot` (0 = read, 1 = write) runs code rather than reading a stored slot.',
			kind: FFun({
				args: [
					{ name: 'ids', type: TPath({ pack: [], name: 'Array', params: [TPType(idCT)] }) },
					{ name: 'slot', type: INT_CT }
				],
				ret: BOOL_CT,
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * The public `spanInfoRoot(root, source): SpanTypeInfo` entry - a fresh bundle
	 * filled by the root rule's own walk over a root the caller already parsed. A null
	 * root (a source that does not parse) yields the empty bundle, as the source-taking
	 * twin always did.
	 */
	private static function publicSpanInfoRootField(result: SpanInfoLowering.SpanInfoResult): Field {
		final rootCall: Expr = {
			expr: ECall(
				{ expr: EConst(CIdent(result.rootFnName)), pos: Context.currentPos() },
				[macro _r, macro null, macro b, macro source, macro tp]
			),
			pos: Context.currentPos()
		};
		final body: Expr = macro {
			final tp: Array<String> = [];
			final b: anyparse.query.SpanTypeInfoProvider.SpanTypeInfo = {
				declaredTypes: [],
				returnTypes: [],
				propertyAccessors: [],
				propertyWriteAccessors: [],
				declaredTypeSources: [],
				castTargetSources: []
			};
			final _r = root;
			if (_r != null) $rootCall;
			return b;
		};
		return {
			name: 'spanInfoRoot',
			access: [APublic, AStatic],
			doc: 'The six span-indexed type/accessor maps of an already-parsed `${result.rootTypePath}`, in one walk.',
			kind: FFun({
				args: [
					{ name: 'root', type: QueryWalkerCodegen.nullRootCT(result.rootCT) },
					{ name: 'source', type: STRING_CT }
				],
				ret: BUNDLE_CT,
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

	/** The source-taking twin of `spanInfoRoot`: parse through the memo, then project. */
	private static function publicSpanInfoField(result: SpanInfoLowering.SpanInfoResult): Field {
		final body: Expr = macro return spanInfoRoot(_root(source), source);
		return {
			name: 'spanInfo',
			access: [APublic, AStatic],
			doc: 'The six span-indexed type/accessor maps of a parsed `${result.rootTypePath}`, in one walk.',
			kind: FFun({
				args: [{ name: 'source', type: STRING_CT }],
				ret: BUNDLE_CT,
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * The public `typeParamNamesRoot(root, source)` entry. It runs the SAME walk as
	 * `spanInfoRoot` and keeps only the type-parameter names; the maps it also fills
	 * are discarded. One traversal family rather than two is worth the throwaway
	 * bundle - the reflective version walked the whole tree for this too.
	 */
	private static function publicTypeParamsRootField(result: SpanInfoLowering.SpanInfoResult): Field {
		final rootCall: Expr = {
			expr: ECall(
				{ expr: EConst(CIdent(result.rootFnName)), pos: Context.currentPos() },
				[macro _r, macro null, macro b, macro source, macro tp]
			),
			pos: Context.currentPos()
		};
		final body: Expr = macro {
			final tp: Array<String> = [];
			final b: anyparse.query.SpanTypeInfoProvider.SpanTypeInfo = {
				declaredTypes: [],
				returnTypes: [],
				propertyAccessors: [],
				propertyWriteAccessors: [],
				declaredTypeSources: [],
				castTargetSources: []
			};
			final _r = root;
			if (_r != null) $rootCall;
			return tp;
		};
		return {
			name: 'typeParamNamesRoot',
			access: [APublic, AStatic],
			doc: 'Every type-parameter name declared anywhere in an already-parsed `${result.rootTypePath}`, in first-occurrence order.',
			kind: FFun({
				args: [
					{ name: 'root', type: QueryWalkerCodegen.nullRootCT(result.rootCT) },
					{ name: 'source', type: STRING_CT }
				],
				ret: TPath({ pack: [], name: 'Array', params: [TPType(STRING_CT)] }),
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

	/** The source-taking twin of `typeParamNamesRoot`: parse through the memo, then project. */
	private static function publicTypeParamsField(result: SpanInfoLowering.SpanInfoResult): Field {
		final body: Expr = macro return typeParamNamesRoot(_root(source), source);
		return {
			name: 'typeParamNames',
			access: [APublic, AStatic],
			doc: 'Every type-parameter name declared anywhere in a parsed `${result.rootTypePath}`, in first-occurrence order.',
			kind: FFun({
				args: [{ name: 'source', type: STRING_CT }],
				ret: TPath({ pack: [], name: 'Array', params: [TPType(STRING_CT)] }),
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

}
#end
