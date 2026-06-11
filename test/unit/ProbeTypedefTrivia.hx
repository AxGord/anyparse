package unit;

import utest.Test;
import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Regression guard for the typedef-trivia cluster
 * (issue_216 / issue_321) — slice ω-trailopt-stash-trivia.
 *
 * Before the fix, parsing a `typedef Foo = Int` (no trailing `;`)
 * followed by a doc-comment + next decl silently DROPPED the
 * intervening trivia: `skipWs` consumed the gap and `matchLit(';')`
 * then failed without restoring it. The doc-comment never reached
 * the next decl's `leadingComments`.
 *
 * Fix: in trivia mode + `@:trailOpt`, the post-Ref skip uses
 * `skipWsAndStash` so consumed comments land in `ctx.pendingTrivia`
 * and the parent Star's next `collectTrivia` drains them as leading
 * of the next decl.
 */
class ProbeTypedefTrivia extends Test {

	private static final _forceBuild: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	public function testIssue216PreservesDocCommentAfterUnsemicolonedTypedef(): Void {
		final src: String = 'typedef Foo = Int\n' + '\n' + '/** Docs for Bar **/\n' + 'typedef Bar = Float\n';
		final m: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(src);
		Assert.equals(2, m.decls.length);
		final next = m.decls[1];
		Assert.equals(1, next.leadingComments.length);
		Assert.isTrue(next.leadingComments[0].indexOf('Docs for Bar') >= 0);
	}

	public function testIssue321PreservesDocCommentAfterUnsemicolonedTypedefBeforeClass(): Void {
		final src: String = 'typedef Bar = String\n' + '\n' + '/**\n' + '\tdocs\n' + '**/\n' + 'class Foo {}\n';
		final m: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(src);
		Assert.equals(2, m.decls.length);
		final next = m.decls[1];
		Assert.equals(1, next.leadingComments.length);
	}

}
