package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;

using StringTools;

/**
 * The VALUE a `case` pattern denotes, as a key two patterns share exactly when the language
 * compares them equal — or null when the value cannot be PROVED. The switch rules (`SwitchChain`,
 * gate 9) ask it of every pattern a chain would emit, so that no two `case`s of the rewritten
 * switch denote one value.
 *
 * A repeated value is dead past its first match in the chain and stays dead in the switch, so the
 * behaviour is kept; what is not kept is the source's standing — the switch carries a `case` the
 * compiler reports as unused (`WUnusedPattern`). The duplicate is invisible in the text: under
 * `enum abstract M(Int) { var DEFAULT = 0; var AUTO = 0; }` the two names are one value.
 *
 * ## The answer is a POSITIVE proof
 *
 * Every shape not listed answers null, and the caller refuses the chain on null. Known values:
 *
 * - a NUMBER literal (`numericLiteralKinds`), optionally negated (`negationKind`), in decimal,
 *   `0x` hexadecimal up to `0x7FFFFFFF` (a wider one wraps to a negative `Int`) or float spelling,
 *   keyed by its numeric value so `1`, `1.0` and `0x1` collide as the language compares them;
 * - a BOOL or NULL literal (`boolLitKind`, `nullLiteralKind`), by text;
 * - a STRING literal (`stringLiteralKinds`) carrying no `\` and no `$`, whose two quotes then denote
 *   the same characters;
 * - a MEMBER (`ofMember`): its initializer (`MemberInfo.initializerKind` / `initializerSource`) read
 *   by the same rules, or, for an enum-abstract value written without one, the value the language
 *   fills in (`RefShape.enumAbstractImplicitValues`). A reference initializer (`var B = A;`) is
 *   unknown, as is every value counted after it, and so is every member of a declaration carrying
 *   a build macro, which may rewrite it.
 *
 * ## Grammar-agnostic
 *
 * Every kind is a `RefShape` seam, read once by `seamsOf`. The numeric spellings are the only
 * syntax written here; a grammar spelling numbers otherwise gets null — fewer findings, never a
 * wrong one.
 */
@:nullSafety(Strict)
final class CaseValueKey {

	/** The largest hexadecimal literal that is its own value: one more wraps to a negative `Int`. */
	private static inline final MAX_HEX_VALUE: Float = 2147483647;

	/** The key a numeric value is filed under — one shared prefix, so an `Int` and an equal `Float` collide. */
	private static inline final NUMBER_PREFIX: String = 'n:';

	/** The key prefix of a string value. */
	private static inline final STRING_PREFIX: String = 's:';

	/** The key prefix of a bool value. */
	private static inline final BOOL_PREFIX: String = 'b:';

	/** The key of the null literal. */
	private static inline final NULL_KEY: String = 'null';

	/** A decimal integer literal. */
	private static final DECIMAL: EReg = ~/^[0-9]+$/;

	/** A hexadecimal integer literal. */
	private static final HEX: EReg = ~/^0[xX][0-9a-fA-F]+$/;

	/** A decimal float literal, with or without fraction digits and exponent. */
	private static final FLOAT: EReg = ~/^(?:[0-9]+\.[0-9]*|\.[0-9]+|[0-9]+)(?:[eE][+-]?[0-9]+)?$/;

	/**
	 * The seams `of` and `ofMember` read; an unset seam leaves the values it would describe unknown.
	 */
	public static function seamsOf(shape: RefShape): CaseValueSeams {
		final implicit: Null<{ counting: Array<String>, naming: Array<String> }> = shape.enumAbstractImplicitValues;
		return {
			numericKinds: shape.numericLiteralKinds ?? [],
			boolKind: shape.boolLitKind,
			nullKind: shape.nullLiteralKind,
			negationKind: shape.negationKind,
			stringKinds: shape.stringLiteralKinds ?? [],
			enumAbstractKind: shape.enumAbstractDeclKind,
			fieldKinds: shape.fieldDeclKinds ?? [],
			countingTypes: implicit?.counting ?? [],
			namingTypes: implicit?.naming ?? []
		};
	}

	/** The value key of a literal of node kind `kind` written as `text`, or null when it is not provably known. */
	public static function of(kind: String, text: String, seams: CaseValueSeams): Null<String> {
		final number: Null<Float> = numberOf(kind, text, seams);
		if (number != null) return numberKey(number);
		if (kind == seams.boolKind) return BOOL_PREFIX + text;
		if (kind == seams.nullKind) return NULL_KEY;
		if (!seams.stringKinds.contains(kind) || text.length < 2) return null;
		final content: String = text.substring(1, text.length - 1);
		return text.charAt(0) != text.charAt(text.length - 1) || content.contains('\\') || content.contains('$')
			? null
			: STRING_PREFIX + content;
	}

