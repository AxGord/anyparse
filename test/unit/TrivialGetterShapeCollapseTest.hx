package unit;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.TrivialGetter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;

/**
 * The accessor-shape collapses of `trivial-getter`, and the subtype/cross-file and
 * conditional-compilation gating that decides whether a collapse may fire.
 *
 * The `(get, set)` shape-A collapse (trivial getter, non-trivial setter) is
 * decided three ways on the external statement-level writes to the backing
 * field: 0 writes collapses to `(default, set)` unchanged; 1..maxBypassWrites
 * writes collapses and marks each write `@:bypassAccessor` (default cap 3,
 * overridable via the `maxBypassWrites` option); more than the cap, or any write
 * nested inside a larger expression, falls back to marking `get_x` `inline`
 * (skipped when the getter is already `inline` or `override`). Shape B (both
 * accessors trivial) collapses to a plain `var`; shape C (trivial setter, real
 * getter) collapses to `(get, default)`.
 */
class TrivialGetterShapeCollapseTest extends TrivialGetterCheckTestBase {

	/**
	 * The confined case: property, backing field and getter all in ONE branch. The collapse's edits —
	 * the accessor-clause rewrite, the field deletion and the getter deletion, modifier runs included
	 * — all land inside the region, leaving the directives untouched.
	 */
	public inline function testConditionalCollapseStaysInsideItsBranch(): Void {
		assertFixContains(
			'class C {\n\t#if cpp\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
			+ '\tprivate function get_active():Bool return _active;\n\t#end\n}',
			'#if cpp\n\tpublic var active(default, null):Bool = false;\n\t#end'
		);
	}

