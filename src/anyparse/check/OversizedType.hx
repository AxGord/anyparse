package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.NoAutofix;
import anyparse.check.Check.Violation;
import anyparse.check.Check.VolatileMessage;
import anyparse.check.ConstantFieldScan.ConstantFieldSeams;
import anyparse.query.CallGraph;
import anyparse.query.Clusters;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.SymbolIndexHost;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Flags a type declaration that has grown past a member-count or line-extent
 * threshold — a decomposition candidate the micro-level checks (per-function
 * complexity, style) cannot see. The first TYPE-level metric check: a ratchet
 * that makes god-file debt visible and keeps types from silently growing;
 * report-only, so `fix` produces no edits (splitting a type is `hxq
 * move-member` / `clusters` territory, not a mechanical autofix).
 *
 * ## The metric
 *
 * Two independent thresholds, either one trips the finding (ONE `Warning` per
 * type, reported on the type header):
 *
 * - **member count** — the type body's children whose kind the grammar lists in
 *   `RefShape.memberDeclKinds`, recursing into `#if` conditional-compilation
 *   blocks (`RefShape.conditionalMemberKind`) so guarded members count too;
 *   modifier siblings are not members and are not counted.
 * - **line extent** — the number of source lines the type's span covers; neither counts a CONSTANT (`isConstant`, `constantLines`).
 *
 * ## The interface carve-out
 *
 * A member an implemented interface DECLARES cannot be moved out of the type without breaking
 * the contract, so a type whose bulk is its `implements` surface is being reported for a size no
 * decomposition reaches. When the dictated members are the MAJORITY and the ones the type owns
 * are within the member cap, the member clause is dropped; the LINE clause never is.
 * `contractFacade` carries both conditions, the measured distribution behind them and what the
 * carve-out loses; `dictatedMemberCount` carries why resolvability is settled before membership.
 * It needs a `SymbolIndexHost` plugin to resolve the interfaces at all, so a scope too narrow to
 * hold them keeps reporting — this gate can only ever fall silent on evidence.
 *
 * ## Grammar-agnostic
 *
 * Type bodies are the plugin's `RefShape.visibilityContainerKinds` — for Haxe the class-like declarations (class / abstract class
 * / abstract); an interface, enum, enum abstract or typedef is deliberately out of scope (a grammar-sized enum is a definition
 * table, not a decomposition candidate). A grammar that declares no containers or no member kinds makes the check a no-op. The
 * thresholds are the built-in defaults unless a discovered `apqlint.json`
 * configures `maxMembers` / `maxLines` on the `oversized-type` rule, or grants a type a CEILING of its own
 * (`readGrant`: silent within it, reported again past it).
 */
@:nullSafety(Strict)
final class OversizedType implements Check implements ConfigAware implements VolatileMessage implements NoAutofix {

	/**
	 * The member count above which a type is flagged — generous enough that only
	 * genuine god-types trip it; used unless an `apqlint.json` configures `maxMembers`.
	 */
	private static inline final DEFAULT_MAX_MEMBERS: Int = 50;

	/**
	 * The line extent above which a type is flagged — generous enough that only
	 * genuine god-files trip it; used unless an `apqlint.json` configures `maxLines`.
	 */
	private static inline final DEFAULT_MAX_LINES: Int = 2000;

	/**
	 * The fragment that follows the LINE EXTENT in the message — shared by the message
	 * builder and by `messageIdentity`, so the anchor cannot drift away from the wording it
	 * points at.
	 */
	private static inline final LINES_UNIT: String = ' lines (max ';

	/**
	 * The same, for the MEMBER count. Masked too: a type gaining one member re-keys a finding
	 * that neither appeared nor went away, and such re-keys are what a blast-radius report is
	 * made of. The `(max N)` threshold beside it stays unmasked — a configuration change IS a
	 * change the gate must show.
	 */
	private static inline final MEMBERS_UNIT: String = ' members (max ';

	/**
	 * Share of the members that SURVIVE hub extraction which one `hxq clusters` component
	 * must hold for the finding to stop pointing at that tool. Chosen from the distribution over
	 * this project's own findings, which is bimodal rather than smooth — a blob's largest
	 * component holds well over three quarters of its members, a type with a real seam well
	 * under two thirds — so the value sits in the gap and needs no tuning.
	 */
	private static inline final BLOB_SHARE: Float = 0.7;

