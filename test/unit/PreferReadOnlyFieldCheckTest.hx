package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferReadOnlyField;
import anyparse.check.PreferFinalPublicField;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-read-only-field` check: a PUBLIC `var` field written only inside its
 * declaring class is flagged `Info` and rewritten to `var X(default, null)`. A field
 * written externally, an unresolved-receiver write, a no-write field (that is
 * `prefer-final-public-field`'s job), a private field, a property, and a field whose
 * type has a subtype are all left alone.
 */
class PreferReadOnlyFieldCheckTest extends Test {

	public function testInternalBareWriteFlagged(): Void {
		final vs: Array<Violation> = violations('class C { public var x:Int = 0; function s():Void { x = 5; } }');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-read-only-field', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testInternalThisWriteFlagged(): Void {
		Assert.equals(1, violations('class C { public var x:Int = 0; function s():Void { this.x = 5; } }').length);
	}

	/** No write anywhere is `prefer-final-public-field`'s territory, not this one. */
	public function testNoWriteNotFlagged(): Void {
		Assert.equals(0, violations('class C { public var x:Int = 0; }').length);
	}

	/** A typed external write (`c.x = 9` where `c:C`) forbids making it read-only. */
	public function testExternalWriteNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { public var x:Int = 0; function s():Void { x = 1; } }' },
			{ file: 'W.hx', source: 'class W { public function poke(c:C):Void { c.x = 9; } }' }
		];
		Assert.equals(0, new PreferReadOnlyField().run(files, new HaxeQueryPlugin()).length);
	}

	/** An unresolved receiver write (`makeC().x = 7`) bails the field name — left alone. */
	public function testUnresolvedReceiverNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C { public var x:Int = 0; function s():Void { x = 1; } function p():Void { makeC().x = 7; } function makeC():C { return new C(); } }'
			).length
		);
	}

	public function testPrivateNotFlagged(): Void {
		Assert.equals(0, violations('class C { private var _x:Int = 0; function s():Void { _x = 1; } }').length);
	}

	/** A property (`var x(...)`) is already accessor-controlled — skipped. */
	public function testPropertyNotFlagged(): Void {
		Assert.equals(0, violations('class C { public var x(default, null):Int = 0; function s():Void { x = 1; } }').length);
	}

	/** A subtype could write the inherited field externally — left alone. */
	public function testSubtypeNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { public var x:Int = 0; function s():Void { x = 1; } }' },
			{ file: 'D.hx', source: 'class D extends C {}' }
		];
		Assert.equals(0, new PreferReadOnlyField().run(files, new HaxeQueryPlugin()).length);
	}

	public function testFixInsertsDefaultNull(): Void {
		final fixed: String = fixedSource('class C { public var x:Int = 0; function s():Void { x = 5; } }');
		Assert.isTrue(fixed.indexOf('public var x(default, null):Int = 0') >= 0);
	}

	/** The two public-field checks are disjoint: an internal-write field is read-only, not final. */
	public function testDisjointFromFinalPublic(): Void {
		final src: String = 'class C { public var x:Int = 0; function s():Void { x = 5; } }';
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.equals(0, new PreferFinalPublicField().run(files, plugin).length);
		Assert.equals(1, new PreferReadOnlyField().run(files, plugin).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-read-only-field'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-read-only-field'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { public var x = ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferReadOnlyField().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixedSource(src: String): String {
		final check: PreferReadOnlyField = new PreferReadOnlyField();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in sorted) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

	/** A field declared `var` by an interface must stay externally writable — `(default, null)` breaks the contract. */
	public function testInterfaceVarFieldNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'I.hx', source: 'interface I { public var x:Int; }' },
			{ file: 'C.hx', source: 'class C implements I { public var x:Int = 0; function s():Void { x = 1; } }' }
		];
		Assert.equals(0, new PreferReadOnlyField().run(files, new HaxeQueryPlugin()).length);
	}

}
