package anyparse.check.haxe.expressions;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.CrossFileEdits;
import anyparse.check.Check.CrossFileFix;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.OptionKeyed;
import anyparse.check.haxe.expressions.CompareFunctions.ConfigProblem;
import anyparse.check.haxe.expressions.CompareFunctions.NamedCompare;
import anyparse.check.haxe.expressions.SortComparatorWalk.SortKinds;
import anyparse.query.AddMember;
import anyparse.query.MemberEdit;
import anyparse.query.ParseGate;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeRefPrinter;
import anyparse.query.TypingService;

using StringTools;
using anyparse.util.Groups;

/** The node kinds the rule reads. */
private typedef Seams = {
	final sort: SortKinds;
	final identKind: String;
	final fieldAccessKind: String;
	final callKind: String;
	final blockKinds: Array<String>;
	final returnKinds: Array<String>;
	final binderKinds: Array<String>;
	final hostKinds: Array<String>;
	final intType: String;
	final compareTypes: Array<String>;
	final nullableWrapper: Null<String>;
	final upperTypes: Bool;
	final elementParams: Map<String, Int>;
}

/** One key of a key comparator: the expression the one-parameter key lambda over `param` returns, and its direction. */
private typedef Key = { final param: String; final key: QueryNode; final ascending: Bool; }

/** A sort callback read for its identity: `canonical` is equal for two callbacks that differ only in parameter names. */
private typedef Callback = {
	final canonical: String;
	final params: Array<String>;
	final body: QueryNode;
	final value: Null<QueryNode>;
	final keys: Null<Array<Key>>;
	final keyedName: Null<String>;
	final named: Null<NamedCompare>;
	final typeNames: Array<String>;
}

/** One sort callback whose element type resolved. */
private typedef Site = {
	final file: String;
	final source: String;
	final tree: QueryNode;
	final span: Span;
	final callback: Callback;
	final element: String;
	final declared: Null<ResolvedType>;
	final ordered: Bool;
	final options: Options;
}

/** The type that receives the extracted static, with the module path a reference from another module imports. */
private typedef Host = {
	final file: String;
	final source: String;
	final tree: QueryNode;
	final type: TypeDeclInfo;
	final path: String;
}

/** The fix of one group, or why it has none. */
private typedef Plan = {
	final name: Null<String>;
	final slices: Array<CrossFileEdits>;
	final noFix: Null<String>;
	final sites: Array<Site>;
}

/** What the rule's options name for one file: the key compare functions, the `asc` / `desc` macros, and what is wrong with them. */
private typedef Options = {
	final compares: Array<NamedCompare>;
	final asc: Null<NamedCompare>;
	final desc: Null<NamedCompare>;
	final problems: Array<String>;
}

/**
	The one answer to "which sort callbacks are the same comparator": the same body up to parameter names, on the same
	resolved element type, at two or more `sort` calls. Each site is reported, and the fix extracts ONE named static and
	passes it by reference at every site, atomically across files through `CrossFileFix`. A callback that reads a name
	its own parameters and locals do not bind is left alone, as a static cannot capture it, and so is a site whose element
	type does not resolve to one nameable type (counted in a config note). A key comparator — a call of the `asc` / `desc`
	macro the `keyed` option names, or a lambda returning the compare function the `compare` option names for one key — is
	extracted in the macro form when its keys are proved orderable, and two of them with the same keys are one comparator.
	Without the options nothing is a key comparator. `Severity.Info`, default OFF.

	The static goes on the element type when the scope declares it as a public class or abstract, else on the type of the
	module holding most sites that encloses most of them; a group whose sites span packages without such an element type
	is reported with no fix, as is a name the host already declares.
**/
@:nullSafety(Strict)
final class DuplicateComparator extends HaxeRule implements DefaultOff implements CrossFileFix implements ConfigAware implements OptionKeyed {

	private static inline final RULE_ID: String = 'duplicate-comparator';

	/** The option naming the compare function of each key type, read through `CompareFunctions` as prefer-compare-function's is. */
	private static final OPTION_COMPARE: String = 'compare';

	/** The option naming the `asc` and `desc` macros that build a comparator from key lambdas. */
	private static final OPTION_KEYED: String = 'keyed';

	private static final ASC: String = 'asc';
	private static final DESC: String = 'desc';

	/** Stand for the first and the second comparator parameter in a canonical body. */
	private static final FIRST: String = '\u0001';

