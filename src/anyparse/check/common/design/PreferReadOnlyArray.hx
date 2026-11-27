package anyparse.check.common.design;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.OptionKeyed;
import anyparse.check.Check.RiskyFix;
import anyparse.check.LintConfig;
import anyparse.check.scan.CheckScan;
import anyparse.query.MemberKinds;
import anyparse.query.ParseGate;
import anyparse.query.ReachLiveness;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeRefPrinter;

/** What the grammar names that the rule reads, resolved once per run. */
private typedef Seams = {
	final arrayNames: Array<String>;
	final readOnly: String;
	final mutators: Array<String>;
	final classKinds: Array<String>;
	final finalClassKind: Null<String>;
	final containerKinds: Array<String>;
	final sealingMetaNames: Array<String>;
	final interfaceKinds: Array<String>;
	final aliasKind: Null<String>;
	final anonKind: Null<String>;
	final fieldKinds: Array<String>;
	final functionKinds: Array<String>;
	final localFunctionKinds: Array<String>;
	final paramKinds: Array<String>;
	final localKinds: Array<String>;
	final typeKinds: Array<String>;
	final shortFieldKinds: Array<String>;
	final longFieldKinds: Array<String>;
	final typeRefKinds: Array<String>;
	final leadKinds: Array<String>;
	final publicKind: Null<String>;
	final privateKind: Null<String>;
	final overrideKind: Null<String>;
	final externKind: Null<String>;
	final pinningMetaNames: Array<String>;
	final conditionalKinds: Array<String>;
	final writeKinds: Array<String>;
	final accessKind: String;
	final indexKind: Null<String>;
	final callKind: String;
	final identKind: String;
	final parenKind: Null<String>;
	final castKinds: Array<String>;
	final reflectiveCalls: Map<String, Int>;
	final fold: Null<StringFoldSupport>;
}

/** The names a scope changes an array through: a value of the name (`names`), or what a call of the name returns (`calls`). */
private typedef Mutations = { final names: Map<String, Bool>; final calls: Map<String, Bool>; }

/** What the whole run says of a name: an array it changes, a member a sibling declaration must match, code no build compiles. */
private typedef RunFacts = { final mutated: Mutations; final contracts: Map<String, Bool>; final unverified: Map<String, Bool>; }

/** One file of the run as the walk of its declarations reads it. */
private typedef FileCtx = {
	final file: String;
	final source: String;
	final closedWorld: Bool;
	final facts: RunFacts;
}

/**
 * The array head a flagged declaration's type is written with, and
 * whether the declaration RECEIVES a value (a parameter, a return type).
 */
private typedef Plan = { final head: Span; final sink: Bool; }

