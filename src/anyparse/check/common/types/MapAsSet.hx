package anyparse.check.common.types;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.LintConfig;
import anyparse.check.common.loops.MapValueScan;
import anyparse.query.IndexScope;
import anyparse.query.MemberWriteScan;
import anyparse.query.ParseGate;
import anyparse.query.ShapeVocab;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeRefPrinter;
import anyparse.query.TypeSyntax;

/**
 * Flags a map declared with boolean values (`Map<K, Bool>`) that is only ever a SET of its keys: every value it stores is
 * the literal `true` and every use asks membership (`exists`, an index read, `keys`, `remove`). An array of the keys with
 * `contains` says the same with no value to misread. `Severity.Info`, DEFAULT OFF: the rewrite trades a hash lookup for a
 * linear scan, which is the project's call, so a set filled once is advice only.
 *
 * Whether the map is a set is `MapValueScan`'s occurrence census under `MapClaim.KeySet`: the one census that already
 * proves what a map can hold, so a local is censused in its file and a non-public member through every file that can
 * reach it. The declared type is read from the written annotation (`TypeInfoProvider.declaredTypeSources`); an
 * unannotated binding and a nullable wrapper are not asked.
 *
 * A set that GROWS is not reported: an array makes every `contains` a linear scan, which is quadratic once the keys are
 * added inside a loop, a local function or a member the map outlives, other than the constructor (a `visited` / `seen`
 * set, a memo) — the hash lookup is the right structure there. A function that also spans the map's own declaration does
 * not count: that map is fresh each call.
 *
 * A project that names its set type (`"map-as-set": { "set": "anyparse.ds.Set" }`) is told about the growing ones too, and
 * `--fix` respells such a set to that type: the declared type, the empty construction, `set(k, true)` / `m[k] = true` as
 * `add`, `exists` as `has`. A growing set is reported only where that rewrite exists, so every finding is one `--fix` clears:
 * a set another declaration of the same name shares the file with, a key other than `String` / `Int` (an enum value is
 * compared structurally by `Map` and by identity by a native set), and any use the set type has no equal for — an index read,
 * `get`, `keys`, `copy` — stay silent.
 *
 * A project that names its bit-set type (`"map-as-set": { "bits": "anyparse.ds.Bits" }`) is told that a set whose key is a
 * fixed enum domain — an enum without constructor parameters, an `Int` enum abstract of literal values — is a bit set,
 * grown or not, and `--fix` respells it. A bit set is replaced by its own `add`, so a `final` binding keeps the plain advice.
 */
@:nullSafety(Strict)
final class MapAsSet extends RuleBase implements DefaultOff implements ConfigAware {

	private static inline final RULE_ID: String = 'map-as-set';

	/** A map type spells its key and its value. */
	private static inline final MAP_ARGUMENTS: Int = 2;

	/** The `apq.json` option naming the project's set type. */
	private static inline final SET_OPTION: String = 'set';

	/** The `apq.json` option naming the project's bit-set type, which takes a set whose key is a fixed enum domain. */
	private static inline final BITS_OPTION: String = 'bits';

	/** The written name of the map a construction respelled to the set type has. */
	private static inline final MAP_TYPE: String = 'Map';

	/** The receiver keyword of a member of the enclosing type. */
	private static inline final THIS_NAME: String = 'this';

	/** The key types a native set compares as `Map` does; an enum value is structural in `Map` and by identity in a native set. */
	private static final SET_KEY_TYPES: Array<String> = ['String', 'Int'];

