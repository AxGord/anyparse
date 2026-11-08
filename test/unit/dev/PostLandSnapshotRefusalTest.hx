package unit.dev;

import dev.PostLand;
import devkit.TempDir;
import haxe.io.Path;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * `dev.PostLand.snapshotRefusal` over two report files through the built engine: what the whole lint of a landed commit may differ
 * from the recorded report by, given what the land's scoped lint carried by design. Skips without a built engine, so a mutation arm
 * kills the stand-in class and the pure `LintScope.judged` pins instead.
 */
@:nullSafety(Strict)
final class PostLandSnapshotRefusalTest extends Test {

	private static inline final MARKED: String = 'hoist-common-import';
	private static inline final PLAIN: String = 'doc-length';
	private static inline final ANON: String = 'anon-type-dup';

	@:pin('guard')
	public function testTheSameFindingsAtOtherLinesAndAMaskedCountAreNoMovement(): Void {
		if (CliFixture.engineOrSkip() == null) return;
		final recorded: Array<String> = [
			finding('a.hx', ANON, 'anonymous structure { a: Int } written 3 times across 2 files — extract a typedef', 1)
		];
		final truth: Array<String> = [
			finding('a.hx', ANON, 'anonymous structure { a: Int } written 4 times across 3 files — extract a typedef', 9)
		];
		Assert.isNull(refusalOf(recorded, truth, null));
	}

	@:pin('guard')
	public function testAFindingGoneIsRefusedNamingItsFileAndRule(): Void {
		if (CliFixture.engineOrSkip() == null) return;
		final refusal: String = refusalOf([finding('b.hx', PLAIN, 'doc block')], [], null) ?? '';
		Assert.stringContains('b.hx', refusal);
		Assert.stringContains(PLAIN, refusal);
	}

	@:pin('guard')
	public function testAMalformedSnapshotCannotBeCompared(): Void {
		if (CliFixture.engineOrSkip() == null) return;
		final refusal: String = TempDir.with(dir -> {
			final recorded: String = dir.file('recorded.json');
			final truth: String = dir.file('truth.json');
			File.saveContent(recorded, 'not a report');
			File.saveContent(truth, '[]');
			return PostLand.snapshotRefusal(tree(), recorded, truth, null) ?? '';
		});
		Assert.stringContains('could not compare', refusal);
	}

	@:pin('guard')
	public function testAMarkedRulesFixedFindingOnARelintedFileIsNoRefusal(): Void {
		if (CliFixture.engineOrSkip() == null) return;
		Assert.isNull(refusalOf([finding('t.hx', MARKED, 'fixed')], [], ['t.hx']));
	}

	@:pin('guard')
	public function testAMarkedRulesMovedMessageCountOnARelintedFileIsNoRefusal(): Void {
		if (CliFixture.engineOrSkip() == null) return;
		Assert.isNull(refusalOf(
			[finding('t.hx', MARKED, 'read by 2 of 3 module(s)')],
			[finding('t.hx', MARKED, 'read by 2 of 4 module(s)')],
			['t.hx']
		));
	}

	@:pin('guard')
	public function testAnUnmarkedRulesMovementOnARelintedFileIsRefused(): Void {
		if (CliFixture.engineOrSkip() == null) return;
		final refusal: String = refusalOf([finding('t.hx', PLAIN, 'doc block')], [], ['t.hx']) ?? '';
		Assert.stringContains(PLAIN, refusal);
	}

	@:pin('guard')
	public function testAMarkedRulesMovementOutsideTheScopeIsRefused(): Void {
		if (CliFixture.engineOrSkip() == null) return;
		final refusal: String = refusalOf([finding('elsewhere.hx', MARKED, 'gone')], [], ['t.hx']) ?? '';
		Assert.stringContains('elsewhere.hx', refusal);
	}

	@:pin('guard')
	public function testNoScopeComparesEveryRule(): Void {
		if (CliFixture.engineOrSkip() == null) return;
		Assert.stringContains(MARKED, refusalOf([finding('t.hx', MARKED, 'gone')], [], null) ?? '');
		Assert.stringContains(MARKED, refusalOf([finding('t.hx', MARKED, 'gone')], [], []) ?? '');
	}

	private static function refusalOf(recorded: Array<String>, truth: Array<String>, scope: Null<Array<String>>): Null<String> {
		return TempDir.with(dir -> {
			final recordedFile: String = dir.file('recorded.json');
			final truthFile: String = dir.file('truth.json');
			File.saveContent(recordedFile, '[${recorded.join(',')}]');
			File.saveContent(truthFile, '[${truth.join(',')}]');
			return PostLand.snapshotRefusal(tree(), recordedFile, truthFile, scope);
		});
	}

	private static function finding(file: String, rule: String, message: String, line: Int = 1): String {
		return '{"file":"$file","line":$line,"col":1,"severity":"info","rule":"$rule","message":"$message"}';
	}

	private static function tree(): String {
		return Path.removeTrailingSlashes(Sys.getCwd());
	}

}
