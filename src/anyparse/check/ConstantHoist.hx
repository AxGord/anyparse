package anyparse.check;

import anyparse.query.CondRegionScan;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.ElementSpan;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.NamingPolicy.HoistedConstant;
import anyparse.query.NamingPolicy.NamedDecl;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.NamingPolicy;
import anyparse.query.NamingPolicy.NamingRule;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.OccurrenceScan;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SourceComments;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * The `naming` autofix's constant-HOIST arm, factored out of the check that drives it.
 *
 * A local `final` that is an author-intended CONSTANT — an UPPER_SNAKE name over a
 * compile-time-constant initializer — is not a camelCase violation to correct in place. It is a
 * class constant written in the wrong scope, and the fix is to MOVE it: at type level UPPER_SNAKE
 * is exactly what the Constant naming rule wants, so the name the author chose survives. Renaming
 * it to `sidePadding` would erase the intent the spelling states.
 *
 * The arm produces one deletion per hoisted declaration plus one insertion per receiving type;
 * `Naming.fix` keeps the ordinary rename arm off every declaration this one claims, and every gate
 * failure here silently leaves the declaration to that arm.
 *
 * ## The caller owns the occurrence resolution
 *
 * The whole-file occupancy gate needs the same scope-correct reference set a RENAME of the binding
 * would rewrite, which is `Naming`'s own resolution. Rather than reach into it, the entry point
 * takes an `OccurrenceResolver`: the caller answers, this module only complements the answer
 * against a whole-file scan.
 *
 * ## Grammar-neutral
 *
 * Reads `localDeclKinds` minus `mutableLocalDeclKinds` / `localDeclContinuationKinds` (the
 * immutable-local hosts), `classDeclKinds` (the types that may receive one),
 * `staticlessTypeMetaNames`, `modifierOrderKinds`, `ControlFlowSupport.blockKinds` (statement-list
 * hosts), `metaShape().metaKinds`, `stringFoldSupport()`, and the grammar's own rendering of the
 * member through `NamingSupport.hoistedConstant`. Any required seam unset makes the arm a no-op.
 */
@:nullSafety(Strict)
final class ConstantHoist {

	/**
	 * An UPPER_SNAKE identifier — the half of a Constant `format` under which a hoisted local keeps
	 * the spelling it already has. A local broken some other way (`min_gap`, `MyLocal`) states no
	 * constant intent and is renamed as ever. A cheap pre-filter only: whether the policy governing
	 * the EMITTED member actually accepts the name is decided per hoist, once the modifier run the
	 * grammar renders is known (see `hoistFor`).
	 */
	private static final UPPER_SNAKE_NAME_PATTERN: EReg = new EReg("^[A-Z][A-Z0-9_]*$", '');

	/**
	 * Every flagged declaration this pass hoists to its enclosing type as a constant. The arm is off
	 * when a seam it needs is missing: no resolution index (the inherited-member proof has nothing
	 * to ask), or a grammar with no immutable-local, class-declaration or statement-block kinds.
	 *
	 * At most ONE hoist per name. That cap is already implied by `occupiesNameAlone` — a second
	 * binding of the name anywhere in the file refuses both — so no fixture isolates it; it is kept
	 * so the "one new member per name" invariant is local to the emission rather than resting on a
	 * gate two functions away.
	 */
	public static function hoistsFor(
		decls: Array<NamedDecl>, source: String, tree: QueryNode, policy: NamingPolicy, plugin: GrammarPlugin, support: NamingSupport,
		flaggedFroms: Array<Int>, resolutionIndex: Null<SymbolIndex>, file: String, occurrences: OccurrenceResolver
	): Array<Hoist> {
		final shape: RefShape = plugin.refShape();
		final control: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		final declKinds: Array<String> = immutableLocalKinds(shape);
		final classKinds: Array<String> = shape.classDeclKinds ?? [];
		final blockKinds: Array<String> = control == null ? [] : control.blockKinds();
		if (resolutionIndex == null || declKinds.length == 0 || classKinds.length == 0 || blockKinds.length == 0) return [];
		// Re-bound as a non-null local: strict null safety does not narrow a captured local inside an
		// anonymous structure literal.
		final index: SymbolIndex = resolutionIndex;
		final ctx: HoistContext = {
			source: source,
			tree: tree,
			policy: policy,
			declKinds: declKinds,
			classKinds: classKinds,
			blockKinds: blockKinds,

			plugin: plugin,
			support: support,
			flaggedFroms: flaggedFroms,
			index: index,
			file: file,
			occurrences: occurrences
		};
		final out: Array<Hoist> = [];
		final names: Array<String> = [];
		// Hoisted out of the loop: the scan is O(file) and every candidate asks the same question of
		// the same source.
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		for (decl in decls) if (!names.contains(decl.name)) {
			final hoist: Null<Hoist> = hoistFor(decl, ctx, regions);
			if (hoist == null) continue;
			names.push(decl.name);
			out.push(hoist);
		}
		return out;
	}

