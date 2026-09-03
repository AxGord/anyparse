package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
#end
import anyparse.query.Cli;
import utest.Assert;
import utest.Test;

/**
 * End-to-end probe for the find-walker `--exit-on-empty` / `--require-match`
 * flag: a walk with zero hits exits non-zero (so a script can reliably confirm
 * a symbol is gone), while the default — no flag — keeps every walk exiting 0
 * for backward compatibility. Drives `Cli.run([...])` against a tmp fixture.
 * Covers every empty signal: `allEntries.length == 0` (refs/uses/lit/cases), `!any`
 * (blast — including its type-not-declared early return — and mentions), and "no edge line
 * rendered" (callers/callees, whose stdout is never blank — the root label is always printed).
 */
class ApqExitOnEmptyCliTest extends Test {

	private static final SRC: String = 'package pkg;\nclass C {\n\tvar used:Int = 1;\n}';

	/** `leaf` is called by nobody and calls nobody; `called` has one in-edge. */
	private static final CALLS: String =
		'package pkg;\nclass C {\n\tfunction caller():Void called();\n\tfunction called():Void {}\n\tfunction leaf():Void {}\n}';

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

	public function testCallersNoEdgesWithFlagExitsNonZero(): Void {
		// `callers` renders the root label even with no in-edges, so its empty signal cannot
		// be "stdout is blank" - it is "no edge line was rendered".
		#if (sys || nodejs)
		final f: String = CliFixture.write('exitempty', CALLS);
		Assert.equals(1, Cli.run(['callers', 'C.leaf', f, '--exit-on-empty']), 'callers honours the flag with no in-edges');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCallersWithEdgesExitsZeroUnderFlag(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('exitempty', CALLS);
		Assert.equals(0, Cli.run(['callers', 'C.called', f, '--exit-on-empty']), 'a resolved caller with the flag still exits 0');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCallersNoEdgesWithoutFlagExitsZero(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('exitempty', CALLS);
		Assert.equals(0, Cli.run(['callers', 'C.leaf', f]), 'no flag keeps exit 0 even with no in-edges');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCalleesNoEdgesWithFlagExitsNonZero(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('exitempty', CALLS);
		Assert.equals(1, Cli.run(['callees', 'C.leaf', f, '--exit-on-empty']), 'callees shares the signal');
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