	/**
	 * The message tail when `hxq clusters` still has something to show — the finding names
	 * the tool that answers "along which lines does this split?".
	 */
	private static inline final SEAM_TAIL: String = ' — a decomposition candidate (see hxq clusters)';

	/**
	 * The message tail when it does not, and the reason this rule stopped being a heuristic
	 * false positive on one shape. A single-algorithm type — a layout engine, a dataflow
	 * lattice, a wrapping decision table — has every member reachable from every other, so
	 * connected components return the whole type and the tool the old wording pointed at
	 * answers "no seam here" after a run the reader pays for. Naming that up front turns a
	 * finding nobody could act on into one that says WHICH KIND of decomposition is left.
	 */
	private static inline final NO_SEAM_TAIL: String =
		' — a decomposition candidate; no member-reference seam — look for an architectural one (a command / handler / responsibility per module)';

	/** Separator between a grant's HEAD (`<Name> <= <ceiling>`) and the reason it is granted, in an `apqlint.json` entry. */
	private static inline final GRANT_SEP: String = ':';

	/** The grant shape after its name, as every refusal spells it — the one shape `readGrant` accepts. */
	private static inline final GRANT_SHAPE: String = ' <= <N> members / <M> lines: <reason>';

	/** The relaxation of `GRANT_SHAPE` a refusal adds: a grant need not give both ceilings. */
	private static inline final EITHER_CLAUSE: String = 'either ceiling alone is accepted, members first when both are given';

	/** The fragment that opens a reported type's grant clause — the grant was not enough for its current size. */
	private static inline final BEYOND_GRANT: String = ' — beyond its grant \'';

