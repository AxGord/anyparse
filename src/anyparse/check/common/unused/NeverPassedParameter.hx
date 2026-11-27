package anyparse.check.common.unused;

import anyparse.check.Check.NoAutofix;
import anyparse.check.scan.ReflectionScan;
import anyparse.query.CallSites;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;

/**
 * Flags a trailing optional or defaulted parameter that no call of its function passes: a named local
 * function, or a private method whose callers are confined to its file (`isPrivateMemberConfined`), every
 * call of which provably leaves the parameter out (`CallSites.collect`). The default is then the only value
 * the parameter ever holds, so it is a constant dressed as an argument.
 *
 * Report-only (`Info`, no fix). A PUBLIC method is never reported: its parameter may be room for an
 * extension a caller outside the file will use, which is the reason `unused-parameter` removes a parameter
 * only from a function with no outside caller. Skipped: a method of a type with a supertype clause (override
 * / interface contract), a function captured as a value or reached by a runtime name string, an operator
 * overload, a `dynamic` function, a compiler-supplied parameter (`compilerSuppliedParamTypes`), a function
 * with a rest parameter (a spread argument can fill the slots before it), and a function with no call at all
 * (`unused-private`s territory). It is its own rule rather than an option of `unused-parameter` because its
 * predicate is "never passed", not "never referenced": the body usually DOES read the parameter.
 */
@:nullSafety(Strict)
final class NeverPassedParameter extends RuleBase implements NoAutofix {

	private static inline final RULE_ID: String = 'never-passed-parameter';

