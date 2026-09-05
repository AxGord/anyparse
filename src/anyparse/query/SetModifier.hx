package anyparse.query;

import anyparse.check.CheckScan;
import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;
using StringTools;

/**
 * Flip a declaration's visibility / add or remove a boolean modifier at a
 * cursor — without retyping the declaration. This is the safe replacement for
 * the `replace-node --at <modifier>` footgun: a modifier projects to a sibling
 * node BEFORE its declaration, and `--at` on it resolves the whole-decl
 * wrapper, so `replace-node --at <private-pos> 'public'` silently overwrites
 * the entire member with the word `public`.
 *
 * Which keywords ARE modifiers is the grammar's answer, read through
 * `RefShape.modifierKinds`. Haxe declares ten; the eight-entry hand-copy that
 * stood here made the other two invisible in BOTH directions — `set-modifier
 * … overload` was refused as unknown, and a member ALREADY carrying `overload`
 * / `abstract` had its run walk stop at that keyword, so the op emitted a
 * second visibility in front of the first (`public overload private function
 * g`) at rc 0, with a file that still parses and that Haxe rejects with
 * `Conflicting access modifier`. A `#if … #end` modifier region between the
 * run and the declaration produced the same duplicate.
 *
 * The run is therefore walked with `RefactorSupport.isDeclPrefixSibling` — the
 * predicate `declGroupSpan` folds with, so the run this op rewrites is the run
 * `remove-element` and `replace-node` cut — and the splice covers the bare
 * KEYWORDS only, ending at the LAST of them rather than at the declaration: an
 * `@:meta`, a conditional region and a keyword such a region merely
 * contributes sit inside the run and survive verbatim.
 *
 * Four shapes are REFUSED rather than guessed at. A bare `public` on a MODULE-LEVEL declaration,
 * because there is no such spelling: measured on 4.3.7, Haxe rejects it on all seven module-level
 * shapes — the five type kinds and a module-level function or var — while `private` is legal on all
 * seven and is the only visibility one can carry. The op wrote it anyway, at rc 0, and the refusal
 * names the edit that expresses the same intent (`-private`, which has always worked).
 *
 * A run with anything but whitespace BETWEEN two of its keywords — a `#if cpp inline #end`
 * region, or a COMMENT, which is trivia and so no sibling at all — because the first-to-last
 * splice covers it and would delete it: a silent semantic change, where the duplicate visibility
 * base emitted at least failed to compile. And a change naming a modifier the declaration carries
 * INSIDE a region, in either direction, because this op rewrites only the unguarded run: `+static`
 * beside a guarded `static` emits a second one that only that branch sees, and `-static` reports
 * success while it still stands.
 *
 * A region BEFORE the run, or between the run and the declaration, lies outside the splice and is
 * served normally — the shape every one of Pony's ten conditional modifier regions actually has.
 * A region contributing a declaration-starting KEYWORD (`#if … enum #end abstract E`) is part of
 * the declaration's head, so with no keyword to splice over the insertion goes in FRONT of it;
 * after the `#end` it produced `enum private abstract E(Int)`, which anyparse re-parses happily
 * and Haxe rejects with `Unexpected keyword "private"`.
 *
 * The result is re-emitted + re-parse-validated through
 * `RefactorSupport.canonicalize` (canonical-gated unless `reformat`). Changing
 * the visibility / a modifier OF a `final` declaration works (the `final` is
 * part of the declaration node); adding or removing `final` itself does NOT —
 * it wraps the declaration, changing its node kind, so a `final` change is an
 * `Err` (use `replace-node`).
 *
 * The source is never mutated; the caller decides whether to write the result.
 */
@:nullSafety(Strict)
final class SetModifier {

