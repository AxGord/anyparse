package unit.check.common.types;

import anyparse.check.LintConfig;
import anyparse.check.common.types.MapAsSet;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;

/**
 * The `map-as-set` fix of a non-public MEMBER set: a subtype in another file reads the member unqualified, and that read
 * cannot be respelled from the declaring file, so the member stays a map wherever such a file mentions it.
 */
class MapAsSetCrossFileTest extends Test {

	private static final SET: String = '{"rules": {"map-as-set": {"enabled": true, "set": "anyparse.ds.Set"}}}';
	private static final BITS: String = '{"rules": {"map-as-set": {"enabled": true, "bits": "anyparse.ds.Bits"}}}';
	private static final COLOR: String = 'package dom;\n\nenum Color {\n\tRed;\n\tGreen;\n}\n';

	/** A subtype of another file reads the member: the declaring file's rewrite would leave that read on a type with no `exists`. */
	@:pin('control')
	@:killer('M-MAS-SET-CROSS-FILE-READER')
	public function testSubtypeInAnotherFileKeepsTheMemberASet(): Void {
		final run: FixRun = holderRun(SET, 'marks.exists(c)');
		Assert.equals(0, run.violations.length);
		Assert.equals(0, run.edits.length);
	}

	/** The same member, with a subtype that never mentions it, is respelled as before. */
	public function testSubtypeNotMentioningTheMemberIsRespelled(): Void {
		final run: FixRun = holderRun(SET, 'true');
		Assert.equals(1, run.violations.length);
		final fixed: String = CanonicalEdit.applyEdits(holder('String'), run.edits);
		Assert.stringContains('private final marks: Set<String> = new Set<String>();', fixed);
		Assert.stringContains('marks.add(c);', fixed);
	}

	/** A member read by a subtype of another file stays a map on the bit-set path too. */
	@:pin('control')
	@:killer('M-MAS-SET-CROSS-FILE-READER')
	public function testSubtypeInAnotherFileKeepsTheMemberABitSetCandidate(): Void {
		final run: FixRun = bitsRun('marks.exists(c)');
		Assert.equals(0, run.edits.length);
	}

	public function testSubtypeNotMentioningTheMemberIsRespelledToBits(): Void {
		final run: FixRun = bitsRun('true');
		final fixed: String = CanonicalEdit.applyEdits(bitsHolder(), run.edits);
		Assert.stringContains('private var marks: Bits<Color> = new Bits<Color>();', fixed);
		Assert.stringContains('marks.add(c);', fixed);
	}

	/** A subtype declared in the member's own file is respelled by the same edits, so it does not hold the member back. */
	@:pin('control')
	@:killer('M-MWS-SAME-FILE-SUBTYPE')
	public function testSubtypeInTheDeclaringFileIsRespelledWithTheMember(): Void {
		final source: String = '${holder('String')}\n\nclass Sub extends Holder {\n\tpublic function also(c: String): Bool {\n'
			+ '\t\treturn marks.exists(c);\n\t}\n}';
		final config: LintConfig = LintConfig.parse(SET);
		final run: FixRun = CheckFixture.fixRun(new MapAsSet(), [{ file: 'use/Holder.hx', source: source }], null, null, _ -> config);
		Assert.equals(1, run.violations.length);
		final fixed: String = CanonicalEdit.applyEdits(source, run.edits);
		Assert.stringContains('private final marks: Set<String> = new Set<String>();', fixed);
		Assert.stringContains('return marks.has(c);', fixed);
	}

	/** Without an index no other file can be ruled out: a member is declined with a reason, a local is respelled. */
	public function testMemberWithoutAnIndexIsDeclinedAndLocalIsNot(): Void {
		final config: LintConfig = LintConfig.parse(SET);
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final local: String = 'package use;\n\nclass Holder {\n\tpublic function new() {}\n\n\tpublic function f(k: String): Bool {\n'
			+ '\t\tfinal seen: Map<String, Bool> = [];\n\t\tfor (i in 0...3) seen[k + i] = true;\n\t\treturn seen.exists(k);\n\t}\n}';
		final member: String = holder('String');
		final check: MapAsSet = new MapAsSet();
		final found: Array<Violation> = CheckFixture.violationsIn(check, [{ file: 'use/Holder.hx', source: member }], plugin, _ -> config);
		Assert.equals(1, found.length);
		Assert.equals(0, check.fix(member, found, plugin).length);
		Assert.notNull(found[0].declineReason);
		final seen: Array<Violation> = CheckFixture.violationsIn(check, [{ file: 'use/Holder.hx', source: local }], plugin, _ -> config);
		Assert.isTrue(check.fix(local, seen, plugin).length > 0);
	}

	private static function holder(key: String): String {
		return 'package use;\n\nclass Holder {\n\tprivate final marks: Map<$key, Bool> = new Map<$key, Bool>();\n\n'
			+ '\tpublic function new() {}\n\n\tpublic function mark(c: $key): Void {\n\t\tmarks[c] = true;\n\t}\n\n'
			+ '\tpublic function marked(c: $key): Bool {\n\t\treturn this.marks.exists(c);\n\t}\n}';
	}

	private static function bitsHolder(): String {
		return 'package use;\n\nimport dom.Color;\n\nclass Holder {\n\tprivate var marks: Map<Color, Bool> = new Map<Color, Bool>();\n\n'
			+ '\tpublic function new() {}\n\n\tpublic function mark(c: Color): Void {\n\t\tmarks[c] = true;\n\t}\n\n'
			+ '\tpublic function marked(c: Color): Bool {\n\t\treturn this.marks.exists(c);\n\t}\n}';
	}

	private static function sub(key: String, read: String): String {
		return 'package use;\n\n${key == 'Color' ? 'import dom.Color;\n\n' : ''}class Sub extends Holder {\n'
			+ '\tpublic function also(c: $key): Bool {\n\t\treturn $read;\n\t}\n}';
	}

	private static function holderRun(json: String, read: String): FixRun {
		return run(json, holder('String'), sub('String', read), []);
	}

	private static function bitsRun(read: String): FixRun {
		return run(BITS, bitsHolder(), sub('Color', read), [{ file: 'dom/Color.hx', source: COLOR }]);
	}

	private static function run(
		json: String, holderSource: String, subSource: String, more: Array<{ file: String, source: String }>
	): FixRun {
		final config: LintConfig = LintConfig.parse(json);
		final files: Array<{ file: String, source: String }> = [
			{ file: 'use/Holder.hx', source: holderSource },
			{ file: 'use/Sub.hx', source: subSource }
		].concat(more);
		return CheckFixture.fixRun(new MapAsSet(), files, 'use/Holder.hx', null, _ -> config);
	}

}
