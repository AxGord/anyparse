package unit;

import anyparse.query.Cli;
import anyparse.query.SharedParseTier;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

/**
 * The PROCESS-scoped second tier behind `CachingGrammarPlugin`'s per-run parse caches: the
 * resolution LIBRARY (declared roots / haxelibs plus the auto-discovered Haxe std) is parsed
 * once per process instead of once per `Cli.run`. Every `Cli.run` builds a fresh
 * `CachingGrammarPlugin`, so before this tier a test suite re-parsed the 200+ std files for
 * every run that demanded a resolution index.
 *
 * What is cached is a PARSE keyed by (language, source CONTENT) — never a file SET and never a
 * report source. The three properties that follow from that are pinned here: the tier HITS
 * across runs, a `--fix` loop's rewritten report sources never enter it (the growth bound), and
 * a library path deleted and recreated with different content is re-parsed rather than served
 * stale. `testDistinctResolutionScopesDoNotCrossContaminate` guards the remaining direction —
 * one fixture's library never leaks into another's scope.
 */
class ResolutionLibraryCacheTest extends Test {

	#if (sys || nodejs)
	private static final BASE: String = 'package lib;\nclass Base {\n\tpublic function new() {}\n\tpublic function foo(): Void {}\n}';

	/** The same module WITHOUT `foo` — what the recreated library path holds on the second run. */
	private static final BASE_NO_FOO: String = 'package lib;\nclass Base {\n\tpublic function new() {}\n}';

	private static final DERIVED: String = 'package proj;\n\nimport lib.Base;\n\nclass Derived extends Base {\n\n\tpublic function new() {'
		+ '\n\t\tsuper();\n\t}\n\n\tpublic function bar():Void {\n\t\tthis.foo();\n\t}\n\n}\n';

	/**
	 * A library base whose CONTENT is unique to the serve-path test below. The tier is keyed by
	 * source content, so reusing `BASE` there would let a sibling test warm it first and leave
	 * that test's promotion count at zero — vacuously satisfying its own arithmetic.
	 */
	private static final SERVE_BASE: String =
		'package servelib;\nclass ServeBase {\n\tpublic function new() {}\n\tpublic function ping(): Void {}\n}';

	private static final SERVE_DERIVED: String = 'package proj;\n\nimport servelib.ServeBase;\n\nclass ServeDerived extends ServeBase {\n\n'
		+ '\tpublic function new() {\n\t\tsuper();\n\t}\n\n\tpublic function bar():Void {\n\t\tthis.ping();\n' + '\t}\n\n}\n';
	#end

