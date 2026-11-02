package unit.dev;

import dev.Dev;
import dev.RuleCode;
import devkit.Cmd.cmd;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/** `dev rule-code`: whether a tree's diff from `merge-base HEAD main` holds code that can move a lint rule's findings. */
@:nullSafety(Strict)
final class RuleCodeTest extends Test {

	private static inline final CLI_FILE: String = 'src/anyparse/query/cli/Cmd.hx';
	private static inline final QUERY_FILE: String = 'src/anyparse/query/Index.hx';
	private static inline final CHECK_FILE: String = 'src/anyparse/check/NewRule.hx';
	private static inline final OUTSIDE_FILE: String = 'tools/Moved.hx';

	public function testAnEmptyDiffTouchesNoRuleCode(): Void {
		TempDir.with(dir -> {
			final repo: String = scaffold(dir);
			Assert.isFalse(RuleCode.answer(repo));
		});
	}

	public function testAQueryCliDiffTouchesNoRuleCode(): Void {
		TempDir.with(dir -> {
			final repo: String = scaffold(dir);
			write(repo, CLI_FILE, 'changed');
			commit(repo);
			Assert.isFalse(RuleCode.answer(repo));
		});
	}

	public function testAQueryFileOutsideCliIsRuleCode(): Void {
		TempDir.with(dir -> {
			final repo: String = scaffold(dir);
			write(repo, QUERY_FILE, 'changed');
			commit(repo);
			Assert.isTrue(RuleCode.answer(repo));
		});
	}

	public function testAnUntrackedNewCheckFileIsRuleCode(): Void {
		TempDir.with(dir -> {
			final repo: String = scaffold(dir);
			write(repo, CHECK_FILE, 'new');
			Assert.isTrue(RuleCode.answer(repo));
		});
	}

	public function testARenameFromOutsideIntoCheckIsRuleCode(): Void {
		TempDir.with(dir -> {
			final repo: String = scaffold(dir);
			FileSystem.createDirectory(Path.join([repo, 'src/anyparse/check']));
			git(repo, ['mv', OUTSIDE_FILE, CHECK_FILE]);
			commit(repo);
			Assert.isTrue(RuleCode.answer(repo));
		});
	}

	public function testADeletedRuleFileAloneTouchesNoRuleCode(): Void {
		TempDir.with(dir -> {
			final repo: String = scaffold(dir);
			FileSystem.deleteFile(Path.join([repo, QUERY_FILE]));
			commit(repo);
			Assert.isFalse(RuleCode.answer(repo));
		});
	}

	public function testASubdirectoryOfAWorkTreeExitsTwo(): Void {
		TempDir.with(dir -> {
			final repo: String = scaffold(dir);
			write(repo, QUERY_FILE, 'changed');
			commit(repo);
			Assert.equals(0, Dev.run(['rule-code', repo]));
			Assert.equals(2, Dev.run(['rule-code', Path.join([repo, 'src'])]));
			Assert.equals(2, Dev.run(['rule-code', Path.join([repo, 'src/anyparse'])]));
		});
	}

	public function testARepositoryWithNoMainBranchExitsTwo(): Void {
		TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			FileSystem.createDirectory(repo);
			git(repo, ['init', '-q', '-b', 'trunk']);
			write(repo, QUERY_FILE, 'base');
			commit(repo);
			Assert.equals(2, Dev.run(['rule-code', repo]));
		});
	}

	public function testATreeThatIsNoRepositoryExitsTwo(): Void {
		TempDir.with(dir -> {
			Assert.equals(2, Dev.run(['rule-code', dir.path]));
			Assert.equals(2, Dev.run(['rule-code']));
		});
	}

	/** A repository on `side` branched from `main`, which holds one file of each kind the predicate tells apart. */
	private static function scaffold(dir: TempDir): String {
		final repo: String = dir.file('repo');
		FileSystem.createDirectory(repo);
		git(repo, ['init', '-q', '-b', 'main']);
		write(repo, CLI_FILE, 'base');
		write(repo, QUERY_FILE, 'base');
		write(repo, OUTSIDE_FILE, 'base');
		commit(repo);
		git(repo, ['checkout', '-q', '-b', 'side']);
		return repo;
	}

	private static function write(repo: String, file: String, content: String): Void {
		final path: String = Path.join([repo, file]);
		FileSystem.createDirectory(Path.directory(path));
		File.saveContent(path, content);
	}

	private static function commit(repo: String): Void {
		git(repo, ['add', '.']);
		git(repo, [
			'-c',
			'user.name=t',
			'-c',
			'user.email=t@t',
			'-c',
			'commit.gpgsign=false',
			'commit',
			'-q',
			'-m',
			'c'
		]);
	}

	private static function git(repo: String, args: Array<String>): Void {
		cmd('git -C $repo $args').run().check();
	}

}
