package unit.query;

import anyparse.query.CrossRename.CrossRenameResult;
import anyparse.query.CrossRename.FileChange;
import anyparse.query.CrossRenameMember;

using Lambda;
using StringTools;

/**
 * `CrossRenameMember.crossRenameMember` on an ENUM CONSTRUCTOR. A constructor's name leaks into every scope that
 * imports its enum, so the declaration, the bare calls and patterns, the qualified `E.A` spellings and the import of
 * the constructor itself rename together — or the whole rename is refused. Every fixture compiled on Haxe 4.3.7, and
 * every Ok shape printed the same values after the rewrite.
 */
class EnumCtorRenameTest extends Test {

	private static final ENUM: String = 'package pkg;\n\nenum E {\n\tA(x: Int);\n\tB;\n}\n\nclass Use {\n'
		+ '\tpublic static function make(): E {\n\t\treturn A(1);\n\t}\n\n\tpublic static function value(e: E): Int {\n'
		+ '\t\treturn switch e {\n\t\t\tcase A(x): x;\n\t\t\tcase B: 0;\n\t\t}\n\t}\n}\n';
	private static final USER: String = 'package other;\n\nimport pkg.E;\n\nclass User {\n\tpublic static function qualified(): E {\n'
		+ '\t\treturn E.A(2);\n\t}\n\n\tpublic static function bare(): E {\n\t\treturn A(3);\n\t}\n}\n';
	private static final CTOR_IMPORT: String =
		'package other;\n\nimport pkg.E.A;\n\nclass Ctor {\n\tpublic static function make(): pkg.E {\n\t\treturn A(4);\n\t}\n}\n';
	private static final PATH: String = 'package other;\n\nclass Path {\n\tpublic static function value(e: pkg.E): Int {\n'
		+ '\t\treturn switch e {\n\t\t\tcase pkg.E.A(0): 0;\n\t\t\tcase A(x): x + 1;\n\t\t\tcase _: 0;\n\t\t}\n\t}\n}\n';

	/**
	 * The declaration, a bare call and a bare pattern in the enum's own module, a qualified call and a bare call in a file
	 * importing the enum, the constructor's own import and the bare call it licenses, and a dotted pattern beside a bare
	 * one under a subject typed as the enum — every spelling renames, nothing else moves.
	 */
	@:pin('control') @:killer('M-CTOR-NOT-A-MEMBER') @:killer('M-CTOR-BARE-KEPT') @:killer('M-CTOR-IMPORT-KEPT') @:killer('M-CTOR-RETURN-CALL-UNPROVEN')
	public function testEveryReferenceOfAConstructorRenames(): Void {
		final changes: Array<FileChange> = ok(run(scope([])));
		Assert.equals(ENUM.replace('A(', 'Alpha('), source(changes, 'pkg/E.hx'));
		Assert.equals(USER.replace('A(', 'Alpha('), source(changes, 'other/User.hx'));
		Assert.equals(CTOR_IMPORT.replace('A(', 'Alpha(').replace('E.A;', 'E.Alpha;'), source(changes, 'other/Ctor.hx'));
		Assert.equals(PATH.replace('A(', 'Alpha('), source(changes, 'other/Path.hx'));
	}

	/** A receiver naming the enum under another name — an import alias, a typedef — reaches the constructor too. */
	@:pin('control') @:killer('M-CTOR-ALIAS-RECEIVER-KEPT')
	public function testAnAliasOrATypedefOfTheEnumReachesItsConstructor(): Void {
		final alias: String =
			'package other;\n\nimport pkg.E as F;\n\nclass Alias {\n\tpublic static function make(): F {\n\t\treturn F.A(5);\n\t}\n}\n';
		final td: String = 'package other;\n\ntypedef T = pkg.E;\n\nclass Td {\n\tpublic static function value(t: T): Int {\n'
			+ '\t\treturn switch t {\n\t\t\tcase T.A(x): x;\n\t\t\tcase _: 0;\n\t\t}\n\t}\n}\n';
		final changes: Array<FileChange> = ok(run(scope([{ file: 'other/Alias.hx', source: alias }, { file: 'other/Td.hx', source: td }])));
		Assert.equals(alias.replace('F.A(', 'F.Alpha('), source(changes, 'other/Alias.hx'));
		Assert.equals(td.replace('T.A(', 'T.Alpha('), source(changes, 'other/Td.hx'));
	}

	/** A local spelling the old name in a file that imports the enum is the local's, and keeps its name. */
	@:pin('guard')
	public function testALocalOfTheOldNameKeepsIt(): Void {
		final shadow: String = 'package other;\n\nimport pkg.E;\n\nclass Shadow {\n\tpublic static function value(): Int {\n'
			+ '\t\tfinal A: Int = 9;\n\t\treturn A;\n\t}\n}\n';
		final changes: Array<FileChange> = ok(run(scope([{ file: 'other/Shadow.hx', source: shadow }])));
		Assert.isNull(changes.find(c -> c.file == 'other/Shadow.hx'));
	}

