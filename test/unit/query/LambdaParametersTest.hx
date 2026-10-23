package unit.query;

import unit.QueryTestHelpers;

/**
 * The type the index host gives a lambda's parameter written with none (`LambdaParameters`): the parameter at its position
 * of the function type the lambda is expected to be — a declaration's type, a callee's parameter with the receiver's type
 * arguments and the type parameters the arguments before the lambda bind (`CallReturns`, `Monomorphs`), a static
 * extension's with the receiver bound first — or null where Haxe 4.3.7 would leave a monomorph.
 */
@:nullSafety(Strict)
class LambdaParametersTest extends Test {

	/** The fixture module: each case reads its lambda's parameter, named apart, in the lambda's body. */
	private static final SOURCE: String = 'package p;\n\nusing p.Ext;\n\nclass Item {\n\tpublic var n: Int = 0;\n\n'
		+ '\tpublic function new() {}\n}\n\nclass Box<T> {\n\tpublic function new() {}\n\n'
		+ '\tpublic function each(f: T -> Void): Void {}\n\n\tpublic function shadow<T>(x: T, f: T -> Void): Void {}\n}\n\n'
		+ 'class Sub extends Box<Item> {}\n\nclass Shelf {}\n\nclass C {\n\tstatic function arr<A>(x: A, f: Array<A> -> Void): Void {}\n\n'
		+ '\tstatic function gen<A>(b: Box<A>, f: A -> Void): Void {}\n\n'
		+ '\tstatic function pair<A, B>(b: Box<A>, f: A -> B): Void {}\n\n\tstatic function late<A>(f: A -> '
		+ 'Void, a: A): Void {}\n\n\tstatic function nul<A>(x: Null<A>, f: A -> Void): Void {}\n\n\tstatic '
		+ 'function dyn(f: Dynamic -> Bool): Void {}\n\n\tstatic function take(f: Item -> Bool): Void {}\n\n'
		+ '\tfunction f(b: Box<Item>, n: Null<Int>, it: Item, s: Shelf, d: Dynamic) {\n\t\ttake(a1 -> a1.n > 0);\n\t\tb.each(a2 -> '
		+ 'trace(a2));\n\t\tgen(b, a3 -> trace(a3));\n\t\tlate(a4 -> trace(a4), it);\n\t\tnul(n, a5 -> '
		+ 'trace(a5));\n\t\tgen(new Sub(), a6 -> trace(a6));\n\t\tdyn(a7 -> a7.lock);\n\t\ts.pick(it, a8 -> '
		+ 'trace(a8));\n\t\tfinal g: Item -> Bool = a9 -> a9.n > 0;\n\t\tpair(b, a10 -> a10.n);\n\t\ttake((?a11) -> a11 != null);\n'
		+ '\t\ttake(function(a12 = null) return a12 != null);\n\t\tarr(d, a13 -> trace(a13));\n\t\tb.shadow(1, a14 -> trace(a14));\n'
		+ '\t}\n}\n';

	/** The static extension the fixture's `using` brings. */
	private static final EXT: String =
		'package p;\n\nimport p.C.Shelf;\n\nclass Ext {\n\tpublic static function pick<A>(s: Shelf, a: A, f: A -> Void): Void {}\n}\n';

	/** A callee written in another package, beside a caller declaring a namesake of a type its parameter names and one that does not. */
	private static final NAMESAKES: Array<{ file: String, source: String }> = [
		{ file: 'lib/Item.hx', source: 'package lib;\n\nclass Item {\n\tpublic var tag: Int = 0;\n}\n' },
		{
			file: 'lib/Box.hx',
			source: 'package lib;\n\nimport lib.Item;\n\nclass Box {\n\tpublic static function plain(f: Item -> Void): Void {}\n}\n'
		},
		{
			file: 'app2/Use.hx',
			source: 'package app2;\n\nimport lib.Box;\nimport lib.Item;\n\nclass Use {\n\tfunction f() {\n\t\tBox.plain(n2 -> trace(n2));\n'
				+ '\t}\n}\n'
		}
	];

	/** The caller declaring its own `Item`. */
	private static final SHADOWING: String = 'package app;\n\nimport lib.Box;\n\nclass Item {\n\tpublic var tag: String = "";\n}\n\n'
		+ 'class Probe {\n\tfunction f() {\n\t\tBox.plain(n1 -> trace(n1));\n\t}\n}\n';

	/** A caller declaring its own `Item`, typing a value read off a member another file writes `Box<Item>`. */
	private static final THIRD_FILE: String = 'package app;\n\nimport lib.Box;\nimport lib.Holder;\n\nclass Item {}\n\nclass Main {\n'
		+ '\tstatic function gen<A>(b: Box<A>, f: A -> Void): Void {}\n\n\tfunction f(h: Holder, b2: Box<Item>) {\n'
		+ '\t\tgen(h.box, t1 -> trace(t1));\n\t\tgen(b2, t2 -> trace(t2));\n\t}\n}\n';

