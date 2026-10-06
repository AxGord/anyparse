package anyparse.check;

import anyparse.check.Check.OracleRelaxable;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.Violation;
import anyparse.check.ReflectionScan.ReflectionSurface;
import anyparse.query.CtorFieldWrite;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.MemberWriteScan;
import anyparse.query.NominalTypes;
import anyparse.query.OccurrenceScan;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * Flags a private field that is only a per-call SCRATCH value of one method — every read and write of
 * it sits in that method, and every read there follows a write of the same call — and turns it into
 * a local of that method. `Info`, with an autofix: the field is deleted and the first write becomes the
 * declaration (`final` when it is the only write, else `var`), keeping the field's declared type; the
 * local drops the field's leading underscores when nothing the method mentions takes that name.
 *
 * ## What is reported — every gate a positive proof
 *
 * - The field is a mutable instance field with no modifier but the default visibility and no metadata,
 *   not a property, declared directly in a class-like type, and every reference to it lives in its own
 *   file (`MemberWriteScan.referencesConfined`: no subtype or `@:access` grantee mentions it, no `@:allow`,
 *   no skipped file spells it); the type carries no `@:rtti`, and the name occurs in no string literal
 *   of the resolution scope (a possible `Reflect.field` target, as for `unused-private`).
 * - Every occurrence of the name in the type — the bare name or `this.name` — lies in the body of ONE
 *   method, none inside a closure (it may run after the call returns), a reification or a conditional
 *   region; no binder in the type takes the name, and no other receiver's member is spelled with it.
 *
 * ## What the fix additionally proves — report-only when it cannot
 *
 * - DOMINANCE (`DominanceWalk`): every read follows a write on every path, so no read can see what an
 *   earlier call left. Pessimistic: a branch assigns only when both arms do, a loop, `switch` or `try`
 *   leaves the state as it found it, and a read in a loop body after a write of the same iteration is
 *   dominated. This one fails in `run`; the finding then says so.
 * - A DECLARATION SLOT: the first write is a statement `name = value;` of a block holding every
 *   occurrence after it, so the local declared there is in scope at each of them.
 * - A TYPE: the field declares one, which the local keeps.
 * - A DROPPABLE INITIALIZER: none, a side-effect-free one, or a construction of a class whose
 *   constructor only assigns its own fields side-effect-free values (`trivialConstruction`).
 * - A LIFETIME the field did not carry: no method is CALLED on an object value, which may start work
 *   outliving the call (a loader's `load()`) that only the field kept alive.
 * - NO RECURSION: the method does not name itself, so no recursive call runs between a write and a
 *   read — the two calls would share a field and not a local (a constructor may name `new`: that
 *   builds another object). Indirect re-entry (a listener the method synchronously fires, mutual
 *   recursion) is the accepted residual: `MemberReach` was tried for it and refuses every
 *   display-object setter through name-based dispatch.
 * - No build macro reaches the type, which may read the field list this deletes — lifted under a
 *   compiler oracle (`RiskyFix` + `OracleRelaxable`), where the edit is typechecked and reverted on
 *   failure; a builder that silently generates less for one field fewer is the residual it keeps.
 */
@:nullSafety(Strict)
final class ScratchField implements Check implements RiskyFix implements OracleRelaxable {

	/** This check's stable id, spelled once. */
	private static inline final RULE_ID: String = 'scratch-field';

	/** A binary node has exactly [left, right] children. */
	private static inline final BINARY_CHILD_COUNT: Int = 2;

	/** The declined fix of a field some read sees before a write of the same call. */
	private static inline final DECLINE_NOT_DOMINATED: String = 'a read is not preceded by a write of the same call on every path, '
		+ 'so the field may carry a value from one call to the next';

	/** The declined fix of a field whose first write has no statement the declaration can take the place of. */
	private static inline final DECLINE_NO_SLOT: String = 'the first write is no statement of a block holding every use after it, '
		+ 'so there is no one place to declare the local';

	/** Whether a compiler oracle verifies the fix, which is what admits a macro-built owner's edit. */
	private var _oracleRelaxed: Bool = false;

	public function new() {}

	/**
	 * Admit the edits of MACRO-BUILT owners. Set by the lint driver only when this check runs as a
	 * verified `RiskyFix`, so those edits always pass the typecheck-and-revert pipeline.
	 */
	public function setOracleRelaxed(relaxed: Bool): Void {
		_oracleRelaxed = relaxed;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a private field written and read in one method only, every read after a write of the same call, that can be a local';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final resolved: Null<Seams> = seamsOf(plugin.refShape());
		if (resolved == null) return [];
		final seams: Seams = resolved;
		final lazyIndex: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin);
		var surface: Null<ReflectionSurface> = null;
		final out: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			for (c in candidatesIn(tree, entry.source, seams)) {
				final index: Null<SymbolIndex> = lazyIndex();
				if (index == null || !MemberWriteScan.referencesConfined(c.owner, c.name, entry.source, index, plugin)) continue;
				if (index.traits.transitivelyCarriesRtti(c.owner)) continue;
				final strings: ReflectionSurface = surface ?? ReflectionScan.reflectionSurface(files, plugin);
				surface = strings;
				if (strings.whole.exists(s -> OccurrenceScan.referencedInRange(s, c.name, 0, s.length, []))) continue;
				final span: Null<Span> = c.field.span;
				if (span == null) continue;
				final where: String = 'field `${c.name}` is used only inside `${c.methodName}`';
				out.push({
					file: entry.file,
					span: span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: c.plan == null && c.decline == DECLINE_NOT_DOMINATED
						? '$where, but a read there can see what an earlier call left in it'
						: '$where, written before every read there — it can be a local of that method',
					declineReason: c.plan == null ? c.decline : null
				});
			}
		}
		return out;
	}

	/**
	 * Delete each flagged field and declare it at its first write, renaming its occurrences — for a
	 * finding whose plan `run` built, whose field declares a type, and that clears the gates only the
	 * whole program can answer (`wholeProgramDecline`). A finding that fails one keeps its report and
	 * names the gate.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final resolved: Null<Seams> = seamsOf(plugin.refShape());
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (resolved == null || tree == null) return [];
		final seams: Seams = resolved;
		final typed: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final types: Null<Map<Int, String>> = typed?.declaredTypeSources(source);
		final byFrom: Map<Int, Candidate> = [];
		for (c in candidatesIn(tree, source, seams)) {
			final from: Null<Int> = c.field.span?.from;
			if (from != null) byFrom[from] = c;
		}
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final at: Null<Span> = v.span;
			final c: Null<Candidate> = at == null ? null : byFrom[at.from];
			if (at == null || v.declineReason != null || c == null) continue;
			final plan: Null<Plan> = c.plan;
			final typeSource: Null<String> = types == null ? null : types[at.from];
			if (plan == null) continue;
			final decline: Null<String> = typeSource == null
				? 'the field declares no type, so the local could infer a different one from its first write'
				: wholeProgramDecline(c, plan, typeSource, v.file, source, plugin, index, _oracleRelaxed);
			if (decline != null) {
				v.declineReason = decline;
				continue;
			}
			for (e in editsFor(c, plan, typeSource ?? '', source, plugin)) edits.push(e);
		}
		return edits;
	}

	/**
	 * Why the program outside the method keeps the field — a build macro reaching the type, a value
	 * whose lifetime the field carried, an initializer that may do something, a method that may recurse
	 * between a write and a read — or null when it does not.
	 */
	private static function wholeProgramDecline(
		c: Candidate, plan: Plan, typeSource: String, file: String, source: String, plugin: GrammarPlugin, index: Null<SymbolIndex>,
		oracleRelaxed: Bool
	): Null<String> {
		final shape: RefShape = plugin.refShape();
		// a fix asked without an index (a direct caller) reads the types of its own file
		final traits: SymbolIndex = RefactorSupport.resolutionIndexOf(plugin) ?? index ?? SymbolIndex.build(
			[{ file: file, source: source }], plugin
		);
		if (!oracleRelaxed && traits.traits.transitivelyCarriesBuildMacro(c.owner, file))
			return 'a build macro may reach the type and read the field list this deletes; with a compiler oracle the edit is '
				+ 'typechecked instead';
		final outer: Null<String> = NominalTypes.outerNominalOf(typeSource, plugin.typeSyntax);
		if (c.retained && (outer == null || !c.seams.valueTypes.contains(outer)))
			return 'a method is called on the value, which may start work that outlives the call — the field kept the object alive, a '
				+ 'local does not';
		final init: Null<QueryNode> = c.field.children.length == 1 ? c.field.children[0] : null;
		if (init != null && !MemberKinds.isSideEffectFree(init, shape) && !trivialConstruction(init, file, plugin, traits))
			return 'dropping the initializer may be observable: it is neither side-effect-free nor a construction whose constructor '
				+ 'only assigns the fields of the object it builds';
		// a constructor that names itself builds ANOTHER object, whose field is not this one's
		if (c.methodName == shape.constructorName) return null;
		final bodySpan: Null<Span> = c.method.children[c.method.children.length - 1].span;
		final mask: Array<Span> = OccurrenceScan.inertMask(source, plugin);
		return bodySpan == null || OccurrenceScan.referencedInRange(source, c.methodName, bodySpan.from, bodySpan.to, [], mask)
			? 'the method names itself, so a recursive call may run between a write and a read — a field shares its value with the '
				+ 'inner call, a local does not'
			: null;
	}

	/**
	 * The edits of one plan: the field deleted with its modifiers and line, the first write's statement
	 * replaced by the declaration, every other occurrence renamed to the local's name.
	 */
	private static function editsFor(
		c: Candidate, plan: Plan, typeSource: String, source: String, plugin: GrammarPlugin
	): Array<{ span: Span, text: String }> {
		final out: Array<{ span: Span, text: String }> = [];
		final fieldSpan: Null<Span> = c.field.span;
		final stmtSpan: Null<Span> = plan.declStmt.span;
		final valueSpan: Null<Span> = plan.declValue.span;
		if (fieldSpan == null || stmtSpan == null || valueSpan == null) return [];
		out.push(CheckScan.deletionEdit(source, c.field, c.container, fieldSpan, plugin.lexicalRegions(source)));
		final keyword: String = plan.writes == 1 ? c.seams.finalKeyword : c.seams.varKeyword;
		final value: String = source.substring(valueSpan.from, valueSpan.to);
		out.push({ span: stmtSpan, text: '$keyword ${plan.localName}:$typeSource = $value;' });
		for (ref in c.refs) {
			final span: Null<Span> = ref.span;
			if (span == null || ref == plan.declTarget) continue;
			if (ref.kind == c.seams.interpIdentKind || ref.kind == c.seams.identKind && ref.name == plan.localName) continue;
			out.push({ span: span, text: plan.localName });
		}
		return out;
	}

	/**
	 * Every field of every class-like type in `tree` that passes the in-file gates, with its plan when
	 * the method's own walk proves the fix (dominance, a declaration slot) and the reason when it does not.
	 */
	private static function candidatesIn(tree: QueryNode, source: String, s: Seams): Array<Candidate> {
		final out: Array<Candidate> = [];
		function visit(node: QueryNode): Void {
			if (s.opaqueKinds.contains(node.kind)) return;
			final owner: Null<String> = node.name;
			if (s.containers.contains(node.kind) && owner != null) for (field in node.children) {
				final c: Null<Candidate> = candidateOf(field, node, owner, source, s);
				if (c != null) out.push(c);
			}
			for (child in node.children) visit(child);
		}
		visit(tree);
		return out;
	}

	/**
	 * `field` as a candidate when it is a plain private `var` of `container` whose every occurrence lies
	 * in the body of one method, outside any closure, reification or conditional region, with no binder
	 * of its name and no other receiver's member spelled with it anywhere in the type, and that method
	 * reads it — else null. The candidate carries its plan when the method's own walk proves the fix.
	 */
	private static function candidateOf(field: QueryNode, container: QueryNode, owner: String, source: String, s: Seams): Null<Candidate> {
		final named: Null<String> = field.name;
		if (named == null || !isPlainPrivateVar(field, container, source, s)) return null;
		final name: String = named;
		final found: Null<Occurrences> = occurrencesOf(name, field, container, s);
		if (found == null) return null;
		final walk: DominanceWalk = new DominanceWalk(found.refs, s);
		walk.statement(found.body, false); // noqa: unused-return-value
		// a field the method never reads is a dead store, `unused-private`'s and `dead-store`'s ground
		if (walk.reads == 0) return null;
		final candidate: Candidate = {
			owner: owner,
			name: name,
			field: field,
			container: container,
			method: found.method,
			methodName: found.methodName,
			refs: found.refs,
			seams: s,
			plan: null,
			decline: DECLINE_NOT_DOMINATED,
			retained: found.retained
		};
		if (!walk.dominated) return candidate;
		candidate.plan = planOf(candidate, found.body, source, walk.writes);
		if (candidate.plan == null) candidate.decline = DECLINE_NO_SLOT;
		return candidate;
	}

	/** Whether `field` is a mutable field with no modifier but the default visibility, no metadata, and no accessor clause. */
	private static function isPlainPrivateVar(field: QueryNode, container: QueryNode, source: String, s: Seams): Bool {
		final span: Null<Span> = field.span;
		if (!s.mutableFieldKinds.contains(field.kind) || span == null || field.children.length > 1) return false;
		final mods: Array<QueryNode> = MemberKinds.precedingModifiers(field, container, s.modifierRunKinds);
		return !mods.exists(m -> !s.visibility.contains(m.kind) || textOf(m, source) != s.defaultVis)
			&& AccessorClauseText.accessorClause(source, span) == null;
	}

	/**
	 * Every occurrence of the field `name` in `container` (outside its own declaration `field`), when
	 * all of them lie in the body of one method and none is sheltered by a closure, a reification or a
	 * conditional region, no binder takes the name and no other receiver's member is spelled with it —
	 * else null.
	 */
	private static function occurrencesOf(name: String, field: QueryNode, container: QueryNode, s: Seams): Null<Occurrences> {
		var method: Null<QueryNode> = null;
		final refs: Array<QueryNode> = [];
		var ok: Bool = true;
		var retained: Bool = false;
		function visit(node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>, member: QueryNode, sheltered: Bool): Void {
			final hidden: Bool = sheltered || s.shelterKinds.contains(node.kind);
			switch useOf(node, name, s) {
				case Foreign:
					ok = false;
				case Unrelated:
					for (c in node.children) if (ok)
						visit(c, node, parent, member, hidden);
				case Occurrence:
					// a second method's occurrence lies outside the body `occurrencesIn` holds them all to
					if (hidden || !s.functionKinds.contains(member.kind)) ok = false;
					method = member;
					refs.push(node);
					if (!lifetimeInert(node, parent, grand, s)) retained = true;
			}
		}
		for (member in container.children) if (ok && member != field) visit(member, null, null, member, false);
		final fn: Null<QueryNode> = method;
		return ok && fn != null ? occurrencesIn(fn, refs, retained) : null;
	}

	/** `refs` as the occurrences of `fn`, when every one lies in its body: a parameter's default runs on entry, before any write. */
	private static function occurrencesIn(fn: QueryNode, refs: Array<QueryNode>, retained: Bool): Null<Occurrences> {
		final fnName: Null<String> = fn.name;
		if (fnName == null || fn.children.length == 0) return null;
		final body: QueryNode = fn.children[fn.children.length - 1];
		final bodySpan: Null<Span> = body.span;
		if (bodySpan == null) return null;
		final inside: Span = bodySpan;
		return refs.exists(r -> r.span == null || r.span.from < inside.from || r.span.to > inside.to) ? null : {
			method: fn,
			methodName: fnName,
			body: body,
			refs: refs,
			retained: retained
		};
	}

	/**
	 * What `node` is to the field `name`: an occurrence (the bare name, `$name`, `this.name`), a FOREIGN
	 * use that refuses the field (a binder taking the name, another receiver's member spelled with it),
	 * or unrelated.
	 */
	private static function useOf(node: QueryNode, name: String, s: Seams): NameUse {
		return if (node.name != name)
			Unrelated;
		else if (node.kind == s.identKind || node.kind == s.interpIdentKind || isSelfAccess(node, name, s))
			Occurrence;
		else if (s.binderKinds.contains(node.kind) || node.kind == s.fieldAccessKind)
			Foreign;
		else
			Unrelated;
	}

	/**
	 * The fix's plan: the first write's statement as the declaration slot, when it is a `name = value;`
	 * statement of a block that holds every occurrence after it; the local's name; the span from that
	 * write to the last occurrence. Null when there is no such slot.
	 */
	private static function planOf(c: Candidate, body: QueryNode, source: String, writes: Int): Null<Plan> {
		final s: Seams = c.seams;
		final first: QueryNode = c.refs[0];
		final firstSpan: Null<Span> = first.span;
		final last: Null<Span> = c.refs[c.refs.length - 1].span;
		if (firstSpan == null || last == null) return null;
		final lastTo: Int = last.to;
		var slot: Null<{ stmt: QueryNode, assign: QueryNode, block: QueryNode }> = null;
		function find(node: QueryNode): Void {
			if (slot != null) return;
			if (s.statementListKinds.contains(node.kind)) for (stmt in node.children) {
				final assign: Null<QueryNode> = stmt.kind == s.exprStmtKind && stmt.children.length == 1 ? stmt.children[0] : null;
				if (
					assign == null || assign.kind != s.assignKind || assign.children.length != BINARY_CHILD_COUNT
					|| assign.children[0] != first
				)
					continue;
				slot = { stmt: stmt, assign: assign, block: node };
				return;
			}
			for (child in node.children) find(child);
		}
		find(body);
		final found: Null<{ stmt: QueryNode, assign: QueryNode, block: QueryNode }> = slot;
		if (found == null) return null;
		final blockSpan: Null<Span> = found.block.span;
		final stmtSpan: Null<Span> = found.stmt.span;
		final assignSpan: Null<Span> = found.assign.span;
		if (blockSpan == null || stmtSpan == null || assignSpan == null) return null;
		// the local is in scope only to the end of its block, so every use must sit inside it
		if (lastTo > blockSpan.to) return null;
		final methodSpan: Null<Span> = c.method.span;
		return methodSpan == null ? null : {
			declStmt: found.stmt,
			declTarget: first,
			declValue: found.assign.children[1],
			localName: localNameOf(c.name, c.refs, source, methodSpan, s),
			writes: writes
		};
	}

	/**
	 * The local's name: the field's without its leading underscores, when that is an identifier the
	 * method's text does not mention, no `$name` interpolation would need re-spelling, and it is no
	 * reserved word — else the field's own name.
	 */
	private static function localNameOf(name: String, refs: Array<QueryNode>, source: String, method: Span, s: Seams): String {
		var bare: String = name;
		while (bare.length > 1 && bare.charAt(0) == '_') bare = bare.substr(1);
		final usable: Bool = bare != name && ~/^[a-z][A-Za-z0-9_]*$/.match(bare) && !s.reservedWords.contains(bare)
			&& !refs.exists(r -> r.kind == s.interpIdentKind)
			&& !OccurrenceScan.referencedInRange(source, bare, method.from, method.to, []);
		return usable ? bare : name;
	}

	/** Whether `node` is `this.name`. */
	private static function isSelfAccess(node: QueryNode, name: String, s: Seams): Bool {
		return node.kind == s.fieldAccessKind && node.name == name && node.children.length == 1 && node.children[0].kind == s.identKind
			&& s.selfText != null && node.children[0].name == s.selfText;
	}

	/** The trimmed source text of `node`. */
	private static function textOf(node: QueryNode, source: String): String {
		final span: Null<Span> = node.span;
		return span == null ? '' : source.substring(span.from, span.to).trim();
	}

	/** Bundle the kinds this check reads, or null when one it cannot work without is unset (the check is then a no-op). */
	private static function seamsOf(shape: RefShape): Null<Seams> {
		final assignKind: Null<String> = shape.assignKind;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		final defaultVis: Null<String> = shape.defaultVisibilityModifierText;
		if (assignKind == null || exprStmtKind == null || fieldAccessKind == null || blockStmtKind == null || defaultVis == null)
			return null;
		final closureKinds: Array<String> = present(shape.lambdaKinds).concat(present(shape.localFunctionKinds));
		return {
			identKind: shape.identKind,
			interpIdentKind: shape.stringInterpIdentKind,
			fieldAccessKind: fieldAccessKind,
			accessKinds: MemberKinds.withSetKinds([fieldAccessKind], [shape.nullSafeAccessKind, shape.forceFieldAccessKind]),
			invocationKinds: MemberKinds.invocationKinds(shape),
			valueTypes: valueTypesOf(shape),
			assignKind: assignKind,
			exprStmtKind: exprStmtKind,
			writeParentKinds: shape.writeParentKinds,
			containers: MemberKinds.classLikeContainerKinds(shape),
			mutableFieldKinds: present(shape.mutableFieldDeclKinds),
			functionKinds: present(shape.functionKinds),
			modifierRunKinds: present(shape.modifierKinds).concat(MemberKinds.META_KINDS),
			visibility: present(shape.visibilityModifierKinds),
			defaultVis: defaultVis,
			binderKinds: binderKindsOf(shape),
			shelterKinds: closureKinds.concat(present(shape.opaqueKinds)).concat(present(shape.conditionalRegionKinds)),
			opaqueKinds: present(shape.opaqueKinds),
			statementListKinds: MemberKinds.withSetKinds([blockStmtKind], [shape.blockBodyKind]),
			branchKinds: MemberKinds.withSetKinds(
				present(shape.ifStatementKinds).concat(present(shape.ifExpressionKinds)), [shape.ternaryKind]
			),
			shortCircuitKinds: MemberKinds.withSetKinds([], [shape.logicalAndKind, shape.logicalOrKind, shape.nullCoalesceKind]),
			loopKinds: MemberKinds.withSetKinds(
				present(shape.loopStatementKinds).concat(present(shape.iterationBindingKinds)), [shape.whileExprKind]
			),
			doWhileKinds: present(shape.doWhileLoopKinds),
			switchKinds: present(shape.switchKinds),
			tryKinds: present(shape.tryStatementKinds).concat(present(shape.tryExpressionKinds)),
			closureKinds: closureKinds,
			selfText: shape.selfReferenceText,
			reservedWords: present(shape.reservedWords),
			finalKeyword: 'final',
			varKeyword: 'var'
		};
	}

	/** Every kind that binds a name: a local, a parameter, a loop binder, a case capture, a local function, a `catch` variable. */
	private static function binderKindsOf(shape: RefShape): Array<String> {
		return MemberKinds.withSetKinds(
			present(shape.localDeclKinds)
				.concat(present(shape.paramKinds))
				.concat(present(shape.iterationBindingKinds))
				.concat(present(shape.iterationValueBinderKinds))
				.concat(present(shape.casePatternBinderKinds))
				.concat(present(shape.localFunctionKinds)),
			[shape.catchClauseKind]
		);
	}

	/** The simple names of the types whose values are no objects — a value type the language never nulls, a literal's type. */
	private static function valueTypesOf(shape: RefShape): Array<String> {
		final out: Array<String> = present(shape.nonNullableTypeNames).copy();
		final literals: Map<String, String> = shape.literalTypeNames ?? [];
		for (t in literals) if (!out.contains(t)) out.push(t);
		return out;
	}

	/** `kinds`, or none when unset. */
	private static function present(kinds: Null<Array<String>>): Array<String> {
		return kinds ?? [];
	}

	/**
	 * Whether the occurrence `ref` (under `parent` and `grand`) uses the field's value in a way that
	 * cannot depend on the field keeping it alive after the call: the field written, a member of the
	 * value read or written (not called), or the value handed over as an argument — whatever it is
	 * handed to holds it from then on. A method CALLED on it is the one shape left out: a loader's
	 * `load()` or a timer's `start()` runs on after the call, and only the field was holding the object.
	 */
	private static function lifetimeInert(ref: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>, s: Seams): Bool {
		if (parent == null) return false;
		final member: Bool = s.accessKinds.contains(parent.kind) && parent.children.length == 1;
		return s.writeParentKinds.contains(parent.kind) || member
			&& (grand == null || !s.invocationKinds.contains(grand.kind) || grand.children[0] != parent) || !member
			&& s.invocationKinds.contains(parent.kind) && parent.children.indexOf(ref) > 0;
	}

	/**
	 * Whether `init` is a construction `new T(args)` nothing can observe being dropped: every argument
	 * side-effect-free, and `T` — resolved from `file` to exactly one declaration — a non-extern class
	 * with no supertype and no build macro reaching it, every instance field initializer (in every branch
	 * of a member-position `#if`) side-effect-free, and a sole constructor whose parameter defaults are
	 * side-effect-free and whose body only assigns side-effect-free values to the class's own non-property
	 * fields or to its parameters. Such a constructor changes nothing but the object it builds.
	 */
	private static function trivialConstruction(init: QueryNode, file: String, plugin: GrammarPlugin, index: SymbolIndex): Bool {
		final shape: RefShape = plugin.refShape();
		final typeArgKinds: Array<String> = present(shape.typeAnnotationKinds);
		final typeName: Null<String> = init.name;
		if (init.kind != shape.newExprKind || typeName == null) return false;
		if (init.children.exists(c -> !typeArgKinds.contains(c.kind) && !MemberKinds.isSideEffectFree(c, shape))) return false;
		final found: Null<{ cls: QueryNode, source: String }> = soleClass(typeName, file, plugin, index);
		if (found == null || CtorFieldWrite.hasSupertypeClause(found.cls, shape)) return false;
		final fields: Null<Array<String>> = plainInstanceFields(found.cls, found.source, shape);
		final ctor: Null<QueryNode> = CtorFieldWrite.soleConstructor(found.cls, shape);
		final params: Null<Array<String>> = ctor == null ? null : inertParams(ctor, shape);
		return fields != null && ctor != null && params != null && ctorOnlyAssigns(ctor, fields, params, shape);
	}

	/**
	 * The class `typeName` resolves to from `file` — exactly one non-extern class declaration no build
	 * macro reaches — with the source it is declared in, or null.
	 */
	private static function soleClass(
		typeName: String, file: String, plugin: GrammarPlugin, index: SymbolIndex
	): Null<{ cls: QueryNode, source: String }> {
		final shape: RefShape = plugin.refShape();
		final classKinds: Array<String> = present(shape.classDeclKinds);
		final found: Array<{ file: FileInfo, type: TypeDeclInfo }> = index.resolveTypeRefsFrom(typeName, file);
		final decl: Null<{ file: FileInfo, type: TypeDeclInfo }> = found.length == 1 ? found[0] : null;
		if (decl == null || decl.type.isExtern || !classKinds.contains(decl.type.kind)) return null;
		if (index.traits.transitivelyCarriesBuildMacro(decl.type.name, decl.file.file)) return null;
		final source: Null<String> = index.sourceOf(decl.file.file);
		final tree: Null<QueryNode> = source == null ? null : CheckScan.parseOrNull(plugin, source);
		if (source == null || tree == null) return null;
		final at: Span = decl.type.span;
		final className: String = decl.type.name;
		var cls: Null<QueryNode> = null;
		function find(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (cls != null) return;
			// a node the declaration does not meet holds none of it (the module root has no span and holds every one); the
			// index's span and the node's need not agree on the trivia around it
			if (span != null && (span.to <= at.from || span.from >= at.to)) return;
			if (span != null && classKinds.contains(node.kind) && node.name == className) cls = node;
			for (c in node.children) find(c);
		}
		find(tree);
		final hit: Null<QueryNode> = cls;
		return hit == null ? null : { cls: hit, source: source };
	}

	/**
	 * The names of `cls`'s instance fields that are no properties, or null when an instance field
	 * initializer is not side-effect-free. Every branch of a member-position `#if` counts: each declares
	 * members of the class in some build.
	 */
	private static function plainInstanceFields(cls: QueryNode, source: String, shape: RefShape): Null<Array<String>> {
		final fieldKinds: Array<String> = present(shape.fieldDeclKinds);
		final statics: Array<Int> = MemberKinds.staticMemberFroms(cls, shape);
		final fields: Array<String> = [];
		var inert: Bool = true;
		MemberKinds.eachMemberHost(
			cls, host -> for (member in host.children) {
				final span: Null<Span> = member.span;
				final name: Null<String> = member.name;
				if (!fieldKinds.contains(member.kind) || span == null || name == null) continue;
				final at: Span = span;
				if (statics.contains(at.from)) continue;
				if (member.children.exists(c -> !MemberKinds.isSideEffectFree(c, shape))) inert = false;
				if (AccessorClauseText.accessorClause(source, at) == null) fields.push(name);
			}
		);
		return inert ? fields : null;
	}

	/** The parameter names of `ctor`, or null when a default value is not side-effect-free. */
	private static function inertParams(ctor: QueryNode, shape: RefShape): Null<Array<String>> {
		final paramKinds: Array<String> = present(shape.paramKinds);
		final params: Array<String> = [];
		for (p in ctor.children) if (paramKinds.contains(p.kind)) {
			final pname: Null<String> = p.name;
			if (pname == null || p.children.exists(c -> !MemberKinds.isSideEffectFree(c, shape))) return null;
			params.push(pname);
		}
		return params;
	}

	/**
	 * Whether every statement of `ctor`'s block body assigns a side-effect-free value to one of
	 * `fields` (bare or through the self reference) or to one of `params` (bare).
	 */
	private static function ctorOnlyAssigns(ctor: QueryNode, fields: Array<String>, params: Array<String>, shape: RefShape): Bool {
		final body: QueryNode = ctor.children[ctor.children.length - 1];
		final self: Null<String> = shape.selfReferenceText;
		return body.kind == shape.blockBodyKind && body.children.foreach(stmt -> {
			final assign: Null<QueryNode> = stmt.kind == shape.exprStatementKind && stmt.children.length == 1 ? stmt.children[0] : null;
			if (assign == null || assign.kind != shape.assignKind || assign.children.length != BINARY_CHILD_COUNT) return false;
			final target: QueryNode = assign.children[0];
			final bare: Bool = target.kind == shape.identKind;
			final throughSelf: Bool = target.kind == shape.fieldAccessKind && target.children.length == 1
			&& target.children[0].kind == shape.identKind && self != null && target.children[0].name == self;
			final name: String = target.name ?? '';
			return (throughSelf && fields.contains(name) || bare && (fields.contains(name) || params.contains(name)))
			&& MemberKinds.isSideEffectFree(assign.children[1], shape);
		});
	}

}

