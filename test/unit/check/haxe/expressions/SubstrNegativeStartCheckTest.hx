package unit.check.haxe.expressions;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Severity;
import anyparse.check.haxe.expressions.SubstrNegativeStart;

/**
 * The `substr-negative-start` check: a `substr` whose start is a subtraction is flagged `Warning`, report-only — a
 * negative result counts from the end of the string. A plain, a literal-negative or a length-slot subtraction,
 * `substring`, and a start the enclosing conditions bound below, are left alone.
 */
class SubstrNegativeStartCheckTest extends Test {

	public function testSubtractedStartFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('s.substr(n - 3, 2)'));
		Assert.equals(1, vs.length);
		Assert.equals('substr-negative-start', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals(1, violations(wrap('s.substr(s.length - n)')).length);
	}

	/** A literal negative start is the from-the-end reading on purpose; a subtraction in the length slot is not a start. */
	@:pin('control')
	@:killer('M-SUBSTR-ANY-START')
	public function testOtherStartsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('s.substr(n)')).length);
		Assert.equals(0, violations(wrap('s.substr(n + 1)')).length);
		Assert.equals(0, violations(wrap('s.substr(-3)')).length);
		Assert.equals(0, violations(wrap('s.substr(0, n - 3)')).length);
		Assert.equals(0, violations(wrap('s.substring(n - 3)')).length);
	}

	public function testNoFix(): Void {
		Assert.equals(0, CheckFixture.edits(new SubstrNegativeStart(), wrap('s.substr(n - 3, 2)')).length);
	}

	/** On by default: a guarded start is no longer a finding, so what stays flagged is a start nothing bounds. */
	public function testRegisteredDefaultOn(): Void {
		Assert.notNull(Linter.byId('substr-negative-start'));
		Assert.isFalse(Std.isOfType(new SubstrNegativeStart(), DefaultOff));
	}

	/** A start an enclosing condition bounds below by its subtrahend is proved non-negative and left alone. */
	@:pin('control')
	@:killer('M-ORDERGUARD-NO-PROOF')
	public function testGuardedStartsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('s.length > k ? s.substr(s.length - k) : s')).length);
		Assert.equals(0, violations(wrap('n >= k && s.substr(n - k) == t')).length);
		Assert.equals(0, violations(wrap('n < k || s.substr(n - k) == t')).length);
		Assert.equals(0, violations(wrap('!(n < k) && s.substr(n - k) == t')).length);
		Assert.equals(0, violations(wrap('n < 2 ? s : s.substr(n - 1)')).length);
		Assert.equals(0, violations(wrap('s.length > k + 1 ? s.substr(s.length - k - 1) : s')).length);
		Assert.equals(0, violations(body('for (cut in 1...n + 1) t = s.substr(n - cut);')).length);
		Assert.equals(0, violations(body('if (n < k) return; t = s.substr(n - k);')).length);
		Assert.equals(0, violations(body('if (n <= k) { t = s; return; } t = s.substr(n - k - 1);')).length);
	}

	/** A write in the guarded region to an operand of the bound voids it, whichever operand and wherever it sits. */
	@:pin('control')
	@:killer('M-ORDERGUARD-WRITES-IGNORED')
	public function testWrittenOperandVoidsTheBound(): Void {
		Assert.equals(1, violations(body('if (n < k) return; n -= 10; t = s.substr(n - k);')).length);
		Assert.equals(1, violations(body('if (n > k) { n = 0; t = s.substr(n - k); }')).length);
		Assert.equals(1, violations(body('if (n > k) { k++; t = s.substr(n - k); }')).length);
		Assert.equals(1, violations(body('for (cut in 1...n + 1) { n--; t = s.substr(n - cut); }')).length);
		Assert.equals(0, violations(body('if (n > k) { t = s.substr(n - k); }')).length);
	}

	/** An operand is the declaration it binds: a local of the guard's name is another operand. */
	@:pin('control')
	@:killer('M-ORDERGUARD-TEXT-ATOMS')
	public function testShadowingLocalIsAnotherOperand(): Void {
		Assert.equals(1, violations(body('if (n > k) { var n = 0; t = s.substr(n - k); }')).length);
	}

	/** A function literal runs after any write, so no bound above it reaches its body. */
	@:pin('control')
	@:killer('M-ORDERGUARD-NO-BARRIER')
	public function testFunctionLiteralIsABarrier(): Void {
		Assert.equals(1, violations(body('if (n > k) (() -> t = s.substr(n - k))();')).length);
		Assert.equals(1, violations(body('if (n > k) [1].map(n -> s.substr(n - k));')).length);
		Assert.equals(0, violations(body('[1].map(m -> m > k ? s.substr(m - k) : s);')).length);
	}

	/** A call in the guarded region may change a field, a static or a member read through a mutable receiver: the bound is void. */
	@:pin('control')
	@:killer('M-ORDERGUARD-CALLS-IGNORED')
	public function testCallVoidsABoundOverMutableStorage(): Void {
		Assert.equals(1, violations(members('if (this.n > k) { shrink(); t = s.substr(this.n - k); }')).length);
		Assert.equals(1, violations(members('if (n > k) { shrink(); t = s.substr(n - k); }')).length);
		Assert.equals(1, violations(members('if (m > k) { shrink(); t = s.substr(m - k); }')).length);
		Assert.equals(1, violations(members('if (C.m > k) { shrink(); t = s.substr(C.m - k); }')).length);
		Assert.equals(1, violations(members('if (o.v > k) { mutate(o); t = s.substr(o.v - k); }')).length);
		Assert.equals(1, violations(members('if (arr.length > k) { arr.pop(); t = s.substr(arr.length - k); }')).length);
		Assert.equals(0, violations(members('if (this.n > k) { t = s.substr(this.n - k); }')).length);
	}

	/** The condition that proved a bound runs after its comparison: a call or write there voids the bound as one in the region does. */
	@:pin('control')
	@:killer('M-ORDERGUARD-CAUSE-UNSCANNED')
	public function testChangeInTheProvingConditionVoidsTheBound(): Void {
		Assert.equals(1, violations(members('if (this.n >= k && this.consume()) trace(s.substr(this.n - k));')).length);
		Assert.equals(1, violations(members('if (this.n < k || !this.consume()) return; trace(s.substr(this.n - k));')).length);
		Assert.equals(1, violations(members('var b = this.n >= k && consume() && s.substr(this.n - k) == t;')).length);
		Assert.equals(1, violations(members('var q = 5; if (q >= k && (q -= 9) < 100) trace(s.substr(q - k));')).length);
		Assert.equals(0, violations(members('if (this.n >= k && s.length > 0) trace(s.substr(this.n - k));')).length);
	}

	/** A local is changed only by a write the region holds, so a call leaves a bound over locals standing. */
	@:pin('control')
	@:killer('M-ORDERGUARD-LOCALS-VOLATILE')
	public function testCallKeepsABoundOverLocals(): Void {
		Assert.equals(0, violations(members('if (k > 3) { shrink(); t = s.substr(k - 3); }')).length);
	}

	/** A string changes only by rebinding, so the length of a local string keeps its bound across a call. */
	@:pin('control')
	@:killer('M-ORDERGUARD-STRING-MUTABLE')
	public function testCallKeepsALocalStringLength(): Void {
		Assert.equals(0, violations(members('if (s.length > k) { trace(s); t = s.substr(s.length - k); }')).length);
	}

	/** A function literal writing a local is code a call runs: the local is storage a call changes. */
	@:pin('control')
	@:killer('M-ORDERGUARD-CAPTURE-IGNORED')
	public function testCapturedLocalVoidsTheBound(): Void {
		Assert.equals(1, violations(members('var q = 5; final dec = () -> q--; if (q > k) { dec(); t = s.substr(q - k); }')).length);
	}

	/** A local `function` statement writing the local is as much a callee that changes it as a lambda is. */
	public function testLocalFunctionWriteVoidsTheBound(): Void {
		Assert.equals(1, violations(members('var q = 5; function dec(): Void q--; if (q > k) { dec(); t = s.substr(q - k); }')).length);
	}

	/** An effect-free std call changes nothing, so the bound stands. */
	@:pin('control')
	@:killer('M-ORDERGUARD-EFFECT-FREE-IGNORED')
	public function testEffectFreeCallKeepsTheBound(): Void {
		Assert.equals(0, violations(members('if (this.n > k) { s.indexOf(t); t = s.substr(this.n - k); }')).length);
	}

	/** A call inside a function literal of the region runs only when another call does. */
	@:pin('control')
	@:killer('M-ORDERGUARD-DEFERRED-CALLS-RUN')
	public function testCallInsideFunctionLiteralKeepsTheBound(): Void {
		Assert.equals(0, violations(members('if (this.n > k) { final g = () -> shrink(); t = s.substr(this.n - k); }')).length);
	}

	/** The receiver's own `length - 1` is negative only on an empty string, where `substr` returns it empty anyway. */
	public function testLastCharacterStartNotFlagged(): Void {
		Assert.equals(0, violations(wrap('s.substr(s.length - 1)')).length);
		Assert.equals(1, violations(wrap('t.substr(s.length - 1)')).length);
		Assert.equals(1, violations(wrap('s.substr(s.length - 2)')).length);
	}

	/** A bound on the other side of the condition, or one too weak by a unit, proves nothing. */
	@:pin('control')
	@:killer('M-ORDERGUARD-ELSE-AS-THEN')
	public function testUnprovedStartsFlagged(): Void {
		Assert.equals(1, violations(wrap('s.length > k ? s : s.substr(s.length - k)')).length);
		Assert.equals(1, violations(wrap('n < k && s.substr(n - k) == t')).length);
		Assert.equals(1, violations(wrap('n >= k || s.substr(n - k) == t')).length);
		Assert.equals(1, violations(wrap('n >= k ? s.substr(n - k - 1) : s')).length);
		Assert.equals(1, violations(body('for (cut in 0...n + 2) t = s.substr(n - cut);')).length);
		Assert.equals(1, violations(body('if (n < k) t = s; t = s.substr(n - k);')).length);
		Assert.equals(1, violations(body('while (n > k) t = s.substr(n - k);')).length);
	}

	private function wrap(expr: String): String {
		return body('var x = $expr;');
	}

	private function body(statements: String): String {
		return 'class C {\n\tfunction f(s:String, t:String, n:Int, k:Int):Void {\n\t\t$statements\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new SubstrNegativeStart(), src);
	}

	private function members(statements: String): String {
		return 'class C {\n\tvar n:Int;\n\tstatic var m:Int;\n\tfunction shrink():Void {}\n\tfunction mutate(o:{v:Int}):Void {}\n'
			+ '\tfunction consume():Bool return true;\n\tfunction f(s:String, t:String, k:Int, o:{v:Int}, arr:Array<Int>):Void {\n\t\t'
			+ '$statements\n\t}\n}';
	}

}
