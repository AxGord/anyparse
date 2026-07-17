package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.RedundantThis;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `redundant-this` check must not strip `this.` from a `using` static-extension
 * call. With `using Type;` / `using Reflect;` a call like `this.getClass()` resolves
 * via STATIC EXTENSION — the bare name is NOT a member of the enclosing type, so
 * dropping the receiver produces an `Unknown identifier` compile error.
 *
 * The conservative gate: only flag a `this.name` whose `name` is a locally-declared
 * member (field / method / property) of the enclosing type. A name absent from the
 * type's own members may be an extension call OR an inherited member — either way
 * the check stays silent (never removes a load-bearing `this.`).
 */
class RedundantThisUsingExtensionTest extends Test {

	// (1) A `using`-extension call `this.ext()` must NOT be flagged: `getClass` is not
	// a member of `Widget`, so `this.` is load-bearing (resolves via `using Type`).
	public function testUsingExtensionCallNotFlagged(): Void {
		Assert.equals(0, violations('using Type; class Widget { function m():Class<Dynamic> { return this.getClass(); } }').length);
	}

	// (1b) Same, with an `extends` clause and a second stdlib extension module.
	public function testUsingExtensionCallWithExtendsNotFlagged(): Void {
		Assert.equals(0, violations('using Reflect; class Widget extends Base { function m():Void { this.setField("a", 1); } }').length);
	}

	// The fix must LEAVE the receiver on an extension call — stripping it breaks compile.
	public function testUsingExtensionFixLeavesReceiver(): Void {
		final src: String = 'using Type; class Widget { function m():Class<Dynamic> { return this.getClass(); } }';
		final out: String = applyFix(src);
		Assert.isTrue(out.indexOf('this.getClass()') != -1, 'this.getClass() must survive, got: $out');
	}

	// A name not declared in this type but reachable via `extends` is AMBIGUOUS
	// (inherited member OR extension) — the conservative gate stays silent.
	public function testInheritedMemberAmbiguityNotFlagged(): Void {
		Assert.equals(0, violations('class Widget extends Base { function m():Int { return this.inherited(); } }').length);
	}

	// (2) A genuine member in a no-extends class is STILL flagged — the rule stays useful.
	public function testGenuineMemberStillFlagged(): Void {
		Assert.equals(1, violations('class Widget { function own():Void {} function m():Void { this.own(); } }').length);
	}

	// The gate is membership-based, NOT "bail whenever a `using` is present": a real
	// member field is flagged even with `using Type;` in the file.
	public function testMemberFlaggedEvenWithUsingPresent(): Void {
		Assert.equals(1, violations('using Type; class Widget { var f:Int; function m():Int { return this.f; } }').length);
	}

	// A member declared inside a `#if … #end` conditional is still recognised as a
	// member (collection descends the conditional wrapper), so `this.g` is flagged.
	public function testConditionalMemberStillFlagged(): Void {
		Assert.equals(1, violations('class Widget { #if debug var g:Int; #end function m():Void { trace(this.g); } }').length);
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantThis().run([{ file: 'Widget.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: RedundantThis = new RedundantThis();
		final vs: Array<Violation> = check.run([{ file: 'Widget.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		edits.sort((a, b) -> b.span.from - a.span.from);
		var result: String = src;
		for (e in edits) result = result.substring(0, e.span.from) + e.text + result.substring(e.span.to);
		return result;
	}

}
