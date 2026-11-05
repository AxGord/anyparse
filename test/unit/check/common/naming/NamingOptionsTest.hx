package unit.check.common.naming;

import anyparse.check.LintConfig;

/**
 * The `naming` options `NamingOptions` lays over a grammar's policy: `catchVarName` names every catch variable (an
 * `_`-prefixed discard keeps its marker) and `handlerSuffix` respells a listener method `onX` as `xHandler`, an override
 * excepted. Both are reported by `naming` and fixed by its rename; with neither option set nothing changes.
 */
class NamingOptionsTest extends Test {

	private static inline final OPTIONS: String = '{"rules": {"naming": {"catchVarName": "exception", "handlerSuffix": "Handler"}}}';

	public function testCatchVariableRenamed(): Void {
		final src: String = wrap('try {\n\t\t\tg();\n\t\t} catch (e: haxe.Exception) {\n\t\t\ttrace(e);\n\t\t}');
		final vs: Array<Violation> = violationsUnder(src);
		Assert.equals(1, vs.length);
		Assert.equals('catch variable named exception: \'e\'', vs[0].message);
		Assert.equals(
			wrap('try {\n\t\t\tg();\n\t\t} catch (exception: haxe.Exception) {\n\t\t\ttrace(exception);\n\t\t}'),
			CheckFixture.fixedUnder(new Naming(), src, OPTIONS)
		);
	}

	public function testSiblingCatchVariablesRenamedInOneRun(): Void {
		final src: String = wrap(
			'try {\n\t\t\tg();\n\t\t} catch (e: haxe.Exception) {\n\t\t\ttrace(e);\n\t\t} catch (e: String) {\n\t\t\ttrace(e);\n\t\t}'
		);
		Assert.equals(2, violationsUnder(src).length);
		Assert.equals(
			wrap(
				'try {\n\t\t\tg();\n\t\t} catch (exception: haxe.Exception) {\n\t\t\ttrace(exception);\n'
				+ '\t\t} catch (exception: String) {\n\t\t\ttrace(exception);\n\t\t}'
			),
			CheckFixture.fixedUnder(new Naming(), src, OPTIONS)
		);
	}

	public function testNestedCatchVariableDefersToItsEnclosingClause(): Void {
		final src: String = wrap(
			'try {\n\t\t\tg();\n\t\t} catch (e: haxe.Exception) {\n\t\t\ttrace(e);\n\t\t\ttry {\n\t\t\t\tg();\n'
			+ '\t\t\t} catch (e: String) {\n\t\t\t\ttrace(e);\n\t\t\t}\n\t\t}'
		);
		Assert.equals(2, violationsUnder(src).length);
		Assert.equals(
			wrap(
				'try {\n\t\t\tg();\n\t\t} catch (exception: haxe.Exception) {\n\t\t\ttrace(exception);\n\t\t\ttry {\n\t\t\t\tg();\n'
				+ '\t\t\t} catch (e: String) {\n\t\t\t\ttrace(e);\n\t\t\t}\n\t\t}'
			),
			CheckFixture.fixedUnder(new Naming(), src, OPTIONS)
		);
	}

	public function testDiscardCatchVariableKept(): Void {
		Assert.equals(0, violationsUnder(wrap('try {\n\t\t\tg();\n\t\t} catch (_e: haxe.Exception) {}')).length);
	}

	public function testListenerRenamed(): Void {
		final src: String = 'final class C {\n\tpublic function new() {}\n\n\tfunction onClick(): Void {}\n\n\tfunction g(): Void {\n'
			+ '\t\tonClick();\n\t}\n}';
		final vs: Array<Violation> = violationsUnder(src);
		Assert.equals(1, vs.length);
		Assert.equals('listener method named <event>Handler, not on<Event>: \'onClick\'', vs[0].message);
		Assert.equals(
			'final class C {\n\tpublic function new() {}\n\n\tfunction clickHandler(): Void {}\n\n\tfunction g(): Void {\n'
			+ '\t\tclickHandler();\n\t}\n}',
			CheckFixture.fixedUnder(new Naming(), src, OPTIONS)
		);
	}

	/** An override is named by its supertype; a name merely starting `on` is no listener. */
	@:pin('control')
	@:killer('M-NAMING-HANDLER-OVERRIDE')
	public function testOverrideAndPlainNamesKept(): Void {
		final src: String = 'class B {\n\tpublic function new() {}\n\n\tfunction onAdd(): Void {}\n}\n\n'
			+ 'final class C extends B {\n\toverride function onAdd(): Void {}\n\n\tfunction once(): Void {}\n}';
		Assert.equals(1, violationsUnder(src).length);
	}

	public function testNoOptionsNoFindings(): Void {
		final check: Naming = new Naming();
		check.setConfigResolver(_ -> LintConfig.parse('{}'));
		Assert.equals(0, CheckFixture.violations(check, wrap('try {\n\t\t\tg();\n\t\t} catch (e: haxe.Exception) {}')).length);
	}

	/** A method returning a value that is only called directly is a query, whatever its first word. */
	public function testValueReturningCalledDirectlyKept(): Void {
		final src: String = 'final class C {\n\tpublic function new() {}\n\n\tfunction onDisk(): Bool {\n\t\treturn true;\n\t}\n\n'
			+ '\tfunction g(): Bool {\n\t\treturn onDisk() && this.onDisk();\n\t}\n}';
		Assert.equals(0, violationsUnder(src).length);
	}

