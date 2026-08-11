package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.ExplicitLocalType;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;

/**
 * The `explicit-local-type` autofix's INDEX-ACCESS arm: `container[key]` annotates the local with
 * the type argument the grammar's `indexedElementTypeParams` names, wrapped `Null<…>` for a map.
 * Split out of `ExplicitLocalTypeCheckTest` (as `ExplicitLocalTypePrinterTest` was) because the arm
 * carries a gate set of its own: the container must resolve to a same-file binding whose written
 * type carries arguments, its nominal must be tabled AND unshadowed by a non-std indexed type, the
 * element must not be `Dynamic` (which the compiler leaves an unbound monomorph rather than
 * inferring), and an anonymous-structure element is subject to the `maxInferredTypeLength` cap.
 */
class ExplicitLocalTypeIndexAccessTest extends Test {

	public inline function testFixMapIndexAccessIsNullableValue(): Void {
		// The TM macro-context shape: `final foundKeys = strings[key];` on a
		// `Map<String, Array<String>>` — the VALUE parameter, wrapped `Null<…>` as Haxe types it.
		assertFixContains('final m:Map<String, Array<String>> = [];\n\t\tfinal v = m["a"];', 'v:Null<Array<String>>');
	}

	public inline function testFixArrayIndexAccessIsElement(): Void {
		// An `Array<T>` subscript is `T`, NOT `Null<T>` — only the map family is nullable-indexed.
		assertFixContains('final a:Array<Int> = [];\n\t\tfinal v = a[0];', 'v:Int');
	}

	public inline function testFixNullWrappedMapIndexAccess(): Void {
		// One `Null<…>` wrapper is peeled off the container before the element lookup.
		assertFixContains('final m:Null<Map<String, Int>> = null;\n\t\tfinal v = m["a"];', 'v:Null<Int>');
	}

	public inline function testSkipIndexAccessUnresolvedContainer(): Void {
		// The container carries no written type — the element parameter cannot be read.
		assertNoFix('final m = makeMap();\n\t\tfinal v = m["a"];');
	}

	public inline function testSkipIndexAccessUnknownContainerType(): Void {
		// A container whose nominal names no `indexedElementTypeParams` entry (a user abstract with
		// its own `@:arrayAccess`) yields nothing — the element type is not derivable from the
		// written type. GENERIC on purpose, so the walk reaches the table lookup instead of dying at
		// the no-arguments guard the sibling test pins.
		assertNoFix('final b:Bag<Int> = null;\n\t\tfinal v = b["a"];');
	}

	public inline function testSkipIndexAccessDynamicElement(): Void {
		// `Array<Dynamic>[0]` does NOT infer `Dynamic` — the compiler leaves the local an unbound
		// monomorph that unifies with its first real use, so writing `:Dynamic` would SILENCE errors
		// it would otherwise raise.
		assertNoFix('final a:Array<Dynamic> = [];\n\t\tfinal e = a[0];');
	}

	public inline function testSkipIndexAccessDynamicMapValue(): Void {
		assertNoFix('final m:Map<String, Dynamic> = [];\n\t\tfinal e = m["a"];');
	}

	public inline function testSkipIndexAccessContainerWithoutTypeArguments(): Void {
		// The defensive no-arguments guard. `Map` with no parameters is not legal Haxe, so this pins
		// the guard rather than a shape real source produces — the reachable case is a written type
		// `typeArgumentSourcesOf` cannot split (a function type whose result is generic).
		assertNoFix('final m:Map = null;\n\t\tfinal v = m["a"];');
	}

	public inline function testFixIndexAccessSmallAnonElement(): Void {
		// Under the cap, an anon-struct element still annotates — the gate is length, not shape.
		assertFixContains('final rows:Array<{a:Int}> = [];\n\t\tfinal r = rows[0];', 'r:{a:Int}');
	}

	public inline function testSkipIndexAccessRestParamContainer(): Void {
		// A rest parameter's BODY type is `haxe.Rest<Array<Int>>` while its written source is the
		// bare `Array<Int>`, so `xs[0]` is an `Array<Int>` — copying the source would say `Int`.
		assertNoFixSrc('class C {\n\tfunction f(...xs:Array<Int>):Void {\n\t\tfinal v = xs[0];\n\t}\n}');
	}

	public function testSkipIndexAccessShadowedContainerNominal(): Void {
		// The table is keyed on the SIMPLE name, so an indexed PROJECT `Vector<T>` with its own
		// `@:arrayAccess` would be read as the stdlib one and annotated `Int` where the real return
		// is `Null<Int>`. Every sibling arm carries this shadow gate; so does this one.
		assertNoFixIdx(wrap('final v:Vector<Int> = null;\n\t\tfinal e = v[0];'), [
			{
				file: 'mypkg/Vector.hx',
				source: 'package mypkg;\nabstract Vector<T>(Array<T>) {\n'
				+ '\t@:arrayAccess public inline function get(i:Int):Null<T> return this[i];\n}'
			}
		]);
	}

	public function testSkipIndexAccessOversizedAnonElement(): Void {
		// An anonymous-structure element over the `maxInferredTypeLength` cap is declined exactly as
		// the oracle tail declines one — the rule's output must not depend on which tier named it.
		assertNoFix(
			'final rows:Array<{alpha:String, beta:String, gamma:String, delta:String, epsilon:String, zeta:String, eta:String}> = [];\n'
			+ '\t\tfinal r = rows[0];'
		);
	}

	private function wrap(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t$body\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new ExplicitLocalType().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function assertFixContains(body: String, expected: String): Void {
		final src: String = wrap(body);
		final check: ExplicitLocalType = new ExplicitLocalType();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.isTrue(vs.length >= 1);
		switch RefactorSupport.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(expected) >= 0, text);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function assertNoFix(body: String): Void {
		assertNoFixSrc(wrap(body));
	}

	private function assertNoFixSrc(src: String): Void {
		Assert.equals(0, new ExplicitLocalType().fix(src, violations(src), new HaxeQueryPlugin()).length);
	}

	/** Fix `fixSrc` (as `C.hx`) with a `SymbolIndex` built over it plus `otherFiles`, and assert no edit is produced. */
	private function assertNoFixIdx(fixSrc: String, otherFiles: Array<{ file: String, source: String }>): Void {
		final check: ExplicitLocalType = new ExplicitLocalType();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final fixFile: { file: String, source: String } = { file: 'C.hx', source: fixSrc };
		final index: SymbolIndex = SymbolIndex.build([fixFile].concat(otherFiles), plugin);
		Assert.equals(0, check.fix(fixSrc, check.run([fixFile], plugin), plugin, index).length);
	}

}
