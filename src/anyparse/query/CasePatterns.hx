package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;

using Lambda;

/**
 * The ONE definition of which names a `case` pattern BINDS. The scope resolver (`Refs`), the
 * case-arm lint rules (`CasePatternScan`) and every consumer that has to tell a capture from a
 * reference ask this class, so no two of them can disagree about the same pattern.
 *
 * A pattern position is read as a WHITELIST: an identifier, a `var x` capture, an `=`-capture's
 * left slot, a constructor call's ARGUMENTS (never its callee), an array element, a structure
 * field's value, a parenthesised sub-pattern, an extractor's RIGHT side (its left side is an
 * expression evaluated on the subject, so identifiers there are reads) and the constant leaves — a
 * dotted path and the literals. Any other shape makes the scan UNMODELLED, and every bare name
 * inside it is `Undecided`: an unmodelled shape may bind a name this scan would otherwise report
 * as a reference.
 *
 * A bare identifier CAPTURES unless its spelling rules that out (`isCaptureSpelling`) or a
 * declaration the caller knows of may make it a pattern CONSTANT (`constantNames`): Haxe matches a
 * lowercase `enum abstract` value, a lowercase enum constructor and a `static inline` field as a
 * value, and an ordinary local, parameter or field never — `case closeAction:` over a field of that
 * name matches every subject.
 */
@:nullSafety(Strict)
final class CasePatterns {

	/** An `=`-capture and an extractor both have exactly two children. */
	private static inline final PAIR_CHILD_COUNT: Int = 2;

	/**
	 * The LEADING run of `branch`'s pattern children — the `case A, B:` alternatives. A top-level
	 * `var x` capture projects as its own kind rather than through the plain wrapper, so both count.
	 */
	public static function patternRun(branch: QueryNode, shape: RefShape): Array<QueryNode> {
		final plainKind: Null<String> = shape.plainCasePatternKind;
		final binderKinds: Array<String> = shape.casePatternBinderKinds ?? [];
		final out: Array<QueryNode> = [];
		for (child in branch.children) {
			if (child.kind != plainKind && !binderKinds.contains(child.kind)) break;
			out.push(child);
		}
		return out;
	}

	/**
	 * Whether a bare pattern identifier spelled `name` may bind at all: not the wildcard, and not a
	 * name the grammar's spelling reserves for a constructor or a constant
	 * (`RefShape.upperInitialNeverCaptures`).
	 */
	public static function isCaptureSpelling(name: String, shape: RefShape): Bool {
		return name.length > 0 && name != shape.wildcardPatternName
			&& !(shape.upperInitialNeverCaptures == true && SourceText.isUpperInitial(name));
	}

	/**
	 * Every name in `branch`'s pattern run a capture may introduce, in document order, and whether
	 * every pattern stayed inside the whitelist. A bare identifier named in `constants` is
	 * `Undecided` rather than a `Capture`; so is every bare name inside an unmodelled shape.
	 */
	public static function scan(branch: QueryNode, shape: RefShape, constants: Array<String>): PatternScan {
		final state: ScanState = new ScanState(shape, constants);
		final binderKinds: Array<String> = shape.casePatternBinderKinds ?? [];
		for (pattern in patternRun(branch, shape)) {
			if (binderKinds.contains(pattern.kind))
				scanNode(state, pattern, true)
			else if (pattern.children.length == 1)
				scanNode(state, pattern.children[0], true)
			else
				state.unmodelled(pattern);
		}
		return { idents: state.idents, modelled: state.modelled };
	}

	/**
	 * Every name declared across `trees` that the language may resolve UNQUALIFIED in a pattern position as a
	 * constant - the names of `constantDeclarations`, each once.
	 */
	public static function constantNames(trees: Array<QueryNode>, shape: RefShape): Array<String> {
		final out: Array<String> = [];
		for (decl in constantDeclarations(trees, shape)) {
			final name: Null<String> = decl.name;
			if (name != null && !out.contains(name)) out.push(name);
		}
		return out;
	}

