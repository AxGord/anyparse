package anyparse.check.common.members;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.OptionKeyed;
import anyparse.check.Check.RiskyArm;
import anyparse.check.Check.RiskyCrossFileEdit;
import anyparse.check.LintConfig;
import anyparse.check.scan.CheckScan;
import anyparse.check.scan.ReflectionScan;
import anyparse.query.MemberKinds;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;

/** The resolved seams `PreferFinalClass` reads in both `run` and `fix`. */
private typedef Seams = {
	final metaName: String;
	final plainKind: String;
	final finalKind: String;
	final metaKinds: Array<String>;
};

private typedef Candidate = { var metaSpan: Span; var redundant: Bool; var declFrom: Int; };

/** What the closed-world arm reads of the grammar, resolved once per run. */
private typedef ClosedSeams = {
	final plainKind: String;
	final leadKinds: Array<String>;
	final externKind: String;
	final finalMetaName: String;
};

/** A plain class the closed-world arm may flag: its file, its name and the span of its class keyword. */
private typedef ClassHead = { final file: String; final name: String; final keyword: Span; };

/**
 * Flags a class declaration carrying the `@:final` metadata tag — the user's rule: use
 * `final class`, not the `@:final` meta, for a class not designed for inheritance.
 * `Severity.Info` (a style cleanup), with an autofix that removes the `@:final` meta and
 * inserts the `final` modifier before the `class` keyword. When the class ALREADY carries
 * the `final` modifier (a redundant `@:final final class`), the fix removes the meta only.
 *
 * Grammar-agnostic over `RefShape.finalClassMetaName` / `plainClassDeclKind` /
 * `finalClassDeclKind` (any unset -> no-op) plus `MetaShape.metaKinds`.
 *
 * ## What is flagged
 *
 * A meta node named `finalClassMetaName` whose decorated declaration — the nearest
 * following sibling that is not itself a meta, in SOURCE order (by span, so child-array
 * order and intervening metas / doc comments do not mislead) — is a plain class
 * (`plainClassDeclKind`) or an already-`final` class (`finalClassDeclKind`). The finding
 * spans only the `@:final` meta token, not the class body, so a `// noqa` inside the body
 * cannot swallow it.
 *
 * ## Deliberate misses
 *
 * - `@:final` on an interface / enum / enum abstract / typedef / `abstract class` — none is a
 *   class the `final` modifier applies to (`final abstract class` is not valid Haxe), so the
 *   meta is left alone.
 * - `@:final` on a method or field (a final method / field) — its decorated decl is a member,
 *   not a class.
 * - A `final class` with no `@:final` meta — already idiomatic.
 *
 * ## The closed-world arm
 *
 * Under the rule's option `closedWorld` a plain class nothing in the run's resolution scope extends is flagged too, and
 * `fix`-ing it inserts `final ` before its class keyword. The subtype index (`SubtypeGraph.hasSubtype`) answers "nothing
 * extends it" over qualified paths, import aliases and every `#if` branch; a class in a build-macro closure, one a string
 * literal names as a type path, one an unreadable file of the scope spells, an extern class and a class declared under `#if`
 * are left alone. The arm is a `RiskyArm`: this trusted `fix` hands its findings over (`declineReason`) and the edit comes
 * from `riskyFix`, so it lands only where the compiler oracle accepts it — a subtype the scope does not see is `Cannot
 * extend a final class`, reverted — while the `@:final` meta arm keeps its unverified fix. A class the meta arm owns is never
 * flagged by both.
 */
@:nullSafety(Strict)
final class PreferFinalClass extends RuleBase implements ConfigAware implements OptionKeyed implements RiskyArm {

	private static inline final RULE_ID: String = 'prefer-final-class';
	private static final MODIFIER: String = 'final ';

	/** The reason the trusted arm leaves a closed-world finding alone. */
	private static final RISKY_ARM: String = 'nothing in the closed world extends this class, but a subtype outside what the run sees '
		+ 'would break — the fix is applied only through the compiler oracle';

	/** The option declaring that every file that can extend a class is in the run or a declared resolution root. */
	private static final CLOSED_WORLD_KEY: String = 'closedWorld';

	/** The finding of each class the closed-world arm flags, by file and the span of its class keyword. */
	private final _unextended: Array<String> = [];

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(RULE_ID, 'a class not designed for inheritance — prefer the final class modifier', RuleCategory.Members);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function acceptedOptions(): Array<String> {
		return [CLOSED_WORLD_KEY];
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		_unextended.resize(0);
		return metaFindings(files, plugin).concat(unextendedFindings(files, plugin));
	}

