package unit.query;

import anyparse.query.CondDirectives;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.BodySkip.SkipMark;
import anyparse.runtime.Span;

/**
 * `CondDirectives` — the one reader of a conditional-compilation directive's condition, shared by
 * every consumer that scans `#if` / `#elseif` from text.
 *
 * A condition may be broken across lines only inside a parenthesised group, after the keyword or
 * after `!`. Outside parentheses Haxe reads `!`* and ONE operand, so a binary operator never carries
 * it across a line and a leading `||` on the next line is the region's body. Every fixture states
 * the expected condition text itself, so none is derived from the reader's own arithmetic.
 */
@:nullSafety(Strict)
final class CondDirectivesTest extends Test {

	/** The Haxe grammar's directive vocabulary, which is where every keyword spelling here comes from. */
	private static final SHAPE: RefShape = new HaxeQueryPlugin().refShape();

	@:pin('control')
	@:killer('M-COND-GROUP-STOPS-AT-LINE')
	public function testAParenthesisedGroupMayBeBrokenAcrossLines(): Void {
		Assert.same(['(\n\t\tsys\n\t)'], conditions('#if (\n\t\tsys\n\t)\nclass C {}\n#end'));
		Assert.same(['(\n\t\tsys || (js\n\t\t&& debug)\n\t)'], conditions('#if (\n\t\tsys || (js\n\t\t&& debug)\n\t)\nclass C {}\n#end'));
	}

	@:pin('control')
	@:killer('M-COND-KEYWORD-OPERAND-SAME-LINE')
	public function testTheConditionMayStartOnTheLineAfterTheKeyword(): Void {
		Assert.same(['sys'], conditions('#if\n\tsys\nclass C {}\n#end'));
		Assert.same(['js', 'sys'], conditions('#if js\nclass C {}\n#elseif\n\tsys\nclass D {}\n#end'));
	}

	@:pin('control')
	@:killer('M-COND-OPERATOR-OPERAND-SAME-LINE')
	public function testABinaryOperatorEndingALineDoesNotCarryTheConditionOver(): Void {
		Assert.same(['sys'], conditions('#if sys &&\n\tjs\nclass C {}\n#end'));
		Assert.equals('#if sys', directiveText('#if sys &&\n\tjs\nclass C {}\n#end', 0));
	}

	@:pin('control')
	@:killer('M-COND-NEGATION-OPERAND-SAME-LINE')
	public function testAConditionContinuesOntoTheOperandOfANegation(): Void {
		Assert.same(['!\n\tsys'], conditions('#if !\n\tsys\nclass C {}\n#end'));
	}

	@:pin('guard')
	public function testALeadingBinaryOperatorOnTheNextLineIsTheRegionBody(): Void {
		Assert.same(['sys'], conditions('#if sys\n\t|| js\nclass C {}\n#end'));
		Assert.equals('#if sys', directiveText('#if sys\n\t|| js\nclass C {}\n#end', 0));
	}

	@:pin('guard')
	public function testCodeOnTheNextLineAfterACompleteConditionIsNotTheCondition(): Void {
		Assert.same(['sys'], conditions('#if sys\nclass C {}\n#end'));
		Assert.same(['sys'], conditions('#if sys\ntrace(1);\n#end'));
		Assert.same(['(sys)'], conditions('#if (sys)\ntrace(1);\n#end'));
	}

	@:pin('guard')
	public function testAnInlineRegionKeepsItsCodeOutOfTheCondition(): Void {
		Assert.same(['sys'], conditions('#if sys trace(1); #end'));
		Assert.same(['sys'], conditions('#if sys && js trace(1); #end'));
	}

	@:pin('control')
	@:killer('M-COND-OPERATOR-OPERAND-SAME-LINE')
	public function testABinaryOperatorAfterTheOperandOpensTheBody(): Void {
		Assert.same(['lime'], conditions('#if lime && renderer.__type == OPENGL trace(1); #end'));
		Assert.equals('#if lime', directiveText('#if lime && x == y trace(1); #end', 0));
		Assert.same(['!sys'], conditions('#if !sys || js trace(1); #end'));
	}

	@:pin('guard')
	public function testAParenthesisedGroupWithOperatorsStaysOneCondition(): Void {
		Assert.same(['(lime && renderer.__type == OPENGL)'], conditions('#if (lime && renderer.__type == OPENGL) trace(1); #end'));
		Assert.same(['!(sys || js)'], conditions('#if !(sys || js) trace(1); #end'));
	}

	@:pin('control')
	@:killer('M-COND-GROUP-STOPS-AT-LINE')
	public function testADirectiveSpanReachesTheEndOfABrokenConditionAndNoFurther(): Void {
		final source: String = '#if (\n\tsys\n)\nclass C {}\n#end';
		final directives: Array<CondDirective> = CondDirectives.scan(source, SHAPE, new HaxeQueryPlugin().lexicalRegions.bind(source));
		Assert.equals('#if (\n\tsys\n)', CondDirectives.text(source, directives[0]));
		Assert.equals('#end', CondDirectives.text(source, directives[1]));
	}

	@:pin('control')
	@:killer('M-COND-GROUP-STOPS-AT-LINE')
	public function testASkipMarkClosesAfterABrokenConditionNotInsideIt(): Void {
		final source: String = '#if (\n\tsys\n)\nclass C {}\n#end';
		final marks: Array<SkipMark> = CondDirectives.skipMarks(source, SHAPE, new HaxeQueryPlugin().lexicalRegions(source));
		Assert.equals(2, marks.length);
		Assert.equals(source.indexOf(')') + 1, marks[0].to);
	}

	@:pin('guard')
	public function testAnUnbalancedGroupIsNoCondition(): Void {
		Assert.same([], conditions('#if (sys\nclass C {}\n#end'));
	}

	/** The leading atom of a spliced fragment ends at whitespace outside parentheses; the whitespace after it is skipped too. */
	@:pin('control')
	@:killer('M-COND-ATOM-ENDS-AT-WS')
	public function testTheConditionAtomEndsAtWhitespaceOutsideParentheses(): Void {
		final fragment: String = '  !(a || b) else x';
		Assert.equals(fragment.indexOf('else'), CondDirectives.skipConditionAtom(fragment, 0));
		final quoted: String = "(a == ')' && b)\n\telse x";
		Assert.equals(quoted.indexOf('else'), CondDirectives.skipConditionAtom(quoted, 0));
		final unbalanced: String = '(a b else';
		Assert.equals(unbalanced.length, CondDirectives.skipConditionAtom(unbalanced, 0));
		final strayClose: String = 'a) else';
		Assert.equals(strayClose.length, CondDirectives.skipConditionAtom(strayClose, 0));
	}

	/** The condition text of every directive `source` carries one for, in source order. */
	private static function conditions(source: String): Array<String> {
		final out: Array<String> = [];
		for (directive in CondDirectives.scan(source, SHAPE, new HaxeQueryPlugin().lexicalRegions.bind(source))) {
			final condition: Null<Span> = directive.condition;
			if (condition != null) out.push(source.substring(condition.from, condition.to));
		}
		return out;
	}

	/** The verbatim text of the `index`-th directive of `source`. */
	private static function directiveText(source: String, index: Int): String {
		final directives: Array<CondDirective> = CondDirectives.scan(source, SHAPE, new HaxeQueryPlugin().lexicalRegions.bind(source));
		return CondDirectives.text(source, directives[index]);
	}

}
