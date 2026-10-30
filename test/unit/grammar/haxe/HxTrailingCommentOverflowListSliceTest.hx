package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * `comments.trailingCommentOverflow: "above"` inside an expression: an object-literal field, or an argument of a
 * call or a `new` already laid out one argument per line, moves an overflowing `//` comment onto its own line above it, at
 * its indent, under the statement's positive list (`HxTrailingCommentOverflowSliceTest`): not a directive, no
 * leading comment of its own, code that alone fits on one line. A Keep-mode field glued to its predecessor keeps
 * the comment, which could not end a line above it. Every moved form is a fixed point. Fixtures are 60 columns
 * wide at tab 4.
 */
@:nullSafety(Strict)
final class HxTrailingCommentOverflowListSliceTest extends Test {

	private static final BASE: String = '"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 60';
	private static final ON: String = '"comments": {"trailingCommentOverflow": "above"}';
	private static final CONFIG_ON: String = '{$BASE}, $ON}';
	private static final CONFIG_OFF: String = '{$BASE}}';
	private static final CONFIG_KEEP_ON: String = '{$BASE, "objectLiteral": {"defaultWrap": "keep", "rules": []}}, $ON}';
	private static final FIELD_SRC: Array<String> = [
		'final d = {',
		'\ta: 1, // a comment long enough to overflow this line here',
		'\tb: 2, // short',
		'\tc: 3 // and another comment long enough to overflow this',
		'};'
	];
	private static final FIELD_ABOVE: Array<String> = [
		'final d = {',
		'\t// a comment long enough to overflow this line here',
		'\ta: 1,',
		'\tb: 2, // short',
		'\t// and another comment long enough to overflow this',
		'\tc: 3',
		'};'
	];
	private static final ARG_SRC: Array<String> = [
		'call(',
		'\tfirstArgument, // a comment long enough to overflow this line',
		'\tsecond, // short',
		'\tthird // another comment long enough to overflow the line',
		');'
	];
	private static final ARG_ABOVE: Array<String> = [
		'call(',
		'\t// a comment long enough to overflow this line',
		'\tfirstArgument,',
		'\tsecond, // short',
		'\t// another comment long enough to overflow the line',
		'\tthird',
		');'
	];

	/** A last element whose source put a separator before the comment: the comment moves, the separator stays. */
	private static final TRAIL_SRC: Array<String> = [
		'call(',
		'\tfirst,',
		'\tthird, // another comment long enough to overflow the line',
		');',
		'final d = {',
		'\ta: 1,',
		'\tc: 3, // and another comment long enough to overflow this',
		'};'
	];

	private static final TRAIL_ABOVE: Array<String> = [
		'call(',
		'\tfirst,',
		'\t// another comment long enough to overflow the line',
		'\tthird,',
		');',
		'final d = {',
		'\ta: 1,',
		'\t// and another comment long enough to overflow this',
		'\tc: 3,',
		'};'
	];

	/** `new` arguments: the comment after a separator moves, a last argument's own one too, its separator stays. */
	private static final NEW_SRC: Array<String> = [
		'final o = new Foo(',
		'\tfirst,',
		'\tsecond, // another comment long enough to overflow the line',
		'\tthird',
		');',
		'final p = new Foo(',
		'\tfirst,',
		'\tthird // another comment long enough to overflow the line',
		');',
		'final q = new Foo(',
		'\tfirst,',
		'\tthird, // another comment long enough to overflow the line',
		');'
	];

	private static final NEW_ABOVE: Array<String> = [
		'final o = new Foo(',
		'\tfirst,',
		'\t// another comment long enough to overflow the line',
		'\tsecond,',
		'\tthird',
		');',
		'final p = new Foo(',
		'\tfirst,',
		'\t// another comment long enough to overflow the line',
		'\tthird',
		');',
		'final q = new Foo(',
		'\tfirst,',
		'\t// another comment long enough to overflow the line',
		'\tthird,',
		');'
	];

	/** Every trailing comment here keeps its place under the knob: a fit, a lead, a directive, over-wide code. */
	private static final STAYS: Array<String> = [
		'final d = {',
		'\ta: 1, // fits here',
		'\t// led by a comment',
		'\tb: 2, // and a trailing one that is long enough to overflow',
		'\tc: 3, // noqa: some-rule and more text so that it overflows',
		'\tdd: someVeryLongIdentifierNameThatFillsTheLineAlone, // c',
		'};',
		'call(',
		'\tfirst, // fits',
		'\t// led by a comment',
		'\tsecond, // and a trailing one that is long enough to overflow',
		'\tthird',
		');'
	];