	/**
	 * Every declaration across `trees` that the language may resolve UNQUALIFIED in a pattern position
	 * as a constant: a member of a closed constructor type (`bareConstructorTypeKinds`), a member of any
	 * abstract or alias (`aliasingDeclKinds` - which reaches a legacy `@:enum abstract`, projected as a
	 * plain abstract), and any `static` member. Over-inclusive on purpose - a `static var` captures in
	 * Haxe, only a `static inline` one compares - because a declaration here is only ever read as "may
	 * be a constant". Names spelled so that they never capture are left out: the spelling rule decides
	 * them first.
	 *
	 * Modifiers project as SIBLING nodes preceding their member, so a pending `static` run is carried
	 * across the nameless modifier nodes and consumed by the next named child.
	 */
	public static function constantDeclarations(trees: Array<QueryNode>, shape: RefShape): Array<QueryNode> {
		final hostKinds: Array<String> = (shape.bareConstructorTypeKinds ?? []).concat(shape.aliasingDeclKinds ?? []);
		final staticKind: Null<String> = shape.staticModifierKind;
		final out: Array<QueryNode> = [];
		function walk(node: QueryNode): Void {
			final allMembers: Bool = hostKinds.contains(node.kind);
			var pendingStatic: Bool = false;
			for (member in node.children) {
				if (member.kind == staticKind) {
					pendingStatic = true;
					continue;
				}
				final name: Null<String> = member.name;
				if (name == null) continue;
				if ((allMembers || pendingStatic) && isCaptureSpelling(name, shape)) out.push(member);
				pendingStatic = false;
			}
			for (child in node.children) walk(child);
		}
		for (tree in trees) walk(tree);
		return out;
	}

	/**
	 * Whether `node` is a constructor-extraction pattern whose callee is NAMED — a bare identifier or
	 * the dotted path of a qualified constructor, the only two callee spellings a pattern may carry.
	 */
	public static function isNamedCallee(node: QueryNode, shape: RefShape): Bool {
		if (node.children.length == 0) return false;
		final callee: QueryNode = node.children[0];
		return callee.kind == shape.identKind || callee.kind == shape.fieldAccessKind;
	}

	/** Walk one pattern node; `whole` marks the node that IS the entire pattern. */
	private static function scanNode(state: ScanState, node: QueryNode, whole: Bool): Void {
		final shape: RefShape = state.shape;
		final kind: String = node.kind;
		if (node.span == null)
			state.unmodelled(node)
		else if (kind == shape.identKind)
			scanIdent(state, node, whole)
		else if ((shape.casePatternBinderKinds ?? []).contains(kind))
			scanBinder(state, node, whole)
		else if (kind == shape.assignKind)
			scanAssign(state, node)
		else if (kind == shape.callKind)
			scanCall(state, node)
		else if (!scanComposite(state, node, whole) && !constantLeafKinds(shape).contains(kind))
			state.unmodelled(node);
	}

	/** A constructor-extraction pattern: a NAMED callee (a read) over scanned arguments. */
	private static function scanCall(state: ScanState, node: QueryNode): Void {
		if (isNamedCallee(node, state.shape))
			for (i in 1...node.children.length) scanNode(state, node.children[i], false)
		else
			state.unmodelled(node);
	}

	/**
	 * Scan `node` when it is a pattern that only WRAPS sub-patterns — an array, a structure, a
	 * parenthesised or negated pattern, an extractor's right side — and answer whether it was one.
	 */
	private static function scanComposite(state: ScanState, node: QueryNode, whole: Bool): Bool {
		final shape: RefShape = state.shape;
		final kind: String = node.kind;
		if (kind == shape.arrayLiteralKind)
			for (child in node.children) scanNode(state, child, false)
		else if (kind == shape.objectLiteralKind)
			for (field in node.children) {
				if (field.kind == shape.objectFieldKind && field.children.length == 1)
					scanNode(state, field.children[0], false)
				else
					state.unmodelled(field);
			}
		else if (kind == shape.parenKind || kind == shape.negationKind) {
			if (node.children.length == 1)
				scanNode(state, node.children[0], whole && kind == shape.parenKind)
			else
				state.unmodelled(node);
		} else if ((shape.casePatternExtractorKinds ?? []).contains(kind)) {
			if (node.children.length == PAIR_CHILD_COUNT)
				scanNode(state, node.children[1], false)
			else
				state.unmodelled(node);
		} else
			return false;
		return true;
	}

	/** A bare identifier: the wildcard and a reserved spelling bind nothing, a known constant name is undecided. */
	private static function scanIdent(state: ScanState, node: QueryNode, whole: Bool): Void {
		final name: Null<String> = node.name;
		if (name == null || name.length == 0) {
			state.unmodelled(node);
			return;
		}
		if (isCaptureSpelling(name, state.shape))
			state.push(node, name, state.constants.contains(name) ? Undecided : Capture, false, whole, null);
	}

