package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * The one answer to "where does a match of a grammar-declared shape end in raw text": from the shape of a `@:peg`
 * type it generates a standalone reader `endAt(input, at)` over an `Input` and an offset — no parse, no AST, no
 * implicit blank skipping. A grammar declares this way the extent of a construct whose text it keeps verbatim (a
 * preprocessor condition) and names the reader from a `@:scan` terminal, so its parser and every scan over a file
 * the grammar cannot parse read one extent.
 *
 * The shape is read as a PEG: an enum tries its constructors in declaration order and takes the first that matches;
 * a constructor or field matches its `@:lead`, its parts and its `@:trail` in order; an `Array<T>` repeats `T` while
 * it advances; a `Null<T>` field may be absent; a terminal matches its `@:re` in one committed pass
 * (`RegexScanPlan`), so the reader needs no regex engine and copies nothing. Any other metadata on a part, a lead or
 * trail around an optional part and a field's `@:lit` refuse the build: a reader that ignored them would answer an
 * extent the declaration does not state.
 */
final class ExtentScanLowering {

	/** The metadata a constructor or a field of an extent shape may carry. */
	private static final PART_META: Array<String> = [':lead', ':trail', ':lit', ':optional'];

	/** The public reader every grammar's `@:scan` names. */
	private static final ENTRY: String = 'endAt';

	/** The fields of the reader of `shape`: the public entry and one private function per rule and constructor it reaches. */
	public static function generate(shape: ShapeBuilder.ShapeResult): Array<Field> {
		final fields: Array<Field> = [entryField(shape.root)];
		final pending: Array<String> = [shape.root];
		final seen: Array<String> = [];
		while (pending.length > 0) {
			final rule: String = pending.shift() ?? '';
			if (seen.contains(rule)) continue;
			seen.push(rule);
			final node: ShapeNode = shape.rules[rule] ?? fail('ExtentScan: the shape has no rule $rule');
			switch node.kind {
				case Alt:
					final tries: Array<Expr> = [];
					for (branch in node.children) {
						final ctor: String = branch.annotations[AnnotationKeys.BASE_CTOR];
						final name: String = '${fnName(rule)}_$ctor';
						fields.push(ruleField(name, seqBody(branch, '$rule.$ctor', pending)));
						tries.push(macro {
							final end: Int = $i{name}(input, at);
							if (end >= 0) return end;
						});
					}
					tries.push(macro return -1);
					fields.push(ruleField(fnName(rule), macro $b{tries}));
				case Seq:
					fields.push(ruleField(fnName(rule), seqBody(node, rule, pending)));
				case Terminal:
					fields.push(ruleField(fnName(rule), terminalBody(node, rule)));
				case _:
					fail('ExtentScan: $rule is neither an enum, a typedef nor a terminal');
			}
		}
		return fields;
	}

	/** Report `message` and stop the build; generic so a value position of any type can return it. */
	private static function fail<T>(message: String): T {
		return Context.fatalError(message, Context.currentPos());
	}

	/** The private reader of `rule`: the end of its match at `at`, or -1. */
	private static function fnName(rule: String): String {
		return '_extent_${rule.split('.').join('_')}';
	}

	private static function entryField(root: String): Field {
		final first: String = fnName(root);
		return {
			name: ENTRY,
			doc: 'Where a match of `$root` starting exactly at `at` ends, or `at` when none — the reader a `@:scan` terminal names.',
			access: [APublic, AStatic],
			kind: FFun({
				args: [
					{ name: 'input', type: macro : anyparse.runtime.Input },
					{ name: 'at', type: macro : Int }
				],
				ret: macro : Int,
				expr: macro {
					final end: Int = $i{first}(input, at);
					return end < 0 ? at : end;
				}
			}),
			pos: Context.currentPos()
		};
	}

