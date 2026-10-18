package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;

/**
 * Which stdlib calls are provably pure, and how far — the ONE table every purity predicate reads. `PurityScan` asks
 * `isTransparentCallee` before it lets a check hoist, merge or drop a call; `TypeResolver.isDeletionPure` (through
 * `TypeResolver.isPureStdlibCall`) asks `isEffectFreeCallee` before a fix deletes one. Two levels, because the two
 * questions differ: a discarded `Date.now()` changes nothing, while two of them are not one.
 *
 * A POSITIVE whitelist on both axes. The functions are enumerated, never "every member but `random`" — a future impure
 * addition is never auto-trusted. And the callee is resolved, never read off its spelling: the receiver's root must bind
 * to no value (a same-named local makes it an instance call) and no project type may declare the simple name (its
 * `Std.int` may do anything), and a `String` method needs a binding DECLARED `String`.
 *
 * PURITY is NOT derivable from a declaration — a signature never states side-effect freedom — so, unlike the
 * extension-method and static-return tables derived from the std sources via `StdResolver`, these lists are intrinsic
 * semantic knowledge and stay hand-maintained. Each entry was read against the Haxe 4.3.7 std source.
 */
@:nullSafety(Strict)
final class StdlibPurity {

	/** The one effect-free `String` method that is not transparent: it answers a FRESH, mutable array. */
	private static inline final SPLIT_METHOD: String = 'split';

	/**
	 * Simple `Type.method` names of stdlib STATIC functions that are REFERENTIALLY TRANSPARENT: no side effect, the same
	 * answer for the same arguments, and a result with no identity of its own (a number, a `Bool`, a `String`, or the
	 * argument itself). `Math.random` / `Std.random` are deliberately ABSENT — they advance PRNG state (a side effect);
	 * every I/O-bearing type (`Sys`, `File`, ...) is out entirely; and a call that is only effect-free is in
	 * `EFFECT_FREE_STATICS` instead.
	 */
	private static final TRANSPARENT_STATICS: Array<String> = [
		'Std.string',
		'Std.int',
		'Std.is',
		'Std.instance',
		'Std.parseInt',
		'Std.parseFloat',
		'Std.isOfType',
		'Std.downcast',
		'Math.abs',
		'Math.min',
		'Math.max',
		'Math.floor',
		'Math.ceil',
		'Math.round',
		'Math.fround',
		'Math.ffloor',
		'Math.fceil',
		'Math.sqrt',
		'Math.pow',
		'Math.sin',
		'Math.cos',
		'Math.tan',
		'Math.asin',
		'Math.acos',
		'Math.atan',
		'Math.atan2',
		'Math.exp',
		'Math.log',
		'Math.isNaN',
		'Math.isFinite',
		'StringTools.trim',
		'StringTools.ltrim',
		'StringTools.rtrim',
		'StringTools.lpad',
		'StringTools.rpad',
		'StringTools.replace',
		'StringTools.startsWith',
		'StringTools.endsWith',
		'StringTools.contains',
		'StringTools.isSpace',
		'StringTools.hex',
		'StringTools.urlEncode',
		'StringTools.urlDecode',
		'StringTools.htmlEscape',
		'StringTools.htmlUnescape',
		'StringTools.fastCodeAt',
		'StringTools.unsafeCodeAt',
		'StringTools.isEof',
		'StringTools.quoteUnixArg',
		'StringTools.quoteWinArg',
		'Path.join',
		'Path.directory',
		'Path.extension',
		'Path.withoutExtension',
		'Path.withoutDirectory',
		'Path.normalize',
		'Path.addTrailingSlash',
		'Path.removeTrailingSlash',
		'Path.isAbsolute'
	];

	/**
	 * Stdlib STATIC functions that are side-effect-free but NOT referentially transparent, so a discarded call may be
	 * deleted while two calls may not be computed once. `Date.now` answers the clock; `Date.fromTime` /
	 * `Date.fromString` and the two `StringTools` iterators answer a FRESH object each call, and an iterator is
	 * stateful besides — one shared by two loops would be drained by the first.
	 */
	private static final EFFECT_FREE_STATICS: Array<String> = [
		'Date.now',
		'Date.fromTime',
		'Date.fromString',
		'StringTools.iterator',
		'StringTools.keyValueIterator'
	];

