package anyparse.check;

import anyparse.query.CasePatterns;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TreePath;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * The case-PATTERN scan the two case-arm rules share — `unused-case-binder` (a
 * pattern binder no guard or body reads) and `redundant-case-body` (an arm whose
 * body a neighbour already carries). Both have to answer the same question about a
 * `case` label: WHICH NAMES DOES IT BIND, and can that be decided at all?
 *
 * `binders` answers it from `CasePatterns.scan` — the ONE definition of a capture, shared
 * with the scope resolver — which reads pattern positions as a WHITELIST, never as a list
 * of banned ones: an identifier, a `var x` capture, an `=`-capture's left slot, a
 * constructor call's ARGUMENTS (never its callee), an array element, a structure
 * field's value, a parenthesised sub-pattern, an extractor's RIGHT side (its left
 * side is an EXPRESSION evaluated on the subject, so identifiers there are reads),
 * and the constant leaves — a dotted path, a string / numeric / boolean / null
 * literal, a negated numeric. Anything else returns null, which every caller reads
 * as "this label may bind something I cannot see" and refuses. That is what keeps a
 * grammar shape nobody has thought of from silently reading as "binds nothing".
 *
 * ## The one family SPELLING assumption
 *
 * A BARE identifier in a pattern is treated as a capture binder unless it opens
 * with an uppercase ASCII letter, in which case it is a constructor or constant
 * reference. This is the assumption `prefer-case-guard`, `collapse-nested-switch` and the scope resolver
 * (`CasePatterns.isCaptureSpelling`) make, and it is not universally true in Haxe: a LOWERCASE `enum` /
 * `enum abstract` value resolves unqualified in a pattern too, so `case one:` may
 * denote a constant rather than a binder. `declaredConstantNames` closes the
 * realistic half of that — every constructor / value name declared by an
 * exhaustiveness-checked type ANYWHERE in the lint scope is collected once per run,
 * and a binder whose name is in that set is refused. A type declared OUTSIDE the
 * scope stays on the spelling assumption alone, which is why the top-level arm of
 * `unused-case-binder` carries its own position gate on top.
 *
 * Grammar-agnostic: every kind arrives through `CaseSeams`, resolved once per run by
 * `seamsOf`, and a grammar leaving a required kind unset makes both rules a no-op.
 */
@:nullSafety(Strict)
final class CasePatternScan {

	/**
	 * Whether `name` opens with an uppercase ASCII letter — the family spelling of a constructor reference. Public
	 * because `collapse-nested-switch` makes the same assumption and reads it from here rather than keeping its own copy.
	 */
	public static inline function startsUpper(name: String): Bool {
		final code: Int = name.fastCodeAt(0);
		return code >= 'A'.code && code <= 'Z'.code;
	}

	/** The seam kinds both case-arm rules read, or null when the grammar leaves a required one unset. */
	public static function seamsOf(plugin: GrammarPlugin): Null<CaseSeams> {
		final shape: RefShape = plugin.refShape();
		final switchKinds: Array<String> = shape.switchKinds ?? [];
		final caseBranchKind: Null<String> = shape.caseBranchKind;
		final plainKind: Null<String> = shape.plainCasePatternKind;
		final wildcard: Null<String> = shape.wildcardPatternName;
		final parenKind: Null<String> = shape.parenKind;
		final assignKind: Null<String> = shape.assignKind;
		final callKind: Null<String> = shape.callKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (
			switchKinds.length == 0 || caseBranchKind == null || plainKind == null || wildcard == null || parenKind == null
			|| assignKind == null || callKind == null || fieldAccessKind == null
		)
			return null;
		final leaves: Array<String> = CasePatterns.constantLeafKinds(shape);
		return {
			shape: shape,
			switchKinds: switchKinds,
			caseBranchKind: caseBranchKind,
			defaultBranchKind: shape.defaultBranchKind,
			plainCasePatternKind: plainKind,
			wildcardPatternName: wildcard,
			identKind: shape.identKind,
			parenKind: parenKind,
			assignKind: assignKind,
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			arrayLiteralKind: shape.arrayLiteralKind,
			objectLiteralKind: shape.objectLiteralKind,
			objectFieldKind: shape.objectFieldKind,
			negationKind: shape.negationKind,
			nullLiteralKind: shape.nullLiteralKind,
			stringInterpIdentKind: shape.stringInterpIdentKind,
			binderKinds: shape.casePatternBinderKinds ?? [],
			extractorKinds: shape.casePatternExtractorKinds ?? [],
			constantHostKinds: shape.bareConstructorTypeKinds ?? [],
			constantMemberHostKinds: (shape.bareConstructorTypeKinds ?? []).concat(shape.aliasingDeclKinds ?? []),
			staticModifierKind: shape.staticModifierKind,
			conditionalKind: shape.conditionalMemberKind,
			opaqueKinds: shape.opaqueKinds ?? [],
			constantLeafKinds: leaves,
			scope: scopeSeamsOf(shape)
		};
	}

