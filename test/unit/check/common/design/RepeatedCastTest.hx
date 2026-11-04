package unit.check.common.design;

import anyparse.check.common.design.RepeatedCast;

/**
 * The `repeated-cast` check: one local or parameter cast to one type several times in a function body is bound once
 * to a typed `final` local by the fix, placed where the first cast runs unconditionally.
 */
class RepeatedCastTest extends Test {

	private static inline final CHECKED: String =
		'class C { function m(o:Dynamic, c:Int) { cast(o, Bubble).color = c; cast(o, Bubble).redraw(); } }';

	public function testCheckedCastRepeatedTwiceIsBoundOnce(): Void {
		final vs: Array<Violation> = violations(CHECKED);
		Assert.equals(1, vs.length);
		Assert.equals('repeated-cast', vs[0].rule);
		Assert.isTrue(vs[0].message.indexOf('evaluated 2 times') != -1);
		Assert.equals(
			'class C { function m(o:Dynamic, c:Int) { final bubble: Bubble = cast(o, Bubble); bubble.color = c; bubble.redraw(); } }',
			CheckFixture.fixedSource(new RepeatedCast(), CHECKED)
		);
	}

	public function testOneCastIsNotRepeated(): Void {
		Assert.equals(0, violations('class C { function m(o:Dynamic) { cast(o, Bubble).redraw(); } }').length);
	}

	public function testUncheckedCastNeedsThree(): Void {
		Assert.equals(0, violations('class C { function m(o:Dynamic) { (cast o : Box).a(); (cast o : Box).b(); } }').length);
		final three: String = 'class C { function m(o:Dynamic) { (cast o : Box).a(); (cast o : Box).b(); (cast o : Box).c(); } }';
		Assert.equals(1, violations(three).length);
		Assert.equals(
			'class C { function m(o:Dynamic) { final box: Box = (cast o : Box); box.a(); box.b(); box.c(); } }',
			CheckFixture.fixedSource(new RepeatedCast(), three)
		);
	}

	@:pin('control')
	@:killer('M-RCAST-MERGE-FAMILIES')
	public function testCheckedAndUncheckedAreNeverMerged(): Void {
		Assert.equals(0, violations('class C { function m(o:Dynamic) { cast(o, B).a(); (cast o : B).b(); (cast o : B).c(); } }').length);
	}

	@:pin('control')
	@:killer('M-RCAST-WRITE-NOT-SPLIT')
	public function testAWriteBetweenCastsSplitsTheRun(): Void {
		Assert.equals(0, violations('class C { function m(o:Dynamic, p:Dynamic) { cast(o, B).a(); o = p; cast(o, B).b(); } }').length);
		Assert.equals(
			0, violations('class C { function m(o:Dynamic) { o = cast(o, B).next; cast(o, B).a(); } }').length,
			'the assignment takes effect after its right side reads'
		);
	}

	public function testDifferentOperandsAndTypesAreSeparate(): Void {
		Assert.equals(
			0, violations('class C { function m(o:Dynamic, p:Dynamic) { cast(o, B).a(); cast(p, B).b(); cast(o, D).c(); } }').length
		);
	}

	@:pin('control')
	@:killer('M-RCAST-HOIST-ABOVE-GUARD')
	public function testNeverHoistedAboveTheGuardThatValidatesTheCast(): Void {
		final src: String = 'class C { function m(o:Dynamic) { if (o is B) { cast(o, B).a(); } cast(o, B).b(); } }';
		Assert.equals(1, violations(src).length);
		Assert.equals(src, CheckFixture.fixedSource(new RepeatedCast(), src));
	}

	public function testBoundInsideTheGuardedBranch(): Void {
		Assert.equals(
			'class C { function m(o:Dynamic) { if (o is Box) { final box: Box = cast(o, Box); box.a(); box.b(); } } }',
			CheckFixture.fixedSource(
				new RepeatedCast(), 'class C { function m(o:Dynamic) { if (o is Box) { cast(o, Box).a(); cast(o, Box).b(); } } }'
			)
		);
	}

	public function testNameCollidingWithAVisibleNameIsSuffixed(): Void {
		Assert.equals(
			'class C { function m(o:Dynamic, b:Int) { final b2: B = cast(o, B); b2.a(b); b2.c(); } }',
			CheckFixture.fixedSource(new RepeatedCast(), 'class C { function m(o:Dynamic, b:Int) { cast(o, B).a(b); cast(o, B).c(); } }')
		);
	}

	public function testThresholdIsConfigurable(): Void {
		final json: String = '{"rules":{"repeated-cast":{"minChecked":3}}}';
		Assert.equals(0, CheckFixture.fixRunUnder(new RepeatedCast(), CHECKED, json).violations.length);
	}

	@:pin('control')
	@:killer('M-RCAST-BACK-EDGE')
	public function testAWriteALoopCarriesCutsTheRun(): Void {
		Assert.equals(
			0,
			violations(
				'class C { function m(o:Dynamic, n:Dynamic, xs:Array<Int>) { cast(o, B).a(); for (x in xs) { cast(o, B).a(); o = n; } } }'
			).length
		);
		Assert.equals(
			0,
			violations('class C { function m(o:Dynamic) { while (cast(o, B).more()) { cast(o, B).a(); o = cast(o, B).next; } } }').length
		);
	}

	public function testABlockInsideTheLoopRecomputesPerIteration(): Void {
		Assert.equals(
			'class C { function m(o:Dynamic, n:Dynamic, xs:Array<Int>) { for (x in xs) { final b: B = cast(o, B); b.a(); b.c(); o = n; } '
			+ '} }',
			CheckFixture.fixedSource(
				new RepeatedCast(),
				'class C { function m(o:Dynamic, n:Dynamic, xs:Array<Int>) { for (x in xs) { cast(o, B).a(); cast(o, B).c(); o = n; } } }'
			)
		);
	}

