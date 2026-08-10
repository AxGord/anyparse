package unit;

import utest.Assert;
import anyparse.check.Check.Violation;
import anyparse.check.FoldStringLiterals;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

using StringTools;

/**
 * The MERGE direction of the `fold-adjacent-string-literals` check: a string
 * concatenation whose segmentation does not match the file's line width is flagged
 * (`Info`) and re-segmented, with literals and expression operands merging into one
 * interpolated literal.
 *
 * Covered here: which operands merge (literal, interpolated, numeric, non-literal,
 * a parenthesised sub-chain, a trailing identifier), which quote style the merged
 * literal takes, how a `$` and an escape sequence are re-spelled across that change
 * (a hex, unicode or brace-spelled escape blocks the merge into a single-quoted
 * literal; a balanced brace does not), and the shapes that refuse the construct
 * outright (a comment between or inside operands, a backslash string, a chain inside
 * an interpolation block).
 *
 * The width-driven re-cut and the seam splits live in
 * `FoldStringLiteralsWidthCheckTest`, the never-a-candidate positions and the
 * macro-argument whitelist in `FoldStringLiteralsCandidateGateTest`.
 */
class FoldStringLiteralsCheckTest extends FoldStringLiteralsCheckTestBase {

	public function testDoubleLiteralPairFlagged(): Void {
		final vs: Array<Violation> = violations('class C { function f() { final a = "a" + "b"; } }');
		Assert.equals(1, vs.length);
		Assert.equals('fold-adjacent-string-literals', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFixMergesDoublePair(): Void {
		Assert.equals('"ab"', foldOf('class C { function f() { final a = "a" + "b"; } }'));
	}

	public function testChainFoldsInOnePass(): Void {
		final src: String = 'class C { function f() { final a = "x" + "y" + "z"; } }';
		Assert.equals(1, violations(src).length);
		Assert.equals('"xyz"', foldOf(src));
	}

	public function testSingleQuotedPlainFolds(): Void {
		final src: String = "class C { function f() { final a = 'p' + 'q'; } }";
		Assert.equals(1, violations(src).length);
		Assert.equals("'pq'", foldOf(src));
	}

	/** An interpolated operand is no longer a blocker: its fragments join the segment list. */
	public function testInterpolatedOperandMerges(): Void {
		Assert.equals("'lead ${name}tail'", foldOf("class C { function f(name:String) { final a = 'lead $name' + 'tail'; } }"));
	}

	/** Mixed quotes merge into ONE single-quoted literal, each side re-escaped for that context. */
	public function testMixedQuotesMergeToSingleQuoted(): Void {
		Assert.equals("'mn'", foldOf("class C { function f() { final a = \"m\" + 'n'; } }"));
	}

	public function testNonLiteralOperandMerges(): Void {
		Assert.equals("'a${name}b'", foldOf('class C { function f(name:String) { final a = "a" + name + "b"; } }'));
	}

	public function testNumericOperandMerges(): Void {
		Assert.equals("'z${1}'", foldOf('class C { function f() { final a = "z" + 1; } }'));
	}

	/** The WHOLE chain is one candidate now — the trailing identifier merges in with the literal pair. */
	public function testWholeChainFoldsWithTrailingIdent(): Void {
		final src: String = 'class C { function f(name:String) { final a = "a" + "b" + name; } }';
		Assert.equals(1, violations(src).length);
		Assert.equals("'ab$name'", foldOf(src));
	}

	/**
	 * The whole pipeline over one construct: `run` -> `fix` -> canonicalize -> re-lint.
	 * The canonicalized FILE is asserted verbatim and then fed straight back through
	 * `run`, which must find nothing — the canonical form is a fixed point of the RULE,
	 * not merely of its own rendered fragment.
	 */
	public function testFixAppliedResultIsCanonicalAndIdempotent(): Void {
		final src: String = 'class C {\n\tfunction f(name:String) {\n\t\tfinal a = "a" + name + "b";\n\t}\n}';
		final check: FoldStringLiterals = new FoldStringLiterals();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals("class C {\n\tfunction f(name:String) {\n\t\tfinal a = 'a${name}b';\n\t}\n}\n", text);
				Assert.equals(0, violations(text).length);
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('fold-adjacent-string-literals'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('fold-adjacent-string-literals'));
	}

	public function testDollarEscapedSingleQuotedFolds(): Void {
		// '$$' is an escaped literal $ (a `Dollar` fragment, not interpolation) — plain, so it folds.
		Assert.equals("'a$$bc'", foldOf("class C { function f() { final a = 'a$$b' + 'c'; } }"));
	}

	/**
	 * A lone `$` literal is ONE segment: nothing to re-cut, so the normalisation to
	 * the escaped `$$` form never fires on its own. It DOES fire when the literal
	 * joins a merge — the plain form would otherwise interpolate whatever follows.
	 */
	public function testLoneDollarLiteralNormalisedOnlyWhenMerged(): Void {
		Assert.equals(0, violations("class C { function f() { final a = '$'; } }").length);
		Assert.equals("'$$a'", foldOf("class C { function f() { final a = '$' + 'a'; } }"));
	}

	/**
	 * The old rule refused a chain laid out ACROSS lines as "deliberate width
	 * layout". Width is now measured, so a cross-line chain that fits when merged
	 * merges.
	 */
	public function testCrossLineChainNowMerges(): Void {
		final src: String = 'class C { function f() { final a = "long message "\n\t\t+ "split for width"; } }';
		Assert.equals(1, violations(src).length);
		Assert.equals('"long message split for width"', foldOf(src));
	}

	/** A cross-line chain is ONE candidate — the whole thing folds, not just its same-line prefix. */
	public function testCrossLinePrefixChainMergesWhole(): Void {
		final src: String = 'class C { function f() { final a = "a" + "b"\n\t\t+ "tail"; } }';
		Assert.equals(1, violations(src).length);
		Assert.equals('"abtail"', foldOf(src));
	}

	public function testConcatHtmlViewRepro(): Void {
		Assert.equals(1, violations(wrap("'<xml>' + xhtml + '</xml>'")).length);
		Assert.equals("'<xml>$xhtml</xml>'", foldOf(wrap("'<xml>' + xhtml + '</xml>'")));
	}

	/** Operands before the first literal are arithmetic — they collapse into ONE `${ … }`, never `$a$b`. */
	public function testConcatEvalOrderPreserved(): Void {
		Assert.equals("'${a + b}x'", foldOf(wrap("a + b + 'x'")));
	}

	public function testConcatIdentBeforeIdentCharBraced(): Void {
		Assert.equals("'a${xhtml}more'", foldOf(wrap("'a' + xhtml + 'more'")));
	}

	public function testConcatNumericOperands(): Void {
		Assert.equals("'s${3}${4}'", foldOf(wrap("'s' + 3 + 4")));
	}

	public function testConcatSingleIdentPrefixBeforeIdentChar(): Void {
		Assert.equals("'${a}x'", foldOf(wrap("a + 'x'")));
	}

	public function testConcatSingleIdentPrefixBeforeNonIdent(): Void {
		Assert.equals("'$a.b'", foldOf(wrap("a + '.b'")));
	}

	/**
	 * The `$name` lookahead reads the DECODED first character of the text that follows,
	 * not its raw one. `"\x41b"` starts with an `A`, which would extend the name, so the
	 * ident needs its braces — emitting the bare `'$x\x41b'` made the compiler read a
	 * local `xAb`, a silent VALUE change (compile-and-run verified: `X!Ab` before,
	 * `XAB-WRONG` after). A raw `\` really starting the text (`'\\x41b'`) is not an
	 * identifier character and keeps the bare form.
	 */
	public function testConcatIdentBeforeDecodedIdentCharBraced(): Void {
		Assert.equals("'${x}\\x41b'", foldOf(wrap('x + "\\x41b"')));
		Assert.equals("'${x}\\u0041b'", foldOf(wrap('x + "\\u0041b"')));
		Assert.equals("'$x\\\\x41b'", foldOf(wrap('x + "\\\\x41b"')));
	}

	public function testConcatDollarInSingleLiteral(): Void {
		Assert.equals("'$$$v'", foldOf(wrap("'$' + v")));
	}

	public function testConcatDoubleQuotedDollar(): Void {
		Assert.equals("'a$$b$x'", foldOf(wrap("\"a$b\" + x")));
	}

	public function testConcatDoubleQuotedEscapedQuote(): Void {
		Assert.equals("'a\"b$x'", foldOf(wrap('\"a\\\"b\" + x')));
	}

	public function testConcatParenSubChain(): Void {
		Assert.equals("'a${(b + 'c')}'", foldOf(wrap("'a' + (b + 'c')")));
	}

	public function testConcatStdStringOperand(): Void {
		Assert.equals("'a${x}b'", foldOf(wrap("'a' + Std.string(x) + 'b'")));
	}

	/** A pure-literal pair is the ORIGINAL fold and still folds — to a plain literal in its own quote. */
	public function testConcatPureLiteralFolds(): Void {
		Assert.equals("'ab'", foldOf(wrap("'a' + 'b'")));
	}

	public function testConcatNumericOnlyNotFlagged(): Void {
		Assert.equals(0, violations(wrap('a + b')).length);
	}

	public function testConcatInterpolatedOperandMerges(): Void {
		Assert.equals("'x$y$z'", foldOf(wrap("'x${y}' + z")));
	}

	public function testConcatCommentBetweenOperandsSkipped(): Void {
		Assert.equals(0, violations(wrap("'a' + /* c */ b")).length);
	}

	/**
	 * An operand whose OWN span carries a comment is refused outright rather than locked: its
	 * source is copied verbatim into the render, where a `//` would comment out the rest.
	 */
	public function testCommentInsideOperandRefusesConstruct(): Void {
		Assert.equals(0, violations(wrap("'a' + (b /* c */ + d) + 'e'")).length);
	}

	public function testConcatOperandWithBackslashStringNotFolded(): Void {
		// `'\\'` nested inside a `${}` block mis-lexes in the REAL Haxe compiler
		// ("Unterminated string" - escapes in nested same-quote strings are not
		// processed by the interp-block scanner), even though anyparse's own
		// parser accepts it. An operand whose source carries a backslash cannot
		// enter a `${}` block, so it stays a BARE operand of its own.
		final src: String = "class C { function f(a:String, b:String):String { return a + '/' + b.replace('\\\\', '/'); } }";
		Assert.equals("'$a/' + b.replace('\\\\', '/')", foldOf(src));
	}

	public function testConcatInsideInterpolationBlockNotFolded(): Void {
		// A `+` chain that itself sits INSIDE a `${...}` interpolation block must
		// not fold - the result would nest an interpolated string inside an
		// interpolation block (fragile in the real compiler's interp scanner).
		final src: String = "class C { function f(t:String):String { return 'x${t.split('a').join(q() + \"n\")}y'; } }";
		Assert.equals(0, violations(src).length);
	}

	/**
	 * A `\x24` decodes to `$` BEFORE Haxe scans a single-quoted literal for
	 * interpolation, so a DOUBLE-quoted text carrying one may not be re-emitted into
	 * one: merging `"a\x24b" + 'c'` to `'a\x24bc'` would print the value of the local
	 * `bc` instead of the text `a$bc`. Verified against Haxe 4.3.7.
	 */
	public function testHexEscapeNotMergedIntoSingleQuoted(): Void {
		Assert.equals(0, violations(wrap('"a\\x24b" + \'c\'')).length);
		Assert.equals(0, violations(wrap('"\\x24" + name')).length);
	}

	/**
	 * The SINGLE-quoted spelling of the same escape is not a text hazard at all — it is
	 * live interpolation the parser used to hide. `'a\x24b'` reads the local `b`, and
	 * `HxInterpProjection` now says so, which turns the concatenation into the ordinary
	 * text + ident + text fold: `'a${b}c'`, the braces added because a bare `$b` would
	 * swallow the following `c`. Compile-and-run confirms both spellings print `aBBBc`
	 * on `--interp` and `-js`.
	 *
	 * Pinned at 0 findings until this slice: the seam refused the whole group because a
	 * blunt "carries any `\x` / `\u` escape" test could not tell a hidden trigger from
	 * an ordinary `\x41`.
	 */
	public function testHexEscapedInterpolationFoldsAsInterpolation(): Void {
		Assert.equals(1, violations(wrap("'a\\x24b' + 'c'")).length);
		Assert.equals("'a${b}c'", foldOf(wrap("'a\\x24b' + 'c'")));
	}

	/** An escape decoding to something ORDINARY never blocked anything but the blunt test — `\x41` is an `A`. */
	public function testNonTriggerEscapeMergesIntoSingleQuoted(): Void {
		Assert.equals("'a\\x41bc'", foldOf(wrap("'a\\x41b' + 'c'")));
		Assert.equals("'a\\x41bc'", foldOf(wrap('"a\\x41b" + \'c\'')));
	}

	/** `$` is the same trap spelled the other way. */
	public function testUnicodeEscapeNotMergedIntoSingleQuoted(): Void {
		Assert.equals(0, violations(wrap('"a\\u0024b" + \'c\'')).length);
	}

	/**
	 * The real compiler finds a `${ … }` block's closing brace by counting `{` / `}`
	 * NAIVELY, without lexing nested strings, so a brace inside one still counts:
	 * `'a${q("}")}z'` is `Unterminated string` and `'a${q("{")}z'` is `Unclosed brace`
	 * on Haxe 4.3.7 — while anyparse's own re-parse validation accepts both, which is
	 * why the fixer cannot lean on it here. Such an operand stays BARE, so the chain
	 * is already canonical and nothing is flagged.
	 */
	public function testUnbalancedBraceOperandNotMerged(): Void {
		Assert.equals(0, violations(wrap("'a' + q(\"}\") + 'z'")).length);
		Assert.equals(0, violations(wrap("'a' + q(\"{\") + 'z'")).length);
	}

	/**
	 * The same brace count runs over the DECODED text, so an operand may spell its
	 * unbalancing brace as `\x7D` and read as balanced. The audit's answer is that
	 * `interpolationBlockSafe` needs no decoder to see it: it already refuses ANY
	 * backslash — nothing in an expression source can carry an escape past that — and
	 * the operand stays bare, exactly as it does for the raw spelling above. Already
	 * true before this slice, and pinned so a later "the backslash rule is too strict"
	 * relaxation has to answer this case first.
	 */
	public function testEscapeSpelledBraceOperandNotMerged(): Void {
		Assert.equals(0, violations(wrap("'a' + q(\"\\x7D\") + 'z'")).length);
		Assert.equals(0, violations(wrap("'a' + q(\"\\x24x\") + 'z'")).length);
	}

	/** A BALANCED brace closes where that scanner expects it to, so it merges. */
	public function testBalancedBraceOperandMerges(): Void {
		Assert.equals("'v=${{x: 1}.x}'", foldOf("class C { function f() { g('v=' + {x: 1}.x); } }"));
	}

	/**
	 * A single-fragment INTERPOLATED literal head is NOT a bare operand: `'${a + b}'`
	 * is a string, so the plan may not open with a bare `(a + b)`. The segment list
	 * cannot tell the two apart — both are one non-text segment in the first group —
	 * so `Decomposition.startsBare` carries the fact from the decomposition, which
	 * knows whether it emitted a head segment at all.
	 */
	public function testInterpolatedHeadNeverBecomesBareOperand(): Void {
		final tail: String = ''.rpad('B', 5);
		Assert.equals('\'$${a + b}${''.rpad('A', 117)}\' + \'$tail\'', foldOf(bareHeadSource("'${a + b}'", 117, 5)));
		Assert.equals('\'$${nnn}${''.rpad('A', 119)}\' + \'$tail\'', foldOf(bareHeadSource("'$nnn'", 119, 5)));
	}

	/**
	 * A `g(<head> + '<aLen a>' + '<bLen b>');` at three tabs, sized so the greedy fill
	 * cannot join `head` to the first text but CAN join the two texts — the shape whose
	 * first group is a lone non-text segment, and so the only one where the leading-bare
	 * gate decides anything.
	 */
	private function bareHeadSource(head: String, aLen: Int, bLen: Int): String {
		return [
			'class C {',
			'\tfunction f(a:Int, b:Int, nnn:String) {',
			'\t\tg(',
			'\t\t\t$head',
			'\t\t\t+ \'${''.rpad('A', aLen)}\'',
			'\t\t\t+ \'${''.rpad('B', bLen)}\'',
			'\t\t);',
			'\t}',
			'}'
		].join('\n');
	}

}
