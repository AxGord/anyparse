package anyparse.check;

import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.EnumAbstractSyntax;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;

/**
 * Suggests grouping a set of related `static final` integer constants into an
 * `enum abstract` — the constants read as a closed enumeration but carry no
 * distinct type, so any `Int` flows where one is expected and the set is not
 * visible as one concept. An advisory that proposes a STRUCTURAL refactor rather
 * than flagging a defect; `Info`. The WHOLE-TYPE arm carries a verified autofix
 * (`RiskyFix`, see below); the prefix arm is report-only.
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
 * ## The autofix — WHOLE-TYPE arm only, and `RiskyFix`
 *
 * The whole-type arm converts in place: the head `class Name` becomes the grammar's
 * enum-abstract spelling (`RefShape.enumAbstractSyntax`, Haxe `enum abstract Name(U) to U`)
 * and each constant sheds the modifiers and the `:U` annotation an enum-abstract value may
 * not carry (`static` makes it a private static field instead of a value; a `:U` annotation
 * types it as `U` instead of the abstract). Everything else — member order, doc comments,
 * per-member metadata, blank lines — is left untouched, because the edits are the two
 * deletions and the one head replacement and nothing more.
 *
 * The PREFIX arm has no fix and is not going to get one here: its constants live inside a
 * type with other members, so converting them means SYNTHESISING a type that does not exist
 * yet, naming it, and rewriting every reference — a different operation from rewriting a
 * declaration in place.
 *
 * **The `to <underlying>` clause is always emitted, and that is what keeps the fix
 * single-file.** An `enum abstract T(U)` does not implicitly convert to `U`, so without the
 * clause every reference that flowed into a `U`-typed slot stops compiling; with it, none
 * does. Measured on the motivating project: converting ONE five-constant type without the
 * clause produced >= 22 errors across >= 17 files, and with it the whole project typechecked
 * unchanged — nine such types converted at once, zero other files touched. `to` costs
 * nothing the conversion is for: only a `from` clause would let a bare `U` back in and
 * dissolve the distinct type, and exhaustive `switch` — the payoff — is unaffected.
 *
 * ## Why `RiskyFix`, and what the structural gates still have to catch
 *
 * `to U` is not a proof. Two residual shapes still break, and neither is decidable without
 * real type inference: a value bound to an inferred local and then used as a `U`
 * (`var a = T.CENTER; a.toUpperCase()` — `T has no field toUpperCase`), and a collection
 * whose element type is inferred from the members (`[T.A, T.B].indexOf(u)` — `U should be
 * T`). Both are COMPILE ERRORS, so the compiler oracle is the right net: the check is
 * `RiskyFix`, every conversion is typechecked project-wide and the ONE edited file reverts
 * to report-only when any call site anywhere breaks. With no `compilerOracle` configured the
 * fix never runs at all.
 *
 * What the oracle cannot catch is a change that still COMPILES, and there is exactly one
 * class of those: an `enum abstract` erases to its underlying type at runtime, so every
 * VALUE behaves identically, but the TYPE stops existing as a runtime class. So the
 * structural refusals target reflection on the type itself and nothing else:
 *
 * - the container carries ANY metadata (a preceding `metaKinds` sibling) — `@:rtti` /
 *   `@:keep` / `@:build` attach behaviour to a CLASS declaration, and whether it survives
 *   the change of declaration kind is not knowable from the annotation's name;
 * - the type's NAME occurs as a plain string literal anywhere in scope — the
 *   `Type.resolveClass('Name')` shape, which compiles before and after and returns null
 *   after (`ConstantFieldScan.reflectedNames`, the same proof `static-constant` uses);
 * - the index reports a subtype or a transitive `@:rtti` hierarchy for the name.
 *
 * Two more refusals are about what the head TEMPLATE would silently drop, since neither
 * projects as a tree child: a declaration keyword that is more than one word (`abstract
 * class`), and anything between the type name and the body opener — type parameters above
 * all, `class Generic<T>` being indistinguishable from `class Plain` in the tree.
 *
 * ## Grammar-agnostic
 *
 * Container / field / modifier / literal / return / assignment / result-container
 * kinds all come from the plugin; a grammar declaring none makes the check a no-op. The
 * fix spells no target syntax of its own either: the declaration head template and the
 * body-opening character come from `RefShape.enumAbstractSyntax`, and a grammar that leaves
 * that slot unset keeps the rule exactly as report-only as it was before the fix existed.
 */
@:nullSafety(Strict)
final class PreferEnumAbstract implements Check implements RiskyFix {

	/** This check's rule id, as it appears on every violation it reports. */
	private static inline final RULE_ID: String = 'prefer-enum-abstract';

