package anyparse.util;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.ExprTools;
import haxe.macro.Type;

/** One ordering key: the lambda's parameter name, the expression reading the key from it, and its direction. */
private typedef KeyRow = {
	final param: String;
	final type: Null<ComplexType>;
	final body: Expr;
	final ascending: Bool;
}
/**
 * The one answer to "how do key lambdas become one comparator": the compile-time expansion behind `Compare.asc` and
 * `Compare.desc`, which reads each key lambda's expression and chains the comparisons into a single `(x, y) -> Int` lambda.
 */
final class CompareKeys {

	/** The comparator lambda of `keys`, the first key deciding and each later key breaking its ties. */
	public static function comparator(keys: Array<Expr>, ascending: Bool): Expr {
		final rows: Array<KeyRow> = [];
		collect(keys, ascending, rows);
		if (rows.length == 0) Context.error('Compare.asc / Compare.desc need at least one key lambda', Context.currentPos());
		final type: ComplexType = elementType(rows);
		var chain: Expr = macro 0;
		var at: Int = rows.length;
		while (at-- > 0) chain = step(rows[at], at, type, chain);
		return macro (_cmpL: $type, _cmpR: $type) -> $chain;
	}

	/** Flattens `args` into key rows; a key wrapped in `Compare.asc(…)` / `Compare.desc(…)` takes that call's direction. */
	private static function collect(args: Array<Expr>, ascending: Bool, rows: Array<KeyRow>): Void {
		for (arg in args) switch arg.expr {
			case EParenthesis(inner):
				collect([inner], ascending, rows);
			case ECall(callee, inner) if (isDirection(callee, 'asc')):
				collect(inner, true, rows);
			case ECall(callee, inner) if (isDirection(callee, 'desc')):
				collect(inner, false, rows);
			case _:
				rows.push(keyRow(arg, ascending));
		}
	}

	/** Whether `callee` names this class's macro `method`, short or fully qualified. */
	private static function isDirection(callee: Expr, method: String): Bool {
		return switch callee.expr {
			case EField(owner, field, _) if (field == method): isCompareClass(owner);
			case _: false;
		}
	}

	private static function isCompareClass(e: Expr): Bool {
		return switch e.expr {
			case EConst(CIdent('Compare')), EField({ expr: EField({ expr: EConst(CIdent('anyparse')) }, 'util', _) }, 'Compare', _): true;
			case _: false;
		}
	}

	/** The row of one key lambda; anything but a one-parameter, one-expression lambda is a compile error. */
	private static function keyRow(arg: Expr, ascending: Bool): KeyRow {
		switch arg.expr {
			case EFunction(_, f) if (f.args.length == 1 && f.expr != null):
				final body: Expr = switch f.expr.expr {
					case EMeta({ name: ':implicitReturn' }, { expr: EReturn(value) }), EReturn(value) if (value != null): value;
					case _: f.expr;
				};
				if (returns(body) || body.expr.match(EBlock(_)))
					Context.error('Compare key lambda: a block body is not supported, write one expression (r -> r.a)', arg.pos);
				return {
					param: f.args[0].name,
					type: f.args[0].type,
					body: body,
					ascending: ascending
				};
			case _:
				return Context.error('Compare key must be a lambda with one parameter (r -> r.a)', arg.pos);
		}
	}

	/** Whether `e` holds a `return` of its own, outside any nested function. */
	private static function returns(e: Expr): Bool {
		switch e.expr {
			case EReturn(_):
				return true;
			case EFunction(_, _):
				return false;
			case _:
		}
		var found: Bool = false;
		ExprTools.iter(e, child -> if (returns(child)) found = true);
		return found;
	}

	/** The element type the comparator takes: a key parameter's annotation, else the expected comparator type's first argument. */
	private static function elementType(rows: Array<KeyRow>): ComplexType {
		for (row in rows) {
			if (row.type != null) return row.type;
		}
		final expected: Null<Type> = Context.getExpectedType();
		if (expected != null) switch Context.follow(expected) {
			case TFun(args, _) if (args.length == 2):
				return Context.toComplexType(args[0].t);
			case _:
		}
		return Context.error(
			'Compare.asc / Compare.desc: the element type is unknown here; use it where a (T, T) '
			+ '-> Int is expected, or annotate a key parameter ((r: Row) -> r.a)',
			Context.currentPos()
		);
	}

	/** The key `row` reads from the comparator parameter `arg`, evaluated as its own block so the lambda parameter stays a local. */
	private static function read(row: KeyRow, arg: Expr): Expr {
		final name: String = row.param;
		final body: Expr = row.body;
		return macro {
			final $name = $arg;
			$body;
		};
	}

	/**
	 * One comparison of the chain: the first key that differs decides, a
	 * tie passes to `next`; `index` keeps the names of nested steps apart.
	 */
	private static function step(row: KeyRow, index: Int, type: ComplexType, next: Expr): Expr {
		final left: String = '_cmpA$index';
		final right: String = '_cmpB$index';
		final lower: Expr = row.ascending ? macro -1 : macro 1;
		final upper: Expr = row.ascending ? macro 1 : macro -1;
		final leftKey: Expr = read(row, macro _cmpL);
		final rightKey: Expr = read(row, macro _cmpR);
		refuseNullable(row, type);
		return macro {
			final $left = $leftKey;
			final $right = $rightKey;
			if ($i{left} < $i{right})
				$lower
			else if ($i{left} > $i{right})
				$upper
			else
				$next;
		};
	}

	/** A `Null<…>` key would order by the target's null coercion, which differs between targets: refused. */
	private static function refuseNullable(row: KeyRow, type: ComplexType): Void {
		final name: String = row.param;
		final body: Expr = row.body;
		final keyType: Type = Context.typeof(macro {
			final $name: $type = cast null;
			$body;
		});
		if (isNull(keyType))
			Context.error(
				'Compare key is Null<…>: a nullable key has no portable order, compare a non-null value (r -> r.a ?? 0)', body.pos
			);
	}

	/** Follows typedef, lazy and monomorph layers one at a time: a full `Context.follow` strips `Null` itself. */
	private static function isNull(type: Type): Bool {
		return switch type {
			case TAbstract(a, _): a.get().name == 'Null';
			case TType(t, _): isNull(t.get().type);
			case TLazy(f): isNull(f());
			case TMono(r):
				final inner: Null<Type> = r.get();
				inner != null && isNull(inner);
			case _: false;
		}
	}

}
#end
