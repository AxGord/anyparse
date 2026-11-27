package unit.grammar.haxe;

import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `whitespace.returnSemicolon`: the optional `;` after a brace-terminated `return` value (an object
 * literal, a `switch`, a block-bodied expression). A separate key from `whitespace.optionalSemicolon`,
 * sharing its three-way policy type: stated, it alone decides the return slot; absent, the slot follows
 * `optionalSemicolon`, so a config that predates the key keeps its bytes.
 *
 * `never` drops the `;` only where the value ends with `}`; `return 42` keeps it, since omitting it
 * there is `Missing ;`. Trivia-mode writer only: the plain writer keeps its AST-shape gate.
 */
@:nullSafety(Strict)
final class HxReturnSemicolonSliceTest extends Test {

	private static final BASE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}';
	private static final ALWAYS: String = '$BASE, "whitespace": {"returnSemicolon": "always"}}';
	private static final NEVER: String = '$BASE, "whitespace": {"returnSemicolon": "never"}}';
	private static final PRESERVE: String = '$BASE, "whitespace": {"returnSemicolon": "preserve"}}';
	private static final GLOBAL_ALWAYS: String = '$BASE, "whitespace": {"optionalSemicolon": "always"}}';
	private static final GLOBAL_ALWAYS_RETURN_PRESERVE: String =
		'$BASE, "whitespace": {"optionalSemicolon": "always", "returnSemicolon": "preserve"}}';
	private static final GLOBAL_NEVER_RETURN_ALWAYS: String =
		'$BASE, "whitespace": {"optionalSemicolon": "never", "returnSemicolon": "always"}}';
	private static final OBJ: String = 'class C {\n\tfunction f() {\n\t\treturn {a: 1}%s\n\t}\n}';
	private static final SWITCH: String = 'class C {\n\tfunction f() {\n\t\treturn switch (v) {\n\t\t\tcase _: 1;\n\t\t}%s\n\t}\n}';
	private static final LAMBDA: String = 'class C {\n\tfunction f() {\n\t\tfinal g = function() {\n\t\t\treturn {a: 1}%s\n\t\t};\n\t}\n}';
	private static final ARROW: String = 'class C {\n\tfunction f() {\n\t\tfinal g = () -> {\n\t\t\treturn {a: 1}%s\n\t\t};\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** `always` writes the `;` after an object literal, a `switch` and a `return` inside a function literal. */
	@:pin('control')
	@:killer('M-RETSEMI-GRAMMAR-KEY-UNNAMED')
	public function testAlwaysAddsTheSemicolon(): Void {
		Assert.equals(shape(OBJ, ';'), triviaWrite(shape(OBJ, ''), ALWAYS));
		Assert.equals(shape(SWITCH, ';'), triviaWrite(shape(SWITCH, ''), ALWAYS));
		Assert.equals(shape(LAMBDA, ';'), triviaWrite(shape(LAMBDA, ''), ALWAYS));
		Assert.equals(shape(ARROW, ';'), triviaWrite(shape(ARROW, ''), ALWAYS));
	}

	/** `never` drops the `;` after an object literal, a `switch` and a `return` inside a function literal. */
	@:pin('control')
	@:killer('M-RETSEMI-KEY-NOT-LOADED')
	public function testNeverDropsTheSemicolon(): Void {
		Assert.equals(shape(OBJ, ''), triviaWrite(shape(OBJ, ';'), NEVER));
		Assert.equals(shape(SWITCH, ''), triviaWrite(shape(SWITCH, ';'), NEVER));
		Assert.equals(shape(LAMBDA, ''), triviaWrite(shape(LAMBDA, ';'), NEVER));
		Assert.equals(shape(ARROW, ''), triviaWrite(shape(ARROW, ';'), NEVER));
	}

	/** A value that does not end with `}` keeps its `;` under `never`. */
	@:pin('guard')
	public function testNeverKeepsTheSemicolonAfterAPlainValue(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\treturn 42;\n\t}\n}';
		Assert.equals(src, triviaWrite(src, NEVER));
	}

	/** `preserve` re-emits the source form, with and without the `;`. */
	@:pin('guard')
	public function testPreserveKeepsBothForms(): Void {
		Assert.equals(shape(OBJ, ''), triviaWrite(shape(OBJ, ''), PRESERVE));
		Assert.equals(shape(OBJ, ';'), triviaWrite(shape(OBJ, ';'), PRESERVE));
		Assert.equals(shape(SWITCH, ''), triviaWrite(shape(SWITCH, ''), PRESERVE));
		Assert.equals(shape(SWITCH, ';'), triviaWrite(shape(SWITCH, ';'), PRESERVE));
	}

	/** Stated, the key beats `optionalSemicolon` in both directions, and the other slots keep following it. */
	@:pin('control')
	@:killer('M-RETSEMI-KEY-NOT-LOADED')
	public function testTheKeyIsSeparateFromOptionalSemicolon(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tvar a = {x: 1}\n\t\treturn {c: 3}\n\t}\n}';
		final keptReturn: String = 'class C {\n\tfunction f() {\n\t\tvar a = {x: 1};\n\t\treturn {c: 3}\n\t}\n}';
		Assert.equals(keptReturn, triviaWrite(src, GLOBAL_ALWAYS_RETURN_PRESERVE));
		final both: String = 'class C {\n\tfunction f() {\n\t\tvar a = {x: 1};\n\t\treturn {c: 3};\n\t}\n}';
		final gainedReturn: String = 'class C {\n\tfunction f() {\n\t\tvar a = {x: 1}\n\t\treturn {c: 3};\n\t}\n}';
		Assert.equals(gainedReturn, triviaWrite(both, GLOBAL_NEVER_RETURN_ALWAYS));
	}

	/** Without its own key the return slot follows `optionalSemicolon`: a config that predates the key keeps its bytes. */
	@:pin('control')
	@:killer('M-RETSEMI-FALLBACK-DROPPED')
	public function testWithoutTheKeyTheSlotFollowsOptionalSemicolon(): Void {
		Assert.equals(shape(OBJ, ';'), triviaWrite(shape(OBJ, ''), GLOBAL_ALWAYS));
		Assert.equals(shape(SWITCH, ';'), triviaWrite(shape(SWITCH, ''), GLOBAL_ALWAYS));
	}

	/** Options that never went through the config loader re-emit the source form. */
	@:pin('control')
	@:killer('M-RETSEMI-DEFAULT-NEVER')
	public function testTheDefaultOptionsPreserve(): Void {
		final opts: HxModuleWriteOptions = HxWriteOptionsKit.rawWith(_ -> {});
		Assert.equals(shape(OBJ, ';'), triviaWrite(shape(OBJ, ';'), opts));
		Assert.equals(shape(OBJ, ''), triviaWrite(shape(OBJ, ''), opts));
	}

	private inline function triviaWrite(src: String, config: HxWriteConfig): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

	private static function shape(template: String, semicolon: String): String {
		return template.replace('%s', semicolon);
	}

}
