package anyparse.check.common.control;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.common.control.BranchChain.ChainSeams;
import anyparse.query.CanonicalEdit;
import anyparse.query.CondRegionScan;
import anyparse.query.ParseGate;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;
import anyparse.query.TreePath;

using StringTools;

/**
 * Flags an if / else-if chain whose branches disagree: one braced, another bare -
 * `if (a) { p(); q(); } else r();`, its mirror, or `if (a) { p(); } else if (b) q();`.
 * `Info`: both spellings compile and mean the same thing, and which one to keep is the
 * project's taste, so the rule is `DefaultOff` - opt in with
 * `"asymmetric-branch-braces": { "enabled": true }`. It is the lint twin of the writer's
 * `whitespace.bracesConfig.singleStatementBraces: "symmetric"` policy (`chainForcesBraces`),
 * for a project whose `fmt` does not run it, and its fix takes the writer's repair
 * direction: the bare branches gain braces (`fix`).
 *
 * ## What is flagged, and what is not
 *
 * Two braced branches are symmetric; two bare ones are symmetric too - this is not a
 * "brace everything" rule, and `if (d.length != 4) throw '...';` is never flagged.
 *
 * TWO exemptions, the writer's own: an `else` whose body is another `if` (a chain link,
 * not a branch) or a `switch` (neither braced nor bare). Both are keyword-headed else
 * bodies the writer glues to the `else` line, each closing on a `}` of its own; bracing
 * the `if` one would rebuild the `else { if ... }` shape `collapsible-else-if` removes.
 * The exemption is ELSE-side only: a `switch` in THEN position is a branch.
 *
 * A chain is a finding with or without a final `else`, and once: the tail pair's own
 * finding when that pair is the asymmetric one - spanning that `if`, its message naming
 * the braced side - else one spanning the whole chain (`if (a) p(); else if (b) { q(); }
 * else { r(); }` is braced in its tail and bare in its head).
 *
 * A try/catch is a group the same way, in statement and in value position: its try body and every catch body braced,
 * or all of them bare. `try { p(); q(); } catch (e:T) r();` is one finding spanning the `try`, and the fix braces
 * `r();`, as the writer's `tryBraceVerdict` does. Neither is read inside a `macro` reification
 * (`RefShape.opaqueKinds`): a brace level there is part of the code it builds - the writer leaves it alone too.
 *
 * ## Grammar-agnostic
 *
 * The `if` kinds come from `RefShape.ifStatementKinds` (statement position only),
 * the block kind from `RefShape.blockStmtKind`, and the exempt else kinds from
 * `ifStatementKinds` plus `RefShape.switchStatementKinds`. Any of the first two
 * unset makes the check a no-op; an unset `switchStatementKinds` costs only the
 * `else switch` exemption, so a grammar without it reports those pairs.
 */
@:nullSafety(Strict)
final class AsymmetricBranchBraces extends RuleBase implements DefaultOff {

	/** The rule id, and the `--rule` selector that force-enables this default-off check. */
	private static inline final RULE_ID: String = 'asymmetric-branch-braces';

	/** The then branch is the second child of an if node - `[cond, then, else]`. */
	private static inline final THEN_BRANCH_INDEX: Int = 1;

	/** The else branch is the third child of an if node - `[cond, then, else]`. */
	private static inline final ELSE_BRANCH_INDEX: Int = 2;

