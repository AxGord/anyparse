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

	private static function commit(root: String, message: String): Void {
		cmd('git -C $root -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m $message').check();
	}

}
