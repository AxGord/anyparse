package unit.query;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.grammar.haxe.HaxeLexicalRegions;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `GrammarPlugin.lexicalRegions` — the seam that moved one grammar's LEXER out of the engine.
 *
 * `anyparse.query.LexicalRegions` held a full Haxe lexer: single-quote interpolation, `${ … }`
 * holes, `~/ … /` literals, `//` and block comments. A grammar-agnostic package deciding what
 * a comment is for every language is invariant 4 in reverse — a second grammar could not answer
 * the question without editing core code — and the debt stayed invisible because the only
 * grammar that ever asked was Haxe.
 *
 * RED AT BASE, and by the seam itself: `plugin.lexicalRegions(source)` does not compile at
 * `3d5bf593`, so the whole class fails to build there rather than failing an assertion. The
 * behaviour half is a characterization pin — the answers must be byte-identical to what the
 * old `LexicalRegions.scan` gave, which `testForwarderAgreesWithTheSeam` states directly and
 * the corpus sweep confirms wholesale.
 */
class LexicalRegionsSeamTest extends Test {

	/** Comment, interpolating literal with a nested same-quote hole, and a regex holding an opener. */
	private static final SOURCE: String = "// note\nvar s = '${c ? '// inner' : x}';\nvar r = ~/[\\/*]/;\n";

	/** The package prefix no grammar-agnostic module may name outside the allow-list. */
	private static final GRAMMAR_PATH: String = 'anyparse.grammar.haxe.';

	/** The two packages that ARE the engine — the five-pass build macro and the IR it walks. */
	private static final ENGINE_DIRS: Array<String> = ['src/anyparse/core', 'src/anyparse/macro'];

	/** The Haxe grammar package: one module per rule type, so the FILE NAMES are the inventory. */
	private static final HAXE_GRAMMAR_DIR: String = 'src/anyparse/grammar/haxe';

	/** The seam answers the Haxe regions — the scan that used to sit in the engine, asked of the grammar. */
	public function testPluginAnswersTheHaxeRegions(): Void {
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final regions: Array<LexRegion> = plugin.lexicalRegions(SOURCE);
		Assert.equals(3, regions.length, 'comment, literal and regex: ${dump(regions)}');
		Assert.equals('// note', SOURCE.substring(regions[0].from, regions[0].to));
		Assert.equals(LexRegionKind.LineComment, regions[0].kind);
		Assert.equals("'${c ? '// inner' : x}'", SOURCE.substring(regions[1].from, regions[1].to), 'the hole stays inside ONE region');
		Assert.equals(LexRegionKind.StringLit, regions[1].kind);
		Assert.equals('~/[\\/*]/', SOURCE.substring(regions[2].from, regions[2].to), 'and the regex opens no comment');
		Assert.equals(LexRegionKind.RegexLit, regions[2].kind);
	}

	/**
	 * The move is behaviour-preserving: the grammar implementation and the seam answer the same
	 * thing. The deprecated `LexicalRegions` forwarder this used to compare against as well is
	 * gone since S60 — every consumer now reaches the scan through the plugin — so what remains
	 * is the arm that would go red if `HaxeQueryPlugin.lexicalRegions` ever stopped delegating.
	 */
	public function testGrammarImplementationAgreesWithTheSeam(): Void {
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final seam: String = text(SOURCE, plugin.lexicalRegions(SOURCE));
		Assert.equals(text(SOURCE, HaxeLexicalRegions.scan(SOURCE)), seam, 'seam == grammar implementation');
	}

	/**
	 * The caching wrapper passes the seam STRAIGHT THROUGH and memoises nothing — two different
	 * sources through one wrapper each get their own answer, and a source asked twice is
	 * re-lexed rather than served from a map that would live as long as the run.
	 *
	 * Deliberate, not an omission: the scan is 2.7 % of a full `lint --all --fix` over 869 files
	 * (`--cpu-prof`), against a parse that is demanded once per CHECK. A cache added on
	 * speculation is exactly the process-lifetime state invariant 1 is about, even when it is
	 * instance-scoped.
	 */
	public function testCachingWrapperPassesThrough(): Void {
		final plain: String = "var t = 'plain';\n";
		final wrapper: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final first: String = text(SOURCE, wrapper.lexicalRegions(SOURCE));
		final other: String = text(plain, wrapper.lexicalRegions(plain));
		Assert.equals(text(SOURCE, new HaxeQueryPlugin().lexicalRegions(SOURCE)), first, 'the wrapper answers what the inner grammar does');
		Assert.equals("'plain'", other, 'a second, different source is not served the first answer');
		Assert.equals(first, text(SOURCE, wrapper.lexicalRegions(SOURCE)), 'and the first source still answers the same');
	}

