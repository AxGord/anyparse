package unit.check.haxe.loops;

import anyparse.check.haxe.loops.PreferMap;

/**
 * Where a comprehension sits where an element type is expected, it takes that type into its body, while the lambda of
 * `xs.map` infers its result alone and an invariant `Array` refuses it: the rule keeps the comprehension unless the
 * expected element is the one plain type the body has. A bare callee with a parameter more than the call passes keeps that
 * parameter in its function type, so the lambda is the spelling.
 */
class PreferMapExpectedTypeTest extends Test {

	@:pin('control')
	@:killer('M-PM-EXPECTED-ELEMENT-ANY')
	public function testSubclassElementKeepsComprehension(): Void {
		assertKept('final ys: Array<Base> = [for (x in xs) new Sub(x)];');
	}

	@:pin('control')
	@:killer('M-PM-EXPECTED-ELEMENT-ANY')
	public function testNarrowedNullableAnonKeepsComprehension(): Void {
		assertKept('final ys: Array<P> = [for (x in ns) x != null ? {a: x, b: true} : {a: "", b: false}];');
	}

	@:pin('control')
	@:killer('M-PM-EXPECTED-ELEMENT-ANY')
	public function testLiteralLeavingOutOptionalFieldsKeepsComprehension(): Void {
		assertKept('send([for (x in xs) {ids: [x], add: [x]}]);');
	}

	@:pin('control')
	@:killer('M-BIND-ARITY')
	public function testBareCalleeWithOptionalParameterBecomesLambda(): Void {
		Assert.equals(
			module('final ys: Array<Bool> = ss.map(x -> opt(x));'), fixed(module('final ys: Array<Bool> = [for (x in ss) opt(x)];'))
		);
	}

	@:pin('control')
	@:killer('M-PM-EXPECTED-ELEMENT-NONE')
	public function testEqualExpectedTypeStillRewritten(): Void {
		final src: String = module('final ys: Array<Int> = [for (x in xs) one(x)];');
		Assert.equals(1, violations(src).length);
		Assert.equals(module('final ys: Array<Int> = xs.map(one);'), fixed(src));
	}

	private function assertKept(statement: String): Void {
		final src: String = module(statement);
		Assert.equals(0, violations(src).length);
		Assert.equals(src, fixed(src));
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new PreferMap(), src);
	}

	private function fixed(src: String): String {
		return CheckFixture.fixedSource(new PreferMap(), src);
	}

	private static function module(statement: String): String {
		return 'class Base { public function new(a: Int) {} }\nclass Sub extends Base {}\n'
			+ 'typedef P = { final a: String; final b: Bool; }\ntypedef Q = { ids: Array<Int>, ?add: Array<Int>, ?remove: Array<Int> '
			+ '}\n\n@:nullSafety(Strict)\nclass C {\n\tstatic function one(a: Int): Int {\n\t\treturn a;\n\t}\n\n\tstatic function '
			+ 'opt(s: String, defer: Bool = false): Bool {\n\t\treturn defer;\n\t}\n\n\tstatic function send(qs: Array<Q>): Void {}\n\n'
			+ '\tstatic function f(xs: Array<Int>, ns: Array<Null<String>>, ss: Array<String>): Void {\n\t\t$statement\n\t}\n}';
	}

}
