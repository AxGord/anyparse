package unit.check.haxe.expressions;

import anyparse.check.Check.FixEdit;
import anyparse.query.AccessorClause;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.Constructs;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;
import anyparse.query.SpanTypeInfoProvider;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.TokenSpans.TokenSpan;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeSyntax;

/**
 * The Haxe builder refusing every type spelled as one of `types`, every member of `members`, when `modifiers` every
 * modifier or constant-keyword edit, when `statements` every statement, run and literal it would build of parts and, when
 * `runs`, every run of statements it would copy, the rest delegating.
 */
@:nullSafety(Strict)
final class RefusingConstructs implements Constructs {

	private final _inner: Constructs;
	private final _types: Array<String>;
	private final _members: Array<String>;
	private final _modifiers: Bool;
	private final _statements: Bool;
	private final _runs: Bool;

	public function new(
		inner: Constructs, types: Array<String>, members: Array<String>, modifiers: Bool = false, statements: Bool = false,
		runs: Bool = false
	) {
		_inner = inner;
		_types = types;
		_members = members;
		_modifiers = modifiers;
		_statements = statements;
		_runs = runs;
	}

	public function copied(source: String, span: Span, kind: ConstructKind): Null<Built> {
		return _runs && kind == Statements ? null : _inner.copied(source, span, kind);
	}

	public function substituted(source: String, span: Span, part: Span, by: Built, kind: ConstructKind): Null<Built> {
		return _inner.substituted(source, span, part, by, kind);
	}

	public function typeRef(spelled: String): Null<Built> {
		return _types.contains(spelled) ? null : _inner.typeRef(spelled);
	}

	public function functionType(params: Array<Built>, result: Built): Null<Built> {
		return _inner.functionType(params, result);
	}

	public function qualified(owner: Built, name: String): Null<Built> {
		return _members.contains(name) ? null : _inner.qualified(owner, name);
	}

	public function call(callee: Built, args: Array<Built>): Null<Built> {
		return _inner.call(callee, args);
	}

	public function lambda(params: Array<String>, body: Built): Null<Built> {
		return _inner.lambda(params, body);
	}

	public function returning(value: Built): Null<Built> {
		return _inner.returning(value);
	}

	public function returningNothing(): Null<Built> {
		return _statements ? null : _inner.returningNothing();
	}

	public function continuing(): Null<Built> {
		return _statements ? null : _inner.continuing();
	}

	public function guard(condition: Built, exit: Built): Null<Built> {
		return _statements ? null : _inner.guard(condition, exit);
	}

	public function conditional(condition: Built, body: Built): Null<Built> {
		return _statements ? null : _inner.conditional(condition, body);
	}

	public function assignment(target: Built, value: Built): Null<Built> {
		return _statements ? null : _inner.assignment(target, value);
	}

	public function compoundAssignment(target: Built, op: Arithmetic, value: Built): Null<Built> {
		return _statements ? null : _inner.compoundAssignment(target, op, value);
	}

	public function local(kind: MemberKind, name: String, type: Null<Built>, value: Null<Built>): Null<Built> {
		return _statements ? null : _inner.local(kind, name, type, value);
	}

	public function forEach(binder: String, iterable: Built, body: Built): Null<Built> {
		return _statements ? null : _inner.forEach(binder, iterable, body);
	}

	public function forEachPair(key: String, value: String, iterable: Built, body: Built): Null<Built> {
		return _statements ? null : _inner.forEachPair(key, value, iterable, body);
	}

	public function block(parts: Array<Built>): Null<Built> {
		return _statements ? null : _inner.block(parts);
	}

	public function sequence(parts: Array<Built>): Null<Built> {
		return _statements ? null : _inner.sequence(parts);
	}

	public function range(from: Built, to: Built): Null<Built> {
		return _statements ? null : _inner.range(from, to);
	}

	public function arrayOf(items: Array<Built>): Null<Built> {
		return _statements ? null : _inner.arrayOf(items);
	}

	public function boolean(value: Bool): Null<Built> {
		return _statements ? null : _inner.boolean(value);
	}

	public function importOf(path: String): Null<Built> {
		return _inner.importOf(path);
	}

	public function usingOf(path: String): Null<Built> {
		return _inner.usingOf(path);
	}

	public function modifiers(set: Array<Modifier>): Null<Built> {
		return _inner.modifiers(set);
	}

	public function withModifier(head: DeclarationHead, modifier: Modifier): Null<FixEdit> {
		return _modifiers ? null : _inner.withModifier(head, modifier);
	}

	public function asConstant(source: String, start: Int): Null<FixEdit> {
		return _modifiers ? null : _inner.asConstant(source, start);
	}

	public function member(set: Array<Modifier>, kind: MemberKind, name: String, type: Null<Built>, value: Null<Built>): Null<Built> {
		return _inner.member(set, kind, name, type, value);
	}

}

/**
 * The Haxe plugin whose `constructs()` answers what `wrap` makes of the Haxe builder, every other method delegating — the way
 * a fix is driven against a grammar that refuses a construct, or builds none, which the real Haxe builder never does.
 */
@:nullSafety(Strict)
final class RefusingConstructsPlugin implements GrammarPlugin implements TypeInfoProvider implements SpanTypeInfoProvider {