	public function testShapeATrivialGetterRealSetterFlagged(): Void {
		final vs: Array<Violation> = violations(cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n'
			+ '\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }'
		));
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'active\' has a trivial getter over backing field \'_active\'; use \'var active(default, set)\' and remove '
			+ 'get_active',
			vs[0].message
		);
	}

	public function testShapeAFixToDefaultSet(): Void {
		final fixed: String = fixedText(cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n'
			+ '\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }'
		));
		Assert.isTrue(fixed.indexOf('active(default, set)') >= 0);
		Assert.isTrue(fixed.indexOf('= false') >= 0);
		Assert.isTrue(fixed.indexOf('return active = v') >= 0);
		Assert.isTrue(fixed.indexOf('get_active') == -1);
		Assert.isTrue(fixed.indexOf('private var _active') == -1);
	}

	public function testShapeAExternalWriteBypassFlagged(): Void {
		final vs: Array<Violation> = violations(cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n'
			+ '\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n\tfunction reset():Void { _active = true; }'
		));
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'active\' has a trivial getter over backing field \'_active\'; use \'var active(default, set)\', remove '
			+ 'get_active and mark 1 external write(s) with @:bypassAccessor',
			vs[0].message
		);
	}

	public function testShapeACtorInitMoveFlagged(): Void {
		final src: String = 'class LicenseButton {\n\tpublic var disabled(get, set):Bool;\n\tprivate var _disabled:Bool;\n'
			+ '\tpublic function new() {\n\t\t_disabled = false;\n\t\tinit();\n\t}\n'
			+ '\tfunction get_disabled():Bool return _disabled;\n\tfunction set_disabled(v:Bool):Bool {\n\t\t_disabled = v;\n'
			+ '\t\talpha = v ? 0.5 : 1;\n\t\treturn _disabled;\n\t}\n}';
		Assert.equals(1, new TrivialGetter().run([{ file: 'LicenseButton.hx', source: src }], new HaxeQueryPlugin()).length);
	}

	public function testShapeACtorInitMoveFix(): Void {
		final src: String = 'class LicenseButton {\n\tpublic var disabled(get, set):Bool;\n\tprivate var _disabled:Bool;\n'
			+ '\tpublic function new() {\n\t\t_disabled = false;\n\t\tinit();\n\t}\n'
			+ '\tfunction get_disabled():Bool return _disabled;\n\tfunction set_disabled(v:Bool):Bool {\n\t\t_disabled = v;\n'
			+ '\t\talpha = v ? 0.5 : 1;\n\t\treturn _disabled;\n\t}\n}';
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
		final src: String = 'class C {\n\tpublic var disabled(get, set):Bool;\n\tprivate var _disabled:Bool;\n\tpublic function new() {\n'
			+ '\t\ttrace(_disabled);\n\t\t_disabled = false;\n\t}\n\tfunction get_disabled():Bool return _disabled;\n'
			+ '\tfunction set_disabled(v:Bool):Bool { redraw(); return _disabled = v; }\n}';
		final vs: Array<Violation> = new TrivialGetter().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.indexOf('@:bypassAccessor disabled = false') >= 0);
		Assert.isTrue(fixed.indexOf('trace(disabled)') >= 0);
		Assert.isTrue(fixed.indexOf('get_disabled') == -1);
	}

	public function testBothTrivialCollapsesToPlainVar(): Void {
		final vs: Array<Violation> = violations(cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n'
			+ '\tfunction set_active(v:Bool):Bool return _active = v;'
		));
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'active\' has a trivial getter and setter over backing field \'_active\'; use a plain field \'var active\' and '
			+ 'remove get_active/set_active',
			vs[0].message
		);
	}

	public function testBothTrivialFixToPlainVar(): Void {
		assertFixCanonical(
			cls(
				'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n'
				+ '\tfunction set_active(v:Bool):Bool return _active = v;'
			),
			'public var active:Bool = false', '_active'
		);
	}

	public function testShapeCTrivialSetterRealGetterFlagged(): Void {
		final vs: Array<Violation> = violations(cls(
			'public var count(get, set):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count + 1;\n'
			+ '\tfunction set_count(v:Int):Int return _count = v;'
		));
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'count\' has a trivial setter over backing field \'_count\'; use \'var count(get, default)\' and remove set_count',
			vs[0].message
		);
	}

	public function testShapeCFixToGetDefault(): Void {
		final fixed: String = fixedText(cls(
			'public var count(get, set):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count + 1;\n'
			+ '\tfunction set_count(v:Int):Int return _count = v;'
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
			'public var count(get, set):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count + 1;\n'
			+ '\tfunction set_count(v:Int):Int return _count = v;\n\tfunction peek():Int { return _count; }'
		);
		Assert.equals(0, violations(src).length);
	}

	public function testShapeCCompoundAssignNotFlagged(): Void {
		// _count += 1 outside get_count READS _count (x += 1 compiles to x = get_count() + 1), so
		// it would newly route through the non-trivial getter — the property is skipped.
		final src: String = cls(
			'public var count(get, set):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count + 1;\n'
			+ '\tfunction set_count(v:Int):Int return _count = v;\n\tfunction bump():Void { _count += 1; }'
		);
		Assert.equals(0, violations(src).length);
	}

	public function testShapeCExternalPureWriteStillFlagged(): Void {
		// A pure write _count = 5 outside the accessors is a direct (default) write, not a read,
		// so it does not block the (get, default) collapse.
		final src: String = cls(
			'public var count(get, set):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count + 1;\n'
			+ '\tfunction set_count(v:Int):Int return _count = v;\n\tfunction reset():Void { _count = 5; }'
		);
		Assert.equals(1, violations(src).length);
	}

	public function testFixShapeCShadowedLoopVarUsesThis(): Void {
		// The sibling arm: a TRIVIAL SETTER collapse to (get, default) renames the backing-field
		// WRITE, which under a loop-variable shadow would become the self-assignment `x = x`.
		final src: String = cls(
			'public var x(get, set):Int;\n\tprivate var _x:Int = 0;\n\tprivate var _items:Array<Int> = [];\n\tfunction get_x():Int {'
			+ ' redraw(); return _x; }\n\tfunction set_x(v:Int):Int return _x = v;\n\tfunction m():Void { for (x in _items) _x = x; }'
		);
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.indexOf('this.x = x') >= 0, 'a shadowed write target must be qualified');
		Assert.isTrue(fixed.indexOf('x(get, default)') >= 0);
	}

	public function testShapeABypassFix(): Void {
		final fixed: String = fixedText(cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n'
			+ '\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n\tfunction reset():Void { _active = true; }'
		));
		Assert.isTrue(fixed.indexOf('@:bypassAccessor active = true') >= 0);
		Assert.isTrue(fixed.indexOf('active(default, set)') >= 0);
		Assert.isTrue(fixed.indexOf('get_active') == -1);
		Assert.isTrue(fixed.indexOf('private var _active') == -1);
	}

	public function testShapeABypassShadowedCtorWrite(): Void {
		final src: String = cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n'
			+ '\tpublic function new(?active:Bool) { _active = active ?? false; }\n\tfunction get_active():Bool return _active;\n'
			+ '\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }'
		);
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.indexOf('@:bypassAccessor this.active = active ?? false') >= 0);
		Assert.isTrue(fixed.indexOf('active(default, set):Bool = false') >= 0);
	}

	public function testShapeAExceedsCapInline(): Void {
		final src: String = cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n'
			+ '\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n\tfunction a():Void { _active = true; }\n'
			+ '\tfunction b():Void { _active = false; }\n\tfunction c():Void { _active = true; }\n\tfunction d():Void { _active = false; }'
		);
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'active\' has a trivial getter over backing field \'_active\', but 4 external write(s) block a (default, set) '
			+ 'collapse; mark get_active inline',
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
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n'
			+ '\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n'
			+ '\tfunction f():Void { if ((_active = true)) trace(1); }'
		);
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'active\' has a trivial getter over backing field \'_active\', but 1 external write(s) block a (default, set) '
			+ 'collapse; mark get_active inline',
			vs[0].message
		);
	}

	public function testShapeAAlreadyInlineGetterNotFlagged(): Void {
		final src: String = cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tinline function get_active():Bool return '
			+ '_active;\n\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n\tfunction a():Void { _active = true; }\n'
			+ '\tfunction b():Void { _active = false; }\n\tfunction c():Void { _active = true; }\n\tfunction d():Void { _active = false; }'
		);
		Assert.equals(0, violations(src).length);
	}

	public function testShapeAOverrideGetterNotFlagged(): Void {
		final src: String = cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\toverride function get_active():Bool return '
			+ '_active;\n\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n\tfunction a():Void { _active = true; }\n'
			+ '\tfunction b():Void { _active = false; }\n\tfunction c():Void { _active = true; }\n\tfunction d():Void { _active = false; }'
		);
		Assert.equals(0, violations(src).length);
	}

	public function testShapeACtorInitPlusBypass(): Void {
		final src: String = 'class C {\n\tpublic var active(get, set):Bool;\n\tprivate var _active:Bool;\n\tpublic function new() {\n'
			+ '\t\t_active = false;\n\t\tinit();\n\t}\n\tfunction get_active():Bool return _active;\n'
			+ '\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n\tfunction reset():Void { _active = true; }\n}';
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.indexOf('active(default, set):Bool = false') >= 0);
		Assert.isTrue(fixed.indexOf('@:bypassAccessor active = true') >= 0);
		Assert.isTrue(fixed.indexOf('_active = false') == -1);
	}

	public function testShapeAConfigCapInline(): Void {
		final src: String = cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n'
			+ '\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n\tfunction a():Void { _active = true; }\n'
			+ '\tfunction b():Void { _active = false; }'
		);
		final check: TrivialGetter = new TrivialGetter();
		final cfg: LintConfig = LintConfig.parse('{"rules": {"trivial-getter": {"maxBypassWrites": 1}}}');
		check.setConfigResolver(_ -> cfg);
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'active\' has a trivial getter over backing field \'_active\', but 2 external write(s) block a (default, set) '
			+ 'collapse; mark get_active inline',
			vs[0].message
		);
	}

	public function testShapeAZeroWritesNoBypass(): Void {
		final src: String = cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n'
			+ '\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }'
		);
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'active\' has a trivial getter over backing field \'_active\'; use \'var active(default, set)\' and remove '
			+ 'get_active',
			vs[0].message
		);
		Assert.isTrue(fixedText(src).indexOf('@:bypassAccessor') == -1);
	}

	public function testShapeAExactlyCapBypass(): Void {
		// Exactly maxBypassWrites (default 3) statement-level writes sit ON the cap boundary
		// and still take the bypass arm — only cap + 1 falls back to the inline arm.
		final src: String = cls(
			'public var active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n'
			+ '\tfunction set_active(v:Bool):Bool { redraw(); return _active = v; }\n\tfunction a():Void { _active = true; }\n'
			+ '\tfunction b():Void { _active = false; }\n\tfunction c():Void { _active = true; }'
		);
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'active\' has a trivial getter over backing field \'_active\'; use \'var active(default, set)\', remove '
			+ 'get_active and mark 3 external write(s) with @:bypassAccessor',
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
			'public var count(get, set):Int;\n\tprivate var _count:Int = 0;\n\tfunction get_count():Int return _count;\n'
			+ '\tfunction set_count(v:Int):Int { redraw(); return _count = v; }\n\tfunction bump():Void { _count += 1; }'
		);
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'count\' has a trivial getter over backing field \'_count\'; use \'var count(default, set)\', remove get_count '
			+ 'and mark 1 external write(s) with @:bypassAccessor',
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
			'public var sel(get, set):Int;\n\tprivate var _sel:Int = -1;\n\tfunction get_sel():Int return _sel;\n'
			+ '\tfunction set_sel(v:Int):Int { redraw(); return _sel = v; }\n\tfunction log():Void { trace(\'v=$$_sel\'); }'
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
			'public var sel(get, set):Int;\n\tprivate var _sel:Int = -1;\n\tfunction get_sel():Int return _sel;\n'
			+ '\tfunction set_sel(v:Int):Int { redraw(); return _sel = v; }\n\tfunction log():Void { var sel = 3; trace(\'v=$$_sel\'); }'
		);
		assertFixRefused(src);
	}

	public function testShapeCStringInterpReadBlocksCollapse(): Void {
		// Shape C (non-trivial getter + trivial setter) would collapse to (get, default), but a
		// simple `$_backing` interpolation READ outside the getter would route through the
		// non-trivial getter after the collapse -- the read-gate must see the interpolation read
		// (it is a bare `Ident`, not `IdentExpr`) and skip the property.
		final src: String = cls(
			'public var x(get, set):Int;\n\tprivate var _x:Int = 0;\n\tfunction get_x():Int { redraw(); return _x; }\n'
			+ '\tfunction set_x(v:Int):Int return _x = v;\n\tfunction log():Void { trace(\'v=$$_x\'); }'
		);
		Assert.equals(0, violations(src).length);
	}

	public function testSubclassedNotOverriddenCollapses(): Void {
		// Sub extends Base but overrides NEITHER get_active/set_active nor redeclares `active`
		// (the DarkDropDownListItem shape), so dropping get_active strands no override — collapse.
		final source: String = 'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
			+ '\tfunction get_active():Bool return _active;\n}\nclass Sub extends Base {\n\tpublic function ping():Void {}\n}';
		Assert.equals(1, violations(source).length);
	}

	public function testSubclassReadingBackingFieldCollapsesCrossFile(): Void {
		// Sub extends Base and reads Base's PRIVATE _active directly (legal — subclass-visible). The
		// collapse deletes _active; the cross-file fix rewrites Sub's READ `_active` -> `active` so the
		// property is flagged AND fixed atomically (both slices land in the one source file here).
		final source: String = 'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
			+ '\tfunction get_active():Bool return _active;\n}\nclass Sub extends Base {\n\tpublic function peek():Bool return _active;\n}';
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
		final source: String = 'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
			+ '\tprivate var _other:Int = 0;\n\tfunction get_active():Bool return _active;\n}\nclass Sub extends Base {\n'
			+ '\tpublic function peek():Int return _other;\n}';
		Assert.equals(1, violations(source).length);
	}

	public function testCrossFileSubtypeReadCollapses(): Void {
		// Base in one file, a subtype in ANOTHER file reads Base's private _active. The property is
		// flagged and the cross-file fix collapses Base AND rewrites the subtype's read `_active` -> `active`.
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'Base.hx',
				source: 'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
					+ '\tfunction get_active():Bool return _active;\n}'
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
				source: 'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
					+ '\tfunction get_active():Bool return _active;\n}'
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
				source: 'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
					+ '\tfunction get_active():Bool return _active;\n}'
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
				source: 'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
					+ '\tfunction get_active():Bool return _active;\n}'
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
				source: 'class Base {\n\tpublic var label(get, set):String;\n\tprivate var _label:String = \'\';\n\tfunction '
					+ 'get_label():String return _label;\n\tfunction set_label(v:String):String { redraw(); return _label = v; }\n}'
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

	public function testAbstractOwnerCrossFileSubtypeReadCollapses(): Void {
		// The OWNER is an abstract class; a subtype in another file reads its private backing field.
		// Exercises subtypeRefWalk's owner-span exclusion / cls attribution for AbstractClassDecl:
		// the property collapses AND the subtype's read is renamed `_active` -> `active`.
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'Base.hx',
				source: 'abstract class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
					+ '\tfunction get_active():Bool return _active;\n}'
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
				source: 'class Base {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
					+ '\tfunction get_active():Bool return _active;\n}'
			},
			{ file: 'Mid.hx', source: 'abstract class Mid extends Base {\n\tpublic function reset():Void _active = false;\n}' }
		];
		Assert.equals(0, new TrivialGetter().run(files, new HaxeQueryPlugin()).length);
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
				'class C {\n\t#if cpp\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
				+ '\tprivate function get_active():Bool return _active;\n\t#end\n}'
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
				'class C {\n\t#if cpp\n\tpublic var active(get, never):Bool;\n\t#end\n\tprivate var _active:Bool = false;\n\tprivate '
				+ 'function get_active():Bool return _active;\n\t#if !cpp\n\tpublic function readIt():Bool return _active;\n\t#end\n}'
			).length
		);
	}

	/**
	 * The getter duplicated across branches: the name-keyed table keeps only the LAST branch's, so the
	 * collapse would delete the `#if` branch's side-effecting getter and route the property straight
	 * to storage in that build — output that parses and compiles, and is silently wrong. The gate
	 * requires every touched member to sit in ONE branch.
	 */
	public function testConditionalRivalGettersNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n\t#if debug\n'
				+ '\tprivate function get_active():Bool { trace(\'read\'); return _active; }\n\t#else\n'
				+ '\tprivate function get_active():Bool return _active;\n\t#end\n}'
			).length
		);
	}

	/**
	 * The collapse deletes the backing field and the getter together. When those are all of a
	 * region's members, the result is a bare `#if … #end` the grammar does not model, so the
	 * candidate is refused rather than emitted as a permanently unfixable advisory.
	 */
	public function testConditionalCollapseEmptyingItsRegionNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tpublic var active(get, never):Bool;\n\t#if cpp\n\tprivate var _active:Bool = false;\n'
				+ '\tprivate function get_active():Bool return _active;\n\t#end\n}'
			).length
		);
	}

	/**
	 * A subtype that reaches its supertype through `import p.Owner as O;` must not be left
	 * reading a backing field the collapse deleted. `affectedSubtypeFiles` ran its own
	 * `supertypes.contains(parent)` scan over `allFiles()` instead of the index's subtype
	 * adjacency, so an alias supertype was not a subtype to IT — while `subtypeBlocks` /
	 * `subtypeFieldBlocks`, which do go through the index, saw the same subtype perfectly well on
	 * the same tree. The collapse rewrote only the owner and the tree stopped compiling with
	 * `Unknown identifier : _v` (Haxe 4.3.7); through a written `extends` the same fixture
	 * rewrote both files and compiled, which is what placed the defect in this check rather than
	 * in the index.
	 *
	 * The invariant asserted is the one the compiler enforces — the subtype may keep its `_active`
	 * read only while the owner still declares the field — because it holds for BOTH acceptable
	 * outcomes: rewriting the subtype too, and withholding the collapse. The written-`extends`
	 * control pins the rewriting one, so a green run cannot come from the check going silent
	 * everywhere.
	 */
	public function testAliasImportedSupertypeLeavesNoDanglingBackingRead(): Void {
		assertNoDanglingBackingRead(crossFixApply(aliasSubtypeFiles('import p.Owner as O;\n', 'O')));
		assertNoDanglingBackingRead(crossFixApply(aliasSubtypeFiles('import p.Owner in O;\n', 'O')));
		final plain: Map<String, String> = crossFixApply(aliasSubtypeFiles('', 'Owner'));
		assertNoDanglingBackingRead(plain);
		Assert.isTrue((plain['p/Owner.hx'] ?? '').indexOf('active(default, null):Bool = false') >= 0, 'the control collapses');
		Assert.isTrue((plain['p/Sub.hx'] ?? '').indexOf('return active;') >= 0, 'the control rewrites the subtype read');
	}

	/**
	 * The residue, pinned in the direction it errs. Through an alias the collapse now WITHHOLDS
	 * rather than rewriting both files, because `classifyOwnerBinding` asks `index.isSubtype`,
	 * whose `closureContains` walks UP from the subtype's written supertype name and cannot
	 * resolve an import alias — the mirror of the DOWNWARD gap `subtypesOf` closed. The
	 * occurrence is then neither renamed nor excluded, so the completeness gate blocks the whole
	 * collapse. That is the safe direction and not a regression (it used to emit a fix that broke
	 * the build), but it is not parity with the written-`extends` control above. A slice closing
	 * the upward alias gap should REPLACE this assertion with the rewrite the control pins, never
	 * weaken it.
	 */
	public function testAliasImportedSupertypeWithholdsRatherThanRewriting(): Void {
		Assert.equals(0, new TrivialGetter().run(aliasSubtypeFiles('import p.Owner as O;\n', 'O'), new HaxeQueryPlugin()).length);
		Assert.equals(1, new TrivialGetter().run(aliasSubtypeFiles('', 'Owner'), new HaxeQueryPlugin()).length);
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
			final fileEdits: Array<{ span: Span, text: String }> = byFile[slice.file] ?? [];
			for (e in slice.edits) fileEdits.push(e);
			byFile[slice.file] = fileEdits;
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
				case Err(message):
					Assert.fail('crossFix canonicalize Err ($message)');
					f.source;
			}
		}
		return out;
	}

	/**
	 * An owner whose trivial getter bridges `_active`, and a subtype in ANOTHER file that reads
	 * that field directly. `subImports` is the subtype file's import line (empty for the written
	 * control) and `superName` the name its `extends` clause spells.
	 */
	private function aliasSubtypeFiles(subImports: String, superName: String): Array<{ file: String, source: String }> {
		return [
			{
				file: 'p/Owner.hx',
				source: 'package p;\nclass Owner {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
					+ '\tfunction get_active():Bool return _active;\n}'
			},
			{
				file: 'p/Sub.hx',
				source: 'package p;\n${subImports}class Sub extends $superName {\n\tpublic function peek():Bool return _active;\n}'
			}
		];
	}

	/**
	 * The subtype may still read `_active` only while the owner still declares it — the shape
	 * the compiler refuses otherwise.
	 */
	private function assertNoDanglingBackingRead(out: Map<String, String>): Void {
		final owner: String = out['p/Owner.hx'] ?? '';
		final sub: String = out['p/Sub.hx'] ?? '';
		Assert.isTrue(
			sub.indexOf('_active') < 0 || owner.indexOf('_active') >= 0, 'the subtype reads a backing field the owner no longer declares'
		);
	}

}