	/** This rule's id — the key its `apqlint.json` options sit under, and the `rule` field of its findings. */
	private static inline final RULE_ID: String = 'oversized-type';

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a type with too many behaviour members or lines (constants are not counted) — a decomposition candidate';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final containerKinds: Array<String> = shape.visibilityContainerKinds ?? [];
		final memberKinds: Array<String> = shape.memberDeclKinds ?? [];
		if (containerKinds.length == 0 || memberKinds.length == 0) return [];
		var index: Null<SymbolIndex> = null;
		var indexAsked: Bool = false;
		final told: Array<String> = [];
		return RunScan.collect(files, plugin, (entry, tree, violations) -> {
			final config: LintConfig = LintConfig.resolveWith(_resolveConfig, entry.file);
			var graph: Null<CallGraph> = null;
			final maxMembers: Int = config.intOption(RULE_ID, 'maxMembers') ?? DEFAULT_MAX_MEMBERS;
			final maxLines: Int = config.intOption(RULE_ID, 'maxLines') ?? DEFAULT_MAX_LINES;
			final grants: GrantList = readGrants(config, maxMembers, maxLines);
			// Every file of a run resolves the config again; a refused entry is one finding per run.
			for (problem in grants.problems) if (!told.contains(problem)) {
				told.push(problem);
				violations.push(configProblem(problem));
			}
			final cfg: OversizedCfg = {
				containerKinds: containerKinds,
				memberKinds: memberKinds,
				conditionalKind: shape.conditionalMemberKind,
				maxMembers: maxMembers,
				maxLines: maxLines,
				granted: grants.granted,
				constants: constantClassifier(plugin, entry.source, tree),
				noSeam: typeName -> {
					final built: CallGraph = graph ?? CallGraph.build([entry], plugin);
					graph = built;
					noMemberSeam(built, typeName);
				},
				dictated: (typeName, names) -> {
					if (!indexAsked) {
						indexAsked = true;
						index = hostIndex(plugin);
					}
					dictatedMemberCount(index, entry.file, typeName, names);
				}
			};
			walk(violations, entry.file, entry.source, tree, cfg);
		});
	}

	/** Splitting a type is a design decision, not a mechanical autofix — report-only. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	public function noAutofixReason(): String {
		return 'which members split off into which new type is a decomposition decision — `apq clusters` proposes one and'
			+ ' `apq move-member` carries it out, and neither is a span rewrite this rule could make on its own';
	}

	/**
	 * BOTH measurements are masked; the two `(max N)` thresholds are not.
	 *
	 * The line extent moves whenever the file is reformatted or edited at all. The member count
	 * seems to move only when a member is written or deleted, and therefore to BE the finding;
	 * that argument is wrong: writing a member elsewhere in the type moves the count without
	 * touching this finding, which stood before and stands after, and every such bump is an
	 * added plus a removed line in the blast-radius gate. Crossing the limit is what makes the
	 * finding appear, and the key shows that on its own.
	 *
	 * Nothing else in the message discriminates by these numbers — the type NAME is there, and
	 * is unique per file — so masking them merges no two findings. Not a guarantee, and the two
	 * shapes that would break it are visible from here: `checkType` writes `<anonymous>` for a
	 * nameless container, and a `#if`/`#else` pair declaring one type twice projects two
	 * same-named siblings. (Contrast `duplicate-code` and `fragmented-doc-comment`, whose counts
	 * are kept precisely because they are the last discriminator their keys have.) Both numbers
	 * stay in the MESSAGE; only the key loses them.
	 *
	 * The price, taken knowingly: no magnitude bound — a type growing by hundreds of members
	 * reports the same nothing as one growing by one.
	 *
	 * Crossing a threshold is still reported, in both directions: a type not previously over
	 * either limit gains a finding, and one already over on members gains the `and N lines`
	 * clause, which no mask can turn back into the shorter text.
	 */
	public function messageIdentity(message: String): String {
		return MessageMask.maskBefore(MessageMask.maskBefore(message, MEMBERS_UNIT), LINES_UNIT);
	}

	/**
	 * Walk `node`; for every type-body descendant emit a `Warning` when either
	 * size threshold is exceeded.
	 */
	private static function walk(out: Array<Violation>, file: String, source: String, node: QueryNode, cfg: OversizedCfg): Void {
		if (cfg.containerKinds.contains(node.kind)) checkType(out, file, source, node, cfg);
		for (c in node.children) walk(out, file, source, c, cfg);
	}

	/**
	 * Append ONE `Warning` naming every exceeded threshold when `type` is over either limit. The reported span is the
	 * type's HEADER LINE only, NOT the whole body: inline suppression clears a finding whose span covers the `// noqa`
	 * line, so a whole-body span would let any unrelated bare `// noqa` deep inside the type silently swallow the
	 * type-level finding — and the god-files this check targets are exactly the ones that accumulate those. Suppressing
	 * this rule is deliberate: `// noqa: oversized-type` on the header line. Bails (no finding) when the node has no span.
	 */
	private static function checkType(out: Array<Violation>, file: String, source: String, type: QueryNode, cfg: OversizedCfg): Void {
		final span: Null<Span> = type.span;
		if (span == null) return;
		final name: String = type.name ?? '<anonymous>';
		final grant: Null<OversizedGrant> = cfg.granted.find(g -> g.name == name);
		final maxMembers: Int = grant?.members ?? cfg.maxMembers;
		final maxLines: Int = grant?.lines ?? cfg.maxLines;
		final all: Array<MemberAt> = membersOf(type, cfg);
		final extent: Int = lineExtent(source, span);
		// Leaving the constants out only ever LOWERS both measurements, so a type within both limits is never classified.
		final constant: Array<Bool> = all.length > maxMembers || extent > maxLines ? cfg.constants(all) : [for (_ in all) false];
		final names: Array<String> = [for (i => m in all) if (!constant[i]) m.node.name ?? ''];
		final members: Int = names.length;
		final lines: Int = extent - constantLines(source, span.from, all, constant);
		final over: Array<String> = [];
		if (members > maxMembers && !contractFacade(members, cfg.dictated(name, names), maxMembers))
			over.push('$members$MEMBERS_UNIT$maxMembers)');
		if (lines > maxLines) over.push('$lines$LINES_UNIT$maxLines)');
		if (over.length == 0) return;
		final beyond: String = grant == null ? '' : '$BEYOND_GRANT${grant.head}\'';
		final headerEnd: Int = source.indexOf('\n', span.from);
		out.push({
			file: file,
			span: new Span(span.from, headerEnd == -1 ? span.to : headerEnd),
			rule: RULE_ID,
			severity: Severity.Warning,
			message: 'type \'$name\' has ${over.join(' and ')}$beyond${cfg.noSeam(name) ? NO_SEAM_TAIL : SEAM_TAIL}'
		});
	}

	/**
	 * The grants this project declares in `apqlint.json`
	 * (`"oversized-type": { "grants": ["Renderer <= 71 members / 4150 lines: <reason>", …] }`),
	 * each read by `readGrant`, and the refusals: one line per entry left out.
	 *
	 * The loader needed no change for this: `rules` carries an arbitrary option bag per rule id
	 * and `LintConfig.stringListOption` already reads a list of strings out of it, so the grant
	 * is a config key rather than a second mechanism. The alternative in the brief — a grant
	 * META on the type — would have put the exemption in the file it exempts, where it reads as
	 * a property of the code rather than as a project decision, and would have needed a new
	 * reader per grammar.
	 *
	 * Two grants naming one type are two ceilings for it, and neither is the obvious one: both
	 * are refused, so the type keeps its finding until the list says which it means.
	 */
	private static function readGrants(config: LintConfig, maxMembers: Int, maxLines: Int): GrantList {
		final read: Array<OversizedGrant> = [];
		final problems: Array<String> = [];
		for (entry in config.stringListOption(RULE_ID, 'grants') ?? []) {
			final grant: Null<OversizedGrant> = readGrant(entry.trim(), maxMembers, maxLines, problems);
			if (grant != null) read.push(grant);
		}
		final granted: Array<OversizedGrant> = [];
		for (grant in read) {
			if (read.count(g -> g.name == grant.name) == 1) {
				granted.push(grant);
				continue;
			}
			final twice: String =
				'$RULE_ID: two grants name "${grant.name}" — one ceiling per type, so both are refused and the type keeps its finding';
			if (!problems.contains(twice)) problems.push(twice);
		}
		return { granted: granted, problems: problems };
	}

	/**
	 * One `grants` entry read STRICTLY, or null with the reason pushed to `problems`: a grant
	 * this cannot read is never a silent grant, and never a silent no-op either.
	 *
	 * The shape is `<Name> <= <N> members / <M> lines: <reason>`, either clause alone accepted
	 * (members first when both are written). A ceiling REPLACES the rule's threshold for that
	 * type and that dimension, so the type is reported again the moment it grows past what was
	 * granted; a dimension with no ceiling keeps the threshold. Refused:
	 *
	 * - **no reason** after the `:`: `// noqa: oversized-type` already suppresses this rule
	 *   anonymously on the header line, and a grant list that accepted a bare name would be the
	 *   same thing one file further away. The reason is what a later reader disagrees with.
	 * - **no ceiling** (`Name: reason`, the syntax before ceilings): it silenced the type at any
	 *   size, which is what the ceiling exists to end — refused with the migration spelled out,
	 *   and the type's own finding, which comes back, gives the size to start from.
	 * - **a ceiling at or below the threshold**: it grants nothing, and reading it as a TIGHTER
	 *   limit would report a type no other type of its size is reported for.
	 * - **any other head**, digits past nine included (no ceiling needs them, and `parseInt`
	 *   would read them differently per target).
	 */
	private static function readGrant(entry: String, maxMembers: Int, maxLines: Int, problems: Array<String>): Null<OversizedGrant> {
		final at: Int = entry.indexOf(GRANT_SEP);
		final head: String = (at < 0 ? entry : entry.substring(0, at)).trim();
		final identifier: EReg = ~/^[A-Za-z_][A-Za-z0-9_]*$/;
		if (at < 0 || entry.substr(at + 1).trim().length == 0) {
			final name: String = identifier.match(head) ? head : '<Name>';
			problems.push(
				'$RULE_ID grant "$head" gives no reason after "$GRANT_SEP" — refused, the type keeps its finding; write "$name$GRANT_SHAPE"'
			);
			return null;
		}
		if (identifier.match(head)) {
			problems.push(
				'$RULE_ID grant "$head" has no ceiling — a ceiling-less grant silenced the type at any size, so it is refused and the '
				+ 'type keeps its finding, which gives its current size; write "$head$GRANT_SHAPE" ($EITHER_CLAUSE)'
			);
			return null;
		}
		final cut: Int = head.indexOf('<=');
		final name: String = cut < 0 ? '' : head.substring(0, cut).trim();
		if (identifier.match(name)) return readCeilings(name, head, head.substring(cut + 2).split('/'), maxMembers, maxLines, problems);
		problems.push(malformedGrant(head));
		return null;
	}

	/**
	 * The grant `head` spells for the type `name`, read from its `/`-separated ceiling clauses,
	 * or null with the reason pushed to `problems` — the half of `readGrant` past the name.
	 */
	private static function readCeilings(
		name: String, head: String, clauses: Array<String>, maxMembers: Int, maxLines: Int, problems: Array<String>
	): Null<OversizedGrant> {
		var members: Null<Int> = null;
		var lines: Null<Int> = null;
		// Judged once every clause has read: a malformed head is refused as malformed, whatever its first ceiling says.
		var grantsNothing: Bool = false;
		final clause: EReg = ~/^\s*([0-9]{1,9})\s+(members|lines)\s*$/;
		for (i => text in clauses) {
			final ceiling: Null<Int> = clause.match(text) ? Std.parseInt(clause.matched(1)) : null;
			final unit: String = ceiling == null ? '' : clause.matched(2);
			if (unit == 'members' && i == 0) {
				members = ceiling;
			} else if (unit == 'lines' && lines == null) {
				lines = ceiling;
			} else {
				problems.push(malformedGrant(head));
				return null;
			}
			if (ceiling != null && ceiling <= (unit == 'members' ? maxMembers : maxLines)) grantsNothing = true;
		}
		if (grantsNothing) {
			problems.push(
				'$RULE_ID grant "$head" is not above the rule\'s thresholds ($maxMembers members / $maxLines lines), so it grants'
				+ ' nothing — refused, the type keeps its finding'
			);
			return null;
		}
		final ceilings: Array<String> = [];
		if (members != null) ceilings.push('$members members');
		if (lines != null) ceilings.push('$lines lines');
		return {
			name: name,
			members: members,
			lines: lines,
			head: '$name <= ${ceilings.join(' / ')}'
		};
	}

	/** The refusal of a grant whose head `readGrant` cannot read at all. */
	private static function malformedGrant(head: String): String {
		return '$RULE_ID grant "$head" is malformed — expected "<Name>$GRANT_SHAPE" ($EITHER_CLAUSE); refused, the type keeps its finding';
	}

	/** The file-less finding for one refused `grants` entry — the shape `thread-safety` reports its unreadable options in. */
	private static function configProblem(problem: String): Violation {
		return {
			file: '',
			span: null,
			rule: RULE_ID,
			severity: Severity.Warning,
			message: problem
		};
	}

	/**
	 * Whether `hxq clusters` would find NO member-reference seam in `typeName`: one connected
	 * component holds at least `BLOB_SHARE` of the members that survive hub extraction.
	 *
	 * This ASKS the tool the message names rather than re-deriving its answer — `Clusters` owns
	 * the definition of a component, and two answers to one question is the defect this project
	 * keeps finding in itself. The graph is built over the ONE file the type is declared in,
	 * which is what `apq clusters <Type> <file>` does and what `BLOB_SHARE` was calibrated
	 * with; a whole-project scope is far slower and only adds unresolved-call noise. It is also
	 * LAZY — built on the first type in a file that is actually over a threshold, so a tree
	 * where nothing trips this rule pays nothing.
	 *
	 * FALSE when the graph holds no members for the type — a type of fields with no methods has
	 * no call graph at all, and `clusters` will say so; pointing the reader at it is honest
	 * there in a way that claiming "no seam" would not be.
	 */
	private static function noMemberSeam(graph: CallGraph, typeName: String): Bool {
		final report: Null<ClusterReport> = Clusters.analyze(graph, typeName, null, null);
		if (report == null) return false;
		var nonHub: Int = 0;
		var largest: Int = 0;
		for (component in report.components) {
			nonHub += component.length;
			if (component.length > largest) largest = component.length;
		}
		return nonHub > 0 && largest >= nonHub * BLOB_SHARE;
	}

	/**
	 * The member declarations among `parent`'s children, in document order, each with the node whose DIRECT
	 * child it is (the modifier run before it is read there), recursing into `#if` conditional-compilation blocks
	 * so guarded members count too — an `#if` and its `#else` branches ALL count (a source-size metric measures
	 * what is written, not one compiled configuration). Modifier siblings (visibility / static runs preceding a
	 * member) are separate nodes whose kinds are not in `memberKinds`, so they are never counted.
	 *
	 * The behaviour members among them are the member metric; their names feed the interface carve-out. A
	 * nameless member projects as the empty string, which no interface can declare, so it counts toward the
	 * total and never toward the dictated share.
	 */
	private static function membersOf(parent: QueryNode, cfg: OversizedCfg): Array<MemberAt> {
		final out: Array<MemberAt> = [];
		for (child in parent.children) {
			if (cfg.conditionalKind != null && child.kind == cfg.conditionalKind)
				for (nested in membersOf(child, cfg)) out.push(nested);
			else if (cfg.memberKinds.contains(child.kind))
				out.push({ node: child, host: parent });
		}
		return out;
	}

	/** The number of source lines `span` covers — newlines in the slice + 1. */
	private static function lineExtent(source: String, span: Span): Int {
		return newlinesIn(source, span.from, span.to) + 1;
	}

	/** The number of line breaks in `source` from `from` (inclusive) to `to` (exclusive). */
	private static function newlinesIn(source: String, from: Int, to: Int): Int {
		var count: Int = 0;
		for (i in from ... to) if (source.fastCodeAt(i) == '\n'.code) count++;
		return count;
	}

	/**
	 * How many of a type's lines belong to its CONSTANTS — the line half of A13, kept in step with the member
	 * half: a constant is neither a member nor lines of the type.
	 *
	 * Every line of the type belongs to the member that ENDS it: the lines after the previous member's last line
	 * (after the header line, for the first member) through this member's own last line. A member therefore owns
	 * its doc comment, its annotations and the blank lines and section comments written above it, which in a
	 * table are the table's. A constant's lines are left out, except a last line a behaviour member also starts
	 * on — there is behaviour on that line. The header line and what follows the last member (the closing brace)
	 * always count, so a type with no constant gets 0 here and its line extent is exactly what it was.
	 */
	private static function constantLines(source: String, typeFrom: Int, members: Array<MemberAt>, constant: Array<Bool>): Int {
		var lines: Int = 0;
		var previousEnd: Int = typeFrom;
		for (i => member in members) {
			final span: Null<Span> = member.node.span;
			if (span == null) continue;
			if (constant[i]) {
				final next: Null<Span> = i + 1 < members.length && !constant[i + 1] ? members[i + 1].node.span : null;
				final owned: Int = newlinesIn(source, previousEnd, span.to);
				final shared: Bool = next != null && newlinesIn(source, span.to, next.from) == 0;
				lines += shared && owned > 0 ? owned - 1 : owned;
			}
			previousEnd = span.to;
		}
		return lines;
	}

	/**
	 * The constant classifier of ONE file, for `OversizedCfg.constants`. Lazy: a file where no type is over a
	 * threshold never builds the accessor map or walks for enum-abstract hosts. When the grammar leaves a seam
	 * the whitelist needs unset, nothing is a constant and every member counts — a constant this rule cannot
	 * prove is counted, never dropped.
	 */
	private static function constantClassifier(plugin: GrammarPlugin, source: String, tree: QueryNode): (Array<MemberAt>) -> Array<Bool> {
		var kit: Null<ConstantKit> = null;
		return members -> {
			final built: Null<ConstantKit> = kit ?? constantKit(plugin, source, tree);
			kit = built;
			built == null ? [for (_ in members) false] : constantFlags(members, source, built);
		};
	}

	/** What `isConstant` reads for one file, or null when the grammar or the plugin cannot answer it. */
	private static function constantKit(plugin: GrammarPlugin, source: String, tree: QueryNode): Null<ConstantKit> {
		final seams: Null<ConstantFieldSeams> = ConstantFieldScan.seams(plugin);
		final info: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		return seams == null || info == null ? null : {
			seams: seams,
			leading: CheckScan.modifierKinds(plugin.refShape()).concat(seams.metaKinds),
			accessors: info.propertyAccessors(source),
			valueStarts: EnumAbstractForms.valueStarts(plugin, tree)
		};
	}

	/**
	 * Which of `members` are CONSTANTS — the declarations the size of a type does not count (A13, the user's
	 * decision of 2026-10-18: a type's size is its behaviour, and a table of constants is not a decomposition
	 * candidate). Read to a fixpoint, because a constant may be written in terms of another one declared anywhere
	 * in the type: a member joins once its initializer is constant given the members already in, and the loop ends
	 * on a pass that adds none — so a reference cycle stays out.
	 */
	private static function constantFlags(members: Array<MemberAt>, source: String, kit: ConstantKit): Array<Bool> {
		final flags: Array<Bool> = [for (_ in members) false];
		final isConstantName: (String) -> Bool = name -> namesOnlyConstants(members, flags, name);
		var grew: Bool = true;
		while (grew) {
			grew = false;
			for (i => member in members) if (!flags[i] && isConstant(member, source, kit, isConstantName)) {
				flags[i] = true;
				grew = true;
			}
		}
		return flags;
	}

	/**
	 * Whether `name` names at least one of `members`, and only ones already `flags`ged constant — what an
	 * identifier in a constant's initializer has to resolve to. A name the type does not declare is an import, a
	 * module-level or an inherited symbol this rule does not resolve, so it proves nothing.
	 */
	private static function namesOnlyConstants(members: Array<MemberAt>, flags: Array<Bool>, name: String): Bool {
		var named: Bool = false;
		for (i => member in members) if (member.node.name == name) {
			if (!flags[i]) return false;
			named = true;
		}
		return named;
	}

	/**
	 * Whether ONE member is a constant, read as a POSITIVE whitelist — anything it does not name is behaviour (or
	 * state) and counts, exactly as before N41:
	 *
	 * - a `static` FINAL field with an initializer and no accessor clause whose value is known: either it is
	 *   `inline` — Haxe's own proof, since the compiler refuses `inline` on an initializer it cannot fold — or
	 *   its initializer is one `ConstantFieldScan.isConstantExpression` accepts;
	 * - a non-`static` field of an `@:enum abstract` (`EnumAbstractForms`; an `enum abstract` is no container of
	 *   this rule at all) with no accessor clause and either no initializer (an implicit value) or a constant one.
	 *
	 * Not a constant: a `static var`, `inline` or not (the user's whitelist names finals); an instance `final`; a
	 * property; a function; and a `static final` initialized by a call, a field access, a cast, an allocation, an
	 * interpolated string, `null`, or a name that is not a constant of this type.
	 */
	private static function isConstant(member: MemberAt, source: String, kit: ConstantKit, isConstantName: (String) -> Bool): Bool {
		final node: QueryNode = member.node;
		final span: Null<Span> = node.span;
		final seams: ConstantFieldSeams = kit.seams;
		if (span == null || kit.accessors.exists(span.from)) return false;
		final run: Array<QueryNode> = MemberKinds.precedingModifiers(node, member.host, kit.leading);
		final init: Null<QueryNode> = ConstantFieldScan.initializerOf(node);
		if (run.exists(m -> m.kind == seams.staticKind)) {
			if (!seams.finalFieldKinds.contains(node.kind) || init == null) return false;
			final compilerFolds: Bool = run.exists(m -> m.kind == seams.inlineKind);
			return compilerFolds || ConstantFieldScan.isConstantExpression(init, source, seams, isConstantName);
		}
		if (!EnumAbstractForms.isValue(span, kit.valueStarts)) return false;
		final field: Bool = seams.finalFieldKinds.contains(node.kind) || seams.mutableFieldKinds.contains(node.kind);
		return field && (init == null || ConstantFieldScan.isConstantExpression(init, source, seams, isConstantName));
	}

	/**
	 * The resolution-scoped `SymbolIndex` the interface carve-out resolves through, or null when
	 * `plugin` hosts none.
	 *
	 * Gated on `SymbolIndexHost` the same way `unused-private` reaches its widest scope, and on
	 * `hasAnyResolutionScope` rather than `hasDeclaredResolutionScope`: the interfaces this
	 * carve-out must resolve are the ones the linted type WRITES in its own `implements` clause,
	 * so the report scope is where they live and an implicit std-only scope is no hazard — a std
	 * interface a project type implements is exactly as dictating as a local one. Null here means
	 * the carve-out cannot run, and a carve-out that cannot run reports, never silences.
	 */
	private static function hostIndex(plugin: GrammarPlugin): Null<SymbolIndex> {
		final host: Null<SymbolIndexHost> = plugin is SymbolIndexHost ? cast plugin : null;
		return host?.resolutionIndex();
	}

	/**
	 * How many of `members` the type's own `implements` clause DICTATES — declared by one of the
	 * interfaces it names, transitively through that interface's own supertypes — or null when
	 * the question cannot be answered here.
	 *
	 * Null in four cases, every one of which leaves the finding standing: no index, the file not
	 * in it, the type not in that file's declarations, or ANY implemented interface unresolvable
	 * in the scope. The last one is the whole reason this function exists rather than a bare
	 * `MemberLookup.implementsInterfaceDeclaringMember` loop. That predicate answers
	 * "declares it OR is unresolvable" and is consumed by `make-final`, where a spurious true
	 * means "skip the rewrite" and is therefore free. Consumed HERE the same true would mean
	 * "this member is dictated" — one unresolvable interface would make every member look
	 * dictated and silence the finding on a type nobody has proved anything about. So
	 * resolvability is settled first, through the same resolver `typeProvablyLacksMember` itself
	 * starts from (`TypeRefIndex.resolveStartType`, against the OWNER's file, since an
	 * `implements` entry is a simple name written in that file's scope), and only then is the
	 * membership question asked.
	 */
	private static function dictatedMemberCount(
		index: Null<SymbolIndex>, file: String, typeName: String, members: Array<String>
	): Null<Int> {
		if (index == null) return null;
		final info: Null<FileInfo> = index.fileInfo(file);
		if (info == null) return null;
		final decl: Null<TypeDeclInfo> = info.types.find(t -> t.name == typeName);
		if (decl == null) return null;
		final interfaces: Array<String> = decl.interfaces;
		if (interfaces.length == 0) return 0;
		for (iface in interfaces) if (index.refs.resolveStartType(iface, file) == null) return null;
		return (members.count(
			member -> member.length > 0 && interfaces.exists(i -> !index.typing.members.typeProvablyLacksMember(i, member, file))
		): Int);
	}

	/**
	 * Whether a type's member count is DICTATED rather than authored — the carve-out that stops
	 * this rule firing on a contract facade.
	 *
	 * The finding says "decomposition candidate", and decomposition can only move members the
	 * type OWNS. A member an implemented interface declares cannot leave without breaking the
	 * contract, so a type whose bulk is its `implements` surface is being reported for a size its
	 * author cannot reduce by splitting: the seam there is in the INTERFACE SET, an architecture
	 * decision, not in the member list.
	 *
	 * Two conditions, and each one is load-bearing:
	 *
	 * - **the dictated members are at least half** (`dictated >= own`). Over this project's own
	 *   findings the dictated share is bimodal with nothing in between — a plugin implementing
	 *   five interfaces has most of its members dictated, every other oversized type a tenth or
	 *   fewer — so a half needs no tuning and states the claim directly.
	 * - **the OWN members are within the cap** (`own <= maxMembers`). Without it a type with 300
	 *   authored members behind 400 dictated ones would be silenced by the share alone. With it
	 *   the carve-out can only ever forgive the dictated surface, never a type that is fat in its
	 *   own right — which is exactly what it must not do.
	 *
	 * What it loses, said plainly: a god-class that got that way by implementing a god-interface
	 * is no longer reported by THIS rule. That is deliberate — the size is real, but the lever is
	 * the interface, and pointing a member-count metric at it produces a finding whose only
	 * honest fix is out of the metric's reach. The LINE extent is untouched by the carve-out, so
	 * such a type still reports the moment its dictated members grow long rather than numerous.
	 */
	private static function contractFacade(members: Int, dictated: Null<Int>, maxMembers: Int): Bool {
		if (dictated == null) return false;
		final own: Int = members - dictated;
		return own <= maxMembers && dictated >= own;
	}

}

