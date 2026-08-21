package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferBind;
import anyparse.check.RedundantLambdaWrapper;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `redundant-lambda-wrapper` check: a lambda whose body is ONE call forwarding the lambda's
 * own parameters, in order and nowhere else, reduces to the bare callee. Every fixture declares
 * the callee it names — the rule resolves against the files it is handed and refuses what it
 * cannot see, so a fixture without the declaration would pass for the wrong reason.
 */
class RedundantLambdaWrapperCheckTest extends Test {

	private static final HELPER: String = 'class Helper {\n\tpublic static function isPos(v:Int):Bool return true;\n\t'
		+ 'public static function pair(a:Int, b:Int):Bool return true;\n}\n';

	public function testStaticForwarderFlagged(): Void {
		final vs: Array<Violation> = violations('${HELPER}class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> Helper.isPos(p));\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('redundant-lambda-wrapper', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testEnclosingMemberForwarderFlagged(): Void {
		Assert.equals(
			1,
			violations('class C {\n\tfunction ok(v:Int):Bool return true;\n\tfunction f():Void {\n\t\txs.foreach(p -> ok(p));\n\t}\n}')
				.length
		);
	}

	public function testTwoParamsInOrderFlagged(): Void {
		Assert.equals(
			1, violations('${HELPER}class C {\n\tfunction f():Void {\n\t\txs.foreach((a, b) -> Helper.pair(a, b));\n\t}\n}').length
		);
	}

	public function testZeroParamZeroArgFlagged(): Void {
		Assert.equals(
			1,
			violations('class C {\n\tstatic function go():Bool return true;\n\tfunction f():Void {\n\t\trun(() -> go());\n\t}\n}').length
		);
	}

	/** `prefer-bind` must stay silent on the one shape both rules could see — the registry-order claim in `Linter.builtins`. */
	public function testPreferBindSilentOnZeroArgCall(): Void {
		final src: String = 'class C {\n\tstatic function go():Bool return true;\n\tfunction f():Void {\n\t\trun(() -> go());\n\t}\n}';
		Assert.equals(0, new PreferBind().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()).length);
		Assert.equals(1, violations(src).length);
	}

	public function testExternInlineCalleeNotFlagged(): Void {
		// `extern inline` has no runtime function to close over — Haxe answers `Can't create closure on
		// an extern inline member method` — so the reduction turns a compiling call into a build
		// failure. Both spellings count: the bare modifier, and the cross-version region that
		// contributes it, which the member walk did not read at all.
		final head: String = 'class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> ok(p));\n\t}\n';
		Assert.equals(0, violations('${head}\textern public inline function ok(v:Int):Bool return true;\n}').length);
		final guard: String = '#if (haxe_ver >= 4.2) extern #else @:extern #end';
		Assert.equals(0, violations('$head\t$guard\n\tpublic inline function ok(v:Int):Bool return true;\n}').length);
		// Plain `inline` closes over fine — only the `extern` pairing removes the callable.
		Assert.equals(1, violations('${head}\tpublic inline function ok(v:Int):Bool return true;\n}').length);
	}

	public function testReorderedParamsNotFlagged(): Void {
		Assert.equals(
			0, violations('${HELPER}class C {\n\tfunction f():Void {\n\t\txs.foreach((a, b) -> Helper.pair(b, a));\n\t}\n}').length
		);
	}

	public function testDroppedParamNotFlagged(): Void {
		Assert.equals(
			0, violations('${HELPER}class C {\n\tfunction f():Void {\n\t\txs.foreach((a, b) -> Helper.isPos(a));\n\t}\n}').length
		);
	}

	public function testExtraArgumentNotFlagged(): Void {
		Assert.equals(0, violations('${HELPER}class C {\n\tfunction f():Void {\n\t\txs.foreach(a -> Helper.pair(a, 1));\n\t}\n}').length);
	}

	public function testNegatedBodyNotFlagged(): Void {
		Assert.equals(0, violations('${HELPER}class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> !Helper.isPos(p));\n\t}\n}').length);
	}

	public function testParenthesisedBodyNotFlagged(): Void {
		Assert.equals(0, violations('${HELPER}class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> (Helper.isPos(p)));\n\t}\n}').length);
	}

	public function testCastBodyNotFlagged(): Void {
		Assert.equals(
			0, violations('${HELPER}class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> cast Helper.isPos(p));\n\t}\n}').length
		);
	}

	public function testBlockBodyNotFlagged(): Void {
		Assert.equals(
			0, violations('${HELPER}class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> { Helper.isPos(p); });\n\t}\n}').length
		);
	}

