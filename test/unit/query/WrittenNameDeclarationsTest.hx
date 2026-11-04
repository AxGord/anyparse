package unit.query;

import anyparse.query.CallReturns;
import anyparse.query.QueryNode;
import anyparse.query.StdResolver;
import anyparse.query.SupertypeWalk;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeRefIndex;
import unit.CheckFixture;

/**
 * What a written type name MAY denote (`TypeRefIndex.mayDenote`) and the census beside it (`declaresName`): what the file
 * binds the name to; else every declaration of its simple name — the side a veto and an every-copy-agrees walk read, and
 * the side each of their sites keeps.
 */
@:nullSafety(Strict)
class WrittenNameDeclarationsTest extends Test {

	/** Two packages' `Base`, a file importing one, a file naming it bare, a file naming it by a path nothing holds. */
	private static final BASES: Array<{ file: String, source: String }> = [
		{ file: 'p/Base.hx', source: 'package p;\n\nclass Base {}\n' },
		{ file: 'q/Base.hx', source: 'package q;\n\nclass Base {}\n' },
		{ file: 'r/Imported.hx', source: 'package r;\n\nimport p.Base;\n\nclass Imported extends Base {}\n' },
		{ file: 'r/Free.hx', source: 'package r;\n\nclass Free extends Base {}\n' },
		{ file: 'r/Far.hx', source: 'package r;\n\nclass Far extends x.y.Base {}\n' },
		{ file: 'r/Generic.hx', source: 'package r;\n\nclass Generic extends Base<Int> {}\n' }
	];

	private static final BOTH: String = 'p/Base.hx,q/Base.hx';

	/** Two copies of one module, another package's namesake, and a file importing the module. */
	private static final COPIES: Array<{ file: String, source: String }> = [
		{ file: 'a/s/Dup.hx', source: 'package s;\n\nclass Dup {}\n' },
		{ file: 'b/s/Dup.hx', source: 'package s;\n\nclass Dup {}\n' },
		{ file: 't/Dup.hx', source: 'package t;\n\nclass Dup {}\n' },
		{ file: 'r/User.hx', source: 'package r;\n\nimport s.Dup;\n\nclass User extends Dup {}\n' }
	];

	/** A reader in one package, an abstract its file does not import in another. */
	private static final READER: String = 'package a;\n\nclass C {\n\tfunction f(u: U) {\n\t\tu[0];\n\t\tu + u;\n\t}\n}\n';

	private static final ABSTRACT: String = 'package b;\n\nabstract U(Int) from Int to Int {\n'
		+ '\t@:op(A + B) static function add(a: U, b: U): U return a;\n\n\t@:arrayAccess function get(i: Int): String return "";\n}\n';
	private static final TWINS: Array<{ file: String, source: String }> = [
		{ file: 't/T.hx', source: 'package t;\n\n#if a\nclass T {}\n#else\nclass T {}\n#end\n' }
	];

	@:pin('control') @:killer('M-MAY-DENOTE-NEVER-BOUND')
	public function testANameItsFileBindsMeansThatDeclarationAlone(): Void {
		Assert.equals('p/Base.hx', denoted('Base', 'r/Imported.hx'), 'the import, not the other package\'s namesake');
		Assert.equals('p/Base.hx', denoted('p.Base', 'r/Free.hx'), 'the path it writes');
	}

	@:pin('control') @:killer('M-MAY-DENOTE-NO-WIDENING')
	public function testANameItsFileBindsToNothingMayMeanEveryDeclaration(): Void {
		Assert.equals(BOTH, denoted('Base', 'r/Free.hx'), 'a bare name nothing in the file binds');
		Assert.equals(BOTH, denoted('Base', null), 'no file to read it in');
		Assert.equals('', denoted('Missing', 'r/Free.hx'), 'a name no declaration carries');
	}

	@:pin('control') @:killer('M-MAY-DENOTE-WHOLE-SPELLING')
	public function testAPathNothingHoldsWidensByItsSimpleName(): Void {
		Assert.equals(BOTH, denoted('x.y.Base', 'r/Free.hx'));
	}

	@:pin('control') @:killer('M-MAY-DENOTE-ONE-BOUND-ONLY')
	public function testTwoCopiesTheFileBindsAreThoseTwoNeverAnotherPackagesNamesake(): Void {
		final index: SymbolIndex = indexOf(COPIES);
		Assert.equals('a/s/Dup.hx,b/s/Dup.hx', filesOf(index.refs.mayDenote('Dup', index.fileInfo('r/User.hx'))));
	}

