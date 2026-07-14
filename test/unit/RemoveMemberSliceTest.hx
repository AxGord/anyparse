package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RemoveMember;

/**
 * `RemoveMember.removeMember` — remove a field / method by its type and
 * name, the by-name wrapper over `RemoveElement`. The removal itself is
 * covered by `RemoveElementSliceTest`; here the focus is resolution: the
 * named member of the named type is removed (including in a `final class`),
 * the siblings survive, and an unknown type or member is refused.
 */
class RemoveMemberSliceTest extends Test {

	/** Remove a method by name; the sibling member survives. */
	public function testRemoveMethod(): Void {
		final source: String = 'class C {\n\tvar keep:Int;\n\tpublic function drop():Void {}\n}\n';
		final text: String = okText(source, 'C', 'drop');
		Assert.isTrue(text.indexOf('drop') == -1);
		Assert.isTrue(text.indexOf('keep') >= 0);
	}

	/** Remove a field by name; the sibling method survives. */
	public function testRemoveVar(): Void {
		final source: String = 'class C {\n\tvar drop:Int;\n\tpublic function keep():Void {}\n}\n';
		final text: String = okText(source, 'C', 'drop');
		Assert.isTrue(text.indexOf('drop') == -1);
		Assert.isTrue(text.indexOf('keep') >= 0);
	}

	/** A member of a `final class` resolves through the final-aware type lookup. */
	public function testRemoveFinalClassMember(): Void {
		final source: String = 'final class C {\n\tvar keep:Int;\n\tvar drop:Int;\n}\n';
		final text: String = okText(source, 'C', 'drop');
		Assert.isTrue(text.indexOf('drop') == -1);
		Assert.isTrue(text.indexOf('keep') >= 0);
	}

	/** `--with-doc` removes the member's leading doc comment with it (no orphan). */
	public function testRemoveMemberWithDoc(): Void {
		final source: String = 'class C {\n\t/** doc */\n\tpublic function drop():Void {}\n\tvar keep:Int;\n}\n';
		switch RemoveMember.removeMember(source, 'C', 'drop', true, new HaxeQueryPlugin(), true) {
			case Ok(text):
				Assert.isTrue(text.indexOf('doc') == -1);
				Assert.isTrue(text.indexOf('drop') == -1);
				Assert.isTrue(text.indexOf('keep') >= 0);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/** An unknown type is refused. */
	public function testTypeNotFound(): Void {
		assertErr('class C {\n\tvar x:Int;\n}\n', 'Nope', 'x');
	}

	/** An unknown member is refused. */
	public function testMemberNotFound(): Void {
		assertErr('class C {\n\tvar x:Int;\n}\n', 'C', 'nope');
	}

	private function okText(source: String, typeName: String, memberName: String): String {
		switch RemoveMember.removeMember(source, typeName, memberName, true, new HaxeQueryPlugin()) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return '';
		}
	}

	private function assertErr(source: String, typeName: String, memberName: String): Void {
		switch RemoveMember.removeMember(source, typeName, memberName, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.fail('expected Err, got Ok:\n$text');
			case Err(_):
				Assert.pass();
		}
	}

}