	/**
	 * A parameter used as the callee receiver. The lower-initial receiver gate is what refuses this — the parameter-mention scan would too, but it never gets the chance (see the check type doc).
	 */
	public function testParamInsideCalleeNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> p.check(p));\n\t}\n}').length);
	}

	public function testOptionalCalleeParamNotFlagged(): Void {
		final src: String = 'class Helper {\n\tpublic static function opt(v:Int, ?k:Int):Bool return true;\n}\n'
			+ 'class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> Helper.opt(p));\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testDefaultedCalleeParamNotFlagged(): Void {
		final src: String = 'class Helper {\n\tpublic static function def(v:Int, k:Int = 1):Bool return true;\n}\n'
			+ 'class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> Helper.def(p));\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testRestCalleeParamNotFlagged(): Void {
		final src: String = 'class Helper {\n\tpublic static function rest(v:Int, ...more:Int):Bool return true;\n}\n'
			+ 'class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> Helper.rest(p));\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testArityMismatchNotFlagged(): Void {
		Assert.equals(0, violations('${HELPER}class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> Helper.pair(p));\n\t}\n}').length);
	}

	public function testAnnotatedCalleeNotFlagged(): Void {
		final src: String = 'class Helper {\n\t@:overload public static function ov(v:Int):Bool return true;\n}\n'
			+ 'class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> Helper.ov(p));\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testDynamicMemberNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tdynamic function ok(v:Int):Bool return true;\n\tfunction f():Void {\n\t\txs.foreach(p -> ok(p));\n\t}\n}'
			).length
		);
	}

	public function testInstanceMemberNotStaticNotFlagged(): Void {
		final src: String = 'class Helper {\n\tpublic function inst(v:Int):Bool return true;\n}\n'
			+ 'class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> Helper.inst(p));\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testInstanceReceiverNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tvar obj:Dynamic;\n\tfunction f():Void {\n\t\txs.foreach(p -> obj.m(p));\n\t}\n}').length);
	}

	public function testUnresolvedCalleeNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> Std.parseInt(p));\n\t}\n}').length);
	}

	public function testLocalFunctionFlagged(): Void {
		Assert.equals(
			1,
			violations('class C {\n\tfunction f():Void {\n\t\tfunction ok(v:Int):Bool return true;\n\t\txs.foreach(p -> ok(p));\n\t}\n}')
				.length
		);
	}

	public function testLocalInlineFunctionNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tinline function ok(v:Int):Bool return true;\n\t\txs.foreach(p -> ok(p));\n\t}\n}'
			).length
		);
	}

	public function testLocalValueBindingNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f():Void {\n\t\tvar ok = (v:Int) -> true;\n\t\txs.foreach(p -> ok(p));\n\t}\n}').length
		);
	}

	public function testShadowedTypeNameNotFlagged(): Void {
		Assert.equals(
			0, violations('${HELPER}class C {\n\tfunction f(Helper:Dynamic):Void {\n\t\txs.foreach(p -> Helper.isPos(p));\n\t}\n}').length
		);
	}

	public function testAmbiguousTypeNameNotFlagged(): Void {
		final second: String = 'class Helper {\n\tpublic static function isPos(v:Int):Bool return false;\n}\n';
		final caller: String = 'class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> Helper.isPos(p));\n\t}\n}';
		final check: RedundantLambdaWrapper = new RedundantLambdaWrapper();
		final vs: Array<Violation> = check.run([
			{ file: 'A.hx', source: HELPER },
			{ file: 'B.hx', source: second },
			{ file: 'C.hx', source: caller }
		], new HaxeQueryPlugin());
		Assert.equals(0, vs.length);
	}

	/** Two arms of a conditional region may disagree about the signature — the name is refused. */
	public function testConditionalDuplicateMemberNotFlagged(): Void {
		final src: String = 'class Helper {\n#if js\n\tpublic static function two(v:Int):Bool return true;\n'
			+ '#else\n\tpublic static function two(v:Int, ?k:Int):Bool return true;\n#end\n}\n'
			+ 'class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> Helper.two(p));\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testFixReplacesLambdaWithCallee(): Void {
		final src: String = '${HELPER}class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> Helper.isPos(p));\n\t}\n}';
		final check: RedundantLambdaWrapper = new RedundantLambdaWrapper();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		Assert.equals(1, edits.length);
		Assert.equals('Helper.isPos', edits[0].text);
		final applied: String = src.substring(0, edits[0].span.from) + edits[0].text + src.substring(edits[0].span.to, src.length);
		// One string spanning both halves: the reduced callee AND the statement around it, untouched.
		Assert.equals('\t\txs.foreach(Helper.isPos);', applied.split('\n')[6]);
	}

	public function testRegisteredAndDefaultOff(): Void {
		Assert.notNull(Linter.byId('redundant-lambda-wrapper'));
		Assert.isTrue(Linter.byId('redundant-lambda-wrapper') is DefaultOff);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { xs.foreach(p -> g(p').length);
	}

	/**
	 * Every refusal this class asserts must be decided by the property it NAMES, not by some earlier
	 * gate on the same path. Each row is a one-variable pair: the refused source, and its twin
	 * differing only in the gated property. A row whose twin does not fire proves nothing about its
	 * gate — the fixture never reached it.
	 */
	public function testEachRefusalIsOneVariableDecided(): Void {
		inline function host(signature: String): String return 'class H {\n\t$signature\n}\n';
		final one: String = 'class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> H.m(p));\n\t}\n}';
		final two: String = 'class C {\n\tfunction f():Void {\n\t\txs.foreach((a, b) -> H.m(a, b));\n\t}\n}';
		final plainTwo: String = host('public static function m(v:Int, k:Int):Bool return true;') + two;
		final plainOne: String = host('public static function m(v:Int):Bool return true;') + one;
		discriminate('optional callee parameter', host('public static function m(v:Int, ?k:Int):Bool return true;') + two, plainTwo);
		discriminate('defaulted callee parameter', host('public static function m(v:Int, k:Int = 1):Bool return true;') + two, plainTwo);
		discriminate('rest callee parameter', host('public static function m(v:Int, ...more:Int):Bool return true;') + two, plainTwo);
		discriminate('callee arity', host('public static function m(v:Int, k:Int):Bool return true;') + one, plainOne);
		discriminate('metadata on the callee', host('@:overload public static function m(v:Int):Bool return true;') + one, plainOne);
		discriminate('non-static member behind a type receiver', host('public function m(v:Int):Bool return true;') + one, plainOne);
		discriminate(
			'lower-initial receiver',
			host('public static function m(v:Int):Bool return true;')
			+ 'class C {\n\tvar h:H;\n\tfunction f():Void {\n\t\txs.foreach(p -> h.m(p));\n\t}\n}',
			plainOne
		);
		discriminate(
			'receiver name shadowed by a parameter',
			host('public static function m(v:Int):Bool return true;')
			+ 'class C {\n\tfunction f(H:Dynamic):Void {\n\t\txs.foreach(p -> H.m(p));\n\t}\n}',
			host('public static function m(v:Int):Bool return true;')
			+ 'class C {\n\tfunction f(other:Dynamic):Void {\n\t\txs.foreach(p -> H.m(p));\n\t}\n}'
		);
		discriminate(
			'wrapped call body',
			host('public static function m(v:Int):Bool return true;')
			+ 'class C {\n\tfunction f():Void {\n\t\txs.foreach(p -> !H.m(p));\n\t}\n}',
			plainOne
		);
		discriminate(
			'dynamic member',
			'class C {\n\tdynamic function m(v:Int):Bool return true;\n\tfunction f():Void {\n\t\txs.foreach(p -> m(p));\n\t}\n}',
			'class C {\n\tfunction m(v:Int):Bool return true;\n\tfunction f():Void {\n\t\txs.foreach(p -> m(p));\n\t}\n}'
		);
		discriminate(
			'local value binding', 'class C {\n\tfunction f():Void {\n\t\tvar m = (v:Int) -> true;\n\t\txs.foreach(p -> m(p));\n\t}\n}',
			'class C {\n\tfunction f():Void {\n\t\tfunction m(v:Int):Bool return true;\n\t\txs.foreach(p -> m(p));\n\t}\n}'
		);
		discriminate(
			'inline local function',
			'class C {\n\tfunction f():Void {\n\t\tinline function m(v:Int):Bool return true;\n\t\txs.foreach(p -> m(p));\n\t}\n}',
			'class C {\n\tfunction f():Void {\n\t\tfunction m(v:Int):Bool return true;\n\t\txs.foreach(p -> m(p));\n\t}\n}'
		);
		discriminate(
			'member declared in two conditional arms',
			'class H {\n#if js\n\tpublic static function m(v:Int):Bool return true;\n#else\n'
			+ '\tpublic static function m(v:Int):Bool return false;\n#end\n}\n$one',
			'class H {\n#if js\n\tpublic static function m(v:Int):Bool return true;\n#end\n}\n$one'
		);
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantLambdaWrapper().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** Assert that `gated` is refused and its one-variable `twin` fires — the pair, not either half, is the evidence. */
	private function discriminate(label: String, gated: String, twin: String): Void {
		Assert.equals(0, violations(gated).length, '$label: the gated source must be refused');
		Assert.equals(1, violations(twin).length, '$label: the one-variable twin must fire, else the fixture never reached this gate');
	}

}