	private static function ruleField(name: String, body: Expr): Field {
		return {
			name: name,
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{ name: 'input', type: macro : anyparse.runtime.Input },
					{ name: 'at', type: macro : Int }
				],
				ret: macro : Int,
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

	/** The parts of a typedef or of one enum constructor, matched in order from `at`, inside the constructor's own lead and trail. */
	private static function seqBody(node: ShapeNode, origin: String, pending: Array<String>): Expr {
		final branch: Bool = node.annotations[AnnotationKeys.BASE_CTOR] != null;
		if (branch) checkMeta(node, origin);
		final steps: Array<Expr> = [macro var p: Int = at];
		if (branch) {
			pushLiteral(steps, MetaInspect.readMetaString(node, ':lead'));
			pushLiteral(steps, MetaInspect.readMetaString(node, ':lit'));
		}
		for (child in node.children) {
			final part: String = '$origin.${child.annotations[AnnotationKeys.BASE_FIELD_NAME]}';
			checkMeta(child, part);
			final lead: Null<String> = MetaInspect.readMetaString(child, ':lead');
			final trail: Null<String> = MetaInspect.readMetaString(child, ':trail');
			// Fail closed on what the parser reads but this reader would not: an optional part's lead and trail belong
			// to the part, and a field's `@:lit` is no part of its extent.
			if (MetaInspect.hasMeta(child, ':lit')) fail('ExtentScan: @:lit on the field $part has no meaning in an extent');
			if (child.annotations[AnnotationKeys.BASE_OPTIONAL] == true && (lead != null || trail != null))
				fail('ExtentScan: the optional part $part carries @:lead or @:trail, which an extent does not read');
			pushLiteral(steps, lead);
			steps.push(partStep(child, part, pending));
			pushLiteral(steps, trail);
		}
		if (branch) pushLiteral(steps, MetaInspect.readMetaString(node, ':trail'));
		steps.push(macro return p);
		return macro $b{steps};
	}

	private static function checkMeta(node: ShapeNode, origin: String): Void {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return;
		for (entry in meta) if (!PART_META.contains(entry.name))
			Context.fatalError('ExtentScan: @${entry.name} on $origin has no meaning in an extent', entry.pos);
	}

	/** Match `text` at `p` and step past it, or answer -1. */
	private static function pushLiteral(steps: Array<Expr>, text: Null<String>): Void {
		if (text == null || text == '') return;
		var test: Null<Expr> = null;
		for (k in 0...text.length) {
			final code: Int = text.charCodeAt(k) ?? -1;
			final one: Expr = macro input.charCodeAt(p + $v{k}) == $v{code};
			test = test == null ? one : macro $test && $one;
		}
		steps.push(macro if (!($test)) return -1);
		steps.push(macro p += $v{text.length});
	}

	/** One part: a required or optional rule, or a repetition of one. */
	private static function partStep(child: ShapeNode, origin: String, pending: Array<String>): Expr {
		return switch child.kind {
			case Ref:
				final fn: String = refFn(child, pending);
				child.annotations[AnnotationKeys.BASE_OPTIONAL] == true
					? macro {
						final next: Int = $i{fn}(input, p);
						if (next >= 0) p = next;
					}
					: macro {
						p = $i{fn}(input, p);
						if (p < 0) return -1;
					};
			case Star:
				final element: ShapeNode = child.children[0];
				if (element.kind != Ref) fail('ExtentScan: the repeated part $origin must name a declared type');
				final fn: String = refFn(element, pending);
				macro while (true) {
					final next: Int = $i{fn}(input, p);
					if (next <= p) break;
					p = next;
				};
			case _: fail('ExtentScan: the part $origin must name a declared type or an Array of one');
		};
	}

	private static function refFn(node: ShapeNode, pending: Array<String>): String {
		final target: String = node.annotations[AnnotationKeys.BASE_REF];
		pending.push(target);
		return fnName(target);
	}

	/** A terminal's `@:re`, scanned in one committed pass: the end of its match at `at`, or -1. */
	private static function terminalBody(node: ShapeNode, rule: String): Expr {
		final pattern: String = MetaInspect.readMetaString(node, ':re') ?? fail('ExtentScan: the terminal $rule needs a @:re pattern');
		final plan: ScanNode = RegexScanPlan.of(pattern) ?? fail(
			'ExtentScan: the @:re of $rule needs backtracking; an extent terminal is scanned in one committed pass'
		);
		return TerminalScanLowering.scan(plan, macro input, macro at, macro return _hit ? _p : -1);
	}

}
#end