	public function new() {
		super(
			RULE_ID, 'an if/else chain or a try/catch that braces some branches and not others - the bare ones read as an accident',
			RuleCategory.Control
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return RunScan.collectWith(files, plugin, resolveSeams(plugin), (entry, tree, seams, violations) -> {
			for (found in collect(tree, seams)) violations.push({
				file: entry.file,
				span: found.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: found.message
			});
		});
	}

	/**
	 * Braces the bare branches of each finding - the writer's repair direction under
	 * `singleStatementBraces: "symmetric"` (`SingleStmtBraces.needsSymmetryWrap`), its gates read off
	 * the grammar's seams instead of the writer's constructor names.
	 *
	 * The unit is the whole if / else-if CHAIN a finding names, as the writer's `chainForcesBraces`
	 * makes it - its tail pair, or the chain itself (`chainFinding`): bracing a tail pair alone would
	 * leave `if (a) x(); else if (b) { y(); } else { … }`, braced in its tail and bare in its head. So
	 * every bare branch of the chain (`bareBranches`) gains braces, or none does - a chain with no
	 * final `else` the same. Gates, each answering for the whole chain:
	 *
	 * - an edit inside a branch this call already braces (or around one) waits for the next pass, so
	 *   no two edits of one call overlap;
	 * - a local declaration stays bare - its braces would scope the binding;
	 * - a branch must close on a terminator of its own (`BranchChain.selfTerminated`), or END in a bare expression
	 *   statement (`openTail`), which takes the terminator inside the braces: Haxe accepts
	 *   `if (a) p() else { … }` and rejects `{ p() }` with `Missing ;` (verified against the
	 *   compiler), and `{ p(); }` is the same statement - as `{ for (c in s) p(); }` is the same loop.
	 *   Anything else unterminated - a conditional-compilation region - stays bare;
	 * - the rewritten source must parse back as the same chain with every branch braced around exactly
	 *   its old statement (`chainBracedAfter`).
	 *
	 * The edit is `{ ` + the branch's own text + ` }`; the canonicalising write lays it out. A finding
	 * a gate keeps carries that gate as its decline reason. Inert when the grammar names no
	 * `RefShape.statementTerminator`.
	 */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final resolved: Null<Seams> = resolveSeams(plugin);
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		final terminator: Null<String> = resolved?.terminator;
		if (resolved == null || tree == null || terminator == null) return [];
		final seams: Seams = resolved;
		final root: QueryNode = tree;
		final closer: String = terminator;
		final site: FixSite = {
			source: source,
			tree: root,
			seams: seams,
			terminator: closer,
			plugin: plugin,
			comments: SourceComments.collectCommentTokens(plugin.lexicalRegions(source))
		};
		final edits: Array<FixEdit> = [];
		for (pair in collect(tree, seams)) {
			final finding: Null<Violation> = violations.find(v -> v.span?.from == pair.span.from && v.span?.to == pair.span.to);
			if (finding != null) switch (seams.tryKinds.contains(pair.node.kind)
				? tryBraceFix(site, pair, edits)
				: braceFix(site, pair, edits)) {
				case Braced(own):
					for (e in own) edits.push(e);
				case Declined(reason):
					finding.declineReason = reason;
			}
		}
		return edits;
	}

	/** The else branch of `node` when it is an `if` with one, else null. */
	private static inline function elseOf(node: QueryNode, seams: Seams): Null<QueryNode> {
		return BranchChain.elseOf(node, seams.ifKinds);
	}

	/**
	 * Every finding in `root`, one per if / else-if chain, in document order (`chainFinding`).
	 */
	private static function collect(root: QueryNode, seams: Seams): Array<Asymmetry> {
		final out: Array<Asymmetry> = [];
		walk(root, seams, out, false);
		return out;
	}

	/**
	 * Collects the finding of every chain HEAD below `node` - an `if` that is not the else of another (`link` false) -
	 * and of every try/catch. A `macro` reification is not descended: `ReificationScan.withoutQuoted` drops a finding
	 * there anyway - a brace level in it is part of the code it builds - so this only spares the walk.
	 */
	private static function walk(node: QueryNode, seams: Seams, out: Array<Asymmetry>, link: Bool): Void {
		if (seams.opaqueKinds.contains(node.kind)) return;
		final found: Null<Asymmetry> = link || !seams.ifKinds.contains(node.kind) ? tryFinding(node, seams) : chainFinding(node, seams);
		if (found != null) out.push(found);
		final elseLink: Null<QueryNode> = elseOf(node, seams);
		for (child in node.children) walk(child, seams, out, child == elseLink && seams.ifKinds.contains(child.kind));
	}