	/** The linter's per-file config resolver (the `set` option), or null to read each file's chain from disk. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(RULE_ID, 'a Map<K, Bool> used only as a set of keys — an Array<K> with contains() says the same', RuleCategory.Types);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	/**
	 * Rewrites a GROWING set to the project's set type (the `set` option). A non-growing one is advice only: whether a
	 * linear scan of an array may replace the hash lookup is the project's call.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final first: Null<Violation> = violations[0];
		final root: Null<QueryNode> = first == null ? null : ParseGate.parseOrNull(plugin, source);
		final seams: Null<ValueSeams> = MapValueScan.seamsOf(plugin.refShape());
		final options: Null<LintConfig> = first == null ? null : LintConfig.resolveWith(_resolveConfig, first.file);
		final setType: Null<String> = options?.stringOption(RULE_ID, SET_OPTION);
		final bitsType: Null<String> = options?.stringOption(RULE_ID, BITS_OPTION);
		if (first == null || root == null || seams == null || setType == null && bitsType == null) return [];
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final printer: TypeRefPrinter = TypeRefPrinter.forFile(
			first.file, source, root, provider == null ? [] : provider.importMap(source, first.file), plugin, index
		);
		final project: SetProject = {
			file: first.file,
			index: index,
			set: setType,
			bits: bitsType,
			spell: spelling -> printer.print(spelling).text
		};
		final out: Array<{ span: Span, text: String }> = [];
		final written: Map<Int, String> = provider == null ? [] : provider.declaredTypeSources(source);
		for (violation in violations) {
			final at: Null<Span> = violation.span;
			final edits: Array<{ span: Span, text: String }> = [];
			final declined: Null<String> = at == null
				? 'the finding has no span'
				: rewriteSet(source, root, at.from, seams, plugin, written[at.from], project, edits);
			if (declined != null) {
				violation.declineReason = declined;
				continue;
			}
			for (edit in edits) out.push(edit);
		}
		// The import rides on a rewrite: a file where every finding declined gets no edit at all.
		if (out.length > 0) for (edit in printer.pendingImportEdits()) out.push({ span: edit.span, text: edit.text });
		return out;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final repeating: Array<String> = ShapeVocab.loopKinds(shape).concat(ShapeVocab.nestedFunctionKinds(shape));
		final functions: Array<String> = shape.functionKinds ?? [];
		final seams: Null<ValueSeams> = MapValueScan.seamsOf(shape);
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final boolName: Null<String> = shape.nonNullBoolTypeName;
		final mapTypes: Array<String> = shape.mapAbstractTypeNames ?? [];
		final config: (String) -> LintConfig = file -> LintConfig.resolveWith(_resolveConfig, file);
		if (seams == null || provider == null || boolName == null || mapTypes.length == 0) return [];
		final census: ValueSeams = seams;
		// The REPORT index, as `redundant-map-exists` hands the census: it reads the report scope's skipped files as
		// the proof that nothing is hidden, and resolves the wider subtype and grant scope itself.
		var reportIndex: Null<SymbolIndex> = null;
		return RunScan.collect(files, plugin, (entry, root, out) -> {
			final written: Map<Int, String> = provider.declaredTypeSources(entry.source);
			eachDeclaration(root, seams.declKinds, (decl, name, from) -> {
				final key: Null<String> = keyOfSet(written[from], plugin.typeSyntax, mapTypes, boolName);
				final span: Null<Span> = decl.span;
				if (key == null || span == null) return;
				final index: SymbolIndex = reportIndex ?? IndexScope.report(files, plugin);
				reportIndex = index;
				if (!MapValueScan.proven(name, from, entry.source, root, index, plugin, seams, KeySet)) return;
				final ask: GrowthQuery = {
					name: name,
					declAt: from,
					seams: census,
					repeating: repeating,
					functions: functions,
					constructor: shape.constructorName
				};
				final grows: Bool = growsInRepetition(root, null, -1, null, -1, false, ask);
				final options: LintConfig = config(entry.file);
				final setType: Null<String> = options.stringOption(RULE_ID, SET_OPTION);
				final bitsType: Null<String> = options.stringOption(RULE_ID, BITS_OPTION);
				final project: SetProject = {
					file: entry.file,
					index: index,
					set: setType,
					bits: bitsType,
					spell: spelling -> spelling
				};
				// A set of enum values is a bit set, grown or not; where the bit set cannot take the rewrite the set is advised as before.
				if (
					bitsType != null
					&& bitsDomain(key, project, from, shape)
					&& rewriteSet(entry.source, root, from, census, plugin, written[from], project, []) == null
				) {
					out.push({
						file: entry.file,
						span: span,
						rule: RULE_ID,
						severity: Severity.Info,
						message: '\'$name\' is a map whose every value is true, a set of the values of $key — '
						+ '${SourceText.lastSegment(bitsType)}<$key> says the same'
					});
					return;
				}

				// A growing set is advice only where the rewrite exists: an unactionable finding is noise.
				if (grows && (setType == null || rewriteSet(entry.source, root, from, census, plugin, written[from], project, []) != null))
					return;
				out.push({
					file: entry.file,
					span: span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: grows
						? '\'$name\' is a map whose every value is true, grown while it is read — '
							+ SourceText.lastSegment(setType ?? '')
							+ '<$key> says the same'
						: '\'$name\' is a map whose every value is true, used only as a set of keys — Array<$key'
							+ '> with contains() says the same'
				});
			});
		});
	}

	/**
	 * Whether `node`'s subtree stores a key into the map `ask.name` (`m[k] = true`, `m.set(k, true)`) while a repetition
	 * is running: inside a loop, a nested function or a member the map outlives other than the constructor (`inside`). A
	 * repetition spanning the declaration `ask.declAt` rebuilds the map each turn, so it opens none. `parent` / `grand` are the two
	 * ancestors with the slots they hold their child in.
	 */
	private static function growsInRepetition(
		node: QueryNode, parent: Null<QueryNode>, parentSlot: Int, grand: Null<QueryNode>, grandSlot: Int, inside: Bool, ask: GrowthQuery
	): Bool {
		if (node.name == ask.name && inside && storesInto(parent, parentSlot, grand, grandSlot, ask.seams)) return true;
		final span: Null<Span> = node.span;
		final opensMap: Bool = span != null && span.from <= ask.declAt && ask.declAt < span.to;
		final callable: Bool = ask.functions.contains(node.kind) && node.name != ask.constructor;
		final nowInside: Bool = inside || (!opensMap && (ask.repeating.contains(node.kind) || callable));
		for (i in 0...node.children.length) if (growsInRepetition(node.children[i], node, i, parent, parentSlot, nowInside, ask))
			return true;
		return false;
	}

