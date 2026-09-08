package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CondRegionScan;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SourceText;
import anyparse.query.cli.command.FmtCommand;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The predicate behind a `#if ... #end` region the writer leaves BYTE-FOR-BYTE while
 * reformatting everything around it — `CondRegionScan.opaqueCondRegions` — and the note
 * `fmt` builds from it.
 *
 * The predicate is NOT how the braces balance, which is the reading the shape invites and
 * the one this class exists to refute: the first two fixtures are the same region with the
 * same number of `{` and `}`, differing only in a trailing `else`, and only one of them is
 * opaque. Re-measured 2026-09-07 over three trees (this project, the Pony fork, the
 * haxe-formatter corpus inputs — 1580 regions between them): 34 of the 59 captured raw have an
 * equal brace count, so a brace rule would report 25 of them and miss 34; and the one region
 * whose braces do NOT balance yet formats is unbalanced only to a count over the region's own
 * text, which adds up both mutually exclusive arms of a nested `#if` / `#else`.
 *
 * What decides it is whether the bytes between the directives are a balanced subtree IN
 * THEIR GRAMMATICAL POSITION. When they are not, the grammar falls back to one of
 * `RefShape.opaqueCondRegionKinds`, whose interior projects no nodes at all — which is the
 * same fact the mutating ops refuse on, reached through the same scan.
 *
 * The remaining fixtures pin the QUOTE, because a message naming the wrong bytes is what
 * the reader acts on: the region runs from the first unmodelled byte to the last, not from
 * the node's own start (a tail splice begins at the operand BEFORE its `#if`) and not to
 * the node's own end (a whitespace gap after the `#end` would drag the shared body in).
 */
class OpaqueCondRegionScanTest extends Test {

	/** `#if x if (c) { g(); } else #end h();` — braces balance, the `else` has no body until after the `#end`. */
	private static final DANGLING_ELSE: String =
		'class C {\n\tstatic function f(c: Bool): Void {\n\t\t#if x\n\t\tif (c) { g(); } else\n\t\t#end\n\t\th();\n\t}\n}\n';

	/** The same region with the `else` removed — identical brace count, an ordinary `Conditional`. */
	private static final BALANCED_TWIN: String =
		'class C {\n\tstatic function f(c: Bool): Void {\n\t\t#if x\n\t\tif (c) { g(); }\n\t\t#end\n\t\th();\n\t}\n}\n';

	/** A postfix tail splice: the node starts at `foo`, so the region is NOT the node's span. */
	private static final TAIL_SPLICE: String = 'class C {\n\tstatic function f(): Void {\n\t\treturn foo #if target .sys #end;\n\t}\n}\n';

	/** A signature-position splice whose shared body follows the `#end`, separated by whitespace only. */
	private static final SHARED_BODY: String = 'class C {\n\tstatic function foo() #if foo :SomeType #end {\n\t\tbar;\n\t}\n}\n';

	/** The user-reported shape: a `try` opened in one region and caught in another. */
	private static final SPLIT_TRY: String = 'class C {\n\tpublic static function build(): Int {\n\t\tvar fields: Int = 0;\n'
		+ '\t\t#if display\n\t\ttry {\n\t\t#end\n\t\tvar a: Int = 1;\n\t\tfields = a + 1;\n'
		+ '\t\t#if display\n\t\t} catch (_:Dynamic) {\n\t\t}\n\t\t#end\n\t\treturn fields;\n\t}\n}\n';

	/**
	 * A signature-position splice with a line comment between the `#end` and the shared body —
	 * the shape that puts trivia inside the byte run no child covers.
	 */
	private static final TRAILING_COMMENT: String =
		'class C {\n\tstatic function foo() #if foo :SomeType #end\n\t// note after the end\n\t{\n\t\tbar;\n\t}\n}\n';

