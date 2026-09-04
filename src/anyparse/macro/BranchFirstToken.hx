package anyparse.macro;

#if macro
/**
 * First-token classification of one Alt branch — produced by
 * `ParseDispatchLowering.branchFirstToken`, consumed by the dispatch guards
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
	 *
	 * What guarantees the "consumed by a word-boundary-checking"
	 * half — the part that makes the equality exact instead of
	 * over-strict — is the `isWordShaped` implies `endsWithWordChar`
	 * argument spelled out on `ParseDispatchLowering.wordOrByteFirst`, the only
	 * producer of this constructor. Read that before changing either
	 * predicate.
	 */
	FirstKw(words: Array<String>);

	/**
	 * The branch's first committed token is a literal whose first byte
	 * is one of `codes`. Guarded by a first-byte compare, which is
	 * exactly the first iteration of `matchLit`'s compare loop — so it
	 * is sound for `expectLit` / `matchLit` AND for `expectKw` /
	 * `matchKw`, which begin with the same literal compare and can
	 * only fail harder (word boundary) after it.
	 *
	 * "First iteration of the compare loop" is how `matchLit` reads
	 * since the allocation-free rewrite that immediately precedes
	 * these guards; before it, `matchLit` compared a whole substring
	 * at once. The guard would be sound EITHER way — a substring
	 * compare also fails whenever the first byte differs — so this is
	 * a statement about which code the justification points at, not a
	 * dependency the soundness rests on.
	 */
	FirstLit(codes: Array<Int>);

	/** Not provably first-token dispatchable — the branch stays unguarded. */
	Unknown;

}
#end
