package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.TrivialGetter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.MemberKinds;
import anyparse.query.SymbolIndex;
import utest.Assert;

/**
 * The `trivial-getter` check on a READ-ONLY property: `var x(get, never)` /
 * `(get, null)` whose `get_x` body is exactly `return _backing;` (a bare ident
 * or `this._backing`) over a PRIVATE same-class field is flagged `Info`,
 * report-only. Soundness misses: a getter with any other logic, a custom `set`
 * or `default` write slot, a `dynamic` getter, a public backing field, a
 * custom-named read accessor, an interface property, an inherited / other-class
 * field. It keys on triviality, not the `_` naming convention. `final class`
 * bodies (`ClassForm`) are covered. The fix rewrites the property to
 * `(default, null)` and re-points the getter's reads, qualifying a shadowed one
 * with `this`.
 *
 * The accessor-shape collapses — `(get, set)`, both-trivial, `(get, default)` —
 * live in `TrivialGetterShapeCollapseTest`.
 */
class TrivialGetterCheckTest extends TrivialGetterCheckTestBase {

	public function testBasicBlockBodyFlagged(): Void {
		final vs: Array<Violation> = violations(cls(
			'public var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
			+ '\tprivate function get_active():Bool { return _active; }'
		));
		Assert.equals(1, vs.length);
		Assert.equals('trivial-getter', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(
			'property \'active\' has a trivial getter returning backing field \'_active\'; use \'var active(default, null)\' and remove '
			+ 'get_active',
			vs[0].message
		);
	}

	public function testExpressionBodyFlagged(): Void {
		Assert.equals(
			1,
			violations(cls(
				'public var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
				+ '\tprivate inline function get_active():Bool return _active;'
			)).length
		);
	}

	public function testThisAccessFlagged(): Void {
		Assert.equals(
			1,
			violations(cls(
				'public var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
				+ '\tfunction get_active():Bool { return this._active; }'
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
		final src: String = 'final class C {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
			+ '\tfunction get_active():Bool return _active;\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testAbstractClassTrivialGetterFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'abstract class C {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
				+ '\tprivate function get_active():Bool { return _active; }\n}'
			).length,
			'an abstract class body is inspected like a plain class'
		);
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
				'public var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
				+ '\tfunction get_active():Bool { trace(\'x\'); return _active; }'
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
				'public var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
				+ '\tdynamic function get_active():Bool return _active;'
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

	public function testBackingTypeDiffersFromPropertyTypeNotFlagged(): Void {
		// The getter performs an implicit upcast (Array -> ReadOnlyArray): collapsing
		// to one (default, null) slot would retype the storage and break every
		// mutating use of the backing field (`resize`, assignment to an Array slot).
		Assert.equals(
			0,
			violations(cls(
				'public var headers(get, never):ReadOnlyArray<Header>;\n\tprivate final _headers:Array<Header> = [];\n'
				+ '\tprivate inline function get_headers():ReadOnlyArray<Header> return _headers;'
			)).length
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

	/**
	 * A local annotated with a comma-carrying generic (`Map<K, V>`) whose initializer reads the
	 * backing field: the comma sits INSIDE `<>`, so the declaration is not a multi-var list and
	 * the collapse must proceed. The AST already says so — only a text-level comma scan can
	 * mistake it.
	 */
	public function testCommaGenericAnnotationStillCollapses(): Void {
		assertFixContains(
			cls(
				'public var frame(get, never):Int;\n\tprivate var _currentFrame:Int = 0;\n\tprivate final _frames:Map<Int, Int> = [];\n'
				+ '\tprivate inline function get_frame():Int return _currentFrame;\n'
				+ '\tpublic function touch():Void { final row:Null<Map<Int, Int>> = _frames[_currentFrame]; }'
			),
			'_frames[frame]'
		);
	}

	public function testFixRenamesThisAndBareRefs(): Void {
		final src: String = 'class C {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
			+ '\tpublic function new() { _active = true; }\n\tfunction get_active():Bool return _active;\n'
			+ '\tfunction toggle():Void { this._active = !_active; }\n}';
		assertFixCanonical(src, 'this.active = !active', '_active');
	}

	public function testFixRefusesOtherReceiverAccess(): Void {
		final src: String = 'class C {\n\tpublic var name(get, null):String;\n\tprivate var _name:String;\n'
			+ '\tpublic function new(n:String) { _name = n; }\n\tfunction get_name():String return _name;\n'
			+ '\tfunction other(c:C):String { return c._name; }\n}';
		assertFixRefused(src);
	}

	public function testFixRefusesLocalShadow(): Void {
		final src: String = 'class C {\n\tpublic var tag(get, never):Int;\n\tprivate var _tag:Int = 0;\n'
			+ '\tfunction get_tag():Int return _tag;\n\tfunction loc():Void { var _tag = 9; trace(_tag); }\n}';
		assertFixRefused(src);
	}

	public function testFixRefusesMultiVarShadow(): Void {
		// The grammar keeps only the FIRST name of a multi-var declaration, so a shadowing
		// second `_tag` is invisible as a node — the fix must refuse on the hidden slot.
		final src: String = 'class C {\n\tpublic var tag(get, never):Int;\n\tprivate var _tag:Int = 0;\n'
			+ '\tfunction get_tag():Int return _tag;\n\tfunction m():Void {\n\t\tvar a = 1, _tag = 2;\n\t\ttrace(_tag);\n\t}\n}';
		assertFixRefused(src);
	}

	/**
	 * The genuine multi-var list the comma scan was guarding against: a later binding projects as
	 * `VarMore`, and an initializer reading the backing field keeps the collapse refused.
	 */
	public function testMultiVarDeclStillRefusesFix(): Void {
		assertFixRefused(cls(
			'public var frame(get, never):Int;\n\tprivate var _currentFrame:Int = 0;\n\tprivate inline function get_frame():Int return '
			+ '_currentFrame;\n\tpublic function touch():Void { var a = _currentFrame, frame = 2; trace(a + frame); }'
		));
	}

	public function testFixRefusesKeyValueForShadow(): Void {
		// The grammar keeps only the KEY name of a key-value for header, so a shadowing
		// value variable `_tag` is invisible as a node — the fix must refuse on the header.
		final src: String = 'class C {\n\tpublic var tag(get, never):Int;\n\tprivate var _tag:Int = 0;\n\tfunction get_tag():Int return '
			+ '_tag;\n\tfunction m(mp:Map<Int, Int>):Void {\n\t\tfor (k => _tag in mp) trace(_tag);\n\t}\n}';
		assertFixRefused(src);
	}

	public function testFixRefusesCasePatternCapture(): Void {
		final src: String = 'class C {\n\tpublic var kind(get, never):Int;\n\tprivate var _kind:Int = 1;\n\tfunction get_kind():Int return '
			+ '_kind;\n\tfunction m(x:Any):Void { switch x { case _kind: trace(_kind); case _: trace(0); } }\n}';
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
		final source: String = 'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
			+ '\tfunction get_active():Bool return _active;\n}\nclass Sub extends Base {\n'
			+ '\toverride function get_active():Bool return true;\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testSubclassTransitiveOverrideStillSkipped(): Void {
		// Leaf -> Mid -> Base: a TRANSITIVE subtype overrides get_active, so dropping it would strand
		// the override — the collapse is still skipped even though the direct subtype Mid is inert.
		final source: String = 'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
			+ '\tfunction get_active():Bool return _active;\n}\nclass Mid extends Base {}\nclass Leaf extends Mid {\n'
			+ '\toverride function get_active():Bool return true;\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testUnresolvableSubtypeHierarchyStillSkipped(): Void {
		// Leaf OVERRIDES get_active but reaches Base only through Mid, which is NOT in the lint scope
		// — the hierarchy below Base is unresolvable, so a hidden override cannot be ruled out and the
		// collapse is kept conservatively.
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'Base.hx',
				source: 'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
					+ '\tfunction get_active():Bool return _active;\n}'
			},
			{ file: 'Leaf.hx', source: 'class Leaf extends Mid {\n\toverride function get_active():Bool return true;\n}' }
		];
		Assert.equals(0, new TrivialGetter().run(files, new HaxeQueryPlugin()).length);
	}

	// --- (a) interface-conformance gate: collapsing a public property to (default, null)
	// drops the physical get_x an implemented interface may require ("Field get_x needed
	// by I is missing"). Skip whenever the class implements anything and the property is
	// public, unless every implemented interface is resolvable in scope and provably lacks it.

	public function testInterfaceImplementerNotFlagged(): Void {
		// The interface `Toggleable` is not in the lint scope, so it cannot be proven to lack
		// `active` — the collapse could break a required `get_active`, so the property is skipped.
		final src: String = 'class C implements Toggleable {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
			+ '\tfunction get_active():Bool return _active;\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testInterfaceDeclaringPropNotFlagged(): Void {
		// The interface is resolvable AND declares `active(get, never)`, so the class MUST keep a
		// physical `get_active` — the collapse is unsafe and the property is skipped.
		final files: Array<{ file: String, source: String }> = [
			{ file: 'Toggle.hx', source: 'interface Toggle {\n\tpublic var active(get, never):Bool;\n}' },
			{
				file: 'C.hx',
				source: 'class C implements Toggle {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
					+ '\tfunction get_active():Bool return _active;\n}'
			}
		];
		Assert.equals(0, new TrivialGetter().run(files, new HaxeQueryPlugin()).length);
	}

	/**
	 * Two interfaces share the simple name `Named`; the class's import picks the one that does NOT
	 * declare `active`, so the collapse stays safe. The gate used to refuse on ambiguity alone.
	 */
	public function testAmbiguousInterfaceNameResolvesFromFileImports(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'a/Named.hx', source: 'package a;\ninterface Named {\n\tpublic var active(get, never):Bool;\n}' },
			{ file: 'b/Named.hx', source: 'package b;\ninterface Named {\n\tpublic var label(get, never):String;\n}' },
			{
				file: 'C.hx',
				source: 'import b.Named;\n\nclass C implements Named {\n\tpublic var active(get, never):Bool;\n'
					+ '\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}'
			}
		];
		Assert.equals(1, new TrivialGetter().run(files, new HaxeQueryPlugin()).length);
	}

	/** The mirror: the imported interface DOES declare `active`, so the getter must stay. */
	public function testAmbiguousInterfaceNameResolvesToTheRequiringOne(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'a/Named.hx', source: 'package a;\ninterface Named {\n\tpublic var active(get, never):Bool;\n}' },
			{ file: 'b/Named.hx', source: 'package b;\ninterface Named {\n\tpublic var label(get, never):String;\n}' },
			{
				file: 'C.hx',
				source: 'import a.Named;\n\nclass C implements Named {\n\tpublic var active(get, never):Bool;\n'
					+ '\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n}'
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
				source: 'class C implements Named {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
					+ '\tfunction get_active():Bool return _active;\n}'
			}
		];
		Assert.equals(1, new TrivialGetter().run(files, new HaxeQueryPlugin()).length);
	}

