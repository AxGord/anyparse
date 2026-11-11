package anyparse.check.common.types;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.query.SourceComments;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;

/**
 * Flags an anonymous structure TYPE whose fields are written in the `var` long form
 * (`{ var name:String; var role:String; }`) where the short form says the same type
 * (`{ name:String, role:String }`), and rewrites it. `Severity.Info`, DEFAULT OFF: one form for
 * anonymous structures is a project convention, not a defect. Applies to a type declaration's body
 * and to an inline structure type alike (a signature, a field, a type argument).
 *
 * ## Why the rewrite is the same type
 *
 * A plain `var x:T;` in a structure type declares a mutable field with no accessor, which is exactly
 * what `x:T` declares; `@:optional var x:T` is `?x:T`; and `public` is the default visibility of a
 * structure field, so it restates nothing.
 *
 * ## What is flagged
 *
 * A body holding at least one long-form `var` field, every one of which is PLAIN: its head between
 * the declaration's start and the type is only the field name (and the optional marker), its tail only
 * the terminator, it carries no initializer and no further declarators, and its leading run is
 * `RefShape.publicModifierKind` and `RefShape.optionalFieldMetaName` and nothing else. Short fields
 * ride along unchanged. ANY other member (a `final` or `function` field, an extension clause, an
 * `#if` region, another annotation on a `var` field) keeps the whole body in its long form and the
 * rule silent, so a body is never left half-converted by a refusal.
 *
 * ## Comments and the fix
 *
 * A doc block above a `var` field, or a comment anywhere the edits reach (before the name, around the
 * colon, before the terminator), keeps the finding silent: the short form has no place for it. Comments
 * elsewhere (a trailing `// note`, a line above a plain field) stay where they are. The edits touch only
 * the leading run (dropped, or replaced by `?`) and the terminator (`,` between fields, none after the
 * last), never the type text, so a structure nested in a field's type is fixed by its own finding.
 * `;` between short fields does not parse, which is why the terminator is rewritten rather than kept.
 *
 * The accessor clause is not projected as a node, so it is recognised by the head holding
 * anything beyond the name and the colon. Grammar-agnostic over the `RefShape` seams it names
 * (`anonTypeKind`, `structureVarFieldKind`, `plainStructureFieldKinds`, `optionalParamKind`); unset
 * -> no-op.
 */
@:nullSafety(Strict)
final class AnonShortFields extends RuleBase implements DefaultOff {

	private static inline final RULE_ID: String = 'anon-short-fields';

	/** The marker the short form spells an optional field with. */
	private static final OPTIONAL_MARK: String = '?';

	/** The separator between short fields, and the colon between a name and its type. */
	private static final FIELD_SEPARATOR: String = ',';

	private static final TYPE_COLON: String = ':';

	/** The terminator a long-form field may carry. */
	private static final FIELD_TERMINATOR: String = ';';

	public function new() {
		super(
			RULE_ID, 'an anonymous structure written in the var long form (var x:T;) where the short form (x:T) is the same type',
			RuleCategory.Types
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = buildSeams(plugin);
		return seams == null
			? []
			: RunScan.collect(files, plugin, (entry, tree, violations) -> {
				final docEnds: () -> Map<Int, Bool> = lazyDocEnds(plugin, entry.source);
				for (anon in anonBodies(tree, seams)) {
					final span: Null<Span> = anon.span;
					if (span != null && rewrite(anon, entry.source, docEnds, seams) != null) violations.push({
						file: entry.file,
						span: span,
						rule: RULE_ID,
						severity: Severity.Info,
						message: 'anonymous structure written in the var long form — write its fields as name:Type'
					});
				}
			});
	}

	/**
	 * Re-derive each flagged body's edits from the source, so an edit lands only while the body still
	 * has the shape the finding was reported for.
	 */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final seams: Null<Seams> = buildSeams(plugin);
		return seams == null
			? []
			: RunScan.edits(plugin, source, tree -> {
				final docEnds: () -> Map<Int, Bool> = lazyDocEnds(plugin, source);
				final byKey: Map<String, QueryNode> = [];
				for (anon in anonBodies(tree, seams)) {
					final span: Null<Span> = anon.span;
					if (span != null) byKey['${span.from}:${span.to}'] = anon;
				}
				final edits: Array<FixEdit> = [];
				RunScan.eachMatched(violations, byKey, (anon, _) -> {
					final body: Null<Array<FixEdit>> = rewrite(anon, source, docEnds, seams);
					if (body != null) for (edit in body) edits.push(edit);
				});
				return edits;
			});
	}

