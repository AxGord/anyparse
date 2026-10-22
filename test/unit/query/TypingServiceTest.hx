package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.DeclarationKey;
import anyparse.query.DeclarationQuery;
import anyparse.query.SymbolIndex;
import unit.CheckFixture;
import utest.Assert;
import utest.Test;

/**
 * The typing service's query cache (`TypingService`, `QueryCache`): an answer is remembered by the DECLARATION it is
 * about — its file and its offset there — so two declarations sharing a name never share an answer, and a remembered
 * answer, a `null` included, is the walk's own and is not asked for again.
 */
@:nullSafety(Strict)
class TypingServiceTest extends Test {

	@:pin('control') @:killer('M-TYPING-KEY-FILE')
	public function testNamesakesInTwoFilesKeepTheirOwnAnswers(): Void {
		final index: SymbolIndex = indexOf([
			'p/Base.hx' => 'package p;\n\nclass Base {\n\tpublic var m: Int = 0;\n}\n',
			'a/X.hx' => 'package a;\n\nclass X extends p.Base {}\n',
			'b/X.hx' => 'package b;\n\nclass X {}\n'
		]);
		final a: ResolvedType = declOf(index, 'a/X.hx', 0);
		final b: ResolvedType = declOf(index, 'b/X.hx', 0);
		Assert.equals(a.type.span.from, b.type.span.from, 'the two declarations sit at one offset of their files');
		Assert.isFalse(index.typing.members.declarationLacksMember(a, 'm'), 'a.X inherits m');
		Assert.isTrue(index.typing.members.declarationLacksMember(b, 'm'), 'b.X declares no m');
	}

	@:pin('control') @:killer('M-TYPING-KEY-OFFSET')
	public function testTwoTypesOfOneFileKeepTheirOwnAnswers(): Void {
		final index: SymbolIndex = indexOf([
			'p/Base.hx' => 'package p;\n\nclass Base {\n\tpublic var m: Int = 0;\n}\n',
			'q/X.hx' => 'package q;\n\nclass X extends p.Base {}\n\nclass Y {}\n'
		]);
		final inheriting: ResolvedType = declOf(index, 'q/X.hx', 0);
		final plain: ResolvedType = declOf(index, 'q/X.hx', 1);
		Assert.isFalse(index.typing.members.declarationLacksMember(inheriting, 'm'), 'X inherits m');
		Assert.isTrue(index.typing.members.declarationLacksMember(plain, 'm'), 'Y, beside it, declares none');
	}

	@:pin('control') @:killer('M-TYPING-TYPE-KEY-FILE')
	public function testATypeQuestionIsKeptPerDeclaration(): Void {
		final index: SymbolIndex = indexOf([
			'p/Ext.hx' => 'package p;\n\nclass Ext {\n\tpublic static function tag(y: Dynamic): Int return 0;\n}\n',
			'a/Y.hx' => 'package a;\n\n@:using(p.Ext)\nclass Y {}\n',
			'b/Y.hx' => 'package b;\n\n@:keeps(p.Ext)\nclass Y {}\n'
		]);
		final a: ResolvedType = declOf(index, 'a/Y.hx', 0);
		final b: ResolvedType = declOf(index, 'b/Y.hx', 0);
		Assert.equals(a.type.span.from, b.type.span.from, 'the two declarations sit at one offset of their files');
		Assert.isFalse(index.typing.members.declarationFreeOfExtensionTypes(a), 'a.Y brings p.Ext');
		Assert.isTrue(index.typing.members.declarationFreeOfExtensionTypes(b), 'b.Y brings none');
	}

	@:pin('control') @:killer('M-TYPING-ANSWER-FORGOTTEN')
	public function testARememberedNullIsNotAskedAgain(): Void {
		final index: SymbolIndex = indexOf(['p/A.hx' => 'package p;\n\nclass A {}\n']);
		final key: DeclarationKey = DeclarationKey.ofMember(declOf(index, 'p/A.hx', 0), 'gone');
		final query: DeclarationQuery<Null<String>> = new DeclarationQuery();
		var asked: Int = 0;
		function compute(): Null<String> {
			asked++;
			return null;
		}
		Assert.isNull(query.answer(key, compute));
		Assert.isNull(query.answer(key, compute));
		Assert.equals(1, asked, 'the second asking is answered from the table');
	}

	@:pin('control') @:killer('M-MEMBER-READ-BRANCHES-FIRST')
	public function testAReadOfAMemberItsBranchesWriteDifferentlyIsUnknown(): Void {
		final index: SymbolIndex = indexOf([
			'p/A.hx' => 'package p;\n\nclass A {\n\t#if js\n\tpublic var m: Int = 0;\n\t#else\n\tpublic var m: String = "";\n\t#end\n'
			+ '\tpublic var n: Int = 0;\n}\n'
		]);
		final a: ResolvedType = declOf(index, 'p/A.hx', 0);
		Assert.isNull(index.typing.members.memberRead(a, 'm', []), 'which branch a build compiles is not known');
		Assert.equals('Int', index.typing.members.memberRead(a, 'n', [])?.text, 'a member written once');
	}

	/** The `nth` type declaration of `file`, in the index's order. */
	private static function declOf(index: SymbolIndex, file: String, nth: Int): ResolvedType {
		final name: String = index.fileInfo(file)?.types[nth]?.name ?? '';
		final found: Null<ResolvedType> = index.refs.findDeclaredType(file, name);
		if (found == null) throw 'no declaration $nth in $file';
		return found;
	}

	private static function indexOf(files: Map<String, String>): SymbolIndex {
		final entries: Array<{ file: String, source: String }> = [for (file => source in files) { file: file, source: source }];
		entries.sort((a, b) -> Reflect.compare(a.file, b.file));
		return CheckFixture.index(entries, new HaxeQueryPlugin());
	}

}
