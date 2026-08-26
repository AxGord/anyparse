package unit;

import anyparse.check.CompilerDisplayOracle;
import anyparse.check.ExplicitLocalType;
import utest.Assert;
import utest.Test;

/**
 * Pure-part coverage of the `explicit-local-type` compiler-oracle TAIL — the display
 * XML parsing (`CompilerDisplayOracle.parseTypeResponse`) and the type normalization
 * / rejection / import-aware shortening (`ExplicitLocalType.normalizeInferredType`),
 * both compiler-free so they run on every host.
 */
class ExplicitLocalTypeOracleTest extends Test {

	// --- parseTypeResponse: the display <type>…</type> reply ---

	public function testParseDecodesEntities(): Void {
		Assert.equals('Array<Int>', CompilerDisplayOracle.parseTypeResponse('<type p="X">\nArray&lt;Int&gt;\n</type>'));
	}

	public function testParsePlainTrimmed(): Void {
		Assert.equals('String', CompilerDisplayOracle.parseTypeResponse('<type>String</type>'));
	}

	public function testParseGenericArgs(): Void {
		Assert.equals('A<B, C>', CompilerDisplayOracle.parseTypeResponse('<type>A&lt;B, C&gt;</type>'));
	}

	public function testParseErrorTextIsNull(): Void {
		Assert.isNull(CompilerDisplayOracle.parseTypeResponse('Main.hx:4: characters 7-13 : Type not found : X'));
	}

	public function testParseNoCompletionIsNull(): Void {
		Assert.isNull(CompilerDisplayOracle.parseTypeResponse('Error: No completion point was found'));
	}

	public function testParseEmptyTypeIsNull(): Void {
		Assert.isNull(CompilerDisplayOracle.parseTypeResponse('<type></type>'));
	}

	// --- normalizeInferredType: acceptance ---

	public function testKeepsGeneric(): Void {
		Assert.equals('Array<Int>', ExplicitLocalType.normalizeInferredType('Array<Int>', [], 80));
	}

	public function testKeepsCleanFunctionType(): Void {
		Assert.equals('(x : Int) -> Void', ExplicitLocalType.normalizeInferredType('(x : Int) -> Void', [], 80));
	}

	public function testKeepsSmallAnon(): Void {
		Assert.equals('{ name : String }', ExplicitLocalType.normalizeInferredType('{ name : String }', [], 80));
	}

	// --- normalizeInferredType: rejection ---

	public function testRejectsMonomorphArray(): Void {
		Assert.isNull(ExplicitLocalType.normalizeInferredType('Array<Unknown<0>>', [], 80));
	}

	public function testRejectsMonomorphNull(): Void {
		Assert.isNull(ExplicitLocalType.normalizeInferredType('Null<Unknown<0>>', [], 80));
	}

	public function testRejectsFunctionHole(): Void {
		Assert.isNull(ExplicitLocalType.normalizeInferredType('(x : Unknown<0>) -> Unknown<0>', [], 80));
	}

	public function testRejectsVerboseAnonOverCap(): Void {
		Assert.isNull(ExplicitLocalType.normalizeInferredType('{ name : String, age : Int }', [], 10));
	}

	public function testRejectsBareUnderscore(): Void {
		Assert.isNull(ExplicitLocalType.normalizeInferredType('Class<_>', [], 80));
	}

	public function testRejectsEmpty(): Void {
		Assert.isNull(ExplicitLocalType.normalizeInferredType('   ', [], 80));
	}

	// --- stripTypeParamQualifiers: the compiler's qualified type parameters ---

	public function testStripsClassTypeParam(): Void {
		Assert.equals('T', ExplicitLocalType.stripTypeParamQualifiers('pkg.Box.T', { file: null, methodName: 'get' }));
	}

	public function testStripsClassTypeParamInsideGeneric(): Void {
		Assert.equals('pkg.Box<T>', ExplicitLocalType.stripTypeParamQualifiers('pkg.Box<pkg.Box.T>', { file: null, methodName: 'wrap' }));
	}

