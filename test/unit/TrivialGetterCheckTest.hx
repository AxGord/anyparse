package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.TrivialGetter;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;

/**
 * The `trivial-getter` check: a read-only property `var x(get, never)` /
 * `(get, null)` whose `get_x` body is exactly `return _backing;` (a bare ident
 * or `this._backing`) over a PRIVATE same-class field is flagged `Info`,
 * report-only. Soundness misses: a getter with any other logic, a custom `set`
 * or `default` write slot, a `dynamic` getter, a public backing field, a
 * custom-named read accessor, an interface property, an inherited / other-class
 * field. It keys on triviality, not the `_` naming convention. `final class`
 * bodies (`ClassForm`) are covered.
 */
class TrivialGetterCheckTest extends Test {

	public function testBasicBlockBodyFlagged(): Void {
		final vs: Array<Violation> = violations(
			cls(
				'public var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tprivate function get_active():Bool { return _active; }'
			)
		);
		Assert.equals(1, vs.length);
		Assert.equals('trivial-getter', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(
			'property \'active\' has a trivial getter returning backing field \'_active\'; use \'var active(default, null)\' and remove get_active',
			vs[0].message
		);
	}

	public function testExpressionBodyFlagged(): Void {
		Assert.equals(
			1,
			violations(
				cls(
					'public var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tprivate inline function get_active():Bool return _active;'
				)
			).length
		);
	}

	public function testThisAccessFlagged(): Void {
		Assert.equals(
			1,
			violations(
				cls(
					'public var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool { return this._active; }'
				)
			).length
		);
	}

	public function testGetNullFlagged(): Void {
		Assert.equals(
			1,
			violations(
				cls('public var active(get, null):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;')
			).length
		);
	}

	public function testFinalClassFlagged(): Void {
		final src: String = 'final class C {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testDifferentFieldNameStillFlagged(): Void {
		Assert.equals(
			1,
			violations(
				cls(
					'public var active(get, never):Bool;\n\tprivate var backing:Bool = false;\n\tfunction get_active():Bool return backing;'
				)
			).length
		);
	}

	public function testGetterWithLogicNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				cls('public var active(get, never):Bool;\n\tprivate var _count:Int = 0;\n\tfunction get_active():Bool return _count > 0;')
			).length
		);
	}

	public function testExtraStatementNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				cls(
					'public var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool { trace(\'x\'); return _active; }'
				)
			).length
		);
	}

	public function testCustomSetterNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				cls(
					'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n\tfunction set_active(v:Bool):Bool return _active = v;'
				)
			).length
		);
	}

	public function testDefaultNullNotFlagged(): Void {
		Assert.equals(0, violations(cls('public var active(default, null):Bool = false;')).length);
	}

	public function testDynamicGetterNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				cls(
					'public var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tdynamic function get_active():Bool return _active;'
				)
			).length
		);
	}

	public function testPublicBackingNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				cls('public var active(get, never):Bool;\n\tpublic var _active:Bool = false;\n\tfunction get_active():Bool return _active;')
			).length
		);
	}

	public function testCustomAccessorNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				cls(
					'public var active(myGet, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction myGet_active():Bool return _active;'
				)
			).length
		);
	}

	public function testInterfacePropertyNotFlagged(): Void {
		Assert.equals(0, violations('interface I {\n\tpublic var active(get, never):Bool;\n}').length);
	}

	public function testNoGetterInClassNotFlagged(): Void {
		Assert.equals(0, violations(cls('public var active(get, never):Bool;\n\tprivate var _active:Bool = false;')).length);
	}

	public function testFixConvertsToDefaultNull(): Void {
		assertFixCanonical(
			cls('public var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;'),
			'public var active(default, null):Bool = false;', '_active'
		);
	}

	public function testFixRenamesThisAndBareRefs(): Void {
		final src: String = 'class C {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tpublic function new() { _active = true; }\n\tfunction get_active():Bool return _active;\n\tfunction toggle():Void { this._active = !_active; }\n}';
		assertFixCanonical(src, 'this.active = !active', '_active');
	}

	public function testFixRefusesOtherReceiverAccess(): Void {
		final src: String = 'class C {\n\tpublic var name(get, null):String;\n\tprivate var _name:String;\n\tpublic function new(n:String) { _name = n; }\n\tfunction get_name():String return _name;\n\tfunction other(c:C):String { return c._name; }\n}';
		assertFixRefused(src);
	}

	public function testFixRefusesLocalShadow(): Void {
		final src: String = 'class C {\n\tpublic var tag(get, never):Int;\n\tprivate var _tag:Int = 0;\n\tfunction get_tag():Int return _tag;\n\tfunction loc():Void { var _tag = 9; trace(_tag); }\n}';
		assertFixRefused(src);
	}

	public function testFixRefusesMultiVarShadow(): Void {
		// The grammar keeps only the FIRST name of a multi-var declaration, so a shadowing
		// second `_tag` is invisible as a node — the fix must refuse on the hidden slot.
		final src: String = 'class C {\n\tpublic var tag(get, never):Int;\n\tprivate var _tag:Int = 0;\n\tfunction get_tag():Int return _tag;\n\tfunction m():Void {\n\t\tvar a = 1, _tag = 2;\n\t\ttrace(_tag);\n\t}\n}';
		assertFixRefused(src);
	}

	public function testFixRefusesKeyValueForShadow(): Void {
		// The grammar keeps only the KEY name of a key-value for header, so a shadowing
		// value variable `_tag` is invisible as a node — the fix must refuse on the header.
		final src: String = 'class C {\n\tpublic var tag(get, never):Int;\n\tprivate var _tag:Int = 0;\n\tfunction get_tag():Int return _tag;\n\tfunction m(mp:Map<Int, Int>):Void {\n\t\tfor (k => _tag in mp) trace(_tag);\n\t}\n}';
		assertFixRefused(src);
	}

	public function testFixRefusesCasePatternCapture(): Void {
		final src: String = 'class C {\n\tpublic var kind(get, never):Int;\n\tprivate var _kind:Int = 1;\n\tfunction get_kind():Int return _kind;\n\tfunction m(x:Any):Void { switch x { case _kind: trace(_kind); case _: trace(0); } }\n}';
		assertFixRefused(src);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('trivial-getter'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('trivial-getter'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { public var active(get, never):Bool; function get_active() return _active;').length);
	}

	public function testSubclassOverrideNotFlagged(): Void {
		// A subclass overriding get_active would break if the base property became
		// (default, null) with the getter dropped, so a class with any subtype is skipped.
		final source: String = 'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}\nclass Sub extends Base {\n\toverride function get_active():Bool return true;\n}';
		Assert.equals(0, violations(source).length);
	}

	// --- (a) interface-conformance gate: collapsing a public property to (default, null)
	// drops the physical get_x an implemented interface may require ("Field get_x needed
	// by I is missing"). Skip whenever the class implements anything and the property is
	// public, unless every implemented interface is resolvable in scope and provably lacks it.

	public function testInterfaceImplementerNotFlagged(): Void {
		// The interface `Toggleable` is not in the lint scope, so it cannot be proven to lack
		// `active` — the collapse could break a required `get_active`, so the property is skipped.
		final src: String = 'class C implements Toggleable {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testInterfaceDeclaringPropNotFlagged(): Void {
		// The interface is resolvable AND declares `active(get, never)`, so the class MUST keep a
		// physical `get_active` — the collapse is unsafe and the property is skipped.
		final files: Array<{ file: String, source: String }> = [
			{ file: 'Toggle.hx', source: 'interface Toggle {\n\tpublic var active(get, never):Bool;\n}' },
			{
				file: 'C.hx',
				source: 'class C implements Toggle {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}'
			}
		];
		Assert.equals(0, new TrivialGetter().run(files, new HaxeQueryPlugin()).length);
	}

	public function testInterfaceLackingPropStillFlagged(): Void {
		// The interface is resolvable and provably LACKS `active`, so the collapse is safe.
		final files: Array<{ file: String, source: String }> = [
			{ file: 'Named.hx', source: 'interface Named {\n\tpublic var label(get, never):String;\n}' },
			{
				file: 'C.hx',
				source: 'class C implements Named {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}'
			}
		];
		Assert.equals(1, new TrivialGetter().run(files, new HaxeQueryPlugin()).length);
	}

	public function testPrivatePropInImplementerStillFlagged(): Void {
		// A PRIVATE property is not exposed through the interface, so `implements` is irrelevant.
		final src: String = 'class C implements Toggleable {\n\tprivate var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testFixProceedsWhenInterfaceLacksProp(): Void {
		final classSrc: String = 'class C implements Named {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'Named.hx', source: 'interface Named {\n\tpublic var label(get, never):String;\n}' },
			{ file: 'C.hx', source: classSrc }
		];
		final check: TrivialGetter = new TrivialGetter();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		Assert.isTrue(check.fix(classSrc, vs, new HaxeQueryPlugin(), index).length > 0);
	}

	// --- (b) shadowed-property rewrite: renaming the backing field `_x` to the property `x`
	// inside a function that binds a parameter / local also named `x` would rewrite `_x = x`
	// into the self-assignment `x = x` (the param wins resolution — silent data loss). The
	// backing-field write must be qualified as `this.x` when the enclosing function shadows `x`.

	public function testFixShadowedParamUsesThis(): Void {
		final src: String = 'class C {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool;\n\tpublic function new(active:Bool) { _active = active; }\n\tfunction get_active():Bool return _active;\n}';
		assertFixContains(src, 'this.active = active');
	}

	public function testFixShadowedLocalUsesThis(): Void {
		final src: String = 'class C {\n\tpublic var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n\tfunction bump():Void { var count = 5; _count = count; }\n}';
		assertFixContains(src, 'this.count = count');
	}

	private function cls(members: String): String {
		return 'class C {\n\t' + members + '\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new TrivialGetter().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function assertFixCanonical(src: String, present: String, absent: String): Void {
		final r = runAndExpectOne(src);
		switch RefactorSupport.canonicalize(src, r.check.fix(src, r.vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(present) >= 0);
				Assert.isTrue(text.indexOf(absent) == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function assertFixContains(src: String, present: String): Void {
		final r = runAndExpectOne(src);
		switch RefactorSupport.canonicalize(src, r.check.fix(src, r.vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(present) >= 0);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function assertFixRefused(src: String): Void {
		final r = runAndExpectOne(src);
		Assert.equals(0, r.check.fix(src, r.vs, new HaxeQueryPlugin()).length);
	}

	private function runAndExpectOne(src: String): { check: TrivialGetter, vs: Array<Violation> } {
		final check: TrivialGetter = new TrivialGetter();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		return { check: check, vs: vs };
	}

}
