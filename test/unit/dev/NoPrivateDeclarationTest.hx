package unit.dev;

import dev.PrivateDeclaration;
import dev.ScrubRow;
import devkit.Result;
import devkit.Summary.Outcome;

/** A checkout that declares nothing private (`ANYPARSE_PRIVATE=none`) can pass the slice gate's `scrub` row without a token list. */
@:nullSafety(Strict)
final class NoPrivateDeclarationTest extends Test {

	private static final VAR: String = 'ANYPARSE_PRIVATE';
	private static final UNCONFIGURED: String = 'scrub-guard: no token list, nothing checked\n';

	private var _before: String = '';

	public function setup(): Void {
		_before = Sys.getEnv(VAR) ?? '';
	}

	public function teardown(): Void {
		Sys.putEnv(VAR, _before);
	}

	@:pin('control')
	@:killer('M-PRIVATE-DECLARED-NEVER')
	public function testADeclaredNothingPrivateLetsAnUnconfiguredScrubRowPass(): Void {
		Sys.putEnv(VAR, 'none');
		Assert.same(Outcome.Skipped(PrivateDeclaration.NOTE), ScrubRow.verdict(run(0, UNCONFIGURED), run(0, '')));
	}

	@:pin('control')
	@:killer('M-PRIVATE-DECLARED-NEVER')
	public function testADeclaredNothingPrivateLetsTheInfraRowSkipForWantOfATree(): Void {
		Sys.putEnv(VAR, 'none');
		Assert.same(Outcome.Skipped(PrivateDeclaration.NOTE), PrivateDeclaration.unlessDeclared('no tree'));
	}

	@:pin('control')
	@:killer('M-PRIVATE-DECLARED-ANY-VALUE')
	public function testAnythingButNoneLeavesTheRowsRefusing(): Void {
		for (value in ['', 'yes', '1', 'None', 'true']) {
			Sys.putEnv(VAR, value);
			Assert.isFalse(PrivateDeclaration.declared(), value);
			Assert.same(Outcome.NotRun('no tree'), PrivateDeclaration.unlessDeclared('no tree'));
			Assert.isTrue(ScrubRow.verdict(run(0, UNCONFIGURED), run(0, '')).match(NotRun(_)), value);
		}
	}

	private static function run(status: Int, err: String): Result {
		return new Result('scrub-guard', {
			status: status,
			out: '',
			err: err,
			failure: '',
			overflowed: false
		});
	}

}
