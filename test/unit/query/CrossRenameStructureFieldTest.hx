package unit.query;

import anyparse.query.CrossRename.CrossRenameResult;
import anyparse.query.CrossRename.FileChange;
import anyparse.query.CrossRenameMember;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * `CrossRenameMember` over a field of a `typedef` structure: the declaration moves, an object literal a written type around it
 * proves builds the type moves with it, a literal proven to be something else stays, and a literal nothing written decides but
 * that could be exactly that structure refuses the rename.
 */
class CrossRenameStructureFieldTest extends Test {

	private static final STRUCTURE: String = 'typedef Ctx = {\n\tfinal flag: Bool;\n\tfinal other: Int;\n}\n';
	private static final CURSOR: String = 'flag: Bool';

	/** A literal returned, held by an annotated local, passed as a typed argument, assigned to a typed target, in an array of the type. */
	@:pin('control')
	@:killer('M-LITERAL-FIELD-PROVEN')
	public function testEveryWrittenExpectationMovesTheLiteralField(): Void {
		final source: String = '${STRUCTURE}class C {\n\tstatic var saved: Ctx;\n\tstatic function take(c: Ctx): Void {}\n'
			+ '\tstatic function make(): Ctx return {flag: true, other: 1};\n\tstatic function f(): Void {\n'
			+ '\t\tfinal held: Ctx = {flag: false, other: 2};\n\t\ttake({flag: true, other: 3});\n\t\tsaved = {flag: false, other: 4};\n'
			+ '\t\tfinal many: Array<Ctx> = [{flag: true, other: 5}];\n\t}\n}\n';
		final result: String = renamed(source);
		Assert.equals(-1, result.indexOf('flag'), result);
		Assert.isTrue(result.contains('final enabled: Bool;'), result);
		Assert.isTrue(result.contains('{enabled: false, other: 2}'), result);
		Assert.isTrue(result.contains('[{enabled: true, other: 5}]'), result);
	}

	/** The `Null<T>` wrapper a return type carries, a nested literal under a field of a proven structure, and a quoted key. */
	public function testAWrappedNestedOrQuotedFieldMoves(): Void {
		final source: String = '${STRUCTURE}typedef Outer = {\n\tinner: Ctx;\n}\nclass C {\n'
			+ '\tstatic function a(): Null<Ctx> return {flag: true, other: 1};\n\tstatic function b(): Outer return {inner: {'
			+ 'flag: true, other: 2}};\n\tstatic function c(): Ctx return {"flag": true, other: 3};\n}\n';
		final result: String = renamed(source);
		Assert.equals(-1, result.indexOf('flag'), result);
		Assert.isTrue(result.contains('{"enabled": true, other: 3}'), result);
	}

	/** Both `#if` branches of a literal's field and of a declaration are one logical member. */
	public function testConditionalLiteralFieldAndDeclarationMove(): Void {
		final source: String = 'typedef Ctx = {\n\t#if a\n\tfinal flag: Bool;\n\t#else\n\tfinal flag: Int;\n\t#end\n\tfinal other: Int;\n'
			+ '}\nclass C {\n\tstatic function m(): Ctx return {#if a flag: true, #else flag: 1, #end other: 3};\n}\n';
		Assert.equals(-1, renamed(source).indexOf('flag'), source);
	}

	/** A literal built as a different structure of the same field name keeps its field, as does one typed `Dynamic`. */
	@:pin('control')
	@:killer('M-LITERAL-FIELD-OTHER-TYPE')
	public function testLiteralProvenToBeAnotherTypeStays(): Void {
		final source: String = '${STRUCTURE}typedef Other = {\n\tfinal flag: Bool;\n}\nclass C {\n'
			+ '\tstatic function a(): Ctx return {flag: true, other: 1};\n\tstatic function b(): Other return {flag: false};\n'
			+ '\tstatic function c(): Dynamic return {flag: false, other: 2};\n}\n';
		final result: String = renamed(source);
		Assert.isTrue(result.contains('{enabled: true, other: 1}'), result);
		Assert.isTrue(result.contains('return {flag: false};'), result);
		Assert.isTrue(result.contains('return {flag: false, other: 2};'), result);
	}

