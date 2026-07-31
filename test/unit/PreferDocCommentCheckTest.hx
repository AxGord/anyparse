package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Linter;
import anyparse.check.PreferDocComment;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.runtime.Span;

/**
 * The `prefer-doc-comment` check: a run of whole-line `//` comments directly above a
 * type or member declaration is rewritten to a doc comment. Each of the eight gates
 * gets a DISCRIMINATING fixture — one that only that gate rejects — so a gate that
 * stops working cannot hide behind a later one.
 */
class PreferDocCommentCheckTest extends Test {

	public function testTypeDeclFlagged(): Void {
		final vs: Array<Violation> = violations('// A type.\nclass C {}');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-doc-comment', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('line comment above a declaration; use a doc comment', vs[0].message);
	}

	public function testTypeDeclFixed(): Void {
		Assert.equals('/** A type. */\nclass C {}', applyFix('// A type.\nclass C {}'));
	}

	public function testMemberFunctionFixed(): Void {
		Assert.equals(
			'class C {\n\t/** Does it. */\n\tpublic function f():Void {}\n}',
			applyFix('class C {\n\t// Does it.\n\tpublic function f():Void {}\n}')
		);
	}

	public function testMemberVarFixed(): Void {
		Assert.equals('class C {\n\t/** The count. */\n\tvar x:Int;\n}', applyFix('class C {\n\t// The count.\n\tvar x:Int;\n}'));
	}

	/** The multi-line shape: ` * ` marker column, star-aligned ` *\/` close. */
	public function testMultiLineRunFixed(): Void {
		Assert.equals(
			'class C {\n\t/**\n\t * One.\n\t * Two.\n\t */\n\tvar x:Int;\n}', applyFix('class C {\n\t// One.\n\t// Two.\n\tvar x:Int;\n}')
		);
	}

	/** An empty comment line inside a run becomes a bare `<indent> *` paragraph break. */
	public function testEmptyLineInRunBecomesBareStar(): Void {
		Assert.equals(
			'class C {\n\t/**\n\t * One.\n\t *\n\t * Two.\n\t */\n\tvar x:Int;\n}',
			applyFix('class C {\n\t// One.\n\t//\n\t// Two.\n\tvar x:Int;\n}')
		);
	}

	/** Only ONE space after `//` is the marker; the rest is the author's own indentation. */
	public function testRelativeIndentKept(): Void {
		Assert.equals(
			'class C {\n\t/**\n\t * One:\n\t *   deeper\n\t */\n\tvar x:Int;\n}',
			applyFix('class C {\n\t// One:\n\t//   deeper\n\tvar x:Int;\n}')
		);
	}

	/** The anchor is the start of the `@:meta` / modifier run, not the declaration keyword. */
	public function testMetaAndModifiersBetweenCommentAndNameFlagged(): Void {
		Assert.equals(
			'class C {\n\t/** Docs. */\n\t@:allow(D)\n\tpublic static inline function f():Void {}\n}',
			applyFix('class C {\n\t// Docs.\n\t@:allow(D)\n\tpublic static inline function f():Void {}\n}')
		);
	}

	public function testEnumAbstractFlagged(): Void {
		Assert.equals(1, violations('// Kinds.\nenum abstract K(Int) {\n\tvar A = 0;\n}').length);
	}

	public function testFinalClassFlagged(): Void {
		Assert.equals(1, violations('// A type.\nfinal class C {}').length);
	}

	/**
	 * A trailing comment belongs to the declaration it SHARES A LINE WITH, never to the one
	 * below it — that is what gate 1 keeps out of the above-line run mechanism, and what the
	 * trailing mechanism then picks up for the right owner. NOT a discriminating test of
	 * gate 1: with whole-line ownership removed the run mechanism still rejects this, by the
	 * indent gate (the code before the comment becomes its "indent").
	 * `testTrailingCommentOnDeclLineDoesNotJoinRun` is the gate's own fixture.
	 */
	public function testTrailingCommentAfterCodeDocumentsItsOwnDecl(): Void {
		Assert.equals(
			'class C {\n\t/** note */\n\tvar a:Int;\n\tvar x:Int;\n}', applyFix('class C {\n\tvar a:Int; // note\n\tvar x:Int;\n}')
		);
	}

