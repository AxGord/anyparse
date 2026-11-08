package unit.dev;

import dev.Battery;
import dev.PostLand;
import devkit.Cmd.cmd;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `dev.PostLand.snapshotRefusal` and `wholeLint` over a stand-in engine: how they read `lint-diff`'s exit and rule listing, and which
 * scope the backstop judges with, without a built engine, so a mutation arm can run them.
 */
@:nullSafety(Strict)
final class PostLandSnapshotRefusalStandInTest extends Test {

	private static inline final LISTING: String = '[{"id":"blind","scopeDependent":true}]';

	/** Reports a scope-dependent rule on the land's file; `lint-diff` moves exactly while its `--new` report still holds it. */
	private static final SCOPED_ENGINE: Array<String> = [
		'case "$$1 $$2" in',
		'  "lint --list-rules") echo \'$LISTING\';;',
		'  "lint --format") echo \'[{"file":"test/a/T.hx","rule":"blind","severity":"warning","message":"m"}]\';;',
		'  lint-diff*)',
		'    if grep -q blind "$$5"; then',
		'      printf "lint-diff: 1 added / 0 removed\\n  + test/a/T.hx  blind  m\\n"',
		'      exit 1',
		'    fi',
		'    echo "lint-diff: 0 added / 0 removed";;',
		'esac'
	];

	@:pin('control')
	@:killer('M-POSTLAND-COMPARE-ALWAYS-REFUSES')
	public function testALintDiffOfNothingIsNoRefusal(): Void {
		Assert.isNull(refusalOf('echo "lint-diff: 0 added / 0 removed"'));
	}

	@:pin('control')
	@:killer('M-POSTLAND-COMPARE-NEVER-REFUSES')
	public function testAMovedLintDiffIsARefusalNamingItsRow(): Void {
		Assert.stringContains('+ a.hx  rule', refusalOf('printf "lint-diff: 1 added / 0 removed\\n  + a.hx  rule  m\\n"; exit 1') ?? '');
	}

	@:pin('control')
	@:killer('M-POSTLAND-MALFORMED-SNAPSHOT-PASSES')
	public function testALintDiffThatCouldNotCompareIsRefusedByName(): Void {
		Assert.stringContains('could not compare', refusalOf('echo "no compare" >&2; exit 2') ?? '');
	}

	@:pin('control')
	@:killer('M-POSTLAND-UNREADABLE-LISTING-COMPARES')
	public function testAnUnreadableRuleListingIsRefusedByName(): Void {
		final refusal: String = withEngine("echo 'no listing'", tree -> withReports(tree, ['t.hx'])) ?? '';
		Assert.stringContains('rule listing', refusal);
	}

	@:pin('control')
	@:killer('M-POSTLAND-WHOLE-LINT-WITHOUT-THE-LAND-SCOPE')
	public function testTheBackstopJudgesWithTheLandsOwnScope(): Void {
		Assert.isNull(withEngine(SCOPED_ENGINE.join('\n'), wholeLintRefusal));
	}

	private static function wholeLintRefusal(tree: String): Null<String> {
		final sha: String = landedCommit(tree);
		final cache: String = Path.join([tree, 'cache']);
		FileSystem.createDirectory(cache);
		File.saveContent(Path.join([cache, '${Battery.keyOf(tree, sha) ?? sha}-anyparse.json']), '[]');
		return switch PostLand.wholeLint(tree, sha, cache, tree) {
			case Passed: null;
			case verdict: Std.string(verdict);
		}
	}

	/** Two commits changing one file, so `<sha>^` answers the land's change; the stand-in engine stays untracked. */
	private static function landedCommit(tree: String): String {
		final file: String = Path.join([tree, 'test/a/T.hx']);
		FileSystem.createDirectory(Path.directory(file));
		cmd('git init -q -b main').at(tree).check();
		for (body in ['class T {}\n', 'class T { }\n']) {
			File.saveContent(file, body);
			cmd('git add test').at(tree).check();
			cmd('git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m land').at(tree).check();
		}
		return cmd('git rev-parse HEAD').at(tree).run().out.trim();
	}

	private static function refusalOf(lintDiff: String): Null<String> {
		return withEngine('case "$$1" in\n  lint-diff) $lintDiff;;\n  *) echo \'$LISTING\';;\nesac', tree -> withReports(tree, ['t.hx']));
	}

	private static function withEngine(script: String, body: String -> Null<String>): Null<String> {
		return TempDir.with(dir -> {
			final tree: String = dir.file('tree');
			FileSystem.createDirectory(Path.join([tree, 'bin']));
			File.saveContent(Path.join([tree, 'bin/hxq']), '$script\n');
			File.saveContent(Path.join([tree, 'bin/apq.js']), '');
			return body(tree);
		});
	}

	private static function withReports(tree: String, scope: Array<String>): Null<String> {
		final recorded: String = Path.join([tree, 'recorded.json']);
		final truth: String = Path.join([tree, 'truth.json']);
		File.saveContent(recorded, '[]');
		File.saveContent(truth, '[]');
		return PostLand.snapshotRefusal(tree, recorded, truth, scope);
	}

}
