package anyparse.check.common.members;

import anyparse.check.Check.FixEdit;
import anyparse.check.Check.RiskyFix;
import anyparse.check.scan.AccessorClauseText;
import anyparse.check.scan.CheckScan;
import anyparse.check.scan.PropertyStorage;
import anyparse.check.scan.ReflectionScan;
import anyparse.query.CtorFieldFold;
import anyparse.query.FieldWriteIndex;
import anyparse.query.MemberKinds;
import anyparse.query.MemberWriteScan;
import anyparse.query.SymbolIndex;

/**
 * Flags a property whose physical field nothing ever stores. Its read slot is `default` / `null`, so a plain read
 * returns the field, but its write slot is `set` and its own set accessor never names it: the value a write hands
 * over lands elsewhere or nowhere, and every read sees the field's initial value. `Warning`, report-only — storing
 * the value changes what every read returns, which is the decision the finding hands to a human.
 *
 * When nothing in scope reads the property at all, the readable field is a promise nobody holds it to: the finding
 * is `Info`, and its fix turns the read slot into `never`. The fix rests on a negative whole-project proof, so it
 * is a `RiskyFix`: applied only under a compiler oracle, typechecked and reverted on failure.
 *
 * ## Gates — all must hold
 *
 * 1. The clause is `(default | null, set)`, the member has no declaration initializer (which would store the
 *    field), its owner is no extern (the native side holds the storage), and its own type declares the `set_`
 *    accessor with a body that never names it (`PropertyStorage.unstoredBy`).
 * 2. Nothing else in scope reaches the storage: no accessor of the name anywhere, `@:bypassAccessor` construct or
 *    target-code carrier mentions it (`PropertyStorage.storageReachable`), no reflective string names it, and no
 *    write of the name escapes type attribution (`FieldWriteIndex.hasUnresolvedWrite` — a write through `Dynamic`
 *    lands in the field past the setter).
 * 3. The fix only: no read of the name anywhere in scope (`PropertyStorage.readAnywhere` — by name, so an
 *    unrelated member of that name refuses), no code enumerating object fields (`ReflectionScan.enumeratesObjects`),
 *    no metadata on the member, an owner with a resolved supertype chain and no `@:keep` / `@:rtti`.
 *
 * ## Residual
 *
 * A setter that READS its property without writing it (a change guard against a field that is never set) names
 * it and is not reported; a name the std spells is counted as read, so a property named like `size` or `length` gets the
 * Warning, never the Info fix; a build macro or a library writing the field by name stores it where no text shows; an
 * object printed without a call naming it — `trace(o)`, a `$o` interpolation — still shows the field the fix removes.
 */
@:nullSafety(Strict)
final class UnstoredProperty extends RuleBase implements RiskyFix {

	/** This check's stable id, spelled once. */
	private static inline final RULE_ID: String = 'unstored-property';

