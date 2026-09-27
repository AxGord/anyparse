package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.SymbolIndex;
import haxe.Exception;

using Lambda;
using StringTools;

/**
 * The run's macro knowledge, built ONCE and lazily: the qualified paths of every `macro`
 * member by simple name, plus the index itself for the TYPE questions the second refusal
 * asks. Shared across the run's per-file gates, since the index is the expensive part and
 * the whitelist is not, and demanded only once a construct has actually planned, which on
 * a tree with no findings is never.
 */
@:nullSafety(Strict)
final class MacroIndex {

	private final _plugin: GrammarPlugin;
	private final _files: Array<{ file: String, source: String }>;

	private var _index: Null<SymbolIndex> = null;
	private var _macros: Null<Map<String, Array<String>>> = null;

	public function new(plugin: GrammarPlugin, files: Array<{ file: String, source: String }>) {
		_plugin = plugin;
		_files = files;
	}

	/** The qualified paths of the `macro` members named `name`, or null when none is. */
	public function macroPathsOf(name: String): Null<Array<String>> {
		build();
		final macros: Null<Map<String, Array<String>>> = _macros;
		if (macros == null) throw new Exception('fold-adjacent-string-literals: the macro index was read before it was built');
		return macros[name];
	}

	/** Whether the index carries a TYPE declaration named `name`. */
	public function declaresType(name: String): Bool {
		build();
		return index().refs.declaringFiles(name).length > 0;
	}

	/**
	 * The raw path of the first import of `file` that BINDS `name` and whose own target
	 * type the index does NOT carry, or null when nothing binds it or what does is in
	 * scope. That is the question "could this file's imports route this call to a
	 * declaration the resolution scope cannot see".
	 *
	 * Binding is per import KIND, and the two wildcard forms are why the kind has to be
	 * read rather than the path: a plain import binds its last segment, an alias binds the
	 * alias, and a WILDCARD or a `using` binds everything — the first because it pulls a
	 * package's types or a type's statics in under their own names, the second because a
	 * static extension routes by receiver TYPE and can answer any method call in the file.
	 */
	public function unresolvedBinding(file: String, name: String): Null<String> {
		build();
		final info: Null<FileInfo> = index().fileInfo(file);
		if (info == null) return null;
		// The wildcard's own `*` is dropped from the answer: the caller appends the member
		// name to it to probe the whitelist, and `m.Lang.*.t` names nothing.
		for (imported in info.imports) if (binds(imported, name) && !carriesTarget(imported.raw))
			return imported.raw.endsWith('.*') ? imported.raw.substr(0, imported.raw.length - 2) : imported.raw;
		return null;
	}

	/** Whether `imported` puts `name` in scope — see the kind-by-kind reasoning on `unresolvedBinding`. */
	private function binds(imported: ImportInfo, name: String): Bool {
		return switch imported.kind {
			case ImportKind.Alias: imported.alias == name;
			case ImportKind.Wild, ImportKind.Using: true;
			case _: lastSegment(imported.raw) == name;
		}
	}

	/**
	 * Whether the index carries the TYPE an import path names. WHICH segment that is
	 * cannot be known from the path alone — `pkg.Lang.t` is a member of `Lang`, `pkg.a.Lang`
	 * is a type in `pkg.a` — so both trailing segments are tried, a wildcard's `*` dropped
	 * first. Trying too many is the safe direction: it can only conclude the target IS in
	 * scope, which is the answer that allows a fix the caller was going to get anyway.
	 */
	private function carriesTarget(raw: String): Bool {
		final segments: Array<String> = raw.split('.');
		if (segments[segments.length - 1] == '*') segments.pop();
		for (i in 0...segments.length) {
			if (i >= 2) break;
			if (declaresType(segments[segments.length - 1 - i])) return true;
		}
		return false;
	}

	/** The resolved index, valid after `build`. */
	private function index(): SymbolIndex {
		final built: Null<SymbolIndex> = _index;
		if (built == null) throw new Exception('fold-adjacent-string-literals: the macro index was read before it was built');
		return built;
	}

