package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxEnumCtor;
import anyparse.grammar.haxe.HxEnumDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxMacroClass;
import anyparse.grammar.haxe.HxStatement;
import haxe.Exception;
import utest.Assert;

/**
 * Constructs valid Haxe that library sources on a dependency classpath spell and the parser used to refuse, each of
 * which turned the whole file into a skip-parse: a GADT enum constructor, a `macro class` with a heritage clause and
 * a reified method name, a statement ending with an object literal and no `;`, a token-splice region holding a
 * region two levels deep, and a region every branch of which opens one `(` the shared tail closes.
 */
@:nullSafety(Strict)
class HxLibraryParseCoverageSliceTest extends HxTestHelpers {

	/** `Flowing:Status<Q>;` / `Errored(e:Error):Status<Error>;` — the constructor's GADT result type is kept. */
	public function testGadtEnumConstructorsKeepTheirResultType(): Void {
		final src: String = 'enum Status<Q> {\n\tFlowing:Status<Q>;\n\tErrored(e:String):Status<Int>;\n\tEnded;\n}\n';
		final ed: HxEnumDecl = expectEnumDecl(HaxeModuleParser.parse(src).decls[0]);
		final ctors: Array<HxEnumCtor> = enumCtors(ed);
		Assert.equals(3, ctors.length);
		switch ctors[0] {
			case SimpleCtor(decl):
				Assert.equals('Flowing', (decl.name: String));
				Assert.equals('Status', (expectNamedType(decl.returnType).name: String));
			case _:
				Assert.fail('expected SimpleCtor, got ${ctors[0]}');
		}
		Assert.equals('Status', (expectNamedType(expectParamCtor(ctors[1]).returnType).name: String));
		switch ctors[2] {
			case SimpleCtor(decl):
				Assert.isNull(decl.returnType, 'a plain constructor carries no result type');
			case _:
				Assert.fail('expected SimpleCtor, got ${ctors[2]}');
		}
		writerEquals(src, src);
	}

