package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * `apq lit --include-directives` / `--kind Directive` — the conditional-compilation reach of the
 * leaf-name probe.
 *
 * A directive's condition is neither a captured literal leaf nor a node: it survives only as
 * trivia on the directive line, so before this flag no `lit` / `search` query could find `#if (`
 * at all and the documented route was `# HXQ_OK:prose`-escaped grep. The scan shares
 * `CondDirectives` with the `redundant-condcomp-parens` check.
 *
 * Every assertion carries `--exit-on-empty`, which is what makes the exit code discriminate: a
 * plain `lit` walk exits 0 whether or not it found anything, so a bare exit-code assertion would
 * pass for both outcomes.
 */
class ApqLitDirectivesCliTest extends Test {

	/** A region per shape: a single flag, a compound condition, an `#elseif` chain and an `#end`. */
	private static final SRC: String = 'class C {\n\tfunction f():Void {\n\t\t#if (sys)\n\t\tg();\n\t\t#elseif (cpp && debug)\n\t\th();\n'
		+ '\t\t#else\n\t\ti();\n\t\t#end\n\t}\n}';

	public function testIncludeDirectivesFindsIfCondition(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('lit_directives', SRC);
		Assert.equals(
			0, Cli.run(['lit', '#if (', f, '--include-directives', '--exit-on-empty']), '--include-directives reaches the #if condition'
		);
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testIncludeDirectivesFindsElseIfAndEnd(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('lit_directives', SRC);
		Assert.equals(0, Cli.run(['lit', '#elseif', f, '--include-directives', '--exit-on-empty']), 'an #elseif line is a directive hit');
		Assert.equals(0, Cli.run(['lit', '#end', f, '--include-directives', '--exit-on-empty']), 'a bare #end is a directive hit');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The default walk is unchanged: no flag, no directive hits. */
	public function testDefaultWalkSkipsDirectives(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('lit_directives', SRC);
		Assert.equals(1, Cli.run(['lit', '#if (', f, '--exit-on-empty']), 'default lit finds no directive text');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `--any-kind` widens the AST kind filter and rides the COMMENT scan, but deliberately not this
	 * one: directive lines are hit surface no shipped query has ever returned, and widening
	 * `--any-kind` would change what an existing query prints.
	 */
	public function testAnyKindDoesNotWidenToDirectives(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('lit_directives', SRC);
		Assert.equals(1, Cli.run(['lit', '#if (', f, '--any-kind', '--exit-on-empty']), '--any-kind leaves directives out');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testKindDirectiveScansDirectivesOnly(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('lit_kind_directive', 'class C {\n\t#if (sys)\n\tvar s:String = "the_marker_text";\n\t#end\n}');
		Assert.equals(0, Cli.run(['lit', '#if', f, '--kind', 'Directive', '--exit-on-empty']), '--kind Directive finds the directive');
		Assert.equals(
			1, Cli.run(['lit', 'the_marker_text', f, '--kind', 'Directive', '--exit-on-empty']),
			'--kind Directive does not fall back to string literals'
		);
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A `#if` written inside a comment is not a directive — the scan shares the engine's lexer. */
	public function testDirectiveInsideCommentIsNotAHit(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('lit_directive_comment', 'class C {\n\t// #if (commented_flag)\n\tvar x:Int = 0;\n}');
		Assert.equals(
			1, Cli.run(['lit', 'commented_flag', f, '--include-directives', '--exit-on-empty']), 'a commented-out #if is not a directive'
		);
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The captured text is the directive alone. On a single-line region the code that follows the
	 * condition stays out of it, so a query spanning the boundary must not match.
	 */
	public function testInlineRegionCodeIsNotDirectiveText(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('lit_directive_inline', 'class C {\n\tfunction f():Void {\n\t\t#if js g(); #end\n\t}\n}');
		Assert.equals(0, Cli.run(['lit', '#if js', f, '--include-directives', '--exit-on-empty']), 'the condition itself is matchable');
		Assert.equals(
			1, Cli.run(['lit', '#if js g', f, '--include-directives', '--exit-on-empty']), 'the guarded code is not part of the directive'
		);
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A DOTTED define is one flag, not a flag followed by a field access — the whole
	 * `#if target.unicode` is the directive text, and a query for a prefix of it must not
	 * match exactly. Real shape: it is how the Haxe standard library spells its unicode gate.
	 */
	public function testDottedDefineIsOneDirective(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('lit_directive_dotted', 'class C {\n\t#if target.unicode\n\tvar x:Int = 0;\n\t#end\n}');
		Assert.equals(0, Cli.run([
			'lit',
			'#if target.unicode',
			f,
			'--include-directives',
			'--exact',
			'--exit-on-empty'
		]), 'a dotted define is captured whole');
		Assert.equals(
			1, Cli.run(['lit', '#if target', f, '--include-directives', '--exact', '--exit-on-empty']),
			'the directive does not end at the dot'
		);
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testExactMatchOnWholeDirectiveText(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('lit_directives', SRC);
		Assert.equals(
			0, Cli.run(['lit', '#if (sys)', f, '--include-directives', '--exact', '--exit-on-empty']),
			'--exact matches the whole directive'
		);
		Assert.equals(
			1, Cli.run(['lit', '#if', f, '--include-directives', '--exact', '--exit-on-empty']), '--exact rejects a prefix of it'
		);
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
