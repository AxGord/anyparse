package anyparse.grammar.haxe.cond;

import anyparse.query.CondExpr;
import haxe.Exception;

/**
 * The Haxe plugin's `RefShape.conditionExpr`: the one answer to "what does a Haxe preprocessor condition say, as a
 * `CondExpr`". The text is read by the generated `HxCondValueParser`, so this only maps the parsed `HxCondValue` onto the
 * grammar-agnostic tree and refuses the shape the compiler's condition grammar has no reading of.
 */
@:nullSafety(Strict)
final class HxCondExprReader {

	/** The condition `condition` states, or null when it does not parse whole or chains a comparison (`a == b == c`). */
	public static function read(condition: String): Null<CondExpr> {
		final tree: Null<HxCondValue> = try HxCondValueParser.parse(condition) catch (_: Exception) null;
		return tree == null || chainsComparisons(tree) ? null : exprOf(tree);
	}

	/** `tree` as a `CondExpr`: a group is its inner condition, a literal loses its quotes. */
	private static function exprOf(tree: HxCondValue): CondExpr {
		return switch tree {
			case VersionCall(literal): CondExpr.Version(unquoted(literal));
			case Group(inner): exprOf(inner);
			case Quoted(text): CondExpr.Text(unquoted(text));
			case Flag(name): CondExpr.Flag(name);
			case Number(text): CondExpr.Number(text);
			case Not(operand): CondExpr.Not(exprOf(operand));
			case Eq(left, right): CondExpr.Compare('==', exprOf(left), exprOf(right));
			case NotEq(left, right): CondExpr.Compare('!=', exprOf(left), exprOf(right));
			case GtEq(left, right): CondExpr.Compare('>=', exprOf(left), exprOf(right));
			case LtEq(left, right): CondExpr.Compare('<=', exprOf(left), exprOf(right));
			case Gt(left, right): CondExpr.Compare('>', exprOf(left), exprOf(right));
			case Lt(left, right): CondExpr.Compare('<', exprOf(left), exprOf(right));
			case And(left, right): CondExpr.And(exprOf(left), exprOf(right));
			case Or(left, right): CondExpr.Or(exprOf(left), exprOf(right));
		};
	}

	/**
	 * Whether a comparison somewhere in `tree` takes a comparison as its left operand (`a == b == c`). The compiler's
	 * condition grammar takes one comparison of two operands, so such a condition is no condition it evaluates; a
	 * parenthesised one (`(a == b) == c`) is a group and stays a value.
	 */
	private static function chainsComparisons(tree: HxCondValue): Bool {
		return switch tree {
			case Eq(left, right), NotEq(left, right), GtEq(left, right), LtEq(left, right), Gt(left, right), Lt(left, right):
				isComparison(left) || chainsComparisons(left) || chainsComparisons(right);
			case And(left, right), Or(left, right):
				chainsComparisons(left) || chainsComparisons(right);
			case Not(operand): chainsComparisons(operand);
			case Group(inner): chainsComparisons(inner);
			case VersionCall(_), Quoted(_), Flag(_), Number(_): false;
		};
	}

	private static function isComparison(tree: HxCondValue): Bool {
		return switch tree {
			case Eq(_, _), NotEq(_, _), GtEq(_, _), LtEq(_, _), Gt(_, _), Lt(_, _): true;
			case _: false;
		};
	}

	/** The text between the quotes of a quoted literal. */
	private static function unquoted(literal: String): String {
		return literal.substring(1, literal.length - 1);
	}

}
