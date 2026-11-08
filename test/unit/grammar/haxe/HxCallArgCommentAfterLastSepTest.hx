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
 * the file. A comment before the last comma and one after it keep their sides of the comma, and a comment after a
 * line comment starts the next line at the argument's indent, never at column 0.
 */
class HxCallArgCommentAfterLastSepTest extends Test {

	private static inline final KEEP: String = '{"wrapping": {"trailingComma": "keep"}}';
	private static inline final REMOVE: String = '{"wrapping": {"trailingComma": "remove"}}';
	private static inline final ADD: String = '{"wrapping": {"trailingComma": "keep", "callParameter": {'
		+ '"defaultWrap": "onePerLine", "rules": []}}, "trailingCommas": {"callArgumentDefault": "yes"}}';

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
		assertWritesOnce(ADD, call('g(a, b, /* c */);'), call('g(\n\t\t\ta,\n\t\t\tb, /* c */\n\t\t);'));
	}

	@:pin('control')
	@:killer('M-CALL-AFTER-SEP-KEPT-UNWRITTEN')
	public function testKeepWritesEachCommentOnItsSideOfTheComma(): Void {
		assertWritesOnce(KEEP, call('g(a, b /* x */, /* c */);'), call('g(\n\t\t\ta,\n\t\t\tb /* x */, /* c */\n\t\t);'));
	}

	@:pin('control')
	@:killer('M-CALL-AFTER-SEP-DROPPED-UNJOINED')
	public function testRemoveWritesBothCommentsBesideTheArgument(): Void {
		assertWritesOnce(REMOVE, call('g(a, b /* x */, /* c */);'), call('g(a, b /* x */ /* c */);'));
	}

	@:pin('control')
	@:killer('M-CALL-AFTER-SEP-BESIDE-BEFORE-DROPPED')
	public function testAddWritesEachCommentOnItsSideOfTheComma(): Void {
		assertWritesOnce(ADD, call('g(a, b /* x */, /* c */);'), call('g(\n\t\t\ta,\n\t\t\tb /* x */, /* c */\n\t\t);'));
	}

	@:pin('control')
	@:killer('M-TRAILING-RUN-COLUMN-ZERO')
	public function testKeepWritesTheCommentAfterALineCommentAtTheArgumentIndent(): Void {
		assertWritesOnce(KEEP, call('g(a, b, // c\n\t\t\t/* d */\n\t\t);'), call('g(\n\t\t\ta,\n\t\t\tb, // c\n\t\t\t/* d */\n\t\t);'));
	}

	@:pin('control')
	@:killer('M-TRAILING-RUN-COLUMN-ZERO')
	public function testRemoveWritesTheCommentAfterALineCommentAtTheArgumentIndent(): Void {
		assertWritesOnce(REMOVE, call('g(a, b, // c\n\t\t\t/* d */\n\t\t);'), call('g(a,\n\t\t\tb // c\n\t\t\t/* d */);'));
	}

	@:pin('control')
	@:killer('M-TRAILING-RUN-COLUMN-ZERO')
	public function testAddWritesTheCommentAfterALineCommentAtTheArgumentIndent(): Void {
		assertWritesOnce(ADD, call('g(a, b, // c\n\t\t\t/* d */\n\t\t);'), call('g(\n\t\t\ta,\n\t\t\tb, // c\n\t\t\t/* d */\n\t\t);'));
	}

	/** A run that opens with a block comment and ends with a line comment still keeps the close paren off its line. */
	@:pin('control')
	@:killer('M-TRAILING-GUARD-FIRST-COMMENT')
	public function testALineCommentEndingTheRunKeepsTheCloseOffItsLine(): Void {
		assertWritesOnce(KEEP, call('g(a, b /* x */ // c\n\t\t);'), call('g(a,\n\t\t\tb /* x */ // c\n\t\t\t);'));
	}

	/** Both comments on the argument's line are one run, so the comma `add` writes after it reads back the same. */
	@:pin('control')
	@:killer('M-CALL-SAME-LINE-RUN-FIRST-ONLY')
	public function testAddKeepsASameLineRunOnTheArgumentLine(): Void {
		assertWritesOnce(ADD, call('g(a, b /* x */ // c\n\t\t);'), call('g(\n\t\t\ta,\n\t\t\tb /* x */ // c\n\t\t\t,\n\t\t);'));
	}

	/** Every comment between the last comma and the close trails the last argument, own-line ones included. */
	@:pin('control')
	@:killer('M-CALL-AFTER-LAST-SEP-TAIL-LEFT')
	public function testOwnLineCommentsAfterTheLastCommaTrailTheLastArgument(): Void {
		assertWritesOnce(REMOVE, call('g(a, b,\n\t\t\t/* c */\n\t\t\t/* d */\n\t\t);'), call('g(a, b /* c */ /* d */);'));
	}

	/** With no comma, a comment on its own line before the close trails the last argument too. */
	@:pin('control')
	@:killer('M-CALL-BEFORE-CLOSE-TAIL-LEFT')
	public function testCommentsBeforeTheCloseTrailTheLastArgument(): Void {
		assertWritesOnce(REMOVE, call('g(a, b /* c */\n\t\t\t/* d */\n\t\t);'), call('g(a, b /* c */ /* d */);'));
	}

	/** Block comments in one trailing slot share a line; only a line comment ends one. */
	@:pin('control')
	@:killer('M-COMMENT-RUN-BLOCKS-SPLIT')
	public function testBlockCommentsAfterTheLastCommaShareALine(): Void {
		assertWritesOnce(KEEP, call('g(a, b, /* c */ /* d */);'), call('g(\n\t\t\ta,\n\t\t\tb, /* c */ /* d */\n\t\t);'));
	}

	/** A line comment after a NON-last comma beside a before-comma comment still leads the next argument. */
	@:pin('control')
	@:killer('M-CALL-AFTER-SEP-LINE-NON-LAST-CLAIMED')
	public function testLineCommentAfterANonLastCommaBesideABeforeCommaCommentLeadsTheNextArgument(): Void {
		assertWritesOnce(KEEP, call('g(a /* x */, // c\n\t\t\tb);'), call('g(\n\t\t\ta /* x */,\n\t\t\t// c\n\t\t\tb\n\t\t);'));
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
