package anyparse.query;

import anyparse.query.CondDirectives;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * What `CondRegionLiveness.branchStep` answers about one conditional-compilation branch: `live`
 * is three-valued — true when the branch is provably taken, false when provably not, null when
 * some flag outside the define set decides — and `guard` is the same three-valued answer to "is
 * every branch up to and including this one refuted", which is exactly what the NEXT branch of
 * the region needs to know.
 */
typedef CondBranchStep = {
	final live: Null<Bool>;
	final guard: Null<Bool>;
};

/**
 * What a CALLER asserts about a define set: `defined` names the flags it proved set, `undefined`
 * the flags it proved absent. The second half is never derived from a compiler's `Defines:` line
 * — only an operator asking "resolve this file as if X were not defined" can supply it.
 */
typedef DefineFacts = {
	final defined: Array<String>;
	final undefined: Array<String>;
};

private typedef Frame = {
	final open: String;
	var branch: String;
	var live: Null<Bool>;
	var elseGuard: Null<Bool>;
}

private typedef Cursor = {
	var pos: Int;
	var ok: Bool;
}

/**
 * Whether a byte offset in a source file sits in code the compiler PROVABLY compiled,
 * given the defines one compile ran under — the REGION half of the coverage question
 * `OracleCoverage` answers per FILE.
 *
 * ## Why a file's `Parsed` line is not enough
 *
 * A conditional-compilation branch the defines exclude is skipped at lex time, so the
 * file still earns its `Parsed <path>` line while that branch is typechecked by
 * NOTHING. Measured in this repo, whose configured oracle is `test-js.hxml`: a
 * `final _planted: Int = 'not an int';` planted in the native-sys `#elseif sys`
 * branch of `HaxeSpawn.run` leaves `haxe test-js.hxml --no-output` at exit 0, while the
 * identical line in the `#if nodejs` branch above it fails with `String should be Int`.
 * Same file, same compile, opposite answers — and a file-level coverage answer says TRUE
 * for both, while `OracleCoverage.uncovered` grants the first offset and declines the
 * second by name.
 *
 * ## The answer is THREE-valued, and only one direction is ever asserted
 *
 * `evaluate` reads a define set that is POSITIVE-ONLY: a name the compiler listed IS
 * defined, a name it did not list is UNKNOWN — never false. The compiler prints its
 * `Defines:` line before init macros run, and a `--macro define('nodejs')` (which is how
 * hxnodejs defines `nodejs`) lands after it, so absence from the list is not evidence.
 * `!flag` is therefore never provably TRUE for an unlisted flag, `#if sys` on a js
 * compile is UNKNOWN rather than dead, and every unknown answer costs a decline rather
 * than a wrong permission. A comparison (`haxe_ver >= 4.0`) is unknown for the same
 * reason one level down: the set carries names, not values.
 *
 * What IS provable, and what closes the hole above: `#else` after an `#if` whose flag
 * the compiler listed is provably DEAD, because exactly one branch of a region is live.
 *
 * A name a CALLER asserts is undefined is the one exception, and it is
 * opt-in: `evaluateFacts` takes a `DefineFacts` whose `undefined` list makes such a flag
 * provably FALSE. That list can only come from an operator — `apq resolve-define
 * --undefined X` states the hypothesis and signs for it — never from absence in the
 * `Defines:` line a compile prints, which is the unsound reading above. `evaluate` itself
 * stays positive-only: a thin wrapper passing an EMPTY `undefined` list, so every coverage
 * answer derived from it is unchanged.
 *
 * ## Grammar-agnostic
 *
 * The directive vocabulary comes from `RefShape.conditionalIfKeyword` /
 * `conditionalElseKeywords` / `conditionalEndKeyword` through `CondDirectives`, the
 * shared reader — so a grammar declaring no opener scans to nothing and every offset is
 * live by construction. Pure: no filesystem, no process, no parse.
 */
@:nullSafety(Strict)
final class CondRegionLiveness {

	/** The comparison operators a condition may carry between two operands, longest first so `>` never shadows `>=`. */
	private static final COMPARISONS: Array<String> = ['==', '!=', '>=', '<=', '>', '<'];

