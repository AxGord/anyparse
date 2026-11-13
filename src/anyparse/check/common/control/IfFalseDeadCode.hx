package anyparse.check.common.control;

import anyparse.query.CondDirectives;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.NodeShape;
import anyparse.query.SymbolIndex;

using anyparse.util.Strings;
using StringTools;

/**
 * Flags every `#if false … #end` conditional-compilation region — dead code the compiler never sees on any target — and every
 * `#if true … #end` region, the mirror smell: the guard buys nothing since the body compiles on every target regardless.
 *
 * Detection is DIRECTIVE-based: conditional nodes of every scope do not project their condition as a child, but all span a region
 * opened by the grammar's `#if`. The shared reader (`CondDirectives`) supplies the region's own directives: a node is a hit when its
 * span is exactly one cleanly closed region whose opener's condition is the literal `false` / `true` (parentheses peeled), and the
 * branch bodies are the gaps between those directives — so a keyword written inside a string or comment of a dead branch is never a
 * branch boundary.
 *
 * `fix`:
 * - `#if false X #end` → delete the region, only when `X` is trivial.
 * - `#if false X #else Y #end` → replace the region with `Y`, only when `X` is trivial.
 * - `#if true X #end` → unwrap to `X` unconditionally: nothing is erased.
 * - `#if true X #else Y #end` → unwrap to `X`, only when `Y` is trivial.
 * - `#elseif` chains are report-only for both polarities: that rewrite is a semantic transform left to a human.
 *
 * ## Non-trivial dead body: report-only
 *
 * The branch a fix would ERASE can be more than filler: an alternate implementation left behind a guard preserves unfinished or
 * reverted work (`ConstantCondition`, the `if (false)` sibling, documents a real case). So `fix` withholds the edit unless the
 * eliminated branch holds only empty statements, empty members or empty blocks; the violation still reports, with a human-review
 * note. Triviality is read off the region's child nodes: every child inside the branch is such a filler and no byte of it is left
 * uncovered, so a comment-only body, or code the grammar did not project as a node, is non-trivial.
 */
@:nullSafety(Strict)
final class IfFalseDeadCode extends RuleBase {

	/** ASCII-only note appended when a non-trivial dead body withholds the autofix. */
	private static final DEAD_BRANCH_NOTE: String = ' (dead branch - verify intent before deleting)';

	/** Base message for a flagged `#if false` region — always dead code. */
	private static final FALSE_MESSAGE: String = 'dead `#if false` region — no compilation target ever includes it';

	/** Base message for a flagged `#if true` region — the guard is always redundant. */
	private static final TRUE_MESSAGE: String = 'redundant `#if true` region — every compilation target already includes it';

	public function new() {
		super(
			'if-false', 'an `#if false … #end` region — dead code — or an `#if true … #end` region — a redundant directive',
			RuleCategory.Control
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return RunScan.collectWith(files, plugin, readSeams(plugin), (entry, tree, seams, violations) -> {
			for (region in regionsOf(tree, scanOf(entry.source, seams, plugin))) violations.push({
				file: entry.file,
				span: region.span,
				rule: 'if-false',
				severity: Severity.Warning,
				message: messageOf(region)
			});
		});
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final flagged: Array<String> = RunScan.spanKeys(violations);
		return RunScan.editsWith(plugin, source, readSeams(plugin), (tree, seams) -> {
			final edits: Array<{ span: Span, text: String }> = [];
			for (region in regionsOf(tree, scanOf(source, seams, plugin))) {
				final edit: Null<{ span: Span, text: String }> = flagged.contains('${region.span.from}:${region.span.to}')
					? editOf(source, region)
					: null;
				if (edit != null) edits.push(edit);
			}
			return edits;
		});
	}

	/** The seams this rule reads, or null when the grammar declares no conditional-compilation opener or closer. */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifKeyword: Null<String> = shape.conditionalIfKeyword;
		final endKeyword: Null<String> = shape.conditionalEndKeyword;
		if (ifKeyword == null || endKeyword == null) return null;
		final flow: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		final emptyStmt: Null<String> = shape.emptyStmtKind;
		final emptyMember: Null<String> = shape.emptyMemberKind;
		final containers: Array<String> = flow == null ? [] : flow.blockKinds().copy();
		final objectLiteral: Null<String> = shape.objectLiteralKind;
		if (objectLiteral != null) containers.push(objectLiteral);
		final fillers: Array<String> = [];
		if (emptyStmt != null) fillers.push(emptyStmt);
		if (emptyMember != null) fillers.push(emptyMember);
		return {
			shape: shape,
			ifKeyword: ifKeyword,
			endKeyword: endKeyword,
			elseKeywords: shape.conditionalElseKeywords ?? [],
			emptyKinds: fillers,
			emptyContainerKinds: containers
		};
	}

