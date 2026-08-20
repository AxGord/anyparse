package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.UsingScan.UsingHeader;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a zero-pad LADDER -- a value-position `if` chain that picks a hand-written run of `0`s by
 * digit count -- and writes it as one `lpad` call:
 *
 * ```haxe
 * for (i in 1...145)
 *     items.push(if (i < 10) 'goals3d000$i' else if (i < 100) 'goals3d00$i' else 'goals3d0$i');
 * // ->
 * for (i in 1...145) items.push('goals3d' + '$i'.lpad('0', 4));
 * ```
 *
 * `Severity.Info` -- the input is correct, this is a readability simplification -- and `DefaultOff`,
 * because a project that spells its padding out on purpose should not be nagged.
 *
 * ## The rewrite is exact only inside a range, and that is the whole difficulty
 *
 * `lpad` pads to a FIXED total width; the ladder pads by digit count. The two agree exactly while
 * the value has as many digits as its branch assumes, and disagree the moment it does not:
 *
 * - NEGATIVE: `'$x'` of `-5` is two characters, so the first branch writes `'000-5'` where `lpad`
 *   writes `'00-5'`. Every negative value diverges.
 * - ABOVE THE LADDER'S TOP: the `else` branch keeps prepending its zeros, so a 4-digit value writes
 *   `'01000'` where `lpad` -- already at width -- writes `'1000'`.
 *
 * Measured rather than argued (`--interp` AND `-cpp`, byte-identical): over ladders of 2..4 branches,
 * widths W..W+2, three prefixes and two suffixes, x from -1050 to 10^n+1050 -- 199800 in-range pairs
 * agreed with ZERO divergences, all 56700 negative pairs diverged, and 37836 of 56754 above-top pairs
 * diverged. So the equivalence interval is exactly `0 <= x < 10^n`, n = branch count, and that
 * interval IS the gate.
 *
 * ## The range gate
 *
 * The only range this check can PROVE is a `for` binder over a literal interval: `for (x in a...b)`
 * with `a` and `b` both plain decimal integer literals, `a >= 0` and `b <= 10^n`. Haxe forbids
 * writing a loop binder at all (`Loop variable cannot be modified`), so proving the range at the
 * `for` header proves it at every read inside the body -- no write scan is needed.
 *
 * Two things still have to hold and are checked structurally, not resolved: the binder must not be
 * REDECLARED anywhere in the loop body (a nested `for`, a local, a lambda parameter of the same
 * name), and the ladder's condition subject must be the same identifier as the string's hole. The
 * redeclaration scan refuses on ANY node inside the body carrying the binder's name whose kind is
 * not a plain identifier read -- deliberately wider than the declaration kinds, since a
 * false refusal costs one missed rewrite and a false acceptance costs a wrong one.
 *
 * Outside a provable range the finding is REPORT-ONLY: it names the interval the rewrite would need
 * and emits no edit. A `--fix` run therefore changes exactly the sites whose range is proved.
 *
 * ## The shape it accepts
 *
 * An `if` / `else if` / `else` chain in VALUE position, 2 to 9 branches, whose:
 *
 * - conditions are `x < 10`, `x < 100`, ... -- consecutive powers of ten starting at ten, on one
 *   and the same bare identifier. Any other threshold breaks the digit-band decomposition the
 *   rewrite rests on (`if (x < 20) …` covers one- AND two-digit values, which no fixed width fits);
 * - LAST branch is a real `else`. A chain without one has no value on the tail path;
 * - branch values are single-quoted interpolating strings holding exactly ONE hole, that hole being
 *   the same identifier, with at most one literal segment on each side of it. A double-quoted
 *   literal projects no segments and is refused, as is a `$$` escape (which projects its own node);
 * - leading segments share one base text and a run of `0`s whose length decreases by exactly one per
 *   branch, and trailing segments are identical across branches. The width is `zeros(first) + 1`.
 *
 * The `0`-run is taken greedily off the end of the leading segment, so a base that itself ends in
 * `0` (`'v10'` + `'000'`) still splits consistently -- every branch loses the same base. A segment
 * holding a BACKSLASH is refused rather than split: `'\x30'` ends in a `0` character that is not a
 * zero digit, and a character-level cut there would corrupt the escape.
 *
 * A comment anywhere inside the ladder's span refuses the fix's own site -- the splice would drop it.
 *
 * ## Emission
 *
 * `'<base>' + '$x'.lpad('0', W) + '<suffix>'`, each affix omitted when empty, plus a
 * `using StringTools;` insert when the file lacks one (`UsingScan`, shared with the other
 * static-extension rewrites). A rival `using` that could also supply `lpad` refuses every edit in
 * the file: the inserted one would lose to it and the call would silently retarget.
 *
 * Replacing an `if`-expression with a `+` chain can only ever bind TIGHTER than what it replaces --
 * `if` is the loosest expression form in the grammar -- so no parenthesisation is needed and any
 * parens the source already carried are outside the replaced span.
 *
 * ## Grammar-agnostic
 *
 * Driven by `RefShape.ifExpressionKinds` / `forStmtKind` / `intervalKind` / `ltKind` / `identKind` /
 * `stringInterpIdentKind` / `stringLiteralKinds` / `numericLiteralKinds` plus
 * `CheckScan.STRING_FRAGMENT_KIND`; any unset seam makes the check a no-op. The pad character, the
 * `lpad` name and the `StringTools` module are the language-specific tokens, spelled as constants.
 */
