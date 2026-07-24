package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.CompilerDisplayOracle;
import anyparse.check.ExplicitLocalType;

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
