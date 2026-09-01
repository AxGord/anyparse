package anyparse.check;

import anyparse.check.Check.CrossFileEdits;
import anyparse.check.Check.CrossFileFix;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;

using Lambda;

/**
 * A parameter with no default that at least two call sites hand the SAME compile-time constant:
 * the constant is the default the signature never declared. Flags the parameter, and the autofix
 * writes `= <constant>` onto it and drops the argument at every site that agreed — atomically,
 * across files, through `CrossFileFix`. Sites passing something ELSE keep their explicit argument
 * and are untouched, which is what makes the rewrite meaning-preserving rather than a guess.
 * `Severity.Info`, default OFF.
 *
 * The shape is common enough to have a name: a constant whose own doc calls it "the default", read
 * at every call site because the signature has no slot for it. The reviewer's version of this rule
 * is "a parameter with one correct value per call site is not flexibility"; this is the mechanical
 * half of it, and it stops short of the other half (deleting a parameter no caller ever varies),
 * which needs a judgement no check has.
 *
 * ## What counts as the constant
 *
 * A REFERENCE to a `static inline` constant, never a literal. Two reasons, and the first is hard:
 * Haxe accepts only a compile-time constant as a default, and a plain `static final` is NOT one —
 * `function f(ms:Int = K.NI)` where `NI` is a non-inline `static final` is
 * `Default argument value should be constant` (measured on 4.3). So the rule must read the
 * constant's own declaration, and `inline` is the gate. The second reason is division of labour: a
 * repeated LITERAL argument is `magic-number`'s finding, and hoisting it into a named constant is
 * that rule's fix, after which this one sees it.
 *
 * Visibility is checked from the DECLARATION, not from the call: a qualified `Type.CONST` is
 * readable wherever `Type` is, but a bare `CONST` is the CALLER's own member, so it is accepted
 * only when caller and declaration share a type.
 *
 * ## Resolution — and why the gates are where they are
 *
 * A callee resolves three ways, all of which require the declaration to be IN the lint scope:
 * a bare name to a member of the enclosing type, `Type.member` to a `static` of a type declared
 * exactly once, and `receiver.member` through the receiver's own declared type. That last one is
 * what reaches the largest real group (a widget method called on a dozen differently-named
 * fields), and it is also the one that would reach a LIBRARY signature if the scope gate were
 * missing — nothing about `gl.disable(gl.BLEND)` should ever be rewritten by a linter.
 *
 * Two gates carry the correctness of the rewrite itself:
 *
 * - the parameter must be TRAILING, or every parameter after it must already have a default.
 *   Otherwise the argument cannot be dropped without Haxe's type-directed skipping deciding what
 *   the remaining arguments mean, which is a different program;
 * - the function must be referenced NOWHERE as a value. Adding a default changes its type —
 *   `(Int) -> Void` becomes `(?Int) -> Void`, and the two do not unify (measured) — so a `.bind`,
 *   a method value or any non-callee occurrence of the name refuses the whole finding.
 *
 * A member NAME declared more than ONCE in the scope is refused outright — by two types, or by
 * the two arms of one conditional region. That is the cheap over-approximation of "this may be an
 * interface member or an override": a default added to an
 * implementation leaves the interface's signature alone, so a call typed by the interface would
 * lose an argument it still needs.
 *
 * ## Scope sensitivity
 *
 * The census is built from the files the check is HANDED. A narrow run sees few call sites and
 * therefore reports almost nothing — the safe direction, and the reason a per-file lint is not a
 * census. The threshold is TWO agreeing sites, so a single-caller parameter is never flagged even
 * though it is the strongest case for a default; deciding that one needs to know whether the
 * caller is the only one that will ever exist, which the scope cannot say.
 */
@:nullSafety(Strict)
final class DefaultRepeatedArgument implements Check implements DefaultOff implements CrossFileFix {

	private static inline final RULE_ID: String = 'default-repeated-argument';

