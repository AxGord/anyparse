package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.SetDoc;

using StringTools;

/**
 * Probe for `apq set-doc` — add or replace a declaration's doc-comment without
 * touching the declaration. Drives `SetDoc.setDoc` directly on in-memory
 * sources (pure, JS-native) with `reformat = true` so the in-memory fixtures
 * need not be writer-canonical: a doc is inserted before an undocumented
 * member, an existing leading doc is replaced, and a cursor off any node is an
 * `Err`.
 */
class SetDocSliceTest extends Test {

	/** A doc-comment is inserted before an undocumented member; the member survives. */
	public function testAddsDocToUndocumented(): Void {
		final src: String = 'package p;\nclass C {\n\tpublic function f(): Int return 1;\n}';
		final text: String = okText(SetDoc.setDoc(src, 3, 2, 'Returns one.', true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('/**'));
		Assert.isTrue(text.contains('Returns one.'));
		Assert.isTrue(text.contains('function f'));
	}

	/** An existing leading doc is replaced, not duplicated. */
	public function testReplacesExistingDoc(): Void {
		final src: String = 'package p;\nclass C {\n\t/** old doc */\n\tpublic function f(): Int return 1;\n}';
		final text: String = okText(SetDoc.setDoc(src, 4, 2, 'new doc', true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('new doc'));
		Assert.isFalse(text.contains('old doc'));
	}

	/** A multi-line doc text becomes one ` * ` line per line. */
	public function testMultiLineDoc(): Void {
		final src: String = 'package p;\nclass C {\n\tpublic function f(): Int return 1;\n}';
		final text: String = okText(SetDoc.setDoc(src, 3, 2, 'First line.\nSecond line.', true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('First line.'));
		Assert.isTrue(text.contains('Second line.'));
	}

	/** A cursor on no node is an error. */
	public function testBadPositionIsError(): Void {
		final src: String = 'package p;\nclass C {}';
		Assert.isTrue(isErr(SetDoc.setDoc(src, 99, 2, 'x', true, new HaxeQueryPlugin())));
	}

	/**
	 * Two stacked leading doc blocks (e.g. a duplicate left by an earlier edit) are
	 * BOTH replaced by the single new doc — `docExtendedSpan` spans the whole run, so
	 * neither stale block nor an orphan ` * ` line survives (exactly one `/**` remains).
	 */
	public function testReplacesStackedDocRun(): Void {
		final src: String = 'package p;\nclass C {\n\t/** first */\n\t/** second */\n\tpublic function f(): Int return 1;\n}';
		final text: String = okText(SetDoc.setDoc(src, 5, 2, 'fresh', true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('fresh'));
		Assert.isFalse(text.contains('first'));
		Assert.isFalse(text.contains('second'));
		Assert.equals(text.indexOf('/**'), text.lastIndexOf('/**'));
	}

	/**
	 * A DISTINCT block comment above the doc (a license / section banner) is NOT
	 * swallowed — only the immediately-preceding doc is replaced.
	 */
	public function testPreservesBlockCommentAboveDoc(): Void {
		final src: String = 'package p;\nclass C {\n\t/* license */\n\t/** old doc */\n\tpublic function f(): Int return 1;\n}';
		final text: String = okText(SetDoc.setDoc(src, 5, 2, 'fresh', true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('license'));
		Assert.isTrue(text.contains('fresh'));
		Assert.isFalse(text.contains('old doc'));
	}

	/**
	 * A trailing newline in the doc text (the artifact every heredoc / stdin
	 * payload carries) must not become a blank ` *` line before the comment
	 * close — the output equals the trimmed payload's output.
	 */
	public function testTrailingNewlineEqualsTrimmed(): Void {
		final src: String = 'package p;\nclass C {\n\tpublic function f(): Int return 1;\n}';
		final plain: String = okText(SetDoc.setDoc(src, 3, 2, 'Returns one.', true, new HaxeQueryPlugin()));
		final trailing: String = okText(SetDoc.setDoc(src, 3, 2, 'Returns one.\n', true, new HaxeQueryPlugin()));
		Assert.equals(plain, trailing);
	}

	/**
	 * A leading newline in the doc text must not become a blank ` *` line
	 * after the comment open — the output equals the trimmed payload's output.
	 */
	public function testLeadingNewlineEqualsTrimmed(): Void {
		final src: String = 'package p;\nclass C {\n\tpublic function f(): Int return 1;\n}';
		final plain: String = okText(SetDoc.setDoc(src, 3, 2, 'Returns one.', true, new HaxeQueryPlugin()));
		final leading: String = okText(SetDoc.setDoc(src, 3, 2, '\nReturns one.', true, new HaxeQueryPlugin()));
		Assert.equals(plain, leading);
	}

	/**
	 * Trimming is edge-only: an INTERNAL blank line (a paragraph break) is kept
	 * while the trailing heredoc newline is still dropped.
	 */
	public function testTrailingNewlineAfterParagraphsEqualsTrimmed(): Void {
		final src: String = 'package p;\nclass C {\n\tpublic function f(): Int return 1;\n}';
		final plain: String = okText(SetDoc.setDoc(src, 3, 2, 'First.\n\nSecond.', true, new HaxeQueryPlugin()));
		final trailing: String = okText(SetDoc.setDoc(src, 3, 2, 'First.\n\nSecond.\n', true, new HaxeQueryPlugin()));
		Assert.equals(plain, trailing);
		Assert.isTrue(plain.contains('First.'));
		Assert.isTrue(plain.contains('Second.'));
	}

	/**
	 * A `final class` doc set from a cursor on the `class` keyword (where a
	 * `--select ClassDecl:C` / `ClassForm:C` resolves) must land before `final`
	 * — today the splice falls INSIDE the `FinalDecl` (between `final` and
	 * `class`) and the writer silently drops it, yielding a byte-identical
	 * "success".
	 */
	public function testFinalClassDocFromClassFormCursor(): Void {
		final src: String = 'package p;\nfinal class C {\n\tpublic function new() {}\n}';
		final text: String = okText(SetDoc.setDoc(src, 2, 7, 'Doc for C.', true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('Doc for C.'));
	}

	/**
	 * Re-setting the byte-identical doc is a no-change edit and reports `Err`
	 * (the silent-drop guard) — a caller learns the truth instead of a
	 * successful-looking write.
	 */
	public function testIdenticalDocIsNoChangeErr(): Void {
		final src: String = 'package p;\nclass C {\n\tpublic function f(): Int return 1;\n}';
		final once: String = okText(SetDoc.setDoc(src, 3, 2, 'Returns one.', true, new HaxeQueryPlugin()));
		// Locate the declaration structurally — `reformat` reflows lines both
		// before AND after the target, so a line-delta formula lands elsewhere.
		final lines: Array<String> = once.split('\n');
		final fnLine: Int = [for (i in 0...lines.length) if (lines[i].contains('function f')) i + 1][0];
		final res: EditResult = SetDoc.setDoc(once, fnLine, 2, 'Returns one.', true, new HaxeQueryPlugin());
		Assert.isTrue(errMessage(res).contains('no change'));
	}

	/**
	 * The doc of a modifier-less sole member of a class stays ON THE MEMBER —
	 * the decl-wrapper lift must not climb from a member to its enclosing
	 * class just because the class has a single child (regression guard for
	 * the identity-scoped lift).
	 */
	public function testSingleMemberClassMemberDocStaysOnMember(): Void {
		final src: String = 'package p;\nclass C {\n\tfunction f(): Int return 1;\n}';
		final text: String = okText(SetDoc.setDoc(src, 3, 2, 'Member doc.', true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('Member doc.'));
		Assert.isTrue(text.indexOf('class C') < text.indexOf('Member doc.'));
	}

	/**
	 * A cursor on a plain expression (no doc slot anywhere above it) must NOT
	 * report a successful write while the writer drops the comment — under
	 * `reformat` the no-op guard compares against the reformatted baseline, so
	 * reflow noise cannot mask the drop.
	 */
	public function testUnattachableExpressionPositionIsErr(): Void {
		final src: String = 'package p;\nclass C {\n\tfunction f(): Void {\n\t\tvar x = !y;\n\t}\n}';
		Assert.isTrue(isErr(SetDoc.setDoc(src, 4, 12, 'Doc for y.', true, new HaxeQueryPlugin())));
	}

	private function okText(res: EditResult): String {
		return switch res {
			case Ok(text): text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				'';
		};
	}

	private function isErr(res: EditResult): Bool {
		return switch res {
			case Ok(_): false;
			case Err(_): true;
		};
	}

	/**
	 * The `Err` payload of `res` — fails the test when `res` is `Ok`.
	 */
	private function errMessage(res: EditResult): String {
		return switch res {
			case Ok(_):
				Assert.fail('expected Err, got Ok');
				'';
			case Err(message): message;
		};
	}

}
