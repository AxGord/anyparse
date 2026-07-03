package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PossibleNullDereference;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `possible-null-dereference` check: a dereference of a `map[key]` result
 * (a `Null<V>`) is flagged `Info`. An `Array` / `String` index (non-null `T`),
 * an unannotated or `Null<Map<…>>` receiver, and a bare `map[key]` with no
 * dereference are not. Type-aware — the receiver's declared type is what tells
 * a `Map` index from an `Array` index. Report-only — `fix` yields no edits.
 */
class PossibleNullDereferenceTest extends Test {

	public function testFieldAccessFlagged(): Void {
		final vs: Array<Violation> = violations('class C { function f(m:Map<String,Int>) { var a = m[k].foo; } }');
		Assert.equals(1, vs.length);
		Assert.equals('possible-null-dereference', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('map access Map[key] can be null; this dereference has no null check', vs[0].message);
	}

	public function testMethodCallFlagged(): Void {
		Assert.equals(1, violations('class C { function f(m:Map<String,Int>) { m[k].bar(); } }').length);
	}

	public function testForceNavFlagged(): Void {
		Assert.equals(1, violations('class C { function f(m:Map<String,Int>) { var b = m[k]!.baz; } }').length);
	}

	public function testConcreteMapFlagged(): Void {
		final vs: Array<Violation> = violations('class C { function f(m:StringMap<Int>) { var a = m[k].foo; } }');
		Assert.equals(1, vs.length);
		Assert.equals('map access StringMap[key] can be null; this dereference has no null check', vs[0].message);
	}

	public function testArrayIndexNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(arr:Array<Int>) { arr[i].qux(); } }').length);
	}

	public function testNullWrappedMapNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(m:Null<Map<String,Int>>) { var a = m[k].foo; } }').length);
	}

	public function testUnannotatedMapNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f() { var m = new Map<String,Int>(); var a = m[k].foo; } }').length);
	}

	public function testBareIndexNoDerefNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(m:Map<String,Int>) { var v = m[k]; } }').length);
	}

	public function testPopDerefFlagged(): Void {
		final vs: Array<Violation> = violations('class C { function f(arr:Array<Int>) { var a = arr.pop().foo; } }');
		Assert.equals(1, vs.length);
		Assert.equals('Array.pop() can be null; this dereference has no null check', vs[0].message);
	}

	public function testShiftMethodCallFlagged(): Void {
		Assert.equals(1, violations('class C { function f(arr:Array<Int>) { arr.shift().bar(); } }').length);
	}

	public function testListPopFlagged(): Void {
		final vs: Array<Violation> = violations('class C { function f(lst:List<Foo>) { var a = lst.pop().baz; } }');
		Assert.equals(1, vs.length);
		Assert.equals('List.pop() can be null; this dereference has no null check', vs[0].message);
	}

	public function testNonNullableMethodNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(arr:Array<Int>) { arr.push(1); var n = arr.length; } }').length);
	}

	public function testPopOnNonArrayTypeNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(o:Foo) { o.pop().bar(); } }').length);
	}

	public function testBarePopNoDerefNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(arr:Array<Int>) { var v = arr.pop(); } }').length);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C { function f(m:Map<String,Int>) { var a = m[k].foo; } }';
		final check: PossibleNullDereference = new PossibleNullDereference();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('possible-null-dereference'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('possible-null-dereference'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new PossibleNullDereference().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
