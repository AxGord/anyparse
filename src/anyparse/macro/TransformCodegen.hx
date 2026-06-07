package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * Pass 4T of the macro pipeline — transform codegen.
 *
 * Turns the `TransformRule` produced by `TransformLowering` into the
 * `Array<Field>` installed on the marker class via `@:build`. This slice
 * emits a single `public static function map(node, f)` field — the
 * shallow `ExprTools.map` analog for the grammar's root family.
 *
 * The signature is `map(node:Family, f:Family -> Family):Family`, where
 * `Family` is the grammar root ComplexType. `f` is applied to every
 * immediate family child during the rebuild; deep traversal is composed
 * by the caller calling `map` inside `f`.
 */
class TransformCodegen {

	public static function emit(rule:TransformLowering.TransformRule):Array<Field> {
		return [mapField(rule)];
	}

	private static function mapField(rule:TransformLowering.TransformRule):Field {
		final familyCT:ComplexType = rule.familyCT;
		final fnCT:ComplexType = TFunction([familyCT], familyCT);
		final args:Array<FunctionArg> = [
			{name: 'node', type: familyCT},
			{name: 'f', type: fnCT},
		];
		return {
			name: rule.fnName,
			access: [APublic, AStatic],
			doc: 'Shallow `ExprTools.map` analog: rebuild `node` applying `f` to '
				+ 'each immediate family child. Does not recurse — compose deep '
				+ 'traversal by calling `map` inside `f`.',
			kind: FFun({
				args: args,
				ret: familyCT,
				expr: rule.body,
			}),
			pos: Context.currentPos(),
		};
	}
}
#end
