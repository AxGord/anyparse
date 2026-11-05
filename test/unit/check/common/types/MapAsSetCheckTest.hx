package unit.check.common.types;

import anyparse.check.Check.DefaultOff;
import anyparse.check.LintConfig;
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
		final src: String = 'final class C {\n\tprivate final _seen: Map<String, Bool> = [\'a\' => true];\n\n\tpublic function new() {}\n\n'
			+ '\tpublic function f(k: String): Bool {\n\t\tfor (key in _seen.keys()) trace(key);\n\t\treturn _seen.exists(k);\n\t}\n}';
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

	/** A set the keys are added to inside a loop (a BFS `visited`) is quadratic as an array: it stays a map. */
	@:pin('control')
	@:killer('M-MAS-GROWTH-BLIND')
	public function testSetGrownInLoopNotFlagged(): Void {
		final bfs: String = 'final seen: Map<Int, Bool> = [];\n\t\tfinal queue: Array<Int> = [k];\n\t\twhile (queue.length > 0) {\n'
			+ '\t\t\tfinal n: Int = queue.pop();\n\t\t\tif (seen.exists(n)) continue;\n\t\t\tseen[n] = true;\n'
			+ '\t\t\tqueue.push(n + 1);\n\t\t}\n\t\treturn false;';
		Assert.equals(0, violations(wrap(bfs)).length);
		final forLoop: String = 'final seen: Map<Int, Bool> = [];\n\t\tfor (i in 0...k) seen.set(i, true);\n\t\treturn seen.exists(k);';
		Assert.equals(0, violations(wrap(forLoop)).length);
	}

	/** A member that calls itself fills its field set once per level. */
	@:pin('control')
	@:killer('M-MAS-GROWTH-BLIND')
	public function testSetGrownInRecursiveMemberNotFlagged(): Void {
		final src: String = 'final class C {\n\tprivate final _seen: Map<Int, Bool> = [];\n\n\tpublic function new() {}\n\n'
			+ '\tpublic function walk(k: Int): Bool {\n\t\tif (_seen.exists(k)) return false;\n\t\t_seen[k] = true;\n'
			+ '\t\treturn walk(k + 1);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** A write inside a local function (or a lambda) runs as often as the function is called. */
	@:pin('control')
	@:killer('M-MAS-GROWTH-BLIND')
	public function testSetGrownInLocalFunctionNotFlagged(): Void {
		final local: String = 'final seen: Map<Int, Bool> = [];\n\t\tfunction visit(n: Int): Void {\n\t\t\tseen[n] = true;\n\t\t}\n'
			+ '\t\tvisit(k);\n\t\treturn seen.exists(k);';
		Assert.equals(0, violations(wrap(local)).length);
	}

	/** A set filled by literals once, and a set written once before a read-only loop, stay flagged. */
	public function testSetFilledOnceFlagged(): Void {
		final flags: String = 'final flags: Map<Int, Bool> = [1 => true, 2 => true];\n\t\treturn flags.exists(k);';
		Assert.equals(1, violations(wrap(flags)).length);
		final once: String = 'final seen: Map<Int, Bool> = [];\n\t\tseen[1] = true;\n'
			+ '\t\tfor (i in 0...k) if (seen.exists(i)) return true;\n\t\treturn false;';
		Assert.equals(1, violations(wrap(once)).length);
	}

	/** A loop that also declares the map rebuilds it each turn: nothing accumulates. */
	@:pin('control')
	@:killer('M-MAS-FRESH-PER-TURN')
	public function testSetDeclaredInsideLoopFlagged(): Void {
		final fresh: String = 'for (i in 0...k) {\n\t\t\tfinal m: Map<Int, Bool> = [];\n\t\t\tm[i] = true;\n'
			+ '\t\t\tif (m.exists(k)) return true;\n\t\t}\n\t\treturn false;';
		Assert.equals(1, violations(wrap(fresh)).length);
	}

	/** A memo filled by a member that is no recursion: the field outlives each call, so every call can add a key. */
	@:pin('control')
	@:killer('M-MAS-MEMBER-LIFETIME-BLIND')
	public function testSetGrownInPlainMemberNotFlagged(): Void {
		final src: String = 'final class C {\n\tprivate final _seen: Map<Int, Bool> = [];\n\n\tpublic function new() {}\n\n'
			+ '\tpublic function see(k: Int): Bool {\n\t\tif (_seen.exists(k)) return false;\n\t\t_seen[k] = true;\n'
			+ '\t\treturn true;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** A field set filled only in the constructor is filled once: the lifetime reading leaves it reported. */
	@:pin('control')
	@:killer('M-MAS-CTOR-LIFETIME')
	public function testSetFilledInConstructorFlagged(): Void {
		final src: String = 'final class C {\n\tprivate final _flags: Map<Int, Bool> = [];\n\n\tpublic function new() {\n\t\t_flags[1] '
			+ '= true;\n\t\t_flags[2] = true;\n\t}\n\n\tpublic function has(k: Int): Bool {\n\t\treturn _flags.exists(k);\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violationsIn(new MapAsSet(), [{ file: 'C.hx', source: src }], null, _ -> LintConfig.parse('{}'));
	}

	private static function wrap(body: String): String {
		return 'final class C {\n\tpublic function new() {}\n\n\tfunction g(set: Map<Int, Bool>): Void {}\n\n'
			+ '\tpublic function f(k: Int): Bool {\n\t\t$body\n\t}\n}';
	}

}
