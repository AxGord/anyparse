package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferFinal;
import anyparse.check.PreferFinalField;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * A `var` of an `abstract` type mutated through a method that reassigns `this`
 * (`abstract Step(Int) { function next():Void this = this + 1; }` used only via
 * `_s.next()`) must NOT be rewritten to `final` — the finalized code fails to
 * compile ("Cannot modify abstract value of final field"). No visible assignment
 * to the binding exists, so the `prefer-final` / `prefer-final-field` writer scan
 * missed the mutation; a method call on an abstract-typed (or unprovable-type)
 * binding is the missing write signal.
 *
 * Control tests pin that the rule stays useful: a plain never-reassigned binding,
 * a field of a resolved CLASS type, and a field of a stdlib value type
 * (`String` / `Array` — their methods do not mutate `this`) are still flagged.
 */
class PreferFinalAbstractMethodCheckTest extends Test {

	static inline final ABSTRACT: String = 'abstract Step(Int) { public function nw(v:Int) this = v; public function next():Void this = this + 1; } ';

	// --- Field case (prefer-final-field) ---

	/** Abstract-typed field used only via a mutating method call — must NOT be flagged. */
	public function testAbstractFieldMethodCallNotFlagged(): Void {
		final vs: Array<Violation> = fieldViolations(ABSTRACT + 'class C { private var _s:Step = new Step(0); function r():Void _s.next(); }');
		Assert.equals(0, vs.length);
	}

	/** Control: a plain never-reassigned field still earns the final suggestion. */
	public function testPlainFieldStillFlagged(): Void {
		Assert.equals(1, fieldViolations('class C { private var _x:Int = 0; }').length);
	}

	/** Control: a field of a resolved CLASS type keeps the suggestion — a class method does not reassign the field. */
	public function testClassTypedFieldMethodCallStillFlagged(): Void {
		final vs: Array<Violation> = fieldViolations('class D { public function nw() {} public function go():Void {} } class C { private var _d:D = new D(); function r():Void _d.go(); }');
		Assert.equals(1, vs.length);
	}

	/** Control: a stdlib `Array` field keeps the suggestion — `push` mutates contents, not the `final` binding. */
	public function testStdlibArrayFieldMethodCallStillFlagged(): Void {
		Assert.equals(1, fieldViolations('class C { private var _a:Array<Int> = []; function r():Void _a.push(1); }').length);
	}

	/** Control: a stdlib `String` field keeps the suggestion — String is immutable. */
	public function testStdlibStringFieldMethodCallStillFlagged(): Void {
		Assert.equals(1, fieldViolations('class C { private var _t:String = "x"; function r():String return _t.toUpperCase(); }').length);
	}

	/** A field of an UNRESOLVED non-stdlib type with a method call is suppressed conservatively (cannot prove non-abstract). */
	public function testUnknownTypeFieldMethodCallNotFlagged(): Void {
		Assert.equals(0, fieldViolations('class C { private var _e:Ext = make(); function r():Void _e.mutate(); }').length);
	}

	/** A method REFERENCE (no call) on an abstract-typed field does not mutate — still flagged. */
	public function testAbstractFieldNoCallStillFlagged(): Void {
		Assert.equals(1, fieldViolations(ABSTRACT + 'class C { private var _s:Step = new Step(0); function r():Step->Void return null; }').length);
	}

	// --- Local case (prefer-final) ---

	/** Abstract-typed local used only via a mutating method call — must NOT be flagged. */
	public function testAbstractLocalMethodCallNotFlagged(): Void {
		final vs: Array<Violation> = localViolations(ABSTRACT + 'class C { function r():Void { var s:Step = new Step(0); s.next(); trace(s); } }');
		Assert.equals(0, vs.length);
	}

	/** Control: a plain never-reassigned local still earns the final suggestion. */
	public function testPlainLocalStillFlagged(): Void {
		Assert.equals(1, localViolations('class C { function r():Void { var n:Int = 5; trace(n); } }').length);
	}

	private function fieldViolations(src: String): Array<Violation> {
		return new PreferFinalField().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function localViolations(src: String): Array<Violation> {
		return new PreferFinal().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
