package unit.check.common.types;

import anyparse.check.LintConfig;
import anyparse.check.common.types.MapAsSet;

/**
 * The `map-as-set` fix under a project that names its set type: a set that GROWS is respelled to that type, a project without
 * the key is told nothing about it, and every shape the set type has no equal for stays as written with a reason.
 */
class MapAsSetFixTest extends Test {

	private static final CONFIG: String = '{"rules": {"map-as-set": {"enabled": true, "set": "anyparse.ds.Set"}}}';

	public function testGrowingLocalRespelled(): Void {
		final bfs: String = 'final seen: Map<String, Bool> = [];\n\t\tfor (i in 0...3) {\n\t\t\tif (seen.exists(k)) continue;\n'
			+ '\t\t\tseen[k] = true;\n\t\t\tseen.set(k + "a", true);\n\t\t\tseen.remove(k);\n\t\t}\n\t\treturn seen.exists(k);';
		final fixed: String = CheckFixture.fixedUnder(new MapAsSet(), wrap(bfs), CONFIG);
		Assert.stringContains('final seen: Set<String> = new Set<String>();', fixed);
		Assert.stringContains('if (seen.has(k)) continue;', fixed);
		Assert.stringContains('seen.add(k);', fixed);
		Assert.stringContains('seen.add(k + "a");', fixed);
		Assert.stringContains('seen.remove(k);', fixed);
		Assert.stringContains('return seen.has(k);', fixed);
		Assert.stringContains('import anyparse.ds.Set;', fixed);
	}

	/** Without the `set` key a growing set gets no advice at all. */
	@:pin('control')
	@:killer('M-MAS-SET-UNCONFIGURED')
	public function testNoKeyNoAdviceOnGrowingSet(): Void {
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: wrap(growing()) }];
		Assert.equals(0, CheckFixture.violationsIn(new MapAsSet(), files, null, _ -> LintConfig.parse('{}')).length);
	}

	public function testGrowingSetReportedUnderKey(): Void {
		final run: FixRun = CheckFixture.fixRunUnder(new MapAsSet(), wrap(growing()), CONFIG);
		Assert.equals(1, run.violations.length);
		Assert.stringContains('Set<String>', run.violations[0].message);
	}

	/** A set filled once stays array advice: the fix never touches it. */
	public function testSetFilledOnceNotRespelled(): Void {
		final once: String = 'final seen: Map<String, Bool> = [];\n\t\tseen["a"] = true;\n\t\treturn seen.exists(k);';
		final src: String = wrap(once);
		Assert.equals(src, CheckFixture.fixedUnder(new MapAsSet(), src, CONFIG));
	}

	/** `Map` compares an enum value structurally, a native set by identity: such a key stays a map. */
	@:pin('control')
	@:killer('M-MAS-SET-KEY')
	public function testEnumKeyStays(): Void {
		final src: String = wrap(growing().split('String').join('E'));
		Assert.equals(src, CheckFixture.fixedUnder(new MapAsSet(), src, CONFIG));
		final run: FixRun = CheckFixture.fixRunUnder(new MapAsSet(), src, CONFIG);
		Assert.equals(0, run.violations.length);
	}

	/** An index read answers Null<Bool> and `keys` / `get` / `copy` have no equal: the set stays as written. */
	@:pin('control')
	@:killer('M-MAS-SET-USES')
	public function testUnanswerableUseKeepsTheMap(): Void {
		for (use in ['seen[k]', 'seen.get(k)', 'seen.keys().hasNext()', 'seen.copy().exists(k)']) {
			final src: String = wrap('final seen: Map<String, Bool> = [];\n\t\tfor (i in 0...3) seen[k + i] = true;\n\t\treturn $use;');
			Assert.equals(src, CheckFixture.fixedUnder(new MapAsSet(), src, CONFIG), use);
		}
	}

	/** A second declaration of the name in the file shares the census, so neither is respelled. */
	@:pin('control')
	@:killer('M-MAS-SET-SHARED-NAME')
	public function testSharedNameStays(): Void {
		final src: String = 'final class C {\n\tpublic function new() {}\n\n\tpublic function f(k: String): Bool {\n'
			+ '\t\tfinal seen: Map<String, Bool> = [];\n\t\tfor (i in 0...3) seen[k] = true;\n\t\treturn seen.exists(k);\n\t}\n\n'
			+ '\tpublic function g(k: String): Bool {\n\t\tfinal seen: Map<String, Bool> = [];\n'
			+ '\t\tfor (i in 0...3) seen[k] = true;\n\t\treturn seen.exists(k);\n\t}\n}';
		Assert.equals(src, CheckFixture.fixedUnder(new MapAsSet(), src, CONFIG));
	}

	/** A field set grown by a plain member is respelled with its constructor. */
	public function testGrowingFieldRespelled(): Void {
		final src: String = 'final class C {\n\tprivate final _seen: Map<Int, Bool> = new Map<Int, Bool>();\n\n'
			+ '\tpublic function new() {}\n\n\tpublic function see(k: Int): Bool {\n\t\tif (_seen.exists(k)) return false;\n'
			+ '\t\tthis._seen.set(k, true);\n\t\treturn true;\n\t}\n}';
		final fixed: String = CheckFixture.fixedUnder(new MapAsSet(), src, CONFIG);
		Assert.stringContains('private final _seen: Set<Int> = new Set<Int>();', fixed);
		Assert.stringContains('if (_seen.has(k)) return false;', fixed);
		Assert.stringContains('this._seen.add(k);', fixed);
	}

	/** `other.seen` is another object's member that shares the name: respelling it breaks the build, so the set stays. */
	@:pin('control')
	@:killer('M-MAS-SET-OTHER-RECEIVER')
	public function testSameNameOnAnotherReceiverStays(): Void {
		final src: String = 'final class C {\n\tprivate final seen: Map<String, Bool> = new Map<String, Bool>();\n\n'
			+ '\tpublic function new() {}\n\n\tpublic function f(k: String, other: Other): Bool {\n'
			+ '\t\tthis.seen.set(k, true);\n\t\treturn seen.exists(k) || other.seen.exists(k);\n\t}\n}';
		Assert.equals(src, CheckFixture.fixedUnder(new MapAsSet(), src, CONFIG));
		Assert.equals(0, CheckFixture.fixRunUnder(new MapAsSet(), src, CONFIG).violations.length);
	}

	@:pin('control')
	@:killer('M-MAS-SET-LOCAL-THIS')
	public function testThisAccessOfInheritedMemberBesideLocalStays(): Void {
		final src: String = 'final class C extends Base {\n\tpublic function new() {}\n\n\tpublic function f(k: String): Bool {\n'
			+ '\t\tfinal seen: Map<String, Bool> = [];\n\t\tfor (i in 0...3) seen[k] = true;\n'
			+ '\t\treturn seen.exists(k) && this.seen.exists(k);\n\t}\n}';
		Assert.equals(src, CheckFixture.fixedUnder(new MapAsSet(), src, CONFIG));
		Assert.equals(0, CheckFixture.fixRunUnder(new MapAsSet(), src, CONFIG).violations.length);
	}

	private static function growing(): String {
		return 'final seen: Map<String, Bool> = [];\n\t\tfor (i in 0...3) seen[k] = true;\n\t\treturn seen.exists(k);';
	}

	private static function wrap(body: String): String {
		return 'final class C {\n\tpublic function new() {}\n\n\tpublic function f(k: String): Bool {\n\t\t$body\n\t}\n}';
	}

}