	/** Nothing written decides this literal and its fields are exactly the structure's: a guess either way breaks the build. */
	@:pin('control')
	@:killer('M-LITERAL-FIELD-REFUSES')
	public function testUndecidedLiteralOfTheStructureShapeRefuses(): Void {
		final source: String = '${STRUCTURE}class C {\n\tstatic function f() return {flag: true, other: 1};\n}\n';
		switch run(source, [{ file: 'A.hx', source: source }]) {
			case Err(message):
				Assert.stringContains('object literal', message);
				Assert.stringContains('"Ctx"', message);
			case Ok(_, _):
				Assert.fail('an undecided literal must refuse');
		}
	}

	/** A literal writing a field the structure lacks, or leaving out a required one, is no value of it: nothing to refuse over. */
	public function testUndecidedLiteralOfAnotherShapeStays(): Void {
		final source: String =
			'${STRUCTURE}class C {\n\tstatic function f() return {flag: true, third: 1};\n\tstatic function g() return {flag: true};\n}\n';
		switch run(source, [{ file: 'A.hx', source: source }]) {
			case Ok(changes, _):
				Assert.equals(1, changes.length);
				Assert.isTrue(changes[0].newSource.contains('{flag: true, third: 1}'), changes[0].newSource);
				Assert.isTrue(changes[0].newSource.contains('{flag: true}'), changes[0].newSource);
			case Err(message):
				Assert.fail(message);
		}
	}

	/** An optional field a literal leaves out keeps it a possible value of the structure, so it refuses like one writing every field. */
	public function testLiteralLeavingOutAnOptionalFieldStillRefuses(): Void {
		final source: String =
			'typedef Ctx = {\n\tfinal flag: Bool;\n\t?more: Int;\n}\nclass C {\n\tstatic function f() return {flag: true};\n}\n';
		Assert.isTrue(
			switch run(source, [{ file: 'A.hx', source: source }]) {
				case Err(_): true;
				case Ok(_, _): false;
			},
			'the literal is exactly the structure'
		);
	}

	/** A literal in another file moves with the declaration; the type it is annotated with resolves through that file's import. */
	public function testLiteralInAnotherFileMoves(): Void {
		final source: String = 'package p;\n\n${STRUCTURE}class B {}\n';
		final other: String = 'package q;\n\nimport p.A.Ctx;\n\nclass C {\n\tstatic function m(): Ctx return {flag: true, other: 1};\n}\n';
		final changes: Array<FileChange> = okChanges(
			source, [{ file: 'p/A.hx', source: source }, { file: 'q/C.hx', source: other }], 'p/A.hx'
		);
		final changed: Null<FileChange> = changes.find(c -> c.file == 'q/C.hx');
		Assert.notNull(changed);
		Assert.isTrue(changed?.newSource.contains('{enabled: true, other: 1}') ?? false);
	}

	/** A structure extended through `>Base` still moves the base's field in a literal built as the extension. */
	public function testLiteralOfAnExtendingStructureMoves(): Void {
		final source: String = '${STRUCTURE}typedef Ext = {\n\t> Ctx,\n\tfinal more: Int;\n}\nclass C {\n'
			+ '\tstatic function m(): Ext return {flag: true, other: 1, more: 2};\n}\n';
		Assert.equals(-1, renamed(source).indexOf('flag'), source);
	}

	/** A plain alias of the structure is the structure. */
	public function testLiteralThroughAPlainAliasMoves(): Void {
		final source: String =
			'${STRUCTURE}typedef Alias = Ctx;\nclass C {\n\tstatic function m(): Alias return {flag: true, other: 1};\n}\n';
		Assert.equals(-1, renamed(source).indexOf('flag'), source);
	}

	/** A class declaring the field is reached by a literal only as a `@:structInit`: the proven literal moves, an unproven one stays. */
	public function testStructInitClassLiteralMoves(): Void {
		final source: String = '@:structInit class Ctx {\n\tpublic final flag: Bool;\n}\n'
			+ 'class C {\n\tstatic function a(): Ctx return {flag: true};\n\tstatic function b() return {flag: false};\n}\n';
		final changes: Array<FileChange> = okChanges(source, [{ file: 'A.hx', source: source }], 'A.hx');
		Assert.isTrue(changes[0].newSource.contains('return {enabled: true};'), changes[0].newSource);
		Assert.isTrue(changes[0].newSource.contains('return {flag: false};'), changes[0].newSource);
	}

