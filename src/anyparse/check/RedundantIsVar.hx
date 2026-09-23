package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.OracleRelaxable;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.Violation;
import anyparse.check.ReflectionScan.ReflectionSurface;
import anyparse.query.CondRegionScan;
import anyparse.query.CtorFieldFold;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberBranchScan;
import anyparse.query.MemberKinds;
import anyparse.query.MemberWriteScan;
import anyparse.query.QueryNode;
import anyparse.query.RawSourceScan;
import anyparse.query.RefactorSupport;
import anyparse.query.SourceText;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * Flags an `@:isVar` whose physical storage is DEAD and deletes the metadata. `Info`, DEFAULT OFF.
 *
 * `@:isVar` gives a property whose slots are all `get` / `set` / `never` a real field. Haxe code reaches
 * it only through an accessor body of the property (`get_x` / `set_x`, declared here, inherited or
 * overridden), an `@:bypassAccessor` access or a declaration initializer; TARGET code pasted as a
 * string reaches it too. Everything else routes through the accessors either way.
 *
 * ## Gates — all must hold
 *
 * 1. Both slots are `get` / `set` / `never`; the metadata is bare or `@:isVar()`, and the member is not `@:keep`.
 * 2. No declaration initializer — `= v` writes the field and needs the metadata to compile.
 * 3. No `get_x` / `set_x` method, `@:bypassAccessor` construct or native-code carrier (`__cpp__`,
 *    `Syntax.code`, `@:functionCode`, …) in ANY type of report UNION resolution scope mentions `x` as a
 *    word — a superset of the inheritance chain, so an override behind an unresolvable link refuses.
 * 4. The name is not reached by reflection (`ReflectionScan.runtimeName`), and no scope file spelling
 *    it fails to parse or hides it in an unparsed `#if` region (`CondRegionScan`).
 * 5. The owner is not `@:keep`, `extern` or `@:coreApi`, carries no `@:rtti` up its chain, and its
 *    supertype chain resolves (`SubtypeGraph.supertypeChainResolved`).
 * 6. The metadata sits in a modifier run every build sees (`MemberBranchScan.eachMember`).
 *
 * ## Macro-built owners — `RiskyFix` + `OracleRelaxable`
 *
 * A builder (`@:build`, or `TypeTraits.transitivelyCarriesBuildMacro` — every OpenFL `Sprite`
 * subclass) may generate code no text here holds. Without the metadata any DIRECT storage access such
 * code makes is "This field cannot be accessed because it is not a real variable", so the edit is
 * admitted only under a compiler oracle, through typecheck-and-revert (`setOracleRelaxed`), and
 * declined without one; every other finding stays an ordinary fix. What the compiler cannot see is a
 * builder or library that reaches the field by NAME at run time or enumerates the object.
 *
 * ## Residual — reflection the source does not spell
 *
 * A text scan cannot bound code that names the field without spelling it — a name concatenated
 * (`Reflect.setField(o, 'wid' + 'th', 7)`), computed or read from data — or that enumerates the
 * object: `Type.getInstanceFields` on every target, and on eval `Reflect.fields` / `hasField`,
 * `haxe.Json.stringify`, `haxe.Serializer` and `Std.string`, all of which saw a constant `null` go.
 * A `Dynamic`-typed WRITE `(o:Dynamic).x = v` lands in the field with the metadata and fails without it on eval.
 */
@:nullSafety(Strict)
final class RedundantIsVar implements Check implements DefaultOff implements RiskyFix implements OracleRelaxable {

	/** This check's stable id. */
	private static inline final RULE_ID: String = 'redundant-isvar';

	/** The metadata that forces physical storage onto a property. */
	private static inline final IS_VAR_META: String = '@:isVar';

	/** The metadata that makes a property access reach the physical field directly. */
	private static inline final BYPASS_META: String = '@:bypassAccessor';

	/** Why a finding on a macro-built owner carries no edit without a compiler oracle — one ledger row for every such site. */
	private static inline final MACRO_DECLINE: String =
		'a build macro reaches the owner and may generate an access to the field, which only a compiler oracle can rule out';


	/** The accessor slots that leave a property without storage of its own unless `@:isVar` grants it. */
	private static final STORAGELESS_SLOTS: Array<String> = ['get', 'set', 'never'];

	/** Whether a compiler oracle verifies the fix, which is what admits a macro-built owner's edit. */
	private var _oracleRelaxed: Bool = false;

