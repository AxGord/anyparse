package anyparse.check;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;

using Lambda;

/**
 * The literal-TABLE shapes the checks share: a collection literal of plain data (`isCollectionTable`)
 * and a `switch` that maps literal keys to literal values (`isSwitchTable`). A table's literals are data,
 * neither a hidden quantity nor a duplicated vocabulary entry: `string-literal-dup` exempts the entries
 * of a collection table, `magic-number` (under its `literalTables` option) the literals of a NAMED
 * collection table and of a switch table.
 *
 * Every shape is POSITIVE: only a construct the grammar names (`RefShape.arrayLiteralKind`,
 * `switchKinds`, `caseBranchKind`, ...) can be a table, and a seam the grammar leaves unset disables that
 * table, never a rule.
 */
@:nullSafety(Strict)
final class LiteralTables {

	/** Resolve the table vocabulary once per run from the grammar's `shape` and its string-fold seam. */
	public static function shapeOf(shape: RefShape, support: Null<StringFoldSupport>): LiteralTableShape {
		final literals: Null<Map<String, String>> = shape.literalTypeNames;
		return {
			support: support,
			arrayLiteralKind: shape.arrayLiteralKind ?? '',
			mapEntryKind: shape.mapLiteralEntryKind ?? '',
			literalKinds: literals == null ? [] : [for (kind in literals.keys()) kind],
			negationKind: shape.negationKind ?? '',
			numericKinds: shape.numericLiteralKinds ?? [],
			switchKinds: shape.switchKinds ?? [],
			caseBranchKind: shape.caseBranchKind ?? '',
			defaultBranchKind: shape.defaultBranchKind ?? '',
			plainPatternKind: shape.plainCasePatternKind ?? '',
			orPatternKind: shape.orPatternKind ?? '',
			exprStatementKind: shape.exprStatementKind ?? '',
			identKind: shape.identKind,
			wildcardName: shape.wildcardPatternName ?? ''
		};
	}

	/**
	 * Whether `node` IS a collection TABLE: a COLLECTION LITERAL the grammar itself names
	 * (`RefShape.arrayLiteralKind`) whose every child is a DATA ENTRY (`isDataEntry`) — of ANY
	 * arity, map entries included.
	 *
	 * Both halves are load-bearing. The kind gate makes the carve-out POSITIVE — only a construct
	 * the grammar declares to be a collection literal can ever be a table — which is what keeps it
	 * from leaking into shapes nobody enumerated. A test of the SHAPE alone ("every child is a
	 * plain literal") leaks into two whole classes: `new Foo("a", "b", "c")` carries its type as the
	 * node's NAME rather than as a child, and a conditional-compilation expression
	 * (`#if js "a" #else "b" #end`) is a run of sibling branch values — both all-literal, neither
	 * a table.
	 *
	 * The homogeneity half keeps LOGIC out of the collection kind itself, and it is what an ARITY
	 * floor used to approximate — badly: a floor of three read `arrayTypeNames: ['Array']` as logic
	 * and a 34-name vocabulary as data, though both are a field's stored value, and it could not
	 * see the MAP literal at all, which Haxe spells with the SAME collection kind, pairing key and
	 * value under an `Arrow`.
	 *
	 * One shape the kind gate cannot reach, because the grammar spells it with the same kind: an
	 * array destructuring PATTERN (`case ["aaaa", "bbbb"]:`) is a collection literal by kind and
	 * logic by meaning. A consumer that walks case patterns refuses beneath them itself
	 * (`StringLiteralDup.collect` carries a sticky `inPattern`).
	 */
	public static function isCollectionTable(node: QueryNode, source: String, t: LiteralTableShape): Bool {
		return node.kind == t.arrayLiteralKind && node.children.foreach(kid -> isDataEntry(kid, source, t));
	}

	/**
	 * Whether `node` is a DATA entry of a collection literal: a scalar datum (`isScalarData`), or a
	 * map ENTRY (`RefShape.mapLiteralEntryKind`) every side of which is again a data entry.
	 *
	 * The map arm requires BOTH sides, not the key alone, because a positive answer makes a consumer
	 * skip the whole subtree — a `'kkkk' => f(x)` pair would take an arbitrary value expression down
	 * with it. The price is small and in the safe direction: a map whose values are calls keeps its
	 * keys as candidates.
	 */
	public static function isDataEntry(node: QueryNode, source: String, t: LiteralTableShape): Bool {
		return node.kind == t.mapEntryKind ? node.children.foreach(part -> isDataEntry(part, source, t)) : isScalarData(node, source, t);
	}

