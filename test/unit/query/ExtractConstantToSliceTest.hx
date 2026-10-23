package unit.query;

import anyparse.query.Address.AddressSpec;
import anyparse.query.ExtractConstantTo;

using Lambda;
using StringTools;

/**
 * `ExtractConstantTo.extractTo` — `extract-constant` addressed mode: one expression, or a declaration's initializer,
 * moves into a `static final` of another type, in this module or another, and a qualified reference takes its
 * place. Each accepted case asserts both texts; each refusal asserts the reason it names.
 */
class ExtractConstantToSliceTest extends Test {

	/** The worker module every case starts from: a local, a field and a parameter to read. */
	private static final WORKER: String = 'package pkg.a;\n\nclass Worker {\n\n\tvar m:Int = 1;\n\n'
		+ '\tfunction f(p:Int):Int {\n\t\tfinal timeout:Int = 5 * 60;\n\t\treturn timeout + p;\n\t}\n}\n';

	/** The existing module the cross-module cases extend. */
	private static final LIMITS: String = 'package pkg.b;\n\nclass Limits {\n\tpublic static final MAX:Int = 9;\n}\n';

	/** A local's initializer moves into a NEW module of another package: reference, import, typed constant. */
	@:pin('control')
	@:killer('M-EXTRACT-TO-DECL-TYPE-DROPPED')
	public function testALocalInitializerMovesIntoANewModuleOfAnotherPackage(): Void {
		final result: Moved = ok(request(WORKER, { select: 'FinalStmt:timeout' }, 'TIMEOUT', other('pkg.b', 'Limits', null)));
		Assert.isTrue(result.source.contains('final timeout:Int = Limits.TIMEOUT;'), 'the local reads the constant');
		Assert.isTrue(result.source.contains('import pkg.b.Limits;'), 'the source imports the new module');
		Assert.isTrue(result.dest.contains('package pkg.b;'), 'the module is created in its package');
		Assert.isTrue(
			result.dest.contains('public static final TIMEOUT:Int = 5 * 60;'), 'the constant keeps the declared type: ${result.dest}'
		);
	}

	/** A source in another package always imports the module, even when that module is a main type. */
	@:pin('control')
	@:killer('M-EXTRACT-TO-ALWAYS-BARE')
	public function testAnotherPackageNeedsTheImport(): Void {
		final result: Moved = ok(request(WORKER, { select: 'FinalStmt:timeout' }, 'TIMEOUT', other('pkg.b', 'Limits', LIMITS)));
		Assert.isTrue(result.source.contains('import pkg.b.Limits;'), 'imported');
		Assert.isTrue(result.dest.contains('public static final TIMEOUT:Int = 5 * 60;'), 'spliced into the existing module');
		Assert.isTrue(result.dest.contains('MAX'), 'the existing members stay');
	}

	/** A same-package main type resolves bare, so no import is written. */
	public function testASamePackageMainTypeNeedsNoImport(): Void {
		final result: Moved = ok(request(WORKER, { select: 'FinalStmt:timeout' }, 'TIMEOUT', other('pkg.a', 'Limits', null)));
		Assert.isTrue(result.source.contains('Limits.TIMEOUT'), 'referenced');
		Assert.isFalse(result.source.contains('import'), 'no import for a same-package main type');
	}

	/** A wildcard import could shadow the bare name, so the explicit import is written even in the same package. */
	@:pin('control')
	@:killer('M-EXTRACT-TO-WILDCARD-IGNORED')
	public function testAWildcardImportForcesTheExplicitOne(): Void {
		final source: String = WORKER.replace('package pkg.a;\n', 'package pkg.a;\n\nimport other.*;\n');
		final result: Moved = ok(request(source, { select: 'FinalStmt:timeout' }, 'TIMEOUT', other('pkg.a', 'Limits', null)));
		Assert.isTrue(result.source.contains('import pkg.a.Limits;'), 'the explicit import beats the wildcard');
	}

	/** A sub-module type is imported by its sub-type path. */
	public function testASubModuleTypeImportsItsSubPath(): Void {
		final module: String = 'package pkg.b;\n\nclass Limits {\n\tpublic static final MAX:Int = 9;\n}\n\nclass Timeouts {\n'
			+ '\tpublic static final SHORT:Int = 1;\n}\n';
		final result: Moved = ok(request(WORKER, { select: 'FinalStmt:timeout' }, 'TIMEOUT', other('pkg.b', 'Limits', module), 'Timeouts'));
		Assert.isTrue(result.source.contains('import pkg.b.Limits.Timeouts;'), 'the sub-type path is imported');
		Assert.isTrue(result.source.contains('Timeouts.TIMEOUT'), 'and named bare');
	}

