package anyparse.check.scan;

import anyparse.check.scan.OperatorSelection.OperandTyping;
import anyparse.check.scan.OperatorSelection.OperatorVerdict;
import anyparse.check.scan.PurityScan.PurityCtx;
import anyparse.query.NominalTypes;
import anyparse.query.Refs;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoMemo;
import anyparse.query.TypeNameBinding.Tier;
import anyparse.query.TypeSyntax.TypeSyntaxReader;

/**
 * The one answer to "can code run inside this stretch of source with no call written in it": a read of a property getter,
 * an operator or an index access a type overloads, and a written type that converts the value it is given (`@:from`).
 *
 * Each is asked of the component that owns it — `PurityScan` for a name, a field or an index read, `OperatorSelection` for an
 * operator, `OperandBinder` for a written type — and anything they cannot place counts as running code: a window is quiet only
 * when it is PROVEN so. A call written in the stretch is the caller's question (`CallGraph`'s spans); here only an argument
 * of a call that opens before the stretch ends is asked, since its conversion runs ahead of the stretch's end.
 */
@:nullSafety(Strict)
final class UnseenCalls {

	private final _tree: QueryNode;
	private final _shape: RefShape;
	private final _annotations: () -> Map<Int, String>;
	private final _plainKinds: Array<String>;
	private final _wrappers: Array<String>;
	private final _typeSyntax: TypeSyntaxReader;
	private final _proofs: () -> Null<Proofs>;

	/** `selection`: the run's operator table, one for every file; `symbols`: the run's declarations, asked on the first window. */
	public function new(
		plugin: GrammarPlugin, file: String, source: String, tree: QueryNode, selection: () -> Null<OperatorSelection>,
		symbols: () -> Null<SymbolIndex>
	) {
		_tree = tree;
		_shape = plugin.refShape();
		var read: Null<Proofs> = null;
		_proofs = () -> {
			read ??= proofsOf(plugin, file, source, tree, selection(), symbols());
			read;
		};
		_typeSyntax = plugin.typeSyntax;
		_wrappers = _shape.memberTransparentWrapperTypeNames ?? [];
		_annotations = TypeInfoMemo.declaredTypeSources(RunScan.typeInfoOf(plugin), source);
		_plainKinds = (_shape.classDeclKinds ?? []).concat(_shape.interfaceDeclKinds ?? []).concat(_shape.runtimeTaggedTypeKinds ?? []);
	}

	/** Whether code may run between offset `from` and offset `to` that no call written there accounts for. */
	public function runsCode(from: Int, to: Int): Bool {
		final proofs: Null<Proofs> = _proofs();

		if (proofs == null) return true;
		for (at => written in _annotations()) if (at >= from && at < to && converts(written, at, proofs)) return true;
		return visit(_tree, from, to, proofs);
	}

	private function visit(node: QueryNode, from: Int, to: Int, proofs: Proofs): Bool {
		final span: Null<Span> = node.span;
		if (span != null) {
			if (span.to <= from || span.from >= to) return false;
			if (span.from >= from && span.to <= to) {
				if (runsOnItsOwn(node, proofs)) return true;
			} else if (opensAnArgumentBefore(node, to)) {
				return true;
			}
		}
		return node.children.exists(c -> visit(c, from, to, proofs));
	}

	/** Whether `node`, evaluated whole inside the window, is a getter read or an operator or index access a type overloads. */
	private function runsOnItsOwn(node: QueryNode, proofs: Proofs): Bool {
		final kind: String = node.kind;
		if (kind == _shape.identKind || kind == _shape.fieldAccessKind || kind == _shape.indexAccessKind)
			return !PurityScan.isPure(node, proofs.purity);
		if (!(_shape.pureOperatorKinds ?? []).contains(kind)) return false;
		final selection: Null<OperatorSelection> = proofs.selection;
		final typing: Null<OperandTyping> = proofs.typing;
		if (selection == null || typing == null) return selection != null;
		// `null` and a value written with a function or structure type carry no overload: the other operand decides
		final operands: Array<QueryNode> = node.children.filter(c -> c.kind != _shape.nullLiteralKind && !structural(c));
		final verdict: OperatorVerdict = operands.length == node.children.length
			? selection.verdictFor(node, [kind], typing)
			: selection.verdictOfOperands(operands, [kind], typing);
		return !verdict.match(Builtin);
	}

	/** Whether `operand` reads a binding written with a function or structure type, which no abstract can be. */
	private function structural(operand: QueryNode): Bool {
		final name: Null<String> = operand.name;
		final from: Null<Int> = operand.span?.from;
		if (operand.kind != _shape.identKind || name == null || from == null) return false;
		final binding: Null<Int> = Refs.bindingAt(name, from, _tree, _shape);
		final written: Null<String> = binding == null ? null : _annotations()[binding];
		return written != null && switch _typeSyntax(NominalTypes.memberLookupReceiverSource(written, _wrappers, _typeSyntax))?.shape {
			case Function(_, _, _), Structure(_): true;
			case _: false;
		};
	}

	/** Whether `call` opens before `to` and holds an operand that ends before it: converted to its parameter ahead of `to`. */
	private function opensAnArgumentBefore(call: QueryNode, to: Int): Bool {
		if (call.kind != _shape.callKind && call.kind != _shape.newExprKind) return false;
		for (i in 1...call.children.length) if ((call.children[i].span?.to ?? to) <= to) return true;
		return call.kind == _shape.newExprKind;
	}

	/** Whether a value written with the type `written` at `at` may be converted into it: anything but a plain nominal or a built-in. */
	private function converts(written: String, at: Int, proofs: Proofs): Bool {
		final binder: Null<OperandBinder> = proofs.binder;
		return binder == null || switch binder.writtenTier(written, at) {
			case Free: false;
			case Bound(decls): !decls.foreach(r -> _plainKinds.contains(r.type.kind));
			case Unknown: true;
		};
	}

	/** What a window is judged by, read from the run's index; null while that cannot be asked. */
	private static function proofsOf(
		plugin: GrammarPlugin, file: String, source: String, tree: QueryNode, selection: Null<OperatorSelection>, index: Null<SymbolIndex>
	): Null<Proofs> {
		final purity: Null<PurityCtx> = index == null ? null : PurityScan.contextOf(plugin, source, tree, index, file);
		return index == null || purity == null ? null : {
			purity: purity,
			selection: selection,
			typing: selection?.typingFor(file, source, tree),
			binder: OperandBinder.forFile(plugin, file, source, tree, index)
		};
	}

}

/** What `UnseenCalls` judges a window by: the purity context, the operator selection with its typing, the operand binder. */
private typedef Proofs = {
	final purity: PurityCtx;
	final selection: Null<OperatorSelection>;
	final typing: Null<OperandTyping>;
	final binder: Null<OperandBinder>;
};