	public function testPrivatePropInImplementerStillFlagged(): Void {
		// A PRIVATE property is not exposed through the interface, so `implements` is irrelevant.
		final src: String = 'class C implements Toggleable {\n\tprivate var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
			+ '\tfunction get_active():Bool return _active;\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testFixProceedsWhenInterfaceLacksProp(): Void {
		final classSrc: String = 'class C implements Named {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
			+ '\tfunction get_active():Bool return _active;\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'Named.hx', source: 'interface Named {\n\tpublic var label(get, never):String;\n}' },
			{ file: 'C.hx', source: classSrc }
		];
		final r: { check: TrivialGetter, vs: Array<Violation> } = runFilesAndExpectOne(files);
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		Assert.isTrue(r.check.fix(classSrc, r.vs, new HaxeQueryPlugin(), index).length > 0);
	}

	// --- (b) shadowed-property rewrite: renaming the backing field `_x` to the property `x`
	// inside a function that binds a parameter / local also named `x` would rewrite `_x = x`
	// into the self-assignment `x = x` (the param wins resolution — silent data loss). The
	// backing-field write must be qualified as `this.x` when the enclosing function shadows `x`.

	public function testFixShadowedParamUsesThis(): Void {
		final src: String = 'class C {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool;\n'
			+ '\tpublic function new(active:Bool) { _active = active; }\n\tfunction get_active():Bool return _active;\n}';
		assertFixContains(src, 'this.active = active');
	}

	public function testFixShadowedLocalUsesThis(): Void {
		final src: String = 'class C {\n\tpublic var count(get, never):Int;\n\tprivate var _count:Int = 0;\n'
			+ '\tfunction get_count():Int return _count;\n\tfunction bump():Void { var count = 5; _count = count; }\n}';
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
			'public var color(get, set):Int;\n\tprivate var _color:Int = 0;\n\tprivate var _palette:Array<Int> = [];\n'
			+ '\tfunction get_color():Int return _color;\n\tfunction set_color(v:Int):Int return _color = v;\n'
			+ '\tfunction upd():Void { for (color in _palette) if (color == _color) trace(color); }'
		);
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.indexOf('color == this.color') >= 0, 'loop-var shadow must qualify the field read');
		Assert.isTrue(fixed.indexOf('color == color') == -1, 'the always-true self-comparison must be gone');
	}

	public function testFixShadowedKeyValueForVarUsesThis(): Void {
		// The grammar keeps only the KEY name of a key-value for header, so a value slot named
		// like the property is invisible as a node — the header text must be scanned for it.
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n'
			+ '\tfunction m(mp:Map<Int, Int>):Void { for (k => count in mp) trace(k + count + _count); }'
		);
		assertFixContains(src, 'count + this.count');
	}

	public function testFixShadowedComprehensionVarUsesThis(): Void {
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tprivate var _items:Array<Int> = [];\n\tfunction '
			+ 'get_count():Int return _count;\n\tfunction m():Void { var xs = [for (count in _items) count + _count]; trace(xs); }'
		);
		assertFixContains(src, 'count + this.count');
	}

	public function testFixShadowedCatchVarUsesThis(): Void {
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n'
			+ '\tfunction m():Void { try { risky(); } catch (count:Dynamic) { trace(count + _count); } }'
		);
		assertFixContains(src, 'count + this.count');
	}

	public function testFixShadowedCasePatternCaptureUsesThis(): Void {
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n'
			+ '\tfunction m(v:Any):Void { switch v { case count: trace(count + _count); } }'
		);
		assertFixContains(src, 'count + this.count');
	}

	public function testFixShadowedMultiVarContinuationUsesThis(): Void {
		// `var a = 1, count = 2;` — the continuation binding is a `VarMore` node, absent from
		// the old binder-kind list.
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n'
			+ '\tfunction m():Void { var a = 1, count = 2; trace(a + count + _count); }'
		);
		assertFixContains(src, 'count + this.count');
	}

	public function testFixShadowedThinArrowParamUsesThis(): Void {
		// A single-parameter thin arrow projects its parameter as a bare `IdentExpr`, not a
		// `Required` / `LambdaParam` node.
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n'
			+ '\tfunction m():Void { var f = count -> count + _count; trace(f(1)); }'
		);
		assertFixContains(src, 'count + this.count');
	}

	public function testFixShadowedLambdaParamUsesThis(): Void {
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n'
			+ '\tfunction m():Void { var f = (count:Int) -> count + _count; trace(f(1)); }'
		);
		assertFixContains(src, 'count + this.count');
	}

	public function testFixShadowedStaticLocalUsesThis(): Void {
		// A Haxe 4.3 `static var` local binds the name in the function like any other local.
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n'
			+ '\tfunction m():Void { static var count:Int = 5; trace(count + _count); }'
		);
		assertFixContains(src, 'count + this.count');
	}

	public function testFixShadowedLocalInlineFunctionUsesThis(): Void {
		// `inline function` is a distinct kind from a plain local function, and the project's own
		// Haxe style mandates it for local helpers.
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n'
			+ '\tfunction m():Void { inline function count():Int return 1; trace(count() + _count); }'
		);
		assertFixContains(src, '+ this.count');
	}

	public function testFixShadowedCaseVarCaptureUsesThis(): Void {
		// `case var x:` carries its binding on a `Capture` node — a direct child of the branch,
		// NOT inside the pattern subtree, so the pattern scan alone never sees it.
		final src: String = cls(
			'public var count(get, never):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n'
			+ '\tfunction m(v:Any):Void { switch v { case var count: trace(Std.string(count) + _count); } }'
		);
		assertFixContains(src, '+ this.count');
	}

	public function testFixRefusesKeyValueComprehensionFieldShadow(): Void {
		// The FIELD-name side of the same dropped slot: a comprehension whose key-value header
		// binds the BACKING FIELD name must refuse — renaming its reads would silently retarget
		// them at the property.
		final src: String = 'class C {\n\tpublic var tag(get, never):Int;\n\tprivate var _tag:Int = 0;\n\tfunction get_tag():Int return '
			+ '_tag;\n\tfunction m(mp:Map<Int, Int>):Array<Int> {\n\t\treturn [for (k => _tag in mp) _tag + k];\n\t}\n}';
		assertFixRefused(src);
	}

	public function testFixStaticPropertyShadowUsesClassName(): Void {
		// A STATIC property cannot be reached through `this` — a shadowed reference must be
		// qualified with the class name even from an instance method.
		final src: String = cls(
			'public static var total(get, never):Int;\n\tprivate static var _total:Int = 0;\n'
			+ '\tstatic function get_total():Int return _total;\n\tfunction m():Void { for (total in [1, 2]) trace(total + _total); }'
		);
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.indexOf('total + C.total') >= 0, 'a static property must be class-qualified');
		Assert.isTrue(fixed.indexOf('this.total') == -1, 'a static property is not reachable through this');
	}

	@:access(anyparse.check.TrivialGetter)
	public function testFnScopeKindsMatchTheGrammarAuthority(): Void {
		// `TrivialGetter.FN_SCOPE_KINDS` is a HAND COPY of a derivable set, and this is what pays for
		// that: it is checked against the grammar in BOTH directions, so a plugin adding or dropping a
		// function-value spelling fails here instead of silently changing which references the rename
		// walk treats as shadowed. (The copy exists because `isFnScope` is called from three points
		// inside a rename walk carrying no context object — deriving it would add a parameter to eight
		// signatures and fourteen call sites, in a file that decides its other node kinds by literal.)
		//
		// The one documented extra over `RefactorSupport.nestedFunctionKinds` is the METHOD-declaration
		// half: `functionKinds` minus the local functions (already function VALUES) and minus the
		// module-level declarations, which are deliberately excluded — a shadowed reference is
		// rewritten to `this.` / `C.`, and neither is spellable at module level.
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		final expected: Array<String> = MemberKinds.nestedFunctionKinds(shape);
		final localOrModule: Array<String> = (shape.localFunctionKinds ?? []).concat(shape.moduleValueDeclKinds);
		for (kind in shape.functionKinds ?? []) if (!localOrModule.contains(kind) && !expected.contains(kind)) expected.push(kind);
		Assert.isTrue(expected.length > 0, 'the plugin must declare at least one function scope kind');
		for (kind in expected)
			Assert.isTrue(TrivialGetter.FN_SCOPE_KINDS.contains(kind), 'FN_SCOPE_KINDS is missing the grammar scope kind $kind');
		for (kind in TrivialGetter.FN_SCOPE_KINDS)
			Assert.isTrue(expected.contains(kind), 'FN_SCOPE_KINDS carries $kind, which the grammar no longer names a function scope');
	}

}
