package anyparse.check;

import anyparse.check.Check.FixEdit;
import anyparse.check.Check.Violation;
import anyparse.check.LoopScan.IndexedLoopHeader;
import anyparse.check.LoopScan.LoopFileScan;
import anyparse.check.LoopScan.LoopSeams;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberReach;
import anyparse.query.OccurrenceScan;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * What the two ELEMENT-loop rewrites share — `prefer-value-loop` (`for (v in X)`) and `prefer-keyvalue-loop`'s
 * no-opener arm (`for (i => v in X)`), both of which re-spell every `X[i]` of an indexed loop as a binder read
 * once per iteration: the binder name, the splices, and the gates that leave a finding report-only with a
 * `declineReason` saying why. The structural scans both rules also need stay in `LoopScan`.
 */
@:nullSafety(Strict)
final class ElementLoopRewrite {

	/**
	 * The head of the decline note of an element-loop fix refused because the body may run code that
	 * changes the collection (see `reachDecline`); the note continues with what `MemberReach` found.
	 */
	public static inline final SELF_CALL_DECLINE: String =
		'the body runs code that may replace an element or grow the collection while the loop runs';

	/** The decline note of an element-loop fix refused over a comment inside a region a splice would overwrite. */
	public static inline final COMMENT_DECLINE: String = 'a comment sits inside a region the rewrite would overwrite';

	/** The English vowels, for deciding which `…ies` plural came from a `…y` singular. */
	private static inline final VOWELS: String = 'aeiou';

	/** The ending a `…y` singular takes in the plural. */
	private static inline final PLURAL_IES: String = 'ies';

	/** The ending the singular behind an `…ies` plural carries. */
	private static inline final SINGULAR_Y: String = 'y';

	/** The ending a sibilant singular takes in the plural. */
	private static inline final PLURAL_ES: String = 'es';

	/** The ending every other plural takes. */
	private static inline final PLURAL_S: String = 's';

	/** The private-member prefix a derived binder drops. */
	private static inline final UNDERSCORE: String = '_';

	/** The size member an OTHER loop's header is matched by when checking for a nested binder clash. */
	private static inline final LENGTH_MEMBER: String = 'length';

	/** Endings that take `es` rather than a bare `s`, so the singular drops both characters. */
	private static final SIBILANT_PLURALS: Array<String> = ['ses', 'xes', 'zes', 'ches', 'shes'];

	/** Endings that make a word LOOK plural while it is not — `class`, `status`, `axis`. */
	private static final SINGULAR_ENDINGS: Array<String> = ['ss', 'us', 'is'];

	/** A collection name the singularizer will touch: lower camelCase, so a derived binder is one too. */
	private static final COLLECTION_NAME_PATTERN: EReg = ~/^[a-z][A-Za-z0-9_]*$/;

	/** The decline note of an element-loop fix refused because `collection`'s declared type is unknown. */
	public static inline function unresolvedDecline(collection: String): String {
		return 'the type of `$collection` is not resolved, so it is not provably an Array';
	}

	/**
	 * The singular of a plural collection name, or null when no rule applies. An English
	 * identifier convention, so it lives here rather than in the grammar seam: a plural is a
	 * property of how people name collections, not of the language being parsed.
	 *
	 * The plural may be any WORD of a camelCase name, not only its last: `gridLinesVertical` ->
	 * `gridLineVertical`, `itemsById` -> `itemById`. A word ends at the end of the name and before
	 * every character that is not a lower-case letter (an upper-case letter, a digit, an underscore).
	 * The ends are tried from the LAST one back, `singularOfEnding` asked of the prefix each closes,
	 * and the first answer wins with the rest of the name kept verbatim. So a name whose end is a
	 * plural is answered exactly as the whole-name rules always answered it, and a later plural word
	 * beats an earlier one (`pointsLabels` -> `pointsLabel`). Every ending the rules know is lower
	 * case, so a word closing on an upper-case letter is never a plural (`HTTPS`, `useHTTPSList` has
	 * no singular) while an acronym taking a lower-case `s` is (`imageURLs` -> `imageURL`,
	 * `userIDsByName` -> `userIDByName`). Only word ENDS are located, never word starts — the rules
	 * read endings — so a one-letter word needs no case of its own: `pointsX` keeps its `X` (an
	 * upper-case close) and singularizes `points`, and `xs` -> `x` is the whole-name answer.
	 */
	public static function singularOf(name: String): Null<String> {
		if (!COLLECTION_NAME_PATTERN.match(name)) return null;
		var end: Int = name.length;
		while (end > 0) {
			final singular: Null<String> = endsWord(name, end) ? singularOfEnding(name.substring(0, end)) : null;
			if (singular != null) return singular + name.substring(end);
			end--;
		}
		return null;
	}

