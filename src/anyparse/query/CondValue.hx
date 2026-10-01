package anyparse.query;

using Lambda;
using StringTools;

/**
 * The value one operand of a conditional-compilation condition takes, as the Haxe compiler's evaluator holds it
 * (`small_type` in `src/syntax/parserEntry.ml`, 4.3): an undefined define, a boolean an operator made, a number, a string —
 * a define's value or a literal — a `version("…")`, or a define known to be set whose value is not known (`Set`).
 */
enum CondValue {
	Undefined;
	Truth(value: Bool);
	Number(value: Float);
	Text(value: String);
	Version(release: Array<VersionPart>, pre: Null<Array<VersionPart>>);

	/** A define known to be set, its value unknown: a string, true, and of no known order against anything but a boolean. */
	Set;
}

/** One dot-separated part of a semantic version: a number, or anything `int_of_string` refuses. */
enum VersionPart {
	Num(value: Int);
	Str(value: String);
}

/** How two operands order (`cmp` in `parserEntry.ml`): by `sign`, never (the comparison is false), or not known here. */
private enum CondOrder {
	Ordered(sign: Int);
	Never;
	Undecided;
}

/**
 * The compiler's evaluation of a condition's values, on a positive whitelist: every rule is the compiler's own, and a
 * value or a comparison this cannot reproduce exactly — a number `float_of_string` might read another way, a non-ASCII
 * string order, a comparison the compiler rejects with an error — is unknown (null), never a guess. Truth (`is_true`): an
 * undefined define, `false` and the number 0 are false, every string — the empty one and `"0"` included — is true. A
 * comparison first converts a string beside a number to a number and a string beside a version to a version
 * (`eval_binop_exprs`); then an undefined define makes every comparison false and `!=` true, two values of one kind order
 * as that kind does (a version by SemVer precedence), a number or a version against anything else is the compiler's error,
 * and any other pair is false (`!=` true). Pure.
 */
@:nullSafety(Strict)
final class CondValues {

	/** A number `float_of_string` and the target read alike: decimal digits, optionally a fraction. */
	private static final DECIMAL: EReg = ~/^[0-9]+(\.[0-9]+)?$/;

	/** The last code of ASCII, whose strings order alike byte by byte and code unit by code unit. */
	private static inline final ASCII_LAST: Int = 0x7f;

	/** A version part `int_of_string` reads as this number: decimal digits, few enough for any integer. */
	private static final SMALL_DIGITS: EReg = ~/^[0-9]{1,9}$/;

	/** The truth of `value` (`is_true`); null when it is unknown. */
	public static function truth(value: Null<CondValue>): Null<Bool> {
		return switch value {
			case null: null;
			case Undefined: false;
			case Truth(b): b;
			case Number(n): n != 0;
			case Text(_) | Version(_, _) | Set: true;
		};
	}

	/** The value of a numeric literal `text` (`EConst (Int|Float)`): one `DECIMAL` reads; null for any other spelling. */
	public static function number(text: String): Null<CondValue> {
		return DECIMAL.match(text) ? Number(Std.parseFloat(text)) : null;
	}

	/**
	 * The value of a string literal whose content between the quotes is `raw` (`EConst String`): the compiler reads it
	 * raw, so one holding an escape is not known here.
	 */
	public static function text(raw: String): Null<CondValue> {
		return raw.indexOf('\\') >= 0 ? null : Text(raw);
	}

	/**
	 * The version `version("s")` names (`Semver.parse_version`): a release of three numbers, then optionally `-` and a
	 * pre-release of dotted parts, any `+` build metadata dropped. Null where the compiler reports an error and where a part
	 * may read differently (`part`).
	 */
	public static function version(s: String): Null<CondValue> {
		final dash: Int = s.indexOf('-');
		final release: Null<Array<VersionPart>> = parts(dash < 0 ? s : s.substr(0, dash));
		if (release == null || release.length != 3 || !release.foreach(p -> p.match(Num(_)))) return null;
		if (dash < 0) return Version(release, null);
		if (dash + 1 == s.length) return null;
		final rest: String = s.substr(dash + 1);
		final plus: Int = rest.indexOf('+');
		final pre: Null<Array<VersionPart>> = parts(plus < 0 ? rest : rest.substr(0, plus));
		return pre == null ? null : Version(release, pre);
	}

	/**
	 * The value of comparing `left` with `right` by `op` (`==`, `!=`, `>`, `>=`, `<`, `<=`): a boolean, or null where an
	 * operand is unknown, its value would decide a conversion, or the compiler rejects the comparison.
	 */
	public static function compare(op: String, left: Null<CondValue>, right: Null<CondValue>): Null<CondValue> {
		if (left == null || right == null) return null;
		return switch order(left, right) {
			case Undecided: null;
			case Never: Truth(op == '!=');
			case Ordered(sign):
				switch op {
					case '==': Truth(sign == 0);
					case '!=': Truth(sign != 0);
					case '>': Truth(sign > 0);
					case '>=': Truth(sign >= 0);
					case '<': Truth(sign < 0);
					case '<=': Truth(sign <= 0);
					case _: null;
				}
		};
	}

