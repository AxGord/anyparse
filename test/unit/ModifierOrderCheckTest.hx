package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.ModifierOrder;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * The `modifier-order` check: a member whose modifier keywords are not in the
 * canonical order `override -> public/private -> static -> inline -> final` is
 * flagged `Info` and reordered by `--fix`. A method's `final` (folded into the
 * `FinalModifiedMember` wrapper) is ranked last; a field's `final` is the storage
 * keyword, not a modifier, and is never ranked. Modifiers with no documented order
 * (dynamic, …) are ignored and kept in place; the run resets per member.
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

	public function testFinalMethodBeforeInlineFlagged(): Void {
		final vs: Array<Violation> = violations('class C { final inline function f():Void {} }');
		Assert.equals(1, vs.length);
		Assert.equals('modifier-order', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testVisibilityBeforeFinalNotFlagged(): Void {
		Assert.equals(0, violations('class C { public final function f():Void {} }').length);
	}

	public function testFinalBeforeVisibilityFlagged(): Void {
		Assert.equals(1, violations('class C { final public function f():Void {} }').length);
	}

	public function testStaticFinalFieldNotFlagged(): Void {
		// `final` on a field is the immutable-storage keyword, not a rankable modifier; `static final` is canonical.
		Assert.equals(0, violations('class C { static final X = 1; }').length);
	}

	public function testPlainFinalFieldNotFlagged(): Void {
		Assert.equals(0, violations('class C { final X = 1; }').length);
	}

	public function testFullFinalChainNotFlagged(): Void {
		Assert.equals(0, violations('class C { override public static inline final function f():Void {} }').length);
	}

	public function testFinalMethodReorderedToLast(): Void {
		final fixed: String = fixedSource('class C { final inline function f():Void {} }');
		Assert.isTrue(fixed.indexOf('inline final function f') >= 0);
		Assert.equals(-1, fixed.indexOf('final inline function f'));
	}

	public function testFinalBeforeVisibilityFixed(): Void {
		final fixed: String = fixedSource('class C { final public function f():Void {} }');
		Assert.isTrue(fixed.indexOf('public final function f') >= 0);
		Assert.equals(-1, fixed.indexOf('final public function f'));
	}

	public function testScrambledFinalChainFixedToCanonical(): Void {
		final fixed: String = fixedSource('class C { final override public static inline function f():Void {} }');
		Assert.isTrue(fixed.indexOf('override public static inline final function f') >= 0);
	}

	/**
	 * B3: `--fix` reorders the method `final` to LAST, which empties the
	 * `FinalModifiedMember` inner modifier run — the exact shape that used to emit a
	 * double space (`final  function`) once the fix output is canonicalized by the
	 * writer round-trip. Assert the canonical form keeps a single space.
	 */
	public function testFixOutputCanonicalizesToSingleSpace(): Void {
		for (src in [
			'class C { final inline function f():Void {} }',
			'class C { final public function f():Void {} }',
			'class C { final override public static inline function f():Void {} }'
		]) {
			final fixed: String = fixedSource(src);
			final canonical: String = HxModuleWriter.write(HaxeModuleParser.parse(fixed));
			Assert.isTrue(canonical.indexOf('final function f') >= 0, 'single space expected in <$canonical>');
			Assert.equals(-1, canonical.indexOf('final  function'));
		}
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
