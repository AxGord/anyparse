package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.FileGated;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.Violation;
import anyparse.check.ConfiguredTypes.OwnedMember;
import anyparse.check.RuleDeclaration.EventSpec;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Retypes an event class's `String` event-type constant to the project's TYPED event-type abstract —
 * `public static inline final CLOSE:String = 'close';` on `class PopupEvent extends Event` becomes
 * `public static inline final CLOSE:EventType<PopupEvent> = 'close';` — so a listener written for another event class
 * stops compiling. Inert until the project declares its framework's event types in `apqlint.json`:
 *
 *     "typed-event-constant": {
 *         "eventBase": "openfl.events.Event",
 *         "typeAbstract": "openfl.events.EventType",
 *         "listenerMethods": ["addEventListener", "removeEventListener", "hasEventListener"]
 *     }
 *
 * ## What a candidate is
 *
 * A `static` FINAL field (`static final` / `static inline final`) whose written type is the grammar's string type and
 * whose initializer is a string literal, declared on a class that extends `eventBase` — directly or through any chain
 * the resolution index resolves, compared by declaration identity — that is non-generic and not `#if`-guarded. A
 * `static var` is no constant and is left alone. A candidate is reported only when it is USED as an event type: the first
 * argument of a call of a `listenerMethods` name, or the first argument of a `new` (the event constructor of
 * `dispatchEvent(new C(X, …))`), written `C.X`, `pkg.C.X`, or a bare `X` that binds to the field.
 *
 * ## The abstract must keep every other use compiling
 *
 * `typeAbstract` is checked against the index before anything is reported: it must be a plain abstract (not an enum
 * abstract) of ONE type parameter over the string type, whose header converts `from` and `to` the string type. That
 * pair is what keeps a comparison with a string, a `String` parameter, a string concatenation and a `case` pattern
 * compiling after the retype; a declaration short of it makes the rule inert with one stderr line.
 *
 * ## Mismatches are reported, not retyped
 *
 * The retype turns an inconsistency the program carries today into a compile error, and the inconsistency is the
 * finding worth having: a listener typed for another event class (`addEventListener(PopupEvent.CLOSE, (e:MouseEvent)
 * -> …)`) or an event dispatched as another class (`new Event(PopupEvent.CLOSE)`) is a latent bug — the listener is
 * handed an object that is not what it declares. Each one the rule can PROVE is reported as a `Warning` at the use,
 * naming the listener's parameter type or the dispatched class, and the constant is NOT retyped (`declineReason`).
 * Proof means: a listener that is a lambda with a written parameter type, a method of the enclosing
 * type (bare or through `this`), or a local or parameter whose written type is a function type, whose
 * first parameter resolves to a class C does not extend; a `new T` whose class does not extend C.
 * A listener parameter that is a supertype of C is fine — a function parameter is contravariant.
 *
 * ## Why it is a `RiskyFix`
 *
 * What the rule cannot prove — a listener held in a variable, passed through another call, a method of another
 * object, a use outside the linted files, an array literal mixing two constants — the compiler decides: the fix is
 * applied speculatively and REVERTED per edit when the project stops typechecking, the finding then staying report-only
 * with the `risky-fix REVERTED <file> (typed-event-constant)` line naming the file. Without a `compilerOracle` the rule
 * is report-only.
 *
 * ## The rewrite
 *
 * One edit per constant: the written type becomes `typeAbstract<C>`, spelled by its simple name when that name already
 * resolves to `typeAbstract` in the file and fully qualified otherwise. No import is inserted — `shorten-type-ref`
 * owns that, and a per-constant edit with no shared import keeps every constant its own unit for the verifier's bisect,
 * so one bad listener reverts one constant.
 *
 * ## Grammar-agnostic
 *
 * Driven by `callKind`, `fieldAccessKind`, `identKind`, `newExprKind`, `lambdaKinds`, `paramKinds`, `fieldDeclKinds` /
 * `mutableFieldDeclKinds`, `memberDeclKinds`, `stringLiteralKinds` + `literalTypeNames` (the string type's name),
 * `underlyingThisTypeKinds` / `enumAbstractDeclKind` and `TypeRefShape.typeRefKinds`. The abstract header's conversion
 * clauses are read by their projected kinds, spelled literally (`FromClause` / `ToClause`) because no seam names them.
 */
@:nullSafety(Strict)
final class TypedEventConstant implements Check implements ConfigAware implements FileGated implements RiskyFix {

	/** The rule id, also the `apqlint.json` option key. */
	private static inline final RULE_ID: String = 'typed-event-constant';

	/** The projected kind of an abstract header's `from T` clause — no seam names it. */
	private static inline final FROM_CLAUSE_KIND: String = 'FromClause';

	/** The projected kind of an abstract header's `to T` clause — no seam names it. */
	private static inline final TO_CLAUSE_KIND: String = 'ToClause';

	/** The type parameters `typeAbstract` must declare: the event class goes in the one slot. */
	private static inline final ABSTRACT_ARITY: Int = 1;

	/** The linter's memoised per-file config resolver; null when run outside it. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a String event-type constant of an event class, used as a listener\'s or an event\'s type, that the project\'s typed '
			+ 'event-type abstract can type — and every listener or dispatch the retype would reject, a latent bug';
	}

	/** `needs-config` while the file's config does not declare the event base, the abstract and the listener methods. */
	public function skipReason(file: String, config: LintConfig): Null<String> {
		return RuleDeclaration.eventTypes(config, RULE_ID, []) == null ? 'needs-config' : null;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null || files.length == 0) return [];
		final spec: Null<EventSpec> = specFor(files[0].file);
		if (spec == null) return [];
		final index: Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin)();
		if (index == null) return [];
		final problems: Array<String> = [];
		final types: Null<EventTypes> = validate(spec, index, plugin, problems);
		for (p in problems) ConfiguredTypes.warn(RULE_ID, p);
		if (types == null) return [];
		final parsed: Array<Parsed> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			final info: Null<FileInfo> = index.fileInfo(entry.file);
			if (tree == null || info == null) continue;
			final parsedTree: QueryNode = tree;
			final parsedInfo: FileInfo = info;
			parsed.push({
				file: entry.file,
				source: entry.source,
				tree: parsedTree,
				info: parsedInfo,
				declaredTypeSources: seams.typed?.declaredTypeSources(entry.source) ?? []
			});
		}
		final candidates: Map<String, Candidate> = [];
		for (p in parsed) collectCandidates(p, p.tree, types, index, seams, candidates);
		final uses: Map<String, Array<Use>> = [];
		for (p in parsed) collectUses(p, p.tree, spec, candidates, index, seams, uses);
		final out: Array<Violation> = [];
		for (key => candidate in candidates) {
			final found: Null<Array<Use>> = uses[key];
			if (found != null) report(candidate, found, types, index, seams, out);
		}
		out.sort((a, b) -> a.file != b.file ? (a.file < b.file ? -1 : 1) : (a.span?.from ?? 0) - (b.span?.from ?? 0));
		return out;
	}

	/**
	 * The retype of every constant a fixable finding names: the finding's span IS the written string type, and the event
	 * class is the type declaration enclosing it. A mismatch finding (at a use, not at a type) gets no edit.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		if (violations.length == 0) return [];
		final file: String = RunScan.oneFile(violations, RULE_ID);
		final seams: Null<Seams> = readSeams(plugin);
		final spec: Null<EventSpec> = specFor(file);
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		final resolved: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		if (seams == null || spec == null || tree == null || resolved == null) return [];
		final abstractType: Null<ResolvedType> = ConfiguredTypes.resolve(resolved, spec.typeAbstract);
		final info: Null<FileInfo> = resolved.fileInfo(file);
		final simple: String = SourceText.lastSegment(spec.typeAbstract);
		final inScope: Null<ResolvedType> = info == null ? null : resolved.refs.resolveTypeRef(simple, info);
		final spelled: String = abstractType != null && inScope != null && ConfiguredTypes.same(resolved, inScope, abstractType)
			? simple
			: spec.typeAbstract;
		final out: Array<FixEdit> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null || !typesAMember(tree, span, seams)) continue;
			final typeSpan: Span = span;
			final owner: Null<String> = TypeResolver.enclosingTypeName(tree, typeSpan);
			if (owner != null) out.push({ span: typeSpan, text: '$spelled<$owner>' });
		}
		return out;
	}

	/** The rule's declaration for `file`'s config, printing every reader problem once. */
	private function specFor(file: String): Null<EventSpec> {
		final problems: Array<String> = [];
		final spec: Null<EventSpec> = RuleDeclaration.eventTypes(LintConfig.resolveWith(_resolveConfig, file), RULE_ID, problems);
		for (p in problems) ConfiguredTypes.warn(RULE_ID, p);
		return spec;
	}

	/**
	 * `spec`'s two types resolved and checked against the index: the event base names one declaration, and the abstract
	 * is a plain abstract of one type parameter over the string type converting `from` and `to` it. Null, with the reason
	 * in `problems`, otherwise.
	 */
	public static function validate(spec: EventSpec, index: SymbolIndex, plugin: GrammarPlugin, problems: Array<String>): Null<EventTypes> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return null;
		final base: Null<ResolvedType> = ConfiguredTypes.resolve(index, spec.eventBase);
		if (base == null) {
			problems.push('"eventBase" "${spec.eventBase}" names no single type in the resolution scope — rule inert');
			return null;
		}
		final abstractType: Null<ResolvedType> = ConfiguredTypes.resolve(index, spec.typeAbstract);
		if (abstractType != null && isStringAbstract(abstractType, index, seams, plugin)) return { base: base, abstractType: abstractType };
		problems.push(
			'"typeAbstract" "${spec.typeAbstract}" is not an abstract of one type parameter over ${seams.stringType} '
			+ 'converting from ${seams.stringType} and to ${seams.stringType} — rule inert'
		);
		return null;
	}

	/**
	 * Whether `span` is exactly the written type of a final field in `node`'s subtree — what a fixable finding is
	 * anchored on. A mismatch finding sits on a call or a `new`, never on a field's type, so it matches nothing.
	 */
	private static function typesAMember(node: QueryNode, span: Span, seams: Seams): Bool {
		final typeSpan: Null<Span> = node.type?.span;
		if (seams.finalKinds.contains(node.kind) && typeSpan != null && typeSpan.from == span.from && typeSpan.to == span.to) return true;
		return node.children.exists(c -> typesAMember(c, span, seams));
	}

	/**
	 * Whether `t` is a plain abstract of `ABSTRACT_ARITY` type parameter over the string type whose header converts from
	 * and to the string type — read off the declaring file's own projection, since the index records no conversion
	 * clause.
	 */
	private static function isStringAbstract(t: ResolvedType, index: SymbolIndex, seams: Seams, plugin: GrammarPlugin): Bool {
		final decl: TypeDeclInfo = t.type;
		if (!seams.abstractKinds.contains(decl.kind) || decl.kind == seams.enumAbstractKind) return false;
		if (decl.typeParamArity != ABSTRACT_ARITY || decl.underlyingRaw != seams.stringType) return false;
		final source: Null<String> = index.sourceOf(t.file.file);
		final tree: Null<QueryNode> = source == null ? null : CheckScan.parseOrNull(plugin, source);
		final node: Null<QueryNode> = tree == null ? null : findDecl(tree, decl.kind, decl.name);
		return node != null && convertsWith(node, FROM_CLAUSE_KIND, seams.stringType) && convertsWith(
			node, TO_CLAUSE_KIND, seams.stringType
		);
	}

	/** The first node of `kind` named `name` in `node`'s subtree, or null. */
	private static function findDecl(node: QueryNode, kind: String, name: String): Null<QueryNode> {
		if (node.kind == kind && node.name == name) return node;
		for (c in node.children) {
			final found: Null<QueryNode> = findDecl(c, kind, name);
			if (found != null) return found;
		}
		return null;
	}

	/** Whether the abstract header `decl` carries a `clauseKind` clause naming `type`. */
	private static function convertsWith(decl: QueryNode, clauseKind: String, type: String): Bool {
		return decl.children.exists(c -> c.kind == clauseKind && c.children.exists(t -> t.name == type));
	}

	/** The seams the rule reads, or null when a required one is unset. */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final callKind: Null<String> = shape.callKind;
		final fieldKind: Null<String> = shape.fieldAccessKind;
		final identKind: Null<String> = shape.identKind;
		final newKind: Null<String> = shape.newExprKind;
		final stringKinds: Array<String> = shape.stringLiteralKinds ?? [];
		final stringType: Null<String> = stringTypeOf(shape, stringKinds);
		final fieldKinds: Array<String> = shape.fieldDeclKinds ?? [];
		final finalKinds: Array<String> = finalFieldKinds(shape, fieldKinds);
		return callKind == null || fieldKind == null || identKind == null || newKind == null || stringType == null || finalKinds.length == 0
			? null
			: {
				shape: shape,
				typed: RunScan.typeInfoOf(plugin),
				callKind: callKind,
				fieldKind: fieldKind,
				identKind: identKind,
				newKind: newKind,
				stringType: stringType,
				stringKinds: stringKinds,
				fieldKinds: fieldKinds,
				finalKinds: finalKinds,
				memberKinds: shape.memberDeclKinds ?? [],
				classKinds: MemberKinds.classLikeContainerKinds(shape),
				abstractKinds: shape.underlyingThisTypeKinds ?? [],
				enumAbstractKind: shape.enumAbstractDeclKind,
				lambdaKinds: shape.lambdaKinds ?? [],
				paramKinds: shape.paramKinds ?? [],
				typeArgKinds: [for (k in plugin.typeRefShape().typeRefKinds) if (k != newKind) k],
				opaqueKinds: shape.opaqueKinds ?? [],
				wrappers: shape.memberTransparentWrapperTypeNames ?? [],
				selfText: shape.selfReferenceText,
				typeSyntax: plugin.typeSyntax
			};
	}

	/** The name of the type the grammar's string literals have (`String`), or null when it declares none. */
	private static function stringTypeOf(shape: RefShape, stringKinds: Array<String>): Null<String> {
		return stringKinds.length == 0 ? null : (shape.literalTypeNames ?? [])[stringKinds[0]];
	}

	/** The field kinds of `fieldKinds` that declare an IMMUTABLE field — every one the grammar does not list as mutable. */
	private static function finalFieldKinds(shape: RefShape, fieldKinds: Array<String>): Array<String> {
		final mutable: Array<String> = shape.mutableFieldDeclKinds ?? [];
		return [for (k in fieldKinds) if (!mutable.contains(k)) k];
	}

	/** Every candidate constant declared in `p`, keyed by its class's identity and its name. */
	private static function collectCandidates(
		p: Parsed, node: QueryNode, types: EventTypes, index: SymbolIndex, seams: Seams, out: Map<String, Candidate>
	): Void {
		if (seams.opaqueKinds.contains(node.kind)) return;
		final name: Null<String> = node.name;
		if (seams.classKinds.contains(node.kind) && name != null) {
			final decl: Null<ResolvedType> = index.refs.findDeclaredType(p.file, name);
			if (
				decl != null && !decl.type.guarded && decl.type.typeParamArity == 0
				&& ConfiguredTypes.inherits(index, decl, types.base) == true
			) for (member in node.children) {
				final candidate: Null<Candidate> = candidateOf(member, decl, p, seams);
				if (candidate != null) out['${index.refs.seenKey(decl)}.${candidate.constName}'] = candidate;
			}
		}
		for (c in node.children) collectCandidates(p, c, types, index, seams, out);
	}

	/** `member` of the event class `decl` as a candidate: a static final field written as the string type, holding a string literal. */
	private static function candidateOf(member: QueryNode, decl: ResolvedType, p: Parsed, seams: Seams): Null<Candidate> {
		final name: Null<String> = member.name;
		final typeSpan: Null<Span> = member.type?.span;
		if (name == null || typeSpan == null || !seams.finalKinds.contains(member.kind)) return null;
		if (p.source.substring(typeSpan.from, typeSpan.to) != seams.stringType) return null;
		final info: Null<MemberInfo> = decl.type.members.find(m -> m.name == name);
		return info == null || !info.isStatic || info.guarded || !seams.stringKinds.contains(info.initializerKind ?? '') ? null : {
			file: p.file,
			decl: decl,
			className: decl.type.name,
			constName: name,
			typeSpan: typeSpan
		};
	}

	/** Every use of a candidate as an event type in `node`'s subtree of `p`. */
	private static function collectUses(
		p: Parsed, node: QueryNode, spec: EventSpec, candidates: Map<String, Candidate>, index: SymbolIndex, seams: Seams,
		out: Map<String, Array<Use>>
	): Void {
		if (seams.opaqueKinds.contains(node.kind)) return;
		final span: Null<Span> = node.span;
		if (span != null) recordUse(p, node, span, spec, candidates, index, seams, out);
		for (c in node.children) collectUses(p, c, spec, candidates, index, seams, out);
	}

	/** Record `node` (spanning `span`) when it is a listener call or a `new` whose first argument names a candidate. */
	private static function recordUse(
		p: Parsed, node: QueryNode, span: Span, spec: EventSpec, candidates: Map<String, Candidate>, index: SymbolIndex, seams: Seams,
		out: Map<String, Array<Use>>
	): Void {
		if (node.kind == seams.callKind && node.children.length >= 2) {
			final callee: QueryNode = node.children[0];
			final method: Null<String> = callee.name;
			if (
				method == null || !spec.listenerMethods.contains(method) || callee.kind != seams.fieldKind && callee.kind != seams.identKind
			)
				return;
			final key: Null<String> = constantKey(node.children[1], p, candidates, index, seams);
			if (key != null) record(out, key, {
				file: p.file,
				span: span,
				handler: node.children.length > 2 ? node.children[2] : null,
				newType: null,
				parsed: p
			});
		} else if (node.kind == seams.newKind) {
			final args: Array<QueryNode> = [for (c in node.children) if (!seams.typeArgKinds.contains(c.kind)) c];
			final typeName: Null<String> = node.name;
			final key: Null<String> = args.length == 0 ? null : constantKey(args[0], p, candidates, index, seams);
			if (key != null && typeName != null) record(out, key, {
				file: p.file,
				span: span,
				handler: null,
				newType: typeName,
				parsed: p
			});
		}
	}

	/** Append `use` under `key`. */
	private static function record(out: Map<String, Array<Use>>, key: String, use: Use): Void {
		final list: Null<Array<Use>> = out[key];
		if (list == null)
			out[key] = [use];
		else
			list.push(use);
	}

	/**
	 * The candidate key `arg` names — `C.X` / `pkg.C.X` with a type root no value shadows, or a bare `X` binding to the
	 * field — or null when it names no candidate.
	 */
	private static function constantKey(
		arg: QueryNode, p: Parsed, candidates: Map<String, Candidate>, index: SymbolIndex, seams: Seams
	): Null<String> {
		final name: Null<String> = arg.name;
		final span: Null<Span> = arg.span;
		if (name == null || span == null) return null;
		final decl: Null<ResolvedType> = if (arg.kind == seams.fieldKind && arg.children.length == 1) {
			final owner: QueryNode = arg.children[0];
			final path: Null<Array<String>> = NominalTypes.pathOf(owner, seams.identKind, seams.fieldKind);
			path == null || !TypeResolver.receiverRootIsUnboundType(owner, p.tree, seams.shape)
				? null
				: index.refs.resolveTypeRef(path.join('.'), p.info);
		} else if (arg.kind == seams.identKind) {
			final owner: Null<String> = TypeResolver.bareFieldOwner(name, span, p.tree, seams.shape, seams.fieldKinds);
			owner == null ? null : index.refs.findDeclaredType(p.file, owner);
		} else {
			null;
		};
		if (decl == null) return null;
		final key: String = '${index.refs.seenKey(decl)}.$name';
		return candidates.exists(key) ? key : null;
	}

	/** The findings of one used candidate: a `Warning` per proven mismatch, else one fixable `Info` at its type. */
	private static function report(
		candidate: Candidate, uses: Array<Use>, types: EventTypes, index: SymbolIndex, seams: Seams, out: Array<Violation>
	): Void {
		final eventUses: Array<Use> = uses.filter(u -> isEventUse(u, types, index));
		if (eventUses.length == 0) return;
		final event: String = '${candidate.className}.${candidate.constName}';
		final abstractName: String = types.abstractType.type.name;
		var mismatched: Bool = false;
		for (use in eventUses) {
			final message: Null<String> = mismatchOf(use, candidate, event, index, seams);
			if (message == null) continue;
			final latent: String = message;
			mismatched = true;
			out.push({
				file: use.file,
				span: use.span,
				rule: RULE_ID,
				severity: Severity.Warning,
				message: latent,
				declineReason: 'typing $event $abstractName<${candidate.className}> would not compile here'
			});
		}
		if (!mismatched) out.push({
			file: candidate.file,
			span: candidate.typeSpan,
			rule: RULE_ID,
			severity: Severity.Info,
			message: 'event-type constant $event is typed ${seams.stringType}; type it $abstractName<${candidate.className}> so a listener '
			+ 'of another event class does not compile'
		});
	}

	/**
	 * Whether `use` is a use as an EVENT type: a listener call always is; a `new` only of a class extending the event
	 * base — the first argument of any other constructor is just a string handed to something that is no event.
	 */
	private static function isEventUse(use: Use, types: EventTypes, index: SymbolIndex): Bool {
		final newType: Null<String> = use.newType;
		if (newType == null) return true;
		final made: Null<ResolvedType> = index.refs.resolveTypeRef(newType, use.parsed.info);
		return made != null && ConfiguredTypes.inherits(index, made, types.base) == true;
	}

	/** The latent-bug sentence for `use`, or null when it is consistent with the event class or not provably not. */
	private static function mismatchOf(use: Use, candidate: Candidate, event: String, index: SymbolIndex, seams: Seams): Null<String> {
		final newType: Null<String> = use.newType;
		if (newType != null) {
			final made: Null<ResolvedType> = index.refs.resolveTypeRef(newType, use.parsed.info);
			return if (made == null || !seams.classKinds.contains(made.type.kind))
				null
			else if (ConfiguredTypes.inherits(index, made, candidate.decl) == false)
				'$event is dispatched as new ${made.type.name}(…), the event is ${candidate.className} — a listener of $event typed '
					+ '${candidate.className} is handed a ${made.type.name}'
			else
				null;
		}
		final handler: Null<QueryNode> = use.handler;
		if (handler == null) return null;
		final listener: QueryNode = handler;
		final param: Null<ResolvedType> = listenerParam(listener, use.parsed, index, seams);
		return if (param == null || !seams.classKinds.contains(param.type.kind))
			null
		else if (ConfiguredTypes.inherits(index, candidate.decl, param) == false)
			'listener ${handlerText(listener, use.parsed)} of $event expects ${param.type.name}, the event is ${candidate.className}'
		else
			null;
	}

	/**
	 * The type a listener's first parameter is written with: a lambda's own annotation, or a method of the enclosing type
	 * named bare or through the self reference, read where the method is declared. Null for any other listener.
	 */
	private static function listenerParam(handler: QueryNode, p: Parsed, index: SymbolIndex, seams: Seams): Null<ResolvedType> {
		if (seams.lambdaKinds.contains(handler.kind)) {
			final param: Null<QueryNode> = handler.children.find(c -> seams.paramKinds.contains(c.kind));
			final typeSpan: Null<Span> = param?.type?.span;
			return typeSpan == null
				? null
				: ConfiguredTypes.resolveWritten(
					index, p.source.substring(typeSpan.from, typeSpan.to), p.info, seams.wrappers, seams.typeSyntax
				);
		}
		final name: Null<String> = handler.name;
		final span: Null<Span> = handler.span;
		if (name == null || span == null) return null;
		if (handler.kind == seams.identKind && TypeResolver.bindsToValueDeclaration(name, span, p.tree, seams.shape)) {
			// a local or a parameter holding a function value: its written function type names the parameter
			final written: Null<String> = TypeResolver.identDeclaredTypeSource(
				handler, seams.shape, p.tree, () -> p.declaredTypeSources, false
			);
			final first: Null<String> = written == null ? null : firstParamText(written, seams.typeSyntax);
			return first == null ? null : ConfiguredTypes.resolveWritten(index, first, p.info, seams.wrappers, seams.typeSyntax);
		}
		final viaSelf: Bool = handler.kind == seams.fieldKind && handler.children.length == 1
			&& handler.children[0].kind == seams.identKind && handler.children[0].name == seams.selfText;
		if (!viaSelf && handler.kind != seams.identKind) return null;
		final enclosing: Null<String> = TypeResolver.enclosingTypeName(p.tree, span);
		final owner: Null<ResolvedType> = enclosing == null ? null : index.refs.findDeclaredType(p.file, enclosing);
		final method: Null<OwnedMember> = owner == null ? null : ConfiguredTypes.memberOf(index, owner, name);
		if (method == null || seams.fieldKinds.contains(method.member.kind) || !seams.memberKinds.contains(method.member.kind)) return null;
		final written: Null<String> = method.member.paramTypeSources[0];
		return written == null ? null : ConfiguredTypes.resolveWritten(index, written, method.owner.file, seams.wrappers, seams.typeSyntax);
	}

	/** The first parameter's text of the written function type `written` (`MouseEvent -> Void`), or null for any other type. */
	private static function firstParamText(written: String, typeSyntax: TypeSyntaxReader): Null<String> {
		return switch typeSyntax(written)?.shape {
			case Function(params, _, _) if (params.length > 0): params[0].type.text;
			case _: null;
		};
	}

	/** The listener as written, for the message. */
	private static function handlerText(handler: QueryNode, p: Parsed): String {
		final span: Null<Span> = handler.span;
		if (span == null) return '';
		final text: String = p.source.substring(span.from, span.to);
		final firstLine: String = text.split('\n')[0];
		return firstLine.length < text.length ? '$firstLine…' : text;
	}

}