	/**
	 * One deletion per hoisted declaration, plus ONE insertion per receiving type carrying every
	 * constant that type gained this pass. Per TYPE rather than per constant because two zero-width
	 * insertions sharing an offset have no defined order in `RefactorSupport.applyEdits`, and the
	 * caller's overlap discipline would defer the second one to a later pass for no reason.
	 *
	 * Each insertion lands immediately after the body's opening brace and carries no trailing
	 * newline — the one already following the brace terminates the last member. Slot and blank-line
	 * spacing are the writer's to settle, as they are for every other emitted member.
	 */
	public static function edits(hoists: Array<Hoist>): Array<{ span: Span, text: String }> {
		final out: Array<{ span: Span, text: String }> = [];
		final inserts: Array<{ at: Int, text: String }> = [];
		for (hoist in hoists) {
			out.push({ span: hoist.deleteSpan, text: '' });
			final member: String = '\n\t${hoist.memberText}';
			final slot: Null<{ at: Int, text: String }> = inserts.find(pending -> pending.at == hoist.insertAt);
			if (slot == null)
				inserts.push({ at: hoist.insertAt, text: member });
			else
				slot.text += member;
		}
		for (slot in inserts) out.push({ span: new Span(slot.at, slot.at), text: slot.text });
		return out;
	}

	/**
	 * The rule governing a Constant carrying `mods` — the same first-applicable walk
	 * `Naming.applicableRule` makes for a projected declaration, asked of the modifier run the
	 * grammar actually renders. Null refuses the hoist: a policy that governs no such member cannot
	 * say the hoisted name is correct, and emitting one it would immediately re-flag is worse than
	 * renaming in place.
	 */
	public static function constantRule(policy: NamingPolicy, mods: Array<String>): Null<NamingRule> {
		return policy.find(
			rule ->
				rule.category == NamingCategory.Constant && rule.requireMods.foreach(m -> mods.contains(m))
				&& !rule.forbidMods.exists(m -> mods.contains(m))
		);
	}

	/**
	 * Whether the receiving type carries a metadata tag under which the language forbids STATIC
	 * members (`RefShape.staticlessTypeMetaNames`). Adding one there does not compile, and no other
	 * gate would notice: the re-parse validation accepts the member and the type closure has nothing
	 * to say about it.
	 */
	public static function staticsForbidden(tree: QueryNode, decl: TypeDeclMatch, plugin: GrammarPlugin): Bool {
		final shape: RefShape = plugin.refShape();
		final staticless: Array<String> = shape.staticlessTypeMetaNames ?? [];
		if (staticless.length == 0) return false;
		final metas: Array<String> = precedingMetaNames(tree, decl.fullSpan, plugin.metaShape().metaKinds, shape.modifierOrderKinds ?? []);
		return metas.exists(meta -> staticless.contains(meta));
	}