	/** `macro class $name extends Base<$ct> implements I { … }` binds both clauses and the members after them. */
	public function testMacroClassHeritageClauses(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tvar d = macro class $$n extends a.Base<$$ct> implements I {\n'
			+ '\t\t\tpublic function new() {}\n\t\t};\n\t}\n}';
		final mc: HxMacroClass = expectMacroClassExpr(varInit(src));
		Assert.equals(2, mc.heritage.length, 'extends and implements clauses');
		Assert.equals(1, mc.members.length, 'the member after the heritage clauses');
		triviaEquals(src);
	}

	/** `function $name()` inside a `macro class` reifies the method name, the twin of `var $name`. */
	public function testMacroClassReifiedMethodName(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tvar d = macro class {\n\t\t\toverride function $$func()\n'
			+ '\t\t\t\treturn $$e;\n\t\t};\n\t}\n}';
		final mc: HxMacroClass = expectMacroClassExpr(varInit(src));
		Assert.equals('$$func', (expectFnMember(mc.members[0].member).name: String));
		triviaEquals(src);
	}

	/**
	 * `x = {a: 1}` ends with `}`, the token the compiler lets stand in for a statement's `;`, so the next statement
	 * starts right after it. `x = [1]` does not end with `}` and still needs its `;`.
	 */
	public function testObjectLiteralAssignmentNeedsNoSemicolon(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tcache[name] = {a: 1}\n\t\tvar exists = 1;\n\t}\n}';
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(HaxeParser.parse(src).members[0].member));
		Assert.equals(2, stmts.length, 'the assignment and the declaration after it');
		switch expectExprStmt(stmts[0]) {
			case Assign(_, ObjectLit(_)):
				Assert.pass();
			case other:
				Assert.fail('expected Assign(_, ObjectLit), got $other');
		}
		triviaEquals(src);
		Assert.raises(() -> HaxeParser.parse('class C { function f() { x = [1] y = 2; } }'), Exception);
	}

	/**
	 * A dangling-else if-head region whose then-branch holds a region that holds another one: the raw capture must
	 * end at the OUTER `#end`, not at the first unmatched-looking one inside, so the shared else-block still follows.
	 */
	public function testSpliceRegionHoldsARegionTwoLevelsDeep(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\t#if a\n\t\tif (x) {\n\t\t\tl(function() {\n\t\t\t\t#if b\n'
			+ '\t\t\t\tuntyped #if haxe4 js.Syntax.code #else __js__ #end ("e")("x");\n\t\t\t\t#end\n\t\t\t});\n\t\t\treturn 1;\n'
			+ '\t\t}\n\t\telse\n\t\t#end\n\t\t{\n\t\t\treturn null;\n\t\t}\n\t}\n}\n';
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(HaxeParser.parse(src).members[0].member));
		Assert.equals(1, stmts.length, 'one splice statement carrying the shared else-block');
		roundTrip(src);
	}

	/**
	 * `#if haxe4 TNamed(a.name, #else ( #end toComplexType(a.t))` — every branch opens one `(` that the shared tail
	 * closes. A region whose branches open none is not this shape and stays `CondSpliceExpr`.
	 */
	public function testCallOpeningSpliceRegion(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tvar t = #if haxe4 TNamed(a.name, #else ( #end toComplexType(a.t));\n\t}\n}\n';
		switch varInit(src) {
			case CondSpliceCallOpenExpr(inner):
				switch inner.tail {
					case Call(IdentExpr(name), _): Assert.equals('toComplexType', (name: String));
					case other: Assert.fail('expected the shared call as the tail, got $other');
				}
			case other:
				Assert.fail('expected CondSpliceCallOpenExpr, got $other');
		}
		writerEquals(src, src);
		switch varInit('class C { function f() { var a = #if c b + #else d + #end e; } }') {
			case CondSpliceCallOpenExpr(_):
				Assert.fail('a region opening no parenthesis is not a call-opening splice');
			case _:
				Assert.pass();
		}
	}

	/**
	 * `enabled = #if cffi false; #else true; #end` — every branch ends the assignment with its own `;` and an `#else` is
	 * present, so the statement ends at the `#end` in every configuration. The branches are statements with nodes, and
	 * the text after the `#end` is a statement of its own whatever it starts with — a `(`, a `-`, a `[` would otherwise
	 * continue the expression.
	 */
	public function testSemicolonBranchRegionEndsTheAssignment(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tenabled = #if d false; #else true; #end\n\t\t(foo)();\n'
			+ '\t\tx = #if d 1; #else 2; #end\n\t\t-y;\n\t\tz = #if d 1; #elseif e 2; #else 3; #end\n\t\t[1].map(g);\n\t}\n}';
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(HaxeParser.parse(src).members[0].member));
		Assert.equals(6, stmts.length, 'three assignments, each followed by a statement of its own');
		for (i in [0, 2, 4]) switch stmts[i] {
			case CondSemiAssignStmt(_):
				Assert.pass();
			case other:
				Assert.fail('expected CondSemiAssignStmt at $i, got $other');
		}
		triviaEquals(src);
	}

	/** A hand-laid region keeps its lines and the comments after its branches. */
	public function testSemicolonBranchRegionKeepsItsLayout(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tthis.a[0] = #if d\n\t\tfalse; // off\n\t\t#elseif e\n\t\tmaybe();\n'
			+ '\t\t#else\n\t\ttrue; /* on */\n\t\t#end\n\t\t-y;\n\t}\n}';
		switch fnBodyStmts(expectFnMember(HaxeParser.parse(src).members[0].member))[0] {
			case CondSemiAssignStmt(_):
				Assert.pass();
			case other:
				Assert.fail('expected CondSemiAssignStmt, got $other');
		}
		triviaEquals(src);
	}

	/**
	 * Without an `#else` a configuration taking no branch reads the text after the `#end` as the value
	 * (`x = compute();`): the region is not self-terminating, and the statement keeps the splice reading.
	 */
	public function testSemicolonBranchRegionWithoutElseIsNoStatementEnd(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tx = #if a 1; #end compute();\n\t}\n}';
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(HaxeParser.parse(src).members[0].member));
		Assert.equals(1, stmts.length);
		switch expectExprStmt(stmts[0]) {
			case Assign(_, CondSpliceExpr(_)):
				Assert.pass();
			case other:
				Assert.fail('expected Assign(_, CondSpliceExpr), got $other');
		}
		triviaEquals(src);
		// bare branch values put the terminator after the `#end`: a value region, the statement's own `;` after it
		final bare: String = 'class C {\n\tfunction f() {\n\t\tx = #if a 1 #else 2 #end;\n\t\ty = 3;\n\t}\n}';
		switch expectExprStmt(fnBodyStmts(expectFnMember(HaxeParser.parse(bare).members[0].member))[0]) {
			case Assign(_, ConditionalExpr(_)):
				Assert.pass();
			case other:
				Assert.fail('expected Assign(_, ConditionalExpr), got $other');
		}
		triviaEquals(bare);
	}

	/**
	 * A parameter list that closes inside a `#if` region, each branch with its own `)` and return type: the member
	 * parses as `CondSigFnMember` with its name and body as nodes, and the member after it is still its own.
	 */
	public function testSignatureClosedInsideARegion(): Void {
		final src: String = 'class C {\n\tprivate function f(key:String, get:#if js Void->Array<Float>):Array<Float> #else '
			+ 'Layout):Array<Pos> #end {\n\t\treturn null;\n\t}\n\n\tfunction g() {}\n}';
		final ast: HxClassDecl = HaxeParser.parse(src);
		Assert.equals(2, ast.members.length);
		switch ast.members[0].member {
			case CondSigFnMember(decl):
				Assert.equals('f', (decl.name: String));
			case other:
				Assert.fail('expected CondSigFnMember, got $other');
		}
		Assert.equals('g', (expectFnMember(ast.members[1].member).name: String));
		triviaEquals(src);
	}

	/** The initializer of the first local declared in the first member's body. */
	private function varInit(src: String): HxExpr {
		final ast: HxClassDecl = HaxeParser.parse(src);
		final init: Null<HxExpr> = switch fnBodyStmts(expectFnMember(ast.members[0].member))[0] {
			case VarStmt(decl): decl.init;
			case other: throw 'expected VarStmt, got $other';
		};
		if (init == null) throw 'expected an initializer';
		return init;
	}

	/** Byte-exact trivia round-trip under the writer defaults: the source keeps its own `;` choices. */
	private function triviaEquals(source: String): Void {
		Assert.equals(source, HxWriteFixture.triviaWrite(source, '{}'));
	}

}
