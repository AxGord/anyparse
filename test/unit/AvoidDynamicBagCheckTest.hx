package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.AvoidDynamic;
import anyparse.check.Check.Violation;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `avoid-dynamic` DynamicAccess bag DETECTION / report (D4). A `Dynamic` used
 * EXCLUSIVELY as a string-keyed reflect bag is re-messaged per its value-type
 * unification: convertible (`Real`), typeless (`Dynamic` values — the owner-rejected
 * `DynamicAccess<Dynamic>` shape), heterogeneous, or unresolved. A non-bag use (a member
 * call, an operator) keeps the generic message; both direct `Reflect.*` and `using
 * Reflect` extension call shapes are recognised, on locals and fields. Structural
 * inference only (the report has no compiler oracle).
 */
class AvoidDynamicBagCheckTest extends Test {

	// ---- bag verdicts ----

	public function testStringBagConvertible(): Void {
		final m: String = bagMsg(usingLocal('bag.setField("a", "s1");\n\t\tbag.setField("b", "s2");'));
		Assert.isTrue(m.indexOf('string-keyed bag') != -1, m);
		Assert.isTrue(m.indexOf('DynamicAccess<String>') != -1, m);
	}

	public function testTypelessDynamicValue(): Void {
		// A value of Dynamic type: DynamicAccess<Dynamic> is rejected → typeless verdict.
		final src: String = 'using Reflect;\nclass C {\n\tfunction f(v:Dynamic):Dynamic {\n\t\tfinal bag:Dynamic = {};\n\t\t'
			+ 'bag.setField("k", v);\n\t\treturn bag;\n\t}\n}';
		final m: String = bagMsg(src);
		Assert.isTrue(m.indexOf('values are themselves Dynamic') != -1, m);
		Assert.isTrue(m.indexOf('adds nothing over Dynamic') != -1, m);
	}

	public function testHeterogeneousValues(): Void {
		final m: String = bagMsg(usingLocal('bag.setField("i", 1);\n\t\tbag.setField("s", "x");'));
		Assert.isTrue(m.indexOf('mixed value types') != -1, m);
	}

	public function testUnresolvedValue(): Void {
		// A field-access value the structural pass cannot pin, and no oracle → undetermined.
		final src: String = 'using Reflect;\nclass C {\n\tfunction f(g:G):Dynamic {\n\t\tfinal bag:Dynamic = {};\n\t\t'
			+ 'bag.setField("k", g.value);\n\t\treturn bag;\n\t}\n}\nclass G {\n\tpublic var value:String = "";\n}';
		final m: String = bagMsg(src);
		Assert.isTrue(m.indexOf('rejected typeless shape') != -1, m);
	}

	// ---- op shapes ----

	public function testDirectReflectCalls(): Void {
		final src: String = 'class C {\n\tfunction f():Dynamic {\n\t\tfinal bag:Dynamic = {};\n\t\tReflect.setField(bag, "a", "x");\n\t\t'
			+ 'return Reflect.field(bag, "a");\n\t}\n}';
		Assert.isTrue(bagMsg(src).indexOf('DynamicAccess<String>') != -1);
	}

	public function testUsingExtensionCalls(): Void {
		Assert.isTrue(bagMsg(usingLocal('bag.setField("a", "x");\n\t\tvar b = bag.hasField("a");')).indexOf('DynamicAccess<String>') != -1);
	}

	// ---- non-bag shapes stay generic ----

	public function testMemberCallDisqualifies(): Void {
		// `bag.other()` is a method call on the value, not a reflect op → not a bag.
		final m: String = bagMsg(usingLocal('bag.setField("a", "x");\n\t\tbag.other();'));
		Assert.equals(-1, m.indexOf('string-keyed bag'), m);
	}

	public function testNonReflectCallArgDisqualifies(): Void {
		// Passing the bag as a plain argument is a value use, not a reflect op.
		final m: String = bagMsg(usingLocal('bag.setField("a", "x");\n\t\tsink(bag);'));
		Assert.equals(-1, m.indexOf('string-keyed bag'), m);
	}

	public function testWithoutUsingReflectExtensionDisqualifies(): Void {
		// No `using Reflect` → `bag.setField(...)` is a dynamic method call, not a reflect op.
		final src: String = 'class C {\n\tfunction f():Dynamic {\n\t\tfinal bag:Dynamic = {};\n\t\tbag.setField("a", "x");\n\t\t'
			+ 'return bag;\n\t}\n}';
		Assert.equals(-1, bagMsg(src).indexOf('string-keyed bag'));
	}

	// ---- flow-out neutrality ----

	public function testReturnAsDynamicNeutral(): Void {
		// A bag returned where the enclosing function returns Dynamic stays a bag (DynamicAccess -> Dynamic is total).
		Assert.isTrue(bagMsg(usingLocal('bag.setField("a", "x");')).indexOf('string-keyed bag') != -1);
	}

	public function testReturnAsNonDynamicDisqualifies(): Void {
		// Returning the bag where a non-Dynamic type is expected would break the conversion → not a bag.
		final src: String = 'using Reflect;\nclass C {\n\tfunction f():Foo {\n\t\tfinal bag:Dynamic = {};\n\t\t'
			+ 'bag.setField("a", "x");\n\t\treturn bag;\n\t}\n}\nclass Foo {}';
		Assert.equals(-1, bagMsg(src).indexOf('string-keyed bag'));
	}

	// ---- fields ----

	public function testPrivateFieldBag(): Void {
		final src: String = 'using Reflect;\nclass C {\n\tvar bag:Dynamic = {};\n\tfunction f():Void {\n\t\t'
			+ 'this.bag.setField("a", "x");\n\t}\n}';
		Assert.isTrue(bagMsg(src).indexOf('DynamicAccess<String>') != -1);
	}

	public function testPublicFieldBagReportedToo(): Void {
		// The report flags a public field bag as well (the blast-radius gate only restricts the FIX).
		final src: String = 'using Reflect;\nclass C {\n\tpublic var bag:Dynamic;\n\tfunction f():Void {\n\t\t'
			+ 'this.bag.setField("a", "x");\n\t}\n}';
		Assert.isTrue(bagMsg(src).indexOf('DynamicAccess<String>') != -1);
	}

	// ---- helpers ----

	private function usingLocal(body: String): String {
		return 'using Reflect;\nclass C {\n\tfunction f():Dynamic {\n\t\tfinal bag:Dynamic = {};\n\t\t$body\n\t\treturn bag;\n\t}\n}';
	}

	private function bagMsg(src: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: AvoidDynamic = new AvoidDynamic();
		for (v in check.run([{ file: 'C.hx', source: src }], plugin)) if (v.message.indexOf('string-keyed bag') != -1) return v.message;
		return '';
	}

}