	/** The member's file and the type it names. */
	private static final HOLDER: Array<{ file: String, source: String }> = [
		{ file: 'lib/Item.hx', source: 'package lib;\n\nclass Item {}\n' },
		{ file: 'lib/Box.hx', source: 'package lib;\n\nclass Box<T> {}\n' },
		{
			file: 'lib/Holder.hx',
			source: 'package lib;\n\nimport lib.Box;\nimport lib.Item;\n\nclass Holder {\n\tpublic final box: Box<Item> = null;\n}\n'
		}
	];

	/** The std the iteration cases read: `Iterable`, an array the index holds two copies of, `Lambda`. */
	private static final STD: Array<{ file: String, source: String }> = [
		{
			file: QueryTestHelpers.stdPath('StdTypes.hx'),
			source: 'typedef Iterator<T> = {\n\tfunction hasNext(): Bool;\n\tfunction next(): T;\n}\n\n'
				+ 'typedef Iterable<T> = {\n\tfunction iterator(): Iterator<T>;\n}\n'
		},
		{
			file: QueryTestHelpers.stdPath('Array.hx'),
			source: 'extern class Array<T> {\n\tfunction iterator(): haxe.iterators.ArrayIterator<T>;\n\n'
				+ '\tfunction filter(f: T -> Bool): Array<T>;\n}\n'
		},
		{
			file: QueryTestHelpers.stdPath('js/_std/Array.hx'),
			source: 'extern class Array<T> {\n\tfunction iterator(): haxe.iterators.ArrayIterator<T>;\n\n'
				+ '\tfunction filter(f: (item: T) -> Bool): Array<T>;\n}\n'
		},
		{
			file: QueryTestHelpers.stdPath('haxe/iterators/ArrayIterator.hx'),
			source: 'package haxe.iterators;\n\nclass ArrayIterator<T> {\n\tpublic function hasNext(): Bool {\n\t\treturn false;\n\t}\n\n'
				+ '\tpublic function next(): T {\n\t\treturn null;\n\t}\n}\n'
		},
		{
			file: QueryTestHelpers.stdPath('Lambda.hx'),
			source: 'class Lambda {\n\tpublic static function exists<A>(it: Iterable<A>, f: (item: A) -> Bool): Bool {\n\t\treturn false;\n'
				+ '\t}\n}\n'
		}
	];

	/** The iteration cases: a std container, its member under two spellings, a class whose own `iterator()` yields. */
	private static final ITERATING: String = 'package p;\n\nusing Lambda;\n\nclass Item {\n\tpublic var n: Int = 0;\n}\n\nclass Bag<T> {\n'
		+ '\tpublic function iterator(): Iterator<T> {\n\t\treturn null;\n\t}\n}\n\nclass C {\n\tfunction f(xs: Array<Item>, bag: '
		+ 'Bag<Item>) {\n\t\txs.exists(b1 -> b1.n > 0);\n\t\txs.filter(b2 -> b2.n > 0);\n\t\tLambda.exists(bag, b3 -> b3.n > 0);\n\t}\n'
		+ '}\n\nabstract Pack(Bag<Item>) {\n\tfunction any(): Bool {\n\t\treturn Lambda.exists(this, b4 -> b4.n > 0);\n\t}\n}\n';

	@:pin('control') @:killer('M-LAMBDA-PARAMETER-NULL')
	public function testAParameterTakesTheTypeItsPositionExpects(): Void {
		Assert.equals('Item', typed('a1.n'), 'a callee\'s concrete parameter');
		Assert.equals('Item', typed('a9.n'), 'a declaration\'s type');
	}

	@:pin('control') @:killer('M-RECEIVER-ARGUMENTS-DROPPED')
	public function testTheReceiversArgumentsBindItsTypesParameters(): Void {
		Assert.equals('Item', typed('a2)'), '`Box<Item>.each(f: T -> Void)`');
	}

	@:pin('control') @:killer('M-INFERRED-CELLS-UNBOUND')
	public function testTheArgumentsBeforeTheLambdaBindTheCallsTypeParameters(): Void {
		Assert.equals('Item', typed('a3)'), 'a `Box<A>` parameter given a `Box<Item>`');
		Assert.equals('Item', typed('a10.n'), 'one bound, the result left to the lambda');
	}

	@:pin('control') @:killer('M-INFERENCE-REREAD-NULL')
	public function testAGivenTypeIsReadThroughTheLanguagesArcs(): Void {
		Assert.equals('Int', typed('a5)'), 'a `Null<A>` parameter given a `Null<Int>`');
		Assert.equals('Item', typed('a6)'), 'a `Box<A>` parameter given a subclass of `Box<Item>`');
	}

