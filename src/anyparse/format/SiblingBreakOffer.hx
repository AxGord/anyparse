package anyparse.format;

import anyparse.core.BreakToken;

/**
 * One alternative placement number for a case list's sibling bodies: the width the widest-sibling pre-pass reads once
 * the break `token` names is committed, the way the next rewrite reads that break back from its own source.
 */
typedef SiblingBreakOffer = {
	final width: Int;
	final token: BreakToken;
}
