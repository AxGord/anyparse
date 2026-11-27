package unit.check.common.unused;

import anyparse.check.Severity;
import anyparse.check.common.unused.NeverPassedParameter;

using StringTools;

/**
 * The `never-passed-parameter` check: a trailing optional / defaulted parameter that every call of a named
 * local function or a confined private method leaves out is flagged `Info`, report-only. A public method
 * (its parameter may be room for an outside caller), a method of a type with a supertype clause, a
 * `dynamic` function, a function with a rest parameter, a function captured as a value, a function with no
 * call, and a parameter some call passes are not flagged.
 */
class NeverPassedParameterTest extends Test {

	public function testDefaultedParameterOfPrivateMethodFlagged(): Void {
		final vs: Array<Violation> =
			violations('class C {\n\tfunction f(a:Int, b:Int = 1):Void {}\n\tpublic function g():Void {\n\t\tf(1);\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('never-passed-parameter', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('parameter \'b\' is never passed: every call of \'f\' leaves it out', vs[0].message);
	}

	public function testOptionalParameterOfPrivateMethodFlagged(): Void {
		Assert.equals(
			1, violations('class C {\n\tfunction f(a:Int, ?b:Int):Void {}\n\tpublic function g():Void {\n\t\tf(1);\n\t}\n}').length
		);
	}

	public function testEveryUnpassedTrailingParameterFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f(a:Int, b:Int = 1, ?c:Int):Void {}\n\tpublic function g():Void {\n\t\tf(1);\n\t}\n}'
		);
		Assert.equals(2, vs.length);
	}

	public function testLocalFunctionFlagged(): Void {
		final src: String = 'class C {\n\tpublic function g():Void {\n\t\tfunction h(a:Int, b:Int = 2):Void {}\n\t\th(1);\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('parameter \'b\' is never passed: every call of \'h\' leaves it out', vs[0].message);
	}

	public function testParameterPassedByACallNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f(a:Int, b:Int = 1):Void {}\n\tpublic function g():Void {\n\t\tf(1, 2);\n\t}\n}').length
		);
	}

	@:pin('control')
	@:killer('M-NEVER-PASSED-WIDEST-SITE')
	public function testOneCallPassingTheParameterKeepsItEvenWhenOthersOmitIt(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f(a:Int, b:Int = 1):Void {}\n\tpublic function g():Void {\n\t\tf(1);\n\t\tf(1, 2);\n\t}\n}')
				.length
		);
	}

	@:pin('control')
	@:killer('M-NEVER-PASSED-CONFINED')
	public function testPublicMethodNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tpublic function f(a:Int, b:Int = 1):Void {}\n\tpublic function g():Void {\n\t\tf(1);\n\t}\n}').length
		);
	}

	@:pin('control')
	@:killer('M-NEVER-PASSED-SITES')
	public function testMethodWithNoCallNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f(a:Int, b:Int = 1):Void {}\n}').length);
	}

	@:pin('control')
	@:killer('M-NEVER-PASSED-CONTRACT')
	public function testMethodOfTypeWithSupertypeClauseNotFlagged(): Void {
		final body: String = '\tfunction f(a:Int, b:Int = 1):Void {}\n\tpublic function g():Void {\n\t\tf(1);\n\t}\n}';
		Assert.equals(0, violations('class C implements I {\n$body').length);
		Assert.equals(0, violations('class C extends B {\n$body').length);
	}

	@:pin('control')
	@:killer('M-NEVER-PASSED-DYNAMIC')
	public function testDynamicFunctionNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tdynamic function f(a:Int, b:Int = 1):Void {}\n\tpublic function g():Void {\n\t\tf(1);\n\t}\n}').length
		);
	}

	@:pin('control')
	@:killer('M-NEVER-PASSED-REST')
	public function testFunctionWithRestParameterNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f(?a:Int, ...r:Int):Void {}\n\tpublic function g():Void {\n\t\tf();\n\t}\n}').length
		);
	}

	@:pin('guard')
	public function testFunctionPassedAsValueNotFlagged(): Void {
		final src: String =
			'class C {\n\tfunction f(a:Int, b:Int = 1):Void {}\n\tpublic function g():Void {\n\t\tf(1);\n\t\tadd(f);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	@:pin('control')
	@:killer('M-NEVER-PASSED-REFLECTION')
	public function testMethodReachedByNameStringNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(a:Int, b:Int = 1):Void {}\n\tpublic function g():Void {\n\t\tf(1);\n'
			+ '\t\tReflect.callMethod(this, Reflect.field(this, \'f\'), [1, 2]);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	@:pin('guard')
	public function testRequiredTrailingParameterNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f(?a:Int, b:Int):Void {}\n\tpublic function g():Void {\n\t\tf(1, 2);\n\t}\n}').length
		);
	}

	@:pin('guard')
	public function testFixYieldsNoEdits(): Void {
		final src: String = 'class C {\n\tfunction f(a:Int, b:Int = 1):Void {}\n\tpublic function g():Void {\n\t\tf(1);\n\t}\n}';
		final check: NeverPassedParameter = new NeverPassedParameter();
		Assert.equals(src, CheckFixture.fixedSource(check, src));
		Assert.notEquals('', check.noAutofixReason());
	}

	@:pin('control')
	@:killer('M-NEVER-PASSED-COMPILER-SUPPLIED')
	public function testCompilerSuppliedParameterNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(a:Int, ?pos:haxe.PosInfos):Void {}\n\tpublic function g():Void {\n\t\tf(1);\n\t}\n}';
		Assert.equals(0, violations(src).length);
		Assert.equals(0, violations(src.replace('haxe.PosInfos', 'PosInfos')).length);
	}

	@:pin('control')
	@:killer('M-NEVER-PASSED-TYPE-SKIP')
	public function testArgumentMaySkipAnOptionalSlotBelowTheUnpassedOnes(): Void {
		// `helper('x')` binds the String to `b`: Haxe skips `?a` by type, so no position says `b` is unpassed.
		final src: String =
			'class C {\n\tfunction helper(?a:Int, ?b:String):Void {}\n\tpublic function g():Void {\n\t\thelper(\'x\');\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	@:pin('guard')
	public function testRequiredLeadingParametersKeepThePositionalReading(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction named(a:Int, b:Int = 2, ?c:Int):Void {}\n\tpublic function g():Void {\n\t\tnamed(1);\n\t}\n}'
		);
		Assert.equals(2, vs.length);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new NeverPassedParameter(), src);
	}

}
