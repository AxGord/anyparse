package unit;

import anyparse.query.Cli;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * `apq safe-delete` is canonical-gated, so it must read the `hxformat.json`
 * that governs the file it writes — the discovery every sibling writer-emit op
 * does and this one alone skipped.
 *
 * Without it the gate compared a project-canonical file against COMPILED
 * DEFAULTS, so every file a project config formats differently from them was
 * refused with `file is not in canonical form — format it first`, naming as the
 * remedy the command that had just produced that state; `--reformat` then
 * re-canonicalised under the defaults, i.e. de-formatted the file it was asked
 * to edit.
 *
 * The matrix here varies ONE thing — whether the config sits beside the file —
 * over the SAME bytes. `typeHintColonPolicy: "after"` is the discriminator
 * because the compiled default writes `main():Void`, so those bytes are
 * canonical with the config present and drifted without it.
 */
class SafeDeleteFormatConfigCliTest extends Test {

	/** Canonical under `typeHintColonPolicy: "after"`, drifted under the compiled default. */
	private static final AFTER_COLON: String = 'package;\n\nclass P {\n\tpublic static function main(): Void {\n\t\ttrace(1);\n\t}\n\n'
		+ '\tstatic function unusedHelper(): Int {\n\t\treturn 1;\n\t}\n}\n';

	/** Canonical under NEITHER policy — input for the `--reformat` arm, which has to rewrite something. */
	private static final DRIFTED: String = 'package;\n\nclass P {\n    public static function main():Void {\n            trace(1);\n    }\n'
		+ '    static function unusedHelper():Int { return 1; }\n}\n';

	/**
	 * The one-key config that makes the discriminator: `after` writes `main(): Void`, the compiled default `main():Void`.
	 */
	private static final CONFIG: String = '{"whitespace":{"typeHintColonPolicy":"after"}}';

	public function testProjectCanonicalFileIsDeletedUnderItsOwnConfig(): Void {
		#if (sys || nodejs)
		final dir: String = fixture(AFTER_COLON, true);
		Assert.equals(
			0, Cli.run(['safe-delete', '$dir/P.hx', 'unusedHelper', '--scope', dir, '--write']),
			'the discovered config makes these bytes canonical'
		);
		final after: String = File.getContent('$dir/P.hx');
		Assert.isTrue(
			after.indexOf('main(): Void') >= 0 && after.indexOf('unusedHelper') == -1,
			'the member is gone AND the config policy survived the re-emit'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSameBytesWithoutTheConfigStillRefuse(): Void {
		#if (sys || nodejs)
		// CONTROL — green at base BY CONSTRUCTION: with no config beside it this file
		// really is not canonical, so the gate is right to refuse. It is what tells a
		// discovery that reads the file apart from one that hands back a fixed config:
		// a `discoverFormatConfig` stubbed to CONFIG turns this rc 1 into rc 0.
		final dir: String = fixture(AFTER_COLON, false);
		Assert.equals(
			1, Cli.run(['safe-delete', '$dir/P.hx', 'unusedHelper', '--scope', dir, '--write']),
			'no config beside it: the bytes are genuinely drifted'
		);
		Assert.equals(AFTER_COLON, File.getContent('$dir/P.hx'), 'a refused delete writes nothing');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReformatCanonicalisesUnderTheDiscoveredConfig(): Void {
		#if (sys || nodejs)
		// The "makes it worse" half: `--reformat` skips the gate and rewrites the WHOLE
		// file, so a default-config re-emit silently de-formats a project file. One
		// assertion spanning both halves — the deletion and the policy — so neither can
		// be satisfied alone.
		final dir: String = fixture(DRIFTED, true);
		Assert.equals(0, Cli.run([
			'safe-delete',
			'$dir/P.hx',
			'unusedHelper',
			'--scope',
			dir,
			'--reformat',
			'--write'
		]), 'reformat accepts a drifted file');
		final after: String = File.getContent('$dir/P.hx');
		Assert.isTrue(
			after.indexOf('main(): Void') >= 0 && after.indexOf('unusedHelper') == -1,
			'reformat re-canonicalised under the DISCOVERED config, not the compiled default'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTheWrittenFileIsAFixedPointForItsOwnConfig(): Void {
		#if (sys || nodejs)
		// Canonical-OUT, judged by the same config the gate used. Asserted through a
		// SECOND canonical-gated op rather than `fmt --list`, which always exits 0 and
		// would have made this pass with the whole fix reverted.
		final dir: String = fixture(AFTER_COLON, true);
		Assert.equals(0, Cli.run(['safe-delete', '$dir/P.hx', 'unusedHelper', '--scope', dir, '--write']), 'the delete lands');
		Assert.equals(0, Cli.run([
			'add-member',
			'$dir/P.hx',
			'--type',
			'P',
			'static function later(): Int return 2;',
			'--write'
		]), 'the next writer-emit op is not blocked by the file this one wrote');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private function fixture(source: String, withConfig: Bool): String {
		final files: Array<{ name: String, source: String }> = [{ name: 'P.hx', source: source }];
		if (withConfig) files.push({ name: 'hxformat.json', source: CONFIG });
		return CliFixture.writeDir('safedeletecfg', files);
	}
	#end

}
