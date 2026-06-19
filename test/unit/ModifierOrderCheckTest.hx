package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.ModifierOrder;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `modifier-order` check: a member whose modifier keywords are not in the
 * canonical order `override -> public/private -> static -> inline` is flagged
 * `Info` and reordered by `--fix`. Modifiers with no documented order (dynamic, …)
 * are ignored and kept in place; the run resets per member.
 */
class ModifierOrderCheckTest extends Test {

	public function testCanonicalOrderNotFlagged(): Void {
		Assert.equals(0, violations('class C { override public static inline function f():Void {} }').length);
	}

	public function testStaticBeforeVisibilityFlagged(): Void {
		final vs: Array<Violation> = violations('class C { static public function f():Void {} }');
		Assert.equals(1, vs.length);
		Assert.equals('modifier-order', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testVisibilityBeforeOverrideFlagged(): Void {
		Assert.equals(1, violations('class C { public override function g():Void {} }').length);
	}

	public function testInlineBeforeStaticFlagged(): Void {
		Assert.equals(1, violations('class C { public inline static function h():Void {} }').length);
	}

	public function testSingleModifierNotFlagged(): Void {
		Assert.equals(0, violations('class C { public function f():Void {} }').length);
	}

	public function testUnrankedModifierIgnored(): Void {
		// `dynamic` carries no documented order; the only ranked modifier is `public`.
		Assert.equals(0, violations('class C { dynamic public function f():Void {} }').length);
	}

	public function testRunResetsPerMember(): Void {
		// Only the second method (static before public) is out of order.
		Assert.equals(1, violations('class C { public static function a():Void {} static public function b():Void {} }').length);
	}

	public function testFixReorders(): Void {
		final fixed: String = fixedSource('class C { static public function f():Void {} }');
		Assert.isTrue(fixed.indexOf('public static function f') >= 0);
		Assert.equals(-1, fixed.indexOf('static public function f'));
	}

	/** Only the ranked pair reorders; the unranked `dynamic` keeps its slot. */
	public function testFixKeepsUnrankedInPlace(): Void {
		final fixed: String = fixedSource('class C { static dynamic public function f():Void {} }');
		Assert.isTrue(fixed.indexOf('public dynamic static function f') >= 0);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('modifier-order'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('modifier-order'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new ModifierOrder().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixedSource(src: String): String {
		final check: ModifierOrder = new ModifierOrder();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in sorted) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
