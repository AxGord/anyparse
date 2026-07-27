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

	public static function emit(result: QueryWalkerLowering.QueryWalkerResult): Array<Field> {
		final fields: Array<Field> = [for (fn in result.walks) walkField(fn)];
		for (fn in result.names) fields.push(nameField(fn));
		for (fn in result.typeRefs) fields.push(typeRefsField(fn));
		fields.push(publicWalkField(result));
		return fields;
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
			expr: ECall(
				{ expr: EConst(CIdent(result.rootFnName)), pos: Context.currentPos() }, [macro root, macro into, macro withTypeRefs]
			),
			pos: Context.currentPos(),
		};
		final body: Expr = macro {
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
					{ name: 'root', type: result.rootCT },
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
