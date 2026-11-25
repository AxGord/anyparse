package unit.check.haxe.design;

import anyparse.check.Check.DefaultOff;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.haxe.design.HandSourceScanner;

/**
 * The `hand-source-scanner` check: a loop that reads characters and compares two of {quote, backslash, comment opener,
 * `#if`}, or a quote beside a state local, or a bracket pair beside a depth counter moved both ways, is reported `Info`;
 * a loop that reads no character, names one feature, or keeps its state inside the iteration is not.
 */
class HandSourceScannerCheckTest extends Test {

	public function testQuoteAndBackslashAreReported(): Void {
		final vs: Array<Violation> = violations(
			'var i = 0; while (i < s.length) { final c = s.charCodeAt(i); if (c == 34) return i; if (c == 92) i++; i++; }'
		);
		Assert.equals(1, vs.length);
		Assert.equals('hand-source-scanner', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('f compares characters with a quote and a backslash') == 0, vs[0].message);
		Assert.isTrue(vs[0].message.indexOf('AST node') != -1, vs[0].message);
	}

	/** A character is named by its literal as well as its code, and an opener or directive spelled whole counts. */
	public function testLiteralFormsAreNamed(): Void {
		Assert.equals(1, violations('for (i in 0...s.length) { if (s.charAt(i) == \'"\') k++; if (s.charAt(i) == \'\\\\\') k++; }').length);
		Assert.equals(1, violations('for (i in 0...s.length) { if (s.charAt(i) == "#") k++; if (s.substr(i, 2) == "//") k++; }').length);
	}

	/** One feature alone is a character class, not a scanner. */
	@:pin('control')
	@:killer('M-HSS-ONE-FEATURE-ENOUGH')
	public function testOneFeatureAloneIsLeftAlone(): Void {
		Assert.equals(0, violations('for (i in 0...s.length) { if (s.charCodeAt(i) == 34) k++; }').length);
		Assert.equals(0, violations('for (i in 0...s.length) { if (s.charCodeAt(i) == 92) k++; }').length);
	}

	/** Comparing the features without reading a character of a text is not a scan of one. */
	@:pin('control')
	@:killer('M-HSS-READ-UNREQUIRED')
	public function testALoopThatReadsNoCharacterIsLeftAlone(): Void {
		Assert.equals(0, violations('for (i in 0...n) { if (i == 34 || i == 92) k++; }').length);
	}