	/**
	 * The hoist for one projected declaration, or null when a gate refuses it — and then the caller's
	 * ordinary rename arm takes it, unchanged. The gates, cheapest and most selective first:
	 *
	 *  - a FLAGGED local whose name is UPPER_SNAKE;
	 *  - the node at its span is an IMMUTABLE local declaration, a DIRECT child of a statement block,
	 *    with exactly ONE child — its initializer. Direct-child-of-a-block is load-bearing, not
	 *    tidiness: a declaration that is the brace-less BODY of an `if` / `for` / `else` owns that
	 *    body slot, and removing its line hands the slot to the next statement — a silent semantic
	 *    change the re-parse gate accepts (verified in all three shapes). A declaration directly under an
	 *    UNBRACED `case` arm is a deliberate conservative miss — an arm is not a statement block here
	 *    (a braced arm hoists fine). A `var` may be written; a multi-binding list carries a continuation
	 *    node as its last child; a declaration without an initializer has no child at all;
	 *  - the initializer is a compile-time constant — the scalar proof `inline-constant` owns
	 *    (`InlineConstant.isConstantScalarInitializer`), or a PLAIN string literal, which is exactly
	 *    what `StringFoldSupport.literalOf` answers (an interpolated one reads locals and is refused
	 *    there);
	 *  - the enclosing type is a CLASS declared in this file, and one the language lets hold a static
	 *    (`staticlessTypeMetaNames` — Haxe's `@:generic` does not). The type form that must never
	 *    receive a constant is `enum abstract`, whose members are enum VALUES rather than fields, and
	 *    it is excluded by `classDeclKinds`; a plain `abstract` is a deliberate conservative miss;
	 *  - the type PROVABLY declares no member of that name across its full supertype closure. Haxe
	 *    rejects a static field whose name matches an instance field, INCLUDING an inherited one
	 *    ("Same field name can't be used for both static and instance", verified), so an unresolvable
	 *    closure is a refusal;
	 *  - no conditional-compilation region stands between the type body and the declaration. Hoisting
	 *    out of one branch hands every OTHER branch a member it never declared;
	 *  - no comment ends on the line directly ABOVE it (`commentAbove`). A comment written ON the
	 *    declaration's own line is unambiguous and travels with it (`trailingCommentOf`);
	 *  - the name occurs NOWHERE else in the file. A hoisted constant is visible from every member of
	 *    its type, so any other occurrence — a sibling method's same-named local, a static import the
	 *    new member would shadow — is a binding the hoist could silently re-point;
	 *  - the policy governing the member the grammar renders accepts the name. The rule is selected
	 *    by the modifier run that member actually carries, which the two arms DIFFER in (`inline` for
	 *    a scalar, absent for a String): a policy splitting its Constant rules on that modifier must
	 *    judge each arm by its own rule.
	 */
	private static function hoistFor(decl: NamedDecl, ctx: HoistContext, regions: Array<LexRegion>): Null<Hoist> {
		final span: Null<Span> = decl.span;
		if (span == null || !ctx.flaggedFroms.contains(span.from) || decl.category != NamingCategory.Local) return null;
		final name: String = decl.name;
		if (!UPPER_SNAKE_NAME_PATTERN.match(name)) return null;
		final owner: Null<String> = decl.enclosingType;
		final node: Null<QueryNode> = blockLevelDeclAt(ctx.tree, ctx.declKinds, ctx.blockKinds, span.from);
		if (owner == null || node == null) return null;
		final ownerName: String = owner;
		final init: QueryNode = node.children[0];
		final scalar: Bool = InlineConstant.isConstantScalarInitializer(init, ctx.plugin);
		if (!scalar && ctx.plugin.stringFoldSupport()?.literalOf(init, ctx.source) == null) return null;
		final type: Null<TypeDeclMatch> = RefactorSupport.uniqueTypeDeclNamed(ctx.tree, ownerName, ctx.classKinds);
		if (type == null) return null;
		final match: TypeDeclMatch = type;
		if (!receivable(match, name, ownerName, span, ctx, () -> regions)) return null;
		final brace: Null<Int> = RefactorSupport.typeBodyBraceOffset(ctx.source, match, ownerName, regions);
		if (brace == null) return null;
		final member: Null<HoistedConstant> = ctx.support.hoistedConstant(declarationTextOf(ctx.source, span), scalar);
		if (member == null) return null;
		final emitted: HoistedConstant = member;
		final rule: Null<NamingRule> = constantRule(ctx.policy, emitted.mods);
		if (rule == null || !rule.format.match(name)) return null;
		// The trailing note is appended to what the grammar rendered rather than folded into its
		// `declarationText`, which is contracted to be the terminated declaration alone.
		final trailing: Null<Span> = trailingCommentOf(ctx.source, span, regions);
		return {
			declFrom: span.from,
			insertAt: brace + 1,
			deleteSpan: ElementSpan.lineExtendedSpan(ctx.source, trailing == null ? span : new Span(span.from, trailing.to)),
			memberText: trailing == null ? emitted.text : '${emitted.text} ${ctx.source.substring(trailing.from, trailing.to)}'
		};
	}

	/**
	 * The local-declaration kinds binding an IMMUTABLE local: `localDeclKinds` minus the mutable ones
	 * and minus the comma-continuation kind — the same subtraction `InlineConstant.resolveSeams`
	 * makes to reach the final FIELD hosts. Only such a binding can become a constant: a `var` may be
	 * written, and a continuation node carries no declaration keyword of its own to copy.
	 */
	private static function immutableLocalKinds(shape: RefShape): Array<String> {
		final mutable: Array<String> = shape.mutableLocalDeclKinds ?? [];
		final continuation: Array<String> = shape.localDeclContinuationKinds ?? [];
		return [
			for (kind in shape.localDeclKinds ?? []) if (!mutable.contains(kind) && !continuation.contains(kind)) kind
		];
	}

