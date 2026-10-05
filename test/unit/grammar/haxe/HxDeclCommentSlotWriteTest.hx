package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A block comment between a declaration's name or type annotation and the token after it survives
 * the trivia round trip, in place, and the result is a fixed point.
 *
 * Two gaps had no reader. After a function's RETURN TYPE the comment lands in the body field's
 * `BeforeLeading` slot (the parser captured it), but the brace-placement seat that writes a
 * function body never read that slot: `function f():Int /* c *\/ {` lost the comment while the
 * same comment after a bare `)` — the params' close-trailing slot — was kept. And before a `@:lead`
 * literal (`var x /* c *\/ = 1`, `f(a /* c *\/ = 1)`, `{x /* c *\/:Int}`) the parser skipped the
 * gap as whitespace before matching the lead, so nothing captured it; it now lands in the field's
 * `BeforeLead` slot and is written back before the lead.
 */
@:nullSafety(Strict)
final class HxDeclCommentSlotWriteTest extends Test {

	public function new(): Void {
		super();
	}

	/** The gap between a return type and a block body, same-line and own-line. */
	@:pin('control')
	@:killer('M-FNBODY-GAP-COMMENT-NONE')
	public function testReturnTypeToBlockBodyKeepsTheComment(): Void {
		assertMember('function bar():Int /* c */ {\n\t\treturn 1;\n\t}', 'function bar():Int /* c */ {\n\t\treturn 1;\n\t}');
		assertMember('function bar():Int\n\t/* c */\n\t{\n\t\treturn 1;\n\t}', 'function bar():Int /* c */ {\n\t\treturn 1;\n\t}');
		assertMember('function bar():Int /* a */ /* b */ {}', 'function bar():Int /* a */ /* b */ {}');
	}

	/** A LINE comment there ends the signature line, exactly as it does after a bare `)`. */
	@:pin('control')
	@:killer('M-FNBODY-GAP-COMMENT-NONE')
	public function testReturnTypeLineCommentBreaksBeforeTheBody(): Void {
		assertMember('function bar():Int // c\n\t{\n\t\treturn 1;\n\t}', 'function bar():Int // c\n\t{\n\t\treturn 1;\n\t}');
		assertMember('function bar():Int // c\n\t\treturn 1;', 'function bar():Int // c\n\t\treturn 1;');
	}

	/** The same gap before an expression body. */
	@:pin('control')
	@:killer('M-FNBODY-GAP-COMMENT-NONE')
	public function testReturnTypeToExpressionBodyKeepsTheComment(): Void {
		assertMember('function bar():Int /* c */ return 1;', 'function bar():Int /* c */\n\t\treturn 1;');
	}

	/** An optional `@:lead` field after a name or a type: `=` initialisers and defaults, `:` hints. */
	@:pin('control')
	@:killer('M-BEFORE-LEAD-CAPTURE-NONE')
	@:killer('M-BEFORE-LEAD-WRITER-OPT-NONE')
	public function testOptionalLeadKeepsTheComment(): Void {
		assertMember('var x /* c */ = 1;', 'var x /* c */ = 1;');
		assertMember('var x:Int /* c */ = 1;', 'var x:Int /* c */ = 1;');
		assertMember('var x /* c */:Int = 1;', 'var x /* c */:Int = 1;');
		assertMember('var x(get, set) /* c */:Int;', 'var x(get, set) /* c */:Int;');
		assertMember('var a /* c */ = 1, b /* d */ = 2;', 'var a /* c */ = 1, b /* d */ = 2;');
		assertMember('function bar(a /* c */ = 1) {}', 'function bar(a /* c */ = 1) {}');
		assertMember('function bar(a:Int /* c */ = 1) {}', 'function bar(a:Int /* c */ = 1) {}');
		assertMember('function bar(?a /* c */:Int) {}', 'function bar(?a /* c */:Int) {}');
		assertMember('function bar() {\n\t\tfinal x:Int /* c */ = 1;\n\t}', 'function bar() {\n\t\tfinal x:Int /* c */ = 1;\n\t}');
		assertMember(
			'function bar() {\n\t\ttry {} catch (e /* c */:Dynamic) {}\n\t}',
			'function bar() {\n\t\ttry {} catch (e /* c */:Dynamic) {}\n\t}'
		);
		assertModule('enum E {\n\tA(x /* c */:Int);\n}', 'enum E {\n\tA(x /* c */:Int);\n}');
	}

	/** A mandatory `@:lead` field after a name: anonymous-structure and object-literal fields. */
	@:pin('control')
	@:killer('M-BEFORE-LEAD-MANDATORY-NONE')
	@:killer('M-BEFORE-LEAD-WRITER-MANDATORY-NONE')
	public function testMandatoryLeadKeepsTheComment(): Void {
		assertModule('typedef T = {x /* c */:Int}', 'typedef T = {x /* c */:Int}');
		assertModule('typedef T = {?x /* c */:Int}', 'typedef T = {?x /* c */:Int}');
		assertMember('function bar() {\n\t\tvar o = {a /* c */: 1};\n\t}', 'function bar() {\n\t\tvar o = {a /* c */: 1};\n\t}');
	}

	private function assertMember(member: String, expected: String): Void {
		assertModule('class Foo {\n\t$member\n}', 'class Foo {\n\t$expected\n}');
	}

	private function assertModule(source: String, expected: String): Void {
		final out: String = HxWriteFixture.triviaWrite(source, '{}');
		Assert.equals(expected, out);
		Assert.equals(out, HxWriteFixture.triviaWrite(out, '{}'), 'not a fixed point');
	}

}