/**
 * The forward must-assign walk behind `scratch-field`'s dominance proof: `dominated` stays true while
 * every read of the field (an occurrence in `refs` that is not the target of a plain assignment) is
 * reached in a state where every path assigned it. Pessimistic by construction — see `ScratchField`.
 */
@:nullSafety(Strict)
private class DominanceWalk {

	/** Whether every read seen so far was dominated by a write. */
	public var dominated(default, null): Bool = true;


	/** How many reads the walk met. */
	public var reads(default, null): Int = 0;

	/** How many writes the method holds — plain assignments, compound ones and increments alike. */
	public var writes(default, null): Int = 0;

	private final _refs: Array<QueryNode>;
	private final _s: Seams;

	public function new(refs: Array<QueryNode>, s: Seams) {
		_refs = refs;
		_s = s;
	}

	/**
	 * Walk `node` entered with the field assigned (`assigned`) and return whether it is assigned when
	 * `node` completes normally.
	 */
	public function statement(node: QueryNode, assigned: Bool): Bool {
		final s: Seams = _s;
		final kids: Array<QueryNode> = node.children;
		return if (_refs.contains(node))
			read(assigned);
		else if (s.closureKinds.contains(node.kind))
			assigned;
		else if (s.writeParentKinds.contains(node.kind) && kids.length >= 1 && _refs.contains(kids[0]))
			write(node, assigned);
		else if (s.branchKinds.contains(node.kind) && kids.length >= 2)
			branch(kids, assigned);
		else if (s.shortCircuitKinds.contains(node.kind) || s.switchKinds.contains(node.kind))
			conditional(kids, 1, assigned);
		else if (s.loopKinds.contains(node.kind))
			conditional(kids, kids.length - 1, assigned);
		else if (s.doWhileKinds.contains(node.kind) || s.tryKinds.contains(node.kind))
			conditional(kids, 0, assigned);
		else
			sequence(kids, 0, assigned);
	}

