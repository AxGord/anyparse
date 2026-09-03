package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import haxe.Exception;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * A parse failure reported through `parseFile` names the LINE and COLUMN it stopped at.
 *
 * It did not. The generated walker memoises a failed parse as a null ROOT — the right answer for
 * the callers that merely skip a file they cannot parse — and `walkRoot` never sees the source, so
 * all it could raise was a bare `parse failed`. Every op re-parses its own rewrite and reports the
 * result, so that string was the whole diagnosis for a `move` whose destination stopped parsing:
 * no offset, no line, nothing to open an editor at. Measured on a real move of a 1127-line test
 * module, where the cause turned out to be a doc comment cut in half.
 *
 * The fix raises the parser's OWN error at the null-root seam (`HaxeQueryPlugin.treeFromRoot`),
 * where the source is in hand. These pins assert the two paths that reach it: the immediate one,
 * where the memo still holds the failing source, and the CACHED one, where a decorator hands back
 * a null root parsed long before and the memo has moved on.
 */
@:nullSafety(Strict)
final class ParseFailureLocusTest extends Test {

	/** A module whose fifth line is a `var x = ;` — the parser stops at 5:11. */
	private static final BROKEN: String = 'package p;\n\nclass A {\n\tfunction f(): Void {\n\t\tvar x = ;\n\t}\n}\n';

	/** A perfectly good module, used to move the walker's single-entry memo off `BROKEN`. */
	private static final GOOD: String = 'package p;\n\nclass B {\n\tpublic function new() {}\n}\n';

	public function testAParseFailureNamesItsLineAndColumn(): Void {
		final message: String = failureOf(new HaxeQueryPlugin(), BROKEN);
		Assert.isTrue(message.contains('5:11'), 'the failure should name line 5, column 11, got: $message');
		Assert.isFalse(message == 'parse failed', 'the failure should not be the bare walker message');
	}

	/**
	 * The discriminating case. A caching decorator keeps null roots, so a source that failed once
	 * is answered from that cache for the rest of the run — long after the walker's own single-entry
	 * memo has moved on to something else. A diagnosis that read only that memo would either say
	 * nothing here or name the WRONG file's position; re-raising from the source in hand cannot.
	 */
	public function testACachedNullRootStillNamesTheFailingSourcesPosition(): Void {
		final plugin: GrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		Assert.isTrue(failureOf(plugin, BROKEN).contains('5:11'), 'the first failure should name 5:11');
		// The move that displaces the walker's single-entry memo, and the assertion that proves it
		// really parsed rather than being served the cached failure.
		Assert.equals('module', plugin.parseFile(GOOD).kind);
		final message: String = failureOf(plugin, BROKEN);
		Assert.isTrue(message.contains('5:11'), 'the cached-null-root failure should still name 5:11, got: $message');
	}

	/** A source that PARSES is unaffected — the diagnosis costs nothing on the path that succeeds. */
	public function testAParseableSourceStillProjects(): Void {
		Assert.equals('module', new HaxeQueryPlugin().parseFile(GOOD).kind);
	}

	/** The message `plugin.parseFile(source)` fails with, or a failed assertion when it does not fail. */
	private function failureOf(plugin: GrammarPlugin, source: String): String {
		try {
			final tree: QueryNode = plugin.parseFile(source);
			Assert.fail('expected a parse failure, got a tree of ${tree.children.length} child(ren)');
			return '';
		} catch (exception: Exception)
			return exception.toString();
	}

}
