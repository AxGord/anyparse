package unit.grammar.haxe;

import anyparse.check.Check.Violation;
import anyparse.check.UnusedLocal;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.haxe.HxStringEscape;
import anyparse.query.QueryNode;
import utest.Assert;
import utest.Test;

/**
 * The escape DECODER (`HxStringEscape`), the query-tree model built on it
 * (`HxInterpProjection`), and the textual word boundary a numeric escape spells
 * (`RefactorSupport.interpolationEscapeBefore`, exercised through `unused-local`)
 * — the three seats that together stop an escape-spelled `$` from reading as
 * plain text.
 *
 * Haxe decodes a string literal's escapes BEFORE it scans a single-quoted literal
 * for interpolation, so `\x24`, `$` and `\u{24}` are alternative SPELLINGS of
 * the trigger `$`: `'\x24a'` is the value of the local `a`, `'\x24{a}'` is `${a}`,
 * and `'\x24\x24a'` is the escaped-dollar TEXT `$a`. Every expected value in this
 * file was confirmed by compiling and running the fixture on `--interp` and `-js`.
 *
 * The parser cannot see any of that: `HxStringLitSegment` is `@:rawString` — it
 * keeps the author's spelling verbatim so the writer can reproduce it — and stops
 * only at a RAW `$`. So it reports ONE plain `Literal` where the compiler reads
 * interpolation, and every consumer of that tree inherits the blindness. The
 * projection re-splits such a fragment into the segments the compiler sees, using
 * the same node kinds and spans the raw spelling produces.
 *
 * Source strings here are DOUBLE-quoted so the `$` and `\` they contain reach the
 * parser under test rather than this file's own compiler.
 */
@:nullSafety(Strict)
final class HxStringEscapeTest extends Test {

	// ---- decoder ----

	public function testHexDollarCarries(): Void {
		Assert.isTrue(HxStringEscape.carriesDollar('a\\x24b'));
		Assert.isTrue(HxStringEscape.carriesEscapedDollar('a\\x24b'));
	}

	public function testUnicodeDollarSpellingsCarry(): Void {
		Assert.isTrue(HxStringEscape.carriesEscapedDollar('a\\u0024b'));
		Assert.isTrue(HxStringEscape.carriesEscapedDollar('a\\u{24}b'));
		Assert.isTrue(HxStringEscape.carriesEscapedDollar('a\\u{000024}b'));
	}

	/** A raw `$` is a dollar the verbatim-copy caller must refuse, and NOT one the re-escaping caller cannot handle. */
	public function testRawDollarSeparatesTheTwoQuestions(): Void {
		Assert.isTrue(HxStringEscape.carriesDollar("a$b"));
		Assert.isFalse(HxStringEscape.carriesEscapedDollar("a$b"));
	}

	/** Precision is the point: the blunt "carries any `\x` / `\u`" test refused these too. */
	public function testNonTriggerEscapesDoNotCarry(): Void {
		Assert.isFalse(HxStringEscape.carriesDollar('a\\x41b'));
		Assert.isFalse(HxStringEscape.carriesDollar('a\\u0041b'));
		Assert.isFalse(HxStringEscape.carriesDollar('a\\x7Bb\\x7Dc'));
		Assert.isFalse(HxStringEscape.carriesDollar('a\\nb\\tc\\\'d'));
	}

	/**
	 * Decoding is ONE pass: a `\x5C` decodes to a backslash that does NOT then open a
	 * second escape, so `'\x5Cx24a'` is the eight characters `\x24a` and holds no `$`.
	 * The same fact under the ordinary spelling — a `\\` consumes its partner, so the
	 * literal backslash in `'\\x24a'` leaves `x24a` as plain text.
	 */
	public function testDecodingIsSinglePass(): Void {
		Assert.isFalse(HxStringEscape.carriesDollar('\\x5Cx24a'));
		Assert.isFalse(HxStringEscape.carriesDollar('\\\\x24a'));
	}

