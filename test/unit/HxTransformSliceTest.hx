package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxModuleAst;
import anyparse.grammar.haxe.HxIdentLit;
import anyparse.grammar.haxe.HxIntLit;
import anyparse.grammar.haxe.HxExprIdentLit;

/**
 * Coverage for the macro-generated DEEP multi-type transform over the
 * Plain `HxModule` AST (`Build.buildTransform` generalized to the whole
 * Haxe grammar forest).
 *
 * The macro emits `HxModuleAst.transform(root, visit)` plus an
 * `HxModuleTransform` hook typedef carrying one optional `T -> T` hook
 * per grammar type (`hxExpr`, `hxStatement`, `hxIdentLit`, ...). The
 * walk is bottom-up over every grammar-typed child, so:
 *
 *  - IDENTITY: `transform(ast, {})` rebuilds the entire tree structurally
 *    unchanged — verified by re-writing both the input AST and the
 *    transformed AST through `HxModuleWriter` and asserting byte-equal,
 *    across class + method + expression + control-flow shapes.
 *  - FUNCTIONAL: a `visit` with ONE hook (rename identifiers, or double
 *    integer literals) rewrites every node of that type at any depth and
 *    leaves all other nodes untouched — verified through the writer
 *    output.
 */
@:nullSafety(Strict)
class HxTransformSliceTest extends Test {

	public function new(): Void {
		super();
	}

	// ---------------- identity ----------------

	public function testIdentityPreservesStructure(): Void {
		// One snippet exercising class + var + method + expressions +
		// control-flow (if / for / while / switch / try) + literals +
		// operators, so the identity walk touches the recursive
		// HxExpr/HxStatement/HxType cycle end-to-end.
		final src: String = 'class C {\n' + '\tvar n:Int = 21;\n' + '\tpublic function run(items:Array<Int>):Int {\n'
			+ '\t\tvar total = 0;\n' + '\t\tfor (i in items) {\n' + '\t\t\tif (i > 0) total += i;\n' + '\t\t\telse total -= i;\n'
			+ '\t\t}\n' + '\t\twhile (total > 100) total = total - 10;\n' + '\t\tvar label = switch (total) {\n' + '\t\t\tcase 0: "zero";\n'
			+ '\t\t\tcase _: "many";\n' + '\t\t}\n' + '\t\ttry {\n' + '\t\t\treturn total;\n' + '\t\t} catch (e:Dynamic) {\n'
			+ '\t\t\treturn -1;\n' + '\t\t}\n' + '\t}\n' + '}';
		assertIdentity(src);
	}

	public function testIdentityEmptyModule(): Void {
		assertIdentity('');
	}

	public function testIdentitySmallShapes(): Void {
		assertIdentity('class Foo {}');
		assertIdentity('class Foo { var x:Int = 42; }');
		assertIdentity('class Foo { function bar(x:Int, y:Float):Void {} }');
		assertIdentity('typedef Point = { x:Int, y:Int }');
		assertIdentity('enum Color { Red; Green; Blue; }');
	}

	// ---------------- functional: rename identifiers ----------------

	public function testRenameIdentifierRewritesEveryOccurrence(): Void {
		final src: String = 'class C { function f() { return foo + keep + foo; } }';
		final ast: HxModule = HaxeModuleParser.parse(src);
		final out: String = HxModuleWriter.write(HxModuleAst.transform(ast, {
			hxIdentLit: renameFooToBar,
			hxExprIdentLit: renameExprFooToBar,
		}));
		// Every `foo` identifier became `bar`; `keep` is untouched.
		Assert.isTrue(out.indexOf('foo') == -1, 'a `foo` survived the rename in: <$out>');
		Assert.isTrue(out.indexOf('bar') != -1, 'no `bar` produced by the rename in: <$out>');
		Assert.isTrue(out.indexOf('keep') != -1, 'unrelated `keep` identifier was lost in: <$out>');
	}

	public function testRenameIdentityWhenNoMatch(): Void {
		// A rename hook that matches nothing is a structural identity.
		final src: String = 'class C { function f() { return a + b; } }';
		final ast: HxModule = HaxeModuleParser.parse(src);
		final renamed: String = HxModuleWriter.write(HxModuleAst.transform(ast, {
			hxIdentLit: renameFooToBar,
		}));
		final plain: String = HxModuleWriter.write(HaxeModuleParser.parse(src));
		Assert.equals(plain, renamed, 'non-matching rename hook changed output');
	}

	/** Rename the identifier `foo` to `bar`; pass everything else through. */
	private static function renameFooToBar(id: HxIdentLit): HxIdentLit {
		return (id: String) == 'foo' ? ('bar': HxIdentLit) : id;
	}

	private static function renameExprFooToBar(id: HxExprIdentLit): HxExprIdentLit {
		return (id: String) == 'foo' ? ('bar': HxExprIdentLit) : id;
	}

	// ---------------- functional: double integer literals ----------------

	public function testDoubleIntLiteralsRewritesEveryOccurrence(): Void {
		final src: String = 'class C { var a:Int = 21; var b:Int = 50; }';
		final ast: HxModule = HaxeModuleParser.parse(src);
		final out: String = HxModuleWriter.write(HxModuleAst.transform(ast, {
			hxIntLit: doubleInt,
		}));
		// 21 -> 42, 50 -> 100. The `Int` type names are HxTypeName, not
		// HxIntLit, so they are untouched.
		Assert.isTrue(out.indexOf('= 42;') != -1, 'first int literal not doubled in: <$out>');
		Assert.isTrue(out.indexOf('= 100;') != -1, 'second int literal not doubled in: <$out>');
		Assert.isTrue(out.indexOf('21') == -1, 'original int literal `21` survived in: <$out>');
		Assert.isTrue(out.indexOf('Int') != -1, 'type name `Int` was wrongly rewritten in: <$out>');
	}

	/** Double an integer literal's numeric value (verbatim string form). */
	private static function doubleInt(lit: HxIntLit): HxIntLit {
		final n: Null<Int> = Std.parseInt((lit: String));
		return n == null ? lit : (('' + (n * 2)): HxIntLit);
	}

	// ---------------- helpers ----------------

	/**
	 * Assert `transform(parse(src), {})` is a structural identity: both
	 * the parsed AST and the transformed AST write byte-identically. This
	 * compares through the existing writer (the project's canonical
	 * structural-equality surface for `HxModule`).
	 */
	private function assertIdentity(src: String): Void {
		final ast: HxModule = HaxeModuleParser.parse(src);
		final expected: String = HxModuleWriter.write(ast);
		final transformed: HxModule = HxModuleAst.transform(ast, {});
		final actual: String = HxModuleWriter.write(transformed);
		Assert.equals(expected, actual, 'identity transform changed the written form of: <$src>');
	}

}
