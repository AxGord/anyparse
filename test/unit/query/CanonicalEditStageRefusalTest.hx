package unit.query;

import anyparse.query.CanonicalEdit;
import anyparse.runtime.Span;

/**
 * The refusal reasons of the two cross-file staging seats: each branch that sinks a whole component says which file sank it
 * and why, so `lint --fix` can name a fix it did not write instead of dropping it.
 */
@:nullSafety(Strict)
class CanonicalEditStageRefusalTest extends Test {

	private static final EDIT: Array<{ file: String, edits: Array<{ span: Span, text: String }> }> = [{
		file: 'a/A.hx',
		edits: [{ span: new Span(0, 0), text: 'x' }]
	}];

	/** A file the run does not hold sinks the set, and the callback hears its path. */
	@:pin('control')
	@:killer('M-STAGE-REFUSE-NOT-HELD')
	public function testAMissingSourceIsReported(): Void {
		final heard: Array<String> = [];
		final staged: Null<Array<{ file: String, source: String }>> = CanonicalEdit.stageCrossFileRename(
			EDIT, _ -> null, (_, source, _) -> Ok(source), (file, reason) -> heard.push('$file|$reason')
		);
		Assert.isNull(staged);
		Assert.equals('a/A.hx|the run does not hold the file', heard.join(';'));
	}

	/** A result equal to the source is no change: the set is refused and the callback says so. */
	@:pin('control')
	@:killer('M-STAGE-REFUSE-UNCHANGED')
	public function testAnUnchangedResultIsReported(): Void {
		final heard: Array<String> = [];
		final staged: Null<Array<{ file: String, source: String }>> = CanonicalEdit.stageCrossFileRename(
			EDIT, _ -> 'same', (_, source, _) -> Ok(source), (file, reason) -> heard.push('$file|$reason')
		);
		Assert.isNull(staged);
		Assert.equals('a/A.hx|its edits leave the file unchanged', heard.join(';'));
	}

	/** A path a create would overwrite sinks the set, and the callback hears it. */
	@:pin('control')
	@:killer('M-STAGE-REFUSE-CREATE-EXISTS')
	public function testACreateOverAnExistingPathIsReported(): Void {
		final heard: Array<String> = [];
		final staged: Null<Array<{ file: String, source: String }>> = CanonicalEdit.stageCrossFileCreates(
			[{ file: 'a/B.hx', text: 'class B {}' }], _ -> true, (_, text) -> Ok(text), (file, reason) -> heard.push('$file|$reason')
		);
		Assert.isNull(staged);
		Assert.equals('a/B.hx|the file it would create already exists', heard.join(';'));
	}

	/** A create the writer cannot settle sinks the set with the writer's own message. */
	@:pin('control')
	@:killer('M-STAGE-REFUSE-CREATE-ERR')
	public function testACreateTheWriterRefusesIsReported(): Void {
		final heard: Array<String> = [];
		final staged: Null<Array<{ file: String, source: String }>> = CanonicalEdit.stageCrossFileCreates(
			[{ file: 'a/B.hx', text: 'import' }], _ -> false, (_, _) -> Err('does not parse'), (file, reason) -> heard.push('$file|$reason')
		);
		Assert.isNull(staged);
		Assert.equals('a/B.hx|does not parse', heard.join(';'));
	}

}
