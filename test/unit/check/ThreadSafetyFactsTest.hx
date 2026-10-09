package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import anyparse.check.CompilerOracle;
import anyparse.check.LintConfig;
import anyparse.check.OracleCoverage;
import anyparse.check.ThreadSafety;
import anyparse.check.TypedFactsProbe;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CompilerFacts;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * `thread-safety` reads its graph through the run's compiler facts when the project asks (`compilerFacts`) and it has them (`SymbolIndexHost.compilerFacts`):
 * a call the syntax cannot type — a receiver whose type only inference knows — resolves, and the function it runs is
 * reached where it runs instead of assumed to run on the main thread. Without facts the graph is the syntax's alone.
 */
class ThreadSafetyFactsTest extends Test {

	private static inline final MAIN: String = 'class S { public function new() {} public function work():Void Sys.sleep(1); }\n'
		+ 'class Runner { public static function create(fn:()->Void):Void {} }\n'
		+ 'class Main {\n\tstatic function make()\n\t\treturn new S();\n\n'
		+ '\tstatic function main():Void Runner.create(() -> {\n\t\tfinal s = make();\n\t\ts.work();\n\t});\n}\n';

	private static inline final CONFIG: String =
		'{"rules":{"thread-safety":{"sinks":["Sys.sleep"],"spawns":["Runner.create"],"compilerFacts":true}}}';

	@:pin('control') @:killer('M-TS-FACTS-IGNORED') @:killer('M-TS-FACTS-MADE-REF') @:killer('M-TS-FACTS-GATE')
	public function testCompilerFactsResolveWhatTheSyntaxCannot(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('ts_facts', [
			{ name: 'Main.hx', source: MAIN },
			{ name: 'build.hxml', source: '-cp .\n-main Main\n--interp\n' },
			{ name: 'apqlint.json', source: CONFIG }
		]);
		final facts: Null<CompilerFacts> = CompilerOracle.typecheck('build.hxml', dir).match(Confirmed)
			? TypedFactsProbe.probeAll([{ hxml: 'build.hxml', dir: dir, defines: [] }])
			: null;
		if (facts == null) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		// the facts key a file by its canonical path, as a lint run hands it over
		final files: Array<{ file: String, source: String }> = [{ file: OracleCoverage.canonical(dir, 'Main.hx'), source: MAIN }];
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		// by syntax `s.work()` is unresolved, and `S.work`, reached by nothing, is assumed to run on the main thread
		final syntax: Array<String> = graded(new ThreadSafety().run(files, plugin));
		plugin.setResolutionScope({
			declared: false,
			sources: () -> {
				report: files,
				projectRoots: [],
				library: new LibrarySources([]),
				rootsMatched: true,
				rootsAllMatched: true
			},
			facts: () -> facts
		});
		final typed: Array<String> = graded(new ThreadSafety().run(files, plugin));
		// a project that does not ask reads the syntax alone, facts or not
		final unasked: ThreadSafety = new ThreadSafety();
		unasked.setConfigResolver(_ -> LintConfig.parse(StringTools.replace(CONFIG, '"compilerFacts":true', '"compilerFacts":false')));
		final off: Array<String> = graded(unasked.run(files, plugin));
		CliFixture.removeDir(dir);
		Assert.same(['warning A S.work | Sys.sleep'], syntax, 'syntax alone');
		Assert.same([], typed, 'through the facts: the worker runs it');
		Assert.same(['warning A S.work | Sys.sleep'], off, 'not asked');
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static function graded(found: Array<Violation>): Array<String> {
		return [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null) '${v.severity.label()} ${data.family} ${data.member} | ${data.subject}';
			}
		];
	}
	#end

}
