package anyparse.check.common.control;

import anyparse.check.scan.CaseValueKey;
import anyparse.check.scan.CheckScan.NegationSeams;
import anyparse.check.scan.NegationScan;
import anyparse.check.scan.OperatorSelection;
import anyparse.query.BoolExprShape;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.ParenGuard;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;
import haxe.Exception;

/**
 * The one place a condition whose TOP-LEVEL node is a logical NOT is read in its positive form —
 * for the branch swap `invert-negated-if-else` performs on an `if` statement, a value-position `if`
 * and a ternary, and for every rule that BUILDS a ternary out of a guard (`prefer-ternary-return`,
 * `return-reassign-ternary`, `prefer-ternary-assignment`, `prefer-ternary-expression`), which emit
 * `c ? b : a` for `if (!c) …a… else …b…` instead of writing the `!c ? a : b` the inversion would
 * then have to undo.
 *
 * Dropping the `!` and swapping the two branches is an EXACT complement, semantics-safe under every
 * value including `NaN` (a De Morgan rewrite is not), on three conditions this class owns:
 *
 *  - the condition's top-level node, outer parentheses unwrapped, IS a not — never a `!=`, never a
 *    `&&` / `||` whose operand happens to be negated (`!a && b` keeps its shape);
 *  - that `!` is the BUILT-IN one: an abstract declaring `@:op(!A)` beside a `to Bool` may make `!f`
 *    and `f` agree, and then the swap runs the other branch (`OperatorSelection`);
 *  - the rebuild drops no comment: the positive form is the not's operand source with a single
 *    redundant paren around it unwrapped, so a comment between `!` and that operand, or inside the
 *    dropped paren, would be lost. A comment INSIDE the kept operand travels verbatim.
 *
 * The operand loses its paren unconditionally; where the result lands in an operator context (a
 * ternary condition) the caller's `ParenGuard` puts back exactly the pair the parser needs.
 *
 * One more refusal is a matter of taste, not of semantics, and is off unless a project asks for it:
 * under `invert-negated-if-else`'s `keepDefaultElse` a choice whose CURRENT else arm is a default
 * literal (`!x ? v : null`) keeps its negation, so the fallback stays last (`invertibleOperand`). Every
 * reader — the swap and the four builders — asks it with the else arm, so they cannot disagree.
 *
 * Its reverse, `defaultLast`, also off by default, turns a choice that puts a default literal FIRST
 * around: `c ? null : v` -> `!c ? v : null`, `a != b ? null : v` -> `a == b ? v : null`
 * (`defaultLastCondition`). It implies `keepDefaultElse` — without it the two would undo each other on
 * every `--fix` pass — so a choice is never turned back, and the swap asks one door for both
 * directions (`swapOf`).
 */
@:nullSafety(Strict)
final class NegatedCondition {

	/**
	 * The `invert-negated-if-else` option that keeps a negation whose else arm is a default literal
	 * (`!x ? v : null`), read by every rule that inverts or orients a choice through this class.
	 */
	public static inline final KEEP_DEFAULT_ELSE: String = 'keepDefaultElse';

	/**
	 * The `invert-negated-if-else` option that turns a choice whose THEN arm is a default literal and whose
	 * else arm is no literal around, so the default goes last (`c ? null : v` -> `!c ? v : null`). It implies
	 * `KEEP_DEFAULT_ELSE`.
	 */
	public static inline final DEFAULT_LAST: String = 'defaultLast';

