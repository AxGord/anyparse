package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnusedReturnValue;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `unused-return-value` check: a call whose PROVABLY non-`Void` result is
 * discarded in statement position (and is not the last statement of its block —
 * where the value might be the block / case / function result) is flagged `Info`.
 * Type-aware — the callee's return nominal, resolved through `TypeInfoProvider` /
 * `SymbolIndex`, is what tells a value-returning call from a `Void` one; an unknown
 * / `Void` / `Dynamic` return and an allowlisted mutator name are safe misses.
 * Report-only — `fix` yields no edits.
 */
class UnusedReturnValueTest extends Test {

	public function testStatementCallFlagged(): Void {
		final vs: Array<Violation> = violations('class C { function r():Int return 1; function m():Void { r(); return; } }');
		Assert.equals(1, vs.length);
		Assert.equals('unused-return-value', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('the Int result of r() is discarded — a possibly-lost value', vs[0].message);
	}

	public function testVoidCallNotFlagged(): Void {
		Assert.equals(0, violations('class C { function v():Void {} function m():Void { v(); return; } }').length);
	}

	public function testRhsNotFlagged(): Void {
		Assert.equals(0, violations('class C { function r():Int return 1; function m():Void { var x = r(); return; } }').length);
	}

	public function testArgumentNotFlagged(): Void {
		Assert.equals(
			0, violations('class C { function r():Int return 1; function g(a:Int):Void {} function m():Void { g(r()); return; } }').length
		);
	}

	public function testReturnedNotFlagged(): Void {
		Assert.equals(0, violations('class C { function r():Int return 1; function m():Int { return r(); } }').length);
	}

	public function testLastStatementNotFlagged(): Void {
		// The only statement of a non-`Void` body IS its return value — not a discard.
		Assert.equals(0, violations('class C { function r():Int return 1; function m():Int { r(); } }').length);
	}

	public function testSwitchCaseValueNotFlagged(): Void {
		// A call that is a `switch`-case body's last expression is the case VALUE.
		Assert.equals(
			0,
			violations('class C { function r():Int return 1; function m(x:Int):Int { return switch x { case 0: r(); case _: 0; }; } }').length
		);
	}

	public function testAllowlistedNotFlagged(): Void {
		Assert.equals(0, violations('class C { function push():Int return 1; function m():Void { push(); return; } }').length);
	}

	public function testUnknownReceiverTypeNotFlagged(): Void {
		// `Array` is not a project-indexed type — `indexOf`'s return is unknown.
		Assert.equals(0, violations('class C { function m(a:Array<Int>):Void { a.indexOf(1); return; } }').length);
	}

	public function testInstanceCallFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class D { function make():Int return 2; } class C { var d:D; function m():Void { d.make(); return; } }'
		);
		Assert.equals(1, vs.length);
		Assert.equals('the Int result of d.make() is discarded — a possibly-lost value', vs[0].message);
	}

	public function testThisCallFlagged(): Void {
		final vs: Array<Violation> = violations('class C { function r():Int return 1; function m():Void { this.r(); return; } }');
		Assert.equals(1, vs.length);
		Assert.equals('the Int result of this.r() is discarded — a possibly-lost value', vs[0].message);
	}

	public function testStaticCallFlagged(): Void {
		Assert.equals(
			1, violations('class H { static function make():Int return 1; } class C { function m():Void { H.make(); return; } }').length
		);
	}

	public function testLocalFunctionFlagged(): Void {
		Assert.equals(1, violations('class C { function m():Void { function h():Int return 3; h(); return; } }').length);
	}

	public function testDynamicReturnNotFlagged(): Void {
		Assert.equals(0, violations('class C { function d():Dynamic return null; function m():Void { d(); return; } }').length);
	}

	public function testNullReturnFlagged(): Void {
		// `Null<Int>` is a concrete non-`Void` value — a discarded find result.
		Assert.equals(1, violations('class C { function find():Null<Int> return null; function m():Void { find(); return; } }').length);
	}

	public function testUsingExtensionCallSkipped(): Void {
		// A `using` extension call is dispatched on a stdlib type (`String`) absent from
		// the project index, so its return is unknown — a safe miss, never a guess.
		Assert.equals(0, violations('using StringTools; class C { function m(s:String):Void { s.trim(); return; } }').length);
	}

	public function testCrossFileInstanceCallFlagged(): Void {
		final vs: Array<Violation> = violationsFiles([
			{ file: 'D.hx', source: 'class D { function make():Int return 2; }' },
			{ file: 'C.hx', source: 'class C { var d:D; function m():Void { d.make(); return; } }' }
		]);
		Assert.equals(1, vs.length);
		Assert.equals('C.hx', vs[0].file);
	}

	public function testConfigExtendsAllowlist(): Void {
		final src: String = 'class C { function make():Int return 1; function m():Void { make(); return; } }';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, violationsWithAllow(src, ['make']).length);
	}

	public function testFixYieldsNoEdits(): Void {
		final src: String = 'class C { function r():Int return 1; function m():Void { r(); return; } }';
		final check: UnusedReturnValue = new UnusedReturnValue();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('unused-return-value'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('unused-return-value'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { r();').length);
	}

	private function violations(src: String): Array<Violation> {
		return new UnusedReturnValue().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function violationsFiles(files: Array<{ file: String, source: String }>): Array<Violation> {
		return new UnusedReturnValue().run(files, new HaxeQueryPlugin());
	}

	private function violationsWithAllow(src: String, allow: Array<String>): Array<Violation> {
		final check: UnusedReturnValue = new UnusedReturnValue();
		final json: String = '{"rules":{"unused-return-value":{"allow":${haxe.Json.stringify(allow)}}}}';
		check.setConfigResolver(_ -> LintConfig.parse(json));
		return check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