	/**
	 * The innermost-enclosing region description of the first byte of `spans` that is NOT
	 * provably compiled under `defines`, or null when every byte of every span is — which
	 * includes the common case of a source with no conditional region at all.
	 *
	 * SPANS rather than points, because liveness is decided by the whole rewritten range: an
	 * edit whose two ENDS are in live code can still rewrite the interior of a branch nothing
	 * compiles. `probePoints` turns each span into the offsets that decide it.
	 *
	 * The description is the region's own directive text, ready to quote in a decline:
	 * `` `#if sys` `` for a first branch, `` `#else` of `#if nodejs` `` for a later one.
	 * The OUTERMOST unproven frame is reported when several nest, because an outer branch
	 * that is dead makes every question about its interior moot.
	 */
	public static function unproven(
		source: String, shape: RefShape, spans: Array<Span>, defines: Array<String>, regions: Array<LexRegion>
	): Null<String> {
		if (spans.length == 0) return null;
		final directives: Array<CondDirective> = CondDirectives.scan(source, shape, () -> regions);
		if (directives.length == 0) return null;
		final sorted: Array<Int> = probePoints(spans, directives);
		sorted.sort((a, b) -> a - b);
		final frames: Array<Frame> = [];
		var next: Int = 0;
		// The three sweeps below differ only in where the frontier sits, so the walk is one
		// closure over the shared cursor rather than three copies of it. `gapOf` is asked ONCE
		// per sweep: the stack cannot change while the cursor advances, so every pending point
		// below the frontier shares one answer.
		inline function answerBelow(limit: Int): Null<String> {
			if (next >= sorted.length || sorted[next] >= limit) return null;
			final gap: Null<String> = gapOf(frames);
			if (gap != null) return gap;
			while (next < sorted.length && sorted[next] < limit) next++;
			return null;
		}
		for (directive in directives) {
			// Answered against the state BEFORE this directive: an offset preceding it belongs
			// to whatever branch was open, and the directive is what ends that branch.
			final before: Null<String> = answerBelow(directive.span.from);
			if (before != null) return before;
			apply(frames, source, directive, shape, defines);
			// A point landing INSIDE a directive's own span is not code, so nothing about it is
			// being verified; it is read as the state the directive leaves behind. `probePoints`
			// never produces one — it takes `directive.span.to`, which is past the directive —
			// so this sweep exists for the boundary case where an edit STARTS on a directive.
			final inside: Null<String> = answerBelow(directive.span.to);
			if (inside != null) return inside;
		}
		return answerBelow(sorted[sorted.length - 1] + 1);
	}

	/**
	 * Three-valued evaluation of one conditional-compilation condition against a
	 * positive-only define set: true when the condition provably HOLDS, false when it
	 * provably does not, and null for everything else — an unlisted flag, a comparison, a
	 * condition this does not parse, or trailing text after one it does.
	 *
	 * The grammar is the one `CondDirectives` delimits: `||` over `&&` over a comparison
	 * over unary `!` over a primary (a parenthesised condition, a possibly-dotted flag, a
	 * number, or a quoted string). A flag in `defines` is TRUE and a flag outside it is
	 * UNKNOWN, so no amount of nesting can turn absence into a proof — which is the one
	 * property that makes a permission derived from this sound.
	 */
	public static function evaluate(condition: String, defines: Array<String>): Null<Bool> {
		return evaluateFacts(condition, { defined: defines, undefined: [] });
	}

	/**
	 * `evaluate` against a define set a CALLER states in both directions: a flag in
	 * `facts.defined` is true, a flag in `facts.undefined` is false, and everything else is
	 * unknown exactly as before.
	 *
	 * The negative half is what a write op needs and a coverage question must never have.
	 * `apq resolve-define --undefined X` asks "fold this file as if X were not defined", which
	 * makes absence an ASSERTION the operator signed for rather than something read off a
	 * compiler's output — and only then may `!X` come out true.
	 */
	public static function evaluateFacts(condition: String, facts: DefineFacts): Null<Bool> {
		final cursor: Cursor = { pos: 0, ok: true };
		final value: Null<Bool> = parseOr(condition, cursor, facts);
		skipSpace(condition, cursor);
		return cursor.ok && cursor.pos >= condition.length ? value : null;
	}

