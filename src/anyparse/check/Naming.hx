package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.NamingPolicy.NamedDecl;
import anyparse.query.NamingPolicy.NamingPolicy;
import anyparse.query.NamingPolicy.NamingRule;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.QueryNode;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

import anyparse.query.Rename;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.SymbolIndex;
import anyparse.query.RefactorSupport;

/**
 * Flags declarations whose identifier violates a naming convention. The check
 * is grammar-agnostic: it asks the plugin's `NamingSupport` to project the
 * declarations worth checking (each with a neutral category and modifier set)
 * and to resolve the effective `NamingPolicy` for the file — a discovered
 * `checkstyle.json` when present, else the grammar's built-in default. Every
 * declaration is matched against the first applicable rule; a name failing the
 * rule's `format` is a `Warning`.
 *
 * ## checkstyle compatibility
 *
 * The policy comes from the plugin: for Haxe, `HaxeNamingSupport.policyFor`
 * adapts an existing `checkstyle.json` via `CheckstyleConfigLoader`, mirroring
 * how the writer honours an `hxformat.json`. A project that already ships a
 * checkstyle config gets its naming rules out of the box; the check itself
 * never parses that format — it stays language- and config-neutral.
 *
 * ## No naming support → no-op
 *
 * A grammar without a naming convention (a binary format) returns null from
 * `namingSupport`; the check skips it. Report-only for now — `fix` returns no
 * edits (a rename-based autofix is a later slice).
 */
@:nullSafety(Strict)
final class Naming implements Check {

	public function new() {}

	public function id(): String {
		return 'naming';
	}

	public function description(): String {
		return 'declaration name violates the naming convention (default, or a discovered checkstyle.json)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final support: Null<NamingSupport> = plugin.namingSupport();
		if (support == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree == null) continue;
			for (v in violationsFor(entry.file, support.project(tree), support.policyFor(entry.file))) violations.push(v);
		}
		return violations;
	}

	/**
	 * Autofix: rename each flagged binding to a mechanically-corrected name when the rename is provably complete in this one file. Always safe for function-body-scoped bindings (Local / Param / CatchVar); for a private FIELD only when the cross-file `index` proves it confined (no subtype, no `@:access`, no `@:allow`, no skip-parse file that could hide one) AND every textual occurrence of the name is covered by the resolved rename spans — the scope resolver can miss a bare field reference, so an uncovered occurrence means an incomplete rename and the field is left report-only. The new name comes from the rule's `normalize`; the occurrences from `Rename.renameOccurrences`, emitted as edits the caller batches and re-parse-validates.
	 *
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		if (violations.length == 0) return [];
		final support: Null<NamingSupport> = plugin.namingSupport();
		if (support == null) return [];
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];

		final policy: NamingPolicy = support.policyFor(violations[0].file);
		final shape: RefShape = plugin.refShape();

		final flaggedFroms: Array<Int> = [];
		for (v in violations) {
			final s: Null<Span> = v.span;
			if (s != null) flaggedFroms.push(s.from);
		}

		final edits: Array<{ span: Span, text: String }> = [];
		for (decl in support.project(tree)) {
			final rename: Null<RenameEdits> = renameEditsFor(decl, source, tree, policy, shape, flaggedFroms, index);
			if (rename != null) for (occ in rename.occurrences) edits.push({ span: occ, text: rename.name });
		}
		return edits;
	}

	/**
	 * The violations for `decls` under `policy`: each declaration is tested
	 * against the first rule whose category matches and whose `requireMods` are
	 * all present and `forbidMods` all absent; a name failing that rule's
	 * `format` is a `Warning`. A declaration with no span is skipped (no
	 * location to report), as is one no rule applies to.
	 */
	public static function violationsFor(file: String, decls: Array<NamedDecl>, policy: NamingPolicy): Array<Violation> {
		final out: Array<Violation> = [];
		for (decl in decls) {
			final span: Null<Span> = decl.span;
			if (span == null) continue;
			final rule: Null<NamingRule> = applicableRule(decl, policy);
			if (rule == null || rule.format.match(decl.name)) continue;
			out.push({
				file: file,
				span: span,
				rule: 'naming',
				severity: Severity.Warning,
				message: '${rule.label}: \'${decl.name}\''
			});
		}
		return out;
	}

	/** The first rule in `policy` applicable to `decl` (category + modifier filters), or null. */
	private static function applicableRule(decl: NamedDecl, policy: NamingPolicy): Null<NamingRule> {
		return policy.find(
			rule -> rule.category == decl.category && rule.requireMods.foreach(m -> decl.mods.contains(m))
			&& !rule.forbidMods.exists(m -> decl.mods.contains(m))
		);
	}

	/**
	 * Is the rename of `decl`'s binding provably complete within `source`?
	 * Function-body-scoped bindings always are; a private field is only when the
	 * cross-file `index` plus in-file checks prove it cannot be referenced from
	 * outside its file. Every other category (types, public members) is not.
	 */
	private static function isRenameSafe(decl: NamedDecl, source: String, index: Null<SymbolIndex>): Bool {
		final category: NamingCategory = decl.category;
		if (category == NamingCategory.Local || category == NamingCategory.Param || category == NamingCategory.CatchVar) return true;
		if (category == NamingCategory.Field && !decl.mods.contains('public') && index != null) {
			final owner: Null<String> = decl.enclosingType;
			return owner != null && RefactorSupport.isPrivateMemberConfined(owner, source, index);
		}
		return false;
	}

	/**
	 * Does `node` contain a field access of `name` through a receiver other than
	 * `this`? Such an `other.<name>` is the one in-file access the scope resolver
	 * (hence `Rename.renameOccurrences`) misses, making a single-file rename incomplete.
	 */
	/**
	 * The rename to apply to one projected declaration, or null when it must be
	 * skipped: not among the flagged spans, not rename-safe, no applicable rule
	 * with a normalizer, already conformant, or — for a field whose textual
	 * occurrences the scope resolver does not fully cover — incompletely
	 * renameable (bailed to avoid a dangling reference). When non-null, every
	 * returned occurrence span is rewritten to `name`.
	 */
	private static function renameEditsFor(
		decl: NamedDecl, source: String, tree: QueryNode, policy: NamingPolicy, shape: RefShape, flaggedFroms: Array<Int>,
		?index: SymbolIndex
	): Null<RenameEdits> {
		final span: Null<Span> = decl.span;
		if (span == null || !flaggedFroms.contains(span.from) || !isRenameSafe(decl, source, index)) return null;
		final rule: Null<NamingRule> = applicableRule(decl, policy);
		if (rule == null) return null;
		final normalize: Null<String -> Null<String>> = rule.normalize;
		if (normalize == null) return null;
		final newName: Null<String> = normalize(decl.name);
		if (newName == null || newName == decl.name || !rule.format.match(newName)) return null;
		final occurrences: Array<Span> = Rename.renameOccurrences(source, tree, span.from, shape);
		if (occurrences.length == 0) return null;
		// Completeness: the scope resolver can miss a bare field reference (a
		// field's decl-node span and its reference binding can disagree), so a
		// rename not covering every textual occurrence of the name would leave a
		// dangling reference — bail rather than emit a broken rename.
		return decl.category == NamingCategory.Field && RefactorSupport.referencedInRange(source, decl.name, 0, source.length, occurrences)
			? null
			: { occurrences: occurrences, name: newName };
	}

}

/**
 * A computed rename for one declaration: every span to rewrite and the new
 * identifier to write at each.
 */
private typedef RenameEdits = {
	final occurrences: Array<Span>;
	final name: String;
};