	private static final SECOND: String = '\u0002';
	private static final NAME_PREFIX: String = 'by';
	private static final DESC_SUFFIX: String = 'Desc';
	private static final THEN: String = 'Then';
	private static final UNRESOLVED_NOTE: String = 'duplicate-comparator.unresolved';

	/** The plan of each reported site, keyed `file:from`; one plan is shared by the sites of its group. */
	private final _plans: Map<String, Plan> = [];

	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(RULE_ID, 'the same comparator lambda at two or more sort calls on one element type', RuleCategory.Expressions);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		_plans.clear();
		final s: Null<Seams> = readSeams(plugin);
		if (s == null) return [];
		final index: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		final groups: Map<String, Array<Site>> = [];
		final order: Array<String> = [];
		final problems: Array<ConfigProblem> = [];
		var unresolved: Int = 0;
		for (entry in files) {
			final options: Options = optionsOf(entry.file, s, plugin, index);
			final enabled: Bool = Linter.enabledBy(LintConfig.resolveWith(_resolveConfig, entry.file), this);
			for (problem in options.problems) CompareFunctions.anchorProblem(problems, problem, entry.file, enabled);
			// A broken name stops the rule on the files it governs: a fix would otherwise call another function than the project named.
			if (options.problems.length > 0) continue;
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, entry.source);
			if (tree != null) unresolved += collect(entry, tree, s, plugin, index, options, groups, order);
		}
		if (unresolved > 0)
			ConfigNotes.into(
				_configNotes,
				notes ->
					ConfigNotes.note(
						notes, UNRESOLVED_NOTE,
						'apq: $RULE_ID: $unresolved sort callback(s) left alone, their element type does not resolve to one nameable type\n'
					)
			);
		final out: Array<Violation> = [];
		final taken: Map<String, Bool> = [];
		final inRun: Map<String, Bool> = [ for (entry in files) entry.file => true ];
		for (key in order) {
			final sites: Array<Site> = groups[key] ?? [];
			if (sites.length < 2) continue;
			final plan: Plan = planOf(sites, s, plugin, index(), taken, inRun);
			final named: String = plan.name == null ? 'one named static' : 'one named static ${plan.name}';
			final noFix: String = plan.noFix == null ? '' : '; no fix, ${plan.noFix}';
			final others: Int = sites.length - 1;
			for (site in sites) {
				_plans['${site.file}:${site.span.from}'] = plan;
				out.push({
					file: site.file,
					span: site.span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: 'the same comparator as $others other sort call(s) on ${site.element}: $named passed by reference$noFix',
					declineReason: plan.noFix
				});
			}
		}
		for (problem in problems) out.push({
			file: problem.file,
			span: null,
			rule: RULE_ID,
			severity: Severity.Error,
			message: problem.message
		});
		return out;
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

	/** One atomic group per comparator, offered only when the run handed back every site of it. */
	public function crossFileFix(
		files: Array<{ file: String, source: String }>, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<Array<CrossFileEdits>> {
		final handed: Map<String, Bool> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) handed['${v.file}:${span.from}'] = true;
		}
		final out: Array<Array<CrossFileEdits>> = [];
		final offered: Array<Plan> = [];
		for (key in handed.keys()) {
			final plan: Null<Plan> = _plans[key];
			if (plan == null || plan.noFix != null || offered.contains(plan)) continue;
			offered.push(plan);
			// A site the run did not hand back (a suppressed one) keeps its lambda, and then so does every other site.
			if (plan.sites.exists(site -> !handed.exists('${site.file}:${site.span.from}'))) continue;
			out.push(plan.slices);
		}
		return out;
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function acceptedOptions(): Array<String> {
		return [OPTION_COMPARE, OPTION_KEYED];
	}

	/** The options the config chain of `file` sets, each path resolved against the index; a broken one is a problem. */
	private function optionsOf(file: String, s: Seams, plugin: GrammarPlugin, index: () -> Null<SymbolIndex>): Options {
		final config: LintConfig = LintConfig.resolveWith(_resolveConfig, file);
		final compare: CompareFunctions = new CompareFunctions(
			config.jsonOption(RULE_ID, OPTION_COMPARE), OPTION_COMPARE, s.compareTypes, s.intType, s.nullableWrapper, plugin.typeSyntax,
			index
		);
		final problems: Array<String> = compare.problems.copy();
		final macros: Map<String, NamedCompare> = CompareFunctions.macrosOf(
			config.jsonOption(RULE_ID, OPTION_KEYED), OPTION_KEYED, [ASC, DESC], index, problems
		);
		final compares: Array<NamedCompare> = [];
		for (type in s.compareTypes) {
			final named: Null<NamedCompare> = compare.of(type);
			if (named != null) compares.push(named);
		}
		return {
			compares: compares,
			asc: macros[ASC],
			desc: macros[DESC],
			problems: problems
		};
	}

	private static inline function inside(site: Site, host: Host): Bool {
		return site.file == host.file && host.type.span.from <= site.span.from && site.span.to <= host.type.span.to;
	}

	/** Adds every comparator site of `tree` to `groups`; answers how many were left alone for an unresolved element type. */
	private static function collect(
		entry: { file: String, source: String }, tree: QueryNode, s: Seams, plugin: GrammarPlugin, index: () -> Null<SymbolIndex>,
		options: Options, groups: Map<String, Array<Site>>, order: Array<String>
	): Int {
		final calls: Array<{ callee: QueryNode, arg: QueryNode }> = [];
		SortComparatorWalk.each(tree, s.sort, (callee, arg) -> calls.push({ callee: callee, arg: arg }));
		if (calls.length == 0) return 0;
		final idx: Null<SymbolIndex> = index();
		final imports: Map<String, String> = RunScan.typeInfoOf(plugin)?.importMap(entry.source, entry.file) ?? [];
		final written: Null<(QueryNode) -> Null<String>> = CheckScan.typeSourceResolver(entry.source, plugin, tree, entry.file, idx);
		final typeParams: Map<String, Array<Span>> = TypeRefPrinter.typeParamScopesOf(entry.source, tree, plugin);
		var unresolved: Int = 0;
		for (call in calls) {
			final at: Null<Span> = call.arg.span;
			final receiver: Null<QueryNode> = call.callee.children[0];
			final read: Null<Callback> = callbackOf(call.arg, s, imports, options);
			if (at == null || receiver == null || read == null) continue;
			final span: Span = at;
			final callback: Callback = read;
			final source: Null<String> = written == null ? null : written(receiver);
			final typed: Null<String> = source == null
				? null
				: NominalTypes.elementTypeSourceOf(source, s.elementParams, [], plugin.typeSyntax);
			if (typed == null || isTypeParameter(typed, span, typeParams, plugin)) {
				unresolved++;
				continue;
			}
			final element: String = typed;
			final found: Array<ResolvedType> = idx == null ? [] : idx.resolveTypeRefsFrom(element, entry.file, span.from);
			final declared: Null<ResolvedType> = found.length == 1 ? found[0] : null;
			final key: String = '${declared == null ? element : SymbolIndex.typePath(declared)}\n${callback.canonical}';
			final keys: Null<Array<Key>> = callback.keys;
			if (!groups.exists(key)) order.push(key);
			final site: Site = {
				file: entry.file,
				source: entry.source,
				tree: tree,
				span: span,
				callback: callback,
				element: element,
				declared: declared,
				ordered: keys != null && (callback.value == null || orderedKeys(keys, element, entry.file, idx, s)),
				options: options
			};
			groups.push(key, site);
		}
		return unresolved;
	}

	/** Whether `element` names a type parameter in scope at `span`, which a static outside that scope cannot name. */
	private static function isTypeParameter(element: String, span: Span, scopes: Map<String, Array<Span>>, plugin: GrammarPlugin): Bool {
		final outer: Null<String> = NominalTypes.outerNominalOf(element, plugin.typeSyntax);
		final owned: Null<Array<Span>> = outer == null ? null : scopes[outer];
		return owned != null && owned.exists(scope -> scope.from <= span.from && span.to <= scope.to);
	}

	/**
	 * The identity of a sort argument that is a non-capturing comparator
	 * lambda or a call of a configured key macro; null for anything else.
	 */
	private static function callbackOf(arg: QueryNode, s: Seams, imports: Map<String, String>, options: Options): Null<Callback> {
		final typeNames: Array<String> = [];
		final bound: Array<String> = [];
		bindersIn(arg, s, bound);
		if (!readsOnly(arg, bound, s, typeNames)) return null;
		if (SortComparatorWalk.isComparator(arg, s.sort)) return lambdaOf(arg, s, imports, typeNames, options.compares);
		final callee: Null<QueryNode> = arg.children[0];
		final macros: Array<NamedCompare> = [ for (named in [options.asc, options.desc]) if (named != null) named ];
		final named: Null<NamedCompare> = arg.kind != s.callKind || callee == null ? null : namedAt(callee, macros, s, imports);
		if (callee == null || named == null) return null;
		final keys: Null<Array<Key>> = keysOfCall(arg, named == options.asc, s);
		final marks: Map<String, String> = [ for (name in bound) name => FIRST ];
		return {
			canonical: keys == null ? 'call:${shapeOf(arg, marks, s)}' : keyCanonical(keys, s),
			params: [],
			body: arg,
			value: null,
			keys: keys,
			keyedName: callee.children[0]?.name,
			named: named,
			typeNames: typeNames
		};
	}

	/**
	 * A two-parameter lambda read for its identity; a body returning one
	 * of the configured compare functions of one key is read as that key.
	 */
	private static function lambdaOf(
		fn: QueryNode, s: Seams, imports: Map<String, String>, typeNames: Array<String>, compares: Array<NamedCompare>
	): Null<Callback> {
		final params: Array<String> = [ for (c in fn.children) if (s.sort.paramKinds.contains(c.kind)) c.name ?? '' ];
		final body: Null<QueryNode> = fn.children[fn.children.length - 1];
		if (body == null || s.sort.paramKinds.contains(body.kind) || params.contains('')) return null;
		final value: Null<QueryNode> = returned(body, s);
		final callee: Null<QueryNode> = value?.children[0];
		final named: Null<NamedCompare> = value != null && value.kind == s.callKind && value.children.length == 3 && callee != null
			? namedAt(callee, compares, s, imports)
			: null;
		final key: Null<Key> = value == null || named == null ? null : keyOfPair(value.children[1], value.children[2], params, s);
		final keys: Null<Array<Key>> = key == null ? null : [key];
		return {
			canonical: keys == null ? 'fn:${shapeOf(value ?? body, [params[0] => FIRST, params[1] => SECOND], s)}' : keyCanonical(keys, s),
			params: params,
			body: body,
			value: value,
			keys: keys,
			keyedName: keys == null ? null : callee?.children[0]?.name,
			named: keys == null ? null : named,
			typeNames: typeNames
		};
	}

	/** The one expression a callback body returns, or null for a body of more statements than one `return`. */
	private static function returned(body: QueryNode, s: Seams): Null<QueryNode> {
		final only: Null<QueryNode> = body.children.length == 1 ? body.children[0] : null;
		if (s.returnKinds.contains(body.kind)) return only;
		if (!s.blockKinds.contains(body.kind)) return body;
		return only != null && s.returnKinds.contains(only.kind) && only.children.length == 1 ? only.children[0] : null;
	}

	/**
	 * The function of `named` that `callee` calls as `<T>.<member>`, `<T>`
	 * naming its type through the file's imports; null for any other callee.
	 */
	private static function namedAt(
		callee: QueryNode, named: Array<NamedCompare>, s: Seams, imports: Map<String, String>
	): Null<NamedCompare> {
		final receiver: Null<QueryNode> = callee.children[0];
		final type: Null<String> = receiver?.name;
		if (callee.kind != s.fieldAccessKind || receiver == null || receiver.kind != s.identKind || type == null) return null;
		final path: Null<String> = imports[type];
		return named.find(n -> n.member == callee.name && n.typePath == path);
	}

	/**
	 * Whether each key is a field path of its parameter whose member, read on `element` from `file`, is declared as one of the
	 * types a key macro orders: a `Null<…>` or optional key, an alias or an abstract stays a static function, as the macro refuses it.
	 */
	private static function orderedKeys(keys: Array<Key>, element: String, file: String, index: Null<SymbolIndex>, s: Seams): Bool {
		if (index == null) return false;
		final idx: SymbolIndex = index;
		return keys.foreach(k -> {
			final path: Null<Array<String>> = fieldPath(k, s);
			final type: Null<String> = path == null ? null : idx.paths.resolveGenericPathFinalMemberTypeSource(file, element, path);
			type != null && s.compareTypes.contains(type);
		});
	}

	/** The fields a key reads off its parameter, outermost first (`r.span.from` is `[span, from]`); null for any other key. */
	private static function fieldPath(key: Key, s: Seams): Null<Array<String>> {
		final path: Array<String> = [];
		var node: QueryNode = key.key;
		while (node.kind == s.fieldAccessKind) {
			final name: Null<String> = node.name;
			final inner: Null<QueryNode> = node.children[0];
			if (name == null || inner == null) return null;
			path.unshift(name);
			node = inner;
		}
		return node.kind == s.identKind && node.name == key.param && path.length > 0 ? path : null;
	}

	/** The keys of an `asc` / `desc` call whose every argument is a one-parameter key lambda; null for any other argument. */
	private static function keysOfCall(call: QueryNode, ascending: Bool, s: Seams): Null<Array<Key>> {
		final keys: Array<Key> = [];
		for (arg in call.children.slice(1)) {
			final params: Array<QueryNode> = arg.children.filter(c -> s.sort.paramKinds.contains(c.kind));
			final param: Null<String> = params.length == 1 ? params[0].name : null;
			final body: Null<QueryNode> = arg.children[arg.children.length - 1];
			if (!s.sort.lambdaKinds.contains(arg.kind) || param == null || body == null || s.blockKinds.contains(body.kind)) return null;
			final named: String = param;
			final read: QueryNode = body;
			final key: Key = { param: named, key: read, ascending: ascending };
			keys.push(key);
		}
		return keys.length == 0 ? null : keys;
	}

	/** The key two operands compare: the same expression over the first parameter and over the second (ascending), or swapped. */
	private static function keyOfPair(x: QueryNode, y: QueryNode, params: Array<String>, s: Seams): Null<Key> {
		final marks: Map<String, String> = [params[0] => FIRST, params[1] => SECOND];
		final left: String = shapeOf(x, marks, s);
		final right: String = shapeOf(y, marks, s);
		return if (left.contains(FIRST) && !left.contains(SECOND) && right == left.replace(FIRST, SECOND))
			{ param: params[0], key: x, ascending: true }
		else if (left.contains(SECOND) && !left.contains(FIRST) && right == left.replace(SECOND, FIRST))
			{ param: params[1], key: x, ascending: false }
		else
			null;
	}

	private static function keyCanonical(keys: Array<Key>, s: Seams): String {
		return 'keys:' + [ for (k in keys) (k.ascending ? '+' : '-') + shapeOf(k.key, [k.param => FIRST], s) ].join(';');
	}

	/** The structure of `node`: kind, name and children, an identifier `marks` names spelled as its mark. */
	private static function shapeOf(node: QueryNode, marks: Map<String, String>, s: Seams): String {
		final name: Null<String> = node.name;
		final spelled: Null<String> = name != null && node.kind == s.identKind ? marks[name] ?? name : name;
		final type: Null<QueryNode> = node.type;
		return node.kind
			+ (spelled == null ? '' : ' $spelled')
			+ (type == null ? '' : ':${shapeOf(type, marks, s)}')
			+ '('
			+ node.children.map(shapeOf.bind(_, marks, s)).join(',')
			+ ')';
	}

	private static function bindersIn(node: QueryNode, s: Seams, into: Array<String>): Void {
		final name: Null<String> = node.name;
		if (name != null && s.binderKinds.contains(node.kind)) into.push(name);
		for (c in node.children) bindersIn(c, s, into);
	}

	/** Whether every identifier under `node` is bound inside the callback or names a type, which goes into `typeNames`. */
	private static function readsOnly(node: QueryNode, bound: Array<String>, s: Seams, typeNames: Array<String>): Bool {
		final name: Null<String> = node.name;
		if (node.kind != s.identKind || name == null) return node.children.foreach(c -> readsOnly(c, bound, s, typeNames));
		if (bound.contains(name)) return true;
		if (!s.upperTypes || !SourceText.isUpperInitial(name)) return false;
		typeNames.pushUnique(name);
		return true;
	}

	/** The static's name from the key it compares by (`byFirstAt`, `byCountDesc`); null when the body compares no one key. */
	private static function nameOf(callback: Callback, s: Seams): Null<String> {
		final value: Null<QueryNode> = callback.value;
		final keys: Null<Array<Key>> = callback.keys ?? (value == null ? null : pairKeys(value, callback.params, s));
		if (keys == null) return null;
		final words: Array<String> = [];
		for (k in keys) {
			final field: Null<String> = k.key.kind == s.fieldAccessKind ? k.key.name : null;
			if (field == null || field.length == 0) return null;
			words.push(field.charAt(0).toUpperCase() + field.substr(1) + (k.ascending ? '' : DESC_SUFFIX));
		}
		return NAME_PREFIX + words.join(THEN);
	}

	/** The key of a body that is one operation over the same expression of each parameter (`a.k - b.k`, `f(a.k, b.k)`). */
	private static function pairKeys(value: QueryNode, params: Array<String>, s: Seams): Null<Array<Key>> {
		final operands: Array<QueryNode> = value.kind == s.callKind ? value.children.slice(1) : value.children;
		final key: Null<Key> = operands.length == 2 && params.length == 2 ? keyOfPair(operands[0], operands[1], params, s) : null;
		return key == null ? null : [key];
	}

	/** The fix of one group of identical comparators, or why there is none. */
	private static function planOf(
		sites: Array<Site>, s: Seams, plugin: GrammarPlugin, index: Null<SymbolIndex>, taken: Map<String, Bool>, inRun: Map<String, Bool>
	): Plan {
		final named: Null<String> = nameOf(sites[0].callback, s);
		function refused(why: String): Plan {
			return {
				name: named,
				slices: [],
				noFix: why,
				sites: sites
			};
		}
		if (named == null) return refused('no name derives from its body');
		if (index == null) return refused('the scope has no symbol index');
		final name: String = named;
		final placed: { host: Null<Host>, why: String } = hostOf(sites, s, plugin, index);
		final found: Null<Host> = placed.host;
		if (found == null) return refused(placed.why);
		final host: Host = found;
		final hostName: String = host.type.name;
		// The fix driver writes only the files the run covers, so a host outside them would leave every site naming a missing member.
		if (!inRun.exists(host.file)) return refused('$hostName is declared in ${host.file}, which this run does not cover');
		final hostKey: String = '${host.file}#$hostName.$name';
		if (taken.exists(hostKey) || host.type.members.exists(m -> m.name == name)) return refused('$hostName already declares $name');
		final printers: Map<String, TypeRefPrinter> = [];
		final at: Int = host.type.span.from;
		final hostPrinter: TypeRefPrinter = printerOf(printers, plugin, index, host.file, host.source, host.tree);
		final origin: Site = sites.find(site -> site.file == host.file) ?? sites[0];
		final outside: Bool = sites.exists(site -> !inside(site, host));
		final unseen: Null<String> = outside ? unseenType(origin, host, hostPrinter, at, index) : null;
		if (unseen != null) return refused('its body names $unseen, which $hostName is not shown to see');
		final declared: Null<ResolvedType> = origin.declared;
		final element: String = if (declared == null)
			origin.element
		else if (declared.type == host.type)
			hostName
		else
			hostPrinter.printTypeExpr(pathOf(declared.file, declared.type), at);
		final member: String = memberOf(
			origin, name, element, outside, sites.exists(site -> site.ordered), path -> hostPrinter.printTypeExpr(path, at), s
		);
		final insert: MemberEdit = AddMember.memberEdit(host.source, host.tree, hostName, member, plugin);
		final added: Null<{ span: Span, text: String }> = insert.edit;
		if (added == null) return refused(insert.refusal);
		final byFile: Map<String, Array<{ span: Span, text: String }>> = [];
		byFile.push(host.file, added);
		for (site in sites) {
			final printer: TypeRefPrinter = printerOf(printers, plugin, index, site.file, site.source, site.tree);
			byFile.push(
				site.file,
				{ span: site.span, text: inside(site, host) ? name : '${printer.printTypeExpr(host.path, site.span.from)}.$name' }
			);
		}
		for (file => printer in printers) for (edit in printer.pendingImportEdits())
			byFile.push(file, { span: edit.span, text: edit.text });
		taken[hostKey] = true;
		return {
			name: name,
			slices: [ for (file => edits in byFile) { file: file, edits: edits } ],
			noFix: null,
			sites: sites
		};
	}

	/**
	 * The extracted member: a typed `static final` over the configured macro for keys proved orderable when the options name a
	 * macro for each direction the keys take, else a static function returning the body, its compare function spelled for the host.
	 */
	private static function memberOf(
		origin: Site, name: String, element: String, outside: Bool, ordered: Bool, typeAt: (String) -> String, s: Seams
	): String {
		final visibility: String = outside ? 'public' : 'private';
		final spell: (NamedCompare) -> String = compare -> '${typeAt(compare.typePath)}.${compare.member}';
		final callback: Callback = origin.callback;
		final keys: Null<Array<Key>> = callback.keys;
		if (keys != null && ordered) {
			final ascending: Bool = keys[0].ascending;
			final outer: Null<NamedCompare> = ascending ? origin.options.asc : origin.options.desc;
			final inner: Null<NamedCompare> = ascending ? origin.options.desc : origin.options.asc;
			if (outer != null && (inner != null || keys.foreach(k -> k.ascending == ascending))) {
				final lambdas: Array<String> = [ for (k in keys) {
					final lambda: String = '${k.param} -> ${textOf(k.key, origin.source)}';
					k.ascending == ascending || inner == null ? lambda : '${spell(inner)}($lambda)';
				} ];
				final declared: String = '$visibility static final $name: ($element, $element) -> ${s.intType}';
				return '$declared = ${spell(outer)}(${lambdas.join(', ')});';
			}
		}
		final value: Null<QueryNode> = callback.value;
		final named: Null<NamedCompare> = callback.named;
		final receiver: Null<QueryNode> = value?.children[0]?.children[0];
		final body: String = value == null || named == null || receiver == null
			? textOf(value, origin.source)
			: respelled(value, receiver, typeAt(named.typePath), origin.source);
		return '$visibility static function $name(${callback.params[0]}: $element, ${callback.params[1]}: $element): ${s.intType} '
			+ 'return $body;';
	}

	/** The source of `value` with the type `receiver` spells replaced by `type`. */
	private static function respelled(value: QueryNode, receiver: QueryNode, type: String, source: String): String {
		final whole: Null<Span> = value.span;
		final part: Null<Span> = receiver.span;
		return whole == null || part == null
			? textOf(value, source)
			: source.substring(whole.from, part.from) + type + source.substring(part.to, whole.to);
	}

	/**
	 * Where the static goes: the element type when the scope declares it
	 * as a public class or abstract, else the type holding most sites.
	 */
	private static function hostOf(
		sites: Array<Site>, s: Seams, plugin: GrammarPlugin, index: SymbolIndex
	): { host: Null<Host>, why: String } {
		final onElement: Null<Host> = elementHost(sites, s, plugin, index);
		if (onElement != null) return { host: onElement, why: '' };
		final best: String = busiestFile(sites);
		final info: Null<FileInfo> = index.fileInfo(best);
		if (info == null) return { host: null, why: 'its module is not in the symbol index' };
		final module: FileInfo = info;
		if (sites.exists(site -> index.fileInfo(site.file)?.pkg != module.pkg))
			return { host: null, why: 'the sites span packages and the element type is no class or abstract the scope declares' };
		var type: Null<TypeDeclInfo> = null;
		var most: Int = 0;
		for (t in module.types) if (s.hostKinds.contains(t.kind)) {
			final held: Int = sites.count(site -> site.file == best && t.span.from <= site.span.from && site.span.to <= t.span.to);
			if (held > most) {
				most = held;
				type = t;
			}
		}
		if (type == null) return { host: null, why: 'no class or abstract of its module holds the sites' };
		if (type.isPrivate && sites.exists(site -> site.file != best)) return { host: null, why: '${type.name} is private to its module' };
		final inModule: Null<Host> = hostIn(module, type, sites, plugin, index);
		return inModule == null ? { host: null, why: 'its module does not parse' } : { host: inModule, why: '' };
	}

	private static function hostIn(
		info: FileInfo, type: TypeDeclInfo, sites: Array<Site>, plugin: GrammarPlugin, index: SymbolIndex
	): Null<Host> {
		final site: Null<Site> = sites.find(site -> site.file == info.file);
		final source: Null<String> = site?.source ?? index.sourceOf(info.file);
		final tree: Null<QueryNode> = site?.tree ?? (source == null ? null : ParseGate.parseOrNull(plugin, source));
		return source == null || tree == null ? null : {
			file: info.file,
			source: source,
			tree: tree,
			type: type,
			path: pathOf(info, type)
		};
	}

	/** The path an import of `type` names: its module's path, then the type's own name when it is not the module's main type. */
	private static function pathOf(info: FileInfo, type: TypeDeclInfo): String {
		return SourceText.lastSegment(info.module) == type.name ? info.module : '${info.module}.${type.name}';
	}

	private static function textOf(node: Null<QueryNode>, source: String): String {
		final span: Null<Span> = node?.span;
		return span == null ? '' : source.substring(span.from, span.to);
	}

	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final sort: Null<SortKinds> = SortComparatorWalk.kindsOf(shape);
		final intType: Null<String> = shape.coreValueTypes?.integer;
		final returnKinds: Null<Array<String>> = shape.valueReturnKinds;
		final blockKinds: Array<String> = plugin.controlFlowSupport()?.blockKinds() ?? [];
		final stringType: Null<String> = TypingService.stringType(shape);
		final realType: Null<String> = shape.coreValueTypes?.real;
		if (sort == null || intType == null || stringType == null || returnKinds == null || blockKinds.length == 0) return null;
		final catchKind: Null<String> = shape.catchClauseKind;
		return {
			sort: sort,
			identKind: shape.identKind,
			fieldAccessKind: sort.fieldAccessKind,
			callKind: sort.callKind,
			blockKinds: blockKinds,
			returnKinds: returnKinds,
			binderKinds: sort.paramKinds.concat(shape.localDeclKinds ?? [])
				.concat(shape.iterationBindingKinds ?? [])
				.concat(shape.iterationValueBinderKinds ?? [])
				.concat(shape.casePatternBinderKinds ?? [])
				.concat(shape.localFunctionKinds ?? [])
				.concat(catchKind == null ? [] : [catchKind]),
			hostKinds: (shape.classDeclKinds ?? []).concat(shape.underlyingThisTypeKinds ?? []),
			intType: intType,
			compareTypes: realType == null ? [intType, stringType] : [intType, stringType, realType],
			nullableWrapper: shape.optionalValueTypeName,
			upperTypes: shape.typeNamesUpperInitial == true,
			elementParams: shape.indexedElementTypeParams ?? []
		};
	}

	/** The type printer of `file`, made once per plan so its pending imports are collected in one place. */
	private static function printerOf(
		printers: Map<String, TypeRefPrinter>, plugin: GrammarPlugin, index: SymbolIndex, file: String, source: String, tree: QueryNode
	): TypeRefPrinter {
		final known: Null<TypeRefPrinter> = printers[file];
		if (known != null) return known;
		final made: TypeRefPrinter = TypeRefPrinter.forFile(
			file, source, tree, RunScan.typeInfoOf(plugin)?.importMap(source, file) ?? [], plugin, index
		);
		printers[file] = made;
		return made;
	}

	/**
	 * A type the body of `origin` names that the host would not bind to the same declaration, or null when every one does.
	 * The keyed type's own spelling is printed for the host anew, so it is never asked here.
	 */
	private static function unseenType(origin: Site, host: Host, hostPrinter: TypeRefPrinter, at: Int, index: SymbolIndex): Null<String> {
		final callback: Callback = origin.callback;
		for (type in callback.typeNames) if (callback.keys == null || type != callback.keyedName) {
			final resolved: Array<ResolvedType> = index.resolveTypeRefsFrom(type, origin.file, origin.span.from);
			if (resolved.length != 1) return type;
			if (origin.file != host.file && hostPrinter.printTypeExpr(pathOf(resolved[0].file, resolved[0].type), at) != type) return type;
		}
		return null;
	}

	/** The element type of the sites as the host, when the scope declares it as a public, non-generic class or abstract. */
	private static function elementHost(sites: Array<Site>, s: Seams, plugin: GrammarPlugin, index: SymbolIndex): Null<Host> {
		final declared: Null<ResolvedType> = sites[0].declared;
		if (declared == null) return null;
		final type: TypeDeclInfo = declared.type;
		final owned: Bool = s.hostKinds.contains(type.kind)
			&& !type.isPrivate && !type.isExtern && type.typeParamArity == 0
			&& !index.isThirdParty(declared.file.file);
		return owned ? hostIn(declared.file, type, sites, plugin, index) : null;
	}

	/** The file holding most of the sites, the first of them on a tie. */
	private static function busiestFile(sites: Array<Site>): String {
		final counts: Map<String, Int> = [];
		var best: String = sites[0].file;
		for (site in sites) {
			final count: Int = (counts[site.file] ?? 0) + 1;
			counts[site.file] = count;
			if (count > (counts[best] ?? 0)) best = site.file;
		}
		return best;
	}

}
