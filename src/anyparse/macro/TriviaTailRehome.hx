package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.macro.MacroNames.*;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;

using Lambda;
using anyparse.macro.MetaInspect;

/**
 * Where the trivia parser puts a comment that directly follows a value: the `TailComments` class of a synth module.
 *
 * A list element `{a: 1}, // c` keeps `// c` on the ELEMENT — the parser reads the separator first. When the writer
 * drops that separator (`wrapping.trailingComma: remove`), the next parse meets `{a: 1} // c`, and the close literal of
 * the element's last construct takes the comment into its own slot. The writer has to lay the element out as that next
 * parse will read it, so it needs the tree the parser would have built: `rehome_<T>(value, comment)` answers that tree
 * for one paired value, or null when the parser would leave the comment where it is.
 *
 * Each function mirrors the trivia parser's own capture points, read off the same shape the parser is lowered from:
 *  - a close-peek `@:trivia` Star branch with a `@:trail` (`ArrayExpr`, `BlockExpr`) fills its `closeTrailing`;
 *  - a postfix Star branch (`Call`) fills its `closeTrailing`;
 *  - a struct `@:trivia` Star field with a `@:trail` (`HxObjectLit.fields`, `HxNewExpr.args`) fills `<field>TrailingClose`;
 *  - the value's last token sits in a nested value — an infix right operand, a ternary's else operand, a prefix operand,
 *    the one operand of a keyword or lead ctor, a struct's last PRESENT field — and the answer is that value's.
 * The list is a POSITIVE whitelist: any other shape (a trail literal after the value, a `@:wrap` pair, an optional `;`
 * already present, a meta this mirror does not know) answers null, so the writer keeps the comment where the source had
 * it — never a confident guess about a capture the parser may not make. A slot that already holds a comment answers null
 * as well: the parser would capture the first comment there and leave the second to the element.
 */
@:access(anyparse.macro.TriviaTypeSynth)
final class TriviaTailRehome {

	/** The synth module's class holding every `rehome_<T>`. */
	public static inline final CLASS_NAME: String = 'TailComments';

	/** The parameter every generated function receives the comment in. */
	private static inline final COMMENT_ARG: String = 'comment';

	/** The positional synth argument a close-trailing Alt branch carries its captured comment in. */
	private static inline final CLOSE_TRAILING_ARG: String = 'closeTrailing';

	/** Branch metas that put no token after the branch's operand. */
	private static final TRANSPARENT_BRANCH_METAS: Array<String> = [':kw', ':lead', ':fmt'];

	/** Field metas that put no token after the field's value (`:trailOpt` is read on its own). */
	private static final TRANSPARENT_FIELD_METAS: Array<String> = [':optional', ':kw', ':lead', ':fmt', ':absentOn', ':trailOpt'];

	/**
	 * Star-field metas a close-peek trivia Star carries; `:trail` is its close, the capture point. `:skimmable` only lets a
	 * declarations-only parse jump to the close — the capture after it runs either way.
	 */
	private static final STAR_FIELD_METAS: Array<String> = [':optional', ':lead', ':trail', ':sep', ':trivia', ':fmt', ':skimmable'];

	/**
	 * The writer-side reference to the function of a Star's element, `<pack>.trivia.Pairs.TailComments.rehome_<Simple>`;
	 * null when the element is not a Ref to a rule that carries trivia (the synth pass generated no function for it).
	 */
	public static function fnRefFor(elem: ShapeNode): Null<Expr> {
		if (elem.kind != Ref) return null;
		final rule: String = elem.annotations[AnnotationKeys.BASE_REF];
		if (!TriviaTypeSynth.refIsBearing(rule)) return null;
		return MacroStringTools.toFieldExpr(packOf(rule).concat([
			TriviaTypeSynth.SYNTH_SUBPACK,
			TriviaTypeSynth.SYNTH_MODULE_LEAF,
			CLASS_NAME,
			fnName(rule)
		]));
	}

	/** The `TailComments` class for one synth batch; `paired` are the batch's paired type definitions. */
	public static function buildClass(
		convertedNames: Array<String>, synthPack: Array<String>, paired: Array<TypeDefinition>
	): TypeDefinition {
		final pos: Position = Context.currentPos();
		final shape: ShapeBuilder.ShapeResult = TriviaTypeSynth.shapes[TriviaTypeSynth.shapes.length - 1];
		final fns: Array<Field> = [];
		for (origName in convertedNames) {
			final node: Null<ShapeNode> = shape.rules[origName];
			if (node == null) continue;
			final body: Null<Expr> = switch node.kind {
				case Seq: seqBody(node, pairedFieldNames(paired, origName));
				case Alt: altBody(origName, node, synthPack);
				case _: null;
			};
			if (body == null) continue;
			final pairedCT: ComplexType = TPath(
				{ pack: synthPack, name: simpleName(origName) + TriviaTypeSynth.PAIRED_SUFFIX, params: [] }
			);
			fns.push({
				name: fnName(origName),
				access: [APublic, AStatic],
				pos: pos,
				kind: FFun({
					args: [{ name: 'value', type: pairedCT }, { name: COMMENT_ARG, type: macro :String }],
					ret: TPath({ pack: [], name: 'Null', params: [TPType(pairedCT)] }),
					expr: macro return $body
				})
			});
		}
		return {
			pos: pos,
			pack: synthPack,
			name: CLASS_NAME,
			kind: TDClass(null, [], false, true, false),
			fields: fns,
			meta: [{ name: ':nullSafety', params: [macro Strict], pos: pos }]
		};
	}

