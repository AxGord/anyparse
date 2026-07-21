package anyparse.grammar.haxe;

/**
 * One further function parameter carried INSIDE a type-position
 * conditional region whose `#if` opened in an earlier parameter's TYPE
 * slot. Element of `HxConditionalType.moreParams`.
 *
 * Motivating shape, openfl `text/_internal/ShapeCache.hx:37`:
 *
 * ```haxe
 * public function cache(formatRange:TextFormatRange,
 *     getPositions:#if (js && html5) Void->Array<Float>,
 *   wordKey:String = null #else TextLayout #end):Array<Float>
 * ```
 *
 * The region opens in `getPositions`'s type slot and closes two
 * parameters later, so the `#if` cannot be an element of the parameter
 * Star (`HxParam.Conditional` already covers THAT shape) - it is an
 * element of the TYPE, and the parameters that follow have to be
 * carried by the type-position region itself.
 *
 * `@:lead(',')` on the element, rather than `@:sep(',')` on the parent
 * Star: the run starts with a separator (the comma that ends
 * `getPositions`'s own entry) rather than between two elements, which
 * is exactly the `HxVarMore` shape (`var a = 1, b = 2`) and exactly
 * what a parent-level `@:sep` cannot express. `@:fmt(spaceAfterLead)`
 * matches `HxVarMore`'s emit.
 *
 * `param` is the full `HxParam` enum, so a defaulted / optional / rest
 * parameter after the region opens parses with no extra machinery, and
 * a nested `#if` inside those parameters re-enters
 * `HxParam.Conditional`.
 */
@:peg
typedef HxCondTypeParamMore = {
	@:lead(',') @:fmt(spaceAfterLead) var param: HxParam;
};
