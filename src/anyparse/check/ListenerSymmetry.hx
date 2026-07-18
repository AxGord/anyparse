package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a subscribe/unsubscribe listener method that lacks its symmetrical
 * twin. A method whose name matches `add<Xxx>Listener(s)` should have a
 * matching `remove<Xxx>Listener(s)` declared in the same type (and vice versa),
 * and the two should be declared next to each other — a user preference that
 * makes what is subscribed obvious and keeps add/remove in sync.
 *
 * ## The three findings (all `Info`, report-only)
 *
 * - **missing twin** — a method matching `add<Xxx>Listener(s)` with no member
 *   named `remove<Xxx>Listener(s)` in the same type (or the reverse). Reported
 *   on the present method.
 * - **static-ness mismatch** — the twin exists by name but one is `static` and
 *   the other is not, so they cannot form a subscribe/unsubscribe pair.
 *   Reported once, on the `add` method.
 * - **not adjacent** — a valid same-static pair exists but another member is
 *   declared between them. Reported once, on the `add` method.
 *
 * The `<Xxx>` middle is required (a bare `addListener` / `removeListener` with
 * no discriminator is NOT a listener-symmetry candidate — nothing names the
 * subscription, so there is no meaningful pair to enforce). The twin name is
 * the exact suffix after the `add` / `remove` prefix, so the `Listener` /
 * `Listeners` plurality carries across unchanged.
 *
 * ## Grammar-agnostic
 *
 * Types are the plugin's `RefShape.visibilityContainerKinds` — for Haxe the
 * class-like declarations (class / abstract class / abstract). An interface is
 * deliberately out of scope (it declares a contract, not the extracted
 * subscribe/unsubscribe helpers this preference is about); an enum / typedef
 * has no such members. Method members are `memberDeclKinds` minus
 * `fieldDeclKinds`; a `#if`-guarded member is seen (recursing into
 * `conditionalMemberKind`). A grammar declaring none of these makes the check a
 * no-op.
 *
 * Report-only: adding the missing twin is a design intent (which events to
 * unsubscribe, in what order), not a mechanical rewrite, so `fix` yields no
 * edits.
 */
@:nullSafety(Strict)
final class ListenerSymmetry implements Check {

	public function new() {}

	public function id(): String {
		return 'listener-symmetry';
	}