	public function new() {}

	/**
	 * Admit the edits of MACRO-BUILT owners. Set by `Cli.applyLintFixes` only when this check runs
	 * as a verified `RiskyFix`, so those edits always pass the typecheck-and-revert pipeline.
	 */
	public function setOracleRelaxed(relaxed: Bool): Void {
		_oracleRelaxed = relaxed;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'an @:isVar on a property whose physical field nothing can reach — no accessor body, @:bypassAccessor, initializer or '
			+ 'reflective name mentions it';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final wide: SymbolIndex = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		final ctx: Ctx = {
			plugin: plugin,
			shape: plugin.refShape(),
			scope: ReflectionScan.scopeFiles(files, plugin),
			reflection: ReflectionScan.reflectionSurface(files, plugin),
			oracleVerified: _oracleRelaxed,
			fold: plugin.stringFoldSupport()
		};
		return RunScan.collect(files, plugin, (entry, tree, out) -> {
			if (MemberWriteScan.coreApiPinsMemberShape(entry.source)) return;
			final scopeIndex: SymbolIndex = wide.fileInfo(entry.file) == null ? index : wide;
			final info: Null<FileInfo> = scopeIndex.fileInfo(entry.file);
			if (info == null) return;
			final branch: MemberBranchSeams = MemberBranchScan.seamsOf(ctx.shape, entry.source, plugin.lexicalRegions.bind(entry.source));
			for (cls in CheckScan.classBodies(tree)) considerClass(out, cls, entry.source, scopeIndex, info, ctx, branch);
		});
	}