	/** Resolve the index on first demand and project both maps out of it. */
	private function build(): Void {
		if (_macros != null) return;
		final index: SymbolIndex = RefactorSupport.resolutionIndexOf(_plugin) ?? SymbolIndex.build(_files, _plugin);
		_index = index;
		final macros: Map<String, Array<String>> = [];
		for (info in index.allFiles()) for (type in info.types) for (member in type.members) if (member.isMacro) {
			final scoped: String = '${type.name}.${member.name}';
			final paths: Array<String> = macros[member.name] ?? [];
			paths.push(info.pkg == '' ? scoped : '${info.pkg}.$scoped');
			macros[member.name] = paths;
		}
		_macros = macros;
	}

	/** `path`'s last dot-separated segment. */
	private static function lastSegment(path: String): String {
		final dot: Int = path.lastIndexOf('.');
		return dot == -1 ? path : path.substr(dot + 1);
	}

}

/**
 * One enclosing call as the macro gate reads it: the target member's simple name, plus
 * the immediate RECEIVER's when the call is written qualified — the last segment of a
 * dotted path (`pkg.Lang.t(…)` gives `Lang`), null for a bare `f(…)`.
 *
 * The receiver is carried because it is the caller's own statement of which TYPE it
 * means, and the gate's second refusal asks whether the index carries that type.
 */
typedef CallRef = {
	final name: String;
	final receiver: Null<String>;
	final qualified: Bool;
};

/**
 * Which enclosing calls forbid re-segmenting their arguments. A `macro` function
 * receives its arguments as unevaluated SYNTAX, and one that pattern-matches a string
 * constant (`EConst(CString)`) sees a concatenation as a different expression
 * altogether — silently, since the match simply stops firing. No structural check can
 * tell whether a given macro folds one, so the default is to refuse the fix and report
 * the construct with the reason.
 *
 * A call target is named in `apqlint.json`'s `concatFoldingMacros` by its QUALIFIED path
 * (`pkg.Type.member`), by any dotted SUFFIX of it (`Type.member`, `member`), and listing
 * it is a claim about that target's implementation — that it folds an `OpAdd` chain of
 * constants before it reads the string. The list comes from the CALLER's own config, so
 * a run spanning several projects honours each one's claim rather than the first file's.
 *
 * TWO refusals, and the second is the one that keeps the gate honest:
 *
 *  - a name some `macro` member declares, unless EVERY such declaration is listed.
 *    Matching is by SIMPLE NAME on purpose: resolving a call target exactly needs the
 *    whole import / static-extension picture, and every gap in that resolution would
 *    open the fix on a macro argument. A same-named ordinary function is refused along
 *    with the macro — a false NEGATIVE, which costs a fix nobody was promised.
 *  - a call whose TARGET TYPE the index does not carry. The index covers the resolution
 *    scope, and that scope is bounded by the INVOCATION: linting one FILE of a project
 *    cannot see a macro declared in another, so reading "no macro declares this name" as
 *    "not a macro" would make `--fix` answer differently depending on how the linter was
 *    called — and the narrow answer is the dangerous one.
 *
 *    The question is asked at TYPE granularity, never by member name: the std alone
 *    declares many members called `t`, so "something declares this name" is true for the
 *    very call the refusal exists for. What the caller's source DOES say is which type it
 *    means — through the import that binds the call (`import pkg.Lang.t`, `import pkg.Lang`,
 *    a wildcard, a `using`) or through a written qualified receiver — and whether the index
 *    carries that type is a question with one answer. A call the file imports nothing for
 *    and writes no receiver on is local, inherited or global, and no import can make it a
 *    macro. A WILDCARD or a `using` whose own target the index cannot see binds every name
 *    in the file, so every unresolved call in it is refused — the honest answer, since such
 *    an import genuinely can route any call into the package it names, and free on a
 *    whole-project run, where the package is in scope.
 */
