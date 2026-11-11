package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * `enumAbstractEmptyLines.abstractRulesUnlessValueList`: an `enum abstract` body holding a method, a property, a
 * `static` member or a line comment above a member lives by the `abstractEmptyLines` rules (edges, between members,
 * `existingBetweenFields`); a body of plain values, doc comments included, keeps the `enumAbstract*` ones. The config
 * packs an `enum abstract` and gives a plain abstract edge blanks and the default `keep`, so the two rule sets differ.
 */
@:nullSafety(Strict)
class HxEnumAbstractClassRulesTest extends Test {

	private static inline final OFF: String = '{"emptyLines":{'
		+ '"enumAbstractEmptyLines":{"beginType":0,"betweenVars":0,"existingBetweenFields":"remove"},'
		+ '"abstractEmptyLines":{"beginType":1,"endType":1}}}';
	private static inline final ON: String = '{"emptyLines":{'
		+ '"enumAbstractEmptyLines":{"beginType":0,"betweenVars":0,"existingBetweenFields":"remove","abstractRulesUnlessValueList":true},'
		+ '"abstractEmptyLines":{"beginType":1,"endType":1}}}';
	private static inline final MIXED: String = 'enum abstract Color(Int) {\n\tvar Red = 1;\n\tvar Green = 2;\n\n'
		+ '\tpublic var name(get, never):String;\n\n\tfunction get_name():String {\n\t\treturn 0;\n\t}\n}\n';
	private static inline final GROUPED: String = 'enum abstract Key(Int) {\n\t// arrows\n\tvar Left = 1;\n\tvar Right = 2;\n\n'
		+ '\t// letters\n\tvar A = 3;\n}\n';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-ENUM-ABSTRACT-RULES-KEY-UNREAD', 'M-MEMBER-BEYOND-VALUE-NEVER')
	public function testAMixedBodyLivesByTheAbstractRules(): Void {
		Assert.equals(
			'enum abstract Color(Int) {\n\n\tvar Red = 1;\n\tvar Green = 2;\n\n\tpublic var name(get, never):String;\n\n'
			+ '\tfunction get_name():String {\n\t\treturn 0;\n\t}\n\n}\n',
			write(MIXED, ON)
		);
	}

	@:pin('control')
	@:killer('M-ENUM-ABSTRACT-RULES-KEY-UNREAD', 'M-ABSTRACT-BODY-LINE-COMMENT-UNREAD')
	public function testLineCommentGroupsKeepTheirBlanks(): Void {
		Assert.equals(
			'enum abstract Key(Int) {\n\n\t// arrows\n\tvar Left = 1;\n\tvar Right = 2;\n\n\t// letters\n\tvar A = 3;\n\n}\n',
			write(GROUPED, ON)
		);
	}

	@:pin('control')
	@:killer('M-ENUM-ABSTRACT-RULES-KNOB-IGNORED')
	public function testAMixedBodyKeepsTheEnumAbstractRulesWithTheKeyOff(): Void {
		Assert.equals(
			'enum abstract Color(Int) {\n\tvar Red = 1;\n\tvar Green = 2;\n\tpublic var name(get, never):String;\n\n'
			+ '\tfunction get_name():String {\n\t\treturn 0;\n\t}\n}\n',
			write(MIXED, OFF)
		);
	}

	@:pin('control')
	@:killer('M-ENUM-ABSTRACT-RULES-KNOB-IGNORED')
	public function testLineCommentGroupsCloseUpWithTheKeyOff(): Void {
		Assert.equals(
			'enum abstract Key(Int) {\n\t// arrows\n\tvar Left = 1;\n\tvar Right = 2;\n\t// letters\n\tvar A = 3;\n}\n',
			write(GROUPED, OFF)
		);
	}

	@:pin('control')
	@:killer('M-ABSTRACT-BODY-BEYOND-VALUES-ALWAYS')
	public function testAPlainValueListKeepsTheEnumAbstractRules(): Void {
		Assert.equals(
			'enum abstract Plain(Int) {\n\tvar A = 1;\n\tvar B = 2;\n}\n',
			write('enum abstract Plain(Int) {\n\tvar A = 1;\n\n\tvar B = 2;\n}\n', ON)
		);
	}

	@:pin('control')
	@:killer('M-LINE-COMMENT-LED-ANY')
	public function testADocCommentIsNoTrigger(): Void {
		Assert.equals(
			'enum abstract Doc(Int) {\n\tvar A = 1;\n\n\t/** b */\n\tvar B = 2;\n}\n',
			write('enum abstract Doc(Int) {\n\tvar A = 1;\n\n\t/** b */\n\tvar B = 2;\n}\n', ON)
		);
	}

	@:pin('control')
	@:killer('M-MEMBER-PROPERTY-AS-VALUE')
	public function testAPropertyTriggers(): Void {
		Assert.equals(
			'enum abstract Prop(Int) {\n\n\tvar A = 1;\n\n\tvar b(get, never):Int;\n\n}\n',
			write('enum abstract Prop(Int) {\n\tvar A = 1;\n\n\tvar b(get, never):Int;\n}\n', ON)
		);
	}

	@:pin('control')
	@:killer('M-MEMBER-STATIC-AS-VALUE')
	public function testAStaticMemberTriggers(): Void {
		Assert.equals(
			'enum abstract Stat(Int) {\n\n\tvar A = 1;\n\n\tstatic var b = 2;\n\n}\n',
			write('enum abstract Stat(Int) {\n\tvar A = 1;\n\n\tstatic var b = 2;\n}\n', ON)
		);
	}

	@:pin('control')
	@:killer('M-MEMBER-METHOD-AS-VALUE')
	public function testAMethodTriggers(): Void {
		Assert.equals(
			'enum abstract Meth(Int) {\n\n\tvar A = 1;\n\n\tfunction f():Int {\n\t\treturn 0;\n\t}\n\n}\n',
			write('enum abstract Meth(Int) {\n\tvar A = 1;\n\n\tfunction f():Int {\n\t\treturn 0;\n\t}\n}\n', ON)
		);
	}

	@:pin('control')
	@:killer('M-ABSTRACT-BODY-TRAILING-COMMENT-READ')
	public function testATrailingLineCommentIsNoTrigger(): Void {
		Assert.equals(
			'enum abstract T(Int) {\n\tvar A = 1; // trailing\n\tvar B = 2;\n\tvar C = 3;\n}\n',
			write('enum abstract T(Int) {\n\tvar A = 1; // trailing\n\tvar B = 2;\n\n\tvar C = 3;\n}\n', ON)
		);
	}

	@:pin('control')
	@:killer('M-MEMBER-FINAL-AS-BEYOND-VALUE')
	public function testAFinalValueIsAValue(): Void {
		Assert.equals(
			'enum abstract T(Int) {\n\tvar A = 1;\n\tfinal B = 2;\n}\n',
			write('enum abstract T(Int) {\n\tvar A = 1;\n\n\tfinal B = 2;\n}\n', ON)
		);
	}

	private function write(src: String, json: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(json));
	}

}