	/**
	 * The liveness of one conditional branch whose condition evaluates to `value`, together with the
	 * guard it leaves for its later siblings, given the guard its earlier siblings left.
	 *
	 * One step for all three keywords, which is why it is a function rather than three copies of the
	 * same Kleene arithmetic: an opener is `branchStep(true, value)`, an `#elseif` is
	 * `branchStep(guard, value)`, and a final `#else` is `branchStep(guard, true)` — it is taken
	 * exactly when every earlier branch is refuted, and leaves nothing behind it. `apply` folds it
	 * over the open-region stack for the coverage question above; `CondQuery` folds the same step over
	 * one region's directives for the report `apq cond` prints, so the two cannot disagree about which
	 * branch a define selects.
	 */
	public static function branchStep(guard: Null<Bool>, value: Null<Bool>): CondBranchStep {
		return { live: andOf(guard, value), guard: andOf(guard, notOf(value)) };
	}

	/** One directive's condition evaluated, or unknown when it carries none the reader could delimit. */
	public static function conditionValue(source: String, directive: CondDirective, defines: Array<String>): Null<Bool> {
		return conditionValueFacts(source, directive, { defined: defines, undefined: [] });
	}

	/** `conditionValue` under a define set stated in both directions — the `evaluateFacts` entry for one directive. */
	public static function conditionValueFacts(source: String, directive: CondDirective, facts: DefineFacts): Null<Bool> {
		final span: Null<Span> = directive.condition;
		return span == null ? null : evaluateFacts(source.substring(span.from, span.to), facts);
	}

	/**
	 * The offsets that decide whether every byte of `spans` is live.
	 *
	 * Liveness is piecewise constant — only a directive can change it — so a span is fully
	 * decided by its own start plus one point inside each region it goes on to CROSS. Sampling
	 * the two ENDS instead, which is what the callers used to do, grants an edit that straddles
	 * a whole `#if … #else … #end`: both ends are in live code, the rewritten interior is in a
	 * branch nothing compiles, and the typecheck afterwards cannot object. That is the same
	 * vacuity this class exists to refuse, one level up.
	 */
	private static function probePoints(spans: Array<Span>, directives: Array<CondDirective>): Array<Int> {
		final points: Array<Int> = [];
		for (span in spans) {
			points.push(span.from);
			// `span.to` is EXCLUSIVE, so a directive starting exactly there is outside the edit;
			// and the point taken is just past the directive, which is inside the branch it opens.
			for (directive in directives) if (directive.span.from > span.from && directive.span.from < span.to)
				points.push(directive.span.to);
		}
		return points;
	}

	/** Three-valued negation: an unknown operand stays unknown. */
	private static function notOf(value: Null<Bool>): Null<Bool> {
		return value == null ? null : !value;
	}

	/** Three-valued conjunction: false wins over unknown, and true needs BOTH proved. */
	private static function andOf(left: Null<Bool>, right: Null<Bool>): Null<Bool> {
		if (left != null && !left || right != null && !right) return false;
		return left != null && left && right != null && right ? true : null;
	}

	/** Three-valued disjunction: true wins over unknown, and false needs BOTH refuted. */
	private static function orOf(left: Null<Bool>, right: Null<Bool>): Null<Bool> {
		if (left != null && left || right != null && right) return true;
		return left != null && !left && right != null && !right ? false : null;
	}

	/** The outermost open branch that is not proved live, described for a decline, or null when every one of them is. */
	private static function gapOf(frames: Array<Frame>): Null<String> {
		for (frame in frames) {
			final live: Null<Bool> = frame.live;
			if (live == null || !live) return frame.branch == frame.open ? '`${frame.open}`' : '`${frame.branch}` of `${frame.open}`';
		}
		return null;
	}

