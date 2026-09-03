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

	// The two argument shapes several generated entries share. Named rather than repeated
	// because the macro BODIES reference these parameters by name (`source`, `withTypeRefs`),
	// so the entries have to agree on the spelling, not merely happen to.
	private static final SOURCE_ARG: FunctionArg = { name: 'source', type: STRING_CT };
	private static final WITH_TYPE_REFS_ARG: FunctionArg = { name: 'withTypeRefs', type: BOOL_CT };

	public static function emit(result: QueryWalkerLowering.QueryWalkerResult, parserPath: String): Array<Field> {
		final fields: Array<Field> = [
			rootMemoSource(),
			rootMemoValue(result),
			rootMemoError(),
			rootField(result, parserPath),
			publicParseRootStrictField(result, parserPath)
		];
		for (fn in result.walks) fields.push(walkField(fn));
		for (fn in result.names) fields.push(nameField(fn));
		for (fn in result.typeRefs) fields.push(typeRefsField(fn));
		fields.push(publicParseRootField(result));
		fields.push(publicWalkRootField(result));
		fields.push(publicWalkField(result));
		return fields;
	}

	/**
	 * `Null<T>` over the paired grammar root. Shared with `SpanInfoCodegen`, which emits
	 * onto the SAME marker class from the same shape, so its root-taking entries must
	 * spell the parameter exactly as the walker's do.
	 */
	public static function nullRootCT(rootCT: ComplexType): ComplexType {
		return TPath({ pack: [], name: 'Null', params: [TPType(rootCT)] });
	}

	/** The memoised source of `_memoRoot` - `null` before the first parse. */
	private static function rootMemoSource(): Field {
		return {
			name: '_memoSource',
			access: [APrivate, AStatic],
			doc: 'Source string `_memoRoot` was parsed from, or null before the first parse.',
			kind: FVar(TPath({ pack: [], name: 'Null', params: [TPType(STRING_CT)] }), macro null),
			pos: Context.currentPos()
		};
	}

	/**
	 * The parse ERROR of `_memoSource`, or null when it parsed. Read only through
	 * `parseRootStrict`, and only under `_memoSource == source`, so a memo that has moved on
	 * cannot answer for a text it never saw.
	 *
	 * A null root is all `walkRoot` ever learns about a failure — it never sees the source — so
	 * every op that re-parses its own rewrite reported a bare `parse failed` with no file
	 * position. This is a second field of the SAME single-entry memo, not a new cache: it lives
	 * and dies with `_memoSource`.
	 */
	private static function rootMemoError(): Field {
		return {
			name: '_memoError',
			access: [APrivate, AStatic],
			doc: 'Parse error of `_memoSource`, or null when it parsed. Valid only while `_memoSource` is the source being asked about.',
			kind: FVar(
				TPath({ pack: [], name: 'Null', params: [TPType(TPath({ pack: ['haxe'], name: 'Exception', params: [] }))] }), macro null
			),
			pos: Context.currentPos()
		};
	}

	/** The memoised parse root - `null` both before the first parse and when that source failed to parse. */
	private static function rootMemoValue(result: QueryWalkerLowering.QueryWalkerResult): Field {
		return {
			name: '_memoRoot',
			access: [APrivate, AStatic],
			doc: 'Parse root of `_memoSource`, or null when that source did not parse. A failed parse is memoised too, so a skip-parse '
				+ 'file is not retried by every projection.',
			kind: FVar(nullRootCT(result.rootCT), macro null),
			pos: Context.currentPos()
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
			pos: Context.currentPos()
		};
		final body: Expr = macro {
			if (_memoSource == source) return _memoRoot;
			_memoSource = source;
			_memoError = null;
			_memoRoot = try $parseCall catch (exception: haxe.Exception) {
				_memoError = exception;
				null;
			};
			return _memoRoot;
		};
		return {
			name: '_root',
			access: [APrivate, AStatic],
			doc: 'The parse root of `source`, memoised on the last source seen; null when it does not parse.',
			kind: FFun({
				args: [SOURCE_ARG],
				ret: nullRootCT(result.rootCT),
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

	private static function field(target: Expr, name: String): Expr {
		return { expr: EField(target, name), pos: Context.currentPos() };
	}

	/** One `private static function _walk<T>(v, into, typeOut, withTypeRefs): Void`. */
	private static function walkField(fn: QueryWalkerLowering.WalkerFn): Field {
		return {
			name: fn.fnName,
			access: [APrivate, AStatic],
			doc: 'Append the `QueryNode`s of a `${fn.typePath}` value to `into`; a `@:queryTypeSlot` field of it fills `typeOut`, which '
				+ 'the enclosing node reads into `QueryNode.type`.',
			kind: FFun({
				args: [
					{ name: 'v', type: fn.paramCT },
					{ name: 'into', type: NODE_ARRAY_CT },
					{ name: 'typeOut', type: NODE_ARRAY_CT },
					WITH_TYPE_REFS_ARG
				],
				ret: VOID_CT,
				expr: fn.body
			}),
			pos: Context.currentPos()
		};
	}

	/** One `private static function _nameOf<T>(v): Null<String>`. */
	private static function nameField(fn: QueryWalkerLowering.WalkerFn): Field {
		return {
			name: fn.fnName,
			access: [APrivate, AStatic],
			doc: 'Display name of a `${fn.typePath}` value, or null when it carries none.',
			kind: FFun({ args: [{ name: 'v', type: fn.paramCT }], ret: NULL_STRING_CT, expr: fn.body }),
			pos: Context.currentPos()
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
					{ name: 'fallbackSpan', type: NULL_SPAN_CT }
				],
				ret: VOID_CT,
				expr: fn.body
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * The public `parseRoot(source)` entry - the memoised parse root itself, handed
	 * out so a caller needing several projections of one source pays ONE parse.
	 */
	private static function publicParseRootField(result: QueryWalkerLowering.QueryWalkerResult): Field {
		final body: Expr = macro return _root(source);
		return {
			name: 'parseRoot',
			access: [APublic, AStatic],
			doc: 'Parse `source` into the grammar root, memoised on the last source seen; null when it does not parse. '
				+ 'The handle a caller projects more than once instead of re-parsing per projection.',
			kind: FFun({
				args: [SOURCE_ARG],
				ret: nullRootCT(result.rootCT),
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * The public `parseRootStrict(source)` entry - the parse that RAISES instead of answering
	 * null, so a caller holding a null root can say WHERE the source failed.
	 *
	 * `parseRoot` swallows the parser's own `ParseError` and hands back null, which is the right
	 * answer for the callers that merely skip a file they cannot parse. It is the wrong answer
	 * for the ones that report to a user: every op re-parses its own rewrite, and all any of them
	 * could print was `parse failed` — no file offset, no line, no expected token — because the
	 * only value that survived the null was the absence of a tree.
	 *
	 * Costs nothing on the path that matters: the caller has just asked `parseRoot(source)`, so
	 * the memo still holds that source and its error is re-raised without touching the parser. A
	 * memo that has moved on is re-parsed once, on a path that throws either way.
	 */
	private static function publicParseRootStrictField(result: QueryWalkerLowering.QueryWalkerResult, parserPath: String): Field {
		final parseCall: Expr = {
			expr: ECall(field(haxe.macro.MacroStringTools.toFieldExpr(parserPath.split('.')), 'parse'), [macro source]),
			pos: Context.currentPos()
		};
		final body: Expr = macro {
			final memo = _memoError;
			if (_memoSource == source && memo != null) throw memo;
			return $parseCall;
		};
		return {
			name: 'parseRootStrict',
			access: [APublic, AStatic],
			doc: 'Parse `source` into the grammar root, RAISING the parser\'s own error when it does not parse — the diagnostic twin '
				+ 'of `parseRoot`, for a caller that must name the line and column rather than report a bare failure.',
			kind: FFun({
				args: [SOURCE_ARG],
				ret: result.rootCT,
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * The public `walkRoot(root, withTypeRefs): Array<QueryNode>` entry - the root
	 * rule's own `_walk` over a fresh accumulator, ordered by source position, from a
	 * root the caller already holds.
	 */
	private static function publicWalkRootField(result: QueryWalkerLowering.QueryWalkerResult): Field {
		final rootCall: Expr = {
			expr: ECall(
				{ expr: EConst(CIdent(result.rootFnName)), pos: Context.currentPos() },
				[macro _r, macro into, macro _rootTypeOut, macro withTypeRefs]
			),
			pos: Context.currentPos()
		};
		final body: Expr = macro {
			final _r = root;
			if (_r == null) throw new haxe.Exception('parse failed');
			final into: Array<anyparse.query.QueryNode> = [];
			// The root rule forms no node of its own, so nothing ever reads this back.
			final _rootTypeOut: Array<anyparse.query.QueryNode> = [];
			$rootCall;
			return anyparse.query.QueryWalkSupport.orderBySpan(into);
		};
		return {
			name: 'walkRoot',
			access: [APublic, AStatic],
			doc: 'Translate an already-parsed `${result.rootTypePath}` into the engine\'s `QueryNode` children. '
				+ '`withTypeRefs` surfaces skipped name-slot types as `TypeRef` nodes (the `apq uses` projection).',
			kind: FFun({
				args: [
					{ name: 'root', type: nullRootCT(result.rootCT) },
					WITH_TYPE_REFS_ARG
				],
				ret: NODE_ARRAY_CT,
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * The source-taking twin of `walkRoot`: parse through the memo, then project. What
	 * a caller with one projection to make uses; the pair exists for the caller with four.
	 */
	private static function publicWalkField(result: QueryWalkerLowering.QueryWalkerResult): Field {
		final body: Expr = macro return walkRoot(_root(source), withTypeRefs);
		return {
			name: 'walk',
			access: [APublic, AStatic],
			doc: 'Translate a parsed `${result.rootTypePath}` into `QueryNode` children - `walkRoot` over `parseRoot(source)`. '
				+ '`withTypeRefs` surfaces skipped name-slot types as `TypeRef` nodes (the `apq uses` projection).',
			kind: FFun({
				args: [
					SOURCE_ARG,
					WITH_TYPE_REFS_ARG
				],
				ret: NODE_ARRAY_CT,
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

}
#end