/**
 * The one answer to "which declarations typed with the built-in array type change nothing through it, so that they may be its
 * read-only view": a class field, a typedef field, a parameter, a return type or an annotated local of type `Array<T>` that no
 * code mutates through its name is flagged and retyped `haxe.ds.ReadOnlyArray<T>`. `Severity.Info`, DEFAULT OFF, a
 * `RiskyFix`: the edit lands only through the compiler oracle, which is the proof that no mutation, no pass into an
 * `Array<T>` parameter and no unification with an `Array<T>` declaration was missed — an edit the compiler rejects is
 * reverted and the finding stays report-only.
 *
 * The read-only type is a VIEW, not a copy: whoever holds the array as `Array<T>` may still change it, it is no snapshot
 * between threads, and its elements stay mutable.
 *
 * ## The syntactic pre-filter
 *
 * A declaration is no candidate when a mutating method of the array type is read off its name (`items.push`,
 * `this.items.sort`), when its name is the target of an index or field write (`items[0] = v`, `items.length = 0`), when it
 * is cast (`cast items`, `cast(items, T)`), or when a reflective call names it with a literal key. A return type is no
 * candidate when the same is done to a call of its function (`all().push(x)`). Fields and return types are judged against
 * every file of the run, parameters and locals against the member function holding them.
 *
 * ## What is refused
 *
 * An `extern` type or member, one carrying `@:keep` or `@:rtti`, a declaration under `#if`, and a name occurring in
 * conditional code no declared build compiles (`ReachLiveness.collectUnverified`). The signature of a function that
 * overrides, is overridden by name, or is a member of an interface of the run, since its siblings would have to change
 * with it, and every member of an interface. A PUBLIC position — a public member of a type that is not private, any
 * member of a class that is neither private nor final (Haxe `private` is visible to subclasses, which may mutate the
 * field or override the method with an `Array<T>` parameter), a field of a typedef that is not private — has users the
 * oracle only sees when every one of them is compiled by a configured build: it is refused unless the rule's option
 * `closedWorld` is `true`.
 *
 * ## Order and passes
 *
 * A declaration that hands its array on (a field, a local passed as an argument or returned) compiles read-only only once
 * the declaration receiving it (a parameter, a return type) is, and the verifier judges a file's edits in one round, its
 * bisect each half alone. The receiving declarations are listed first, so a bisect keeping one of two halves that compile
 * alone keeps them; a declaration the round left as written is taken by the next `lint --fix`, once what receives it is
 * read-only. Where the file does not already see the read-only type by its short name the edit writes its full path: an
 * import line every edit needed would tie the edits of the file into one bisect unit (`shorten-type-ref` brings it in).
 */
@:nullSafety(Strict)
final class PreferReadOnlyArray extends RuleBase implements RiskyFix implements DefaultOff implements ConfigAware implements OptionKeyed {

	private static inline final RULE_ID: String = 'prefer-read-only-array';

	/** The option declaring that every caller of a public member is compiled by a configured build. */
	private static final CLOSED_WORLD_KEY: String = 'closedWorld';

	/** Each flagged declaration, by file and the span of its type, with the head its edit rewrites. */
	private final _plans: Map<String, Plan> = [];

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(RULE_ID, 'an array declaration nothing mutates through — declared as the read-only view of the array', RuleCategory.Design);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function acceptedOptions(): Array<String> {
		return [CLOSED_WORLD_KEY];
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		_plans.clear();
		final seams: Null<Seams> = seamsOf(plugin);
		return seams == null ? [] : judgeRun(CheckScan.parseAll(plugin, files), plugin, seams);
	}

	/** The edits recorded for each flagged declaration while its head still reads so, the receiving declarations first. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final first: Null<Violation> = violations[0];
		final seams: Null<Seams> = seamsOf(plugin);
		if (first == null || seams == null) return [];
		final text: String = spelling(source, first.file, plugin, seams.readOnly, index);
		final sinks: Array<FixEdit> = [];
		final sources: Array<FixEdit> = [];
		for (v in violations) {
			final at: Null<Span> = v.span;
			final plan: Null<Plan> = at == null || v.declineReason != null ? null : _plans[CheckScan.spanKey(v.file, at)];
			if (plan != null && seams.arrayNames.contains(source.substring(plan.head.from, plan.head.to)))
				(plan.sink ? sinks : sources).push({ span: plan.head, text: text });
		}
		return sinks.concat(sources);
	}

	/** Read what the whole run mutates and shares, then judge the declarations of each file against it. */
	private function judgeRun(
		parsed: Array<{ file: String, source: String, tree: QueryNode }>, plugin: GrammarPlugin, seams: Seams
	): Array<Violation> {
		final facts: RunFacts = { mutated: { names: [], calls: [] }, contracts: [], unverified: [] };
		final live: () -> Null<ReachLiveness> = ReachLiveness.ofRun(plugin);
		for (item in parsed) {
			collectMutations(item.tree, item.source, seams, facts.mutated);
			collectContracts(item.tree, seams, facts.contracts);
			ReachLiveness.collectUnverified(item.tree, item, false, seams.conditionalKinds, live, facts.unverified);
		}
		final out: Array<Violation> = [];
		for (item in parsed) {
			final ctx: FileCtx = {
				file: item.file,
				source: item.source,
				closedWorld: LintConfig.resolveWith(_resolveConfig, item.file).boolOption(RULE_ID, CLOSED_WORLD_KEY) == true,
				facts: facts
			};
			for (decl in item.tree.children) judgeType(decl, item.tree, ctx, seams, out);
		}
		return out;
	}

