package anyparse.grammar.haxe.glue;

using Lambda;

/**
 * Whether a ternary branch holds a multi-line block — the operands `wrapping.ternaryMultilineBranch`
 * acts on (`cond ? macro {…} : …`, `cond ? f(function() {…}) : …`).
 *
 * Reached from the writer lowering as the `ternaryBranchHoldsMultilineBlock` predicate on the
 * per-family `AstPreds` marker classes (`HxAstPredLowering.ternaryBranchHoldsMultilineBlockField`),
 * for the same reason as `HxComplexItems`: the lowering is grammar-agnostic and holds the operand
 * untyped, as a bare node or a trivia-synth `{node: …}` wrapper.
 *
 * A block is a brace pair that is not a collection: a statement block, a function body, a
 * `switch` body, a `macro class` body. It counts when it has content, because a non-empty one
 * never renders on one line. Object and array literals are not blocks, but a block inside one
 * counts. A branch that itself OPENS with a brace or bracket group (`cond ? a : {…}`,
 * `cond ? [] : […]`) keeps that group on the line of its `?` / `:`, so the group is skipped and
 * only what follows it is searched — the exception set of haxe-formatter's
 * `MarkWrapping.hasMultilineBlockBranch`, so both tools act on the same ternaries.
 *
 * `endsInTailBlock` answers the narrower question `sameLine.ternaryTailBlockMaxThenLength` asks of
 * an else branch: does it break only inside the block or collection it ends in.
 */
final class HxTernaryBranchBlocks {

	/**
	 * Depth ceiling of the subtree walk, as in `HxComplexItems`: not a cycle guard (the AST has no
	 * back-pointers) but a cost bound, answering "no block" past it.
	 */
	private static inline final MAX_DEPTH: Int = 64;

	/** Constructors whose own brace group is the branch's leading group when the branch opens with it. */
	private static final HEAD_GROUP_CTORS: Array<String> = ['BlockExpr', 'ObjectLit', 'ArrayExpr'];

	/**
	 * True iff `branch` holds a non-empty block outside the brace or bracket group it opens with.
	 * `leftOperandCtors` names the constructors that print their first operand first (infix,
	 * postfix, ternary): the descent through them reaches the token the branch opens with.
	 */
	public static function holdsMultilineBlock(branch: Null<Any>, leftOperandCtors: Array<String>): Bool {
		var node: Null<Any> = unwrap(branch);
		while (node != null && Reflect.isEnumValue(node)) {
			final ctor: String = Type.enumConstructor(node);
			if (HEAD_GROUP_CTORS.contains(ctor)) return false;
			if (!leftOperandCtors.contains(ctor)) return holdsBlock(node, 0);
			final params: Array<Any> = Type.enumParameters(node);
			for (i in 1...params.length) if (holdsBlock(params[i], 0)) return true;
			node = params.length == 0 ? null : unwrap(params[0]);
		}
		return false;
	}

	/**
	 * True iff `branch` ENDS in a non-empty block or collection that is its only multi-line part: the
	 * branch is that group, a lambda whose body ends in one, or a call or `new` whose LAST argument
	 * does, while the callee and every earlier argument hold no block. A collection before the tail may
	 * still break; the writer refuses that hug on the rendered shape (`BinaryChainEmit.hugsTailBlock`).
	 */
	public static function endsInTailBlock(branch: Null<Any>): Bool {
		var node: Null<Any> = unwrap(branch);
		for (_ in 0...MAX_DEPTH) {
			if (node == null || !Reflect.isEnumValue(node)) return false;
			final params: Array<Any> = Type.enumParameters(node);
			switch Type.enumConstructor(node) {
				case 'BlockExpr', 'ArrayExpr':
					return nonEmpty(params[0]);
				case 'ObjectLit':
					return nonEmpty(Reflect.field(params[0], 'fields'));
				case 'BlockBody':
					return nonEmpty(Reflect.field(params[0], 'stmts'));
				case 'ThinArrow':
					node = unwrap(params[1]);
				case 'ExprBody':
					node = unwrap(params[0]);
				case 'ThinParenLambdaExpr', 'ParenLambdaExpr', 'FnExpr':
					node = unwrap(Reflect.field(params[0], 'body'));
				case 'Call':
					node = holdsBlock(params[0], 0) ? null : lastPlainArg(params[1]);
				case 'NewExpr':
					node = lastPlainArg(Reflect.field(params[0], 'args'));
				case _:
					return false;
			}
		}
		return false;
	}

	private static inline function nonEmpty(v: Null<Any>): Bool {
		return Std.isOfType(v, Array) && (cast v: Array<Any>).length > 0;
	}

	/** The last of `args`, or null when there is none or an argument before it holds a block. */
	private static function lastPlainArg(args: Null<Any>): Null<Any> {
		if (!nonEmpty(args)) return null;
		final list: Array<Any> = cast args;
		for (i in 0...list.length - 1) if (holdsBlock(list[i], 0)) return null;
		return unwrap(list[list.length - 1]);
	}

	/** True iff `v`'s subtree holds a non-empty block, `v` included. */
	private static function holdsBlock(v: Null<Any>, depth: Int): Bool {
		if (v == null || depth > MAX_DEPTH) return false;
		if (Reflect.isEnumValue(v)) {
			final params: Array<Any> = Type.enumParameters(v);
			return switch Type.enumConstructor(v) {
				case 'BlockExpr', 'BlockStmt': nonEmpty(params[0]);
				case 'BlockBody': nonEmpty(Reflect.field(params[0], 'stmts'));
				case 'SwitchExpr', 'SwitchExprBare', 'SwitchStmt', 'SwitchStmtBare': nonEmpty(Reflect.field(params[0], 'cases'));
				case 'MacroClassExpr': nonEmpty(Reflect.field(params[0], 'members'));
				case _: params.exists(param -> holdsBlock(param, depth + 1));
			};
		}
		if (Std.isOfType(v, Array)) {
			final arr: Array<Any> = cast v;
			return arr.exists(item -> holdsBlock(item, depth + 1));
		}
		// `Reflect.isObject` answers true for String on several targets; a string has no blocks.
		return !Std.isOfType(v, String)
			&& Reflect.isObject(v)
			&& Reflect.fields(v).exists(name -> holdsBlock(Reflect.field(v, name), depth + 1));
	}

	/** A trivia-synth `{node: …}` wrapper's node, or `v` itself. */
	private static function unwrap(v: Null<Any>): Null<Any> {
		return v != null && !Reflect.isEnumValue(v) && !Std.isOfType(v, String) && Reflect.isObject(v) && Reflect.hasField(v, 'node')
			? Reflect.field(v, 'node')
			: v;
	}

}