	/**
	 * Rewrite each flagged class. A plain class gets its `@:final` meta removed and a `final `
	 * modifier inserted before the class keyword; a redundant `@:final final class` gets the
	 * meta removed only. The tree is re-parsed and the candidates re-collected, so each edit is
	 * keyed to the still-present meta span (a guard against any stale span) and its decl
	 * position is re-derived from the same source.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		for (v in violations) if (handedOff(v)) v.declineReason = RISKY_ARM;
		return RunScan.editsWith(plugin, source, resolveSeams(plugin), (tree, seams) -> {
			final byKey: Map<String, Candidate> = [];
			for (c in collect(tree, seams.metaName, seams.metaKinds, seams.plainKind, seams.finalKind))
				byKey['${c.metaSpan.from}:${c.metaSpan.to}'] = c;
			final edits: Array<{ span: Span, text: String }> = [];
			RunScan.eachMatched(violations, byKey, (c, _) -> for (e in editsFor(c, source)) edits.push(e));
			return edits;
		});
	}

	public function riskyArmFindings(violations: Array<Violation>): Array<Violation> {
		return violations.filter(handedOff);
	}

	public function riskyFix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final at: Null<Span> = v.span;
			if (at != null && handedOff(v)) edits.push({ span: at, text: MODIFIER + source.substring(at.from, at.to) });
		}
		return edits;
	}

	public function riskyCrossFileFindings(violations: Array<Violation>): Array<Violation> {
		return [];
	}

	public function riskyCrossFileFix(
		files: Array<{ file: String, source: String }>, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<RiskyCrossFileEdit> {
		return [];
	}

	/** The findings of the `@:final` meta arm. */
	private function metaFindings(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return RunScan.collectWith(files, plugin, resolveSeams(plugin), (entry, tree, seams, violations) -> {
			for (c in collect(tree, seams.metaName, seams.metaKinds, seams.plainKind, seams.finalKind)) violations.push({
				file: entry.file,
				span: c.metaSpan,
				rule: 'prefer-final-class',
				severity: Severity.Info,
				message: c.redundant
					? 'redundant @:final meta on an already-final class — remove it'
					: 'use the final class modifier instead of the @:final meta'
			});
		});
	}

	/** Whether the closed-world arm, not the `@:final` meta arm, owns `v`. */
	private function handedOff(v: Violation): Bool {
		final at: Null<Span> = v.span;
		return at != null && _unextended.contains(CheckScan.spanKey(v.file, at));
	}

	/**
	 * The plain classes of the files whose `closedWorld` option is on that nothing in the run's resolution scope extends. The
	 * subtype index reads every `extends` of the scope — qualified, aliased and under `#if` alike — so a class it finds no
	 * subtype for, that no build macro reaches and no string names, is a class the compiler would let `final`; the rest of what
	 * the run cannot see is the oracle's to refuse.
	 */
	private function unextendedFindings(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<ClosedSeams> = closedSeams(plugin);
		if (seams == null) return [];
		final heads: Array<ClassHead> = [];
		for (item in CheckScan.parseAll(plugin, files)) if (
			LintConfig.resolveWith(_resolveConfig, item.file).boolOption(RULE_ID, CLOSED_WORLD_KEY) == true
		) for (decl in item.tree.children) {
			final head: Null<ClassHead> = headOf(decl, item.tree, item.file, seams);
			if (head != null) heads.push(head);
		}
		if (heads.length == 0) return [];
		final index: SymbolIndex = IndexScope.resolution(RefactorSupport.resolutionProjectSourcesOf(plugin) ?? files, plugin);
		final names: Array<String> = heads.map(h -> h.name);
		final surface: ReflectionSurface = ReflectionScan.reflectionSurface(
			files.filter(entry -> names.exists(n -> entry.source.indexOf(n) >= 0)), plugin
		);
		final out: Array<Violation> = [];
		for (h in heads) if (
			!index.subtypes.hasSubtype(h.name, h.file)
			&& !index.traits.transitivelyCarriesBuildMacro(h.name, h.file)
			&& !index.text.skippedMayReference(h.name, h.file)
			&& !ReflectionScan.runtimeTypePath(surface.whole, h.name)
			&& !ReflectionScan.runtimeTypePathFragment(surface.fragments, h.name)
		) {
			_unextended.push(CheckScan.spanKey(h.file, h.keyword));
			out.push({
				file: h.file,
				span: h.keyword,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'class \'${h.name}\' is extended by nothing in the declared closed world — use the final class modifier'
			});
		}
		return out;
	}

	/**
	 * The one- or two-edit fix for `c`. The meta and its trailing whitespace are cut back to
	 * the first following non-whitespace character (so no blank residue). A redundant class is
	 * that single deletion. A plain class also inserts `final ` before the class keyword: as
	 * ONE combined `[meta, keyword)` replacement when only whitespace separates them (a
	 * zero-width insert adjacent to the deletion would be dropped by the edit-dedup), else as
	 * two disjoint edits so a doc comment or another meta sitting between is preserved.
	 */
	private static function editsFor(c: Candidate, source: String): Array<{ span: Span, text: String }> {
		final metaFrom: Int = c.metaSpan.from;
		final cutTo: Int = firstNonWs(source, c.metaSpan.to);
		return if (c.redundant)
			[{ span: new Span(metaFrom, cutTo), text: '' }]
		else if (cutTo == c.declFrom)
			[{ span: new Span(metaFrom, c.declFrom), text: MODIFIER }]
		else
			[
				{ span: new Span(metaFrom, cutTo), text: '' },
				{ span: new Span(c.declFrom, c.declFrom), text: MODIFIER }
			];
	}

