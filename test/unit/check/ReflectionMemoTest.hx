package unit.check;

import anyparse.check.ReflectionScan;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import utest.Assert;
import utest.Test;

/**
 * The LIFETIME half of the reflection gate — `LintScopeGateTest` pins how WIDE the scan's scope
 * is, this one pins that memoising the answer cannot change it.
 *
 * The surface is one walk of every file in that scope, five registered checks demand it per run,
 * and each used to recompute the whole thing (measured on Pony, 680 report files against a
 * resolution scope of 2764: ~0.12s per repeat demand, 0.57s of an 18s `lint src`). The memo that
 * ends the repeat has exactly one way to be wrong, and it is the silent one: answering about the
 * text of an EARLIER `--fix` pass. A pass rewrites a report entry's `source` in place, so a name a
 * pass has just written into a `Reflect.field(o, 'NAME')` must veto the next rewrite of `NAME`, and
 * a memo that missed it would license a rewrite that compiles and fails at run time — the same
 * class of defect the scan's scope width exists to prevent.
 *
 * So `ReflectionMemo` is VALIDATED rather than expired: it keeps the source string of every scope
 * entry it read and answers only while that list still matches. The two cells below are the two
 * ways that can be wrong — the memo not being consulted at all, and it being consulted when the
 * sources have moved — and each has its own arm.
 */
@:nullSafety(Strict)
class ReflectionMemoTest extends Test {

	/** A scope file naming no type at run time. */
	private static inline final PLAIN: String = 'package pkg;\n\nclass Use {\n\tpublic static function m():Int {\n\t\treturn 1;\n\t}\n}';

	/** The same file after a rewrite that puts a runtime type path into it. */
	private static inline final REFLECTS: String =
		'package pkg;\n\nclass Use {\n\tpublic static function m():Dynamic {\n\t\treturn Type.resolveClass(\'pkg.Align\');\n\t}\n}';

	public function new(): Void {
		super();
	}

	/**
	 * A second demand over unchanged sources is answered from the memo — the whole point of it, and
	 * the assertion that stops the staleness cell below passing vacuously on a memo nothing fills.
	 */
	@:pin('control')
	@:killer('M-REFLECTION-MEMO-DEAD')
	public function testTheSurfaceIsMemoisedWithinARun(): Void {
		final report: Array<ScopeFile> = [{ file: 'pkg/Use.hx', source: REFLECTS }];
		final plugin: CachingGrammarPlugin = scoped(report);
		final first: ReflectionSurface = ReflectionScan.reflectionSurface(report, plugin);
		// Leading assertion: the surface really carries something, so the identity below is a memo
		// rather than two empty answers.
		Assert.isTrue(ReflectionScan.runtimeTypePath(first.whole, 'Align'), 'the literal is in the surface at all');
		Assert.isTrue(first == ReflectionScan.reflectionSurface(report, plugin), 'the second demand returns the SAME surface');
	}

	/**
	 * ...and a scope file rewritten since — the shape every `--fix` pass writes, in place, into the
	 * very entry the scan holds — is re-read. A memo answering the previous pass's text here would
	 * let the next rewrite orphan the reflective read the pass had just introduced.
	 */
	@:pin('control')
	@:killer('M-REFLECTION-MEMO-STALE')
	public function testARewrittenScopeFileIsReRead(): Void {
		final report: Array<ScopeFile> = [{ file: 'pkg/Use.hx', source: PLAIN }];
		final plugin: CachingGrammarPlugin = scoped(report);
		Assert.isFalse(
			ReflectionScan.runtimeTypePath(ReflectionScan.reflectionSurface(report, plugin).whole, 'Align'),
			'nothing reaches the type before the rewrite'
		);
		report[0].source = REFLECTS;
		Assert.isTrue(
			ReflectionScan.runtimeTypePath(ReflectionScan.reflectionSurface(report, plugin).whole, 'Align'),
			'the rewritten source reaches the type'
		);
	}

	/**
	 * Two different scopes through ONE plugin answer separately. The cross-CALLER witness of the
	 * same cut the cell above pins across passes: `check/Naming` hands this scan a set built from
	 * the pass index while the five whole-scope checks hand it the report array, so both shapes
	 * reach one memo within a single run — and both sets here hold ONE file, so a memo validating
	 * only its LENGTH answers the second from the first.
	 */
	@:pin('control')
	@:killer('M-REFLECTION-MEMO-STALE')
	public function testASecondScopeIsNotAnsweredFromTheFirst(): Void {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final reflecting: Array<ScopeFile> = [{ file: 'pkg/Use.hx', source: REFLECTS }];
		final plain: Array<ScopeFile> = [{ file: 'pkg/Other.hx', source: PLAIN }];
		Assert.isTrue(
			ReflectionScan.runtimeTypePath(ReflectionScan.reflectionSurface(reflecting, plugin).whole, 'Align'),
			'the first scope reaches the type'
		);
		Assert.isFalse(
			ReflectionScan.runtimeTypePath(ReflectionScan.reflectionSurface(plain, plugin).whole, 'Align'), 'the second scope does not'
		);
	}

	/**
	 * A plugin hosting no memo answers the same, recollecting each time. The unit tests that hold a
	 * bare grammar plugin take this path, so it is what keeps the memo from being load-bearing for
	 * anything but speed.
	 */
	public function testAPluginWithNoMemoStillAnswers(): Void {
		final report: Array<ScopeFile> = [{ file: 'pkg/Use.hx', source: REFLECTS }];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.isTrue(ReflectionScan.runtimeTypePath(ReflectionScan.reflectionSurface(report, plugin).whole, 'Align'));
	}

	/**
	 * The scope's report half is `report` itself — the same array instance, as it is under `Cli`, so a
	 * rewrite of an entry reaches the resolution view too and the cells above vary only the source.
	 */
	private function scoped(report: Array<ScopeFile>): CachingGrammarPlugin {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope({ declared: true, sources: () -> {report: report, projectRoots: [], library: new LibrarySources([]) } });
		return plugin;
	}

}