	/**
	 * This op's private emit order for the recomputed modifier run, and NOT the grammar's:
	 * `RefShape.modifierOrderKinds` ranks six kinds (`Override Public Private Static Inline Final`)
	 * and this list ranks eight, adding `macro` / `extern` / `dynamic`, which `modifier-order`
	 * leaves unranked by design. So a flip here reorders three keywords that check would have left
	 * alone — long-standing behaviour of this op, preserved deliberately, and order-clean either
	 * way because the six ranked kinds keep their relative positions.
	 *
	 * A modifier absent from here is emitted in the PHYSICAL slot it already occupied. That is the
	 * rule `ModifierOrder.fix` states for its own unranked set, and it is why `abstract` and
	 * `overload` are left out: this op has no position to put them in that the language documents,
	 * and inventing one would move a keyword on every unrelated edit.
	 *
	 * `SetModifierSliceTest.testTheRankedRunIsEmittedInCanonicalOrder` guards the ranking — a
	 * scrambled run of every ranked keyword must come back in this order — for seven of the eight.
	 * `public` is the exception it cannot cover: its fixture flips TO `private`, so `public` is
	 * already out of the surviving set and dropping its entry changes nothing;
	 * `testAFlipToPublicKeepsTheRankedRunInOrder` covers that one. Membership is guarded
	 * separately, and over the GRAMMAR rather than over this list, by
	 * `testEveryDeclaredModifierIsAnAcceptedChange` and
	 * `testEveryDeclaredModifierSurvivesAVisibilityFlipExactlyOnce`.
	 */
	private static final ORDER: Array<String> = [
		'macro',
		'extern',
		'override',
		'public',
		'private',
		'static',
		'inline',
		'dynamic'
	];

	/**
	 * Apply `changes` to the modifiers of the declaration at `line:col` (the
	 * `apq refs` column convention). Each change is `public` / `private` (set
	 * visibility), or `+<mod>` / `-<mod>` (add / remove a boolean modifier).
	 * Returns `Ok(rewritten)` or an `Err`.
	 */
	public static function setModifier(
		source: String, line: Int, col: Int, changes: Array<String>, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		if (changes.length == 0) return Err('no modifier changes given (e.g. public, +static, -inline)');
		// The modifier VOCABULARY is the grammar's, read through the seam every check and every
		// span walk reads (`RefShape.modifierKinds`, decoded by `CheckScan.modifierKinds`). The
		// hand-copy that stood here knew eight of the ten keywords the Haxe grammar projects, so
		// `abstract` / `overload` were refused as unknown on the way IN and, far worse, invisible
		// to the run walk on the way OUT.
		final shape: RefShape = plugin.refShape();
		final modifierKinds: Array<String> = CheckScan.modifierKinds(shape);
		final vocabulary: Array<String> = [for (kind in modifierKinds) kind.toLowerCase()];
		final visibility: Array<String> = [for (kind in shape.visibilityModifierKinds ?? []) kind.toLowerCase()];
		final invalid: Null<String> = validate(changes, vocabulary, visibility);
		if (invalid != null) return Err(invalid);

		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err('source does not parse: $exception')
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		final cursor: Int = Span.offsetOf(source, line, col);
		final node: Null<QueryNode> = Engine.at(tree, cursor);
		if (node == null) return Err('position $line:$col is not on a node');
		final parent: Null<QueryNode> = TreePath.parentOf(tree, node);
		if (parent == null) return Err('the node at $line:$col has no parent (not a member / declaration)');

		final siblings: Array<QueryNode> = parent.children;
		final cursorIndex: Int = siblings.indexOf(node);
		if (cursorIndex < 0) return Err('could not locate the declaration at $line:$col');

		// The core declaration: the cursor node, or — when the cursor is on a prefix sibling — the
		// first following sibling that is not one. `RefactorSupport.isDeclPrefixSibling` is the
		// SHARED predicate `declGroupSpan` folds with, so the run this op rewrites is the run
		// `remove-element` / `replace-node` cut: a keyword one of them crosses and the other stops
		// at is how a second visibility keyword got emitted in front of the first.
		var declIndex: Int = cursorIndex;
		while (declIndex < siblings.length && ElementSpan.isDeclPrefixSibling(siblings[declIndex])) declIndex++;
		if (declIndex >= siblings.length) return Err('no declaration follows the modifiers at $line:$col');
		final coreSpan: Null<Span> = siblings[declIndex].span;
		if (coreSpan == null) return Err('the ${siblings[declIndex].kind} declaration has no source span');

		// The splice ends at the LAST keyword of the run, not at the declaration: an `@:meta`, a
		// `#if … #end` modifier region and a keyword such a region merely contributes may sit
		// between the two, and running the span on to the declaration deleted them. When there is
		// no keyword at all the splice is an empty insertion point in front of the declaration, and
		// only then does the emitted run need its own trailing space.
		final run: ModifierRun = modifierRun(source, siblings, declIndex, shape, modifierKinds, coreSpan.from);
		// A modifier the declaration carries INSIDE a conditional region is not in the run this op
		// rewrites, so a change naming it is applied beside it rather than to it: `+static` on
		// `private #if cpp static #end function f` emitted a second `static` that only the guarded
		// target sees, and `-static` reported success while the region's own still stood. Same for a
		// visibility, which a flip removes from the run and cannot remove from the branch.
		final collision: Null<String> = guardedCollision(changes, run.guarded, visibility);
		if (collision != null) return Err('the declaration at $line:$col $collision');
		// A run SPLIT by a conditional region (`public #if cpp inline #end static function f`) cannot
		// be rewritten as one splice: the span from the first keyword to the last covers the region,
		// so emitting the recomputed run over it DELETES the region — a silent semantic change on the
		// guarded target, at rc 0. Which side of the region a keyword belongs on is a policy this op
		// does not have, so it refuses rather than guesses. A region BEFORE the whole run, or between
		// the run and the declaration, is untouched by the splice and is served normally.
		if (run.split)
			return Err(
				'the modifier run at $line:$col has something other than whitespace between two of its keywords — a conditional region, '
				+ 'or a comment. Rewriting the run in one splice would delete it; move the modifiers together, or edit them by hand'
			);
		// A MODULE-LEVEL declaration has no visibility container, so the public keyword has no
		// spelling there at all — and this op wrote it anyway, at rc 0, leaving a file anyparse
		// re-parses and Haxe refuses.
		final unspellable: Null<String> = modulePublicRefusal(tree, siblings[declIndex], changes, shape, run.names);
		if (unspellable != null) return Err('the declaration at $line:$col $unspellable');
		final rendered: String = applyChanges(run.names, changes, visibility);
		final edit: { span: Span, text: String } = {
			span: new Span(run.from, run.to),
			text: run.names.length == 0 ? rendered : rendered.rtrim()
		};
		return CanonicalEdit.canonicalize(source, [edit], reformat, plugin, optsJson);
	}