	/** Count a read, which is dominated only when `assigned`. */
	private function read(assigned: Bool): Bool {
		reads++;
		if (!assigned) dominated = false;
		return assigned;
	}

	/**
	 * A write to the field: its value is evaluated first, in the state before the write; a compound
	 * write (`+=`, `++`) reads the field too, and a plain one assigns it.
	 */
	private function write(node: QueryNode, assigned: Bool): Bool {
		writes++;
		final plain: Bool = node.kind == _s.assignKind;
		if (!plain) read(assigned); // noqa: unused-return-value
		final after: Bool = sequence(node.children, 1, assigned);
		return plain || after;
	}

	/** An `if` / ternary: the condition first, then each arm from its state; assigned only when both arms assign. */
	private function branch(kids: Array<QueryNode>, assigned: Bool): Bool {
		final afterCond: Bool = statement(kids[0], assigned);
		final thenState: Bool = statement(kids[1], afterCond);
		final elseState: Bool = kids.length > 2 ? statement(kids[2], afterCond) : afterCond;
		return thenState && elseState;
	}

	/**
	 * A construct whose first `always` children run unconditionally in order, while the rest may run
	 * or not: a short-circuit's right operand, a `switch`'s arms, a loop's body after its header. Each of
	 * the rest is walked from the state after the first part, and none of what it assigns survives. A
	 * `try` and a `do … while` take `always` 0: an exception or a `break` / `continue` may leave either
	 * before any write of its body, so even the body that runs first assigns nothing that survives.
	 */
	private function conditional(kids: Array<QueryNode>, always: Int, assigned: Bool): Bool {
		final head: Bool = sequence(kids.slice(0, always), 0, assigned);
		for (i in always ... kids.length) statement(kids[i], head); // noqa: unused-return-value
		return head;
	}

