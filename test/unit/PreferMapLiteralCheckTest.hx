package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferMapLiteral;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import anyparse.query.SymbolIndex;

/**
 * The `prefer-map-literal` check: an empty-argument `new Map()` / `new Map<K, V>()` is
 * flagged `Info` and rewritten to `[]`. A non-Map construction and a `new Array()` are
 * left alone.
 */
class PreferMapLiteralCheckTest extends Test {

	public function testNewMapTypedFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('new Map<Int, Int>()'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-map-literal', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this new Map() can be the map literal []', vs[0].message);
	}

	public function testNewMapBareFlagged(): Void {
		Assert.equals(1, violations(wrap('new Map()')).length);
	}

	public function testArrayNotFlagged(): Void {
		Assert.equals(0, violations(wrap('new Array()')).length);
	}

	public function testOtherTypeNotFlagged(): Void {
		Assert.equals(0, violations(wrap('new Foo()')).length);
	}

	/** A typed local declaration pins the key/value types — the `new Map()` is rewritten to `[]`. */
	public function testFixTypedMap(): Void {
		Assert.equals('[]', fixText('class C { function f():Void { var m:Map<Int, Int> = new Map(); } }'));
	}

	/** A typed field default pins the key/value types — rewritten to `[]`. */
	public function testFixTypedField(): Void {
		Assert.equals('[]', fixText('class C { public var m:Map<String, Int> = new Map(); }'));
	}

	/** The critical case: an unannotated `var m = new Map()` is NOT pinned — `[]` infers `Array`, not `Map`, so rewriting it would miscompile. Reported, not fixed. */
	public function testGateRefusesUntypedLocal(): Void {
		assertGateRefuses('class C { function f():Void { var m = new Map(); } }');
	}

	/** An unannotated local whose only type source is the constructor `<Int, Int>` is NOT pinned — `[]` drops the key/value types and infers Array. */
	public function testGateRefusesUntypedTypeParam(): Void {
		assertGateRefuses('class C { function f():Void { var m = new Map<Int, Int>(); } }');
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-map-literal'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-map-literal'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/** A plain assignment to a bare-identifier field whose declaration pins the key/value types — rewritten to `[]`. */
	public function testFixBareIdentFieldAssignment(): Void {
		Assert.equals('[]', fixText('class C { var _m:Map<Int, String>; function f():Void { _m = new Map(); } }'));
	}

	/** A `this.<field>` Map assignment resolves the field type through the SymbolIndex — rewritten to `[]`. */
	public function testFixThisFieldAssignment(): Void {
		Assert.equals('[]', fixTextIndexed('class C { var m:Map<Int, String>; function f():Void { this.m = new Map(); } }'));
	}

	/** SOUNDNESS: a `new Map()` assigned to a `Dynamic`-typed target must NOT become `[]` (which would infer Array). Reported, no edit. */
	public function testGateRefusesDynamicTargetAssignment(): Void {
		assertGateRefuses('class C { var d:Dynamic; function f():Void { d = new Map(); } }');
	}

	/** SOUNDNESS: a `this.<field>` Map assignment whose field is `Dynamic` must NOT become `[]`, even with an index threaded. Reported, no edit. */
	public function testGateRefusesDynamicThisTargetWithIndex(): Void {
		final src: String = 'class C { var d:Dynamic; function f():Void { this.d = new Map(); } }';
		Assert.equals(1, violations(src).length);
		Assert.equals('<0 edits>', fixTextIndexed(src));
	}

	private function wrap(expr: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\tvar x = $expr;\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new PreferMapLiteral().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixText(src: String): String {
		final check: PreferMapLiteral = new PreferMapLiteral();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		return edits.length == 1 ? edits[0].text : '<${edits.length} edits>';
	}

	/** Assert `src` is reported (one finding) yet gate-refused (no fix edit). */
	private function assertGateRefuses(src: String): Void {
		Assert.equals(1, violations(src).length);
		Assert.equals('<0 edits>', fixText(src));
	}

	private function fixTextIndexed(src: String): String {
		final check: PreferMapLiteral = new PreferMapLiteral();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		final idx: SymbolIndex = SymbolIndex.build(files, plugin);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run(files, plugin), plugin, idx);
		return edits.length == 1 ? edits[0].text : '<${edits.length} edits>';
	}

}