@:nullSafety(Strict)
final class MacroGate {

	/**
	 * What a finding adds when the callee is a TARGET INTRINSIC — a refusal
	 * `concatFoldingMacros` deliberately does NOT lift, because listing one would be a claim
	 * about the COMPILER's implementation rather than about a target this project owns, and the
	 * claim is false: `untyped __lua__("{x=" + "1}")` compiles with no diagnostic at all and
	 * emits `__lua__(Std.string("{x=") .. Std.string("1}"))`.
	 *
	 * It lives here rather than beside `MACRO_REFUSAL` for the reason `OperatorGate.REFUSAL`
	 * does: the gate that DECIDES a refusal owns the sentence that explains it.
	 */
	public static inline final INTRINSIC_REFUSAL: String = ', but it is an argument of a compiler intrinsic, which matches a '
		+ 'string CONSTANT and stops matching a concatenation — the generator then emits a call to a function no runtime '
		+ 'declares, or rejects the argument outright';

	/**
	 * What a `prefer-interpolation` finding adds when `readsAsSyntax` turned it report-only. That rule rewrites a string
	 * literal INTO another literal, which a macro matching the literal's TEXT (a translation lookup keyed by it) or an
	 * intrinsic emitting it sees as different syntax, so no `concatFoldingMacros` claim lifts it.
	 */
	public static inline final SYNTAX_REFUSAL: String = ', but it is an argument of a macro or compiler intrinsic, which reads '
		+ 'it as syntax — a rewrite there changes what that call sees';

	private final _macros: MacroIndex;
	private final _whitelist: Array<String>;
	private final _file: String;

	/** The grammar's own reading of which bare call NAMES take their arguments as syntax. */
	private final _support: StringFoldSupport;

	public function new(macros: MacroIndex, whitelist: Array<String>, file: String, support: StringFoldSupport) {
		_macros = macros;
		_whitelist = whitelist;
		_file = file;
		_support = support;
	}

	/**
	 * Whether a plan that is not a compile-time `constant` sits inside a call to a TARGET
	 * INTRINSIC — the hole the two refusals below cannot see, because both are questions about
	 * RESOLUTION and an intrinsic
	 * resolves to nothing anywhere: no `macro` member declares it, no import binds it, and the
	 * last line's fall-through then reads "local, inherited or global, and no import can make it
	 * a macro" — true, and beside the point. A gate that passes on an unresolvable callee is
	 * fail-OPEN, and this family never resolves BY CONSTRUCTION.
	 *
	 * Only the BARE spelling is asked about. A written receiver already refuses on its own
	 * evidence (`js.Syntax.code(…)` is `call.qualified`), and requiring the bare form keeps an
	 * ordinary member that happens to carry the affix — a `python`/`lua` magic method called as
	 * `x.__next__(…)` — out of it.
	 *
	 * A plan that is a compile-time CONSTANT is exempt, and the exemption is worth stating exactly
	 * because the sibling `blocks` states a WIDER one: reaching a single PLAIN literal only removes
	 * `+` operators the argument already had, and is the very shape the target wants — but a single
	 * INTERPOLATED literal is no such thing. Haxe desugars `'a$k'` back into a `+` chain before
	 * anything reads the argument as syntax, so `__lua__('local q = $k;')` and
	 * `__lua__("local q = " + k + ";")` emit the identical broken code. Hence
	 * `constant`, which is `PlannedFold`'s answer to that, and not the group COUNT.
	 */
	public function intrinsic(calls: Array<CallRef>, constant: Bool): Bool {
		return !constant && calls.exists(call -> call.receiver == null && !call.qualified && _support.readsArgumentsAsSyntax(call.name));
	}