	private static inline function fnName(rule: String): String {
		return 'rehome_${simpleName(rule)}';
	}

	/** Every field of `origName`'s paired struct, synth slots included — what a rebuilt copy has to carry. */
	private static function pairedFieldNames(paired: Array<TypeDefinition>, origName: String): Array<String> {
		final name: String = simpleName(origName) + TriviaTypeSynth.PAIRED_SUFFIX;
		final def: Null<TypeDefinition> = paired.find(d -> d.name == name);
		if (def == null) throw 'TriviaTailRehome: no paired definition for $origName';
		return switch def.kind {
			case TDAlias(TAnonymous(fields)): [for (f in fields) f.name];
			case _: throw 'TriviaTailRehome: $name is not an anonymous structure';
		};
	}

	/** Whether every meta `node` carries is one of `allowed`. */
	private static function onlyMetas(node: ShapeNode, allowed: Array<String>): Bool {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		return meta == null || meta.foreach(entry -> allowed.contains(entry.name));
	}

	/** `rehome_<ref>(<access>, comment)`, or null when the referenced rule carries no trivia (nothing to rehome into). */
	private static function refCall(node: ShapeNode, access: Expr): Null<Expr> {
		if (node.kind != Ref) return null;
		final refName: String = node.annotations[AnnotationKeys.BASE_REF];
		if (!TriviaTypeSynth.refIsBearing(refName)) return null;
		final fn: Expr = macro $i{fnName(refName)};
		return macro $fn($access, $i{COMMENT_ARG});
	}

	// -------- struct --------

	/**
	 * A struct's answer is its last PRESENT field's: an absent optional field emits nothing, so the token before it is
	 * the previous field's. The walk runs from the last field back and stops at the first field that is always emitted.
	 */
	private static function seqBody(node: ShapeNode, fieldNames: Array<String>): Expr {
		if (!onlyMetas(node, [':peg', ':fmt'])) return macro null;
		var tail: Expr = macro null;
		for (i in 0...node.children.length) tail = seqField(node.children[i], fieldNames, tail);
		return tail;
	}

	/** One field's answer, with `before` the answer of the fields ahead of it (taken when this one is absent). */
	private static function seqField(child: ShapeNode, fieldNames: Array<String>, before: Expr): Expr {
		final name: String = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		final access: Expr = { expr: EField(macro value, name), pos: Context.currentPos() };
		final present: Expr = switch child.kind {
			case Star: starField(child, name, fieldNames);
			case Ref: refField(child, name, fieldNames);
			case _: macro null;
		};
		if (child.annotations[AnnotationKeys.BASE_OPTIONAL] != true) return present;
		return macro $access == null ? $before : $present;
	}

	/** A close-peek trivia Star field: the comment lands in `<field>TrailingClose` after its close literal. */
	private static function starField(child: ShapeNode, name: String, fieldNames: Array<String>): Expr {
		final collects: Bool = child.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
		if (!collects || !child.hasMeta(':trail') || !onlyMetas(child, STAR_FIELD_METAS)) return macro null;
		final slot: String = name + TriviaTypeSynth.TRAILING_CLOSE_SUFFIX;
		if (!fieldNames.contains(slot)) return macro null;
		final slotAccess: Expr = { expr: EField(macro value, slot), pos: Context.currentPos() };
		final copy: Expr = structCopy(fieldNames, slot, macro $i{COMMENT_ARG});
		return macro $slotAccess == null ? $copy : null;
	}

	/** A Ref field emitted last: the answer is its value's, unless an optional `;` the source wrote follows it. */
	private static function refField(child: ShapeNode, name: String, fieldNames: Array<String>): Expr {
		if (!onlyMetas(child, TRANSPARENT_FIELD_METAS)) return macro null;
		final access: Expr = { expr: EField(macro value, name), pos: Context.currentPos() };
		final call: Null<Expr> = refCall(child, macro _f);
		if (call == null) return macro null;
		final rebuilt: Expr = macro {
			final _f = $access;
			if (_f == null)
				null
			else {
				final _r = $call;
				_r == null ? null : ${structCopy(fieldNames, name, macro _r)};
			}
		};
		if (!child.hasMeta(':trailOpt')) return rebuilt;
		// The optional trail literal only reads as transparent when the source left it out; a present `;` is the tail.
		final presentSlot: String = name + TriviaTypeSynth.TRAIL_PRESENT_SUFFIX;
		if (!fieldNames.contains(presentSlot)) return macro null;
		final presentAccess: Expr = { expr: EField(macro value, presentSlot), pos: Context.currentPos() };
		return macro $presentAccess == true ? null : $rebuilt;
	}