	/** A value-returning method handed on as a function value is a callback, so it is a listener. */
	public function testValueReturningPassedAsValueFlagged(): Void {
		final src: String = 'final class C {\n\tpublic function new() {}\n\n\tfunction onCycle(id: String): Bool {\n\t\treturn true;\n'
			+ '\t}\n\n\tfunction g(): Bool {\n\t\treturn walk(onCycle);\n\t}\n\n\tfunction walk(f: String -> Bool): Bool {\n'
			+ '\t\treturn f(\'a\');\n\t}\n}';
		final vs: Array<Violation> = violationsUnder(src);
		Assert.equals(1, vs.length);
		Assert.equals('listener method named <event>Handler, not on<Event>: \'onCycle\'', vs[0].message);
	}

	/** A method with no declared result whose body returns nothing is a listener; one whose body returns a value is not. */
	public function testUnannotatedResultByBody(): Void {
		final src: String = 'final class C {\n\tpublic function new() {}\n\n\tfunction onTick() {\n\t\ttrace(1);\n\t}\n\n'
			+ '\tfunction onFind() {\n\t\treturn 1;\n\t}\n\n\tfunction g() {\n\t\tonTick();\n\t\ttrace(onFind());\n\t}\n}';
		final vs: Array<Violation> = violationsUnder(src);
		Assert.equals(1, vs.length);
		Assert.equals('listener method named <event>Handler, not on<Event>: \'onTick\'', vs[0].message);
	}

	/** A parameter that shares the method's name is a different binding, so reading it is no function-value read. */
	public function testSameNamedParameterReadKept(): Void {
		final src: String = 'final class C {\n\tpublic function new() {}\n\n\tfunction onParam(): Bool {\n\t\treturn true;\n\t}\n\n'
			+ '\tfunction g(onParam: Bool): Bool {\n\t\treturn onParam;\n\t}\n\n\tfunction h(): Bool {\n\t\treturn onParam();\n\t}\n}';
		Assert.equals(0, violationsUnder(src).length);
	}

	/** A field of another type that shares the method's name is not a read of it. */
	public function testOtherTypesFieldKept(): Void {
		final src: String = 'final class Other {\n\tpublic var onShared: Bool = false;\n\n\tpublic function new() {}\n}\n\n'
			+ 'final class C {\n\tpublic function new() {}\n\n\tfunction onShared(): Bool {\n\t\treturn true;\n\t}\n\n'
			+ '\tfunction g(o: Other): Bool {\n\t\treturn o.onShared || onShared();\n\t}\n}';
		Assert.equals(0, violationsUnder(src).length);
	}

	/** A name inside `macro` is a template, not a read: the projection treats the subtree as opaque. */
	public function testMacroReifiedNameKept(): Void {
		final src: String = 'final class C {\n\tpublic function new() {}\n\n\tfunction onReified(): Bool {\n\t\treturn true;\n\t}\n\n'
			+ '\tstatic macro function m() {\n\t\treturn macro onReified;\n\t}\n}';
		Assert.equals(0, violationsUnder(src).length);
	}

	/** A value returned by a nested function is that function's, so the method holding it returns nothing itself. */
	public function testNestedFunctionReturnIsNotTheMethods(): Void {
		final src: String = 'final class C {\n\tpublic function new() {}\n\n\tfunction onLambda() {\n\t\tfinal f = function(): Int {\n'
			+ '\t\t\treturn 1;\n\t\t};\n\t\ttrace(f());\n\t}\n}';
		final vs: Array<Violation> = violationsUnder(src);
		Assert.equals(1, vs.length);
		Assert.equals('listener method named <event>Handler, not on<Event>: \'onLambda\'', vs[0].message);
	}

	/** A value-returning method read as `this.name` is handed on as a function value. */
	public function testReadOffThisFlagged(): Void {
		final src: String = 'final class C {\n\tpublic function new() {}\n\n\tfunction onCycle(): Bool {\n\t\treturn true;\n\t}\n\n'
			+ '\tfunction g(): Void {\n\t\twalk(this.onCycle);\n\t}\n\n\tfunction walk(f: () -> Bool): Void {}\n}';
		Assert.equals(1, violationsUnder(src).length);
	}

	/** A static value-returning method read off its own type's name is handed on as a function value. */
	public function testReadOffTypeNameFlagged(): Void {
		final src: String = 'final class C {\n\tpublic function new() {}\n\n\tstatic function onStatic(): Bool {\n\t\treturn true;\n\t}\n\n'
			+ '\tstatic function g(): Void {\n\t\twalk(C.onStatic);\n\t}\n\n\tstatic function walk(f: () -> Bool): Void {}\n}';
		Assert.equals(1, violationsUnder(src).length);
	}

	/** An interface member has no body, so it returns nothing the rule can see and is a listener. */
	public function testInterfaceMemberWithoutBodyFlagged(): Void {
		Assert.equals(1, violationsUnder('interface I {\n\tfunction onTick();\n}').length);
	}

	private function violationsUnder(src: String): Array<Violation> {
		final check: Naming = new Naming();
		check.setConfigResolver(_ -> LintConfig.parse(OPTIONS));
		return CheckFixture.violations(check, src);
	}

	private static function wrap(body: String): String {
		return 'final class C {\n\tpublic function new() {}\n\n\tfunction g(): Void {}\n\n\tfunction f(): Void {\n\t\t$body\n\t}\n}';
	}

}