	/** Whether the receiver occurrence under `parent` / `grand` stores a key: an index assignment target or a `set` call. */
	private static function storesInto(
		parent: Null<QueryNode>, parentSlot: Int, grand: Null<QueryNode>, grandSlot: Int, seams: ValueSeams
	): Bool {
		return parent != null && grand != null && parentSlot == 0 && grandSlot == 0 && (
			parent.kind == seams.indexAccessKind
			&& grand.kind == seams.assignKind
			|| parent.kind == seams.fieldAccessKind
			&& parent.name == MapValueScan.SET_METHOD
			&& grand.kind == seams.callKind
		);
	}

	/**
	 * Why the set declared at `declAt` stays as written, or null after `edits` took its rewrite: to the bit set when the key
	 * is a domain `anyparse.ds.Bits` takes, else to the project's set type. The declared type, every initialiser and every use
	 * of the name in the file are respelled, so a use outside the four the target answers the same (`set(k, true)` /
	 * `m[k] = true`, `exists`, `remove`, `clear`) leaves all of it alone.
	 */
	private static function rewriteSet(
		source: String, root: QueryNode, declAt: Int, seams: ValueSeams, plugin: GrammarPlugin, written: Null<String>, project: SetProject,
		edits: Array<{ span: Span, text: String }>
	): Null<String> {
		final shape: RefShape = plugin.refShape();
		final boolName: Null<String> = shape.nonNullBoolTypeName;
		final key: Null<String> =
			boolName == null ? null : keyOfSet(written, plugin.typeSyntax, shape.mapAbstractTypeNames ?? [], boolName);
		final decl: Null<QueryNode> = declarationAt(root, declAt, seams.declKinds);
		final name: Null<String> = decl?.name;
		if (written == null || key == null || decl == null || name == null) return 'no written Map<K, Bool> declaration to respell';
		// A bit set is a value its own `add` replaces, so a `final` binding cannot hold one and keeps the plain advice.
		final mutable: Array<String> = (shape.mutableLocalDeclKinds ?? []).concat(shape.mutableFieldDeclKinds ?? []);
		final asBits: Bool = mutable.contains(decl.kind) && bitsDomain(key, project, declAt, shape);
		final target: Null<String> = asBits ? project.bits : project.set;
		if (target == null) return 'the project names no set type';
		if (!asBits && !SET_KEY_TYPES.contains(key)) return 'a $key key may compare differently in the native set of some target';
		final unconfined: Null<String> = unconfinedReason(source, root, declAt, name, seams, project, plugin);
		if (unconfined != null) return unconfined;
		// Re-bind: a null-check does not narrow into an anonymous-structure literal.
		final declared: String = name;
		final targetName: String = target;
		final keyType: String = key;
		final typeText: String = written;
		final ask: GrowthQuery = {
			name: declared,
			declAt: declAt,
			seams: seams,
			repeating: ShapeVocab.loopKinds(shape).concat(ShapeVocab.nestedFunctionKinds(shape)),
			functions: shape.functionKinds ?? [],
			constructor: shape.constructorName
		};
		if (!asBits && !growsInRepetition(root, null, -1, null, -1, false, ask)) return 'a set filled once is advice only';
		final site: SetRewrite = {
			source: source,
			seams: seams,
			name: declared,
			member: shape.fieldDeclKinds?.contains(decl.kind) ?? false,
			key: keyType,
			written: typeText,
			setName: targetName
		};
		// The target is spelled (and its import queued) only for a rewrite that holds, so a dry run decides first.
		final dry: Null<String> = respell(root, null, -1, null, -1, site, []);
		if (dry != null) return dry;
		final spelled: SetRewrite = {
			source: source,
			seams: seams,
			name: declared,
			member: site.member,
			key: keyType,
			written: typeText,
			setName: project.spell(targetName)
		};
		return respell(root, null, -1, null, -1, spelled, edits);
	}

