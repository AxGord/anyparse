package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.AvoidDynamic;
import anyparse.check.Check.TypeOracle;
import anyparse.check.Check.Violation;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `avoid-dynamic` DynamicAccess bag FIX (`fixWithOracle`, D4). A `Dynamic` LOCAL /
 * private plain FIELD used exclusively as a string-keyed reflect bag whose values unify to
 * a real type is rewritten to `haxe.DynamicAccess<T>` (+ import) with map syntax; a typeless
 * (`Dynamic` value), heterogeneous, public, or property bag yields no edit. Structural
 * resolution needs no oracle; a field-access value's type is asked of the `TypeOracle`
 * (here a `FakeTypeOracle` double), so both a resolved-real and a resolved-`Dynamic` tail
 * are pinned without spawning a compiler.
 */
class AvoidDynamicBagFixTest extends Test {

	// ---- structural (no oracle query) ----

	public function testStringBagRewrites(): Void {
		final src: String = usingLocal('bag.setField("a", "x");\n\t\tbag.setField("b", "y");');
		final out: String = apply(src, edits(src, new FakeTypeOracle(null)));
		Assert.isTrue(out.indexOf('final bag:DynamicAccess<String> = {}') != -1, out);
		Assert.isTrue(out.indexOf('bag["a"] = "x"') != -1, out);
		Assert.isTrue(out.indexOf('bag["b"] = "y"') != -1, out);
		Assert.isTrue(out.indexOf('import haxe.DynamicAccess;') != -1, out);
	}

	public function testAllOpRewrites(): Void {
		final body: String = 'bag.setField("a", "x");\n\t\tvar h = bag.hasField("a");\n\t\tbag.deleteField("a");\n\t\t'
			+ 'var ks = bag.fields();\n\t\tvar v = Reflect.field(bag, "a");';
		final out: String = apply(usingLocal(body), edits(usingLocal(body), new FakeTypeOracle(null)));
		Assert.isTrue(out.indexOf('bag["a"] = "x"') != -1, out);
		Assert.isTrue(out.indexOf('bag.exists("a")') != -1, out);
		Assert.isTrue(out.indexOf('bag.remove("a")') != -1, out);
		Assert.isTrue(out.indexOf('bag.keys()') != -1, out);
		Assert.isTrue(out.indexOf('bag["a"]') != -1, out);
	}

	public function testTypelessNoEdits(): Void {
		final src: String = 'using Reflect;\nclass C {\n\tfunction f(v:Dynamic):Dynamic {\n\t\tfinal bag:Dynamic = {};\n\t\t'
			+ 'bag.setField("k", v);\n\t\treturn bag;\n\t}\n}';
		Assert.equals(0, edits(src, new FakeTypeOracle(null)).length);
	}

	public function testHeterogeneousNoEdits(): Void {
		Assert.equals(0, edits(usingLocal('bag.setField("i", 1);\n\t\tbag.setField("s", "x");'), new FakeTypeOracle(null)).length);
	}

	// ---- blast-radius ----

	public function testPublicFieldNoEdits(): Void {
		final src: String = 'using Reflect;\nclass C {\n\tpublic var bag:Dynamic;\n\tfunction f():Void {\n\t\t'
			+ 'this.bag.setField("a", "x");\n\t}\n}';
		Assert.equals(0, edits(src, new FakeTypeOracle(null)).length);
	}

	public function testPrivateFieldRewrites(): Void {
		final src: String = 'using Reflect;\nclass C {\n\tvar bag:Dynamic = {};\n\tfunction f():Void {\n\t\t'
			+ 'this.bag.setField("a", "x");\n\t}\n}';
		final out: String = apply(src, edits(src, new FakeTypeOracle(null)));
		Assert.isTrue(out.indexOf('var bag:DynamicAccess<String> = {}') != -1, out);
		Assert.isTrue(out.indexOf('this.bag["a"] = "x"') != -1, out);
	}

