package unit.check.oracle;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.facts.TypedFactsProbe;
import anyparse.check.oracle.CompilerOracle;
import anyparse.check.oracle.OracleCoverage;
import anyparse.check.oracle.OracleRunMemo;
import anyparse.check.oracle.ReachDefinesProbe;
import anyparse.macro.EmbeddedSource;
import anyparse.query.CompilerFacts;
import anyparse.query.ReachLiveness.ReachConfiguration;

/**
 * In a run whose memo reads sources, the facts compile carries the define probe (`ReachDefinesProbe.ProbeRider`): ONE
 * compile per configuration answers the facts, the `-v` baseline and the builds, each as its own compile answers it.
 * When the hook's define may be read, a module the hook shadows holds other text, or the build has several arms, that
 * compile answers the facts alone, and the baseline and the builds take compiles of their own.
 *
 * Every fixture counts COMPILES: its hxml runs an init macro (`CompileCounter`) once per compile arm.
 */
@:nullSafety(Strict)
final class RiddenProbeTest extends Test {

	#if (sys || nodejs)
	private static final MAIN: String = 'class Main {\n\tstatic inline function size(a:Array<Int>):Int {\n\t\treturn a.length;\n\t}\n\n'
		+ '\tstatic function main() {\n\t\ttrace(size([Std.random(3)]));\n\t}\n}\n';
	private static final READER: String =
		'class Main {\n\tstatic function main() {\n\t\t#if keep_inline_positions\n\t\ttrace(1);\n\t\t#end\n\t}\n}\n';
	private static final SHADOWED: String =
		'class Main {\n\tstatic function main() {\n\t\ttrace(anyparse.query.FileIdentity.same(\'a\', \'b\'));\n\t}\n}\n';
	private static final BUILD: String = '-cp .\n-main Main\n--interp\n${CompileCounter.MACRO}';
	private static final IDENTITY: String = 'anyparse/query/FileIdentity.hx';
	#end

