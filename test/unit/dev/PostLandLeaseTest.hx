package unit.dev;

import dev.PostLand;
import dev.Shard;
import devkit.LeaseHistory;
import devkit.TempDir;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/** `dev.PostLand` asks the pool for its suite run with the per-size times its earlier runs left in the lease history. */
@:nullSafety(Strict)
final class PostLandLeaseTest extends Test {

	@:pin('control')
	@:killer('M-POSTLAND-LEASED-HISTORY')
	public function testTheSuiteRunsLeaseCarriesTheCurveOfItsEarlierRuns(): Void {
		TempDir.with(dir -> {
			final history: LeaseHistory = new LeaseHistory(dir.file('h.tsv'));
			for (_ in 0...LeaseHistory.MIN_RUNS) {
				history.record(LeaseHistory.keyOf('post-land fedcba98'), 2, 100 * 1000);
				history.record(LeaseHistory.keyOf('post-land fedcba98'), Shard.DEFAULT_SHARDS, 60 * 1000);
			}
			final words: Array<String> = ['node', 'dev.js'];
			final argv: Array<String> = PostLand.leased(Own('/p/scripts/wf-run', 10), words, 'post-land 0123abcd', history);
			Assert.isTrue(argv.exists(word -> word.startsWith('--est-by-threads=2:100,')));
			Assert.isTrue(argv.contains('--priority=0'));
			final bare: Array<String> = PostLand.leased(Own('/p/scripts/wf-run', 10), words, 'baseline-warm 0123abcd');
			Assert.isFalse(bare.exists(word -> word.startsWith('--est-by-threads')));
		});
	}

}
