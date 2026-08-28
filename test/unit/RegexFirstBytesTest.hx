package unit;

import anyparse.macro.RegexFirstBytes;
import utest.Assert;
import utest.Test;

/**
 * The contract of the first-byte classifier the Alt dispatch guards and the
 * `@:re` terminals' own first-byte reject are both built on.
 *
 * GREEN AT BASE BY CONSTRUCTION: `RegexFirstBytes` does not exist before this
 * slice, so there is no revision of the tree where these assertions run and
 * fail. The guard that makes them worth anything is MUTATION, not a red base —
 * weaken the classifier and every group below flips, and the rest of the suite
 * does not, which is also the measurement of how little else covers it.
 *
 * The reason this needs its own suite rather than riding on the parser's output
 * is that the defect it guards against is SILENT. An answer that MISSES a byte
 * makes a dispatch guard skip a branch whose trial would have matched: the
 * parse still succeeds, down a different branch, and produces a different tree.
 * `testSoundnessAgainstTheRealRegex` is the direct statement of the property —
 * it runs the very `EReg` `Codegen.eregField` builds over every byte 0…127
 * crossed with `PROBE_TAILS`, holds every accepted match's first byte against
 * the claim, and counts the hits per pattern so an entry no probe can reach
 * fails instead of passing vacuously.
 */
@:nullSafety(Strict)
class RegexFirstBytesTest extends Test {

	/**
	 * Highest byte a probe carries, and the highest a claim may hold — the
	 * test-side spelling of `RegexFirstBytes.MAX_BYTE`, which is private.
	 */
	private static inline final MAX_PROBE_BYTE: Int = 0x7F;

