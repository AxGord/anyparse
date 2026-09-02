package anyparse.grammar.haxe;

import anyparse.query.LexicalRegions.LexRegion;

using StringTools;

/**
 * The HAXE lexer behind `GrammarPlugin.lexicalRegions`: one single-pass scan mapping a
 * source string to its non-code regions, plus the quote / brace / regex walks it is built
 * from. No AST, no `QueryNode`, no parse — just bytes.
 *
 * ## Why it lives HERE
 *
 * Everything in it is Haxe syntax: single-quote interpolation, `${ … }` holes, `~/ … /`
 * literals, `//` and `/* … *\/` comments. It sat in `anyparse.query.LexicalRegions` until
 * this commit, which made a grammar-agnostic package the home of one grammar's lexer —
 * invariant 4 ("a new language is a new package, not a core change"): a second grammar
 * could not answer the same question without editing core code. It now reaches every
 * consumer that holds a plugin through `GrammarPlugin.lexicalRegions(source)`, beside
 * `controlFlowSupport()`.
 *
 * `anyparse.query.LexicalRegions` keeps the region TYPES and the two pure helpers over a
 * region array, which are grammar-agnostic, and one deprecated forwarder for the callers
 * that hold no plugin — its doc lists them.
 *
 * ## Why the scan is correct where a naive one is not
 *
 * Every consumer of `RefactorSupport.collectCommentTokens` — most of the tool — depends on
 * this being right, and for a long time a defect in it only made an occurrence COUNT wrong,
 * which nothing acted on. Then it began gating a DELETE: `skipStringLiteral` mis-paired the
 * quotes of `'${cond ? '// note' : X}'`, the region ended mid-expression, the `//` inside
 * opened a comment region over live source, and `unused-import --fix` removed an import the
 * commented-over line was using (`Type not found : Dep`, compile-proved).
 *
 * ## Why this is still a HAND scanner, measured
 *
 * The standing question was whether the parser could hand this back instead. Both ways were
 * measured over 6784 real sources - this project, the haxe-formatter `.hxtest` corpus, Pony, the
 * haxe-formatter sources and the Haxe 4.3.7 standard library:
 *
 *  - From a full PARSE: REFUSED. 116 of those sources do not parse at all (115 of the corpus
 *    1890, 6.1 %), and this scan is handed RAW source everywhere, with no promise that it
 *    parses: `RefactorSupport.nameBoundInRange` says so in code, falling back to the pure text
 *    scan the moment `classifyOccurrences` reports the file did not parse. Even where the
 *    parse succeeds the tree carries no node for a string literal in
 *    three positions - a conditional-compilation CONDITION, a `#error` message, and a quoted
 *    object-literal KEY, whose text the projection folds into the field node name slot. That is
 *    34 of 1775 parsed corpus sources and 83 of 3340 parsed real-world files. The direction is
 *    uniformly tree-BLIND, never scanner-blind, which is the safe one: an unmasked region costs
 *    a refusal, a missed one costs a delete.
 *  - From a generated LEXICAL-ONLY pass: expressible, NOT built. Every ingredient is already
 *    declarative - `HaxeFormat.lineComment` / `blockComment` are read at macro time into
 *    `FormatReader.commentPatterns`, and the literal terminals carry their own `@:re` - but the
 *    one hard part, finding where a `${ ... }` hole ENDS, is the brace-and-quote balancing that
 *    no declaration expresses and that `skipInterpolationHole` below IS. Measured drift between
 *    this scanner, `CommentInventory.scan` and the parse tree over those 6784 sources: ZERO. A
 *    new macro pass would buy drift-proofing that one test file buys instead.
 *
 * That test file is `unit.LexicalRegionAgreementTest`, and it is the pin the measurement argued
 * for: every outermost literal NODE must be an exactly-equal region here, and this scanner must
 * agree with `CommentInventory.scan` on every comment of every file in the tree. Both historical
 * corruptions above are caught by it - verified by mutation, arms named in that class.
 */
@:nullSafety(Strict)
final class HaxeLexicalRegions {