	/**
	 * Validate `changes` against the grammar's own modifier `vocabulary` (lower-cased
	 * `RefShape.modifierKinds`) and its `visibility` subset, returning an error message or null.
	 * A `final` change is rejected (it wraps the declaration); a bare change must be a
	 * visibility; `+`/`-` apply to any other modifier the grammar declares.
	 */
	private static function validate(changes: Array<String>, vocabulary: Array<String>, visibility: Array<String>): Null<String> {
		final booleans: Array<String> = vocabulary.filter(name -> !visibility.contains(name));
		for (change in changes) {
			final prefixed: Bool = change.startsWith('+') || change.startsWith('-');
			final name: String = prefixed ? change.substr(1) : change;
			if (name == 'final') return 'cannot set-modifier `final` — it wraps the declaration; use replace-node';
			if (!vocabulary.contains(name))
				return 'unknown modifier "$name" (use ${visibility.join('/')}, or +/- on ${booleans.join('/')})';
			if (!prefixed && !visibility.contains(name)) return 'a bare change must be ${visibility.join('/')}; use +$name / -$name';
		}
		return null;
	}

	/**
	 * Fold the validated `changes` into `current` and render the modifier prefix (space-separated,
	 * with a trailing space; `''` when none remain).
	 *
	 * Each RANKED slot of the original run — a keyword `ORDER` names — receives the next surviving
	 * ranked keyword in `ORDER`; a keyword `ORDER` does not rank keeps its own slot, and one that is
	 * newly ADDED has no slot and goes last. Same shape as `ModifierOrder.fix` ("unranked modifiers
	 * keep their physical positions; only ranked keywords move"), applied to an edit that also inserts
	 * and deletes — but over `ORDER`, which ranks three kinds that check leaves alone, so the two agree
	 * on the outcome without agreeing on which keywords may move.
	 */
	private static function applyChanges(current: Array<String>, changes: Array<String>, visibility: Array<String>): String {
		final mods: Array<String> = current.copy();
		for (change in changes) {
			final remove: Bool = change.startsWith('-');
			final name: String = remove || change.startsWith('+') ? change.substr(1) : change;
			if (visibility.contains(name)) {
				for (v in visibility) mods.remove(v);
				if (!remove) mods.push(name);
			} else if (remove)
				mods.remove(name)
			else if (!mods.contains(name))
				mods.push(name);
		}
		final ranked: Array<String> = ORDER.filter(m -> mods.contains(m));
		final out: Array<String> = [];
		var next: Int = 0;
		for (name in current) if (ORDER.contains(name)) {
			if (next < ranked.length) out.push(ranked[next++]);
		} else if (mods.contains(name))
			out.push(name);
		while (next < ranked.length) out.push(ranked[next++]);
		for (name in mods) if (!ORDER.contains(name) && !out.contains(name)) out.push(name);
		return out.length > 0 ? '${out.join(' ')} ' : '';
	}