	/** TRAILING — the user's shape: a field's own remark becomes that field's doc. */
	public function testTrailingFieldCommentHoisted(): Void {
		Assert.equals(
			'class C {\n\t/** when this session started */\n\tpublic final startTime:Date = Date.now();\n}',
			applyFix('class C {\n\tpublic final startTime:Date = Date.now(); // when this session started\n}')
		);
	}

	/** TRAILING — a function's OPENING line qualifies: its header closes with `{` on that line. */
	public function testTrailingCommentOnFunctionOpeningLineHoisted(): Void {
		Assert.equals(
			'class C {\n\t/** legacy sort */\n\toverride private function f(x:Int):Int {\n\t\treturn x;\n\t}\n}',
			applyFix('class C {\n\toverride private function f(x:Int):Int { // legacy sort\n\t\treturn x;\n\t}\n}')
		);
	}

	/** TRAILING — a type declaration's opening line qualifies the same way. */
	public function testTrailingCommentOnTypeOpeningLineHoisted(): Void {
		Assert.equals('/** the model */\nclass C {\n\tvar x:Int;\n}', applyFix('class C { // the model\n\tvar x:Int;\n}'));
	}

	/** TRAILING — the doc lands at the ANCHOR, above the `@:meta` / modifier run, where the compiler reads it. */
	public function testTrailingCommentHoistsAboveMetaRun(): Void {
		Assert.equals(
			'class C {\n\t/** how many so far */\n\t@:allow(D)\n\tpublic var count:Int = 0;\n}',
			applyFix('class C {\n\t@:allow(D)\n\tpublic var count:Int = 0; // how many so far\n}')
		);
	}

	/**
	 * TRAILING — a declaration at column 0 hoists with an EMPTY indent before it. Also pins
	 * that a one-line `class C {} // note` does NOT qualify: its code ends with the closing
	 * `}`, and a closing brace is not a declaration line.
	 */
	public function testTrailingCommentAtModuleLevelHoisted(): Void {
		Assert.equals('/** the kinds */\nenum E {\n\tA;\n}', applyFix('enum E { // the kinds\n\tA;\n}'));
		Assert.equals(0, violations('class C {} // the model').length);
	}

	/** TRAILING — a line declaring TWO members has no single owner. */
	public function testTrailingCommentOnMultiDeclLineKept(): Void {
		Assert.equals(0, violations('class C {\n\tpublic var a:Int; public var b:Int; // ambiguous\n}').length);
	}

