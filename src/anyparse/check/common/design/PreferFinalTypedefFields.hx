package anyparse.check.common.design;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.OptionKeyed;
import anyparse.check.Check.RiskyFix;
import anyparse.check.LintConfig;
import anyparse.check.scan.CheckScan;
import anyparse.query.LexicalRegions;
import anyparse.query.ParseGate;
import anyparse.query.ReachLiveness;
import anyparse.query.SourceText;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoMemo;

/** What the grammar names that the rule reads, resolved once per run. */
private typedef Seams = {
	final aliasKind: String;
	final anonKind: String;
	final shortKinds: Array<String>;
	final varKind: String;
	final finalKind: String;
	final metaKinds: Array<String>;
	final publicKind: Null<String>;
	final conditionalKinds: Array<String>;
	final classKinds: Array<String>;
	final writeKinds: Array<String>;
	final accessKind: String;
	final indexKind: Null<String>;
	final callKind: String;
	final identKind: String;
	final selfText: Null<String>;
	final leadEntry: (QueryNode) -> Bool;
	final fold: Null<StringFoldSupport>;
}

/** One file of the run as the walk of its typedefs reads it. */
private typedef FileCtx = {
	final file: String;
	final source: String;
	final regions: () -> Array<LexRegion>;
	final accessors: () -> Map<Int, Bool>;
	final perField: Bool;
	final unverified: Map<String, Bool>;
}

/** The edits of one flagged typedef and the text they were made for: they apply only while the typedef still reads so. */
private typedef Plan = { final body: String; final edits: Array<FixEdit>; }

/** The fields of one typedef that may become final, and the edits that make them so. */
private typedef Rewrite = { final names: Array<String>; final edits: Array<FixEdit>; }

/** A not-yet-final field of a body: `ready` when nothing writes it and its form can spell `final`; `edit` swaps a long form's keyword. */
private typedef Field = {
	final node: QueryNode;
	final name: String;
	final ready: Bool;
	final edit: Null<FixEdit>;
}

/** The field members of a structure body and whether they are written in the short form. */
private typedef Body = { final fields: Array<QueryNode>; final short: Bool; }
/**
 * The one answer to "which fields of a typedef's structure does nothing write, so that they may be `final`": a typedef of an
 * anonymous structure, `{ x:Int, y:Int }` or `{ var x:Int; }`, whose fields no write in the run names is flagged and rewritten
 * to the class notation, `{ final x:Int; final y:Int; }`. `Severity.Info`, DEFAULT OFF, a `RiskyFix`: the edit lands only
 * through the compiler oracle, which is the proof that no write, no `++` and no unification with a writable structure was
 * missed — a file the compiler rejects keeps its form and the finding stays report-only.
 *
 * ## Shape
 *
 * The short form cannot carry `final`, so the body is rewritten whole: each field gets `final ` (`final ?x:T;` for an
 * optional one), the `,` between short fields becomes `;`, and a long-form `var x:T;` has its keyword swapped. The
 * writer's typedef-body layout finishes the result. A class notation holding a `final` field is never re-shortened by
 * `anon-short-fields`, so the two rules settle on one form.
 *
 * ## Option `mode`
 *
 * - `wholeType` (default) — a typedef is flagged only when ALL its not-yet-final fields can become final.
 * - `perField` — the fields that can become final do, the others stay writable in the class notation (`var x:T;`: the
 *   short form cannot be mixed with it, so a short body is rewritten whole).
 *
 * ## The syntactic pre-filter
 *
 * A field is not a candidate when any file of the run writes a field of its NAME: an assignment, a compound assignment,
 * `++` / `--` on `<expr>.<name>`, an index write with that string literal, or a `Reflect.setField` / `setProperty` /
 * `deleteField` with that literal key. A write the pre-filter cannot see (a computed reflective key, a write in a file
 * outside the run) is the oracle's to reject when it is compile-visible and nobody's when it is not. A `this.<name>`
 * write inside a CLASS writes that class's own field and is no write of a typedef's. Every branch of an `#if` is read, so
 * a write no oracle configuration compiles still keeps the field a `var`.
 *
 * ## Code no configuration compiles
 *
 * The oracle types only what its configurations compile: a typedef whose name or any field name occurs in `#if` code none of
 * them takes (`ReachLiveness.live`) is refused whole. With no complete list of builds declared, every conditional region is such.
 *
 * ## What is refused whole
 *
 * A typedef carrying metadata (`@:structInit`, a schema or build annotation), declared under `#if`, extending another
 * structure (`> Base`), or holding a member other than a field, and a body mixing the short and the long form.
 * A long-form field with an accessor clause or a comment before its name is kept as written.
 */