	/**
	 * The LEADING run of `branch`'s pattern children — the `case A, B:` alternatives.
	 * A `var x` capture projects as its own kind rather than through the plain wrapper,
	 * so both count.
	 */
	public static inline function patternRun(seams: CaseSeams, branch: QueryNode): Array<QueryNode> {
		return CasePatterns.patternRun(branch, seams.shape);
	}

	/** The guard node of `branch` (the parenthesised condition after its pattern run), or null when it has none. */
	public static function guardOf(seams: CaseSeams, branch: QueryNode, run: Int): Null<QueryNode> {
		final kids: Array<QueryNode> = branch.children;
		return run < kids.length && kids[run].kind == seams.parenKind ? kids[run] : null;
	}

	/**
	 * Every name `branch`'s pattern run BINDS, or null when any pattern holds a shape the
	 * whitelist does not model — the refusal every caller must honour, since an unmodelled
	 * shape may bind a name this scan would otherwise report as absent.
	 */
	public static function binders(seams: CaseSeams, branch: QueryNode): Null<Array<PatternBinder>> {
		final found: PatternScan = CasePatterns.scan(branch, seams.shape, []);
		if (!found.modelled) return null;
		final out: Array<PatternBinder> = [];
		for (ident in found.idents) {
			final span: Null<Span> = ident.node.span;
			final assigned: Null<QueryNode> = ident.assigned;
			final assignedSpan: Null<Span> = assigned?.span;
			if (span == null || (assigned != null && assignedSpan == null)) return null;
			out.push({
				node: ident.node,
				name: ident.name,
				bare: !ident.explicit,
				whole: ident.whole,
				editSpan: assignedSpan == null ? span : new Span(span.from, assignedSpan.from),
				editText: assignedSpan == null ? seams.wildcardPatternName : ''
			});
		}
		return out;
	}

	/**
	 * Whether `binder` of `arm` is a PROVEN capture (`CasePatterns.isDecidedCapture`) — the gate every
	 * rule that ACTS on a binder being a capture (spelling it `_`, reporting it as a catch-all, splicing
	 * a nested switch over it) must pass. A bare name that may compare against a constant of the
	 * subject's type or of an import is not one, and such a rule declines.
	 */
	public static function provesCapture(
		seams: CaseSeams, root: QueryNode, switchNode: QueryNode, arm: QueryNode, binder: PatternBinder
	): Bool {
		return CasePatterns.provesCaptureAt(arm, switchNode, root, seams.shape, binder.node, subjectResolver(root, seams.shape));
	}

	/** How a lint rule resolves a switch subject identifier to its declaration: through the reference walk. */
	public static function subjectResolver(root: QueryNode, shape: RefShape): QueryNode -> Null<QueryNode> {
		return subject -> {
			final name: Null<String> = subject.name;
			final span: Null<Span> = subject.span;
			return name == null || span == null ? null : TypeResolver.resolveBindingHit(name, span, root, shape)?.bindingNode;
		};
	}