	/**
	 * Single-pass lexer emitting every non-code region (line/block comment, string
	 * literal, regex literal) with byte offsets. Strings are skipped with
	 * `\`-escape handling, regex literals through `scanRegexLiteral`;
	 * `RefactorSupport.collectCommentTokens` filters this to its comment tokens.
	 *
	 * The regex arm exists because a regex body may legally contain a comment
	 * opener (`~/[\/*]/`), and without it that opener started a phantom block
	 * comment running to EOF - see `scanRegexLiteral` for what that broke.
	 */
	public static function scan(source: String): Array<LexRegion> {
		final out: Array<LexRegion> = [];
		final n: Int = source.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = source.fastCodeAt(i);
			if (c == '"'.code || c == "'".code) {
				final start: Int = i;
				i = skipStringLiteral(source, i, c) + 1;
				out.push({ from: start, to: i, kind: StringLit });
				continue;
			}
			if (c == '~'.code && i + 1 < n && source.fastCodeAt(i + 1) == '/'.code) {
				final regexEnd: Int = scanRegexLiteral(source, i, n);
				if (regexEnd >= 0) {
					out.push({ from: i, to: regexEnd, kind: RegexLit });
					i = regexEnd;
					continue;
				}
			}
			if (c == '/'.code && i + 1 < n) {
				final next: Int = source.fastCodeAt(i + 1);
				if (next == '/'.code) {
					final start: Int = i;
					i += 2;
					while (i < n && source.fastCodeAt(i) != '\n'.code) i++;
					out.push({ from: start, to: i, kind: LineComment });
					continue;
				}
				if (next == '*'.code) {
					final start: Int = i;
					i += 2;
					var closed: Bool = false;
					while (i + 1 < n) {
						if (source.fastCodeAt(i) == '*'.code && source.fastCodeAt(i + 1) == '/'.code) {
							i += 2;
							closed = true;
							break;
						}
						i++;
					}
					if (!closed) i = n;
					out.push({ from: start, to: i, kind: BlockComment });
					continue;
				}
			}
			i++;
		}
		return out;
	}

	/**
	 * Index of the closing `quote` of the string opened at `open`, honouring `\`-escapes and — for the
	 * INTERPOLATING quote — the `${ … }` holes whose contents are code rather than text; the source
	 * length minus one if unterminated (the caller's `i++` then ends the scan).
	 */
	public static function skipStringLiteral(text: String, open: Int, quote: Int): Int {
		final n: Int = text.length;
		final interpolating: Bool = quote == "'".code;
		var i: Int = open + 1;
		while (i < n) {
			final c: Int = text.fastCodeAt(i);
			if (c == '\\'.code) {
				i += 2;
				continue;
			}
			// A `${ … }` hole is CODE, and Haxe lexes it by brace/quote balancing at any depth — so a
			// nested literal of the SAME quote inside one closes nothing. Reading `$` as ordinary text
			// mis-paired the quotes of `'${cond ? '// note' : X}'` and handed the caller a region that
			// ended mid-expression; `scan` then lexed the rest as code, and a `//` or
			// `/*` there opened a comment region over live source. `$$` is the escaped dollar and the
			// unbraced `$name` shorthand carries no nesting, so only `${` needs the walk.
			if (interpolating && c == '$'.code && i + 1 < n) {
				final next: Int = text.fastCodeAt(i + 1);
				if (next == '$'.code) {
					i += 2;
					continue;
				}
				if (next == '{'.code) {
					i = skipInterpolationHole(text, i + 1);
					continue;
				}
			}
			if (c == quote) return i;
			i++;
		}
		return n - 1;
	}

	/** One of the flag letters Haxe accepts after a regex literal's closing `/`. */
	private static inline function isRegexFlag(c: Int): Bool {
		return c == 'g'.code || c == 'i'.code || c == 'm'.code || c == 's'.code || c == 'u'.code;
	}

	/**
	 * Offset just past the `}` closing the interpolation hole whose `{` is at `open`, or the source
	 * length when it is unterminated. Nested braces are counted and a nested string literal is
	 * skipped whole through `skipStringLiteral`, so the two walk arbitrary depth together — the same
	 * mutual balancing Haxe's own lexer does for `'${'a ${'b'}'}'`.
	 */
	private static function skipInterpolationHole(text: String, open: Int): Int {
		final n: Int = text.length;
		var depth: Int = 0;
		var i: Int = open;
		while (i < n) {
			final c: Int = text.fastCodeAt(i);
			if (c == '"'.code || c == "'".code) {
				final close: Int = skipStringLiteral(text, i, c);
				// An unterminated nested literal means the walk has lost the thread — a quote inside a
				// regex or a comment in the hole, which this scanner does not model. Fail CLOSED: hand
				// the caller back the `{` so the outer literal falls back to plain quote pairing rather
				// than swallowing the rest of the file, which would widen a region every consumer reads.
				if (text.fastCodeAt(close) != c) return open;
				i = close + 1;
				continue;
			}
			if (c == '{'.code) {
				depth++;
			} else if (c == '}'.code) {
				depth--;
				if (depth <= 0) return i + 1;
			}
			i++;
		}
		// Unterminated hole — same fail-closed reading.
		return open;
	}

	/**
	 * End offset (exclusive) of the Haxe regex literal opened by `~/` at `open`,
	 * flags included; -1 when it is not terminated on its own line. Matches the
	 * compiler's own lexer: the body runs to the first unescaped `/`, and a
	 * comment OPENER inside it is body text - `haxe` lexes a block-comment
	 * opener right after `~/` as part of the regex too, not as `~` applied to a
	 * comment (verified against the compiler).
	 *
	 * Without this arm the shared region scan opened a phantom block comment at
	 * the comment opener hiding in `~/[\/*]/`: unterminated, so every byte to
	 * EOF counted as comment trivia and real code after the literal became
	 * invisible - a cross-file member rename refused the whole scope, and every
	 * consumer of `RefactorSupport.collectCommentTokens` saw a comment token that is not there.
	 */
	private static function scanRegexLiteral(source: String, open: Int, n: Int): Int {
		final nl: Int = source.indexOf('\n', open + 2);
		final lineEnd: Int = nl < 0 ? n : nl;
		var i: Int = open + 2;
		while (i < lineEnd) {
			final c: Int = source.fastCodeAt(i);
			if (c == '\\'.code) {
				i += 2;
				continue;
			}
			if (c == '/'.code) {
				i++;
				while (i < lineEnd && isRegexFlag(source.fastCodeAt(i))) i++;
				return i;
			}
			i++;
		}
		return -1;
	}

}