	/** The region texts joined, so a failure says what was actually scanned. */
	private function text(source: String, regions: Array<LexRegion>): String {
		return [for (region in regions) source.substring(region.from, region.to)].join(' | ');
	}

	/** Region bounds and kinds, for a length assertion that would otherwise say only a number. */
	private function dump(regions: Array<LexRegion>): String {
		return [for (region in regions) '[${region.from},${region.to})'].join(' ');
	}

	/**
	 * THE ACCEPTANCE PIN, in the "shrinkage IS the test" shape: the grammar-agnostic packages
	 * `anyparse.query`, `anyparse.check` and `anyparse.format` may name `anyparse.grammar.haxe.*`
	 * in EXACTLY two modules, and this asserts the list rather than a count.
	 *
	 *  - `query/Cli.hx` — `pickPlugin` maps `--lang haxe` to `HaxeQueryPlugin`. Something has to
	 *    know one concrete grammar for the CLI to have a default, and this is the one place that
	 *    does; every other module receives the plugin it was handed.
	 *  - `query/FormatConfigDiscovery.hx` — `HaxeFormatConfigDiagnostics` names the `hxformat.json`
	 *    keys this engine does not implement, which is a fact about the HAXE formatter's config
	 *    schema and cannot be derived from a grammar-agnostic seam.
	 *
	 * Everything else must reach a grammar through `GrammarPlugin`. Before S60 the exception was
	 * `LexicalRegions.scan` / `skipStringLiteral`, a deprecated forwarder that hardcoded the Haxe
	 * lexer for 65 `collectCommentTokens` call sites — the path that gates every DELETE in the
	 * tool. Both are gone; this test is what stops the next one being added quietly.
	 *
	 * `anyparse.format` contributes NO entry, and that is a measured fact rather than an empty
	 * slot: its debt was never an import but a Haxe state machine written out INLINE — the
	 * `'…'` interpolation / `$$` / `~/…/` lexer `CommentInventory` carried for the writer's
	 * comment-loss guard, now `HaxeLexicalRegions.scanComments` behind the `CommentScan` seam.
	 * A name-based scan could not have seen that, so this arm is a RATCHET on the shape the
	 * fix left behind, and `unit.format.CommentInventoryTest.testTheAuditFollowsTheScanItIsHanded` is
	 * the arm that would catch the lexer coming back.
	 *
	 * Occurrences inside a COMMENT or a STRING do not count, and the masking is done with the very
	 * seam under test (`plugin.lexicalRegions` + `LexicalRegions.regionAt`) — this file's own class
	 * doc names `anyparse.grammar.haxe` in prose, and so does `LexicalRegions`'s.
	 */
	#if (sys || nodejs)
	public function testNoGrammarAgnosticModuleReachesTheHaxeGrammar(): Void {
		final allowed: Array<String> = ['src/anyparse/query/Cli.hx', 'src/anyparse/query/FormatConfigDiscovery.hx'];
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final found: Array<String> = [];
		for (dir in ['src/anyparse/check', 'src/anyparse/format', 'src/anyparse/query']) for (path in hxFilesUnder(dir)) {
			final source: String = File.getContent(path);
			final regions: Array<LexRegion> = plugin.lexicalRegions(source);
			var at: Int = source.indexOf(GRAMMAR_PATH);
			while (at >= 0) {
				if (LexicalRegions.regionAt(at, regions) == null) {
					found.push(path);
					break;
				}
				at = source.indexOf(GRAMMAR_PATH, at + 1);
			}
		}
		found.sort(Reflect.compare);
		Assert.equals(allowed.join('\n'), found.join('\n'), 'the allow-list is the whole story — a new one is a forwarder');
	}