	public function new() {
		super(
			RULE_ID, 'trailing optional / defaulted parameter that no call of a private method or local function passes',
			RuleCategory.Unused
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		if ((shape.functionKinds ?? []).length == 0 || (shape.paramKinds ?? []).length == 0) return [];
		// The confinement proof reads the widest index there is, as `unused-parameter` does: a subtype or an
		// access grant in a file outside the report scope can only turn a finding off.
		final index: SymbolIndex = IndexScope.widest(files, plugin);
		final reflection: ReflectionSurface = ReflectionScan.reflectionSurface(files, plugin);
		return RunScan.collect(files, plugin, (entry, tree, violations) -> {
			final captured: Array<String> = UnusedParameter.valueCapturedNames(tree, shape);
			final operators: Array<Int> = AnnotatedDeclScan.memberStarts(plugin, tree, shape.operatorOverloadMetaName);
			for (c in UnusedParameter.candidateFunctions(tree, shape)) if (!AnnotatedDeclScan.covers(c.fn.span, operators))
				checkFunction(violations, entry.file, entry.source, c.fn, c.parent, tree, shape, index, reflection, captured);
		});
	}

	/** No edit: dropping the parameter folds its default into the body, which the author decides. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	public function noAutofixReason(): String {
		return 'removing the parameter folds its default into the body, and whether the slot is deliberate room for a later caller is'
			+ ' the author\'s call';
	}

	/** Whether a call may omit `param`: a `?x` parameter, or one that carries a default-value child. */
	private static inline function isOptionalSlot(param: QueryNode, shape: RefShape): Bool {
		return param.kind == shape.optionalParamKind || param.children.length > 0;
	}

	/**
	 * Append a violation for every parameter of `fn` that lies in its trailing optional run and sits at or past
	 * the widest argument list any call of `fn` passes. Nothing is reported unless the function has a complete,
	 * non-empty in-file call set and no outside caller is expressible.
	 */
	private static function checkFunction(
		out: Array<Violation>, file: String, source: String, fn: QueryNode, parent: QueryNode, tree: QueryNode, shape: RefShape,
		index: SymbolIndex, reflection: ReflectionSurface, captured: Array<String>
	): Void {
		final fnSpan: Null<Span> = fn.span;
		final fnName: Null<String> = fn.name;
		if (fnSpan == null || fnName == null) return;
		final name: String = fnName;
		if (captured.contains(name) || !isConfined(fn, parent, name, source, shape, index, reflection)) return;
		final restKind: Null<String> = shape.restParamKind;
		if (fn.children.exists(c -> c.kind == restKind)) return;
		final params: Array<QueryNode> = CallSites.leadingParams(fn, shape);
		for (pi in firstUnpassed(fn, params, tree, source, name, fnSpan.from, shape) ... params.length) {
			final paramName: Null<String> = params[pi].name;
			final pspan: Null<Span> = params[pi].span;
			if (paramName == null || pspan == null || isCompilerSupplied(params[pi], shape)) continue;
			out.push({
				file: file,
				span: pspan,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'parameter \'$paramName\' is never passed: every call of \'$name\' leaves it out'
			});
		}
	}

	/**
	 * The index where the run of optional / defaulted parameters that
	 * ends the list begins; `params.length` when the last one is required.
	 */
	private static function trailingOptionalFrom(params: Array<QueryNode>, shape: RefShape): Int {
		var from: Int = params.length;
		while (from > 0 && isOptionalSlot(params[from - 1], shape)) from--;
		return from;
	}

	/**
	 * The index of the first parameter no call passes and a call may omit; `params.length` when there is none. It
	 * needs a complete, non-empty in-file call set, so an unresolvable site or a function nobody calls reports nothing.
	 */
	private static function firstUnpassed(
		fn: QueryNode, params: Array<QueryNode>, tree: QueryNode, source: String, name: String, binding: Int, shape: RefShape
	): Int {
		final trailingFrom: Int = trailingOptionalFrom(params, shape);
		if (trailingFrom >= params.length) return params.length;
		final sites: Array<QueryNode> = switch CallSites.collect(fn, tree, source, name, binding, shape) {
			case CErr(_): return params.length;
			case COk(found): found;
		};
		if (sites.length == 0) return params.length;
		var passed: Int = 0;
		for (call in sites) if (call.children.length - 1 > passed) passed = call.children.length - 1;
		if (passed > params.length) return params.length;
		final from: Int = passed > trailingFrom ? passed : trailingFrom;
		// An argument may have skipped an optional slot below `from` (Haxe binds by type), so the positional count says nothing there.
		for (pi in 0...from) if (isOptionalSlot(params[pi], shape)) return params.length;
		return from;
	}

	/**
	 * Whether every caller of `fn` is in this file: a named local function, or a private method no subtype, access grant or
	 * runtime-name string (`Reflect.field(o, 'f')`) can reach, and not a `dynamic` slot that outside code reassigns.
	 */
	private static function isConfined(
		fn: QueryNode, parent: QueryNode, name: String, source: String, shape: RefShape, index: SymbolIndex, reflection: ReflectionSurface
	): Bool {
		if ((shape.localFunctionKinds ?? []).contains(fn.kind)) return true;
		final visibilityKinds: Array<String> = shape.visibilityModifierKinds ?? [];
		final modifierKinds: Array<String> = shape.modifierOrderKinds ?? [];
		final ownerName: Null<String> = parent.name;
		return ownerName != null
			&& !UnusedParameter.isDynamicFn(fn, parent, visibilityKinds, modifierKinds, shape.dynamicModifierKind)
			&& !UnusedParameter.isPublicDecl(fn, parent, source, visibilityKinds, modifierKinds)
			&& !ReflectionScan.runtimeName(reflection, name)
			&& RefactorSupport.isPrivateMemberConfined(ownerName, name, source, index);
	}

	/** Whether the compiler, not a caller, supplies `param` (Haxe `?pos: haxe.PosInfos`), so no call ever passes it by hand. */
	private static function isCompilerSupplied(param: QueryNode, shape: RefShape): Bool {
		final declared: Null<String> = param.type?.name;
		return declared != null && (shape.execution?.compilerSuppliedParamTypes ?? []).contains(declared);
	}

}