	@:pin('control')
	@:killer('M-RCAST-CONDITION-SLOT')
	public function testNeverHoistedOutOfAnUnbracedBody(): Void {
		for (body in [
			'if (o is B) cast(o, B).a(); if (o is B) cast(o, B).c();',
			'if (k) cast(o, B).a(); cast(o, B).c();',
			'if (k) k; else cast(o, B).a(); cast(o, B).c();',
			'if (k) log(); else cast(o, B).a(); cast(o, B).c();',
			'for (x in xs) cast(o, B).a(); cast(o, B).c();',
			'try cast(o, B).a() catch (e:Dynamic) log(); cast(o, B).c();',
			'do cast(o, B).a() while (k); cast(o, B).c();',
			'while (cast(o, B).more()) cast(o, B).a();',
			'k && cast(o, B).more(); cast(o, B).c();',
			'k ? cast(o, B).a() : cast(o, B).c();'
		]) {
			final src: String = 'class C { function m(o:Dynamic, k:Bool, xs:Array<Int>) { $body } }';
			Assert.equals(1, violations(src).length, body);
			Assert.equals(src, CheckFixture.fixedSource(new RepeatedCast(), src), body);
		}
	}

	public function testAConditionSlotRunsFirstAndAlways(): Void {
		Assert.equals(
			'class C { function m(o:Dynamic) { final b: B = cast(o, B); if (b.ok) b.a(); } }',
			CheckFixture.fixedSource(new RepeatedCast(), 'class C { function m(o:Dynamic) { if (cast(o, B).ok) cast(o, B).a(); } }')
		);
	}

	@:pin('control')
	@:killer('M-RCAST-PURE-PREFIX')
	public function testNeverHoistedAcrossCodeThatDoesSomething(): Void {
		for (body in [
			'sink(o = n, cast(o, B).a()); cast(o, B).a();',
			'sink(log(), cast(o, B).c); cast(o, B).a();'
		]) {
			final src: String = 'class C { function m(o:Dynamic, n:Dynamic) { $body } }';
			Assert.equals(src, CheckFixture.fixedSource(new RepeatedCast(), src), body);
		}
	}

	public function testHoistedAcrossPureArguments(): Void {
		Assert.equals(
			'class C { function m(o:Dynamic, x:Int) { final b: B = cast(o, B); sink(x, b.c); b.a(); } }',
			CheckFixture.fixedSource(
				new RepeatedCast(), 'class C { function m(o:Dynamic, x:Int) { sink(x, cast(o, B).c); cast(o, B).a(); } }'
			)
		);
	}

	public function testTwoRunsInOneStatementBindOneAtATime(): Void {
		final src: String =
			'class C { function m(o:Dynamic, p:Dynamic) { sink(cast(o, B).c, cast(p, D).c); sink(cast(o, B).c, cast(p, D).c); } }';
		final once: String =
			'class C { function m(o:Dynamic, p:Dynamic) { final b: B = cast(o, B); sink(b.c, cast(p, D).c); sink(b.c, cast(p, D).c); } }';
		Assert.equals(once, CheckFixture.fixedSource(new RepeatedCast(), src));
		Assert.equals(
			'class C { function m(o:Dynamic, p:Dynamic) {'
			+ ' final b: B = cast(o, B); final d: D = cast(p, D); sink(b.c, d.c); sink(b.c, d.c); } }',
			CheckFixture.fixedSource(new RepeatedCast(), once)
		);
	}

	public function testATypeSuggestingNoNameStaysReportOnly(): Void {
		for (type in ['Void -> Void', 'Null<B>', 'Array<Int>', 'Int', 'Dynamic']) {
			final src: String = 'class C { function m(o:Dynamic) { (cast o : $type); (cast o : $type); (cast o : $type); } }';
			Assert.equals(1, violations(src).length, type);
			Assert.equals(src, CheckFixture.fixedSource(new RepeatedCast(), src), type);
		}
	}

	public function testAnAcronymTypeNameLowersAsAWord(): Void {
		Assert.equals(
			'class C { function m(o:Dynamic) { final xmlNode: XMLNode = cast(o, XMLNode); xmlNode.a(); xmlNode.c(); } }',
			CheckFixture.fixedSource(
				new RepeatedCast(), 'class C { function m(o:Dynamic) { cast(o, XMLNode).a(); cast(o, XMLNode).c(); } }'
			)
		);
	}

	@:pin('control')
	@:killer('M-RCAST-OWN-DECLARATION')
	public function testNeverHoistedAboveTheOperandsOwnDeclaration(): Void {
		for (params in ['o:Dynamic, other:Dynamic', 'other:Dynamic']) {
			final src: String = 'class C { function m($params) { var o:Dynamic = other, y:Int = cast(o, B).n; cast(o, B).a(); } }';
			Assert.equals(1, violations(src).length, params);
			Assert.equals(src, CheckFixture.fixedSource(new RepeatedCast(), src), params);
		}
	}

	public function testHoistedBelowADeclarationInAnEarlierStatement(): Void {
		Assert.equals(
			'class C { function m(other:Dynamic) { var o:Dynamic = other; final b: B = cast(o, B); var y:Int = b.n; b.a(); } }',
			CheckFixture.fixedSource(
				new RepeatedCast(),
				'class C { function m(other:Dynamic) { var o:Dynamic = other; var y:Int = cast(o, B).n; cast(o, B).a(); } }'
			)
		);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new RepeatedCast(), src);
	}

}
