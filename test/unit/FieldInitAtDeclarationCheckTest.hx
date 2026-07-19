package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.FieldInitAtDeclaration;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `field-init-at-declaration` check: an instance field (`var` or `final`) with no
 * declaration initializer whose sole write is one unconditional top-level constructor
 * statement with a context-free right-hand side is flagged `Info`, and the fix moves
 * `= expr` onto the declaration and deletes the constructor statement. A static field,
 * a property, a right-hand side referencing a constructor parameter / `this` / another
 * instance member, a multiple-write / conditional / non-constructor write, and a class
 * without a single constructor are left alone.
 */
class FieldInitAtDeclarationCheckTest extends Test {

	public function testInstanceVarMoved(): Void {
		final vs: Array<Violation> = violations('class C { private var _a:Array<Int>; public function new() { _a = new Array<Int>(); } }');
		Assert.equals(1, vs.length);
		Assert.equals('field-init-at-declaration', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testInstanceFinalMoved(): Void {
		Assert.equals(1, violations('class C { private final _b:Array<Int>; public function new() { _b = new Array<Int>(); } }').length);
	}

	/** The repro shape: a no-init field initialised with `new Array<Int>()` in the constructor. */
	public function testNewArrayMoved(): Void {
		Assert.equals(
			1, violations('class C { private var _nums:Array<Int>; public function new() { _nums = new Array<Int>(); } }').length
		);
	}

	/** A static field's init timing is unrelated to instance construction — left alone. */
	public function testStaticNotMoved(): Void {
		Assert.equals(0, violations('class C { static var _s:Int; public function new() { _s = 5; } }').length);
	}

	/** A property (a `(` in the declaration head) is skipped. */
	public function testPropertyNotMoved(): Void {
		Assert.equals(0, violations('class C { public var x(default, null):Int; public function new() { x = 5; } }').length);
	}

	/** A right-hand side referencing a constructor parameter is order-dependent — left alone. */
	public function testCtorParamRefNotMoved(): Void {
		Assert.equals(0, violations('class C { private var _x:Int; public function new(p:Int) { _x = p; } }').length);
	}

	/** A right-hand side referencing another instance member is order-dependent — left alone. */
	public function testInstanceMemberRefNotMoved(): Void {
		Assert.equals(0, violations('class C { var _a:Int = 1; var _x:Int; public function new() { _x = _a; } }').length);
	}

	/** A right-hand side referencing `this` is order-dependent — left alone. */
	public function testThisRefNotMoved(): Void {
		Assert.equals(0, violations('class C { private var _self:C; public function new() { _self = this; } }').length);
	}

	/** A field with no constructor at all has no init to move — left alone. */
	public function testNoConstructorNotMoved(): Void {
		Assert.equals(0, violations('class C { private var _x:Int; }').length);
	}

	/** A field written twice in the constructor is not single-write — left alone. */
	public function testWrittenTwiceNotMoved(): Void {
		Assert.equals(0, violations('class C { private var _x:Int; public function new() { _x = 1; _x = 2; } }').length);
	}

	/** A field assigned only conditionally (not a top-level constructor statement) — left alone. */
	public function testConditionalNotMoved(): Void {
		Assert.equals(0, violations('class C { private var _x:Int; public function new(c:Bool) { if (c) _x = 1; } }').length);
	}

	/** A field also written in another method (write count > 1) — left alone. */
	public function testWrittenInMethodNotMoved(): Void {
		Assert.equals(
			0, violations('class C { private var _x:Int; public function new() { _x = 1; } function s():Void { _x = 2; } }').length
		);
	}

	/** A static reference in the right-hand side is available at declaration-init time — moved. */
	public function testStaticRefMoved(): Void {
		Assert.equals(1, violations('class C { static var _base:Int = 5; var _x:Int; public function new() { _x = _base; } }').length);
	}

	/** The fix inserts `= expr` on the declaration and deletes the constructor statement. */
	public function testFixMovesInit(): Void {
		final fixed: String = fixedSource(
			'class C {\n\tprivate var _a:Array<Int>;\n\tpublic function new() {\n\t\t_a = new Array<Int>();\n\t}\n}'
		);
		Assert.isTrue(fixed.indexOf('private var _a:Array<Int> = new Array<Int>();') >= 0);
		Assert.equals(-1, fixed.indexOf('_a = new'));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('field-init-at-declaration'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('field-init-at-declaration'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { var _x = ').length);
	}

	/** A field READ in the constructor before its assignment would change value if moved — left alone. */
	public function testReadBeforeWriteNotMoved(): Void {
		Assert.equals(0, violations('class C { private var _x:Int; public function new() { trace(_x); _x = 5; } }').length);
	}

	/** A field read only AFTER its constructor assignment is safe to move — flagged. */
	public function testReadAfterWriteMoved(): Void {
		Assert.equals(1, violations('class C { private var _x:Int; public function new() { _x = 5; trace(_x); } }').length);
	}

	/** A `this.field = expr` target is recognised — flagged. */
	public function testThisTargetMoved(): Void {
		Assert.equals(1, violations('class C { private var _y:Int; public function new() { this._y = 7; } }').length);
	}

	/** A right-hand side calling an instance method is order-dependent — left alone. */
	public function testInstanceMethodCallRhsNotMoved(): Void {
		Assert.equals(
			0, violations('class C { private var _x:Int; function h():Int return 1; public function new() { _x = h(); } }').length
		);
	}

	/** A `new T(param)` whose argument references a constructor parameter is order-dependent — left alone. */
	public function testNewWithParamArgNotMoved(): Void {
		Assert.equals(0, violations('class C { private var _o:Foo; public function new(p:Int) { _o = new Foo(p); } }').length);
	}

	private function violations(src: String): Array<Violation> {
		return new FieldInitAtDeclaration().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixedSource(src: String): String {
		final check: FieldInitAtDeclaration = new FieldInitAtDeclaration();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in sorted) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
