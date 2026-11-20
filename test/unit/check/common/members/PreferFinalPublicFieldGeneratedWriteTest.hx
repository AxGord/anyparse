package unit.check.common.members;

import anyparse.check.common.members.PreferFinalPublicField;

/**
 * A field named by a string argument of grammar metadata is WRITTEN by the code a macro
 * generates from that metadata, though no source text assigns it: `prefer-final-public-field`
 * must stay silent on it, and still report a public field nothing writes.
 */
class PreferFinalPublicFieldGeneratedWriteTest extends Test {

	/** The field named by an `@:fmt(...)` string argument is a generated write. */
	@:pin('control')
	@:killer('M-GENERATED-WRITE-UNMARKED')
	public function testFieldNamedByMetadataStringIsWritten(): Void {
		Assert.equals(
			0,
			ownerViolations([
				{ file: 'G.hx', source: "@:fmt(optFlagForCtor('flag', 'X')) class G {}" },
				{ file: 'C.hx', source: 'class C { public var flag:Bool = false; }' }
			]).length
		);
	}

	/** A never-written public field with no metadata naming it is still reported. */
	public function testNeverWrittenFieldStillFlagged(): Void {
		Assert.equals(
			1,
			ownerViolations([
				{ file: 'G.hx', source: "@:fmt(optFlagForCtor('other', 'X')) class G {}" },
				{ file: 'C.hx', source: 'class C { public var never:Bool = false; }' }
			]).length
		);
	}

	/** A metadata's OWN direct string argument is not a call argument and writes nothing. */
	@:pin('control')
	@:killer('M-GENERATED-WRITE-DIRECT-ARG')
	public function testDirectMetadataStringIsNotAWrite(): Void {
		Assert.equals(
			1,
			ownerViolations([
				{ file: 'G.hx', source: "@:native('never') class G {}" },
				{ file: 'C.hx', source: 'class C { public var never:Bool = false; }' }
			]).length
		);
	}

	private function ownerViolations(files: Array<{ file: String, source: String }>): Array<Violation> {
		return CheckFixture.violationsIn(new PreferFinalPublicField(), files).filter(v -> v.file == 'C.hx');
	}

}
