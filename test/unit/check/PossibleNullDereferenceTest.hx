package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PossibleNullDereference;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * The `possible-null-dereference` check: a dereference of a `map[key]` result
 * (a `Null<V>`) is flagged `Info`. An `Array` / `String` index (non-null `T`), an
 * unannotated and unresolvable receiver, and a bare `map[key]` with no dereference
 * are not. Type-aware — the receiver type is what tells a `Map` index from an
 * `Array` index, read from its written annotation and, past that, from the chain
 * resolver, which also peels the `Null<…>` wrapper the annotation map degrades to a
 * bare `Null`. Report-only — `fix` yields no edits.
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

	/**
	 * `declaredTypes` records `Null<Map<String, Int>>` as its bare outer name `Null`, which names
	 * no member set of its own — a LOSS the check used to read as "not a `Map`, safe miss". The
	 * discriminating real site is `pony/src/pony/ui/gui/RubberLayoutCore.hx:76`, where the author
	 * put `@:nullSafety(Off)` on the very expression this now reports.
	 */
	@:pin('control')
	@:killer('M-NULLABLE-WRAPPER-OPAQUE')
	public function testNullWrappedMapFlagged(): Void {
		final vs: Array<Violation> = violations('class C { function f(m:Null<Map<String,Int>>) { var a = m[k].foo; } }');
		Assert.equals(1, vs.length);
		Assert.equals('map access Map[key] can be null; this dereference has no null check', vs[0].message);
	}

	/**
	 * The chain resolver's index arc: the receiver is a field PATH, which carries no annotation of
	 * its own, so the `declaredTypes` lookup has nothing to answer with and only
	 * `CheckScan.typeNominalResolver` can name the type.
	 */
	@:pin('control')
	@:killer('M-NULLABLE-NO-CHAIN')
	public function testFieldPathMapReceiverFlagged(): Void {
		final vs: Array<Violation> = violations('class C { var cache:Map<String,Int>; function f(o:C) { var a = o.cache[k].foo; } }');
		Assert.equals(1, vs.length);
		Assert.equals('map access Map[key] can be null; this dereference has no null check', vs[0].message);
	}

	/**
	 * The chain resolver's instance-call arc: the receiver of `.pop()` is itself a CALL, so its
	 * type comes from the callee's written return type and from nowhere else.
	 */
	@:pin('control')
	@:killer('M-NULLABLE-NO-CHAIN')
	public function testCallReturnPopFlagged(): Void {
		final vs: Array<Violation> =
			violations('class C { function g():Array<Int> { return []; } function f() { var a = g().pop().foo; } }');
		Assert.equals(1, vs.length);
		Assert.equals('Array.pop() can be null; this dereference has no null check', vs[0].message);
	}

	/** The same field path over an `Array` stays a miss — the resolver names a type, it does not assume one. */
	public function testFieldPathArrayReceiverNotFlagged(): Void {
		Assert.equals(0, violations('class C { var items:Array<Int>; function f(o:C) { var a = o.items[i].foo; } }').length);
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

	public function testNullReturnFunctionFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C { function findUser(s:String):Null<Foo> { return null; } function g() { findUser("x").bar(); } }'
		);
		Assert.equals(1, vs.length);
		Assert.equals('findUser() can be null; this dereference has no null check', vs[0].message);
	}

	public function testNonNullReturnFunctionNotFlagged(): Void {
		Assert.equals(0, violations('class C { function getFoo():Foo { return null; } function g() { getFoo().bar(); } }').length);
	}

	public function testUnannotatedReturnFunctionNotFlagged(): Void {
		Assert.equals(0, violations('class C { function compute() { return null; } function g() { compute().bar(); } }').length);
	}

	public function testBareNullReturnCallNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C { function findUser(s:String):Null<Foo> { return null; } function g() { var v = findUser("x"); } }').length
		);
	}

	public function testMapGetFlagged(): Void {
		final vs: Array<Violation> = violations('class C { function f(m:Map<String,Int>) { m.get(k).toString(); } }');
		Assert.equals(1, vs.length);
		Assert.equals('Map.get() can be null; this dereference has no null check', vs[0].message);
	}

	public function testListFirstFlagged(): Void {
		Assert.equals(1, violations('class C { function f(lst:List<Foo>) { var a = lst.first().bar; } }').length);
	}

	public function testGetOnNonMapNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(o:Foo) { o.get(k).bar(); } }').length);
	}

	public function testCrossFileDirectReturnFlagged(): Void {
		final vs: Array<Violation> = violationsFiles([
			{ file: 'Helper.hx', source: 'class Helper { public function findUser(s:String):Null<Foo> return null; }' },
			{ file: 'Caller.hx', source: 'class Caller { function f(h:Helper) { h.findUser(k).name; } }' }
		]);
		Assert.equals(1, vs.length);
		Assert.equals('h.findUser() can be null; this dereference has no null check', vs[0].message);
	}

	public function testCrossFileNonNullDirectNotFlagged(): Void {
		Assert.equals(
			0, violationsFiles([
				{ file: 'Helper.hx', source: 'class Helper { public function plain():Foo return null; }' },
				{ file: 'Caller.hx', source: 'class Caller { function f(h:Helper) { h.plain().name; } }' }
			]).length
		);
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

	private function violationsFiles(files: Array<{ file: String, source: String }>): Array<Violation> {
		return new PossibleNullDereference().run(files, new HaxeQueryPlugin());
	}

}