	/** Delete each flagged `@:isVar`, with the whitespace or line it leaves behind (`AccessorClauseText.metaRemovalSpan`). */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final edits: Array<FixEdit> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null && v.declineReason == null && isVarSpelling(source.substring(span.from, span.to)))
				edits.push({ span: AccessorClauseText.metaRemovalSpan(source, span), text: '' });
		}
		return edits;
	}

	/**
	 * Flag every `@:isVar` property of `cls` whose storage no code in scope can reach. The per-member
	 * shape gates run first; the owner's index-resolved gates and the scope scan only for a class that
	 * holds a candidate at all.
	 */
	private static function considerClass(
		out: Array<Violation>, cls: QueryNode, source: String, scopeIndex: SymbolIndex, host: FileInfo, ctx: Ctx, branch: MemberBranchSeams
	): Void {
		final owner: Null<String> = cls.name;
		if (owner == null) return;
		final declared: Null<TypeDeclInfo> = host.types.find(t -> t.name == owner);
		if (declared == null || declared.hasKeep || declared.isExtern) return;
		final candidates: Array<Candidate> = [];
		MemberBranchScan.eachMember(branch, cls, child -> MemberKinds.isMemberDeclKind(child.kind), (child, run, certain) -> {
			final candidate: Null<Candidate> = certain ? candidateOf(child, run, source, ctx.shape) : null;
			if (candidate != null) candidates.push(candidate);
		});
		if (candidates.length == 0) return;
		if (scopeIndex.traits.transitivelyCarriesRtti(owner) || !scopeIndex.subtypes.supertypeChainResolved(owner)) return;
		// A builder may generate an access to the field that no text here holds; without the metadata
		// that access is a compile error, so only an oracle-verified fix may remove it.
		final declined: Bool = !ctx.oracleVerified
			&& (declared.hasBuild || scopeIndex.traits.transitivelyCarriesBuildMacro(owner, host.file));
		for (c in candidates) if (!ReflectionScan.runtimeName(ctx.reflection, c.name) && !storageReachable(ctx, c.name)) {
			final finding: Violation = {
				file: host.file,
				span: c.meta,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'redundant @:isVar on ${c.name}: no accessor body, @:bypassAccessor or initializer reaches its storage'
			};
			if (declined) finding.declineReason = MACRO_DECLINE;
			out.push(finding);
		}
	}

	/**
	 * The property `member` declares when it is a shape this rule judges — an `@:isVar` in its modifier
	 * run `run`, both accessor slots storageless, no initializer — or null.
	 */
	private static function candidateOf(member: QueryNode, run: Array<QueryNode>, source: String, shape: RefShape): Null<Candidate> {
		final name: Null<String> = member.name;
		final span: Null<Span> = member.span;
		if (name == null || span == null || CheckScan.METHOD_KINDS.contains(member.kind)) return null;
		// `@:keep` pins the member against removal because machinery no scan models reaches it.
		final retained: Null<String> = shape.retainedDeclMetaName;
		if (retained != null && run.exists(n -> MemberKinds.META_KINDS.contains(n.kind) && n.name == retained)) return null;
		// An argument-less `@:isVar()` is the same metadata; one carrying arguments is not a spelling `fix` removes.
		final metaSpan: Null<Span> = run.find(n ->
			MemberKinds.META_KINDS.contains(n.kind) && n.name == IS_VAR_META && n.children.length == 0
		)?.span;
		final access: Null<{ read: String, write: String }> = AccessorClauseText.accessorClause(source, span);
		return metaSpan != null && access != null && STORAGELESS_SLOTS.contains(access.read) && STORAGELESS_SLOTS.contains(access.write)
			&& CtorFieldFold.declInitializer(member, shape) == null
			? { name: name, meta: metaSpan }
			: null;
	}

	/**
	 * Whether any scope file may reach the physical field of the property `name`: a file spelling the
	 * name that does not parse, an unparsed `#if` region spelling it, or a construct `touchesStorage`
	 * reports.
	 */
	private static function storageReachable(ctx: Ctx, name: String): Bool {
		final accessors: Array<String> = [CheckScan.GET_PREFIX + name, CheckScan.SET_PREFIX + name];
		for (entry in ctx.scope) if (RawSourceScan.mentionsWord(entry.source, name)) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(ctx.plugin, entry.source);
			if (tree == null) return true;
			if (CondRegionScan.opaqueCondRegionMentioning(tree, entry.source, name, ctx.shape) != null) return true;
			if (touchesStorage(tree, entry.source, name, accessors, ctx)) return true;
		}
		return false;
	}

	/**
	 * Whether the subtree under `node` holds a method named one of `accessors`, a construct carrying
	 * `@:bypassAccessor`, or a native-code carrier (`NativeCodeScan.isCarrier`), whose text mentions `name` as a
	 * standalone identifier. Text rather than resolution: inside an accessor body a mention may reach the
	 * field in any spelling — bare, `this.`-qualified, interpolated — and inside target code it is not
	 * Haxe at all; a mention that reaches nothing only costs a finding.
	 */
	private static function touchesStorage(node: QueryNode, source: String, name: String, accessors: Array<String>, ctx: Ctx): Bool {
		final span: Null<Span> = node.span;
		final nodeName: Null<String> = node.name;
		final accessor: Bool = nodeName != null && CheckScan.METHOD_KINDS.contains(node.kind) && accessors.contains(nodeName);
		final bypass: Bool = node.children.exists(c -> MemberKinds.META_KINDS.contains(c.kind) && c.name == BYPASS_META);
		if (
			span != null && (accessor || bypass || NativeCodeScan.isCarrier(node, ctx.shape, ctx.fold))
			&& SourceText.mentionsIdent(source, span, name)
		)
			return true;
		return node.children.exists(c -> touchesStorage(c, source, name, accessors, ctx));
	}

	/** Whether `text` is the whole `@:isVar` metadata as `fix` may delete it — bare, or with an empty argument list. */
	private static function isVarSpelling(text: String): Bool {
		return text == IS_VAR_META || text.replace(' ', '').replace('\t', '') == '$IS_VAR_META()';
	}

}

/** One `@:isVar` property that cleared the per-member shape gates. */
private typedef Candidate = {

	/** The property's name — the token every scope scan asks about. */
	final name: String;

	/** The `@:isVar` metadata's own span, which the finding reports and `fix` deletes. */
	final meta: Span;

};

/** The run-wide evidence every candidate is judged against. */
private typedef Ctx = {

	/** The grammar plugin, for parsing scope files. */
	final plugin: GrammarPlugin;

	/** The grammar's reference shape, resolved once per run. */
	final shape: RefShape;

	/** Report UNION the resolution sources — every file that may reach the field. */
	final scope: Array<{ file: String, source: String }>;

	/** Every string in scope a member name may be reached by at runtime. */
	final reflection: ReflectionSurface;

	/** Whether the fix runs under a compiler oracle — a macro-built owner's finding is declined without one. */
	final oracleVerified: Bool;

	/** The grammar's string-fold support, which names the target intrinsics; null when it exposes none. */
	final fold: Null<StringFoldSupport>;

};
