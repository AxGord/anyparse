package unit.check.scan;

import anyparse.check.common.control.JoinBranchCall;

/**
 * A receiver written with no type is read as the type the typer binds it to: a loop binder as its iterable's element, a
 * lambda parameter as the function type the lambda is expected to be, a bare inherited member as its declaration. A
 * field read through a typedef alias asks the aliased type. What still resolves to nothing may be a getter and is impure,
 * so `join-branch-call` keeps the branches apart.
 */
class PurityBinderTypesTest extends Test {

	/**
	 * A class with a plain field `x` and a getter `g`, and its alias.
	 */
	private static final TYPES: String =
		'class P { public var x:Int = 0; public var g(get, never):Int; function get_g():Int return 1; }\ntypedef Al = P;\n';

	@:pin('control')
	@:killer('M-PURITY-BOUND-RECEIVER')
	public function testLoopBinderPlainFieldReadIsPure(): Void {
		Assert.equals(1, violations('function f(c:Bool, us:Array<P>) { for (u in us) { if (c) h(u.x, 1); else h(u.x, 2); } }'));
	}

	@:pin('control')
	@:killer('M-PURITY-GETTER-OFF')
	public function testLoopBinderGetterReadIsNotPure(): Void {
		Assert.equals(0, violations('function f(c:Bool, us:Array<P>) { for (u in us) { if (c) h(u.g, 1); else h(u.g, 2); } }'));
	}

	@:pin('control')
	@:killer('M-PURITY-BOUND-RECEIVER')
	public function testLambdaParameterPlainFieldReadIsPure(): Void {
		Assert.equals(1, violations('function f(c:Bool, us:Array<P>) { each(us, u -> { if (c) h(u.x, 1); else h(u.x, 2); }); }'));
	}

	@:pin('control')
	@:killer('M-PURITY-GETTER-OFF')
	public function testLambdaParameterGetterReadIsNotPure(): Void {
		Assert.equals(0, violations('function f(c:Bool, us:Array<P>) { each(us, u -> { if (c) h(u.g, 1); else h(u.g, 2); }); }'));
	}

	@:pin('control')
	@:killer('M-PURITY-ALIAS-GETTER')
	public function testPlainFieldReadThroughAliasIsPure(): Void {
		Assert.equals(1, violations('function f(c:Bool, u:Al) { if (c) h(u.x, 1); else h(u.x, 2); }'));
	}

	@:pin('control')
	@:killer('M-PURITY-GETTER-OFF')
	public function testGetterReadThroughAliasIsNotPure(): Void {
		Assert.equals(0, violations('function f(c:Bool, u:Al) { if (c) h(u.g, 1); else h(u.g, 2); }'));
	}

	@:pin('control')
	@:killer('M-PURITY-UNRESOLVED-RECEIVER')
	public function testUntypedParameterReadIsNotPure(): Void {
		Assert.equals(0, violations('function f(c:Bool, u) { if (c) h(u.x, 1); else h(u.x, 2); }'));
	}

	@:pin('control')
	@:killer('M-PURITY-UNRESOLVED-RECEIVER')
	public function testUntypedLocalReadIsNotPure(): Void {
		Assert.equals(0, violations('function f(c:Bool) { var u = mk(); if (c) h(u.x, 1); else h(u.x, 2); }'));
	}

	@:pin('control')
	@:killer('M-PURITY-TRANSPARENT-CALL-RECEIVER')
	public function testTransparentCallOnGetterReceiverIsNotPure(): Void {
		final member: String = 'var s(get, never):String; static function get_s():String return \'\'; '
			+ 'public static function f(c:Bool) { if (c) h(s.charCodeAt(0), 1); else h(s.charCodeAt(0), 2); }';
		Assert.equals(0, violations(member));
	}

	@:pin('control')
	@:killer('M-PURITY-IMPLICIT-SELF-MEMBER')
	public function testInheritedMemberReadWithoutSelfIsPure(): Void {
		final src: String = 'class Base { public var p:P; public function new() {} }\nclass D extends Base {\n'
			+ '\tstatic function h(a:Int, b:Int) {}\n\tpublic function f(c:Bool) { if (c) h(p.x, 1); else h(p.x, 2); }\n}';
		Assert.equals(1, CheckFixture.violations(new JoinBranchCall(), TYPES + src).length);
	}

	/** The `join-branch-call` findings of `member`, placed in a class beside `TYPES` with the helpers it calls. */
	private static function violations(member: String): Int {
		final src: String = '${TYPES}class B {\n\tstatic function h(a:Int, b:Int) {}\n'
			+ '\tstatic function each(xs:Array<P>, fn:P->Void) {}\n\tpublic static $member\n}';
		return CheckFixture.violations(new JoinBranchCall(), src).length;
	}

}