	/** Every `@:final`-on-class candidate in `tree`, in pre-order. */
	private static function collect(
		tree: QueryNode, metaName: String, metaKinds: Array<String>, plainKind: String, finalKind: String
	): Array<Candidate> {
		final out: Array<Candidate> = [];
		walk(tree, metaName, metaKinds, plainKind, finalKind, out);
		return out;
	}

	private static function walk(
		node: QueryNode, metaName: String, metaKinds: Array<String>, plainKind: String, finalKind: String, out: Array<Candidate>
	): Void {
		final children: Array<QueryNode> = node.children;
		for (child in children) if (metaKinds.contains(child.kind) && child.name == metaName) {
			final decl: Null<QueryNode> = nearestNonMetaFollowing(children, child, metaKinds);
			final ms: Null<Span> = child.span;
			if (decl != null && ms != null) {
				final metaSpan: Span = ms;
				final dk: String = decl.kind;
				final ds: Null<Span> = decl.span;
				if ((dk == plainKind || dk == finalKind) && ds != null)
					out.push({ metaSpan: metaSpan, redundant: dk == finalKind, declFrom: ds.from });
			}
		}
		for (child in children) walk(child, metaName, metaKinds, plainKind, finalKind, out);
	}

	/**
	 * The nearest following sibling of `meta`, in source order, that is not itself a meta node
	 * — the declaration the meta decorates. Spans are used (not child-array position, which the
	 * plugin does not guarantee to match source order) and the intervening meta run is skipped,
	 * so `@:final @:keep class`, `@:keep @:final class`, and a `@:final` before a doc-commented
	 * class all resolve the class. A `@:final` before a typedef / enum returns that decl (not a
	 * later class), so the caller's kind check correctly leaves it alone.
	 */
	private static function nearestNonMetaFollowing(
		siblings: Array<QueryNode>, meta: QueryNode, metaKinds: Array<String>
	): Null<QueryNode> {
		final ms: Null<Span> = meta.span;
		if (ms == null) return null;
		final after: Int = ms.from;
		var best: Null<QueryNode> = null;
		var bestFrom: Int = 0;
		for (s in siblings) if (!metaKinds.contains(s.kind)) {
			final ss: Null<Span> = s.span;
			if (ss != null && ss.from > after && (best == null || ss.from < bestFrom)) {
				best = s;
				bestFrom = ss.from;
			}
		}
		return best;
	}

	/** The first index at or after `from` whose character is not whitespace (clamped to length). */
	private static function firstNonWs(source: String, from: Int): Int {
		var i: Int = from;
		while (i < source.length && source.isSpace(i)) i++;
		return i;
	}

	/** Resolve the meta / plain-class / final-class seam kinds, or null when any required kind is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final metaName: Null<String> = shape.finalClassMetaName;
		if (metaName == null) return null;
		final plainKind: Null<String> = shape.plainClassDeclKind;
		if (plainKind == null) return null;
		final finalKind: Null<String> = shape.finalClassDeclKind;
		if (finalKind == null) return null;
		final metaKinds: Array<String> = plugin.metaShape().metaKinds;
		return {
			metaName: metaName,
			plainKind: plainKind,
			finalKind: finalKind,
			metaKinds: metaKinds
		};
	}

	/** `decl` as a closed-world candidate: a plain class that is not extern and carries no `@:final` meta (the meta arm's). */
	private static function headOf(decl: QueryNode, root: QueryNode, file: String, seams: ClosedSeams): Null<ClassHead> {
		final name: Null<String> = decl.name;
		final keyword: Null<Span> = decl.tokenSpans()[0];
		if (decl.kind != seams.plainKind || name == null || keyword == null) return null;
		final lead: Array<QueryNode> = MemberKinds.precedingModifiers(decl, root, seams.leadKinds);
		return lead.exists(m -> m.kind == seams.externKind || m.name == seams.finalMetaName)
			? null
			: { file: file, name: name, keyword: keyword };
	}

	/** The seams of the closed-world arm, or null when the grammar names no plain class kind. */
	private static function closedSeams(plugin: GrammarPlugin): Null<ClosedSeams> {
		final shape: RefShape = plugin.refShape();
		final plainKind: Null<String> = shape.plainClassDeclKind;
		return plainKind == null ? null : {
			plainKind: plainKind,
			leadKinds: (shape.visibilityModifierKinds ?? []).concat(shape.modifierKinds ?? []).concat(plugin.metaShape().metaKinds),
			externKind: shape.externModifierKind ?? '',
			finalMetaName: shape.finalClassMetaName ?? ''
		};
	}

}