	/** One file's directives and the offsets its `#if` openers start at. */
	private static function scanOf(source: String, seams: Seams, plugin: GrammarPlugin): Scan {
		final directives: Array<CondDirective> = CondDirectives.scan(source, seams.shape, plugin.lexicalRegions.bind(source));
		final openers: Map<Int, Bool> = [];
		for (directive in directives) if (directive.keyword == seams.ifKeyword) openers[directive.span.from] = true;
		return {
			source: source,
			seams: seams,
			directives: directives,
			openers: openers
		};
	}

	/** Every dead or redundant region under `tree`, in document order; a flagged region's own children are not searched. */
	private static function regionsOf(tree: QueryNode, scan: Scan): Array<Region> {
		final out: Array<Region> = [];
		if (scan.directives.length > 0) collect(tree, scan, out);
		return out;
	}

	private static function collect(node: QueryNode, scan: Scan, out: Array<Region>): Void {
		final region: Null<Region> = regionAt(node, scan);
		if (region != null)
			out.push(region);
		else
			for (child in node.children) collect(child, scan, out);
	}

	/** The region `node` is, or null when it is not exactly one cleanly closed `#if <literal>` region. */
	private static function regionAt(node: QueryNode, scan: Scan): Null<Region> {
		final span: Null<Span> = node.span;
		if (span == null || !scan.openers.exists(span.from)) return null;
		final seams: Seams = scan.seams;
		final own: Null<Array<CondDirective>> = CondDirectives.ownDirectives(
			scan.directives, span, seams.ifKeyword, seams.elseKeywords, seams.endKeyword
		);
		if (own == null) return null;
		// A node that runs past its closer (`#if t "a" #end + "b"`) is not the region: replacing it would drop what follows.
		final condition: Null<Span> = own[0].condition;
		if (condition == null || own[own.length - 1].span.to != span.to) return null;
		final isTrue: Bool = isLiteral(scan.source, condition, 'true');
		return !isTrue && !isLiteral(scan.source, condition, 'false')
			? null
			: { span: span, isTrue: isTrue, eliminated: branchesOf(node, own, scan) };
	}

	/**
	 * Whether `condition` is NOTHING but `literal`, under any layer of parentheses:
	 * `#if false && x` is a conditional on `x`, not a dead region.
	 */
	private static function isLiteral(source: String, condition: Span, literal: String): Bool {
		final text: String = CondDirectives.normalizeCondition(source.substring(condition.from, condition.to));
		return text.stripOuterParens() == literal;
	}

	/**
	 * The `#if` body and the `#else` body of a region, or null for an `#elseif` chain (or a repeated
	 * `#else`) — `fix` stays report-only there and the message keeps its base text. The `#if` body starts
	 * right after the opener's condition, the `#else` body right after its keyword.
	 */
	private static function branchesOf(node: QueryNode, own: Array<CondDirective>, scan: Scan): Null<Branches> {
		final seams: Seams = scan.seams;
		final hasElse: Bool = own.length == 3;
		if (own.length > 3 || (hasElse && CondDirectives.takesCondition(own[1].keyword, seams.ifKeyword, seams.endKeyword))) return null;
		final then: Span = new Span(own[0].span.to, own[1].span.from);
		final otherwise: Null<Span> = hasElse ? new Span(own[1].span.to, own[2].span.from) : null;
		return {
			then: then,
			otherwise: otherwise,
			thenTrivial: isTrivial(node, then, scan),
			otherwiseTrivial: otherwise == null || isTrivial(node, otherwise, scan)
		};
	}

