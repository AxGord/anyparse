package unit.check;

import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.TypeSyntax;
import anyparse.runtime.Span;

/**
 * The Haxe plugin standing in for a SECOND grammar whose annotations project under other kind names and trail the
 * modifiers they belong to: `Meta` / `MetaCall` come out as `Annot` / `AnnotCall`, and an annotation written before
 * `private` is moved after it. `metaShape` declares the new names and every other method delegates, so a rule that reads
 * the annotation kinds from a Haxe table instead of `metaShape` sees no annotation here.
 */
@:nullSafety(Strict)
final class RenamedAnnotationPlugin implements GrammarPlugin {

	public static final BARE_KIND: String = 'Annot';
	public static final CALL_KIND: String = 'AnnotCall';

	private final _inner: HaxeQueryPlugin = new HaxeQueryPlugin();

	public function new() {}

	public function langName(): String {
		return _inner.langName();
	}

	public function parseFile(source: String): QueryNode {
		return recast(_inner.parseFile(source));
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
		final inner: MetaShape = _inner.metaShape();
		return { metaKinds: inner.metaKinds.map(renamed), declHostKinds: inner.declHostKinds };
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
		return null;
	}

	/** `node` and its descendants under the renamed annotation kinds, each annotation moved behind the `private` that follows it. */
	private function recast(node: QueryNode): QueryNode {
		final children: Array<QueryNode> = node.children.map(recast);
		final privateKind: Null<String> = _inner.refShape().privateModifierKind;
		var i: Int = 0;
		while (i + 1 < children.length) {
			if (
				privateKind != null
				&& children[i + 1].kind == privateKind
				&& (children[i].kind == BARE_KIND || children[i].kind == CALL_KIND)
			) {
				final annotation: QueryNode = children[i];
				children[i] = children[i + 1];
				children[i + 1] = annotation;
				i++;
			}
			i++;
		}
		return new QueryNode(renamed(node.kind), node.name, children, node.span, node.type, node.typeArgCount);
	}

	/** The kind a Haxe annotation kind is projected as here; every other kind is unchanged. */
	private static function renamed(kind: String): String {
		return switch kind {
			case 'Meta': BARE_KIND;
			case 'MetaCall': CALL_KIND;
			case _: kind;
		};
	}

}