	/**
	 * The ENGINE — `anyparse.core` and the five-pass build macro — names no rule
	 * type of any one grammar. Invariant 4 stated where it is most load-bearing:
	 * a `@:fmt` feature whose lowering spells a grammar's own type is a feature
	 * only that grammar can ever opt into, and nothing but a reader noticing
	 * stood between the macro and the next one.
	 *
	 * RED AT BASE `3977e25e` with EIGHT hits from two mechanisms. Six sat in
	 * `WriterLowering.buildFnBodyEmptyCheck`, which dispatched on the literal
	 * strings `HxFnBody` / `HxFnBodyT` / `HxFnExprBody` / `HxFnExprBodyT` to pick
	 * which set of BODY CTORS to emit, and named two of them again in its
	 * `fatalError` text. The other two emitted a direct call to
	 * `anyparse.grammar.haxe.HxComplexItems.kinds` — one in `WriterLowering`, one
	 * in `TriviaSepLowering`, the plain and trivia halves of one flag.
	 *
	 * The inventory is DERIVED, not listed: the Haxe grammar is one module per
	 * rule type, so the `Hx…` file names under `HAXE_GRAMMAR_DIR` are exactly the
	 * names in question, and adding a rule extends the pin for free. A trailing
	 * `T` / `S` is stripped before the membership test because the macro
	 * addresses the `TriviaTypeSynth` / `SpanTypeSynth` pairs by that suffix —
	 * `HxFnBodyT` is the same debt as `HxFnBody`.
	 *
	 * Unlike its sibling above, a hit inside a STRING LITERAL COUNTS. Half the
	 * debt this pins WAS a string literal — `case 'HxFnBody', 'HxFnBodyT':` — so
	 * excusing strings would have made the pin blind to the thing it exists for.
	 * Only comments are masked, and with the seam under test.
	 *
	 * What it does NOT catch: a bare enum-CTOR name (`case NoBody:` inside a
	 * `macro switch`), which the deleted handler also carried. Reaching those
	 * needs the ctor inventory rather than the module list. In practice a ctor
	 * arrives with its type — `ruleCtorPath` takes a type path — so the type-name
	 * scan is the tripwire on the same edit; a hand-written `macro switch` over
	 * bare ctors would still slip past, and that is the known hole.
	 */
	public function testTheEngineNamesNoHaxeGrammarRuleType(): Void {
		final ruleTypes: Array<String> = haxeGrammarRuleTypeNames();
		Assert.isTrue(ruleTypes.length > 100, 'rule-type inventory looks wrong: ${ruleTypes.length} name(s) — did the grammar move?');
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final found: Array<String> = [];
		for (dir in ENGINE_DIRS) for (path in hxFilesUnder(dir)) {
			final source: String = File.getContent(path);
			final regions: Array<LexRegion> = plugin.lexicalRegions(source);
			for (name in grammarNamesOutsideComments(source, ruleTypes, regions)) found.push('$path: $name');
		}
		found.sort(Reflect.compare);
		Assert.equals('', found.join('\n'), 'the engine must ASK the grammar (a `@:fmt` arg, an `AstPreds` predicate), never name it');
	}

	/** Every `.hx` under `dir`, recursively, in a stable order. */
	private function hxFilesUnder(dir: String): Array<String> {
		final out: Array<String> = [];
		if (!FileSystem.exists(dir)) return out;
		for (entry in FileSystem.readDirectory(dir)) {
			final path: String = '$dir/$entry';
			if (FileSystem.isDirectory(path))
				for (nested in hxFilesUnder(path)) out.push(nested);
			else if (path.endsWith('.hx'))
				out.push(path);
		}
		out.sort(Reflect.compare);
		return out;
	}

	/** The `Hx…` module names under the Haxe grammar package — one module per rule type. */
	private function haxeGrammarRuleTypeNames(): Array<String> {
		return [
			for (path in hxFilesUnder(HAXE_GRAMMAR_DIR))
				path.substring(path.lastIndexOf('/') + 1, path.length - '.hx'.length)
		].filter(name -> name.startsWith('Hx'));
	}

	/**
	 * Every `Hx…` identifier in `source` that names one of `ruleTypes` and does
	 * not sit inside a comment. Scans for the identifier rather than testing each
	 * name with `indexOf`, so the cost is one pass over the file instead of one
	 * per name over a 190-name inventory.
	 */
	private function grammarNamesOutsideComments(source: String, ruleTypes: Array<String>, regions: Array<LexRegion>): Array<String> {
		final out: Array<String> = [];
		final n: Int = source.length;
		var i: Int = 0;
		while (i < n - 1) {
			if (source.fastCodeAt(i) != 'H'.code || source.fastCodeAt(i + 1) != 'x'.code || isIdentPart(source, i - 1)) {
				i++;
				continue;
			}
			var end: Int = i + 2;
			while (isIdentPart(source, end)) end++;
			final name: String = source.substring(i, end);
			final region: Null<LexRegion> = LexicalRegions.regionAt(i, regions);
			final masked: Bool = region != null && (region.kind == LexRegionKind.LineComment || region.kind == LexRegionKind.BlockComment);
			if (!masked && (ruleTypes.contains(name) || ruleTypes.contains(pairedBase(name)))) out.push(name);
			i = end;
		}
		return out;
	}

	/** `HxFnBodyT` / `HxFnBodyS` -> `HxFnBody`: the synth pairs are the same rule type. */
	private static function pairedBase(name: String): String {
		return name.endsWith('T') || name.endsWith('S') ? name.substr(0, name.length - 1) : name;
	}

	/** Whether `at` is inside `source` and holds an identifier character. */
	private static function isIdentPart(source: String, at: Int): Bool {
		if (at < 0 || at >= source.length) return false;
		final c: Int = source.fastCodeAt(at);
		return c == '_'.code || (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code);
	}
	#end

}