	@:pin('control')
	@:killer('M-RIDDEN-KEEPS-HOOK-LOADS')
	@:killer('M-RIDDEN-NO-HOOK-DEFINES')
	public function testOneCompileAnswersTheFactsTheBaselineAndTheBuilds(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(MAIN);
		if (dir == null) return;
		final oracles: Array<OracleConfig> = ridden(dir);
		final facts: Null<CompilerFacts> = TypedFactsProbe.probeAll(oracles);
		Assert.equals(1, facts?.configurations.length, 'the facts answered');
		Assert.equals(1, CompileCounter.count(dir), 'from one compile');
		final carried: Null<ReachConfiguration> = ReachDefinesProbe.probeAll(oracles)?.configurations[0];
		Assert.isTrue(CompilerOracle.judging(oracles).verdict.match(Confirmed), 'the baseline confirms');
		Assert.isTrue(OracleCoverage.probeAll(oracles)[0].covers('$dir/Main.hx'), 'the coverage reads the same compile');
		Assert.equals(1, CompileCounter.count(dir), 'which answered the builds, the baseline and the coverage as well');
		sameBuild(ReachDefinesProbe.probeAll(plain(dir))?.configurations[0], carried, dir);
		// the hook's define comes from a macro after `early`, and types as `-D` does: an inlined body keeps the callee's range
		final shared: Array<String> = factsIn(facts, dir);
		Assert.isTrue(shared.length > 0, 'the facts hold the fixture');
		Assert.same(factsIn(TypedFactsProbe.probeAll(plain(dir)), dir), shared, 'the facts the plain facts compile types');
		Assert.same([MAIN.indexOf('a.length')], [
			for (f in facts?.node('Main.main')?.fields ?? []) if (f.field == 'length') f.at.span.from
		], 'the inlined body keeps the callee\'s range');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-DEFINE-READS-NONE')
	public function testABuildReadingTheHooksDefineIsCompiledApart(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(READER);
		if (dir == null) return;
		final oracles: Array<OracleConfig> = ridden(dir);
		Assert.equals(1, TypedFactsProbe.probeAll(oracles)?.configurations.length, 'the facts answered');
		final builds: Null<ReachConfiguration> = ReachDefinesProbe.probeAll(oracles)?.configurations[0];
		Assert.equals(2, CompileCounter.count(dir), 'the builds took a compile of their own');
		Assert.isFalse(builds?.everDefined.contains('keep_inline_positions') ?? true, 'under the build\'s own defines');
		Assert.isTrue(CompilerOracle.judging(oracles).verdict.match(Confirmed), 'the baseline confirms');
		Assert.equals(3, CompileCounter.count(dir), 'from a compile of its own as well');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-RIDDEN-NO-RERUN')
	public function testTheFactsOfABuildOfSeveralArmsAreCompiledApart(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(MAIN, '$BUILD--next\n$BUILD');
		if (dir == null) return;
		final oracles: Array<OracleConfig> = ridden(dir);
		Assert.equals(1, TypedFactsProbe.probeAll(oracles)?.configurations.length, 'the facts answered');
		Assert.equals(4, CompileCounter.count(dir), 'the plain facts compile ran after the shared one, both of two arms');
		Assert.isNull(ReachDefinesProbe.probeAll(oracles), 'and no build of several arms answers');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('guard')
	public function testAModuleTheHookShadowsIsReadWhereTheBuildFindsIt(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(SHADOWED);
		if (dir == null) return;
		final oracles: Array<OracleConfig> = ridden(dir);
		Assert.equals(1, TypedFactsProbe.probeAll(oracles)?.configurations.length, 'the facts answered');
		final carried: Null<ReachConfiguration> = ReachDefinesProbe.probeAll(oracles)?.configurations[0];
		Assert.equals(1, CompileCounter.count(dir), 'the builds came from the shared compile');
		sameBuild(ReachDefinesProbe.probeAll(plain(dir))?.configurations[0], carried, dir);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-RIDDEN-SHADOW-UNCHECKED')
	public function testAShadowedModuleOfOtherTextIsCompiledApart(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(SHADOWED, BUILD, '\n// the project\'s own copy\n');
		if (dir == null) return;
		final oracles: Array<OracleConfig> = ridden(dir);
		Assert.equals(1, TypedFactsProbe.probeAll(oracles)?.configurations.length, 'the facts answered');
		Assert.notNull(ReachDefinesProbe.probeAll(oracles), 'the builds answered');
		Assert.equals(2, CompileCounter.count(dir), 'from a compile of their own');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A build the shared compile reported while the tree changed is not filed: the tree it read is not the one its
	 * fingerprint names, so even once the tree is back at that content the builds take a compile of their own.
	 */
	@:pin('control')
	@:killer('M-RUNMEMO-BUILD-UNGUARDED')
	public function testABuildCompiledWhileTheTreeChangedIsNotFiled(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(MAIN);
		if (dir == null) return;
		final oracles: Array<OracleConfig> = ridden(dir);
		final probe: FactsProbe = TypedFactsProbe.start(oracles);
		sys.io.File.saveContent('$dir/Main.hx', '${MAIN}\nclass Extra {}\n');
		Assert.equals(1, TypedFactsProbe.finish(probe)?.configurations.length, 'the facts answered');
		sys.io.File.saveContent('$dir/Main.hx', MAIN);
		Assert.isTrue(CompilerOracle.judging(oracles).verdict.match(Confirmed), 'the baseline of the tree back as it was confirms');
		Assert.equals(2, CompileCounter.count(dir), 'from a compile of its own');
		Assert.notNull(ReachDefinesProbe.probeAll(oracles), 'the builds answered');
		Assert.equals(3, CompileCounter.count(dir), 'from a compile of their own, not from the build the shared compile reported');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * What the shared compile reported for the build is what its own compile reports: every define set and value, the
	 * types and files it typed, and the fixture's files it parsed — the hook loads library files of its own.
	 */
	private static function sameBuild(apart: Null<ReachConfiguration>, carried: Null<ReachConfiguration>, dir: String): Void {
		Assert.notNull(apart);
		Assert.notNull(carried);
		if (apart == null || carried == null) return;
		Assert.same(apart.defined, carried.defined);
		Assert.same(apart.everDefined, carried.everDefined);
		Assert.same([for (k => v in apart.values) '$k=$v'], [for (k => v in carried.values) '$k=$v']);
		Assert.same(apart.compiled, carried.compiled);
		Assert.same([for (t in apart.types) '${t.name} ${t.file}'], [for (t in carried.types) '${t.name} ${t.file}']);
		final own: String = haxe.io.Path.withoutDirectory(dir);
		Assert.same(
			[for (p in apart.parsed ?? []) if (p.indexOf(own) >= 0) p],
			[for (p in carried.parsed ?? []) if (p.indexOf(own) >= 0) p]
		);
	}
	/** Every node the compile typed in the fixture's `Main.hx`, with each call and field access it holds and their ranges. */
	private static function factsIn(facts: Null<CompilerFacts>, dir: String): Array<String> {
		return [
			for (node in facts?.nodesIn('$dir/Main.hx') ?? []) {
				final calls: Array<String> = [
					for (c in node.calls) '${c.target} ${c.access} ${c.result} ${c.at.span.from}-${c.at.span.to}'
				];
				final fields: Array<String> = [
					for (f in node.fields) '${f.field} ${f.access} ${f.type} ${f.at.span.from}-${f.at.span.to}'
				];
				[
					node.id,
					node.signature,
					'${node.at.span.from}-${node.at.span.to}',
					calls.join(', '),
					fields.join(', ')
				].join(' | ');
			}
		];
	}

	/**
	 * A fixture of `main` built by `build`, with the engine's copy of the module the hook shadows beside it when `main`
	 * names it — `edit` appended to it — or null (the test passed) when no compiler is available.
	 */
	private static function scratch(main: String, ?build: String, edit: String = ''): Null<String> {
		final dir: String = CliFixture.writeDir('ridden', [
			{ name: 'Main.hx', source: main },
			{ name: 'Counter.hx', source: CompileCounter.SOURCE },
			{ name: 'build.hxml', source: build ?? BUILD }
		]);
		if (main == SHADOWED) {
			sys.FileSystem.createDirectory('$dir/${haxe.io.Path.directory(IDENTITY)}');
			sys.io.File.saveContent('$dir/$IDENTITY', EmbeddedSource.text('anyparse/query/FileIdentity.hx') + edit);
		}
		final works: Bool = CompilerOracle.typecheck('build.hxml', dir).match(Confirmed);
		if (sys.FileSystem.exists('$dir/compiles.log')) sys.FileSystem.deleteFile('$dir/compiles.log');
		if (works) return dir;
		CliFixture.removeDir(dir);
		Assert.pass('haxe unavailable — skipped');
		return null;
	}

	/** The configuration of `dir` in a lint run's memo, which reads sources and so carries the probe. */
	private static function ridden(dir: String): Array<OracleConfig> {
		return OracleRunMemo.attach(plain(dir), new OracleRunMemo(false, () -> ['$dir/Main.hx'], new HaxeQueryPlugin()));
	}

	/** The configuration of `dir` outside any run: every probe compiles on its own. */
	private static function plain(dir: String): Array<OracleConfig> {
		return [{ hxml: 'build.hxml', dir: dir, defines: [] }];
	}
	#end

}
