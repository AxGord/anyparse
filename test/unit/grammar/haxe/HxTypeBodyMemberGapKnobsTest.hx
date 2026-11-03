package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * The gap between two members answers to that kind's OWN `<kind>EmptyLines` section: `extern abstract` and
 * `extern interface` are abstract and interface bodies, only `extern class` has a section of its own, and no
 * section moves another kind's body. Every expected text here is what haxe-formatter writes for that source and config.
 */
@:nullSafety(Strict)
class HxTypeBodyMemberGapKnobsTest extends Test {

	private static inline final MACRO_OPEN: String = 'class M {\n\tstatic function f() {\n\t\tvar c = macro class X {\n';
	private static inline final MACRO_CLOSE: String = '\n\t\t};\n\t}\n}';
	private static inline final SPLIT_LEAD: String = '\t/** d */\n\t// foo\n\n\t/** e */\n';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-EXTERN-CLASS-BETWEEN-DROPPED')
	public function testAnExternClassReadsItsOwnCounts(): Void {
		Assert.equals(
			'extern class X {\n\tstatic var s;\n\n\tvar a;\n\n\tfunction f();\n\n\tstatic function g();\n}',
			write(
				'extern class X {\n\tstatic var s;\n\tvar a;\n\tfunction f();\n\tstatic function g();\n}',
				'"externClassEmptyLines":{"betweenVars":1,"betweenFunctions":1,"afterVars":1}'
			)
		);
	}

	public function testTheClassSectionDoesNotMoveAnExternClass(): Void {
		final src: String = 'extern class X {\n\tvar a;\n\tvar b;\n\n\tvar c;\n}';
		Assert.equals(src, write(src, '"classEmptyLines":{"betweenVars":1,"existingBetweenFields":"remove"}'));
	}

	@:pin('control')
	@:killer('M-EXTERN-GATE-RESTORED')
	public function testAnExternAbstractIsAnAbstractBody(): Void {
		Assert.equals(
			'extern abstract Y(Int) {\n\tvar v;\n\n\tfunction a();\n\n\tfunction b();\n}',
			write('extern abstract Y(Int) {\n\tvar v;\n\tfunction a();\n\n\tfunction b();\n}', '')
		);
	}

	public function testAnExternInterfaceIsAnInterfaceBody(): Void {
		final src: String = 'extern interface Y {\n\tvar v;\n\tfunction a();\n\n\tfunction b();\n}';
		Assert.equals(src, write(src, ''));
	}

	@:pin('control')
	@:killer('M-ENUM-ABSTRACT-BETWEEN-DROPPED')
	public function testAnEnumAbstractReadsItsOwnCounts(): Void {
		Assert.equals(
			'enum abstract E(Int) {\n\tvar a;\n\n\tstatic var s;\n\tfunction f();\n\tfunction g();\n}',
			write(
				'enum abstract E(Int) {\n\tvar a;\n\tstatic var s;\n\tfunction f();\n\tfunction g();\n}',
				'"enumAbstractEmptyLines":{"betweenVars":1,"betweenFunctions":0,"afterVars":0}'
			)
		);
	}

	public function testTheAbstractSectionDoesNotMoveAnEnumAbstract(): Void {
		Assert.equals(
			'enum abstract E(Int) {\n\tvar a;\n\tvar b;\n\n\tfunction f();\n}',
			write('enum abstract E(Int) {\n\tvar a;\n\tvar b;\n\tfunction f();\n}', '"abstractEmptyLines":{"betweenVars":1,"afterVars":0}')
		);
	}

	@:pin('control')
	@:killer('M-ABSTRACT-BETWEEN-DROPPED')
	public function testAnAbstractReadsItsOwnCounts(): Void {
		Assert.equals(
			'abstract A(Int) {\n\tvar a;\n\n\tvar b;\n\tfunction f();\n\tfunction g();\n}',
			write(
				'abstract A(Int) {\n\tvar a;\n\tvar b;\n\tfunction f();\n\tfunction g();\n}',
				'"abstractEmptyLines":{"betweenVars":1,"afterVars":0,"betweenFunctions":0}'
			)
		);
	}

	public function testTheClassSectionDoesNotMoveAnAbstract(): Void {
		Assert.equals(
			'abstract A(Int) {\n\tvar a;\n\tvar b;\n\n\tvar c;\n\n\tfunction f();\n\n\tfunction g();\n}',
			write(
				'abstract A(Int) {\n\tvar a;\n\tvar b;\n\n\tvar c;\n\tfunction f();\n\tfunction g();\n}',
				'"classEmptyLines":{"betweenVars":1,"afterVars":0,"betweenFunctions":0,"existingBetweenFields":"remove"}'
			)
		);
	}

	@:pin('control')
	@:killer('M-MACRO-CLASS-BETWEEN-DROPPED')
	public function testAMacroClassReadsItsOwnCounts(): Void {
		Assert.equals(
			macroClass('\t\t\tvar a;\n\n\t\t\tvar b;\n\t\t\tfunction f() {}\n\t\t\tfunction g() {}'),
			write(
				macroClass('\t\t\tvar a;\n\t\t\tvar b;\n\t\t\tfunction f() {}\n\t\t\tfunction g() {}'),
				'"macroClassEmptyLines":{"betweenVars":1,"afterVars":0,"betweenFunctions":0}'
			)
		);
	}

	public function testTheClassSectionDoesNotMoveAMacroClass(): Void {
		Assert.equals(
			macroClass('\t\t\tvar a;\n\t\t\tvar b;\n\n\t\t\tfunction f() {}\n\n\t\t\tfunction g() {}'),
			write(
				macroClass('\t\t\tvar a;\n\t\t\tvar b;\n\t\t\tfunction f() {}\n\t\t\tfunction g() {}'),
				'"classEmptyLines":{"betweenVars":1,"afterVars":0,"betweenFunctions":0}'
			)
		);
	}

