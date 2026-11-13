package unit.lowering;

import anyparse.grammar.haxe.HaxeLexicalRegions;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexDirective;
import unit.minilex.MiniLexScan;

/**
 * The generated lexical pass's `directives` entry: it reports the keywords a grammar DECLARES with
 * `@:condDirectives` on its root rule, each at its offset and only at a token boundary, and nothing it was not
 * handed — the second grammar's keywords share no byte with Haxe's, so each side is asserted in one source.
 */
@:nullSafety(Strict)
final class GeneratedDirectiveScanTest extends Test {

	/** Haxe's opener, branches and closer, each where it is written. */
	@:pin('control')
	@:killer('M-DIRECTIVES-UNDECLARED')
	public function testEveryDeclaredHaxeKeywordIsReportedAtItsOffset(): Void {
		Assert.equals('0:#if 7:#elseif 17:#else 23:#end', render(HaxeLexicalRegions.directives('#if a\n\t#elseif b\n#else\n#end')));
	}

	/** A keyword continued by an identifier character is a longer word, never the keyword. */
	@:pin('control')
	@:killer('M-DIRECTIVES-NO-BOUNDARY')
	public function testAKeywordInsideALongerWordIsNone(): Void {
		Assert.equals('', render(HaxeLexicalRegions.directives('#ifdef a #endif #elsewhere')));
		Assert.equals('0:#if', render(HaxeLexicalRegions.directives('#if(a)')));
	}

	/** The walk does not mask: a keyword in a comment is reported, and dropping it is the caller's mask. */
	@:pin('guard')
	public function testAKeywordInACommentIsStillAnOccurrence(): Void {
		Assert.equals('3:#if', render(HaxeLexicalRegions.directives('// #if a')));
	}

	/** The second grammar's keywords are its own declaration, and Haxe's are none of them. */
	@:pin('control')
	@:killer('M-DIRECTIVES-UNDECLARED')
	public function testTheSecondGrammarReportsOnlyTheKeywordsItDeclares(): Void {
		Assert.equals('0:%when 8:%or 12:%done', render(MiniLexScan.directives('%when a %or %done #if b #end')));
		Assert.equals('%when', MiniLexScan.directiveOpen);
		Assert.equals('%or', MiniLexScan.directiveBranches.join(','));
		Assert.equals('%done', MiniLexScan.directiveClose);
	}

	/** The Haxe plugin's directive roles are the ones the grammar declares, read off the generated pass. */
	@:pin('control')
	@:killer('M-DIRECTIVES-UNDECLARED')
	public function testTheHaxeRolesComeFromTheDeclaration(): Void {
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		Assert.equals('#if', shape.conditionalIfKeyword);
		Assert.equals('#else,#elseif', (shape.conditionalElseKeywords ?? []).join(','));
		Assert.equals('#end', shape.conditionalEndKeyword);
	}

	private static function render(occurrences: Array<LexDirective>): String {
		return occurrences.map(o -> '${o.from}:${o.keyword}').join(' ');
	}

}