	/** The minimum same-prefix constant group worth an enum-abstract suggestion — a pair is not yet a set. */
	private static inline final MIN_GROUP: Int = 3;

	/** The `EnumAbstractSyntax.head` placeholder for the converted type's own name. */
	private static inline final NAME_SLOT: String = '{name}';

	/** The `EnumAbstractSyntax.head` placeholder for the underlying primitive the constants share. */
	private static inline final UNDER_SLOT: String = '{under}';

	/**
	 * The character introducing a declaration's type annotation. Textual because the tree does
	 * not carry it: the `type` slot spans the TYPE (`String`), not the `:String` region the fix
	 * has to delete — the same reading `LiteralInfer.hasTypeBeforeInit` already takes.
	 */
	private static inline final ANNOTATION_SEPARATOR: String = ':';

	/**
	 * The conversion plan for every whole-type finding the LAST `run` accepted, keyed
	 * `<file>#<container span.from>` — the key a `fix` violation reconstructs from its own
	 * `file` / `span`. Instance state, run-scoped and rebuilt from scratch on every `run`
	 * (never static — see the project's zero-global-state invariant); the callers that ask
	 * for edits (`Cli.applyLintPass`, `FixVerifier.verify`) always run the check first, on
	 * this same instance.
	 *
	 * Empty is FAIL-CLOSED and deliberately so: a `fix` reached without a preceding `run`
	 * finds no plan and yields no edits, rather than converting a type whose whole-project
	 * refusals were never evaluated.
	 */
	private var plans: Map<String, ConversionPlan> = [];

	public function new() {}

