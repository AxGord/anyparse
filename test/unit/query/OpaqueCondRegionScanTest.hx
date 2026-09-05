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
 * opaque. Measured over two real trees when this landed, 34 of 56 opaque regions had an
 * equal brace count, so a brace rule would have missed most of the class.
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

	private static function regionsOf(source: String): Array<OpaqueCondRegion> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final shape: RefShape = plugin.refShape();
		return CondRegionScan.opaqueCondRegions(plugin.parseFile(source), source, shape);
	}

	private static function quoteOf(source: String, index: Int): String {
		return SourceText.regionExcerpt(source, regionsOf(source)[index].region);
	}

	/** `{` minus `}` over the whole source — the reading the first fixture refutes. */
	private static function braceDelta(source: String): Int {
		var delta: Int = 0;
		for (i in 0...source.length) {
			final code: Int = source.fastCodeAt(i);
			if (code == '{'.code)
				delta++;
			else if (code == '}'.code)
				delta--;
		}
		return delta;
	}

}