	/** Judge the declarations of the module-level type `decl`, a child of `root`. */
	private function judgeType(decl: QueryNode, root: QueryNode, ctx: FileCtx, seams: Seams, out: Array<Violation>): Void {
		final lead: Array<QueryNode> = MemberKinds.precedingModifiers(decl, root, seams.leadKinds);
		if (pinned(lead, seams)) return;
		final open: Bool = !lead.exists(m -> m.kind == seams.privateKind);
		final cls: Null<QueryNode> = classOf(decl, seams);
		if (cls != null) {
			final sealed: Bool = cls != decl || lead.exists(m -> seams.sealingMetaNames.contains(m.name ?? ''));
			judgeClass(cls, open, sealed, ctx, seams, out);
		} else if (decl.kind == seams.aliasKind) {
			judgeTypedef(decl, open, ctx, seams, out);
		}
	}

	/**
	 * Judge the members of the class `cls`. A member is exposed when the type is not private and the member is public or,
	 * the class not being `sealed` (final), a subclass outside the run may reach it: Haxe `private` is visible to subclasses.
	 */
	private function judgeClass(cls: QueryNode, open: Bool, sealed: Bool, ctx: FileCtx, seams: Seams, out: Array<Violation>): Void {
		for (member in cls.children) {
			final name: Null<String> = member.name;
			final field: Bool = seams.fieldKinds.contains(member.kind);
			if (name == null || !(field || seams.functionKinds.contains(member.kind))) continue;
			final lead: Array<QueryNode> = MemberKinds.precedingModifiers(member, cls, seams.leadKinds);
			if (pinned(lead, seams)) continue;
			final exposed: Bool = open && (!sealed || lead.exists(m -> m.kind == seams.publicKind));
			final contract: Bool = ctx.facts.contracts.exists(name) || lead.exists(m -> m.kind == seams.overrideKind);
			if (field) {
				if (!contract && !refused(name, ctx.facts.mutated.names, exposed, ctx))
					flagType(member.type, 'field', name, false, ctx, seams, out);
				continue;
			}
			final scope: Mutations = { names: [], calls: [] };
			collectMutations(member, ctx.source, seams, scope);
			if (!contract) signature(member, name, exposed, ctx.facts.mutated.calls, scope, ctx, seams, out);
			for (child in member.children) locals(child, scope, ctx, seams, out);
		}
	}

	/** Judge the parameters of the function `fn` named `name` against `scope`, and its return type against `calls`. */
	private function signature(
		fn: QueryNode, name: String, exposed: Bool, calls: Map<String, Bool>, scope: Mutations, ctx: FileCtx, seams: Seams,
		out: Array<Violation>
	): Void {
		var returned: Bool = false;
		for (child in fn.children) {
			final param: Null<String> = child.name;
			if (seams.paramKinds.contains(child.kind) && param != null) {
				if (!refused(param, scope.names, exposed, ctx)) flagType(child.type, 'parameter', param, true, ctx, seams, out);
			} else if (!returned && seams.typeKinds.contains(child.kind)) {
				returned = true;
				if (!refused(name, calls, exposed, ctx)) flagType(child, 'return type', name, true, ctx, seams, out);
			}
		}
	}

