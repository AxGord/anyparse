package unit.dev;

import dev.ScrubGuard;
import devkit.Args.UsageError;
import devkit.Cmd.cmd;
import devkit.TempDir;
import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * `dev scrub-guard` over a SYNTHETIC list: the real one names what must not be published, so it never enters the
 * repository. What is pinned is the filter-repo list format, the row each match prints, and the two scan modes.
 */
@:nullSafety(Strict)
final class ScrubGuardTest extends Test {

	/**
	 * Every line shape of a filter-repo replace-text file: a plain literal with its replacement, a `literal:` one with a
	 * CRLF ending, a `regex:` one with a lookbehind, a blank line (no rule), an inline-flag regex, and a last line with
	 * no line break. No rule can match inside a commit hash, which the range mode scans with the messages.
	 */
	private static inline final LIST: String = 'alpha==>X\nliteral:be.ta\r\nregex:(?<=x)y+==>c\n\nregex:(?i)gam\nend';

	public function testEveryLineShapeOfTheListIsARule(): Void {
		final rules: Array<Rule> = ScrubGuard.loadRules(LIST);
		Assert.equals(5, rules.length, 'the blank line is no rule, and the rules after it are numbered without it');
		Assert.same(Literal('alpha'), rules[0], 'only the left-hand side of `==>` is read');
		Assert.same(Literal('be.ta'), rules[1], 'the `literal:` prefix and the line end are dropped');
		Assert.same(Literal('end'), rules[4]);
	}

	public function testRowsGoRuleByRuleEachInTextOrder(): Void {
		final data: String = 'alpha\nxbe.ta beXta xyyy\nGAM end\nalphaalpha';
		Assert.same([
			'f:1: rule 1',
			'f:4: rule 1',
			'f:4: rule 1',
			'f:2: rule 2',
			'f:2: rule 3',
			'f:3: rule 4',
			'f:3: rule 5'
		], ScrubGuard.scan('f', data, ScrubGuard.loadRules(LIST)));
	}

	/** A pattern that can match nothing moves on by one character, as Python's `finditer` does, instead of standing still. */
	public function testAnEmptyMatchMovesOn(): Void {
		Assert.same(['f:1: rule 1', 'f:1: rule 1', 'f:2: rule 1'], ScrubGuard.scan('f', 'a\n', ScrubGuard.loadRules('regex:x*')));
	}

	public function testARegexJavaScriptCannotCompileIsRefusedByNumber(): Void {
		final list: String = 'ok\nregex:(?P<n>a)';
		final refused: Null<UsageError> = try {
			Assert.fail('accepted ${ScrubGuard.loadRules(list).length} rule(s)');
			null;
		} catch (e: UsageError) e;
		Assert.notNull(refused);
		if (refused != null) Assert.isTrue(refused.message.indexOf('rule 2') >= 0, refused.message);
	}

	/** The tree mode reads tracked files only, skips a binary one, and names each file relative to the root. */
	public function testTreeAndRangeModes(): Void {
		TempDir.with(dir -> {
			final root: String = dir.file('repo');
			FileSystem.createDirectory('$root/sub');
			cmd('git init -q $root').check();
			File.saveContent('$root/a.txt', 'one\nalpha\n');
			final binary: Bytes = Bytes.ofString('\x00alpha');
			File.saveBytes('$root/bin.dat', binary);
			File.saveContent('$root/sub/b.txt', 'be.ta');
			File.saveContent('$root/untracked.txt', 'alpha');
			cmd('git -C $root add a.txt bin.dat sub/b.txt').check();
			commit(root, 'base');
			final rules: Array<Rule> = ScrubGuard.loadRules(LIST);
			Assert.same(['a.txt:2: rule 1', 'sub/b.txt:1: rule 2'], ScrubGuard.scanTree(rules, root));
			File.saveContent('$root/a.txt', 'one\nalpha\nend\n');
			cmd('git -C $root add a.txt').check();
			commit(root, 'alpha in the message');
			final rows: Array<String> = ScrubGuard.scanRange('HEAD~1..HEAD', rules, root);
			Assert.same(['diff HEAD~1..HEAD:1: rule 5', 'messages HEAD~1..HEAD:2: rule 1'], rows, rows.join(' / '));
			Assert.raises(ScrubGuard.scanRange.bind('HEAD', rules, root), UsageError);
		});
	}

