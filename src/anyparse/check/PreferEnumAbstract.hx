package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;

/**
 * Suggests grouping a set of related `static final` integer constants into an
 * `enum abstract` — the constants read as a closed enumeration but carry no
 * distinct type, so any `Int` flows where one is expected and the set is not
 * visible as one concept. An advisory that proposes a STRUCTURAL refactor rather
 * than flagging a defect; `Info`, report-only (the conversion picks an operator
 * flavour a mechanical edit cannot choose — see below).
 *
 * ## What is flagged — two arms
 *
 * **Whole-type arm.** A type in `RefShape.visibilityContainerKinds` whose ENTIRE body
 * is THREE OR MORE `static inline final` members of ONE primitive type, every value a
 * distinct literal, and nothing else — no method, no constructor, no supertype clause,
 * no mutable or instance field. Such a type IS the enumeration already; it has no
 * behaviour an `enum abstract` could not carry, and its members are read from other
 * files, so no in-file use is required as evidence.
 *
 * **Prefix arm.** A type declaring THREE OR MORE `static [inline] final <NAME> =
 * <numericLiteral>` members that share a common name prefix (the segment before the
 * first `_`: `RANK_ACCESSOR` / `RANK_CONSTRUCTOR` → `RANK`) AND are USED
 * INTERCHANGEABLY. Used for constants that live INSIDE a type with other members,
 * where the type itself carries no signal.
 *
 * A container flagged by the whole-type arm is not re-examined by the prefix arm — the
 * whole-type finding already names every constant the type declares.
 *
 * ## Why the interchangeability gate
 *
 * A shared prefix alone is not an enumeration. A domain namespace of independent
 * tuning knobs (`FUZZY_MAX_DIST`, `FUZZY_TOP_K`, `FUZZY_SUBSTRING_MIN_QUERY`)
 * shares a prefix, yet each knob is its own magnitude, used once in its own
 * expression and never as an alternative to a sibling; advising an enum there
 * would be wrong. An enumeration's members are MUTUALLY-EXCLUSIVE ALTERNATIVES
 * that flow into ONE slot. So a group is flagged only when TWO OR MORE of its
 * members appear as a RESULT VALUE feeding the same sink — a `return` of one
 * function, or an assignment to one lvalue — reached through result-preserving
 * containers (parentheses, ternary branches, switch / case values) but NOT as an
 * operand of a comparison / arithmetic / call. A namespace of thresholds, only
 * ever compared against other quantities, shares no sink and is left alone.
 *
 * ## Not flagged
 *
 * An existing `enum abstract` (its values are not `fieldDeclKinds`, its decl kind
 * not a container kind); a mutable `static var` (`mutableFieldDeclKinds`); an
 * instance (non-`static`) `final` field; fewer than three members.
 *
 * Prefix arm only: a non-numeric constant; a prefix-less name; a prefix group whose
 * members are never used interchangeably (a knob namespace).
 *
 * Whole-type arm only: a member without `inline` (storage, not a compile-time
 * substituted value — and a non-`inline` constant bag is far more often a namespace of
 * unrelated knobs than an enumeration); a value that is not a literal; two primitive
 * types in one body; two members on the SAME value (aliases, not distinct members); any
 * child node that is neither a modifier, a metadata annotation nor a qualifying
 * constant — which is what refuses a method, a constructor, an `extends` / `implements`
 * clause and an `abstract`'s underlying-type node, without a per-shape exclusion list.
 *
 * ## Why report-only
 *
 * The right enum-abstract FLAVOUR depends on how the values are used, which the
 * check does not decide: ordinal comparison (`<`) needs `@:op(A < B)`, bitwise
 * combination (bit-flags) needs `from Int to Int`, pure `==` / `switch` needs
 * neither. A blind rewrite would pick the wrong one, so the fix is the author's;
 * `fix` yields no edits.
 *
 * ## Grammar-agnostic
 *
 * Container / field / modifier / literal / return / assignment / result-container
 * kinds all come from the plugin; a grammar declaring none makes the check a no-op.
 */
@:nullSafety(Strict)
final class PreferEnumAbstract implements Check {

	/** The minimum same-prefix constant group worth an enum-abstract suggestion — a pair is not yet a set. */
	private static inline final MIN_GROUP: Int = 3;

	public function new() {}

	public function id(): String {
		return 'prefer-enum-abstract';
	}