	/**
	 * The singular of `name` read as a plural at its very end, or null when no rule applies — the
	 * whole-name rules `singularOf` asks of every word end.
	 */
	private static function singularOfEnding(name: String): Null<String> {
		if (name.endsWith(PLURAL_IES)) {
			// A `…y` singular pluralises through a consonant (`property`, `body`); a stem already
			// ending in a vowel had an `…ie` singular, which loses only the `s`.
			final stem: String = name.substring(0, name.length - PLURAL_IES.length);
			return if (stem.length == 0)
				null
			else if (VOWELS.indexOf(stem.charAt(stem.length - 1)) >= 0)
				name.substring(0, name.length - PLURAL_S.length)
			else
				stem + SINGULAR_Y;
		}
		for (suffix in SIBILANT_PLURALS) if (name.endsWith(suffix)) return name.substring(0, name.length - PLURAL_ES.length);
		for (suffix in SINGULAR_ENDINGS) if (name.endsWith(suffix)) return null;
		if (!name.endsWith(PLURAL_S)) return null;
		final stem: String = name.substring(0, name.length - PLURAL_S.length);
		return stem.length == 0 ? null : stem;
	}

	/**
	 * The name a value binder derived from `collection` would take, or why a loop rewrite may not write one.
	 * A candidate spelled ANYWHERE in ACTIVE text inside `scan` (named `where` in the refusal) is refused - a masked
	 * TEXT scan, because a name that occurs only in a `macro` quotation is just as capturable as one in plain code,
	 * while a comment naming it cannot capture anything.
	 *
	 * So is a candidate that an indexed loop ENCLOSING or NESTED in `forNode` would derive too, under either
	 * element-loop rule: every check reads the ORIGINAL source, so both loops would be fixed in one pass and the
	 * inner binder would shadow the outer one for the whole inner body.
	 *
	 * `candidate == collection` is not tested: every `singularOf` answer is strictly shorter than its input.
	 */
	public static function binderFor(
		f: LoopFileScan, forNode: QueryNode, index: String, collection: String, scan: Span, where: String
	): BinderChoice {
		final candidate: Null<String> = singularOf(collection);
		final refusal: Null<String> = if (candidate == null)
			'no singular of `$collection` names the element'
		else if (candidate == index)
			'the element name `$candidate` is the index'
		else if ((f.seams.core.shape.reservedWords ?? []).contains(candidate))
			'the element name `$candidate` is a reserved word'
		else if (OccurrenceScan.referencedInRange(f.source, candidate, scan.from, scan.to, [], f.inert))
			'the element name `$candidate` is already spelled in $where'
		else if (nestingLoopDerives(f.root, forNode, candidate, f))
			'an enclosing or nested indexed loop derives the same element name `$candidate`'
		else
			null;
		return { name: refusal == null ? candidate : null, refusal: refusal };
	}

