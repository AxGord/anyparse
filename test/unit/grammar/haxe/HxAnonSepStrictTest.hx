package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import haxe.Exception;
import utest.Assert;
import utest.Test;

/**
 * Two fields of an anonymous structure TYPE with nothing between them are refused, as the Haxe
 * compiler refuses them, by the plain and the trivia parser alike — otherwise the writer's
 * fixed-point check passes sep-less source that does not compile. A field that consumed its own
 * `;` (a `function` field included — Haxe allows it no body), a `#if … #end` field region and a
 * `var` field whose type ends with `}` need no `,` after them; a trailing `,` stays legal.
 */
@:nullSafety(Strict)
class HxAnonSepStrictTest extends Test {

	private static final ADJACENT_SHORT: String = 'typedef T = { a:Int b:String }';
	private static final ADJACENT_SHORT_LINES: String = 'typedef T = {\n\ta:Int\n\tb:String\n}';
	private static final VAR_WITHOUT_SEMI: String = 'typedef T = { var a:Int var b:String }';
	private static final SHORT_ENDED_BY_BRACE: String = 'typedef T = { a:{x:Int} b:String }';
	private static final VAR_ENDED_BY_GENERIC: String = 'typedef T = { var a:Array<{x:Int}> var b:String; }';
	private static final VAR_ENDED_BY_ANON: String = 'typedef T = {\n\tvar a:{x:Int}\n\tvar b:String;\n}';
	private static final VAR_ENDED_BY_ARROW: String = 'typedef T = {\n\tvar a:Int->{x:Int}\n\tvar b:String;\n}';
	private static final VAR_ENDED_BY_ARROW_FN: String = 'typedef T = {\n\tvar a:(Int) -> {x:Int}\n\tvar b:String;\n}';
	private static final SELF_TERMINATED: String = 'typedef T = {\n\tvar a:Int;\n\tvar b:String;\n}';
	private static final REGION: String = 'typedef T = {\n\ta:Int,\n\t#if x\n\tvar b:Int;\n\t#end\n\tc:Int\n}';
	private static final FN_TERMINATED: String = 'typedef T = {\n\tfunction f():Void;\n\tvar b:Int;\n}';
	private static final FN_BLOCK_BODY: String = 'typedef T = {\n\tfunction f():Void {}\n\tvar b:Int;\n}';

	public function new(): Void {
		super();
	}

	@:pin('control') @:killer('M-ANON-SEP-PLAIN-OPTIONAL')
	public function testPlainRefusesAdjacentFields(): Void {
		Assert.raises(() -> HaxeModuleParser.parse(ADJACENT_SHORT), Exception);
		Assert.raises(() -> HaxeModuleParser.parse(ADJACENT_SHORT_LINES), Exception);
		Assert.raises(() -> HaxeModuleParser.parse(VAR_WITHOUT_SEMI), Exception);
		Assert.raises(() -> HaxeModuleParser.parse(SHORT_ENDED_BY_BRACE), Exception);
		Assert.raises(() -> HaxeModuleParser.parse(VAR_ENDED_BY_GENERIC), Exception);
	}

	@:pin('control') @:killer('M-ANON-SEP-TRIVIA-OPTIONAL')
	public function testTriviaRefusesAdjacentFields(): Void {
		Assert.raises(() -> HaxeModuleTriviaParser.parse(ADJACENT_SHORT), Exception);
		Assert.raises(() -> HaxeModuleTriviaParser.parse(ADJACENT_SHORT_LINES), Exception);
		Assert.raises(() -> HaxeModuleTriviaParser.parse(VAR_WITHOUT_SEMI), Exception);
		Assert.raises(() -> HaxeModuleTriviaParser.parse(SHORT_ENDED_BY_BRACE), Exception);
		Assert.raises(() -> HaxeModuleTriviaParser.parse(VAR_ENDED_BY_GENERIC), Exception);
	}

	/** Haxe's class notation takes a field's closing `}` for its `;`. */
	@:pin('control') @:killer('M-ANON-SEP-VAR-BRACE-NOT-SELF-ENDED')
	public function testClassNotationFieldEndedByBraceNeedsNoSeparator(): Void {
		Assert.equals(1, HaxeModuleParser.parse(VAR_ENDED_BY_ANON).decls.length);
		Assert.notNull(HaxeModuleTriviaParser.parse(VAR_ENDED_BY_ANON));
	}

	@:pin('control') @:killer('M-ANON-SEP-ARROW-NOT-BRACE-ENDED')
	public function testFunctionTypeEndedByBraceNeedsNoSeparator(): Void {
		Assert.equals(1, HaxeModuleParser.parse(VAR_ENDED_BY_ARROW).decls.length);
		Assert.notNull(HaxeModuleTriviaParser.parse(VAR_ENDED_BY_ARROW));
	}

	@:pin('control') @:killer('M-ANON-SEP-ARROW-FN-NOT-BRACE-ENDED')
	public function testArrowFunctionTypeEndedByBraceNeedsNoSeparator(): Void {
		Assert.equals(1, HaxeModuleParser.parse(VAR_ENDED_BY_ARROW_FN).decls.length);
		Assert.notNull(HaxeModuleTriviaParser.parse(VAR_ENDED_BY_ARROW_FN));
	}

	@:pin('control') @:killer('M-ANON-SEP-PLAIN-NO-BYTE-WAIVER')
	public function testPlainAcceptsSelfTerminatedFields(): Void {
		Assert.equals(1, HaxeModuleParser.parse(SELF_TERMINATED).decls.length);
	}

	@:pin('control') @:killer('M-ANON-SEP-TRIVIA-NO-BYTE-WAIVER')
	public function testTriviaRoundTripsSelfTerminatedFields(): Void {
		Assert.equals(SELF_TERMINATED, HxWriteFixture.triviaWrite(SELF_TERMINATED, '{}'));
	}

	@:pin('control') @:killer('M-ANON-SEP-COND-NOT-SELF-ENDED')
	public function testRegionNeedsNoSeparatorAfterIt(): Void {
		Assert.equals(1, HaxeModuleParser.parse(REGION).decls.length);
		Assert.equals(REGION, HxWriteFixture.triviaWrite(REGION, '{}'));
	}

	/** A `function` field ends only with its own `;`: Haxe refuses a body on it. */
	@:pin('control') @:killer('M-ANON-SEP-FN-NOT-SELF-ENDED')
	public function testFunctionFieldNeedsItsOwnSemicolon(): Void {
		Assert.equals(1, HaxeModuleParser.parse(FN_TERMINATED).decls.length);
		Assert.notNull(HaxeModuleTriviaParser.parse(FN_TERMINATED));
		Assert.raises(() -> HaxeModuleParser.parse(FN_BLOCK_BODY), Exception);
		Assert.raises(() -> HaxeModuleTriviaParser.parse(FN_BLOCK_BODY), Exception);
	}

	@:pin('guard')
	public function testTrailingCommaStaysLegal(): Void {
		final src: String = 'typedef T = {\n\ta:Int,\n\tb:String,\n}';
		Assert.equals(1, HaxeModuleParser.parse(src).decls.length);
		Assert.equals(src, HxWriteFixture.triviaWrite(src, '{}'));
	}

}
