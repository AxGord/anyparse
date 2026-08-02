package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.RedundantCondCompParens;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;

/**
 * The `redundant-condcomp-parens` check: parentheses around a conditional-compilation condition
 * that is ONE bare flag are noise (`#if (sys)` parses exactly as `#if sys`), so they are flagged
 * `Info` and dropped. Everything the pair could be load-bearing for — a compound condition, a
 * version comparison, a negation, a nested pair — keeps it.
 *
 * The check is a pure source scan through `CondDirectives`, which is why the fixtures below reach
 * positions no node walk does: a directive at module level, inside a class body, nested in
 * another region's branch, and inline on one line with the code it guards.
 */
class RedundantCondCompParensCheckTest extends Test {

	public function testSingleFlagFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\t#if (sys)\n\t\tg();\n\t\t#end\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('redundant-condcomp-parens', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('sys') >= 0);
	}

	public function testFixDropsTheParens(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t#if (sys)\n\t\tg();\n\t\t#end\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t#if sys\n\t\tg();\n\t\t#end\n\t}\n}', applyFix(src));
	}

	public function testBareFlagNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\t#if sys\n\t\tg();\n\t\t#end\n\t}\n}').length);
	}

	public function testElseIfBranchFlaggedAndFixed(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t#if (sys)\n\t\tg();\n\t\t#elseif (js)\n\t\th();\n\t\t#end\n\t}\n}';
		Assert.equals(2, violations(src).length);
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t#if sys\n\t\tg();\n\t\t#elseif js\n\t\th();\n\t\t#end\n\t}\n}', applyFix(src));
	}

	public function testCompoundConjunctionKept(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\t#if (cpp && debug)\n\t\tg();\n\t\t#end\n\t}\n}').length);
	}

	public function testCompoundDisjunctionKept(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t#if (windows || mac || linux)\n\t\tg();\n\t\t#end\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testVersionComparisonKept(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t#if (haxe_ver >= "3.1.0")\n\t\tg();\n\t\t#end\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testNegationKept(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\t#if (!flag)\n\t\tg();\n\t\t#end\n\t}\n}').length);
	}

	public function testNestedParenPairKept(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\t#if ((sys))\n\t\tg();\n\t\t#end\n\t}\n}').length);
	}

	public function testInteriorWhitespaceFlaggedAndFixed(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t#if ( sys )\n\t\tg();\n\t\t#end\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t#if sys\n\t\tg();\n\t\t#end\n\t}\n}', applyFix(src));
	}

	/** Module level and class body are the same scan — a directive is not a node, so it has no host kind to gate on. */
	public function testModuleLevelAndClassBodyBothFlagged(): Void {
		final src: String = '#if (sys)\nimport sys.io.File;\n#end\n\nclass C {\n\t#if (debug)\n\tvar x:Int = 0;\n\t#end\n}';
		Assert.equals(2, violations(src).length);
	}

	/** A region nested in another region's branch: the inner flag drops its pair, the outer compound keeps its own. */
	public function testNestedRegionFlagsInnerOnly(): Void {
		final src: String =
			'class C {\n\tfunction f():Void {\n\t\t#if (windows || mac)\n\t\t#if (mobile)\n\t\tg();\n\t\t#end\n\t\t#end\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('mobile') >= 0);
		final fixed: String =
			'class C {\n\tfunction f():Void {\n\t\t#if (windows || mac)\n\t\t#if mobile\n\t\tg();\n\t\t#end\n\t\t#end\n\t}\n}';
		Assert.equals(fixed, applyFix(src));
	}

	/**
	 * An INLINE region carries ordinary code on the directive's own line. The condition span stops
	 * at the closing parenthesis, so the fix rewrites the condition and leaves the guarded code —
	 * and the `#end` that follows it — untouched.
	 */
	public function testInlineRegionKeepsItsCode(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t#if (js) g(); #end\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t#if js g(); #end\n\t}\n}', applyFix(src));
	}

	/** A trailing line comment sits outside the condition span and survives the fix verbatim, indentation included. */
	public function testFixKeepsIndentAndTrailingComment(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t\t#if (sys) // note\n\t\t\tg();\n\t\t\t#end\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t\t#if sys // note\n\t\t\tg();\n\t\t\t#end\n\t}\n}', applyFix(src));
	}

	/**
	 * The parenthesis can be the only separator between the keyword and the flag. Dropping it bare
	 * would weld them into one word (`#ifsys`), which the directive lexer reads as a different
	 * keyword, so the fix re-separates.
	 */
	public function testFixSeparatesGluedKeyword(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t#if(sys)\n\t\tg();\n\t\t#end\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t#if sys\n\t\tg();\n\t\t#end\n\t}\n}', applyFix(src));
	}

	/** The same weld on the trailing side: an inline region whose code starts flush against the `)`. */
	public function testFixSeparatesGluedTrailingCode(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t#if (js)g(); #end\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t#if js g(); #end\n\t}\n}', applyFix(src));
	}

	public function testDirectiveInsideLineCommentNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\t// #if (sys)\n\t\tg();\n\t}\n}').length);
	}

	public function testDirectiveInsideBlockCommentNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\t/* #if (sys) */\n\t\tg();\n\t}\n}').length);
	}

	public function testDirectiveInsideStringNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar s:String = "#if (sys)";\n\t}\n}').length);
	}

	/**
	 * A DOTTED define (`#if (target.unicode)`) is delimited correctly by the reader but is not
	 * "one bare flag", so the pair stays. Pinned because the reader learned dotted names for the
	 * `lit` consumer's sake, and that must not silently widen this rule's shape.
	 */
	public function testDottedDefineKept(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\t#if (target.unicode)\n\t\tg();\n\t\t#end\n\t}\n}').length);
	}

	/** A keyword that takes no condition never grows one, however condition-shaped the text after it looks. */
	public function testKeywordWithoutConditionIgnoresTrailingParens(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f():Void {\n\t\t#if sys\n\t\tg();\n\t\t#else (mac)\n\t\t#end (sys)\n\t}\n}').length
		);
	}

	/** A directive that ends the file with no trailing newline: the trailing-weld probe reads past the end. */
	public function testDirectiveAtEndOfFileWithoutNewline(): Void {
		Assert.equals('#if sys', applyFix('#if (sys)'));
	}

	/** CRLF: the carriage return terminates the condition exactly as a bare newline does. */
	public function testCrlfLineEndings(): Void {
		Assert.equals('class C {\r\n\t#if sys\r\n\t#end\r\n}', applyFix('class C {\r\n\t#if (sys)\r\n\t#end\r\n}'));
	}

	/**
	 * `fix` is handed a SUBSET of what `run` reported whenever a finding was suppressed or another
	 * rule's edits won an overlap, so it must edit exactly the sites it was given.
	 */
	public function testFixEditsOnlyTheGivenSubset(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t#if (sys)\n\t\tg();\n\t\t#elseif (js)\n\t\th();\n\t\t#end\n\t}\n}';
		final check: RedundantCondCompParens = new RedundantCondCompParens();
		final all: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(2, all.length);
		final edited: String = RefactorSupport.applyEdits(src, check.fix(src, [all[1]], new HaxeQueryPlugin()));
		Assert.equals('class C {\n\tfunction f():Void {\n\t\t#if (sys)\n\t\tg();\n\t\t#elseif js\n\t\th();\n\t\t#end\n\t}\n}', edited);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-condcomp-parens'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-condcomp-parens'));
	}

	/**
	 * The check never parses, so an unparseable file is scanned like any other — the opposite of a
	 * node-driven rule, which silently reports nothing there. Asserted so the property is not lost
	 * to a later "just parse it" refactor.
	 */
	public function testUnparseableSourceStillScanned(): Void {
		Assert.equals(1, violations('class Bad {\n\t#if (sys)\n\tfunction f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantCondCompParens().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: RedundantCondCompParens = new RedundantCondCompParens();
		return RefactorSupport.applyEdits(
			src, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin())
		);
	}

}
