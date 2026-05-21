package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;

#if sys
import sys.FileSystem;
#end

/**
 * `apq ast --select <Kind>` on an unknown kind name must still exit
 * cleanly (an empty result is not an error) and now also surface a
 * fuzzy "Did you mean: …" suggestion drawn from the kinds actually
 * present in the file. The stderr surface is not captured here —
 * exercising the code path is enough; the integration with the
 * existing `findFuzzy` helper is covered by `refs`/`uses` fuzzy
 * tests on the value-binding side.
 */
@:nullSafety(Strict)
class ApqAstSelectFuzzyTest extends Test {

	public function testUnknownKindIsCleanExit():Void {
		#if sys
		final fixture:String = writeFixture('class X { var y:Int; }');
		Assert.equals(0, Cli.run(['ast', '--select', 'NotAKind', fixture]),
			'unknown --select kind is an empty result, not an error');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTypoNearKindStillCleanExit():Void {
		#if sys
		// `ClassDeclX` is one edit away from `ClassDecl` (Levenshtein
		// tier 1: dist=1, well inside FUZZY_MAX_DIST). The substring
		// tier needs the candidate to CONTAIN the query, not the
		// inverse, so it does not apply here — Levenshtein is what
		// surfaces the suggestion. Either way the CLI still exits 0
		// (empty selector result is not an error).
		final fixture:String = writeFixture('class X {}');
		Assert.equals(0, Cli.run(['ast', '--select', 'ClassDeclX', fixture]),
			'a typo near a real kind name is still an empty result, not an error');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testChainStillSurfaceFuzzy():Void {
		#if sys
		// First kind segment `ClassDeclX` is the fuzzy-source; the
		// chain syntax must not break extraction. (The selector itself
		// still matches no nodes, exit 0.)
		final fixture:String = writeFixture('class X { var y:Int; }');
		Assert.equals(0, Cli.run(['ast', '--select', 'ClassDeclX > VarField', fixture]),
			'fuzzy extraction must use only the first kind segment');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if sys
	private static function writeFixture(source:String):String {
		return CliFixture.write('apq_ast_select_fuzzy', source);
	}
	#end
}
