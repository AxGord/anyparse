package anyparse.macro;

#if macro
/**
 * First-token classification of one Alt branch — produced by
 * `Lowering.branchFirstToken`, consumed by the dispatch guards
 * `Lowering.lowerEnum` wraps each guardable `tryBranch` block in.
 *
 * THE SOUNDNESS INVARIANT every non-`Unknown` classification must
 * uphold: the guard may only skip a branch whose trial would
 * deterministically FAIL WITHOUT CONSUMING INPUT at the current
 * position. A skipped branch is then observationally identical to a
 * failed trial (bar `ctx.recordFail` bookkeeping). Classify as
 * `Unknown` whenever the first consumed token cannot be established
 * with certainty — `Unknown` is the safe default, it merely costs the
 * trial the parser paid before guards existed.
 */
enum BranchFirstToken {

	/**
	 * The branch's first committed token is one of `words`, every one
	 * of them word-shaped (`#?[A-Za-z_][A-Za-z0-9_]*`) and consumed by
	 * a word-boundary-checking `expectKw` / `matchKw`. Guarded by
	 * `peekWord(ctx) == word`, which is EXACTLY `expectKw`'s
	 * acceptance test for a word-shaped keyword: both read the word
	 * boundary as "the maximal ident run ends here".
	 */
	FirstKw(words: Array<String>);

	/**
	 * The branch's first committed token is a literal whose first byte
	 * is one of `codes`. Guarded by a first-byte compare, which is
	 * exactly the first iteration of `matchLit`'s compare loop — so it
	 * is sound for `expectLit` / `matchLit` AND for `expectKw` /
	 * `matchKw`, which begin with the same literal compare and can
	 * only fail harder (word boundary) after it.
	 */
	FirstLit(codes: Array<Int>);

	/** Not provably first-token dispatchable — the branch stays unguarded. */
	Unknown;

}
#end