	/**
	 * Whether the `branch` of `region` holds nothing a fix must not discard: every child node inside it is a
	 * filler (an empty statement, an empty member, an empty block with nothing between its braces) and the
	 * bytes between the fillers are blank.
	 */
	private static function isTrivial(region: QueryNode, branch: Span, scan: Scan): Bool {
		var at: Int = branch.from;
		for (child in region.children) {
			final span: Null<Span> = child.span;
			if (span == null || span.to <= branch.from || span.from >= branch.to) continue;
			if (
				span.from < at
				|| span.to > branch.to
				|| !NodeShape.isEmptyFiller(child, scan.source, scan.seams.emptyKinds, scan.seams.emptyContainerKinds)
				|| !scan.source.substring(at, span.from).isBlank()
			)
				return false;
			at = span.to;
		}
		return scan.source.substring(at, branch.to).isBlank();
	}

	/**
	 * The violation message of `region`: the base message for its polarity, extended with an ASCII
	 * human-review note when the branch a fix would eliminate is non-trivial — the false arm's `#if`
	 * body, or the true arm's `#else` body when one exists (an elseless `#if true` region eliminates
	 * nothing, so it never gets the note). An `#elseif` chain keeps the base message — report-only for
	 * an unrelated reason (the rewrite is a semantic transform, not a triviality question).
	 */
	private static function messageOf(region: Region): String {
		final base: String = region.isTrue ? TRUE_MESSAGE : FALSE_MESSAGE;
		final branches: Null<Branches> = region.eliminated;
		if (branches == null) return base;
		final trivial: Bool = region.isTrue ? branches.otherwiseTrivial : branches.thenTrivial;
		return trivial ? base : base + DEAD_BRANCH_NOTE;
	}

	/**
	 * The edit that rewrites `region`, or null when it stays report-only. The false arm erases its `#if`
	 * body and keeps the `#else` body (or nothing); the true arm keeps its `#if` body and erases the `#else`
	 * body — an elseless `#if true` region erases nothing, so it unwraps unconditionally.
	 */
	private static function editOf(source: String, region: Region): Null<{ span: Span, text: String }> {
		final branches: Null<Branches> = region.eliminated;
		if (branches == null) return null;
		final otherwise: Null<Span> = branches.otherwise;
		if (region.isTrue)
			return otherwise != null && !branches.otherwiseTrivial
				? null
				: { span: region.span, text: source.substring(branches.then.from, branches.then.to).trim() };
		return branches.thenTrivial
			? { span: region.span, text: otherwise == null ? '' : source.substring(otherwise.from, otherwise.to).trim() }
			: null;
	}

}

/** What a run reads of the grammar: the directive vocabulary, and the node kinds that carry no code. */
private typedef Seams = {
	final shape: RefShape;
	final ifKeyword: String;
	final endKeyword: String;
	final elseKeywords: Array<String>;
	final emptyKinds: Array<String>;
	final emptyContainerKinds: Array<String>;
};

/** One file's source, its conditional directives, and the offsets its openers start at. */
private typedef Scan = {
	final source: String;
	final seams: Seams;
	final directives: Array<CondDirective>;
	final openers: Map<Int, Bool>;
};

/** A flagged region: its node span, its polarity, and its branches (null for an `#elseif` chain). */
private typedef Region = { final span: Span; final isTrue: Bool; final eliminated: Null<Branches>; };

/** The `#if` body and the `#else` body (null when there is none) of a region, each with its triviality. */
private typedef Branches = {
	final then: Span;
	final otherwise: Null<Span>;
	final thenTrivial: Bool;
	final otherwiseTrivial: Bool;
};
