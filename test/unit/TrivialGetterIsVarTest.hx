package unit;

import utest.Assert;
import anyparse.check.Check.Violation;
import anyparse.check.TrivialGetter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;

/**
 * The SELF-BACKED arm of `trivial-getter`: a property whose trivial getter returns the property's
 * OWN name, which Haxe allows only when the property has physical storage of its own — either
 * because `@:isVar` grants it (`(get, set)` / `(get, never)`) or because one accessor side is
 * already physical (`(get, null)`). The rule's other arm bridges a SEPARATE private backing field;
 * here the property IS the field, so the collapse deletes no field, renames nothing, and marks no
 * write — external access already routes through the accessors before and after.
 *
 * `@:isVar` is dropped WITH the collapse, never on its own: every collapse target has a physical
 * side, so the meta is dead once the getter is gone, and Haxe rejects the pre-collapse shape
 * without it.
 */
class TrivialGetterIsVarTest extends TrivialGetterCheckTestBase {

	public function testIsVarShapeATrivialGetterRealSetterFlagged(): Void {
		final vs: Array<Violation> = violations(cls(
			'@:isVar public var angle(get, set):Float;\n\tpublic inline function get_angle():Float return angle;\n'
			+ '\tpublic function set_angle(v:Float):Float { redraw(); return angle = v; }'
		));
		Assert.equals(1, vs.length);
		Assert.equals(
			'property \'angle\' is its own backing field; use \'var angle(default, set)\', remove get_angle and drop @:isVar',
			vs[0].message
		);
	}

	public function testIsVarShapeAFixDropsGetterAndMeta(): Void {
		final fixed: String = fixedText(cls(
			'@:isVar public var angle(get, set):Float;\n\tpublic inline function get_angle():Float return angle;\n'
			+ '\tpublic function set_angle(v:Float):Float { redraw(); return angle = v; }'
		));
		Assert.isTrue(fixed.indexOf('public var angle(default, set):Float;') >= 0);
		Assert.equals(-1, fixed.indexOf('@:isVar'));
		Assert.equals(-1, fixed.indexOf('get_angle'));
		Assert.isTrue(fixed.indexOf('set_angle') >= 0);
	}

	/** An external write is NOT marked `@:bypassAccessor`: it routed through `set_angle` before the collapse and still does. */
	public function testIsVarShapeAExternalWriteNotMarked(): Void {
		final fixed: String = fixedText(cls(
			'@:isVar public var angle(get, set):Float;\n\tfunction get_angle():Float return angle;\n'
			+ '\tfunction set_angle(v:Float):Float { redraw(); return angle = v; }\n\tfunction reset():Void { angle = 0; }'
		));
		Assert.equals(-1, fixed.indexOf('@:bypassAccessor'));
		Assert.isTrue(fixed.indexOf('angle(default, set)') >= 0);
		Assert.isTrue(fixed.indexOf('angle = 0;') >= 0);
	}

	public function testIsVarBothTrivialCollapsesToPlainVar(): Void {
		final fixed: String = fixedText(cls(
			'@:isVar public var angle(get, set):Float;\n\tfunction get_angle():Float return angle;\n'
			+ '\tfunction set_angle(v:Float):Float return angle = v;'
		));
		Assert.isTrue(fixed.indexOf('public var angle:Float;') >= 0);
		Assert.equals(-1, fixed.indexOf('@:isVar'));
		Assert.equals(-1, fixed.indexOf('get_angle'));
		Assert.equals(-1, fixed.indexOf('set_angle'));
	}

	public function testIsVarGetNullCollapsesToDefaultNull(): Void {
		final fixed: String = fixedText(cls('@:isVar public var angle(get, null):Float;\n\tfunction get_angle():Float return angle;'));
		Assert.isTrue(fixed.indexOf('public var angle(default, null):Float;') >= 0);
		Assert.equals(-1, fixed.indexOf('@:isVar'));
	}

	/** No `@:isVar` to drop: a `(get, null)` write side is already physical, so the self-backed getter compiles without it. */
	public function testSelfBackedGetNullWithoutMetaCollapses(): Void {
		final fixed: String = fixedText(cls('public var angle(get, null):Float;\n\tfunction get_angle():Float return angle;'));
		Assert.isTrue(fixed.indexOf('public var angle(default, null):Float;') >= 0);
	}

	/** `never` blocks writes everywhere, so the exact-preserving target is `(default, never)`, not the bridged arm's `(default, null)`. */
	public function testIsVarGetNeverCollapsesToDefaultNever(): Void {
		final fixed: String = fixedText(cls('@:isVar public var angle(get, never):Float = 1;\n\tfunction get_angle():Float return angle;'));
		Assert.isTrue(fixed.indexOf('public var angle(default, never):Float = 1;') >= 0);
		Assert.equals(-1, fixed.indexOf('@:isVar'));
	}