	public function new() {
		super(
			RULE_ID,
			'a property whose plain reads return its field while its set accessor never stores it — every read sees the '
			+ 'initial value; when nothing reads it either, its read access can be never',
			RuleCategory.Members
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final index: SymbolIndex = IndexScope.report(files, plugin);
		final wide: SymbolIndex = IndexScope.resolutionIndexOf(plugin) ?? index;
		final r: RunState = {
			files: files,
			storage: {
				plugin: plugin,
				shape: shape,
				scope: ReflectionScan.scopeFiles(files, plugin),
				fold: plugin.stringFoldSupport()
			},
			reflection: ReflectionScan.reflectionSurface(files, plugin),
			propertyKinds: shape.mutableFieldDeclKinds ?? [],
			runKinds: (shape.modifierKinds ?? []).concat(MemberKinds.META_KINDS),
			writes: null,
			enumerates: null
		};
		return RunScan.collect(files, plugin, (entry, tree, out) -> {
			if (MemberWriteScan.coreApiPinsMemberShape(entry.source)) return;
			final scopeIndex: SymbolIndex = wide.fileInfo(entry.file) == null ? index : wide;
			for (cls in CheckScan.classBodies(tree)) {
				// an extern's storage lives on the native side, which no text here shows writing it
				final declared: Null<TypeDeclInfo> = scopeIndex.fileInfo(entry.file)?.types.find(t -> t.name == cls.name);
				if (declared != null && declared.isExtern) continue;
				for (method in cls.children) considerSetter(r, method, cls, entry.file, entry.source, scopeIndex, out);
			}
		});
	}

	/** Turn the read accessor of each fixable finding's property into `never`. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final edits: Array<FixEdit> = [];
		for (v in violations) {
			final at: Null<Span> = v.span;
			if (at == null || v.declineReason != null || v.severity != Severity.Info) continue;
			final span: Span = at;
			final clause: Null<AccessorClause> = AccessorClauseText.accessorClause(source, span);
			if (clause == null || !AccessorClauseText.readsFieldWritesThroughSetter(clause)) continue;
			final edit: Null<FixEdit> = AccessorClauseText.neverReadEdit(source, span);
			if (edit != null) edits.push(edit);
		}
		return edits;
	}

	/**
	 * Why the owner keeps the property's read slot: an owner the index cannot place, one pinned by `@:keep` or
	 * described by `@:rtti`, a supertype chain that does not resolve or that declares the name — or null.
	 */
	private static function ownerDecline(owner: Null<String>, file: String, index: SymbolIndex): Null<String> {
		final declared: Null<TypeDeclInfo> = owner == null ? null : index.fileInfo(file)?.types.find(t -> t.name == owner);
		if (owner == null || declared == null) return 'the owner is not indexed, so its supertypes and metadata are unknown';
		final info: TypeDeclInfo = declared;
		if (info.hasKeep) return 'the owner is kept, so its field may be reached by name';
		if (index.traits.transitivelyCarriesRtti(owner)) return 'the owner carries runtime type information, which describes the field';
		// a supertype in scope declaring the name is already a read by name; one out of scope leaves the chain unresolved
		return index.subtypes.supertypeChainResolved(owner) ? null : 'a supertype outside the scope may declare the property';
	}

	/** Whether the modifier run of `property` in `cls` holds metadata. */
	private static function carriesMetadata(property: QueryNode, cls: QueryNode, runKinds: Array<String>): Bool {
		return MemberKinds.precedingModifiers(property, cls, runKinds).exists(m -> MemberKinds.META_KINDS.contains(m.kind));
	}

	/**
	 * Report the property `method` is the set accessor of, in `cls` of `file`, when it clears every storage gate: a
	 * Warning when anything may read it, else an Info finding whose fix is declined when a fix gate fails.
	 */
	private static function considerSetter(
		r: RunState, method: QueryNode, cls: QueryNode, file: String, source: String, scopeIndex: SymbolIndex, out: Array<Violation>
	): Void {
		final shape: RefShape = r.storage.shape;
		final reflection: ReflectionSurface = r.reflection;
		final found: Null<QueryNode> = PropertyStorage.unstoredBy(method, cls, source, r.propertyKinds, shape.noBodyKind);
		final named: Null<String> = found?.name;
		final at: Null<Span> = found?.span;
		if (found == null || named == null || at == null) return;
		final property: QueryNode = found;
		final name: String = named;
		final span: Span = at;
		if (
			CtorFieldFold.declInitializer(property, shape) != null || ReflectionScan.runtimeName(reflection, name)
			|| PropertyStorage.storageReachable(r.storage, name)
		)
			return;
		// a write the index cannot place on a type — through `Dynamic`, say — may land in the field past the setter
		final writes: FieldWriteIndex = r.writes ?? IndexScope.resolutionWrites(r.files, r.storage.plugin);
		r.writes = writes;
		if (writes.hasUnresolvedWrite(name, file)) return;
		final where: String = 'property `$name` is never stored: `${CheckScan.SET_PREFIX}$name` does not assign it and nothing else in '
			+ 'scope writes its field';
		if (PropertyStorage.readAnywhere(r.storage, name, file, span)) {
			out.push({
				file: file,
				span: span,
				rule: RULE_ID,
				severity: Severity.Warning,
				message: '$where, so every read of it sees its initial value'
			});
			return;
		}
		out.push({
			file: file,
			span: span,
			rule: RULE_ID,
			severity: Severity.Info,
			message: '$where, and nothing reads it — its read access can be never',
			declineReason: carriesMetadata(property, cls, r.runKinds)
				? 'the property carries metadata, which may reach its field in a way no text here shows'
				: enumerates(r)
					? 'code in scope may list or render an object\'s fields, which sees the field this fix removes'
					: ownerDecline(cls.name, file, scopeIndex)
		});
	}

	/** Whether the run's scope may enumerate an object's fields (`ReflectionScan.enumeratesObjects`), asked once per run. */
	private static function enumerates(r: RunState): Bool {
		final answer: Bool = r.enumerates ?? ReflectionScan.enumeratesObjects(r.files, r.storage.plugin);
		r.enumerates = answer;
		return answer;
	}

}

/** The run-wide evidence of one `run`, two whole-scope answers among it computed on first need. */
private typedef RunState = {

	/** The report set the run was given. */
	final files: Array<{ file: String, source: String }>;

	/** The scope and grammar the storage scans read. */
	final storage: StorageScope;

	/** Every string in scope a member name may be reached by at runtime. */
	final reflection: ReflectionSurface;

	/** The grammar's mutable field declaration kinds. */
	final propertyKinds: Array<String>;

	/** The kinds of a member's modifier and metadata run. */
	final runKinds: Array<String>;

	/** The scope's field write index, once a candidate needs it. */
	var writes: Null<FieldWriteIndex>;

	/** Whether the scope enumerates object fields, once an Info finding needs it. */
	var enumerates: Null<Bool>;

};
