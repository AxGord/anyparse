package unit.query;

import utest.Assert;
import utest.Test;

/**
 * The index host's answers for a value composed of others (`ComposedValues`): a construction, an element read by index,
 * an operator over its operands, the element a loop over an interval binds, an enum-abstract value and an array or object
 * literal — each as Haxe 4.3.7 types it, or null where the walk cannot say exactly.
 */
@:nullSafety(Strict)
class ComposedValuesTest extends Test {

	/** The fixture module: each case is the node of a kind starting at a marked text. */
	private static final SOURCE: String = 'package p;\n\ntypedef Inner = { x: Int };\n\ntypedef Num = { v: Float };\n\ntypedef Opt = {'
		+ ' a: Float, ?b: Int, ?c: String, ?k: Item, ?p: Plain };\n\ntypedef Dyn = { m: Dynamic, ?d: Dynamic };\n\ntypedef Outer = {'
		+ ' a: Int, inner: Inner, ?list: Array<Int> };\n\nabstract U(Int) from Int to Int {\n\t@:op(A + B) static function add(a: U, b: '
		+ 'U): U return a;\n\n\t@:arrayAccess function get(i: Int): String return "";\n}\n\nabstract Two(Int) from Int {\n\t@:arrayAccess '
		+ 'function byInt(i: Int): Float return 1.0;\n\n\t@:arrayAccess function byName(s: String): Bool return true;\n}\n\nabstract '
		+ 'W(Int) {\n#if !x\n\t@:op(A * B) static function mulA(a: W, b: W): W return a;\n#end\n\n\t@:op(A * B) static function mulB(a: '
		+ 'W, b: Float): Float return 1.0;\n}\n\nabstract Plain(Int) from Int to Int {}\n\nenum abstract Color(Int) {\n\tvar Red = 1;\n'
		+ '}\n\nclass Box<T> {\n\tpublic function new(?t: T) {}\n}\n\nclass Item {}\n\nclass Def<T = Item> {\n\tpublic function new() {}\n'
		+ '}\n\nclass C {\n\tstatic function take(o: Outer) {}\n\n\tstatic function any(o: Dynamic) {}\n\n\tstatic function num(o: Num) '
		+ '{}\n\n\tstatic function opt(o: Opt) {}\n\n\tstatic function dyn(o: Dyn) {}\n\n\tfunction f<T>(n: Null<Int>, i: Int, fl: Flo'
		+ 'at, s: String, u: U, two: Two, plain: Plain, a: Array<Int>, na: Null<Array<Int>>, d: Dynamic, w: W, it: Item) {\n\t\tnew '
		+ 'Box<Int>();\n\t\tnew Box(i);\n\t\tnew Def();\n\t\tnew T();\n\t\ta[0];\n\t\tna[0];\n\t\tu[0];\n\t\ttwo[0];\n\t\ttwo["k"];\n'
		+ '\t\td[0];\n\t\ti + fl;\n\t\ts + i;\n\t\tn + 1;\n\t\t-n;\n\t\ti < fl;\n\t\tn += 1;\n\t\tu + u;\n\t\tplain + 1;\n\t\tfor ('
		+ 'k in 0...i) trace(k);\n\t\tColor.Red;\n\t\tfinal xs = [1, 2.5];\n\t\tfinal o = { a: 1, b: "x" };\n\t\tfinal none = [];\n'
		+ '\t\tfinal pick = i < 0 ? 1 : 2.5;\n\t\tany([1, 2]);\n\t\ttake({ a: 1, inner: { x: 2 } });\n\t\tnum({ v: 1 });\n\t\t(n + 1);\n'
		+ '\t\tfinal nxs = [n, 1];\n\t\tfinal nfl = [n, 1.5];\n\t\tfinal npick = i < 0 ? n : 1;\n\t\topt({ a: 1, b: 2 });\n\t\topt({ a: '
		+ '1.5, k: it });\n\t\topt({ a: 2.5, p: plain });\n\t\tdyn({ m: [1], d: { q: 1 } });\n\t\tany(["k" => 1]);\n\t\tw * w;\n\t}\n}\n';

