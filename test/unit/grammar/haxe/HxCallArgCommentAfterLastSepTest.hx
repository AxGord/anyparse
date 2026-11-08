package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * A comment after the last separator of a call's argument list (`g(a, b, /* c *\/)`) has no next argument to lead,
 * so it trails the last argument under every trailing-comma policy: written after the kept comma, beside the argument
 * when the comma is dropped. Before, the parser left it to a leading slot nothing read and the round trip refused
 * the file.
 */
class HxCallArgCommentAfterLastSepTest extends Test {

	private static inline final KEEP: String = '{"wrapping": {"trailingComma": "keep"}}';
	private static inline final REMOVE: String = '{"wrapping": {"trailingComma": "remove"}}';

	@:pin('control')
	@:killer('M-CALL-AFTER-LAST-SEP-BLOCK-LEFT')
	public function testKeepWritesTheCommentAfterTheComma(): Void {
		assertWritesOnce(KEEP, call('g(a, b, /* c */);'), call('g(\n\t\t\ta,\n\t\t\tb, /* c */\n\t\t);'));
	}

	@:pin('control')
	@:killer('M-CALL-AFTER-LAST-SEP-BLOCK-LEFT')
	public function testRemoveWritesTheCommentBesideTheArgument(): Void {
		assertWritesOnce(REMOVE, call('g(a, b, /* c */);'), call('g(a, b /* c */);'));
	}

	@:pin('control')
	@:killer('M-CALL-AFTER-LAST-SEP-BLOCK-LEFT')
	public function testAddKeepsTheCommentAfterTheComma(): Void {
		final config: String = '{"wrapping": {"trailingComma": "keep", "callParameter": {'
			+ '"defaultWrap": "onePerLine", "rules": []}}, "trailingCommas": {"callArgumentDefault": "yes"}}';
		assertWritesOnce(config, call('g(a, b, /* c */);'), call('g(\n\t\t\ta,\n\t\t\tb, /* c */\n\t\t);'));
	}

	/** Every comment between the last comma and the close trails the last argument, own-line ones included. */
	@:pin('control')
	@:killer('M-CALL-AFTER-LAST-SEP-TAIL-LEFT')
	public function testOwnLineCommentsAfterTheLastCommaTrailTheLastArgument(): Void {
		assertWritesOnce(REMOVE, call('g(a, b,\n\t\t\t/* c */\n\t\t\t/* d */\n\t\t);'), call('g(a, b /* c */ /* d */);'));
	}

	/** With no comma, comments before the close trail the last argument too: what `remove` writes reads back the same. */
	@:pin('control')
	@:killer('M-CALL-BEFORE-CLOSE-TAIL-LEFT')
	public function testCommentsBeforeTheCloseTrailTheLastArgument(): Void {
		assertWritesOnce(REMOVE, call('g(a, b /* c */ /* d */);'), call('g(a, b /* c */ /* d */);'));
	}

	/** Block comments in one trailing slot share a line; only a line comment ends one. */
	@:pin('control')
	@:killer('M-COMMENT-RUN-BLOCKS-SPLIT')
	public function testBlockCommentsAfterTheLastCommaShareALine(): Void {
		assertWritesOnce(KEEP, call('g(a, b, /* c */ /* d */);'), call('g(\n\t\t\ta,\n\t\t\tb, /* c */ /* d */\n\t\t);'));
	}

	/** A block comment after a comma that an argument follows still leads that argument. */
	public function testCommentBeforeALaterArgumentStillLeadsIt(): Void {
		assertWritesOnce(KEEP, call('g(a, /* c */ b);'), call('g(a, /* c */ b);'));
	}

	private function call(stmt: String): String {
		return 'class A {\n\tfunction f() {\n\t\t$stmt\n\t}\n}\n';
	}

	/** Under `config`, `source` writes as `expected`, and `expected` writes as itself. */
	private function assertWritesOnce(config: String, source: String, expected: String): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(config);
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts));
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(expected), opts));
	}

}