	/**
	 * The one finding of the if / else-if chain `head` starts, or null when its branches agree. The tail pair's own
	 * finding comes first - its then branch braced and its else bare or the reverse, an `else switch` exempt - and is
	 * what a pair, a one-link chain, always answers. Otherwise the chain is a finding when one of its branches is
	 * braced and another is one the writer's `chainForcesBraces` would brace (`bareBranches`): a chain with no final
	 * `else`, or one braced in its tail and bare in its head. Its span is the whole chain.
	 */
	private static function chainFinding(head: QueryNode, seams: Seams): Null<Asymmetry> {
		final links: Array<QueryNode> = BranchChain.linksFrom(head, seams.ifKinds);
		final tail: QueryNode = links[links.length - 1];
		final last: Null<QueryNode> = elseOf(tail, seams);
		final headSpan: Null<Span> = head.span;
		final braced: Bool = last?.kind == seams.blockStmtKind
			|| links.exists(l -> l.children[THEN_BRANCH_INDEX].kind == seams.blockStmtKind);
		return pairFinding(tail, last, seams) ?? (
			headSpan != null && braced && bareBranches(links, seams).length > 0
				? { span: headSpan, node: head, message: 'the if/else-if chain braces some branches and not others - brace all or none' }
				: null
		);
	}

	/**
	 * The finding of the pair `tail` ends with its else branch `last`: exactly one of the two braced, a braced then
	 * opposite an exempt `else switch` excepted. Null when `last` is null - a chain with no final `else` has no pair.
	 */
	private static function pairFinding(tail: QueryNode, last: Null<QueryNode>, seams: Seams): Null<Asymmetry> {
		final span: Null<Span> = tail.span;
		final thenBraced: Bool = tail.children[THEN_BRANCH_INDEX].kind == seams.blockStmtKind;
		return if (
			last == null
			|| span == null
			|| thenBraced == (last.kind == seams.blockStmtKind)
			|| thenBraced
			&& seams.exemptElseKinds.contains(last.kind)
		)
			null
		else
			{
				span: span,
				node: tail,
				message: thenBraced
					? 'the then branch is braced and the else branch is not - brace both or neither'
					: 'the else branch is braced and the then branch is not - brace both or neither'
			};
	}

	/** `fix`'s answer for one asymmetric pair: the brace edits on every bare branch of its chain, or the gate that kept them bare. */
	private static function braceFix(site: FixSite, pair: Asymmetry, taken: Array<FixEdit>): BraceFix {
		final links: Null<Array<QueryNode>> = chainOf(site.tree, pair.node, site.seams);
		if (links == null) return Declined('the pair cannot be placed in the source again');
		final edits: Array<FixEdit> = [];
		for (bare in bareBranches(links, site.seams)) {
			final placed: Null<Span> = bare.span;
			if (placed == null) return Declined('a bare branch cannot be placed in the source again');
			if (site.seams.declKinds.contains(bare.kind))
				return Declined('a bare branch is a declaration, and braces would scope its binding');
			// An unterminated statement's span runs on over the blank before `else`; the braces close on its last token.
			final text: String = site.source.substring(placed.from, placed.to).rtrim();
			final statement: Null<String> = if (BranchChain.selfTerminated(bare, site.source, site.seams))
				text
			else if (openTail(bare, site.seams))
				text + site.terminator
			else
				null;
			if (statement == null) return Declined('a bare branch carries no terminator of its own, so it would not compile inside braces');
			edits.push(bracedEdit(site, placed.from, placed.from + text.length, statement));
		}
		if (edits.exists(e -> taken.exists(t -> e.span.from < t.span.to && t.span.from < e.span.to)))
			return Declined('it overlaps a branch this pass braces - the next pass takes it');
		return chainBracedAfter(site, edits, links)
			? Braced(edits)
			: Declined('the braced chain does not parse back as the same if/else with every branch braced');
	}

	/**
	 * The edit that braces the bare statement whose text starts at `from`, replacing up to `close`: `{ statement }`, or -
	 * when the branch's own comments sit above it (`bracesOpenAt`) - braces opened after the header that take them in.
	 */
	private static function bracedEdit(site: FixSite, from: Int, close: Int, statement: String): FixEdit {
		final open: Int = bracesOpenAt(site, from);
		return {
			span: new Span(open, close),
			text: open == from ? '{ $statement }' : ' {${site.source.substring(open, from)}$statement }'
		};
	}

