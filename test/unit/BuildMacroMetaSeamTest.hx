package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.UnusedPrivate;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.MemberWriteScan;

/**
 * The drift guard between the TWO answers to one question — "does a macro generate this type's
 * members?" — and the last Haxe tag a check still spelled itself.
 *
 * `MemberWriteScan.carriesBuildMacro` matches `@:build` / `@:autoBuild` / `@:genericBuild` as whole
 * metadata tokens. `unused-private`'s leading-run walk asked `AnnotatedDeclScan` for `'@:build'` and
 * nothing else, so a `@:genericBuild` class — built WHOLE per instantiation, its declared members
 * discarded — had its privates deleted by the same `--fix` that spares a `@:build` one. Nothing
 * failed: the two lists simply disagreed, and no test compared them.
 *
 * So compare them here. The grammar publishes the list ONCE (`RefShape.typeBuildMacroMetaNames`),
 * the walk reads it, and every tag of a probe alphabet must get the same answer from the seam and
 * from the text scan. A tag taught to one and not the other fails; a tag added to the seam and not
 * to the alphabet fails too, so the alphabet cannot go stale behind the guard.
 *
 * `retainedDeclMetaName` is the same repair for `@:keep`, pinned end-to-end instead: the tag the
 * grammar names makes `--fix` decline, and a LONGER tag that merely starts with it does not.
 */
class BuildMacroMetaSeamTest extends Test {

	/**
	 * The tags the two answers are compared over — the three real ones plus the near-misses that
	 * have been confused with them (`@:buildXml` is an hxcpp build-file tag with 17 declarations in
	 * the Haxe std, and reading it as `@:build` by prefix is a defect this project already paid for).
	 */
	private static final PROBE_TAGS: Array<String> = [
		'@:build',
		'@:autoBuild',
		'@:genericBuild',
		'@:buildXml',
		'@:coreApi',
		'@:keep',
		'@:keepSub',
		'@:rtti',
		'@:enum',
		'@:op',
		'@:generic',
		'@:final',
		'@:publicFields',
		'@:structInit'
	];

	/** One question, one answer: the grammar's declared list and the text scan agree tag for tag. */
	public function testSeamAndTextScanAgreeOnEveryProbeTag(): Void {
		final names: Array<String> = declaredBuildMacroNames();
		for (tag in PROBE_TAGS)
			Assert.equals(
				MemberWriteScan.carriesBuildMacro('$tag\nclass C {}\n'), names.contains(tag),
				'$tag: the grammar seam and the text scan answer one question differently'
			);
	}

	/** ...and the alphabet the comparison runs over covers everything the grammar declares. */
	public function testEveryDeclaredNameIsInTheProbeAlphabet(): Void {
		for (name in declaredBuildMacroNames())
			Assert.isTrue(PROBE_TAGS.contains(name), '$name is declared by the grammar but absent from the probe alphabet');
	}

	/** Every declared tag reaches the consumer: `unused-private --fix` keeps the dead private under each. */
	public function testEveryDeclaredNameProtectsAPrivateMember(): Void {
		for (name in declaredBuildMacroNames()) Assert.equals(0, deletions(name), '$name does not protect the private member');
	}

	/** And a tag outside the list protects nothing — the walk matches a whole tag name, never a prefix. */
	public function testANearMissTagProtectsNothing(): Void {
		Assert.equals(1, deletions('@:buildXml'), '@:buildXml is an hxcpp build-file tag, not a build macro');
	}

	/** The retained-declaration seam, both directions. */
	public function testTheRetainedTagIsHonouredAndIsNotAPrefixMatch(): Void {
		final keep: Null<String> = new HaxeQueryPlugin().refShape().retainedDeclMetaName;
		Assert.notNull(keep);
		if (keep == null) return;
		Assert.equals(0, deletions(keep), '$keep does not pin the declaration');
		Assert.equals(1, deletions('${keep}Sub'), '${keep}Sub is a different tag and pins nothing');
	}

	/** The grammar's declared build-macro tags; asserted non-empty so no guard here can pass vacuously. */
	private function declaredBuildMacroNames(): Array<String> {
		final names: Array<String> = new HaxeQueryPlugin().refShape().typeBuildMacroMetaNames ?? [];
		Assert.isTrue(names.length > 0, 'the grammar declares no build-macro tag - every guard here would pass vacuously');
		return names;
	}

	/** How many members `unused-private --fix` deletes from a one-dead-private class carrying `tag`. */
	private function deletions(tag: String): Int {
		final src: String = '$tag(M.build()) class C {\n\tprivate function dead() {}\n}';
		final check: UnusedPrivate = new UnusedPrivate();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		return check.fix(src, vs, new HaxeQueryPlugin()).length;
	}

}