	/** An escape the compiler rejects (`\X24` — only lowercase `x` opens a hex escape) decodes to its tag, never to a trigger. */
	public function testInvalidEscapeDecodesToItsTag(): Void {
		Assert.isFalse(HxStringEscape.carriesDollar('\\X24a'));
		Assert.isFalse(HxStringEscape.carriesDollar('\\x2'));
		Assert.isFalse(HxStringEscape.carriesDollar('\\u{'));
	}

	/** The `$name` lookahead's question: what character does this text START with once decoded? */
	public function testFirstCodeIsDecoded(): Void {
		Assert.equals('A'.code, HxStringEscape.firstCode('\\x41b'));
		Assert.equals('A'.code, HxStringEscape.firstCode('\\u0041b'));
		Assert.equals('\\'.code, HxStringEscape.firstCode('\\\\x41b'));
		Assert.equals(-1, HxStringEscape.firstCode(''));
	}

	// ---- projection ----

	/** `'\x24a'` is a read of `a`, projected as the same `Ident` node the raw `'$a'` produces. */
	public function testHexDollarProjectsIdent(): Void {
		Assert.equals('(Ident a)', segments("'\\x24a'"));
	}

	/** `'\x24{a}'` is `${a}`. The block projects CHILDLESS: its interior is not contiguous source anyparse can re-read. */
	public function testHexDollarBraceProjectsBlock(): Void {
		Assert.equals('(Block)', segments("'\\x24{a}'"));
	}

	/** `'\x24\x24a'` is the escaped-dollar text `$a` — a `Dollar` fragment, not a read. */
	public function testDoubledHexDollarProjectsEscape(): Void {
		Assert.equals('(Dollar)(Literal a)', segments("'\\x24\\x24a'"));
	}

	/** A trailing escape-spelled `$` followed by nothing an identifier can start is a literal dollar. */
	public function testTrailingHexDollarProjectsLoneDollar(): Void {
		Assert.equals('(LoneDollar)', segments("'\\x24'"));
		Assert.equals('(LoneDollar)(Literal  x)', segments("'\\x24 x'"));
	}

	/** Text around the trigger keeps its own verbatim slices, so a span-reading consumer sees exactly what it saw before the split. */
	public function testSurroundingTextKeepsItsSlices(): Void {
		Assert.equals('(Literal x)(Ident a)(Literal  y)', segments("'x\\x24a y'"));
	}

	/**
	 * The seam the PARSER creates: `HxStringLitSegment` cuts a fragment at every RAW
	 * `$`, which is precisely where a decoded one can meet it. All four shapes are one
	 * escaped dollar plus literal text — the two `$`s pair — and a per-fragment reading
	 * saw a lone `$` beside the parser's own live `Ident` / `Block`, i.e. a read that is
	 * not there. Folding `'\x24$a' + 'b'` then printed `$AAAb` for a string whose value
	 * is `$ab` (compile-and-run). Scanning from the LITERAL's span is what closes it.
	 */
	public function testDecodedDollarMeetingRawDollarPairs(): Void {
		Assert.equals('(Dollar)(Literal a)', segments("'\\x24$a'"));
		Assert.equals('(Dollar)(Literal {a})', segments("'\\x24${a}'"));
		Assert.equals('(Dollar)(Literal a)', segments("'$\\x24a'"));
		Assert.equals('(Dollar)', segments("'\\x24$'"));
	}

	/** Three dollars in a row are an escaped one plus a live trigger, whichever two of them are escape-spelled. */
	public function testThreeDollarsPairThenInterpolate(): Void {
		Assert.equals('(Dollar)(Ident a)', segments("'\\x24$$a'"));
		Assert.equals('(Dollar)(Ident a)', segments("'$$\\x24a'"));
	}

	/**
	 * Rescanning the whole literal must not COST the parser's work: a raw `${ … }`
	 * elsewhere in the same literal keeps its parsed expression subtree, because the
	 * rescan reuses the parser's node whenever the spans agree. Without that, every
	 * reference inside such a block would go dark the moment an escape appeared anywhere
	 * in the literal.
	 */
	public function testRawBlockKeepsItsParsedSubtree(): Void {
		final tree: QueryNode = new HaxeQueryPlugin().parseFile("class C { function f() { var s = '\\x24a ${b + 1}'; } }");
		final block: Null<QueryNode> = firstOfKind(tree, 'Block');
		Assert.notNull(block);
		if (block != null) Assert.equals('Add', block.children[0].kind);
	}

