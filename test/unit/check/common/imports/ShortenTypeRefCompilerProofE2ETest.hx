package unit.check.common.imports;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.FixVerifier;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.common.imports.ShortenTypeRef;
import anyparse.check.oracle.CompilerOracle.OracleOutcome;
import anyparse.check.oracle.OracleRunMemo;
import anyparse.query.CachingGrammarPlugin;
import unit.cli.CliFixture;

/**
 * A VALUE site of `shorten-type-ref` is rewritten only where the compiler names one declaration for the qualified and the
 * short spelling. A build macro attached by the build configuration (`--macro addGlobalMetadata`) is invisible in every
 * source, adds a static of the short name, and the shortened call still compiles while reading that static instead.
 * Runs the whole verified pass: `FixVerifier`, the real compiler, its display server.
 */
final class ShortenTypeRefCompilerProofE2ETest extends Test {

	#if (sys || nodejs)
	/** The type the value site names. */
	private static final F_SOURCE: String =
		'package a;\n\nclass F {\n\tpublic static function make():String {\n\t\treturn \'a.F\';\n\t}\n}\n';

	/** A build macro adding a static `F` with a `make` of its own to the class it builds. */
	private static final BUILDER_SOURCE: String = 'package a;\n\nimport haxe.macro.Context;\nimport haxe.macro.Expr;\n\nclass Builder {\n'
		+ '\tpublic static macro function build():Array<Field> {\n\t\tfinal fields = Context.getBuildFields();\n'
		+ '\t\tfields.push({name: \'F\', access: [AStatic, APublic], kind: FVar(null, macro {make: () '
		+ '-> \'built\'}), pos: Context.currentPos()});\n\t\treturn fields;\n\t}\n}\n';

	/** The consumer: `a.F` from the child package `a.b`, whose short name the parent package reaches. */
	private static final MAIN_SOURCE: String = 'package a.b;\n\nclass Main {\n\tstatic function main() {\n\t\ttrace(a.F.make());\n\t}\n}\n';

	private static final PLAIN_HXML: String = '-cp .\n-main a.b.Main\n--no-output\n';
	#end

	@:pin('control')
	@:killer('M-NAME-PROOF-ALWAYS-SAME')
	public function testABuildMacroFromTheBuildConfigurationKeepsTheValueSiteQualified(): Void {
		#if (sys || nodejs)
		final hxml: String = '$PLAIN_HXML--macro addGlobalMetadata(\'a.b.Main\', \'@:build(a.Builder.build())\')\n';
		final after: Verified = verified(hxml);
		Assert.isTrue(after.verdict.baseline.match(Confirmed), 'the baseline confirms, so the verdict is the rule\'s');
		Assert.equals(MAIN_SOURCE, after.main, 'the shortened call would read the macro\'s static');
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-FIXVERIFIER-NAMES-NOT-INSTALLED')
	public function testWithoutTheMacroTheValueSiteShortens(): Void {
		#if (sys || nodejs)
		final after: Verified = verified(PLAIN_HXML);
		Assert.isTrue(after.main.indexOf('trace(F.make());') != -1, 'the compiler names a.F for both, got: ${after.main}');
		Assert.equals(1, after.verdict.applied.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** The verified pass of `shorten-type-ref` over the consumer of a tree built by `hxml`, and the consumer's text after it. */
	private function verified(hxml: String): Verified {
		final root: String = CliFixture.writeTree('apq_shorten_proof', [
			{ name: 'a/F.hx', source: F_SOURCE },
			{ name: 'a/Builder.hx', source: BUILDER_SOURCE },
			{ name: 'a/b/Main.hx', source: MAIN_SOURCE },
			{ name: 'build.hxml', source: hxml }
		]);
		final report: Array<{ file: String, source: String }> = [{ file: '$root/a/b/Main.hx', source: MAIN_SOURCE }];
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope({
			declared: true,
			sources: () -> {
				report: report,
				projectRoots: [],
				library: new LibrarySources([{ file: '$root/a/F.hx', source: F_SOURCE }])
			}
		});
		// the configuration as a lint run prepares it, carrying the run's memo and so its warm servers
		final memo: OracleRunMemo = new OracleRunMemo(false, () -> ['$root/a/b/Main.hx']);
		final oracles: Array<OracleConfig> = OracleRunMemo.attach([{ hxml: 'build.hxml', dir: root, defines: [] }], memo);
		final verdict: FixVerifyResult = FixVerifier.verify(report, [new ShortenTypeRef()], plugin, oracles, File.saveContent);
		memo.servers.stop();
		final main: String = File.getContent('$root/a/b/Main.hx');
		CliFixture.removeDir(root);
		return { verdict: verdict, main: main };
	}
	#end

}

/** A verified pass's verdict and the consumer's text on disk after it. */
private typedef Verified = {
	var verdict: FixVerifyResult;
	var main: String;
}
