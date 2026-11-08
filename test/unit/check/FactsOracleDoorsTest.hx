package unit.check;

import anyparse.check.Check.OracleType;
import anyparse.check.Check.TypeOracle;
import anyparse.check.FactsOracle;
import anyparse.grammar.json.JsonQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CompilerFacts;
import anyparse.query.EditJournal;
import anyparse.query.OracleProvider;
import anyparse.query.OracleProviders;
import anyparse.runtime.Span;

/**
 * The doors a check reaches a run's compiler facts through: `OracleProvider.factsForFix`, `factsForFixRun` and
 * `factsForFiles` answer from the grammar's compiler on the run's complete facts, and a grammar that supplies no compiler
 * answers none.
 */
@:nullSafety(Strict)
class FactsOracleDoorsTest extends Test {

	private static final FILE: String = 'A.hx';
	private static final SRC: String = 'class A {\n\tfunction f(p) {\n\t\tvar v = g();\n\t}\n}\n';

	/** The Haxe grammar hands a fix the run's facts as an oracle. */
	@:pin('control')
	@:killer('M-HAXE-FACTS-FOR-FIX')
	public function testAFixOnTheHaxeGrammarIsAskedThroughTheRunsFacts(): Void {
		final plugin: CachingGrammarPlugin = hostWith(completeFacts());
		Assert.notNull(OracleProviders.of(plugin).factsForFix(plugin, FILE, SRC));
	}

	/** A run that records no edits gives the fix-run door no oracle, whatever facts it holds. */
	@:pin('control')
	@:killer('M-HAXE-FACTS-FIX-RUN')
	public function testTheFixRunDoorAnswersOnlyInsideARunRecordingItsEdits(): Void {
		final plugin: CachingGrammarPlugin = hostWith(completeFacts());
		Assert.isNull(OracleProviders.of(plugin).factsForFixRun(plugin, FILE, SRC));
		plugin.editJournal = new EditJournal();
		Assert.notNull(OracleProviders.of(plugin).factsForFixRun(plugin, FILE, SRC));
	}

	/** The assisted door reads a file of its list as it is now; any other file the run compiled goes to the fallback. */
	@:pin('control')
	@:killer('M-HAXE-FACTS-FOR-FILES') @:killer('M-FACTS-FILES-CURRENT') @:killer('M-FACTS-FILES-FALLBACK')
	public function testTheAssistedDoorReadsItsFilesAndFallsBackForAnyOther(): Void {
		final plugin: CachingGrammarPlugin = hostWith(completeFacts());
		final provider: OracleProvider = OracleProviders.of(plugin);
		var fallbacks: Int = 0;
		final fallback: () -> Null<TypeOracle> = () -> {
			fallbacks++;
			return null;
		};
		final listed: Null<FactsOracle> = provider.factsForFiles(plugin, [{ file: FILE, source: SRC }], fallback);
		final unlisted: Null<FactsOracle> = provider.factsForFiles(plugin, [], fallback);
		if (listed == null || unlisted == null) {
			Assert.fail('the run holds complete facts');
			return;
		}
		Assert.same(Typed('Int'), localOf(listed));
		Assert.equals(0, fallbacks, 'a listed file is answered by the facts');
		Assert.isTrue(localOf(unlisted).match(Declined(_)), 'the fallback here answers nothing');
		Assert.equals(1, fallbacks, 'a file outside the list asks the fallback');
	}

	/** A run with no facts offers no oracle. */
	@:pin('guard')
	public function testARunWithoutFactsAnswersNothing(): Void {
		final plugin: CachingGrammarPlugin = hostWith(null);
		Assert.isNull(OracleProviders.of(plugin).factsForFix(plugin, FILE, SRC));
	}

	/** A grammar without a compiler offers no facts, even over a run scope that names some. */
	@:pin('guard')
	public function testAGrammarWithoutACompilerOffersNoFacts(): Void {
		final plugin: CachingGrammarPlugin = hostOver(new CachingGrammarPlugin(new JsonQueryPlugin()), completeFacts());
		final provider: OracleProvider = OracleProviders.of(plugin);
		Assert.isNull(provider.factsForFix(plugin, FILE, SRC));
		Assert.isNull(provider.factsForFixRun(plugin, FILE, SRC));
		Assert.isNull(provider.factsForFiles(plugin, [{ file: FILE, source: SRC }], () -> null));
	}

	private static function completeFacts(): CompilerFacts {
		final fnFrom: Int = SRC.indexOf('(p)');
		final fnTo: Int = SRC.indexOf('\t}\n}') + 2;
		final varFrom: Int = SRC.indexOf('var v');
		final varTo: Int = SRC.indexOf('g();\n\t}') + 3;
		final dump: String = '{"k":"facts","v":1,"inline":true}\n{"k":"type","id":"A","f":"$FILE","p":[0,${SRC.length}'
			+ '],"kind":"class","pack":"","params":[],"fields":[]}\n{"k":"node","id":"A.f","f":"$FILE","p":[$fnFrom,$fnTo'
			+ '],"kind":"method","owner":"A","t":"(?Null<Int>)->Void","params":[{"n":"p","t":"Null<Int>"}],"vars":[{"n":"v","t":"Int","p":['
			+ '$varFrom,$varTo]}]}\n{"k":"end","nodes":1,"types":1}\n';
		return CompilerFacts.build([{ name: 'one', text: dump, file: path -> path }], file -> file == FILE ? SRC : null, file -> file);
	}

	private static function hostWith(facts: Null<CompilerFacts>): CachingGrammarPlugin {
		return hostOver(new CachingGrammarPlugin(new HaxeQueryPlugin()), facts);
	}

	private static function hostOver(plugin: CachingGrammarPlugin, facts: Null<CompilerFacts>): CachingGrammarPlugin {
		plugin.setResolutionScope({
			declared: true,
			sources: () -> {
				report: [{ file: FILE, source: SRC }],
				projectRoots: [],
				library: new LibrarySources([]),
				rootsMatched: true,
				rootsAllMatched: true
			},
			facts: () -> facts
		});
		return plugin;
	}

	/** What `oracle` answers for the local of the fixture's function. */
	private static function localOf(oracle: FactsOracle): OracleType {
		return oracle.localType(FILE, new Span(SRC.indexOf('var v'), SRC.indexOf('g();\n\t}') + 4), 'v', SRC.indexOf('var v') + 5);
	}

}
