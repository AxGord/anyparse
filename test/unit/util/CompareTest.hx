package unit.util;

import anyparse.proc.ProcessRun;
import anyparse.proc.ProcessSpawn;
import anyparse.util.Compare;
import unit.cli.CliFixture;

private typedef Row = {
	final a: Int;
	final b: Int;
	final c: Int;
	final s: String;
	final f: Float;
}

/** `Compare`: three-way comparators that return exactly -1, 0 or 1 and order strings by code unit. */
final class CompareTest extends Test {

	@:pin('control')
	@:killer('M-UTIL-COMPARE-INT-LESS')
	public function testASmallerIntegerComesFirst(): Void {
		Assert.equals(-1, Compare.compareInt(1, 2));
		Assert.equals(-1, Compare.compareInt(-3, -2));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-INT-MORE')
	public function testALargerIntegerComesLast(): Void {
		Assert.equals(1, Compare.compareInt(2, 1));
		Assert.equals(1, Compare.compareInt(-2, -3));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-INT-EQUAL')
	public function testEqualIntegersCompareAsZero(): Void {
		Assert.equals(0, Compare.compareInt(2, 2));
		Assert.equals(0, Compare.compareInt(0, 0));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-STRING-LESS')
	public function testASmallerStringComesFirst(): Void {
		Assert.equals(-1, Compare.compareString('a', 'b'));
		Assert.equals(-1, Compare.compareString('ab', 'abc'));
		Assert.equals(-1, Compare.compareString('', 'a'));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-STRING-MORE')
	public function testALargerStringComesLast(): Void {
		Assert.equals(1, Compare.compareString('b', 'a'));
		Assert.equals(1, Compare.compareString('abc', 'ab'));
		Assert.equals(1, Compare.compareString('a', ''));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-STRING-EQUAL')
	public function testEqualStringsCompareAsZero(): Void {
		Assert.equals(0, Compare.compareString('ab', 'ab'));
		Assert.equals(0, Compare.compareString('', ''));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-STRING-CASE')
	public function testStringsOrderByCodeUnitNotByLetter(): Void {
		Assert.equals(-1, Compare.compareString('Z', 'a'));
		Assert.equals(1, Compare.compareString('a', 'B'));
	}

	public function testItSortsAnArrayTheSameWayEveryTime(): Void {
		final names: Array<String> = ['b', 'B', 'a', 'ab', ''];
		names.sort(Compare.compareString);
		Assert.same(['', 'B', 'a', 'ab', 'b'], names);
		final numbers: Array<Int> = [3, -1, 2, 2];
		numbers.sort(Compare.compareInt);
		Assert.same([-1, 2, 2, 3], numbers);
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-INT-OVERFLOW')
	public function testIntegersFarApartCompareWithoutOverflow(): Void {
		Assert.equals(1, Compare.compareInt(2147483647, -1));
		Assert.equals(-1, Compare.compareInt(-1, 2147483647));
		Assert.equals(-1, Compare.compareInt(-2147483648, 1));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-FLOAT-LESS')
	public function testASmallerFloatComesFirstEvenUnderOneApart(): Void {
		Assert.equals(-1, Compare.compareFloat(1.25, 1.5));
		Assert.equals(-1, Compare.compareFloat(-3.0, -2.5));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-FLOAT-MORE')
	public function testALargerFloatComesLastEvenUnderOneApart(): Void {
		Assert.equals(1, Compare.compareFloat(1.5, 1.25));
		Assert.equals(1, Compare.compareFloat(-2.5, -3.0));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-FLOAT-EQUAL')
	public function testEqualFloatsCompareAsZero(): Void {
		Assert.equals(0, Compare.compareFloat(2.5, 2.5));
		Assert.equals(0, Compare.compareFloat(0.0, -0.0));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-FLOAT-NAN-LESS')
	public function testNaNOnTheLeftComparesAsZero(): Void {
		Assert.equals(0, Compare.compareFloat(Math.NaN, 1.0));
		Assert.equals(0, Compare.compareFloat(Math.NaN, Math.NaN));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-FLOAT-NAN-MORE')
	public function testNaNOnTheRightComparesAsZero(): Void {
		Assert.equals(0, Compare.compareFloat(1.0, Math.NaN));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-ASC-ANSWER')
	public function testAscendingSortsByAnIntKey(): Void {
		final rows: Array<Row> = [row(3, 0, 0), row(1, 0, 0), row(2, 0, 0)];
		rows.sort(Compare.asc(r -> r.a));
		Assert.same([1, 2, 3], rows.map(r -> r.a));
		final cmp: (Row, Row) -> Int = Compare.asc(r -> r.a);
		Assert.equals(1, cmp(row(2, 0, 0), row(1, 0, 0)));
		Assert.equals(-1, cmp(row(1, 0, 0), row(2, 0, 0)));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-DESC-ANSWER')
	public function testDescendingSortsByAnIntKey(): Void {
		final rows: Array<Row> = [row(3, 0, 0), row(1, 0, 0), row(2, 0, 0)];
		rows.sort(Compare.desc(r -> r.a));
		Assert.same([3, 2, 1], rows.map(r -> r.a));
		final cmp: (Row, Row) -> Int = Compare.desc(r -> r.a);
		Assert.equals(-1, cmp(row(2, 0, 0), row(1, 0, 0)));
		Assert.equals(1, cmp(row(1, 0, 0), row(2, 0, 0)));
	}

	@:pin('guard')
	public function testAStringKeyOrdersByCodeUnit(): Void {
		final rows: Array<Row> = [named('b'), named('B'), named('a'), named('ab')];
		rows.sort(Compare.asc(r -> r.s));
		Assert.same(['B', 'a', 'ab', 'b'], rows.map(r -> r.s));
		rows.sort(Compare.desc(r -> r.s));
		Assert.same(['b', 'ab', 'a', 'B'], rows.map(r -> r.s));
	}

	public function testAFloatKeyOrdersGapsUnderOne(): Void {
		final rows: Array<Row> = [scaled(0.5), scaled(0.25), scaled(0.75)];
		rows.sort(Compare.asc(r -> r.f));
		Assert.same([0.25, 0.5, 0.75], rows.map(r -> r.f));
		rows.sort(Compare.desc(r -> r.f));
		Assert.same([0.75, 0.5, 0.25], rows.map(r -> r.f));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-ANSWER-RANGE')
	public function testTheComparatorAnswersExactlyMinusOneZeroOrOne(): Void {
		final up: (Row, Row) -> Int = Compare.asc(r -> r.a);
		final down: (Row, Row) -> Int = Compare.desc(r -> r.a);
		Assert.equals(-1, up(row(1, 0, 0), row(9, 0, 0)));
		Assert.equals(1, up(row(9, 0, 0), row(1, 0, 0)));
		Assert.equals(0, up(row(4, 0, 0), row(4, 1, 1)));
		Assert.equals(1, down(row(1, 0, 0), row(9, 0, 0)));
		Assert.equals(-1, down(row(9, 0, 0), row(1, 0, 0)));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-TIE-DROPPED')
	public function testASecondKeyBreaksTheTiesOfTheFirst(): Void {
		final rows: Array<Row> = [row(2, 2, 0), row(1, 9, 0), row(2, 1, 0), row(1, 3, 0)];
		rows.sort(Compare.asc(r -> r.a, r -> r.b));
		Assert.same([[1, 3], [1, 9], [2, 1], [2, 2]], rows.map(r -> [r.a, r.b]));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-DESC-WRAP-IGNORED')
	public function testAKeyWrappedInDescReadsDescendingInsideAsc(): Void {
		final rows: Array<Row> = [row(2, 2, 0), row(1, 9, 0), row(2, 1, 0), row(1, 3, 0)];
		rows.sort(Compare.asc(r -> r.a, Compare.desc(r -> r.b)));
		Assert.same([[1, 9], [1, 3], [2, 2], [2, 1]], rows.map(r -> [r.a, r.b]));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-ASC-WRAP-IGNORED')
	public function testAKeyWrappedInAscReadsAscendingInsideDesc(): Void {
		final rows: Array<Row> = [row(2, 2, 0), row(1, 9, 0), row(2, 1, 0), row(1, 3, 0)];
		rows.sort(Compare.desc(r -> r.a, Compare.asc(r -> r.b)));
		Assert.same([[2, 1], [2, 2], [1, 3], [1, 9]], rows.map(r -> [r.a, r.b]));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-WRAP-KEYS-LOST')
	public function testAWrappedCallKeepsAllItsKeys(): Void {
		final rows: Array<Row> = [row(1, 1, 1), row(1, 2, 1), row(1, 1, 2), row(0, 5, 5)];
		rows.sort(Compare.asc(r -> r.a, Compare.desc(r -> r.b, r -> r.c)));
		Assert.same([[0, 5, 5], [1, 2, 1], [1, 1, 2], [1, 1, 1]], rows.map(r -> [r.a, r.b, r.c]));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-THIRD-DROPPED')
	public function testThreeKeysOrderOneAfterAnother(): Void {
		final rows: Array<Row> = [row(1, 1, 2), row(1, 1, 1), row(1, 0, 9), row(0, 9, 9)];
		rows.sort(Compare.asc(r -> r.a, r -> r.b, r -> r.c));
		Assert.same([[0, 9, 9], [1, 0, 9], [1, 1, 1], [1, 1, 2]], rows.map(r -> [r.a, r.b, r.c]));
	}

	public function testKeysOfDifferentKindsShareOneComparator(): Void {
		final rows: Array<Row> = [mixed('b', 1, 0.5), mixed('a', 2, 0.5), mixed('a', 1, 0.25), mixed('a', 1, 0.75)];
		rows.sort(Compare.asc(r -> r.s, r -> r.a, r -> r.f));
		Assert.same(['a1 0.25', 'a1 0.75', 'a2 0.5', 'b1 0.5'], rows.map(r -> '${r.s + r.a} ${r.f}'));
	}

	public function testAKeyReadsLocalsNamedLikeTheComparatorParameters(): Void {
		final x: Int = 10;
		final y: Int = 20;
		final rows: Array<Row> = [row(2, 0, 0), row(1, 0, 0)];
		rows.sort(Compare.desc(r -> r.a * x + y));
		Assert.same([2, 1], rows.map(r -> r.a));
		rows.sort(Compare.asc(r -> r.a * x - y));
		Assert.same([1, 2], rows.map(r -> r.a));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-LEFT-CAPTURE')
	public function testAFirstKeyReadsALocalNamedX(): Void {
		final x: Int = -100;
		final cmp: (Row, Row) -> Int = Compare.asc(r -> r.a + x);
		Assert.equals(1, cmp(row(2, 0, 0), row(1, 0, 0)));
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-RIGHT-CAPTURE')
	public function testALaterKeyReadsALocalNamedY(): Void {
		final y: Int = -100;
		final cmp: (Row, Row) -> Int = Compare.asc(r -> r.a, r -> r.b * y);
		Assert.equals(1, cmp(row(1, 1, 0), row(1, 2, 0)));
	}

	public function testAKeyParameterMayBeNamedLikeAComparatorParameter(): Void {
		final rows: Array<Row> = [row(2, 0, 0), row(1, 0, 0)];
		rows.sort(Compare.asc(x -> x.a));
		Assert.same([1, 2], rows.map(r -> r.a));
		rows.sort(Compare.desc(y -> y.a, _cmpL -> _cmpL.b)); // noqa: no-underscore-prefix
		Assert.same([2, 1], rows.map(r -> r.a));
	}

	public function testALaterKeyIsNotReadWhenAnEarlierOneDecides(): Void {
		var reads: Int = 0;
		final probe: (Int) -> Int = value -> {
			reads++;
			return value;
		};
		final cmp: (Row, Row) -> Int = Compare.asc(r -> r.a, r -> probe(r.b));
		Assert.equals(-1, cmp(row(1, 0, 0), row(2, 0, 0)));
		Assert.equals(0, reads);
		Assert.equals(0, cmp(row(1, 0, 0), row(1, 0, 0)));
		Assert.equals(2, reads);
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-NAN-TIE')
	public function testANaNKeyPassesTheTieToTheNextKey(): Void {
		final cmp: (Row, Row) -> Int = Compare.asc(r -> r.f, r -> r.a);
		Assert.equals(-1, cmp(mixed('', 1, Math.NaN), mixed('', 2, 1.0)));
		Assert.equals(1, cmp(mixed('', 2, Math.NaN), mixed('', 1, Math.NaN)));
	}

	@:pin('guard')
	public function testAnAnnotatedKeyParameterNeedsNoExpectedType(): Void {
		Assert.equals(1, Compare.desc((r: Row) -> r.a)(row(1, 0, 0), row(2, 0, 0)));
	}

	@:pin('guard')
	public function testAParenthesisedLambdaKeyIsRead(): Void {
		final cmp: (Row, Row) -> Int = Compare.asc((r -> r.a)); // noqa: redundant-parens
		Assert.equals(-1, cmp(row(1, 0, 0), row(2, 0, 0)));
	}

	@:pin('guard')
	public function testAParenthesisedWrappedCallIsRead(): Void {
		final cmp: (Row, Row) -> Int = Compare.asc(r -> r.a, (Compare.desc(r -> r.b))); // noqa: redundant-parens
		Assert.equals(-1, cmp(row(1, 5, 0), row(1, 1, 0)));
	}

	@:pin('guard')
	public function testTheQualifiedMacroNameOverridesToo(): Void {
		final cmp: (Row, Row) -> Int = Compare.asc(r -> r.a, anyparse.util.Compare.desc(r -> r.b));
		Assert.equals(-1, cmp(row(1, 5, 0), row(1, 1, 0)));
	}

	public function testAWellFormedCallCompilesInTheRefusalFixture(): Void {
		final run: Null<ProcessRun> = typecheck('rows.sort(Compare.asc(r -> r.a, Compare.desc(r -> r.b)));');
		if (run != null) Assert.equals(0, run.status, run.err);
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-RETURN-ALLOWED')
	public function testAReturnInsideAKeyIsRefused(): Void {
		assertRefused('rows.sort(Compare.asc(r -> if (r.a > 0) return 1 else 2));', 'a block body is not supported');
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-BLOCK-ALLOWED')
	public function testABlockBodiedKeyIsRefused(): Void {
		assertRefused('rows.sort(Compare.asc(r -> { return r.a; }));', 'a block body is not supported');
		assertRefused('rows.sort(Compare.asc(r -> { r.a; }));', 'a block body is not supported');
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-NULL-ALLOWED')
	public function testANullableKeyIsRefused(): Void {
		assertRefused('rows.sort(Compare.asc(r -> r.n));', 'Compare key is Null');
		assertRefused('rows.sort(Compare.asc(r -> r.a, Compare.desc(r -> r.n)));', 'Compare key is Null');
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-ARITY')
	public function testAKeyThatIsNotALambdaIsRefused(): Void {
		assertRefused('rows.sort(Compare.asc(rows));', 'must be a lambda with one parameter');
		assertRefused('rows.sort(Compare.asc((a, b) -> a.a));', 'must be a lambda with one parameter');
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-NO-KEYS')
	public function testACallWithoutKeysIsRefused(): Void {
		assertRefused('rows.sort(Compare.asc());', 'at least one key lambda');
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-NO-ELEMENT-TYPE')
	public function testAComparatorWithoutAnElementTypeIsRefused(): Void {
		assertRefused('final cmp = Compare.asc(r -> r.a);', 'the element type is unknown');
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-NULL-ALIAS-ALLOWED')
	public function testANullableKeyBehindATypedefIsRefused(): Void {
		assertRefused('rows.sort(Compare.asc(r -> r.m));', 'Compare key is Null');
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-ALIAS-BLIND')
	public function testAnImportAliasOfCompareIsRecognisedInsideAKey(): Void {
		final run: Null<ProcessRun> = typecheck(
			'rows.sort(Order.asc(r -> r.a, Order.desc(r -> r.b)));', 'import anyparse.util.Compare as Order;'
		);
		if (run != null) Assert.equals(0, run.status, run.err);
	}

	@:pin('control')
	@:killer('M-UTIL-COMPARE-KEY-UNORDERED-ALLOWED')
	public function testABoolKeyIsRefusedAtTheCall(): Void {
		assertRefused('rows.sort(Compare.asc(r -> r.flag));', 'Compare key must be an Int, a Float or a String, not Bool');
		final run: Null<ProcessRun> = typecheck('rows.sort(Compare.asc(r -> r.flag));');
		if (run == null) return;
		Assert.isTrue(run.err.indexOf('Main.hx:') >= 0, run.err);
		Assert.isTrue(run.err.indexOf('CompareKeys.hx') < 0, run.err);
	}

	private static function row(a: Int, b: Int, c: Int): Row {
		return {
			a: a,
			b: b,
			c: c,
			s: '',
			f: 0.0
		};
	}

	private static function named(s: String): Row {
		return {
			a: 0,
			b: 0,
			c: 0,
			s: s,
			f: 0.0
		};
	}

	private static function scaled(f: Float): Row {
		return {
			a: 0,
			b: 0,
			c: 0,
			s: '',
			f: f
		};
	}

	private static function mixed(s: String, a: Int, f: Float): Row {
		return {
			a: a,
			b: 0,
			c: 0,
			s: s,
			f: f
		};
	}

	private static function typecheck(statement: String, header: String = 'import anyparse.util.Compare;'): Null<ProcessRun> {
		#if (sys || nodejs)
		final main: String = '$header\n\ntypedef MaybeInt = Null<Int>;\n\n'
			+ 'typedef Row = {final a: Int; final b: Int; final n: Null<Int>; final m: MaybeInt; final flag: Bool;}\n\nclass Main {\n'
			+ '\tstatic function main():Void {\n\t\tfinal rows:Array<Row> = [];\n\t\t$statement\n\t}\n}\n';
		final dir: String = CliFixture.writeTree('comparekeys', [{ name: 'Main.hx', source: main }]);
		final run: ProcessRun = ProcessSpawn.run(['-cp', '.', '-cp', '${Sys.getCwd()}src', '-main', 'Main', '--no-output'], dir, 1 << 20);
		CliFixture.removeDir(dir);
		return run;
		#else
		return null;
		#end
	}

	private static function assertRefused(statement: String, message: String): Void {
		final run: Null<ProcessRun> = typecheck(statement);
		if (run == null) return;
		Assert.notEquals(0, run.status);
		Assert.isTrue(run.err.indexOf(message) >= 0, run.err);
	}

}
