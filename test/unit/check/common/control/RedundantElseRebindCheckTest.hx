package unit.check.common.control;

import anyparse.check.Check.FixEdit;
import anyparse.check.common.control.RedundantElse;

/**
 * `redundant-else-after-return --fix` and the names a de-nested else body would capture: a local the
 * body declares lands in the enclosing frame, so a LATER bare read of the same spelling — a field, a
 * free name, or whatever a splice expands to — would silently bind to it. The fix is withheld then.
 */
class RedundantElseRebindCheckTest extends Test {

	/** The field `t` read after the `if` would rebind to the else body's local `t`: the program changes and still compiles. */
	@:pin('control')
	@:killer('M-REDUNDANT-ELSE-CAPTURE-BLIND')
	public function testLaterFieldReadKeepsTheElse(): Void {
		final src: String = 'class C {\n\tvar t:Int = 0;\n\n\tfunction f(c:Bool):Int {\n\t\tif (c)\n\t\t\treturn 1;\n\t\telse {\n'
			+ '\t\t\tvar t = 2;\n\t\t\tfoo(t);\n\t\t}\n\t\treturn t;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	/** A later read of a name the else body does not declare is untouched by the de-nest. */
	@:pin('control')
	@:killer('M-REDUNDANT-ELSE-CAPTURE-ALWAYS')
	public function testLaterReadOfAnotherNameStillDeNests(): Void {
		final src: String = 'class C {\n\tvar u:Int = 0;\n\n\tfunction f(c:Bool):Int {\n\t\tif (c)\n\t\t\treturn 1;\n\t\telse {\n'
			+ '\t\t\tvar t = 2;\n\t\t\tfoo(t);\n\t\t}\n\t\treturn u;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(1, edits(src).length);
	}

	/** The same local with nothing reading its name afterwards de-nests. */
	@:pin('control')
	@:killer('M-REDUNDANT-ELSE-CAPTURE-ALWAYS')
	public function testLocalWithNoLaterReadStillDeNests(): Void {
		final src: String = 'class C {\n\tvar t:Int = 0;\n\n\tfunction f(c:Bool):Int {\n\t\tif (c)\n\t\t\treturn 1;\n\t\telse {\n'
			+ '\t\t\tvar t = 2;\n\t\t\tfoo(t);\n\t\t}\n\t\treturn 0;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(1, edits(src).length);
	}

	/** A later read inside a function whose parameter is the local's name reads that parameter, so the de-nest stays. */
	@:pin('guard')
	public function testLaterReadShadowedByAnInnerFunctionParameterStillDeNests(): Void {
		final src: String = 'class C {\n\tvar t:Int = 0;\n\n\tfunction f(c:Bool):Int {\n\t\tif (c)\n\t\t\treturn 1;\n\t\telse {\n'
			+ '\t\t\tvar t = 2;\n\t\t\tfoo(t);\n\t\t}\n\t\treturn bar(function(t:Int) return t);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(1, edits(src).length);
	}

	/** A splice nested in a later call argument may expand to a read of any name: with a local in the else body the fix is withheld. */
	@:pin('control')
	@:killer('M-REDUNDANT-ELSE-CAPTURE-BLIND')
	public function testLaterSpliceInACallKeepsTheElse(): Void {
		final src: String = 'class C {\n\tfunction f(x:Expr, c:Bool):Expr {\n\t\treturn macro {\n\t\t\tif (c)\n\t\t\t\treturn 1;\n'
			+ '\t\t\telse {\n\t\t\t\tvar t = 2;\n\t\t\t\tfoo(t);\n\t\t\t}\n\t\t\tbar($$x);\n\t\t};\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	/** The same inside a loop body, the splice being a call's callee. */
	@:pin('control')
	@:killer('M-REDUNDANT-ELSE-CAPTURE-BLIND')
	public function testLaterSpliceAsCalleeKeepsTheElse(): Void {
		final src: String = 'class C {\n\tfunction f(c:Bool):Expr {\n\t\treturn macro {\n\t\t\twhile (c) {\n\t\t\t\tif (c)\n'
			+ '\t\t\t\t\tcontinue;\n\t\t\t\telse {\n\t\t\t\t\tvar t = 2;\n\t\t\t\t\tfoo(t);\n\t\t\t\t}\n'
			+ '\t\t\t\t$$i{"foo"}();\n\t\t\t}\n\t\t};\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	/** Without a local in the else body a later splice captures nothing, so it does not hold the fix back. */
	@:pin('control')
	@:killer('M-REDUNDANT-ELSE-CAPTURE-ALWAYS')
	public function testLaterSpliceWithoutLocalStillDeNests(): Void {
		final src: String = 'class C {\n\tfunction f(x:Expr, c:Bool):Expr {\n\t\treturn macro {\n\t\t\tif (c)\n\t\t\t\treturn 1;\n'
			+ '\t\t\telse {\n\t\t\t\tfoo();\n\t\t\t}\n\t\t\tbar($$x);\n\t\t};\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(1, edits(src).length);
	}

	/** A conditional region opens no scope: the lifted local lands beside what follows its `#end` and would capture that read of `t`. */
	@:pin('control')
	@:killer('M-TAIL-FRAME-REGION-BLIND')
	public function testReadAfterTheRegionKeepsTheElse(): Void {
		final src: String = 'class C {\n\tvar t:Int = 0;\n\n\tfunction f(c:Bool):Int {\n\t\t#if debug\n\t\tif (c)\n\t\t\treturn 1;\n'
			+ '\t\telse {\n\t\t\tvar t = 2;\n\t\t\tfoo(t);\n\t\t}\n\t\t#end\n\t\treturn t;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	/** The same region with a later read of another name lifts as before. */
	@:pin('control')
	@:killer('M-REDUNDANT-ELSE-CAPTURE-ALWAYS')
	public function testOtherReadAfterTheRegionStillDeNests(): Void {
		final src: String = 'class C {\n\tvar u:Int = 0;\n\n\tfunction f(c:Bool):Int {\n\t\t#if debug\n\t\tif (c)\n\t\t\treturn 1;\n'
			+ '\t\telse {\n\t\t\tvar t = 2;\n\t\t\tfoo(t);\n\t\t}\n\t\t#end\n\t\treturn u;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(1, edits(src).length);
	}

	/** Regions nest: a read after both `#end`s follows the lifted local, so statements after every enclosing region count. */
	@:pin('control')
	@:killer('M-TAIL-FRAME-OUTER-DROPPED')
	public function testReadAfterAnInnerRegionInsideAnOuterOneKeepsTheElse(): Void {
		final src: String = 'class C {\n\tvar t:Int = 0;\n\n\tfunction f(c:Bool):Int {\n\t\t#if a\n\t\t#if b\n\t\tif (c)\n\t\t\treturn 1;\n'
			+ '\t\telse {\n\t\t\tvar t = 2;\n\t\t\tfoo(t);\n\t\t}\n\t\t#end\n\t\t#end\n\t\treturn t;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new RedundantElse(), src);
	}

	private function edits(src: String): Array<FixEdit> {
		return CheckFixture.edits(new RedundantElse(), src);
	}

}