	/**
	 * The splices that re-spell an indexed loop over its elements: `[for, end of range)` becomes
	 * `header`, then each `X[i]` span becomes `binder`. Empty when a comment sits inside a region a
	 * splice would overwrite. The closing paren and the body lie outside every span, so a braced and
	 * an unbraced body take the same edits.
	 */
	public static function elementReadEdits(
		source: String, forSpan: Span, iterableSpan: Span, header: String, readSpans: Array<Span>, binder: String
	): Array<FixEdit> {
		if (CheckScan.hasCommentMarker(source, forSpan.from, iterableSpan.to)) return [];
		for (span in readSpans) if (CheckScan.hasCommentMarker(source, span.from, span.to)) return [];
		final edits: Array<FixEdit> = [{ span: new Span(forSpan.from, iterableSpan.to), text: header }];
		for (span in readSpans) edits.push({ span: span, text: binder });
		return edits;
	}

	/**
	 * The reach gate of one `fix` call over `file`: a thunk building the file's `MemberReach` on first demand
	 * (memoised on the run's host for the pass), so a fix that never gets past its cheaper gates never builds
	 * a call graph, and where a decline of `rule` is written.
	 */
	public static function gateFor(
		plugin: GrammarPlugin, file: String, source: String, violations: Array<Violation>, rule: String
	): ReachGate {
		var reach: Null<MemberReach> = null;
		return {
			reachOf: () -> {
				final built: MemberReach = reach ?? MemberReach.forRun(plugin, file, source);
				reach = built;
				built;
			},
			file: file,
			violations: violations,
			rule: rule
		};
	}

	/**
	 * Hand `built` on to `out` when the body's reach allows it, else record why not: `prior` (a cheaper gate's
	 * refusal) first, then the reach decline, then the comment decline an empty `built` stands for. The reach
	 * is asked only when every cheaper gate passed.
	 */
	public static function gatedEdits(
		built: Array<FixEdit>, gate: ReachGate, header: IndexedLoopHeader, forSpan: Span, prior: Null<String>, out: Array<FixEdit>
	): Void {
		final reach: Null<String> = built.length == 0 ? null : reachDecline(gate.reachOf(), gate.file, header);
		final edits: Array<FixEdit> = reach == null ? built : [];
		if (edits.length == 0) declineAt(gate.violations, gate.rule, forSpan, prior ?? reach ?? COMMENT_DECLINE);
		for (e in edits) out.push(e);
	}

	/**
	 * Why an element-loop fix is withheld because the loop BODY may change the collection behind the
	 * binder's back, or null when `MemberReach` proves it cannot. Such code can replace `X[i]` after the
	 * binder read it, or grow `X`, which an element iterator follows and a once-evaluated `0...X.length`
	 * does not. The body is the entry REGION, so everything it runs counts — calls, constructors, the
	 * accessors of the properties it touches, and whatever the language runs implicitly — as far as the
	 * call graph and `MemberReach`'s whitelist of modelled constructs can show; what they cannot show refuses.
	 */
	public static function reachDecline(reach: MemberReach, file: String, h: IndexedLoopHeader): Null<String> {
		final at: Null<Span> = h.sizeReceiver.span;
		final region: Null<Span> = h.body.span;
		if (at == null || region == null) return SELF_CALL_DECLINE;
		final result: ReachResult = reach.mayMutateNamed(file, h.collection, at, region);
		return switch result {
			case Proven: null;
			case _: '$SELF_CALL_DECLINE: ${reach.explain(result)}';
		};
	}

	/**
	 * Write `reason` on each finding of `rule` spanned exactly at `span` — the per-site note `lint --fix`
	 * prints for a finding whose fix was withheld. `fix` is handed the caller's own violation objects,
	 * so the note reaches the reporter.
	 */
	public static function declineAt(violations: Array<Violation>, rule: String, span: Span, reason: String): Void {
		for (v in violations) {
			final at: Null<Span> = v.span;
			if (v.rule == rule && at != null && at.from == span.from && at.to == span.to) v.declineReason = reason;
		}
	}