	/**
	 * The one finding of the try/catch `node`, or null when `node` is none or its bodies agree: one braced and another
	 * bare - the group the writer's `tryBraceVerdict` braces whole. Its span is the whole `try`.
	 */
	private static function tryFinding(node: QueryNode, seams: Seams): Null<Asymmetry> {
		final bodies: Null<Array<QueryNode>> = BranchChain.tryBodiesOf(node, seams.tryKinds, seams.catchKind);
		final span: Null<Span> = node.span;
		return bodies == null
			|| span == null
			|| !bodies.exists(b -> seams.bracedKinds.contains(b.kind))
			|| bareBodies(bodies, seams).length == 0
			? null
			: { span: span, node: node, message: 'the try/catch braces some bodies and not others - brace all or none' };
	}

	/** The bodies of a try/catch group that carry no braces. */
	private static function bareBodies(bodies: Array<QueryNode>, seams: Seams): Array<QueryNode> {
		return bodies.filter(b -> !seams.bracedKinds.contains(b.kind));
	}

	/**
	 * `fix`'s answer for one asymmetric try/catch: the brace edits on every bare body of the group, or the gate that kept
	 * them bare. The chain's gates, with one difference: a body in an EXPRESSION slot (`try p() catch …`) carries no
	 * terminator of its own, so a bare body that does not close on one takes it inside its braces, and the parse back
	 * (`tryBracedAfter`) proves the block holds that body and nothing else. A bare LAST body followed by the statement's
	 * own terminator takes it in too: once braced, the `try` closes on its `}`.
	 */
	private static function tryBraceFix(site: FixSite, found: Asymmetry, taken: Array<FixEdit>): BraceFix {
		final seams: Seams = site.seams;
		final bodies: Null<Array<QueryNode>> = BranchChain.tryBodiesOf(found.node, seams.tryKinds, seams.catchKind);
		final end: Null<Int> = found.node.span?.to;
		if (bodies == null || end == null) return Declined('the try cannot be placed in the source again');
		final edits: Array<FixEdit> = [];
		for (bare in bareBodies(bodies, seams)) {
			final placed: Null<Span> = bare.span;
			if (placed == null) return Declined('a bare body cannot be placed in the source again');
			if (seams.declKinds.contains(bare.kind)) return Declined('a bare body is a declaration, and braces would scope its binding');
			if (CondRegionScan.isConditionalKind(bare.kind, seams.shape))
				return Declined('a bare body carries no terminator of its own, so it would not compile inside braces');
			final text: String = site.source.substring(placed.from, placed.to).rtrim();
			final statement: String = BranchChain.selfTerminated(bare, site.source, seams) ? text : text + site.terminator;
			final textEnd: Int = placed.from + text.length;
			final last: Bool = bare == bodies[bodies.length - 1];
			edits.push(bracedEdit(
				site, placed.from, last && site.source.substring(textEnd, end).trim() == site.terminator ? end : textEnd, statement
			));
		}
		if (edits.exists(e -> taken.exists(t -> e.span.from < t.span.to && t.span.from < e.span.to)))
			return Declined('it overlaps a branch this pass braces - the next pass takes it');
		return tryBracedAfter(site, edits, found.node, bodies)
			? Braced(edits)
			: Declined('the braced try does not parse back as the same try/catch with every body braced');
	}

	/**
	 * Whether the source with `edits` applied parses back as a try/catch where `node` stood - of any try kind, since a
	 * braced value-shaped `try` reads as the statement one - with as many bodies, every one braced, and each block braced
	 * anew holding exactly its old body: the same statement, or the same expression as its one expression statement.
	 */
	private static function tryBracedAfter(site: FixSite, edits: Array<FixEdit>, node: QueryNode, bodies: Array<QueryNode>): Bool {
		final seams: Seams = site.seams;
		final rewritten: Null<QueryNode> = ParseGate.parseOrNull(site.plugin, CanonicalEdit.applyEdits(site.source, edits));
		final from: Null<Int> = node.span?.from;
		final after: Null<QueryNode> = rewritten == null || from == null
			? null
			: TreePath.firstAround(rewritten, new Span(from, from), n -> n.span?.from == from && seams.tryKinds.contains(n.kind));
		final now: Null<Array<QueryNode>> = after == null ? null : BranchChain.tryBodiesOf(after, seams.tryKinds, seams.catchKind);
		if (now == null || now.length != bodies.length || bareBodies(now, seams).length > 0) return false;
		return [
			for (i => body in bodies) if (!seams.bracedKinds.contains(body.kind)) holdsOnly(now[i], body.kind, seams.exprStmtKind)
		].foreach(ok -> ok);
	}