	/** A `@:structInit` class written with its own constructor reads a literal's fields as that constructor's parameters. */
	@:pin('control')
	@:killer('M-STRUCTINIT-CTOR-KEPT')
	public function testStructInitConstructorParametersStayOnTheLiteral(): Void {
		final source: String = '@:structInit class Ctx {\n\tpublic final flag: Bool;\n\tpublic function new(flag: Bool) {\n'
			+ '\t\tthis.flag = flag;\n\t}\n}\nclass C {\n\tstatic function a(): Ctx return {flag: true};\n}\n';
		final result: String = renamed(source);
		Assert.isTrue(result.contains('return {flag: true};'), result);
		Assert.isTrue(result.contains('new(flag: Bool)'), result);
	}

	/** A partial `case` pattern is proven by the value the switch matches: its field moves with the structure's. */
	@:pin('control')
	@:killer('M-PATTERN-SUBJECT-PROVEN')
	public function testPartialPatternOnAProvenSubjectMoves(): Void {
		final source: String = '${STRUCTURE}class C {\n\tstatic function f(c: Ctx): Int return switch c {\n\t\tcase {flag: true}: 1;\n'
			+ '\t\tcase _: 0;\n\t};\n}\n';
		final result: String = renamed(source);
		Assert.equals(-1, result.indexOf('flag'), result);
		Assert.isTrue(result.contains('case {enabled: true}:'), result);
	}

	/** A pattern never has to name every field, so an unproven subject refuses on a part of the structure's shape too. */
	@:pin('control')
	@:killer('M-PATTERN-PARTIAL-REFUSES')
	public function testPartialPatternOnAnUnprovenSubjectRefuses(): Void {
		final source: String = '${STRUCTURE}class C {\n\tstatic function make() return null;\n'
			+ '\tstatic function f(): Int return switch make() {\n\t\tcase {flag: true}: 1;\n\t\tcase _: 0;\n\t};\n}\n';
		assertRefuses(source);
	}

	/** Every comma alternative of a `case` is a pattern on the subject, each proven by it. */
	@:pin('control')
	@:killer('M-PATTERN-EVERY-ALTERNATIVE')
	public function testEveryCommaAlternativeOfAPatternMoves(): Void {
		final source: String = '${STRUCTURE}class C {\n\tstatic function f(c: Ctx): Int return switch c {\n'
			+ '\t\tcase {flag: true}, {flag: false}: 1;\n\t\tcase _: 0;\n\t};\n}\n';
		final result: String = renamed(source);
		Assert.equals(-1, result.indexOf('flag'), result);
		Assert.isTrue(result.contains('case {enabled: true}, {enabled: false}:'), result);
	}

	/** A written type naming the structure through an extension leaves the literal's field unattributed. */
	@:pin('control')
	@:killer('M-EXTENSION-UNFOLLOWED')
	public function testLiteralOfAnExtendedInlineStructureRefuses(): Void {
		final source: String = '${STRUCTURE}class C {\n\tstatic function f(): Void {\n'
			+ '\t\tfinal e: {> Ctx, extra: Int} = {flag: true, other: 1, extra: 2};\n\t}\n}\n';
		assertRefuses(source);
	}

	/** A parameter written as a type parameter says nothing about the argument, which may be the structure through its bound. */
	@:pin('control')
	@:killer('M-TYPE-PARAM-UNWRITTEN')
	public function testLiteralPassedToATypeParameterRefuses(): Void {
		final source: String = '${STRUCTURE}class C {\n\tstatic function g<T: Ctx>(c: T): Void {}\n\tstatic function f(): Void {\n'
			+ '\t\tg({flag: true, other: 1});\n\t}\n}\n';
		assertRefuses(source);
	}

	/** An abstract over the structure takes a literal of it through a cast, and hands its field on through `@:forward`. */
	@:pin('control')
	@:killer('M-ABSTRACT-WRAPS-STRUCTURE')
	public function testLiteralOfAnAbstractOverTheStructureRefuses(): Void {
		final source: String =
			'${STRUCTURE}abstract A(Ctx) from Ctx {}\nclass C {\n\tstatic function f(): A return {flag: true, other: 1};\n}\n';
		assertRefuses(source);
	}

