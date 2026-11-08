package unit.check.oracle;

import anyparse.check.Check;
import anyparse.check.LintConfig;
import anyparse.check.common.types.MapAsSet;
import anyparse.check.haxe.expressions.PreferCompareFunction;
import anyparse.check.haxe.expressions.PreferSplitPart;
import anyparse.check.oracle.OracleCoverage;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.Cli.RuleEdits;
import anyparse.query.ImportReach;
import anyparse.query.OracleProviders;
import anyparse.query.cli.command.LintFixDriver;

/**
 * `ImportReach` - a fix that adds an `import` is offered only where every build that compiles the file resolves that module.
 *
 * The fixture is the incident's shape: a leaf whose classpath is the file's own folder alone, a text-tools module that
 * lives under another root, and a second leaf that adds that root. `prefer-split-part` is the rule that adds the import;
 * the leaf's compiler is real, since the premise is a statement about what its `Classpath:` and `Parsed` lines say.
 */
@:nullSafety(Strict)
final class ImportReachTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"prefer-split-part":{"enabled":true,"textTools":"lib.Text"}}}';
	private static inline final COMPARE_CONFIG: String =
		'{"rules":{"prefer-compare-function":{"enabled":true,"compare":{"String":"lib.Cmp.strings"}}}}';
	private static final TEXT: String = 'package lib;\nclass Text {\n'
		+ '\tpublic static function allBefore(text:String, delimiter:String):String return text;\n'
		+ '\tpublic static function allAfterLast(text:String, delimiter:String):String return text;\n}';
	private static final MAIN: String =
		'class C {\n\n\tstatic function main() {}\n\n\tfunction f(s:String):Void {\n\t\tvar a = s.split(",")[0];\n\t}\n\n}\n';
	private static final SET_CONFIG: String = '{"rules":{"map-as-set":{"enabled":true,"set":"lib.Sets","bits":"lib.Flags"}}}';
	private static final GROWN: String = 'class C {\n\n\tstatic function main() {}\n\n\tfunction f(k:String):Bool {\n'
		+ '\t\tfinal seen:Map<String, Bool> = [];\n\t\tfor (i in 0...3) seen[k] = true;\n\t\treturn seen.exists(k);\n\t}\n\n}\n';
	private static final ONCE: String = 'class C {\n\n\tstatic function main() {}\n\n\tfunction f(k:String):Bool {\n'
		+ '\t\tfinal seen:Map<String, Bool> = [];\n\t\tseen["a"] = true;\n\t\treturn seen.exists(k);\n\t}\n\n}\n';
	private static final FLAGGED: String = 'enum Color {\n\tRed;\n\tGreen;\n}\n\nclass C {\n\n\tstatic function main() {}\n\n'
		+ '\tfunction f(c:Color):Bool {\n\t\tvar seen:Map<Color, Bool> = [];\n\t\tseen[c] = true;\n\t\treturn seen.exists(c);\n\t}\n\n}\n';
	private static final CMP: String = 'package lib;\nclass Cmp {\n\tpublic static function strings(a:String, b:String):Int return 0;\n}';
	private static final SORTED: String = '@:nullSafety(Strict)\nclass C {\n\n\tstatic function main() {}\n\n'
		+ '\tfunction wrapped(xs:Array<String>):Void {\n\t\txs.sort((a, b) -> Reflect.compare(a, b));\n\t}\n\n'
		+ '\tfunction ternary(xs:Array<String>):Void {\n\t\txs.sort((a:String, b:String) -> a < b ? -1 : a > b ? 1 : 0);\n\t}\n\n}\n';

	/** The driver refuses a fix importing what the file's own build cannot see, with a sentence naming the module. */
	@:pin('control')
	@:killer('M-IMPORTREACH-GUARD-UNWIRED')
	public function testAFixImportingWhatTheBuildCannotSeeIsRefused(): Void {
		#if (sys || nodejs)
		final root: String = fixture();
		final groups: Array<RuleEdits> = groupsUnder(root, reachOver([leaf(root, 'narrow.hxml')]));
		Assert.equals(1, groups.length);
		final refusal: Null<String> = groups[0].refusal;
		Assert.notNull(refusal);
		Assert.isTrue((refusal ?? '').indexOf('`lib.Text`') != -1, 'the sentence names the module: $refusal');
		Assert.equals(0, LintFixDriver.contributedEdits(groups).length, 'and no edit of it reaches the file');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The coverage of a compile answers per module: a root without it names the gap, a root with it says nothing. */
	@:pin('control')
	@:killer('M-IMPORTREACH-NEVER-REFUSES')
	public function testACoverageNamesTheModuleItsRootsLack(): Void {
		#if (sys || nodejs)
		final root: String = fixture();
		final file: String = '$root/leaf/src/C.hx';
		final lacking: OracleCoverage = OracleCoverage.of([file], root, null, ['$root/leaf/src']);
		Assert.isTrue((lacking.unreached(file, ['lib.Text']) ?? '').indexOf('`lib.Text`') != -1);
		Assert.isNull(OracleCoverage.of([file], root, null, ['$root/leaf/src', '$root/shared']).unreached(file, ['lib.Text']));
		Assert.isNull(lacking.unreached('$root/leaf/src/Other.hx', ['lib.Text']), 'a file the compile does not read is not its question');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The same fix in a build whose classpath holds the module is offered untouched. */
	@:pin('control')
	@:killer('M-IMPORTREACH-ALWAYS-REFUSES')
	public function testAFixImportingWhatTheBuildSeesIsOffered(): Void {
		#if (sys || nodejs)
		final root: String = fixture();
		final groups: Array<RuleEdits> = groupsUnder(root, reachOver([leaf(root, 'wide.hxml')]));
		Assert.equals(1, groups.length);
		Assert.isNull(groups[0].refusal);
		Assert.isTrue(LintFixDriver.contributedEdits(groups).length > 0);
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** One build that lacks the module is enough: the wide leaf does not vouch for the file the narrow leaf compiles too. */
	@:pin('control')
	@:killer('M-IMPORTREACH-FIRST-BUILD-ONLY')
	public function testEveryBuildThatCompilesTheFileMustSeeTheModule(): Void {
		#if (sys || nodejs)
		final root: String = fixture();
		final groups: Array<RuleEdits> = groupsUnder(root, reachOver([leaf(root, 'wide.hxml'), leaf(root, 'narrow.hxml')]));
		Assert.notNull(groups[0].refusal);
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** No declared build, no question: the fix is offered as it was. */
	public function testNoDeclaredBuildAsksNothing(): Void {
		#if (sys || nodejs)
		final root: String = fixture();
		final groups: Array<RuleEdits> = groupsUnder(root, reachOver([]));
		Assert.isNull(groups[0].refusal);
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The transcript reader gives each arm the `Classpath:` line printed before its `Defines:`. */
	@:pin('control')
	@:killer('M-IMPORTREACH-ARM-CLASSPATH-DROPPED')
	public function testEachArmCarriesItsOwnClasspath(): Void {
		final arms: Array<CompiledArm> =
			OracleCoverage.parseArms('Classpath: a/;;/std/\nDefines: js\nParsed a/A.hx\nClasspath: b/\nDefines: neko\nParsed b/B.hx\n');
		Assert.equals(2, arms.length);
		Assert.same(['a/', '.', '/std/'], arms[0].classPaths);
		Assert.same(['b/'], arms[1].classPaths);
	}

	/** `pack.Module.member` and `pack.Module.Sub` import through `pack/Module.hx`: the longest prefix that is a file decides. */
	@:pin('control')
	@:killer('M-IMPORTREACH-HOLDS-EXACT-PATH-ONLY')
	public function testAModulePathResolvesThroughItsLongestFilePrefix(): Void {
		#if (sys || nodejs)
		final root: String = fixture();
		final roots: Array<String> = ['$root/shared'];
		Assert.isTrue(OracleCoverage.holdsModule(roots, 'lib.Text'));
		Assert.isTrue(OracleCoverage.holdsModule(roots, 'lib.Text.allBefore'));
		Assert.isFalse(OracleCoverage.holdsModule(roots, 'lib.Other'));
		Assert.isFalse(OracleCoverage.holdsModule(['$root/leaf/src'], 'lib.Text'));
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** An arm whose roots the transcript did not name proves nothing, so it refuses nothing. */
	public function testAnArmWithNoNamedRootsIsUnknownNotEmpty(): Void {
		#if (sys || nodejs)
		final coverage: OracleCoverage = OracleCoverage.of(['C.hx'], '.');
		Assert.isNull(coverage.unreached('C.hx', ['lib.Text']));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A finding whose only remedy imports what a build reading its file cannot see is not reported, though the rule found it. */
	@:pin('control')
	@:killer('M-IMPORTREACH-REPORT-KEEPS-ALL')
	public function testAFindingWhoseRemedyTheBuildCannotSeeIsNotReported(): Void {
		#if (sys || nodejs)
		final root: String = fixture();
		Assert.equals(1, foundIn(root, MAIN).own.length, 'the rule does find the site');
		Assert.equals(0, reportedUnder(root, reachOver([leaf(root, 'narrow.hxml')]), MAIN).length);
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The same finding in a build that holds the module is reported, and so is one when a build is not asked at all. */
	@:pin('control')
	@:killer('M-IMPORTREACH-REPORT-DROPS-ALL')
	public function testAFindingWhoseRemedyTheBuildSeesIsReported(): Void {
		#if (sys || nodejs)
		final root: String = fixture();
		Assert.equals(1, reportedUnder(root, reachOver([leaf(root, 'wide.hxml')]), MAIN).length);
		Assert.equals(1, reportedUnder(root, reachOver([]), MAIN).length, 'no declared build, no question');
		Assert.equals(
			0, reportedUnder(root, reachOver([leaf(root, 'wide.hxml'), leaf(root, 'narrow.hxml')]), MAIN).length,
			'one blind build is enough'
		);
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Builds are compiled only for a finding whose fix would add an import: one the file already has asks nothing. */
	@:pin('control')
	@:killer('M-IMPORTREACH-PROBES-EAGERLY')
	public function testNoBuildIsProbedWhenTheFixAddsNoImport(): Void {
		#if (sys || nodejs)
		final root: String = fixture();
		final reach: ImportReach = reachOver([leaf(root, 'narrow.hxml')]);
		Assert.equals(1, reportedUnder(root, reach, 'import lib.Text;\n\n$MAIN').length);
		Assert.isFalse(reach.probed(), 'an import already in the file is nothing to probe for');
		Assert.equals(0, reportedUnder(root, reach, MAIN).length);
		Assert.isTrue(reach.probed(), 'the same builds are probed once a fix would import');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A finding advising the project's helper names its module: that is what a build is asked about. */
	@:pin('control')
	@:killer('M-REMEDY-COMPARE-UNSET')
	public function testACompareFindingNamesTheModuleOfItsFunction(): Void {
		final run: Found = compareFoundIn('.', SORTED);
		Assert.equals(1, run.own.length);
		Assert.equals('lib.Cmp', run.own[0].remedy);
	}

	/** A compare finding follows the same reach: silent where the build cannot read `lib.Cmp`, reported where it can. */
	@:pin('control')
	@:killer('M-IMPORTREACH-REPORT-KEEPS-ALL')
	public function testACompareFindingFollowsTheSameReach(): Void {
		#if (sys || nodejs)
		final root: String = fixture();
		final run: Found = compareFoundIn(root, SORTED);
		Assert.equals(0, reachOver([leaf(root, 'narrow.hxml')]).reportable(run.own, run.files, run.plugin).length);
		Assert.equals(1, reachOver([leaf(root, 'wide.hxml')]).reportable(run.own, run.files, run.plugin).length);
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A split-part finding names its utility's module. */
	@:pin('control')
	@:killer('M-REMEDY-SPLIT-UNSET')
	public function testASplitFindingNamesTheModuleOfItsUtility(): Void {
		final run: Found = foundIn('.', MAIN);
		Assert.equals(1, run.own.length);
		Assert.equals('lib.Text', run.own[0].remedy);
	}

	/** A growing map-as-set finding names the project's `set` module, a bit-set finding its `bits` module, and the Array advice none. */
	@:pin('control')
	@:killer('M-REMEDY-MAPASSET-SET-UNSET')
	public function testAGrowingSetFindingNamesTheSetModule(): Void {
		final run: Found = mapAsSetFoundIn(GROWN);
		Assert.equals(1, run.own.length);
		Assert.stringContains('Sets<String>', run.own[0].message);
		Assert.equals('lib.Sets', run.own[0].remedy);
	}

	@:pin('control')
	@:killer('M-REMEDY-MAPASSET-BITS-UNSET')
	public function testABitSetFindingNamesTheBitsModule(): Void {
		final run: Found = mapAsSetFoundIn(FLAGGED);
		Assert.equals(1, run.own.length);
		Assert.stringContains('Flags<Color>', run.own[0].message);
		Assert.equals('lib.Flags', run.own[0].remedy);
	}

	/** The Array advice needs no project module, so nothing is asked of a build for it. */
	@:pin('control')
	@:killer('M-REMEDY-MAPASSET-ARRAY-NAMES')
	public function testTheArrayAdviceNamesNoModule(): Void {
		final run: Found = mapAsSetFoundIn(ONCE);
		Assert.equals(1, run.own.length);
		Assert.stringContains('Array<String>', run.own[0].message);
		Assert.isNull(run.own[0].remedy);
	}

	#if (sys || nodejs)
	/** Two leaves over one tree: `narrow` sees `src` alone, `wide` also sees the root `lib.Text` lives under. */
	private static function fixture(): String {
		return CliFixture.writeTree('importreach', [
			{ name: 'leaf/narrow.hxml', source: '-cp src\n-main C\n' },
			{ name: 'leaf/wide.hxml', source: '-cp src\n-cp ../shared\n-main C\n' },
			{ name: 'leaf/src/C.hx', source: MAIN },
			{ name: 'shared/lib/Text.hx', source: TEXT },
			{ name: 'shared/lib/Cmp.hx', source: CMP }
		]);
	}

	/** The reach over `builds`, answered by the Haxe compiler oracle the grammar supplies. */
	private static function reachOver(builds: Array<OracleConfig>): ImportReach {
		return new ImportReach(OracleProviders.of(new HaxeQueryPlugin()), builds);
	}

	private static function leaf(root: String, hxml: String): OracleConfig {
		return {
			hxml: '$root/leaf/$hxml',
			dir: '$root/leaf',
			defines: []
		};
	}

	/** The groups `lint --fix` would collect for `C.hx` under `reach`. */
	private static function groupsUnder(root: String, reach: ImportReach): Array<RuleEdits> {
		final run: Found = foundIn(root, MAIN);
		return LintFixDriver.collectFileLintEdits(MAIN, run.own, [run.check], run.plugin, CheckFixture.index(run.files, run.plugin), reach);
	}

	/** The findings `lint` would report for `source` as `C.hx`, once `reach` has asked each remedy's builds. */
	private static function reportedUnder(root: String, reach: ImportReach, source: String): Array<Violation> {
		final run: Found = foundIn(root, source);
		return reach.reportable(run.own, run.files, run.plugin);
	}

	private static function foundIn(root: String, source: String): Found {
		final check: PreferSplitPart = new PreferSplitPart();
		check.setConfigResolver(_ -> LintConfig.parse(CONFIG));
		return foundBy(root, source, check, CONFIG);
	}

	/** The findings of `compare` over `source` as `C.hx`, the project naming `lib.Cmp.strings` for `String`. */
	private static function compareFoundIn(root: String, source: String): Found {
		final check: PreferCompareFunction = new PreferCompareFunction();
		check.setConfigResolver(_ -> LintConfig.parse(COMPARE_CONFIG));
		return foundBy(root, source, check, COMPARE_CONFIG);
	}

	/** The findings of `map-as-set` over `source` as `C.hx`, the project naming `lib.Sets` and `lib.Flags` as its set and bit-set types. */
	private static function mapAsSetFoundIn(source: String): Found {
		final check: MapAsSet = new MapAsSet();
		check.setConfigResolver(_ -> LintConfig.parse(SET_CONFIG));
		return foundBy('.', source, check, SET_CONFIG);
	}

	private static function foundBy(root: String, source: String, check: Check, config: String): Found {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final files: Array<{ file: String, source: String }> = [
			{ file: '$root/leaf/src/C.hx', source: source },
			{ file: 'lib/Text.hx', source: TEXT },
			{ file: 'lib/Cmp.hx', source: CMP }
		];
		final own: Array<Violation> = CheckFixture.violationsIn(check, files, plugin, _ -> LintConfig.parse(config))
			.filter(v -> v.file == files[0].file);
		return {
			check: check,
			files: files,
			plugin: plugin,
			own: own
		};
	}
	#end

}

/** One rule's findings in `C.hx` and what produced them. */
private typedef Found = {
	final check: Check;
	final files: Array<{ file: String, source: String }>;
	final plugin: CachingGrammarPlugin;
	final own: Array<Violation>;
}
