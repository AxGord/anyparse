package unit.dev;

import dev.LandArgs;
import devkit.Args.UsageError;
import utest.Assert;
import utest.Test;

/** `LandArgs` — the command line of `dev land` parses whatever the order of its options and its branch. */
@:nullSafety(Strict)
final class LandArgsTest extends Test {

	public function testTheWarmRecipeParsesBesideTheBranch(): Void {
		final parsed: LandArgs = new LandArgs(['batch/hxqb-S1', '--warm-frozen', 'a', '--warm-infra', 'b', '--warm-frozen', 'c']);
		Assert.equals('batch/hxqb-S1', parsed.branch);
		Assert.same(['a', 'c'], parsed.recipe.frozen);
		Assert.same(['b'], parsed.recipe.infra);
	}

	public function testTheOptionsParseBeforeTheBranchAsWell(): Void {
		final parsed: LandArgs = new LandArgs([
			'--logs',
			'l',
			'--repo',
			'r',
			'--queue',
			'q',
			'--warm-infra',
			'b',
			'batch/hxqb-S1',
			'--no-battery'
		]);
		Assert.equals('batch/hxqb-S1', parsed.branch);
		Assert.equals('l', parsed.logs);
		Assert.equals('r', parsed.repo);
		Assert.equals('q', parsed.queue);
		Assert.same(['b'], parsed.recipe.infra);
		Assert.isTrue(parsed.noBattery);
	}

	public function testEveryOptionOfTheUsageIsReadWhereverTheBranchStands(): Void {
		final parsed: LandArgs = new LandArgs([
			      '-m', 'msg', '--rounds', '2', '--tokens', '9', '--allow-blast', '--snapshot',        '--full', '--allow',            'x', '--resolve',
			'p#k=ours',   'B',  '--queue', 'q',   '--logs', 'l',        '--repo',          'r', '--warm-frozen',       'f', '--warm-infra',         'i'
		]);
		Assert.equals('B', parsed.branch);
		Assert.equals('msg', parsed.message);
		Assert.isTrue(parsed.allowBlast && parsed.snapshot && parsed.full);
		Assert.same(['x'], parsed.allow);
		Assert.same(['p#k=ours'], parsed.resolve);
		Assert.same(['f'], parsed.recipe.frozen);
		Assert.same(['i'], parsed.recipe.infra);
		Assert.equals(2, parsed.trailers.length);
	}

	public function testAnUnknownOptionIsStillRefused(): Void {
		Assert.raises(() -> new LandArgs(['B', '--warm-unknown', 'd']), UsageError);
	}

}
