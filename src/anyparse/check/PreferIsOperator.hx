package anyparse.check;

import anyparse.check.Check.VersionGated;
import anyparse.check.scan.CheckScan;
import anyparse.check.scan.RunScan;
import anyparse.query.IndexScope;
import anyparse.query.ParenGuard;
import anyparse.query.SymbolIndex;
import anyparse.query.ValueDoors;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Flags a two-argument `Std.isOfType(x, T)` whose second argument names a type and rewrites it to the operator it is the
 * sugar of, `x is T` (`RefShape.isExprCall`, `isOperatorText`) — `Severity.Info`, never past a declared `languageVersion`
 * older than the operator.
 *
 * The operator reads `T` as a TYPE and calls the std's own `Std`, so a site is rewritten only where both spellings mean
 * the same: the receiver binds the std's type (`receiverIsStd`), and `T` is a bare name that binds no value
 * (`namesType`) — `Std.isOfType(x, kind)` over a `Class<T>` parameter stays. A dotted argument and a qualified
 * receiver are declined. Parentheses are `ParenGuard`'s, asked of the parser: a value operand that would bind across the
 * operator and an operator under `!` are wrapped, nothing else. A call carrying a comment the rewrite would drop, and one
 * inside an annotation argument or a reification, are skipped.
 */
@:nullSafety(Strict)
final class PreferIsOperator extends RuleBase implements VersionGated {