	/** `cmp` after `eval_binop_exprs` converted the operands. */
	private static function order(left: CondValue, right: CondValue): CondOrder {
		final pair: Null<{ left: CondValue, right: CondValue }> = converted(left, right);
		if (pair == null) return Undecided;
		return switch [pair.left, pair.right] {
			case [Undefined, _] | [_, Undefined]: Never;
			case [Set, Truth(_)] | [Truth(_), Set]: Never;
			case [Set, _] | [_, Set]: Undecided;
			case [Number(a), Number(b)]: Ordered(a < b ? -1 : a > b ? 1 : 0);
			case [Text(a), Text(b)]: textOrder(a, b);
			case [Truth(a), Truth(b)]: Ordered(a == b ? 0 : a ? 1 : -1);
			case [Version(r1, p1), Version(r2, p2)]:
				versionOrder(r1, p1, r2, p2);
			// the compiler's `Cannot compare` error: no build compiles the condition
			case [Text(_), Number(_)] | [Number(_), Text(_)] | [_, Version(_, _)] | [Version(_, _), _]: Undecided;
			case _: Never;
		};
	}

	/**
	 * The operands `eval_binop_exprs` hands `cmp`: a string beside a number read as a number where `float_of_string`
	 * reads it, a string beside a version parsed as one; null where that conversion is not known here — a define's unknown
	 * value, or a string the reading could take either way.
	 */
	private static function converted(left: CondValue, right: CondValue): Null<{ left: CondValue, right: CondValue }> {
		return switch [left, right] {
			case [Set, Number(_) | Version(_, _)] | [Number(_) | Version(_, _), Set]: null;
			case [Text(s), Number(_)]:
				final n: Null<CondValue> = number(s);
				n == null ? null : { left: n, right: right };
			case [Number(_), Text(s)]:
				final n: Null<CondValue> = number(s);
				n == null ? null : { left: left, right: n };
			case [Version(_, _), Text(s)]:
				final v: Null<CondValue> = version(s);
				v == null ? null : { left: left, right: v };
			case [Text(s), Version(_, _)]:
				final v: Null<CondValue> = version(s);
				v == null ? null : { left: v, right: right };
			case _: { left: left, right: right };
		};
	}

	/** The byte order OCaml's `compare` gives two strings, where it is the target's: both ASCII. */
	private static function textOrder(a: String, b: String): CondOrder {
		if (!ascii(a) || !ascii(b)) return Undecided;
		return Ordered(a < b ? -1 : a > b ? 1 : 0);
	}

	/** SemVer precedence (`Semver.compare_version`): the release, then no pre-release above any, then the pre-releases. */
	private static function versionOrder(
		r1: Array<VersionPart>, p1: Null<Array<VersionPart>>, r2: Array<VersionPart>, p2: Null<Array<VersionPart>>
	): CondOrder {
		final release: CondOrder = listOrder(r1, r2);
		if (!release.match(Ordered(0))) return release;
		return if (p1 == null)
			Ordered(p2 == null ? 0 : 1);
		else if (p2 == null)
			Ordered(-1);
		else
			listOrder(p1, p2);
	}

	/** `compare_lists`: part by part, a list that runs out first below. */
	private static function listOrder(a: Array<VersionPart>, b: Array<VersionPart>): CondOrder {
		for (i in 0...(a.length < b.length ? a.length : b.length)) {
			final step: CondOrder = switch [a[i], b[i]] {
				case [Num(x), Num(y)]: Ordered(x < y ? -1 : x > y ? 1 : 0);
				case [Str(x), Str(y)]: textOrder(x, y);
				case [Str(_), Num(_)]: Ordered(1);
				case [Num(_), Str(_)]: Ordered(-1);
			};
			if (!step.match(Ordered(0))) return step;
		}
		return Ordered(a.length < b.length ? -1 : a.length > b.length ? 1 : 0);
	}

	/**
	 * The parts of `dotted`: decimal digits a number, a part no `int_of_string` reads — one starting with neither a digit
	 * nor a sign — a string; null when one may be either (`0x1f`, `1_0`, `+1`, a long number).
	 */
	private static function parts(dotted: String): Null<Array<VersionPart>> {
		final out: Array<VersionPart> = [];
		for (p in dotted.split('.')) {
			if (SMALL_DIGITS.match(p)) {
				out.push(Num(Std.parseInt(p) ?? 0));
				continue;
			}
			final first: Int = p.length == 0 ? 'a'.code : p.fastCodeAt(0);
			if ((first >= '0'.code && first <= '9'.code) || first == '+'.code || first == '-'.code) return null;
			out.push(Str(p));
		}
		return out;
	}

	/** Whether every character of `s` is ASCII. */
	private static function ascii(s: String): Bool {
		for (i in 0...s.length) if (s.fastCodeAt(i) > ASCII_LAST) return false;
		return true;
	}

}
