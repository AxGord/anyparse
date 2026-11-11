package unit.check.scan;

import anyparse.check.common.control.JoinBranchCall;

/**
 * A field read on an abstract asks only about field-read interception (`@:op(a.b)`, `@:resolve`):
 * an index overload or an unrelated `@:op` does not make `xs.push` run code, so the purity walk
 * behind `join-branch-call` stays open on it.
 */
class PurityFieldReadOverloadTest extends Test {

	/** Two abstracts declaring `push`, one intercepting field reads with `@:op(a.b)`, one with `@:resolve`. */
	private static final INTERCEPTORS: String = 'abstract WithDot<T>(Array<T>) {'
		+ ' public function push(x:T):Int return this.push(x); @:op(a.b) function '
		+ 'dot(n:String):Int return 0; }\nabstract WithResolve<T>(Array<T>) { public function '
		+ 'push(x:T):Int return this.push(x); @:resolve function res(n:String):Int return 0; }\n';

	@:pin('control')
	@:killer('M-PURITY-FIELD-READ-ASKS-INDEX')
	public function testFieldReadIgnoresIndexAndUnrelatedOperator(): Void {
		final src: String = 'abstract Plain<T>(Array<T>) { public function push(x:T):Int return this.push(x); }\n'
			+ 'abstract WithIndex<T>(Array<T>) { public function push(x:T):Int return this.push(x); @:arrayAccess public '
			+ 'function get(i:Int):T return this[i]; }\nabstract WithOp<T>(Array<T>) { public function push(x:T):Int '
			+ 'return this.push(x); @:op(A + B) static function add<T>(a:WithOp<T>, b:WithOp<T>):WithOp<T> return a; }\n'
			+ 'class B {\n\tpublic static function p(c:Bool, xs:Plain<Int>) { if (c) xs.push(1); else xs.push(2); }\n'
			+ '\tpublic static function i(c:Bool, xs:WithIndex<Int>) { if (c) xs.push(1); else xs.push(2); }\n'
			+ '\tpublic static function o(c:Bool, xs:WithOp<Int>) { if (c) xs.push(1); else xs.push(2); }\n}';
		Assert.equals(3, CheckFixture.violations(new JoinBranchCall(), src).length);
	}

	/** An index read of an abstract declaring an index access still may run code. */
	@:pin('control')
	@:killer('M-PURITY-INDEX-READ-ASKS-FIELD')
	public function testIndexReadOfIndexedAbstractRefused(): Void {
		final src: String = 'abstract WithIndex<T>(Array<T>) { @:arrayAccess public function get(i:Int):T return this[i]; }\nclass B {\n'
			+ '\tstatic function f(a:Int, b:Int) {}\n'
			+ '\tpublic static function i(c:Bool, xs:WithIndex<Int>) { if (c) f(xs[0], 1); else f(xs[0], 2); }\n}';
		Assert.equals(0, CheckFixture.violations(new JoinBranchCall(), src).length);
	}

	/** A read of a name an abstract with `@:op(a.b)` or `@:resolve` does not declare runs the interceptor. */
	@:pin('control')
	@:killer('M-PURITY-FIELD-INTERCEPTOR-IGNORED')
	public function testFieldReadOfInterceptingAbstractRefused(): Void {
		final src: String = '${INTERCEPTORS}class B {\n\tstatic function f(a:Int, b:Int) {}\n'
			+ '\tpublic static function d(c:Bool, xs:WithDot<Int>) { if (c) f(xs.foo, 1); else f(xs.foo, 2); }\n'
			+ '\tpublic static function r(c:Bool, xs:WithResolve<Int>) { if (c) f(xs.foo, 1); else f(xs.foo, 2); }\n}';
		Assert.equals(0, CheckFixture.violations(new JoinBranchCall(), src).length);
	}

	/** A declared member of an intercepting abstract is read directly: the interceptor runs only for an undeclared name. */
	@:pin('control')
	@:killer('M-PURITY-INTERCEPTOR-DECLARED-NAME')
	public function testDeclaredFieldOfInterceptingAbstractStaysPure(): Void {
		final src: String = '${INTERCEPTORS}class B {\n\tpublic static function d(c:Bool, xs:WithDot<Int>) { if (c) xs.push(1); else '
			+ 'xs.push(2); }\n\tpublic static function r(c:Bool, xs:WithResolve<Int>) { if (c) xs.push(1); else xs.push(2); }\n}';
		Assert.equals(2, CheckFixture.violations(new JoinBranchCall(), src).length);
	}

}