	/** Judge the annotated locals and the local functions under `node`, a part of a member function whose mutations are `scope`. */
	private function locals(node: QueryNode, scope: Mutations, ctx: FileCtx, seams: Seams, out: Array<Violation>): Void {
		final name: Null<String> = node.name;
		if (name != null && seams.localKinds.contains(node.kind) && !refused(name, scope.names, false, ctx))
			flagType(node.type, 'local', name, false, ctx, seams, out);
		if (name != null && seams.localFunctionKinds.contains(node.kind)) signature(node, name, false, scope.calls, scope, ctx, seams, out);
		for (child in node.children) locals(child, scope, ctx, seams, out);
	}

	private function judgeTypedef(decl: QueryNode, open: Bool, ctx: FileCtx, seams: Seams, out: Array<Violation>): Void {
		final anon: Null<QueryNode> = decl.children[0];
		if (anon == null || decl.children.length != 1 || anon.kind != seams.anonKind) return;
		for (field in anon.children) {
			final name: Null<String> = field.name;
			final span: Null<Span> = field.span;
			if (name == null || span == null || refused(name, ctx.facts.mutated.names, open, ctx)) continue;
			final head: Null<Span> = if (seams.shortFieldKinds.contains(field.kind))
				shortHead(field, ctx.source, seams)
			else if (seams.longFieldKinds.contains(field.kind))
				arrayHead(field.children[0]?.type, ctx.source, seams)
			else
				null;
			if (head != null) report(span, head, 'typedef field', name, false, ctx, seams, out);
		}
	}

	/** Flag the declaration typed `type` when that type is the array type over one element type. */
	private function flagType(
		type: Null<QueryNode>, what: String, name: String, sink: Bool, ctx: FileCtx, seams: Seams, out: Array<Violation>
	): Void {
		final head: Null<Span> = arrayHead(type, ctx.source, seams);
		final span: Null<Span> = type?.span;
		if (head != null && span != null) report(span, head, what, name, sink, ctx, seams, out);
	}

	private function report(
		at: Span, head: Span, what: String, name: String, sink: Bool, ctx: FileCtx, seams: Seams, out: Array<Violation>
	): Void {
		final plan: Plan = { head: head, sink: sink };
		_plans[CheckScan.spanKey(ctx.file, at)] = plan;
		out.push({
			file: ctx.file,
			span: at,
			rule: RULE_ID,
			severity: Severity.Info,
			message: '\'$name\' ($what): nothing mutates the array through it — declare it ${seams.readOnly}, a read-only VIEW and not '
			+ 'a copy: whoever holds the array may still change it, it is no snapshot between threads, and its elements stay mutable'
		});
	}

	/**
	 * Whether the declaration `name` must stay as written: `mutated` changes it,
	 * conditional code no build compiles names it, or it is public in an open world.
	 */
	private static function refused(name: String, mutated: Map<String, Bool>, exposed: Bool, ctx: FileCtx): Bool {
		return mutated.exists(name) || ctx.facts.unverified.exists(name) || (exposed && !ctx.closedWorld);
	}

	/** Whether a declaration led by `lead` is extern, or kept or described by name for reflection. */
	private static function pinned(lead: Array<QueryNode>, seams: Seams): Bool {
		return lead.exists(m -> m.kind == seams.externKind || seams.pinningMetaNames.contains(m.name ?? ''));
	}

	/** The span of the array type's name heading `type`, or null when `type` is not the array type over one element type. */
	private static function arrayHead(type: Null<QueryNode>, source: String, seams: Seams): Null<Span> {
		return type == null || !seams.typeKinds.contains(type.kind) || type.children.length != 1 ? null : headAt(type, source, seams);
	}

	/** The head of a short structure field, whose type projects as a flat run of references: only `Array<E>` with a nominal `E`. */
	private static function shortHead(field: QueryNode, source: String, seams: Seams): Null<Span> {
		final refs: Array<QueryNode> = field.children.filter(c -> seams.typeRefKinds.contains(c.kind));
		return refs.length == 2 ? headAt(refs[0], source, seams) : null;
	}