	/** How many nodes in `node`'s subtree MENTION `name` — an identifier, a `'$name'` interpolation, or a pattern binder. */
	public static function mentionCount(seams: CaseSeams, node: QueryNode, name: String): Int {
		var count: Int = node.name == name
			&& (node.kind == seams.identKind || node.kind == seams.stringInterpIdentKind || seams.binderKinds.contains(node.kind))
			? 1
			: 0;
		for (child in node.children) count += mentionCount(seams, child, name);
		return count;
	}

	/** Whether `node`'s subtree holds a node of any kind in `kinds`. */
	public static function containsAnyKind(node: QueryNode, kinds: Array<String>): Bool {
		return kinds.length != 0 && (kinds.contains(node.kind) || node.children.exists(child -> containsAnyKind(child, kinds)));
	}

	/**
	 * Whether every pattern of `arm`'s run is one a REWRITE may reason about: no EXTRACTOR (which
	 * RUNS code while matching, so deleting the arm — or moving when its label is evaluated — is
	 * observable) and no `null` LITERAL (whether a wildcard reaches `null` is the target-dependent
	 * question `nullable-switch-missing-null` exists for, and refusing the literal keeps a caller out
	 * of that argument entirely).
	 *
	 * The shared half of `redundant-case-body`'s and `empty-case-arm`'s arm gates, which differ only
	 * in what each adds around this loop. A grammar leaving both kinds unset makes it vacuously true —
	 * the callers' other gates still decide.
	 */
	public static function patternsModellable(seams: CaseSeams, arm: QueryNode): Bool {
		final nullKind: Null<String> = seams.nullLiteralKind;
		for (pattern in patternRun(seams, arm)) {
			if (containsAnyKind(pattern, seams.extractorKinds)) return false;
			if (nullKind != null && containsAnyKind(pattern, [nullKind])) return false;
		}
		return true;
	}

	/**
	 * Whether `branch` matches EVERY subject its position still reaches — a `default:` arm,
	 * or one unguarded `_` pattern. A guarded arm never qualifies: its guard may reject.
	 */
	public static function isCatchAll(seams: CaseSeams, branch: QueryNode): Bool {
		if (branch.kind == seams.defaultBranchKind) return true;
		if (branch.kind != seams.caseBranchKind) return false;
		final run: Array<QueryNode> = patternRun(seams, branch);
		if (run.length != 1 || guardOf(seams, branch, run.length) != null) return false;
		final node: Null<QueryNode> = sole(run[0]);
		return node != null && node.kind == seams.identKind && node.name == seams.wildcardPatternName;
	}

	/**
	 * Every name declared across `trees` that Haxe can resolve UNQUALIFIED in a pattern
	 * position — the set a bare pattern identifier must NOT be in before it may be read as
	 * a binder (see the type doc's spelling assumption). Three declaration classes qualify:
	 * a member of an exhaustiveness-checked type (`constantHostKinds`), a member of any
	 * abstract or alias declaration (`constantMemberHostKinds` — which is what reaches a
	 * legacy `@:enum abstract`, projected as a plain abstract with no marker this scan can
	 * read), and any STATIC member of any type, since a `static inline` field resolves as a
	 * pattern constant both inside its own type and through a static import.
	 *
	 * Only names that do NOT open uppercase are collected: an uppercase name is refused by
	 * the spelling assumption before this set is ever consulted, so admitting one would
	 * grow the set without changing a single verdict.
	 */
	public static inline function declaredConstantNames(seams: CaseSeams, trees: Array<QueryNode>): Array<String> {
		return CasePatterns.constantNames(trees, seams.shape);
	}

	/**
	 * `node`'s name when it carries a NON-EMPTY one, else null — the guard every reader of a bare
	 * identifier pattern opens with, here rather than once per reader. Public for the same reason
	 * `startsUpper` is: `case-pattern-separator` asks it of the same nodes.
	 */
	public static function patternName(node: QueryNode): Null<String> {
		final name: Null<String> = node.name;
		return name == null || name.length == 0 ? null : name;
	}

