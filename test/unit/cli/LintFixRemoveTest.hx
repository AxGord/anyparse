package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.check.Check;
import anyparse.check.EmptyAmbientSource;
import anyparse.check.LintConfig;
import anyparse.check.RuleCategory;
import anyparse.check.Severity;
import anyparse.check.UnusedImport;
import anyparse.check.oracle.CompilerOracle;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.ExitCode;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.query.cli.command.LintFixDriver;
import anyparse.runtime.Span;

using StringTools;

/**
 * A fix that DELETES a file, and the ambient sources a pass rewrites: `lint --fix` takes a deleted file out
 * of the run, restores its exact bytes when the oracle rejects the pass, and puts an ambient source a pass
 * rewrote on disk before the next pass resolves the chain from there.
 */
@:nullSafety(Strict)
class LintFixRemoveTest extends Test {

	/** The modules every fixture's ambient source governs. */
	private static final MODULES: Array<{ name: String, source: String }> = [
		{ name: 'src/qqz/Liveqqw.hx', source: 'package qqz;\n\nclass Liveqqw {}\n' },
		{ name: 'src/qqz/Deadqqw.hx', source: 'package qqz;\n\nclass Deadqqw {}\n' },
		{ name: 'src/aqq/Mqq.hx', source: 'package aqq;\n\nclass Mqq {\n\n\tstatic var a:Liveqqw;\n\n\tstatic function main() {}\n\n}\n' }
	];

	/** A slice that removes a file deletes it from disk and from the run, and nothing else moves. */
	@:pin('control')
	@:killer('M-FIX-REMOVE-IGNORED')
	public function testARemoveDeletesTheFile(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_fix_remove', MODULES.concat([{ name: 'src/aqq/import.hx', source: '\n' }]));
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final code: Int = run(root, [new EmptyAmbientSource()], []);
			out = '$code|${FileSystem.exists('$root/src/aqq/import.hx')}|${File.getContent('$root/src/aqq/Mqq.hx') == MODULES[2].source}';
		});
		Assert.equals('0|false|true', out);
		#else
		Assert.pass();
		#end
	}

	/** A pass the oracle rejects writes a deleted file back with the bytes the run started from. */
	@:pin('control')
	@:killer('M-FIX-REMOVE-NO-RESTORE')
	public function testARevertRestoresADeletedFileByteForByte(): Void {
		#if (sys || nodejs)
		final ambient: String = '// keep  these bytes\nimport  qqz.Liveqqw;\n';
		final root: String = CliFixture.writeTree('apq_fix_remove_revert', MODULES.concat([
			{ name: 'src/aqq/import.hx', source: ambient },
			{ name: 'check.hxml', source: '-cp src\n-main aqq.Mqq\n--interp\n' }
		]));
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			if (!CompilerOracle.typecheck('check.hxml', root).match(Confirmed)) {
				out = 'skipped';
				return;
			}
			final code: Int = run(root, [new LoadBearingRemove()], [{ hxml: 'check.hxml', dir: root, defines: [] }]);
			final path: String = '$root/src/aqq/import.hx';
			out = '${code == ExitCode.EXIT_RUNTIME}|${FileSystem.exists(path) && File.getContent(path) == ambient}';
		});
		if (out == 'skipped')
			Assert.pass('haxe unavailable — skipped')
		else
			Assert.equals('true|true', out);
		#else
		Assert.pass();
		#end
	}

	/** An ambient source a pass rewrote is on disk when the next pass starts, since that pass reads the chain from there. */
	@:pin('control')
	@:killer('M-FIX-AMBIENT-HELD')
	public function testAPassPutsAnAmbientSourceItRewroteOnDisk(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_fix_ambient_disk', MODULES.concat([
			{ name: 'src/aqq/import.hx', source: 'import qqz.Deadqqw;\nimport qqz.Liveqqw;\n' }
		]));
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final witness: DiskWitness = new DiskWitness('$root/src/aqq/import.hx');
			out = '${run(root, [new UnusedImport(), witness], [])}|${witness.seen.join(' :: ')}';
		});
		Assert.equals('0|import qqz.Deadqqw;\nimport qqz.Liveqqw;\n :: import qqz.Liveqqw;\n', out);
		#else
		Assert.pass();
		#end
	}

	/**
	 * Two cross-file fixes whose edits of one file overlap are refused as a component: applied together the
	 * later one would silently swallow the earlier — here a whole-file rewrite would drop a rename.
	 */
	@:pin('control')
	@:killer('M-FIX-OVERLAP-BLIND')
	public function testOverlappingCrossFileEditsAreSkipped(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree(
			'apq_fix_overlap', MODULES.concat([{ name: 'src/aqq/import.hx', source: 'import qqz.Liveqqw;\n' }])
		);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final code: Int = run(root, [new OverlappingPair()], []);
			out = '$code|${File.getContent('$root/src/aqq/Mqq.hx') == MODULES[2].source}';
		});
		Assert.equals('0|true', out);
		#else
		Assert.pass();
		#end
	}

	#if (sys || nodejs)
	/** One `lint --fix` over every file of the fixture tree under `root`, judged by `oracles` when there are any. */
	private static function run(root: String, checks: Array<Check>, oracles: Array<OracleConfig>): Int {
		final files: Array<{ file: String, source: String }> = [
			for (entry in MODULES.concat([{ name: 'src/aqq/import.hx', source: '' }]))
				{ file: '$root/${entry.name}', source: File.getContent('$root/${entry.name}') }
		];
		var code: Int = 0;
		CliFixture.captureStderr(() ->
			code = LintFixDriver.runLintFix(
				files, checks, new HaxeQueryPlugin(), _ -> LintConfig.parse('{}'), false, null, oracles, oracles.length == 0, null, false
			)
		);
		return code;
	}
	#end

}