@:nullSafety(Strict)
final class PreferLpad implements Check implements DefaultOff {

	/** This check's stable id, spelled once. */
	private static inline final RULE_ID: String = 'prefer-lpad';

	/** The static-extension module supplying `lpad`. */
	private static inline final STRING_TOOLS_MODULE: String = 'StringTools';

	/** The `StringTools` method padding a string on the left to a fixed width. */
	private static inline final LPAD_METHOD: String = 'lpad';

	/** The character a zero-pad ladder writes, and the one the emitted call pads with. */
	private static inline final PAD_CHAR: String = '0';

	/** The single-quote the emitted interpolating literals carry. */
	private static inline final QUOTE: String = "'";

	/** The interpolation sigil the emitted hole carries. */
	private static inline final HOLE_SIGIL: String = "$";

	/** A segment holding this is refused rather than split -- its trailing `0` may belong to an escape. */
	private static inline final ESCAPE: String = '\\';

	/** The numeric base the ladder's thresholds step through. */
	private static inline final BASE: Int = 10;

	/** Fewer than two branches is not a ladder. */
	private static inline final MIN_BRANCHES: Int = 2;

	/** Nine branches puts the top at 10^9, the last power of ten an `Int` holds. */
	private static inline final MAX_BRANCHES: Int = 9;

	/** A single-binder `for` node has exactly [iterable, body] children. */
	private static inline final FOR_CHILD_COUNT: Int = 2;

	/** An interval node has exactly [low, high] children. */
	private static inline final INTERVAL_CHILD_COUNT: Int = 2;

	/** A ladder link has exactly [condition, value, tail] children -- a chain with no `else` has two. */
	private static inline final LADDER_CHILD_COUNT: Int = 3;