	/**
	 * The declaration starting at `declFrom` whose kind is in `kinds`, whose single child is its
	 * initializer, and which is a DIRECT child of a statement block — the only position from which
	 * removing its line cannot change what some enclosing construct's body is (see `hoistFor`).
	 */
	private static function blockLevelDeclAt(
		tree: QueryNode, kinds: Array<String>, blockKinds: Array<String>, declFrom: Int
	): Null<QueryNode> {
		var found: Null<QueryNode> = null;
		function walk(node: QueryNode): Void {
			final isBlock: Bool = blockKinds.contains(node.kind);
			for (child in node.children) {
				final s: Null<Span> = child.span;
				if (isBlock && s != null && s.from == declFrom && kinds.contains(child.kind) && child.children.length == 1) found = child;
				walk(child);
			}
		}
		walk(tree);
		return found;
	}

	/**
	 * Whether a conditional-compilation region stands anywhere on the path from `node` down to the
	 * declaration at `declFrom`. Descends through the one child whose span contains the offset, so
	 * the answer is about that declaration's own ancestry rather than the subtree holding a region
	 * somewhere.
	 */
	private static function conditionalBetween(node: QueryNode, declFrom: Int): Bool {
		if (CondRegionScan.isConditionalKind(node.kind)) return true;
		for (child in node.children) {
			final s: Null<Span> = child.span;
			if (s != null && declFrom >= s.from && declFrom < s.to) return conditionalBetween(child, declFrom);
		}
		return false;
	}

	/**
	 * The names of the metadata siblings preceding the node spanning exactly `span`, skipping the
	 * modifier siblings that may sit between them and the declaration. A type's annotations project
	 * as siblings BEFORE it rather than as its children, so this is the only way to read them off a
	 * `TypeDeclMatch`. Empty when the span names no node or the run holds no metadata.
	 */
	private static function precedingMetaNames(
		node: QueryNode, span: Span, metaKinds: Array<String>, modifierKinds: Array<String>
	): Array<String> {
		final children: Array<QueryNode> = node.children;
		for (i in 0...children.length) {
			final s: Null<Span> = children[i].span;
			if (s == null || s.from != span.from || s.to != span.to) continue;
			final out: Array<String> = [];
			var k: Int = i - 1;
			while (k >= 0) {
				final kind: String = children[k].kind;
				if (metaKinds.contains(kind))
					out.push(children[k].name ?? '');
				else if (!modifierKinds.contains(kind))
					break;
				k--;
			}
			return out;
		}
		for (child in children) {
			final found: Array<String> = precedingMetaNames(child, span, metaKinds, modifierKinds);
			if (found.length > 0) return found;
		}
		return [];
	}

	/**
	 * Whether `name` occurs nowhere in the file outside the binding's own occurrence set. The set is
	 * the caller's scope-correct resolution, so a comment mention inside the binding's container does
	 * not block, while a second declaration, a read the resolver could not attribute, or a `#if`
	 * region naming it does. An unresolvable set is a refusal.
	 */
	private static function occupiesNameAlone(name: String, declFrom: Int, ctx: HoistContext): Bool {
		final spans: Null<Array<Span>> = ctx.occurrences(declFrom, name);
		if (spans == null) return false;
		final rest: Null<Array<ClassifiedOccurrence>> = OccurrenceScan.classifyOccurrences(
			ctx.source, name, ctx.plugin, 0, ctx.source.length, spans
		);
		return rest != null && rest.length == 0;
	}

	/**
	 * The declaration's own source text from its keyword on, terminated — the verbatim body of the
	 * hoisted member, so the type annotation and the initializer are carried exactly as written. A
	 * grammar whose declaration span excludes the terminator gets one appended.
	 */
	private static function declarationTextOf(source: String, span: Span): String {
		final text: String = source.substring(span.from, span.to).trim();
		return text.endsWith(';') ? text : '$text;';
	}

	/**
	 * The comment written on the declaration's OWN line after it (`final PAD:Int = 4; // px`), or
	 * null when there is none. Such a comment is unambiguously about the declaration, so it travels
	 * with it to the class body; left behind it would be a note about a constant that is no longer
	 * there. A comment running onto further lines is not one and is declined.
	 */
	private static function trailingCommentOf(source: String, span: Span, regions: Array<LexRegion>): Null<Span> {
		var at: Int = span.to;
		while (at < source.length && (source.fastCodeAt(at) == ' '.code || source.fastCodeAt(at) == '\t'.code)) at++;
		final comment: Null<Span> = SourceComments.commentBlockAt(source, at, regions);
		if (comment == null) return null;
		final block: Span = comment;
		final newline: Int = source.indexOf('\n', block.from);
		return block.from == at && (newline < 0 || newline >= block.to) ? block : null;
	}

