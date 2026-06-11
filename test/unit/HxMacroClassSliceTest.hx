package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxMacroClass;
import anyparse.grammar.haxe.HxMacroClassHead;
import anyparse.grammar.haxe.HxStatement;

/**
 * Slice ω-macro-class: `macro class` reification-as-expression —
 * `macro class [$name|Name]? { members }`.
 *
 * `HxExpr` gained a `@:kw('macro') MacroClassExpr(v:HxMacroClass)` ctor
 * declared BETWEEN `MacroTypeExpr` (`macro :`) and `MacroExpr`
 * (`macro <expr>`) so `macro class` is tried before the generic
 * operand form. `HxMacroClass` is `head + { members }`; the head is a
 * two-branch `HxMacroClassHead` enum (`NamedHead(HxMacroClassName)` /
 * `AnonHead`, both `@:kw('class')`, ParamCtor-then-SimpleCtor
 * declaration-order rollback — the `UntypedExpr`/`UntypedAtom`
 * precedent) which owns the always-consume-`class` / optional-name
 * disambiguation that a single `@:kw`+`@:optional` field cannot
 * express. `HxMacroClassName` is a `$`-optional ident terminal (clone
 * of `HxFieldNameLit`); `members` is the separator-less close-peek
 * `HxMemberDecl` Star, parse-identical to `HxClassDecl.members`.
 * `HxExprUtil.stmtExprNoSemi` gained a `MacroClassExpr` arm so a
 * bare-statement `macro class {}` needs no trailing `;`.
 *
 * Corpus drivers: `other/issue_33_macro_class_reification`,
 * `emptylines/issue_377_macro_classes`,
 * `emptylines/issue_384_macro_classes_with_metadata` (bare-statement
 * form — fully covered here). The `var x = macro class {}` no-`;`
 * forms (`other/issue_163`, `lineends/issue_565`) have a separate
 * downstream blocker (the VarStmt `@:trailOpt` gate keys on
 * `endsWithCloseBrace`, deliberately left unmodified for this slice)
 * and are an out-of-scope follow-up.
 *
 * Sources containing `$name` are DOUBLE-quoted: a single-quoted Haxe
 * string interpolates `$name` (the recurring Slice 4 fixture miss).
 */
class HxMacroClassSliceTest extends HxTestHelpers {

	// -- Isolated: anonymous head, single member fn --

	public function testMacroClassAnonIsolated(): Void {
		final cls: HxClassDecl = HaxeParser.parse(
			'class C {\n\tfunction f() {\n\t\tmacro class {\n\t\t\tpublic function new() {}\n\t\t}\n\t}\n}'
		);
		final stmts: Array<HxStatement> = fnBodyStmts(expectFnMember(cls.members[0].member));
		Assert.equals(1, stmts.length);
		final mc: HxMacroClass = expectMacroClassExpr(expectExprStmt(stmts[0]));
		Assert.isTrue(mc.head.match(AnonHead));
		Assert.equals(1, mc.members.length);
		Assert.equals('new', (expectFnMember(mc.members[0].member).name: String));
	}

	// -- Isolated: $name-reified head --

	public function testMacroClassDollarName(): Void {
		final cls: HxClassDecl = HaxeParser.parse(
			"class C {\n\tfunction f() {\n\t\tmacro class $name {\n\t\t\tpublic function new() {}\n\t\t}\n\t}\n}"
		);
		final mc: HxMacroClass = expectMacroClassExpr(expectExprStmt(fnBodyStmts(expectFnMember(cls.members[0].member))[0]));
		final name: String = switch mc.head {
			case NamedHead(n): (n: String);
			case AnonHead: throw 'expected NamedHead, got AnonHead';
		};
		Assert.equals("$name", name);
	}

	// -- Isolated: plain-identifier head (issue_565 2nd main: `class name`) --

	public function testMacroClassPlainName(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tmacro class Foo {\n\t\t\tvar x:Int;\n\t\t}\n\t}\n}');
		final mc: HxMacroClass = expectMacroClassExpr(expectExprStmt(fnBodyStmts(expectFnMember(cls.members[0].member))[0]));
		final name: String = switch mc.head {
			case NamedHead(n): (n: String);
			case AnonHead: throw 'expected NamedHead, got AnonHead';
		};
		Assert.equals('Foo', name);
		Assert.equals('x', (expectVarMember(mc.members[0].member).name: String));
	}

	// -- Isolated: empty body ($name, zero members) --

	public function testMacroClassEmptyBody(): Void {
		final cls: HxClassDecl = HaxeParser.parse("class C {\n\tfunction f() {\n\t\tmacro class $name {}\n\t}\n}");
		final mc: HxMacroClass = expectMacroClassExpr(expectExprStmt(fnBodyStmts(expectFnMember(cls.members[0].member))[0]));
		Assert.isFalse(mc.head.match(AnonHead));
		Assert.equals(0, mc.members.length);
	}

	// -- Corpus `emptylines/issue_377`: anon head, var + two fns --

	public function testMacroClassCorpusIssue377(): Void {
		final cls: HxClassDecl = HaxeParser.parse(
			'class Main {\n\tstatic function main() {\n\t\tmacro class {\n\t\t\tvar foo:Int;\n\t\t\tfunction bar() {\n\t\t\t\ttrace("bar");\n\t\t\t}\n\t\t\tfunction foobar() {\n\t\t\t\ttrace("foobar");\n\t\t\t}\n\t\t}\n\t}\n}'
		);
		final mc: HxMacroClass = expectMacroClassExpr(expectExprStmt(fnBodyStmts(expectFnMember(cls.members[0].member))[0]));
		Assert.isTrue(mc.head.match(AnonHead));
		Assert.equals(3, mc.members.length);
		Assert.equals('foo', (expectVarMember(mc.members[0].member).name: String));
		Assert.equals('bar', (expectFnMember(mc.members[1].member).name: String));
		Assert.equals('foobar', (expectFnMember(mc.members[2].member).name: String));
	}

	// -- Idempotency: verbatim `other/issue_33` source --

	public function testMacroClassCorpusIssue33RoundTrip(): Void {
		roundTrip('class Macro {\n\tstatic function foo() {\n\t\tmacro class {\n\t\t\tpublic function new() {}\n\t\t}\n\t}\n}');
	}

	// -- Idempotency: verbatim `emptylines/issue_377` source --

	public function testMacroClassCorpusIssue377RoundTrip(): Void {
		roundTrip(
			'class Main {\n\tstatic function main() {\n\t\tmacro class {\n\t\t\tvar foo:Int;\n\t\t\tfunction bar() {\n\t\t\t\ttrace("bar");\n\t\t\t}\n\t\t\tfunction foobar() {\n\t\t\t\ttrace("foobar");\n\t\t\t}\n\t\t}\n\t}\n}'
		);
	}

	// -- Regression: plain `macro <expr>` (MacroExpr) still parses --

	public function testNoMacroExprRegression(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tfunction f() {\n\t\tmacro foo();\n\t}\n}');
		final e: HxExpr = expectExprStmt(fnBodyStmts(expectFnMember(cls.members[0].member))[0]);
		Assert.isTrue(e.match(MacroExpr(_)));
	}

	// -- Regression: a plain class member is unaffected --

	public function testNoMacroClassRegression(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tvar x:Int;\n}');
		Assert.equals('x', (expectVarMember(cls.members[0].member).name: String));
	}

}
