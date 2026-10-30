package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * The comments an infix chain operator (`||`, `&&`, `+`, `-`, `??`) owns: an own-line run between the operator and
 * its right operand reads back into the operator's own slot and is written where it stood, under every chain
 * `defaultWrap`; and under `comments.trailingCommentOverflow: "above"` an overflowing `//` comment after an operator
 * moves onto its own line above the operand it trails, when that operand opens its own line after an operator.
 */
@:nullSafety(Strict)
final class HxChainOperatorCommentSlotTest extends Test {

	private static final MODES: Array<String> = [
		'noWrap',
		'keep',
		'onePerLine',
		'onePerLineAfterFirst',
		'fillLine',
		'fillLineWithLeadingBreak'
	];

	/** Own-line comments after each chain operator, beside a same-line one and a block one. */
	private static final OWN_LINE: Array<String> = [
		'final a = alpha(first) ||',
		'\t// one',
		'\tbeta(second) &&',
		'\t// two',
		'\t// three',
		'\tgamma(third);',
		'final b = left +',
		'\t// four',
		'\tright -',
		'\t/* five */',
		'\tother;',
		'final c = maybe ??',
		'\t// six',
		'\tfallback;',
		'final d = alpha && // seven',
		'\t// eight',
		'\tbeta;'
	];

	private static final ABOVE_BASE: String = '"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 60}';
	private static final ABOVE_ON: String = '{$ABOVE_BASE, "comments": {"trailingCommentOverflow": "above"}}';
	private static final ABOVE_OFF: String = '{$ABOVE_BASE}';

	/** The `+` chain at `afterLast`, its operators at the line ends. */
	private static final AFTER_LAST: String = '"opAddSubChain": {"defaultLocation": "afterLast", "rules": []}';