	/**
	 * The bare modifier KEYWORDS of the prefix run before `siblings[declIndex]`, in source order, the
	 * span they occupy, and whether a non-keyword prefix sibling stands BETWEEN two of them.
	 *
	 * `RefactorSupport.isDeclPrefixSibling` bounds the run — the shared predicate `declGroupSpan`
	 * folds with — while `modifierKinds` picks the keywords out of it. An `@:meta`, a `#if … #end`
	 * region and a keyword such a region merely contributes are therefore inside the run and outside
	 * the SPAN, which reaches only from the first keyword to the last — unless one of them stands
	 * between two keywords, which the span cannot express and `split` reports so the caller can
	 * refuse rather than delete it. With no keyword at all the span is the empty insertion point at
	 * `declFrom`, in front of the declaration.
	 */
	private static function modifierRun(
		source: String, siblings: Array<QueryNode>, declIndex: Int, shape: RefShape, modifierKinds: Array<String>, declFrom: Int
	): ModifierRun {
		var startIndex: Int = declIndex;
		while (startIndex > 0 && ElementSpan.isDeclPrefixSibling(siblings[startIndex - 1])) startIndex--;
		final regionKind: Null<String> = shape.conditionalMemberKind;
		final headKinds: Array<String> = shape.condDeclPrefixKeywordKinds ?? [];
		final names: Array<String> = [];
		final guarded: Array<String> = [];
		var from: Int = declFrom;
		var to: Int = declFrom;
		var anchor: Int = declFrom;
		var anchored: Bool = false;
		var split: Bool = false;
		var crossed: Bool = false;
		for (j in startIndex ... declIndex) {
			final sib: QueryNode = siblings[j];
			final sibSpan: Null<Span> = sib.span;
			if (sibSpan == null) continue;
			if (!modifierKinds.contains(sib.kind)) {
				if (names.length > 0) crossed = true;
				if (sib.kind == regionKind) for (child in sib.children) if (modifierKinds.contains(child.kind))
					guarded.push(child.kind.toLowerCase())
				else if (headKinds.contains(child.kind) && !anchored) {
					anchor = sibSpan.from;
					anchored = true;
				}
				continue;
			}
			// A keyword reached across something that is not whitespace — another prefix sibling, or a
			// COMMENT, which is trivia and so no sibling at all. Either way the first-to-last span the
			// splice uses covers it, and re-emitting the run over it would delete it.
			if (crossed || (names.length > 0 && source.substring(to, sibSpan.from).trim().length > 0)) split = true;
			if (names.length == 0) from = sibSpan.from;
			to = sibSpan.to;
			names.push(sib.kind.toLowerCase());
		}
		// With no keyword to splice over, the run is an INSERTION point. It is the declaration's own
		// start — except in front of a region contributing a declaration-starting keyword, which is
		// part of the declaration's head (`#if … enum #end abstract E` reads `enum abstract`): writing
		// the modifier after that `#end` produced `enum private abstract E(Int)`, which anyparse
		// re-parses happily and Haxe rejects.
		if (names.length == 0) {
			from = anchor;
			to = anchor;
		}
		return {
			names: names,
			from: from,
			to: to,
			split: split,
			guarded: guarded
		};
	}