	/**
	 * Whether a comment ends on the line directly ABOVE the declaration. Such a comment reads
	 * identically whether it documents the declaration or introduces the block the declaration
	 * opens, and the two want OPPOSITE halves of the move — carried along, or left where it is.
	 * Neither choice is right for both, so the hoist refuses and the ordinary rename applies, which
	 * leaves the comment exactly where its author put it. A comment separated by a blank line is not
	 * "directly above" and does not refuse.
	 */
	private static function commentAbove(source: String, span: Span, regions: () -> Array<LexRegion>): Bool {
		var at: Int = span.from;
		var newlines: Int = 0;
		while (at > 0 && SourceText.isSpace(source.fastCodeAt(at - 1))) {
			if (source.fastCodeAt(at - 1) == '\n'.code) newlines++;
			if (newlines > 1) return false;
			at--;
		}
		return at > 0 && newlines == 1 && SourceComments.commentBlockAt(source, at - 1, regions()) != null;
	}

	/**
	 * The five proofs about the RECEIVING side of the move, split out of `hoistFor` so the emission
	 * half reads as emission: the type may hold a static at all, it provably declares no member of the
	 * name (own or inherited), no conditional-compilation region stands between its body and the
	 * declaration, no comment ends on the line directly above the declaration, and the name is the
	 * declaration's alone in this file. Each is documented at its bullet in `hoistFor`; `commentAbove`
	 * rides along because it too asks only whether the move is safe, not what to write.
	 */
	private static function receivable(
		match: TypeDeclMatch, name: String, ownerName: String, declSpan: Span, ctx: HoistContext, regions: () -> Array<LexRegion>
	): Bool {
		return !staticsForbidden(ctx.tree, match, ctx.plugin) && ctx.index.members.typeProvablyLacksMember(ownerName, name, ctx.file)
			&& !conditionalBetween(match.nameNode, declSpan.from) && !commentAbove(ctx.source, declSpan, regions)
			&& occupiesNameAlone(name, declSpan.from, ctx);
	}

}

/**
 * One constant to move out of a function body: which declaration it came from, where the new member
 * goes, what to remove, and what to write.
 */
typedef Hoist = {
	/** The flagged declaration's cursor offset — how the caller knows to keep its rename arm off it. */
	final declFrom: Int;

	/** Where the new member goes: just after the receiving type's body-opening brace. */
	final insertAt: Int;

	/**
	 * The whole line the local declaration occupies, removed with it — including a trailing comment
	 * carried into `memberText`, which is part of the declaration's line and must not be left behind.
	 */
	final deleteSpan: Span;

	/** The member declaration the grammar renders for it (`NamingSupport.hoistedConstant`). */
	final memberText: String;
};

/**
 * The scope-correct occurrence set of the binding declared at an offset — every span a RENAME of it
 * would rewrite — or null when that set cannot be proven complete.
 *
 * Supplied by the caller rather than re-derived here: `Naming` already resolves it for its rename
 * arm, and the two gates must agree about what counts as a reference. Passing the answer in keeps the
 * hoist arm out of that resolution's internals. The set is resolved
 * BODY-SCOPED: the arm only ever hands the resolver a LOCAL's declaration (its category gate runs
 * first), and `Naming`'s closure assumes exactly that.
 */
typedef OccurrenceResolver = (declFrom:Int, name:String) -> Null<Array<Span>>;

/**
 * What every gate of the arm reads, resolved once per `hoistsFor` call: the parsed file and its
 * source, the policy the emitted member must satisfy, the grammar kinds and seams the gates need,
 * the flagged spans, the RESOLUTION-scope index the inherited-member proof asks, and the caller's
 * occurrence resolver.
 */
private typedef HoistContext = {
	final source: String;
	final tree: QueryNode;
	final policy: NamingPolicy;

	/** The local-declaration kinds that bind an immutable local — see `immutableLocalKinds`. */
	final declKinds: Array<String>;

	/** The type-declaration kinds a constant may be hoisted INTO — classes only. */
	final classKinds: Array<String>;

	/** The statement-list hosts — a declaration must be a DIRECT child of one. */
	final blockKinds: Array<String>;

	final plugin: GrammarPlugin;
	final support: NamingSupport;
	final flaggedFroms: Array<Int>;
	final index: SymbolIndex;
	final file: String;
	final occurrences: OccurrenceResolver;
};