	/**
	 * The class a brace count gets wrong in the OTHER direction. The OUTER region holds two `{`
	 * and one `}` — a text count adds up both mutually exclusive arms of the region nested in it
	 * — and it is an ordinary `Conditional` the writer formats; only the INNER region is captured
	 * raw. Live shape: `Pony/src/pony/flash/HaxeInit.hx:26`, the one region of the 1580 measured
	 * that a brace rule calls unbalanced while `fmt` reformats it.
	 */
	private static final NESTED_ARMS: String = 'class C {\n\tstatic function f(c: Bool, d: Bool): Void {\n\t\t#if outer\n'
		+ '\t\t#if inner\n\t\tif (c) {\n\t\t#else\n\t\tif (d) {\n\t\t#end\n\t\t\tg();\n\t\t}\n\t\t#end\n\t}\n}\n';

	/**
	 * THE discriminating pair. Both regions hold one `{` and one `}`; the only difference is
	 * the trailing `else`, which leaves the statement unfinished at the `#end` and forces the
	 * splice fallback. A brace-delta rule answers the same for both and is therefore not the
	 * predicate.
	 */
	@:pin('control')
	@:killer('M-OPAQUE-REGION-NONE')
	public function testDanglingElseIsOpaqueWhileItsBraceIdenticalTwinIsNot(): Void {
		Assert.equals(1, regionsOf(DANGLING_ELSE).length, 'the dangling-else region is captured raw');
		Assert.equals('#if x if (c) { g(); } else #end', quoteOf(DANGLING_ELSE, 0));
		Assert.equals(0, regionsOf(BALANCED_TWIN).length, 'the same region without the `else` is an ordinary Conditional');
		Assert.equals(braceDelta(DANGLING_ELSE), braceDelta(BALANCED_TWIN), 'the pair differs in no brace');
	}

	/**
	 * A `CondSpliceTail` node begins at the operand BEFORE its `#if`, so quoting the node
	 * would bury the directive under the leading expression — the real corpus case is a
	 * hundred characters of call chain, which the 60-char excerpt then cuts before the `#if`
	 * is ever reached.
	 */
	@:pin('control')
	@:killer('M-OPAQUE-REGION-NODE-SPAN')
	public function testTheQuoteStartsAtTheIfEvenWhenTheNodeBeginsBeforeIt(): Void {
		Assert.equals(1, regionsOf(TAIL_SPLICE).length);
		Assert.equals('#if target .sys #end', quoteOf(TAIL_SPLICE, 0));
	}

	/**
	 * The byte run between the `#end` and the shared body is whitespace — layout between two
	 * children, not something the model dropped. Counting it extends the quote past the `#end`
	 * and into the body the region does not own.
	 */
	@:pin('control')
	@:killer('M-OPAQUE-REGION-WS-GAP')
	public function testAWhitespaceGapDoesNotDragTheSharedBodyIntoTheQuote(): Void {
		Assert.equals(1, regionsOf(SHARED_BODY).length);
		Assert.equals('#if foo :SomeType #end', quoteOf(SHARED_BODY, 0));
	}

	/** The reported source: two regions, one opening the `try` and one closing it around the `catch`. */
	@:pin('control')
	@:killer('M-OPAQUE-REGION-NONE')
	public function testTheSplitTryReportsBothOfItsRegions(): Void {
		Assert.equals(2, regionsOf(SPLIT_TRY).length);
		Assert.equals('#if display try { #end', quoteOf(SPLIT_TRY, 0));
		Assert.equals('#if display } catch (_:Dynamic) { } #end', quoteOf(SPLIT_TRY, 1));
	}

	/**
	 * The note `fmt` prints, asserted whole: a message naming the wrong line or the wrong
	 * bytes is what the reader acts on, and `Sys.stderr()` is a raw fd no in-process test can
	 * read — which is why the builder hands the lines back instead of printing them.
	 */
	@:pin('control')
	@:killer('M-OPAQUE-REGION-NONE')
	public function testTheNoteNamesTheLineTheRegionAndTheReason(): Void {
		final notes: Array<String> = FmtCommand.opaqueCondRegionNotes(new HaxeQueryPlugin(), 'A.hx', SPLIT_TRY);
		Assert.equals(2, notes.length);
		Assert.equals(
			'apq fmt: A.hx:4:3: conditional-compilation region left unformatted - "#if display try { #end" is not a'
			+ ' balanced subtree, so the parser captured it raw and the writer re-emits it byte-for-byte; restructure it'
			+ ' into a balanced #if to have it formatted',
			notes[0]
		);
	}

