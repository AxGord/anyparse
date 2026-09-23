package anyparse.check;

import anyparse.check.ReflectionScan.ReflectionSurface;
import anyparse.check.ReflectionScan.ScopeFile;
import anyparse.query.CondRegionScan;
import anyparse.query.GrammarPlugin;
import anyparse.query.OccurrenceScan;
import anyparse.query.QueryNode;
import anyparse.query.RawSourceScan;
import anyparse.query.RefactorSupport;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Whether a string spelling a PRIVATE STATIC's name can reach that static by reflection — the question
 * `unused-private`'s string gate asks, answered for statics by where a CLASS VALUE can go.
 *
 * A static is reached reflectively only through a class value: `Reflect.field(instance, 'X')`,
 * `Reflect.getProperty` and `Reflect.fields` on an instance never expose one (eval, js and hxcpp alike),
 * while a SUBCLASS's class value does on eval and on ES6 js. So the string matters only when a class
 * value of the owner, of a subtype, or of an alias of either can reach a reflective member API. One
 * arises from:
 *
 *  - the class NAME in a value position — not a type, not `C.member` (unless `member` is no member of
 *    `C`, which makes it a `using` extension receiving the class), not `new C()`;
 *  - `Type.getClass(e)` / `Type.typeof(e)`: on `this` it yields the enclosing class's chain, on anything
 *    else every class — and inside a macro module every class, since `this` is
 *    reified into the caller;
 *  - `Type.resolveClass(s)` for a non-literal `s`; a literal is judged by the type-path test over every
 *    string in scope, which also covers a library wrapper handed a literal path;
 *  - the js handles `constructor`, `__class__` and `$hxClasses`, which reach an instance's class or the
 *    class registry by name, and a string spelling a class source, which a reflective call reaches;
 *  - a PROJECT macro module that obtains or reifies a class identity (`REIFY_TOKENS`): every type declared
 *    in a file naming it, as a build argument or a call, and every subtype of one;
 *  - `getDefinitionByName` / `getDefinition` with a non-literal name, the library wrappers of `resolveClass`.
 *
 * A value is CONSUMED — goes nowhere reflective — only when handed straight to `Type.getClassName`,
 * `Type.createInstance`, `Type.createEmptyInstance` or `Std.isOfType`, in either the static or the
 * `using` spelling. `Type.getSuperClass` needs no arm: its argument is already a class value this scan
 * accounts for, and its result lies on the same inheritance chain.
 *
 * The scan reads the PROJECT half of the scope (report UNION the declared `resolutionRoots`); a string
 * a library, a macro-using file or a native-code carrier spells keeps the gate closed whatever the scan
 * says, as does any unparseable project file; the raw text of an unparsed `#if` region counts as an escape when
 * it spells a class source or a js handle, and as a reach when it spells the member or a class on its chain.
 *
 * ## Residual
 *
 * Library code — a library build macro reifying the class it builds, or ANY library call returning a
 * `Class` value — that turns a project instance, or a computed name, into a class value — `js.Boot`'s
 * `__class__`, a `Lib.getDefinitionByName(Type.getClassName(...))` round trip — and then applies a name
 * the PROJECT hands it by reflection. The class-name test is by simple name, so a namesake class that
 * declares the member reads as a static access. A project that declares no `resolutionRoots` answers
 * from the report set alone, the residual every name-keyed gate here carries.
 */
@:nullSafety(Strict)
final class StaticReflectionReach {

	/** The receiver the `TYPE_CONSUMERS` and `CLASS_SOURCES` hang off. */
	private static inline final TYPE_RECEIVER: String = 'Type';

	/** The receiver the `STD_CONSUMERS` hang off. */
	private static inline final STD_RECEIVER: String = 'Std';

	/** The receiver whose class a `getClass` / `typeof` call on it is bounded by. */
	private static inline final THIS: String = 'this';

	/** The word that marks a file whose strings may be macro-reified into identifiers. */
	private static inline final MACRO_WORD: String = 'macro';

	/** A file's own `using Std;` — what makes a receiver-less `x.isOfType(v)` the `Std` one. */
	private static final USING_STD: EReg = ~/\busing\s+Std\s*;/;

	/** The `Type` functions that turn an INSTANCE into a class value. */
	private static final CLASS_SOURCES: Array<String> = ['getClass', 'typeof'];

	/**
	 * The functions that turn a NAME into a class value — `Type.resolveClass` and the `getDefinitionByName` /
	 * `getDefinition` wrappers of it a library (OpenFL, Flash) ships. A literal name is judged by the
	 * type-path test instead.
	 */
	private static final NAME_SOURCES: Array<String> = ['resolveClass', 'getDefinitionByName', 'getDefinition'];