	/**
	 * Whether `node` is a constructor-EXTRACTION pattern whose callee is NAMED — a bare identifier
	 * or the dotted path of a qualified constructor, the only two callee spellings a pattern may
	 * carry. Public for the same reason `startsUpper` is: `case-pattern-separator`'s pattern
	 * whitelist asks this exact question of the same node, and a second copy would drift.
	 */
	public static inline function isNamedCallee(seams: CaseSeams, node: QueryNode): Bool {
		return CasePatterns.isNamedCallee(node, seams.shape);
	}

	/**
	 * The kind of VISIBLE DECLARATION a bare pattern binder named `name`, written in `arm`, shadows
	 * — `'field'`, `'inherited field'`, `'parameter'` or `'local'` — or null when it shadows nothing
	 * this scan can see.
	 *
	 * Haxe resolves a bare lowercase identifier in a pattern as a CAPTURE, never as a comparison
	 * against a same-named binding in scope: `case closeAction:` over a field of that name matches
	 * EVERY value and compiles without a warning (verified on `--interp`). So a binder whose name is
	 * already taken is almost always an intended comparison, and the shadowed declaration is the
	 * evidence for it. `shadowing-case-binder` reports that; `unused-case-binder` uses the same
	 * answer to REFUSE spelling such a binder `_`, a rewrite that preserves behaviour while erasing
	 * the only trace of the mistake.
	 *
	 * The scan walks the ancestor chain OUTWARD from `arm`: a function-like ancestor is asked for a
	 * parameter of that name and then for a binding declared before the arm (`bindingDeclKinds` —
	 * locals, loop and catch binders, local functions); a type ancestor is asked for a member, and —
	 * when an `index` is supplied — for an inherited one. A local declared AFTER the arm is not in
	 * scope there, so it is not shadowed; a binding written INSIDE the arm is the binder's own and is
	 * skipped.
	 *
	 * A grammar leaving the relevant kinds unset answers null throughout, which leaves both callers
	 * exactly as they were before this scan existed.
	 */
	public static function shadowedDeclaration(
		seams: CaseSeams, root: QueryNode, arm: QueryNode, name: String, ?index: SymbolIndex
	): Null<String> {
		final armSpan: Null<Span> = arm.span;
		if (armSpan == null) return null;
		final path: Null<Array<QueryNode>> = TreePath.pathTo(root, arm);
		if (path == null) return null;
		for (step in 0...path.length) {
			final node: QueryNode = path[path.length - 1 - step];
			if (seams.scope.functionKinds.contains(node.kind)) {
				if (declaresNamed(seams.scope.paramKinds, node.children, name)) return 'parameter';
				if (declaresBefore(seams, node, arm, armSpan, name)) return 'local';
			}
			if (!seams.scope.classLikeKinds.contains(node.kind)) continue;
			if (declaresNamed(seams.scope.memberDeclKinds, node.children, name)) return 'field';
			final owner: Null<String> = node.name;
			if (index != null && owner != null && index.members.supertypeDeclaresMember(owner, name)) return 'inherited field';
		}
		return null;
	}

	/**
	 * Visit every arm of every switch in `node`'s subtree, in document order, never descending into a
	 * reification subtree — a splice inside one may carry code no source scan resolves. `visit`
	 * receives the switch node and the arm's child index, so a caller that cares about an arm's
	 * POSITION (the last-arm gate `unused-case-binder` carries) still has it.
	 */
	public static function eachCaseArm(seams: CaseSeams, node: QueryNode, visit: (QueryNode, Int) -> Void): Void {
		if (seams.opaqueKinds.contains(node.kind)) return;
		if (seams.switchKinds.contains(node.kind)) for (at in 1...node.children.length) visit(node, at);
		for (child in node.children) eachCaseArm(seams, child, visit);
	}

