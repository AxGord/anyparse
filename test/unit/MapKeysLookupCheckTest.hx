package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.MapKeysLookup;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;

/**
 * The `map-keys-lookup` check: a `for (k in m.keys())` loop whose body re-looks-up the
 * same map by the same key (`m[k]` / `m.get(k)`) is flagged `Info`, with an autofix applying the key-value rewrite. Soundness misses: a body with no matching lookup,
 * a different key or a different map, any mutation of the map (`m[k] =` / `m.set` /
 * `m.remove` / `m.clear`), a re-binding shadowing `k` or `m`, a chained (non-identifier)
 * receiver, and a receiver resolving to a concrete non-map type. An unresolvable receiver
 * type still flags — `.keys()` plus a same-key lookup is Map-shaped by construction.
 */
class MapKeysLookupCheckTest extends Test {

	public function testIndexLookupFlagged(): Void {
		final vs: Array<Violation> = violations(wrapMap('for (k in m.keys()) trace(m[k]);'));
		Assert.equals(1, vs.length);
		Assert.equals('map-keys-lookup', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('iterate key-value instead of keys()-then-lookup — for (k => value in m)', vs[0].message);
	}

	public function testGetLookupFlagged(): Void {
		Assert.equals(1, violations(wrapMap('for (k in m.keys()) trace(m.get(k));')).length);
	}

	public function testBracedBodyFlagged(): Void {
		Assert.equals(1, violations(wrapMap('for (k in m.keys()) {\n\t\t\tfinal v = m[k];\n\t\t\ttrace(v);\n\t\t}')).length);
	}

	public function testNoLookupNotFlagged(): Void {
		Assert.equals(0, violations(wrapMap('for (k in m.keys()) trace(k);')).length);
	}

	public function testDifferentKeyNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(m:Map<String,Int>, j:String):Void {\n\t\tfor (k in m.keys()) trace(m[j]);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testDifferentMapNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(m:Map<String,Int>, n:Map<String,Int>):Void {\n\t\tfor (k in m.keys()) trace(n[k]);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testIndexWriteNotFlagged(): Void {
		Assert.equals(0, violations(wrapMap('for (k in m.keys()) {\n\t\t\ttrace(m[k]);\n\t\t\tm[k] = 1;\n\t\t}')).length);
	}

	public function testSetWriteNotFlagged(): Void {
		Assert.equals(0, violations(wrapMap('for (k in m.keys()) {\n\t\t\ttrace(m[k]);\n\t\t\tm.set(k, 1);\n\t\t}')).length);
	}

	public function testRemoveWriteNotFlagged(): Void {
		Assert.equals(0, violations(wrapMap('for (k in m.keys()) {\n\t\t\ttrace(m[k]);\n\t\t\tm.remove(k);\n\t\t}')).length);
	}

	public function testShadowedKeyNotFlagged(): Void {
		Assert.equals(0, violations(wrapMap('for (k in m.keys()) {\n\t\t\tfinal k = 5;\n\t\t\ttrace(m[k]);\n\t\t}')).length);
	}

	public function testShadowedMapByNestedLoopNotFlagged(): Void {
		Assert.equals(0, violations(wrapMap('for (k in m.keys()) for (m in rows) trace(m[k]);')).length);
	}

	public function testCompoundAssignWriteNotFlagged(): Void {
		Assert.equals(0, violations(wrapMap('for (k in m.keys()) {\n\t\t\ttrace(m[k]);\n\t\t\tm[k] += 1;\n\t\t}')).length);
	}

	public function testIncrementWriteNotFlagged(): Void {
		Assert.equals(0, violations(wrapMap('for (k in m.keys()) {\n\t\t\ttrace(m[k]);\n\t\t\tm[k]++;\n\t\t}')).length);
	}

	public function testShadowedKeyByLambdaParamNotFlagged(): Void {
		Assert.equals(
			0, violations(wrapMap('for (k in m.keys()) {\n\t\t\tfinal f = (k:String) -> m[k];\n\t\t\ttrace(f("x"));\n\t\t}')).length
		);
	}

	public function testChainedReceiverNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(o:{ m:Map<String,Int> }):Void {\n\t\tfor (k in o.m.keys()) trace(o.m[k]);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testNonMapTypeNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(arr:Array<Int>):Void {\n\t\tfor (k in arr.keys()) trace(arr[k]);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testUnresolvableTypeStillFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(m):Void {\n\t\tfor (k in m.keys()) trace(m[k]);\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testFixIndexLookup(): Void {
		assertFixCanonical(wrapMap('for (k in m.keys()) trace(m[k]);'), 'for (k => value in m) trace(value);', '.keys()');
	}

	public function testFixGetLookup(): Void {
		assertFixCanonical(wrapMap('for (k in m.keys()) trace(m.get(k));'), 'for (k => value in m) trace(value);', 'm.get(k)');
	}

	public function testFixFreshValueNameOnCollision(): Void {
		assertFixCanonical(
			wrapMap('for (k in m.keys()) {\n\t\t\tfinal value = 7;\n\t\t\ttrace(m[k] + value);\n\t\t}'), 'for (k => value1 in m)', 'm[k]'
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('map-keys-lookup'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('map-keys-lookup'));
		Assert.equals(95, Linter.builtins().length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f(m:Map<String,Int>) { for (k in m.keys()) trace(m[k]);').length);
	}

	private function wrapMap(loopCode: String): String {
		return 'class C {\n\tfunction f(m:Map<String,Int>):Void {\n\t\t$loopCode\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new MapKeysLookup().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}


	private function assertFixCanonical(src: String, present: String, absent: String): Void {
		final check: MapKeysLookup = new MapKeysLookup();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		switch RefactorSupport.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(present) >= 0);
				Assert.isTrue(text.indexOf(absent) == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

}
