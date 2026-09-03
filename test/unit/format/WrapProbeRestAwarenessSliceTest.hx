package unit.format;

import anyparse.core.Doc;
import anyparse.format.wrap.WrapList;
import utest.Assert;
import utest.Test;

/**
 * `WrapList.groupifyInlineBodies` is a hand-written copy of `D.mapChildren`'s
 * traversal with one extra rule, and it merged `IfNaturalFirstLineExceeds` and
 * `IfNaturalFirstLineExceedsWithRest` into ONE arm that rebuilt BOTH as the
 * plain ctor — the exact failure `D.mapChildren`'s own doc warns about, three
 * lines above the arrow pair that keeps its two spellings separate.
 *
 * The defect is LATENT, and this class exists because that is what makes it
 * unpinnable end to end: swept over 868 Pony files with `fmt --write`, the
 * unfixed and fixed writers produced BYTE-IDENTICAL trees (7 of 868 rewritten
 * in both), and so did a POISON arm that made the same mistake in the opposite
 * direction (the plain ctor rebuilt as the rest-aware one). The same harness
 * DOES detect a writer change through this very function — dropping the
 * `flatLength` gate on its `BodyGroup` arm moved 8 of 868 files — so the null
 * result is a measurement, not a blind spot. What is left to assert is the
 * function's own contract, at the `Doc` level.
 */
@:nullSafety(Strict)
final class WrapProbeRestAwarenessSliceTest extends Test {

	/**
	 * The rest-aware probe survives the walk as ITSELF, and its break branch is
	 * rebuilt on the way — one assertion over both halves, so neither the ctor
	 * check nor the traversal check can be satisfied alone. A `BodyGroup` whose
	 * inner has a flat length is the arm's one non-identity rewrite, so seeing it
	 * come back as a `Group` is the witness that the probe was RECONSTRUCTED
	 * rather than handed back untouched.
	 */
	public function testRestAwareProbeKeepsItsCtorAndIsWalked(): Void {
		Assert.equals(
			'IfNaturalFirstLineExceedsWithRest/Group', shapeOf(Doc.IfNaturalFirstLineExceedsWithRest(40, bodyGroup(), Text('f')))
		);
	}

	/** CONTROL, green at base BY CONSTRUCTION: the plain probe keeps its own ctor — the merge did not rename in both directions. */
	public function testPlainProbeKeepsItsCtor(): Void {
		Assert.equals('IfNaturalFirstLineExceeds/Group', shapeOf(Doc.IfNaturalFirstLineExceeds(40, bodyGroup(), Text('f'))));
	}

	/** CONTROL, green at base BY CONSTRUCTION: the sibling arrow pair the merged arm sits next to was already separate. */
	public function testArrowRestAwareProbeKeepsItsCtor(): Void {
		Assert.equals(
			'IfArrowContinuationFitsWithRest/Group', shapeOf(Doc.IfArrowContinuationFitsWithRest(0, 4, 40, bodyGroup(), Text('f')))
		);
	}

	/** A `BodyGroup` the walk must re-tag to `Group` — the arm's one non-identity rewrite. */
	private static inline function bodyGroup(): Doc {
		return BodyGroup(Text('b'));
	}

	/**
	 * `<ctor of the mapped node>/<ctor of its rebuilt break branch>`. The index holds
	 * for the whole `If*` probe family and only for it: every member ends
	 * `(…, breakDoc, flatDoc)`. It is NOT a general `Doc` accessor — `Fill`'s
	 * second-from-last is its separator (a `Doc`, so the string would still look
	 * plausible) and a one-parameter ctor would index -1.
	 */
	@:access(anyparse.format.wrap.WrapList)
	private static function shapeOf(d: Doc): String {
		final mapped: Doc = WrapList.groupifyInlineBodies(d);
		final params: Array<Any> = Type.enumParameters(mapped);
		final brk: Doc = cast params[params.length - 2];
		return '${Type.enumConstructor(mapped)}/${Type.enumConstructor(brk)}';
	}

}
