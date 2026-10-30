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
		Assert.equals(0, CheckFixture.violations(new Naming(), wrap('try {\n\t\t\tg();\n\t\t} catch (e: haxe.Exception) {}')).length);
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
