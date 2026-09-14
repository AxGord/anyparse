package unit.query;

#if (sys || nodejs)
import sys.FileSystem;
#end
import anyparse.query.Cli;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * `apq ast --select <Kind>` on a kind this grammar's parser projects no node for: the
 * fuzzy "Did you mean: …" suggestion drawn from the kinds actually present in the
 * file, and a USAGE exit rather than a clean one.
 *
 * This class used to assert the opposite, on the reading that a read-only
 * walker's empty result is never an error. The distinction it was missing: a kind that IS projected and merely absent here stays exit 0,
 * because the walk legitimately found nothing; a spelling no rule projects can
 * never match anything and is the caller's mistake. The stderr surface is not
 * captured here — `unit.cli.ApqKindVocabularyCliTest` pins the message.
 */
@:nullSafety(Strict)
class ApqAstSelectFuzzyTest extends Test {

	public function testUnknownKindIsAUsageError(): Void {
		#if (sys || nodejs)
		final fixture: String = writeFixture('class X { var y:Int; }');
		// Exit 0 used to be the answer, on the reading that an empty result is never an error. It is not an
		// empty result: `NotAKind` is a spelling no file could ever match, and a script driving
		// `ast` had no way to separate it from a node that is simply somewhere else.
		Assert.equals(2, Cli.run(['ast', '--select', 'NotAKind', fixture]), 'a kind no grammar projects is a usage error');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTypoNearKindIsAUsageError(): Void {
		#if (sys || nodejs)
		// `ClassDeclX` is one edit away from `ClassDecl` (Levenshtein
		// tier 1: dist=1, well inside FUZZY_MAX_DIST). The substring
		// tier needs the candidate to CONTAIN the query, not the
		// inverse, so it does not apply here — Levenshtein is what
		// surfaces the suggestion. A typo is exactly the case the
		// usage exit is for: the suggestion names the fix, and the
		// status says a fix is needed.
		final fixture: String = writeFixture('class X {}');
		Assert.equals(2, Cli.run(['ast', '--select', 'ClassDeclX', fixture]), 'a typo near a real kind name is a usage error');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testChainStillSurfaceFuzzy(): Void {
		#if (sys || nodejs)
		// First kind segment `ClassDeclX` is the fuzzy-source; the chain syntax must not break
		// extraction. The vocabulary verdict reads EVERY segment, so a chain whose first segment
		// is a typo is a usage error like the bare form.
		final fixture: String = writeFixture('class X { var y:Int; }');
		Assert.equals(
			2, Cli.run(['ast', '--select', 'ClassDeclX > VarField', fixture]), 'fuzzy extraction must use only the first kind segment'
		);
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static inline function writeFixture(source: String): String {
		return CliFixture.write('apq_ast_select_fuzzy', source);
	}
	#end

}
