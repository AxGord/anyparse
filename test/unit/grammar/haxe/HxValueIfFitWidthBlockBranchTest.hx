package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * omega-value-if-fit value-width cap: it gates only the flat collapse of a chain of plain values.
 * A chain with a value that carries a forced break (a switch or block, the glued block path) has no
 * flat width to cap and keeps the layout it has without the cap.
 */
@:nullSafety(Strict)
final class HxValueIfFitWidthBlockBranchTest extends Test {

	private static final BASE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}';
	private static final WIDTH8: String = '$BASE, "sameLine": {'
		+ '"expressionIf": "next", "expressionIfFit": true, "expressionIfFitMaxBranches": 3, "expressionIfFitMaxValueWidth": 8}}';
	private static final NO_WIDTH: String =
		'$BASE, "sameLine": {"expressionIf": "next", "expressionIfFit": true, "expressionIfFitMaxBranches": 3}}';
	private static final THEN_SWITCH: String = 'class C {\n\tfunction f(a:Bool, b:Int, d:String):String {\n'
		+ '\t\tfinal v:String = if (a) switch b {\n\t\t\tcase 0: \'zero\';\n\t\t\tcase _: \'other\';\n'
		+ '\t\t} else d;\n\t\treturn v;\n\t}\n}';
	private static final ELSE_SWITCH: String = 'class C {\n\tfunction g(s:String):String {\n\t\treturn if (s.length == 2) describe(s) '
		+ 'else switch s {\n\t\t\tcase \'x\': \'X\';\n\t\t\tcase _: \'Y\';\n\t\t};\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** A switch as the THEN value keeps the glued layout under the width cap. */
	@:pin('control')
	@:killer('M-VIF-WIDTH-FORCED-BREAK-REFUSES')
	public function testSwitchThenValueStaysGlued(): Void {
		Assert.equals(THEN_SWITCH, HxWriteFixture.triviaWrite(THEN_SWITCH, WIDTH8));
	}

	/** A switch as the final ELSE value keeps the glued layout under the width cap, whatever the width of a plain value beside it. */
	@:pin('control')
	@:killer('M-VIF-WIDTH-TAIL-BREAK-UNSEEN')
	public function testSwitchElseValueStaysGlued(): Void {
		Assert.equals(ELSE_SWITCH, HxWriteFixture.triviaWrite(ELSE_SWITCH, WIDTH8));
	}

	/** A wide plain value beside a THEN switch does not re-ladder the chain: the cap does not apply to it at all. */
	@:pin('control')
	@:killer('M-VIF-WIDTH-BREAK-NOT-EXEMPT')
	public function testSwitchThenWideElseStaysGlued(): Void {
		final src: String = 'class C {\n\tfunction f(a:Bool, b:Int):String {\n\t\treturn if (a) switch b {\n\t\t\tcase 0: \'zero\';\n'
			+ '\t\t\tcase _: \'other\';\n\t\t} else describe(b);\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, WIDTH8));
	}

	/** Without the width key the same sources are already stable: the cap alone was the difference. */
	public function testNoWidthKeyIsTheReference(): Void {
		Assert.equals(THEN_SWITCH, HxWriteFixture.triviaWrite(THEN_SWITCH, NO_WIDTH));
		Assert.equals(ELSE_SWITCH, HxWriteFixture.triviaWrite(ELSE_SWITCH, NO_WIDTH));
	}

}