	/** The reason an occurrence of the set's name (or one below it) cannot be respelled, else null once its edits are in `edits`. */
	private static function respell(
		node: QueryNode, parent: Null<QueryNode>, parentSlot: Int, grand: Null<QueryNode>, grandSlot: Int, site: SetRewrite,
		edits: Array<{ span: Span, text: String }>
	): Null<String> {
		if (node.name == site.name) {
			final declined: Null<String> = respellOccurrence(node, parent, parentSlot, grand, grandSlot, site, edits);
			if (declined != null) return declined;
		}
		for (i in 0...node.children.length) {
			final declined: Null<String> = respell(node.children[i], node, i, parent, parentSlot, site, edits);
			if (declined != null) return declined;
		}
		return null;
	}

	private static function respellOccurrence(
		node: QueryNode, parent: Null<QueryNode>, parentSlot: Int, grand: Null<QueryNode>, grandSlot: Int, site: SetRewrite,
		edits: Array<{ span: Span, text: String }>
	): Null<String> {
		final seams: ValueSeams = site.seams;
		if (seams.declKinds.contains(node.kind)) return respellDeclaration(node, site, edits);
		final foreign: Null<String> = node.kind == seams.fieldAccessKind ? foreignAccess(node, site) : null;
		if (foreign != null) return foreign;
		if (parent == null) return 'a use outside a declaration or a call';
		if (parent.kind == seams.assignKind && parentSlot == 0) return respellInitialiser(parent.children[1], site, edits);
		if (parent.kind != seams.indexAccessKind || parentSlot != 0)
			return parent.kind != seams.fieldAccessKind
				|| parentSlot != 0
				|| grand == null
				|| grand.kind != seams.callKind
				|| grandSlot != 0
				? 'a use that is not a call of a set member'
				: respellCall(parent, grand, site, edits);
		final target: Null<QueryNode> = grand;
		final key: Null<Span> = parent.children[1].span;
		final receiver: Null<Span> = node.span;
		final span: Null<Span> = target?.span;
		if (target == null || target.kind != seams.assignKind || grandSlot != 0 || key == null || receiver == null || span == null)
			return 'an index read answers Null<Bool>, which has() does not';
		edits.push({
			span: span,
			text: '${site.source.substring(receiver.from, receiver.to)}.add(${site.source.substring(key.from, key.to)})'
		});
		return null;
	}

	/** `m.set(k, true)` becomes `m.add(k)`, `m.exists(k)` becomes `m.has(k)`; `remove` and `clear` read the same. */
	private static function respellCall(
		access: QueryNode, call: QueryNode, site: SetRewrite, edits: Array<{ span: Span, text: String }>
	): Null<String> {
		final method: String = access.name ?? '';
		final accessSpan: Null<Span> = access.span;
		if (accessSpan == null) return 'a call without a span';
		final nameAt: Int = accessSpan.to - method.length;
		if (method == 'remove' || method == 'clear') return null;
		if (method == 'exists') {
			edits.push({ span: new Span(nameAt, accessSpan.to), text: 'has' });
			return null;
		}
		final key: Null<Span> = call.children[1]?.span;
		final value: Null<Span> = call.children[2]?.span;
		if (method != MapValueScan.SET_METHOD || key == null || value == null) return '${method}() has no equal on the set type';
		edits.push({ span: new Span(nameAt, accessSpan.to), text: 'add' });
		edits.push({ span: new Span(key.to, value.to), text: '' });
		return null;
	}