	@:pin('control') @:killer('M-HOPS-NO-WIDENING')
	public function testASupertypeLinkNothingResolvesWidensForTheVeto(): Void {
		final index: SymbolIndex = indexOf(BASES);
		Assert.equals('p/Base.hx', hopsOf(index, 'r/Imported.hx', 'Imported'), 'a resolved link');
		Assert.equals(BOTH, hopsOf(index, 'r/Free.hx', 'Free'), 'an unresolved bare link');
		Assert.equals(BOTH, hopsOf(index, 'r/Far.hx', 'Far'), 'an unresolved qualified link');
		Assert.equals(BOTH, hopsOf(index, 'r/Generic.hx', 'Generic'), 'a link with type arguments');
	}

	@:pin('control') @:killer('M-VERDICT-UNDECLARED-MAYBE', 'M-VERDICT-DECLARED-FALSE')
	public function testASubtypeStartReadsTheCensusOfItsName(): Void {
		final index: SymbolIndex = indexOf(BASES);
		Assert.equals(false, SupertypeWalk.verdict(index.refs, 'Missing', 'Free'), 'a name no declaration carries');
		Assert.isNull(SupertypeWalk.verdict(index.refs, 'Base', 'Free'), 'a name two declarations carry');
	}

	@:pin('control') @:killer('M-WRITTEN-DECL-NO-WIDENING')
	public function testAWrittenDeclarationIsTheOneBoundElseEveryOne(): Void {
		final index: SymbolIndex = indexOf(BASES);
		final at: QueryNode = new HaxeQueryPlugin().parseFile(BASES[0].source);
		Assert.equals('p/Base.hx', filesOf(CallReturns.writtenDeclaration('Base', at, index, 'r/Imported.hx')), 'the import');
		Assert.equals(BOTH, filesOf(CallReturns.writtenDeclaration('Base', at, index, 'r/Free.hx')), 'unbound in the file');
		Assert.equals(BOTH, filesOf(CallReturns.writtenDeclaration('Base', at, index, 'absent.hx')), 'no such file');
	}

	@:pin('control') @:killer('M-WRITTEN-DECL-TWO-COPIES-WIDEN')
	public function testAWrittenDeclarationOfTwoBoundCopiesIsThoseTwo(): Void {
		final index: SymbolIndex = indexOf(COPIES);
		final at: QueryNode = new HaxeQueryPlugin().parseFile(COPIES[0].source);
		Assert.equals('a/s/Dup.hx,b/s/Dup.hx', filesOf(CallReturns.writtenDeclaration('Dup', at, index, 'r/User.hx')));
	}

	@:pin('control') @:killer('M-INDEX-ELEMENT-NO-WIDENING')
	public function testAnElementReadOfATypeTheFileDoesNotBindReadsItsDeclaration(): Void {
		Assert.equals('String', typed('IndexAccess', 'u[0]'));
	}

	@:pin('control') @:killer('M-OPERAND-END-NO-WIDENING')
	public function testAnOperandOfATypeTheFileDoesNotBindReadsItsOneDeclaration(): Void {
		Assert.equals('U', typed('Add', 'u + u'));
	}

	@:pin('control') @:killer('M-DECLARES-NAME-FALSE', 'M-DECLARES-NAME-TRUE')
	public function testTheCensusAsksTheWholeIndexAndNoFile(): Void {
		final index: SymbolIndex = indexOf(BASES);
		Assert.isTrue(index.refs.declaresName('Base'));
		Assert.isFalse(index.refs.declaresName('Missing'));
	}

	@:pin('control') @:killer('M-DECLARED-OUTSIDE-STD-FALSE', 'M-DECLARED-OUTSIDE-STD-TRUE')
	public function testOnlyAFileOutsideTheStdShadowsAName(): Void {
		final std: Null<String> = StdResolver.stdDir();
		if (std == null) {
			Assert.pass();
			return;
		}
		final index: SymbolIndex = indexOf([
			{ file: haxe.io.Path.join([std, 'ZzProbe.hx']), source: 'class ZzOnlyStd {}\n\nclass ZzBoth {}\n' },
			{ file: 'p/ZzProject.hx', source: 'package p;\n\nclass ZzOnlyProject {}\n\nclass ZzBoth {}\n' }
		]);
		Assert.isFalse(index.refs.declaredOutsideStd('ZzOnlyStd'), 'only the std declares it');
		Assert.isTrue(index.refs.declaredOutsideStd('ZzOnlyProject'), 'a project file declares it');
		Assert.isTrue(index.refs.declaredOutsideStd('ZzBoth'), 'both declare it');
		Assert.isFalse(index.refs.declaredOutsideStd('ZzMissing'), 'nothing declares it');
	}