	/**
	 * The macro-API spellings through which a macro obtains or builds a CLASS identity — the local class,
	 * a looked-up type, or a reified path. A project macro module spelling one may hand the class it is
	 * built on, or called from, to code no text here holds.
	 */
	private static final REIFY_TOKENS: Array<String> = ['getLocalClass', 'getLocalType', 'getType', 'TInst', '$$p{', '$$i{', 'TPath'];

	/** The `Type` members that consume a class value, taken as their FIRST argument, without reflecting on it. */
	private static final TYPE_CONSUMERS: Array<String> = ['getClassName', 'createInstance', 'createEmptyInstance'];

	/** The `Std` members that consume a class value, taken as their SECOND argument, without reflecting on it. */
	private static final STD_CONSUMERS: Array<String> = ['isOfType', 'is'];

	/** The names through which js code reaches an instance's class or the class registry. */
	private static final JS_CLASS_HANDLES: Array<String> = ['constructor', '__class__', '$$hxClasses'];

	/** Whether some project site yields a class value of ANY class. */
	private final _escapesAll: Bool;

	/** The classes a `getClass(this)` / `typeof(this)` inside them hands out — each one's whole chain escapes. */
	private final _thisOwners: Array<String>;

	/** Every name read in a value position the scan does not see consumed, with its occurrence count. */
	private final _values: Map<String, Int>;

	/** Every `receiver.member` access in the project: the receiver, spelled as a name, to the members it is read with. */
	private final _receivers: Map<String, Array<String>>;

	/**
	 * The types a class-reifying project macro may hand out a class value of: those declared in a file
	 * that names such a macro module — as a `@:build` / `@:autoBuild` argument or as a call.
	 */
	private final _reified: Array<String>;

	/** Every `typedef` / `import … as` alias in the project, with the simple name it stands for. */
	private final _aliases: Array<{ alias: String, target: String }>;

	/** The raw text of every unparsed `#if` region in the project, which no node walk sees. */
	private final _opaque: Array<String>;

	/** The string contents that keep the gate closed for any name they spell. */
	private final _veto: Array<String>;

	/** The whole-scope reflection surface, for the type-path test and the unreadable-file test. */
	private final _surface: ReflectionSurface;

	private function new(state: ScanState, veto: Array<String>, surface: ReflectionSurface) {
		_escapesAll = state.escapesAll;
		_thisOwners = state.thisOwners;
		_values = state.values;
		_receivers = state.receivers;
		_aliases = state.aliases;
		_reified = state.reified;
		_opaque = state.opaque;
		_veto = veto;
		_surface = surface;
	}

	/**
	 * Whether a string spelling `name` may reach the private static `name` of the class `owner`
	 * declared in `ownerFile`, with `index` resolving the owner's subtypes.
	 */
	public function staticReachable(owner: String, ownerFile: String, name: String, index: SymbolIndex): Bool {
		if (_escapesAll) return true;
		if (_veto.exists(c -> OccurrenceScan.referencedInRange(c, name, 0, c.length, []))) return true;
		if (_surface.unreadable.exists(source -> RawSourceScan.mentionsWord(source, name))) return true;
		final chain: Array<String> = chainOf(owner, ownerFile, index);
		// An unparsed `#if` region is bytes, not nodes: any mention of the member or of a class on the
		// chain there may be the reflective use the walk could not see.
		if (_opaque.exists(text -> RawSourceScan.mentionsWord(text, name) || chain.exists(k -> RawSourceScan.mentionsWord(text, k))))
			return true;
		for (k in chain) {
			if (_values.exists(k)) return true;
			if (ReflectionScan.runtimeTypePath(_surface.whole, k) || ReflectionScan.runtimeTypePathFragment(_surface.fragments, k))
				return true;
			if ((_receivers[k] ?? []).exists(member -> !index.members.typeDeclaresMember(k, member))) return true;
		}
		// A class-reifying macro yields the class it is built on (an `@:autoBuild` one: every subtype too)
		// or called from, so a type on the chain, or an ancestor the owner inherits the build from, escapes.
		final reified: (String) -> Bool = k -> chain.contains(k) || index.subtypes.subtypeNames(k).contains(owner);
		return _reified.exists(reified) || _thisOwners.exists(reified);
	}