	/** A scalar literal becomes `static inline final`, as `inline-constant` would make it. */
	@:pin('control')
	@:killer('M-EXTRACT-TO-NEVER-INLINE')
	public function testAScalarLiteralBecomesInline(): Void {
		final result: Moved = ok(request(WORKER, { match: '60' }, 'MINUTE', other('pkg.b', 'Limits', null)));
		Assert.isTrue(result.dest.contains('public static inline final MINUTE:Int = 60;'), 'inline, typed by the literal: ${result.dest}');
		Assert.isTrue(result.source.contains('5 * Limits.MINUTE'), 'the literal is replaced where it sat');
	}

	/** An operator expression is a constant but does not fold into `inline` here. */
	@:pin('control')
	@:killer('M-EXTRACT-TO-ALWAYS-INLINE')
	public function testAnOperatorExpressionIsNotInlined(): Void {
		final result: Moved = ok(request(WORKER, { match: '5 * 60' }, 'TIMEOUT', other('pkg.b', 'Limits', null)));
		Assert.isTrue(result.dest.contains('public static final TIMEOUT = 5 * 60;'), 'no inline, type left to inference: ${result.dest}');
		Assert.isTrue(result.advisories.exists(a -> a.contains('inference')), 'and the inference is said');
	}

	/** Another type of the same file receives a public constant and no import. */
	public function testAnotherTypeOfTheSameFile(): Void {
		final source: String = '$WORKER\nclass Limits {\n\tpublic static final MAX:Int = 9;\n}\n';
		final result: Moved = ok(request(source, { select: 'FinalStmt:timeout' }, 'TIMEOUT', null, 'Limits'));
		Assert.isTrue(result.source.contains('public static final TIMEOUT:Int = 5 * 60;'), 'public in the other type');
		Assert.isTrue(result.source.contains('final timeout:Int = Limits.TIMEOUT;'), 'referenced');
		Assert.isFalse(result.source.contains('import'), 'no import');
		Assert.isNull(result.destOrNull, 'one file');
	}

	/** The enclosing type itself receives a PRIVATE constant. */
	@:pin('control')
	@:killer('M-EXTRACT-TO-ALWAYS-PUBLIC')
	public function testTheEnclosingTypeKeepsItPrivate(): Void {
		final result: Moved = ok(request(WORKER, { select: 'FinalStmt:timeout' }, 'TIMEOUT', null, 'Worker'));
		Assert.isTrue(result.source.contains('private static final TIMEOUT:Int = 5 * 60;'), 'private: ${result.source}');
		Assert.isTrue(result.source.contains('final timeout:Int = Worker.TIMEOUT;'), 'referenced');
	}

	/** An array literal of constants moves under `--shared`, and the one shared instance is said. */
	public function testASharedArrayMoves(): Void {
		final arr: String = WORKER.replace('final timeout:Int = 5 * 60;', 'final xs:Array<Int> = [1, 2, 3];');
		final result: Moved = ok(request(arr, { select: 'FinalStmt:xs' }, 'XS', other('pkg.b', 'Limits', null), null, true));
		Assert.isTrue(result.dest.contains('public static final XS:Array<Int> = [1, 2, 3];'), 'moved: ${result.dest}');
		Assert.isTrue(result.advisories.exists(a -> a.contains('shared')), 'the sharing is said');
	}

	/** Without `--shared` an array literal is refused: a static final is one instance, the literal a fresh one each time. */
	@:pin('control')
	@:killer('M-EXTRACT-TO-SHARED-IGNORED')
	public function testAnUnsharedArrayIsRefused(): Void {
		final arr: String = WORKER.replace('final timeout:Int = 5 * 60;', 'final xs:Array<Int> = [1, 2, 3];');
		refused(request(arr, { select: 'FinalStmt:xs' }, 'XS', other('pkg.b', 'Limits', null)), '--shared');
	}

	/** An array holding a non-constant is refused even under `--shared`. */
	@:pin('control')
	@:killer('M-EXTRACT-TO-ANY-AGGREGATE')
	public function testAnArrayOfANonConstantIsRefused(): Void {
		final arr: String = WORKER.replace('final timeout:Int = 5 * 60;', 'final xs:Array<Null<Int>> = [1, null];');
		refused(request(arr, { select: 'FinalStmt:xs' }, 'XS', other('pkg.b', 'Limits', null), null, true), 'not a compile-time constant');
	}