	/**
	 * The per-run seams, or null when the grammar declares no not kind (every caller then emits the
	 * condition as written). `config` is the run's per-file config resolver (`ConfigAware`; null reads
	 * each file's chain from disk), consulted for `keepDefaultElse` / `defaultLast` only when a choice
	 * has a default-literal arm. `report` is a fix's report index (see `OperatorSelection.of`).
	 */
	public static function readSeams(
		plugin: GrammarPlugin, files: Array<{ file: String, source: String }>, config: Null<(String) -> LintConfig>, ?report: SymbolIndex
	): Null<InversionSeams> {
		final shape: RefShape = plugin.refShape();
		final declaredNot: Null<String> = shape.notKind;
		if (declaredNot == null) return null;
		final notKind: String = declaredNot;
		final negation: NegationSeams = NegationScan.negationSeams(shape);
		final equality: Array<String> = [for (k in [negation.eqKind, negation.notEqKind]) if (k != null) k];
		return {
			notKind: notKind,
			parenKind: shape.parenKind,
			selection: OperatorSelection.of(plugin, files, report),
			defaults: {
				values: CaseValueKey.seamsOf(shape),
				blockKind: shape.blockStmtKind,
				returnKind: shape.returnStatementKind,
				config: config,
				negation: negation,
				support: plugin.booleanLogicSupport(),
				turnableKinds: [
					for (k in negation.atomicKinds) if (k != shape.boolLitKind && k != shape.parenKind) k
				].concat(equality),
				negationKinds: [notKind].concat(equality),
				interpolationKinds: [
					for (k in [shape.stringInterpIdentKind, shape.stringInterpBlockKind]) if (k != null) k
				]
			}
		};
	}

	/** The negation site of `file`'s `tree`, or null when the run has no `seams` (the grammar declares no not kind). */
	public static function siteOf(seams: Null<InversionSeams>, file: String, source: String, root: Null<QueryNode>): Null<InversionSite> {
		return seams == null ? null : site(seams, file, source, root);
	}

	/**
	 * The negation site of `file`'s `tree` under `seams`. Its `keepDefaultElse` and `defaultLast` read the
	 * file's config once, on first demand — a file whose choices have no default-literal arm never resolves it.
	 */
	public static function site(seams: InversionSeams, file: String, source: String, root: Null<QueryNode>): InversionSite {
		var known: Null<{ keep: Bool, last: Bool }> = null;
		function options(): { keep: Bool, last: Bool } {
			final read: Null<{ keep: Bool, last: Bool }> = known;
			if (read != null) return read;
			final config: LintConfig = LintConfig.resolveWith(seams.defaults.config, file);
			final last: Bool = config.boolOption(InvertNegatedIfElse.RULE_ID, DEFAULT_LAST) ?? false;
			final fresh: { keep: Bool, last: Bool } = {
				keep: last || (config.boolOption(InvertNegatedIfElse.RULE_ID, KEEP_DEFAULT_ELSE) ?? false),
				last: last
			};
			known = fresh;
			return fresh;
		}
		return {
			seams: seams,
			file: file,
			source: source,
			root: root,
			keepDefaultElse: () -> options().keep,
			defaultLast: () -> options().last
		};
	}

	/**
	 * The node whose source is the positive condition of the two-way choice `cond ? … : elseArm` — the
	 * not's operand, a single paren around it unwrapped — or null when the choice is not to be inverted:
	 * `cond` is no built-in top-level not, or `keepDefaultElse` keeps `elseArm`, a default literal, last.
	 * Comments are NOT consulted: a rule that reports a site it cannot rewrite asks `dropsComment` separately.
	 */
	public static function invertibleOperand(cond: QueryNode, elseArm: QueryNode, site: InversionSite): Null<QueryNode> {
		final kept: Null<QueryNode> = negatedOperand(cond, site);
		return kept == null || keepsDefaultElse(elseArm, site) ? null : kept;
	}

	/** Whether rebuilding `cond` as `kept`'s source alone would drop a comment (one outside `kept`). */
	public static function dropsComment(cond: QueryNode, kept: QueryNode, source: String): Bool {
		final condSpan: Null<Span> = cond.span;
		final keptSpan: Null<Span> = kept.span;
		return condSpan == null || (keptSpan == null || commentOutside(source, condSpan, keptSpan));
	}

	/**
	 * `invertibleOperand` when its rebuild drops no comment — the condition a rule may emit positive for
	 * the choice whose else arm is `elseArm` — else null.
	 */
	public static function positive(cond: QueryNode, elseArm: QueryNode, site: Null<InversionSite>): Null<QueryNode> {
		if (site == null) return null;
		final kept: Null<QueryNode> = invertibleOperand(cond, elseArm, site);
		return kept == null || dropsComment(cond, kept, site.source) ? null : kept;
	}