	/**
	 * A bare spelling under a subject whose type nothing proves — Haxe resolves it from the expected type, which the op
	 * cannot read — refuses the whole rename instead of leaving that pattern on the old name.
	 */
	@:pin('control') @:killer('M-CTOR-UNPROVEN-RENAMED')
	public function testAnUnprovableBareSpellingRefusesTheRename(): Void {
		final blind: String = 'package other;\n\nclass Blind {\n\tpublic static function value(): Int {\n'
			+ '\t\treturn switch pkg.E.Use.make() {\n\t\t\tcase A(x): x;\n\t\t\tcase _: 0;\n\t\t}\n\t}\n}\n';
		refused(run(scope([{ file: 'other/Blind.hx', source: blind }])), 'other/Blind.hx: "A" at 6:9 is not proven to be the constructor');
	}

	/** Another enum hosting either name makes a bare spelling mean either, so the rename is refused. */
	@:pin('control') @:killer('M-CTOR-RIVAL-IGNORED') @:killer('M-CTOR-TAKEN-IGNORED')
	public function testAValueOfEitherNameOnAnotherEnumRefuses(): Void {
		refused(run(scope([{ file: 'other/F.hx', source: 'package other;\n\nenum F {\n\tA;\n}\n' }])), '"F" also hosts');
		refused(run(scope([{ file: 'other/G.hx', source: 'package other;\n\nenum G {\n\tAlpha;\n}\n' }])), '"G" already hosts');
	}

	/** A local holding the new name would capture the renamed call. */
	@:pin('control') @:killer('M-CTOR-CAPTURE-UNCHECKED')
	public function testANewNameALocalHoldsRefuses(): Void {
		final local: String = 'package other;\n\nimport pkg.E;\n\nclass Local {\n\tpublic static function make(): E {\n'
			+ '\t\tfinal Alpha: Int = 1;\n\t\treturn A(Alpha);\n\t}\n}\n';
		refused(run(scope([{ file: 'other/Local.hx', source: local }])), 'is captured by a binding');
	}

	/** An inherited member holding the new name would bind the renamed call, and the reference index cannot see it. */
	@:pin('control') @:killer('M-CTOR-NEW-NAME-OUTRANKED')
	public function testANewNameAnInheritedMemberHoldsRefuses(): Void {
		final base: String = 'package other;\n\nclass Base {\n\tpublic var Alpha: Int = 1;\n\n\tpublic function new() {}\n}\n';
		final member: String =
			'package other;\n\nimport pkg.E;\n\nclass Member extends Base {\n\tpublic function make(): E {\n\t\treturn A(1);\n\t}\n}\n';
		refused(run(scope([
			{ file: 'other/Base.hx', source: base },
			{ file: 'other/Member.hx', source: member }
		])), '"Alpha" at 7:10 would bind a member');
	}

	/**
	 * A bare spelling of the new name that already means something — here a statically imported function — would be taken
	 * over by the renamed constructor, which 4.3.7 resolves first whatever the import order.
	 */
	@:pin('control') @:killer('M-CTOR-NEW-NAME-TAKEN-OVER')
	public function testANewNameAnImportedStaticSpellsRefuses(): Void {
		final stat: String = 'package other;\n\nimport pkg.E;\nimport other.Fn.Alpha;\n\nclass Stat {\n'
			+ '\tpublic static function make(): Int {\n\t\treturn Alpha(1);\n\t}\n}\n';
		final fn: String = 'package other;\n\nclass Fn {\n\tpublic static function Alpha(x: Int): Int {\n\t\treturn x + 100;\n\t}\n}\n';
		refused(
			run(scope([{ file: 'other/Stat.hx', source: stat }, { file: 'other/Fn.hx', source: fn }])),
			'other/Stat.hx: "Alpha" at 8:10 already names something'
		);
	}

	/**
	 * A pattern variable spelling the new name in a file that does NOT import the enum: Haxe reads a pattern identifier
	 * against the subject's enum first, so the capture would turn into the renamed constructor (`2,2` became `3,2`).
	 */
	@:pin('control') @:killer('M-CTOR-NEW-NAME-ONLY-WHERE-VISIBLE')
	public function testANewNameAPatternCapturesWithoutTheImportRefuses(): Void {
		final enumSource: String = 'package p;\n\nenum E {\n\tA(x: Int);\n\tB;\n\tC;\n}\n';
		final user: String = 'package q;\n\nclass U {\n\tpublic static function f(e: p.E): Int {\n\t\treturn switch e {\n'
			+ '\t\t\tcase A(1): 1;\n\t\t\tcase rest: 2;\n\t\t\tcase _: 3;\n\t\t}\n\t}\n}\n';
		refused(
			runAt([{ file: 'p/E.hx', source: enumSource }, { file: 'q/U.hx', source: user }], 6, 2, 'rest'),
			'q/U.hx: "rest" at 7:9 already names something'
		);
	}