	/** A source with no `#if` at all never reaches the parse, and answers no note. */
	public function testASourceWithoutConditionalCompilationYieldsNothing(): Void {
		Assert.equals(0, FmtCommand.opaqueCondRegionNotes(new HaxeQueryPlugin(), 'A.hx', 'class C {\n\tvar a: Int = 1;\n}\n').length);
	}

	/**
	 * A comment after the `#end` is TRIVIA, so it falls in the byte run no child covers and used
	 * to close the quote — `"#if foo :SomeType #end // note after the end"`. No projection carries
	 * a comment node anywhere, inside a region or out of it, so those bytes are not something the
	 * model dropped HERE; they come off both ends of the quoted range, the COORDINATE with them.
	 *
	 * The fixture is a signature-position splice on purpose: the shapes whose interior a grammar
	 * could learn to parse (a `catch` tail, an `else` tail, a bare `case` label, a lone `{` or
	 * `}`) may stop being opaque, and this pin is about the quote, not about which shapes are.
	 */
	@:pin('control')
	@:killer('M-OPAQUE-REGION-TRIVIA-KEPT')
	public function testACommentAfterTheEndStaysOutOfTheQuote(): Void {
		final notes: Array<String> = FmtCommand.opaqueCondRegionNotes(new HaxeQueryPlugin(), 'A.hx', TRAILING_COMMENT);
		Assert.equals(1, notes.length);
		Assert.isTrue(notes[0].indexOf('"#if foo :SomeType #end"') != -1, 'the quote stops at the `#end`: ${notes[0]}');
		Assert.isTrue(notes[0].indexOf('A.hx:2:24:') != -1, 'and the coordinate is the `#if`, not the space before it: ${notes[0]}');
	}

	/**
	 * A region the ctor keeps CHILDREN inside gets its own sentence, and a quote made of the
	 * raw bytes alone.
	 *
	 * `CondSpliceBlockTail` is unbalanced in its HEAD only — the `}` closes a `{` opened in
	 * another region — while everything from its own `{` on is an ordinary statement the
	 * writer formats. The old single sentence said the writer re-emits the whole region
	 * byte-for-byte, and the quoted range ran from the first raw byte to the last, straight
	 * over that statement; on the Pony fork 9 of 31 regions were that shape. The `…` is where
	 * the formatted block was.
	 */
	@:pin('control')
	@:killer('M-REGION-INSIDE-NONE')
	public function testAPartlyRawRegionSaysSoAndQuotesOnlyItsRawBytes(): Void {
		final notes: Array<String> = FmtCommand.opaqueCondRegionNotes(new HaxeQueryPlugin(), 'A.hx', SPLIT_TRY);
		Assert.equals(2, notes.length);
		Assert.equals(
			'apq fmt: A.hx:9:3: conditional-compilation region formatted only in part - "#if display } catch (_:Dynamic) … #end"'
			+ ' is not a balanced subtree in its position, so the parser captured those bytes raw and the writer re-emits them'
			+ ' byte-for-byte; what the quote elides is formatted like any other subtree',
			notes[1]
		);
		Assert.stringContains('region left unformatted', notes[0], 'and the wholly raw opener keeps the sentence it always had');
	}

