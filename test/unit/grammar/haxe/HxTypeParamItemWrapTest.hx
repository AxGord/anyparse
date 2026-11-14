package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * The `typeParamItemCount >= n` wrap condition: how many items of an anonymous type, a function's parameters or an enum
 * constructor's arguments declare a type carrying type parameters, read off each item's declared type.
 *
 * `CONFIG` gives `anonType` and `functionSignature` the same two rules — two such items, or four items with one — and a
 * `noWrap` default, so a list breaks exactly when the count reaches the rule.
 */
@:nullSafety(Strict)
final class HxTypeParamItemWrapTest extends Test {

	/** Two generic-typed items, or four items with one of them generic, put the list one item per line. */
	private static final RULES: String = '[{"conditions":[{"cond":"typeParamItemCount >= n","value":2}],"type":"onePerLine"},'
		+ '{"conditions":[{"cond":"itemCount >= n","value":4},{"cond":"typeParamItemCount >= n","value":1}],"type":"onePerLine"}]';

	private static final CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},'
		+ '"wrapping":{"maxLineLength":140,"anonType":{"defaultWrap":"noWrap","rules":$RULES'
		+ '},"functionSignature":{"defaultWrap":"noWrap","rules":$RULES}}}';

	/**
	 * Pairs beside an `Array<Int>` item: `Int->Void` and `Int` count zero; `Null<String>`, a nested `Map<K, V>`, an arrow's
	 * generic return or parameter, a `> Base<Int>` extension and a function field's generic return or parameter count one.
	 */
	private static final COUNT_SRC: String = 'class C {\n\tvar a0:{a:Array<Int>, b:Int->Void};\n\tvar a1:{a:Array<Int>, b:Null<String>};\n'
		+ '\tvar a2:{a:Array<Int>, b:{c:Map<K, V>}};\n\tvar b0:{a:Array<Int>, b:Int->Array<Int>};\n'
		+ '\tvar b1:{a:Array<Int>, b:(x:Array<Int>) -> Void};\n\tvar b2:{> Base<Int>, a:Array<Int>};\n\tvar b3:{var a:Array<Int>; function '
		+ 'f():Null<Int>;};\n\tvar b4:{var a:Array<Int>; function f(x:Map<K, V>):Void;};\n\tfunction f0(a:Array<Int>, b:Int->Void) {}\n'
		+ '\tfunction f1(a:Array<Int>, b:Null<String>) {}\n\tfunction f2(a:Array<Int>, b:{c:Map<K, V>}) {}\n}\n'
		+ 'enum E {\n\tC0(a:Array<Int>, b:Null<Int>);\n\tC1(a:Array<Int>, b:Int);\n}';

	private static final COUNT_OUT: String = 'class C {\n\tvar a0:{a:Array<Int>, b:Int->Void};\n\tvar a1:{\n\t\ta:Array<Int>,\n'
		+ '\t\tb:Null<String>\n\t};\n\tvar a2:{\n\t\ta:Array<Int>,\n\t\tb:{c:Map<K, V>}\n\t};\n'
		+ '\tvar b0:{\n\t\ta:Array<Int>,\n\t\tb:Int->Array<Int>\n\t};\n\tvar b1:{\n\t\ta:Array<Int>,\n'
		+ '\t\tb:(x:Array<Int>) -> Void\n\t};\n\tvar b2:{\n\t\t> Base<Int>,\n\t\ta:Array<Int>\n\t};\n'
		+ '\tvar b3:{\n\t\tvar a:Array<Int>;\n\t\tfunction f():Null<Int>;\n\t};\n\tvar b4:{\n'
		+ '\t\tvar a:Array<Int>;\n\t\tfunction f(x:Map<K, V>):Void;\n\t};\n\n'
		+ '\tfunction f0(a:Array<Int>, b:Int->Void) {}\n\n\tfunction f1(\n\t\ta:Array<Int>,\n'
		+ '\t\tb:Null<String>\n\t) {}\n\n\tfunction f2(\n\t\ta:Array<Int>,\n\t\tb:{c:Map<K, V>}\n\t) {}\n'
		+ '}\n\nenum E {\n\tC0(\n\t\ta:Array<Int>,\n\t\tb:Null<Int>\n\t);\n\tC1(a:Array<Int>, b:Int);\n}';

	/** Four and three items, with and without a generic one, in a field type, a signature and a typedef body. */
	private static final FOUR_SRC: String = 'class F {\n\tvar a4:{a:Array<Int>, b:String, c:Bool, d:Float};\n'
		+ '\tvar a5:{a:Int, b:String, c:Bool, d:Float};\n\tvar a6:{a:Array<Int>, b:String, c:Bool};\n'
		+ '\tfunction f3(a:Array<Int>, b:String, c:Bool, d:Float) {}\n\tfunction f4(a:Int, b:String, c:Bool, d:Float) {}\n}\n'
		+ 'typedef TD = {a:Array<Int>, b:String, c:Bool, d:Float};\ntypedef TE = {a:Int, b:String, c:Bool, d:Float};';

	private static final FOUR_OUT: String = 'class F {\n\tvar a4:{\n\t\ta:Array<Int>,\n\t\tb:String,\n\t\tc:Bool,\n\t\td:Float\n\t};\n'
		+ '\tvar a5:{a:Int, b:String, c:Bool, d:Float};\n\tvar a6:{a:Array<Int>, b:String, c:Bool};\n\n\tfunction f3(\n\t\ta:Array<Int>,\n'
		+ '\t\tb:String,\n\t\tc:Bool,\n\t\td:Float\n\t) {}\n\n\tfunction f4(a:Int, b:String, c:Bool, d:Float) {}\n}\n\ntypedef TD = {\n'
		+ '\ta:Array<Int>,\n\tb:String,\n\tc:Bool,\n\td:Float\n};\n\ntypedef TE = {a:Int, b:String, c:Bool, d:Float};';

	/** A default value is not a declared type: its `Array<Int>` check-type does not make a second generic item. */
	private static final DEFAULT_SRC: String = 'class D {\n\tfunction f6(a:Array<Int>, b = (null : Array<Int>)) {}\n}';

	public function new(): Void {
		super();
	}

	/** Each item counts by its own declared type, at any depth, in an anonymous type, a signature and an enum constructor. */
	@:pin('control')
	@:killer('M-TYPE-PARAM-NAMED-OFF')
	public function testItemsCountByTheirDeclaredType(): Void {
		Assert.equals(COUNT_OUT, write(COUNT_SRC));
		Assert.equals(COUNT_OUT, write(COUNT_OUT));
	}

	/** `itemCount >= 4` with `typeParamItemCount >= 1` breaks four items one of which is generic, and nothing narrower. */
	@:pin('control')
	@:killer('M-TYPE-PARAM-COND-OFF')
	public function testFourItemsWithAGenericOneBreak(): Void {
		Assert.equals(FOUR_OUT, write(FOUR_SRC));
		Assert.equals(FOUR_OUT, write(FOUR_OUT));
	}

	/** A parameter's default value is never read as its type. */
	@:pin('control')
	@:killer('M-TYPE-PARAM-DEFAULT-VALUE-READ')
	public function testDefaultValueIsNotADeclaredType(): Void {
		Assert.equals(DEFAULT_SRC, write(DEFAULT_SRC));
	}

	private inline function write(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