	/**
	 * Fold one directive into the open-region stack. An `#end` closes the innermost region,
	 * an opener pushes a new one, and a branch keyword re-decides the innermost one's
	 * liveness against the guard its earlier branches left.
	 *
	 * A stray branch or closer with no open region is IGNORED rather than treated as an
	 * error: this reads sources the grammar may not even parse, and a lone `#end` must not
	 * make the rest of the file answer differently from the rest of the region.
	 */
	private static function apply(
		frames: Array<Frame>, source: String, directive: CondDirective, shape: RefShape, defines: Array<String>
	): Void {
		final text: String = CondDirectives.text(source, directive);
		if (directive.keyword == shape.conditionalEndKeyword) {
			if (frames.length > 0) frames.pop();
			return;
		}
		if (directive.keyword == shape.conditionalIfKeyword) {
			final step: CondBranchStep = branchStep(true, conditionValue(source, directive, defines));
			frames.push({
				open: text,
				branch: text,
				live: step.live,
				elseGuard: step.guard
			});
			return;
		}
		if (frames.length == 0) return;
		final frame: Frame = frames[frames.length - 1];
		frame.branch = text;
		// Decided by the KEYWORD, never by a null condition span. `CondDirective.condition` is
		// null for two different facts — a keyword that takes none (`#else`) and a
		// condition-bearing keyword whose tail the reader could not delimit (`#elseif (` with the
		// condition continuing on the next line, which parses) — and reading the second as the
		// first declares that branch live whenever the opener is provably false, granting a
		// region the compiler compiles only under a condition nobody read.
		final ifKeyword: Null<String> = shape.conditionalIfKeyword;
		if (ifKeyword == null || !CondDirectives.takesCondition(directive.keyword, ifKeyword, shape.conditionalEndKeyword)) {
			// The final `#else`: live exactly when every earlier branch is refuted, and nothing
			// can follow it.
			final elseStep: CondBranchStep = branchStep(frame.elseGuard, true);
			frame.live = elseStep.live;
			frame.elseGuard = elseStep.guard;
			return;
		}
		// Unknown when the condition could not be delimited, which `conditionValue` answers for a
		// null span — the conservative half of the pair above.
		final step: CondBranchStep = branchStep(frame.elseGuard, conditionValue(source, directive, defines));
		frame.live = step.live;
		frame.elseGuard = step.guard;
	}

	/** `&&` over `||`: the disjunction level, lowest precedence. */
	private static function parseOr(text: String, cursor: Cursor, facts: DefineFacts): Null<Bool> {
		var value: Null<Bool> = parseAnd(text, cursor, facts);
		while (cursor.ok && matchOperator(text, cursor, '||')) value = orOf(value, parseAnd(text, cursor, facts));
		return value;
	}

	/** The conjunction level. */
	private static function parseAnd(text: String, cursor: Cursor, facts: DefineFacts): Null<Bool> {
		var value: Null<Bool> = parseCompare(text, cursor, facts);
		while (cursor.ok && matchOperator(text, cursor, '&&')) value = andOf(value, parseCompare(text, cursor, facts));
		return value;
	}

	/**
	 * The comparison level. A comparison PARSES — so the condition around it is not refused
	 * as malformed — and evaluates to unknown: the define set carries names, not the values
	 * a `haxe_ver >= 4.0` would need.
	 */
	private static function parseCompare(text: String, cursor: Cursor, facts: DefineFacts): Null<Bool> {
		final left: Null<Bool> = parseUnary(text, cursor, facts);
		if (!cursor.ok) return null;
		skipSpace(text, cursor);
		final comparison: Null<String> = comparisonAt(text, cursor.pos);
		if (comparison == null) return left;
		cursor.pos += comparison.length;
		// The right operand is parsed for its POSITION, not its value: consuming it is what keeps
		// the enclosing condition on grammar, and its value could not change an unknown anyway.
		parseUnary(text, cursor, facts); // noqa: unused-return-value
		return null;
	}

	/** The unary level: any run of `!` prefixes, then a primary. */
	private static function parseUnary(text: String, cursor: Cursor, facts: DefineFacts): Null<Bool> {
		skipSpace(text, cursor);
		if (cursor.pos >= text.length || text.fastCodeAt(cursor.pos) != '!'.code) return parsePrimary(text, cursor, facts);
		cursor.pos++;
		return notOf(parseUnary(text, cursor, facts));
	}

