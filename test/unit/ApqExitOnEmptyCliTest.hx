package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * End-to-end probe for the find-walker `--exit-on-empty` / `--require-match`
 * flag: a walk with zero hits exits non-zero (so a script can reliably confirm
 * a symbol is gone), while the default — no flag — keeps every walk exiting 0
 * for backward compatibility. Drives `Cli.run([...])` against a tmp fixture.
 * Covers both empty signals: `allEntries.length == 0` (refs/uses/lit/cases) and
 * `!any` (blast — including its type-not-declared early return — and mentions).
 */
class ApqExitOnEmptyCliTest extends Test {

	private static final SRC: String = 'package pkg;\nclass C {\n\tvar used:Int = 1;\n}';

	public function testRefsEmptyWithoutFlagExitsZero(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('exitempty', SRC);
		Assert.equals(0, Cli.run(['refs', 'nonexistent', f]), 'no flag keeps exit 0 even with no hits');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRefsEmptyWithFlagExitsNonZero(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('exitempty', SRC);
		Assert.equals(1, Cli.run(['refs', 'nonexistent', f, '--exit-on-empty']), '--exit-on-empty + 0 hits exits non-zero');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRequireMatchAlias(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('exitempty', SRC);
		Assert.equals(1, Cli.run(['refs', 'nonexistent', f, '--require-match']), '--require-match is an alias');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRefsNonEmptyWithFlagExitsZero(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('exitempty', SRC);
		Assert.equals(0, Cli.run(['refs', 'used', f, '--exit-on-empty']), 'a hit with the flag still exits 0');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testUsesEmptyWithFlagExitsNonZero(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('exitempty', SRC);
		Assert.equals(1, Cli.run(['uses', 'NoSuchType', f, '--exit-on-empty']), 'uses honours the flag');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSearchEmptyWithFlagExitsNonZero(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('exitempty', SRC);
		Assert.equals(1, Cli.run(['search', "noSuchCall($x)", f, '--exit-on-empty']), 'search honours the flag');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testLitEmptyWithFlagExitsNonZero(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('exitempty', SRC);
		Assert.equals(1, Cli.run(['lit', 'no_such_literal_xyz', f, '--exit-on-empty']), 'lit honours the flag');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCasesEmptyWithFlagExitsNonZero(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('exitempty', SRC);
		Assert.equals(1, Cli.run(['cases', 'NoSuchCase', f, '--exit-on-empty']), 'cases honours the flag');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testMentionsEmptyWithFlagExitsNonZero(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('exitempty', SRC);
		Assert.equals(1, Cli.run(['mentions', 'nonexistent', f, '--exit-on-empty']), 'mentions honours the flag (!any signal)');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testBlastEmptyEarlyReturnWithFlagExitsNonZero(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('exitempty', SRC);
		// NoSuchType is neither declared nor used → blast's type-not-declared
		// early return; with the flag it must still exit non-zero.
		Assert.equals(1, Cli.run(['blast', 'NoSuchType', f, '--exit-on-empty']), 'blast early return honours the flag');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testBlastNonEmptyWithFlagExitsZero(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('exitempty', SRC);
		Assert.equals(0, Cli.run(['blast', 'Int', f, '--exit-on-empty']), 'blast with a real type use exits 0');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