	@:pin('control') @:killer('M-COMPOSED-CONSTRUCTION-NULL')
	public function testAConstructionIsTheTypeItWrites(): Void {
		Assert.equals('Box<Int>', source('NewExpr', 'new Box<Int>'), 'with the arguments it writes');
	}

	@:pin('control') @:killer('M-COMPOSED-CONSTRUCTION-AS-WRITTEN', 'M-COMPOSED-DEFAULTS-UNWRITTEN')
	public function testAConstructionLeavingArgumentsToInferenceIsUnknown(): Void {
		Assert.isNull(source('NewExpr', 'new Box(i)'), 'a `Box<Int>` nothing spells');
		Assert.isNull(source('NewExpr', 'new T()'), 'a type parameter makes what its call binds');
		Assert.isNull(source('NewExpr', 'new Def'), 'a monomorph the code binds later, though its parameter has a default');
	}

	@:pin('control') @:killer('M-COMPOSED-ELEMENT-NULL')
	public function testAnIndexAccessReadsTheElement(): Void {
		Assert.equals('Int', source('IndexAccess', 'a[0]'), 'an array\'s element');
		Assert.equals('Int', source('IndexAccess', 'na[0]'), 'through a `Null<…>`');
		Assert.equals('String', source('IndexAccess', 'u[0]'), 'an abstract\'s read access');
		Assert.isNull(source('IndexAccess', 'd[0]'), 'a dynamic value\'s element is a monomorph');
	}

	@:pin('control') @:killer('M-INDEX-READ-FIRST')
	public function testAnAbstractsReadAccessIsTheOneTheKeyCastsTo(): Void {
		Assert.equals('Float', source('IndexAccess', 'two[0]'), 'an `Int` key');
		Assert.equals('Bool', source('IndexAccess', 'two["k"]'), 'a `String` key');
	}

	@:pin('control') @:killer('M-COMPOSED-OPERATOR-NULL')
	public function testAnOperatorOverCoreValuesIsTheLanguagesOwn(): Void {
		Assert.equals('Float', source('Add', 'i + fl'), 'an `Int` and a `Float`');
		Assert.equals('String', source('Add', 's + i'), 'a concatenation');
		Assert.equals('Int', source('Add', 'n + 1'), 'a `Null<Int>` operand');
		Assert.equals('Int', source('Neg', '-n'), 'the negation');
		Assert.equals('Bool', source('Lt', 'i < fl'), 'a comparison');
	}

	@:pin('control') @:killer('M-COMPOUND-KEEPS-TARGET-FALSE')
	public function testACompoundAssignmentIsOfItsTargetsType(): Void {
		Assert.equals('Null<Int>', source('AddAssign', 'n += 1'), 'the target\'s, its `Null<…>` kept');
	}

	@:pin('control') @:killer('M-COMPOSED-OVERLOAD-NULL')
	public function testAnOperatorAnAbstractTakesIsItsOverloads(): Void {
		Assert.equals('U', source('Add', 'u + u'), 'the overload\'s return');
		Assert.isNull(source('Add', 'plain + 1'), 'an abstract no overload decides');
	}

	@:pin('control') @:killer('M-COMPOSED-INTERVAL-NULL')
	public function testALoopOverAnIntervalBindsTheIntegerType(): Void {
		Assert.equals('Int', source('IdentExpr', 'k);'), 'the binder of `0...i`');
	}

	@:pin('control') @:killer('M-COMPOSED-ENUM-VALUE-NULL')
	public function testAnEnumAbstractValueIsOfTheAbstract(): Void {
		Assert.equals('Color', source('FieldAccess', 'Color.Red'), 'a value written with no type');
	}

	@:pin('control') @:killer('M-COMPOSED-PARTS-NULL')
	public function testALiteralExpectedOfNothingIsOfItsParts(): Void {
		Assert.equals('Array<Float>', source('FinalStmt', 'final xs'), 'core numbers widen');
		Assert.equals('{a: Int, b: String}', source('FinalStmt', 'final o'), 'a structure of its fields');
		Assert.isNull(source('FinalStmt', 'final none'), 'an empty one is a monomorph');
	}