	private static final ADD_ON: String = '{"indentation": {"character": "tab", "tabWidth": 4}, '
		+ '"wrapping": {"maxLineLength": 60, $AFTER_LAST}, "comments": {"trailingCommentOverflow": "above"}}';
	private static final ADD_OFF: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 60, $AFTER_LAST}}';

	/**
	 * A chain at `beforeLast` (the default) breaks before its operators, so a moved comment leaves its gap breaking
	 * before the operator and the next operand no longer opens a line after one: its comment stays though it
	 * overflows too.
	 */
	private static final BOOL_SRC: Array<String> = [
		'return alpha(first) || // a comment long enough to overflow',
		'\tbeta(second) || // another comment long enough to overflow',
		'\tgamma(third) || // and one more comment long enough to overflow',
		'\tdelta(fourth);'
	];

	private static final BOOL_ABOVE: Array<String> = [
		'return alpha(first) || // a comment long enough to overflow',
		'\t// another comment long enough to overflow',
		'\tbeta(second)',
		'\t|| gamma(third) || // and one more comment long enough to overflow',
		'\tdelta(fourth);'
	];

	/** At `afterLast` a gap keeps its operator at the line end, so every operand that opens a line takes its comment. */
	private static final ADD_SRC: Array<String> = [
		'return a + // c',
		'\tbb + // a comment long enough to overflow this line here',
		'\tcc + // a comment long enough to overflow this line here',
		'\tdd;'
	];

	private static final ADD_ABOVE: Array<String> = [
		'return a + // c',
		'\t// a comment long enough to overflow this line here',
		'\tbb +',
		'\t// a comment long enough to overflow this line here',
		'\tcc +',
		'\tdd;'
	];

	/**
	 * `+` and `-` at the default `beforeLast`: the gap after a moved comment breaks before its operator, which an
	 * additive operator reads back as a break even though its left operand's parse consumed the newline.
	 */
	private static final ADD_SUB_SRC: Array<String> = [
		'return aaaa + // a comment long enough to overflow this line here',
		'\tbbbb + // a comment long enough to overflow this line here',
		'\tcccc + // c',
		'\tdddd;',
		'return aaaa - // a comment long enough to overflow this line here',
		'\tbbbb - // a comment long enough to overflow this line here',
		'\tcccc - // c',
		'\tdddd;'
	];

	private static final ADD_SUB_ABOVE: Array<String> = [
		'return aaaa + // a comment long enough to overflow this line here',
		'\t// a comment long enough to overflow this line here',
		'\tbbbb',
		'\t+ cccc + // c',
		'\tdddd;',
		'return aaaa - // a comment long enough to overflow this line here',
		'\t// a comment long enough to overflow this line here',
		'\tbbbb',
		'\t- cccc - // c',
		'\tdddd;'
	];

	/** A comment keeps an additive chain in its source layout, a break before a non-head operator included. */
	private static final ADD_SUB_KEPT: Array<String> = [
		'var s = aaaaaaaaaaaa',
		'\t+ bbbbbbbbbbbb + // a comment',
		'\tcccccccccccc;',
		'var t = aaaaaaaaaaaa',
		'\t- bbbbbbbbbbbb - // a comment',
		'\tcccccccccccc;'
	];

	/** Every comment here keeps its place under the knob: one that fits, one above an operand led by a comment. */
	private static final ABOVE_STAYS: Array<String> = [
		'return a + // c',
		'\tbb + // fits',
		'\t// led',
		'\tcc + // a comment long enough to overflow this line here',
		'\tdd;'
	];

	public function new(): Void {
		super();
	}

	/** The own-line run stays between its operator and operand, one pass, under every chain `defaultWrap`. */
	@:pin('control')
	@:killer('M-CHAIN-OWN-COMMENTS-UNTAKEN')
	public function testOwnLineCommentsStayAfterTheirOperator(): Void {
		Assert.equals(fn(OWN_LINE), write(fn(OWN_LINE), '{}'));
		for (mode in MODES) {
			final config: String = '{"wrapping": {"opBoolChain": {"defaultWrap": "$mode", "rules": []}, '
				+ '"opAddSubChain": {"defaultWrap": "$mode", "rules": []}}}';
			Assert.equals(fn(OWN_LINE), write(fn(OWN_LINE), config), mode);
		}
	}

	/** Under "above" the overflowing operator comments move; the knob off moves nothing. */
	@:pin('control')
	@:killer('M-CHAIN-ABOVE-KNOB-IGNORED')
	@:killer('M-CHAIN-ABOVE-NEXT-UNBLOCKED')
	public function testOverflowingOperatorCommentMovesAbove(): Void {
		Assert.equals(fn(BOOL_ABOVE), write(fn(BOOL_SRC), ABOVE_ON));
		Assert.equals(fn(ADD_ABOVE), write(fn(ADD_SRC), ADD_ON));
		Assert.equals(fn(ADD_SUB_ABOVE), write(fn(ADD_SUB_SRC), ABOVE_ON));
		Assert.equals(fn(BOOL_SRC), write(fn(BOOL_SRC), ABOVE_OFF));
		Assert.equals(fn(ADD_SRC), write(fn(ADD_SRC), ADD_OFF));
	}

	/** A break before a non-head `+` / `-` reads back as a break, so a kept additive chain is one pass. */
	@:pin('control')
	@:killer('M-ADDSUB-BREAK-BEFORE-OP-LOST')
	public function testBreakBeforeAnAdditiveOperatorReadsBack(): Void {
		Assert.equals(fn(ADD_SUB_KEPT), write(fn(ADD_SUB_KEPT), '{}'));
	}

	/** A comment that fits, or one whose operand already has a comment above it, stays. */
	@:pin('control')
	@:killer('M-CHAIN-ABOVE-LED-IGNORED')
	public function testCommentsOutsideThePositiveListStay(): Void {
		Assert.equals(fn(ABOVE_STAYS), write(fn(ABOVE_STAYS), ADD_ON));
	}

	/** Every moved form is a fixed point of the same config. */
	public function testMovedFormsAreFixedPoints(): Void {
		Assert.equals(fn(BOOL_ABOVE), write(fn(BOOL_ABOVE), ABOVE_ON));
		Assert.equals(fn(ADD_ABOVE), write(fn(ADD_ABOVE), ADD_ON));
		Assert.equals(fn(ADD_SUB_ABOVE), write(fn(ADD_SUB_ABOVE), ABOVE_ON));
	}

	private function write(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

	/** A one-function class whose body is `lines`, each at the body's indent. */
	private static function fn(lines: Array<String>): String {
		return 'class C {\n\tfunction f() {\n' + [for (line in lines) '\t\t$line\n'].join('') + '\t}\n}';
	}

}
