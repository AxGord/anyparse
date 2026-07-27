package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * Pass 4Q of the macro pipeline - query-walker codegen.
 *
 * Turns the `QueryWalkerResult` produced by `QueryWalkerLowering` into the
 * `Array<Field>` installed on the marker class via `@:build`. Sister to
 * `TransformCodegen`; unlike it, nothing extra is synthesised - the walker
 * needs no companion typedef, only the functions and the public entry.
 */
class QueryWalkerCodegen {

	private static final NODE_ARRAY_CT: ComplexType = TPath({
		pack: [],
		name: 'Array',
		params: [TPType(TPath({ pack: ['anyparse', 'query'], name: 'QueryNode', params: [] }))]
	});
	private static final BOOL_CT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });

	private static final STRING_CT: ComplexType = TPath({ pack: [], name: 'String', params: [] });
	private static final VOID_CT: ComplexType = TPath({ pack: [], name: 'Void', params: [] });
	private static final NULL_STRING_CT: ComplexType = TPath({
		pack: [],
		name: 'Null',
		params: [TPType(TPath({ pack: [], name: 'String', params: [] }))]
	});
	private static final NULL_SPAN_CT: ComplexType = TPath({
		pack: [],
		name: 'Null',
		params: [TPType(TPath({ pack: ['anyparse', 'runtime'], name: 'Span', params: [] }))]
	});

	public static function emit(result: QueryWalkerLowering.QueryWalkerResult, parserPath: String): Array<Field> {
		final fields: Array<Field> = [rootMemoSource(), rootMemoValue(result), rootField(result, parserPath)];
		for (fn in result.walks) fields.push(walkField(fn));
		for (fn in result.names) fields.push(nameField(fn));
		for (fn in result.typeRefs) fields.push(typeRefsField(fn));
		fields.push(publicWalkField(result));
		return fields;
	}

	/** The memoised source of `_memoRoot` - `null` before the first parse. */
	private static function rootMemoSource(): Field {
		return {
			name: '_memoSource',
			access: [APrivate, AStatic],
			doc: 'Source string `_memoRoot` was parsed from, or null before the first parse.',
			kind: FVar(TPath({ pack: [], name: 'Null', params: [TPType(STRING_CT)] }), macro null),
			pos: Context.currentPos(),
		};
	}

	/** The memoised parse root - `null` both before the first parse and when that source failed to parse. */
	private static function rootMemoValue(result: QueryWalkerLowering.QueryWalkerResult): Field {
		return {
			name: '_memoRoot',
			access: [APrivate, AStatic],
			doc: 'Parse root of `_memoSource`, or null when that source did not parse. A failed parse is memoised too, so a skip-parse file is not retried by every projection.',
			kind: FVar(TPath({ pack: [], name: 'Null', params: [TPType(result.rootCT)] }), macro null),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Parse `source`, reusing the LAST result when the same string comes back.
	 *
	 * The three projections (`walk`, `spanInfo`, `typeParamNames`) are called
	 * back to back on one file - the index builder parses a file and then asks
	 * for its type maps - and each used to parse it again from scratch. Parsing
	 * dominates the cost of building an index, so one entry keyed on the source
	 * removes most of it. One entry is enough BECAUSE the calls are adjacent;
	 * holding more would pin whole ASTs for no gain.
	 */
	private static function rootField(result: QueryWalkerLowering.QueryWalkerResult, parserPath: String): Field {
		final parseCall: Expr = {
			expr: ECall(field(haxe.macro.MacroStringTools.toFieldExpr(parserPath.split('.')), 'parse'), [macro source]),
			pos: Context.currentPos(),
		};
		final body: Expr = macro {
			if (_memoSource == source) return _memoRoot;
			_memoSource = source;
			_memoRoot = try $parseCall catch (exception: haxe.Exception) null;
			return _memoRoot;
		};
		return {
			name: '_root',
			access: [APrivate, AStatic],
			doc: 'The parse root of `source`, memoised on the last source seen; null when it does not parse.',
			kind: FFun({
				args: [{ name: 'source', type: STRING_CT }],
				ret: TPath({ pack: [], name: 'Null', params: [TPType(result.rootCT)] }),
				expr: body
			}),
			pos: Context.currentPos(),
		};
	}

	private static function field(target: Expr, name: String): Expr {
		return { expr: EField(target, name), pos: Context.currentPos() };
	}

	/** One `private static function _walk<T>(v, into, withTypeRefs): Void`. */
	private static function walkField(fn: QueryWalkerLowering.WalkerFn): Field {
		return {
			name: fn.fnName,
			access: [APrivate, AStatic],
			doc: 'Append the `QueryNode`s of a `${fn.typePath}` value to `into`.',
			kind: FFun({
				args: [
					{ name: 'v', type: fn.paramCT },
					{ name: 'into', type: NODE_ARRAY_CT },
					{ name: 'withTypeRefs', type: BOOL_CT },
				],
				ret: VOID_CT,
				expr: fn.body
			}),
			pos: Context.currentPos(),
		};
	}

	/** One `private static function _nameOf<T>(v): Null<String>`. */
	private static function nameField(fn: QueryWalkerLowering.WalkerFn): Field {
		return {
			name: fn.fnName,
			access: [APrivate, AStatic],
			doc: 'Display name of a `${fn.typePath}` value, or null when it carries none.',
			kind: FFun({ args: [{ name: 'v', type: fn.paramCT }], ret: NULL_STRING_CT, expr: fn.body }),
			pos: Context.currentPos(),
		};
	}

	/** One `private static function _typeRefs<T>(v, into, fallbackSpan): Void`. */
	private static function typeRefsField(fn: QueryWalkerLowering.WalkerFn): Field {
		return {
			name: fn.fnName,
			access: [APrivate, AStatic],
			doc: 'Append the `TypeRef` nodes inside a `${fn.typePath}` value to `into`.',
			kind: FFun({
				args: [
					{ name: 'v', type: fn.paramCT },
					{ name: 'into', type: NODE_ARRAY_CT },
					{ name: 'fallbackSpan', type: NULL_SPAN_CT },
				],
				ret: VOID_CT,
				expr: fn.body
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * The public `walk(root, withTypeRefs): Array<QueryNode>` entry - the root
	 * rule's own `_walk` over a fresh accumulator, ordered by source position.
	 */
	private static function publicWalkField(result: QueryWalkerLowering.QueryWalkerResult): Field {
		final rootCall: Expr = {
			expr: ECall({ expr: EConst(CIdent(result.rootFnName)), pos: Context.currentPos() }, [macro _r, macro into, macro withTypeRefs]),
			pos: Context.currentPos(),
		};
		final body: Expr = macro {
			final _r = _root(source);
			if (_r == null) throw new haxe.Exception('parse failed');
			final into: Array<anyparse.query.QueryNode> = [];
			$rootCall;
			return anyparse.query.QueryWalkSupport.orderBySpan(into);
		};
		return {
			name: 'walk',
			access: [APublic, AStatic],
			doc: 'Translate a parsed `${result.rootTypePath}` into the engine\'s `QueryNode` children. '
				+ '`withTypeRefs` surfaces skipped name-slot types as `TypeRef` nodes (the `apq uses` projection).',
			kind: FFun({
				args: [
					{ name: 'source', type: STRING_CT },
					{ name: 'withTypeRefs', type: BOOL_CT },
				],
				ret: NODE_ARRAY_CT,
				expr: body
			}),
			pos: Context.currentPos(),
		};
	}

}
#end