	/**
	 * A path that names a file of a private tree is a match, numbered by the tree and never printed: a `./` or `../`
	 * lead is dropped and an extension other than `.hx` counts, while a bare name, a module at the top of a source root,
	 * a path the scanned tree also holds, a longer path ending in a private one and a near miss do not.
	 */
	@:pin('control')
	@:killer('M-SCRUB-PRIVATE-PATH-BLIND')
	public function testAPathOfAPrivateTreeIsAMatch(): Void {
		TempDir.with(dir -> {
			final one: String = dir.file('one');
			final two: String = dir.file('two');
			for (sub in ['$one/src/app', '$one/src/shared', '$two/tools']) FileSystem.createDirectory(sub);
			for (file in [
				'$one/src/app/Secret.hx',
				'$one/src/shared/Common.hx',
				'$one/src/Main.hx',
				'$two/tools/Gen.cfg'
			]) File.saveContent(file, '');
			final root: String = dir.file('repo');
			FileSystem.createDirectory('$root/shared');
			cmd('git init -q $root').check();
			File.saveContent('$root/shared/Common.hx', '');
			File.saveContent('$root/a.md', [
				'see src/app/Secret.hx:12 and `app/Secret.hx`',
				'Secret.hx alone, src/Main.hx, shared/Common.hx',
				'./src/app/Secret.hx then ../app/Secret.hx',
				'x/src/app/Secret.hx, app/Secret.hxml, app/Other.hx',
				'tools/Gen.cfg'
			].join('\n'));
			cmd('git -C $root add a.md shared/Common.hx').check();
			final privates: Array<PathIndex> = [for (tree in [one, two]) new PathIndex(ScrubGuard.privateFiles(tree))];
			Assert.same([
				'a.md:1: private root 1',
				'a.md:1: private root 1',
				'a.md:3: private root 1',
				'a.md:3: private root 1',
				'a.md:5: private root 2'
			], ScrubGuard.scanTree([], root, privates));
		});
	}

	/**
	 * A private checkout counts only what git tracks there — a build's output is not the project's text — and the range
	 * mode reads the private paths of the lines it adds and of its commit messages.
	 */
	public function testAPrivateCheckoutCountsItsTrackedFilesAndTheRangeModeReadsPaths(): Void {
		TempDir.with(dir -> {
			final priv: String = dir.file('private');
			for (sub in ['$priv/app', '$priv/out']) FileSystem.createDirectory(sub);
			cmd('git init -q $priv').check();
			File.saveContent('$priv/app/Kept.hx', '');
			File.saveContent('$priv/out/Built.hx', '');
			cmd('git -C $priv add app/Kept.hx').check();
			Assert.same(['app/Kept.hx'], ScrubGuard.privateFiles(priv));
			final privates: Array<PathIndex> = [new PathIndex(ScrubGuard.privateFiles(priv))];
			final root: String = dir.file('repo');
			cmd('git init -q $root').check();
			File.saveContent('$root/a.txt', 'one\n');
			cmd('git -C $root add a.txt').check();
			commit(root, 'base');
			File.saveContent('$root/a.txt', 'one\nout/Built.hx app/Kept.hx\n');
			cmd('git -C $root add a.txt').check();
			commit(root, 'names app/Kept.hx');
			final rows: Array<String> = ScrubGuard.scanRange('HEAD~1..HEAD', [], root, privates);
			Assert.same(['diff HEAD~1..HEAD:1: private root 1', 'messages HEAD~1..HEAD:2: private root 1'], rows, rows.join(' / '));
		});
	}

	/** A private root that is not a directory is a usage error, refused before anything is scanned. */
	public function testAPrivateRootThatIsNoDirectoryIsRefused(): Void {
		TempDir.with(dir -> Assert.equals(2, ScrubGuard.main(['--private-root', dir.file('absent')])));
	}

	private static function commit(root: String, message: String): Void {
		cmd('git -C $root -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m $message').check();
	}

}