	/** Both halves of the trigger may be escape-spelled — the decoder reads the NAME through its escapes too. */
	public function testFullyEscapedIdentProjects(): Void {
		Assert.equals('(Ident ab)', segments("'\\x24\\x61b'"));
	}

	/** Braces decode to ordinary text: only a `$` opens interpolation, so `'\x7Ba\x7D'` stays one literal. */
	public function testEscapedBracesAreNotTriggers(): Void {
		Assert.equals('(Literal \\x7Ba\\x7D)', segments("'\\x7Ba\\x7D'"));
	}

	/** The raw spelling is untouched — the projection must reproduce it, not replace it. */
	public function testRawSpellingUnchanged(): Void {
		Assert.equals('(Ident a)', segments("'$a'"));
		Assert.equals('(Dollar)(Literal a)', segments("'$$a'"));
	}

	/** A `\x` that decodes to no trigger leaves the fragment whole — the pass must not churn every escaped literal. */
	public function testNonTriggerEscapeLeavesOneFragment(): Void {
		Assert.equals('(Literal a\\x41b)', segments("'a\\x41b'"));
	}

	/** The synthesized `Ident` spans the bytes that SPELL it (`\x24a`), so every span-driven edit still addresses real source. */
	public function testSynthesizedSpanCoversItsSpelling(): Void {
		final src: String = "class C { function f() { var s = '\\x24a'; } }";
		final node: Null<QueryNode> = firstOfKind(new HaxeQueryPlugin().parseFile(src), 'Ident');
		Assert.notNull(node);
		if (node != null) Assert.equals('\\x24a', src.substring(node.span?.from ?? 0, node.span?.to ?? 0));
	}

	// ---- what the projection buys ----

	/**
	 * The measured data loss this closes at the reference-scan seam: `unused-local`
	 * flagged — and `--fix` DELETED — a local whose only read was `'\x24a'`, leaving
	 * source that no longer compiles. The scan is textual, so the fix is the word
	 * boundary a numeric escape spells (`RefactorSupport.interpolationEscapeBefore`).
	 */
	public function testEscapedInterpolationReadKeepsTheLocal(): Void {
		Assert.equals(0, unusedLocals("class C { function f() { var a = 1; trace('\\x24a'); } }").length);
		Assert.equals(0, unusedLocals("class C { function f() { var a = 1; trace('\\u0024a'); } }").length);
	}

	/**
	 * The boundary is not a blanket amnesty. `'\x24ab'` reads `ab`, NOT `a` — the escape
	 * opens a token, it does not end one, so the character AFTER the match still has to
	 * be a boundary. Both locals are checked in one fixture so the discriminating one
	 * cannot be masked: `ab` is kept, `a` is still flagged.
	 */
	public function testEscapePrefixDoesNotCreditALongerName(): Void {
		final vs: Array<Violation> = unusedLocals("class C { function f() { var a = 1; var ab = 2; trace('\\x24ab'); } }");
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf("'a'") >= 0);
	}

	private static function segments(literal: String): String {
		final tree: QueryNode = new HaxeQueryPlugin().parseFile('class C { function f() { var s = $literal; } }');
		final node: Null<QueryNode> = firstOfKind(tree, 'SingleStringExpr');
		if (node == null) return '';
		final buf: StringBuf = new StringBuf();
		for (c in node.children) buf.add(c.name == null ? '(${c.kind})' : '(${c.kind} ${c.name})');
		return buf.toString();
	}

	private static function unusedLocals(src: String): Array<Violation> {
		return new UnusedLocal().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** The first node of `kind` in `node`'s subtree, depth-first, or null. */
	private static function firstOfKind(node: QueryNode, kind: String): Null<QueryNode> {
		if (node.kind == kind) return node;
		for (c in node.children) {
			final found: Null<QueryNode> = firstOfKind(c, kind);
			if (found != null) return found;
		}
		return null;
	}

}
