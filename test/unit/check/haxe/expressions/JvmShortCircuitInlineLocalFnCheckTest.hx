package unit.check.haxe.expressions;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Severity;
import anyparse.check.haxe.expressions.JvmShortCircuitInlineLocalFn;

/**
 * The `jvm-short-circuit-inline-local-fn` check: Haxe's JVM backend emits an invalid stack map for a local inline function
 * whose body holds an object literal when it is called in the right operand of a short-circuit `||` / `&&`; js is fine.
 * The call is flagged `Warning`, report-only; every other placement or kind of function is left alone.
 */
class JvmShortCircuitInlineLocalFnCheckTest extends Test {

	public function testInlineCallInShortCircuitOperandFlagged(): Void {
		final vs: Array<Violation> = violations(source('if (c || fits(w - rf(col, true), 1)) r = 1;'));
		Assert.equals(1, vs.length);
		Assert.equals('jvm-short-circuit-inline-local-fn', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals(1, violations(source('if (c && fits(w - rf(col, true), 1)) r = 1;')).length);
		Assert.equals(1, violations(source('r = c || fits(w - rf(col, true), 1) ? 1 : 2;')).length);
		Assert.equals(1, violations(source('if (c || (col > 1 && fits(w - rf(col, true), 1))) r = 1;')).length);
	}

	/** Only the right operand runs conditionally, and a call outside any short-circuit is not the shape. */
	@:pin('control')
	@:killer('M-JVMSC-ANY-PLACE')
	public function testOtherPlacesNotFlagged(): Void {
		Assert.equals(0, violations(source('if (fits(w - rf(col, true), 1) || c) r = 1;')).length);
		Assert.equals(0, violations(source('if (fits(w - rf(col, true), 1)) r = 1;')).length);
		Assert.equals(0, violations(source('final q = rf(col, true); if (c || fits(w - q, 1)) r = 1;')).length);
	}

	/** The miscompiled expansion needs the object literal in the inline body, and the callee must be that local function. */
	@:pin('control')
	@:killer('M-JVMSC-ANY-CALLEE')
	public function testOtherCalleesNotFlagged(): Void {
		Assert.equals(0, violations(source('if (c || fits(w - plain(col), 1)) r = 1;')).length);
		Assert.equals(0, violations(source('if (c || fits(w - other(col), 1)) r = 1;')).length);
		Assert.equals(0, violations(source('if (c || fits(w - rw(col, null), 1)) r = 1;')).length);
	}

	@:pin('control')
	@:killer('M-JVMSC-ANY-INLINE')
	public function testInlineWithoutLiteralNotFlagged(): Void {
		Assert.equals(
			0, violations(source('inline function bare(x:Int):Int return x + 1; if (c || fits(w - bare(col), 1)) r = 1;')).length
		);
	}

	/** A function literal is its own method: the call in its body is not on the short-circuit's stack frame. */
	@:pin('control')
	@:killer('M-JVMSC-LAMBDA-BODY-IN-OPERAND')
	public function testCallInsideFunctionLiteralNotFlagged(): Void {
		Assert.equals(0, violations(source('if (c || Lambda.exists([1], v -> fits(w - rf(v, true), 1))) r = 1;')).length);
		Assert.equals(1, violations(source('if (c || Lambda.exists([1], v -> v > 0 || fits(w - rf(v, true), 1))) r = 1;')).length);
	}

	/** `??` is not a miscompiled short-circuit: its right operand with the inline call compiles and runs on jvm. */
	@:pin('control')
	@:killer('M-JVMSC-NULL-COALESCE-OPERAND')
	public function testNullCoalesceOperandNotFlagged(): Void {
		Assert.equals(0, violations(source('if ((c ?? (w - rf(col, true))) > 1) r = 1;')).length);
	}

	public function testNoFix(): Void {
		Assert.equals(
			0, CheckFixture.edits(new JvmShortCircuitInlineLocalFn(), source('if (c || fits(w - rf(col, true), 1)) r = 1;')).length
		);
	}

	public function testRegisteredDefaultOn(): Void {
		Assert.notNull(Linter.byId('jvm-short-circuit-inline-local-fn'));
		Assert.isFalse(Std.isOfType(new JvmShortCircuitInlineLocalFn(), DefaultOff));
	}

	private function source(statements: String): String {
		return 'class C {\n\tstatic function rw(n:Int, o:Null<{col:Int, f:Bool}>):Int return n;\n'
			+ '\tstatic function fits(n:Int, d:Int):Bool return n > d;\n\tstatic function plain(n:Int):Int return n;\n'
			+ '\tstatic function p(c:Bool, col:Int, w:Int):Int {\n\t\tvar r = 0;\n'
			+ '\t\tinline function rf(x:Int, z:Bool):Int return rw(x, {col: x, f: z});\n\t\t$statements\n\t\treturn r;\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new JvmShortCircuitInlineLocalFn(), src);
	}

}