	@:pin('control')
	@:killer('M-HSS-STATE-FLAG-IGNORED')
	public function testAQuoteBesideAStateLocalIsReported(): Void {
		final vs: Array<Violation> =
			violations('var inQuote = false; for (i in 0...s.length) { if (s.charCodeAt(i) == 34) inQuote = !inQuote; }');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('a quote and keeps its state in a variable') != -1, vs[0].message);
	}

	/** State born and dropped inside one iteration carries nothing from character to character. */
	@:pin('control')
	@:killer('M-HSS-STATE-DECLARED-IN-LOOP')
	public function testStateDeclaredInTheLoopIsLeftAlone(): Void {
		Assert.equals(0, violations('for (i in 0...s.length) { var q = false; if (s.charCodeAt(i) == 34) q = true; }').length);
	}

	@:pin('control')
	@:killer('M-HSS-DEPTH-IGNORED')
	public function testABracketPairBesideADepthCounterIsReported(): Void {
		final vs: Array<Violation> = violations(
			'var d = 0; for (i in 0...s.length) { final c = s.charCodeAt(i); if (c == 40) d++; else if (c == 41) d--; }'
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('a bracket pair and counts its depth in a variable') != -1, vs[0].message);
	}

	/** A counter that only grows is a position, and a pair without any counter is a test. */
	@:pin('control')
	@:killer('M-HSS-DEPTH-ONE-WAY')
	public function testACounterMovedOneWayIsLeftAlone(): Void {
		Assert.equals(
			0,
			violations('var d = 0; for (i in 0...s.length) { final c = s.charCodeAt(i); if (c == 40) d++; else if (c == 41) return; }')
				.length
		);
		Assert.equals(0, violations('for (i in 0...s.length) { final c = s.charCodeAt(i); if (c == 40 || c == 41) k = 0; }').length);
	}

	public function testAnInnerScannerIsReportedOnceAtTheOutermostLoop(): Void {
		Assert.equals(
			1,
			violations('for (j in 0...2) { for (i in 0...s.length) { final c = s.charCodeAt(i); if (c == 34) k++; if (c == 92) k++; } }')
				.length
		);
	}

	public function testNoFix(): Void {
		Assert.equals(
			0,
			CheckFixture.edits(
				new HandSourceScanner(), body('for (i in 0...s.length) { final c = s.charCodeAt(i); if (c == 34) k++; if (c == 92) k++; }')
			)
				.length
		);
	}

	public function testDefaultOff(): Void {
		Assert.notNull(Linter.byId('hand-source-scanner'));
		Assert.isTrue(Std.isOfType(new HandSourceScanner(), DefaultOff));
	}

	/** A file path holding an `allow` key is skipped; the key carries its reason as the value. */
	@:pin('control')
	@:killer('M-HSS-ALLOW-IGNORED')
	public function testAnAllowedPathIsSkipped(): Void {
		final config: LintConfig = LintConfig.parse('{"rules":{"hand-source-scanner":{"allow":{"query/Owner.hx":"it is the owner"}}}}');
		Assert.equals('config-excluded', new HandSourceScanner().skipReason('src/query/Owner.hx', config));
		Assert.isNull(new HandSourceScanner().skipReason('src/query/Other.hx', config));
		Assert.isNull(new HandSourceScanner().skipReason('src/query/Owner.hx', LintConfig.parse('{}')));
	}

	/** A character only emitted beside a compared one names nothing: the compare is what scans. */
	@:pin('control')
	@:killer('M-HSS-COMPARED-ONLY-STRING')
	public function testAnEmittedCharacterIsNotACompare(): Void {
		Assert.equals(0, violations('var o = ""; for (i in 0...s.length) { final c = s.charCodeAt(i); if (c == 92) o += \'"\'; }').length);
	}

	/** A number only assigned beside a compared character names nothing either. */
	@:pin('control')
	@:killer('M-HSS-COMPARED-ONLY-NUMBER')
	public function testANumberOnlyAssignedIsNotACompare(): Void {
		Assert.equals(0, violations('for (i in 0...s.length) { if (s.charCodeAt(i) == 92) k = 34; }').length);
	}

	@:pin('control')
	@:killer('M-HSS-CASE-PATTERN-IGNORED')
	public function testCaseValuesAreCompared(): Void {
		Assert.equals(1, violations('for (i in 0...s.length) { switch s.charCodeAt(i) { case 34: k++; case 92: k++; default: } }').length);
	}

	/** A `.code` read alone is a character read: no `charAt` / `charCodeAt` call stands beside it. */
	@:pin('control')
	@:killer('M-HSS-CODE-FIELD')
	public function testACodeReadAloneReadsACharacter(): Void {
		Assert.equals(1, violations('var c = n; for (i in 0...n) { if (c == \'"\'.code) k++; if (c == \'\\\\\'.code) k++; }').length);
	}

	/** The literal under a compared `.code` is itself compared. */
	@:pin('control')
	@:killer('M-HSS-CODE-PASSTHROUGH')
	public function testALiteralUnderACodeReadIsCompared(): Void {
		Assert.equals(
			1,
			violations('for (i in 0...s.length) { final c = s.charCodeAt(i); if (c == \'"\'.code) k++; if (c == \'\\\\\'.code) k++; }')
				.length
		);
	}

	@:pin('control')
	@:killer('M-HSS-POSTDECR-KIND')
	public function testAPostfixDecrementIsSteppingDown(): Void {
		Assert.equals(1, violations(depth('d++', 'd--')).length);
	}

	@:pin('control')
	@:killer('M-HSS-PREDECR-KIND')
	public function testAPrefixDecrementIsSteppingDown(): Void {
		Assert.equals(1, violations(depth('d++', '--d')).length);
	}

	@:pin('control')
	@:killer('M-HSS-SUB-ASSIGN-KIND')
	public function testASubtractionAssignmentIsSteppingDown(): Void {
		Assert.equals(1, violations(depth('d++', 'd -= 1')).length);
	}

	@:pin('control')
	@:killer('M-HSS-ADD-ASSIGN-ONE')
	public function testAnAdditionAssignmentIsSteppingUp(): Void {
		Assert.equals(1, violations(depth('d += 1', 'd--')).length);
	}

	/** Stepping by more than one is not a depth counter. */
	public function testASteppingByTwoIsNoDepth(): Void {
		Assert.equals(0, violations(depth('d += 2', 'd -= 2')).length);
	}

	@:pin('control')
	@:killer('M-HSS-OPENERS-LITERAL')
	public function testASpelledOpenerIsNamed(): Void {
		Assert.equals(1, violations(beside('s.substr(i, 2) == "/*"')).length);
	}

	@:pin('control')
	@:killer('M-HSS-DIRECTIVES-LITERAL')
	public function testASpelledDirectiveIsNamed(): Void {
		Assert.equals(1, violations(beside('s.substr(i, 3) == "#if"')).length);
	}

	@:pin('control')
	@:killer('M-HSS-SLASH-STAR')
	public function testASlashBesideAStarIsAnOpener(): Void {
		Assert.equals(1, violations(beside('c == 47 && s.charCodeAt(i + 1) == 42')).length);
	}

	/** Two compared slashes spell `//`; one is a path separator and names nothing. */
	@:pin('control')
	@:killer('M-HSS-DOUBLE-SLASH')
	public function testTwoComparedSlashesAreAnOpener(): Void {
		Assert.equals(1, violations(beside('c == 47 && s.charCodeAt(i + 1) == 47')).length);
		Assert.equals(0, violations(beside('c == 47')).length);
	}

	public function testAHexCodeIsNamed(): Void {
		Assert.equals(
			1, violations('for (i in 0...s.length) { final c = s.charCodeAt(i); if (c == 0x22) k++; if (c == 0x5c) k++; }').length
		);
	}

	/** A finding names the node or the declaration that knows the construct, never a hand-written owner. */
	@:pin('control')
	@:killer('M-HSS-MESSAGE-NAMES-OWNER')
	public function testTheMessageNamesNoHandWrittenOwner(): Void {
		final vs: Array<Violation> = violations('source.indexOf("(");');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('AST node or the grammar declaration') != -1, vs[0].message);
		Assert.equals(-1, vs[0].message.indexOf('LexicalRegions'), vs[0].message);
	}

	/** A search of source text for a piece of syntax is a scan: the text is the source name or a window cut from one. */
	@:pin('control')
	@:killer('M-HSS-SEARCH-IGNORED')
	public function testASyntaxSearchOfSourceTextIsReported(): Void {
		final vs: Array<Violation> = violations('final at = source.indexOf(\'(\');');
		Assert.equals(1, vs.length);
		Assert.equals('hand-source-scanner', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('f searches source text for `(` by hand') == 0, vs[0].message);
		Assert.equals(1, violations('final at = src.lastIndexOf("=>");').length);
		Assert.equals(1, violations('final at = source.indexOf("//");').length);
	}

	@:pin('control')
	@:killer('M-HSS-WINDOW-IGNORED')
	public function testAWindowCutFromATextIsSourceText(): Void {
		Assert.equals(1, violations('final at = s.substring(a, b).indexOf(":");').length);
		Assert.equals(1, violations('final at = s.substr(a, b).lastIndexOf("=");').length);
	}

	/** A dot, a newline or a name is not a piece of syntax: the search reads a path or a line, not source. */
	@:pin('control')
	@:killer('M-HSS-NEEDLE-ANY')
	public function testASearchForAnythingButSyntaxIsLeftAlone(): Void {
		Assert.equals(0, violations('final at = source.indexOf(".");').length);
		Assert.equals(0, violations('final at = source.indexOf("\\n");').length);
		Assert.equals(0, violations('final at = source.indexOf("class");').length);
		Assert.equals(0, violations('final at = source.indexOf(needle);').length);
	}

	@:pin('control')
	@:killer('M-HSS-RECEIVER-ANY')
	public function testASearchOfATextThatIsNoSourceIsLeftAlone(): Void {
		Assert.equals(0, violations('final at = path.indexOf("(");').length);
		Assert.equals(0, violations('final at = s.indexOf("(");').length);
		Assert.equals(0, violations('final at = source.contains("(");').length);
	}

	/** A search inside a loop that is no scanner is still a search of source text: the walk descends into it. */
	@:pin('control')
	@:killer('M-HSS-UNFLAGGED-LOOP-NOT-DESCENDED')
	public function testASearchInsideAnUnflaggedLoopIsReported(): Void {
		final vs: Array<Violation> = violations('for (i in 0...n) { k += source.indexOf(\'(\'); }');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('searches source text for `(`') != -1, vs[0].message);
	}

	/** A scanner loop carries one finding as the loop; the search it holds is not a second one. */
	@:pin('control')
	@:killer('M-HSS-SCANNER-LOOP-DESCENDS')
	public function testASearchInsideAScannerLoopIsReportedOnceAsTheLoop(): Void {
		final vs: Array<Violation> = violations(
			'for (i in 0...s.length) { final c = s.charCodeAt(i); if (c == 34) k++; if (c == 92) k += source.indexOf(\'(\'); }'
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('compares characters with a quote and a backslash') != -1, vs[0].message);
	}

	private function body(statements: String): String {
		return 'class C {\n\tfunction f(s:String, n:Int):Int {\n\t\tvar k = 0;\n\t\t$statements\n\t\treturn k;\n\t}\n}';
	}

	private function violations(statements: String): Array<Violation> {
		return CheckFixture.violations(new HandSourceScanner(), body(statements));
	}

	/** A loop comparing `(` and `)` that steps a counter `up` on one and `down` on the other. */
	private function depth(up: String, down: String): String {
		return 'var d = 0; for (i in 0...s.length) { final c = s.charCodeAt(i); if (c == 40) $up; else if (c == 41) $down; }';
	}

	/** A loop comparing a quote and, beside it, the `test`. */
	private function beside(test: String): String {
		return 'for (i in 0...s.length) { final c = s.charCodeAt(i); if (c == 34) k++; if ($test) k++; }';
	}

}