	public function new() {
		super(
			'prefer-is-operator',
			'a Std.isOfType(x, T) call whose second argument names a type, replaceable with the is operator (x is T)', RuleCategory.Types
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		return RunScan.collectWith(files, plugin, seamsOf(plugin), (entry, tree, seams, violations) -> {
			final proof: Proof = {
				file: entry.file,
				source: entry.source,
				root: tree,
				shape: plugin.refShape(),
				seams: seams,
				plugin: plugin,
				index: index
			};
			walk(tree, proof, violations);
		});
	}

	/**
	 * Rewrite each flagged call to `<value> <operator> <type>`, the value operand
	 * and the whole result parenthesised where the parser would read them otherwise.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return RunScan.editsWith(plugin, source, seamsOf(plugin), (_, seams) -> {
			final guarded: Array<GuardedEdit> = [];
			CheckScan.applyBySpan(plugin, source, violations, [seams.callKind], (node, span) -> {
				final args: Null<CallArgs> = argsOf(node, seams);
				final edit: Null<GuardedEdit> = args == null ? null : rewrite(span, args, source, seams);
				if (edit != null) guarded.push(edit);
				return null;
			});
			return ParenGuard.guard(source, guarded, plugin);
		});
	}

	/** The operator is Haxe 4.2; a project declaring an older `languageVersion` is not told to write it. */
	public function minLanguageVersion(): String {
		return '4.2';
	}

	/**
	 * Flag every proven call under `node` (`proven`), the outermost one only: a flagged call is not descended into, so two
	 * findings never overlap, and a call nested in its value operand is found by the next `--fix` pass. A reification and an
	 * annotation argument are skipped whole — their code is read as syntax.
	 */
	private static function walk(node: QueryNode, proof: Proof, out: Array<Violation>): Void {
		final seams: Seams = proof.seams;
		if (seams.opaqueKinds.contains(node.kind) || seams.metaKinds.contains(node.kind)) return;
		final args: Null<CallArgs> = argsOf(node, seams);
		final span: Null<Span> = node.span;
		if (args != null && span != null && rewrite(span, args, proof.source, seams) != null && proven(args, proof)) {
			out.push({
				file: proof.file,
				span: span,
				rule: 'prefer-is-operator',
				severity: Severity.Info,
				message: 'this ${seams.call}() call names a type: it can be the ${seams.keyword} operator'
			});
			return;
		}
		for (c in node.children) walk(c, proof, out);
	}

	/** The receiver, value and type argument of `node` when it is a two-argument `seams.call` through a bare receiver; else null. */
	private static function argsOf(node: QueryNode, seams: Seams): Null<CallArgs> {
		if (node.kind != seams.callKind || node.children.length != 3) return null;
		final callee: QueryNode = node.children[0];
		if (callee.kind != seams.fieldAccessKind || callee.name != seams.method || callee.children.length != 1) return null;
		final receiver: QueryNode = callee.children[0];
		return receiver.kind != seams.identKind || receiver.name != seams.owner
			? null
			: { receiver: receiver, value: node.children[1], type: node.children[2] };
	}

	/**
	 * The edit replacing the call at `span` with `<value> <operator> <type>`, the value registered as a hole for `ParenGuard`;
	 * null when an argument has no span, the type argument is not a bare name, or a comment sits in the call outside its
	 * arguments, which the rewrite would drop.
	 */
	private static function rewrite(span: Span, args: CallArgs, source: String, seams: Seams): Null<GuardedEdit> {
		final value: Null<Span> = args.value.span;
		final type: Null<Span> = args.type.span;
		if (value == null || type == null || args.type.kind != seams.identKind) return null;
		final gaps: Array<String> = [
			source.substring(span.from, value.from),
			source.substring(value.to, type.from),
			source.substring(type.to, span.to)
		];
		if (gaps.exists(gap -> gap.indexOf('//') != -1 || gap.indexOf('/*') != -1)) return null;
		final valueText: String = source.substring(value.from, value.to).trim();
		final text: String = '$valueText ${seams.keyword} ${source.substring(type.from, type.to).trim()}';
		return { span: span, text: text, holes: [new Span(0, valueText.length)] };
	}

	/**
	 * Whether the receiver of `args` is the std's type, its type argument names a type (`receiverIsStd`, `namesType`), and its
	 * value types alike without the call's expectation (`ExpectedTypes.unifiesUnderExpectation`): the operator types its
	 * operand with nothing expected of it, where the call expects `Dynamic`.
	 */
	private static function proven(args: CallArgs, proof: Proof): Bool {
		final index: Null<SymbolIndex> = proof.index();
		final fi: Null<FileInfo> = index?.fileInfo(proof.file);
		return index != null && fi != null && !index.typing.expectations.unifiesUnderExpectation(args.value)
			&& receiverIsStd(args.receiver, index, fi, proof) && namesType(args.type, index, fi, proof);
	}

	/**
	 * Whether the bare receiver binds the std's type of its name, the one the operator calls: no value of the name is in
	 * scope (`ValueDoors.bindsNoValue`) and the type name binds the std's declaration (`TypeNameBinding.bindsStdDeclaration`).
	 */
	private static function receiverIsStd(receiver: QueryNode, index: SymbolIndex, fi: FileInfo, proof: Proof): Bool {
		final span: Null<Span> = receiver.span;
		final name: String = proof.seams.owner;
		return span != null && ValueDoors.bindsNoValue(receiver, name, span, fi, proof.root, proof.shape, proof.file, index)
			&& index.refs.names.bindsStdDeclaration(name, fi, span.from);
	}

	/**
	 * Whether the bare name `type` reads the same as a value argument and as the operator's type: it binds no value
	 * (`ValueDoors.bindsNoValue`), so the call reads it as the type the operator's type position finds.
	 */
	private static function namesType(type: QueryNode, index: SymbolIndex, fi: FileInfo, proof: Proof): Bool {
		final name: Null<String> = type.name;
		final span: Null<Span> = type.span;
		return name != null && span != null && ValueDoors.bindsNoValue(type, name, span, fi, proof.root, proof.shape, proof.file, index);
	}

	/** The seams both halves read, or null when the grammar declares no is-operator call, keyword or call kind. */
	private static function seamsOf(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final call: Null<String> = shape.isExprCall;
		final keyword: Null<String> = shape.isOperatorText;
		final callKind: Null<String> = shape.callKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (call == null || keyword == null || callKind == null || fieldAccessKind == null) return null;
		final dot: Int = call.lastIndexOf('.');
		final owner: String = call.substring(0, dot);
		return dot <= 0 || owner.indexOf('.') != -1 ? null : {
			call: call,
			owner: owner,
			method: call.substring(dot + 1),
			keyword: keyword,
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			identKind: shape.identKind,
			opaqueKinds: shape.opaqueKinds ?? [],
			metaKinds: plugin.metaShape().metaKinds
		};
	}

}

/** The grammar's spellings `PreferIsOperator` reads in both `run` and `fix`. */
private typedef Seams = {
	final call: String;
	final owner: String;
	final method: String;
	final keyword: String;
	final callKind: String;
	final fieldAccessKind: String;
	final identKind: String;
	final opaqueKinds: Array<String>;
	final metaKinds: Array<String>;
};

/** The parts of one candidate call. */
private typedef CallArgs = {
	final receiver: QueryNode;
	final value: QueryNode;
	final type: QueryNode;
};

/** What a `run` proof of one file reads. */
private typedef Proof = {
	final file: String;
	final source: String;
	final root: QueryNode;
	final shape: RefShape;
	final seams: Seams;
	final plugin: GrammarPlugin;
	final index: () -> Null<SymbolIndex>;
};