	/**
	 * Every `@:re` pattern the shipped grammars declare that this ACCEPTS —
	 * verbatim, so an entry is the exact string `Codegen.eregField` anchors —
	 * plus the two class escapes. The eight it REFUSES are in `REFUSED`, each
	 * in the construct that makes it refuse.
	 */
	private static final CLASSIFIED: Array<{ pattern: String, codes: Array<Int> }> = [
		// HxIntLit — the head that cost the most: a character class, so the
		// pre-slice reader (first byte must be a non-meta literal) refused it
		// and the branch was tried, and threw, on EVERY atom.
		{ pattern: '[0-9](?:_?[0-9])*(?:_?(?:i8|i16|i32|i64|u8|u16|u32|u64))?', codes: digits() },
		// HxFloatLit — a top-level alternation inside a `(?:…)`, two of whose
		// alternatives lead with a digit and one with an escaped dot.
		{
			pattern: '(?:[0-9](?:_?[0-9])*\\.[0-9](?:_?[0-9])*(?:[eE][-+]?[0-9](?:_?[0-9])*)?(?:_?f(?:32|64))?'
				+ '|[0-9](?:_?[0-9])*\\.(?![\\w.])' + '|\\.[0-9](?:_?[0-9])*(?:[eE][-+]?[0-9](?:_?[0-9])*)?(?:_?f(?:32|64))?'
				+ '|[0-9](?:_?[0-9])*[eE][-+]?[0-9](?:_?[0-9])*(?:_?f(?:32|64))?' + '|[0-9](?:_?[0-9])*_?f(?:32|64))',
			codes: ['.'.code].concat(digits())
		},
		// HxIdentLit / HxTypeName / HxWildPath.
		{ pattern: '[A-Za-z_][A-Za-z0-9_]*', codes: identStarts() },
		// HxExprIdentLit — a NEGATIVE LOOKAHEAD leads the pattern. It consumes
		// nothing, so the head is what follows it.
		{ pattern: '(?!(?:if|else|for|while)\\b)[A-Za-z_][A-Za-z0-9_]*', codes: identStarts() },
		// HxFieldNameLit / HxNewTypeName / HxMacroClassName — an OPTIONAL head,
		// so the answer is its byte unioned with the rest of the sequence.
		{ pattern: '\\$?[A-Za-z_][A-Za-z0-9_]*', codes: ['$'.code].concat(identStarts()) },
		// HxVarNameLit — optional head AND a lookahead behind it.
		{ pattern: '\\$?(?!(?:var|final)\\b)[A-Za-z_][A-Za-z0-9_]*', codes: ['$'.code].concat(identStarts()) },
		// HxObjectKeyLit — a TOP-LEVEL alternation, which `^A|B` leaves anchored
		// on its first alternative only. The union is sound because
		// `lowerTerminal` rejects any match starting past the cursor.
		{ pattern: '"[^"]*"|[A-Za-z_][A-Za-z0-9_]*', codes: ['"'.code].concat(identStarts()) },
		// HxErrorMsg — two quoted alternatives, no shared head.
		{ pattern: '"[^"]*"|\'[^\']*\'', codes: ['"'.code, '\''.code] },
		// JBoolLit — bare word alternatives.
		{ pattern: 'true|false', codes: ['f'.code, 't'.code] },
		// JNumberLit — an optional sign in front of a group.
		{ pattern: '-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][-+]?[0-9]+)?', codes: ['-'.code].concat(digits()) },
		// HxHexLit, HxCondEndLit, HxRegexLit, HxMetaName, HxMetaRaw,
		// HxMetaNameTight, HxCondAltRaw — single literal heads, the only shape
		// the pre-slice reader classified. They must keep answering the same
		// thing.
		{ pattern: '0[xX][0-9A-Fa-f](?:_?[0-9A-Fa-f])*(?:_?(?:i8|i16|i32|i64|u8|u16|u32|u64))?', codes: ['0'.code] },
		{ pattern: '#end', codes: ['#'.code] },
		{ pattern: '~/(?:[^/\\\\\n]|\\\\.)*/[a-z]*', codes: ['~'.code] },
		{ pattern: '@:?[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*', codes: ['@'.code] },
		{
			pattern: '@:?[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*' + '(?:\\((?:[^()]|\\((?:[^()]|\\([^()]*\\))*\\))*\\))?',
			codes: ['@'.code]
		},
		{ pattern: '@:?[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*(?=\\()', codes: ['@'.code] },
		{
			pattern: '#else(?:(?:(?!#if|#end)[\\s\\S])*(?:#if(?:(?!#end)[\\s\\S])*#end(?:(?!#if|#end)[\\s\\S])*)*#end'
				+ '|(?:(?!#end)[\\s\\S])*#end)',
			codes: ['#'.code]
		},
		// HxTypeName / HxWildPath / HxNewTypeName — the dotted-path family, the
		// last of them with the optional `$` head.
		{ pattern: '[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*', codes: identStarts() },
		{ pattern: '[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*\\.\\*', codes: identStarts() },
		{ pattern: '\\$?[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*', codes: ['$'.code].concat(identStarts()) },
		// HxDoubleStringLit / JStringLit, and JIntLit.
		{ pattern: '"(?:[^"\\\\]|\\\\.)*"', codes: ['"'.code] },
		{ pattern: '-?(?:0|[1-9][0-9]*)', codes: ['-'.code].concat(digits()) },
		// HxCondSpliceOpLit — a THIRTY-branch top-level alternation whose last
		// branch closes with a lookahead. Nothing else here has that shape, and
		// it is the only entry whose set is mostly punctuation, so it is the one
		// that exercises `byteSetTerms` at many short runs rather than few long
		// ones.
		{
			pattern: '(?:>>>=|>>>|>>=|>>|>=|>|<<=|<<|<=|<|\\?\\?=|\\?\\?|&&=|&&|&=|&|\\|\\|=|\\|\\||\\|=|\\||\\.\\.\\.'
				+ '|==|=>|=|!=|\\+=|\\+|-=|->|-|\\*=|\\*|/=|/|%=|%|\\^=|\\^|(?:is|in)(?![A-Za-z0-9_]))',
			codes: [
				'!'.code, '%'.code, '&'.code, '*'.code, '+'.code, '-'.code, '.'.code, '/'.code, '<'.code, '='.code, '>'.code, '?'.code,
				'^'.code, 'i'.code, '|'.code
			]
		},
		// HxPpCondLit — an erasable literal head in front of a group whose
		// alternatives lead with three different shapes. 65 codes, the widest
		// set any shipped grammar asks for.
		{
			pattern: '!*(?:[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*|[0-9]+'
				+ '|\\((?:[^()]|\\((?:[^()]|\\((?:[^()]|\\([^()]*\\))*\\))*\\))*\\))',
			codes: ['!'.code, '('.code].concat(digits()).concat(identStarts())
		},
		// The two class escapes that expand.
		{ pattern: '\\d+', codes: digits() },
		{ pattern: '\\w+', codes: digits().concat(upper()).concat(['_'.code]).concat(lower()) }
	];