	/** Walk `kids` from index `from` in order, threading the state. */
	private function sequence(kids: Array<QueryNode>, from: Int, assigned: Bool): Bool {
		var state: Bool = assigned;
		for (i in from ... kids.length) state = statement(kids[i], state);
		return state;
	}

}

/** The `RefShape` kinds and names `ScratchField` reads, bundled once by `seamsOf`. */
private typedef Seams = {
	var identKind: String;
	var interpIdentKind: Null<String>;
	var fieldAccessKind: String;
	var accessKinds: Array<String>;
	var invocationKinds: Array<String>;
	var valueTypes: Array<String>;
	var assignKind: String;
	var exprStmtKind: String;
	var writeParentKinds: Array<String>;
	var containers: Array<String>;
	var mutableFieldKinds: Array<String>;
	var functionKinds: Array<String>;
	var modifierRunKinds: Array<String>;
	var visibility: Array<String>;
	var defaultVis: String;
	var binderKinds: Array<String>;
	var shelterKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var statementListKinds: Array<String>;
	var branchKinds: Array<String>;
	var shortCircuitKinds: Array<String>;
	var loopKinds: Array<String>;
	var doWhileKinds: Array<String>;
	var switchKinds: Array<String>;
	var tryKinds: Array<String>;
	var closureKinds: Array<String>;
	var selfText: Null<String>;
	var reservedWords: Array<String>;
	var finalKeyword: String;
	var varKeyword: String;
}