	/**
	 * An EXPLICIT `--list` builds no notes at all, and everything else still does.
	 *
	 * The notes are a second front end — one full projection parse per file that has a `#if` —
	 * and that is +19.9% on the whole-tree `fmt --list --one-pass` gate, measured as
	 * interleaved medians. `--list` is the machine mode a gate spells; a human surveying a
	 * directory types `fmt <dir>`, which implies the same listing and keeps the notes. Nothing
	 * about the FILE decides it: both real trees are already canonical, so "only for an
	 * unchanged file" is the identity and its inverse deletes every note there is.
	 */
	@:pin('control')
	@:killer('M-REGION-NOTES-ALWAYS')
	public function testAnExplicitListBuildsNoNotes(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.equals(2, FmtCommand.opaqueCondRegionNotes(plugin, 'A.hx', SPLIT_TRY, false).length, 'the survey path keeps them');
		Assert.equals(0, FmtCommand.opaqueCondRegionNotes(plugin, 'A.hx', SPLIT_TRY, true).length, 'an explicit --list builds none');
	}

	/**
	 * The three classes a `#if` region falls into, and the two of them a brace-delta rule
	 * answers wrong.
	 *
	 * Construct-cutting with BALANCED braces is the MAJORITY — 34 of the 59 raw regions over
	 * the three trees — and a brace rule reports none of them. Construct-cutting with
	 * unbalanced braces is the one class it gets right. The third is its false positive:
	 * braces that do not balance over the region TEXT while the region is an ordinary
	 * `Conditional` the writer formats, because the count added up both mutually exclusive
	 * arms of a nested `#if` / `#else` — one region in 1580, and no configuration of the file
	 * ever holds both arms.
	 *
	 * The arm IS the refuted rule: keep a record only where the region's brace counts differ,
	 * and the first class stops being reported at all.
	 */
	@:pin('control')
	@:killer('M-OPAQUE-REGION-BRACE-DELTA')
	public function testABraceDeltaRuleAnswersTwoOfTheThreeRegionClassesWrong(): Void {
		final danglingFrom: Int = DANGLING_ELSE.indexOf('#if x');
		final danglingTo: Int = DANGLING_ELSE.indexOf('#end') + '#end'.length;
		Assert.equals(0, braceDelta(DANGLING_ELSE, danglingFrom, danglingTo), 'class 1: the region braces balance');
		Assert.equals(1, regionsOf(DANGLING_ELSE).length, 'class 1: and it is captured raw regardless');
		final tryFrom: Int = SPLIT_TRY.indexOf('#if display');
		final tryTo: Int = SPLIT_TRY.indexOf('#end') + '#end'.length;
		Assert.equals(1, braceDelta(SPLIT_TRY, tryFrom, tryTo), 'class 2: the region opens a brace it never closes');
		Assert.equals(2, regionsOf(SPLIT_TRY).length, 'class 2: both of its regions are captured raw');
		final outerFrom: Int = NESTED_ARMS.indexOf('#if outer');
		final outerTo: Int = NESTED_ARMS.lastIndexOf('#end') + '#end'.length;
		Assert.equals(1, braceDelta(NESTED_ARMS, outerFrom, outerTo), 'class 3: the outer region text holds one brace too many');
		final nested: Array<OpaqueCondRegion> = regionsOf(NESTED_ARMS);
		Assert.equals(1, nested.length, 'class 3: yet only ONE region there is captured raw');
		Assert.equals(NESTED_ARMS.indexOf('#if inner'), nested[0].region.from, 'class 3: and it is the inner region, not the outer');
	}

	private static function regionsOf(source: String): Array<OpaqueCondRegion> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final shape: RefShape = plugin.refShape();
		return CondRegionScan.opaqueCondRegions(plugin.parseFile(source), source, shape);
	}

	private static function quoteOf(source: String, index: Int): String {
		return SourceText.regionExcerpt(source, regionsOf(source)[index].region);
	}

	/**
	 * `{` minus `}` over `[from, to)`, the whole source by default — the reading these fixtures
	 * refute, read off the same bytes a brace rule would.
	 */
	private static function braceDelta(source: String, from: Int = 0, ?to: Int): Int {
		var delta: Int = 0;
		for (i in from ... (to ?? source.length)) {
			final code: Int = source.fastCodeAt(i);
			if (code == '{'.code)
				delta++;
			else if (code == '}'.code)
				delta--;
		}
		return delta;
	}

}