	/** A `<` comparison has exactly [left, right] children. */
	private static inline final CONDITION_CHILD_COUNT: Int = 2;

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a hand-written zero-pad if-ladder over a range-bound Int, replaceable with one lpad call';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<LpadSeams> = readSeams(plugin);
		if (seams == null) return [];
		final s: LpadSeams = seams;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			for (site in sitesOf(tree, s, entry.source)) violations.push({
				file: entry.file,
				span: site.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: messageOf(site)
			});
		}
		return violations;
	}

	/**
	 * Replace each RANGE-PROVED ladder with its `lpad` form, and insert `using StringTools;` when the
	 * file lacks one. A finding whose range is not proved yields no edit -- that is the report-only
	 * half, and it is the reason a `--fix` run can report more findings than it fixes.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<LpadSeams> = readSeams(plugin);
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (seams == null || tree == null) return [];
		final wanted: Map<String, Bool> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) wanted['${span.from}:${span.to}'] = true;
		}
		final edits: Array<{ span: Span, text: String }> = [for (site in sitesOf(tree, seams, source)) if (
			site.proven && wanted.exists('${site.span.from}:${site.span.to}')
		) { span: site.span, text: replacement(site.ladder) }];
		if (edits.length == 0) return edits;
		final header: UsingHeader = UsingScan.headerOf(tree, source, plugin);
		final symbols: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		// A second `using` supplying `lpad` outranks the inserted one, so the rewritten calls would
		// resolve there instead -- refuse the whole file rather than retarget them silently.
		if (UsingScan.conflictingUsing(UsingScan.usingModules(header), STRING_TOOLS_MODULE, LPAD_METHOD, plugin, () -> symbols, []))
			return [];
		if (UsingScan.hasUsingModule(header, STRING_TOOLS_MODULE)) return edits;
		final usingEdit: { span: Span, text: String } = UsingScan.usingInsertEdit(header, STRING_TOOLS_MODULE);
		if (!RefactorSupport.editsOverlapAny([usingEdit], edits)) edits.push(usingEdit);
		return edits;
	}

	/** Bundle the kinds this check reads, or null when one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<LpadSeams> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifExpressionKinds ?? [];
		final stringKinds: Array<String> = shape.stringLiteralKinds ?? [];
		final numericKinds: Array<String> = shape.numericLiteralKinds ?? [];
		if (ifKinds.length == 0 || stringKinds.length == 0 || numericKinds.length == 0) return null;
		final forKind: Null<String> = shape.forStmtKind;
		final intervalKind: Null<String> = shape.intervalKind;
		final ltKind: Null<String> = shape.ltKind;
		final interpIdentKind: Null<String> = shape.stringInterpIdentKind;
		return forKind == null || intervalKind == null || ltKind == null || interpIdentKind == null ? null : {
			ifKinds: ifKinds,
			stringKinds: stringKinds,
			numericKinds: numericKinds,
			forKind: forKind,
			intervalKind: intervalKind,
			ltKind: ltKind,
			identKind: shape.identKind,
			interpIdentKind: interpIdentKind
		};
	}

	/** Every ladder in `tree`, each already carrying the range verdict of the scope it sits in. */
	private static function sitesOf(tree: QueryNode, s: LpadSeams, source: String): Array<LpadSite> {
		final out: Array<LpadSite> = [];
		final env: Map<String, Int> = [];
		collect(tree, env, s, source, out);
		return out;
	}

	/**
	 * Descend `node`, carrying the range binders in scope: entering a `for` over a literal interval
	 * binds its name to the interval's exclusive upper bound, and a body that redeclares the name --
	 * or an interval this check cannot read -- removes the binding instead of narrowing it.
	 */
	private static function collect(node: QueryNode, env: Map<String, Int>, s: LpadSeams, source: String, out: Array<LpadSite>): Void {
		final binder: Null<String> = node.name;
		if (node.kind == s.forKind && binder != null && node.children.length == FOR_CHILD_COUNT) {
			final iterable: QueryNode = node.children[0];
			final body: QueryNode = node.children[1];
			collect(iterable, env, s, source, out);
			final bound: Null<Int> = rangeBound(iterable, s, source);
			final inner: Map<String, Int> = env.copy();
			if (bound != null && !rebinds(body, binder, s))
				inner[binder] = bound;
			else
				inner.remove(binder);
			collect(body, inner, s, source, out);
			return;
		}
		final ladder: Null<LpadLadder> = ladderOf(node, s, source);
		final span: Null<Span> = node.span;
		if (ladder != null && span != null && !CheckScan.hasCommentMarker(source, span.from, span.to)) {
			// Re-bound out of the narrowed locals: a narrowing never reaches an anonymous-structure
			// literal whose field type is non-nullable.
			final at: Span = span;
			final found: LpadLadder = ladder;
			final limit: Null<Int> = env[found.subject];
			out.push({ span: at, ladder: found, proven: limit != null && limit <= found.top });
			return;
		}
		for (child in node.children) collect(child, env, s, source, out);
	}

	/**
	 * The exclusive upper bound of `iterable` when it is a literal `a...b` with `a >= 0`, else null.
	 * A non-literal bound, a negative low bound and a non-decimal spelling all read as "unprovable".
	 */
	private static function rangeBound(iterable: QueryNode, s: LpadSeams, source: String): Null<Int> {
		if (iterable.kind != s.intervalKind || iterable.children.length != INTERVAL_CHILD_COUNT) return null;
		final low: Null<Int> = intLiteral(iterable.children[0], s, source);
		final high: Null<Int> = intLiteral(iterable.children[1], s, source);
		return low != null && high != null && low >= 0 ? high : null;
	}

	/**
	 * Whether `binder` is bound to something else anywhere inside `node`. Any occurrence of the name
	 * that is not a plain identifier read counts -- wider than the declaration kinds on purpose, so a
	 * shape this check has not enumerated refuses rather than resolves to the wrong binding.
	 */
	private static function rebinds(node: QueryNode, binder: String, s: LpadSeams): Bool {
		return node.name == binder && node.kind != s.identKind && node.kind != s.interpIdentKind
			|| node.children.exists(child -> rebinds(child, binder, s));
	}

	/** The decimal integer `node` spells, or null when it is not one (a hex or float spelling included). */
	private static function intLiteral(node: QueryNode, s: LpadSeams, source: String): Null<Int> {
		if (!s.numericKinds.contains(node.kind)) return null;
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final text: String = source.substring(span.from, span.to);
		final value: Null<Int> = Std.parseInt(text);
		return value != null && '$value' == text ? value : null;
	}

	/** The ladder `node` forms, or null when any of the shape gates in the type doc refuses it. */
	private static function ladderOf(node: QueryNode, s: LpadSeams, source: String): Null<LpadLadder> {
		if (!s.ifKinds.contains(node.kind)) return null;
		var subject: Null<String> = null;
		var threshold: Int = BASE;
		var cursor: QueryNode = node;
		final values: Array<QueryNode> = [];
		while (true) {
			if (!s.ifKinds.contains(cursor.kind) || cursor.children.length != LADDER_CHILD_COUNT) return null;
			final condition: QueryNode = cursor.children[0];
			if (condition.kind != s.ltKind || condition.children.length != CONDITION_CHILD_COUNT) return null;
			final left: QueryNode = condition.children[0];
			final name: Null<String> = left.name;
			if (left.kind != s.identKind || name == null) return null;
			if (subject == null)
				subject = name;
			else if (subject != name)
				return null;
			final bound: Null<Int> = intLiteral(condition.children[1], s, source);
			if (bound == null || bound != threshold) return null;
			values.push(cursor.children[1]);
			if (values.length >= MAX_BRANCHES) return null;
			threshold *= BASE;
			final tail: QueryNode = cursor.children[2];
			if (!s.ifKinds.contains(tail.kind)) {
				values.push(tail);
				break;
			}
			cursor = tail;
		}
		final name: Null<String> = subject;
		return name == null || values.length < MIN_BRANCHES ? null : ladderOfValues(values, name, threshold, s);
	}

	/** The affix / width agreement across a ladder's branch values -- the arithmetic half of the shape gate. */
	private static function ladderOfValues(values: Array<QueryNode>, subject: String, top: Int, s: LpadSeams): Null<LpadLadder> {
		var base: String = '';
		var suffix: String = '';
		var lead: Int = 0;
		for (k in 0...values.length) {
			final seg: Null<LpadSegments> = segmentsOf(values[k], s, subject);
			if (seg == null) return null;
			if (k == 0) {
				base = seg.base;
				suffix = seg.suffix;
				lead = seg.zeros;
			} else if (seg.base != base || seg.suffix != suffix || seg.zeros != lead - k)
				return null;
		}
		return {
			subject: subject,
			base: base,
			suffix: suffix,
			width: lead + 1,
			top: top
		};
	}

	/** Split one branch value into `<base><zeros>$<subject><suffix>`, or null when it is not that shape. */
	private static function segmentsOf(value: QueryNode, s: LpadSeams, subject: String): Null<LpadSegments> {
		if (!s.stringKinds.contains(value.kind)) return null;
		final kids: Array<QueryNode> = value.children;
		var holeAt: Int = -1;
		for (k => kid in kids) {
			if (kid.kind == s.interpIdentKind) {
				if (holeAt >= 0 || kid.name != subject) return null;
				holeAt = k;
			} else if (kid.kind != CheckScan.STRING_FRAGMENT_KIND)
				return null;
		}
		if (holeAt < 0 || holeAt > 1 || kids.length > holeAt + 2) return null;
		final prefix: Null<String> = holeAt == 1 ? kids[0].name : '';
		final tail: Null<String> = kids.length == holeAt + 2 ? kids[holeAt + 1].name : '';
		if (prefix == null || tail == null || prefix.indexOf(ESCAPE) >= 0) return null;
		var zeros: Int = 0;
		while (zeros < prefix.length && prefix.charAt(prefix.length - 1 - zeros) == PAD_CHAR) zeros++;
		return { base: prefix.substr(0, prefix.length - zeros), zeros: zeros, suffix: tail };
	}

	/** The `lpad` form of `ladder`, with each empty affix omitted. */
	private static function replacement(ladder: LpadLadder): String {
		final parts: Array<String> = [];
		if (ladder.base != '') parts.push(QUOTE + ladder.base + QUOTE);
		parts.push('${QUOTE + HOLE_SIGIL + ladder.subject + QUOTE}.$LPAD_METHOD($QUOTE$PAD_CHAR$QUOTE, ${ladder.width})');
		if (ladder.suffix != '') parts.push(QUOTE + ladder.suffix + QUOTE);
		return parts.join(' + ');
	}

	/** The finding text -- the rewrite when the range is proved, the interval it would need when not. */
	private static function messageOf(site: LpadSite): String {
		final form: String = replacement(site.ladder);
		final subject: String = site.ladder.subject;
		return site.proven
			? 'zero-pad ladder over \'$subject\' -- write it as $form'
			: 'zero-pad ladder over \'$subject\' -- $form'
				+ ' holds only where $subject is in [0, ${site.ladder.top}), which no literal range bound proves here (report-only)';
	}

}

/** The node kinds `PreferLpad` reads, resolved once per run by `readSeams`. */
typedef LpadSeams = {
	final ifKinds: Array<String>;
	final stringKinds: Array<String>;
	final numericKinds: Array<String>;
	final forKind: String;
	final intervalKind: String;
	final ltKind: String;
	final identKind: String;
	final interpIdentKind: String;
}

/** One accepted ladder: the padded value's name, the affixes written around it, the width and the exclusive top. */
typedef LpadLadder = {
	final subject: String;
	final base: String;
	final suffix: String;
	final width: Int;
	final top: Int;
}

/** One branch value split into the text before the zeros, the zero run itself, and the text after the hole. */
typedef LpadSegments = {
	final base: String;
	final zeros: Int;
	final suffix: String;
}

/** One ladder in a file: where it is, what it says, and whether its range is proved (the fix gate). */
typedef LpadSite = {
	final span: Span;
	final ladder: LpadLadder;
	final proven: Bool;
}