	public function testStripsMethodTypeParam(): Void {
		Assert.equals(
			'{ b : U, a : T }',
			ExplicitLocalType.stripTypeParamQualifiers('{ b : pair.U, a : pkg.Box.T }', { file: null, methodName: 'pair' })
		);
	}

	public function testKeepsPackageQualifiedType(): Void {
		Assert.equals(
			'haxe.ds.Map<String, Int>',
			ExplicitLocalType.stripTypeParamQualifiers('haxe.ds.Map<String, Int>', { file: null, methodName: 'get' })
		);
	}

	public function testKeepsSecondaryModuleType(): Void {
		Assert.equals('pkg.Side', ExplicitLocalType.stripTypeParamQualifiers('pkg.Side', { file: null, methodName: 'side' }));
	}

	public function testKeepsMethodNameMismatch(): Void {
		Assert.equals('other.U', ExplicitLocalType.stripTypeParamQualifiers('other.U', { file: null, methodName: 'pair' }));
	}

	/**
	 * A NON-generic method gets a null `methodName`, so a package tail that happens to match its
	 * name is still a package — `function utils()` returning `utils.Thing` keeps its qualifier.
	 */
	public function testKeepsPackageTailMatchingNonGenericMethod(): Void {
		Assert.equals('utils.Thing', ExplicitLocalType.stripTypeParamQualifiers('utils.Thing', { file: null, methodName: null }));
	}

	// --- private module types: nameable only inside their own module ---

	public function testStripsOwnPrivateModuleType(): Void {
		final site: AnnotationSite = { file: 'src/pkg/Holder.hx', methodName: null };
		Assert.equals('Array<Entry>', ExplicitLocalType.stripTypeParamQualifiers('Array<pkg._Holder.Entry>', site));
	}

	public function testKeepsForeignPrivateModuleType(): Void {
		final site: AnnotationSite = { file: 'pkg/Other.hx', methodName: null };
		Assert.equals('Array<pkg._Holder.Entry>', ExplicitLocalType.stripTypeParamQualifiers('Array<pkg._Holder.Entry>', site));
	}

	/** Same module NAME, different package — the package half of the path must discriminate. */
	public function testKeepsSameNamedPrivateModuleOfAnotherPackage(): Void {
		final site: AnnotationSite = { file: 'src/other/Holder.hx', methodName: null };
		Assert.equals('Array<pkg._Holder.Entry>', ExplicitLocalType.stripTypeParamQualifiers('Array<pkg._Holder.Entry>', site));
	}

	/** A private type of ANOTHER module has no spelling that reaches it, so the annotation is refused. */
	public function testRejectsForeignPrivateModuleType(): Void {
		Assert.isNull(ExplicitLocalType.normalizeInferredType('Array<pkg._Holder.Entry>', [], 80));
	}

	public function testKeepsBareName(): Void {
		Assert.equals('String', ExplicitLocalType.stripTypeParamQualifiers('String', { file: null, methodName: 'get' }));
	}

	// --- normalizeInferredType: import-aware shortening ---

	public function testShortensBuiltinQualifiedMap(): Void {
		Assert.equals('Map<String, Int>', ExplicitLocalType.normalizeInferredType('haxe.ds.Map<String, Int>', [], 80));
	}

	public function testShortensImportedType(): Void {
		final imports: Map<String, String> = ['Foo' => 'pkg.Foo'];
		Assert.equals('Foo', ExplicitLocalType.normalizeInferredType('pkg.Foo', imports, 80));
	}

	public function testKeepsUnimportedFqn(): Void {
		Assert.equals('pkg.Foo', ExplicitLocalType.normalizeInferredType('pkg.Foo', [], 80));
	}

	public function testDoesNotMisShortenWrongFqn(): Void {
		final imports: Map<String, String> = ['Foo' => 'other.Foo'];
		Assert.equals('pkg.Foo', ExplicitLocalType.normalizeInferredType('pkg.Foo', imports, 80));
	}

	public function testShortensNestedGenericComponents(): Void {
		final imports: Map<String, String> = ['Foo' => 'pkg.Foo'];
		Assert.equals('Array<Foo>', ExplicitLocalType.normalizeInferredType('Array<pkg.Foo>', imports, 80));
	}

}