	@:pin('control') @:killer('M-COMPOSED-EXPECTED-NULL')
	public function testALiteralExpectedOfATypeIsTheTypeItPicks(): Void {
		Assert.equals('Array<Dynamic>', source('ArrayExpr', '[1, 2]);'), 'an array under the dynamic type');
		Assert.equals(
			'{a: Int, inner: {x: Int}, ?list: Array<Int>}', source('ObjectLit', '{ a: 1, inner'),
			'the fields it writes, and the optional ones it leaves out'
		);
		Assert.equals('{v: Float}', source('ObjectLit', '{ v: 1 }'), 'a core value cast to the field\'s type');
	}

	@:pin('control') @:killer('M-COMPOSED-BRANCHES-NULL')
	public function testAConditionalExpectedOfNothingUnifiesItsBranches(): Void {
		Assert.equals('Float', source('FinalStmt', 'final pick'), 'an `Int` and a `Float` branch');
	}

	@:pin('control') @:killer('M-INDEX-HOST-PARENS-KEPT')
	public function testAParenthesizedValueIsTheValues(): Void {
		Assert.equals('Int', source('ParenExpr', '(n + 1)'), 'parentheses change no type');
	}

	@:pin('control') @:killer('M-COMPOSED-UNIFIED-NULLABLE-DROPPED')
	public function testANullablePartMakesTheUnifiedTypeNullable(): Void {
		Assert.equals('Array<Null<Int>>', source('FinalStmt', 'final nxs'), 'a `Null<Int>` and an `Int`');
		Assert.equals('Array<Null<Float>>', source('FinalStmt', 'final nfl'), 'a `Null<Int>` and a `Float`');
		Assert.equals('Null<Int>', source('FinalStmt', 'final npick'), 'the branches of a conditional');
	}

	@:pin('control') @:killer('M-COMPOSED-OPTIONAL-FIELD-BARE', 'M-COMPOSED-NULLABLE-KEEPS-OWN', 'M-COMPOSED-NULLABLE-ABSTRACT-DECIDED')
	public function testAWrittenOptionalFieldHoldsANullableValue(): Void {
		Assert.equals(
			'{a: Float, b: Null<Int>, ?c: String, ?k: Item, ?p: Plain}', source('ObjectLit', '{ a: 1, b: 2 }'),
			'an `Int` written for `?b: Int`'
		);
		Assert.equals(
			'{a: Float, ?b: Int, ?c: String, k: Item, ?p: Plain}', source('ObjectLit', '{ a: 1.5, k: it }'),
			'a class instance, which may be null already'
		);
		Assert.isNull(source('ObjectLit', '{ a: 2.5, p: plain }'), 'an abstract is what it wraps');
	}

	@:pin('control') @:killer('M-COMPOSED-DYNAMIC-FIELD-LITERAL', 'M-COMPOSED-MAP-UNDER-DYNAMIC')
	public function testALiteralForADynamicFieldIsDynamic(): Void {
		Assert.equals('{m: Dynamic, d: Null<Dynamic>}', source('ObjectLit', '{ m: [1]'), 'the field\'s type, not the literal\'s');
		Assert.isNull(source('ArrayExpr', '["k" => 1]'), 'a map literal is a map, whatever is expected of it');
	}

	@:pin('control') @:killer('M-OVERLOAD-GUARDED-SOURCE-ORDER')
	public function testAnOverloadUnderAConditionLeavesTheOperatorUndecided(): Void {
		Assert.isNull(source('Mul', 'w * w'), 'the compiler tries `#if` overloads in source order, the index lists them last');
	}

	/** The written-source answer for the node of `kind` starting at the first character of the first `at` of `SOURCE`. */
	private static function source(kind: String, at: String): Null<String> {
		return ValueDoorsTest.typedIn(SOURCE, 'p/C.hx', [], kind, at).source;
	}

}
