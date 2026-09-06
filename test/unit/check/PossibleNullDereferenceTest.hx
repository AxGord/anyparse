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

	/**
	 * The guard this check was blind to until S135: `NullFlow` already modelled `m.exists(k)`
	 * for the flow check's seed, and the point-wise walk never asked it. Measured on the Pony
	 * fork, 15 of 65 findings were sites the author had guarded.
	 */
	@:pin('control')
	@:killer('M-EXISTS-GUARD-BLIND')
	public function testExistsGuardedThenArmNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(m:Map<String,Int>, k:String) { if (m.exists(k)) m[k].foo(); } }').length);
	}

	/**
	 * The early-return spelling — the guard lives in the ELSE arm of a negated test, and the
	 * read is the fall-through. The real site is `pony/src/pony/LangTable.hx:92`.
	 */
	@:pin('control')
	@:killer('M-EXISTS-GUARD-BLIND')
	public function testExistsGuardedEarlyReturnNotFlagged(): Void {
		Assert.equals(
			0, violations('class C { function f(m:Map<String,Int>, k:String) { if (!m.exists(k)) return; m[k].foo(); } }').length
		);
	}

	/** A conjunct of the guarding condition — `pony/src/pony/flash/starling/converter/AtlasCreator.hx:68`. */
	public function testExistsGuardedAmongConjunctsNotFlagged(): Void {
		Assert.equals(
			0, violations('class C { function f(m:Map<String,Int>, k:String, b:Bool) { if (!b && m.exists(k)) m[k].foo(); } }').length
		);
	}

	/**
	 * The read sits in the RIGHT operand of the `&&` whose left operand is the guard, so no arm
	 * of any `if` contains it — `AtlasCreator.hx:64`. The `||` mirror (`!m.exists(k) || m[k].f`)
	 * is `AtlasCreator.hx:96`.
	 */
	public function testExistsGuardedShortCircuitOperandsNotFlagged(): Void {
		Assert.equals(
			0, violations('class C { function f(m:Map<String,Int>, k:String) { if (m.exists(k) && m[k].ok()) trace(1); } }').length
		);
		Assert.equals(
			0, violations('class C { function f(m:Map<String,Int>, k:String) { if (!m.exists(k) || m[k].ok()) trace(1); } }').length
		);
	}

	/**
	 * A CONSTANT key. The commonest real spelling (`args.exists('fix')` guarding `args['fix']`,
	 * five sites across the `mmodels` actions) and the one a leaf-only purity test misses:
	 * Haxe projects `'fix'` as `SingleStringExpr(Literal fix)`, which is not a leaf.
	 */
	public function testExistsGuardedConstantKeyNotFlagged(): Void {
		Assert.equals(0, violations("class C { function f(m:Map<String,Int>) { if (m.exists('fix')) m['fix'].foo(); } }").length);
	}

	/**
	 * The shape S132 measured as the whole valuable residue of the type-resolver's "don't know"
	 * set: a Map behind a multi-hop field path across files, guarded by `exists`. Seven of the
	 * ten positions whose answer would change a finding are this, and closing the field-path gap
	 * without this guard would have shipped all seven as false positives.
	 *
	 * Both halves are asserted together because either alone is vacuous: the guarded half passes
	 * on its own whenever the resolver simply cannot type the path.
	 */
	@:pin('control')
	@:killer('M-EXISTS-GUARD-BLIND')
	public function testFieldPathMapExistsGuardedNotFlagged(): Void {
		final decls: Array<{ file: String, source: String }> = [
			{ file: 'Inner.hx', source: 'class Inner { public var subactions:Map<String,Int>; }' },
			{ file: 'Mid.hx', source: 'class Mid { public var model:Inner; }' }
		];
		Assert.equals(
			1,
			violationsFiles(decls.concat([
				{ file: 'C.hx', source: 'class C { function f(a:Mid, name:String) { a.model.subactions[name].tpl(); } }' }
			])).length,
			'the unguarded multi-hop path IS reported — without this half the guarded one is vacuous'
		);
		Assert.equals(
			0,
			violationsFiles(decls.concat([
				{
					file: 'C.hx',
					source: 'class C { function f(a:Mid, name:String) { if (a.model.subactions.exists(name)) '
					+ 'a.model.subactions[name].tpl(); } }'
				}
			])).length,
			'the same read under its own exists-guard is not'
		);
	}

	/** The guard proves `k` present, not `k2` — a blanket silencer would swallow this. */
	public function testExistsGuardWrongKeyStillFlagged(): Void {
		Assert.equals(
			1, violations('class C { function f(m:Map<String,Int>, k:String, k2:String) { if (m.exists(k)) m[k2].foo(); } }').length
		);
	}

	/** The guard proves membership in `m`, not in `n`. */
	public function testExistsGuardWrongMapStillFlagged(): Void {
		Assert.equals(
			1, violations('class C { function f(m:Map<String,Int>, n:Map<String,Int>, k:String) { if (m.exists(k)) n[k].foo(); } }').length
		);
	}

	/** The read precedes the guard, so nothing dominates it. */
	public function testExistsGuardAfterReadStillFlagged(): Void {
		Assert.equals(
			1, violations('class C { function f(m:Map<String,Int>, k:String) { m[k].foo(); if (m.exists(k)) trace(1); } }').length
		);
	}

	/** Rewriting either operand between guard and read kills the fact — the name-keyed invalidation. */
	public function testExistsGuardOperandRewrittenStillFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C { function f(m:Map<String,Int>, k:String) { if (m.exists(k)) { k = other(); m[k].foo(); } } '
				+ 'function other():String return ""; }'
			).length
		);
	}

	/**
	 * A key made present by a CONDITIONAL WRITE rather than by a test of its own is a different
	 * fact and stays reported — the boundary of what this guard claims. Two real sites
	 * (`AtlasCreator.hx:103` / `:214`) are this shape and remain false positives on purpose,
	 * rather than being swept in by a looser predicate.
	 */
	public function testConditionalWriteNotAGuardStillFlagged(): Void {
		Assert.equals(
			1, violations('class C { function f(m:Map<String,Int>, k:String) { if (!m.exists(k)) m[k] = 1; m[k].foo(); } }').length
		);
	}

	/** A membership test whose receiver is a CALL cannot be identified by text — refused, so the read stays reported. */
	public function testExistsGuardOnCallReceiverStillFlagged(): Void {
		Assert.equals(
			1,
			violations('class C { function f(k:String) { if (mk().exists(k)) mk()[k].foo(); } function mk():Map<String,Int> return null; }')
				.length
		);
	}

	private function violations(src: String): Array<Violation> {
		return new PossibleNullDereference().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function violationsFiles(files: Array<{ file: String, source: String }>): Array<Violation> {
		return new PossibleNullDereference().run(files, new HaxeQueryPlugin());
	}

}
