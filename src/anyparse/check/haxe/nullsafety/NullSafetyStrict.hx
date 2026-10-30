package anyparse.check.haxe.nullsafety;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.RiskyFix;
import anyparse.check.scan.RunScan;
import anyparse.query.AddMeta;
import anyparse.query.MemberKinds;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;

/**
 * One finding of `null-safety-strict`: where it is reported, what it says, and the edit that makes the type strict, null
 * when it is reported only.
 */
private typedef StrictFinding = {
	final span: Span;
	final message: String;
	final edit: Null<FixEdit>;
}

/**
 * Flags a class that does not declare STRICT null safety — no `@:nullSafety` entry, a bare (loose) one, or one
 * switching it `Off` — and a `@:nullSafety(Off)` anywhere else (a member, an expression, a type the rule does not ask). The
 * fix writes `@:nullSafety(Strict)` on the class: a new entry below its doc and above its modifiers (`AddMeta.entryEdit`),
 * or the existing entry rewritten. Any other `Off` is reported only: dropping it is a decision about the code it shields.
 *
 * ## Why `DefaultOff` and `RiskyFix`
 *
 * A project may switch null safety on from its build (`--macro nullSafety(…)`), where every finding is noise; and a type
 * that compiles loose need not compile strict, so an edit stands only where the compiler oracle accepts it.
 */
@:nullSafety(Strict)
final class NullSafetyStrict extends HaxeRule implements DefaultOff implements RiskyFix {

	private static inline final RULE_ID: String = 'null-safety-strict';

	/** The arguments that make null safety strict. */
	private static final STRICT_ARGS: Array<String> = ['Strict', 'StrictThreaded'];

	/**
	 * The type declarations the rule asks for strictness: the classes, which carry the code. An abstract's body is mostly
	 * forwarding and an enum abstract's a value list, so neither is asked.
	 */
	private static final CHECKED_TYPE_KINDS: Array<String> = ['ClassDecl', 'AbstractClassDecl'];

	public function new() {
		super(RULE_ID, 'a class without @:nullSafety(Strict), or a @:nullSafety(Off) anywhere', RuleCategory.NullSafety);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final metaName: Null<String> = shape.nullSafetyMetaName;
		return metaName == null
			? []
			: RunScan.collect(files, plugin, (entry, tree, out) -> {
				for (f in findings(tree, entry.source, metaName, shape.nullSafetyDisableArg, shape.externModifierKind)) out.push({
					file: entry.file,
					span: f.span,
					rule: RULE_ID,
					severity: Severity.Warning,
					message: f.message
				});
			});
	}

	/** Make each flagged type strict; a below-type `Off` gets no edit. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final shape: RefShape = plugin.refShape();
		return RunScan.editsWith(plugin, source, shape.nullSafetyMetaName, (tree, metaName) -> {
			final byKey: Map<String, StrictFinding> = [];
			for (f in findings(tree, source, metaName, shape.nullSafetyDisableArg, shape.externModifierKind))
				byKey['${f.span.from}:${f.span.to}'] = f;
			final edits: Array<FixEdit> = [];
			RunScan.eachMatched(violations, byKey, (f, _) -> {
				final edit: Null<FixEdit> = f.edit;
				if (edit != null) edits.push(edit);
			});
			return edits;
		});
	}

	/** Whether `node` is a `metaName` metadata entry. */
	private static inline function isEntry(node: QueryNode, metaName: String): Bool {
		return MemberKinds.META_KINDS.contains(node.kind) && node.name == metaName;
	}

	/**
	 * Every finding in `tree`: each checked, non-extern type whose own `metaName` entry is missing or not strict, then each
	 * `disableArg` entry that annotates no such type.
	 */
	private static function findings(
		tree: QueryNode, source: String, metaName: String, disableArg: Null<String>, externKind: Null<String>
	): Array<StrictFinding> {
		final entry: String = '$metaName(${STRICT_ARGS[0]})';
		final out: Array<StrictFinding> = [];
		final typeEntries: Array<QueryNode> = [];
		function add(span: Span, message: String, rewrite: Bool): Void {
			out.push({ span: span, message: message, edit: rewrite ? { span: span, text: entry } : null });
		}
		function types(node: QueryNode): Void {
			final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (decl != null && CHECKED_TYPE_KINDS.contains(decl.kind)) {
				final run: Array<QueryNode> = AddMeta.leadingRun(tree, decl.declNode);
				final meta: Null<QueryNode> = run.find(n -> isEntry(n, metaName));
				final metaSpan: Null<Span> = meta?.span;
				if (meta != null) typeEntries.push(meta);
				final checked: Bool = !run.exists(n -> n.kind == externKind);
				if (checked && meta == null) out.push({
					span: decl.fullSpan,
					message: '${decl.name} declares no $entry',
					edit: AddMeta.entryEdit(source, tree, decl.declNode, entry)
				});
				if (checked && meta != null && metaSpan != null && !STRICT_ARGS.contains(argOf(meta) ?? ''))
					add(metaSpan, 'null safety here is ${argOf(meta) ?? 'loose'}, not strict: make it $entry', true);
			}
			for (c in node.children) types(c);
		}
		function offs(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (span != null && isEntry(node, metaName) && !typeEntries.contains(node) && argOf(node) == disableArg)
				add(span, 'this switches null safety off: make the code it shields pass $entry instead', false);
			for (c in node.children) offs(c);
		}
		types(tree);
		offs(tree);
		return out;
	}

	/** The argument a `@:nullSafety` entry names (`Strict`, `Off`, …), or null for the bare entry. */
	private static function argOf(meta: QueryNode): Null<String> {
		return meta.children.length == 0 ? null : meta.children[0].name;
	}

}