	/**
	 * The value key of `member`, declared by `type`: its initializer's (`of`), or the implicit value
	 * of an uninitialized enum-abstract value, or null when neither is provable.
	 */
	public static function ofMember(type: TypeDeclInfo, member: MemberInfo, seams: CaseValueSeams): Null<String> {
		if (type.hasBuild) return null;
		final kind: Null<String> = member.initializerKind;
		final text: Null<String> = member.initializerSource;
		if (kind != null && text != null) return of(kind, text, seams);
		final underlying: Null<String> = type.underlyingRaw;
		if (underlying == null || !isEnumAbstractValue(type, member, seams)) return null;
		if (seams.namingTypes.contains(underlying)) return STRING_PREFIX + member.name;
		if (!seams.countingTypes.contains(underlying)) return null;
		final counted: Null<Float> = countedValue(type, member, seams);
		return counted == null ? null : numberKey(counted);
	}

	/** The key a numeric `value` is filed under. */
	private static inline function numberKey(value: Float): String {
		return '$NUMBER_PREFIX$value';
	}

	/**
	 * The value a COUNTING enum abstract gives `member`: walking its values in declaration order, each
	 * uninitialized one is the previous plus one (the first `0`) and each initialized one is its own
	 * integer literal. Null as soon as the walk meets a value it cannot read — a non-integer or
	 * non-literal initializer, or a `#if`-guarded value, whose presence moves the count per branch.
	 */
	private static function countedValue(type: TypeDeclInfo, member: MemberInfo, seams: CaseValueSeams): Null<Float> {
		var next: Null<Float> = 0;
		for (m in type.members) if (isEnumAbstractValue(type, m, seams)) {
			if (m.guarded) return null;
			final kind: Null<String> = m.initializerKind;
			final text: Null<String> = m.initializerSource;
			final value: Null<Float> = kind == null || text == null ? next : numberOf(kind, text, seams);
			if (m == member) return value;
			next = value == null || Math.ffloor(value) != value ? null : value + 1;
		}
		return null;
	}

	/** Whether `member` is a VALUE of the enum abstract `type` — a non-static field of an enum-abstract declaration. */
	private static function isEnumAbstractValue(type: TypeDeclInfo, member: MemberInfo, seams: CaseValueSeams): Bool {
		return type.kind == seams.enumAbstractKind && !member.isStatic && seams.fieldKinds.contains(member.kind);
	}

	/**
	 * The numeric value of a number literal of kind `kind` written as `text` — negated when `kind` is the
	 * negation kind over one — or null when it is not a number literal in one of the three known spellings.
	 */
	private static function numberOf(kind: String, text: String, seams: CaseValueSeams): Null<Float> {
		if (kind != seams.negationKind || !text.startsWith('-')) return seams.numericKinds.contains(kind) ? unsignedNumberOf(text) : null;
		final operand: Null<Float> = unsignedNumberOf(text.substring(1).trim());
		return operand == null ? null : -operand;
	}

	/** `text` read as an unsigned decimal, hexadecimal or float spelling, or null for any other text. */
	private static function unsignedNumberOf(text: String): Null<Float> {
		if (!HEX.match(text)) return DECIMAL.match(text) || FLOAT.match(text) ? Std.parseFloat(text) : null;
		final value: Null<Int> = Std.parseInt(text);
		return value == null || value < 0 || (value: Float) > MAX_HEX_VALUE ? null : value;
	}

}

/** The `RefShape` seams `CaseValueKey` reads, resolved once by `CaseValueKey.seamsOf`. */
typedef CaseValueSeams = {
	final numericKinds: Array<String>;
	final boolKind: Null<String>;
	final nullKind: Null<String>;
	final negationKind: Null<String>;
	final stringKinds: Array<String>;
	final enumAbstractKind: Null<String>;
	final fieldKinds: Array<String>;

	/** `RefShape.enumAbstractImplicitValues.counting` — the underlying types an uninitialized value counts in. */
	final countingTypes: Array<String>;

	/** `RefShape.enumAbstractImplicitValues.naming` — the underlying types an uninitialized value is named in. */
	final namingTypes: Array<String>;
};