	/** The declared type and the initialiser of the set's own declaration. */
	private static function respellDeclaration(
		decl: QueryNode, site: SetRewrite, edits: Array<{ span: Span, text: String }>
	): Null<String> {
		final span: Null<Span> = decl.span;
		if (span == null) return 'a declaration without a span';
		final init: Null<QueryNode> = decl.children[0];
		final end: Int = init?.span?.from ?? span.to;
		final typeAt: Int = site.source.indexOf(site.written, span.from);
		if (typeAt < 0 || typeAt + site.written.length > end) return 'the declared type is not written in the declaration';
		edits.push({ span: new Span(typeAt, typeAt + site.written.length), text: '${site.setName}<${site.key}>' });
		return init == null ? null : respellInitialiser(init, site, edits);
	}

	/** A construction of the map (`new Map()` or an empty literal) becomes a construction of the set. */
	private static function respellInitialiser(
		init: QueryNode, site: SetRewrite, edits: Array<{ span: Span, text: String }>
	): Null<String> {
		final span: Null<Span> = init.span;
		final seams: ValueSeams = site.seams;
		final constructs: Bool = init.kind == seams.newExprKind
			&& SourceText.lastSegment(init.name ?? '') == MAP_TYPE
			|| init.kind == seams.arrayLiteralKind
			&& init.children.length == 0;
		if (span == null || !constructs) return 'the map is built from something other than an empty construction';
		edits.push({ span: span, text: 'new ${site.setName}<${site.key}>()' });
		return null;
	}

	/** The reason a field access of the set's name is not the set: `this.name` binds a member, so only a member declaration owns it. */
	private static function foreignAccess(access: QueryNode, site: SetRewrite): Null<String> {
		if (!isOwnMember(access, site.seams)) return 'a member of another receiver that shares the name';
		return site.member ? null : 'a member of this type that shares the name of the local set';
	}

	/** Whether a field access names a member of the enclosing type: only `this.name` does, any other receiver is another object's. */
	private static function isOwnMember(access: QueryNode, seams: ValueSeams): Bool {
		final receiver: Null<QueryNode> = access.children[0];
		return receiver != null && receiver.kind == seams.identKind && receiver.name == THIS_NAME;
	}

	/** How many declarations of `name` the file holds. */
	private static function declarationsOf(node: QueryNode, name: String, declKinds: Array<String>): Int {
		var count: Int = declKinds.contains(node.kind) && node.name == name ? 1 : 0;
		for (c in node.children) count += declarationsOf(c, name, declKinds);
		return count;
	}

	/** The declaration whose span starts at `at`. */
	private static function declarationAt(node: QueryNode, at: Int, declKinds: Array<String>): Null<QueryNode> {
		if (declKinds.contains(node.kind) && node.span?.from == at) return node;
		for (c in node.children) {
			final found: Null<QueryNode> = declarationAt(c, at, declKinds);
			if (found != null) return found;
		}
		return null;
	}

	/** Call `sink` with every declaration of a `declKinds` kind under `node` that carries a name and a span. */
	private static function eachDeclaration(node: QueryNode, declKinds: Array<String>, sink: (QueryNode, String, Int) -> Void): Void {
		final name: Null<String> = node.name;
		final span: Null<Span> = node.span;
		if (declKinds.contains(node.kind) && name != null && span != null) sink(node, name, span.from);
		for (c in node.children) eachDeclaration(c, declKinds, sink);
	}

	/**
	 * The key type's text when `written` is a map type (`mapTypes`) whose value type is the boolean `boolName`, else null —
	 * a nullable wrapper around the map included, which a set of keys would not be written as.
	 */
	private static function keyOfSet(
		written: Null<String>, typeSyntax: TypeSyntaxReader, mapTypes: Array<String>, boolName: String
	): Null<String> {
		final type: Null<TypeSyntax> = written == null ? null : typeSyntax(written);
		return switch type?.shape {
			case Nominal(path, args) if (args.length == MAP_ARGUMENTS && mapTypes.contains(SourceText.lastSegment(path))):
				switch args[1].shape {
					case Nominal(value, []) if (SourceText.lastSegment(value) == boolName): args[0].text;
					case _: null;
				}
			case _: null;
		};
	}