	/** What each flagged parameter's fix must do, keyed by `<file>:<span.from>` of the violation. */
	private final _plans: Map<String, Plan> = [];

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a parameter with no default that several call sites hand the same constant — the default the signature never declared';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		_plans.clear();
		final resolved: Null<Seams> = resolveSeams(plugin);
		if (resolved == null) return [];
		final seams: Seams = resolved;
		final parsed: Array<Parsed> = parseAll(plugin, files, seams);
		final scope: Scope = collectDeclarations(parsed, seams);
		final census: Map<String, Map<String, Array<CallSite>>> = [];
		for (entry in parsed) collectCalls(census, entry, scope, seams);
		return report(census, scope, seams);
	}

	/** Every edit lands through `crossFileFix` — the argument sites are in other files. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** One atomic group per flagged parameter: the default written on, the agreed arguments dropped. */
	public function crossFileFix(
		files: Array<{ file: String, source: String }>, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<Array<CrossFileEdits>> {
		final out: Array<Array<CrossFileEdits>> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final plan: Null<Plan> = _plans['${v.file}:${span.from}'];
			if (plan != null) out.push(slices(plan));
		}
		return out;
	}

	// ---- reporting -------------------------------------------------------------------------

	/** One finding per (member, parameter) whose agreeing sites clear every gate. */
	private function report(census: Map<String, Map<String, Array<CallSite>>>, scope: Scope, seams: Seams): Array<Violation> {
		final out: Array<Violation> = [];
		for (key => byConstant in census) {
			final parts: Array<String> = key.split('#');
			final index: Null<Int> = Std.parseInt(parts[1]);
			final found: Null<MemberInfo> = scope.members[parts[0]];
			if (index == null || found == null) continue;
			final member: MemberInfo = found;
			if (!eligible(member, scope, seams)) continue;
			final winner: Null<{ constant: String, sites: Array<CallSite> }> = agreed(byConstant);
			if (winner == null) continue;
			final param: Null<QueryNode> = index < member.params.length ? member.params[index] : null;
			if (param == null || !defaultable(member, index, seams)) continue;
			final paramSpan: Null<Span> = param.span;
			if (paramSpan == null) continue;
			// The literal is bound before the index write: array-access assignment resolves its
			// `@:arrayAccess` overload from the argument's own type, which a bare structure literal
			// does not yet have.
			final plan: Plan = {
				declFile: member.file,
				paramEnd: paramSpan.to,
				constant: winner.constant,
				sites: winner.sites
			};
			_plans['${member.file}:${paramSpan.from}'] = plan;
			out.push({
				file: member.file,
				span: paramSpan,
				rule: RULE_ID,
				severity: Severity.Info,
				message: '${winner.sites.length} call sites pass \'${winner.constant}\' here — make it the parameter\'s default'
			});
		}
		return out;
	}

	/** One plan's edits, grouped by the file each falls in. */
	private static function slices(plan: Plan): Array<CrossFileEdits> {
		final byFile: Map<String, Array<{ span: Span, text: String }>> = [];
		inline function add(file: String, edit: { span: Span, text: String }): Void {
			final edits: Array<{ span: Span, text: String }> = byFile[file] ?? [];
			edits.push(edit);
			byFile[file] = edits;
		}
		add(plan.declFile, { span: new Span(plan.paramEnd, plan.paramEnd), text: ' = ${plan.constant}' });
		for (site in plan.sites) add(site.file, { span: new Span(site.cutFrom, site.cutTo), text: '' });
		return [for (file => edits in byFile) { file: file, edits: edits }];
	}

	// ---- census ----------------------------------------------------------------------------

	/** Every (member, parameter index) a call handed a constant, and which constant, and where. */
	private static function collectCalls(
		census: Map<String, Map<String, Array<CallSite>>>, entry: Parsed, scope: Scope, seams: Seams
	): Void {
		walkCalls(entry.tree, null, (call, owner) -> {
			final member: Null<MemberInfo> = resolveCallee(call, owner, entry, scope, seams);
			if (member == null) return;
			final args: Array<QueryNode> = [for (i in 1...call.children.length) call.children[i]];
			// Argument index equals PARAMETER index only when the call fills every slot. Haxe skips
			// an already-defaulted parameter by TYPE, so a shorter argument list can bind its values
			// to a different set of parameters than their positions suggest, and the census would
			// then attribute a constant to the wrong one.
			if (args.length != member.params.length) return;
			for (i in 0...args.length) {
				final constant: Null<String> = constantSpelling(args[i], owner, member.owner, entry, scope, seams);
				if (constant == null) continue;
				final key: String = '${member.owner}.${member.name}#$i';
				final byConstant: Map<String, Array<CallSite>> = census[key] ?? [];
				final sites: Array<CallSite> = byConstant[constant] ?? [];
				final site: Null<CallSite> = callSite(entry.file, args, i);
				if (site == null) continue;
				sites.push(site);
				byConstant[constant] = sites;
				census[key] = byConstant;
			}
		}, seams);
	}

	/**
	 * The deletion span for argument `i` — the argument plus the comma that separates it from its
	 * neighbour, so removing it leaves a well-formed list. A sole argument cuts only itself.
	 */
	private static function callSite(file: String, args: Array<QueryNode>, i: Int): Null<CallSite> {
		final span: Null<Span> = args[i].span;
		if (span == null) return null;
		if (i > 0) {
			final previous: Null<Span> = args[i - 1].span;
			return previous == null ? null : { file: file, cutFrom: previous.to, cutTo: span.to };
		}
		if (args.length <= 1) return { file: file, cutFrom: span.from, cutTo: span.to };
		final next: Null<Span> = args[i + 1].span;
		return next == null ? null : { file: file, cutFrom: span.from, cutTo: next.from };
	}

	/** The constant at least two sites agree on, or null when no single spelling reaches two. */
	private static function agreed(byConstant: Map<String, Array<CallSite>>): Null<{ constant: String, sites: Array<CallSite> }> {
		var best: Null<{ constant: String, sites: Array<CallSite> }> = null;
		for (constant => sites in byConstant) if (sites.length >= 2 && (best == null || sites.length > best.sites.length))
			best = { constant: constant, sites: sites };
		return best;
	}

	// ---- gates -----------------------------------------------------------------------------

	/** Whether the DECLARATION may take a default at all — see the type doc's gate list. */
	private static function eligible(member: MemberInfo, scope: Scope, seams: Seams): Bool {
		return member.plain && scope.memberOwners[member.name] == 1 && scope.valueReferenced[member.name] != true;
	}

	/** Whether parameter `index` can lose its argument — it is last, or every later one already defaults. */
	private static function defaultable(member: MemberInfo, index: Int, seams: Seams): Bool {
		final param: QueryNode = member.params[index];
		if (param.children.length != 0 || param.kind == seams.optionalParamKind || param.kind == seams.restParamKind) return false;
		for (i in index + 1...member.params.length) {
			final later: QueryNode = member.params[i];
			if (later.children.length == 0 && later.kind != seams.optionalParamKind && later.kind != seams.restParamKind) return false;
		}
		return true;
	}

	/**
	 * The written spelling of `arg` when it is a reference to an `inline` constant this
	 * declaration can also see, else null. `callerOwner` is the type the call sits in and
	 * `declOwner` the one declaring the callee — a BARE constant belongs to the former and is
	 * only usable as a default when the two are the same type.
	 */
	private static function constantSpelling(
		arg: QueryNode, callerOwner: Null<String>, declOwner: String, entry: Parsed, scope: Scope, seams: Seams
	): Null<String> {
		final name: Null<String> = arg.name;
		if (name == null) return null;
		if (arg.kind == seams.identKind) {
			return if (callerOwner != declOwner || entry.binders.exists(name))
				null
			else if (scope.constants['$declOwner.$name'] == true)
				name
			else
				null;
		}
		if (arg.kind != seams.fieldAccessKind || arg.children.length != 1) return null;
		final receiver: QueryNode = arg.children[0];
		final declared: Null<String> = receiver.name;
		if (receiver.kind != seams.identKind || declared == null) return null;
		final typeName: String = declared;
		// The default is written INSIDE the declaring type, where the qualifier is that type's own name
		// — `drainIOThread(ms:Int = ThreadsUtil.DRAIN_TIMEOUT_MS)` inside `ThreadsUtil` compiles but
		// reads as a stutter. Dropping it also merges the qualified and bare spellings of one constant
		// into a single census bucket, which is what they are.
		return if (!upperInitial(typeName) || entry.binders.exists(typeName) || scope.ambiguousTypes[typeName] == true)
			null
		else if (scope.constants['$typeName.$name'] != true)
			null
		else if (typeName == declOwner)
			name
		else
			'$typeName.$name';
	}

	// ---- resolution ------------------------------------------------------------------------

	/** The declaration a call's callee names, or null when the rule cannot see one. */
	private static function resolveCallee(
		call: QueryNode, owner: Null<String>, entry: Parsed, scope: Scope, seams: Seams
	): Null<MemberInfo> {
		final callee: QueryNode = call.children[0];
		final name: Null<String> = callee.name;
		if (name == null) return null;
		if (callee.kind == seams.identKind) return owner == null || entry.binders.exists(name) ? null : scope.members['$owner.$name'];
		if (callee.kind != seams.fieldAccessKind || callee.children.length != 1) return null;
		final receiver: QueryNode = callee.children[0];
		final receiverName: Null<String> = receiver.name;
		if (receiver.kind != seams.identKind || receiverName == null || receiverName == '') return null;
		if (upperInitial(receiverName)) {
			if (entry.binders.exists(receiverName) || scope.ambiguousTypes[receiverName] == true) return null;
			final member: Null<MemberInfo> = scope.members['$receiverName.$name'];
			return member != null && member.isStatic ? member : null;
		}
		final typeName: Null<String> = receiverType(receiverName, receiver, entry, seams);
		if (typeName == null || scope.ambiguousTypes[typeName] == true) return null;
		final member: Null<MemberInfo> = scope.members['$typeName.$name'];
		return member != null && !member.isStatic ? member : null;
	}

	/**
	 * The simple name of an INSTANCE receiver's declared type, resolved through the binding the
	 * scope resolver hands the occurrence and the annotation on that binding. Null for an
	 * unannotated or unresolved receiver — no evidence, no finding.
	 */
	private static function receiverType(name: String, receiver: QueryNode, entry: Parsed, seams: Seams): Null<String> {
		final span: Null<Span> = receiver.span;
		final sources: Null<Map<Int, String>> = entry.declaredTypes;
		if (span == null || sources == null) return null;
		final hits: Array<RefHit> = entry.refs[name] ?? Refs.find(name, entry.tree, entry.shape);
		entry.refs.set(name, hits);
		for (hit in hits) if (hit.span.from == span.from) {
			final binding: Null<Span> = hit.bindingSpan;
			return binding == null ? null : sources[binding.from];
		}
		return null;
	}

	// ---- declaration collection ------------------------------------------------------------

	/** Every type, member, `inline` constant and value-use of a member name across the scope. */
	private static function collectDeclarations(parsed: Array<Parsed>, seams: Seams): Scope {
		final scope: Scope = {
			members: [],
			constants: [],
			memberOwners: [],
			ambiguousTypes: [],
			seenTypes: [],
			valueReferenced: []
		};
		for (entry in parsed) collectHosts(entry.tree, entry, scope, seams);
		for (entry in parsed) collectValueUses(entry.tree, null, 0, scope, seams);
		return scope;
	}

	private static function collectHosts(node: QueryNode, entry: Parsed, scope: Scope, seams: Seams): Void {
		final name: Null<String> = node.name;
		if (seams.typeHostKinds.contains(node.kind) && name != null) {
			if (scope.seenTypes.exists(name)) scope.ambiguousTypes.set(name, true);
			scope.seenTypes.set(name, true);
			collectMembers(node, name, entry, scope, seams);
		}
		for (c in node.children) collectHosts(c, entry, scope, seams);
	}

	private static function collectMembers(host: QueryNode, owner: String, entry: Parsed, scope: Scope, seams: Seams): Void {
		final run: Array<String> = [];
		var blocked: Bool = false;
		for (child in host.children) {
			if (seams.metaKinds.contains(child.kind)) {
				blocked = true;
				continue;
			}
			if (seams.modifierKinds.contains(child.kind)) {
				run.push(child.kind);
				continue;
			}
			if (child.kind == seams.conditionalMemberKind) {
				collectMembers(child, owner, entry, scope, seams);
				run.resize(0);
				blocked = false;
				continue;
			}
			final name: Null<String> = child.name;
			if (name != null && seams.memberDeclKinds.contains(child.kind)) {
				if (seams.functionKinds.contains(child.kind))
					addMember(child, owner, name, run, blocked, entry, scope, seams);
				else if (isInlineConstant(run, seams))
					scope.constants.set('$owner.$name', true);
			}
			run.resize(0);
			blocked = false;
		}
	}

	private static function addMember(
		decl: QueryNode, owner: String, name: String, run: Array<String>, blocked: Bool, entry: Parsed, scope: Scope, seams: Seams
	): Void {
		final key: String = '$owner.$name';
		scope.memberOwners.set(name, (scope.memberOwners[name] ?? 0) + 1);
		if (scope.members.exists(key)) return;
		final staticKind: Null<String> = seams.staticModifierKind;
		scope.members.set(key, {
			file: entry.file,
			owner: owner,
			name: name,
			params: [for (c in decl.children) if (seams.paramKinds.contains(c.kind)) c],
			isStatic: staticKind != null && run.contains(staticKind),
			plain: !blocked && name != seams.constructorName && !overriding(run, seams) && !rebindable(run, seams)
			&& decl.children.exists(c -> seams.bodyKinds.contains(c.kind))
		});
	}

	/** Whether a modifier run marks a constant this rule may spell as a default — `static inline`. */
	private static function isInlineConstant(run: Array<String>, seams: Seams): Bool {
		final inlineKind: Null<String> = seams.inlineModifierKind;
		final staticKind: Null<String> = seams.staticModifierKind;
		return inlineKind != null && staticKind != null && run.contains(inlineKind) && run.contains(staticKind);
	}

	private static function overriding(run: Array<String>, seams: Seams): Bool {
		final kind: Null<String> = seams.overrideModifierKind;
		return kind != null && run.contains(kind);
	}

	private static function rebindable(run: Array<String>, seams: Seams): Bool {
		final dyn: Null<String> = seams.dynamicModifierKind;
		if (dyn != null && run.contains(dyn)) return true;
		final mac: Null<String> = seams.macroModifierKind;
		return mac != null && run.contains(mac);
	}

	/** Mark every member name that occurs anywhere OTHER than as a call's callee — a value use. */
	private static function collectValueUses(node: QueryNode, parent: Null<QueryNode>, index: Int, scope: Scope, seams: Seams): Void {
		final name: Null<String> = node.name;
		final isCallee: Bool = parent != null && parent.kind == seams.callKind && index == 0;
		if (
			name != null && !isCallee && (node.kind == seams.identKind || node.kind == seams.fieldAccessKind)
			&& scope.memberOwners.exists(name)
		)
			scope.valueReferenced.set(name, true);
		for (i in 0...node.children.length) collectValueUses(node.children[i], node, i, scope, seams);
	}

	// ---- walking ---------------------------------------------------------------------------

	/** Visit every call with the simple name of the type it sits in. */
	private static function walkCalls(node: QueryNode, owner: Null<String>, visit: (QueryNode, Null<String>) -> Void, seams: Seams): Void {
		final here: Null<String> = seams.typeHostKinds.contains(node.kind) && node.name != null ? node.name : owner;
		if (node.kind == seams.callKind && node.children.length > 1) visit(node, here);
		for (c in node.children) walkCalls(c, here, visit, seams);
	}

	private static function parseAll(plugin: GrammarPlugin, files: Array<{ file: String, source: String }>, seams: Seams): Array<Parsed> {
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		final shape: RefShape = plugin.refShape();
		final out: Array<Parsed> = [];
		for (entry in files) {
			final parsedTree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (parsedTree == null) continue;
			// A narrowed local never reaches a non-nullable field of an anonymous structure literal.
			final tree: QueryNode = parsedTree;
			final binders: Map<String, Bool> = [];
			collectBinders(tree, binders, seams);
			out.push({
				file: entry.file,
				tree: tree,
				shape: shape,
				binders: binders,
				declaredTypes: provider?.declaredTypes(entry.source),
				refs: []
			});
		}
		return out;
	}

	private static function collectBinders(node: QueryNode, out: Map<String, Bool>, seams: Seams): Void {
		final name: Null<String> = node.name;
		if (name != null && seams.binderKinds.contains(node.kind)) out[name] = true;
		for (c in node.children) collectBinders(c, out, seams);
	}

	private static function upperInitial(name: String): Bool {
		return name.charAt(0).toUpperCase() == name.charAt(0);
	}

	/** Resolve every seam the check reads, or null when one it cannot work without is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final callKind: Null<String> = shape.callKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (callKind == null || fieldAccessKind == null || shape.upperInitialNeverCaptures != true) return null;
		final modifiers: Array<String> = (shape.modifierOrderKinds ?? []).concat(shape.visibilityModifierKinds ?? []);
		for (kind in [
			shape.staticModifierKind,
			shape.inlineModifierKind,
			shape.macroModifierKind,
			shape.dynamicModifierKind,
			shape.externModifierKind,
			shape.overrideModifierKind
		]) {
			if (kind != null && !modifiers.contains(kind)) modifiers.push(kind);
		}
		return {
			callKind: callKind,
			identKind: shape.identKind,
			fieldAccessKind: fieldAccessKind,
			paramKinds: shape.paramKinds ?? [],
			optionalParamKind: shape.optionalParamKind,
			restParamKind: shape.restParamKind,
			typeHostKinds: (shape.typeDeclKinds ?? []).concat(shape.visibilityContainerKinds ?? []),
			memberDeclKinds: shape.memberDeclKinds ?? [],
			functionKinds: shape.functionKinds ?? [],
			binderKinds: (shape.localDeclKinds ?? []).concat(shape.paramKinds ?? []).concat(shape.selfScopeDeclKinds ?? []),
			modifierKinds: modifiers,
			metaKinds: plugin.metaShape().metaKinds,
			staticModifierKind: shape.staticModifierKind,
			inlineModifierKind: shape.inlineModifierKind,
			dynamicModifierKind: shape.dynamicModifierKind,
			macroModifierKind: shape.macroModifierKind,
			overrideModifierKind: shape.overrideModifierKind,
			conditionalMemberKind: shape.conditionalMemberKind,
			constructorName: shape.constructorName,
			bodyKinds: shape.functionBodyKinds ?? []
		};
	}

}

/** One parsed file plus the per-file tables the census reads. */
private typedef Parsed = {
	final file: String;
	final tree: QueryNode;
	final shape: RefShape;
	final binders: Map<String, Bool>;
	final declaredTypes: Null<Map<Int, String>>;
	final refs: Map<String, Array<RefHit>>;
};