	/** Reading a parameter refuses, naming it. */
	@:pin('control')
	@:killer('M-EXTRACT-TO-READS-UNCHECKED')
	public function testReadingALocalIsRefused(): Void {
		refused(request(WORKER, { match: 'timeout + p' }, 'SUM', other('pkg.b', 'Limits', null)), 'reads `timeout`');
	}

	/** Reading `this` refuses. */
	public function testReadingThisIsRefused(): Void {
		final source: String = WORKER.replace('5 * 60', 'this.m');
		refused(request(source, { select: 'FinalStmt:timeout' }, 'T', other('pkg.b', 'Limits', null)), 'reads `this`');
	}

	/** A non-constant that reads nothing — `null` — is refused as such. */
	public function testANullIsNotAConstant(): Void {
		final source: String = WORKER.replace('final timeout:Int = 5 * 60;', 'final n:Null<Int> = null;');
		refused(request(source, { select: 'FinalStmt:n' }, 'N', other('pkg.b', 'Limits', null)), 'not a compile-time constant');
	}

	/** A metadata argument must stay a literal. */
	@:pin('control')
	@:killer('M-EXTRACT-TO-META-POSITION')
	public function testAMetadataArgumentIsRefused(): Void {
		final source: String = WORKER.replace('\tfunction f', '\t@:m(3)\n\tfunction f');
		refused(request(source, { select: 'MetaCall >> IntLit' }, 'THREE', other('pkg.b', 'Limits', null)), 'metadata');
	}

	/** A case pattern would read a reference as a capture or another kind of pattern. */
	@:pin('control')
	@:killer('M-EXTRACT-TO-CASE-PATTERN')
	public function testACasePatternIsRefused(): Void {
		final source: String = WORKER.replace('return timeout + p;', 'return switch p {\n\t\t\tcase 7: 1;\n\t\t\tcase _: 0;\n\t\t};');
		refused(request(source, { match: '7' }, 'SEVEN', other('pkg.b', 'Limits', null)), 'case pattern');
	}

	/** A parameter default must fold, so a non-inline constant may not replace it. */
	@:pin('control')
	@:killer('M-EXTRACT-TO-PARAM-DEFAULT')
	public function testANonFoldingParameterDefaultIsRefused(): Void {
		final source: String = WORKER.replace('function f(p:Int)', 'function f(p:Int = 2 * 3)');
		refused(request(source, { match: '2 * 3' }, 'SIX', other('pkg.b', 'Limits', null)), 'parameter default');
	}

	/** A scalar parameter default becomes an inline constant and moves. */
	public function testAScalarParameterDefaultMoves(): Void {
		final source: String = WORKER.replace('function f(p:Int)', 'function f(p:Int = 6)');
		final result: Moved = ok(request(source, { match: '6' }, 'SIX', other('pkg.b', 'Limits', null)));
		Assert.isTrue(result.source.contains('p:Int = Limits.SIX'), 'the default reads the inline constant: ${result.source}');
	}

	/** A local named like the receiving type would take the reference. */
	@:pin('control')
	@:killer('M-EXTRACT-TO-SHADOW-UNCHECKED')
	public function testALocalShadowingTheTypeIsRefused(): Void {
		final source: String = WORKER.replace('return timeout + p;', 'final Limits:Int = 0;\n\t\treturn timeout + p + Limits;');
		refused(request(source, { select: 'FinalStmt:timeout' }, 'TIMEOUT', other('pkg.b', 'Limits', null)), 'local name');
	}

	/** An import of another `Limits` would take the reference. */
	@:pin('control')
	@:killer('M-EXTRACT-TO-REBIND-UNCHECKED')
	public function testAnotherImportOfTheNameIsRefused(): Void {
		final source: String = WORKER.replace('package pkg.a;\n', 'package pkg.a;\n\nimport other.Limits;\n');
		refused(request(source, { select: 'FinalStmt:timeout' }, 'TIMEOUT', other('pkg.b', 'Limits', null)), 'another import');
	}

	/** The source's own type of that name would take the reference. */
	public function testASourceTypeOfTheNameIsRefused(): Void {
		final source: String = '$WORKER\nclass Limits {}\n';
		refused(request(source, { select: 'FinalStmt:timeout' }, 'TIMEOUT', other('pkg.b', 'Limits', null)), 'declares its own type');
	}