	/**
	 * Why an element-loop fix is withheld before the body's reach is asked, or null when nothing withholds
	 * it: no usable binder name, or a container whose declared type is unknown (`typeSource` null). The
	 * order is the order a reader fixes them in; the first applies. `reachDecline` is asked after it.
	 */
	public static function elementDecline(binder: BinderChoice, collection: String, typeSource: Null<String>): Null<String> {
		return if (binder.refusal != null)
			binder.refusal
		else if (typeSource == null)
			unresolvedDecline(collection)
		else
			null;
	}

	/** `name` with every leading underscore dropped — the private-member prefix a binder does not carry. */
	public static function withoutLeadingUnderscores(name: String): String {
		var at: Int = 0;
		while (at < name.length && name.charAt(at) == UNDERSCORE) at++;
		return name.substring(at);
	}

	/**
	 * The body gates both element-loop rewrites share, each on a line of its own: the collection is only
	 * read in length-preserving positions, nothing in the body re-binds the index or the collection (a
	 * nested binder would own the `X[i]` under it, and the over-wide name-slot answer is also what
	 * refuses a body reaching the collection as `this.X`), and no closure mentions the collection — a
	 * closure reads `X[i]` when it RUNS, a binder holds the element of the iteration that made it.
	 */
	public static function bodyAdmitsElementLoop(h: IndexedLoopHeader, source: String, sizeMember: String, core: LoopSeams): Bool {
		if (!LoopScan.usedOnlyAsStableCollection(h.body, h.collection, sizeMember, core)) return false;
		if (LoopScan.bindsName(h.body, h.index, core) || LoopScan.bindsName(h.body, h.collection, core)) return false;
		return !LoopScan.capturedByClosure(h.body, source, h.collection, core);
	}

	/**
	 * Whether an indexed `for` that encloses `loop` or sits inside it derives `candidate` as its own
	 * element name — with its collection's leading underscores dropped, the wider of the two rules'
	 * spellings, so the answer covers a loop either rule may rewrite. Sibling loops never collide: each
	 * binder is scoped to its own loop.
	 */
	private static function nestingLoopDerives(node: QueryNode, loop: QueryNode, candidate: String, f: LoopFileScan): Bool {
		if (f.seams.core.opaqueKinds.contains(node.kind)) return false;
		if (node != loop && nests(node, loop)) {
			final h: Null<IndexedLoopHeader> = LoopScan.indexedHeaderOf(node, f.source, LENGTH_MEMBER, f.seams);
			if (h != null && singularOf(withoutLeadingUnderscores(h.collection)) == candidate) return true;
		}
		return node.children.exists(c -> nestingLoopDerives(c, loop, candidate, f));
	}

	/** Whether a word of `name` ends at `end`: the end of the name, or before a character that is not a lower-case letter. */
	private static inline function endsWord(name: String, end: Int): Bool {
		final next: Int = end < name.length ? name.fastCodeAt(end) : -1;
		return next < 'a'.code || next > 'z'.code;
	}

	/** Whether one of the two nodes' spans contains the other's. */
	private static function nests(a: QueryNode, b: QueryNode): Bool {
		final sa: Null<Span> = a.span;
		final sb: Null<Span> = b.span;
		return sa != null && sb != null && (sa.from <= sb.from && sb.to <= sa.to || sb.from <= sa.from && sa.to <= sb.to);
	}

}

/** What `ElementLoopRewrite.gatedEdits` needs besides the loop: the reach thunk, the file, and where a decline is written. */
typedef ReachGate = {
	var reachOf: () -> MemberReach;
	var file: String;
	var violations: Array<Violation>;
	var rule: String;
}

/**
 * What `ElementLoopRewrite.binderFor` decided: the element binder's name, or null with the `refusal` a
 * report-only finding carries as its `declineReason`. Exactly one of the two is set.
 */
typedef BinderChoice = {
	var name: Null<String>;
	var refusal: Null<String>;
}