	/** Whether a doc block ends right before the leading run starting at `at`. */
	private static inline function docAbove(source: String, docEnds: Map<Int, Bool>, at: Int): Bool {
		return CheckScan.hasDocBefore(source, docEnds, at);
	}

	/** Whether a comment sits in `[from, to)`, the leading run the fix replaces. */
	private static inline function commentIn(source: String, from: Int, to: Int): Bool {
		return SourceComments.hasCommentMarker(source, from, to);
	}

	private static function buildSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final anon: Null<String> = shape.anonTypeKind;
		final varField: Null<String> = shape.structureVarFieldKind;
		final shortFields: Array<String> = shape.plainStructureFieldKinds ?? [];
		return anon == null || varField == null || shortFields.length == 0 ? null : {
			anonKind: anon,
			varKind: varField,
			shortKinds: shortFields,
			optionalKind: shape.optionalParamKind,
			publicKind: shape.publicModifierKind,
			bareMetaKind: shape.bareMetaKind,
			optionalMetaName: shape.optionalFieldMetaName,
			metaKinds: plugin.metaShape().metaKinds
		};
	}

	/**
	 * Every structure-type body under `root`, each once: a body written as a declaration's whole type is projected both
	 * as its child and in its type slot, and a body inside a type argument (`Map<K, { … }>`) only in the type slot.
	 */
	private static function anonBodies(root: QueryNode, seams: Seams): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		collectBodies(out, [], root, seams);
		return out;
	}

	private static function collectBodies(out: Array<QueryNode>, seen: Map<Int, Bool>, node: QueryNode, seams: Seams): Void {
		final span: Null<Span> = node.span;
		if (node.kind == seams.anonKind && span != null && !seen.exists(span.from)) {
			seen[span.from] = true;
			out.push(node);
		}
		for (child in node.children) collectBodies(out, seen, child, seams);
		final written: Null<QueryNode> = node.type;
		if (written != null) collectBodies(out, seen, written, seams);
	}

	/**
	 * The edits turning `anon` into its short form, or null when it holds no long-form field or any member
	 * (or any field) that must stay as written. The children are walked in order: a leading run of
	 * annotations and `public` accumulates until the field it leads arrives.
	 */
	private static function rewrite(anon: QueryNode, source: String, docEnds: () -> Map<Int, Bool>, seams: Seams): Null<Array<FixEdit>> {
		final edits: Array<FixEdit> = [];
		final members: Array<QueryNode> = anon.children;
		final lastMember: Null<QueryNode> = members[members.length - 1];
		var runFrom: Null<Int> = null;
		var optionalMeta: Bool = false;
		var foreignMeta: Bool = false;
		for (member in members) {
			final span: Null<Span> = member.span;
			if (span == null || keepsLong(member, seams)) return null;
			final isVar: Bool = member.kind == seams.varKind;
			if (seams.metaKinds.contains(member.kind)) {
				runFrom ??= span.from;
				final optional: Bool = member.kind == seams.bareMetaKind
					&& seams.optionalMetaName != null
					&& member.name == seams.optionalMetaName;
				optionalMeta = optionalMeta || optional;
				foreignMeta = foreignMeta || !optional;
			} else if (member.kind == seams.publicKind) {
				runFrom ??= span.from;
			} else {
				if (isVar && foreignMeta) return null;
				if (
					isVar
					&& !longFieldEdits(edits, member, runFrom ?? span.from, optionalMeta, member == lastMember, source, docEnds, seams)
				)
					return null;
				runFrom = null;
				optionalMeta = false;
				foreignMeta = false;
			}
		}
		return edits.length == 0 ? null : edits;
	}

	/**
	 * Push the edits rewriting one plain long-form field `field` (its leading run starting at `runFrom`) and
	 * answer true; answer false, pushing nothing, when the field is not plain. `last` says no field follows,
	 * so no separator is wanted after it.
	 */
	private static function longFieldEdits(
		edits: Array<FixEdit>, field: QueryNode, runFrom: Int, optionalMeta: Bool, last: Bool, source: String,
		docEnds: () -> Map<Int, Bool>, seams: Seams
	): Bool {
		final fieldSpan: Null<Span> = field.span;
		final decl: Null<QueryNode> = field.children[0];
		if (fieldSpan == null || decl == null || field.children.length != 1) return false;
		final declSpan: Null<Span> = decl.span;
		final name: Null<String> = decl.name;
		final typeSpan: Null<Span> = typeOf(decl, seams)?.span;
		if (declSpan == null || name == null || typeSpan == null) return false;
		final optionalDecl: Bool = seams.optionalKind != null && decl.kind == seams.optionalKind;
		final head: String = (optionalDecl ? OPTIONAL_MARK : '') + name + TYPE_COLON;
		if (!bareHead(source, declSpan.from, typeSpan.from, head) || !bareTail(source, typeSpan.to, fieldSpan.to)) return false;
		if (commentIn(source, runFrom, declSpan.from) || docAbove(source, docEnds(), runFrom)) return false;
		edits.push({ span: new Span(runFrom, declSpan.from), text: optionalMeta && !optionalDecl ? OPTIONAL_MARK : '' });
		final wanted: String = last ? '' : FIELD_SEPARATOR;
		if (source.substring(typeSpan.to, fieldSpan.to) != wanted) edits.push({ span: new Span(typeSpan.to, fieldSpan.to), text: wanted });
		return true;
	}

	private static function lazyDocEnds(plugin: GrammarPlugin, source: String): () -> Map<Int, Bool> {
		var cached: Null<Map<Int, Bool>> = null;
		function resolve(): Map<Int, Bool> {
			final have: Null<Map<Int, Bool>> = cached;
			if (have != null) return have;
			final built: Map<Int, Bool> = CheckScan.docBlockEnds(source, plugin.lexicalRegions(source));
			cached = built;
			return built;
		}
		return resolve;
	}

	/**
	 * Whether `member` is one the short form cannot spell — a `final` or `function` field, an extension clause, an
	 * `#if` region: anything other than an annotation, `public`, a `var` field or a short field.
	 */
	private static function keepsLong(member: QueryNode, seams: Seams): Bool {
		final kind: String = member.kind;
		return !(seams.metaKinds.contains(kind) || kind == seams.publicKind || kind == seams.varKind || seams.shortKinds.contains(kind));
	}

	/** Whether the text from a field's start to its type is only the name, the colon and the optional marker: no accessor, no comment. */
	private static function bareHead(source: String, from: Int, to: Int, head: String): Bool {
		return SourceText.withoutSpace(source.substring(from, to)) == head;
	}

	/** Whether what follows a field's type is only its terminator, or nothing. */
	private static function bareTail(source: String, from: Int, to: Int): Bool {
		final tail: String = SourceText.withoutSpace(source.substring(from, to));
		return tail == '' || tail == FIELD_TERMINATOR;
	}

	/**
	 * The type of a plain declaration, or null when it has none or carries anything else beside it (an initializer, a
	 * further declarator). A structure type is projected both in the type slot and as the declaration's only child.
	 */
	private static function typeOf(decl: QueryNode, seams: Seams): Null<QueryNode> {
		final written: Null<QueryNode> = decl.type;
		if (written == null) return null;
		final others: Int = decl.children.length;
		return others == 0 || (others == 1 && written.kind == seams.anonKind && decl.children[0].kind == seams.anonKind) ? written : null;
	}

}

private typedef Seams = {
	final anonKind: String;
	final varKind: String;
	final shortKinds: Array<String>;
	final optionalKind: Null<String>;
	final publicKind: Null<String>;
	final bareMetaKind: Null<String>;
	final optionalMetaName: Null<String>;
	final metaKinds: Array<String>;
}