	/** TRAILING — a closing brace is not a declaration line. */
	public function testTrailingCommentOnClosingBraceKept(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg();\n\t} // done\n}').length);
	}

	/** TRAILING — a statement inside a body is not a declaration. */
	public function testTrailingCommentOnStatementKept(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg(); // why\n\t}\n}').length);
	}

	/** TRAILING — a `case` arm is not a declaration. */
	public function testTrailingCommentOnCaseKept(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f(v:Int):Void {\n\t\tswitch v {\n\t\t\tcase 1: // first\n\t\t}\n\t}\n}').length);
	}

	/** TRAILING — a CONTINUATION line of a wrapped declaration carries no anchor, so it never qualifies. */
	public function testTrailingCommentOnContinuationLineKept(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f(\n\t\ta:Int\n\t):Void {} // wrapped\n}').length);
	}

	/** TRAILING — the content gates are the run's own: a task marker is still not documentation. */
	public function testTrailingTaskMarkerKept(): Void {
		Assert.equals(0, violations('class C {\n\tpublic var d:Int = 0; // TODO: Date\n}').length);
	}

	/** TRAILING — commented-out code as a tail is still code. */
	public function testTrailingCommentedOutCodeKept(): Void {
		Assert.equals(0, violations("class C {\n\tpublic var d:Int = 0; // tmsMessages.getMessageById('59');\n}").length);
	}

	/** TRAILING — a declaration that already has a doc is never given a second one. */
	public function testTrailingCommentOnDocumentedDeclKept(): Void {
		Assert.equals(0, violations('class C {\n\t/** Documented. */\n\tpublic var d:Int = 0; // extra\n}').length);
	}

	/** TRAILING — decoration is a divider wherever it sits. */
	public function testTrailingSeparatorKept(): Void {
		Assert.equals(0, violations('class C {\n\tpublic var d:Int = 0; // ----\n}').length);
	}

	/**
	 * TRAILING — a `//` inside a STRING is not a comment. The token scan is string-aware, so
	 * the initializer's URL never reaches the mechanism; the real tail on the same line does.
	 */
	public function testCommentMarkerInsideStringIsNotATrailingComment(): Void {
		Assert.equals(0, violations("class C {\n\tpublic var s:String = 'https://x/y';\n}").length);
		Assert.equals(
			"class C {\n\t/** a url */\n\tpublic var s:String = 'https://x/y';\n}",
			applyFix("class C {\n\tpublic var s:String = 'https://x/y'; // a url\n}")
		);
	}

	/** TRAILING — a `//` run directly above the declaration owns it; the two mechanisms never stack two docs. */
	public function testTrailingCommentBelowRunKept(): Void {
		Assert.equals(
			'class C {\n\t/** The count. */\n\tvar x:Int; // in units\n}',
			applyFix('class C {\n\t// The count.\n\tvar x:Int; // in units\n}')
		);
	}

	/** TRAILING — a CRLF file keeps its terminator on both the cut line and the inserted doc. */
	public function testTrailingCommentCrlfPreserved(): Void {
		Assert.equals('class C {\r\n\t/** note */\r\n\tvar x:Int;\r\n}', applyFix('class C {\r\n\tvar x:Int; // note\r\n}'));
	}

	/**
	 * GATE 1, discriminating — the trailing comment sits on the very next line, so without
	 * whole-line ownership it would JOIN the run; the run's lines would then disagree on
	 * indent and the whole conversion would be LOST. With the gate, the run above converts
	 * and the trailing remark stays where it is.
	 */
	public function testTrailingCommentOnDeclLineDoesNotJoinRun(): Void {
		Assert.equals(
			'class C {\n\t/** The count. */\n\tvar x:Int; // in units\n}',
			applyFix('class C {\n\t// The count.\n\tvar x:Int; // in units\n}')
		);
	}

	/** GATE 2 — one blank line detaches the run from the declaration. */
	public function testBlankLineBeforeDeclKept(): Void {
		Assert.equals(0, violations('class C {\n\t// note\n\n\tvar x:Int;\n}').length);
	}

	/** GATE 3 — the run sits at a different column than the declaration it precedes. */
	public function testIndentMismatchKept(): Void {
		Assert.equals(0, violations('class C {\n// note\n\tvar x:Int;\n}').length);
	}

	/** GATE 3 — the run's own lines disagree on indent, so it is not one block of prose. */
	public function testMixedIndentRunKept(): Void {
		Assert.equals(0, violations('class C {\n\t// one\n  // two\n\tvar x:Int;\n}').length);
	}

	/** GATE 4 — a doc directly above the run: converting would leave two adjacent docs. */
	public function testExistingDocAboveRunKept(): Void {
		Assert.equals(0, violations('class C {\n\t/** Real doc. */\n\t// note\n\tvar x:Int;\n}').length);
	}

	/**
	 * A doc BETWEEN the run and the declaration: the run documents nothing. Held by GATE 2
	 * (the doc, not the declaration, is what follows the run) — verified by ablation, not
	 * by gate 4.
	 */
	public function testExistingDocBelowRunKept(): Void {
		Assert.equals(0, violations('class C {\n\t// note\n\t/** Real doc. */\n\tvar x:Int;\n}').length);
	}

	/** GATE 5 — a tooling directive is a machine instruction; burying it in a doc silences it. */
	public function testDirectiveRunKept(): Void {
		Assert.equals(0, violations('class C {\n\t// noqa: naming\n\tvar x:Int;\n}').length);
		Assert.equals(0, violations('class C {\n\t// CHECKSTYLE:OFF\n\tvar x:Int;\n}').length);
		Assert.equals(0, violations('class C {\n\t// @formatter:off\n\tvar x:Int;\n}').length);
		Assert.equals(0, violations('class C {\n\t// #region fields\n\tvar x:Int;\n}').length);
	}

	/** GATE 5 — one directive line skips the WHOLE run, prose lines included. */
	public function testDirectiveSkipsWholeRun(): Void {
		Assert.equals(0, violations('class C {\n\t// The count.\n\t// noqa\n\tvar x:Int;\n}').length);
	}

	/** GATE 6 — a reminder to change the code is not a description of it. */
	public function testTaskMarkerRunKept(): Void {
		Assert.equals(0, violations('class C {\n\t// TODO: widen this\n\tvar x:Int;\n}').length);
		Assert.equals(0, violations('class C {\n\t// fixme later\n\tvar x:Int;\n}').length);
		Assert.equals(0, violations('class C {\n\t// A HACK for now\n\tvar x:Int;\n}').length);
		Assert.equals(0, violations('class C {\n\t// xxx\n\tvar x:Int;\n}').length);
	}

	/** GATE 7 — commented-out code, by terminator and by opening keyword. */
	public function testCommentedOutCodeKept(): Void {
		Assert.equals(0, violations('class C {\n\t// g();\n\tvar x:Int;\n}').length);
		Assert.equals(0, violations('class C {\n\t// if (b) {\n\tvar x:Int;\n}').length);
		Assert.equals(0, violations('class C {\n\t// return\n\tvar x:Int;\n}').length);
		Assert.equals(0, violations('class C {\n\t// import a.B\n\tvar x:Int;\n}').length);
		Assert.equals(0, violations('class C {\n\t// }\n\tvar x:Int;\n}').length);
	}

	/**
	 * GATE 7 — the eight realistic commented-out shapes that a negative list of code forms
	 * let through, each rejected by the positive prose criterion instead. Regression pins
	 * for the review that found them; a shape that starts reading as prose again is a leak.
	 */
	public function testRealisticCommentedOutCodeKept(): Void {
		for (line in [
			'public static final addedUserList:Map<Int, Users> = []; // demo storage',
			'override public function dispose(): Void',
			'private static var cache:Map<String, Int> = new Map()',
			'x = compute(y)',
			'@:keep @:noCompletion',
			'else if (b) doThing()',
			'new Foo().bar()',
			'try { risky() } catch (e:Exception) {}  see note'
		]) Assert.equals(0, violations('class C {\n\t// $line\n\tvar x:Int;\n}').length, 'converted code: $line');
	}

	/** GATE 7 — the prose the criterion must keep converting; each is a real comment shape. */
	public function testRealisticProseFlagged(): Void {
		for (line in [
			'If unset, the default applies',
			'called from Editor.hx',
			'fit movieclip to sprite width and height (center align)',
			'access private fields',
			'for internal use only',
			'Note: see the header',
			'macOS filesystems return filenames in NFD; servers and Windows use NFC.',
			'Returns {x, y} in stage space.'
		]) Assert.equals(1, violations('class C {\n\t// $line\n\tvar x:Int;\n}').length, 'declined prose: $line');
	}

	/**
	 * GATE 7 — `;` `{` `}` are ordinary English punctuation, so they read as code only in a
	 * STRUCTURAL position: a `;` with nothing but a trailing comment behind it, a `{` at the
	 * line end, a `}` opening or ending the line. These four are the real commented-out
	 * declarations the consuming project carries; each also fails the head test, which is
	 * what keeps them declining now that the characters alone no longer do.
	 */
	public function testCommentedOutDeclarationsStillKept(): Void {
		for (line in [
			"public static inline final API_URL:String = 'https://example.test/api/';",
			'private static var simulateOldToken:Bool = false;',
			'import openfl.filters.GlowFilter;',
			'private var initialPlayerHeight:Float;'
		]) Assert.equals(0, violations('class C {\n\t// $line\n\tvar x:Int;\n}').length, 'converted code: $line');
	}

	/**
	 * GATE 7, discriminating for the CONTROL heads — `for` / `while` open English sentences
	 * too, so they read as code only with the construct's bracket behind them. These two
	 * carry no other code punctuation: the space before `(` is prose spacing, not a call.
	 */
	public function testControlHeadWithBracketKept(): Void {
		Assert.equals(0, violations('class C {\n\t// for (x in xs)\n\tvar x:Int;\n}').length);
		Assert.equals(0, violations('class C {\n\t// while (running)\n\tvar x:Int;\n}').length);
	}

	/** GATE 7 is CASE-SENSITIVE, so a sentence opening with a keyword word stays prose. */
	public function testProseOpeningWithCapitalisedKeywordFlagged(): Void {
		Assert.equals(1, violations('class C {\n\t// If unset, the default applies\n\tvar x:Int;\n}').length);
	}

	/** GATE 9 — a rule line is a visual divider, not a description. */
	public function testSeparatorRunKept(): Void {
		Assert.equals(0, violations('class C {\n\t//----\n\tvar x:Int;\n}').length);
		Assert.equals(0, violations('class C {\n\t// === \n\tvar x:Int;\n}').length);
		// A DECORATED label is a divider too, even above a declaration that stands alone.
		Assert.equals(0, violations('class C {\n\t// --- Mobile touch ---\n\tvar x:Int;\n}').length);
		// The same words WITHOUT the decoration are an ordinary run and still convert.
		Assert.equals(1, violations('class C {\n\t// Mobile touch\n\tvar x:Int;\n}').length);
		// A sentence is not turned into a divider by a leading dash.
		Assert.equals(1, violations('class C {\n\t// - the count of items currently on the pitch\n\tvar x:Int;\n}').length);
	}

	/**
	 * GATE 10 — a label above a RUN of siblings describes all of them; attaching it to
	 * sibling #1 as that member's haxedoc misdescribes the member and loses the label.
	 */
	public function testGroupLabelAboveSiblingsKept(): Void {
		Assert.equals(
			0,
			violations('class C {\n\t// Button\n\tpublic static inline final A:Int = 1;\n\tpublic static inline final B:Int = 2;\n}').length
		);
	}

	/** GATE 10 — the LAST label of a stack is still a label: siblings above it count too. */
	public function testGroupLabelOverLastSiblingKept(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tpublic static inline final A:Int = 1;\n\t// Slider\n\tpublic static inline final B:Int = 2;\n}').length
		);
	}

	/** GATE 10 — a declaration alone in its group and its section is documented, not labelled. */
	public function testLoneDeclarationInGroupFlagged(): Void {
		Assert.equals(1, violations('class C {\n\n\t// The count.\n\tvar x:Int;\n\n}').length);
	}

	/**
	 * GATE 10, section half — a codebase that blank-line-separates its members writes a
	 * section label the same way it writes a doc, so the blank-line group alone cannot tell
	 * them apart. What ends a section is the NEXT label, not the next blank line.
	 */
	public function testBlankSeparatedSectionLabelKept(): Void {
		Assert.equals(
			0,
			violations('class C {\n\t// Popup\n\tpublic static inline final A:Int = 1;\n\n\tpublic static inline final B:Int = 2;\n}').length
		);
	}

	/**
	 * GATE 10, section half — the section stops at the OWNER's end. Two types in one module
	 * hold their members at the same depth, so an indent-bounded scan read `class Two`'s
	 * field as a sibling of `class One`'s and declined a real doc.
	 */
	public function testSectionDoesNotCrossTypeBoundary(): Void {
		Assert.equals(1, violations('class One {\n\t// The count.\n\tvar a:Int;\n}\n\nclass Two {\n\tvar b:Int;\n}').length);
	}

	/**
	 * GATE 11 — the heading tally is per OWNER. A constants table's headings must not
	 * outvote, and silently suppress, a sibling type's genuine per-member docs.
	 */
	public function testHeadingConventionDoesNotLeakAcrossTypes(): Void {
		Assert.equals(
			2,
			violations(
				'class Tables {\n\t// Popup\n\tpublic static inline final A:Int = 1;\n\n\tpublic static inline final B:Int = 2;\n\n'
				+ '\t// Button\n\tpublic static inline final C1:Int = 3;\n\n\tpublic static inline final D:Int = 4;\n\n'
				+ '\t// Slider\n\tpublic static inline final E:Int = 5;\n\n\tpublic static inline final F:Int = 6;\n}\n\n'
				+ 'class Model {\n\t// The name.\n\tpublic var name:String;\n\n\t// The date.\n\tpublic var date:String;\n}'
			).length
		);
	}

	/**
	 * GATE 10, section half — a separately-documented sibling ends the section: a run cannot
	 * label a span that another declaration's own doc already interrupts.
	 */
	public function testDocumentedSiblingEndsSection(): Void {
		Assert.equals(
			1, violations('class C {\n\t// The count.\n\tvar a:Int;\n\n\t/** The other. */\n\tvar b:Int;\n\n\tvar c:Int;\n}').length
		);
	}

	/** GATE 10, section half — a following member of a DIFFERENT kind is not what a label groups. */
	public function testSectionStopsAtDifferentMemberKind(): Void {
		Assert.equals(1, violations('class C {\n\t// The count.\n\tvar x:Int;\n\n\tpublic function f():Void {}\n}').length);
	}

	/**
	 * GATE 11 — a file whose `//` runs mostly label SECTIONS is using them as headings, and
	 * its single-member headings (`// Slider` over the one constant that needs it) read
	 * exactly like a doc. The convention decides: here two runs label sections and one sits
	 * over a lone constant, so none converts.
	 */
	public function testHeadingConventionSuppressesLoneHeading(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\t// Popup\n\tpublic static inline final A:Int = 1;\n\n\tpublic static inline final B:Int = 2;\n\n'
				+ '\t// Button\n\tpublic static inline final C1:Int = 3;\n\n\tpublic static inline final D:Int = 4;\n\n'
				+ '\t// Slider\n\tpublic static inline final E:Int = 5;\n}'
			).length
		);
	}

	/**
	 * GATE 11, the inverse — a file that documents its members one at a time keeps every
	 * doc, even though one run happens to precede two of them. A single grouping among many
	 * per-member docs is an author grouping two related fields, not a convention.
	 */
	public function testPerMemberDocConventionKeepsSingleMemberDocs(): Void {
		Assert.equals(
			3,
			violations(
				'class C {\n\t// The name.\n\tpublic var a:String;\n\n\t// The date.\n\tpublic var b:String;\n\n'
				+ '\t// The hour.\n\tpublic var c:String;\n\n\t// A pair.\n\tpublic var d:String;\n\n\tpublic var e:String;\n}'
			).length
		);
	}

	/** GATE 8 — triple-slash is a section-label convention, not a per-declaration doc. */
	public function testTripleSlashRunKept(): Void {
		Assert.equals(0, violations('class C {\n\t/// Fields\n\tvar x:Int;\n}').length);
	}

	/** A content-free run is `empty-comment`'s shape — converting would emit an empty doc. */
	public function testContentFreeRunKept(): Void {
		Assert.equals(0, violations('class C {\n\t//\n\t//\n\tvar x:Int;\n}').length);
	}

	/** A body carrying `*\/` cannot be wrapped: the doc would end mid-text and the tail become code. */
	public function testBodyWithBlockCloseKept(): Void {
		Assert.equals(0, violations('class C {\n\t// see /* x */ above\n\tvar x:Int;\n}').length);
	}

	/** A run above a STATEMENT is `prefer-line-comment`'s domain, not this rule's. */
	public function testCommentAboveStatementKept(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\t// note\n\t\tg();\n\t}\n}').length);
	}

	/** A member guarded by `#if` still converts, and the result parses. */
	public function testMemberInsideConditionalFlagged(): Void {
		final src: String = 'class C {\n\t#if debug\n\t// The count.\n\tvar x:Int;\n\t#end\n}';
		Assert.equals(1, violations(src).length);
		final fixed: String = applyFix(src);
		Assert.equals('class C {\n\t#if debug\n\t/** The count. */\n\tvar x:Int;\n\t#end\n}', fixed);
		Assert.notNull(new HaxeQueryPlugin().parseFile(fixed));
	}

	/**
	 * Kinds outside `typeDeclKinds` / `memberDeclKinds` are not anchors — a module-level
	 * function or variable and an enum constructor are left alone by design, so a run above
	 * one keeps its `//` form.
	 */
	public function testNonAnchorDeclarationsKept(): Void {
		Assert.equals(0, violations('// Helper.\nfunction f():Void {}').length);
		Assert.equals(0, violations('// The seed.\nvar seed:Int = 0;').length);
		Assert.equals(0, violations('enum E {\n\t// The first.\n\tA;\n\tB;\n}').length);
	}

	public function testBlockCommentKept(): Void {
		Assert.equals(0, violations('class C {\n\t/* note */\n\tvar x:Int;\n}').length);
	}

	public function testCommentInStringLiteralKept(): Void {
		Assert.equals(0, violations('class C {\n\tvar s:String = "// x";\n\tvar x:Int;\n}').length);
	}

	/** A CRLF file keeps its terminator: the join re-emits it. */
	public function testCrlfTerminatorPreserved(): Void {
		Assert.equals(
			'class C {\r\n\t/**\r\n\t * One.\r\n\t * Two.\r\n\t */\r\n\tvar x:Int;\r\n}',
			applyFix('class C {\r\n\t// One.\r\n\t// Two.\r\n\tvar x:Int;\r\n}')
		);
	}

	/**
	 * The emitted multi-line shape is a FIXED POINT of the default `Verbatim` writer, so a
	 * fixed site never drifts on the next `fmt` — the interface contract with
	 * `BlockCommentNormalizer.canonicalDoc`, which emits the same bytes under
	 * `commentStyle: Javadoc`.
	 */
	public function testFixOutputSurvivesWriteRoundTrip(): Void {
		final fixed: String = applyFix('class C {\n\t// One.\n\t//\n\t// Two.\n\tvar x:Int;\n}');
		Assert.equals('$fixed\n', HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(fixed)));
	}

	/** The single-line shape is a fixed point too. */
	public function testSingleLineFixOutputSurvivesWriteRoundTrip(): Void {
		final fixed: String = applyFix('class C {\n\t// The count.\n\tvar x:Int;\n}');
		Assert.equals('$fixed\n', HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(fixed)));
	}

	public function testDefaultOff(): Void {
		Assert.isTrue(new PreferDocComment() is DefaultOff);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-doc-comment'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-doc-comment'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('// note\nclass Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferDocComment().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: PreferDocComment = new PreferDocComment();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