	/**
	 * How the two-way choice `cond ? thenArm : elseArm` reads with its two arms changing places, or null
	 * when it stays as written: the not's operand when `cond` is an invertible built-in not
	 * (`invertibleOperand`), else the `defaultLast` negation (`defaultLastCondition`). The one door the
	 * branch swap asks, so the two directions are read together and a swapped choice never qualifies again.
	 */
	public static function swapOf(cond: QueryNode, thenArm: QueryNode, elseArm: QueryNode, site: InversionSite): Null<Swap> {
		final kept: Null<QueryNode> = invertibleOperand(cond, elseArm, site);
		final keptSpan: Null<Span> = kept?.span;
		if (kept != null && keptSpan != null) return {
			condition: site.source.substring(keptSpan.from, keptSpan.to),
			dropsComment: dropsComment(cond, kept, site.source),
			defaultLast: false
		};
		final turned: Null<String> = defaultLastCondition(cond, thenArm, elseArm, site);
		return turned == null ? null : { condition: turned, dropsComment: false, defaultLast: true };
	}

	/**
	 * The negation of `cond` that lets the choice `cond ? thenArm : elseArm` swap its arms so a default
	 * goes LAST — `c ? null : v` -> `!c ? v : null`, `a != b ? null : v` -> `a == b ? v : null` — or null
	 * when the choice is not to be turned. Every condition holds, the config read last:
	 *
	 *  - `cond`, read through its parentheses, is an atom (`NegationSeams.atomicKinds`: a name, a field,
	 *    a call, an index, a `new`) that takes a bare `!`, or an `==` / `!=`, which flips (NaN-safe). A
	 *    not is `invertibleOperand`'s (one it refuses stays: no `!!`), and a compound, an ordered
	 *    comparison or anything else would need a wrap or a De Morgan rewrite, which reads worse than
	 *    the order it fixes;
	 *  - the then arm is a default literal (`CaseValueKey.isDefaultLiteral`) and the else arm is no
	 *    literal at all (`CaseValueKey.isLiteral`) — two literals are a mapping, left in its order — each
	 *    read as `keepDefaultElse` reads an arm, and both or neither a `return`;
	 *  - the file sets `defaultLast`;
	 *  - the `!` it adds and the comparison it flips are the built-in ones (`builtin`).
	 *
	 * The text is the shared negation engine's (`NegationScan.negateConditionText`), which drops no
	 * comment for these shapes.
	 */
	public static function defaultLastCondition(
		cond: QueryNode, thenArm: QueryNode, elseArm: QueryNode, site: InversionSite
	): Null<String> {
		final d: DefaultElseSeams = site.seams.defaults;
		final written: QueryNode = BoolExprShape.unwrapParens(cond, site.seams.parenKind);
		if (!d.turnableKinds.contains(written.kind)) return null;
		final first: ArmValue = armValue(thenArm, site);
		final last: ArmValue = armValue(elseArm, site);
		return first.returned != last.returned || !isDefault(first.value, site) || isLiteral(last.value, site) || !site.defaultLast()
			|| !builtin(written, d.negationKinds, site)
			? null
			: NegationScan.negateConditionText(written, site.source, d.negation, d.support);
	}

	/**
	 * `<head><cond> ? <then> : <else><tail>` replacing `span` as a `ParenGuard` edit, `<then>` and
	 * `<else>` the sources of `thenValue` and `elseValue`, oriented positive: when `cond` is a negated
	 * condition `positive` accepts for that else value, the `!` is dropped and the two values change
	 * places, and BOTH values become holes as well as the condition — each now lands in the other's
	 * slot, so the parse round-trip is what proves the swap re-reads as the same two nodes. Otherwise
	 * exactly `ParenGuard.ternaryEdit` over the condition as written.
	 */
	public static function ternaryEdit(
		span: Span, head: String, cond: QueryNode, thenValue: QueryNode, elseValue: QueryNode, tail: String, source: String,
		site: Null<InversionSite>
	): GuardedEdit {
		final condSpan: Null<Span> = cond.span;
		final thenSpan: Null<Span> = thenValue.span;
		final elseSpan: Null<Span> = elseValue.span;
		if (condSpan == null || thenSpan == null || elseSpan == null)
			throw new Exception('NegatedCondition.ternaryEdit: a condition or a value without a span');
		final thenText: String = source.substring(thenSpan.from, thenSpan.to);
		final elseText: String = source.substring(elseSpan.from, elseSpan.to);
		final kept: Null<QueryNode> = positive(cond, elseValue, site);
		final keptSpan: Null<Span> = kept?.span;
		if (keptSpan == null)
			return ParenGuard.ternaryEdit(span, head, source.substring(condSpan.from, condSpan.to), thenText, elseText, tail);
		final positiveText: String = source.substring(keptSpan.from, keptSpan.to);
		final edit: GuardedEdit = ParenGuard.ternaryEdit(span, head, positiveText, elseText, thenText, tail);
		final firstFrom: Int = head.length + positiveText.length + ' ? '.length;
		final secondFrom: Int = firstFrom + elseText.length + ' : '.length;
		edit.holes.push(new Span(firstFrom, firstFrom + elseText.length));
		edit.holes.push(new Span(secondFrom, secondFrom + thenText.length));
		return edit;
	}