	public function testIsVarShapeCTrivialSetterRealGetterCollapses(): Void {
		final fixed: String = fixedText(cls(
			'@:isVar public var angle(get, set):Float;\n\tfunction get_angle():Float { redraw(); return angle * 2; }\n'
			+ '\tfunction set_angle(v:Float):Float return angle = v;'
		));
		Assert.isTrue(fixed.indexOf('public var angle(get, default):Float;') >= 0);
		Assert.equals(-1, fixed.indexOf('@:isVar'));
		Assert.equals(-1, fixed.indexOf('set_angle'));
		Assert.isTrue(fixed.indexOf('get_angle') >= 0);
	}

	/** Only the `@:isVar` token goes; a sibling metadata annotation on the same line survives. */
	public function testIsVarDropsOnlyItsOwnMeta(): Void {
		final fixed: String = fixedText(
			cls('@:isVar @:noCompletion public var angle(get, null):Float;\n\tfunction get_angle():Float return angle;')
		);
		Assert.isTrue(fixed.indexOf('@:noCompletion public var angle(default, null):Float;') >= 0);
		Assert.equals(-1, fixed.indexOf('@:isVar'));
	}

	/** A meta alone on its line takes the line with it, not just the token. */
	public function testIsVarOnOwnLineRemovesTheLine(): Void {
		final fixed: String = fixedText(
			'class C {\n\t@:isVar\n\tpublic var angle(get, null):Float;\n\tfunction get_angle():Float return angle;\n}'
		);
		Assert.equals(-1, fixed.indexOf('@:isVar'));
		Assert.isTrue(fixed.indexOf('public var angle(default, null):Float;') >= 0);
	}

	/** The subtype gate is the bridged arm's `subtypeOverridesProperty`, and it covers the self-backed arm unchanged. */
	public function testSubclassOverridingAccessorNotFlagged(): Void {
		final base: String = 'class C {\n\t@:isVar public var angle(get, set):Float;\n\tfunction get_angle():Float return angle;\n'
			+ '\tfunction set_angle(v:Float):Float { redraw(); return angle = v; }\n}';
		final sub: String = 'class D extends C {\n\toverride function get_angle():Float return 0;\n}';
		final vs: Array<Violation> = new TrivialGetter().run(
			[{ file: 'C.hx', source: base }, { file: 'D.hx', source: sub }], new HaxeQueryPlugin()
		);
		Assert.equals(0, vs.length);
	}

	/** A subtype merely READING the property is fine — the property survives the collapse, so nothing is stranded. */
	public function testSubclassReadingPropertyStillCollapses(): Void {
		final base: String = 'class C {\n\t@:isVar public var angle(get, set):Float;\n\tfunction get_angle():Float return angle;\n'
			+ '\tfunction set_angle(v:Float):Float { redraw(); return angle = v; }\n}';
		final sub: String = 'class D extends C {\n\tfunction show():Void { trace(angle); }\n}';
		final vs: Array<Violation> = new TrivialGetter().run(
			[{ file: 'C.hx', source: base }, { file: 'D.hx', source: sub }], new HaxeQueryPlugin()
		);
		Assert.equals(1, vs.length);
	}

	/** An `override` getter answers a supertype contract the collapse would silently break. */
	public function testOverrideGetterNotFlagged(): Void {
		final vs: Array<Violation> = violations(
			cls('@:isVar public var angle(get, null):Float;\n\toverride function get_angle():Float return angle;')
		);
		Assert.equals(0, vs.length);
	}

	/** An implemented interface may require the physical accessor, so an unresolvable one keeps blocking. */
	public function testImplementedInterfaceBlocks(): Void {
		final src: String =
			'class C implements I {\n\t@:isVar public var angle(get, null):Float;\n\tfunction get_angle():Float return angle;\n}';
		Assert.equals(0, violations(src).length);
	}

	/** A `dynamic` getter is real re-bindable behaviour and never collapses. */
	public function testDynamicGetterNotFlagged(): Void {
		final vs: Array<Violation> = violations(
			cls('@:isVar public var angle(get, null):Float;\n\tdynamic function get_angle():Float return angle;')
		);
		Assert.equals(0, vs.length);
	}

	/** The self-backed arm registers no cross-file rename: nothing is deleted, so there is nothing to rewrite elsewhere. */
	public function testNoCrossFileRenameForSelfBacked(): Void {
		final base: String = 'class C {\n\t@:isVar public var angle(get, set):Float;\n\tfunction get_angle():Float return angle;\n'
			+ '\tfunction set_angle(v:Float):Float { redraw(); return angle = v; }\n}';
		final sub: String = 'class D extends C {\n\tfunction show():Void { trace(angle); }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: base }, { file: 'D.hx', source: sub }];
		final r: { check: TrivialGetter, vs: Array<Violation> } = runFilesAndExpectOne(files);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.equals(0, r.check.crossFileFix(files, r.vs, plugin, SymbolIndex.build(files, plugin)).length);
	}

}
