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
	 * Two stacked leading doc blocks (e.g. a duplicate left by an earlier edit) are
	 * BOTH replaced by the single new doc — `docExtendedSpan` spans the whole run, so
	 * neither stale block nor an orphan ` * ` line survives (exactly one `/**` remains).
	 */
	public function testReplacesStackedDocRun(): Void {
		final src: String = "package p;\nclass C {\n\t/** first */\n\t/** second */\n\tpublic function f(): Int return 1;\n}";
		final text: String = okText(SetDoc.setDoc(src, 5, 2, "fresh", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains("fresh"));
		Assert.isFalse(text.contains("first"));
		Assert.isFalse(text.contains("second"));
		Assert.equals(text.indexOf("/**"), text.lastIndexOf("/**"));
	}

	/**
	 * A DISTINCT block comment above the doc (a license / section banner) is NOT
	 * swallowed — only the immediately-preceding doc is replaced.
	 */
	public function testPreservesBlockCommentAboveDoc(): Void {
		final src: String = "package p;\nclass C {\n\t/* license */\n\t/** old doc */\n\tpublic function f(): Int return 1;\n}";
		final text: String = okText(SetDoc.setDoc(src, 5, 2, "fresh", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains("license"));
		Assert.isTrue(text.contains("fresh"));
		Assert.isFalse(text.contains("old doc"));
	}

}
