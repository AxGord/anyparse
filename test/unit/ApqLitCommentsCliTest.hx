package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if sys
import sys.FileSystem;
#end

/**
 * `apq lit --include-comments` / `--kind Comment` — comment-scan
 * extension to the leaf-name probe.
 *
 * Pre-DX, `apq lit` walked the AST only (`plugin.parseFile` returns the
 * plain projection that drops trivia), so a target text living inside
 * a line or block comment was invisible — the documented escape was
 * `# HXQ_OK:prose`-gated grep. This DX adds a string-literal-aware
 * comment lexer that runs alongside the AST walk when `Comment` is in
 * the effective kind filter, `--include-comments` is set, or
 * `--any-kind` widens.
 *
 * Tests exercise CLI exit codes only — text-content assertions live in
 * the unit-level `Lit`/comment-lexer tests (none yet — the lexer is a
 * private static helper in `Cli.hx`; happy path verified manually).
 */
@:nullSafety(Strict)
class ApqLitCommentsCliTest extends Test {

	// --- --include-comments: AST + comment hits ---

	public function testLitIncludeCommentsFindsBlockCommentText(): Void {
		#if sys
		final fixture: String = CliFixture.write(
			'apq_lit_comments_block', 'class C {\n\t/* the_marker_text lives here */\n\tvar x:Int = 0;\n}'
		);
		Assert.equals(
			0, Cli.run(['lit', 'the_marker_text', '--include-comments', fixture]),
			'lit --include-comments finds text inside /* */ block comment'
		);
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testLitIncludeCommentsFindsLineCommentText(): Void {
		#if sys
		final fixture: String = CliFixture.write(
			'apq_lit_comments_line', 'class C {\n\t// the_marker_text in a line comment\n\tvar x:Int = 0;\n}'
		);
		Assert.equals(
			0, Cli.run(['lit', 'the_marker_text', '--include-comments', fixture]),
			'lit --include-comments finds text inside // line comment'
		);
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testLitIncludeCommentsFindsDocCommentText(): Void {
		#if sys
		final fixture: String = CliFixture.write(
			'apq_lit_comments_doc', '/**\n * the_marker_text in a doc comment\n */\nclass C { var x:Int = 0; }'
		);
		Assert.equals(
			0, Cli.run(['lit', 'the_marker_text', '--include-comments', fixture]),
			'lit --include-comments finds text inside /** */ doc comment'
		);
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- --kind Comment: comment-only scan ---

	public function testLitKindCommentScansOnlyComments(): Void {
		#if sys
		// Target appears in both a string literal and a comment;
		// --kind Comment restricts to the comment hit only. Exit code is
		// 0 (found in comment) — text-content correctness verified
		// manually (stderr / stdout text not captured here).
		final fixture: String = CliFixture.write(
			'apq_lit_kind_comment', 'class C {\n\t/* the_marker_text comment */\n\tvar s:String = "the_marker_text string";\n}'
		);
		Assert.equals(0, Cli.run(['lit', 'the_marker_text', '--kind', 'Comment', fixture]), 'lit --kind Comment finds text in comment');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- Regression: default lit (no --include-comments) skips comments ---

	public function testLitDefaultSkipsCommentText(): Void {
		#if sys
		// Target lives ONLY in a comment. Default lit walks AST only;
		// 0 AST hits triggers the auto-widen retry (Literal+IdentExpr →
		// any-kind), which still finds 0 — comments are not in the parse
		// tree. Exit is 0 (not an error), no hits found.
		final fixture: String = CliFixture.write('apq_lit_default_skip', 'class C {\n\t// only_in_comment lives here\n\tvar x:Int = 0;\n}');
		Assert.equals(0, Cli.run(['lit', 'only_in_comment', fixture]), 'default lit (no --include-comments) skips comments');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- String-literal awareness: `//` inside a string is not a comment ---

	public function testLitCommentScanIgnoresSlashSlashInString(): Void {
		#if sys
		// `"//not_a_comment"` is a string, not a comment. --kind Comment
		// (comment-only) must NOT match `not_a_comment` — it lives in a
		// quoted region the lexer skips. Exit 0 (clean run, no hits).
		final fixture: String = CliFixture.write('apq_lit_comment_string_aware', 'class C { var s:String = "//not_a_comment"; }');
		Assert.equals(0, Cli.run(['lit', 'not_a_comment', '--kind', 'Comment', fixture]), 'comment scan ignores // inside string literals');
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- --any-kind also triggers comment scan ---

	public function testLitAnyKindAlsoScansComments(): Void {
		#if sys
		final fixture: String = CliFixture.write('apq_lit_anykind_comments', 'class C {\n\t/* the_anykind_marker */\n\tvar x:Int = 0;\n}');
		Assert.equals(
			0, Cli.run(['lit', 'the_anykind_marker', '--any-kind', fixture]), 'lit --any-kind scans comments alongside AST leaves'
		);
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