	/**
	 * `arm`'s binders grouped by NAME, in first-occurrence order — Haxe requires every alternative of
	 * `case A(x), B(x):` to bind the same names, so a name must be decided as a whole and never one
	 * occurrence at a time.
	 *
	 * Null when the arm is not one to reason about at all: not a `case` (a `default:` binds nothing),
	 * one holding a conditional-compilation region (its arm run cannot be enumerated) or a macro
	 * reification (a splice may carry a read no source scan resolves), or one whose patterns
	 * `binders` refuses. This is the shared HEAD of `unused-case-binder` and
	 * `shadowing-case-binder` — both ask exactly these questions before their own gates begin.
	 */
	public static function binderGroups(seams: CaseSeams, arm: QueryNode): Null<Array<Array<PatternBinder>>> {
		if (arm.kind != seams.caseBranchKind) return null;
		final conditional: Null<String> = seams.conditionalKind;
		if (conditional != null && containsAnyKind(arm, [conditional])) return null;
		if (containsAnyKind(arm, seams.opaqueKinds)) return null;
		final found: Null<Array<PatternBinder>> = binders(seams, arm);
		if (found == null) return null;
		final groups: Array<Array<PatternBinder>> = [];
		final seen: Array<String> = [];
		for (binder in found) if (!seen.contains(binder.name)) {
			seen.push(binder.name);
			groups.push(found.filter(b -> b.name == binder.name));
		}
		return groups;
	}

	/**
	 * The per-run context both case-binder rules open with: every file that parses, the
	 * unqualified-resolvable CONSTANT names collected across all of them (a project-wide run
	 * therefore refuses more bare identifiers than a single-file one), and one symbol index over the
	 * same set. Built once here rather than twice, because a rule that computed the constant set from
	 * a DIFFERENT file list than its sibling would disagree with it about what a bare identifier even
	 * is.
	 */
	public static function runContextOf(
		seams: CaseSeams, files: Array<{ file: String, source: String }>, plugin: GrammarPlugin
	): CaseRunContext {
		final parsed: Array<{ file: String, source: String, tree: QueryNode }> = CheckScan.parseAll(plugin, files);
		return {
			parsed: parsed,
			constants: declaredConstantNames(seams, [for (entry in parsed) entry.tree]),
			index: SymbolIndex.build(files, plugin)
		};
	}

	/** `wrapper`'s ONE child, or null when it holds any other number. */
	private static function sole(wrapper: QueryNode): Null<QueryNode> {
		return wrapper.children.length == 1 ? wrapper.children[0] : null;
	}


	/** Whether any direct child of `nodes` whose kind is in `kinds` declares `name`. */
	private static function declaresNamed(kinds: Array<String>, nodes: Array<QueryNode>, name: String): Bool {
		return nodes.exists(node -> kinds.contains(node.kind) && node.name == name);
	}


	/**
	 * Whether `scope`'s subtree declares `name` at a position BEFORE `arm` — the bindings actually in
	 * scope where the pattern is written. The arm's own subtree is skipped: a binding inside it
	 * belongs to the binder, not to what the binder shadows.
	 */
	private static function declaresBefore(seams: CaseSeams, scope: QueryNode, arm: QueryNode, at: Span, name: String): Bool {
		if (scope == arm) return false;
		final span: Null<Span> = scope.span;
		if (seams.scope.bindingDeclKinds.contains(scope.kind) && scope.name == name && span != null && span.from < at.from) return true;
		return scope.children.exists(child -> declaresBefore(seams, child, arm, at, name));
	}


	/**
	 * The SCOPE half of the seams — every kind `shadowedDeclaration` needs to walk an ancestor chain.
	 * Split out of `seamsOf` so that function stays under the complexity budget: each `??` fallback is
	 * a branch of its own, and there are six here.
	 */
	private static function scopeSeamsOf(shape: RefShape): ScopeSeams {
		final functionKinds: Array<String> = (shape.functionKinds ?? []).concat(shape.lambdaKinds ?? []);
		final catchKind: Null<String> = shape.catchClauseKind;
		return {
			functionKinds: functionKinds,
			paramKinds: shape.paramKinds ?? [],
			bindingDeclKinds: (shape.localDeclKinds ?? []).concat(shape.iterationBindingKinds ?? [])
				.concat(shape.iterationValueBinderKinds ?? [])
				.concat(catchKind == null ? [] : [catchKind])
				.concat(functionKinds),
			classLikeKinds: MemberKinds.classLikeContainerKinds(shape),
			memberDeclKinds: shape.memberDeclKinds ?? []
		};
	}

}

