package unit.check.common.types;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Severity;
import anyparse.check.common.types.MapAsSet;

/**
 * The `map-as-set` check: a map declared with boolean values whose every stored value is `true` and every use asks
 * membership is flagged `Info`, report-only; a stored `false`, a value iterated, a map handed away and an unannotated map
 * are left alone. Default-off.
 */
class MapAsSetCheckTest extends Test {

	public function testLocalSetFlagged(): Void {
		final vs: Array<Violation> = violations(
			wrap('final m: Map<Int, Bool> = [];\n\t\tm[1] = true;\n\t\tm.set(2, true);\n\t\treturn m.exists(k) || m[k];')
		);
		Assert.equals(1, vs.length);
		Assert.equals('map-as-set', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(
			'\'m\' is a map whose every value is true, used only as a set of keys — Array<Int> with contains() says the same',
			vs[0].message
		);
	}

	public function testPrivateFieldSetFlagged(): Void {
		final src: String = 'final class C {\n\tprivate final _seen: Map<String, Bool> = [];\n\n\tpublic function new() {}\n\n'
			+ '\tpublic function f(k: String): Bool {\n\t\t_seen[k] = true;\n\t\tfor (key in _seen.keys()) trace(key);\n'
			+ '\t\treturn _seen.exists(k);\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	/** A value other than `true` is a value the map holds, not membership. */
	@:pin('control')
	@:killer('M-MAS-ANY-VALUE')
	public function testFalseValueNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final m: Map<Int, Bool> = [];\n\t\tm[1] = false;\n\t\treturn m.exists(k);')).length);
		Assert.equals(0, violations(wrap('final m: Map<Int, Bool> = [1 => false];\n\t\treturn m.exists(k);')).length);
	}

	public function testValuesReadNotFlagged(): Void {
		Assert.equals(
			0, violations(wrap('final m: Map<Int, Bool> = [];\n\t\tm[1] = true;\n\t\tfor (v in m) trace(v);\n\t\treturn false;')).length
		);
		Assert.equals(
			0, violations(wrap('final m: Map<Int, Bool> = [];\n\t\tm[1] = true;\n\t\ttrace(m.toString());\n\t\treturn false;')).length
		);
	}

	public function testEscapingMapNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final m: Map<Int, Bool> = [];\n\t\tm[1] = true;\n\t\tg(m);\n\t\treturn false;')).length);
	}

	public function testOtherTypesNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final m: Map<Int, String> = [];\n\t\tm[1] = "a";\n\t\treturn m.exists(k);')).length);
		Assert.equals(0, violations(wrap('final m = new Map<Int, Bool>();\n\t\tm[1] = true;\n\t\treturn m.exists(k);')).length);
	}

	public function testDefaultOff(): Void {
		Assert.isTrue(Std.isOfType(new MapAsSet(), DefaultOff));
		Assert.notNull(Linter.byId('map-as-set'));
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new MapAsSet(), src);
	}

	private static function wrap(body: String): String {
		return 'final class C {\n\tpublic function new() {}\n\n\tfunction g(set: Map<Int, Bool>): Void {}\n\n'
			+ '\tpublic function f(k: Int): Bool {\n\t\t$body\n\t}\n}';
	}

}
