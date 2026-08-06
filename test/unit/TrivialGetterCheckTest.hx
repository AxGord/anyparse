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
import anyparse.check.LintConfig;
import anyparse.runtime.Span;

/**
 * The `trivial-getter` check: a read-only property `var x(get, never)` /
 * `(get, null)` whose `get_x` body is exactly `return _backing;` (a bare ident
 * or `this._backing`) over a PRIVATE same-class field is flagged `Info`,
 * report-only. Soundness misses: a getter with any other logic, a custom `set`
 * or `default` write slot, a `dynamic` getter, a public backing field, a
 * custom-named read accessor, an interface property, an inherited / other-class
 * field. It keys on triviality, not the `_` naming convention. `final class`
 * bodies (`ClassForm`) are covered.
 *
 * The `(get, set)` shape-A collapse (trivial getter, non-trivial setter) is
 * decided three ways on the external statement-level writes to the backing
 * field: 0 writes collapses to `(default, set)` unchanged; 1..maxBypassWrites
 * writes collapses and marks each write `@:bypassAccessor` (default cap 3,
 * overridable via the `maxBypassWrites` option); more than the cap, or any write
 * nested inside a larger expression, falls back to marking `get_x` `inline`
 * (skipped when the getter is already `inline` or `override`).
 */
class TrivialGetterCheckTest extends Test {