	/** A grammar-declared binder node (`case var x:`) — a leaf carrying the bound name. */
	private static function scanBinder(state: ScanState, node: QueryNode, whole: Bool): Void {
		final name: Null<String> = node.name;
		if (name == null || node.children.length != 0)
			state.unmodelled(node)
		else
			state.push(node, name, Capture, true, whole, null);
	}

	/** A `name = subpattern` capture: the name binds by syntax, the subpattern is scanned on its own. */
	private static function scanAssign(state: ScanState, node: QueryNode): Void {
		if (node.children.length != PAIR_CHILD_COUNT) {
			state.unmodelled(node);
			return;
		}
		final lhs: QueryNode = node.children[0];
		final rhs: QueryNode = node.children[1];
		final name: Null<String> = lhs.name;
		if (lhs.kind != state.shape.identKind || name == null || lhs.span == null || rhs.span == null) {
			state.unmodelled(node);
			return;
		}
		if (name != state.shape.wildcardPatternName) state.push(lhs, name, Capture, true, false, rhs);
		scanNode(state, rhs, false);
	}

	/** The pattern leaves that bind nothing and hold no sub-pattern: a dotted path and the literals. */
	public static function constantLeafKinds(shape: RefShape): Array<String> {
		final leaves: Array<String> = [];
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind != null) leaves.push(fieldAccessKind);
		for (kind in shape.stringLiteralKinds ?? []) leaves.push(kind);
		for (kind in shape.numericLiteralKinds ?? []) leaves.push(kind);
		final boolKind: Null<String> = shape.boolLitKind;
		if (boolKind != null) leaves.push(boolKind);
		final nullKind: Null<String> = shape.nullLiteralKind;
		if (nullKind != null) leaves.push(nullKind);
		return leaves;
	}

}

/** What a name in a pattern IS, as far as the caller's knowledge of declarations reaches. */
enum abstract PatternRole(Int) {

	/** Binds a new name for the arm — by syntax (`var x`, `x = p`) or by the bare-name rule. */
	final Capture = 0;

	/** A bare name a constant declaration may claim, or one inside an unmodelled shape. */
	final Undecided = 1;

}

/** One name a pattern may bind. */
typedef PatternIdent = {

	/** The node that carries the name — a bare identifier, a binder node or an `=`-capture's left slot. */
	final node: QueryNode;
	final name: String;
	final role: PatternRole;

	/** Whether the name binds by SYNTAX (`var x`, `x = p`) rather than by the bare-name rule. */
	final explicit: Bool;

	/** Whether the binder IS the whole pattern — a catch-all. */
	final whole: Bool;

	/** The sub-pattern of an `x = p` capture, whose start ends the text that unbinds `x`; null otherwise. */
	final assigned: Null<QueryNode>;
};

/** The result of `CasePatterns.scan`. */
typedef PatternScan = {
	final idents: Array<PatternIdent>;

	/** Whether every pattern stayed inside the whitelist; when false, a name the scan missed may still bind. */
	final modelled: Bool;
};

/** The mutable accumulator of one `CasePatterns.scan`. */
@:nullSafety(Strict)
private final class ScanState {

	public final idents: Array<PatternIdent> = [];
	public final shape: RefShape;
	public final constants: Array<String>;
	public var modelled(default, null): Bool = true;

	public function new(shape: RefShape, constants: Array<String>) {
		this.shape = shape;
		this.constants = constants;
	}

	public function push(
		node: QueryNode, name: String, role: PatternRole, explicit: Bool, whole: Bool, assigned: Null<QueryNode>
	): Void {
		idents.push({
			node: node,
			name: name,
			role: role,
			explicit: explicit,
			whole: whole,
			assigned: assigned
		});
	}

	/**
	 * Record a shape outside the whitelist: every bare name inside it may bind, so each is `Undecided`.
	 * A declaration node the resolver already binds (a nested `var x`) carries no bare name to add.
	 */
	public function unmodelled(node: QueryNode): Void {
		modelled = false;
		final declKinds: Array<String> = shape.declHostKinds;
		function walk(n: QueryNode): Void {
			if (declKinds.contains(n.kind)) return;
			final name: Null<String> = n.name;
			if (n.kind == shape.identKind && name != null && CasePatterns.isCaptureSpelling(name, shape))
				push(n, name, Undecided, false, false, null);
			for (child in n.children) walk(child);
		}
		walk(node);
	}

}
