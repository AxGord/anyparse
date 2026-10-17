package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.runtime.ParseError;
import utest.Assert;
import utest.Test;

/**
 * A NAME slot — what a declaration binds — refuses every keyword Haxe reserves. Haxe's lexer turns a reserved word into
 * a keyword token, so `final dynamic = 1;`, `var default:Int;`, `function f(macro:Int)`, `catch (null:Dynamic)` and
 * the rest are syntax errors (`Unexpected keyword "dynamic"`, verified one by one on 4.3.7). The name terminals took any
 * identifier-shaped word except `var` / `final`, so an op that wrote such a name re-parsed clean and handed over a tree
 * the compiler rejects — the re-parse gate every op ends on cannot refuse what the parser accepts.
 *
 * The slots that DO take a keyword keep taking it: a property accessor (`(default, null)`, `(get, never)`, `dynamic`),
 * the constructor's name `new`, a field access (`haxe.macro.Context`), an interpolated `'$this'`. `super` is not
 * reserved — Haxe parses `final super = 1;` and only refuses its use as a value.
 */
@:nullSafety(Strict)
final class HxReservedNameSliceTest extends Test {

	/** Every word Haxe 4.3 reserves (its lexer's keyword table), each refused as a local's name on 4.3.7. */
	private static final RESERVED: Array<String> = [
		'abstract',
		'break',
		'case',
		'cast',
		'catch',
		'class',
		'continue',
		'default',
		'do',
		'dynamic',
		'else',
		'enum',
		'extends',
		'extern',
		'false',
		'final',
		'for',
		'function',
		'if',
		'implements',
		'import',
		'in',
		'inline',
		'interface',
		'macro',
		'new',
		'null',
		'operator',
		'overload',
		'override',
		'package',
		'private',
		'public',
		'return',
		'static',
		'switch',
		'this',
		'throw',
		'true',
		'try',
		'typedef',
		'untyped',
		'using',
		'var',
		'while'
	];

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-RESERVED-VAR-NAME')
	public function testAReservedWordIsNoLocalOrFieldName(): Void {
		for (k in RESERVED) {
			refused('class C { function f() { final $k = 1; } }', 'final local `$k`');
			refused('class C { function f() { var $k = 1; } }', 'var local `$k`');
			refused('class C { function f() { var a = 1, $k = 2; } }', 'multi-binding `$k`');
			refused('class C { var $k:Int; }', 'field `$k`');
			refused('class C { final $k:Int = 1; }', 'final field `$k`');
		}
	}

	@:pin('control')
	@:killer('M-RESERVED-IDENT-NAME') @:killer('M-RESERVED-FN-NAME')
	public function testAReservedWordIsNoFunctionParameterOrBinderName(): Void {
		for (k in RESERVED) {
			if (k != 'new') refused('class C { function $k() {} }', 'method `$k`');
			refused('class C { function f($k:Int) {} }', 'parameter `$k`');
			refused('class C { function f() { try {} catch ($k:Dynamic) {} } }', 'catch binder `$k`');
			if (!EXPRESSION_ATOMS.contains(k)) refused('class C { function f() { g(($k:Int) -> 1); } }', 'lambda parameter `$k`');
			refused('enum E { $k; }', 'enum constructor `$k`');
			refused('typedef T = { var $k:Int; }', 'structure field `$k`');
			refused('class C<$k> {}', 'type parameter `$k`');
		}
	}

	public function testTheSlotsThatTakeAKeywordStillDo(): Void {
		for (src in [
			'class C { var x(default, null):Int; }',
			'class C { var x(get, never):Int; var y(dynamic, dynamic):Int; }',
			'class C { public function new() {} }',
			'class C { function f() { final c = haxe.macro.Context.currentPos(); } }',
			"class C { function f() { trace('$this'); } }",
			'class C { function f() { final super = 1; final vararg = 2; final final_count = 3; final dynamicValue = 4; } }',
			'class C { function f() { for (i in 0...3) {} } }'
		]) Assert.isTrue(parses(src), src);
	}

	private static function refused(src: String, what: String): Void {
		Assert.isFalse(parses(src), 'Haxe refuses a $what: $src');
	}

	private static function parses(src: String): Bool {
		return try {
			HaxeModuleParser.parse(src);
			true;
		} catch (_: ParseError) false;
	}

	/**
	 * The reserved words that ARE expressions (`HxExprIdentLit` keeps them, `break` /
	 * `continue` / `return` as value-less atoms): `(null:Int) -> 1` parses as an arrow over the
	 * check-type expression `(null : Int)` rather than as a lambda, the arrow-expression fallback no name slot governs.
	 */
	private static final EXPRESSION_ATOMS: Array<String> = [
		'abstract',
		'break',
		'cast',
		'continue',
		'false',
		'function',
		'inline',
		'macro',
		'new',
		'null',
		'return',
		'this',
		'true',
		'untyped'
	];

}
