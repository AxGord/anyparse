package unit.query;

import anyparse.query.Patch;
import anyparse.query.ReplaceNode;

using StringTools;

/**
 * The op's parse gate is the grammar, so a string literal the grammar accepts and `haxe` rejects
 * is written unchallenged. These payloads are the shapes `haxe` refuses (an escape outside its
 * set, an unclosed `${`) and the shapes it takes, through `Patch.patchNode`. `#` stands for `$`
 * in a body, so the fixtures carry no interpolation of their own.
 */
class PatchStringLiteralGateTest extends Test {

	private static final SOURCE: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = 0;\n\t}\n}\n';

	@:pin('guard')
	public function testInvalidEscapesRefusedInBothQuotes(): Void {
		for (body in [
			'a\\qb',
			'a\\/b',
			'a\\#b',
			'a\\0b',
			'a\\8b',
			'a\\x4',
			'a\\u004',
			'a\\u{}',
			'a\\u{1234567}',
			'a\\200',
			'a\\180',
			'a\\x80',
			'a\\xFF'
		]) for (quote in ['\'', '"']) assertRefused('$quote$body$quote');
	}

	@:pin('control')
	@:killer('M-REJECT-FOLLOW-LIT-IGNORED')
	public function testUnclosedInterpolationRefused(): Void {
		assertRefused('\'a #{b\'');
		assertRefused('\'#{\'');
	}

	public function testEscapesHaxeTakesApplied(): Void {
		for (body in [
			'a\\nb\\r\\t\\\\',
			'\\\'',
			'\\"',
			'\\101\\177\\077',
			'\\x41\\u0041\\u{41}\\u{10FFFF}\\u{0001F600}\\u{000010FFFF}\\u{0000041}\\x7F'
		]) for (quote in ['\'', '"']) assertApplied('$quote$body$quote');
	}

	public function testDollarFormsApplied(): Void {
		for (body in ['##', '#', '# ', '#5', 'a #b #{c} d', 'x#']) assertApplied('\'$body\'');
	}

	private function assertRefused(literal: String): Void {
		switch Patch.patchNode(
			SOURCE, BySelector('FnMember:f'), 'var a = 0;', 'var a = ${dollars(literal)};', false, new HaxeQueryPlugin()
		) {
			case Ok(text):
				Assert.fail('expected Err for $literal, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('result does not parse') >= 0, message);
		}
	}

	private function assertApplied(literal: String): Void {
		switch Patch.patchNode(
			SOURCE, BySelector('FnMember:f'), 'var a = 0;', 'var a = ${dollars(literal)};', false, new HaxeQueryPlugin()
		) {
			case Ok(text):
				Assert.isTrue(text.indexOf(dollars(literal)) >= 0, text);
			case Err(message):
				Assert.fail('expected Ok for $literal, got Err: $message');
		}
	}

	private function dollars(body: String): String {
		return body.replace('#', String.fromCharCode(36));
	}

}