	@:pin('control') @:killer('M-UNBOUND-PART-TAKEN', 'M-LAMBDA-DYNAMIC-TAKEN')
	public function testAMonomorphTheLambdaMayBindIsNoAnswer(): Void {
		Assert.isNull(typed('a4)'), 'a type parameter the argument after the lambda binds');
		Assert.isNull(typed('a7.lock'), 'the dynamic type, which a monomorph does not bind to');
	}

	@:pin('control') @:killer('M-EXTENSION-PARAMETER-NULL')
	public function testAStaticExtensionBindsItsReceiverFirst(): Void {
		Assert.equals('Item', typed('a8)'), '`Ext.pick<A>(s: Shelf, a: A, f: A -> Void)`: the argument after the receiver binds `A`');
	}

	@:pin('control') @:killer('M-ONE-DECLARATION-NONE', 'M-PARAMETER-MERGE-BY-TEXT')
	public function testTheStdsCopiesOfOneTypeAnswerAsOne(): Void {
		Assert.equals('Item', iterating('b1.n'), 'the element an array binds `Iterable<A>` to');
		Assert.equals('Item', iterating('b2.n'), 'two copies writing the parameter two ways');
	}

	@:pin('control') @:killer('M-ITERATOR-ELEMENT-NULL')
	public function testAClassIteratesWhatItsIteratorYields(): Void {
		Assert.equals('Item', iterating('b3.n'), '`Bag<Item>` whose `iterator()` returns an `Iterator<T>`');
	}

	@:pin('control') @:killer('M-NAMESAKE-READS-ALIKE', 'M-LAMBDA-FOREIGN-FILE-TAKEN')
	public function testATypeWrittenInTheCalleesFileIsNoAnswerWhereTheCallerHasANamesake(): Void {
		Assert.isNull(
			ValueDoorsTest.typedIn(SHADOWING, 'app/Probe.hx', NAMESAKES, 'IdentExpr', 'n1)').source,
			'the caller\'s `Item` is not the callee\'s'
		);
		final use: { file: String, source: String } = NAMESAKES[2];
		Assert.equals(
			'Item', ValueDoorsTest.typedIn(use.source, use.file, NAMESAKES.slice(0, 2), 'IdentExpr', 'n2)').source,
			'a caller importing the callee\'s `Item` reads it alike'
		);
	}

	@:pin('control') @:killer('M-LAMBDA-OPTIONAL-TAKEN')
	public function testAParameterWrittenOptionalOrWithADefaultIsNoAnswer(): Void {
		Assert.isNull(typed('a11 != null'), '`(?x)` is a `Null<Item>`');
		Assert.isNull(typed('a12 != null'), '`x = null` is a `Null<Item>`');
	}

	@:pin('control') @:killer('M-MONO-DYNAMIC-BINDS')
	public function testTheDynamicTypeBindsNoCell(): Void {
		Assert.isNull(typed('a13)'), 'a `Dynamic` argument leaves `A` free: the lambda binds it');
	}

	@:pin('control') @:killer('M-BOUND-SHADOWED-SUBSTITUTED')
	public function testAMethodsTypeParameterShadowsItsTypesOfTheName(): Void {
		Assert.equals('Int', typed('a14)'), '`shadow<T>` of `Box<T>` on a `Box<Item>`: its own `T`');
	}

	@:pin('control') @:killer('M-ARGUMENT-WRITTEN-ELSEWHERE')
	public function testATypeAMemberReadCarriesIsNoArgumentTheCallerMayRead(): Void {
		Assert.isNull(
			ValueDoorsTest.typedIn(THIRD_FILE, 'app/Main.hx', HOLDER, 'IdentExpr', 't1)').source,
			'`h.box` is a `Box<Item>` its declaring file writes, the caller\'s `Item` another type'
		);
		Assert.equals(
			'Item', ValueDoorsTest.typedIn(THIRD_FILE, 'app/Main.hx', HOLDER, 'IdentExpr', 't2)').source, 'a `Box<Item>` the caller writes'
		);
	}

	@:pin('control') @:killer('M-SELF-UNWRITTEN')
	public function testTheSelfReferenceOfAnAbstractIsItsWrittenUnderlyingType(): Void {
		Assert.equals('Item', iterating('b4.n'), '`this` of `abstract Pack(Bag<Item>)` handed to `Iterable<A>`');
	}

	/** The written-source answer for the identifier starting at the first `at` of `SOURCE`. */
	private static function typed(at: String): Null<String> {
		return ValueDoorsTest.typedIn(SOURCE, 'p/C.hx', [{ file: 'p/Ext.hx', source: EXT }], 'IdentExpr', at).source;
	}

	/** The written-source answer for the identifier starting at the first `at` of `ITERATING`, the std stubs indexed. */
	private static function iterating(at: String): Null<String> {
		return ValueDoorsTest.typedIn(ITERATING, 'p/C.hx', STD, 'IdentExpr', at).source;
	}

}