	/** The span of `node`'s name where its source starts with it and the name is the array type's. */
	private static function headAt(node: QueryNode, source: String, seams: Seams): Null<Span> {
		final name: Null<String> = node.name;
		final span: Null<Span> = node.span;
		return name != null && span != null && (seams.arrayNames.contains(name) && source.substr(span.from, name.length) == name)
			? new Span(span.from, span.from + name.length)
			: null;
	}

	/**
	 * How the file spells the read-only type `readOnly`: its short name where that already resolves to it, else its full path —
	 * an import line every edit needed would tie the edits of the file into one bisect unit.
	 */
	private static function spelling(
		source: String, file: String, plugin: GrammarPlugin, readOnly: String, index: Null<SymbolIndex>
	): String {
		final root: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		if (root == null) return readOnly;
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final printer: TypeRefPrinter = TypeRefPrinter.forFile(
			file, source, root, provider == null ? [] : provider.importMap(source, file), plugin, index
		);
		final printed: PrintedTypeRef = printer.print(readOnly);
		return printed.importPath == null ? printed.text : readOnly;
	}

	/**
	 * Record into `into` every name an array is changed through under `node`: the receiver of a mutating method, the target of
	 * an index or field write, a cast operand, a literal key of a reflective call, and a call whose result is one of those.
	 */
	private static function collectMutations(node: QueryNode, source: String, seams: Seams, into: Mutations): Void {
		final first: Null<QueryNode> = node.children[0];
		if (first != null) {
			if (node.kind == seams.accessKind && seams.mutators.contains(node.name ?? '')) {
				mark(first, seams, into);
			} else if (seams.castKinds.contains(node.kind)) {
				mark(first, seams, into);
			} else if (seams.writeKinds.contains(node.kind) && (first.kind == seams.accessKind || first.kind == seams.indexKind)) {
				final receiver: Null<QueryNode> = first.children[0];
				if (receiver != null) mark(receiver, seams, into);
			} else if (node.kind == seams.callKind) {
				markReflected(node, source, seams, into);
			}
		}
		for (child in node.children) collectMutations(child, source, seams, into);
	}

	/** Record the name `node` changes an array through, its parentheses peeled: a name, a field, or a call's function. */
	private static function mark(node: QueryNode, seams: Seams, into: Mutations): Void {
		var target: QueryNode = node;
		while (target.kind == seams.parenKind && target.children.length == 1) target = target.children[0];
		final named: Null<QueryNode> = target.kind == seams.callKind ? target.children[0] : target;
		final name: Null<String> = named?.name;
		if (named == null || name == null || (named.kind != seams.identKind && named.kind != seams.accessKind)) return;
		if (target.kind == seams.callKind)
			into.calls[name] = true;
		else
			into.names[name] = true;
	}

	/** `Reflect.setField(o, 'items', v)` and every other reflective call naming a member by a literal key. */
	private static function markReflected(call: QueryNode, source: String, seams: Seams, into: Mutations): Void {
		final callee: Null<QueryNode> = call.children[0];
		if (callee == null || callee.kind != seams.accessKind) return;
		final receiver: Null<QueryNode> = callee.children[0];
		if (receiver == null || receiver.kind != seams.identKind) return;
		final at: Null<Int> = seams.reflectiveCalls['${receiver.name}.${callee.name}'];
		final key: Null<QueryNode> = at == null ? null : call.children[at + 1];
		final literal: Null<StringLiteral> = key == null ? null : seams.fold?.literalOf(key, source);
		if (literal != null) into.names[literal.content] = true;
	}

	/** Record every member name of an interface of `root`, and of an overriding class member: a signature its siblings share. */
	private static function collectContracts(root: QueryNode, seams: Seams, into: Map<String, Bool>): Void {
		for (child in root.children) {
			final iface: Bool = seams.interfaceKinds.contains(child.kind);
			final decl: Null<QueryNode> = iface ? child : classOf(child, seams);
			if (decl == null) continue;
			for (member in decl.children) {
				final name: Null<String> = member.name;
				if (name == null || !(seams.fieldKinds.contains(member.kind) || seams.functionKinds.contains(member.kind))) continue;
				if (iface || MemberKinds.precedingModifiers(member, decl, seams.leadKinds).exists(m -> m.kind == seams.overrideKind))
					into[name] = true;
			}
		}
	}

