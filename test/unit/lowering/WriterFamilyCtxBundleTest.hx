package unit.lowering;

import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The family ctx-bundle pin — every `Writer*Lowering` family reaches `WriterLowering`'s
 * build state through ONE bundle, and that bundle carries nothing the family never reads.
 *
 * Seven shape families have left `WriterLowering` as sibling modules whose members are all
 * static. Each needs build state, and each gets it the same way: a ctx-bundle typedef
 * declared beside the family, built once in `WriterLowering`'s constructor, and passed as
 * the first argument. Every one of those modules documents the same claim about it — "the
 * bundle IS the dependency surface" — and nothing enforces it. The compiler checks that the
 * literal and the typedef agree; it has no opinion on whether anyone READS a field.
 *
 * That gap is not cosmetic. The bundle is what the next extraction is priced against: a
 * family whose bundle lists five things looks five-deep coupled to `WriterLowering` whether
 * or not two of them are leftovers from a member that has since moved on again. A dead
 * field also survives the reverse move — fold the family back in and the field silently
 * describes a dependency that was never there.
 *
 * The scan is deliberately COARSE in the same direction as `FmtFlagOwnershipTest`: a field
 * counts as read when `.<name>` appears anywhere in the module outside the typedef, so an
 * unrelated `foo.shape` would keep `shape` alive. Over-approximating "reads it" means the
 * test can fail to notice a dead field; it cannot invent one.
 */
class WriterFamilyCtxBundleTest extends Test {

	private static inline final MACRO_DIR: String = 'src/anyparse/macro';
	private static inline final WRITER_LOWERING: String = 'src/anyparse/macro/WriterLowering.hx';

	/** Below this the typedef bodies were mis-parsed and every per-field assertion would pass vacuously. */
	private static inline final MIN_BUNDLE_FIELDS: Int = 25;

	/** Each family module and the ctx bundle it declares — the seven `WriterLowering` extractions that carry state. */
	private static final EXPECTED_BUNDLES: Map<String, String> = [
		'WriterArrowValueIfLowering' => 'ArrowValueIfCtx',
		'WriterBodyPolicyLowering' => 'BodyPolicyCtx',
		'WriterBraceSymmetryLowering' => 'BraceSymmetryCtx',
		'WriterCtorBlankLowering' => 'CtorBlankCtx',
		'WriterKwRefLowering' => 'KwRefCtx',
		'WriterPrattLowering' => 'PrattLoweringCtx',
		'WriterTriviaStarDispatch' => 'TriviaStarDispatchCtx'
	];

	/**
	 * Every listed family module declares its bundle, and the seven together carry enough
	 * fields that the per-field reading below is answering about real text.
	 *
	 * The leading half is the vacuity guard: a typedef this scan cannot find contributes no
	 * fields, and a scan that finds none would report every module clean.
	 */
	public function testEveryFamilyModuleDeclaresItsCtxBundle(): Void {
		final root: String = CliFixture.repoRoot();
		var total: Int = 0;
		for (module => bundle in EXPECTED_BUNDLES) {
			final fields: Array<String> = bundleFields(root, module, bundle);
			Assert.isTrue(
				fields.length > 0,
				'$MACRO_DIR/$module.hx declares no `typedef $bundle = { … }` with fields - '
				+ 'the family lost its ctx bundle, or the bundle was renamed: update EXPECTED_BUNDLES'
			);
			total += fields.length;
		}
		Assert.isTrue(
			total >= MIN_BUNDLE_FIELDS,
			'the seven ctx bundles parsed as $total field(s) - below $MIN_BUNDLE_FIELDS the '
			+ 'per-field reading in this class would pass vacuously'
		);
	}

	/**
	 * No ctx bundle carries a field its own module never reads.
	 *
	 * The direction that catches a stale dependency surface: a member moves on (or a call is
	 * rewritten to take its answer as an argument) and the field it needed stays in the
	 * bundle, where it goes on claiming a coupling that no longer exists.
	 */
	public function testNoCtxBundleCarriesAFieldItsModuleNeverReads(): Void {
		final root: String = CliFixture.repoRoot();
		for (module => bundle in EXPECTED_BUNDLES) {
			final source: String = moduleSource(root, module);
			final outside: String = sourceOutsideBundle(source, bundle);
			for (field in bundleFields(root, module, bundle))
				Assert.isTrue(
					outside.indexOf('.$field') >= 0,
					'$bundle.$field is never read as `.$field` anywhere in $MACRO_DIR/$module.hx - drop it from the typedef and from the '
					+ 'literal in WriterLowering\'s constructor, or the bundle over-states what this family depends on'
				);
		}
	}

