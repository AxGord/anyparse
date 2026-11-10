package unit.cli;

import anyparse.query.Cli;

/**
 * `apq mentions <Name>` answers a name written in a COMMENT as its own section.
 *
 * A removed member leaves its name in doc and plain comments; the structural sections read the AST and
 * never see them, so a name scrub looked clean when prose still named the member. The comment section
 * reads the lexer's comment regions, labels each hit doc or plain, and never mixes into refs / uses / lit.
 */
@:nullSafety(Strict)
class ApqMentionsCommentCliTest extends Test {

	private static final HEADER: String = '# comments';
	private static final SOURCE: String = 'package a;\n\n/** The class that replaced Zq. */\nclass M {\n\n\t// plain note about Zq here\n'
		+ '\tpublic function new() {}\n\n\t/** Not Zqx, and not aZq either. */\n\t/* block note: Zq */\n\tpublic function f(): Void {\n'
		+ '\t\ttrace(\'Zq\');\n\t}\n\n}\n';

	/** A doc comment naming the name is a hit in a section of its own, labelled doc. */
	@:pin('control')
	@:killer('M-MENTIONS-COMMENTS-UNEMITTED')
	public function testDocCommentIsReported(): Void {
		final section: String = commentsSection(mentions('Zq'));
		Assert.isTrue(section.indexOf('  3:') >= 0 && section.indexOf('doc: /** The class that replaced Zq. */') >= 0, section);
	}

	/** A `//` comment and a plain block comment are hits too, labelled apart from a doc comment. */
	@:pin('control')
	@:killer('M-COMMENT-MENTIONS-DOC-ALWAYS')
	public function testPlainCommentsAreReported(): Void {
		final section: String = commentsSection(mentions('Zq'));
		Assert.isTrue(section.indexOf('  6:') >= 0 && section.indexOf('plain: // plain note about Zq here') >= 0, section);
		Assert.isTrue(section.indexOf('  10:') >= 0 && section.indexOf('plain: /* block note: Zq */') >= 0, section);
	}

	/** Only a whole identifier counts: `Zqx` and `aZq` in a comment are other names. */
	@:pin('control')
	@:killer('M-COMMENT-MENTIONS-SUBSTRING')
	public function testOnlyWholeIdentifiers(): Void {
		final section: String = commentsSection(mentions('Zq'));
		Assert.isTrue(section.indexOf('  9:') == -1, 'line 9 names only Zqx and aZq:\n$section');
	}

	/** A string literal holding the word is no comment: line 12 is the lit section's, not this one. */
	@:pin('control')
	@:killer('M-COMMENT-MENTIONS-TEXT-SCAN')
	public function testStringLiteralIsNotAComment(): Void {
		final out: String = mentions('Zq');
		Assert.isTrue(out.indexOf('  12:') >= 0, 'the lit section still answers the literal:\n$out');
		Assert.isTrue(commentsSection(out).indexOf('  12:') == -1, out);
	}

	/** A name written only in comments is a found name: no structural section, but still a hit. */
	public function testCommentOnlyNameHasNoStructuralSection(): Void {
		final out: String = mentions('replaced');
		Assert.isTrue(out.indexOf('# refs') == -1 && out.indexOf('# uses') == -1 && out.indexOf('# lit') == -1, out);
		Assert.isTrue(out.indexOf(HEADER) == 0, out);
	}

	/** `--flat` keeps the `file:line:col:` shape on a comment hit. */
	public function testFlatShape(): Void {
		final flat: String = commentsSection(mentions('Zq', ['--flat']));
		Assert.isTrue(~/\.hx:3:\d+: doc: /.match(flat), flat);
	}

	/** The comments section is not capped by `--limit`: every hit prints, as the usage text says. */
	@:pin('control')
	@:killer('M-MENTIONS-COMMENTS-LIMITED')
	public function testLimitDoesNotCapTheCommentSection(): Void {
		final section: String = commentsSection(mentions('Zq', ['--limit', '1']));
		Assert.isTrue(section.indexOf('  3:') >= 0 && section.indexOf('  6:') >= 0 && section.indexOf('  10:') >= 0, section);
	}

	private static function commentsSection(out: String): String {
		final at: Int = out.indexOf(HEADER);
		if (at < 0) return '';
		final next: Int = out.indexOf('\n# ', at + 1);
		return next < 0 ? out.substring(at) : out.substring(at, next);
	}

	private static function mentions(name: String, ?extra: Array<String>): String {
		#if (sys || nodejs)
		final file: String = CliFixture.write('mentionscomment', SOURCE);
		final out: String = CliFixture.captureStdout(() -> Cli.run(['mentions', name, file].concat(extra ?? [])));
		sys.FileSystem.deleteFile(file);
		return out;
		#else
		return '';
		#end
	}

}