/** A field that passed the in-file gates: where it lives, its occurrences in document order, and the fix's plan or why there is none. */
private typedef Candidate = {
	var owner: String;
	var name: String;
	var field: QueryNode;
	var container: QueryNode;
	var method: QueryNode;
	var methodName: String;
	var refs: Array<QueryNode>;
	var seams: Seams;
	var plan: Null<Plan>;
	var decline: String;

	/**
	 * Whether an occurrence uses the value other than as a plain read or write of one of its members or
	 * an argument — a method called on it above all, which may start work that outlives the call.
	 */
	var retained: Bool;
}

/** The fix of one candidate: the statement the declaration replaces, the local's name, how many writes, and the re-entry window. */
private typedef Plan = {
	var declStmt: QueryNode;
	var declTarget: QueryNode;
	var declValue: QueryNode;
	var localName: String;
	var writes: Int;
}

/** Where a field's occurrences live: the one method, its body, the occurrences in document order, and whether one keeps a lifetime. */
private typedef Occurrences = {
	var method: QueryNode;
	var methodName: String;
	var body: QueryNode;
	var refs: Array<QueryNode>;
	var retained: Bool;
}

/** What a node is to the field a scan follows (`ScratchField.useOf`). */
private enum NameUse {

	Occurrence;
	Foreign;
	Unrelated;

}
