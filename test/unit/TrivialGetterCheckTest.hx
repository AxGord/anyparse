package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.TrivialGetter;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

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

	public function testFixIsReportOnly(): Void {
		final check: TrivialGetter = new TrivialGetter();
		final src: String = cls(
			'public var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;'
		);
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('trivial-getter'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('trivial-getter'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { public var active(get, never):Bool; function get_active() return _active;').length);
	}

	private function cls(members: String): String {
		return 'class C {\n\t' + members + '\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new TrivialGetter().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

}