	/**
	 * Patterns that must answer `null`. Each names the reason, and each reason
	 * is a place where guessing would silently narrow the accepted language.
	 */
	private static final REFUSED: Array<{ pattern: String, why: String }> = [
		{ pattern: '(?:[^\'\\\\$]|\\\\.)+', why: 'a negated class is a complement, not a member set' },
		{ pattern: '[^"]*"', why: 'a negated class in head position' },
		{ pattern: '.*', why: '`.` is every character but the line terminators' },
		{ pattern: '[ \\t]*', why: 'the only element is erasable and nothing follows it' },
		{ pattern: '(?:(?!\\*/)[^\\n])*', why: 'an erasable group over a negated class' },
		{ pattern: '(?:(?!#end)[\\s\\S])*#end', why: '`\\s` is an open Unicode set' },
		{ pattern: 'a{0,3}b', why: 'a counted quantifier whose minimum is 0 — reading it wrong would claim only `a`' },
		{ pattern: 'a{2,3}', why: 'and one whose minimum is not, since the reader parses neither' },
		{ pattern: '(?<name>a)b', why: 'a named group is not parsed for its `>`' },
		{ pattern: '(?=a)', why: 'a lookahead with nothing after it matches the empty string' },
		{ pattern: '(a', why: 'an unbalanced group' },
		{ pattern: '[a', why: 'an unterminated class' },
		{ pattern: 'a)b', why: 'a close with no open' },
		{ pattern: 'a|', why: 'an empty alternative matches the empty string' },
		{ pattern: '\\1a', why: 'a backreference' },
		{ pattern: '\\uFFFF', why: 'a code escape this does not decode' },
		{ pattern: '\\', why: 'a dangling escape' },
		{ pattern: '', why: 'an empty pattern' }
	];

	/**
	 * The probe suffixes `testSoundnessAgainstTheRealRegex` appends to every
	 * byte. One of them has to carry each pattern past its first character —
	 * a bare byte would let most patterns fail for a reason that has nothing
	 * to do with the head, and the soundness assertion would then never run
	 * for that pattern at all.
	 *
	 * That vacuity is not hypothetical: the first version of this list carried
	 * `nd` where `end` was meant, and no tail at all began with `x`, so
	 * `#end` and `HxHexLit` — the two entries whose comment says they must keep
	 * answering what the pre-slice reader answered — got ZERO accepted probes
	 * and were green by construction. `testSoundnessAgainstTheRealRegex` now
	 * asserts a hit count per entry, so adding a pattern no tail can reach is
	 * a failure rather than a silence.
	 */
	private static final PROBE_TAILS: Array<String> = [
		'', '0', '9', 'a', 'z', 'A', '_', '.5', '0.5', '"x"', '\'y\'', ':meta', '/x/', 'end', 'rue', 'alse', ')', '\n', 'x0', 's', '.*',
		'a(', 'else#end'
	];

	public function testTheHeadsTheGrammarsDeclare(): Void {
		for (entry in CLASSIFIED) {
			final got: Null<Array<Int>> = RegexFirstBytes.of(entry.pattern);
			Assert.notNull(got, 'unclassified: ${entry.pattern}');
			if (got != null) Assert.same(sorted(entry.codes), got, 'wrong first-byte set for ${entry.pattern}');
		}
	}

	public function testTheHeadsItRefuses(): Void {
		for (entry in REFUSED) Assert.isNull(RegexFirstBytes.of(entry.pattern), 'should have refused (${entry.why}): ${entry.pattern}');
	}