	/**
	 * The SERVE path — the half of the tier that actually saves the work, and the half nothing
	 * used to assert. Deleting BOTH shared-tier lookups (`parseFile`'s and `spanTypeInfo`'s) once
	 * left the whole suite green while this fixture's `Cli.run` went 4.5x slower, because the hit
	 * counter lived in `SharedParseTier.promote`'s own `exists` short-circuit and so measured promotion
	 * bookkeeping rather than serving.
	 *
	 * Pinned as an exact identity on the INNER (`_inner.parseFile` / `_inner.spanTypeInfo`)
	 * counters: run 2 must inner-parse exactly what run 1 inner-parsed BESIDES the sources it
	 * promoted. Everything else run 1 paid for — the report file, and the retries of any
	 * library file that does not parse — recurs identically in run 2, so subtracting the
	 * promotion count is precisely "run 2 inner-parses ZERO library sources". A deleted serve
	 * lookup sends the whole library back through `_inner` and the identity fails by ~200.
	 */
	public function testSecondRunPerformsNoInnerParseOfLibrarySources(): Void {
		#if (sys || nodejs)
		final lib: String = CliFixture.writeDir('resservelib', [{ name: 'ServeBase.hx', source: SERVE_BASE }]);
		final proj: String = CliFixture.writeDir('resserveproj', [
			{ name: 'ServeDerived.hx', source: SERVE_DERIVED },
			{ name: 'apqlint.json', source: '{"resolutionRoots":["$lib"]}' }
		]);
		final args: Array<String> = ['lint', '--rule', 'redundant-this', '--fail-on', 'info', '$proj/ServeDerived.hx'];

		final parsesBefore: Int = SharedParseTier.innerParses;
		final spansBefore: Int = SharedParseTier.innerSpanParses;
		final promotedBefore: Int = SharedParseTier.libraryParses;
		Assert.equals(1, Cli.run(args), 'the first run resolves the library base and flags this.ping()');
		final parsesAfterFirst: Int = SharedParseTier.innerParses;
		final spansAfterFirst: Int = SharedParseTier.innerSpanParses;
		final promoted: Int = SharedParseTier.libraryParses - promotedBefore;
		Assert.isTrue(promoted > 0, 'the first run promoted at least this fixture library — the identity below is not vacuous');

		final hitsBefore: Int = SharedParseTier.libraryHits;
		final spanHitsBefore: Int = SharedParseTier.librarySpanHits;
		Assert.equals(1, Cli.run(args), 'the second run reaches the same finding');

		Assert.equals(
			parsesAfterFirst - parsesBefore - promoted, SharedParseTier.innerParses - parsesAfterFirst,
			'the second run inner-parses only what the first run parsed besides the library — zero library sources'
		);
		Assert.equals(
			spansAfterFirst - spansBefore - promoted, SharedParseTier.innerSpanParses - spansAfterFirst,
			'the same for span info — the second run span-parses zero library sources'
		);
		Assert.isTrue(
			SharedParseTier.libraryHits - hitsBefore >= promoted, 'every promoted parse was SERVED from the tier in the second run'
		);
		Assert.isTrue(SharedParseTier.librarySpanHits - spanHitsBefore >= promoted, 'the span half of the tier served the second run too');

		CliFixture.removeDir(proj);
		CliFixture.removeDir(lib);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Two `Cli.run` calls over the SAME resolution scope in one process parse the library once:
	 * the second run re-parses nothing and is served entirely from the shared tier. Asserted on
	 * the counters, not on wall clock — and as a DELTA around the second run, so an earlier test
	 * having already warmed the std entries cannot make it vacuous.
	 */
	public function testLibraryParseIsSharedAcrossRuns(): Void {
		#if (sys || nodejs)
		final lib: String = CliFixture.writeDir('rescachelib', [{ name: 'Base.hx', source: BASE }]);
		final proj: String = CliFixture.writeDir('rescacheproj', [
			{ name: 'Derived.hx', source: DERIVED },
			{ name: 'apqlint.json', source: '{"resolutionRoots":["$lib"]}' }
		]);
		final args: Array<String> = ['lint', '--rule', 'redundant-this', '--fail-on', 'info', '$proj/Derived.hx'];

		Assert.equals(1, Cli.run(args), 'the first run resolves the library base and flags this.foo()');
		final parsesAfterFirst: Int = SharedParseTier.libraryParses;
		final hitsAfterFirst: Int = SharedParseTier.libraryHits;

		Assert.equals(1, Cli.run(args), 'the second run reaches the same finding');
		Assert.equals(parsesAfterFirst, SharedParseTier.libraryParses, 'the second run re-parses no library source');
		Assert.isTrue(SharedParseTier.libraryHits > hitsAfterFirst, 'the second run is served from the process-scoped tier');

		CliFixture.removeDir(proj);
		CliFixture.removeDir(lib);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The GROWTH bound: a `--fix` loop produces a fresh source string per pass per edited file,
	 * and none of them may be retained. With the library already warmed by a preceding report
	 * run, a `--fix` run over the same scope adds ZERO entries — every pass's rewritten report
	 * source stays out of the tier, which is what keeps it bounded by the (immutable) library.
	 */
	public function testReportSourcesNeverEnterTheSharedTier(): Void {
		#if (sys || nodejs)
		final lib: String = CliFixture.writeDir('resgrowlib', [{ name: 'Base.hx', source: BASE }]);
		final proj: String = CliFixture.writeDir('resgrowproj', [
			{ name: 'Derived.hx', source: DERIVED },
			{ name: 'apqlint.json', source: '{"resolutionRoots":["$lib"]}' }
		]);
		Assert.equals(0, Cli.run(['lint', '--rule', 'redundant-this', '$proj/Derived.hx']), 'the warming report run succeeds');
		final parsesWarm: Int = SharedParseTier.libraryParses;

		Assert.equals(0, Cli.run(['lint', '--fix', '--rule', 'redundant-this', '$proj/Derived.hx']), 'the fix run succeeds');
		Assert.isTrue(File.getContent('$proj/Derived.hx').indexOf('this.foo()') == -1, 'the fix actually rewrote the report file');
		Assert.equals(parsesWarm, SharedParseTier.libraryParses, 'no pass of the fix loop added a report source to the shared tier');

		CliFixture.removeDir(proj);
		CliFixture.removeDir(lib);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * STALENESS: the library directory is deleted and recreated at the SAME path with the base's
	 * `foo` removed. The second run must see the NEW content — a tier keyed by path (or by
	 * anything else that survives a content change) would serve the first run's tree and keep
	 * flagging an inherited member that no longer exists.
	 */
	public function testRecreatedLibraryPathWithNewContentIsNotServedStale(): Void {
		#if (sys || nodejs)
		final lib: String = CliFixture.writeDir('resstalelib', [{ name: 'Base.hx', source: BASE }]);
		final proj: String = CliFixture.writeDir('resstaleproj', [
			{ name: 'Derived.hx', source: DERIVED },
			{ name: 'apqlint.json', source: '{"resolutionRoots":["$lib"]}' }
		]);
		final args: Array<String> = ['lint', '--rule', 'redundant-this', '--fail-on', 'info', '$proj/Derived.hx'];
		Assert.equals(1, Cli.run(args), 'the base declaring foo makes this.foo() a finding');

		CliFixture.removeDir(lib);
		FileSystem.createDirectory(lib);
		File.saveContent('$lib/Base.hx', BASE_NO_FOO);
		Assert.equals(0, Cli.run(args), 'the recreated base without foo is re-parsed — the finding is gone, not served stale');

		CliFixture.removeDir(proj);
		CliFixture.removeDir(lib);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * ISOLATION: two runs in one process configure DIFFERENT resolution scopes. The second
	 * declares a library that does not contain `lib.Base` at all, so its identical report file
	 * must stay a conservative miss — one fixture never sees another's library. The file SET is
	 * re-expanded per run and never cached, so this holds by construction; the test is the
	 * standing guard on that.
	 */
	public function testDistinctResolutionScopesDoNotCrossContaminate(): Void {
		#if (sys || nodejs)
		final libWithBase: String = CliFixture.writeDir('resisoa', [{ name: 'Base.hx', source: BASE }]);
		final libWithoutBase: String = CliFixture.writeDir('resisob', [
			{ name: 'Other.hx', source: 'package lib;\nclass Other {\n\tpublic function new() {}\n}' }
		]);
		final projA: String = CliFixture.writeDir('resisoproja', [
			{ name: 'Derived.hx', source: DERIVED },
			{ name: 'apqlint.json', source: '{"resolutionRoots":["$libWithBase"]}' }
		]);
		final projB: String = CliFixture.writeDir('resisoprojb', [
			{ name: 'Derived.hx', source: DERIVED },
			{ name: 'apqlint.json', source: '{"resolutionRoots":["$libWithoutBase"]}' }
		]);

		Assert.equals(
			1, Cli.run(['lint', '--rule', 'redundant-this', '--fail-on', 'info', '$projA/Derived.hx']),
			'the scope declaring the base resolves the inherited foo'
		);
		Assert.equals(
			0, Cli.run(['lint', '--rule', 'redundant-this', '--fail-on', 'info', '$projB/Derived.hx']),
			'a different scope without the base stays a conservative miss — no cross-run leak'
		);

		CliFixture.removeDir(projB);
		CliFixture.removeDir(projA);
		CliFixture.removeDir(libWithoutBase);
		CliFixture.removeDir(libWithBase);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
