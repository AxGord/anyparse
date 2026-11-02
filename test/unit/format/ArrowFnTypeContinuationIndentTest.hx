package unit.format;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * The continuation indent of a wrapped function-TYPE signature `(a:A, b:B, …) -> R`.
 *
 * A function type has no body to set its parameters apart from, so they continue one unit past
 * the line the type starts on, wherever it stands. Nested in a type argument (also a `new`
 * expression's), parentheses, an abstract's underlying type or an `#if` type arm (every arm) the
 * cascade's additional unit stays: the type hangs off its enclosing
 * construct's own opening there. An anon-body element starts a line of its own, so a function
 * type written as its field is direct again however the anon itself is nested.
 */
@:nullSafety(Strict)
final class ArrowFnTypeContinuationIndentTest extends Test {

	private static final PARAMS: String = '(document:TextDocument, position:Position, context:CompletionContext, token:CancellationToken,';
	private static final REST: String =
		'next:ProvideCompletionItemsSignature) -> ProviderResult<EitherType<Array<CompletionItem>, CompletionList>>';

	@:pin('control')
	@:killer('M-FNTYPE-COMPACT-OFF')
	public function testClassMemberTypeContinuesOneUnitPastTheMember(): Void {
		assertContinues('class A {\n\tvar f:${flat()};\n}\n', '\tvar f:$PARAMS', 2);
	}

	@:pin('control')
	@:killer('M-FNTYPE-COMPACT-OFF')
	public function testFunctionParameterTypeContinuesOneUnit(): Void {
		assertContinues('class A {\n\tfunction g(cb:${flat()}):Void {}\n}\n', '\tfunction g(cb:$PARAMS', 2);
	}

	@:pin('control')
	@:killer('M-FNTYPE-COMPACT-OFF')
	public function testReturnTypeContinuesOneUnit(): Void {
		assertContinues('class A {\n\tfunction g():${flat()} {}\n}\n', '\tfunction g():$PARAMS', 2);
	}

	@:pin('control')
	@:killer('M-FNTYPE-COMPACT-OFF')
	public function testPlainTypedefRightHandSideContinuesOneUnit(): Void {
		assertContinues('typedef F = ${flat()};\n', 'typedef F = $PARAMS', 1);
	}

	@:pin('control')
	@:killer('M-FNTYPE-COMPACT-OFF')
	public function testAnonFieldContinuesOneUnitPastTheField(): Void {
		assertContinues('typedef M = {\n\t?f:${flat()},\n}\n', '\t?f:$PARAMS', 2);
	}

	@:pin('control')
	@:killer('M-FNTYPE-NEST-TYPE-ARG-OFF')
	public function testTypeArgumentKeepsTheAdditionalUnit(): Void {
		assertContinues('class A {\n\tvar f:Array<${flat()}>;\n}\n', '\tvar f:Array<$PARAMS', 3);
	}

	@:pin('control')
	@:killer('M-FNTYPE-NEST-TYPE-ARG-OFF')
	public function testTypeArgumentInAnonFieldKeepsTheAdditionalUnit(): Void {
		assertContinues('typedef M = {\n\t?f:Null<${flat()}>,\n}\n', '\t?f:Null<$PARAMS', 3);
	}

	@:pin('control')
	@:killer('M-FNTYPE-NEST-PARENS-OFF')
	public function testParenthesesKeepTheAdditionalUnit(): Void {
		assertContinues('typedef M = {\n\t?f:(${flat()}),\n}\n', '\t?f:($PARAMS', 3);
	}

	@:pin('control')
	@:killer('M-FNTYPE-NEST-COND-OFF')
	public function testConditionalTypeArmKeepsTheAdditionalUnit(): Void {
		assertContinues('typedef C = #if a ${flat()}; #else Int; #end\n', 'typedef C = #if a $PARAMS', 2);
	}

	@:pin('control')
	@:killer('M-FNTYPE-NEST-RESET-OFF')
	public function testAnonFieldInsideATypeArgumentIsDirectAgain(): Void {
		assertContinues('class A {\n\tvar f:Array<{?f:${flat()}}>;\n}\n', '?f:$PARAMS', 3);
	}

	public function testIsAFixedPoint(): Void {
		final once: String = write('typedef M = {\n\t?f:${flat()},\n}\n');
		Assert.equals(once, write(once));
	}

	@:pin('control')
	@:killer('M-FNTYPE-NEST-NEW-OFF')
	public function testNewExpressionTypeArgumentKeepsTheAdditionalUnit(): Void {
		assertContinues('class A {\n\tfunction g() {\n\t\tnew Foo<${flat()}>();\n\t}\n}\n', '\t\tnew Foo<$PARAMS', 4);
		assertContinues('class A {\n\tfunction g() {\n\t\tnew Foo<${flat()}>();\n\t}\n}\n', '\t\tnew Foo<$PARAMS', 4, true);
	}

	@:pin('control')
	@:killer('M-FNTYPE-NEST-ABSTRACT-OFF')
	public function testAbstractUnderlyingTypeKeepsTheAdditionalUnit(): Void {
		assertContinues('abstract A(${flat()}) {}\n', 'abstract A($PARAMS', 2);
		assertContinues('enum abstract A(${flat()}) {}\n', 'enum abstract A($PARAMS', 2);
		assertContinues('abstract A(${flat()}) {}\n', 'abstract A($PARAMS', 2, true);
		assertContinues('enum abstract A(${flat()}) {}\n', 'enum abstract A($PARAMS', 2, true);
	}

	@:pin('control')
	@:killer('M-FNTYPE-NEST-COND-OFF')
	public function testElseAndElseifArmsKeepTheAdditionalUnit(): Void {
		assertContinues('typedef C = #if a Int; #else ${flat()}; #end\n', 'typedef C = #if a Int; #else $PARAMS', 2);
		assertContinues('typedef C = #if a Int; #elseif b ${flat()}; #else Int; #end\n', 'typedef C = #if a Int; #elseif b $PARAMS', 2);
	}

	@:pin('control')
	@:killer('M-FNTYPE-COMPACT-OFF')
	public function testPropertyVarContinuesOneUnitPastTheMember(): Void {
		assertContinues('class A {\n\tvar f(default, null):${flat()};\n}\n', '\tvar f(default, null):$PARAMS', 2);
	}

	@:pin('control')
	@:killer('M-FNTYPE-NEST-RESET-PLAIN-OFF')
	public function testPlainWriterResetsTheNestedContextPerAnonField(): Void {
		assertContinues('class A {\n\tvar f:Array<{?f:${flat()}}>;\n}\n', '?f:$PARAMS', 3, true);
		assertContinues('class A {\n\tvar f:(${flat()});\n}\n', '\tvar f:($PARAMS', 3, true);
	}

	@:pin('control')
	@:killer('M-FNTYPE-NEST-ABSTRACT-HEAD-OFF')
	public function testConditionalAbstractHeadKeepsTheAdditionalUnit(): Void {
		assertContinues('#if a\nabstract A(${flat()}) {\n#else\nabstract A(Int) {\n#end\n}\n', 'abstract A($PARAMS', 2);
	}

	private inline function write(src: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson('{}'));
	}

	private inline function writePlain(src: String): String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson('{}'));
	}

	/** The wrapped line must start with `$head` and its continuation sit at `$tabs` tabs. */
	private function assertContinues(src: String, head: String, tabs: Int, plain: Bool = false): Void {
		final out: String = plain ? writePlain(src) : write(src);
		final indent: String = [for (_ in 0...tabs) '\t'].join('');
		Assert.isTrue(out.indexOf('$head\n$indent$REST') != -1, 'continuation must sit at $tabs tab(s): <$out>');
	}

	private static function flat(): String {
		return '$PARAMS $REST';
	}

}