	private static function seamsOf(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final readOnly: Null<String> = shape.execution?.readOnlyArrayType;
		final access: Null<String> = shape.fieldAccessKind;
		final call: Null<String> = shape.callKind;
		final arrays: Array<String> = kindsOf(shape.arrayTypeNames);
		if (readOnly == null || access == null || call == null || arrays.length == 0) return null;
		final localFunctions: Array<String> = kindsOf(shape.localFunctionKinds);
		final rest: Null<String> = shape.restParamKind;
		return {
			arrayNames: arrays,
			readOnly: readOnly,
			mutators: kindsOf(shape.execution?.mutatingArrayMethods),
			classKinds: kindsOf(shape.classDeclKinds),
			finalClassKind: shape.finalClassDeclKind,
			containerKinds: kindsOf(shape.visibilityContainerKinds),
			sealingMetaNames: MemberKinds.withSetKinds([], [shape.finalClassMetaName]),
			interfaceKinds: kindsOf(shape.interfaceDeclKinds),
			aliasKind: shape.typeAliasDeclKind,
			anonKind: shape.anonTypeKind,
			fieldKinds: kindsOf(shape.fieldDeclKinds),
			functionKinds: kindsOf(shape.functionKinds).filter(k -> !localFunctions.contains(k)),
			localFunctionKinds: localFunctions,
			paramKinds: kindsOf(shape.paramKinds).filter(k -> k != rest),
			localKinds: kindsOf(shape.localDeclKinds),
			typeKinds: kindsOf(shape.typeAnnotationKinds),
			shortFieldKinds: kindsOf(shape.plainStructureFieldKinds),
			longFieldKinds: MemberKinds.withSetKinds([], [shape.structureVarFieldKind, shape.structureFinalFieldKind]),
			typeRefKinds: kindsOf(shape.typeRefChildKinds),
			leadKinds: kindsOf(shape.visibilityModifierKinds).concat(kindsOf(shape.modifierKinds)).concat(plugin.metaShape().metaKinds),
			publicKind: shape.publicModifierKind,
			privateKind: shape.privateModifierKind,
			overrideKind: shape.overrideModifierKind,
			externKind: shape.externModifierKind,
			pinningMetaNames: MemberKinds.withSetKinds([], [shape.retainedDeclMetaName, shape.reflectedDeclMetaName]),
			conditionalKinds: MemberKinds.withSetKinds(kindsOf(shape.conditionalRegionKinds), [shape.conditionalMemberKind]),
			writeKinds: shape.writeParentKinds,
			accessKind: access,
			indexKind: shape.indexAccessKind,
			callKind: call,
			identKind: shape.identKind,
			parenKind: shape.parenKind,
			castKinds: MemberKinds.withSetKinds([], [shape.uncheckedCastKind, shape.checkedCastKind]),
			reflectiveCalls: shape.execution?.reflectiveNameCalls ?? [],
			fold: plugin.stringFoldSupport()
		};
	}

	/** The names an optional grammar list holds, none when the grammar leaves it unset. */
	private static function kindsOf(kinds: Null<Array<String>>): Array<String> {
		return kinds ?? [];
	}

	/**
	 * The node holding the members of the module-level declaration `decl`
	 * when it is a class: itself, or the form a `final` class wraps.
	 */
	private static function classOf(decl: QueryNode, seams: Seams): Null<QueryNode> {
		if (seams.classKinds.contains(decl.kind)) return decl;
		return decl.kind == seams.finalClassKind ? decl.children.find(c -> seams.containerKinds.contains(c.kind)) : null;
	}

}
