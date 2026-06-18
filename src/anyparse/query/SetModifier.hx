package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
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
 * Modifiers (`public` / `private` / `static` / `inline` / `override` / `macro`
 * / `extern` / `dynamic`) project as separate siblings between any `@:meta`
 * and the declaration keyword. This op recomputes that NON-`@:meta` modifier
 * run from `changes` and splices it back, leaving the `@:meta`, the
 * declaration, and its body untouched, then re-emits + re-parse-validates the
 * whole file via `RefactorSupport.canonicalize` (canonical-gated unless
 * `reformat`). Changing the visibility / a modifier OF a `final` declaration
 * works (the `final` is part of the declaration node); adding or removing
 * `final` itself does NOT — it wraps the declaration, changing its node kind,
 * so a `final` change is an `Err` (use `replace-node`).
 *
 * The source is never mutated; the caller decides whether to write the result.
 */
@:nullSafety(Strict)
final class SetModifier {

	/** Boolean modifiers (non-visibility) this op can add / remove. */
	private static final BOOLEAN_MODS: Array<String> = ['static', 'inline', 'override', 'macro', 'extern', 'dynamic'];

	/** Canonical emit order for the recomputed modifier run. */
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

	/** Sibling node kinds that are modifiers (NOT `@:meta`); the keyword is the lower-cased kind. */
	private static final MODIFIER_KINDS: Array<String> = [
		'Public',
		'Private',
		'Static',
		'Inline',
		'Override',
		'Macro',
		'Extern',
		'Dynamic'
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
		final invalid: Null<String> = validate(changes);
		if (invalid != null) return Err(invalid);

		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		final cursor: Int = Span.offsetOf(source, line, col);
		final node: Null<QueryNode> = Engine.at(tree, cursor);
		if (node == null) return Err('position $line:$col is not on a node');
		final parent: Null<QueryNode> = RefactorSupport.parentOf(tree, node);
		if (parent == null) return Err('the node at $line:$col has no parent (not a member / declaration)');

		final siblings: Array<QueryNode> = parent.children;
		final cursorIndex: Int = siblings.indexOf(node);
		if (cursorIndex < 0) return Err('could not locate the declaration at $line:$col');

		// The core declaration: the cursor node, or — when the cursor is on a
		// modifier / `@:meta` sibling — the first following sibling that is not.
		var declIndex: Int = cursorIndex;
		while (declIndex < siblings.length && isModifierMeta(siblings[declIndex].kind)) declIndex++;
		if (declIndex >= siblings.length) return Err('no declaration follows the modifiers at $line:$col');
		final coreSpan: Null<Span> = siblings[declIndex].span;
		if (coreSpan == null) return Err('the ${siblings[declIndex].kind} declaration has no source span');

		// The modifier / `@:meta` run preceding the declaration; collect the
		// current NON-meta modifier keywords (source order) and the splice point
		// — the first such modifier, or the declaration itself when there are none.
		var startIndex: Int = declIndex;
		while (startIndex > 0 && isModifierMeta(siblings[startIndex - 1].kind)) startIndex--;
		final current: Array<String> = [];
		var regionFrom: Int = coreSpan.from;
		for (j in startIndex...declIndex) {
			final sib: QueryNode = siblings[j];
			final sibSpan: Null<Span> = sib.span;
			if (!MODIFIER_KINDS.contains(sib.kind) || sibSpan == null) continue;
			if (current.length == 0) regionFrom = sibSpan.from;
			current.push(sib.kind.toLowerCase());
		}

		final edit: { span: Span, text: String } = { span: new Span(regionFrom, coreSpan.from), text: applyChanges(current, changes) };
		return RefactorSupport.canonicalize(source, [edit], reformat, plugin, optsJson);
	}

	private static inline function isModifierMeta(kind: String): Bool {
		return kind == 'Meta' || MODIFIER_KINDS.contains(kind);
	}

	/**
	 * Validate `changes`, returning an error message or null. A `final` change
	 * is rejected (it wraps the declaration); a bare change must be a
	 * visibility (`public` / `private`); `+`/`-` apply to a known modifier.
	 */
	private static function validate(changes: Array<String>): Null<String> {
		for (change in changes) {
			final prefixed: Bool = change.startsWith('+') || change.startsWith('-');
			final name: String = prefixed ? change.substr(1) : change;
			if (name == 'final') return 'cannot set-modifier `final` — it wraps the declaration; use replace-node';
			final known: Bool = name == 'public' || name == 'private' || BOOLEAN_MODS.contains(name);
			if (!known) return 'unknown modifier "$name" (use public/private, or +/- on ${BOOLEAN_MODS.join('/')})';
			if (!prefixed && name != 'public' && name != 'private') return 'a bare change must be public/private; use +$name / -$name';
		}
		return null;
	}

	/**
	 * Fold the validated `changes` into `current` and render the canonical
	 * modifier prefix (keywords in `ORDER`, space-separated, with a trailing
	 * space; `''` when none remain).
	 */
	private static function applyChanges(current: Array<String>, changes: Array<String>): String {
		final mods: Array<String> = current.copy();
		for (change in changes) {
			final remove: Bool = change.startsWith('-');
			final name: String = remove || change.startsWith('+') ? change.substr(1) : change;
			if (name == 'public' || name == 'private') {
				mods.remove('public');
				mods.remove('private');
				if (!remove) mods.push(name);
			} else if (remove)
				mods.remove(name)
			else if (!mods.contains(name)) mods.push(name);
		}
		final ordered: Array<String> = ORDER.filter(m -> mods.contains(m));
		return ordered.length > 0 ? '${ordered.join(' ')} ' : '';
	}

}