	/** `{ every field: value.<field> }` with `replaced` set to `with`. */
	private static function structCopy(fieldNames: Array<String>, replaced: String, with: Expr): Expr {
		final pos: Position = Context.currentPos();
		return {
			expr: EObjectDecl([
				for (f in fieldNames)
					{ field: f, expr: f == replaced ? with : { expr: EField(macro value, f), pos: pos } }
			]),
			pos: pos
		};
	}

	// -------- enum --------

	private static function altBody(origName: String, node: ShapeNode, synthPack: Array<String>): Expr {
		final cases: Array<Case> = [];
		for (branch in node.children) {
			final c: Null<Case> = altCase(origName, branch, synthPack);
			if (c != null) cases.push(c);
		}
		return { expr: ESwitch(macro value, cases, macro null), pos: Context.currentPos() };
	}

	/** One branch's case, or null when the branch never takes the comment (the switch's default answers null). */
	private static function altCase(origName: String, branch: ShapeNode, synthPack: Array<String>): Null<Case> {
		final pos: Position = Context.currentPos();
		final argNames: Array<String> = ctorArgNames(branch, synthPack);
		if (argNames.length == 0) return null;
		final binders: Array<String> = [for (i in 0...argNames.length) '_v$i'];
		final ctorName: String = branch.annotations[AnnotationKeys.BASE_CTOR];
		final ctorPath: Array<String> = synthPack.concat([
			TriviaTypeSynth.SYNTH_MODULE_LEAF,
			simpleName(origName) + TriviaTypeSynth.PAIRED_SUFFIX,
			ctorName
		]);
		final ctorRef: Expr = MacroStringTools.toFieldExpr(ctorPath);
		inline function rebuild(index: Int, with: Expr): Expr {
			return {
				expr: ECall(ctorRef, [for (i in 0...binders.length) i == index ? with : macro $i{binders[i]}]),
				pos: pos
			};
		}
		final body: Null<Expr> = switch altTail(branch, argNames) {
			case Slot(index):
				final slot: Expr = macro $i{binders[index]};
				macro $slot == null ? ${rebuild(index, macro $i{COMMENT_ARG})} : null;
			case Operand(index):
				final call: Null<Expr> = refCall(branch.children[index], macro $i{binders[index]});
				call == null
					? null
					: macro {
						final _r = $call;
						_r == null ? null : ${rebuild(index, macro _r)};
					};
			case None: null;
		};
		if (body == null) return null;
		final pattern: Expr = { expr: ECall(ctorRef, [for (b in binders) macro $i{b}]), pos: pos };
		return { values: [pattern], expr: body, guard: null };
	}

	/** Where a branch's last token is: a capture slot of its own, an operand whose answer it takes, or neither. */
	private static function altTail(branch: ShapeNode, argNames: Array<String>): AltTail {
		final children: Array<ShapeNode> = branch.children;
		if (TriviaPairAltCtor.isAltCloseTrailingBranch(branch) || TriviaPairAltCtor.isPostfixCloseTrailingBranch(branch)) {
			final index: Int = argNames.indexOf(CLOSE_TRAILING_ARG);
			return index < 0 ? None : Slot(index);
		}
		if (branch.hasMeta(':infix')) return children.length == 2 && onlyMetas(branch, [':infix', ':fmt']) ? Operand(1) : None;
		if (branch.hasMeta(':ternary')) return children.length == 3 && onlyMetas(branch, [':ternary', ':fmt']) ? Operand(2) : None;
		if (branch.hasMeta(':prefix')) return children.length == 1 && onlyMetas(branch, [':prefix', ':fmt']) ? Operand(0) : None;
		final single: Bool = children.length == 1
			&& children[0].kind == Ref
			&& children[0].annotations[AnnotationKeys.BASE_OPTIONAL] != true;
		return single && onlyMetas(branch, TRANSPARENT_BRANCH_METAS) ? Operand(0) : None;
	}

	/** The paired ctor's positional argument names, read off the definition the synth pass emits — never recounted. */
	private static function ctorArgNames(branch: ShapeNode, synthPack: Array<String>): Array<String> {
		return switch TriviaPairAltCtor.buildEnumCtor(branch, Context.currentPos(), synthPack).kind {
			case FFun(f): [for (a in f.args) a.name];
			case _: [];
		};
	}

}

/** Where an Alt branch's last token lies, for `TriviaTailRehome.altTail`. */
private enum AltTail {

	/** The branch's own positional slot at this index captures the comment. */
	Slot(index: Int);

	/** The operand at this index ends the branch; its answer is the branch's. */
	Operand(index: Int);

	/** Neither: the parser leaves the comment where it is. */
	None;

}
#end