	/**
	 * Whether the key type `key`, written in the project's file at `at`, is a domain the project's bit-set type takes: it
	 * resolves to exactly one declaration that is an enum whose constructors take no parameters, or an `Int` enum abstract
	 * whose every value is a non-negative integer literal. Stricter than `BitsBuilder` where the index cannot say more.
	 */
	private static function bitsDomain(key: String, project: SetProject, at: Int, shape: RefShape): Bool {
		final index: Null<SymbolIndex> = project.index;
		final info: Null<FileInfo> = index?.fileInfo(project.file);
		if (project.bits == null || index == null || info == null) return false;
		final found: Array<ResolvedType> = index.refs.resolveTypeRefAll(key, info, at);
		if (found.length != 1) return false;
		final type: TypeDeclInfo = found[0].type;
		final integer: Null<String> = shape.coreValueTypes?.integer;
		return !type.isPrivate && !type.hasBuild && type.typeParamArity == 0 && (
			type.isEnumAbstract
				? integer != null && type.underlyingRaw == integer && abstractValuesAreLiterals(type.members, shape)
				: (shape.bareConstructorTypeKinds ?? []).contains(type.kind)
					&& type.members.length > 0
					&& type.members.filter(member -> member.paramTypeSources.length > 0 || member.guarded).length == 0
		);
	}

	/** Whether the values of an enum abstract (its non-static fields) are at least one, each a non-negative integer literal. */
	private static function abstractValuesAreLiterals(members: Array<MemberInfo>, shape: RefShape): Bool {
		final fields: Array<MemberInfo> = members.filter(member -> !member.isStatic && (shape.fieldDeclKinds ?? []).contains(member.kind));
		final literals: Array<String> = shape.numericLiteralKinds ?? [];
		return fields.length > 0
			&& fields.filter(
				field ->
					!field.guarded
					&& literals.contains(field.initializerKind ?? '')
					&& (Std.parseInt(field.initializerSource ?? '') ?? -1) >= 0
			)
				.length
				== fields.length;
	}

	/**
	 * Why the set declared at `declAt` cannot be respelled from this file alone, or null: another declaration of its name shares
	 * the file, or it is a member that a subtype or an `@:access` grantee of another file may read, which these edits cannot respell.
	 */
	private static function unconfinedReason(
		source: String, root: QueryNode, declAt: Int, name: String, seams: ValueSeams, project: SetProject, plugin: GrammarPlugin
	): Null<String> {
		if (declarationsOf(root, name, seams.declKinds) != 1) return 'the file declares another \'$name\'';
		final owner: Null<String> = MapValueScan.memberOwner(root, declAt, seams);
		final scope: Null<SymbolIndex> = project.index;
		return owner == null || scope != null && MemberWriteScan.referencesConfinedToFile(owner, name, source, scope, plugin)
			? null
			: 'a subtype or an @:access grantee in another file may read the member';
	}

}

/**
 * What `growsInRepetition` asks: the map's name and declaration offset,
 * the census seams, and the kinds that repeat or declare a function.
 */
private typedef GrowthQuery = {
	final name: String;
	final declAt: Int;
	final seams: ValueSeams;
	final repeating: Array<String>;
	final functions: Array<String>;
	final constructor: Null<String>;
};

/** What `rewriteSet` respells in one file: the set's name, its key type and written type, and the project's set type. */
private typedef SetRewrite = {
	final source: String;
	final seams: ValueSeams;
	final name: String;
	final member: Bool;
	final key: String;
	final written: String;
	final setName: String;
};

/**
 * What the rewrite of one file needs from the project: the file and the index its names resolve against, the configured
 * set type and bit-set type (null for a project that names none), and how a configured type is spelled in the file.
 */
private typedef SetProject = {
	final file: String;
	final index: Null<SymbolIndex>;
	final set: Null<String>;
	final bits: Null<String>;
	final spell: (String) -> String;
};