	public function description(): String {
		return 'an add/remove listener method missing its symmetrical twin (or the twin not declared next to it)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final containerKinds: Array<String> = shape.visibilityContainerKinds ?? [];
		final memberKinds: Array<String> = shape.memberDeclKinds ?? [];
		final fieldKinds: Array<String> = shape.fieldDeclKinds ?? [];
		final methodKinds: Array<String> = [for (k in memberKinds) if (!fieldKinds.contains(k)) k];
		if (containerKinds.length == 0 || methodKinds.length == 0) return [];
		final cfg: ListenerCfg = {
			containerKinds: containerKinds,
			memberKinds: memberKinds,
			methodKinds: methodKinds,
			staticKind: shape.staticModifierKind,
			conditionalKind: shape.conditionalMemberKind,
			addRe: ~/^add(\w+Listeners?)$/,
			removeRe: ~/^remove(\w+Listeners?)$/
		};
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, entry.source, tree, cfg);
		}
		return violations;
	}

	/** Adding the missing twin is a design decision, not a mechanical autofix — report-only. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Walk `node`; check every type-body descendant's listener methods for symmetry. */
	private static function walk(out: Array<Violation>, file: String, source: String, node: QueryNode, cfg: ListenerCfg): Void {
		if (cfg.containerKinds.contains(node.kind)) checkContainer(out, file, source, node, cfg);
		for (c in node.children) walk(out, file, source, c, cfg);
	}

	/**
	 * Emit the symmetry findings for one type `container`. Collect its members in
	 * source order (a `#if`-guarded member included), then for each method whose
	 * name is an `add` / `remove` listener candidate resolve its expected twin and
	 * emit the missing / static-mismatch / not-adjacent finding as applicable.
	 */
	private static function checkContainer(
		out: Array<Violation>, file: String, source: String, container: QueryNode, cfg: ListenerCfg
	): Void {
		final members: Array<ListenerMember> = [];
		collect(members, container, cfg);
		final byName: Map<String, ListenerMember> = [];
		for (m in members) if (m.isMethod) byName[m.name] = m;
		for (m in members) if (m.isMethod) {
			final twinName: Null<String> = twinOf(m.name, cfg);
			if (twinName == null) continue;
			final isAdd: Bool = StringTools.startsWith(m.name, 'add');
			final twin: Null<ListenerMember> = byName[twinName];
			if (twin == null)
				out.push(finding(file, source, m.span, '\'${m.name}\' has no matching \'$twinName\' declared in this type'));
			else if (twin.isStatic != m.isStatic) {
				if (isAdd)
					out.push(finding(
						file, source, m.span, '\'${m.name}\' and \'$twinName\' must match in static-ness to form a listener pair'
					));
			} else if (isAdd && intAbs(m.index - twin.index) != 1)
				out.push(finding(file, source, m.span, '\'${m.name}\' and \'$twinName\' should be declared next to each other'));
		}
	}

	/**
	 * The name of the expected symmetrical twin of `name`, or null when `name` is
	 * not an `add` / `remove` listener candidate. The suffix after the prefix (the
	 * `<Xxx>Listener` / `<Xxx>Listeners` part) is carried across verbatim, so the
	 * plurality is preserved.
	 */
	private static function twinOf(name: String, cfg: ListenerCfg): Null<String> {
		return cfg.addRe.match(name) ? 'remove' + cfg.addRe.matched(1) : cfg.removeRe.match(name) ? 'add' + cfg.removeRe.matched(1) : null;
	}

	/**
	 * Collect `parent`'s member declarations into `out` in source order — the
	 * running `static` modifier attaches to the member that follows it, and a
	 * `#if` conditional-compilation block is descended into so a guarded member is
	 * recorded too. `index` is the position among ALL members (fields included) so
	 * adjacency counts any member sitting between a pair, not only another method.
	 */
	private static function collect(out: Array<ListenerMember>, parent: QueryNode, cfg: ListenerCfg): Void {
		var isStatic: Bool = false;
		for (child in parent.children) {
			if (cfg.conditionalKind != null && child.kind == cfg.conditionalKind) {
				collect(out, child, cfg);
				isStatic = false;
			} else if (cfg.memberKinds.contains(child.kind)) {
				final span: Null<Span> = child.span;
				final name: Null<String> = child.name;
				if (span != null && name != null) {
					final memberSpan: Span = span;
					final memberName: String = name;
					out.push({
						name: memberName,
						isStatic: isStatic,
						isMethod: cfg.methodKinds.contains(child.kind),
						span: memberSpan,
						index: out.length
					});
				}
				isStatic = false;
			} else if (cfg.staticKind != null && child.kind == cfg.staticKind)
				isStatic = true;
		}
	}

	/** One `Info` finding on the header line of `span` (line-clamped so a `// noqa` deep in a method body cannot swallow it). */
	private static function finding(file: String, source: String, span: Span, message: String): Violation {
		final headerEnd: Int = source.indexOf('\n', span.from);
		return {
			file: file,
			span: new Span(span.from, headerEnd == -1 ? span.to : headerEnd),
			rule: 'listener-symmetry',
			severity: Severity.Info,
			message: message
		};
	}

	/** Absolute value of `n` — the member-index distance for the adjacency test. */
	private static inline function intAbs(n: Int): Int {
		return n < 0 ? -n : n;
	}

}

/** Resolved kind-sets and the compiled add/remove patterns for one check run. */
private typedef ListenerCfg = {
	final containerKinds: Array<String>;
	final memberKinds: Array<String>;
	final methodKinds: Array<String>;
	final staticKind: Null<String>;
	final conditionalKind: Null<String>;
	final addRe: EReg;
	final removeRe: EReg;
};

/** One collected type member: its name, static flag, whether it is a method, its span and source-order index. */
private typedef ListenerMember = {
	final name: String;
	final isStatic: Bool;
	final isMethod: Bool;
	final span: Span;
	final index: Int;
};