/** Reports every ambient source and deletes it — a fix the oracle has to reject wherever a module reads one. */
private class LoadBearingRemove implements Check implements CrossFileFix {

	public function new() {}

	public function id(): String {
		return 'load-bearing-remove';
	}

	public function description(): String {
		return 'deletes every ambient source';
	}

	public function category(): RuleCategory {
		return RuleCategory.Design;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return [
			for (entry in files) if (plugin.ambientImportGovernance(entry.file) != null) {
				file: entry.file,
				span: new Span(0, entry.source.length),
				rule: id(),
				severity: Severity.Warning,
				message: 'an ambient source'
			}
		];
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

	public function crossFileFix(
		files: Array<{ file: String, source: String }>, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<Array<CrossFileEdits>> {
		return [for (v in violations) [{ file: v.file, edits: [], remove: true }]];
	}

}

/** Reads one file from DISK each time it is run — what the pass about to judge it would find there. */
private class DiskWitness implements Check {

	/** The text found at each run, in order. */
	public final seen: Array<String> = [];

	private final _path: String;

	public function new(path: String) {
		_path = path;
	}

	public function id(): String {
		return 'disk-witness';
	}

	public function description(): String {
		return 'records one file as it stands on disk';
	}

	public function category(): RuleCategory {
		return RuleCategory.Design;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		#if (sys || nodejs)
		final text: String = File.getContent(_path);
		if (seen.length == 0 || seen[seen.length - 1] != text) seen.push(text);
		#end
		return [];
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

}

/** Two fixes of one module that overlap: a rename of its field `a`, and a rewrite of the whole file beside it. */
private class OverlappingPair implements Check implements CrossFileFix {

	public function new() {}

	public function id(): String {
		return 'overlapping-pair';
	}

	public function description(): String {
		return 'two overlapping fixes of one module';
	}

	public function category(): RuleCategory {
		return RuleCategory.Design;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return [
			for (entry in files) if (entry.file.endsWith('/Mqq.hx')) {
				file: entry.file,
				span: new Span(0, 1),
				rule: id(),
				severity: Severity.Warning,
				message: 'a module'
			}
		];
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

	public function crossFileFix(
		files: Array<{ file: String, source: String }>, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<Array<CrossFileEdits>> {
		final out: Array<Array<CrossFileEdits>> = [];
		for (v in violations) for (entry in files) if (entry.file == v.file) {
			final at: Int = entry.source.indexOf('var a:') + 'var '.length;
			out.push([{ file: v.file, edits: [{ span: new Span(at, at + 1), text: 'b' }] }]);
			out.push([
				{
					file: v.file,
					edits: [
						{
							span: new Span(0, entry.source.length),
							text: entry.source.replace('static function main() {}', 'static function main() {}\n\n\tstatic var c:Int = 0;')
						}
					]
				}
			]);
		}
		return out;
	}

}
