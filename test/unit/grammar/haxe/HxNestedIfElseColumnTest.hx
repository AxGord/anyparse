package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A statement body that is an `if` with an `else` starts its own line one indent deeper than its head, so the inner
 * `else` sits under the inner `if` and never in the column of the enclosing head, where it would read as that head's.
 */
@:nullSafety(Strict)
final class HxNestedIfElseColumnTest extends Test {

	/** Bodies on the head's line when they fit. */
	private static final FIT_LINE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, '
		+ '"sameLine": {"ifBody": "fitLine", "forBody": "fitLine", "whileBody": "fitLine"}}';

	/** Bodies on the head's line. */
	private static final SAME: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "sameLine": {"ifBody": "same", "forBody": "same", "whileBody": "same"}}';

	private static final BARE_SOURCE: Array<String> = ['if (a) if (b) x(); else y();'];
	private static final BARE_LADDER: Array<String> = ['if (a)', '\tif (b)', '\t\tx();', '\telse', '\t\ty();'];
	private static final BRACED_SOURCE: Array<String> = ['if (a) if (b) { x(); } else { y(); }'];
	private static final BRACED_LADDER: Array<String> = ['if (a)', '\tif (b) {', '\t\tx();', '\t} else {', '\t\ty();', '\t}'];
	private static final HALF_SOURCE: Array<String> = ['if (a) if (b) { x(); } else y();'];
	private static final HALF_LADDER: Array<String> = ['if (a)', '\tif (b) {', '\t\tx();', '\t} else', '\t\ty();'];
	private static final OUTER_ELSE_SOURCE: Array<String> = ['if (a) if (b) x(); else y(); else z();'];
	private static final OUTER_ELSE_LADDER: Array<String> = ['if (a)', '\tif (b)', '\t\tx();', '\telse', '\t\ty();', 'else', '\tz();'];
	private static final NO_ELSE: Array<String> = ['if (a) if (b) x();'];
	private static final VALUE_TAIL: Array<String> = ['final r = {', '\tif (a) if (b) 10; else 20;', '};'];

	public function new(): Void {
		super();
	}

	/** The inner `if` of a brace-less pair takes its own line and indent level. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-NO-NESTED')
	public function testInnerIfElseStartsItsOwnLine(): Void {
		for (config in [FIT_LINE, SAME]) Assert.equals(fn(BARE_LADDER), write(BARE_SOURCE, config));
	}

	/** Every inner branch braced: the inner `} else {` sits at the inner `if`'s indent, not the outer head's. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-NO-NESTED')
	public function testBracedInnerIfElseStartsItsOwnLine(): Void {
		for (config in [FIT_LINE, SAME]) Assert.equals(fn(BRACED_LADDER), write(BRACED_SOURCE, config));
	}

	/** A braced then-branch beside a brace-less else keeps `} else` at the inner `if`'s indent. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-NO-NESTED')
	public function testHalfBracedInnerIfElseStartsItsOwnLine(): Void {
		for (config in [FIT_LINE, SAME]) Assert.equals(fn(HALF_LADDER), write(HALF_SOURCE, config));
	}

	/** An outer `if` with its own `else` ladders both levels, through its own `else` alone. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-OFF')
	public function testOuterElseLaddersBothLevels(): Void {
		for (config in [FIT_LINE, SAME]) Assert.equals(fn(OUTER_ELSE_LADDER), write(OUTER_ELSE_SOURCE, config));
	}

	/** An inner `if` without an `else` has no column to confuse: it keeps its placement. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-NO-ELSE')
	public function testInnerIfWithoutElseIsLeftAlone(): Void {
		for (config in [FIT_LINE, SAME]) Assert.equals(fn(NO_ELSE), write(NO_ELSE, config));
	}

	/** A statement `if` yielding a block's value sits in expression position: the expression knob places it. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-IN-EXPR')
	public function testValueTailIsLeftAlone(): Void {
		Assert.equals(fn(VALUE_TAIL), write(VALUE_TAIL, FIT_LINE));
	}

	/** Every nested ladder is a fixed point of the writer. */
	@:pin('control')
	@:killer('M-IF-ELSE-LADDER-NO-NESTED')
	public function testNestedLaddersAreIdempotent(): Void {
		for (ladder in [BARE_LADDER, BRACED_LADDER, HALF_LADDER, OUTER_ELSE_LADDER]) for (config in [FIT_LINE, SAME])
			Assert.equals(fn(ladder), write(ladder, config));
	}

	/** `lines` as the body of `function f()` in `class C`. */
	private static function fn(lines: Array<String>): String {
		return 'class C {\n\tfunction f() {\n' + lines.map(line -> '\t\t$line').join('\n') + '\n\t}\n}';
	}

	private static function write(lines: Array<String>, config: String): String {
		return HxWriteFixture.triviaWrite(fn(lines), config);
	}

}
