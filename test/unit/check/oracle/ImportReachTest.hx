package unit.check.oracle;

import anyparse.check.LintConfig;
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
	private static final TEXT: String = 'package lib;\nclass Text {\n'
		+ '\tpublic static function allBefore(text:String, delimiter:String):String return text;\n'
		+ '\tpublic static function allAfterLast(text:String, delimiter:String):String return text;\n}';
	private static final MAIN: String =
		'class C {\n\n\tstatic function main() {}\n\n\tfunction f(s:String):Void {\n\t\tvar a = s.split(",")[0];\n\t}\n\n}\n';

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

	#if (sys || nodejs)
	/** Two leaves over one tree: `narrow` sees `src` alone, `wide` also sees the root `lib.Text` lives under. */
	private static function fixture(): String {
		return CliFixture.writeTree('importreach', [
			{ name: 'leaf/narrow.hxml', source: '-cp src\n-main C\n' },
			{ name: 'leaf/wide.hxml', source: '-cp src\n-cp ../shared\n-main C\n' },
			{ name: 'leaf/src/C.hx', source: MAIN },
			{ name: 'shared/lib/Text.hx', source: TEXT }
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
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final check: PreferSplitPart = new PreferSplitPart();
		check.setConfigResolver(_ -> LintConfig.parse(CONFIG));
		final files: Array<{ file: String, source: String }> = [
			{ file: '$root/leaf/src/C.hx', source: MAIN },
			{ file: 'lib/Text.hx', source: TEXT }
		];
		final own: Array<Violation> = CheckFixture.violationsIn(check, files, plugin, _ -> LintConfig.parse(CONFIG))
			.filter(v -> v.file == files[0].file);
		return LintFixDriver.collectFileLintEdits(MAIN, own, [check], plugin, CheckFixture.index(files, plugin), reach);
	}
	#end

}