/**
 * Resolved kind-sets and thresholds for the oversized-type walk, built once per
 * file so the recursion threads one struct.
 */
private typedef OversizedCfg = {
	final containerKinds: Array<String>;
	final memberKinds: Array<String>;
	final conditionalKind: Null<String>;
	final maxMembers: Int;
	final maxLines: Int;
	final granted: Array<OversizedGrant>;
	final constants: (Array<MemberAt>) -> Array<Bool>;
	final noSeam: (String) -> Bool;
	final dictated: (String, Array<String>) -> Null<Int>;
};

/** One member declaration of a type, with the node whose DIRECT child it is — the type, or a `#if` region in it. */
private typedef MemberAt = {
	final node: QueryNode;
	final host: QueryNode;
};

/** What `OversizedType.isConstant` reads for one file — resolved once, on the first type that needs it. */
private typedef ConstantKit = {
	final seams: ConstantFieldSeams;

	/** The kinds a member's leading run may hold (modifiers and annotations) — where its `static` / `inline` sit. */
	final leading: Array<String>;

	/** `TypeInfoProvider.propertyAccessors`: the span starts of the members that carry an accessor clause. */
	final accessors: Map<Int, Bool>;

	/** `EnumAbstractForms.valueStarts`: the span starts of the members of an `@:enum abstract`. */
	final valueStarts: Array<Int>;
};

/**
 * One `grants` entry as `OversizedType.readGrant` accepted it: the type it names, its ceiling per dimension (null where
 * the grant gives none, so the rule's threshold holds there) and its head as a finding quotes it.
 */
private typedef OversizedGrant = {
	final name: String;
	final members: Null<Int>;
	final lines: Null<Int>;
	final head: String;
};

/** What `OversizedType.readGrants` made of one config's `grants`: the accepted grants and one line per refused entry. */
private typedef GrantList = {
	final granted: Array<OversizedGrant>;
	final problems: Array<String>;
};
