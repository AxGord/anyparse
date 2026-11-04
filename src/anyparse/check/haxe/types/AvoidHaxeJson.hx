package anyparse.check.haxe.types;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.NoAutofix;
import anyparse.check.scan.RunScan;
import anyparse.query.IndexScope;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeNameBinding;
import anyparse.query.TypeResolver;

/**
 * Flags a use of `haxe.Json.parse` or `haxe.Json.stringify` — a call, or the function taken as a value (`a.map(Json.parse)`):
 * a JSON document read or written with no schema, which the project describes with its own JSON grammar instead. The message
 * names that way — a `@:schema(JsonFormat)` typedef with its generated parser and writer, which read and write through the
 * engine's own JSON where the format's native door is declared (`JsonFormat.nativeDoor`), or for a document with no fixed
 * shape `JValueParser` (a parse) / `JValueWriter` (a stringify).
 *
 * A bare receiver is the std type where the file binds its name to `haxe.Json` (`TypeNameBinding.bindingsOf`, an `import
 * haxe.Json as J` included); a local or parameter of that name (`TypeResolver.identBindingFrom`), a project type, a same-package
 * type outside the scan and an import of another `Json` are other receivers; `haxe.Json` written out always is. The rule only
 * reports, so a receiver it cannot read is not given the benefit of the doubt in the other direction: an import from outside
 * the index still binds. Another member of the type is not a finding. Off by default — the message is this project's convention.
 */
@:nullSafety(Strict)
final class AvoidHaxeJson extends HaxeRule implements NoAutofix implements DefaultOff {

	private static inline final RULE_ID: String = 'avoid-haxe-json';

	/** The std type the calls are on, as a file writes it bare and written out. */
	private static inline final JSON_TYPE: String = 'Json';

	private static inline final JSON_QUALIFIED: String = 'haxe.Json';

	/** The members that read or write a document, each with the raw-document type a schemaless use is sent to. */
	private static final ALTERNATIVES: Map<String, String> = ['parse' => 'JValueParser', 'stringify' => 'JValueWriter'];

	public function new() {
		super(
			RULE_ID, 'a use of haxe.Json parse or stringify, which reads or writes a JSON document through no schema', RuleCategory.Types
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final index: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		return fieldAccessKind == null
			? []
			: RunScan.collect(files, plugin, (entry, tree, out) -> {
				function walk(node: QueryNode): Void {
					final receiver: Null<QueryNode> = node.kind == fieldAccessKind && node.children.length > 0 ? node.children[0] : null;
					final span: Null<Span> = node.span;
					final receiverSpan: Null<Span> = receiver?.span;
					final method: String = node.name ?? '';
					final alternative: Null<String> = ALTERNATIVES[method];
					if (
						receiver != null
						&& span != null
						&& receiverSpan != null
						&& alternative != null
						&& isJson(receiver, entry.source.substring(receiverSpan.from, receiverSpan.to), entry.file, tree, shape, index())
					) out.push({
						file: entry.file,
						span: span,
						rule: RULE_ID,
						severity: Severity.Warning,
						message: 'haxe.Json.$method reads or writes a JSON document with no schema: declare a @:schema(JsonFormat) '
						+ 'typedef and use its generated parser and writer, which go through the engine\'s own JSON behind '
						+ 'JsonFormat.nativeDoor, or $alternative for a document with no fixed shape'
					});
					for (c in node.children) walk(c);
				}
				walk(tree);
			});
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

	public function noAutofixReason(): String {
		return 'the replacement is a schema typedef the project declares, with the shape of this document';
	}

	/**
	 * Whether `receiver`, written `written` in `file`, denotes `haxe.Json`: written out it always does; a bare name does unless
	 * a local or parameter of that name is in scope or the file binds the name to another type (declared in the index, or
	 * imported by a path other than `haxe.Json` from outside it; an alias binds the name it gives). A report-only rule flags
	 * unless it proves another receiver, so what the index cannot read stays the std type — a rewrite would need the proof
	 * the other way. With no index the spelling `Json` decides.
	 */
	private static function isJson(
		receiver: QueryNode, written: String, file: String, root: QueryNode, shape: RefShape, index: Null<SymbolIndex>
	): Bool {
		if (written == JSON_QUALIFIED) return true;
		if (written.indexOf('.') != -1) return false;
		final fi: Null<FileInfo> = index?.fileInfo(file);
		final span: Null<Span> = receiver.span;
		if (index == null || fi == null || span == null) return written == JSON_TYPE;
		if (TypeResolver.identBindingFrom(receiver, root, shape) != null) return false;
		return switch index.refs.names.bindingsOf(written, fi, span.from).bound {
			case InIndex(decls):
				decls.length > 0 && decls.foreach(d -> TypeNameBinding.canonicalPath(d) == JSON_QUALIFIED);
			case OutOfIndex(path): path == JSON_QUALIFIED;
			case null: false;
		};
	}

}
