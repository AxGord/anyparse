package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.RedundantBypassAccessor;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `redundant-bypass-accessor` check: a `@:bypassAccessor` on a plain-`=`
 * assignment whose lvalue resolves to an own-class member with no set-accessor (a
 * plain `var` / `final`, or a `(_, default|null|never)` property) is a stale meta -
 * flagged `Info`, and `fix` removes the `@:bypassAccessor ` token. A member with a
 * real setter, a compound assign, a non-member lvalue, and a bare meta-less
 * assignment are all left alone.
 */
class RedundantBypassAccessorCheckTest extends Test {

	public function testNullWriteSlotFlagged(): Void {
		final src: String = 'class C {\n\tpublic var align(default, null):String;\n\tpublic function new(align:String) {\n\t\t@:bypassAccessor this.align = align;\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('redundant-bypass-accessor', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this @:bypassAccessor bypasses a set-accessor that align does not have', vs[0].message);
	}

	public function testPlainVarFlagged(): Void {
		Assert.equals(
			1, violations('class C {\n\tvar align:Int;\n\tfunction f():Void {\n\t\t@:bypassAccessor this.align = 1;\n\t}\n}').length
		);
	}

	public function testFinalFieldFlagged(): Void {
		final src: String = 'class C {\n\tfinal align:Int;\n\tpublic function new() {\n\t\t@:bypassAccessor this.align = 1;\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testGetDefaultWriteSlotFlagged(): Void {
		final src: String = 'class C {\n\tpublic var align(get, default):Int;\n\tfunction get_align():Int return 1;\n\tfunction f():Void {\n\t\t@:bypassAccessor this.align = 1;\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testBareIdentLvalueFlagged(): Void {
		final src: String = 'class C {\n\tpublic var align(default, null):Int;\n\tfunction f():Void {\n\t\t@:bypassAccessor align = 1;\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testSetterNotFlagged(): Void {
		// `(default, set)` has a real setter, so bypassing it is meaningful.
		final src: String = 'class C {\n\tpublic var align(default, set):Int;\n\tfunction set_align(v:Int):Int return v;\n\tfunction f():Void {\n\t\t@:bypassAccessor this.align = 1;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testGetSetNotFlagged(): Void {
		final src: String = 'class C {\n\tpublic var align(get, set):Int;\n\tfunction get_align():Int return 1;\n\tfunction set_align(v:Int):Int return v;\n\tfunction f():Void {\n\t\t@:bypassAccessor this.align = 1;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testCompoundAssignNotFlagged(): Void {
		// `+=` also reads the member; a compound assign is out of scope.
		Assert.equals(
			0, violations('class C {\n\tvar align:Int;\n\tfunction f():Void {\n\t\t@:bypassAccessor this.align += 1;\n\t}\n}').length
		);
	}

	public function testLocalLvalueNotFlagged(): Void {
		// `align` is a local, not a member - nothing to resolve.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar align:Int = 0;\n\t\t@:bypassAccessor align = 1;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testInheritedMemberNotFlagged(): Void {
		// `align` is not declared in this class (maybe inherited) - write slot unknown.
		final src: String = 'class C extends Base {\n\tfunction f():Void {\n\t\t@:bypassAccessor this.align = 1;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testNoMetaNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tvar align:Int;\n\tfunction f():Void {\n\t\tthis.align = 1;\n\t}\n}').length);
	}

	public function testFixRemovesMeta(): Void {
		final src: String = 'class C {\n\tpublic var align(default, null):String;\n\tpublic function new(align:String) {\n\t\t@:bypassAccessor this.align = align;\n\t}\n}';
		final want: String = 'class C {\n\tpublic var align(default, null):String;\n\tpublic function new(align:String) {\n\t\tthis.align = align;\n\t}\n}';
		Assert.equals(want, applyFix(src));
	}

	public function testFixKeepsOtherStackedMeta(): Void {
		final src: String = 'class C {\n\tvar align:Int;\n\tfunction f():Void {\n\t\t@:keep @:bypassAccessor this.align = 1;\n\t}\n}';
		final want: String = 'class C {\n\tvar align:Int;\n\tfunction f():Void {\n\t\t@:keep this.align = 1;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(want, applyFix(src));
	}

	public function testReverseStackedMetaFlaggedAndFixed(): Void {
		final src: String = 'class C {\n\tvar align:Int;\n\tfunction f():Void {\n\t\t@:bypassAccessor @:keep this.align = 1;\n\t}\n}';
		final want: String = 'class C {\n\tvar align:Int;\n\tfunction f():Void {\n\t\t@:keep this.align = 1;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(want, applyFix(src));
	}

	public function testCrossReceiverNotFlagged(): Void {
		final src: String = 'class C {\n\tvar other:C;\n\tvar align:Int;\n\tfunction f():Void {\n\t\t@:bypassAccessor other.align = 1;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testIndexAccessLvalueNotFlagged(): Void {
		final src: String = 'class C {\n\tvar arr:Array<Int>;\n\tfunction f():Void {\n\t\t@:bypassAccessor this.arr[0] = 1;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-bypass-accessor'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-bypass-accessor'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { @:bypassAccessor this.x = ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantBypassAccessor().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: RedundantBypassAccessor = new RedundantBypassAccessor();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
