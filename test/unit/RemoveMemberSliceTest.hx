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

	/**
	 * A doc whose TEXT contains a backticked block-comment opener is still ONE comment
	 * token, so the whole doc goes with the member and the neighbour's doc is untouched.
	 * The lexical `lastIndexOf('/*')` this used to do cut the doc at that literal.
	 */
	public function testRemoveMemberWithDocContainingBlockOpener(): Void {
		final source: String = docFixture('`//` or `/*`');
		switch RemoveMember.removeMember(source, 'A', 'victim', true, new HaxeQueryPlugin(), true) {
			case Ok(text):
				Assert.isTrue(text.indexOf('victim') == -1, text);
				Assert.isTrue(text.indexOf('Whether the gap') == -1, text);
				Assert.isTrue(text.indexOf("The next member's own doc.") >= 0, text);
				Assert.isTrue(text.indexOf('neighbor') >= 0, text);
				assertBalancedComments(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/** Same defect shape with a backticked DOC opener in the text. */
	public function testRemoveMemberWithDocContainingDocOpener(): Void {
		final source: String = docFixture('a nested `/**` marker');
		switch RemoveMember.removeMember(source, 'A', 'victim', true, new HaxeQueryPlugin(), true) {
			case Ok(text):
				Assert.isTrue(text.indexOf('Whether the gap') == -1, text);
				Assert.isTrue(text.indexOf("The next member's own doc.") >= 0, text);
				assertBalancedComments(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * A literal `*` followed by `/` CLOSES a Haxe block comment, so a doc claiming to
	 * contain one never parses in the first place — the op refuses the source outright
	 * rather than mangling it. Locks in that the fix does not try to be clever about a
	 * sequence the language itself cannot express.
	 */
	public function testDocWithLiteralCloserIsUnparseable(): Void {
		assertErr(docFixture('a literal `*/` closer and no'), 'A', 'victim');
	}

	/**
	 * The same doc on the LAST member of the class. The lexical scan produced an
	 * unterminated fragment here too, but the reparse guard caught it and the op refused
	 * with "result does not parse" — an incidental refusal, not a gate. It now succeeds.
	 */
	public function testRemoveLastMemberWithDocContainingBlockOpener(): Void {
		final source: String = 'class A {\n\n\tvar keep:Int;\n\n\t/**\n\t * Whether the gap holds a `//` or `/*` opener.\n\t */\n'
			+ '\tprivate function victim():Bool {\n\t\treturn true;\n\t}\n\n}\n';
		switch RemoveMember.removeMember(source, 'A', 'victim', true, new HaxeQueryPlugin(), true) {
			case Ok(text):
				Assert.isTrue(text.indexOf('victim') == -1, text);
				Assert.isTrue(text.indexOf('Whether the gap') == -1, text);
				Assert.isTrue(text.indexOf('keep') >= 0, text);
				assertBalancedComments(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/** An unknown type is refused. */
	public inline function testTypeNotFound(): Void {
		assertErr('class C {\n\tvar x:Int;\n}\n', 'Nope', 'x');
	}

	/** An unknown member is refused. */
	public inline function testMemberNotFound(): Void {
		assertErr('class C {\n\tvar x:Int;\n}\n', 'C', 'nope');
	}

	/**
	 * A field of an anonymous structure written as a member's TYPE is not a member of the
	 * enclosing class. Matching it deleted the field out of the annotation and left
	 * `cfg:{}` — a silent Ok that no longer type-checks.
	 */
	public inline function testAnonStructureFieldInMemberTypeIsRefused(): Void {
		assertErr('class C {\n\tvar cfg:{ var inner:Int; } = { inner: 1 };\n}\n', 'C', 'inner');
	}

	/** Control: a typedef's own fields ARE its members and stay removable. */
	public function testTypedefFieldIsRemovable(): Void {
		final text: String = okText('typedef Td = {\n\tvar x:Int;\n\tvar y:String;\n}\n', 'Td', 'x');

		Assert.isTrue(text.indexOf('x') == -1, text);
		Assert.isTrue(text.indexOf('y') >= 0, text);
	}

	/** The round-2 repro: a doc'd `victim` whose text carries `marker`, followed by a doc'd `neighbor`. */
	private function docFixture(marker: String): String {
		return 'class A {\n\n\t/**\n\t * Whether the gap holds $marker comment opener.\n\t */\n\tprivate function victim():Bool {\n'
			+ '\t\treturn true;\n\t}\n\n\t/**\n\t * The next member\'s own doc.\n\t */\n\tprivate function neighbor():Bool {\n'
			+ '\t\treturn false;\n\t}\n\n}\n';
	}

	/** Every block-comment opener in `text` is matched by a closer — the orphan-doc signature. */
	private function assertBalancedComments(text: String): Void {
		var opens: Int = 0;
		var closes: Int = 0;
		for (i in 0...text.length - 1) {
			if (text.charAt(i) == '/' && text.charAt(i + 1) == '*') opens++;
			if (text.charAt(i) == '*' && text.charAt(i + 1) == '/') closes++;
		}
		Assert.equals(closes, opens, text);
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
