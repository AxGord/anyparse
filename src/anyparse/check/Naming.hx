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
	 * Autofix: rename each flagged binding to a mechanically-corrected name, for
	 * the rename-safe categories only (function-body-scoped — Local / Param /
	 * CatchVar). The new name comes from the applicable rule's `normalize`; the
	 * occurrences come from `Rename.renameOccurrences` (the same scope resolver
	 * `apq rename` uses), emitted as replace-edits the caller batches and
	 * re-parse-validates. A private field / method or a type is left report-only:
	 * this single-source fix cannot prove the binding has no cross-file
	 * (subclass / `@:access`) reference.
	 */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin): Array<{ span: Span, text: String }> {
		if (violations.length == 0) return [];
		final support: Null<NamingSupport> = plugin.namingSupport();
		if (support == null) return [];
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];

		final renameSafe: Array<NamingCategory> = [NamingCategory.Local, NamingCategory.Param, NamingCategory.CatchVar];
		final policy: NamingPolicy = support.policyFor(violations[0].file);
		final shape: RefShape = plugin.refShape();

		final flaggedFroms: Array<Int> = [];
		for (v in violations) {
			final s: Null<Span> = v.span;
			if (s != null) flaggedFroms.push(s.from);
		}

		final edits: Array<{ span: Span, text: String }> = [];
		for (decl in support.project(tree)) {
			final span: Null<Span> = decl.span;
			if (span == null || !flaggedFroms.contains(span.from) || !renameSafe.contains(decl.category)) continue;
			final rule: Null<NamingRule> = applicableRule(decl, policy);
			if (rule == null) continue;
			final normalize: Null<String -> Null<String>> = rule.normalize;
			if (normalize == null) continue;
			final newName: Null<String> = normalize(decl.name);
			if (newName == null || newName == decl.name || !rule.format.match(newName)) continue;
			final finalName: String = newName;
			for (occ in Rename.renameOccurrences(source, tree, span.from, shape)) edits.push({ span: occ, text: finalName });
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

}