	public function testBasicBlockBodyFlagged(): Void {
		final vs: Array<Violation> = violations(cls(
			'public var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tprivate function get_active():Bool { return _active; }'
		));
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
			violations(cls(
				'public var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tprivate inline function get_active():Bool return _active;'
			)).length
		);
	}

	public function testThisAccessFlagged(): Void {
		Assert.equals(
			1,
			violations(cls(
				'public var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool { return this._active; }'
			)).length
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
		final src: String =
			'final class C {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testDifferentFieldNameStillFlagged(): Void {
		Assert.equals(
			1,
			violations(cls(
				'public var active(get, never):Bool;\n\tprivate var backing:Bool = false;\n\tfunction get_active():Bool return backing;'
			)).length
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
			violations(cls(
				'public var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool { trace(\'x\'); return _active; }'
			)).length
		);
	}

	public function testDefaultNullNotFlagged(): Void {
		Assert.equals(0, violations(cls('public var active(default, null):Bool = false;')).length);
	}

	public function testDynamicGetterNotFlagged(): Void {
		Assert.equals(
			0,
			violations(cls(
				'public var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tdynamic function get_active():Bool return _active;'
			)).length
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
			violations(cls(
				'public var active(myGet, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction myGet_active():Bool return _active;'
			)).length
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
		final src: String =
			'class C {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tpublic function new() { _active = true; }\n\tfunction get_active():Bool return _active;\n\tfunction toggle():Void { this._active = !_active; }\n}';
		assertFixCanonical(src, 'this.active = !active', '_active');
	}

	public function testFixRefusesOtherReceiverAccess(): Void {
		final src: String =
			'class C {\n\tpublic var name(get, null):String;\n\tprivate var _name:String;\n\tpublic function new(n:String) { _name = n; }\n\tfunction get_name():String return _name;\n\tfunction other(c:C):String { return c._name; }\n}';
		assertFixRefused(src);
	}

	public function testFixRefusesLocalShadow(): Void {
		final src: String =
			'class C {\n\tpublic var tag(get, never):Int;\n\tprivate var _tag:Int = 0;\n\tfunction get_tag():Int return _tag;\n\tfunction loc():Void { var _tag = 9; trace(_tag); }\n}';
		assertFixRefused(src);
	}

	public function testFixRefusesMultiVarShadow(): Void {
		// The grammar keeps only the FIRST name of a multi-var declaration, so a shadowing
		// second `_tag` is invisible as a node — the fix must refuse on the hidden slot.
		final src: String =
			'class C {\n\tpublic var tag(get, never):Int;\n\tprivate var _tag:Int = 0;\n\tfunction get_tag():Int return _tag;\n\tfunction m():Void {\n\t\tvar a = 1, _tag = 2;\n\t\ttrace(_tag);\n\t}\n}';
		assertFixRefused(src);
	}

	public function testFixRefusesKeyValueForShadow(): Void {
		// The grammar keeps only the KEY name of a key-value for header, so a shadowing
		// value variable `_tag` is invisible as a node — the fix must refuse on the header.
		final src: String =
			'class C {\n\tpublic var tag(get, never):Int;\n\tprivate var _tag:Int = 0;\n\tfunction get_tag():Int return _tag;\n\tfunction m(mp:Map<Int, Int>):Void {\n\t\tfor (k => _tag in mp) trace(_tag);\n\t}\n}';
		assertFixRefused(src);
	}

	public function testFixRefusesCasePatternCapture(): Void {
		final src: String =
			'class C {\n\tpublic var kind(get, never):Int;\n\tprivate var _kind:Int = 1;\n\tfunction get_kind():Int return _kind;\n\tfunction m(x:Any):Void { switch x { case _kind: trace(_kind); case _: trace(0); } }\n}';
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
		final source: String =
			'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}\nclass Sub extends Base {\n\toverride function get_active():Bool return true;\n}';
		Assert.equals(0, violations(source).length);
	}

	// --- (a) interface-conformance gate: collapsing a public property to (default, null)
	// drops the physical get_x an implemented interface may require ("Field get_x needed
	// by I is missing"). Skip whenever the class implements anything and the property is
	// public, unless every implemented interface is resolvable in scope and provably lacks it.

	public function testInterfaceImplementerNotFlagged(): Void {
		// The interface `Toggleable` is not in the lint scope, so it cannot be proven to lack
		// `active` — the collapse could break a required `get_active`, so the property is skipped.
		final src: String =
			'class C implements Toggleable {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}';
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
		final src: String =
			'class C implements Toggleable {\n\tprivate var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testFixProceedsWhenInterfaceLacksProp(): Void {
		final classSrc: String =
			'class C implements Named {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}';
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
		final src: String =
			'class C {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool;\n\tpublic function new(active:Bool) { _active = active; }\n\tfunction get_active():Bool return _active;\n}';
		assertFixContains(src, 'this.active = active');
	}

	public function testFixShadowedLocalUsesThis(): Void {
		final src: String =
			'class C {\n\tpublic var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n\tfunction bump():Void { var count = 5; _count = count; }\n}';
		assertFixContains(src, 'this.count = count');
	}

	// --- (b2) the shadow scan must see EVERY binding form, not just parameters and plain
	// locals: a loop variable, a key-value loop's value slot, a comprehension variable, a
	// catch variable, a case-pattern capture, a multi-var continuation and a lambda
	// parameter all bind the PROPERTY name too, so a backing-field reference under them
	// must be qualified `this.x` (instance) / `C.x` (static) exactly as under a parameter.

	public function testFixShadowedLoopVarUsesThis(): Void {
		// The live ColorPickerSelector shape: `for (color in _palette) if (color == _color)`
		// renamed to `color == color` (always true) because the loop variable was invisible
		// to the shadow scan.
		final src: String = cls(
			'public var color(get, set):Int;\n\tprivate var _color:Int = 0;\n\tprivate var _palette:Array<Int> = [];\n\tfunction get_color():Int return _color;\n\tfunction set_color(v:Int):Int return _color = v;\n\tfunction upd():Void { for (color in _palette) if (color == _color) trace(color); }'
		);
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.indexOf('color == this.color') >= 0, 'loop-var shadow must qualify the field read');
		Assert.isTrue(fixed.indexOf('color == color') == -1, 'the always-true self-comparison must be gone');
	}

	public function testFixShadowedKeyValueForVarUsesThis(): Void {
		// The grammar keeps only the KEY name of a key-value for header, so a value slot named
		// like the property is invisible as a node — the header text must be scanned for it.
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n\tfunction m(mp:Map<Int, Int>):Void { for (k => count in mp) trace(k + count + _count); }'
		);
		assertFixContains(src, 'count + this.count');
	}

	public function testFixShadowedComprehensionVarUsesThis(): Void {
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tprivate var _items:Array<Int> = [];\n\tfunction get_count():Int return _count;\n\tfunction m():Void { var xs = [for (count in _items) count + _count]; trace(xs); }'
		);
		assertFixContains(src, 'count + this.count');
	}

	public function testFixShadowedCatchVarUsesThis(): Void {
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n\tfunction m():Void { try { risky(); } catch (count:Dynamic) { trace(count + _count); } }'
		);
		assertFixContains(src, 'count + this.count');
	}

	public function testFixShadowedCasePatternCaptureUsesThis(): Void {
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n\tfunction m(v:Any):Void { switch v { case count: trace(count + _count); } }'
		);
		assertFixContains(src, 'count + this.count');
	}

	public function testFixShadowedMultiVarContinuationUsesThis(): Void {
		// `var a = 1, count = 2;` — the continuation binding is a `VarMore` node, absent from
		// the old binder-kind list.
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n\tfunction m():Void { var a = 1, count = 2; trace(a + count + _count); }'
		);
		assertFixContains(src, 'count + this.count');
	}

	public function testFixShadowedThinArrowParamUsesThis(): Void {
		// A single-parameter thin arrow projects its parameter as a bare `IdentExpr`, not a
		// `Required` / `LambdaParam` node.
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n\tfunction m():Void { var f = count -> count + _count; trace(f(1)); }'
		);
		assertFixContains(src, 'count + this.count');
	}

	public function testFixShadowedLambdaParamUsesThis(): Void {
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n\tfunction m():Void { var f = (count:Int) -> count + _count; trace(f(1)); }'
		);
		assertFixContains(src, 'count + this.count');
	}

	public function testFixShadowedStaticLocalUsesThis(): Void {
		// A Haxe 4.3 `static var` local binds the name in the function like any other local.
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n\tfunction m():Void { static var count:Int = 5; trace(count + _count); }'
		);
		assertFixContains(src, 'count + this.count');
	}

	public function testFixShadowedLocalInlineFunctionUsesThis(): Void {
		// `inline function` is a distinct kind from a plain local function, and the project's own
		// Haxe style mandates it for local helpers.
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n\tfunction m():Void { inline function count():Int return 1; trace(count() + _count); }'
		);
		assertFixContains(src, '+ this.count');
	}

	public function testFixShadowedCaseVarCaptureUsesThis(): Void {
		// `case var x:` carries its binding on a `Capture` node — a direct child of the branch,
		// NOT inside the pattern subtree, so the pattern scan alone never sees it.
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n\tfunction m(v:Any):Void { switch v { case var count: trace(Std.string(count) + _count); } }'
		);
		assertFixContains(src, '+ this.count');
	}

	public function testFixRefusesKeyValueComprehensionFieldShadow(): Void {
		// The FIELD-name side of the same dropped slot: a comprehension whose key-value header
		// binds the BACKING FIELD name must refuse — renaming its reads would silently retarget
		// them at the property.
		final src: String =
			'class C {\n\tpublic var tag(get, never):Int;\n\tprivate var _tag:Int = 0;\n\tfunction get_tag():Int return _tag;\n\tfunction m(mp:Map<Int, Int>):Array<Int> {\n\t\treturn [for (k => _tag in mp) _tag + k];\n\t}\n}';
		assertFixRefused(src);
	}

	public function testFixStaticPropertyShadowUsesClassName(): Void {
		// A STATIC property cannot be reached through `this` — a shadowed reference must be
		// qualified with the class name even from an instance method.
		final src: String = cls(
			'public static var total(get, never):Int;\n\tprivate static var _total:Int = 0;\n\tstatic function get_total():Int return _total;\n\tfunction m():Void { for (total in [1, 2]) trace(total + _total); }'
		);
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.indexOf('total + C.total') >= 0, 'a static property must be class-qualified');
		Assert.isTrue(fixed.indexOf('this.total') == -1, 'a static property is not reachable through this');
	}

	public function testFixShapeCShadowedLoopVarUsesThis(): Void {
		// The sibling arm: a TRIVIAL SETTER collapse to (get, default) renames the backing-field
		// WRITE, which under a loop-variable shadow would become the self-assignment `x = x`.
		final src: String = cls(
			'public var x(get, set):Int;\n\tprivate var _x:Int = 0;\n\tprivate var _items:Array<Int> = [];\n\tfunction get_x():Int { redraw(); return _x; }\n\tfunction set_x(v:Int):Int return _x = v;\n\tfunction m():Void { for (x in _items) _x = x; }'
		);
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.indexOf('this.x = x') >= 0, 'a shadowed write target must be qualified');
		Assert.isTrue(fixed.indexOf('x(get, default)') >= 0);
	}

	public function testShapeATrivialGetterRealSetterFlagged(): Void {
		final vs: Array<Violation> = violations(cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }'
		));
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'active\' has a trivial getter over backing field \'_active\'; use \'var active(default, set)\' and remove get_active',
			vs[0].message
		);
	}

	public function testShapeAFixToDefaultSet(): Void {
		final fixed: String = fixedText(cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }'
		));
		Assert.isTrue(fixed.indexOf('active(default, set)') >= 0);
		Assert.isTrue(fixed.indexOf('= false') >= 0);
		Assert.isTrue(fixed.indexOf('return active = v') >= 0);
		Assert.isTrue(fixed.indexOf('get_active') == -1);
		Assert.isTrue(fixed.indexOf('private var _active') == -1);
	}

	public function testShapeAExternalWriteBypassFlagged(): Void {
		final vs: Array<Violation> = violations(cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n\tfunction reset():Void { _active = true; }'
		));
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'active\' has a trivial getter over backing field \'_active\'; use \'var active(default, set)\', remove get_active and mark 1 external write(s) with @:bypassAccessor',
			vs[0].message
		);
	}

	public function testShapeACtorInitMoveFlagged(): Void {
		final src: String =
			'class LicenseButton {\n\tpublic var disabled(get, set):Bool;\n\tprivate var _disabled:Bool;\n\tpublic function new() {\n\t\t_disabled = false;\n\t\tinit();\n\t}\n\tfunction get_disabled():Bool return _disabled;\n\tfunction set_disabled(v:Bool):Bool {\n\t\t_disabled = v;\n\t\talpha = v ? 0.5 : 1;\n\t\treturn _disabled;\n\t}\n}';
		Assert.equals(1, new TrivialGetter().run([{ file: 'LicenseButton.hx', source: src }], new HaxeQueryPlugin()).length);
	}

	public function testShapeACtorInitMoveFix(): Void {
		final src: String =
			'class LicenseButton {\n\tpublic var disabled(get, set):Bool;\n\tprivate var _disabled:Bool;\n\tpublic function new() {\n\t\t_disabled = false;\n\t\tinit();\n\t}\n\tfunction get_disabled():Bool return _disabled;\n\tfunction set_disabled(v:Bool):Bool {\n\t\t_disabled = v;\n\t\talpha = v ? 0.5 : 1;\n\t\treturn _disabled;\n\t}\n}';
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.indexOf('disabled(default, set):Bool = false') >= 0);
		Assert.isTrue(fixed.indexOf('return disabled;') >= 0);
		Assert.isTrue(fixed.indexOf('disabled = v') >= 0);
		Assert.isTrue(fixed.indexOf('get_disabled') == -1);
		Assert.isTrue(fixed.indexOf('private var _disabled') == -1);
		Assert.isTrue(fixed.indexOf('_disabled = false') == -1);
	}

	public function testShapeACtorInitNotMovableBypassFlagged(): Void {
		// `trace(_disabled)` reads the field before `_disabled = false`, so the init is not
		// relocatable; the write is marked @:bypassAccessor instead and the property collapses.
		final src: String =
			'class C {\n\tpublic var disabled(get, set):Bool;\n\tprivate var _disabled:Bool;\n\tpublic function new() {\n\t\ttrace(_disabled);\n\t\t_disabled = false;\n\t}\n\tfunction get_disabled():Bool return _disabled;\n\tfunction set_disabled(v:Bool):Bool { redraw(); return _disabled = v; }\n}';
		final vs: Array<Violation> = new TrivialGetter().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.indexOf('@:bypassAccessor disabled = false') >= 0);
		Assert.isTrue(fixed.indexOf('trace(disabled)') >= 0);
		Assert.isTrue(fixed.indexOf('get_disabled') == -1);
	}

	public function testBothTrivialCollapsesToPlainVar(): Void {
		final vs: Array<Violation> = violations(cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n\tfunction set_active(v:Bool):Bool return _active = v;'
		));
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'active\' has a trivial getter and setter over backing field \'_active\'; use a plain field \'var active\' and remove get_active/set_active',
			vs[0].message
		);
	}

	public function testBothTrivialFixToPlainVar(): Void {
		assertFixCanonical(
			cls(
				'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n\tfunction set_active(v:Bool):Bool return _active = v;'
			),
			'public var active:Bool = false', '_active'
		);
	}

	public function testShapeCTrivialSetterRealGetterFlagged(): Void {
		final vs: Array<Violation> = violations(cls(
			'public var count(get, set):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count + 1;\n\tfunction set_count(v:Int):Int return _count = v;'
		));
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'count\' has a trivial setter over backing field \'_count\'; use \'var count(get, default)\' and remove set_count',
			vs[0].message
		);
	}

	public function testShapeCFixToGetDefault(): Void {
		final fixed: String = fixedText(cls(
			'public var count(get, set):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count + 1;\n\tfunction set_count(v:Int):Int return _count = v;'
		));
		Assert.isTrue(fixed.indexOf('count(get, default):Int = 0') >= 0);
		Assert.isTrue(fixed.indexOf('return count + 1') >= 0);
		Assert.isTrue(fixed.indexOf('set_count') == -1);
		Assert.isTrue(fixed.indexOf('private var _count') == -1);
	}

	public function testShapeCExternalReadNotFlagged(): Void {
		// A read of _count outside get_count would newly route through the non-trivial getter
		// after conversion to (get, default), so the property is skipped.
		final src: String = cls(
			'public var count(get, set):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count + 1;\n\tfunction set_count(v:Int):Int return _count = v;\n\tfunction peek():Int { return _count; }'
		);
		Assert.equals(0, violations(src).length);
	}

	public function testShapeCCompoundAssignNotFlagged(): Void {
		// _count += 1 outside get_count READS _count (x += 1 compiles to x = get_count() + 1), so
		// it would newly route through the non-trivial getter — the property is skipped.
		final src: String = cls(
			'public var count(get, set):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count + 1;\n\tfunction set_count(v:Int):Int return _count = v;\n\tfunction bump():Void { _count += 1; }'
		);
		Assert.equals(0, violations(src).length);
	}

	public function testShapeCExternalPureWriteStillFlagged(): Void {
		// A pure write _count = 5 outside the accessors is a direct (default) write, not a read,
		// so it does not block the (get, default) collapse.
		final src: String = cls(
			'public var count(get, set):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count + 1;\n\tfunction set_count(v:Int):Int return _count = v;\n\tfunction reset():Void { _count = 5; }'
		);
		Assert.equals(1, violations(src).length);
	}

	public function testShapeABypassFix(): Void {
		final fixed: String = fixedText(cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n\tfunction reset():Void { _active = true; }'
		));
		Assert.isTrue(fixed.indexOf('@:bypassAccessor active = true') >= 0);
		Assert.isTrue(fixed.indexOf('active(default, set)') >= 0);
		Assert.isTrue(fixed.indexOf('get_active') == -1);
		Assert.isTrue(fixed.indexOf('private var _active') == -1);
	}

	public function testShapeABypassShadowedCtorWrite(): Void {
		final src: String = cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tpublic function new(?active:Bool) { _active = active ?? false; }\n\tfunction get_active():Bool return _active;\n\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }'
		);
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.indexOf('@:bypassAccessor this.active = active ?? false') >= 0);
		Assert.isTrue(fixed.indexOf('active(default, set):Bool = false') >= 0);
	}

	public function testShapeAExceedsCapInline(): Void {
		final src: String = cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n\tfunction a():Void { _active = true; }\n\tfunction b():Void { _active = false; }\n\tfunction c():Void { _active = true; }\n\tfunction d():Void { _active = false; }'
		);
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'active\' has a trivial getter over backing field \'_active\', but 4 external write(s) block a (default, set) collapse; mark get_active inline',
			vs[0].message
		);
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.indexOf('inline function get_active') >= 0);
		Assert.isTrue(fixed.indexOf('return _active') >= 0);
		Assert.isTrue(fixed.indexOf('private var _active') >= 0);
		Assert.isTrue(fixed.indexOf('(get, set)') >= 0);
	}

	public function testShapeANonStmtWriteInline(): Void {
		final src: String = cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n\tfunction f():Void { if ((_active = true)) trace(1); }'
		);
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'active\' has a trivial getter over backing field \'_active\', but 1 external write(s) block a (default, set) collapse; mark get_active inline',
			vs[0].message
		);
	}

	public function testShapeAAlreadyInlineGetterNotFlagged(): Void {
		final src: String = cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tinline function get_active():Bool return _active;\n\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n\tfunction a():Void { _active = true; }\n\tfunction b():Void { _active = false; }\n\tfunction c():Void { _active = true; }\n\tfunction d():Void { _active = false; }'
		);
		Assert.equals(0, violations(src).length);
	}

	public function testShapeAOverrideGetterNotFlagged(): Void {
		final src: String = cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\toverride function get_active():Bool return _active;\n\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n\tfunction a():Void { _active = true; }\n\tfunction b():Void { _active = false; }\n\tfunction c():Void { _active = true; }\n\tfunction d():Void { _active = false; }'
		);
		Assert.equals(0, violations(src).length);
	}

	public function testShapeACtorInitPlusBypass(): Void {
		final src: String =
			'class C {\n\tpublic var active(get, set):Bool;\n\tprivate var _active:Bool;\n\tpublic function new() {\n\t\t_active = false;\n\t\tinit();\n\t}\n\tfunction get_active():Bool return _active;\n\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n\tfunction reset():Void { _active = true; }\n}';
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.indexOf('active(default, set):Bool = false') >= 0);
		Assert.isTrue(fixed.indexOf('@:bypassAccessor active = true') >= 0);
		Assert.isTrue(fixed.indexOf('_active = false') == -1);
	}

	public function testShapeAConfigCapInline(): Void {
		final src: String = cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n\tfunction a():Void { _active = true; }\n\tfunction b():Void { _active = false; }'
		);
		final check: TrivialGetter = new TrivialGetter();
		final cfg: LintConfig = LintConfig.parse('{"rules": {"trivial-getter": {"maxBypassWrites": 1}}}');
		check.setConfigResolver(_ -> cfg);
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'active\' has a trivial getter over backing field \'_active\', but 2 external write(s) block a (default, set) collapse; mark get_active inline',
			vs[0].message
		);
	}

	public function testShapeAZeroWritesNoBypass(): Void {
		final src: String = cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }'
		);
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'active\' has a trivial getter over backing field \'_active\'; use \'var active(default, set)\' and remove get_active',
			vs[0].message
		);
		Assert.isTrue(fixedText(src).indexOf('@:bypassAccessor') == -1);
	}

	public function testShapeAExactlyCapBypass(): Void {
		// Exactly maxBypassWrites (default 3) statement-level writes sit ON the cap boundary
		// and still take the bypass arm — only cap + 1 falls back to the inline arm.
		final src: String = cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n\tfunction a():Void { _active = true; }\n\tfunction b():Void { _active = false; }\n\tfunction c():Void { _active = true; }'
		);
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'active\' has a trivial getter over backing field \'_active\'; use \'var active(default, set)\', remove get_active and mark 3 external write(s) with @:bypassAccessor',
			vs[0].message
		);
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.indexOf('@:bypassAccessor active = true') >= 0);
		Assert.isTrue(fixed.indexOf('active(default, set)') >= 0);
	}

	public function testShapeACompoundAssignBypass(): Void {
		// A compound assign (`_count += 1;`) is a statement-level WRITE (`writeTargetField`
		// covers it), so it takes the bypass arm; under `@:bypassAccessor` both its read and
		// write are direct — identical to the pre-collapse backing-field access.
		final src: String = cls(
			'public var count(get, set):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n\tfunction set_count(v:Int):Int { redraw(); return _count = v; }\n\tfunction bump():Void { _count += 1; }'
		);
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'count\' has a trivial getter over backing field \'_count\'; use \'var count(default, set)\', remove get_count and mark 1 external write(s) with @:bypassAccessor',
			vs[0].message
		);
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.indexOf('@:bypassAccessor count += 1') >= 0);
		Assert.isTrue(fixed.indexOf('count(default, set)') >= 0);
		Assert.isTrue(fixed.indexOf('get_count') == -1);
	}

	public function testShapeAStringInterpSimpleReadRenamed(): Void {
		// A simple `$_backing` string-interpolation READ of the backing field must be
		// renamed to `$prop` on a (get, set) -> (default, set) collapse — the property has
		// physical storage, so the interpolation reads it directly. Previously the simple
		// `$name` form (a bare `Ident` node, not `IdentExpr`) tripped the rename refusal.
		final src: String = cls(
			'public var sel(get, set):Int;\n\tprivate var _sel:Int = -1;\n\tfunction get_sel():Int return _sel;\n\tfunction set_sel(v:Int):Int { redraw(); return _sel = v; }\n\tfunction log():Void { trace(\'v=$$_sel\'); }'
		);
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.indexOf('sel(default, set)') >= 0);
		Assert.isTrue(fixed.indexOf('get_sel') == -1);
		Assert.isTrue(fixed.indexOf('v=$$sel') >= 0);
		Assert.isTrue(fixed.indexOf('v=$$_sel') == -1);
	}

	public function testShapeAStringInterpSimpleReadShadowedRefused(): Void {
		// When a local of the PROPERTY name shadows the field in a function, a simple
		// `$_backing` interpolation cannot be safely rewritten to `$prop` (a bare `$prop`
		// would bind the local, not the field, and the `$name` form admits no `this.`
		// qualifier) — the collapse is refused (conservative).
		final src: String = cls(
			'public var sel(get, set):Int;\n\tprivate var _sel:Int = -1;\n\tfunction get_sel():Int return _sel;\n\tfunction set_sel(v:Int):Int { redraw(); return _sel = v; }\n\tfunction log():Void { var sel = 3; trace(\'v=$$_sel\'); }'
		);
		assertFixRefused(src);
	}

	public function testShapeCStringInterpReadBlocksCollapse(): Void {
		// Shape C (non-trivial getter + trivial setter) would collapse to (get, default), but a
		// simple `$_backing` interpolation READ outside the getter would route through the
		// non-trivial getter after the collapse -- the read-gate must see the interpolation read
		// (it is a bare `Ident`, not `IdentExpr`) and skip the property.
		final src: String = cls(
			'public var x(get, set):Int;\n\tprivate var _x:Int = 0;\n\tfunction get_x():Int { redraw(); return _x; }\n\tfunction set_x(v:Int):Int return _x = v;\n\tfunction log():Void { trace(\'v=$$_x\'); }'
		);
		Assert.equals(0, violations(src).length);
	}

	public function testSubclassedNotOverriddenCollapses(): Void {
		// Sub extends Base but overrides NEITHER get_active/set_active nor redeclares `active`
		// (the DarkDropDownListItem shape), so dropping get_active strands no override — collapse.
		final source: String =
			'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}\nclass Sub extends Base {\n\tpublic function ping():Void {}\n}';
		Assert.equals(1, violations(source).length);
	}

	public function testSubclassTransitiveOverrideStillSkipped(): Void {
		// Leaf -> Mid -> Base: a TRANSITIVE subtype overrides get_active, so dropping it would strand
		// the override — the collapse is still skipped even though the direct subtype Mid is inert.
		final source: String =
			'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}\nclass Mid extends Base {}\nclass Leaf extends Mid {\n\toverride function get_active():Bool return true;\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testUnresolvableSubtypeHierarchyStillSkipped(): Void {
		// Leaf OVERRIDES get_active but reaches Base only through Mid, which is NOT in the lint scope
		// — the hierarchy below Base is unresolvable, so a hidden override cannot be ruled out and the
		// collapse is kept conservatively.
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'Base.hx',
				source: 'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}'
			},
			{ file: 'Leaf.hx', source: 'class Leaf extends Mid {\n\toverride function get_active():Bool return true;\n}' }
		];
		Assert.equals(0, new TrivialGetter().run(files, new HaxeQueryPlugin()).length);
	}

	public function testSubclassReadingBackingFieldCollapsesCrossFile(): Void {
		// Sub extends Base and reads Base's PRIVATE _active directly (legal — subclass-visible). The
		// collapse deletes _active; the cross-file fix rewrites Sub's READ `_active` -> `active` so the
		// property is flagged AND fixed atomically (both slices land in the one source file here).
		final source: String =
			'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}\nclass Sub extends Base {\n\tpublic function peek():Bool return _active;\n}';
		Assert.equals(1, violations(source).length);
		final fixed: String = crossFixApply([{ file: 'C.hx', source: source }])['C.hx'] ?? '';
		Assert.isTrue(fixed.indexOf('active(default, null):Bool = false') >= 0);
		Assert.isTrue(fixed.indexOf('get_active') == -1);
		Assert.isTrue(fixed.indexOf('_active') == -1);
		Assert.isTrue(fixed.indexOf('return active;') >= 0);
	}

	public function testSubclassReadingDifferentFieldCollapses(): Void {
		// Sub reads a DIFFERENT inherited private field (_other), never _active, so deleting _active
		// is safe — the field-reference gate is field-specific and the property collapses.
		final source: String =
			'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tprivate var _other:Int = 0;\n\tfunction get_active():Bool return _active;\n}\nclass Sub extends Base {\n\tpublic function peek():Int return _other;\n}';
		Assert.equals(1, violations(source).length);
	}

	public function testCrossFileSubtypeReadCollapses(): Void {
		// Base in one file, a subtype in ANOTHER file reads Base's private _active. The property is
		// flagged and the cross-file fix collapses Base AND rewrites the subtype's read `_active` -> `active`.
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'Base.hx',
				source: 'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}'
			},
			{ file: 'Sub.hx', source: 'class Sub extends Base {\n\tpublic function peek():Bool return _active;\n}' }
		];
		Assert.equals(1, new TrivialGetter().run(files, new HaxeQueryPlugin()).length);
		final out: Map<String, String> = crossFixApply(files);
		final base: String = out['Base.hx'] ?? '';
		final sub: String = out['Sub.hx'] ?? '';
		Assert.isTrue(base.indexOf('active(default, null):Bool = false') >= 0);
		Assert.isTrue(base.indexOf('get_active') == -1);
		Assert.isTrue(base.indexOf('_active') == -1);
		Assert.isTrue(sub.indexOf('return active;') >= 0);
		Assert.isTrue(sub.indexOf('_active') == -1);
	}

	public function testCrossFileSubtypeWriteBlocked(): Void {
		// The subtype WRITES the backing field; after a collapse that write would route through the
		// (default, null) storage illegally — the whole collapse stays blocked (0 findings).
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'Base.hx',
				source: 'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}'
			},
			{ file: 'Sub.hx', source: 'class Sub extends Base {\n\tpublic function set():Void { _active = true; }\n}' }
		];
		Assert.equals(0, new TrivialGetter().run(files, new HaxeQueryPlugin()).length);
	}

	public function testCrossFileUnresolvableReceiverBlocked(): Void {
		// The subtype reads the backing field through a NON-this/super receiver (`o._active`); the
		// receiver's binding is not proven owner-or-subtype, so the occurrence is unattributable and
		// the collapse stays blocked (fail-closed).
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'Base.hx',
				source: 'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}'
			},
			{ file: 'Sub.hx', source: 'class Sub extends Base {\n\tpublic function peek(o:Base):Bool return o._active;\n}' }
		];
		Assert.equals(0, new TrivialGetter().run(files, new HaxeQueryPlugin()).length);
	}

	public function testCrossFileMultiSubtypeReadsAtomic(): Void {
		// Two subtypes in two files each read the backing field; ALL are rewritten in one atomic rename.
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'Base.hx',
				source: 'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}'
			},
			{ file: 'Sub1.hx', source: 'class Sub1 extends Base {\n\tpublic function a():Bool return _active;\n}' },
			{ file: 'Sub2.hx', source: 'class Sub2 extends Base {\n\tpublic function b():Bool return this._active;\n}' }
		];
		Assert.equals(1, new TrivialGetter().run(files, new HaxeQueryPlugin()).length);
		final out: Map<String, String> = crossFixApply(files);
		Assert.isTrue((out['Base.hx'] ?? '').indexOf('_active') == -1);
		Assert.isTrue((out['Sub1.hx'] ?? '').indexOf('return active;') >= 0);
		Assert.isTrue((out['Sub2.hx'] ?? '').indexOf('return this.active;') >= 0);
		Assert.isTrue((out['Sub1.hx'] ?? '').indexOf('_active') == -1);
		Assert.isTrue((out['Sub2.hx'] ?? '').indexOf('_active') == -1);
	}

	public function testCrossFileShapeASubtypeRead(): Void {
		// The TextLink.label shape: a (get, set) property with a trivial getter and a NON-trivial
		// setter, whose backing field a subtype reads in another file. The collapse to (default, set)
		// deletes get_x, keeps set_x, and rewrites the subtype read `_label` -> `label`.
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'Base.hx',
				source: 'class Base {\n\tpublic var label(get, set):String;\n\tprivate var _label:String = \'\';\n\tfunction get_label():String return _label;\n\tfunction set_label(v:String):String { redraw(); return _label = v; }\n}'
			},
			{ file: 'Sub.hx', source: 'class Sub extends Base {\n\tpublic function draw():String return _label;\n}' }
		];
		Assert.equals(1, new TrivialGetter().run(files, new HaxeQueryPlugin()).length);
		final out: Map<String, String> = crossFixApply(files);
		final base: String = out['Base.hx'] ?? '';
		Assert.isTrue(base.indexOf('label(default, set)') >= 0);
		Assert.isTrue(base.indexOf('get_label') == -1);
		Assert.isTrue(base.indexOf('return label = v') >= 0);
		Assert.isTrue((out['Sub.hx'] ?? '').indexOf('return label;') >= 0);
	}

	private function cls(members: String): String {
		return 'class C {\n\t$members\n}';
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

	private function fixedText(src: String): String {
		final r = runAndExpectOne(src);
		return switch RefactorSupport.canonicalize(src, r.check.fix(src, r.vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message): {
				Assert.fail('fix canonicalize Err: $message');
				'';
			}
		}
	}

	/**
	 * Run the check + `crossFileFix` over `files`, apply every rename's per-file edits (unioned,
	 * canonicalized), and return the resulting source per file — the in-test equivalent of `apq lint
	 * --fix`'s cross-file commit. A file with no edits keeps its source.
	 */
	private function crossFixApply(files: Array<{ file: String, source: String }>): Map<String, String> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: TrivialGetter = new TrivialGetter();
		final vs: Array<Violation> = check.run(files, plugin);
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final byFile: Map<String, Array<{ span: Span, text: String }>> = [];
		for (rename in check.crossFileFix(files, vs, plugin, index)) for (slice in rename) {
			if (!byFile.exists(slice.file)) byFile[slice.file] = [];
			for (e in slice.edits) byFile[slice.file].push(e);
		}
		final out: Map<String, String> = [];
		for (f in files) {
			final edits: Null<Array<{ span: Span, text: String }>> = byFile[f.file];
			if (edits == null) {
				out[f.file] = f.source;
				continue;
			}
			out[f.file] = switch RefactorSupport.canonicalize(f.source, edits, true, plugin) {
				case Ok(text): text;
				case Err(message): {
					Assert.fail('crossFix canonicalize Err ($message)');
					f.source;
				}
			}
		}
		return out;
	}

	public function testAbstractClassTrivialGetterFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'abstract class C {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tprivate function get_active():Bool { return _active; }\n}'
			).length,
			'an abstract class body is inspected like a plain class'
		);
	}

	public function testAbstractOwnerCrossFileSubtypeReadCollapses(): Void {
		// The OWNER is an abstract class; a subtype in another file reads its private backing field.
		// Exercises subtypeRefWalk's owner-span exclusion / cls attribution for AbstractClassDecl:
		// the property collapses AND the subtype's read is renamed `_active` -> `active`.
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'Base.hx',
				source: 'abstract class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}'
			},
			{ file: 'Sub.hx', source: 'class Sub extends Base {\n\tpublic function peek():Bool return _active;\n}' }
		];
		Assert.equals(1, new TrivialGetter().run(files, new HaxeQueryPlugin()).length);
		final out: Map<String, String> = crossFixApply(files);
		final base: String = out['Base.hx'] ?? '';
		final sub: String = out['Sub.hx'] ?? '';
		Assert.isTrue(base.indexOf('active(default, null):Bool = false') >= 0);
		Assert.isTrue(base.indexOf('get_active') == -1);
		Assert.isTrue(sub.indexOf('return active;') >= 0);
		Assert.isTrue(sub.indexOf('_active') == -1);
	}

	public function testAbstractSubtypeWriteBlocked(): Void {
		// The subtype is itself an abstract class and WRITES the inherited backing
		// field — the collapse must stay blocked. Integration guard: the block is
		// carried by SymbolIndex's subtype machinery seeing the abstract subtype.
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'Base.hx',
				source: 'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}'
			},
			{ file: 'Mid.hx', source: 'abstract class Mid extends Base {\n\tpublic function reset():Void _active = false;\n}' }
		];
		Assert.equals(0, new TrivialGetter().run(files, new HaxeQueryPlugin()).length);
	}


	public function testBackingTypeDiffersFromPropertyTypeNotFlagged(): Void {
		// The getter performs an implicit upcast (Array -> ReadOnlyArray): collapsing
		// to one (default, null) slot would retype the storage and break every
		// mutating use of the backing field (`resize`, assignment to an Array slot).
		Assert.equals(
			0,
			violations(cls(
				'public var headers(get, never):ReadOnlyArray<Header>;\n\tprivate final _headers:Array<Header> = [];\n\tprivate inline function get_headers():ReadOnlyArray<Header> return _headers;'
			)).length
		);
	}


	/**
	 * A local annotated with a comma-carrying generic (`Map<K, V>`) whose initializer reads the
	 * backing field: the comma sits INSIDE `<>`, so the declaration is not a multi-var list and
	 * the collapse must proceed. The AST already says so — only a text-level comma scan can
	 * mistake it.
	 */
	public function testCommaGenericAnnotationStillCollapses(): Void {
		assertFixContains(
			cls(
				'public var frame(get, never):Int;\n' + '\tprivate var _currentFrame:Int = 0;\n'
				+ '\tprivate final _frames:Map<Int, Int> = [];\n' + '\tprivate inline function get_frame():Int return _currentFrame;\n'
				+ '\tpublic function touch():Void { final row:Null<Map<Int, Int>> = _frames[_currentFrame]; }'
			),
			'_frames[frame]'
		);
	}

	/**
	 * The genuine multi-var list the comma scan was guarding against: a later binding projects as
	 * `VarMore`, and an initializer reading the backing field keeps the collapse refused.
	 */
	public function testMultiVarDeclStillRefusesFix(): Void {
		assertFixRefused(cls(
			'public var frame(get, never):Int;\n' + '\tprivate var _currentFrame:Int = 0;\n'
			+ '\tprivate inline function get_frame():Int return _currentFrame;\n'
			+ '\tpublic function touch():Void { var a = _currentFrame, frame = 2; trace(a + frame); }'
		));
	}


	/**
	 * A property and its trivial getter written inside a member-position `#if` are members of the
	 * class like any other. The region is ONE child of the container holding every branch's members
	 * flattened, so scanning the container's direct children alone silently exempted the whole trio.
	 */
	public function testConditionalMemberFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\t#if cpp\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tprivate function get_active():Bool return _active;\n\t#end\n}'
			).length
		);
	}


	/**
	 * The collapse renames the backing field into the PROPERTY's name, which only exists where the
	 * property's branch compiles. A reader in another branch would be rewritten to a member its own
	 * build does not have, so a guarded property whose backing field is mentioned outside its branch
	 * is refused outright.
	 */
	public function testConditionalBackingFieldReadInAnotherBranchNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\t#if cpp\n\tpublic var active(get, never):Bool;\n\t#end\n\tprivate var _active:Bool = false;\n\tprivate function get_active():Bool return _active;\n\t#if !cpp\n\tpublic function readIt():Bool return _active;\n\t#end\n}'
			).length
		);
	}


	/**
	 * The confined case: property, backing field and getter all in ONE branch. The collapse's edits —
	 * the accessor-clause rewrite, the field deletion and the getter deletion, modifier runs included
	 * — all land inside the region, leaving the directives untouched.
	 */
	public function testConditionalCollapseStaysInsideItsBranch(): Void {
		assertFixContains(
			'class C {\n\t#if cpp\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\tprivate function get_active():Bool return _active;\n\t#end\n}',
			'#if cpp\n\tpublic var active(default, null):Bool = false;\n\t#end'
		);
	}

}