	public function id(): String {
		return RULE_ID;
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
			resultContainerKinds: resultContainers(shape),
			classKinds: shape.classDeclKinds ?? [],
			syntax: shape.enumAbstractSyntax
		};
		final violations: Array<Violation> = [];
		final candidates: Array<ConversionPlan> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) flagFile(violations, candidates, entry.file, entry.source, tree, containerKinds, cfg);
		}
		plans = [];
		for (plan in acceptedPlans(files, plugin, candidates)) plans[planKey(plan.file, plan.from)] = plan;
		return violations;
	}

	/**
	 * The whole-type conversion edits for `violations` — one head replacement plus, per
	 * constant, the modifier-run and type-annotation deletions (see the class doc). A prefix-arm
	 * finding, a finding whose container the plan phase refused, and every finding at all when
	 * `run` has not been called on this instance all yield nothing.
	 *
	 * `index` adds the two whole-project refusals that need resolution rather than text: a
	 * SUBTYPE of the converted type (`class Sub extends Name`, which an abstract cannot host)
	 * and a transitive `@:rtti` hierarchy. Both are cheap and precise here, and both are
	 * belt-and-braces for the `RiskyFix` oracle, which would reject the first as a compile
	 * error anyway.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final out: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final plan: Null<ConversionPlan> = plans[planKey(v.file, span.from)];
			if (plan == null || source.substring(span.from, span.to) != plan.declSource) continue;
			if (index != null && (index.hasSubtype(plan.name) || index.transitivelyCarriesRtti(plan.name))) continue;
			for (e in plan.edits) out.push(e);
		}
		return out;
	}

	/** The `plans` key for one container: its file plus the container's own start offset. */
	private static function planKey(file: String, from: Int): String {
		return '$file#$from';
	}

	/**
	 * The subset of `candidates` no whole-scope refusal rejects. The one such refusal is the
	 * REFLECTION-NAME gate: a converted type stops existing as a runtime class, so a
	 * `Type.resolveClass('Name')` anywhere in scope keeps compiling and starts returning null.
	 * The proof is `static-constant`'s — every plain string literal in scope — narrowed to the
	 * files whose raw text even MENTIONS a candidate name, since parsing 800 files to find out
	 * that nine names appear in fifty of them is the same answer for a fraction of the walk.
	 */
	private static function acceptedPlans(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, candidates: Array<ConversionPlan>
	): Array<ConversionPlan> {
		if (candidates.length == 0) return candidates;
		final names: Array<String> = [];
		for (c in candidates) if (!names.contains(c.name)) names.push(c.name);
		final mentioning: Array<{ file: String, source: String }> = [
			for (entry in files) if (mentionsAny(entry.source, names)) entry
		];
		final literals: Array<String> = ConstantFieldScan.reflectedNames(mentioning, plugin, plugin.stringFoldSupport());
		return [for (c in candidates) if (!literals.contains(c.name)) c];
	}

	/** Whether `source` contains any of `names` as raw text — the cheap pre-filter ahead of the literal scan. */
	private static function mentionsAny(source: String, names: Array<String>): Bool {
		for (n in names) if (source.indexOf(n) >= 0) return true;
		return false;
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
		out: Array<Violation>, plans: Array<ConversionPlan>, file: String, source: String, tree: QueryNode, containerKinds: Array<String>,
		cfg: EnumAbstractCfg
	): Void {
		final groups: Array<Group> = [];
		final whole: Array<WholeType> = [];
		collectGroups(groups, whole, tree, [], -1, source, containerKinds, cfg);
		for (w in whole) {
			final plan: Null<ConversionPlan> = w.plan;
			if (plan != null) plans.push({
				file: file,
				from: plan.from,
				name: plan.name,
				declSource: plan.declSource,
				edits: plan.edits
			});
		}
		for (w in whole) out.push({
			file: file,
			span: w.span,
			rule: RULE_ID,
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
			rule: RULE_ID,
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
		out: Array<Group>, whole: Array<WholeType>, node: QueryNode, siblings: Array<QueryNode>, selfIndex: Int, source: String,
		containerKinds: Array<String>, cfg: EnumAbstractCfg
	): Void {
		if (containerKinds.contains(node.kind)) {
			final wt: Null<WholeType> = wholeType(node, siblings, selfIndex, source, cfg);
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
		for (i in 0...node.children.length) collectGroups(out, whole, node.children[i], node.children, i, source, containerKinds, cfg);
	}

	/**
	 * The whole-type finding for `container`, or null when its body is anything other than
	 * `MIN_GROUP`+ `static inline final` members of ONE primitive type carrying DISTINCT
	 * literal values. Every child must be a modifier, a metadata annotation or a qualifying
	 * constant — a positive whitelist, so a method, a constructor, a supertype clause, an
	 * `abstract`'s underlying-type node and any member shape not thought of here all refuse
	 * the container rather than leaking through a list of exclusions.
	 */
	private static function wholeType(
		container: QueryNode, siblings: Array<QueryNode>, selfIndex: Int, source: String, cfg: EnumAbstractCfg
	): Null<WholeType> {
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
			typeName: typeName,
			plan: conversionPlan(container, siblings, selfIndex, source, nameValue, spanValue, typeName, cfg)
		};
	}

	/**
	 * The in-file conversion plan for an accepted whole-type `container` — the head
	 * replacement plus every member's deletions — or null at the first refusal (see the class
	 * doc's autofix section). Null is the norm rather than an error: the finding is reported
	 * either way, and only a container this function fully accepts is ever rewritten.
	 */
	private static function conversionPlan(
		container: QueryNode, siblings: Array<QueryNode>, selfIndex: Int, source: String, name: String, span: Span, typeName: String,
		cfg: EnumAbstractCfg
	): Null<ConversionPlan> {
		final syntax: Null<EnumAbstractSyntax> = cfg.syntax;
		if (syntax == null || !cfg.classKinds.contains(container.kind)) return null;
		// Metadata / a declaration modifier projects as a PRECEDING SIBLING, not a child, so the
		// body whitelist never sees it: `@:keep class C` and `class C` have identical subtrees.
		if (selfIndex > 0) {
			final prev: String = siblings[selfIndex - 1].kind;
			if (cfg.metaKinds.contains(prev) || cfg.modifierKinds.contains(prev)) return null;
		}
		final head: Null<{ span: Span, text: String }> = headEdit(container, source, name, span, typeName, syntax);
		if (head == null) return null;
		final edits: Array<{ span: Span, text: String }> = [head];
		final kids: Array<QueryNode> = container.children;
		for (i in 0...kids.length) {
			if (!cfg.constKinds.contains(kids[i].kind)) continue;
			if (!memberEdits(kids, i, source, cfg, edits)) return null;
		}
		return {
			file: '',
			from: span.from,
			name: name,
			declSource: source.substring(span.from, span.to),
			edits: edits
		};
	}

	/**
	 * The edit that replaces the container's own `<keyword> <Name>` with the grammar's
	 * enum-abstract head, or null when the head carries anything the template would silently
	 * drop. Both refusals are textual because neither shape projects into the tree: a
	 * multi-word declaration keyword (`abstract class`), and anything at all between the name
	 * and the body opener — a type parameter list above all, `class Generic<T>` being
	 * indistinguishable from `class Plain` in the AST.
	 */
	private static function headEdit(
		container: QueryNode, source: String, name: String, span: Span, typeName: String, syntax: EnumAbstractSyntax
	): Null<{ span: Span, text: String }> {
		final limit: Int = headLimit(container, span);
		final nameStart: Int = wordIndex(source, name, span.from, limit);
		if (nameStart <= span.from) return null;
		final keyword: String = source.substring(span.from, nameStart).trim();
		if (keyword.length == 0 || !isBareWord(keyword)) return null;
		var after: Int = nameStart + name.length;
		while (after < limit && isSpace(source.charAt(after))) after++;
		if (after >= source.length || source.charAt(after) != syntax.bodyOpen) return null;
		return {
			span: new Span(span.from, nameStart + name.length),
			text: syntax.head.replace(NAME_SLOT, name).replace(UNDER_SLOT, typeName)
		};
	}

	/** Where the declaration HEAD ends at the latest: the first child's start, else the container's own end. */
	private static function headLimit(container: QueryNode, span: Span): Int {
		for (child in container.children) {
			final s: Null<Span> = child.span;
			if (s != null) return s.from;
		}
		return span.to;
	}

	/**
	 * Append the member at `kids[i]`'s deletions to `edits` — the modifier run before it
	 * (`static` makes an enum-abstract value a private static field) and its `:T` annotation
	 * (which would type the value as `T` rather than as the abstract). False = refuse the whole
	 * container: a comment inside either deleted region, or an annotation whose separator is not
	 * where it should be, is a shape this rewrite has no answer for.
	 */
	private static function memberEdits(
		kids: Array<QueryNode>, i: Int, source: String, cfg: EnumAbstractCfg, edits: Array<{ span: Span, text: String }>
	): Bool {
		final member: QueryNode = kids[i];
		final memberSpan: Null<Span> = member.span;
		if (memberSpan == null) return false;
		var runStart: Int = -1;
		var j: Int = i - 1;
		while (j >= 0 && cfg.modifierKinds.contains(kids[j].kind)) {
			final s: Null<Span> = kids[j].span;
			if (s == null) return false;
			runStart = s.from;
			j--;
		}
		if (runStart >= 0) {
			if (CheckScan.hasCommentMarker(source, runStart, memberSpan.from)) return false;
			edits.push({ span: new Span(runStart, memberSpan.from), text: '' });
		}
		final annotation: Null<QueryNode> = member.type;
		if (annotation == null) return true;
		final annSpan: Null<Span> = annotation.span;
		if (annSpan == null) return false;
		var sep: Int = annSpan.from - 1;
		while (sep > memberSpan.from && isSpace(source.charAt(sep))) sep--;
		if (sep <= memberSpan.from || source.charAt(sep) != ANNOTATION_SEPARATOR) return false;
		if (CheckScan.hasCommentMarker(source, sep, annSpan.to)) return false;
		edits.push({ span: new Span(sep, annSpan.to), text: '' });
		return true;
	}

	/** The index of `needle` in `[from, limit)` as a WHOLE word (no identifier character either side), or -1. */
	private static function wordIndex(haystack: String, needle: String, from: Int, limit: Int): Int {
		var at: Int = haystack.indexOf(needle, from);
		while (at >= 0 && at + needle.length <= limit) {
			final before: String = at == 0 ? ' ' : haystack.charAt(at - 1);
			final after: String = haystack.charAt(at + needle.length);
			if (!isWordChar(before) && !isWordChar(after)) return at;
			at = haystack.indexOf(needle, at + 1);
		}
		return -1;
	}

	/** Whether `text` is one bare word — letters and underscores only, which is what a declaration keyword is. */
	private static function isBareWord(text: String): Bool {
		for (i in 0...text.length) {
			final c: String = text.charAt(i);
			if (!isWordChar(c) || (c >= '0' && c <= '9')) return false;
		}
		return true;
	}

	/** Whether `c` can appear inside an identifier — a letter, a digit or an underscore. */
	private static function isWordChar(c: String): Bool {
		return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
	}

	/** Whether `c` is source whitespace (space, tab, CR or LF). */
	private static function isSpace(c: String): Bool {
		return c == ' ' || c == '\t' || c == '\r' || c == '\n';
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
	final classKinds: Array<String>;
	final syntax: Null<EnumAbstractSyntax>;
};

private typedef WholeType = {
	final span: Span;
	final name: String;
	final count: Int;
	final typeName: String;

	/** The conversion edits for this container, or null when a refusal declined the rewrite. */
	final plan: Null<ConversionPlan>;
};

/**
 * One accepted whole-type conversion: which container, and the edits that convert it.
 *
 * `from` is the container's own start offset, which with `file` is the key `fix` reconstructs
 * from a violation's `span`. `declSource` is the declaration's verbatim text at plan time —
 * `fix` re-checks it against the source it is handed, so a plan can never be applied to a file
 * that moved underneath it (the fix loop re-runs the check per pass, but a stale plan would
 * splice at offsets that no longer mean anything).
 */
private typedef ConversionPlan = {
	final file: String;
	final from: Int;
	final name: String;
	final declSource: String;
	final edits: Array<{ span: Span, text: String }>;
};

private typedef Group = {
	final prefix: String;
	final span: Span;
	final members: Array<String>;
};
