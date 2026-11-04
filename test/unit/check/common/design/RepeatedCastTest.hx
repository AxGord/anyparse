package unit.check.common.design;

import anyparse.check.common.design.RepeatedCast;
import anyparse.query.CanonicalEdit;

/**
 * The `repeated-cast` check: one stable value — a local, a parameter or a chain of
 * final fields — cast to one type several times in a function body is bound once
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
			'k ? cast(o, B).a() : log(); cast(o, B).c();'
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

	public function testAFinalFieldIsOneValue(): Void {
		Assert.equals(
			'class C { final o:Dynamic; function m() { final b: B = cast(o, B); b.a(); b.c(); } }',
			CheckFixture.fixedSource(
				new RepeatedCast(), 'class C { final o:Dynamic; function m() { cast(o, B).a(); cast(this.o, B).c(); } }'
			)
		);
	}

	@:pin('control')
	@:killer('M-RCAST-VAR-FIELD')
	public function testAVarFieldOrAGetterIsNoOperand(): Void {
		for (field in ['var o:Dynamic;', 'final o(get, never):Dynamic; function get_o() return null;']) {
			final src: String = 'class C { $field function m() { cast(o, B).a(); cast(this.o, B).c(); } }';
			Assert.equals(0, violations(src).length, field);
		}
	}

	@:pin('control')
	@:killer('M-RCAST-INTERFACE-FIELD')
	public function testAFieldAPropertyMayImplementIsNoOperand(): Void {
		for (host in ['interface I { final o:Dynamic; }', 'typedef I = { final o:Dynamic; }']) {
			final src: String = '$host class C { final i:I; function m() { cast(i.o, B).a(); cast(i.o, B).c(); } }';
			Assert.equals(0, violations(src).length, host);
		}
	}

	public function testAChainOfFinalFieldsAcrossFilesIsOneValue(): Void {
		final model: String = 'class Model { public final view:Dynamic; public var loose:Dynamic; public function new() {} }';
		final src: String = 'class C { final model:Model; function m(p:Model) { cast(model.view, B).a(); cast(this.model.view, B).c();'
			+ ' cast(p.view, D).a(); cast(p.view, D).c(); cast(model.loose, E).a(); cast(model.loose, E).c(); } }';
		Assert.equals(
			'class C { final model:Model; function m(p:Model) { final b: B = cast(model.view, B); b.a(); b.c();'
			+ ' final d: D = cast(p.view, D); d.a(); d.c(); cast(model.loose, E).a(); cast(model.loose, E).c(); } }',
			CanonicalEdit.applyEdits(
				src, CheckFixture.fixRun(new RepeatedCast(), [{ file: 'C.hx', source: src }, { file: 'Model.hx', source: model }]).edits
			)
		);
	}

	@:pin('control')
	@:killer('M-RCAST-EXCLUSIVE-BRANCHES')
	public function testCastsInExclusiveBranchesAreOneEvaluation(): Void {
		for (body in [
			'if (k) cast(o, B).a(); else cast(o, B).b();',
			'switch k { case true: cast(o, B).a(); case _: cast(o, B).b(); }',
			'sink(k ? cast(o, B).a : cast(o, B).b);'
		]) Assert.equals(0, violations('class C { function m(o:Dynamic, k:Bool) { $body } }').length, body);
		final src: String = 'class C { function m(o:Dynamic, k:Bool) { cast(o, B).a(); if (k) cast(o, B).c(); else cast(o, B).d(); } }';
		Assert.isTrue(violations(src)[0].message.indexOf('evaluated 2 times') != -1);
		Assert.equals(
			'class C { function m(o:Dynamic, k:Bool) { final b: B = cast(o, B); b.a(); if (k) b.c(); else b.d(); } }',
			CheckFixture.fixedSource(new RepeatedCast(), src)
		);
	}

	public function testBoundInTheCaseArmHoldingTheCasts(): Void {
		Assert.equals(
			'class C { function m(o:Dynamic, k:Int) { switch k { case 1: final b: B = cast(o, B); b.a(); b.c(); case _: } } }',
			CheckFixture.fixedSource(
				new RepeatedCast(),
				'class C { function m(o:Dynamic, k:Int) { switch k { case 1: cast(o, B).a(); cast(o, B).c(); case _: } } }'
			)
		);
	}

	@:pin('control')
	@:killer('M-RCAST-CASE-GUARD')
	public function testNeverBoundAheadOfACaseGuard(): Void {
		final src: String = 'class C { function m(o:Dynamic, k:Int) { switch k { case 1 if (cast(o, B).ok): cast(o, B).a(); case _: } } }';
		Assert.equals(1, violations(src).length);
		Assert.equals(src, CheckFixture.fixedSource(new RepeatedCast(), src));
	}

	public function testAnOperandOfAnOperatorRunsInOrder(): Void {
		Assert.equals(
			'class C { function m(o:Dynamic):Int { final b: B = cast(o, B); return b.n + b.m; } }',
			CheckFixture.fixedSource(new RepeatedCast(), 'class C { function m(o:Dynamic):Int { return cast(o, B).n + cast(o, B).m; } }')
		);
	}

	@:pin('control')
	@:killer('M-RCAST-SHORT-CIRCUIT')
	public function testNeverBoundAheadOfAShortCircuit(): Void {
		final src: String = 'class C { function m(o:Dynamic, k:Bool):Bool { return k && cast(o, B).ok && cast(o, B).on; } }';
		Assert.equals(1, violations(src).length);
		Assert.equals(src, CheckFixture.fixedSource(new RepeatedCast(), src));
	}

	public function testAFunctionLiteralCapturesTheBoundLocal(): Void {
		Assert.equals(
			'class C { function m(o:Dynamic, xs:Array<Int>) { final b: B = cast(o, B); b.a(); xs.map(x -> b.n + x); } }',
			CheckFixture.fixedSource(
				new RepeatedCast(), 'class C { function m(o:Dynamic, xs:Array<Int>) { cast(o, B).a(); xs.map(x -> cast(o, B).n + x); } }'
			)
		);
		Assert.equals(
			0,
			violations('class C { function m(o:Dynamic, xs:Array<Int>) { xs.map(x -> cast(o, B).n); xs.map(x -> cast(o, B).m); } }').length,
			'two literals each run their own cast, maybe never'
		);
	}

	@:pin('control')
	@:killer('M-RCAST-CAPTURE-WRITTEN')
	public function testAFunctionLiteralNeverCapturesAWrittenOperand(): Void {
		Assert.equals(
			0,
			violations('class C { function m(o:Dynamic, p:Dynamic, xs:Array<Int>) { cast(o, B).a(); xs.map(x -> cast(o, B).n); o = p; } }')
				.length
		);
	}

	/**
	 * A link's type is read as the reading file spells it: a same-named
	 * type of the reading file never stands for the declaring one's one.
	 */
	@:pin('control')
	@:killer('M-RCAST-LINK-READER-SPELLING')
	public function testAChainLinkIsTypedAsTheReadingFileSpellsIt(): Void {
		final view: String = 'package m; class View { public var data:Dynamic; public function new() {} }';
		final model: String = 'package m; class Model { public final view:View; public function new() { view = new View(); } }';
		final own: String = 'package p; class View { public final data:Dynamic; public function new() { data = null; } }';
		final src: String = 'package p; import m.Model; class A { function f(model:Model) { cast(model.view.data, B).a(); reset(model);'
			+ ' cast(model.view.data, B).c(); } static function reset(model:Model) { model.view.data = null; } }';
		final run: FixRun = CheckFixture.fixRun(new RepeatedCast(), [
			{ file: 'p/A.hx', source: src },
			{ file: 'm/Model.hx', source: model },
			{ file: 'm/View.hx', source: view },
			{ file: 'p/View.hx', source: own }
		]);
		Assert.equals(0, run.violations.length);
		Assert.equals(0, run.edits.length);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new RepeatedCast(), src);
	}

}