	/**
	 * Whether every operator of `kinds` an inversion drops, adds or flips at `node` — the not it drops, the
	 * not it puts over an atom, the `==` / `!=` it flips — is the language's own. A tree declaring none of
	 * `kinds` as an overload pays a map lookup and nothing more: no operand type is ever resolved. A tree
	 * that does declare one is judged per occurrence, which needs the file's tree; a site handed none
	 * answers false — the condition is then emitted as written, never inverted on a guess.
	 */
	private static function builtin(node: QueryNode, kinds: Array<String>, site: InversionSite): Bool {
		final selection: Null<OperatorSelection> = site.seams.selection;
		if (selection == null || !selection.declared(kinds)) return true;
		final root: Null<QueryNode> = site.root;
		return root != null && selection.verdictOfOperands([node], kinds, selection.typingFor(site.file, site.source, root)).match(Builtin);
	}

	/**
	 * The node whose source is `cond`'s positive form — the not's operand, a single paren around it
	 * unwrapped — or null when `cond` is not a built-in top-level not.
	 */
	private static function negatedOperand(cond: QueryNode, site: InversionSite): Null<QueryNode> {
		final s: InversionSeams = site.seams;
		final not: QueryNode = BoolExprShape.unwrapParens(cond, s.parenKind);
		if (not.kind != s.notKind || not.children.length != 1) return null;
		final operand: QueryNode = not.children[0];
		final kept: QueryNode = s.parenKind != null && operand.kind == s.parenKind && operand.children.length == 1
			? operand.children[0]
			: operand;
		return builtin(not, [s.notKind], site) ? kept : null;
	}

	/**
	 * Whether the inversion keeps the negation because it would bring a default value forward: the file
	 * sets `keepDefaultElse` (or `defaultLast`, which implies it) and `elseArm` is a default literal
	 * (`CaseValueKey.isDefaultLiteral`) as `armValue` reads it — through its parentheses, or, for an `if`
	 * statement's else branch, a `return` of one, bare or the sole statement of a block. Any other
	 * statement (`else null;`, `else x = null;`) is no default arm. The config is read last, only for
	 * a default arm.
	 */
	private static function keepsDefaultElse(elseArm: QueryNode, site: InversionSite): Bool {
		return isDefault(armValue(elseArm, site).value, site) && site.keepDefaultElse();
	}

	/**
	 * The value the arm `arm` of a two-way choice yields: read through every block holding only one
	 * statement, then through a value `return` (`returned`), then through parentheses.
	 */
	private static function armValue(arm: QueryNode, site: InversionSite): ArmValue {
		final d: DefaultElseSeams = site.seams.defaults;
		var value: QueryNode = arm;
		while (value.kind == d.blockKind && value.children.length == 1) value = value.children[0];
		final returned: Bool = value.kind == d.returnKind && value.children.length == 1;
		return { value: BoolExprShape.unwrapParens(returned ? value.children[0] : value, site.seams.parenKind), returned: returned };
	}

