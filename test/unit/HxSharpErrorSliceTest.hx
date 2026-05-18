package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxConditionalDecl;
import anyparse.grammar.haxe.HxConditionalMember;
import anyparse.grammar.haxe.HxConditionalStmt;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxStatement;

/**
 * Slice ω-sharp-error: the `#error "msg"` / `#error 'msg'` preprocessor
 * directive at module-decl, class-member, and statement scope.
 *
 * Each of `HxDecl` / `HxClassMember` / `HxStatement` gained a
 * `@:kw('#error')` ctor (`ErrorDecl` / `ErrorMember` / `ErrorStmt`)
 * with a `HxErrorMsg` payload — a verbatim quoted-string capture
 * (clone of `HxPpCondLit`). In the haxe-formatter corpus `#error` only
 * appears as the body of a `#if … #end` guard for an unsupported
 * target (`other/sharp_error`, `indentation/issue_298_*`,
 * `lineends/issue_17`), reachable from each `HxConditional*.body`.
 *
 * Covers: the isolated ctor at all three scopes (single- and
 * double-quoted message, captured WITH quotes), the corpus
 * `other/sharp_error` module form, the `issue_298` multi-scope nested
 * form, the single-line `#if js #error "x" #elseif …` shape (the
 * quote-delimited regex must stop at the closing quote and NOT swallow
 * the trailing `#elseif`), idempotency, and the no-`#error` regression
 * (the new ctors must not perturb existing dispatch).
 */
class HxSharpErrorSliceTest extends HxTestHelpers {

	// -- Isolated ctor: module-decl scope, double-quoted, verbatim --

	public function testErrorDeclModuleScope():Void {
		final module:HxModule = HaxeModuleParser.parse('#error "please implement"');
		Assert.equals(1, module.decls.length);
		Assert.equals('"please implement"', (expectErrorDecl(module.decls[0].decl) : String));
	}

	// -- Isolated ctor: single-quoted message captured WITH quotes --

	public function testErrorDeclSingleQuoted():Void {
		final module:HxModule = HaxeModuleParser.parse("#error 'just a message'");
		Assert.equals(1, module.decls.length);
		Assert.equals("'just a message'", (expectErrorDecl(module.decls[0].decl) : String));
	}

	// -- Isolated ctor: class-member scope --

	public function testErrorMemberScope():Void {
		final cls:HxClassDecl = HaxeParser.parse('class C {\n\t#error "todo"\n}');
		Assert.equals(1, cls.members.length);
		Assert.equals('"todo"', (expectErrorMember(cls.members[0].member) : String));
	}

	// -- Isolated ctor: statement scope --

	public function testErrorStmtScope():Void {
		final cls:HxClassDecl = HaxeParser.parse('class C {\n\tfunction f():Void {\n\t\t#error "todo"\n\t}\n}');
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		Assert.equals('"todo"', (expectErrorStmt(stmts[0]) : String));
	}

	// -- Corpus `other/sharp_error`: `#if java #error #end` then a class --

	public function testSharpErrorCorpusModuleForm():Void {
		final module:HxModule = HaxeModuleParser.parse(
			'#if java\n#error "please implement"\n#end\nclass Main {\n\tpublic function new() {}\n}'
		);
		Assert.equals(2, module.decls.length);
		final cond:HxConditionalDecl = expectConditionalDecl(module.decls[0].decl);
		Assert.equals('java', (cond.cond : String));
		Assert.equals(1, cond.body.length);
		Assert.equals('"please implement"', (expectErrorDecl(cond.body[0].decl) : String));
		Assert.equals('Main', (expectClassDecl(module.decls[1]).name : String));
	}

	// -- Corpus `issue_298` shape: `#error` guarded at member + stmt scope --

	public function testSharpErrorCorpusMultiScope():Void {
		final cls:HxClassDecl = HaxeParser.parse(
			'class Main {\n#if cs\n#error \'msg\'\n#end\n\tpublic function new() {\n\t\t#if cs\n#error \'msg\'\n#end\n\t}\n}'
		);
		Assert.equals(2, cls.members.length);
		final memberCond:HxConditionalMember = expectConditionalMember(cls.members[0].member);
		Assert.equals('cs', (memberCond.cond : String));
		Assert.equals("'msg'", (expectErrorMember(memberCond.body[0].member) : String));
		final stmts:Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[1].member));
		final stmtCond:HxConditionalStmt = expectConditionalStmt(stmts[0]);
		Assert.equals('cs', (stmtCond.cond : String));
		Assert.equals("'msg'", (expectErrorStmt(stmtCond.body[0]) : String));
	}

	// -- Single-line: the quote-delimited regex must NOT eat `#elseif` --

	public function testSharpErrorSingleLineNoOverEat():Void {
		final module:HxModule = HaxeModuleParser.parse('#if js #error "js is defined" #elseif php #else #end');
		Assert.equals(1, module.decls.length);
		final cond:HxConditionalDecl = expectConditionalDecl(module.decls[0].decl);
		Assert.equals('js', (cond.cond : String));
		Assert.equals('"js is defined"', (expectErrorDecl(cond.body[0].decl) : String));
		Assert.equals(1, cond.elseifs.length);
		Assert.equals('php', (cond.elseifs[0].cond : String));
	}

	// -- Idempotency on the corpus module form --

	public function testSharpErrorRoundTrip():Void {
		roundTrip('#if java\n#error "please implement"\n#end\nclass Main {\n\tpublic function new() {}\n}');
	}

	// -- Regression: a module with no `#error` is unaffected --

	public function testNoSharpErrorRegression():Void {
		final module:HxModule = HaxeModuleParser.parse('class C {\n\tvar x:Int;\n}');
		Assert.equals(1, module.decls.length);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals('x', (expectVarMember(cls.members[0].member).name : String));
	}
}
