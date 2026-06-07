package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

using Lambda;

/**
 * Pass 4T of the macro pipeline — transform codegen.
 *
 * Turns the `TransformResult` produced by `TransformLowering` into the
 * `Array<Field>` installed on the marker class via `@:build`, plus a
 * synthesized `visit` typedef module.
 *
 * Two artifacts are produced:
 *
 *  1. A `<RootSimple>Transform` typedef (an anonymous struct with one
 *     optional `T -> T` hook per grammar type), defined as its own
 *     module via `Context.defineType` so callers can name it. An empty
 *     `{}` literal also unifies against it structurally, so callers can
 *     pass `{}` for an identity transform without naming the typedef.
 *
 *  2. One `private static function _transform<T>(node:T, visit):T`
 *     field per reachable grammar type, plus the public
 *     `transform(root:Root, visit):Root` entry that delegates to the
 *     root type's `_transform`. The deep bottom-up walk and per-type
 *     hook application live in each `_transform`'s body, built by
 *     `TransformLowering`.
 */
class TransformCodegen {

	public static function emit(result:TransformLowering.TransformResult):Array<Field> {
		final visitTypePath:String = visitTypePathOf(result.rootTypePath);
		defineVisitTypedef(visitTypePath, result.hooks);
		final visitCT:ComplexType = pathToComplexType(visitTypePath);

		final fields:Array<Field> = [for (fn in result.fns) transformField(fn, visitCT)];
		fields.push(publicTransformField(result, visitCT));
		return fields;
	}

	/**
	 * Define the per-type-hook `visit` typedef as its own module. The
	 * struct carries one `@:optional` `T -> T` field per grammar type;
	 * setting one rewrites every node of that type across the tree.
	 */
	private static function defineVisitTypedef(visitTypePath:String, hooks:Array<TransformLowering.TransformHook>):Void {
		final idx:Int = visitTypePath.lastIndexOf('.');
		final pack:Array<String> = idx == -1 ? [] : visitTypePath.substring(0, idx).split('.');
		final name:String = idx == -1 ? visitTypePath : visitTypePath.substring(idx + 1);

		final structFields:Array<Field> = [
			for (hook in hooks) {
				name: hook.name,
				kind: FVar(TFunction([hook.ct], hook.ct)),
				access: [],
				meta: [{name: ':optional', params: [], pos: Context.currentPos()}],
				pos: Context.currentPos(),
			}
		];

		Context.defineType({
			pack: pack,
			name: name,
			pos: Context.currentPos(),
			kind: TDStructure,
			fields: structFields,
			doc: 'Per-type rewrite hooks for the generated deep transform. '
				+ 'Each optional field is a `T -> T` rewrite applied to every '
				+ 'node of that type during the bottom-up walk. An empty `{}` '
				+ 'is a structural identity; setting one hook is the rewrite '
				+ 'primitive for that node type.',
			meta: [],
		});
	}

	/**
	 * One `private static function _transform<T>(node:T, visit):T` field.
	 */
	private static function transformField(fn:TransformLowering.TransformFn, visitCT:ComplexType):Field {
		final args:Array<FunctionArg> = [
			{name: 'node', type: fn.paramCT},
			{name: 'visit', type: visitCT},
		];
		return {
			name: fn.fnName,
			access: [APrivate, AStatic],
			doc: 'Deep transform of `${fn.typePath}`: recurse each grammar-typed '
				+ 'child via its own `_transform`, rebuild this node, then apply '
				+ 'the matching `visit` hook if set.',
			kind: FFun({args: args, ret: fn.paramCT, expr: fn.body}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * The public `transform(root:Root, visit):Root` entry — delegates to
	 * the root type's `_transform`.
	 */
	private static function publicTransformField(result:TransformLowering.TransformResult, visitCT:ComplexType):Field {
		final rootCT:ComplexType = result.rootCT;
		final args:Array<FunctionArg> = [
			{name: 'root', type: rootCT},
			{name: 'visit', type: visitCT},
		];
		final callee:Expr = {expr: EConst(CIdent(result.rootFnName)), pos: Context.currentPos()};
		final body:Expr = {
			expr: EReturn({expr: ECall(callee, [macro root, macro visit]), pos: Context.currentPos()}),
			pos: Context.currentPos(),
		};
		return {
			name: 'transform',
			access: [APublic, AStatic],
			doc: 'Deep whole-tree transform: bottom-up walk applying each set '
				+ '`visit` hook to every node of its type. An empty `visit` '
				+ '(`{}`) is a structural identity.',
			kind: FFun({args: args, ret: rootCT, expr: body}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * `visit` typedef path for a grammar root: the root path with its
	 * simple name suffixed `Transform` (e.g.
	 * `anyparse.grammar.haxe.HxModule` to
	 * `anyparse.grammar.haxe.HxModuleTransform`).
	 */
	private static function visitTypePathOf(rootTypePath:String):String {
		return rootTypePath + 'Transform';
	}

	private static function pathToComplexType(typePath:String):ComplexType {
		final idx:Int = typePath.lastIndexOf('.');
		final pack:Array<String> = idx == -1 ? [] : typePath.substring(0, idx).split('.');
		final name:String = idx == -1 ? typePath : typePath.substring(idx + 1);
		return TPath({pack: pack, name: name, params: []});
	}
}
#end
