package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferBind;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `prefer-bind` check: a zero-parameter arrow lambda wrapping a single call with
 * arguments (`() -> f(a, b)`) is flagged `Info` and rewritten to `f.bind(a, b)`. A
 * parameter-bearing lambda, a block body, and a zero-argument call are not; nor is one whose
 * receiver or argument could read differently at creation than at the call — a written local, a
 * field, a nullable binding, a field receiver.
 */
class PreferBindCheckTest extends Test {

	public function testWrapperLambdaFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction h(a:Int, b:String):Void {}\n\tfunction f(a:Int, b:String):Void {\n\t\tvar g = () -> h(a, b);\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-bind', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testParamLambdaNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar g = x -> h(x);\n\t}\n}').length);
	}

	public function testParenParamLambdaNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar g = (x) -> h(x);\n\t}\n}').length);
	}

	public function testBlockBodyNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar g = () -> { h(a); };\n\t}\n}').length);
	}

	public function testZeroArgCallNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar g = () -> h();\n\t}\n}').length);
	}

	/** A `new X()` argument allocates — `.bind` would move the allocation to creation time; not flagged. */
	public function testAllocationArgNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar g = () -> h(new StringBuf());\n\t}\n}').length);
	}

	/** A call argument computes — `.bind` would evaluate it eagerly; not flagged. */
	public function testCallArgNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar g = () -> h(compute());\n\t}\n}').length);
	}

	/** An interpolated single-quoted string evaluates at bind time; not flagged. */
	public function testInterpolatedStringArgNotFlagged(): Void {
		Assert.equals(0, violations("class C {\n\tfunction f(x:Int):Void {\n\t\tvar g = () -> h('id-$x');\n\t}\n}").length);
	}

	/** An operator expression computes; not flagged. */
	public function testOperatorArgNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f(a:Int):Void {\n\t\tvar g = () -> h(a + 1);\n\t}\n}').length);
	}

	/** Stable values — a parameter, a final local, a plain string, a negated literal — still convert. */
	public function testStableArgsFixed(): Void {
		final src: String = "class C {\n\tfunction h(i:Int, k:String, n:Int, s:String):Void {}\n\tfunction f(i:Int):Void {\n"
			+ "\t\tfinal k:String = 'k';\n\t\tvar g = () -> h(i, k, -1, 'plain');\n\t}\n}";
		final check: PreferBind = new PreferBind();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		Assert.equals(1, edits.length);
		Assert.equals("h.bind(i, k, -1, 'plain')", edits[0].text);
	}

	public function testFixToBind(): Void {
		final src: String =
			'class C {\n\tfunction h(a:Int, b:String):Void {}\n\tfunction f(a:Int, b:String):Void {\n\t\tvar g = () -> h(a, b);\n\t}\n}';
		final check: PreferBind = new PreferBind();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		Assert.equals(1, edits.length);
		Assert.equals('h.bind(a, b)', edits[0].text);
	}

	public function testFixFieldAccessCallee(): Void {
		final src: String = 'class Obj {\n\tpublic function m(x:Int):Void {}\n}\nclass C {\n\tfunction f(obj:Obj, x:Int):Void {\n'
			+ '\t\tvar g = () -> obj.m(x);\n\t}\n}';
		final check: PreferBind = new PreferBind();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		Assert.equals(1, edits.length);
		Assert.equals('obj.m.bind(x)', edits[0].text);
	}

	/**
	 * `bind` reads its arguments when the callback is CREATED, the lambda when it is CALLED: a local
	 * written after the lambda exists would hand the callback a stale value.
	 */
	@:pin('control')
	@:killer('M-BIND-WRITES-IGNORED')
	public function testReassignedLocalNotFlagged(): Void {
		final cls: String = 'class C {\n\tfunction h(n:Int):Void {}\n\tfunction f(p:Int):Void {\n\t\tBODY\n\t}\n}';
		Assert.equals(0, violations(cls.replace('BODY', 'var v:Int = 1;\n\t\tfinal g = () -> h(v);\n\t\tv = 2;')).length);
		Assert.equals(0, violations(cls.replace('BODY', 'final g = () -> h(p);\n\t\tp++;')).length);
		Assert.equals(1, violations(cls.replace('BODY', 'final g = () -> h(p);')).length, 'the unwritten twin');
	}

	/** A field — bare, through `this`, or a static — may change between creation and call. */
	@:pin('control')
	@:killer('M-BIND-FIELD-ARG')
	public function testFieldArgumentNotFlagged(): Void {
		final cls: String =
			'class C {\n\tvar count:Int = 0;\n\tfunction h(n:Int):Void {}\n\tfunction f(p:Int):Void {\n\t\tfinal g = () -> h(ARG);\n\t}\n}';
		Assert.equals(0, violations(cls.replace('ARG', 'count')).length);
		Assert.equals(0, violations(cls.replace('ARG', 'this.count')).length);
		Assert.equals(0, violations(cls.replace('ARG', 'MouseEvent.CLICK')).length);
		Assert.equals(1, violations(cls.replace('ARG', 'p')).length, 'the parameter twin');
	}

	/**
	 * Null safety accepts a `Null<String>` capture passed on inside the lambda and rejects the same
	 * value as a `bind` argument (`Cannot assign nullable value here`); an optional parameter and a
	 * `null`-initialised local are nullable the same way.
	 */
	@:pin('control')
	@:killer('M-BIND-NULLABLE-ARG')
	public function testNullableArgumentNotFlagged(): Void {
		final cls: String = 'class C {\n\tfunction put(k:String, v:Null<String>):Void {}\n\tfunction f(?o:String, s:String):Void {\n'
			+ "\t\tfinal d:Null<String> = Sys.getEnv('X');\n\t\tfinal g = () -> put('K', ARG);\n\t}\n}";
		Assert.equals(0, violations(cls.replace('ARG', 'd')).length);
		Assert.equals(0, violations(cls.replace('ARG', 'o')).length);
		Assert.equals(1, violations(cls.replace('ARG', 's')).length, 'the non-nullable twin');
	}

	/** `bind` reads a field receiver at creation time, and throws there on a null one. */
	@:pin('control')
	@:killer('M-BIND-FIELD-RECEIVER')
	public function testFieldReceiverNotFlagged(): Void {
		final cls: String = 'class Tool {\n\tpublic static function m(n:Int):Void {}\n}\nclass View {\n\tpublic function m(n:Int):Void {}\n'
			+ '}\nclass C {\n\tvar view:View;\n\tfunction m(n:Int):Void {}\n\tfunction f():Void {\n'
			+ '\t\tfinal g = () -> CALLEE(1);\n\t}\n}';
		Assert.equals(0, violations(cls.replace('CALLEE', 'view.m')).length);
		Assert.equals(0, violations(cls.replace('CALLEE', 'this.view.m')).length);
		Assert.equals(0, violations(cls.replace('CALLEE', 'pkg.Tool.m')).length);
		Assert.equals(1, violations(cls.replace('CALLEE', 'this.m')).length);
		Assert.equals(1, violations(cls.replace('CALLEE', 'Tool.m')).length);
	}

	/**
	 * A `dynamic` method, or a `var` holding a function, may be REBOUND after the callback is created:
	 * the lambda calls the new function, `bind` keeps calling the old one.
	 */
	@:pin('control')
	@:killer('M-BIND-METHOD-UNPROVEN')
	@:killer('M-BIND-DYNAMIC-CALLEE')
	public function testRebindableCalleeNotFlagged(): Void {
		final cls: String = 'class Foo {\n\tpublic var cb:Int->Void;\n\tpublic dynamic function dm(x:Int):Void {}\n}\n'
			+ 'class C {\n\tdynamic function dyn(x:Int):Void {}\n\tfunction f(foo:Foo):Void {\n\t\tfinal g = () -> CALLEE(1);\n\t}\n}';
		Assert.equals(0, violations(cls.replace('CALLEE', 'this.dyn')).length);
		Assert.equals(0, violations(cls.replace('CALLEE', 'dyn')).length);
		Assert.equals(0, violations(cls.replace('CALLEE', 'foo.dm')).length);
		Assert.equals(0, violations(cls.replace('CALLEE', 'foo.cb')).length);
	}

	/**
	 * A function that has no single closure — a macro (`Macro functions must be called immediately`), a
	 * `@:generic` one, an `extern inline` one, one of several overloads — cannot be `bind`-ed at all.
	 */
	@:pin('control')
	@:killer('M-BIND-METHOD-UNPROVEN')
	@:killer('M-BIND-CLOSURELESS-CALLEE')
	public function testClosurelessCalleeNotFlagged(): Void {
		final cls: String = 'class U {\n\tpublic static macro function mac(e:Expr):Expr return e;\n'
			+ '\t@:generic public static function gen<T>(x:T):Void {}\n\tpublic static extern inline function ei(x:Int):Void {}\n'
			+ '\tpublic static overload extern inline function ov(x:Int):Void {}\n'
			+ '\t@:overload(function(x:String):Void {}) public static function om(x:Int):Void {}\n}\n'
			+ 'class C {\n\textern inline function mei(x:Int):Void {}\n\tfunction f():Void {\n\t\tfinal g = () -> CALLEE(1);\n\t}\n}';
		for (callee in ['U.mac', 'U.gen', 'U.ei', 'U.ov', 'U.om', 'mei', 'this.mei'])
			Assert.equals(0, violations(cls.replace('CALLEE', callee)).length, callee);
	}

	/** A bare name the enclosing type does not declare — inherited, a static import — is not proven a plain method. */
	@:pin('control')
	@:killer('M-BIND-UNDECLARED-BARE')
	public function testUndeclaredBareCalleeNotFlagged(): Void {
		Assert.equals(0, violations('class C extends B {\n\tfunction f():Void {\n\t\tfinal g = () -> inherited(1);\n\t}\n}').length);
	}

	/**
	 * A method of a library or standard-library type is one view among the target's overrides —
	 * `std/js/_std` makes `String.charCodeAt` `extern inline`, which has no closure — and a member of
	 * an `extern` type may be native. Only a project type's method is bound.
	 */
	@:pin('control')
	@:killer('M-BIND-LIBRARY-CALLEE')
	@:killer('M-BIND-EXTERN-TYPE')
	public function testLibraryOrExternCalleeNotFlagged(): Void {
		final lib: String =
			'class Lib {\n\tpublic static function m(n:Int):Void {}\n}\nextern class Ext {\n\tpublic static function e(n:Int):Void;\n}\n';
		final src: String = 'class C {\n\tfunction f(p:Int):Void {\n\t\tfinal g = () -> CALLEE(p);\n\t}\n}';
		function edits(callee: String, thirdParty: Array<String>): Int {
			final files: Array<{ file: String, source: String }> = [
				{ file: 'C.hx', source: src.replace('CALLEE', callee) },
				{ file: 'Lib.hx', source: lib }
			];
			final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
			final check: PreferBind = new PreferBind();
			final own: Array<Violation> = check.run(files, plugin).filter(v -> v.file == 'C.hx');
			return check.fix(files[0].source, own, plugin, SymbolIndex.build(files, plugin, thirdParty)).length;
		}
		Assert.equals(0, edits('Lib.m', ['Lib.hx']), 'a library method');
		Assert.equals(1, edits('Lib.m', []), 'the project twin');
		Assert.equals(0, edits('Ext.e', []), 'an extern type');
	}

	/**
	 * Through an implicit `this`, an abstract's instance method is bound to the value `this` holds at
	 * creation, and an abstract may reassign `this` before the call (`200` became `6`). A static one is
	 * unaffected.
	 */
	@:pin('control')
	@:killer('M-BIND-ABSTRACT-SELF')
	public function testAbstractInstanceMethodNotFlagged(): Void {
		final src: String = 'abstract W(Int) {\n\tpublic function plain(x:Int):Int return this * x;\n'
			+ '\tpublic static function st(x:Int):Int return x;\n\tpublic inline function run(v:Int):Void {\n'
			+ '\t\tfinal c:() -> Int = () -> CALLEE(v);\n\t\tthis = 100;\n\t}\n}';
		Assert.equals(0, violations(src.replace('CALLEE', 'plain')).length);
		Assert.equals(0, violations(src.replace('CALLEE', 'this.plain')).length);
		Assert.equals(1, violations(src.replace('CALLEE', 'st')).length, 'the static twin');
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-bind'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-bind'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { var g = () -> h(a, ').length);
	}

	public function testNestedLambdaFlaggedOnce(): Void {
		Assert.equals(
			1, violations('class C {\n\tfunction k(n:Int):Void {}\n\tfunction f():Void {\n\t\tvar g = () -> h(() -> k(1));\n\t}\n}').length
		);
	}

	public function testGenericCallNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar g = () -> fn<Int>(x);\n\t}\n}').length);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferBind().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