@:nullSafety(Strict)
final class PreferFinalTypedefFields extends RuleBase implements RiskyFix implements DefaultOff implements ConfigAware
		implements OptionKeyed {

	private static inline final RULE_ID: String = 'prefer-final-typedef-fields';

	/** The option choosing between the whole-typedef and the per-field rewrite. */
	private static final MODE_KEY: String = 'mode';

	private static final MODE_WHOLE: String = 'wholeType';
	private static final MODE_PER_FIELD: String = 'perField';
	private static final FINAL_KEYWORD: String = 'final ';
	private static final VAR_KEYWORD: String = 'var ';
	private static final VAR_TOKEN: String = 'var';
	private static final FIELD_SEPARATOR: String = ',';
	private static final FIELD_TERMINATOR: String = ';';
	private static final REFLECT: String = 'Reflect';

	/** The `Reflect` calls writing a field by name -> the position of the name among the call's children when called off `Reflect`. */
	private static final REFLECT_WRITES: Map<String, Int> = ['setField' => 2, 'setProperty' => 2, 'deleteField' => 2];

	/** Each flagged typedef, by file and span, with the edits that rewrite it. */
	private final _plans: Map<String, Plan> = [];

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(
			RULE_ID, 'a typedef structure whose fields nothing writes — written in the class notation with final fields',
			RuleCategory.Design
		);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function acceptedOptions(): Array<String> {
		return [MODE_KEY];
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		_plans.clear();
		final seams: Null<Seams> = seamsOf(plugin);
		if (seams == null) return [];
		final parsed: Array<{ entry: { file: String, source: String }, tree: QueryNode }> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, entry.source);
			if (tree != null) parsed.push({ entry: entry, tree: tree });
		}
		final written: Map<String, Bool> = [];
		for (item in parsed) collectWrites(item.tree, item.entry.source, false, seams, written);
		final unverified: Map<String, Bool> = [];
		final live: () -> Null<ReachLiveness> = ReachLiveness.ofRun(plugin);
		for (item in parsed) ReachLiveness.collectUnverified(item.tree, item.entry, false, seams.conditionalKinds, live, unverified);
		final out: Array<Violation> = [];
		for (item in parsed) {
			final ctx: FileCtx = {
				file: item.entry.file,
				source: item.entry.source,
				regions: LexicalRegions.lazyOf(item.entry.source, plugin),
				accessors: TypeInfoMemo.propertyAccessors(RunScan.typeInfoOf(plugin), item.entry.source),
				perField: perFieldOf(item.entry.file),
				unverified: unverified
			};
			for (i => kid in item.tree.children) if (kid.kind == seams.aliasKind) judge(item.tree.children, i, ctx, seams, written, out);
		}
		return out;
	}

	/** The edits recorded for each flagged typedef, while its text is the one they were made for. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final edits: Array<FixEdit> = [];
		for (v in violations) {
			final at: Null<Span> = v.span;
			final plan: Null<Plan> = at == null || v.declineReason != null ? null : _plans[planKey(v.file, at)];
			if (at != null && plan != null && source.substring(at.from, at.to) == plan.body) for (edit in plan.edits) edits.push(edit);
		}
		return edits;
	}

	private function perFieldOf(file: String): Bool {
		final value: Null<String> = LintConfig.resolveWith(_resolveConfig, file).stringOption(RULE_ID, MODE_KEY);
		if (value != null && value != MODE_WHOLE && value != MODE_PER_FIELD)
			ConfiguredTypes.warn(_configNotes, RULE_ID, 'unknown mode "$value" — expected "$MODE_WHOLE" or "$MODE_PER_FIELD"');
		return value == MODE_PER_FIELD;
	}

	/** Flag `siblings[at]` when it is a typedef of a structure that may take `final` fields, and keep its edits for `fix`. */
	private function judge(
		siblings: Array<QueryNode>, at: Int, ctx: FileCtx, seams: Seams, written: Map<String, Bool>, out: Array<Violation>
	): Void {
		final decl: QueryNode = siblings[at];
		final name: Null<String> = decl.name;
		final span: Null<Span> = decl.span;
		if (name == null || span == null || decl.children.length != 1 || decl.children[0].kind != seams.anonKind) return;
		if (carriesMetaOrCondition(siblings, at, seams)) return;
		if (ctx.unverified.exists(name) || decl.children[0].children.exists(m -> ctx.unverified.exists(m.name ?? ''))) return;
		final planned: Null<Rewrite> = rewrite(decl.children[0], ctx, seams, written);
		if (planned == null) return;
		final one: Bool = planned.names.length == 1;
		final plan: Plan = { body: ctx.source.substring(span.from, span.to), edits: planned.edits };
		_plans[planKey(ctx.file, span)] = plan;
		out.push({
			file: ctx.file,
			span: span,
			rule: RULE_ID,
			severity: Severity.Info,
			message: 'typedef \'$name\': ${one ? 'field' : 'fields'} ${planned.names.join(', ')} never written — declare '
			+ (one ? 'it' : 'them')
			+ ' final'
		});
	}

	private static function planKey(file: String, at: Span): String {
		return '$file|${at.from}:${at.to}';
	}

	private static function seamsOf(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final alias: Null<String> = shape.typeAliasDeclKind;
		final anon: Null<String> = shape.anonTypeKind;
		final varField: Null<String> = shape.structureVarFieldKind;
		final finalField: Null<String> = shape.structureFinalFieldKind;
		final access: Null<String> = shape.fieldAccessKind;
		final call: Null<String> = shape.callKind;
		final shortFields: Array<String> = shape.plainStructureFieldKinds ?? [];
		if (
			alias == null || anon == null || varField == null || finalField == null || access == null || call == null
			|| shortFields.length == 0
		)
			return null;
		final member: Null<String> = shape.conditionalMemberKind;
		return {
			aliasKind: alias,
			anonKind: anon,
			shortKinds: shortFields,
			varKind: varField,
			finalKind: finalField,
			metaKinds: plugin.metaShape().metaKinds,
			publicKind: shape.publicModifierKind,
			conditionalKinds: (shape.conditionalRegionKinds ?? []).concat(member == null ? [] : [member]),
			classKinds: shape.classDeclKinds ?? [],
			writeKinds: shape.writeParentKinds,
			accessKind: access,
			indexKind: shape.indexAccessKind,
			callKind: call,
			identKind: shape.identKind,
			selfText: shape.selfReferenceText,
			leadEntry: CheckScan.leadingRunEntry(plugin),
			fold: plugin.stringFoldSupport()
		};
	}

	/**
	 * Record every field NAME the subtree of `node` writes into `written`: the target of an assignment or an increment, an
	 * index write with a plain literal key, a reflective write with a literal key. `inClass` says a class (not an abstract)
	 * encloses `node`, where `this.<name> = …` writes the class's own field.
	 */
	private static function collectWrites(node: QueryNode, source: String, inClass: Bool, seams: Seams, written: Map<String, Bool>): Void {
		final within: Bool = inClass || seams.classKinds.contains(node.kind);
		if (seams.writeKinds.contains(node.kind) && node.children.length > 0) noteWrite(node.children[0], source, within, seams, written);
		if (node.kind == seams.callKind) noteReflectiveWrite(node, source, seams, written);
		for (child in node.children) collectWrites(child, source, within, seams, written);
	}

	private static function noteWrite(target: QueryNode, source: String, inClass: Bool, seams: Seams, written: Map<String, Bool>): Void {
		final name: Null<String> = target.name;
		if (target.kind == seams.accessKind && name != null) {
			if (!(inClass && isSelf(target.children[0], seams))) written[name] = true;
		} else if (seams.indexKind != null && target.kind == seams.indexKind && target.children.length == 2) {
			final key: Null<StringLiteral> = seams.fold?.literalOf(target.children[1], source);
			if (key != null) written[key.content] = true;
		}
	}

	/** `Reflect.setField(o, 'name', v)` (and `setProperty`, `deleteField`), or the same as an extension call `o.setField('name', v)`. */
	private static function noteReflectiveWrite(call: QueryNode, source: String, seams: Seams, written: Map<String, Bool>): Void {
		final callee: Null<QueryNode> = call.children[0];
		if (callee == null || callee.kind != seams.accessKind || callee.children.length == 0) return;
		final keyAt: Null<Int> = REFLECT_WRITES[callee.name ?? ''];
		if (keyAt == null) return;
		final receiver: QueryNode = callee.children[0];
		final direct: Bool = receiver.kind == seams.identKind && receiver.name == REFLECT;
		final key: Null<QueryNode> = call.children[direct ? keyAt : keyAt - 1];
		final literal: Null<StringLiteral> = key == null ? null : seams.fold?.literalOf(key, source);
		if (literal != null) written[literal.content] = true;
	}

	private static function isSelf(node: Null<QueryNode>, seams: Seams): Bool {
		return node != null && node.kind == seams.identKind && seams.selfText != null && node.name == seams.selfText;
	}

	/** Whether the declaration `siblings[at]` is led by an annotation or by a conditional-compilation region. */
	private static function carriesMetaOrCondition(siblings: Array<QueryNode>, at: Int, seams: Seams): Bool {
		var i: Int = at - 1;
		while (i >= 0 && seams.leadEntry(siblings[i])) {
			final kind: String = siblings[i].kind;
			if (seams.metaKinds.contains(kind) || seams.conditionalKinds.contains(kind)) return true;
			i--;
		}
		return false;
	}

	/**
	 * The fields of the structure `anon` that become final and the edits that rewrite its body, or null when it must stay as
	 * written: a member other than a field, the two forms mixed, no field to change, and — in `wholeType` mode — any field
	 * that cannot change.
	 */
	private static function rewrite(anon: QueryNode, ctx: FileCtx, seams: Seams, written: Map<String, Bool>): Null<Rewrite> {
		final body: Null<Body> = bodyOf(anon, seams);
		if (body == null) return null;
		final open: Null<Array<Field>> = openFields(body, ctx, seams, written);
		if (open == null) return null;
		final ready: Array<Field> = open.filter(f -> f.ready);
		if (ready.length == 0 || (!ctx.perField && ready.length != open.length)) return null;
		final edits: Array<FixEdit> = [];
		if (body.short) {
			final readyNames: Map<String, Bool> = [ for (f in ready) f.name => true ];
			if (!shortEdits(body.fields, readyNames, ctx, edits)) return null;
		} else {
			for (f in ready) {
				final edit: Null<FixEdit> = f.edit;
				if (edit != null) edits.push(edit);
			}
		}
		return { names: ready.map(f -> f.name), edits: edits };
	}

	/**
	 * The field members of `anon` and whether they are written short, or null when the body must stay as written: a member
	 * that is neither a field, an annotation nor `public`, no field at all, or the two forms mixed.
	 */
	private static function bodyOf(anon: QueryNode, seams: Seams): Null<Body> {
		final fields: Array<QueryNode> = [];
		var shortCount: Int = 0;
		for (member in anon.children) {
			final kind: String = member.kind;
			if (seams.shortKinds.contains(kind)) {
				shortCount++;
				fields.push(member);
			} else if (kind == seams.varKind || kind == seams.finalKind) {
				fields.push(member);
			} else if (!(seams.metaKinds.contains(kind) || kind == seams.publicKind)) {
				return null;
			}
		}
		return fields.length == 0 || (shortCount != 0 && shortCount != fields.length) ? null : { fields: fields, short: shortCount != 0 };
	}

	/** The fields of `body` that are not final yet, each judged against `written`; null when one has no name. */
	private static function openFields(body: Body, ctx: FileCtx, seams: Seams, written: Map<String, Bool>): Null<Array<Field>> {
		final open: Array<Field> = [];
		for (node in body.fields) {
			final named: Null<String> = node.name;
			if (named == null) return null;
			final name: String = named;
			if (node.kind == seams.finalKind) continue;
			final edit: Null<FixEdit> = body.short ? null : longEdit(node, ctx);
			final field: Field = {
				node: node,
				name: name,
				ready: !written.exists(name) && (body.short || edit != null),
				edit: edit
			};
			open.push(field);
		}
		return open;
	}

	/**
	 * The edits of a short-form body written whole into the class notation: `final ` before each field in `ready`, `var ` before
	 * the others, and the `;` each field then ends with in place of the `,` between short fields. False when a separator is not
	 * where the grammar puts it.
	 */
	private static function shortEdits(fields: Array<QueryNode>, ready: Map<String, Bool>, ctx: FileCtx, edits: Array<FixEdit>): Bool {
		for (i => node in fields) {
			final span: Null<Span> = node.span;
			final end: Null<Span> = node.children[node.children.length - 1]?.span;
			if (span == null || end == null) return false;
			edits.push({ span: new Span(span.from, span.from), text: ready.exists(node.name ?? '') ? FINAL_KEYWORD : VAR_KEYWORD });
			final after: Int = LexicalRegions.skipTriviaLazy(ctx.source, end.to, ctx.regions);
			if (ctx.source.substr(after, FIELD_SEPARATOR.length) == FIELD_SEPARATOR)
				edits.push({ span: new Span(after, after + FIELD_SEPARATOR.length), text: FIELD_TERMINATOR });
			else if (i == fields.length - 1)
				edits.push({ span: new Span(end.to, end.to), text: FIELD_TERMINATOR });
			else
				return false;
		}
		return true;
	}

	/**
	 * The edit swapping the `var` of a long-form field for `final`, or null when the field is not plain: it carries an accessor
	 * clause, a comment between the keyword and the name, or anything beside one typed declaration.
	 */
	private static function longEdit(field: QueryNode, ctx: FileCtx): Null<FixEdit> {
		final span: Null<Span> = field.span;
		final decl: Null<QueryNode> = field.children[0];
		final declSpan: Null<Span> = decl?.span;
		if (span == null || decl == null || declSpan == null || field.children.length != 1 || decl.type == null) return null;
		if (ctx.accessors().exists(declSpan.from) || LexicalRegions.commentIntersects(span.from, declSpan.from, ctx.regions())) return null;
		return SourceText.withoutSpace(ctx.source.substring(span.from, declSpan.from)) == VAR_TOKEN
			? { span: new Span(span.from, declSpan.from), text: FINAL_KEYWORD }
			: null;
	}

}
