package unit.grammar;

import anyparse.grammar.json.JsonNative;
import utest.Assert;
import utest.Test;

/** `JsonNative.stringField`: the string a JSON object text holds under a key, read where no generated parser can be used. */
class JsonNativeStringFieldTest extends Test {

	public function testTheStringUnderTheKey(): Void {
		Assert.equals('a.B', JsonNative.stringField('{"type": "a.B", "n": 1}', 'type'));
		Assert.equals('last', JsonNative.stringField('{"type": "first", "type": "last"}', 'type'));
		Assert.equals('', JsonNative.stringField('{"type": ""}', 'type'));
	}

	public function testNoStringIsNull(): Void {
		for (text in [
			'{"type": 1}',
			'{"type": null}',
			'{"type": ["a"]}',
			'{"other": "a"}',
			'[]',
			'"type"',
			'5',
			'null'
		]) Assert.isNull(JsonNative.stringField(text, 'type'), text);
	}

	public function testTextThatIsNoJsonThrows(): Void {
		Assert.raises(JsonNative.stringField.bind('{"type": ', 'type'));
	}

}