	/** An interface cannot hold the constant. */
	@:pin('control')
	@:killer('M-EXTRACT-TO-ANY-HOST')
	public function testAnInterfaceIsRefusedAsAHost(): Void {
		final module: String = 'package pkg.b;\n\ninterface Limits {}\n';
		refused(request(WORKER, { select: 'FinalStmt:timeout' }, 'TIMEOUT', other('pkg.b', 'Limits', module)), 'needs a class');
	}

	/** A declared project type the destination may not see is refused; `--annotate` spells it. */
	@:pin('control')
	@:killer('M-EXTRACT-TO-UNSEEN-TYPE')
	public function testAnUnseenDeclaredTypeIsRefusedUnlessAnnotated(): Void {
		final source: String = WORKER.replace('final timeout:Int = 5 * 60;', 'final d:Duration = 5;');
		refused(request(source, { select: 'FinalStmt:d' }, 'D', other('pkg.b', 'Limits', null)), '`Duration`');
		final annotated: Moved = ok(
			request(source, { select: 'FinalStmt:d' }, 'D', other('pkg.b', 'Limits', null), null, false, 'pkg.a.Duration')
		);
		Assert.isTrue(annotated.dest.contains('D:pkg.a.Duration = 5'), 'spelled as given: ${annotated.dest}');
	}

	/** A name the receiving type already has is refused. */
	public function testANameCollisionIsRefused(): Void {
		refused(request(WORKER, { select: 'FinalStmt:timeout' }, 'MAX', other('pkg.b', 'Limits', LIMITS)), 'already has a member');
	}

	/** A missing module holds only its main type. */
	public function testANewModuleTakesOnlyItsMainType(): Void {
		refused(request(WORKER, { select: 'FinalStmt:timeout' }, 'T', other('pkg.b', 'Limits', null), 'Other'), 'main type');
	}

	/** Without a module, the receiving type must be named. */
	public function testTheSameFileNeedsAType(): Void {
		refused(request(WORKER, { select: 'FinalStmt:timeout' }, 'T', null), '--to');
	}

	/** A declaration without an initializer has nothing to move. */
	public function testADeclarationWithoutAnInitializerIsRefused(): Void {
		final source: String = WORKER.replace('var m:Int = 1;', 'var m:Int;');
		refused(request(source, { select: 'VarMember:m' }, 'M', other('pkg.b', 'Limits', null)), 'no initializer');
	}

	/** An invalid constant name is refused. */
	public function testAnInvalidNameIsRefused(): Void {
		refused(request(WORKER, { select: 'FinalStmt:timeout' }, '9T', other('pkg.b', 'Limits', null)), 'not a valid identifier');
	}

	private static function other(pkg: String, base: String, source: Null<String>): ExtractToModule {
		return {
			file: 'src/${pkg.replace('.', '/')}/$base.hx',
			source: source,
			pkg: pkg,
			base: base,
			optsJson: null
		};
	}

	private static function request(
		source: String, address: AddressSpec, name: String, dest: Null<ExtractToModule>, ?destType: String, shared: Bool = false,
		?annotate: String
	): ExtractToRequest {
		return {
			source: source,
			sourceFile: 'src/pkg/a/Worker.hx',
			address: address,
			name: name,
			destType: destType,
			dest: dest,
			shared: shared,
			annotate: annotate,
			reformat: true,
			optsJson: null
		};
	}

	private static function ok(request: ExtractToRequest): Moved {
		return switch ExtractConstantTo.extractTo(request, new HaxeQueryPlugin()) {
			case Ok(source, dest, advisories): {
				source: source,
				dest: dest ?? '',
				destOrNull: dest,
				advisories: advisories
			};
			case Err(message):
				Assert.fail('expected the constant to move, got: $message');
				{
					source: '',
					dest: '',
					destOrNull: null,
					advisories: []
				};
		};
	}

	private static function refused(request: ExtractToRequest, reason: String): Void {
		switch ExtractConstantTo.extractTo(request, new HaxeQueryPlugin()) {
			case Ok(source, _, _):
				Assert.fail('expected a refusal naming "$reason", got:\n$source');
			case Err(message):
				Assert.isTrue(message.contains(reason), 'refusal "$message" should name "$reason"');
		}
	}

}

/** What a successful move hands back, `dest` empty when it is the source file. */
private typedef Moved = {
	final source: String;
	final dest: String;
	final destOrNull: Null<String>;
	final advisories: Array<String>;
}