	/** Every receiver the expression typing proves is the structure: an index, a for binder, a call, a held field, the access operators. */
	@:pin('control')
	@:killer('M-READ-PROVEN-MOVES')
	public function testReadsThroughProvenReceiversMove(): Void {
		final source: String = '${STRUCTURE}class C {\n\tstatic var cs: Array<Ctx> = [];\n\tvar held: Ctx;\n'
			+ '\tstatic function g(): Ctx return null;\n\tstatic function f(c: Ctx): Void {\n\t\ttrace(cs[0].flag);\n'
			+ '\t\tfor (one in cs) trace(one.flag);\n\t\ttrace(g().flag);\n\t\ttrace(c?.flag);\n\t\ttrace((c : Ctx).flag);\n\t}\n'
			+ '\tfunction h(): Bool return this.held.flag;\n}\n';
		final result: String = renamed(source);
		Assert.equals(-1, result.indexOf('flag'), result);
	}

	/** `?.` is a read too. */
	@:pin('control')
	@:killer('M-READ-NULL-SAFE')
	public function testANullSafeReadMoves(): Void {
		final source: String = '${STRUCTURE}class C {\n\tstatic function f(c: Ctx): Bool return c?.flag;\n}\n';
		Assert.isTrue(renamed(source).contains('c?.enabled'), source);
	}

	/** A check-type receiver is typed by what it is ascribed to. */
	@:pin('control')
	@:killer('M-READ-CHECK-TYPE')
	public function testACheckTypeReceiverMoves(): Void {
		final source: String = '${STRUCTURE}class C {\n\tstatic function f(c: Ctx): Bool return (c : Ctx).flag;\n}\n';
		Assert.isTrue(renamed(source).contains('(c : Ctx).enabled'), source);
	}

	/** A receiver nothing written types refuses the rename and names the read, rather than leaving the old name behind. */
	@:pin('control')
	@:killer('M-READ-UNKNOWN-REFUSES')
	public function testAReadOfAnUnknownReceiverRefuses(): Void {
		final source: String = '${STRUCTURE}class C {\n\tstatic function f(cs: Array<Ctx>) return cs.map(c -> c.flag);\n}\n';
		switch run(source, [{ file: 'A.hx', source: source }]) {
			case Err(message):
				Assert.stringContains('read of "flag"', message);
				Assert.stringContains('rename "flag" by hand', message);
			case Ok(_, _):
				Assert.fail('an unknown receiver must refuse');
		}
	}

	/** A receiver typed as another declared type reads a field of that type. */
	@:pin('control')
	@:killer('M-LITERAL-FIELD-OTHER-TYPE')
	public function testAReadOfAnotherTypeStays(): Void {
		final source: String = '${STRUCTURE}typedef Other = {\n\tfinal flag: Bool;\n}\nclass C {\n'
			+ '\tstatic function f(a: Ctx, b: Other): Void {\n\t\ttrace(a.flag);\n\t\ttrace(b.flag);\n\t}\n}\n';
		final result: String = renamed(source);
		Assert.isTrue(result.contains('trace(a.enabled);'), result);
		Assert.isTrue(result.contains('trace(b.flag);'), result);
	}

	/** A receiver naming a type is a static read, and not a value of the structure: it is left alone and refuses nothing. */
	@:pin('control')
	@:killer('M-READ-TYPED-RECEIVER-STAYS')
	public function testAStaticReadOfAnotherTypeDoesNotRefuse(): Void {
		final source: String = '${STRUCTURE}class D {\n\tpublic static final flag: Bool = true;\n}\nclass C {\n'
			+ '\tstatic function f(c: Ctx): Bool return D.flag || c.flag;\n}\n';
		final result: String = renamed(source);
		Assert.isTrue(result.contains('D.flag || c.enabled'), result);
	}

	/** A receiver written as a literal has the literal's own type, even when the typing reads no type off its parts. */
	@:pin('control')
	@:killer('M-READ-LITERAL-RECEIVER')
	public function testAReadOfALiteralDoesNotRefuse(): Void {
		final source: String = '${STRUCTURE}class C {\n\tstatic function make() return true;\n\tstatic function f(c: Ctx): Bool {\n'
			+ '\t\ttrace({flag: make()}.flag);\n\t\treturn c.flag;\n\t}\n}\n';
		Assert.isTrue(renamed(source).contains('{flag: make()}.flag'), source);
	}