	/** Whether `block` holds one statement of `kind`, or one expression statement (`exprStmtKind`) of a `kind` expression. */
	private static function holdsOnly(block: QueryNode, kind: String, exprStmtKind: Null<String>): Bool {
		final inner: Null<QueryNode> = block.children.length == 1 ? block.children[0] : null;
		return inner != null
			&& (inner.kind == kind || inner.kind == exprStmtKind && inner.children.length == 1 && inner.children[0].kind == kind);
	}

	/**
	 * Where a bare branch whose statement starts at `from` opens its braces: `from` itself, or - when comments of its
	 * own sit between its header and the statement, each opening a line of its own (`SourceComments.ownLineCommentAbove`)
	 * - right after the header's last token, so the braces take those notes in instead of leaving them between the
	 * header and the `{`.
	 */
	private static function bracesOpenAt(site: FixSite, from: Int): Int {
		var start: Int = from;
		var open: Int = SourceComments.ownLineCommentAbove(site.source, site.comments, start, false);
		while (open >= 0) {
			start = open;
			open = SourceComments.ownLineCommentAbove(site.source, site.comments, start, false);
		}
		return start == from ? from : site.source.substring(0, start).rtrim().length;
	}

	/**
	 * The if / else-if chain `pair` belongs to, head first: up through every `if` whose ELSE is the
	 * link below it, then down the else-if spine. Null when `pair` is not in `root`.
	 */
	private static function chainOf(root: QueryNode, pair: QueryNode, seams: Seams): Null<Array<QueryNode>> {
		final path: Null<Array<QueryNode>> = TreePath.pathTo(root, pair);
		if (path == null) return null;
		var head: QueryNode = pair;
		var at: Int = path.length - 2;
		while (at >= 0 && elseOf(path[at], seams) == head) {
			head = path[at];
			at--;
		}
		return BranchChain.linksFrom(head, seams.ifKinds);
	}

	/**
	 * The branches of the chain `links` the writer would brace: every bare then, and a bare terminal else that is
	 * neither a link nor an exempt `else switch` - the writer glues that one to its `else` (`SYMMETRY_WRAP_SKIP_CTORS`).
	 */
	private static function bareBranches(links: Array<QueryNode>, seams: Seams): Array<QueryNode> {
		final out: Array<QueryNode> = [
			for (link in links) if (link.children[THEN_BRANCH_INDEX].kind != seams.blockStmtKind) link.children[THEN_BRANCH_INDEX]
		];
		final last: Null<QueryNode> = elseOf(links[links.length - 1], seams);
		if (last != null && last.kind != seams.blockStmtKind && !seams.exemptElseKinds.contains(last.kind)) out.push(last);
		return out;
	}

	/**
	 * Whether `node`, which `BranchChain.selfTerminated` refused, ends in an expression statement written without its
	 * terminator - `p()`, `for (c in s) p()`, `if (b) x else y` - so that the terminator appended to its
	 * text is that statement's own. A conditional-compilation region, whose terminator its parent owns,
	 * is not one.
	 */
	private static function openTail(node: QueryNode, seams: Seams): Bool {
		if (node.kind == seams.exprStmtKind) return true;
		final last: Null<QueryNode> = node.children.length == 0 ? null : node.children[node.children.length - 1];
		return last != null && seams.lastChildClosedKinds.contains(node.kind) && openTail(last, seams);
	}