	private final _inner: HaxeQueryPlugin = new HaxeQueryPlugin();
	private final _wrap: (Constructs) -> Null<Constructs>;

	public function new(wrap: (Constructs) -> Null<Constructs>) {
		_wrap = wrap;
	}

	public function constructs(): Null<Constructs> {
		final real: Null<Constructs> = _inner.constructs();
		return real == null ? null : _wrap(real);
	}

	public function langName(): String {
		return _inner.langName();
	}

	public function parseFile(source: String): QueryNode {
		return _inner.parseFile(source);
	}

	public function parsePattern(source: String): Pattern {
		return _inner.parsePattern(source);
	}

	public function refShape(): RefShape {
		return _inner.refShape();
	}

	public function projectedKinds(): Array<String> {
		return _inner.projectedKinds();
	}

	public function metaShape(): MetaShape {
		return _inner.metaShape();
	}

	public function selectKindEquivalence(): KindEquivalence {
		return _inner.selectKindEquivalence();
	}

	public function parseFileTypeRefs(source: String): QueryNode {
		return _inner.parseFileTypeRefs(source);
	}

	public function projectBranchAware(tree: QueryNode, source: String): QueryNode {
		return _inner.projectBranchAware(tree, source);
	}

	public function typeRefShape(): TypeRefShape {
		return _inner.typeRefShape();
	}

	public function writeRoundTrip(source: String, ?optsJson: String): Null<String> {
		return _inner.writeRoundTrip(source, optsJson);
	}

	public function layoutSplice(source: String, edits: Array<{ span: Span, text: String }>): Null<String> {
		return _inner.layoutSplice(source, edits);
	}

	public function layoutMetrics(?optsJson: String): Null<LayoutMetrics> {
		return _inner.layoutMetrics(optsJson);
	}

	public function memberGapPolicy(?optsJson: String): Null<MemberGapPolicy> {
		return _inner.memberGapPolicy(optsJson);
	}

	public function writeRoundTripPlain(source: String, ?optsJson: String): Null<String> {
		return _inner.writeRoundTripPlain(source, optsJson);
	}

	public function reconParse(source: String): Bool {
		return _inner.reconParse(source);
	}

	public function typeSyntax(typeSource: String): Null<TypeSyntax> {
		return _inner.typeSyntax(typeSource);
	}

	public function namingSupport(): Null<NamingSupport> {
		return _inner.namingSupport();
	}

	public function stringFoldSupport(): Null<StringFoldSupport> {
		return _inner.stringFoldSupport();
	}

	public function maxComplexity(path: String): Null<Int> {
		return _inner.maxComplexity(path);
	}

	public function controlFlowSupport(): Null<ControlFlowSupport> {
		return _inner.controlFlowSupport();
	}

	public function lexicalRegions(source: String): Array<LexRegion> {
		return _inner.lexicalRegions(source);
	}

	public function tokenSpans(source: String, from: Int, to: Int): Array<TokenSpan> {
		return _inner.tokenSpans(source, from, to);
	}

	public function booleanLogicSupport(): Null<BooleanLogicSupport> {
		return _inner.booleanLogicSupport();
	}

	public function knownExtensionMethods(modulePath: String): Null<Array<String>> {
		return _inner.knownExtensionMethods(modulePath);
	}

	public function checkOverrides(path: String): Null<CheckOverrides> {
		return _inner.checkOverrides(path);
	}

	public function ambientImportSources(path: String, pkg: String): AmbientImports {
		return _inner.ambientImportSources(path, pkg);
	}

	public function ambientImportGovernance(path: String): Null<AmbientImportGovernance> {
		return _inner.ambientImportGovernance(path);
	}

	public function ambientImportGovernedFiles(path: String): Null<AmbientImportGovernedFiles> {
		return _inner.ambientImportGovernedFiles(path);
	}

	public function ambientImportSites(path: String, pkg: String): Array<String> {
		return _inner.ambientImportSites(path, pkg);
	}

	public function typedOptionsRewrite(
		source: String, kit: String, reformat: Bool, ?optsJson: String, ?subjects: Array<String>
	): Null<EditResult> {
		return _inner.typedOptionsRewrite(source, kit, reformat, optsJson, subjects);
	}

	public function declaredTypes(source: String): Map<Int, String> {
		return _inner.declaredTypes(source);
	}

	public function returnTypes(source: String): Map<Int, String> {
		return _inner.returnTypes(source);
	}

	public function propertyAccessors(source: String): Map<Int, Bool> {
		return _inner.propertyAccessors(source);
	}

	public function propertyWriteAccessors(source: String): Map<Int, Bool> {
		return _inner.propertyWriteAccessors(source);
	}

	public function accessorClauses(source: String): Map<Int, AccessorClause> {
		return _inner.accessorClauses(source);
	}

	public function declaredTypeSources(source: String): Map<Int, String> {
		return _inner.declaredTypeSources(source);
	}

	public function castTargetSources(source: String): Map<Int, String> {
		return _inner.castTargetSources(source);
	}

	public function typeParamNames(source: String): Map<Int, Array<String>> {
		return _inner.typeParamNames(source);
	}

	public function importMap(source: String, ?path: String): Map<String, String> {
		return _inner.importMap(source, path);
	}

	public function spanTypeInfo(source: String): SpanTypeInfo {
		return _inner.spanTypeInfo(source);
	}

}