	/**
	 * Whether ANY call of `calls` reads its arguments as syntax — a macro this gate cannot clear (`blocksCall`, the
	 * whitelist included) or a target intrinsic — whatever the rewrite looks like. The question a rule asks whose every
	 * rewrite changes a literal's text, where `blocks`' one-group exemption does not hold.
	 */
	public function readsAsSyntax(calls: Array<CallRef>): Bool {
		return intrinsic(calls, false) || calls.exists(blocksCall);
	}

	/**
	 * Whether a plan of `groups` groups sitting inside the call stack `calls` must stay
	 * report-only. A plan that renders as ONE group is never refused: it is a lone
	 * literal, the very shape a constant-matching macro expects, and reaching it can only
	 * remove `+` operators the argument already had.
	 */
	public function blocks(calls: Array<CallRef>, groups: Int): Bool {
		return groups >= 2 && calls.exists(call -> blocksCall(call));
	}

	/**
	 * Whether `call` refuses the rewrite — the two refusals in the type doc, in order.
	 *
	 * The whitelist is consulted against every spelling of the target the call site can
	 * supply, because which one exists depends on what the index could resolve: the bare
	 * name, the resolved macro path, the written `Receiver.member`, and the binding
	 * import's path with the member appended.
	 */
	private function blocksCall(call: CallRef): Bool {
		if (whitelisted(call.name)) return false;
		final declarations: Null<Array<String>> = _macros.macroPathsOf(call.name);
		if (declarations != null) {
			return declarations.exists(path -> !whitelisted(path));
		}
		final receiver: Null<String> = call.receiver;
		if (receiver != null && (_macros.declaresType(receiver) || whitelisted('$receiver.${call.name}'))) return false;
		final binding: Null<String> = _macros.unresolvedBinding(_file, receiver ?? call.name);
		// A WRITTEN qualified receiver names a type path directly, so it refuses on its own
		// evidence: `pkg.Lang.t(…)` needs no import at all, and nothing else in the file
		// says where `Lang` lives.
		return binding != null ? !whitelisted('$binding.${call.name}') : call.qualified;
	}

	/**
	 * Whether `path` is listed. Matching is by dotted SUFFIX in BOTH directions, because
	 * the two sides name the same target at different lengths and neither side chooses:
	 * a project writes the fully qualified `pkg.Lang.t`, while what the gate holds is
	 * whatever the CALL SITE said — the resolved `pkg.Lang.t` for a macro the index
	 * carries, the import's `m.Lang`, or a written `Lang.t`. Comparing one direction only
	 * meant the entry that worked depended on the invocation's scope.
	 */
	private function whitelisted(path: String): Bool {
		return _whitelist.exists(entry -> entry == path || entry.endsWith('.$path') || path.endsWith('.$entry'));
	}

	/**
	 * `node`'s call target as the gate reads it — the member's simple name plus the RECEIVER's, when the call is written
	 * qualified. Null when `node` is not a call, or when its callee is an expression rather than a name (the gate has nothing
	 * to ask about a computed target, and such a call cannot be a macro invocation).
	 *
	 * The receiver is carried because the two spellings of the same import bind DIFFERENT names: `import pkg.Lang.t` binds
	 * `t`, `import pkg.Lang` binds `Lang`, and the unresolved-target refusal asks whether the caller's own imports could route
	 * the call somewhere the index cannot see.
	 */
	public static function callOf(
		node: QueryNode, callKind: Null<String>, fieldAccessKind: Null<String>, identKind: String
	): Null<CallRef> {
		if (node.kind != callKind || node.children.length == 0) return null;
		final callee: QueryNode = node.children[0];
		final name: Null<String> = callee.name;
		if (name == null) return null;
		if (callee.kind == identKind) return { name: name, receiver: null, qualified: false };
		if (callee.kind != fieldAccessKind || callee.children.length != 1) return null;
		final receiver: QueryNode = callee.children[0];
		return receiver.kind == identKind || receiver.kind == fieldAccessKind
			? {
				name: name,
				receiver: receiver.name,
				qualified: receiver.kind == fieldAccessKind
			}
			: {
				name: name,
				receiver: null,
				qualified: false
			};
	}

}
