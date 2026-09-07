package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
#end
import anyparse.query.Cli;
import utest.Assert;
import utest.Test;

/**
 * `apq source <file>` with nothing narrowing the read: REFUSED past a line
 * budget, with the selector menu the reader needed in order to narrow it.
 *
 * `source` is the gate-blessed replacement for `cat`, and with no `--range` /
 * `--select` it behaved exactly like one. Measured on one real session: 7 files,
 * 1270 lines dumped whole, ~100 of them used (≈8%), two files needed nothing at
 * all. On THIS tree the three largest `src` files cost 262 830 / 186 685 /
 * 168 070 bytes of stdout — 617 585 for the three, against 6 994 for the three
 * refusals that replace them.
 *
 * The reason it is a TOOL fix and not a discipline one: `--select` needs a member
 * NAME, and on first contact with a file the only way to learn one was to dump
 * the file. So the refusal hands back the names — `Address.describe`'s canonical,
 * edit-stable selectors, with the line window each one prints, which is the same
 * window `--select` will hand back.
 *
 * "Top-level" is counted in NAMED ANCESTORS, not in Haxe kind names, and
 * one-line nodes are dropped — a grammar-agnostic stand-in for "worth
 * addressing", because the menu has to survive the next grammar. That is what
 * `testTheMenuNamesDeclarationsAndMembersAndNotEveryImport` pins.
 *
 * `testALongUnnarrowedReadIsRefused` is the control: every other case here is
 * about an ESCAPE from the refusal (`--all`, the budget env, a short file), and
 * all of them pass trivially if the refusal never fires.
 */
@:nullSafety(Strict)
class ApqSourceReadGuardCliTest extends Test {

	/**
	 * Members, not lines: `writeClassOf` emits four lines each plus a five-line
	 * header, so this is an 806-line file — comfortably past the 120-line default
	 * budget, and past it by enough that changing the member template cannot
	 * quietly bring the fixture back under.
	 */
	private static inline final LONG_MEMBERS: Int = 200;

	/** Members again: 86 lines, comfortably UNDER the budget. */
	private static inline final SHORT_MEMBERS: Int = 20;