	/** A type no scope file declares types as nothing and still cannot be the structure. */
	@:pin('control')
	@:killer('M-READ-TYPE-PATH-STAYS')
	public function testAStaticReadOfATypeOutsideTheScopeDoesNotRefuse(): Void {
		final source: String = '${STRUCTURE}class C {\n\tstatic function f(c: Ctx): Bool return Flags.flag || c.flag;\n}\n';
		Assert.isTrue(renamed(source).contains('Flags.flag || c.enabled'), source);
	}

	/** A package-qualified type path is a type path too. */
	@:pin('control')
	@:killer('M-READ-TYPE-PATH-STAYS')
	public function testAStaticReadThroughAPackagePathDoesNotRefuse(): Void {
		final source: String = '${STRUCTURE}class C {\n\tstatic function f(c: Ctx): Bool return pkg.sub.Flags.flag || c.flag;\n}\n';
		Assert.isTrue(renamed(source).contains('pkg.sub.Flags.flag || c.enabled'), source);
	}

	/** A segment read off a type-cased prefix is a member of unknown type, which may hold the structure. */
	@:pin('control')
	@:killer('M-TYPE-PATH-PACKAGE-PREFIX')
	public function testAMemberOfAnUnknownTypeRefuses(): Void {
		final source: String = '${STRUCTURE}class C {\n\tstatic function f(c: Ctx): Bool return Other.LIMIT.flag || c.flag;\n}\n';
		switch run(source, [{ file: 'A.hx', source: source }]) {
			case Err(message):
				Assert.stringContains('read of "flag"', message);
			case Ok(_, _):
				Assert.fail('a member of an unknown type must refuse');
		}
	}

	/** An unbound lowercase root is an inherited member, not a type name. */
	@:pin('control')
	@:killer('M-TYPE-PATH-UPPER-END')
	public function testAnUnboundLowercaseReceiverRefuses(): Void {
		final source: String = '${STRUCTURE}class C extends Base {\n\tfunction f(c: Ctx): Bool return inherited.flag || c.flag;\n}\n';
		switch run(source, [{ file: 'A.hx', source: source }]) {
			case Err(message):
				Assert.stringContains('read of "flag"', message);
			case Ok(_, _):
				Assert.fail('an inherited member of unknown type must refuse');
		}
	}

	/** An imported static is a value, whatever its casing, and may hold the structure. */
	@:pin('control')
	@:killer('M-TYPE-PATH-IMPORTED-STATIC')
	public function testAnImportedStaticOfUnknownTypeRefuses(): Void {
		final source: String =
			'import Consts.DEFAULT;\n${STRUCTURE}class C {\n\tstatic function f(c: Ctx): Bool return DEFAULT.flag || c.flag;\n}\n';
		final consts: String = 'class Consts {\n\tpublic static final DEFAULT: A.Ctx = {flag: true, other: 1};\n}\n';
		switch run(source, [{ file: 'A.hx', source: source }, { file: 'Consts.hx', source: consts }]) {
			case Err(message):
				Assert.stringContains('read of "flag"', message);
			case Ok(_, _):
				Assert.fail('a static an import binds is not a type path');
		}
	}

	private function renamed(source: String): String {
		return okChanges(source, [{ file: 'A.hx', source: source }], 'A.hx')[0].newSource;
	}

	private function okChanges(source: String, scope: Array<{ file: String, source: String }>, cursorFile: String): Array<FileChange> {
		return switch run(source, scope, cursorFile) {
			case Ok(changes, _): changes;
			case Err(message):
				Assert.fail(message);
				[
					{
						file: cursorFile,
						newSource: source,
						count: 0,
						edits: []
					}
				];
		};
	}

	private function run(source: String, scope: Array<{ file: String, source: String }>, cursorFile: String = 'A.hx'): CrossRenameResult {
		final position: { line: Int, col: Int } = new Span(source.indexOf(CURSOR), source.indexOf(CURSOR)).lineCol(source);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return CrossRenameMember.crossRenameMember(
			cursorFile, source, position.line, position.col, 'enabled', scope, plugin, plugin.refShape()
		);
	}

	private function assertRefuses(source: String): Void {
		Assert.isTrue(
			switch run(source, [{ file: 'A.hx', source: source }]) {
				case Err(_): true;
				case Ok(_, _): false;
			},
			'the literal has no written type to answer'
		);
	}

}
