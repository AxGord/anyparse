package dev;

import devkit.Args;
import haxe.Exception;

using Lambda;
using StringTools;

/**
 * `dev rule-code <tree>` — the one answer to "does this slice's diff touch rule code": prints `yes` or `no` over the
 * files `tree` changed against `merge-base HEAD main`, judged by the gate's own `GateTree.isRuleCode`, so the orient's claim
 * and the gate's cannot drift apart. A tree that is not the top of a git work tree exits 2: git names changed paths from the
 * top, so a subdirectory would silently answer `no`.
 */
@:nullSafety(Strict)
final class RuleCode {

	public static inline final USAGE: String = 'usage: dev rule-code <tree>';

	public static function main(argv: Array<String>): Int {
		final tree: String = new Args(argv).positionals(['<tree>'])[0];
		Sys.println(answer(tree) ? 'yes' : 'no');
		return 0;
	}

	/** Whether the diff of `tree` against `merge-base HEAD main` holds rule code. */
	public static function answer(tree: String): Bool {
		if (GateTree.gitIn(tree, ['rev-parse', '--show-prefix']).trim() != '')
			throw new Exception('$tree is not the top of a git work tree');
		final base: String = GateTree.gitIn(tree, ['merge-base', 'HEAD', 'main']).trim();
		return GateTree.touchedSince(tree, base).paths.exists(GateTree.isRuleCode);
	}

}
