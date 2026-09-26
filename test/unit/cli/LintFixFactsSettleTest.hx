package unit.cli;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.CompilerOracle;
import anyparse.check.ExplicitLocalType;
import anyparse.check.LintConfig;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin.ResolutionScope;
import anyparse.query.CachingGrammarPlugin.LibrarySources;
import anyparse.query.cli.command.LintFixDriver;
import utest.Assert;
import utest.Test;

/**
 * `lint --fix` lets the facts compiles it started ahead finish before its first disk write: a compile still typing when a
 * rewrite lands would certify the new text for positions of the old one.
 */
class LintFixFactsSettleTest extends Test {

	@:pin('control') @:killer('M-FIX-FACTS-SETTLED')
	public function testTheFactsSettleBeforeTheFirstWrite(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('factssettle', [
			{ name: 'Main.hx', source: 'class Main {\n\tstatic function main() {\n\t\tvar x = 1;\n\t\ttrace(x);\n\t}\n}\n' },
			{ name: 'check.hxml', source: '-cp .\n-main Main\n--interp\n' }
		]);
		if (!CompilerOracle.typecheck('check.hxml', dir).match(Confirmed)) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final file: String = '$dir/Main.hx';
		final before: String = File.getContent(file);
		final seen: Array<String> = [];
		final resolution: ResolutionScope = {
			declared: true,
			sources: () -> {report: [], projectRoots: [], library: new LibrarySources([]) },
			facts: () -> null,
			factsSettled: () -> seen.push(File.getContent(file))
		};
		CliFixture.captureStderr(() ->
			LintFixDriver.runLintFix(
				[{ file: file, source: before }],
				[new ExplicitLocalType()],
				new HaxeQueryPlugin(), _ -> LintConfig.parse('{}'), false, resolution, [{ hxml: 'check.hxml', dir: dir, defines: [] }],
				false, null, false
			)
		);
		Assert.notEquals(before, File.getContent(file), 'the run wrote the file');
		Assert.isTrue(seen.length > 0, 'the run never let the facts compiles settle');
		Assert.equals(before, seen[0], 'the facts compiles settled only after the run wrote');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