	/**
	 * Every bundle is built ONCE in `WriterLowering`'s constructor, not per call.
	 *
	 * A bundle assembled at each call site would still type-check and still be a bundle; it
	 * would just re-allocate the family's whole dependency surface per invocation, and the
	 * one literal that documents that surface would no longer exist to read.
	 */
	public function testEveryCtxBundleIsBuiltInTheWriterLoweringConstructor(): Void {
		final source: String = File.getContent('${CliFixture.repoRoot()}/$WRITER_LOWERING');
		final ctor: String = writerLoweringConstructor(source);
		Assert.isTrue(ctor.length > 0, 'could not find the `public function new(` body in $WRITER_LOWERING - this test cannot answer');
		for (module => bundle in EXPECTED_BUNDLES) {
			final field: String = bundleFieldName(source, module, bundle);
			Assert.notEquals(
				'', field,
				'$WRITER_LOWERING declares no field of type `$module.$bundle` - '
				+ 'the family bundle is no longer held per `WriterLowering` instance'
			);
			if (field != '')
				Assert.isTrue(
					ctor.indexOf('$field = {') >= 0,
					'`$field` is declared as `$bundle` but is never assigned a literal in the constructor of '
					+ '$WRITER_LOWERING - a bundle assembled per call re-allocates the family\'s whole dependency '
					+ 'surface, and the one literal that documents that surface stops existing'
				);
		}
	}

	/** The field names of `typedef <bundle> = { … }` in the given family module. */
	private function bundleFields(root: String, module: String, bundle: String): Array<String> {
		final body: String = bundleBody(moduleSource(root, module), bundle);
		final out: Array<String> = [];
		for (line in body.split('\n')) {
			final text: String = line.trim();
			final head: String = if (text.startsWith('final '))
				text.substr('final '.length)
			else if (text.startsWith('var '))
				text.substr('var '.length)
			else
				'';
			final colon: Int = head.indexOf(':');
			if (colon <= 0) continue;
			final name: String = head.substring(0, colon).trim();
			if (name != '' && !out.contains(name)) out.push(name);
		}
		return out;
	}

	/** The `{ … }` interior of `typedef <bundle> =`, or `''` when the module declares none. */
	private function bundleBody(source: String, bundle: String): String {
		final marker: Int = source.indexOf('typedef $bundle = {');
		if (marker < 0) return '';
		final open: Int = source.indexOf('{', marker);
		final close: Int = source.indexOf('\n}', open);
		return close < 0 ? '' : source.substring(open + 1, close);
	}

	/** The module source with its own bundle declaration cut out, so a field's own name does not count as a read. */
	private function sourceOutsideBundle(source: String, bundle: String): String {
		final marker: Int = source.indexOf('typedef $bundle = {');
		if (marker < 0) return source;
		final close: Int = source.indexOf('\n}', marker);
		return close < 0 ? source.substring(0, marker) : source.substring(0, marker) + source.substr(close + 2);
	}

	private function moduleSource(root: String, module: String): String {
		return File.getContent('$root/$MACRO_DIR/$module.hx');
	}

	/** The `WriterLowering` field name declared with type `<module>.<bundle>`, or `''` when there is none. */
	private function bundleFieldName(source: String, module: String, bundle: String): String {
		final marker: Int = source.indexOf(': anyparse.macro.$module.$bundle;');
		if (marker < 0) return '';
		final lineStart: Int = source.lastIndexOf('\n', marker) + 1;
		final decl: String = source.substring(lineStart, marker).trim();
		final space: Int = decl.lastIndexOf(' ');
		return space < 0 ? decl : decl.substr(space + 1);
	}

	/** The body of `WriterLowering`'s constructor — from `public function new(` to the first line that closes it. */
	private function writerLoweringConstructor(source: String): String {
		final marker: Int = source.indexOf('public function new(');
		if (marker < 0) return '';
		final close: Int = source.indexOf('\n\t}', marker);
		return close < 0 ? '' : source.substring(marker, close);
	}

}