	/**
	 * The property the dispatch guards rest on, checked against the very
	 * `EReg` the codegen builds: whenever the terminal would ACCEPT a probe —
	 * the regex matches AND the match starts at the cursor, which is
	 * `lowerTerminal`'s own acceptance test — the probe's first byte must be in
	 * the claim.
	 *
	 * A classifier that answers a set too NARROW is the silent defect: nothing
	 * fails, a branch is skipped, and the parse takes a different one. This is
	 * the assertion that catches it without waiting for a corpus fixture to
	 * notice.
	 */
	public function testSoundnessAgainstTheRealRegex(): Void {
		for (entry in CLASSIFIED) {
			final claim: Null<Array<Int>> = RegexFirstBytes.of(entry.pattern);
			Assert.notNull(claim, 'unclassified: ${entry.pattern}');
			if (claim == null) continue;
			final re: EReg = new EReg('^' + entry.pattern, '');
			var accepted: Int = 0;
			for (code in 0...MAX_PROBE_BYTE + 1) for (tail in PROBE_TAILS) {
				final probe: String = String.fromCharCode(code) + tail;
				if (!re.match(probe) || re.matchedPos().pos != 0) continue;
				accepted++;
				Assert.isTrue(claim.contains(code), 'accepted "$probe" but ${code} is outside the claim for ${entry.pattern}');
			}
			// Without this the assertion above is VACUOUS for any pattern no
			// probe can satisfy, and the entry passes while checking nothing.
			Assert.isTrue(accepted > 0, 'no probe ever reached a match — add a PROBE_TAILS entry for ${entry.pattern}');
		}
	}

	/**
	 * A head above `MAX_BYTE` is refused, member by member.
	 *
	 * The claim is a BYTE claim, and `Input.charCodeAt` answers a byte where
	 * `Input.substring` — the text the `EReg` runs on — answers decoded
	 * characters. A non-ASCII head would be claimed as its code POINT and seen
	 * by the guard as a UTF-8 lead byte, which is the too-narrow direction, so
	 * the whole answer goes.
	 */
	public function testANonAsciiHeadIsRefused(): Void {
		Assert.isNull(RegexFirstBytes.of('é'), 'a bare non-ASCII literal head');
		Assert.isNull(RegexFirstBytes.of('[aé]x'), 'one non-ASCII member poisons the whole class');
		Assert.isNull(RegexFirstBytes.of('a|é'), 'and one non-ASCII alternative poisons the union');
		Assert.same(['a'.code], RegexFirstBytes.of('[a]x'), 'while the ASCII neighbour is unaffected');
		// The boundary itself: DEL is the last code a guard may carry.
		Assert.same([MAX_PROBE_BYTE], RegexFirstBytes.of(String.fromCharCode(MAX_PROBE_BYTE) + 'x'));
		Assert.isNull(RegexFirstBytes.of(String.fromCharCode(MAX_PROBE_BYTE + 1) + 'x'));
	}

	/** Ranges, a trailing `-`, and an escaped member inside a class. */
	public function testClassMembers(): Void {
		Assert.same(['a'.code, 'b'.code, 'c'.code], RegexFirstBytes.of('[a-c]x'));
		Assert.same(['-'.code, 'a'.code], RegexFirstBytes.of('[a-]x'), 'a trailing `-` is a member, not a range');
		Assert.same(['.'.code, ']'.code], RegexFirstBytes.of('[\\.\\]]x'), 'escaped members, including the closer');
		Assert.isNull(RegexFirstBytes.of('[c-a]x'), 'an inverted range is not a range');
	}

	private static function sorted(codes: Array<Int>): Array<Int> {
		final copy: Array<Int> = codes.copy();
		copy.sort((a, b) -> a - b);
		return copy;
	}

	private static function digits(): Array<Int> {
		return [for (c in '0'.code ... '9'.code + 1) c];
	}

	private static function upper(): Array<Int> {
		return [for (c in 'A'.code ... 'Z'.code + 1) c];
	}

	private static function lower(): Array<Int> {
		return [for (c in 'a'.code ... 'z'.code + 1) c];
	}

	private static function identStarts(): Array<Int> {
		return upper().concat(['_'.code]).concat(lower());
	}

}