	public function testPropertyNoEdits(): Void {
		// A property (get/set accessors) is not a plain field — rewriting its type would need accessor changes.
		final src: String = 'using Reflect;\nclass C {\n\tvar bag(get, set):Dynamic;\n\tfunction f():Void {\n\t\t'
			+ 'this.bag.setField("a", "x");\n\t}\n}';
		Assert.equals(0, edits(src, new FakeTypeOracle(null)).length);
	}

	// ---- oracle tail ----

	public function testOracleTailResolvesReal(): Void {
		// A field-access value the structural pass cannot pin; the oracle names it String.
		final src: String = fieldValueSrc();
		final out: String = apply(src, edits(src, new FakeTypeOracle('String')));
		Assert.isTrue(out.indexOf('final bag:DynamicAccess<String> = {}') != -1, out);
		Assert.isTrue(out.indexOf('bag["k"] = g.value') != -1, out);
	}

	public function testOracleTailDynamicTypeless(): Void {
		// Same shape, but the oracle names the value Dynamic → typeless → no edit.
		Assert.equals(0, edits(fieldValueSrc(), new FakeTypeOracle('Dynamic')).length);
	}

	public function testOracleTailUnresolvedNoEdits(): Void {
		// The oracle cannot name it either → undetermined → no edit.
		Assert.equals(0, edits(fieldValueSrc(), new FakeTypeOracle(null)).length);
	}

	// ---- import handling / idempotency ----

	public function testExistingImportNotDuplicated(): Void {
		final src: String = 'using Reflect;\nimport haxe.DynamicAccess;\nclass C {\n\tfunction f():Dynamic {\n\t\tfinal bag:Dynamic = {};\n\t\t'
			+ 'bag.setField("a", "x");\n\t\treturn bag;\n\t}\n}';
		final e: Array<{ span: Span, text: String }> = edits(src, new FakeTypeOracle(null));
		var importEdits: Int = 0;
		for (ed in e) if (ed.text.indexOf('import haxe.DynamicAccess;') != -1) importEdits++;
		Assert.equals(0, importEdits);
	}

	public function testIdempotent(): Void {
		final src: String = usingLocal('bag.setField("a", "x");');
		final out: String = apply(src, edits(src, new FakeTypeOracle(null)));
		Assert.equals(0, edits(out, new FakeTypeOracle(null)).length);
	}

	public function testNonBagNotEdited(): Void {
		Assert.equals(0, edits(usingLocal('bag.setField("a", "x");\n\t\tbag.other();'), new FakeTypeOracle(null)).length);
	}

	// ---- helpers ----

	private function usingLocal(body: String): String {
		return 'using Reflect;\nclass C {\n\tfunction f():Dynamic {\n\t\tfinal bag:Dynamic = {};\n\t\t$body\n\t\treturn bag;\n\t}\n}';
	}

	private function fieldValueSrc(): String {
		return 'using Reflect;\nclass C {\n\tfunction f(g:G):Dynamic {\n\t\tfinal bag:Dynamic = {};\n\t\t'
			+ 'bag.setField("k", g.value);\n\t\treturn bag;\n\t}\n}\nclass G {\n\tpublic var value:String = "";\n}';
	}

	private function edits(src: String, oracle: TypeOracle): Array<{ span: Span, text: String }> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: AvoidDynamic = new AvoidDynamic();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		return check.fixWithOracle(src, vs, plugin, oracle);
	}

	private function apply(src: String, e: Array<{ span: Span, text: String }>): String {
		final sorted: Array<{ span: Span, text: String }> = e.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (ed in sorted) out = out.substring(0, ed.span.from) + ed.text + out.substring(ed.span.to);
		return out;
	}

}

/** A canned `TypeOracle` for the bag-fix inference tail — returns one fixed type (or null) for every query, no process. */
private class FakeTypeOracle implements TypeOracle {

	private final _answer: Null<String>;

	public function new(answer: Null<String>) {
		_answer = answer;
	}

	public function typeAt(file: String, bytePos: Int): Null<String> {
		return _answer;
	}

}