	/**
	 * The tail of a refusal message when one of `changes` names a modifier the declaration carries
	 * inside a conditional region, or null when none does. A visibility collides with ANY
	 * visibility: a flip removes one from the run and cannot remove one from a branch.
	 */
	private static function guardedCollision(changes: Array<String>, guarded: Array<String>, visibility: Array<String>): Null<String> {
		for (change in changes) {
			final name: String = change.startsWith('+') || change.startsWith('-') ? change.substr(1) : change;
			for (keyword in guarded) if (keyword == name || (visibility.contains(keyword) && visibility.contains(name)))
				return 'carries "$keyword" inside a conditional region, which this op does not rewrite — changing "$name'
					+ '\" here would leave the guarded branch carrying both; edit the modifiers by hand';
		}
		return null;
	}

	/**
	 * The tail of a refusal when `changes` would ADD the public-visibility keyword to a declaration
	 * that sits at the MODULE level, or null when they would not.
	 *
	 * Measured on Haxe 4.3.7: `public` is rejected on EVERY module-level shape the language has —
	 * the five type kinds (`public modifier is not supported for classes / enums / abstracts`) and
	 * a module-level function or var (`... for module-level fields`). Seven of seven, so the
	 * refusal is the whole module level and needs no per-kind carve-out. `private` is legal on all
	 * seven, and is the ONLY visibility a module-level declaration can spell.
	 *
	 * That is why the message names this op's own `-private` rather than another op: a module-level
	 * declaration is public unless it says `private`, so "make it public" IS the removal, and
	 * `set-modifier <file> --select '<decl>' -private` has always done it.
	 *
	 * Only an ADD is refused. `-public` removes a keyword that cannot be there, and is harmless.
	 */
	private static function modulePublicRefusal(
		tree: QueryNode, decl: QueryNode, changes: Array<String>, shape: RefShape, current: Array<String>
	): Null<String> {
		final publicName: Null<String> = shape.publicModifierKind?.toLowerCase();
		if (publicName == null) return null;
		final adds: Bool = changes.exists(
			change -> !change.startsWith('-') && (change.startsWith('+') ? change.substr(1) : change) == publicName
		);
		if (!adds || !isModuleLevel(tree, decl, shape)) return null;
		final visibility: Array<String> = [for (kind in shape.visibilityModifierKinds ?? []) kind.toLowerCase()];
		final held: Null<String> = current.find(name -> name != publicName && visibility.contains(name));
		return 'is at MODULE level, where "$publicName" has no spelling at all — Haxe rejects it on every module-level kind. ' + (
			held == null
				? 'A module-level declaration is "$publicName" unless it says otherwise, and this one says nothing: it already is'
				: 'A module-level declaration is "$publicName" unless it says "$held", so drop that instead: -$held'
		);
	}

	/**
	 * Whether `decl` sits at the MODULE level — every node between the parsed root and it is a
	 * conditional region, so nothing encloses it that could give a member its visibility.
	 *
	 * Asked structurally rather than off a kind list, because both lists that look like the answer
	 * are answering something else: `RefShape.typeDeclKinds` omits `EnumAbstractDecl`, whose members
	 * DO take a visibility, and `visibilityContainerKinds` names the containers whose members must
	 * SPELL one, which excludes an interface. A module-level `#if … #end` wraps its declarations in
	 * a region node without making them members of anything, and that is the one ancestor kind this
	 * has to see through.
	 */
	private static function isModuleLevel(tree: QueryNode, decl: QueryNode, shape: RefShape): Bool {
		final path: Null<Array<QueryNode>> = TreePath.pathTo(tree, decl);
		if (path == null) return false;
		final regionKind: Null<String> = shape.conditionalMemberKind;
		for (i in 1...path.length - 1) if (path[i].kind != regionKind) return false;
		return true;
	}

}

/**
 * The bare modifier keywords of one declaration prefix run, the source span they occupy, whether
 * that span covers anything but keywords and whitespace (`split` — the caller refuses), and the
 * keywords the run's conditional regions contribute (`guarded` — which this op does not rewrite and
 * a change must not collide with).
 */
private typedef ModifierRun = {
	final names: Array<String>;
	final from: Int;
	final to: Int;
	final split: Bool;
	final guarded: Array<String>;
};