	public function description(): String {
		return 'a constant-only type, or related static-final int constants, reading as a closed enumeration';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final containerKinds: Array<String> = shape.visibilityContainerKinds ?? [];
		final mutableKinds: Array<String> = shape.mutableFieldDeclKinds ?? [];
		final fieldKinds: Array<String> = shape.fieldDeclKinds ?? [];
		final constKinds: Array<String> = [for (k in fieldKinds) if (!mutableKinds.contains(k)) k];
		final staticKind: Null<String> = shape.staticModifierKind;
		final numericKinds: Array<String> = shape.numericLiteralKinds ?? [];
		if (staticKind == null || containerKinds.length == 0 || constKinds.length == 0 || numericKinds.length == 0) return [];
		final staticKindValue: String = staticKind;
		final cfg: EnumAbstractCfg = {
			constKinds: constKinds,
			staticKind: staticKindValue,
			inlineKind: shape.inlineModifierKind ?? '',
			metaKinds: plugin.metaShape().metaKinds,
			literalTypeNames: shape.literalTypeNames ?? [],
			modifierKinds: shape.modifierOrderKinds ?? [],
			numericKinds: numericKinds,
			negationKind: shape.negationKind ?? '',
			identKind: shape.identKind,
			functionKinds: shape.functionKinds ?? [],
			returnKind: shape.returnStatementKind ?? '',
			assignKinds: shape.writeParentKinds,
			ternaryKind: shape.ternaryKind ?? '',
			resultContainerKinds: resultContainers(shape)
		};
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) flagFile(violations, entry.file, entry.source, tree, containerKinds, cfg);
		}
		return violations;
	}

	/** No mechanical autofix — the enum-abstract flavour depends on usage the check does not analyse. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * The prefixed static-final numeric constants declared directly by `container`.
	 * A constant is a `constKinds` (final) member preceded by a `Static` modifier,
	 * whose value is a numeric literal and whose name carries a `_`-delimited prefix.
	 */
	private static function collectConsts(container: QueryNode, cfg: EnumAbstractCfg): Array<ConstDecl> {
		final out: Array<ConstDecl> = [];
		final kids: Array<QueryNode> = container.children;
		for (i in 0...kids.length) {
			final node: QueryNode = kids[i];
			if (!cfg.constKinds.contains(node.kind) || !precededByStatic(kids, i, cfg) || !hasNumericValue(node, cfg)) continue;
			final name: Null<String> = node.name;
			final span: Null<Span> = node.span;
			final prefix: Null<String> = name != null ? prefixOf(name) : null;
			if (prefix == null || span == null || name == null) continue;
			final prefixValue: String = prefix;
			final spanValue: Span = span;
			final nameValue: String = name;
			out.push({ prefix: prefixValue, span: spanValue, name: nameValue });
		}
		return out;
	}

	/** Whether the member at `kids[i]` carries a `Static` modifier — scanning back over its preceding modifier siblings. */
	private static function precededByStatic(kids: Array<QueryNode>, i: Int, cfg: EnumAbstractCfg): Bool {
		var j: Int = i - 1;
		while (j >= 0) {
			final kind: String = kids[j].kind;
			if (kind == cfg.staticKind) return true;
			if (!cfg.modifierKinds.contains(kind)) break;
			j--;
		}
		return false;
	}

	/** Whether `node`'s value — its first child — is a numeric literal. */
	private static function hasNumericValue(node: QueryNode, cfg: EnumAbstractCfg): Bool {
		if (node.children.length == 0) return false;
		final value: QueryNode = node.children[0];
		final literal: QueryNode = cfg.negationKind != '' && value.kind == cfg.negationKind && value.children.length > 0
			? value.children[0]
			: value;
		return cfg.numericKinds.contains(literal.kind);
	}

	/** The `_`-delimited prefix of `name` (`RANK_ACCESSOR` → `RANK`), or null when the name has no prefix. */
	private static function prefixOf(name: String): Null<String> {
		final idx: Int = name.indexOf('_');
		return idx > 0 ? name.substring(0, idx) : null;
	}

	/** The result-preserving container kinds a value flows through unchanged (parentheses, switch, case branch). */
	private static function resultContainers(shape: RefShape): Array<String> {
		final out: Array<String> = [];
		final paren: Null<String> = shape.parenKind;
		if (paren != null) out.push(paren);
		for (k in shape.switchKinds ?? []) out.push(k);
		final caseBranch: Null<String> = shape.caseBranchKind;
		if (caseBranch != null) out.push(caseBranch);
		return out;
	}

	/**
	 * Flag every container in `tree` whose static-final numeric constants form a
	 * same-prefix group of `MIN_GROUP`+ used interchangeably (see the class doc).
	 * Member usage is scanned once over the whole file — a group's members are read
	 * throughout the file, not only near their declaration.
	 */
	private static function flagFile(
		out: Array<Violation>, file: String, source: String, tree: QueryNode, containerKinds: Array<String>, cfg: EnumAbstractCfg
	): Void {
		final groups: Array<Group> = [];
		final whole: Array<WholeType> = [];
		collectGroups(groups, whole, tree, source, containerKinds, cfg);
		for (w in whole) out.push({
			file: file,
			span: w.span,
			rule: 'prefer-enum-abstract',
			severity: Severity.Info,
			message: '\'${w.name}\' declares nothing but ${w.count} distinct static-inline-final ${w.typeName} '
			+ 'constants — the type already IS a closed enumeration; consider enum abstract ${w.name}(${w.typeName})'
		});
		if (groups.length == 0) return;
		final names: Array<String> = [];
		for (g in groups) for (n in g.members) if (!names.contains(n)) names.push(n);
		final sinks: Map<String, Array<String>> = [];
		computeSinks(tree, source, names, cfg, sinks, -1);
		for (g in groups) if (interchangeable(g.members, sinks)) out.push({
			file: file,
			span: g.span,
			rule: 'prefer-enum-abstract',
			severity: Severity.Info,
			message: '${g.members.length} \'${g.prefix}'
			+ '_*\' static-final constants read as a closed enumeration — consider an enum abstract for a distinct type'
		});
	}

	/**
	 * Walk `node`; for every container either record a whole-type finding (its body is
	 * nothing but a same-typed constant set) or, failing that, append a `Group` for each
	 * of its `MIN_GROUP`+ same-prefix constant groups. A whole-type finding already names
	 * every constant the type declares, so the prefix arm is not run on that container.
	 */
	private static function collectGroups(
		out: Array<Group>, whole: Array<WholeType>, node: QueryNode, source: String, containerKinds: Array<String>, cfg: EnumAbstractCfg
	): Void {
		if (containerKinds.contains(node.kind)) {
			final wt: Null<WholeType> = wholeType(node, source, cfg);
			if (wt != null)
				whole.push(wt);
			else {
				final byPrefix: Map<String, Array<ConstDecl>> = [];
				for (decl in collectConsts(node, cfg)) {
					final existing: Null<Array<ConstDecl>> = byPrefix[decl.prefix];
					if (existing == null)
						byPrefix[decl.prefix] = [decl];
					else
						existing.push(decl);
				}
				for (prefix => group in byPrefix) if (group.length >= MIN_GROUP) out.push({
					prefix: prefix,
					span: group[0].span,
					members: [for (d in group) d.name]
				});
			}
		}
		for (child in node.children) collectGroups(out, whole, child, source, containerKinds, cfg);
	}

	/**
	 * The whole-type finding for `container`, or null when its body is anything other than
	 * `MIN_GROUP`+ `static inline final` members of ONE primitive type carrying DISTINCT
	 * literal values. Every child must be a modifier, a metadata annotation or a qualifying
	 * constant — a positive whitelist, so a method, a constructor, a supertype clause, an
	 * `abstract`'s underlying-type node and any member shape not thought of here all refuse
	 * the container rather than leaking through a list of exclusions.
	 */
	private static function wholeType(container: QueryNode, source: String, cfg: EnumAbstractCfg): Null<WholeType> {
		final name: Null<String> = container.name;
		final span: Null<Span> = container.span;
		if (cfg.inlineKind == '' || name == null || span == null) return null;
		final kids: Array<QueryNode> = container.children;
		final values: Array<String> = [];
		var typeName: String = '';
		for (i in 0...kids.length) {
			final node: QueryNode = kids[i];
			final kind: String = node.kind;
			if (cfg.modifierKinds.contains(kind) || cfg.metaKinds.contains(kind)) continue;
			if (!cfg.constKinds.contains(kind) || !staticInline(kids, i, cfg)) return null;
			final literal: Null<QueryNode> = valueLiteral(node, cfg);
			if (literal == null) return null;
			final t: Null<String> = cfg.literalTypeNames[literal.kind];
			if (t == null || (typeName != '' && t != typeName)) return null;
			final text: String = spanText(node.children[0], source);
			if (values.contains(text)) return null;
			typeName = t;
			values.push(text);
		}
		if (values.length < MIN_GROUP) return null;
		final nameValue: String = name;
		final spanValue: Span = span;
		return {
			span: spanValue,
			name: nameValue,
			count: values.length,
			typeName: typeName
		};
	}

	/** Whether the member at `kids[i]` carries BOTH a `Static` and an `inline` modifier. */
	private static function staticInline(kids: Array<QueryNode>, i: Int, cfg: EnumAbstractCfg): Bool {
		var hasStatic: Bool = false;
		var hasInline: Bool = false;
		var j: Int = i - 1;
		while (j >= 0) {
			final kind: String = kids[j].kind;
			if (kind == cfg.staticKind)
				hasStatic = true;
			else if (kind == cfg.inlineKind)
				hasInline = true;
			else if (!cfg.modifierKinds.contains(kind) && !cfg.metaKinds.contains(kind))
				break;
			j--;
		}
		return hasStatic && hasInline;
	}

	/** `node`'s value — its first child, unwrapped through a negation — or null when it has none. */
	private static function valueLiteral(node: QueryNode, cfg: EnumAbstractCfg): Null<QueryNode> {
		if (node.children.length == 0) return null;
		final value: QueryNode = node.children[0];
		return cfg.negationKind != '' && value.kind == cfg.negationKind && value.children.length > 0 ? value.children[0] : value;
	}

	/**
	 * Walk `node`, dispatching each `return` value / assignment RHS to `collectResults`
	 * under the sink it feeds: `ret@<fn>` for a return (keyed by the enclosing function's
	 * offset), `asg@<lvalue>` for an assignment. `fnId` is the nearest enclosing
	 * function's offset (`-1` at top level). The whole tree is walked so nested functions
	 * and every result position are reached.
	 */
	private static function computeSinks(
		node: QueryNode, source: String, names: Array<String>, cfg: EnumAbstractCfg, out: Map<String, Array<String>>, fnId: Int
	): Void {
		final kind: String = node.kind;
		final span: Null<Span> = node.span;
		final childFnId: Int = cfg.functionKinds.contains(kind) && span != null ? span.from : fnId;
		if (kind == cfg.returnKind && node.children.length > 0)
			collectResults(node.children[0], 'ret@$fnId', source, names, cfg, out);
		else if (cfg.assignKinds.contains(kind) && node.children.length >= 2)
			collectResults(node.children[1], 'asg@${spanText(node.children[0], source)}', source, names, cfg, out);
		for (child in node.children) computeSinks(child, source, names, cfg, out, childFnId);
	}

	/**
	 * Descend from a sink's value root through result-preserving containers
	 * (parentheses, ternary BRANCHES, switch / case values), recording every group
	 * member (`names`) reached as a leaf value under `sink`. Stops at any other node (an
	 * operator / comparison / call / arithmetic operand): a constant used only as an
	 * operand is not a result value and does not signal an enumeration.
	 */
	private static function collectResults(
		node: QueryNode, sink: String, source: String, names: Array<String>, cfg: EnumAbstractCfg, out: Map<String, Array<String>>
	): Void {
		final kind: String = node.kind;
		if (kind == cfg.identKind) {
			final nm: Null<String> = node.name;
			if (nm != null && names.contains(nm)) record(out, sink, nm);
		} else if (cfg.ternaryKind != '' && kind == cfg.ternaryKind) {
			for (i in 1...node.children.length) collectResults(node.children[i], sink, source, names, cfg, out);
		} else if (cfg.resultContainerKinds.contains(kind)) {
			for (child in node.children) collectResults(child, sink, source, names, cfg, out);
		}
	}

	/** Record that member `name` feeds `sink` (deduped). */
	private static function record(out: Map<String, Array<String>>, sink: String, name: String): Void {
		final cur: Null<Array<String>> = out[sink];
		if (cur == null)
			out[sink] = [name];
		else if (!cur.contains(name))
			cur.push(name);
	}

	/** Verbatim source of `node`, or empty when unspanned. */
	private static function spanText(node: QueryNode, source: String): String {
		final s: Null<Span> = node.span;
		return s == null ? '' : source.substring(s.from, s.to).trim();
	}

	/** Whether two or more of `members` feed a single sink — the interchangeable-use signal. */
	private static function interchangeable(members: Array<String>, sinks: Map<String, Array<String>>): Bool {
		for (ms in sinks) {
			var count: Int = 0;
			for (m in members) if (ms.contains(m)) count++;
			if (count >= 2) return true;
		}
		return false;
	}

}

private typedef ConstDecl = {
	final prefix: String;
	final span: Span;
	final name: String;
};

private typedef EnumAbstractCfg = {
	final constKinds: Array<String>;
	final staticKind: String;
	final inlineKind: String;
	final metaKinds: Array<String>;
	final literalTypeNames: Map<String, String>;
	final modifierKinds: Array<String>;
	final numericKinds: Array<String>;
	final negationKind: String;
	final identKind: String;
	final functionKinds: Array<String>;
	final returnKind: String;
	final assignKinds: Array<String>;
	final ternaryKind: String;
	final resultContainerKinds: Array<String>;
};

private typedef WholeType = {
	final span: Span;
	final name: String;
	final count: Int;
	final typeName: String;
};

private typedef Group = {
	final prefix: String;
	final span: Span;
	final members: Array<String>;
};