	/** A Keep-mode literal glues its first field to `{`, so that field's comment stays; the next field's moves. */
	private static final KEEP_SRC: Array<String> = [
		'final d = {a: 1, // a comment long enough to overflow this line here',
		'\tb: 2, // and another comment long enough to overflow this',
		'\tc: 3',
		'};'
	];

	private static final KEEP_ABOVE: Array<String> = [
		'final d = {a: 1, // a comment long enough to overflow this line here',
		'\t// and another comment long enough to overflow this',
		'\tb: 2,',
		'\tc: 3',
		'};'
	];

	/** The head operand's operator comment stays: above the head is the statement, not the chain. */
	private static final CHAIN: Array<String> = [
		'return alpha(first) || // a comment long enough to overflow',
		'\tbeta(second);'
	];

	public function new(): Void {
		super();
	}

	/** An object-literal field: the overflowing comments move, the fitting one stays; the knob off moves nothing. */
	@:pin('control')
	@:killer('M-TCO-FIELD-KNOB-IGNORED')
	public function testOverflowingFieldCommentMovesAbove(): Void {
		Assert.equals(fn(FIELD_ABOVE), write(fn(FIELD_SRC), CONFIG_ON));
		Assert.equals(fn(FIELD_SRC), write(fn(FIELD_SRC), CONFIG_OFF));
	}

	/**
	 * A call argument: the comment after the separator moves, and so does the last argument's, which no
	 * separator follows, once that comment has put the list one argument per line.
	 */
	@:pin('control')
	@:killer('M-TCO-ARG-KNOB-IGNORED')
	@:killer('M-TCO-ARG-LAST-STAYS')
	public function testOverflowingArgumentCommentMovesAbove(): Void {
		Assert.equals(fn(ARG_ABOVE), write(fn(ARG_SRC), CONFIG_ON));
		Assert.equals(fn(ARG_SRC), write(fn(ARG_SRC), CONFIG_OFF));
	}

	/** A trailing separator the source put before the comment survives the move, in a call and a literal alike. */
	public function testTrailingSeparatorStaysWithTheMovedElement(): Void {
		Assert.equals(fn(TRAIL_ABOVE), write(fn(TRAIL_SRC), CONFIG_ON));
		Assert.equals(fn(TRAIL_SRC), write(fn(TRAIL_SRC), CONFIG_OFF));
	}

	/** A `new` argument moves its overflowing comment as a call argument does; the knob off moves nothing. */
	@:pin('control')
	@:killer('M-TCO-FIELD-KNOB-IGNORED')
	public function testOverflowingNewArgumentCommentMovesAbove(): Void {
		Assert.equals(fn(NEW_ABOVE), write(fn(NEW_SRC), CONFIG_ON));
		Assert.equals(fn(NEW_SRC), write(fn(NEW_SRC), CONFIG_OFF));
	}

	/** Outside the positive list nothing moves, in a literal and in an argument list alike. */
	@:pin('control')
	@:killer('M-TCO-FIELD-LEADING-IGNORED')
	@:killer('M-TCO-ARG-LEADING-IGNORED')
	public function testEverythingOutsideThePositiveListStays(): Void {
		Assert.equals(fn(STAYS), write(fn(STAYS), CONFIG_ON));
	}

	/** A Keep-mode field that shares its line with `{` keeps its comment; one that starts its own line moves it. */
	@:pin('control')
	@:killer('M-TCO-FIELD-OWN-LINE-IGNORED')
	public function testKeepGluedFieldKeepsItsComment(): Void {
		Assert.equals(fn(KEEP_ABOVE), write(fn(KEEP_SRC), CONFIG_KEEP_ON));
	}

	/** The chain head's operator comment keeps its line under the knob. */
	public function testChainOperatorCommentStays(): Void {
		Assert.equals(fn(CHAIN), write(fn(CHAIN), CONFIG_ON));
	}

	/** Every moved form is a fixed point of the same config. */
	public function testMovedFormsAreFixedPoints(): Void {
		for (canon in [FIELD_ABOVE, ARG_ABOVE, TRAIL_ABOVE, NEW_ABOVE]) Assert.equals(fn(canon), write(fn(canon), CONFIG_ON));
		Assert.equals(fn(KEEP_ABOVE), write(fn(KEEP_ABOVE), CONFIG_KEEP_ON));
	}

	private function write(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

	/** A one-function class whose body is `lines`, each at the body's indent. */
	private static function fn(lines: Array<String>): String {
		return 'class C {\n\tfunction f() {\n' + [for (line in lines) '\t\t$line\n'].join('') + '\t}\n}';
	}

}
