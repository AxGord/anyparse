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
		final text: String = okText(SetDoc.setDoc(src, 3, 1, 'Returns one.', true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('/**'));
		Assert.isTrue(text.contains('Returns one.'));
		Assert.isTrue(text.contains('function f'));
	}

	/** An existing leading doc is replaced, not duplicated. */
	public function testReplacesExistingDoc(): Void {
		final src: String = 'package p;\nclass C {\n\t/** old doc */\n\tpublic function f(): Int return 1;\n}';
		final text: String = okText(SetDoc.setDoc(src, 4, 1, 'new doc', true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('new doc'));
		Assert.isFalse(text.contains('old doc'));
	}

	/** A multi-line doc text becomes one ` * ` line per line. */
	public function testMultiLineDoc(): Void {
		final src: String = 'package p;\nclass C {\n\tpublic function f(): Int return 1;\n}';
		final text: String = okText(SetDoc.setDoc(src, 3, 1, 'First line.\nSecond line.', true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('First line.'));
		Assert.isTrue(text.contains('Second line.'));
	}

	/** A cursor on no node is an error. */
	public function testBadPositionIsError(): Void {
		final src: String = 'package p;\nclass C {}';
		Assert.isTrue(isErr(SetDoc.setDoc(src, 99, 1, 'x', true, new HaxeQueryPlugin())));
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

}
