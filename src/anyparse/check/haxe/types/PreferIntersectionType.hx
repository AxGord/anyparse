package anyparse.check.haxe.types;

import anyparse.check.Check.FixEdit;
import anyparse.check.Check.RiskyFix;
import anyparse.check.scan.RunScan;
import anyparse.query.LexicalRegions;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;

/**
 * Flags a typedef whose whole right-hand side is an anonymous structure holding nothing but `> T` extension clauses
 * (`typedef C = { > A, > B, };`) and rewrites it to the intersection it says (`typedef C = A & B;`; a single extension
 * is a plain alias, `typedef C = A;`). `Severity.Info`. The clauses' own text is carried over untouched, type arguments
 * and all, joined by ` & `; a typedef written without its `;` gains one, which the intersection form requires.
 *
 * ## What is flagged
 *
 * Only a structure that IS the typedef's type: nothing but the terminator follows it, so a constraint on a type
 * parameter is left alone. ANY member other than an extension clause (an own field, an annotation, an `#if` region) and
 * any comment inside the body keep the rule silent: an intersection has no place for them.
 *
 * ## Where the grammar reads an intersection
 *
 * `A & B` parses on a typedef's right-hand side and as a type argument, and nowhere else (`HxIntersectionClause`: `&` is
 * not a type operator, since `x is T && y` would read `&&` greedily). A field, parameter or return type written
 * `{ > A, > B, }` has no intersection spelling the grammar can read, and a structure inside a type argument is not
 * projected as a node; both stay as they are.
 *
 * ## Verified, not trusted: `RiskyFix`
 *
 * The extensions are not resolved, and `>` and `&` agree only where each `T` is a structure type. A class, an abstract
 * or a type parameter is rejected by the compiler, and `lint --fix` reverts the file; with no `compilerOracle`
 * configured the rule is report-only.
 */
@:nullSafety(Strict)
final class PreferIntersectionType extends HaxeRule implements RiskyFix {

	private static inline final RULE_ID: String = 'prefer-intersection-type';

	/** The kind of a `> T` clause in a structure type (`HxAnonField.ExtendsField`). */
	private static final EXTENSION_KIND: String = 'ExtendsField';

	/** The clause's lead, which the grammar declares and the rewritten text drops. */
	private static final EXTENSION_LEAD: String = '>';

	private static final INTERSECTION: String = ' & ';

	/** What the typedef's source may hold after the structure: the terminator, or nothing. */
	private static final TYPEDEF_TERMINATOR: String = ';';

	public function new() {
		super(RULE_ID, 'a structure type made only of `> T` extensions, which the intersection `A & B` says directly', RuleCategory.Types);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = seamsOf(plugin);
		return seams == null
			? []
			: RunScan.collect(files, plugin, (entry, tree, violations) -> {
				for (site in sitesOf(tree, entry.source, plugin.lexicalRegions(entry.source), seams)) violations.push({
					file: entry.file,
					span: site.span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: 'this structure only extends other types: write it as an intersection (A & B)'
				});
			});
	}

	/** Re-derive each flagged structure's rewrite from the source, so an edit lands only while the shape still holds. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final seams: Null<Seams> = seamsOf(plugin);
		return seams == null
			? []
			: RunScan.edits(plugin, source, tree -> {
				final byKey: Map<String, Site> = [];
				for (site in sitesOf(tree, source, plugin.lexicalRegions(source), seams)) byKey['${site.span.from}:${site.span.to}'] = site;
				final edits: Array<FixEdit> = [];
				RunScan.eachMatched(violations, byKey, (site, span) -> edits.push({ span: span, text: site.text }));
				return edits;
			});
	}

	private static function seamsOf(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final anon: Null<String> = shape.anonTypeKind;
		final alias: Null<String> = shape.typeAliasDeclKind;
		return anon == null || alias == null ? null : { anonKind: anon, aliasKind: alias };
	}

	/** Every typedef right-hand side under `node` that is extensions only, each with the text it becomes. */
	private static function sitesOf(node: QueryNode, source: String, regions: Array<LexRegion>, seams: Seams): Array<Site> {
		final out: Array<Site> = [];
		collectSites(out, node, source, regions, seams);
		return out;
	}

	private static function collectSites(out: Array<Site>, node: QueryNode, source: String, regions: Array<LexRegion>, seams: Seams): Void {
		for (child in node.children) {
			if (node.kind == seams.aliasKind && child.kind == seams.anonKind) {
				final site: Null<Site> = siteOf(node, child, source, regions);
				if (site != null) out.push(site);
			}
			collectSites(out, child, source, regions, seams);
		}
	}

	/**
	 * The rewrite of `anon`, the structure of the typedef `alias`, or null when it holds anything but extension clauses, a
	 * comment, or is followed by more than the typedef's terminator.
	 */
	private static function siteOf(alias: QueryNode, anon: QueryNode, source: String, regions: Array<LexRegion>): Null<Site> {
		final aliasSpan: Null<Span> = alias.span;
		final span: Null<Span> = anon.span;
		if (aliasSpan == null || span == null || anon.children.length == 0) return null;
		if (LexicalRegions.commentIntersects(span.from, span.to, regions)) return null;
		final tail: String = SourceText.withoutSpace(source.substring(span.to, aliasSpan.to));
		if (tail != '' && tail != TYPEDEF_TERMINATOR) return null;
		final types: Array<String> = [];
		for (member in anon.children) {
			final memberSpan: Null<Span> = member.span;
			final written: String = memberSpan == null ? '' : source.substring(memberSpan.from, memberSpan.to);
			if (member.kind != EXTENSION_KIND) return null;
			types.push(written.substr(EXTENSION_LEAD.length).trim());
		}
		return { span: span, text: types.join(INTERSECTION) + (tail == '' ? TYPEDEF_TERMINATOR : '') };
	}

}

private typedef Seams = { final anonKind: String; final aliasKind: String; }

/** A structure to rewrite: its span, and the text that replaces it. */
private typedef Site = { final span: Span; final text: String; }