	/**
	 * KILLED by arm `M-SOURCE-READ-GUARD-OFF`, which answers `null` from the
	 * refusal — `source` goes back to printing the whole file at exit 0.
	 */
	@:pin('control')
	@:killer('M-SOURCE-READ-GUARD-OFF')
	public function testALongUnnarrowedReadIsRefused(): Void {
		#if (sys || nodejs)
		final path: String = writeLongClass();
		var code: Int = -1;
		var out: String = '';
		// Both streams captured around ONE run: a second, half-captured invocation
		// would print this very refusal — 60 menu entries of it — into the suite
		// transcript, which is the noise this slice exists to remove.
		final err: String = CliFixture.captureStderr(() -> out = CliFixture.captureStdout(() -> code = Cli.run(['source', path])));
		FileSystem.deleteFile(path);
		Assert.equals(2, code, 'a whole-file read past the budget is a usage error');
		Assert.equals('', out, 'and it prints no source at all');
		#if nodejs
		Assert.stringContains('nothing narrowed the read', err);
		Assert.stringContains('HXQ_SOURCE_MAX_LINES', err);
		Assert.stringContains('--all', err);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** `--all` is the escape, and it prints every line. */
	public function testAllPrintsTheWholeFile(): Void {
		#if (sys || nodejs)
		final path: String = writeLongClass();
		var code: Int = -1;
		final out: String = CliFixture.captureStdout(() -> code = Cli.run(['source', path, '--all']));
		FileSystem.deleteFile(path);
		Assert.equals(0, code);
		#if nodejs
		Assert.stringContains('function member0', out);
		Assert.stringContains('function member${LONG_MEMBERS - 1}', out);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** A file inside the budget reads whole with no flag — the behaviour every short-file caller had. */
	public function testAShortFileStillReadsWhole(): Void {
		#if (sys || nodejs)
		final path: String = writeClassOf(SHORT_MEMBERS);
		var code: Int = -1;
		final out: String = CliFixture.captureStdout(() -> code = Cli.run(['source', path]));
		FileSystem.deleteFile(path);
		Assert.equals(0, code);
		#if nodejs
		Assert.stringContains('function member0', out);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** `HXQ_SOURCE_MAX_LINES` moves the budget, and `0` switches the refusal off entirely. */
	public function testTheBudgetIsConfigurable(): Void {
		#if (sys || nodejs)
		final path: String = writeClassOf(SHORT_MEMBERS);
		final saved: Null<String> = Sys.getEnv('HXQ_SOURCE_MAX_LINES');
		// Captured: a tightened budget REFUSES, and an uncaptured refusal is 20 menu
		// entries in the suite transcript.
		var tightened: Int = -1;
		var disabled: Int = -1;
		var malformed: Int = -1;
		CliFixture.captureStderr(() -> CliFixture.captureStdout(() -> {
			Sys.putEnv('HXQ_SOURCE_MAX_LINES', '5');
			tightened = Cli.run(['source', path]);
			Sys.putEnv('HXQ_SOURCE_MAX_LINES', '0');
			disabled = Cli.run(['source', path]);
			Sys.putEnv('HXQ_SOURCE_MAX_LINES', 'nonsense');
			malformed = Cli.run(['source', path]);
		}));
		Sys.putEnv('HXQ_SOURCE_MAX_LINES', saved ?? '');
		FileSystem.deleteFile(path);
		Assert.equals(2, tightened, 'a 5-line budget refuses the 86-line short fixture');
		Assert.equals(0, disabled, '0 disables the refusal');
		Assert.equals(0, malformed, 'a malformed budget falls back to the default, which this file is under');
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** `--range`, `--select` and `--at` each narrow the read, so none of them meets the refusal. */
	public function testEveryNarrowingFormBypassesTheRefusal(): Void {
		#if (sys || nodejs)
		final path: String = writeLongClass();
		var ranged: Int = -1;
		var selected: Int = -1;
		var positioned: Int = -1;
		CliFixture.captureStdout(() -> {
			ranged = Cli.run(['source', path, '--range', '1:3']);
			selected = Cli.run(['source', path, '--select', 'FnMember:member7']);
			positioned = Cli.run(['source', path, '--at', '1:1']);
		});
		FileSystem.deleteFile(path);
		Assert.equals(0, ranged);
		Assert.equals(0, selected);
		Assert.equals(0, positioned);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/**
	 * The menu is the point of the refusal, so it has to name what a reader would
	 * pick: the type and its members, and NOT the package line or the imports —
	 * which is what dropping one-line nodes buys, without naming a single Haxe
	 * kind.
	 */
	public function testTheMenuNamesDeclarationsAndMembersAndNotEveryImport(): Void {
		#if (sys || nodejs)
		final path: String = writeLongClass();
		final err: String = CliFixture.captureStderr(() -> Cli.run(['source', path]));
		FileSystem.deleteFile(path);
		#if nodejs
		Assert.stringContains('ClassDecl:Long', err);
		Assert.stringContains('FnMember:member7', err);
		Assert.stringContains('lines ', err);
		Assert.isFalse(err.indexOf('ImportDecl:') >= 0, 'a one-line import is not worth addressing: $err');
		Assert.isFalse(err.indexOf('PackageDecl:') >= 0, 'nor is the package line: $err');
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/**
	 * A file that does not parse has no menu to offer, and `source` must still be
	 * the reader of last resort for one — so the refusal names `--range` and
	 * `--all` instead of pretending to a selector.
	 */
	public function testAnUnparseableLongFileIsRefusedWithoutAMenu(): Void {
		#if (sys || nodejs)
		final buf: StringBuf = new StringBuf();
		for (i in 0...LONG_MEMBERS) buf.add('this line $i is not Haxe at all ((( ]]]\n');
		final path: String = CliFixture.writeAs('apq_source_guard_unparseable', 'hx', buf.toString());
		var code: Int = -1;
		final err: String = CliFixture.captureStderr(() -> code = Cli.run(['source', path]));
		var rescued: Int = -1;
		CliFixture.captureStdout(() -> rescued = Cli.run(['source', path, '--all']));
		FileSystem.deleteFile(path);
		Assert.equals(2, code);
		Assert.equals(0, rescued, '--all still reads a skip-parse file whole');
		#if nodejs
		Assert.stringContains('does not parse', err);
		Assert.stringContains('--range', err);
		Assert.isFalse(err.indexOf('--select') >= 0, 'no selector is offered for a file that has none: $err');
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	#if (sys || nodejs)
	/** The 806-line fixture: `LONG_MEMBERS` members plus a package line and an import. */
	private inline function writeLongClass(): String {
		return writeClassOf(LONG_MEMBERS);
	}

	/**
	 * A parseable module holding `count` members, each on its own line, under a
	 * package line and an import — so the menu has one-line nodes to drop and
	 * multi-line ones to keep.
	 */
	private function writeClassOf(count: Int): String {
		final buf: StringBuf = new StringBuf();
		buf.add('package;\n\nimport haxe.Exception;\n\nclass Long {\n');
		for (i in 0...count) buf.add('\tpublic function member$i(): Int {\n\t\treturn $i;\n\t}\n\n');
		buf.add('}\n');
		return CliFixture.writeAs('apq_source_guard', 'hx', buf.toString());
	}
	#end

}