	/** A parenthesised condition, a possibly-dotted flag, a number, or a quoted string. */
	private static function parsePrimary(text: String, cursor: Cursor, facts: DefineFacts): Null<Bool> {
		skipSpace(text, cursor);
		if (cursor.pos >= text.length) {
			cursor.ok = false;
			return null;
		}
		final code: Int = text.fastCodeAt(cursor.pos);
		if (code == '('.code) {
			cursor.pos++;
			final inner: Null<Bool> = parseOr(text, cursor, facts);
			skipSpace(text, cursor);
			if (cursor.ok && cursor.pos < text.length && text.fastCodeAt(cursor.pos) == ')'.code) {
				cursor.pos++;
				return inner;
			}
			cursor.ok = false;
			return null;
		}
		if (CondDirectives.isIdentStart(code)) {
			final from: Int = cursor.pos;
			cursor.pos = flagEnd(text, cursor.pos);
			// The one asymmetry `evaluate` rests on: a listed flag is PROVED, an unlisted one is
			// unknown. Reading absence as `false` would let `#if !nothing_special` claim a region
			// the compiler may never have compiled. A flag the CALLER put in `facts.undefined` is
			// the one way to get a `false` here, and no compile output can produce that list.
			final flag: String = text.substring(from, cursor.pos);
			return if (facts.defined.contains(flag))
				true;
			else if (facts.undefined.contains(flag))
				false;
			else
				null;
		}
		if (code == '"'.code || code == '\''.code) {
			cursor.pos = quotedEnd(text, cursor.pos);
			if (cursor.pos < 0) cursor.ok = false;
			return null;
		}
		if (code >= '0'.code && code <= '9'.code) {
			cursor.pos = numberEnd(text, cursor.pos);
			return null;
		}
		cursor.ok = false;
		return null;
	}

	/** Consume `wanted` when it sits at the cursor (after spaces), reporting whether it did. */
	private static function matchOperator(text: String, cursor: Cursor, wanted: String): Bool {
		skipSpace(text, cursor);
		if (text.substr(cursor.pos, wanted.length) != wanted) return false;
		cursor.pos += wanted.length;
		return true;
	}

	/** The comparison operator at `at`, longest first so `>` never shadows `>=`, or null. */
	private static function comparisonAt(text: String, at: Int): Null<String> {
		return COMPARISONS.find(candidate -> text.substr(at, candidate.length) == candidate);
	}

	/** The end of the possibly-dotted flag whose first character sits at `at`; a dot not followed by an identifier start ends it. */
	private static function flagEnd(text: String, at: Int): Int {
		var i: Int = at;
		while (true) {
			while (i < text.length && CondDirectives.isIdentChar(text.fastCodeAt(i))) i++;
			if (i + 1 >= text.length || text.fastCodeAt(i) != '.'.code) return i;
			if (!CondDirectives.isIdentStart(text.fastCodeAt(i + 1))) return i;
			i += 2;
		}
	}

	/** The index just past the string literal opening at `at`, or -1 when it is unterminated. */
	private static function quotedEnd(text: String, at: Int): Int {
		final quote: Int = text.fastCodeAt(at);
		var i: Int = at + 1;
		while (i < text.length) {
			final code: Int = text.fastCodeAt(i);
			if (code == '\\'.code) {
				i += 2;
				continue;
			}
			if (code == quote) return i + 1;
			i++;
		}
		return -1;
	}

	/** The end of the digit-and-dot run starting at `at`. */
	private static function numberEnd(text: String, at: Int): Int {
		var i: Int = at;
		while (i < text.length) {
			final code: Int = text.fastCodeAt(i);
			if ((code < '0'.code || code > '9'.code) && code != '.'.code) return i;
			i++;
		}
		return i;
	}

	/** Advance past spaces and tabs. */
	private static function skipSpace(text: String, cursor: Cursor): Void {
		while (cursor.pos < text.length) {
			final code: Int = text.fastCodeAt(cursor.pos);
			if (code != ' '.code && code != '\t'.code) return;
			cursor.pos++;
		}
	}

}