	/** Whether `value` is a default literal (`CaseValueKey.isDefaultLiteral`: `null`, `false`, a numeric zero, an empty string). */
	private static function isDefault(value: QueryNode, site: InversionSite): Bool {
		final span: Null<Span> = value.span;
		return span != null
			&& CaseValueKey.isDefaultLiteral(value.kind, site.source.substring(span.from, span.to), site.seams.defaults.values);
	}

	/**
	 * Whether `value` is a literal of any value (`CaseValueKey.isLiteral`) — an interpolating string is not:
	 * it computes its value, as `'${item.id}'` does.
	 */
	private static function isLiteral(value: QueryNode, site: InversionSite): Bool {
		final d: DefaultElseSeams = site.seams.defaults;
		final span: Null<Span> = value.span;
		return span != null && CaseValueKey.isLiteral(value.kind, site.source.substring(span.from, span.to), d.values)
			&& !value.children.exists(c -> d.interpolationKinds.contains(c.kind));
	}

	/** Whether a comment lies in `outer` before or after `inner` — the part of `outer` a rebuild as `inner` drops. */
	private static function commentOutside(source: String, outer: Span, inner: Span): Bool {
		return SourceComments.hasCommentMarker(source, outer.from, inner.from)
			|| SourceComments.hasCommentMarker(source, inner.to, outer.to);
	}

}

/** The per-run half of a negation read: the not and paren kinds, and the run's operator table. */
typedef InversionSeams = {
	final notKind: String;
	final parenKind: Null<String>;

	/** Null when the grammar declares no operator-overload annotation — every `!` is then built in. */
	final selection: Null<OperatorSelection>;

	/** What `keepDefaultElse` and `defaultLast` read: the literals, the statement shapes around one, the config, the negation engine. */
	final defaults: DefaultElseSeams;
};

/** The per-run half of the `keepDefaultElse` and `defaultLast` reads. */
typedef DefaultElseSeams = {
	final values: CaseValueSeams;

	/** A block wrapping one statement is read through (`else { return null; }`); null when the grammar has none. */
	final blockKind: Null<String>;

	/** A value `return` is read through to its value (`else return null;`); null when the grammar has none. */
	final returnKind: Null<String>;

	/** The run's per-file config resolver; null reads each file's chain from disk (`LintConfig.resolveWith`). */
	final config: Null<(String) -> LintConfig>;

	/** What `defaultLast` negates a condition with (`NegationScan.negateConditionText`). */
	final negation: NegationSeams;

	/** The grammar's negation engine, or null for the text engine alone. */
	final support: Null<BooleanLogicSupport>;

	/** The condition kinds `defaultLast` turns: an atom that takes a bare `!`, an `==` / `!=` that flips. */
	final turnableKinds: Array<String>;

	/** The operators a `defaultLast` negation adds or flips — the not, `==`, `!=` — each asked of the operator table. */
	final negationKinds: Array<String>;

	/** The interpolation segment kinds of a string literal: a string holding one computes its value. */
	final interpolationKinds: Array<String>;
};

/** One file's negation context: the run seams plus the file, its source and its parsed tree. */
typedef InversionSite = {
	final seams: InversionSeams;
	final file: String;
	final source: String;

	/** The file's tree, read only when the run declares an overloaded `!` (to type the operand). */
	final root: Null<QueryNode>;

	/** The file's `invert-negated-if-else` `keepDefaultElse` option (default off; `defaultLast` implies it), read once on first demand. */
	final keepDefaultElse: () -> Bool;

	/** The file's `invert-negated-if-else` `defaultLast` option (default off), read with `keepDefaultElse`. */
	final defaultLast: () -> Bool;
};

/** A two-way choice read with its arms swapped (`NegatedCondition.swapOf`). */
typedef Swap = {
	/** The condition's text once the two arms change places. */
	final condition: String;

	/** Whether that rebuild drops a comment of the condition (one between a dropped `!` and its operand). */
	final dropsComment: Bool;

	/** True for a `defaultLast` turn (a default then arm brought last), false for a dropped not. */
	final defaultLast: Bool;
};

/** What one arm of a two-way choice yields (`NegatedCondition.armValue`). */
private typedef ArmValue = {
	final value: QueryNode;

	/** Whether a `return` yields it — the arm is a statement. */
	final returned: Bool;
};