	/**
	 * An imported static spelling the new name at a position expecting the enum, in a file that does not import it: the
	 * expected enum's constructor wins over the import, so `B` became `Alpha` silently.
	 */
	@:pin('control') @:killer('M-CTOR-NEW-NAME-ONLY-WHERE-VISIBLE')
	public function testANewNameAnImportedStaticAtAnExpectedEnumRefuses(): Void {
		final enumSource: String = 'package p;\n\nenum E {\n\tA;\n\tB;\n}\n';
		final util: String = 'package q;\n\nclass Util {\n\tpublic static var Alpha: p.E = p.E.B;\n}\n';
		final v: String =
			'package q;\n\nimport q.Util.Alpha;\n\nclass V {\n\tpublic static function g(): p.E {\n\t\treturn Alpha;\n\t}\n}\n';
		refused(runAt([
			{ file: 'p/E.hx', source: enumSource },
			{ file: 'q/Util.hx', source: util },
			{ file: 'q/V.hx', source: v }
		], 4, 2, 'Alpha'), 'q/V.hx: "Alpha" at 7:10 already names something');
	}

	/**
	 * An import of a module the scope does not hold (`haxe.ds.Option`) may bring a constructor of the old name, and the later
	 * import wins: the bare `None` was Option's, and renaming it made it the enum's.
	 */
	@:pin('control') @:killer('M-CTOR-UNLISTED-IMPORT-IGNORED')
	public function testAnOldNameAnUnlistedImportMayBringRefuses(): Void {
		final enumSource: String = 'package p;\n\nenum E {\n\tNone;\n\tB;\n}\n';
		final user: String = 'package p;\n\nimport p.E;\nimport haxe.ds.Option;\n\nclass U {\n\tpublic static function f(): String {\n'
			+ '\t\tvar x = None;\n\t\treturn Std.string(x);\n\t}\n}\n';
		refused(runAt([{ file: 'p/E.hx', source: enumSource }, { file: 'p/U.hx', source: user }], 4, 2, 'Empty'), 'haxe.ds.Option');
	}

	/** The reverse: the renamed spelling takes the name of an unlisted import's constructor, which the later import makes win. */
	@:pin('control') @:killer('M-CTOR-UNLISTED-IMPORT-IGNORED')
	public function testANewNameAnUnlistedImportMayBringRefuses(): Void {
		final enumSource: String = 'package p;\n\nenum E {\n\tA;\n\tB;\n}\n';
		final user: String = 'package p;\n\nimport p.E;\nimport haxe.ds.Option;\n\nclass U {\n\tpublic static function f(): String {\n'
			+ '\t\tvar x = A;\n\t\treturn Std.string(x);\n\t}\n}\n';
		refused(runAt([{ file: 'p/E.hx', source: enumSource }, { file: 'p/U.hx', source: user }], 4, 2, 'None'), 'haxe.ds.Option');
	}

	/** A name every module reads without an import (`trace`) is refused as a new name: the constructor would take it over. */
	@:pin('control') @:killer('M-CTOR-IMPLICIT-NAME-TAKEN')
	public function testAnImplicitNameRefuses(): Void {
		final enumSource: String = 'package p;\n\nenum E {\n\tA;\n\tB;\n}\n';
		refused(runAt([{ file: 'p/E.hx', source: enumSource }], 4, 2, 'trace'), '"trace" is a name every module');
	}

	/**
	 * A bare spelling in a file importing the enum, under a switch on a subject of ANOTHER enum type the scope cannot see:
	 * the pattern is that enum's constructor (`Type.typeof(v)`'s `TNull`), and renaming it turned `nulltrueotherfalse`
	 * into `othertruenullfalse`.
	 */
	@:pin('control') @:killer('M-CTOR-SUBJECT-UNPROVEN') @:killer('M-CTOR-UNPROVEN-RENAMED')
	public function testABareSpellingUnderAnUnprovenSubjectRefuses(): Void {
		final enumSource: String = 'package p;\n\nenum E {\n\tTNull;\n\tB;\n}\n';
		final user: String = 'package p;\n\nimport p.E;\n\nclass U {\n\tpublic static function f(v: Dynamic, e: E): String {\n\t\treturn ('
			+ 'switch Type.typeof(v) {\n\t\t\tcase TNull: "null";\n\t\t\tcase _: "other";\n\t\t}) + Std.string(e == TNull);\n\t}\n}\n';
		refused(runAt([{ file: 'p/E.hx', source: enumSource }, { file: 'p/U.hx', source: user }], 4, 2, 'TInt'), 'p/U.hx: "TNull" at 8:9');
	}