	/**
	 * Whether the source with `edits` applied parses back as the chain `links` - as many links, the head
	 * where it was - with every branch braced and each braced-anew block holding exactly its old statement.
	 */
	private static function chainBracedAfter(site: FixSite, edits: Array<FixEdit>, links: Array<QueryNode>): Bool {
		final rewritten: Null<QueryNode> = ParseGate.parseOrNull(site.plugin, CanonicalEdit.applyEdits(site.source, edits));
		final from: Null<Int> = links[0].span?.from;
		final head: Null<QueryNode> = rewritten == null || from == null
			? null
			: TreePath.firstAround(rewritten, new Span(from, from), n -> n.span?.from == from && site.seams.ifKinds.contains(n.kind));
		final after: Null<Array<QueryNode>> = rewritten == null || head == null ? null : chainOf(rewritten, head, site.seams);
		if (after == null || after.length != links.length || bareBranches(after, site.seams).length > 0) return false;
		final before: Array<QueryNode> = bareBranches(links, site.seams);
		final braced: Array<QueryNode> = [
			for (i => link in after) for (b in [THEN_BRANCH_INDEX, ELSE_BRANCH_INDEX]) if (
				b < link.children.length && before.contains(links[i].children[b])
			)
				link.children[b]
		];
		return braced.length == before.length && [
			for (i => block in braced) block.children.length == 1 && block.children[0].kind == before[i].kind
		].foreach(ok -> ok);
	}

	/**
	 * The `if` kinds, the block-statement kind and the else kinds exempt from the
	 * symmetry question, or null when either of the first two is unset.
	 */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final chain: Null<ChainSeams> = BranchChain.chainSeams(shape);
		return chain == null ? null : {
			ifKinds: chain.ifKinds,
			blockStmtKind: chain.blockStmtKind,
			exemptElseKinds: chain.ifKinds.concat(shape.switchStatementKinds ?? []),
			terminator: chain.terminator,
			exprStmtKind: shape.exprStatementKind,
			declKinds: shape.localDeclKinds ?? [],
			braceClosedKinds: chain.braceClosedKinds,
			lastChildClosedKinds: chain.lastChildClosedKinds,
			tryKinds: chain.tryKinds,
			catchKind: chain.catchKind,
			bracedKinds: [chain.blockStmtKind].concat(plugin.controlFlowSupport()?.blockKinds() ?? []),
			opaqueKinds: shape.opaqueKinds ?? [],
			shape: shape
		};
	}

}

/**
 * The seam kinds `AsymmetricBranchBraces` reads: the statement-position `if` kinds, the block kind, the exempt
 * else kinds, and the five `fix` reads to decide whether a bare branch may be braced.
 */
private typedef Seams = {
	final ifKinds: Array<String>;
	final blockStmtKind: String;
	final exemptElseKinds: Array<String>;

	/** `RefShape.statementTerminator`; unset makes `fix` inert. */
	final terminator: Null<String>;

	/** `RefShape.exprStatementKind`: an unterminated bare expression statement takes the terminator inside the braces. */
	final exprStmtKind: Null<String>;

	/** `RefShape.localDeclKinds`: a bare declaration is never braced. */
	final declKinds: Array<String>;

	/** Statements closed by a brace of their own whatever their content: `RefShape.switchStatementKinds`. */
	final braceClosedKinds: Array<String>;

	/** Statements that close the way their LAST child does: the `if`, loop, `try` and `catch` kinds. */
	final lastChildClosedKinds: Array<String>;

	/** The try/catch kinds, statement and value alike (`BranchChain.tryBodiesOf`). */
	final tryKinds: Array<String>;

	final catchKind: Null<String>;

	/** What a braced body is: the block-statement kind and `ControlFlowSupport.blockKinds` - a value `try` holds blocks too. */
	final bracedKinds: Array<String>;

	/** Subtrees not walked: a macro reification is code the program builds, not code it runs. */
	final opaqueKinds: Array<String>;

	/** The grammar's shape, for `CondRegionScan.isConditionalKind`. */
	final shape: RefShape;
};

/** One asymmetric if/else or chain: the reported span, the `if` node it is anchored on, and the message naming the defect. */
private typedef Asymmetry = {
	final span: Span;
	final node: QueryNode;
	final message: String;
};

/** The per-file context of `AsymmetricBranchBraces.fix`. */
private typedef FixSite = {
	final source: String;
	final tree: QueryNode;
	final seams: Seams;
	final terminator: String;
	final plugin: GrammarPlugin;

	/** The file's comment tokens (`SourceComments.collectCommentTokens`): a bare branch's own comments go inside its braces. */
	final comments: Array<CommentTok>;
};

/** What `fix` does with one asymmetric pair: the brace edits of its chain, or the gate that kept them bare. */
private enum BraceFix {
	Braced(edits: Array<FixEdit>);
	Declined(reason: String);
}
