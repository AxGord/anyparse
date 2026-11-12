package unit.cli;

import anyparse.query.Cli;
#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * An integer a user writes inside a spec piece (`ast --at 1x:2`, `move-elements --range 1x..2`, a `mutation-schema` plan id
 * `1x`) is refused like an integer flag: read whole, never by its leading digits.
 */
@:nullSafety(Strict)
class CliIntSpecPiecesRefuseTrailingTextCliTest extends Test {

	private static final CODE: String = 'class C {\n\tstatic final X: Array<Int> = [1, 2, 3];\n}\n';

	@:killer('M-AST-AT-PREFIX-PARSE')
	@:pin('control')
	public function testAstAtRefusesTrailingTextInTheLine(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('int_piece_ast', CODE);
		var exit: Int = -1;
		CliFixture.captureStderr(() -> exit = Cli.run(['ast', f, '--at', '1x:2']));
		Assert.equals(2, exit, 'a LINE with trailing text is a usage error');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:killer('M-MOVE-RANGE-PREFIX-PARSE')
	@:pin('control')
	public function testMoveElementsRangeRefusesTrailingText(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('int_piece_move', CODE);
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run([
			'move-elements',
			f,
			'2',
			'--range',
			'1x..2',
			'--append',
			'match:[9]',
			'--dry-run'
		]));
		Assert.equals(2, exit, 'a --range bound with trailing text is a usage error');
		Assert.isTrue(err.indexOf('--range') >= 0, 'stderr names the flag: $err');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:killer('M-MUTATION-PLAN-ID-PREFIX-PARSE')
	@:pin('control')
	public function testMutationSchemaPlanIdRefusesTrailingText(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.write('int_piece_plan_src', CODE);
		final plan: String = CliFixture.writeAs('int_piece_plan', 'tsv', '1x\t$f\tVarDecl\t$f\n');
		var exit: Int = -1;
		CliFixture.captureStderr(() -> exit = Cli.run(['mutation-schema', plan]));
		Assert.notEquals(0, exit, 'a plan id with trailing text is refused');
		FileSystem.deleteFile(f);
		FileSystem.deleteFile(plan);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