	public function testAMacroClassSubdividesStaticsOnItsOwnCounts(): Void {
		final src: String = macroClass('\t\t\tstatic var s;\n\t\t\tvar a;\n\t\t\tstatic function f() {}\n\t\t\tstatic function g() {}');
		Assert.equals(
			macroClass('\t\t\tstatic var s;\n\n\t\t\tvar a;\n\n\t\t\tstatic function f() {}\n\n\t\t\tstatic function g() {}'),
			write(src, '')
		);
		Assert.equals(
			macroClass('\t\t\tstatic var s;\n\t\t\tvar a;\n\n\t\t\tstatic function f() {}\n\t\t\tstatic function g() {}'),
			write(src, '"macroClassEmptyLines":{"afterStaticVars":0,"betweenStaticFunctions":0}')
		);
	}

	@:pin('control')
	@:killer('M-EXISTING-READS-CLASS-KNOB')
	public function testEachSectionStripsOnlyItsOwnSourceBlanks(): Void {
		for (kind in [
			{ head: 'interface I', section: 'interfaceEmptyLines' },
			{ head: 'extern class I', section: 'externClassEmptyLines' },
			{ head: 'enum abstract I(Int)', section: 'enumAbstractEmptyLines' },
			{ head: 'abstract I(Int)', section: 'abstractEmptyLines' }
		]) {
			final remove: String = '"${kind.section}":{"existingBetweenFields":"remove"}';
			Assert.equals('${kind.head} {\n\tvar a;\n\tvar b;\n}', write('${kind.head} {\n\tvar a;\n\n\tvar b;\n}', remove));
			final classBody: String = 'class I {\n\tvar a;\n\n\tvar b;\n}';
			Assert.equals(classBody, write(classBody, remove));
		}
	}

	public function testAMacroClassStripsOnItsOwnPolicy(): Void {
		Assert.equals(
			macroClass('\t\t\tvar a;\n\t\t\tvar b;'),
			write(macroClass('\t\t\tvar a;\n\n\t\t\tvar b;'), '"macroClassEmptyLines":{"existingBetweenFields":"remove"}')
		);
	}

	@:pin('control')
	@:killer('M-INTERFACE-EXISTING-DROPPED')
	public function testAnInterfaceStripsOnItsOwnPolicy(): Void {
		Assert.equals(
			'interface I {\n\tvar a;\n\tvar b;\n}',
			write('interface I {\n\tvar a;\n\n\tvar b;\n}', '"interfaceEmptyLines":{"existingBetweenFields":"remove"}')
		);
	}

	/** The blank of a split-led member sits inside its leading cluster: no body adds a second one above it for the doc comment. */
	@:pin('control')
	@:killer('M-SPLIT-LEAD-IGNORED')
	public function testASplitLeadGetsNoDocBlankInAnyBody(): Void {
		Assert.equals(
			'interface I {\n\tfunction a();\n$SPLIT_LEAD\tfunction b();\n}',
			write(
				'interface I {\n\tfunction a();\n\t/** d */\n\t// foo\n\t/** e */\n\tfunction b();\n}',
				'"afterFieldsWithDocComments":"ignore"'
			)
		);
		Assert.equals(
			'class C {\n\tfunction a() {}\n$SPLIT_LEAD\tfunction b() {}\n}',
			write(
				'class C {\n\tfunction a() {}\n\t/** d */\n\t// foo\n\t/** e */\n\tfunction b() {}\n}',
				'"afterFieldsWithDocComments":"ignore","classEmptyLines":{"betweenFunctions":0}'
			)
		);
	}

	public function testASplitLeadStillTakesTheOtherRulesOfItsGap(): Void {
		Assert.equals(
			'extern class C {\n\tfunction a();\n\n$SPLIT_LEAD\tfunction b();\n}',
			write(
				'extern class C {\n\tfunction a();\n\t/** d */\n\t// foo\n\t/** e */\n\tfunction b();\n}',
				'"externClassEmptyLines":{"betweenFunctions":1}'
			)
		);
		Assert.equals(
			'extern class C {\n\t/** c */\n\tfunction a();\n\n$SPLIT_LEAD\tfunction b();\n}',
			write('extern class C {\n\t/** c */\n\tfunction a();\n\t/** d */\n\t// foo\n\t/** e */\n\tfunction b();\n}', '')
		);
	}

	/** Both flags are set on this head: the enum-abstract one decides, since `HxAbstractDecl` names only it. */
	public function testAnExternEnumAbstractReadsTheEnumAbstractSection(): Void {
		final src: String = 'extern enum abstract E(Int) {\n\tvar a;\n\tvar b;\n\tfunction f();\n}';
		Assert.equals(
			'extern enum abstract E(Int) {\n\tvar a;\n\n\tvar b;\n\tfunction f();\n}',
			write(src, '"enumAbstractEmptyLines":{"betweenVars":1,"afterVars":0}')
		);
		Assert.equals(
			'extern enum abstract E(Int) {\n\tvar a;\n\tvar b;\n\n\tfunction f();\n}',
			write(src, '"abstractEmptyLines":{"betweenVars":1,"afterVars":0}')
		);
	}

	public function testAnEnumAbstractDoesNotSubdivideStaticVars(): Void {
		final src: String = 'enum abstract E(Int) {\n\tstatic var s;\n\tvar a;\n}';
		Assert.equals(src, write(src, ''));
	}

	private static function macroClass(members: String): String {
		return '$MACRO_OPEN$members$MACRO_CLOSE';
	}

	private static function write(src: String, sections: String): String {
		return HxWriteFixture.triviaWrite(src, '{"emptyLines":{$sections}}');
	}

}
