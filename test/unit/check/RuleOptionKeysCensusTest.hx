package unit.check;

import anyparse.check.Check;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.util.Compare;
import unit.cli.CliFixture;

/**
 * The option-key diagnostic covers every builtin rule id, not only the ones that declare keys: a key under a rule that
 * reads none is said, and a rule id no check has is said with the nearest ids.
 */
@:nullSafety(Strict)
final class RuleOptionKeysCensusTest extends Test {

	/**
	 * One source holding the shapes whose option reads real code does not reach: a caught `Dynamic`, a `Map` used as a set
	 * that grows, a `split` cut of a `String`, and an untyped local.
	 */
	private static final FIXTURES: Array<{ file: String, source: String }> = [{
		file: 'fixture/A.hx',
		source: 'import haxe.ds.StringMap;\nimport haxe.ds.IntMap;\nclass A {\n'
			+ '\tpublic function f(s: String, m: Map<String, Bool>): Void {\n\t\ttry {} catch (e: Dynamic) {}\n'
			+ '\t\tfinal i = s.indexOf(",");\n\t\tfinal t = s.substr(i + 1);\n\t\tvar local = new StringMap<Int>();\n\t\tfinal seen: '
			+ 'Map<String, Bool> = [];\n\t\tfor (k in [s]) seen[k] = true;\n\t\tfinal head: String = s.split(",")[0];\n\t}\n}\n'
	}];

	/**
	 * The checks that declare keys and still read none under the corpus: `hoist-common-import` reads them only while planning
	 * over a directory tree on disk. Its keys are held by `RuleOptionKeysDeclaredTest` and its own test, not by this census.
	 */
	private static final UNREACHED: Array<String> = ['hoist-common-import'];

	/** Files the census runs every check over: real code of this repository, each shape-rich in a different way. */
	private static final CORPUS: Array<String> = [
		'src/anyparse/check/LintDocuments.hx',
		'src/anyparse/check/Linter.hx',
		'src/anyparse/check/LintConfig.hx',
		'test/unit/check/RuleOptionKeysTest.hx'
	];

	@:pin('control')
	@:killer('M-OPTKEYS-OPTIONLESS-ENTERED')
	public function testAKeyUnderARuleThatDeclaresNoneIsSaid(): Void {
		#if (sys || nodejs)
		final notes: Array<ConfigNote> = discover('{"rules":{"unused-import":{"foo":1}}}');
		Assert.equals(1, notes.length, notes.map(note -> note.message).join('\n'));
		final message: String = notes.length == 1 ? notes[0].message : '';
		Assert.isTrue(message.indexOf('rules "unused-import" has unknown option "foo" — ignored; accepts: none') >= 0, message);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-OPTKEYS-UNKNOWN-RULE-SILENT')
	@:killer('M-OPTKEYS-UNKNOWN-RULE-NEAREST')
	public function testAnUnknownRuleIdIsSaidWithTheNearestIds(): Void {
		#if (sys || nodejs)
		final notes: Array<ConfigNote> = discover('{"rules":{"unused-imports":{"enabled":true}}}');
		Assert.equals(1, notes.length, notes.map(note -> note.message).join('\n'));
		final message: String = notes.length == 1 ? notes[0].message : '';
		Assert.isTrue(message.indexOf('rules "unused-imports" names no rule — ignored; nearest: unused-import') >= 0, message);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Every option a check reads through its config is one it declares: each builtin runs over a corpus under a recording
	 * config, and the keys it asked for are checked against its `OptionKeyed` list. A check reading an option with no
	 * declaration, or a key outside its list, is what this fails on; the diagnostics above are only as good as these lists.
	 * A read reached only by a source shape the corpus lacks is the residual gap, named by `testTheCorpusReachesEveryDeclaringCheck`.
	 */
	@:pin('control')
	@:killer('M-OPTKEYS-AVOID-ANY-DECLARED')
	public function testEveryKeyACheckReadsIsDeclaredByIt(): Void {
		#if (sys || nodejs)
		final checks: Array<Check> = Linter.builtins();
		final recorder: ConfigReadRecorder = recordedReads(checks);
		final declared: Map<String, Array<String>> = Linter.acceptedOptions();
		final keyed: Map<String, Bool> = [ for (check in checks) check.id() => check is OptionKeyed ];
		final problems: Array<String> = [];
		for (id => keys in recorder.reads) {
			if (keyed[id] != true)
				problems.push('$id reads options and does not declare them (OptionKeyed)');
			else
				for (key in keys) if (!(declared[id] ?? []).contains(key)) problems.push('$id reads "$key" and does not declare it');
		}
		problems.sort(Compare.compareString);
		Assert.same([], problems, problems.join('; '));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Reads are conditional on the source, so the census only proves what its corpus reaches: every declaring check is reached. */
	@:pin('guard')
	public function testTheCorpusReachesEveryDeclaringCheck(): Void {
		#if (sys || nodejs)
		final checks: Array<Check> = Linter.builtins();
		final recorder: ConfigReadRecorder = recordedReads(checks);
		final unreached: Array<String> = [
			for (check in checks) if (check is OptionKeyed && !recorder.reads.exists(check.id())) check.id()
		];
		unreached.sort(Compare.compareString);
		Assert.same(UNREACHED, unreached, 'checks the corpus never made read an option: ' + unreached.join(', '));
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static function discover(config: String): Array<ConfigNote> {
		final dir: String = CliFixture.writeDir('ruleoptionkeyscensus', [
			{ name: 'apq.json', source: config },
			{ name: 'Foo.hx', source: 'class Foo {}\n' }
		]);
		final notes: Array<ConfigNote> = [];
		final config: LintConfig = LintConfig.discover('$dir/Foo.hx', notes, Linter.acceptedOptions());
		CliFixture.removeDir(dir);
		Assert.isTrue(config.enabledFor('naming'), 'the config still applies');
		return notes;
	}

	private static function recordedReads(checks: Array<Check>): ConfigReadRecorder {
		final recorder: ConfigReadRecorder = new ConfigReadRecorder(checks.map(check -> check.id()));
		final files: Array<{ file: String, source: String }> = CORPUS.map(file -> { file: file, source: sys.io.File.getContent(file) })
			.concat(FIXTURES);
		var found: Int = 0;
		for (check in checks) {
			final violations: Array<Violation> = CheckFixture.violationsIn(check, files, null, _ -> recorder.config());
			found += violations.length;
			// A fix reads options of its own (where a rule edits, how it spells the edit), so each file's findings go through it too.
			for (entry in files) {
				final here: Array<Violation> = violations.filter(v -> v.file == entry.file);
				if (here.length > 0) CheckFixture.fixIn(check, files, here, entry.file);
			}
		}
		Assert.isTrue(found > 0, 'the corpus draws findings, so the checks ran');
		return recorder;
	}
	#end

}