	/** `owner`, every subtype of it, and every alias of any of those, to a fixed point. */
	private function chainOf(owner: String, ownerFile: String, index: SymbolIndex): Array<String> {
		final chain: Array<String> = [owner];
		for (sub in index.subtypes.subtypeNames(owner, ownerFile)) if (!chain.contains(sub)) chain.push(sub);
		var i: Int = 0;
		while (i < chain.length) {
			final target: String = chain[i++];
			for (a in _aliases) if (a.target == target && !chain.contains(a.alias)) chain.push(a.alias);
		}
		return chain;
	}

	/**
	 * Scan the project half of the scope `files` belongs to; `surface` is the whole-scope reflection
	 * surface the caller already holds. Null when the grammar exposes no call / field-access kind or
	 * no string fold, which leaves every string gate closed.
	 */
	public static function build(files: Array<ScopeFile>, plugin: GrammarPlugin, surface: ReflectionSurface): Null<StaticReflectionReach> {
		final shape: RefShape = plugin.refShape();
		final foldOrNull: Null<StringFoldSupport> = plugin.stringFoldSupport();
		final callOrNull: Null<String> = shape.callKind;
		final fieldOrNull: Null<String> = shape.fieldAccessKind;
		if (foldOrNull == null || callOrNull == null || fieldOrNull == null) return null;
		final fold: StringFoldSupport = foldOrNull;
		final callKind: String = callOrNull;
		final fieldKind: String = fieldOrNull;
		final state: ScanState = {
			escapesAll: false,
			thisOwners: [],
			values: [],
			receivers: [],
			aliases: [],
			reified: [],
			relaxable: [],
			opaque: []
		};
		final scanned: Array<FileScan> = [];
		for (entry in projectFiles(files, plugin)) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) {
				state.escapesAll = true;
				break;
			}
			for (region in CondRegionScan.opaqueCondRegions(tree, entry.source, shape)) for (gap in region.gaps)
				state.opaque.push(entry.source.substring(gap.from, gap.to));
			final scan: FileScan = {
				source: entry.source,
				shape: shape,
				fold: fold,
				callKind: callKind,
				fieldKind: fieldKind,
				macroFile: RawSourceScan.mentionsWord(entry.source, MACRO_WORD),
				usingStd: USING_STD.match(entry.source),
				declared: []
			};
			walk(tree, [], null, false, scan, state);
			scanned.push(scan);
		}
		noteReified(scanned, state);
		final handles: Array<String> = CLASS_SOURCES.concat(NAME_SOURCES).concat(JS_CLASS_HANDLES);
		if (state.opaque.exists(text -> handles.exists(h -> RawSourceScan.mentionsWord(text, h)))) state.escapesAll = true;
		return new StaticReflectionReach(state, vetoOf(surface.whole, state.relaxable), surface);
	}

	/** Whether `node` is the callee of the call `parent`. */
	private static inline function isCallee(node: QueryNode, parent: Null<QueryNode>, scan: FileScan): Bool {
		return parent != null && parent.kind == scan.callKind && parent.children[0] == node;
	}

	/**
	 * Record in `state.reified` every type declared in a file that NAMES a class-reifying project macro
	 * module — one whose file spells `macro` and a `REIFY_TOKENS` spelling. Naming covers both ways the
	 * macro reaches a class: as a `@:build` / `@:autoBuild` argument, where it is built on that class, and
	 * as a call, where the local class is the caller's. File-scoped and by word, so it over-approximates.
	 */
	private static function noteReified(scanned: Array<FileScan>, state: ScanState): Void {
		final modules: Array<String> = [];
		for (scan in scanned)
			if (scan.macroFile && REIFY_TOKENS.exists(t -> scan.source.indexOf(t) >= 0))
				for (name in scan.declared)
					if (!modules.contains(name)) modules.push(name);
		for (scan in scanned)
			if (modules.exists(m -> !scan.declared.contains(m) && RawSourceScan.mentionsWord(scan.source, m)))
				for (name in scan.declared)
					if (!state.reified.contains(name)) state.reified.push(name);
	}

	/** `files` UNION the declared project roots, deduped by path. */
	private static function projectFiles(files: Array<ScopeFile>, plugin: GrammarPlugin): Array<ScopeFile> {
		final byPath: Map<String, ScopeFile> = [];
		final out: Array<ScopeFile> = [];
		for (entry in files.concat(RefactorSupport.resolutionProjectSourcesOf(plugin) ?? [])) if (!byPath.exists(entry.file)) {
			byPath[entry.file] = entry;
			out.push(entry);
		}
		return out;
	}

	/** `whole` minus one copy of each `relaxable` content — the strings no project scan vouches for. */
	private static function vetoOf(whole: Array<String>, relaxable: Array<String>): Array<String> {
		final pending: Map<String, Int> = [];
		for (c in relaxable) pending[c] = (pending[c] ?? 0) + 1;
		final out: Array<String> = [];
		for (c in whole) {
			final left: Int = pending[c] ?? 0;
			if (left > 0)
				pending[c] = left - 1;
			else
				out.push(c);
		}
		return out;
	}

	/**
	 * Record what `node` contributes, then descend. `path` holds its ancestors, nearest last; `owner`
	 * is the enclosing class; `inCarrier` whether a native-code carrier encloses it.
	 */
	private static function walk(
		node: QueryNode, path: Array<QueryNode>, owner: Null<String>, inCarrier: Bool, scan: FileScan, state: ScanState
	): Void {
		final kind: String = node.kind;
		final name: Null<String> = node.name;
		final here: Null<String> = CheckScan.isClassBodyKind(kind) ? name : owner;
		if (name != null && (scan.shape.typeDeclKinds ?? []).contains(kind)) scan.declared.push(name);
		final literal: Null<StringLiteral> = scan.fold.literalOf(node, scan.source);
		if (literal != null)
			noteString(literal.content, inCarrier, scan, state);
		else if (name != null && (kind == scan.shape.identKind || kind == scan.fieldKind))
			noteName(node, name, path, here, scan, state);
		else if (name != null)
			noteAlias(node, name, scan, state);
		final carrier: Bool = inCarrier || NativeCodeScan.isCarrier(node, scan.shape, scan.fold);
		path.push(node);
		for (child in node.children) walk(child, path, here, carrier, scan, state);
		path.pop();
	}

	/**
	 * A string literal: a js class handle, or the name of a class source (a reflective call of `Type.getClass`),
	 * opens every class; outside a macro file and a carrier it is vouched for.
	 */
	private static function noteString(content: String, inCarrier: Bool, scan: FileScan, state: ScanState): Void {
		final named: Bool = JS_CLASS_HANDLES.contains(content) || CLASS_SOURCES.contains(content) || NAME_SOURCES.contains(content);
		if (named || inCarrier && JS_CLASS_HANDLES.exists(h -> RawSourceScan.mentionsWord(content, h))) state.escapesAll = true;
		if (!inCarrier && !scan.macroFile) state.relaxable.push(content);
	}

	/** An identifier or a field access named `name`, with its ancestors `path` and enclosing class `owner`. */
	private static function noteName(
		node: QueryNode, name: String, path: Array<QueryNode>, owner: Null<String>, scan: FileScan, state: ScanState
	): Void {
		final parent: Null<QueryNode> = path.length > 0 ? path[path.length - 1] : null;
		if (JS_CLASS_HANDLES.contains(name)) {
			state.escapesAll = true;
			return;
		}
		if (CLASS_SOURCES.contains(name) || NAME_SOURCES.contains(name)) {
			noteClassSource(node, name, path, owner, scan, state);
			return;
		}
		if (consumed(node, path, path.length - 1, scan)) return;
		if (parent != null && parent.kind == scan.fieldKind && parent.children[0] == node) {
			final member: Null<String> = parent.name;
			final members: Array<String> = state.receivers[name] ?? [];
			if (member != null && !members.contains(member)) members.push(member);
			state.receivers[name] = members;
			return;
		}
		state.values[name] = (state.values[name] ?? 0) + 1;
	}

	/**
	 * A reference to one of the `CLASS_SOURCES`: a direct call is judged
	 * by its argument and its consumer; any other use opens every class.
	 */
	private static function noteClassSource(
		node: QueryNode, name: String, path: Array<QueryNode>, owner: Null<String>, scan: FileScan, state: ScanState
	): Void {
		final parent: Null<QueryNode> = path.length > 0 ? path[path.length - 1] : null;
		if (parent == null || !isCallee(node, parent, scan)) {
			// A field access NAMED like a source but not called through: a `Type.getClass` value, or
			// an unrelated member that happens to share the name — both are read as an escape.
			state.escapesAll = true;
			return;
		}
		if (consumed(parent, path, path.length - 2, scan)) return;
		final receiver: Null<QueryNode> = node.kind == scan.fieldKind && node.children.length > 0 ? node.children[0] : null;
		final arg: Null<QueryNode> = if (receiver != null && receiver.name != TYPE_RECEIVER)
			receiver
		else if (parent.children.length > 1)
			parent.children[1]
		else
			null;
		if (NAME_SOURCES.contains(name)) {
			if (arg == null || scan.fold.literalOf(arg, scan.source) == null) state.escapesAll = true;
		} else if (arg != null && arg.name == THIS && arg.kind == scan.shape.identKind && owner != null && !scan.macroFile) {
			// Inside a macro module `this` is reified into whatever class CALLS the macro, not `owner`.
			state.thisOwners.push(owner);
		} else {
			state.escapesAll = true;
		}
	}

	/** A `typedef A = C` or an `import p.C as A` — the alias and the simple name it stands for, read off its text. */
	private static function noteAlias(node: QueryNode, name: String, scan: FileScan, state: ScanState): Void {
		final span: Null<Span> = node.span;
		if (span == null) return;
		final text: String = scan.source.substring(span.from, span.to);
		final target: Null<String> = if ((scan.shape.aliasingDeclKinds ?? []).contains(node.kind))
			aliasTarget(text, text.indexOf('=') + 1)
		else if ((scan.shape.importAliasKinds ?? []).contains(node.kind))
			importTarget(text)
		else
			null;
		if (target != null) state.aliases.push({ alias: name, target: target });
	}

	/** The last dot-segment of the type path that starts at `from` in `text`, or null when none does (a structure). */
	private static function aliasTarget(text: String, from: Int): Null<String> {
		final re: EReg = ~/^\s*([A-Za-z_][A-Za-z0-9_.]*)/;
		return from > 0 && re.match(text.substr(from)) ? CheckScan.simpleModuleName(re.matched(1)) : null;
	}

	/** The simple name an `import p.C as A` / `import p.C in A` binds, or null. */
	private static function importTarget(text: String): Null<String> {
		final re: EReg = ~/^\s*import\s+([A-Za-z_][A-Za-z0-9_.]*)\s+(as|in)\s/;
		return re.match(text) ? CheckScan.simpleModuleName(re.matched(1)) : null;
	}

	/**
	 * Whether the value `node`, whose parent sits at `path[at]`, is handed straight to a whitelisted
	 * consumer: `Type.getClassName(v)` / `Type.createInstance(v, …)` / `Type.createEmptyInstance(v)`,
	 * `Std.isOfType(x, v)`, or the `using` spellings `v.getClassName()` / `x.isOfType(v)`.
	 */
	private static function consumed(node: QueryNode, path: Array<QueryNode>, at: Int, scan: FileScan): Bool {
		if (at < 0) return false;
		final parent: QueryNode = path[at];
		if (parent.kind == scan.fieldKind && parent.children[0] == node) {
			final call: Null<QueryNode> = at > 0 ? path[at - 1] : null;
			final member: Null<String> = parent.name;
			return member != null && TYPE_CONSUMERS.contains(member) && isCallee(parent, call, scan);
		}
		if (parent.kind != scan.callKind) return false;
		final callee: QueryNode = parent.children[0];
		final member: Null<String> = callee.name;
		if (callee.kind != scan.fieldKind || member == null || callee.children.length == 0) return false;
		final slot: Int = parent.children.indexOf(node);
		final receiver: Null<String> = callee.children[0].name;
		if (receiver == TYPE_RECEIVER) return TYPE_CONSUMERS.contains(member) && slot == 1;
		// The receiver-less `x.isOfType(v)` is `Std`'s only under a `using Std` the file itself spells.
		return STD_CONSUMERS.contains(member) && (receiver == STD_RECEIVER ? slot == 2 : scan.usingStd && slot == 1);
	}

}