	/** The subject's declared type names another enum fully qualified (`haxe.ds.Option<Int>`), so its `None` is not this one. */
	@:pin('control') @:killer('M-CTOR-SUBJECT-UNPROVEN') @:killer('M-CTOR-UNPROVEN-RENAMED')
	public function testABareSpellingUnderASubjectOfAnotherDeclaredEnumRefuses(): Void {
		final enumSource: String = 'package p;\n\nenum E {\n\tNone;\n\tB;\n}\n';
		final user: String = 'package p;\n\nimport p.E;\n\nclass U {\n\tpublic static function f(o: haxe.ds.Option<Int>, e: E): String {\n'
			+ '\t\treturn (switch o {\n\t\t\tcase None: "none";\n\t\t\tcase _: "some";\n\t\t}) + Std.string(e);\n\t}\n}\n';
		refused(runAt([{ file: 'p/E.hx', source: enumSource }, { file: 'p/U.hx', source: user }], 4, 2, 'Empty'), 'p/U.hx: "None" at 8:9');
	}

	/** The subject is a call whose declared return type is another enum (`Lib.get(): Option<Int>`), never proven this one. */
	@:pin('control') @:killer('M-CTOR-SUBJECT-UNPROVEN') @:killer('M-CTOR-UNPROVEN-RENAMED')
	public function testABareSpellingUnderACallSubjectRefuses(): Void {
		final enumSource: String = 'package p;\n\nenum E {\n\tNone;\n\tB;\n}\n';
		final lib: String =
			'package p;\n\nclass Lib {\n\tpublic static function get(): haxe.ds.Option<Int> {\n\t\treturn haxe.ds.Option.None;\n\t}\n}\n';
		final user: String = 'package p;\n\nimport p.E;\n\nclass U {\n\tpublic static function f(e: E): String {\n'
			+ '\t\treturn (switch Lib.get() {\n\t\t\tcase None: "none";\n\t\t\tcase _: "some";\n\t\t}) + Std.string(e);\n\t}\n}\n';
		refused(runAt([
			{ file: 'p/E.hx', source: enumSource },
			{ file: 'p/Lib.hx', source: lib },
			{ file: 'p/U.hx', source: user }
		], 4, 2, 'Empty'), 'p/U.hx: "None" at 8:9');
	}

	/** The right operand of `==` / `!=` whose left operand is declared the enum reads its constructor, import or not. */
	@:pin('control') @:killer('M-CTOR-EQUALITY-UNPROVEN')
	public function testTheRightOperandOfAComparisonWithTheEnumRenames(): Void {
		final enumSource: String = 'package p;\n\nenum E {\n\tA;\n\tB;\n}\n';
		final user: String =
			'package q;\n\nclass U {\n\tpublic static function isA(e: p.E): Bool {\n\t\treturn e == A && !(e != A);\n\t}\n}\n';
		final changes: Array<FileChange> = ok(
			runAt([{ file: 'p/E.hx', source: enumSource }, { file: 'q/U.hx', source: user }], 4, 2, 'Alpha')
		);
		Assert.equals(user.replace('== A', '== Alpha').replace('!= A', '!= Alpha'), source(changes, 'q/U.hx'));
	}

	private static function scope(extra: Array<{ file: String, source: String }>): Array<{ file: String, source: String }> {
		return [
			{ file: 'pkg/E.hx', source: ENUM },
			{ file: 'other/User.hx', source: USER },
			{ file: 'other/Ctor.hx', source: CTOR_IMPORT },
			{ file: 'other/Path.hx', source: PATH }
		].concat(extra);
	}

	private static function run(files: Array<{ file: String, source: String }>): CrossRenameResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return CrossRenameMember.crossRenameMember('pkg/E.hx', ENUM, 4, 2, 'Alpha', files, plugin, plugin.refShape());
	}

	private static function runAt(files: Array<{ file: String, source: String }>, line: Int, col: Int, newName: String): CrossRenameResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return CrossRenameMember.crossRenameMember(files[0].file, files[0].source, line, col, newName, files, plugin, plugin.refShape());
	}

	private static function ok(result: CrossRenameResult): Array<FileChange> {
		return switch result {
			case Ok(changes, _): changes;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				[];
		};
	}

	private static function source(changes: Array<FileChange>, file: String): String {
		return changes.find(c -> c.file == file)?.newSource ?? 'NO CHANGE FOR $file';
	}

	private static function refused(result: CrossRenameResult, reason: String): Void {
		switch result {
			case Ok(changes, _):
				Assert.fail('expected a refusal naming "$reason", got Ok over ${[for (c in changes) c.file].join(', ')}');
			case Err(message):
				Assert.isTrue(message.contains(reason), message);
		}
	}

}