	/**
	 * Whether `node` is a switch TABLE: a `RefShape.switchKinds` node whose every arm (each child after
	 * the subject) maps literal patterns to ONE literal value (`isTableArm`) — `case 0x410300: 0xC0;`, a
	 * lookup the function or binding around it names. The subject is no part of the table: a consumer
	 * still reads it as logic.
	 */
	public static function isSwitchTable(node: QueryNode, source: String, t: LiteralTableShape): Bool {
		return t.switchKinds.contains(node.kind) && node.children.length >= 2
			&& node.children.slice(1).foreach(arm -> isTableArm(arm, source, t));
	}

	/**
	 * Whether `node` is a scalar DATUM, each shape named by the GRAMMAR rather than by a consumer: a
	 * plain string literal (`StringFoldSupport.literalOf`), a childless leaf of a kind the grammar
	 * declares to BE a literal (`RefShape.literalTypeNames` keys — a number, a bool), or a negation
	 * (`RefShape.negationKind`) whose one operand is a childless numeric literal: Haxe has no negative
	 * literal, `-1` is a negation over `1`, and a negative number is data as much as a positive one.
	 *
	 * The childless test on the literal kinds is what keeps an INTERPOLATED string out: it carries its
	 * captured expressions as children, and `literalOf` has already refused it. A grammar naming no
	 * string-fold seam still gets its number and bool data; a missing seam narrows a table, never a rule.
	 */
	private static function isScalarData(node: QueryNode, source: String, t: LiteralTableShape): Bool {
		return node.kind == t.negationKind
			? node.children.length == 1 && node.children[0].children.length == 0 && t.numericKinds.contains(node.children[0].kind)
			: t.support?.literalOf(node, source) != null || (node.children.length == 0 && t.literalKinds.contains(node.kind));
	}

	/**
	 * An arm of a switch table: its LAST child is an expression statement holding one scalar datum, and
	 * everything before it is a case pattern (`isTablePattern`) — at least one for a `caseBranchKind`
	 * arm, none for the `defaultBranchKind` one. Positive: a guard, a block body, several statements or
	 * an arm kind the grammar names nowhere here make the switch no table.
	 */
	private static function isTableArm(arm: QueryNode, source: String, t: LiteralTableShape): Bool {
		final last: Int = arm.children.length - 1;
		if (last < 0 || !isValueStatement(arm.children[last], source, t)) return false;
		if (arm.kind == t.defaultBranchKind) return last == 0;
		if (arm.kind != t.caseBranchKind || last == 0) return false;
		for (i in 0...last) if (!isTablePattern(arm.children[i], source, t)) return false;
		return true;
	}

	/** An expression statement (`RefShape.exprStatementKind`) whose one child is a scalar datum — an arm's value. */
	private static function isValueStatement(stmt: QueryNode, source: String, t: LiteralTableShape): Bool {
		return stmt.kind == t.exprStatementKind && stmt.children.length == 1 && isScalarData(stmt.children[0], source, t);
	}

	/** A plain case pattern (`RefShape.plainCasePatternKind`) over one pattern value (`isPatternValue`). */
	private static function isTablePattern(pattern: QueryNode, source: String, t: LiteralTableShape): Bool {
		return pattern.kind == t.plainPatternKind && pattern.children.length == 1 && isPatternValue(pattern.children[0], source, t);
	}

	/**
	 * A table key: a scalar datum, the wildcard (`RefShape.wildcardPatternName` as a bare identifier),
	 * or an or-pattern (`RefShape.orPatternKind`, `case 33 | 44:`) of these. Any other identifier is a
	 * CAPTURE, whose arm is logic over the captured value.
	 */
	private static function isPatternValue(node: QueryNode, source: String, t: LiteralTableShape): Bool {
		return node.kind == t.orPatternKind
			? node.children.foreach(part -> isPatternValue(part, source, t))
			: isScalarData(node, source, t) || (node.kind == t.identKind && node.children.length == 0 && node.name == t.wildcardName);
	}

}

/** The grammar vocabulary the table shapes read, resolved once per run by `LiteralTables.shapeOf`. */
typedef LiteralTableShape = {
	final support: Null<StringFoldSupport>;
	final arrayLiteralKind: String;
	final mapEntryKind: String;
	final literalKinds: Array<String>;
	final negationKind: String;
	final numericKinds: Array<String>;
	final switchKinds: Array<String>;
	final caseBranchKind: String;
	final defaultBranchKind: String;
	final plainPatternKind: String;
	final orPatternKind: String;
	final exprStatementKind: String;
	final identKind: String;
	final wildcardName: String;
};
