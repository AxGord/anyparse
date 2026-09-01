package unit;

import utest.Assert;
import utest.Test;

/**
 * ω-fileheader-multiline-comments — WHICH leading block comment counts as
 * the module's file header.
 *
 * The rule replaces the source-driven blank slot after a module's first
 * leading block comment with `emptyLines.afterFileHeaderComment` (default
 * 1). It fired whenever the module held ANY top-level `package` / `import`
 * / `using` decl, read off a scan of the WHOLE decl array — so a module
 * whose first decl is a documented TYPE and whose `import` sits BELOW it
 * had a blank line pushed between the doc comment and the declaration it
 * documents, on every `fmt` pass, idempotently (T396).
 *
 * The header is now classified from the decl the comment actually leads:
 * a file header introduces the module's package / import section, not a
 * type. The `2+ leading comments` arm is unchanged — a header comment
 * followed by the type's own doc comment still gets its blank.
 */
@:nullSafety(Strict)
final class HxFileHeaderCommentSliceTest extends Test {

	public function new(): Void {
		super();
	}

	/**
	 * T396 pin — RED at base: the writer put a blank line between the doc
	 * comment's closing gutter and `class F`.
	 */
	public function testDocStaysAttachedWhenImportFollowsType(): Void {
		final src: String = '/**\n * Doc for F.\n */\nclass F {\n\tpublic function new() {}\n}\n\nimport haxe.ds.StringMap;';
		final out: String = format(src);
		Assert.isTrue(out.indexOf(' */\nclass F {') != -1, 'expected doc attached to class F in: <$out>');
		Assert.equals(out, format(out), 'writer is not its own fixed point on the T396 shape');
	}

	/**
	 * T396 pin, `using` arm — RED at base for the same reason.
	 */
	public function testDocStaysAttachedWhenUsingFollowsType(): Void {
		final src: String = '/**\n * Doc for F.\n */\nclass F {\n\tpublic function new() {}\n}\n\nusing Lambda;';
		final out: String = format(src);
		Assert.isTrue(out.indexOf(' */\nclass F {') != -1, 'expected doc attached to class F in: <$out>');
	}

	/**
	 * Control — green at base BY CONSTRUCTION (a real file header above a
	 * `package` decl is what the knob exists for). Killed by arm M3
	 * (head-is-p/i/u forced false).
	 */
	public function testFileHeaderBlankBeforePackage(): Void {
		final src: String = '/* Header */\npackage foo;\n\nclass F {\n\tpublic function new() {}\n}';
		final out: String = format(src);
		Assert.isTrue(out.indexOf('/* Header */\n\npackage foo;') != -1, 'expected blank after file header in: <$out>');
	}

	/**
	 * Control — green at base BY CONSTRUCTION (header above a leading
	 * `import`, no `package`). Killed by arm M3.
	 */
	public function testFileHeaderBlankBeforeLeadingImport(): Void {
		final src: String = '/* Header */\nimport haxe.ds.StringMap;\n\nclass F {\n\tpublic function new() {}\n}';
		final out: String = format(src);
		Assert.isTrue(out.indexOf('/* Header */\n\nimport haxe.ds.StringMap;') != -1, 'expected blank after file header in: <$out>');
	}

	/**
	 * Control — green at base BY CONSTRUCTION. Two leading block comments
	 * with no package / import / using anywhere: the `2+ comments` arm
	 * separates header from doc, and the doc stays glued to its type.
	 * Killed by arm M7 (the `2+ comments` arm dropped) and by arm M5 (the
	 * first-comment guard dropped, which would also split doc from type).
	 */
	public function testHeaderSeparatedFromDocButDocKeepsItsType(): Void {
		final src: String = '/* Header */\n/**\n * Doc for F.\n */\nclass F {\n\tpublic function new() {}\n}';
		final out: String = format(src);
		Assert.isTrue(out.indexOf('/* Header */\n\n/**') != -1, 'expected blank after file header in: <$out>');
		Assert.isTrue(out.indexOf(' */\nclass F {') != -1, 'expected doc attached to class F in: <$out>');
	}

	/**
	 * Control — green at base BY CONSTRUCTION (no p/i/u, one comment, so
	 * the rule never fired). Killed by arm M2 (head-is-p/i/u forced true).
	 */
	public function testNoFileHeaderBlankWithoutImports(): Void {
		final src: String = '/**\n * Doc for F.\n */\nclass F {\n\tpublic function new() {}\n}';
		final out: String = format(src);
		Assert.isTrue(out.indexOf(' */\nclass F {') != -1, 'expected doc attached to class F in: <$out>');
	}

	/**
	 * Control — green at base BY CONSTRUCTION (a `//` header is not a
	 * block comment, so neither the header slot nor the doc slot fires).
	 * Killed by arm M6 (the block-comment guard dropped: the 2+-comments
	 * arm then puts a blank after the `//` header) and by arm M5.
	 */
	public function testLineCommentHeaderLeavesDocAttached(): Void {
		final src: String = '// header\n/**\n * Doc for F.\n */\nclass F {\n\tpublic function new() {}\n}\n\nimport haxe.ds.StringMap;';
		final out: String = format(src);
		Assert.isTrue(out.indexOf(' */\nclass F {') != -1, 'expected doc attached to class F in: <$out>');
		Assert.isTrue(out.indexOf('// header\n/**') != -1, 'expected no blank after the line-comment header in: <$out>');
	}

	/**
	 * Control — green at base BY CONSTRUCTION (the doc leads the SECOND
	 * decl, so the first-decl guard never held). Killed by arm M4 (the
	 * first-decl guard dropped).
	 */
	public function testDocOnSecondDeclIsNotAFileHeader(): Void {
		final src: String =
			'package foo;\n\n/**\n * Doc for F.\n */\nclass F {\n\tpublic function new() {}\n}\n\nimport haxe.ds.StringMap;';
		final out: String = format(src);
		Assert.isTrue(out.indexOf(' */\nclass F {') != -1, 'expected doc attached to class F in: <$out>');
	}

	/**
	 * T396 pin, conditional-wrapped type — RED at base: the doc was detached
	 * from the `#if`-guarded declaration it documents.
	 */
	public function testDocOnConditionalWrappedTypeStaysAttached(): Void {
		final src: String = '/**\n * Doc for F.\n */\n#if js\nclass F {\n\tpublic function new() {}\n}\n#end\n\nimport haxe.ds.StringMap;';
		final out: String = format(src);
		Assert.isTrue(out.indexOf(' */\n#if js') != -1, 'expected doc attached to the guarded class in: <$out>');
	}

	/**
	 * Control — green at base BY CONSTRUCTION, and the reason the head-decl
	 * classification reaches THROUGH a module-head `#if`: a real file header
	 * above a guarded import block still gets its blank. Killed by arm M8
	 * (the conditional-transparent arm dropped, which is the naive
	 * head-only fix).
	 */
	public function testFileHeaderBlankBeforeConditionalImportBlock(): Void {
		final src: String = '/* Header */\n#if js\nimport a.A;\n#end\nimport b.B;\n\nclass F {\n\tpublic function new() {}\n}';
		final out: String = format(src);
		Assert.isTrue(out.indexOf('/* Header */\n\n#if js') != -1, 'expected blank after file header in: <$out>');
	}

	private inline function format(src: String): String {
		return HxWriteFixture.triviaWrite(src, '{}');
	}

}
