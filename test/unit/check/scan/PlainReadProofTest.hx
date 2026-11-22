package unit.check.scan;

import anyparse.check.common.nullsafety.PreferNullGuardedLoop;
import anyparse.check.common.nullsafety.PreferSafeNav;
import haxe.PosInfos;

using StringTools;

/**
 * The plain-read proof binds a for-loop binder, a key-value binder and a decided case capture as
 * bound roots, and types a `.field` step off a root whose type is not written (a loop binder, an
 * untyped lambda parameter, an inferred local): both `prefer-null-guarded-loop` and
 * `prefer-safe-nav` rewrite such a receiver, since its second read cannot observe a different value.
 * A pattern name that may compare against a constant, and a getter step off a binder, stay refused.
 */
class PlainReadProofTest extends Test {

	@:pin('control')
	@:killer('M-PLAIN-READ-BINDER')
	public function testLoopBinderGuardedLoop(): Void {
		assertLoopFixed(
			'if (b != null) for (i in b) trace(i);', 'for (b in ls) for (i in b ?? []) trace(i);', 'ls: Array<Null<Array<Int>>>'
		);
	}

	@:pin('control')
	@:killer('M-GUARDED-LOOP-FIX-FILE')
	public function testCaptureGuardedLoop(): Void {
		assertLoopFixed(
			'if (bx != null) for (i in bx) trace(i);', 'switch e {\n\t\t\tcase Leaf(bx): for (i in bx ?? []) trace(i);\n\t\t}', 'e: E'
		);
	}

	@:pin('control')
	@:killer('M-PLAIN-READ-TYPED-STEP')
	public function testBinderFieldGuardedLoop(): Void {
		assertLoopFixed(
			'if (b.items != null) for (i in b.items) trace(i);', 'for (b in bs) for (i in b.items ?? []) trace(i);', 'bs: Array<Box>'
		);
	}

	public function testKeyValueBinderFieldGuardedLoop(): Void {
		assertLoopFixed(
			'if (v.items != null) for (i in v.items) trace(i);', 'for (k => v in m) for (i in v.items ?? []) trace(i);',
			'm: Map<String, Box>'
		);
	}

	@:pin('control')
	@:killer('M-PLAIN-READ-TYPED-STEP')
	public function testUntypedLambdaParamFieldGuardedLoop(): Void {
		assertLoopFixed(
			'if (bb.items != null) for (i in bb.items) trace(i);',
			'each(bs, bb -> {\n\t\t\tfor (i in bb.items ?? []) trace(i);\n\t\t\t1;\n\t\t});', 'bs: Array<Box>'
		);
	}

	public function testInferredLocalFieldGuardedLoop(): Void {
		assertLoopFixed(
			'if (loc.items != null) for (i in loc.items) trace(i);', 'final loc = box;\n\t\tfor (i in loc.items ?? []) trace(i);',
			'box: Box'
		);
	}

	public function testLoopBinderSafeNav(): Void {
		assertSafeNavFixed('s?.command("a");', 'for (s in ss) if (s != null) s.command("a");', 'ss: Array<Null<Sh>>');
	}

	@:pin('control')
	@:killer('M-PLAIN-READ-BINDER')
	public function testCaptureSafeNav(): Void {
		assertSafeNavFixed('s?.command("b");', 'switch e {\n\t\t\tcase Some(s): if (s != null) s.command("b");\n\t\t}', 'e: E');
	}

	public function testBinderFieldSafeNav(): Void {
		assertSafeNavFixed('b.s?.command("c");', 'for (b in bs) if (b.s != null) b.s.command("c");', 'bs: Array<Box>');
	}

	/** A pattern name whose slot type may hold a constant of that name compares rather than captures: no proof. */
	@:pin('control')
	@:killer('M-PLAIN-READ-CAPTURE-PROOF')
	public function testUndecidedCaptureRefused(): Void {
		assertLoopRefused('switch e {\n\t\t\tcase Ext(t): for (i in t ?? []) trace(i);\n\t\t}', 'e: E');
	}

	/** A binder is a bound root, but a getter step off it still runs code on each read. */
	@:pin('control')
	@:killer('M-PLAIN-READ-STEP-GETTER')
	public function testGetterStepOffBinderRefused(): Void {
		assertLoopRefused('for (q in qs) for (i in q.items ?? []) trace(i);', 'qs: Array<Q>');
	}

	/** `stmt` in the body of a method taking `param`, beside the types every row reads. */
	private function host(stmt: String, param: String): String {
		return 'class Sh {\n\tpublic function command(c: String): Void {}\n}\n\ntypedef Box = {\n\tfinal items: Null<Array<Int>>;\n'
			+ '\tfinal s: Null<Sh>;\n}\n\nenum E {\n\tLeaf(b: Null<Array<Int>>);\n\tSome(s: Null<Sh>);\n\tExt(t: Null<Unknown>);\n}\n\n'
			+ 'class Q {\n\tpublic var items(get, never): Null<Array<Int>>;\n\n\tfunction get_items(): Null<Array<Int>> return null;\n'
			+ '}\n\nclass C {\n\tstatic function each(xs: Array<Box>, fn: Box -> Int): Void {}\n\n\tfunction f($param): Void {\n\t\t'
			+ '$stmt\n\t}\n}';
	}

	/** One `prefer-null-guarded-loop` finding, rewritten: the fixed source holds `expected`. */
	private function assertLoopFixed(expected: String, stmt: String, param: String, ?pos: PosInfos): Void {
		final src: String = host(stmt, param);
		final fixed: String = CheckFixture.fixedSource(new PreferNullGuardedLoop(), src);
		Assert.isTrue(
			fixed.contains(expected), CheckFixture.violations(new PreferNullGuardedLoop(), src).map(v -> v.message).join('; '), pos
		);
	}

	/** One `prefer-null-guarded-loop` finding refused for an unproven read, and no edit. */
	private function assertLoopRefused(stmt: String, param: String, ?pos: PosInfos): Void {
		final src: String = host(stmt, param);
		final vs: Array<Violation> = CheckFixture.violations(new PreferNullGuardedLoop(), src);
		Assert.equals(1, vs.length, pos);
		if (vs.length == 1) Assert.isTrue(vs[0].message.contains('getter'), vs[0].message, pos);
		Assert.equals(0, CheckFixture.edits(new PreferNullGuardedLoop(), src).length, pos);
	}

	/** One `prefer-safe-nav` finding, rewritten: the fixed source holds `expected`. */
	private function assertSafeNavFixed(expected: String, stmt: String, param: String, ?pos: PosInfos): Void {
		final src: String = host(stmt, param);
		Assert.equals(1, CheckFixture.violations(new PreferSafeNav(), src).length, pos);
		final fixed: String = CheckFixture.fixedSource(new PreferSafeNav(), src);
		Assert.isTrue(fixed.contains(expected), fixed, pos);
	}

}