/** One name a case label BINDS, with the edit that turns it into the wildcard. */
typedef PatternBinder = {

	/** The node that carries the name — its identity is what the mention count subtracts. */
	final node: QueryNode;
	final name: String;

	/** Whether the name was written as a BARE identifier (so the spelling assumption carries it) rather than a `var` / `=` capture. */
	final bare: Bool;

	/** Whether the binder IS the whole pattern — a catch-all, which the top-level position gate covers. */
	final whole: Bool;

	/** The span to replace, and what with, to unbind the name (`_`, or an empty string that drops an `x = ` capture head). */
	final editSpan: Span;
	final editText: String;
};

/** The seam kinds `CasePatternScan` resolves once per run for both case-arm rules. */
typedef CaseSeams = {

	/** The shape the seams were read from — what `CasePatterns` takes. */
	final shape: RefShape;
	final switchKinds: Array<String>;
	final caseBranchKind: String;
	final defaultBranchKind: Null<String>;
	final plainCasePatternKind: String;
	final wildcardPatternName: String;
	final identKind: String;
	final parenKind: String;

	/** Inside a pattern the assignment kind is the `=`-CAPTURE form, whose left slot holds a NAME. */
	final assignKind: String;
	final callKind: String;
	final fieldAccessKind: String;
	final arrayLiteralKind: Null<String>;
	final objectLiteralKind: Null<String>;
	final objectFieldKind: Null<String>;
	final negationKind: Null<String>;
	final nullLiteralKind: Null<String>;

	/** A `'$b'` read projects as this, never as `identKind` — the mention count reads both. */
	final stringInterpIdentKind: Null<String>;
	final binderKinds: Array<String>;

	/** Pattern kinds that RUN code while matching — an arm holding one is never deleted. */
	final extractorKinds: Array<String>;

	/** The type kinds whose values the compiler tracks as a closed constructor list. */
	final constantHostKinds: Array<String>;

	/** The type kinds ALL of whose members resolve unqualified in a pattern — the above plus abstracts and aliases. */
	final constantMemberHostKinds: Array<String>;

	/** The `static` modifier — a static member resolves unqualified in a pattern from inside its own type. */
	final staticModifierKind: Null<String>;
	final conditionalKind: Null<String>;
	final opaqueKinds: Array<String>;

	/** The pattern leaves that bind nothing and hold no sub-pattern: a dotted path and the literals. */
	final constantLeafKinds: Array<String>;

	/** The SCOPE kinds `shadowedDeclaration` walks the ancestor chain with. */
	final scope: ScopeSeams;
};

/** The scope-shaped half of `CaseSeams`, read only by `shadowedDeclaration` and its helpers. */
typedef ScopeSeams = {

	/** Function-like kinds — the ancestors that own a parameter list and a local scope. */
	final functionKinds: Array<String>;

	/** Parameter kinds — the declarations a function-like ancestor carries as direct children. */
	final paramKinds: Array<String>;

	/** Every local BINDING kind: declarations, loop and catch binders, and local functions. */
	final bindingDeclKinds: Array<String>;

	/** The type kinds that own a member list — the ancestors asked for a field. */
	final classLikeKinds: Array<String>;

	/** The member kinds a `classLikeKinds` container declares. */
	final memberDeclKinds: Array<String>;
};

/** What `runContextOf` resolves once for a whole lint run. */
typedef CaseRunContext = {

	/** Every file that parsed, with its source and tree. */
	final parsed: Array<{ file: String, source: String, tree: QueryNode }>;

	/** Names a bare pattern identifier must avoid to read as a binder at all. */
	final constants: Array<String>;

	/** The index over the same file set — the resolution half of `shadowedDeclaration`. */
	final index: SymbolIndex;
};