/** The per-file facts `walk` reads. */
private typedef FileScan = {

	/** The file's source. */
	final source: String;

	/** The grammar's reference shape. */
	final shape: RefShape;

	/** The grammar's string fold. */
	final fold: StringFoldSupport;

	/** The grammar's call kind. */
	final callKind: String;

	/** The grammar's field-access kind. */
	final fieldKind: String;

	/** Whether the file spells `macro`, so its strings may become identifiers at compile time. */
	final macroFile: Bool;

	/** Whether the file spells `using Std;`. */
	final usingStd: Bool;

	/** The names of the types the file declares, filled by the walk. */
	final declared: Array<String>;

};

/** What the project scan has gathered so far. */
private typedef ScanState = {

	/** Whether some site yields a class value of any class. */
	var escapesAll: Bool;

	/** The classes whose `getClass(this)` escapes. */
	final thisOwners: Array<String>;

	/** The names read in an unconsumed value position, with their counts. */
	final values: Map<String, Int>;

	/** Every receiver name, to the members it is read with. */
	final receivers: Map<String, Array<String>>;

	/** The types a class-reifying project macro may hand out. */
	final reified: Array<String>;

	/** Every alias and its target. */
	final aliases: Array<{ alias: String, target: String }>;

	/** The string contents a project file spells outside a macro file and a native-code carrier. */
	final relaxable: Array<String>;

	/** The raw text of every unparsed `#if` region. */
	final opaque: Array<String>;

};