	@:pin('control') @:killer('M-MEMBER-IMPORT-NONE')
	public function testAMemberImportIsNamedByItsStatement(): Void {
		final index: SymbolIndex = indexOf([
			{ file: 'p/Base.hx', source: 'package p;\n\nclass Base {\n\tpublic static function make() {}\n}\n' },
			{ file: 'r/User.hx', source: 'package r;\n\nimport p.Base.make;\nimport p.Base;\n\nclass User {}\n' }
		]);
		final user: Null<FileInfo> = index.fileInfo('r/User.hx');
		if (user == null) throw 'no r/User.hx';
		Assert.equals('p.Base.make', TypeRefIndex.memberImportOf(user, 'Base', ['other', 'make']));
		Assert.isNull(TypeRefIndex.memberImportOf(user, 'Base', ['other']), 'another member');
		Assert.isNull(TypeRefIndex.memberImportOf(user, 'Other', ['make']), 'another type');
	}

	@:pin('control') @:killer('M-MAY-ANSWER-WIDENS-A-PATH')
	public function testAnElementReadOfAPathNothingHoldsAnswersNothing(): Void {
		Assert.isNull(typedAs('x.U', 'IndexAccess', 'u[0]'));
	}

	@:pin('control') @:killer('M-MAY-ANSWER-WIDENS-A-PATH')
	public function testAnOperandOfAPathNothingHoldsAnswersNothing(): Void {
		Assert.isNull(typedAs('x.U', 'Add', 'u + u'));
	}

	@:pin('control') @:killer('M-MAY-ANSWER-NEVER-BOUND')
	public function testAPathTheIndexHoldsStillAnswers(): Void {
		Assert.equals('String', typedAs('b.U', 'IndexAccess', 'u[0]'));
		Assert.equals('U', typedAs('b.U', 'Add', 'u + u'));
	}

	@:pin('control') @:killer('M-ONLY-DECLARATION-FIRST', 'M-ONLY-DECLARATION-NONE')
	public function testAnOnlyDeclarationIsTheOneOfItsName(): Void {
		final index: SymbolIndex = indexOf(BASES);
		Assert.equals('r/Free.hx', index.refs.onlyDeclaration('Free')?.file.file);
		Assert.isNull(index.refs.onlyDeclaration('Base'));
		Assert.isNull(index.refs.onlyDeclaration('Missing'));
		Assert.equals('t/T.hx', indexOf(TWINS).refs.onlyDeclaration('T')?.file.file);
	}

	@:pin('control') @:killer('M-DECLARING-PATHS-EMPTY', 'M-DECLARINGFILES-EMPTY')
	public function testARefusalNamesEveryDeclaringFile(): Void {
		final found: Array<String> = indexOf(BASES).refs.declaringPaths('Base');
		found.sort(Reflect.compare);
		Assert.equals(BOTH, found.join(','));
		Assert.equals('t/T.hx', indexOf(TWINS).refs.declaringPaths('T').join(','));
	}

	private static function denoted(raw: String, file: Null<String>): String {
		final index: SymbolIndex = indexOf(BASES);
		return filesOf(index.refs.mayDenote(raw, file == null ? null : index.fileInfo(file)));
	}

	private static function typed(kind: String, at: String): Null<String> {
		return ValueDoorsTest.typedIn(READER, 'a/C.hx', [{ file: 'b/U.hx', source: ABSTRACT }], kind, at).source;
	}

	private static function hopsOf(index: SymbolIndex, file: String, name: String): String {
		final decl: ResolvedType = index.refs.findDeclaredType(file, name) ?? throw 'no $name in $file';
		return filesOf(SupertypeWalk.hops(index.refs, decl));
	}

	private static function filesOf(found: Array<ResolvedType>): String {
		final files: Array<String> = [for (r in found) r.file.file];
		files.sort(Reflect.compare);
		return files.join(',');
	}

	private static function indexOf(files: Array<{ file: String, source: String }>): SymbolIndex {
		return CheckFixture.index(files, new HaxeQueryPlugin());
	}

	private static function typedAs(written: String, kind: String, at: String): Null<String> {
		final reader: String = 'package a;\n\nclass C {\n\tfunction f(u: $written) {\n\t\tu[0];\n\t\tu + u;\n\t}\n}\n';
		return ValueDoorsTest.typedIn(reader, 'a/C.hx', [{ file: 'b/U.hx', source: ABSTRACT }], kind, at).source;
	}

}