	/**
	 * Every transparent instance method of the std `String`: an immutable value, so each only reads its receiver and
	 * answers a number or a new immutable `String`.
	 */
	private static final TRANSPARENT_STRING_METHODS: Array<String> = [
		'charAt',
		'charCodeAt',
		'indexOf',
		'lastIndexOf',
		'substr',
		'substring',
		'toLowerCase',
		'toUpperCase',
		'toString'
	];

	/**
	 * Whether `callNode`'s CALLEE is a referentially transparent stdlib function: two calls with the same arguments may
	 * be computed once, and a discarded one dropped. It answers for the callee ONLY — the arguments are the caller's
	 * business, so a caller that walks a subtree must recurse into them itself (`Std.int(Math.random())` has a
	 * transparent callee and an impure argument).
	 */
	public static function isTransparentCallee(
		callNode: QueryNode, tree: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, index: SymbolIndex
	): Bool {
		return calleePurity(callNode, tree, shape, declaredTypes, index) == StdCallPurity.Transparent;
	}

	/** Whether `callNode`'s CALLEE is a side-effect-free stdlib function (a discarded call may go); callee only. */
	public static function isEffectFreeCallee(
		callNode: QueryNode, tree: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, index: SymbolIndex
	): Bool {
		return calleePurity(callNode, tree, shape, declaredTypes, index) != null;
	}

	/**
	 * How far `callNode`'s CALLEE is proven pure, or null when it is not a proven stdlib function at all. A STATIC callee
	 * requires: a field access `Type.method` whose flattened `Type.method` names a `TRANSPARENT_STATICS` entry
	 * (`Transparent`) or an `EFFECT_FREE_STATICS` one (`EffectFree`); a receiver that is a genuine type / package
	 * reference (`TypeResolver.receiverRootIsUnboundType`); and no project type declaring the simple type name
	 * (`index.refs.declaringFiles` empty). A `String` METHOD qualifies on an identifier DECLARED `String`
	 * (`declaredTypes` at its binding — a `Null<String>` reads `Null` and is refused) when no project type shadows
	 * `String`; an instance field wins over a `using` extension of the same name, so the method IS the std one, and a
	 * null receiver's throw is the exposure `TypeResolver.isPlainFieldRead` already accepts.
	 */
	private static function calleePurity(
		callNode: QueryNode, tree: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, index: SymbolIndex
	): Null<StdCallPurity> {
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind == null || callNode.children.length == 0) return null;
		final callee: QueryNode = callNode.children[0];
		if (callee.kind != fieldAccessKind || callee.children.length != 1) return null;
		final method: String = callee.name ?? '';
		final receiver: QueryNode = callee.children[0];
		final typeName: Null<String> = receiver.name;
		if (
			typeName != null && TypeResolver.receiverRootIsUnboundType(receiver, tree, shape)
			&& index.refs.declaringFiles(typeName).length == 0
		) {
			final qualified: String = '$typeName.$method';
			if (TRANSPARENT_STATICS.contains(qualified)) return StdCallPurity.Transparent;
			if (EFFECT_FREE_STATICS.contains(qualified)) return StdCallPurity.EffectFree;
		}
		if (!TRANSPARENT_STRING_METHODS.contains(method) && method != SPLIT_METHOD) return null;
		final from: Null<Int> = TypeResolver.identBindingFrom(receiver, tree, shape);
		return if (from == null || declaredTypes[from] != 'String' || NominalTypes.shadowedByNonStdType(index, 'String'))
			null
		else if (method == SPLIT_METHOD)
			StdCallPurity.EffectFree
		else
			StdCallPurity.Transparent;
	}

}

/** How far a stdlib callee is proven pure (`StdlibPurity.calleePurity`). */
private enum abstract StdCallPurity(Int) {

	/** No side effect, the same answer for the same arguments, no identity of its own: computable once. */
	final Transparent = 0;

	/** No side effect, so a discarded call may go, but two calls are not one (a clock, a fresh object). */
	final EffectFree = 1;

}