/** The declaration's two types, resolved and checked. */
typedef EventTypes = {
	final base: ResolvedType;
	final abstractType: ResolvedType;
}

/** One linted file, parsed once for both walks. */
private typedef Parsed = {
	final file: String;
	final source: String;
	final tree: QueryNode;
	final info: FileInfo;
	final declaredTypeSources: Map<Int, String>;
}

/** One candidate constant. */
private typedef Candidate = {
	final file: String;
	final decl: ResolvedType;
	final className: String;
	final constName: String;
	final typeSpan: Span;
}

/** One use of a candidate as an event type: a listener call (with its listener, if any) or a `new`. */
private typedef Use = {
	final file: String;
	final span: Span;
	final handler: Null<QueryNode>;
	final newType: Null<String>;
	final parsed: Parsed;
}

/** The seams the rule reads, resolved once per run. */
private typedef Seams = {
	final shape: RefShape;
	final typed: Null<TypeInfoProvider>;
	final callKind: String;
	final fieldKind: String;
	final identKind: String;
	final newKind: String;
	final stringType: String;
	final stringKinds: Array<String>;
	final fieldKinds: Array<String>;
	final finalKinds: Array<String>;
	final memberKinds: Array<String>;
	final classKinds: Array<String>;
	final abstractKinds: Array<String>;
	final enumAbstractKind: Null<String>;
	final lambdaKinds: Array<String>;
	final paramKinds: Array<String>;
	final typeArgKinds: Array<String>;
	final opaqueKinds: Array<String>;
	final wrappers: Array<String>;
	final selfText: Null<String>;
	final typeSyntax: TypeSyntaxReader;
}
