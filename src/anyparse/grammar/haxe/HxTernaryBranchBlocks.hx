package anyparse.grammar.haxe;

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

	private static inline function nonEmpty(v: Null<Any>): Bool {
		return Std.isOfType(v, Array) && (cast v: Array<Any>).length > 0;
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