/** One function declaration the rule can see, and what its signature allows. */
private typedef MemberInfo = {
	final file: String;
	final owner: String;
	final name: String;
	final params: Array<QueryNode>;
	final isStatic: Bool;

	/** False when the declaration's own shape forbids a default — see the type doc's gate list. */
	final plain: Bool;
};

/** One agreeing call site's deletion span. */
private typedef CallSite = {
	final file: String;
	final cutFrom: Int;
	final cutTo: Int;
};

/** What one flagged parameter's fix must do. */
private typedef Plan = {
	final declFile: String;
	final paramEnd: Int;
	final constant: String;
	final sites: Array<CallSite>;
};

/** Everything the scope declares, keyed for the census. */
private typedef Scope = {
	final members: Map<String, MemberInfo>;
	final constants: Map<String, Bool>;
	final memberOwners: Map<String, Int>;
	final ambiguousTypes: Map<String, Bool>;
	final seenTypes: Map<String, Bool>;
	final valueReferenced: Map<String, Bool>;
};

/** Every seam `DefaultRepeatedArgument` reads, resolved once per run. */
private typedef Seams = {
	final callKind: String;
	final identKind: String;
	final fieldAccessKind: String;
	final paramKinds: Array<String>;
	final optionalParamKind: Null<String>;
	final restParamKind: Null<String>;
	final typeHostKinds: Array<String>;
	final memberDeclKinds: Array<String>;
	final functionKinds: Array<String>;
	final binderKinds: Array<String>;
	final modifierKinds: Array<String>;
	final metaKinds: Array<String>;
	final staticModifierKind: Null<String>;
	final inlineModifierKind: Null<String>;
	final dynamicModifierKind: Null<String>;
	final macroModifierKind: Null<String>;
	final overrideModifierKind: Null<String>;
	final conditionalMemberKind: Null<String>;
	final constructorName: Null<String>;
	final bodyKinds: Array<String>;
};
