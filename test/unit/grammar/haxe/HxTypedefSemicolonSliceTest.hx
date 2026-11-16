package unit.grammar.haxe;

import anyparse.check.haxe.types.PreferIntersectionType;
import unit.CheckFixture;
import utest.Assert;
import utest.Test;

/**
 * `whitespace.typedefSemicolon`: the optional `;` after a typedef. A separate key from
 * `whitespace.optionalSemicolon`, sharing its three-way policy type but never its value, because a
 * config may want `always` for statement terminators and `never` here.
 *
 * `never` drops the `;` only when the WRITTEN right-hand side ends with `}` (an anonymous structure,
 * or a last `& {…}` clause); any other body keeps it. The decision reads the AST the
 * writer receives, so a fixer that rewrites a structure into an intersection keeps its `;`.
 */
@:nullSafety(Strict)
final class HxTypedefSemicolonSliceTest extends Test {

	private static final BASE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}';
	private static final NEVER: String = '$BASE, "whitespace": {"typedefSemicolon": "never"}}';
	private static final ALWAYS: String = '$BASE, "whitespace": {"typedefSemicolon": "always"}}';
	private static final PRESERVE: String = '$BASE, "whitespace": {}}';
	private static final STMT_ALWAYS_TYPEDEF_NEVER: String =
		'$BASE, "whitespace": {"optionalSemicolon": "always", "typedefSemicolon": "never"}}';
	private static final STMT_NEVER: String = '$BASE, "whitespace": {"optionalSemicolon": "never"}}';

	public function new(): Void {
		super();
	}

	/** `never` drops the `;` after a one-line structure body, an extension one included. */
	@:pin('control')
	@:killer('M-TDSEMI-NEVER-DROPS-NOTHING')
	public function testNeverDropsAfterAStructure(): Void {
		final src: String = 'typedef A = {> Base, name:String};\ntypedef F = {x:Int};';
		Assert.equals('typedef A = {> Base, name:String}\ntypedef F = {x:Int}', triviaWrite(src, NEVER));
	}

	/** A structure written over several lines loses its `;` after the closing `}`. */
	@:pin('control')
	@:killer('M-TDSEMI-NEVER-DROPS-NOTHING')
	public function testNeverDropsAfterAMultiLineStructure(): Void {
		final body: String = '\tvar x:Int;\n\tvar yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy:String;\n'
			+ '\tvar wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww:String;\n';
		Assert.equals('typedef M = {\n$body}', triviaWrite('typedef M = {\n$body};', NEVER));
	}

	/** A body that does not end with `}` keeps its `;` under `never`: the policy drops it only after a brace. */
	@:pin('control')
	@:killer('M-TDSEMI-NEVER-DROPS-ALL')
	public function testNeverKeepsAfterABodyThatDoesNotEndWithABrace(): Void {
		final src: String = 'typedef C = Base & Other;\ntypedef D = (a:Int) -> Void;';
		Assert.equals(src, triviaWrite(src, NEVER));
	}

	/** With intersection clauses the written body ends with the LAST clause, not the head type. */
	@:pin('control')
	@:killer('M-TDSEMI-TAIL-IGNORED')
	public function testNeverReadsTheLastIntersectionClause(): Void {
		final src: String = 'typedef E = Base & {x:Int};\ntypedef G = {x:Int} & Base;';
		Assert.equals('typedef E = Base & {x:Int}\ntypedef G = {x:Int} & Base;', triviaWrite(src, NEVER));
	}

	/** A function type whose return type is a structure ends with `}`, so `never` drops its `;`. */
	@:pin('control')
	@:killer('M-ANON-SEP-ARROW-NOT-BRACE-ENDED')
	public function testNeverDropsAfterAFunctionTypeReturningAStructure(): Void {
		Assert.equals('typedef R = Int->{x:Int}', triviaWrite('typedef R = Int -> {x:Int};', NEVER));
	}

	/** The parenthesised function-type spelling reads its return type the same way. */
	@:pin('control')
	@:killer('M-ANON-SEP-ARROW-FN-NOT-BRACE-ENDED')
	public function testNeverDropsAfterANamedArgFunctionTypeReturningAStructure(): Void {
		Assert.equals('typedef S = (a:Int) -> {x:Int}', triviaWrite('typedef S = (a:Int) -> {x:Int};', NEVER));
	}

	/** `always` writes the `;` after every typedef, a structure body included. */
	@:pin('control')
	@:killer('M-TDSEMI-KEY-NOT-LOADED')
	public function testAlwaysAddsTheSemicolon(): Void {
		final src: String = 'typedef F = {x:Int}\ntypedef C = Base & Other;';
		Assert.equals('typedef F = {x:Int};\ntypedef C = Base & Other;', triviaWrite(src, ALWAYS));
	}

	/** The default keeps what the source wrote, so a config without the key is byte-inert. */
	@:pin('control')
	@:killer('M-TDSEMI-DEFAULT-NEVER')
	public function testPreserveKeepsBothForms(): Void {
		final src: String = 'typedef A = {a:Int};\ntypedef F = {x:Int}';
		Assert.equals(src, triviaWrite(src, PRESERVE));
	}

	/** The key and `optionalSemicolon` answer separately, in both directions. */
	@:pin('control')
	@:killer('M-TDSEMI-SHARED-KEY')
	public function testTheKeyIsSeparateFromOptionalSemicolon(): Void {
		final gains: String = 'typedef B = {a:Int};\n\nclass C {\n\tfunction f() {\n\t\tfinal o = {a: 1}\n\t}\n}';
		final gained: String = 'typedef B = {a:Int}\n\nclass C {\n\tfunction f() {\n\t\tfinal o = {a: 1};\n\t}\n}';
		Assert.equals(gained, triviaWrite(gains, STMT_ALWAYS_TYPEDEF_NEVER));
		final drops: String = 'typedef B = {a:Int};\n\nclass C {\n\tfunction f() {\n\t\tfinal o = {a: 1};\n\t}\n}';
		final dropped: String = 'typedef B = {a:Int};\n\nclass C {\n\tfunction f() {\n\t\tfinal o = {a: 1}\n\t}\n}';
		Assert.equals(dropped, triviaWrite(drops, STMT_NEVER));
	}

	/** A structure the intersection fixer rewrote into `A & B` keeps the `;` its new body needs. */
	@:pin('control')
	@:killer('M-TDSEMI-NEVER-DROPS-ALL')
	public function testAnIntersectionTheFixerWroteKeepsItsSemicolon(): Void {
		final src: String = 'typedef A = {a:Int}\ntypedef B = {b:Int}\ntypedef C = {\n\t> A,\n\t> B,\n}\n';
		final fixed: String = CheckFixture.fixedSource(new PreferIntersectionType(), src);
		Assert.stringContains('typedef C = A & B;', triviaWrite(fixed, NEVER));
	}

	/** A blank line, a doc comment and a trailing comment after the dropped `;` all stay where they were. */
	@:pin('guard')
	public function testCommentsAndBlankLinesAfterTheTypedefSurvive(): Void {
		final src: String = 'typedef A = {a:Int};\n\n/** doc */\nclass K {}\n\ntypedef B = {b:Int}; // trailing\ntypedef C = {c:Int};';
		final out: String = 'typedef A = {a:Int}\n\n/** doc */\nclass K {}\n\ntypedef B = {b:Int} // trailing\ntypedef C = {c:Int}';
		Assert.equals(out, triviaWrite(src, NEVER));
	}

	private inline function triviaWrite(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

}
